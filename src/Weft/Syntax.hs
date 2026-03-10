{-# LANGUAGE OverloadedStrings #-}

module Weft.Syntax
  ( Decl (..)
  , Expr (..)
  , Module (..)
  , ModuleName (..)
  , Type (..)
  , renderType
  ) where

import Data.Text (Text)
import qualified Data.Text as T

newtype ModuleName = ModuleName
  { unModuleName :: Text
  }
  deriving (Eq, Ord, Show)

data Module = Module
  { moduleName :: ModuleName
  , moduleDecls :: [Decl]
  }
  deriving (Eq, Show)

data Decl = Decl
  { declName :: Text
  , declAnnotation :: Maybe Type
  , declParams :: [Text]
  , declBody :: Expr
  }
  deriving (Eq, Show)

data Type
  = TInt
  | TStr
  | TBool
  | TFunction [Type] Type
  deriving (Eq, Ord, Show)

data Expr
  = EVar Text
  | EInt Integer
  | EString Text
  | EBool Bool
  | ECall Expr [Expr]
  deriving (Eq, Show)

renderType :: Type -> Text
renderType typ =
  case typ of
    TInt ->
      "Int"
    TStr ->
      "Str"
    TBool ->
      "Bool"
    TFunction args result ->
      T.intercalate " -> " (fmap renderAtomicType (args <> [result]))

renderAtomicType :: Type -> Text
renderAtomicType typ =
  case typ of
    TFunction _ _ ->
      "(" <> renderType typ <> ")"
    _ ->
      renderType typ
