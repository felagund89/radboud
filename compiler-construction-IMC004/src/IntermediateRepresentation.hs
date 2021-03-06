module IntermediateRepresentation where

import Control.Monad.Trans.State
import qualified Data.Map as Map
import Data.Map (Map)
import Control.Monad (liftM, when)

import Ast

type Asm = [String] -- assembly program

data IrExpression
  = IrBinOp IrBinOp IrExpression IrExpression
  | IrConst Int
  | IrTemp IrTemp
  | IrMem IrExpression
  | IrCall IrExpression [IrExpression]
  | IrName String
  | IrRecord [(Int, IrExpression)]
  deriving (Show, Eq)

data IrBinOp
  = OpAdd | OpSub | OpMul | OpDiv | OpMod
  | OpEq | OpNeq | OpLt | OpLte | OpGt | OpGte
  | OpAnd | OpOr | OpXor
  deriving (Show, Eq)

data IrTemp
  = IrStackPointer
  | IrFramePointer
  | IrGlobalFramePointer
  deriving (Show, Eq)

data IrStatement
  = IrMove IrExpression IrExpression
  | IrSeq IrStatement IrStatement
  | IrLabel String
  | IrJump String
  | IrAsm Asm
  | IrExp IrExpression
  | IrCNjump IrExpression String IrStatement String -- if (not condition) goto elseLabel body endLabel
  | IrSkip
  deriving (Show, Eq)

data Machine = Machine
  { machineTrue  :: Int -- encoding of the truth value True
  , machineFalse :: Int -- encoding of the truth value False
  , machineWord  :: Int -- number of bytes in a machine word
  , machineEnv :: Map String IrExpression
  , machineFrameSize :: Int -- size of current frame; i.e. the number of local variables
  , machineMakePrologue :: IR IrStatement
  , machineMakeEpilogue :: IR IrStatement
  , machineMakeGlobalInitCode :: [IrStatement] -> IR [IrStatement]
  , machineCurFunctionName :: String
  , machineCurFunctionArgCount :: Int
  , machineCurFunArgIndex :: Int
  , machineAccessFunArg :: IR IrExpression
  , machineLabelNumber :: Int
  , machineRecordLabelNumber :: Int
  , machineRecordFields :: Map String Int
  }

mkMachine :: Int -> Int -> Int -> (IR IrStatement) -> (IR IrStatement) -> (IR IrExpression) -> ([IrStatement] -> IR [IrStatement]) -> Machine
mkMachine tru fals word mkPrologue mkEpilogue accessFunArg mkInitCode = Machine
  { machineTrue = tru
  , machineFalse = fals
  , machineWord = word
  , machineEnv = Map.empty
  , machineFrameSize = 0
  , machineMakePrologue = mkPrologue
  , machineMakeEpilogue = mkEpilogue
  , machineMakeGlobalInitCode = mkInitCode
  , machineCurFunctionName = ""
  , machineCurFunctionArgCount = 0
  , machineCurFunArgIndex = 0
  , machineAccessFunArg = accessFunArg
  , machineLabelNumber = 0
  , machineRecordLabelNumber = 1 -- 0 is reserved for end-of-record sentinel
  , machineRecordFields = Map.empty
  }

type IR a = State Machine a

curFrameSize :: IR Int
curFrameSize = gets machineFrameSize

-- increase Frame Size by one machine word
bumpFrameSize :: IR ()
bumpFrameSize = modify $ \m -> m { machineFrameSize = 1 + machineFrameSize m }

-- lookup label name, and if not found, create fresh one
recordLabel :: String -> IR Int
recordLabel label = do
  fields <- gets machineRecordFields
  nextRecordLabel <- gets machineRecordLabelNumber
  when (nextRecordLabel == maxBound) $ error "IR: maximal number of different record labels exceeded"
  case Map.lookup label fields of
    Just n -> return n
    Nothing -> do
      modify $ \m ->
        m { machineRecordLabelNumber = machineRecordLabelNumber m + 1
          , machineRecordFields = Map.insert label nextRecordLabel (machineRecordFields m)
          }
      return nextRecordLabel

envAddFunArg :: AstFunctionArgument -> IR ()
envAddFunArg (AstFunctionArgument _ _ name) = do
  lookupCode <- gets machineAccessFunArg >>= id
  modify $ \m -> m { machineEnv = Map.insert name lookupCode (machineEnv m) }

envAdd :: String -> IrExpression -> IR ()
envAdd name lookupCode = modify $ \m -> m { machineEnv = Map.insert name lookupCode (machineEnv m) }

envLookup :: String -> IR IrExpression
envLookup name = do
  env <- gets machineEnv
  case Map.lookup name env of
    Nothing -> error ("IR: unknown identifier " ++ name) -- should never happen
    Just e  -> return e

freshLabel :: IR String
freshLabel = do
  name <- gets machineCurFunctionName
  i <- gets machineLabelNumber
  modify $ \m -> m { machineLabelNumber = i + 1 }
  return $ name ++ "_l" ++ show i

addLocalVariable :: String -> IR ()
addLocalVariable name = do
  bumpFrameSize
  s <- curFrameSize
  envAdd name (IrMem $ (IrBinOp OpAdd (IrTemp IrFramePointer) (IrConst s)))

addGlobalVariable :: String -> IR ()
addGlobalVariable name = do
  bumpFrameSize
  s <- curFrameSize
  envAdd name (IrMem $ (IrBinOp OpAdd (IrTemp IrGlobalFramePointer) (IrConst s)))

varDecl2ir :: AstDeclaration -> IR IrStatement
varDecl2ir (AstVarDeclaration _ _ name expr) = do
  e <- exp2ir expr
  dst <- envLookup name
  return $ IrMove dst e

sequenceIr :: [IrStatement] -> IrStatement
sequenceIr [] = IrSkip
sequenceIr (s:ss) = IrSeq s (sequenceIr ss)

funDecl2ir :: AstDeclaration -> IR IrStatement
funDecl2ir (AstFunDeclaration _ _ name formalArgs localVars body) = do
  oldEnv <- gets machineEnv
  modify $ \m -> m { machineCurFunArgIndex = 0 }
  modify $ \m -> m { machineCurFunctionName = name }
  modify $ \m -> m { machineCurFunctionArgCount = length formalArgs }
  modify $ \m -> m { machineFrameSize = 0 }
  mapM_ envAddFunArg formalArgs
  mapM_ (\(AstVarDeclaration _ _ varName _) -> addLocalVariable varName) localVars
  varInits <- liftM sequenceIr $ mapM varDecl2ir localVars
  prologue <- gets machineMakePrologue >>= id
  b <- stmts2ir body
  epilogue <- gets machineMakeEpilogue >>= id
  modify $ \m -> m { machineEnv = oldEnv }
  return $ IrSeq (IrSeq prologue (IrSeq varInits b)) (IrSeq (IrLabel $ name ++ "_return") epilogue)

stmt2ir :: AstStatement -> IR IrStatement
stmt2ir (AstReturn _ Nothing) = do
  name <- gets machineCurFunctionName
  return $ IrJump $ name ++ "_return"
stmt2ir (AstReturn _ (Just e)) = do
  name <- gets machineCurFunctionName
  expr <- exp2ir e
  nArgs <- gets machineCurFunctionArgCount
  return $ IrSeq
    (IrMove (IrMem $ IrBinOp OpAdd (IrTemp IrFramePointer) (IrConst $ -(nArgs + 2) {- return address, frame pointer -})) expr)
    (IrJump $ name ++ "_return")
stmt2ir (AstFunctionCallStmt f) = funCall2ir f >>= return . IrExp
stmt2ir (AstAsm asm) = return $ IrAsm asm
stmt2ir (AstIfThenElse _ astCondition astThen astElse) = do
  elseLabel <- freshLabel
  endLabel <- freshLabel
  cond <- exp2ir astCondition
  thenStmt <- stmt2ir astThen
  elseStmt <- stmt2ir astElse
  return $ IrCNjump
    cond
    elseLabel
    (IrSeq (IrSeq thenStmt (IrJump endLabel))
           (IrSeq (IrLabel elseLabel) elseStmt)
    )
    endLabel
stmt2ir (AstAssignment _ name value) = do
  src <- exp2ir value
  dst <- envLookup name
  return $ IrMove dst src
stmt2ir (AstWhile _ condition body) = do
  c <- exp2ir condition
  b <- stmt2ir body
  startLabel <- freshLabel
  endLabel <- freshLabel
  return $ IrSeq (IrLabel startLabel) (IrCNjump c endLabel (IrSeq b (IrJump startLabel)) endLabel)
stmt2ir (AstBlock stmts) = stmts2ir stmts

funCall2ir :: AstFunctionCall -> IR IrExpression
funCall2ir (AstFunctionCall _ name actualArgs) = do
  args <- mapM exp2ir actualArgs
  addr <- envLookup name
  return $ IrCall addr args

stmts2ir :: [AstStatement] -> IR IrStatement
stmts2ir [] = error "empty statement list"
stmts2ir (s:[]) = stmt2ir s
stmts2ir (s:ss) = do
  s_ <- stmt2ir s
  ss_ <- stmts2ir ss
  return $ IrSeq s_ ss_

-- the types of the arguments and the return type don't matter.  The number of arguments is crucial though.
-- TODO: move to backend specific part
builtins :: [AstDeclaration]
builtins =
  [ AstFunDeclaration emptyMeta (BaseType emptyMeta "Void") "print"
      [ AstFunctionArgument emptyMeta (PolymorphicType emptyMeta "a") "x" ]
      []
      [ AstAsm ["ldl -2", "trap 0"] ]
  , cons "__mktuple__"
  , car "fst"
  , cdr "snd"
  , cons "__mklist__"
  , car "head"
  , cdr "tail"
  , AstFunDeclaration emptyMeta (BaseType emptyMeta "Bool") "isEmpty"
      [ AstFunctionArgument emptyMeta (PolymorphicType emptyMeta "a") "x" ]
      []
      [ AstAsm
        [ "ldl -2"
        , "ldc 0"
        , "eq ; the empty list is just the null pointer"
        , "stl -3"
        ]
      ]
  , AstFunDeclaration emptyMeta (BaseType emptyMeta "Void") "__lookupRecord__"
      [ AstFunctionArgument emptyMeta (PolymorphicType emptyMeta "a") "record"
      , AstFunctionArgument emptyMeta (PolymorphicType emptyMeta "b") "fieldName"
      ]
      [] -- no locals
      [ AstAsm
        [ "__lookupRecord__loop:"

        , "ldl -3 ; safety check: is current field name the sentinel 0?"
        , "ldh 0"
        , "ldc 0"
        , "eq"
        , "brf __lookupRecord__ok_continue"
        , "halt ; we have reached the end of the record. for well typed programs, this should never happen"

        , "__lookupRecord__ok_continue:"
        , "ldl -3 ; record pointer, first argument"
        , "ldh 0  ; load field name of current field"
        , "ldl -2 ; requested field name, is second argument"
        , "eq"
        , "brf __lookupRecord__try_next_field"
        , "ldl -3 ; else we're successful. return current value"
        , "ldh -1"
        , "stl -4 ; store to return value"
        , "bra __lookupRecord___return"
        , "__lookupRecord__try_next_field:"
        , "ldl -3"
        , "ldc 2"
        , "sub"
        , "stl -3 ; decrement pointer to record by two"
        , "bra __lookupRecord__loop"
        ]
      ]
  ]
  where
    cons name =
      AstFunDeclaration emptyMeta (BaseType emptyMeta "(a, b)") name
        [ AstFunctionArgument emptyMeta (PolymorphicType emptyMeta "a") "a"
        , AstFunctionArgument emptyMeta (PolymorphicType emptyMeta "b") "b"
        ]
        []
        [ AstAsm
          [ "ldl -3 ; load first argument"
          , "ldl -2 ; load second argument"
          , "stmh 2 ; store both on the heap, and obtain pointer to second value"
          , "stl -4 ; pop tuple pointer to return value"
          ]
        ]

    car name =
      AstFunDeclaration emptyMeta (BaseType emptyMeta "a") name
        [ AstFunctionArgument emptyMeta (TupleType emptyMeta (PolymorphicType emptyMeta "a") (PolymorphicType emptyMeta "b")) "t"
        ]
        []
        [ AstAsm
          [ "ldl -2 ; load first argument"
          , "ldh -1 ; tuple pointer points to second value, but we want the first"
          , "stl -3 ; return value"
          ]
        ]

    cdr name =
      AstFunDeclaration emptyMeta (BaseType emptyMeta "b") name
        [ AstFunctionArgument emptyMeta (TupleType emptyMeta (PolymorphicType emptyMeta "a") (PolymorphicType emptyMeta "b")) "t"
        ]
        []
        [ AstAsm
          [ "ldl -2 ; load first argument"
          , "ldh 0  ; tuple pointer points to second value"
          , "stl -3 ; return value"
          ]
        ]

program2ir :: AstProgram -> IR [IrStatement]
program2ir (AstProgram decls) =
  decls2ir $ concat decls ++ builtins

decls2ir :: [AstDeclaration] -> IR [IrStatement]
decls2ir decls = do
  mapM_ (\(AstFunDeclaration _ _ name _ _ _) -> envAdd name (IrName name)) funDecls
  mapM_ (\(AstVarDeclaration _ _ name _) -> addGlobalVariable name) varDecls
  vars <- mapM varDecl2ir varDecls
  initCode <- gets machineMakeGlobalInitCode >>= \f -> f vars
  funs <- mapM funDecl2ir funDecls
  return $ initCode ++ funs
  where
    funDecls = filter isFunDecl decls
    varDecls = filter (not . isFunDecl) decls
    isFunDecl (AstFunDeclaration _ _ _ _ _ _) = True
    isFunDecl _ = False

exp2ir :: AstExpr -> IR IrExpression
exp2ir (AstInteger _ i) = return $ IrConst $ fromInteger i
exp2ir (AstBoolean _ b) = do
  m <- get
  return $ IrConst $ if b then machineTrue m else machineFalse m
exp2ir (AstBinOp _ ":" lhs rhs) = do
  hd <- exp2ir lhs
  tl <- exp2ir rhs
  return $ IrCall (IrName "__mklist__") [hd, tl]
exp2ir (AstBinOp _ "." lhs (AstIdentifier _ label)) = do
  record <- exp2ir lhs
  labelNr <- recordLabel label
  return $ IrCall (IrName "__lookupRecord__") [record, IrConst labelNr]
exp2ir (AstBinOp _ op lhs rhs) = do
  l <- exp2ir lhs
  r <- exp2ir rhs
  return $ IrBinOp (op2ir op) l r
exp2ir (AstIdentifier _ name) = envLookup name
exp2ir (AstFunctionCallExpr f) = funCall2ir f
exp2ir (AstUnaryOp _ "-" operand) = do
  e <- exp2ir operand
  return $ IrBinOp OpSub (IrConst 0) e
exp2ir (AstUnaryOp _ "!" operand) = do
  e <- exp2ir operand
  return $ IrBinOp OpXor (IrConst (-1)) e -- TODO: need a platform-independent way to specify the machine word of all ones
exp2ir (AstUnaryOp _ _ _) = error "undefined unary operator"
exp2ir (AstTuple _ astA astB) = do
  a <- exp2ir astA
  b <- exp2ir astB
  return $ IrCall (IrName "__mktuple__") [a, b]
exp2ir (AstEmptyList _) = return $ IrConst 0 -- the empty list is just the null pointer
exp2ir (AstRecord _ fields) = do
  fields_ <- mapM field2ir fields
  return $ IrRecord fields_
  where
    field2ir (AstRecordField _ label expr) = do
      labelNr <- recordLabel label
      exprIr <- exp2ir expr
      return (labelNr, exprIr)


op2ir :: String -> IrBinOp
op2ir "+" = OpAdd
op2ir "-" = OpSub
op2ir "*" = OpMul
op2ir "/" = OpDiv
op2ir "%" = OpMod

op2ir "==" = OpEq
op2ir "!=" = OpNeq
op2ir "<" = OpLt
op2ir "<=" = OpLte
op2ir ">" = OpGt
op2ir ">=" = OpGte

op2ir "&&" = OpAnd
op2ir "||" = OpOr

op2ir _ = error "undefined binary operator"
