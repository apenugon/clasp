{-# LANGUAGE OverloadedStrings #-}

module Weft.Syntax
  ( ConstructorDecl (..)
  , Decl (..)
  , Expr (..)
  , MatchBranch (..)
  , Module (..)
  , ModuleName (..)
  , PatternBinder (..)
  , Pattern (..)
  , Position (..)
  , SourceSpan (..)
  , TypeDecl (..)
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
  , moduleTypeDecls :: [TypeDecl]
  , moduleDecls :: [Decl]
  }
  deriving (Eq, Show)

data TypeDecl = TypeDecl
  { typeDeclName :: Text
  , typeDeclSpan :: SourceSpan
  , typeDeclNameSpan :: SourceSpan
  , typeDeclConstructors :: [ConstructorDecl]
  }
  deriving (Eq, Show)

data ConstructorDecl = ConstructorDecl
  { constructorDeclName :: Text
  , constructorDeclSpan :: SourceSpan
  , constructorDeclNameSpan :: SourceSpan
  , constructorDeclFields :: [Type]
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
  | TNamed Text
  | TFunction [Type] Type
  deriving (Eq, Ord, Show)

data PatternBinder = PatternBinder
  { patternBinderName :: Text
  , patternBinderSpan :: SourceSpan
  }
  deriving (Eq, Show)

data Pattern = PConstructor SourceSpan Text [PatternBinder]
  deriving (Eq, Show)

data MatchBranch = MatchBranch
  { matchBranchSpan :: SourceSpan
  , matchBranchPattern :: Pattern
  , matchBranchBody :: Expr
  }
  deriving (Eq, Show)

data Expr
  = EVar SourceSpan Text
  | EInt SourceSpan Integer
  | EString SourceSpan Text
  | EBool SourceSpan Bool
  | ECall SourceSpan Expr [Expr]
  | EMatch SourceSpan Expr [MatchBranch]
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
    EMatch span' _ _ ->
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
    TNamed name ->
      name
    TFunction args result ->
      T.intercalate " -> " (fmap renderAtomicType (args <> [result]))

renderAtomicType :: Type -> Text
renderAtomicType typ =
  case typ of
    TFunction _ _ ->
      "(" <> renderType typ <> ")"
    _ ->
      renderType typ
