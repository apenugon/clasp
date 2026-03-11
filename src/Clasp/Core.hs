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
  | CPage SourceSpan CoreExpr CoreExpr
  | CViewEmpty SourceSpan
  | CViewText SourceSpan CoreExpr
  | CViewAppend SourceSpan CoreExpr CoreExpr
  | CViewElement SourceSpan Text CoreExpr
  | CViewStyled SourceSpan Text CoreExpr
  | CViewLink SourceSpan Text CoreExpr
  | CViewForm SourceSpan Text Text CoreExpr
  | CViewInput SourceSpan Text Text CoreExpr
  | CViewSubmit SourceSpan CoreExpr
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
    CPage _ _ _ ->
      TNamed "Page"
    CViewEmpty _ ->
      TNamed "View"
    CViewText _ _ ->
      TNamed "View"
    CViewAppend _ _ _ ->
      TNamed "View"
    CViewElement _ _ _ ->
      TNamed "View"
    CViewStyled _ _ _ ->
      TNamed "View"
    CViewLink _ _ _ ->
      TNamed "View"
    CViewForm _ _ _ _ ->
      TNamed "View"
    CViewInput _ _ _ _ ->
      TNamed "View"
    CViewSubmit _ _ ->
      TNamed "View"
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
