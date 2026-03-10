{-# LANGUAGE OverloadedStrings #-}

module Clasp.Core
  ( CoreDecl (..)
  , CoreExpr (..)
  , CoreMatchBranch (..)
  , CoreModule (..)
  , CoreParam (..)
  , CorePattern (..)
  , CorePatternBinder (..)
  , CoreRecordField (..)
  , coreExprType
  ) where

import Data.Text (Text)
import Clasp.Syntax
  ( ForeignDecl
  , ModuleName
  , RecordDecl
  , RouteDecl
  , SourceSpan
  , Type (..)
  , TypeDecl
  )

data CoreModule = CoreModule
  { coreModuleName :: ModuleName
  , coreModuleTypeDecls :: [TypeDecl]
  , coreModuleRecordDecls :: [RecordDecl]
  , coreModuleForeignDecls :: [ForeignDecl]
  , coreModuleRouteDecls :: [RouteDecl]
  , coreModuleDecls :: [CoreDecl]
  }
  deriving (Eq, Show)

data CoreDecl = CoreDecl
  { coreDeclName :: Text
  , coreDeclType :: Type
  , coreDeclParams :: [CoreParam]
  , coreDeclBody :: CoreExpr
  }
  deriving (Eq, Show)

data CoreParam = CoreParam
  { coreParamName :: Text
  , coreParamType :: Type
  }
  deriving (Eq, Show)

data CorePatternBinder = CorePatternBinder
  { corePatternBinderName :: Text
  , corePatternBinderSpan :: SourceSpan
  , corePatternBinderType :: Type
  }
  deriving (Eq, Show)

data CorePattern = CConstructorPattern SourceSpan Text [CorePatternBinder]
  deriving (Eq, Show)

data CoreMatchBranch = CoreMatchBranch
  { coreMatchBranchSpan :: SourceSpan
  , coreMatchBranchPattern :: CorePattern
  , coreMatchBranchBody :: CoreExpr
  }
  deriving (Eq, Show)

data CoreRecordField = CoreRecordField
  { coreRecordFieldName :: Text
  , coreRecordFieldValue :: CoreExpr
  }
  deriving (Eq, Show)

data CoreExpr
  = CVar SourceSpan Type Text
  | CInt SourceSpan Integer
  | CString SourceSpan Text
  | CBool SourceSpan Bool
  | CCall SourceSpan Type CoreExpr [CoreExpr]
  | CMatch SourceSpan Type CoreExpr [CoreMatchBranch]
  | CRecord SourceSpan Type Text [CoreRecordField]
  | CFieldAccess SourceSpan Type CoreExpr Text
  | CDecodeJson SourceSpan Type CoreExpr
  | CEncodeJson SourceSpan CoreExpr
  deriving (Eq, Show)

coreExprType :: CoreExpr -> Type
coreExprType expr =
  case expr of
    CVar _ typ _ ->
      typ
    CInt _ _ ->
      TInt
    CString _ _ ->
      TStr
    CBool _ _ ->
      TBool
    CCall _ typ _ _ ->
      typ
    CMatch _ typ _ _ ->
      typ
    CRecord _ typ _ _ ->
      typ
    CFieldAccess _ typ _ _ ->
      typ
    CDecodeJson _ typ _ ->
      typ
    CEncodeJson _ _ ->
      TStr
