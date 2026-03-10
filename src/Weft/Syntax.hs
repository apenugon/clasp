{-# LANGUAGE OverloadedStrings #-}

module Weft.Syntax
  ( Decl (..)
  , Expr (..)
  , Module (..)
  , ModuleName (..)
  , Position (..)
  , SourceSpan (..)
  , Type (..)
  , exprSpan
  , mergeSourceSpans
  , renderType
  ) where

import Data.Aeson
  ( ToJSON (toJSON)
  , object
  , (.=)
  )
import Data.Text (Text)
import qualified Data.Text as T

newtype ModuleName = ModuleName
  { unModuleName :: Text
  }
  deriving (Eq, Ord, Show)

data Position = Position
  { positionLine :: Int
  , positionColumn :: Int
  }
  deriving (Eq, Ord, Show)

instance ToJSON Position where
  toJSON position =
    object
      [ "line" .= positionLine position
      , "column" .= positionColumn position
      ]

data SourceSpan = SourceSpan
  { sourceSpanFile :: Text
  , sourceSpanStart :: Position
  , sourceSpanEnd :: Position
  }
  deriving (Eq, Ord, Show)

instance ToJSON SourceSpan where
  toJSON span' =
    object
      [ "file" .= sourceSpanFile span'
      , "start" .= sourceSpanStart span'
      , "end" .= sourceSpanEnd span'
      ]

data Module = Module
  { moduleName :: ModuleName
  , moduleDecls :: [Decl]
  }
  deriving (Eq, Show)

data Decl = Decl
  { declName :: Text
  , declSpan :: SourceSpan
  , declNameSpan :: SourceSpan
  , declAnnotationSpan :: Maybe SourceSpan
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
  = EVar SourceSpan Text
  | EInt SourceSpan Integer
  | EString SourceSpan Text
  | EBool SourceSpan Bool
  | ECall SourceSpan Expr [Expr]
  deriving (Eq, Show)

exprSpan :: Expr -> SourceSpan
exprSpan expr =
  case expr of
    EVar span' _ ->
      span'
    EInt span' _ ->
      span'
    EString span' _ ->
      span'
    EBool span' _ ->
      span'
    ECall span' _ _ ->
      span'

mergeSourceSpans :: SourceSpan -> SourceSpan -> SourceSpan
mergeSourceSpans left right =
  SourceSpan
    { sourceSpanFile = sourceSpanFile left
    , sourceSpanStart = sourceSpanStart left
    , sourceSpanEnd = sourceSpanEnd right
    }

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
