{-# LANGUAGE OverloadedStrings #-}

module Weft.Lower
  ( LowerDecl (..)
  , LowerExpr (..)
  , LowerMatchBranch (..)
  , LowerModule (..)
  , LowerRecordField (..)
  , lowerModule
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Weft.Core
  ( CoreDecl (..)
  , CoreExpr (..)
  , CoreMatchBranch (..)
  , CoreModule (..)
  , CoreParam (..)
  , CorePattern (..)
  , CorePatternBinder (..)
  , CoreRecordField (..)
  )
import Weft.Syntax
  ( ConstructorDecl (..)
  , ModuleName
  , TypeDecl (..)
  )

data LowerModule = LowerModule
  { lowerModuleName :: ModuleName
  , lowerModuleDecls :: [LowerDecl]
  }
  deriving (Eq, Show)

data LowerDecl
  = LValueDecl Text LowerExpr
  | LFunctionDecl Text [Text] LowerExpr
  deriving (Eq, Show)

data LowerRecordField = LowerRecordField
  { lowerRecordFieldName :: Text
  , lowerRecordFieldValue :: LowerExpr
  }
  deriving (Eq, Show)

data LowerExpr
  = LVar Text
  | LInt Integer
  | LString Text
  | LBool Bool
  | LCall LowerExpr [LowerExpr]
  | LConstruct Text [LowerExpr]
  | LMatch LowerExpr [LowerMatchBranch]
  | LRecord [LowerRecordField]
  | LFieldAccess LowerExpr Text
  deriving (Eq, Show)

data LowerMatchBranch = LowerMatchBranch
  { lowerMatchBranchTag :: Text
  , lowerMatchBranchBinders :: [Text]
  , lowerMatchBranchBody :: LowerExpr
  }
  deriving (Eq, Show)

lowerModule :: CoreModule -> LowerModule
lowerModule modl =
  LowerModule
    { lowerModuleName = coreModuleName modl
    , lowerModuleDecls =
        concatMap lowerTypeDeclConstructors (coreModuleTypeDecls modl)
          <> fmap lowerCoreDecl (coreModuleDecls modl)
    }

lowerTypeDeclConstructors :: TypeDecl -> [LowerDecl]
lowerTypeDeclConstructors typeDecl =
  fmap lowerConstructorDecl (typeDeclConstructors typeDecl)

lowerConstructorDecl :: ConstructorDecl -> LowerDecl
lowerConstructorDecl constructorDecl =
  case constructorDeclFields constructorDecl of
    [] ->
      LValueDecl
        (constructorDeclName constructorDecl)
        (LConstruct (constructorDeclName constructorDecl) [])
    fieldTypes ->
      let fieldNames = fmap (("$" <>) . T.pack . show) [(0 :: Int) .. (length fieldTypes - 1)]
       in LFunctionDecl
            (constructorDeclName constructorDecl)
            fieldNames
            (LConstruct (constructorDeclName constructorDecl) (fmap LVar fieldNames))

lowerCoreDecl :: CoreDecl -> LowerDecl
lowerCoreDecl decl
  | null (coreDeclParams decl) =
      LValueDecl (coreDeclName decl) (lowerCoreExpr (coreDeclBody decl))
  | otherwise =
      LFunctionDecl
        (coreDeclName decl)
        (fmap coreParamName (coreDeclParams decl))
        (lowerCoreExpr (coreDeclBody decl))

lowerCoreExpr :: CoreExpr -> LowerExpr
lowerCoreExpr expr =
  case expr of
    CVar _ _ name ->
      LVar name
    CInt _ value ->
      LInt value
    CString _ value ->
      LString value
    CBool _ value ->
      LBool value
    CCall _ _ fn args ->
      LCall (lowerCoreExpr fn) (fmap lowerCoreExpr args)
    CMatch _ _ subject branches ->
      LMatch (lowerCoreExpr subject) (fmap lowerMatchBranch branches)
    CRecord _ _ _ fields ->
      LRecord (fmap lowerRecordField fields)
    CFieldAccess _ _ subject fieldName ->
      LFieldAccess (lowerCoreExpr subject) fieldName

lowerRecordField :: CoreRecordField -> LowerRecordField
lowerRecordField field =
  LowerRecordField
    { lowerRecordFieldName = coreRecordFieldName field
    , lowerRecordFieldValue = lowerCoreExpr (coreRecordFieldValue field)
    }

lowerMatchBranch :: CoreMatchBranch -> LowerMatchBranch
lowerMatchBranch branch =
  case coreMatchBranchPattern branch of
    CConstructorPattern _ constructorName binders ->
      LowerMatchBranch
        { lowerMatchBranchTag = constructorName
        , lowerMatchBranchBinders = fmap corePatternBinderName binders
        , lowerMatchBranchBody = lowerCoreExpr (coreMatchBranchBody branch)
        }
