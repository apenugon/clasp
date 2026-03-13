{-# LANGUAGE OverloadedStrings #-}

module Clasp.Native
  ( NativeCompareOp (..)
  , NativeDecl (..)
  , NativeExpr (..)
  , NativeField (..)
  , NativeFunction (..)
  , NativeGlobal (..)
  , NativeIntrinsic (..)
  , NativeLiteral (..)
  , NativeMatchBranch (..)
  , NativeModule (..)
  , NativeMutability (..)
  , buildNativeModule
  ) where

import Data.Text (Text)
import Clasp.Lower
  ( LowerDecl (..)
  , LowerExpr (..)
  , LowerMatchBranch (..)
  , LowerModule (..)
  , LowerRecordField (..)
  , LowerRouteContract
  )
import Clasp.Syntax (ModuleName)

data NativeModule = NativeModule
  { nativeModuleName :: ModuleName
  , nativeModuleExports :: [Text]
  , nativeModuleDecls :: [NativeDecl]
  }
  deriving (Eq, Show)

data NativeDecl
  = NativeGlobalDecl NativeGlobal
  | NativeFunctionDecl NativeFunction
  deriving (Eq, Show)

data NativeGlobal = NativeGlobal
  { nativeGlobalName :: Text
  , nativeGlobalBody :: NativeExpr
  }
  deriving (Eq, Show)

data NativeFunction = NativeFunction
  { nativeFunctionName :: Text
  , nativeFunctionParams :: [Text]
  , nativeFunctionBody :: NativeExpr
  }
  deriving (Eq, Show)

data NativeLiteral
  = NativeInt Integer
  | NativeString Text
  | NativeBool Bool
  deriving (Eq, Show)

data NativeCompareOp
  = NativeEqual
  | NativeNotEqual
  | NativeLessThan
  | NativeLessThanOrEqual
  | NativeGreaterThan
  | NativeGreaterThanOrEqual
  deriving (Eq, Show)

data NativeMutability
  = NativeImmutable
  | NativeMutable
  deriving (Eq, Show)

data NativeExpr
  = NativeLocal Text
  | NativeLiteralExpr NativeLiteral
  | NativeList [NativeExpr]
  | NativeReturn NativeExpr
  | NativeCompare NativeCompareOp NativeExpr NativeExpr
  | NativeLet NativeMutability Text NativeExpr NativeExpr
  | NativeAssign Text NativeExpr NativeExpr
  | NativeForEach Text NativeExpr NativeExpr NativeExpr
  | NativeIntrinsic NativeIntrinsic
  | NativeCall NativeExpr [NativeExpr]
  | NativeConstruct Text [NativeExpr]
  | NativeMatch NativeExpr [NativeMatchBranch]
  | NativeRecord [NativeField]
  | NativeFieldAccess NativeExpr Text
  deriving (Eq, Show)

data NativeIntrinsic
  = NativePageIntrinsic NativeExpr NativeExpr
  | NativeRedirectIntrinsic Text
  | NativeViewEmptyIntrinsic
  | NativeViewTextIntrinsic NativeExpr
  | NativeViewAppendIntrinsic NativeExpr NativeExpr
  | NativeViewElementIntrinsic Text NativeExpr
  | NativeViewStyledIntrinsic Text NativeExpr
  | NativeViewLinkIntrinsic LowerRouteContract Text NativeExpr
  | NativeViewFormIntrinsic LowerRouteContract Text Text NativeExpr
  | NativeViewInputIntrinsic Text Text NativeExpr
  | NativeViewSubmitIntrinsic NativeExpr
  | NativePromptMessageIntrinsic Text NativeExpr
  | NativePromptAppendIntrinsic NativeExpr NativeExpr
  | NativePromptTextIntrinsic NativeExpr
  deriving (Eq, Show)

data NativeMatchBranch = NativeMatchBranch
  { nativeMatchBranchTag :: Text
  , nativeMatchBranchBinders :: [Text]
  , nativeMatchBranchBody :: NativeExpr
  }
  deriving (Eq, Show)

data NativeField = NativeField
  { nativeFieldName :: Text
  , nativeFieldValue :: NativeExpr
  }
  deriving (Eq, Show)

buildNativeModule :: LowerModule -> NativeModule
buildNativeModule modl =
  NativeModule
    { nativeModuleName = lowerModuleName modl
    , nativeModuleExports = fmap lowerDeclName (lowerModuleDecls modl)
    , nativeModuleDecls = fmap lowerDeclToNative (lowerModuleDecls modl)
    }

lowerDeclName :: LowerDecl -> Text
lowerDeclName decl =
  case decl of
    LValueDecl name _ ->
      name
    LFunctionDecl name _ _ ->
      name

lowerDeclToNative :: LowerDecl -> NativeDecl
lowerDeclToNative decl =
  case decl of
    LValueDecl name body ->
      NativeGlobalDecl
        NativeGlobal
          { nativeGlobalName = name
          , nativeGlobalBody = lowerExprToNative body
          }
    LFunctionDecl name params body ->
      NativeFunctionDecl
        NativeFunction
          { nativeFunctionName = name
          , nativeFunctionParams = params
          , nativeFunctionBody = lowerExprToNative body
          }

lowerExprToNative :: LowerExpr -> NativeExpr
lowerExprToNative expr =
  case expr of
    LVar name ->
      NativeLocal name
    LInt value ->
      NativeLiteralExpr (NativeInt value)
    LString value ->
      NativeLiteralExpr (NativeString value)
    LBool value ->
      NativeLiteralExpr (NativeBool value)
    LList items ->
      NativeList (fmap lowerExprToNative items)
    LReturn value ->
      NativeReturn (lowerExprToNative value)
    LEqual left right ->
      NativeCompare NativeEqual (lowerExprToNative left) (lowerExprToNative right)
    LNotEqual left right ->
      NativeCompare NativeNotEqual (lowerExprToNative left) (lowerExprToNative right)
    LLessThan left right ->
      NativeCompare NativeLessThan (lowerExprToNative left) (lowerExprToNative right)
    LLessThanOrEqual left right ->
      NativeCompare NativeLessThanOrEqual (lowerExprToNative left) (lowerExprToNative right)
    LGreaterThan left right ->
      NativeCompare NativeGreaterThan (lowerExprToNative left) (lowerExprToNative right)
    LGreaterThanOrEqual left right ->
      NativeCompare NativeGreaterThanOrEqual (lowerExprToNative left) (lowerExprToNative right)
    LLet name value body ->
      NativeLet NativeImmutable name (lowerExprToNative value) (lowerExprToNative body)
    LMutableLet name value body ->
      NativeLet NativeMutable name (lowerExprToNative value) (lowerExprToNative body)
    LAssign name value body ->
      NativeAssign name (lowerExprToNative value) (lowerExprToNative body)
    LFor name iterable loopBody body ->
      NativeForEach name (lowerExprToNative iterable) (lowerExprToNative loopBody) (lowerExprToNative body)
    LPage title body ->
      NativeIntrinsic (NativePageIntrinsic (lowerExprToNative title) (lowerExprToNative body))
    LRedirect targetPath ->
      NativeIntrinsic (NativeRedirectIntrinsic targetPath)
    LViewEmpty ->
      NativeIntrinsic NativeViewEmptyIntrinsic
    LViewText value ->
      NativeIntrinsic (NativeViewTextIntrinsic (lowerExprToNative value))
    LViewAppend left right ->
      NativeIntrinsic (NativeViewAppendIntrinsic (lowerExprToNative left) (lowerExprToNative right))
    LViewElement tag child ->
      NativeIntrinsic (NativeViewElementIntrinsic tag (lowerExprToNative child))
    LViewStyled styleRef child ->
      NativeIntrinsic (NativeViewStyledIntrinsic styleRef (lowerExprToNative child))
    LViewLink routeContract href child ->
      NativeIntrinsic (NativeViewLinkIntrinsic routeContract href (lowerExprToNative child))
    LViewForm routeContract method action child ->
      NativeIntrinsic (NativeViewFormIntrinsic routeContract method action (lowerExprToNative child))
    LViewInput fieldName inputKind value ->
      NativeIntrinsic (NativeViewInputIntrinsic fieldName inputKind (lowerExprToNative value))
    LViewSubmit label ->
      NativeIntrinsic (NativeViewSubmitIntrinsic (lowerExprToNative label))
    LPromptMessage role content ->
      NativeIntrinsic (NativePromptMessageIntrinsic role (lowerExprToNative content))
    LPromptAppend left right ->
      NativeIntrinsic (NativePromptAppendIntrinsic (lowerExprToNative left) (lowerExprToNative right))
    LPromptText promptExpr ->
      NativeIntrinsic (NativePromptTextIntrinsic (lowerExprToNative promptExpr))
    LCall fn args ->
      NativeCall (lowerExprToNative fn) (fmap lowerExprToNative args)
    LConstruct tag args ->
      NativeConstruct tag (fmap lowerExprToNative args)
    LMatch subject branches ->
      NativeMatch (lowerExprToNative subject) (fmap lowerBranchToNative branches)
    LRecord fields ->
      NativeRecord (fmap lowerFieldToNative fields)
    LFieldAccess subject fieldName ->
      NativeFieldAccess (lowerExprToNative subject) fieldName

lowerBranchToNative :: LowerMatchBranch -> NativeMatchBranch
lowerBranchToNative branch =
  NativeMatchBranch
    { nativeMatchBranchTag = lowerMatchBranchTag branch
    , nativeMatchBranchBinders = lowerMatchBranchBinders branch
    , nativeMatchBranchBody = lowerExprToNative (lowerMatchBranchBody branch)
    }

lowerFieldToNative :: LowerRecordField -> NativeField
lowerFieldToNative field =
  NativeField
    { nativeFieldName = lowerRecordFieldName field
    , nativeFieldValue = lowerExprToNative (lowerRecordFieldValue field)
    }
