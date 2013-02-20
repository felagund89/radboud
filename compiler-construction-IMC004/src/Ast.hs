
-- Data structures which form the Abstract Syntax Tree
module Ast where

import Data.List (intersperse)

data AstProgram = AstProgram [AstDeclaration]

data AstDeclaration
  = AstVarDeclaration AstType String AstExpr
  | AstFunDeclaration AstType String [AstFunctionArgument] [AstDeclaration]

data AstType = BaseType String | TupleType AstType AstType | ListType AstType | PolymorphicType String

data AstExpr
  = AstIdentifier String
  | AstInteger Integer
  | AstBoolean Bool
  | AstTuple AstExpr AstExpr
  | AstEmptyList

data AstFunctionArgument = AstFunctionArgument AstType String

instance Show AstProgram where
  show (AstProgram decls) = concat $ intersperse "\n" $ map show decls

instance Show AstDeclaration where
  show (AstFunDeclaration typ ident args vars) = concat $ intersperse " "
    [show typ, "#" ++ ident, "("]
      ++ arguments
      ++ [")", "{"]
      ++ variables
      ++ ["}"]
    where
      arguments = intersperse ", " $ map show args
      variables = intersperse " " $ map show vars
  show (AstVarDeclaration typ ident expr) = concat $ intersperse " " [show typ, "#" ++ ident, "=", show expr, ";"]

instance Show AstType where
  show (BaseType t) = t
  show (TupleType a b) = concat ["(", show a, ", ", show b, ")"]
  show (ListType t) = concat ["[", show t, "]"]
  show (PolymorphicType t) = "$" ++ t

instance Show AstExpr where
  show (AstIdentifier ident) = "#" ++ ident
  show (AstInteger i) = show i
  show (AstBoolean b) = "@" ++ show b
  show (AstTuple a b) = concat ["(", show a, ", ", show b, ")"]
  show (AstEmptyList) = "[]"

instance Show AstFunctionArgument where
  show (AstFunctionArgument typ ident) = concat $ intersperse " " [show typ, ident]
