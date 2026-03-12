{-# LANGUAGE OverloadedStrings #-}

module Clasp.Syntax
  ( ConstructorDecl (..)
  , Decl (..)
  , Expr (..)
  , ForeignDecl (..)
  , ImportDecl (..)
  , MatchBranch (..)
  , Module (..)
  , ModuleName (..)
  , PatternBinder (..)
  , Pattern (..)
  , PolicyClassificationDecl (..)
  , PolicyDecl (..)
  , Position (..)
  , ProjectionDecl (..)
  , ProjectionFieldDecl (..)
  , RecordDecl (..)
  , RecordFieldDecl (..)
  , RecordFieldExpr (..)
  , RouteBoundaryDecl (..)
  , RouteDecl (..)
  , RouteMethod (..)
  , RoutePathDecl (..)
  , RoutePathParamDecl (..)
  , SourceSpan (..)
  , TypeDecl (..)
  , Type (..)
  , exprSpan
  , mergeSourceSpans
  , renderType
  , splitModuleName
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

splitModuleName :: ModuleName -> [Text]
splitModuleName =
  T.splitOn "." . unModuleName

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

data ImportDecl = ImportDecl
  { importDeclModule :: ModuleName
  , importDeclSpan :: SourceSpan
  }
  deriving (Eq, Show)

data Module = Module
  { moduleName :: ModuleName
  , moduleImports :: [ImportDecl]
  , moduleTypeDecls :: [TypeDecl]
  , moduleRecordDecls :: [RecordDecl]
  , modulePolicyDecls :: [PolicyDecl]
  , moduleProjectionDecls :: [ProjectionDecl]
  , moduleForeignDecls :: [ForeignDecl]
  , moduleRouteDecls :: [RouteDecl]
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

data RecordDecl = RecordDecl
  { recordDeclName :: Text
  , recordDeclSpan :: SourceSpan
  , recordDeclNameSpan :: SourceSpan
  , recordDeclProjectionSource :: Maybe Text
  , recordDeclProjectionPolicy :: Maybe Text
  , recordDeclFields :: [RecordFieldDecl]
  }
  deriving (Eq, Show)

data RecordFieldDecl = RecordFieldDecl
  { recordFieldDeclName :: Text
  , recordFieldDeclSpan :: SourceSpan
  , recordFieldDeclType :: Type
  , recordFieldDeclClassification :: Text
  }
  deriving (Eq, Show)

data PolicyClassificationDecl = PolicyClassificationDecl
  { policyClassificationDeclName :: Text
  , policyClassificationDeclSpan :: SourceSpan
  }
  deriving (Eq, Show)

data PolicyDecl = PolicyDecl
  { policyDeclName :: Text
  , policyDeclSpan :: SourceSpan
  , policyDeclNameSpan :: SourceSpan
  , policyDeclAllowedClassifications :: [PolicyClassificationDecl]
  }
  deriving (Eq, Show)

data ProjectionFieldDecl = ProjectionFieldDecl
  { projectionFieldDeclName :: Text
  , projectionFieldDeclSpan :: SourceSpan
  }
  deriving (Eq, Show)

data ProjectionDecl = ProjectionDecl
  { projectionDeclName :: Text
  , projectionDeclSpan :: SourceSpan
  , projectionDeclNameSpan :: SourceSpan
  , projectionDeclSourceRecordName :: Text
  , projectionDeclSourceRecordSpan :: SourceSpan
  , projectionDeclPolicyName :: Text
  , projectionDeclPolicySpan :: SourceSpan
  , projectionDeclFields :: [ProjectionFieldDecl]
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

data ForeignDecl = ForeignDecl
  { foreignDeclName :: Text
  , foreignDeclSpan :: SourceSpan
  , foreignDeclNameSpan :: SourceSpan
  , foreignDeclAnnotationSpan :: SourceSpan
  , foreignDeclType :: Type
  , foreignDeclRuntimeName :: Text
  , foreignDeclRuntimeSpan :: SourceSpan
  }
  deriving (Eq, Show)

data Type
  = TInt
  | TStr
  | TBool
  | TList Type
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

data RouteMethod
  = RouteGet
  | RoutePost
  deriving (Eq, Ord, Show)

data RoutePathParamDecl = RoutePathParamDecl
  { routePathParamDeclName :: Text
  , routePathParamDeclType :: Text
  }
  deriving (Eq, Show)

data RoutePathDecl = RoutePathDecl
  { routePathDeclPattern :: Text
  , routePathDeclParams :: [RoutePathParamDecl]
  }
  deriving (Eq, Show)

data RouteBoundaryDecl = RouteBoundaryDecl
  { routeBoundaryDeclType :: Text
  }
  deriving (Eq, Show)

data RouteDecl = RouteDecl
  { routeDeclName :: Text
  , routeDeclSpan :: SourceSpan
  , routeDeclNameSpan :: SourceSpan
  , routeDeclIdentity :: Text
  , routeDeclMethod :: RouteMethod
  , routeDeclPath :: Text
  , routeDeclPathDecl :: RoutePathDecl
  , routeDeclPathSpan :: SourceSpan
  , routeDeclRequestType :: Text
  , routeDeclQueryDecl :: Maybe RouteBoundaryDecl
  , routeDeclFormDecl :: Maybe RouteBoundaryDecl
  , routeDeclBodyDecl :: Maybe RouteBoundaryDecl
  , routeDeclRequestTypeSpan :: SourceSpan
  , routeDeclResponseType :: Text
  , routeDeclResponseDecl :: RouteBoundaryDecl
  , routeDeclResponseTypeSpan :: SourceSpan
  , routeDeclHandlerName :: Text
  , routeDeclHandlerSpan :: SourceSpan
  }
  deriving (Eq, Show)

data RecordFieldExpr = RecordFieldExpr
  { recordFieldExprName :: Text
  , recordFieldExprSpan :: SourceSpan
  , recordFieldExprValue :: Expr
  }
  deriving (Eq, Show)

data Expr
  = EVar SourceSpan Text
  | EInt SourceSpan Integer
  | EString SourceSpan Text
  | EBool SourceSpan Bool
  | EList SourceSpan [Expr]
  | ECall SourceSpan Expr [Expr]
  | ELet SourceSpan SourceSpan Text Expr Expr
  | EMatch SourceSpan Expr [MatchBranch]
  | ERecord SourceSpan Text [RecordFieldExpr]
  | EFieldAccess SourceSpan Expr Text
  | EDecode SourceSpan Type Expr
  | EEncode SourceSpan Expr
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
    EList span' _ ->
      span'
    ECall span' _ _ ->
      span'
    ELet span' _ _ _ _ ->
      span'
    EMatch span' _ _ ->
      span'
    ERecord span' _ _ ->
      span'
    EFieldAccess span' _ _ ->
      span'
    EDecode span' _ _ ->
      span'
    EEncode span' _ ->
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
    TList itemType ->
      "[" <> renderType itemType <> "]"
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
