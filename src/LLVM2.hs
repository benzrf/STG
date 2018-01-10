{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
module LLVM2 where

import Bound
import Bound.Scope
import Control.Monad.Reader
import Control.Monad.State
import Data.ByteString (ByteString)
import Data.List
import qualified Data.Map as M
import Data.String
import Lam
import LLVM.AST hiding (function, Name, Add, Sub, Mul)
import qualified LLVM.AST as AST
import qualified LLVM.AST.Constant as K
import qualified LLVM.AST.IntegerPredicate as IP
import LLVM.AST.Type hiding (void)
import LLVM.IRBuilder
import qualified LLVM.Module as L
import LLVM.Context
import Preamble

-- looks like the place we'll need fresh names is in the monad that
-- DOESN'T supply them...
type ModB = ReaderT Env (StateT Int ModuleBuilder)
-- The map associates thunk variables to variables containing the result of
-- forcing them, to avoid duplicating thunk forces.
type FunB = StateT (M.Map Operand Operand) (IRBuilderT ModB)

data Pos r where
  Res :: Pos ()
  Scrut :: Pos Operand
  Force :: Pos Operand
deriving instance Show (Pos r)

result :: Pos r -> FunB Operand -> FunB r
result Res o = o `named` "res" >>= ret
result Scrut o = o
result Force o = o

-- The caller must supply an exhaustive list of possibilities or there will be
-- undefined behavior!!!
switchPos :: Pos r -> Operand -> [(K.Constant, FunB r)] -> FunB r
switchPos p x branches = do
  defaultLabel <- freshName "default"
  resLabel <- freshName "res"
  labelled <- forM branches $ \b -> (,) b <$> freshName "branch"
  switch x defaultLabel . flip map labelled $ \((k, _), l) -> (k, l)
  phis <- forM labelled $ \((_, body), label) -> do
    emitBlockStart label
    old <- get
    r <- body
    put old
    () <- case p of Res -> return (); _ -> br resLabel
    -- this is kinda hacky...
    let l IRBuilderState {builderBlock =
      Just PartialBlock {partialBlockName = name}} = name
    curLabel <- liftIRState (gets l)
    return (r, curLabel)
  emitBlockStart defaultLabel
  unreachable
  case p of
    Res -> return ()
    Scrut -> do
      emitBlockStart resLabel
      phi phis
    Force -> do
      emitBlockStart resLabel
      phi phis

-- In order to support recursive definitions, we need to account for the fact
-- that a field of the closure may depend on the closure itself
mkClosure :: Operand -> [Operand -> FunB Operand] -> FunB Operand
mkClosure proc fieldAs = do
  alloc <- asks allocObj
  let fc = lit64 (length fieldAs)
  clos <- call alloc [(proc, []), (fc, []), (fc, [])]
  fields <- mapM ($ clos) fieldAs

  forM_ (zip fields [0..]) $ \(fr, i) -> do
    fieldp <- closFieldp clos i `named` "fieldp_new"
    store fieldp 0 fr

  return clos

mkProc ::
  (Operand -> Operand -> Operand -> Operand -> FunB ()) -> ModB Operand
mkProc body = do
  freshNum <- get
  put (freshNum + 1)
  let funName = mkName ("proc." ++ show freshNum)
      params = [(objP, ParameterName "cur_clos"),
                (objA, ParameterName "stack"),
                (i8, ParameterName "arg_count")]
      proc = ConstantOperand $ K.GlobalReference funTy funName
      body' [cur, stk, argc] =
        evalStateT (body proc cur stk argc `named` "tmp") mempty
  function funName params resTy body'
  return proc

mkProc' ::
  (Operand -> Operand -> Operand -> Operand -> FunB ()) -> FunB Operand
mkProc' = lift . lift . mkProc

closureProc :: Eq a => Lam a -> FunB (Operand, [a])
closureProc l = do
  let (li, free) = runState (traverse (state . replace) l) []
      replace v seen = case findIndex (==v) seen of
        Nothing -> (length seen, seen ++ [v])
        Just i  -> (i, seen)

  proc <- mkProc' $ \proc cur stk argc -> do
    fields <- case free of
      [] -> return []
      _ -> do
        forM [0..length free - 1] $ \i -> do
          field <- closFieldp cur i `named` "closedp"
          load field 0 `named` "closed"
    let l' = (fields !!) <$> li
    case l' of
      Abs (Name s) b -> do
        (arg, args') <- pop (Args stk argc 0) `named` fromString s
        compile Res args' (instantiate1 (Var arg) b)
      _ -> do
        res <- compile Force (Args stk (lit8 0) 0) l' `named` "res"
        enter <- objEnter cur `named` "enter_cur"
        asks indirProc >>= store enter 0
        target <- resObj res `named` "target"
        targeti <- ptrtoint target i64 `named` "targeti"
        valp <- objVal cur `named` "valp"
        store valp 0 targeti
        haveArg <- icmp IP.UGT argc (lit8 0) `named` "have_arg"
        switchPos Res haveArg [(K.Int 1 0, ret res),
                               (K.Int 1 1,
                                compile Res (Args stk argc 0) (Var target))]

  return (proc, free)

-- F is a normal free variable and B is a circular reference to the thunk
-- itself. "let x = x in ..." will have undefined behavior if x is forced in
-- "...".
thunk :: Lam (Var () Operand) -> FunB Operand
thunk (Var (B ())) = return (undef objP)
thunk (Var (F obj)) = return obj
thunk (Ctor name fs) = do
  proc <- mkProc' $ \proc cur stk argc ->
    mkRes (lit64 (hashCode name)) (Just cur) >>= ret
  let free self (B ()) = F self
      free self (F o)  = F o
      field f self = thunk (free self <$> f) `named` "field_new"
  mkClosure proc (map field fs)
thunk l = do
  (proc, free) <- closureProc l
  let field (B ()) self = return self
      field (F clos) self = return clos
  mkClosure proc (map field free)

-- nsr = no self-reference
nsrThunk :: Lam Operand -> FunB Operand
nsrThunk = thunk . fmap F

scrutinize :: Args -> Lam Operand -> FunB Operand
scrutinize (Args stk _ _) = compile Scrut (Args stk (lit8 0) 0)

compile :: Pos r -> Args -> Lam Operand -> FunB r
compile p args@(Args stk argc change) l = case l of
  Var obj -> do
    saved <- gets (M.lookup obj)
    result p $ case (p, change, saved) of
      -- in Scrut or Force, we will never even end up reaching a
      -- variable with change < 0 in a well-formed program, so matching
      -- 0 is enough
      (Scrut, 0, Just res) -> return res
      (Force, 0, Just res) -> return res
      _ -> do
        enter <- objEnter obj `named` "enter"
        proc <- load enter 0 `named` "proc"
        case p of
          Res -> do
            argc' <- add argc (lit8 change) `named` "arg_count"
            call' proc [obj, stk, argc'] (Just MustTail)
          _ -> do
            res <- call' proc [obj, stk, lit8 change] Nothing
            when (change == 0) $ modify' (M.insert obj res)
            return res
  Abs (Name s) b -> do
    let doApply = do
          (arg, args') <- pop args `named` fromString s
          compile p args' (instantiate1 (Var arg) b)
    if change <= 0 then do
      haveArg <- icmp IP.UGT argc (lit8 (-change)) `named` "have_arg"
      switchPos p haveArg [(K.Int 1 1, doApply),
                           (K.Int 1 0,
                            nsrThunk l `named` "pap" >>=
                            result p . mkRes (undef i64) . Just)]
    else doApply
  App f x -> do
    obj <- nsrThunk x `named` "arg"
    args' <- push args obj
    compile p args' f
  SApp f x -> do
    obj <- nsrThunk x `named` "arg"
    scrutinize args (Var obj)
    args' <- push args obj
    compile p args' f
  Let (Name s) x b -> do
    obj <- thunk (fromScope x) `named` fromString s
    compile p args (instantiate1 (Var obj) b)
  Lit i -> do
    case p of
      Scrut -> mkRes (lit64 i) Nothing
      _ -> result p $ do
        mk <- asks mkIntRes
        call mk [(lit64 i, [])]
  Op op x y -> do
    x' <- (scrutinize args x >>= resInt) `named` "lhs"
    y' <- (scrutinize args y >>= resInt) `named` "rhs"
    let [t, f] = map (lit64 . hashCode . Name) ["True", "False"]
        sel b = select b t f
    val <- flip named "val" $ case op of
      Add -> add x' y'
      Sub -> sub x' y'
      Mul -> mul x' y'
      Div -> emitInstr i64 $ SDiv False x' y' []
      Eq  -> icmp IP.EQ x' y' >>= sel
      Leq -> icmp IP.SLE x' y' >>= sel
    result p $ case p of
      Scrut -> mkRes val Nothing
      _ -> do mk <- asks mkIntRes; call mk [(val, [])]
  Ctor name fs ->
    nsrThunk l `named` "ctor" >>=
    result p . mkRes (lit64 (hashCode name)) . Just
  Case x cs -> do
    x' <- scrutinize args x `named` "scrutinee"
    hash <- resInt x' `named` "hash"
    clos <- resObj x' `named` "clos_res"
    -- fs <- emitInstr closA (ExtractValue closv [1] []) `named` "fields_res"
    switchPos p hash . flip map cs $ \(Clause name names b) ->
      (K.Int 64 (toInteger (hashCode name)), do
        fields <- forM (zip [0..] names) $ \(i, Name s) -> do
          fieldp <- closFieldp clos i `named` fromString (s ++ "p")
          load fieldp 0 `named` fromString s
        compile p args (instantiateVars fields b))

driverTerm :: Lam Name
Right driverTerm = parseLam . unlines $ [
  "case main of",
  "  Left i -> print i",
  "  Right p ->",
  "    let input x = (let c = (let c = getchar in c)",
  "                   in if c <= -1 then Nil []",
  "                      else Cons [c, input 0])",
  "        driver o = case o of",
  "          Nil -> 0",
  "          Cons c cs -> (\\x -> driver cs) $! putchar c",
  "    in driver (p (input 0))"]

driver :: Lam Operand -> ModB Operand
driver main = do
  env <- ask
  mkProc $ \proc cur stk argc -> do
    let alloc0 proc = call (allocObj env)
          [(proc, []), (lit64 0, []), (lit64 0, [])]
    [print, getchar, putchar] <- mapM alloc0
      [printProc env, gcProc env, pcProc env]
    let impl "main" = main
        impl "print" = return print
        impl "getchar" = return getchar
        impl "putchar" = return putchar
        implTerm = driverTerm >>= impl . getName
    compile Res (Args stk argc 0) implTerm

compileMain :: Lam Operand -> ModuleBuilder ()
compileMain l = do
  env <- preamble
  outer <- evalStateT (runReaderT (driver l) env) 0
  let calloc' = calloc env
  void . function "main" [] i32 . const $ do
    let allocation = [(lit64 3000, []), (lit64 8, [])]
    stkMem <- call calloc' allocation `named` "stack_mem"
    stk <- bitcast stkMem objA `named` "stack"
    call outer [(undef objP, []), (stk, []), (lit8 1, [])]
    ret (lit32 0)

serialize :: Module -> IO ByteString
serialize mod = withContext $ \ctx ->
  L.withModuleFromAST ctx mod L.moduleLLVMAssembly

compileToLL :: Lam Operand -> IO ByteString
compileToLL = serialize . buildModule "main" . compileMain
