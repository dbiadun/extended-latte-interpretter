module Interpreter where

-- Haskell module generated by the BNF converter

import           Control.Monad.State
import           Control.Monad.Except
import           Control.Monad                  ( void )
import           Data.Maybe
import           System.IO
import qualified Data.Map                      as Map
import qualified Data.Set                      as Set

import           AbsGrammar                    as Grammar
import           ErrM


-------------------------------------------------------------------------------

-- TODO: runtime error on missing return

type Result = IM ()

interpret :: Show a => Program a -> IO ()
interpret p = do
  (ret, s) <- runStateT (runExceptT $ transProgram p) initialState
  case ret of
    Left (ErrorExcept err) -> hPutStrLn stderr err
    _                      -> do
      (ret1, _) <- runStateT
        (runExceptT $ getFunction (Ident "main") >>= runFunction [])
        s
      case ret1 of
        Left (ErrorExcept err1) -> hPutStrLn stderr err1
        _                       -> return ()
  return ()


-- Program --------------------------------------------------------------------

transProgram :: Show a => Program a -> IM ()
transProgram x = case x of
  Program _ decls -> transAllDecls decls


-- Main monad -----------------------------------------------------------------

type IM = ExceptT ExceptItem (StateT IState IO)

-- runOnExcept :: ExceptT String (StateT IState IO) a -> IM a
-- runOnExcept = id

-- runOnState :: StateT IState IO a -> IM a
-- runOnState = lift

runOnIO :: IO a -> IM a
runOnIO = lift . lift


-- Except ---------------------------------------------------------------------

data ExceptItem = ErrorExcept String | ReturnExcept Value | VoidReturnExcept | BreakExcept | ContinueExcept

showPos :: Show a => a -> String
showPos pos = case show pos of
  ('J' : 'u' : 's' : 't' : ' ' : realPos) -> realPos
  _ -> show pos

runtimeError :: Show a => a -> String -> IM b
runtimeError pos mes =
  throwError $ ErrorExcept $ "RuntimeError on " ++ showPos pos ++ ": " ++ mes


staticError :: IM a
staticError = throwError $ ErrorExcept "StaticError"


-- State ----------------------------------------------------------------------

data Value = IntV Integer | StrV String | BoolV Bool | VoidV ()
  deriving (Eq, Ord, Read)
newtype Loc = Loc Integer deriving (Eq, Ord, Show, Read)
data ValueType = IntT | StrT | BoolT | VoidT | NoneT

data Func = Func [ArgT] ([FArg] -> IM Value)
data ArgT = ValT ValueType | RefT ValueType
data FArg = ValArg Value | RefArg Loc

data FunArg = ValType Value | RefType Loc

newtype VEnv = VEnv (Map.Map Ident Loc)
newtype FEnv = FEnv (Map.Map Ident Func)
newtype TEnv = TEnv (Map.Map Ident ValueType)
newtype Store = Store (Map.Map Loc Value)
newtype LocsSet = LocsSet (Set.Set Loc)

data IState = IState {
  venv :: VEnv,
  fenv :: FEnv,
  tenv :: TEnv,
  store :: Store,
  freeLocs :: LocsSet,
  usedLocs :: LocsSet,
  maxLoc :: Loc
}

instance Show Value where
  show (IntV  n) = show n
  show (StrV  s) = s
  show (BoolV b) = show b
  show _         = ""

initialState :: IState
initialState = IState { venv     = VEnv Map.empty
                      , fenv     = FEnv Map.empty
                      , tenv     = TEnv Map.empty
                      , store    = Store Map.empty
                      , freeLocs = LocsSet Set.empty
                      , usedLocs = LocsSet Set.empty
                      , maxLoc   = Loc 0
                      }


runOnVenvMap :: (Map.Map Ident Loc -> a) -> VEnv -> a
runOnVenvMap f (VEnv map) = f map

runOnFenvMap :: (Map.Map Ident Func -> a) -> FEnv -> a
runOnFenvMap f (FEnv map) = f map

runOnTenvMap :: (Map.Map Ident ValueType -> a) -> TEnv -> a
runOnTenvMap f (TEnv map) = f map

runOnStoreMap :: (Map.Map Loc Value -> a) -> Store -> a
runOnStoreMap f (Store map) = f map

runOnLocsSet :: (Set.Set Loc -> a) -> LocsSet -> a
runOnLocsSet f (LocsSet set) = f set

runIsolated :: IM a -> IM a
runIsolated x = do
  formerState  <- get
  ret          <- x
  currentStore <- gets store
  put formerState
    { store = Store $ runOnStoreMap
                (runOnStoreMap Map.intersection currentStore)
                (store formerState)
    }
  return ret

-- Variables ------------------------------------------------------------------

isDeclared :: Ident -> IM Bool
isDeclared id = gets $ runOnVenvMap (Map.member id) . venv

getLocation :: Ident -> IM Loc
getLocation id = gets $ runOnVenvMap (Map.findWithDefault (Loc (-1)) id) . venv

isDefined :: Ident -> IM Bool
isDefined id = do
  l <- getLocation id
  gets $ runOnStoreMap (Map.member l) . store

getType :: Ident -> IM ValueType
getType id =
  let getTypeFromState :: IState -> ValueType
      getTypeFromState = runOnTenvMap (Map.findWithDefault NoneT id) . tenv
  in  gets getTypeFromState

addVariableType :: Ident -> ValueType -> IState -> IState
addVariableType id t s =
  s { tenv = TEnv $ runOnTenvMap (Map.insert id t) $ tenv s }

setVariableLoc :: Ident -> Loc -> IState -> IState
setVariableLoc id l s =
  s { venv = VEnv $ runOnVenvMap (Map.insert id l) $ venv s }

declareVariable :: Ident -> ValueType -> IM ()
declareVariable id type_ =
  let
    locAvailable :: IState -> Bool
    locAvailable = runOnLocsSet (not . Set.null) . freeLocs

    addLoc :: IState -> IState
    addLoc s = s
      { freeLocs = LocsSet $ runOnLocsSet (Set.insert (Loc (l + 1))) $ freeLocs
                     s
      , maxLoc   = Loc (l + 1)
      }
      where (Loc l) = maxLoc s

    prepareNextLoc :: IState -> IState
    prepareNextLoc s | locAvailable s = s
                     | otherwise      = addLoc s

    takeNextLoc :: IState -> (Loc, IState)
    takeNextLoc s =
      (l, s { usedLocs = LocsSet newUsedLocs, freeLocs = LocsSet newFreeLocs })
     where
      l           = runOnLocsSet Set.findMin $ freeLocs s
      newFreeLocs = runOnLocsSet Set.deleteMin $ freeLocs s
      newUsedLocs = runOnLocsSet (Set.insert l) $ usedLocs s

    addVariableLoc :: Ident -> IState -> IState
    addVariableLoc id1 s1 = setVariableLoc id1 l s2
      where (l, s2) = takeNextLoc $ prepareNextLoc s1
  in
    do
      modify (addVariableType id type_)
      modify (addVariableLoc id)

assignValue :: Ident -> Value -> IM ()
assignValue id val =
  let addValue :: Ident -> Value -> IState -> IState
      addValue id1 val1 s = s
        { store = Store $ runOnStoreMap (Map.insert l val1) $ store s
        }
          where l = runOnVenvMap (Map.findWithDefault (Loc (-1)) id1) $ venv s
  in  modify (addValue id val)

getValue :: Show a => a -> Ident -> IM Value
getValue pos id = do
  def <- isDefined id
  if def
    then do
      l <- getLocation id
      gets $ runOnStoreMap (Map.findWithDefault (VoidV ()) l) . store
    else runtimeError pos $ "Variable " ++ show id ++ " not defined"


-- Functions ------------------------------------------------------------------

addFunction :: Ident -> Func -> IM ()
addFunction id f =
  let addFunctionToState :: Ident -> Func -> IState -> IState
      addFunctionToState id1 f1 s =
          s { fenv = FEnv $ runOnFenvMap (Map.insert id1 f1) $ fenv s }
  in  modify $ addFunctionToState id f

createFunction
  :: Show a
  => IState
  -> Ident
  -> ValueType
  -> [(ArgT, Ident)]
  -> Block a
  -> Func
createFunction s id fType argDescriptions block =
  let argTypes :: [ArgT]
      argTypes = map fst argDescriptions

      addParameters :: [(ArgT, Ident)] -> [FArg] -> IM ()
      addParameters [] []               = return ()
      addParameters ((type_, id) : nextTypeDecriptions) (arg : nextArgs) = do
        case (type_, arg) of
          (ValT t, ValArg v) -> declareVariable id t >> assignValue id v
          (RefT t, RefArg l) ->
            modify (addVariableType id t . setVariableLoc id l)
        addParameters nextTypeDecriptions nextArgs
      addParameters _ _ = staticError

      fAction :: [FArg] -> IM Value
      fAction args =
          do
              currentState <- get
              put $ currentState { venv = venv s, fenv = fenv s, tenv = tenv s }
              addParameters argDescriptions args
              addFunction id $ createFunction s id fType argDescriptions block
              transBlock block
              return $ VoidV ()
            `catchError` (\err -> case err of
                           ReturnExcept ret -> return ret
                           VoidReturnExcept -> return $ VoidV ()
                           _                -> throwError err
                         )
  in  Func argTypes (runIsolated . fAction)

getFunction :: Ident -> IM Func
getFunction id =
  gets
    $ runOnFenvMap (Map.findWithDefault (Func [] (\_ -> return $ VoidV ())) id)
    . fenv

runFunction :: [FArg] -> Func -> IM Value
runFunction args (Func argDescriptions f) = f args


-- Blocks ---------------------------------------------------------------------

transBlock :: Show a => Block a -> IM ()
transBlock x = case x of
  Block _ blockinsts -> runIsolated $ transAllBlockInsts blockinsts

transAllBlockInsts :: Show a => [BlockInst a] -> IM ()
transAllBlockInsts x = case x of
  []       -> return ()
  bi : bis -> transBlockInst bi >> transAllBlockInsts bis

transBlockInst :: Show a => BlockInst a -> IM ()
transBlockInst x = case x of
  DeclInst _ decl -> transDecl decl
  StmtInst _ stmt -> transStmt stmt


-- Declarations ---------------------------------------------------------------

transAllDecls :: Show a => [Decl a] -> IM ()
transAllDecls x = case x of
  [ d ]  -> transDecl d
  d : ds -> transDecl d >> transAllDecls ds

transDecl :: Show a => Decl a -> IM ()
transDecl x = case x of
  FnDecl _ type_ ident args block -> do
    s <- get
    let returnType      = transType type_
    let argDescriptions = map transArg args
    let f = createFunction s ident returnType argDescriptions block
    addFunction ident f
  VarDecl _ type_ [item] -> case item of
    NoInit pos id    -> declareVariable id (transType type_)
    Init pos id expr -> do
      let t = transType type_
      val <- transExpr expr
      declareVariable id t
      assignValue id val
  VarDecl pos type_ (item : items) -> transDecl (VarDecl pos type_ [item])
    >> transDecl (VarDecl pos type_ items)

transArg :: Show a => Arg a -> (ArgT, Ident)
transArg x = case x of
  Arg _ argtype ident -> (transArgType argtype, ident)

correctType :: ValueType -> Value -> Bool
correctType type_ value = case (type_, value) of
  (IntT , IntV _ ) -> True
  (StrT , StrV _ ) -> True
  (BoolT, BoolV _) -> True
  _                -> False


-- Statements -----------------------------------------------------------------

transStmt :: Show a => Stmt a -> IM ()
transStmt x = case x of
  Empty _          -> return ()
  BStmt _ block    -> transBlock block
  Ass _ ident expr -> transExpr expr >>= assignValue ident
  Incr pos ident   -> do
    val <- getValue pos ident
    case val of
      IntV n -> assignValue ident $ IntV (n + 1)
      _      -> staticError
  Decr pos ident -> do
    val <- getValue pos ident
    case val of
      IntV n -> assignValue ident $ IntV (n - 1)
      _      -> staticError
  Ret _ expr       -> transExpr expr >>= throwError . ReturnExcept
  VRet _           -> throwError VoidReturnExcept
  Cond _ expr stmt -> do
    b <- transExpr expr
    case b of
      BoolV True -> transStmt stmt
      _          -> return ()
  CondElse _ expr stmt1 stmt2 -> do
    b <- transExpr expr
    case b of
      BoolV True -> transStmt stmt1
      _          -> transStmt stmt2
  w@(While _ expr stmt) -> do
    b <- transExpr expr
    case b of
      BoolV True ->
        do
            transStmt stmt
            transStmt w
          `catchError` (\x -> case x of
                         BreakExcept    -> return ()
                         ContinueExcept -> transStmt w
                         err            -> throwError err
                       )
      _ -> return ()
  SExp _ expr  -> Control.Monad.void $ transExpr expr
  Break    _   -> throwError BreakExcept
  Continue _   -> throwError ContinueExcept
  Print _ expr -> do
    val <- transExpr expr
    runOnIO $ putStr $ show val


-- Types ----------------------------------------------------------------------

transType :: Show a => Type a -> ValueType
transType x = case x of
  Grammar.Int  _ -> IntT
  Grammar.Str  _ -> StrT
  Grammar.Bool _ -> BoolT
  Grammar.Void _ -> VoidT

transArgType :: Show a => ArgType a -> ArgT
transArgType x = case x of
  ValArgType _ type_ -> ValT $ transType type_
  RefArgType _ type_ -> RefT $ transType type_


-- Expressions ----------------------------------------------------------------

transExpr :: Show a => Expr a -> IM Value
transExpr x = case x of
  EVar    pos ident   -> getValue pos ident
  ELitInt _   integer -> return $ IntV integer
  ELitTrue  _         -> return $ BoolV True
  ELitFalse _         -> return $ BoolV False
  EApp _ ident exprs  -> do
    (Func types f) <- getFunction ident
    args           <- getArgsFromExprs types exprs
    f args
  EString _ string -> return $ StrV string
  Neg     _ expr   -> do
    former_val <- transExpr expr
    case former_val of
      IntV n -> return $ IntV $ (-1) * n
      _      -> staticError
  Not _ expr -> do
    former_val <- transExpr expr
    case former_val of
      BoolV b -> return $ BoolV $ not b
      _       -> staticError
  EMul _ expr1 mulop expr2 -> do
    v1 <- transExpr expr1
    v2 <- transExpr expr2
    transMulOp mulop v1 v2
  EAdd _ expr1 addop expr2 -> do
    v1 <- transExpr expr1
    v2 <- transExpr expr2
    transAddOp addop v1 v2
  ERel _ expr1 relop expr2 -> do
    v1 <- transExpr expr1
    v2 <- transExpr expr2
    transRelOp relop v1 v2
  EAnd _ expr1 expr2 -> do
    v1 <- transExpr expr1
    v2 <- transExpr expr2
    case (v1, v2) of
      (BoolV b1, BoolV b2) -> return $ BoolV $ b1 && b2
      _                    -> staticError
  EOr _ expr1 expr2 -> do
    v1 <- transExpr expr1
    v2 <- transExpr expr2
    case (v1, v2) of
      (BoolV b1, BoolV b2) -> return $ BoolV $ b1 || b2
      _                    -> staticError

getArgsFromExprs :: Show a => [ArgT] -> [Expr a] -> IM [FArg]
getArgsFromExprs []              []             = return []
getArgsFromExprs (type_ : types) (expr : exprs) = do
  nextArgs <- getArgsFromExprs types exprs
  case (type_, expr) of
    (ValT t, e) -> do
      val <- transExpr e
      return $ ValArg val : nextArgs
    (RefT t, EVar _ id) -> do
      l <- getLocation id
      return $ RefArg l : nextArgs


-- Operators ------------------------------------------------------------------

transAddOp :: Show a => AddOp a -> (Value -> Value -> IM Value)
transAddOp x = case x of
  Plus _ ->
    let add :: Value -> Value -> IM Value
        add v1 v2 = case (v1, v2) of
          (IntV n1, IntV n2) -> return $ IntV $ n1 + n2
          (StrV s1, StrV s2) -> return $ StrV $ s1 ++ s2
          _                  -> staticError
    in  add
  Minus _ ->
    let subtract :: Value -> Value -> IM Value
        subtract v1 v2 = case (v1, v2) of
          (IntV n1, IntV n2) -> return $ IntV $ n1 - n2
          _                  -> staticError
    in  subtract

transMulOp :: Show a => MulOp a -> (Value -> Value -> IM Value)
transMulOp x = case x of
  Times _ ->
    let multiply :: Value -> Value -> IM Value
        multiply v1 v2 = case (v1, v2) of
          (IntV n1, IntV n2) -> return $ IntV $ n1 * n2
          _                  -> staticError
    in  multiply
  Div pos ->
    let divide :: Value -> Value -> IM Value
        divide v1 v2 = case (v1, v2) of
          (IntV n1, IntV n2) -> if n2 == 0
            then runtimeError pos "Division by 0"
            else return $ IntV $ n1 `div` n2
          _ -> staticError
    in  divide
  Mod pos ->
    let modulo :: Value -> Value -> IM Value
        modulo v1 v2 = case (v1, v2) of
          (IntV n1, IntV n2) -> if n2 == 0
            then runtimeError pos "Modulo 0 operation"
            else return $ IntV $ n1 `mod` n2
          _ -> staticError
    in  modulo

transRelOp :: Show a => RelOp a -> (Value -> Value -> IM Value)
transRelOp x = case x of
  LTH _ ->
    let lth :: Value -> Value -> IM Value
        lth v1 v2 = case (v1, v2) of
          (IntV n1, IntV n2) -> return $ BoolV $ n1 < n2
          _                  -> staticError
    in  lth
  LE _ ->
    let le :: Value -> Value -> IM Value
        le v1 v2 = case (v1, v2) of
          (IntV n1, IntV n2) -> return $ BoolV $ n1 <= n2
          _                  -> staticError
    in  le
  GTH _ ->
    let gth :: Value -> Value -> IM Value
        gth v1 v2 = case (v1, v2) of
          (IntV n1, IntV n2) -> return $ BoolV $ n1 > n2
          _                  -> staticError
    in  gth
  GE _ ->
    let ge :: Value -> Value -> IM Value
        ge v1 v2 = case (v1, v2) of
          (IntV n1, IntV n2) -> return $ BoolV $ n1 >= n2
          _                  -> staticError
    in  ge
  EQU _ ->
    let equ :: Value -> Value -> IM Value
        equ v1 v2 = case (v1, v2) of
          (IntV  n1, IntV n2 ) -> return $ BoolV $ n1 == n2
          (BoolV b1, BoolV b2) -> return $ BoolV $ b1 == b2
          (StrV  s1, StrV s2 ) -> return $ BoolV $ s1 == s2
          _                    -> return $ BoolV False
    in  equ
  NE _ ->
    let ne :: Value -> Value -> IM Value
        ne v1 v2 = case (v1, v2) of
          (IntV  n1, IntV n2 ) -> return $ BoolV $ n1 /= n2
          (BoolV b1, BoolV b2) -> return $ BoolV $ b1 /= b2
          (StrV  s1, StrV s2 ) -> return $ BoolV $ s1 /= s2
          _                    -> return $ BoolV True
    in  ne

