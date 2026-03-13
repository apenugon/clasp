{-# LANGUAGE OverloadedStrings #-}

module Clasp.Native
  ( NativeAbi (..)
  , NativeBuiltinLayout (..)
  , NativeCompareOp (..)
  , NativeConstructorLayout (..)
  , NativeDecl (..)
  , NativeFieldLayout (..)
  , NativeExpr (..)
  , NativeField (..)
  , NativeFunction (..)
  , NativeGlobal (..)
  , NativeIntrinsic (..)
  , NativeLayoutStorage (..)
  , NativeLiteral (..)
  , NativeMatchBranch (..)
  , NativeModule (..)
  , NativeMutability (..)
  , NativeRecordLayout (..)
  , NativeSlotLayout (..)
  , NativeVariantLayout (..)
  , buildNativeModule
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Clasp.Lower
  ( LowerDecl (..)
  , LowerExpr (..)
  , LowerMatchBranch (..)
  , LowerModule (..)
  , LowerRecordField (..)
  , LowerRouteContract
  )
import Clasp.Syntax
  ( ConstructorDecl (..)
  , ModuleName
  , RecordDecl (..)
  , RecordFieldDecl (..)
  , Type (..)
  , TypeDecl (..)
  )

data NativeModule = NativeModule
  { nativeModuleName :: ModuleName
  , nativeModuleExports :: [Text]
  , nativeModuleAbi :: NativeAbi
  , nativeModuleDecls :: [NativeDecl]
  }
  deriving (Eq, Show)

data NativeAbi = NativeAbi
  { nativeAbiVersion :: Text
  , nativeAbiWordBytes :: Int
  , nativeAbiBuiltinLayouts :: [NativeBuiltinLayout]
  , nativeAbiRecordLayouts :: [NativeRecordLayout]
  , nativeAbiVariantLayouts :: [NativeVariantLayout]
  }
  deriving (Eq, Show)

data NativeLayoutStorage
  = NativeImmediateStorage
  | NativeHandleStorage
  deriving (Eq, Show)

data NativeBuiltinLayout = NativeBuiltinLayout
  { nativeBuiltinLayoutName :: Text
  , nativeBuiltinLayoutStorage :: NativeLayoutStorage
  , nativeBuiltinLayoutWordCount :: Int
  }
  deriving (Eq, Show)

data NativeSlotLayout = NativeSlotLayout
  { nativeSlotLayoutName :: Text
  , nativeSlotLayoutType :: Type
  , nativeSlotLayoutStorage :: NativeLayoutStorage
  , nativeSlotLayoutWordOffset :: Int
  , nativeSlotLayoutWordCount :: Int
  }
  deriving (Eq, Show)

data NativeFieldLayout = NativeFieldLayout
  { nativeFieldLayoutName :: Text
  , nativeFieldLayoutType :: Type
  , nativeFieldLayoutStorage :: NativeLayoutStorage
  , nativeFieldLayoutWordOffset :: Int
  , nativeFieldLayoutWordCount :: Int
  }
  deriving (Eq, Show)

data NativeRecordLayout = NativeRecordLayout
  { nativeRecordLayoutName :: Text
  , nativeRecordLayoutWordCount :: Int
  , nativeRecordLayoutFields :: [NativeFieldLayout]
  }
  deriving (Eq, Show)

data NativeConstructorLayout = NativeConstructorLayout
  { nativeConstructorLayoutName :: Text
  , nativeConstructorLayoutTagWord :: Int
  , nativeConstructorLayoutPayloadWords :: Int
  , nativeConstructorLayoutWordCount :: Int
  , nativeConstructorLayoutPayloads :: [NativeSlotLayout]
  }
  deriving (Eq, Show)

data NativeVariantLayout = NativeVariantLayout
  { nativeVariantLayoutName :: Text
  , nativeVariantLayoutTagWord :: Int
  , nativeVariantLayoutMaxPayloadWords :: Int
  , nativeVariantLayoutWordCount :: Int
  , nativeVariantLayoutConstructors :: [NativeConstructorLayout]
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
    , nativeModuleAbi = buildNativeAbi modl
    , nativeModuleDecls = fmap lowerDeclToNative (lowerModuleDecls modl)
    }

buildNativeAbi :: LowerModule -> NativeAbi
buildNativeAbi modl =
  NativeAbi
    { nativeAbiVersion = "clasp-native-v1"
    , nativeAbiWordBytes = 8
    , nativeAbiBuiltinLayouts = builtinLayouts
    , nativeAbiRecordLayouts = fmap (buildRecordLayout recordEnv typeEnv) recordDecls
    , nativeAbiVariantLayouts = fmap (buildVariantLayout recordEnv typeEnv) typeDecls
    }
  where
    typeDecls = lowerModuleTypeDecls modl
    recordDecls = lowerModuleRecordDecls modl
    typeEnv = Map.fromList [(typeDeclName typeDecl, typeDecl) | typeDecl <- typeDecls]
    recordEnv = Map.fromList [(recordDeclName recordDecl, recordDecl) | recordDecl <- recordDecls]
    builtinLayouts =
      [ NativeBuiltinLayout "Int" NativeImmediateStorage 1
      , NativeBuiltinLayout "Bool" NativeImmediateStorage 1
      , NativeBuiltinLayout "Str" NativeHandleStorage 1
      , NativeBuiltinLayout "List" NativeHandleStorage 1
      , NativeBuiltinLayout "Page" NativeHandleStorage 1
      , NativeBuiltinLayout "Redirect" NativeHandleStorage 1
      , NativeBuiltinLayout "View" NativeHandleStorage 1
      , NativeBuiltinLayout "Prompt" NativeHandleStorage 1
      ]

buildRecordLayout :: Map.Map Text RecordDecl -> Map.Map Text TypeDecl -> RecordDecl -> NativeRecordLayout
buildRecordLayout recordEnv typeEnv recordDecl =
  NativeRecordLayout
    { nativeRecordLayoutName = recordDeclName recordDecl
    , nativeRecordLayoutWordCount = length fieldLayouts
    , nativeRecordLayoutFields = fieldLayouts
    }
  where
    fieldLayouts =
      zipWith (buildFieldLayout recordEnv typeEnv) [0 ..] (recordDeclFields recordDecl)

buildFieldLayout :: Map.Map Text RecordDecl -> Map.Map Text TypeDecl -> Int -> RecordFieldDecl -> NativeFieldLayout
buildFieldLayout recordEnv typeEnv wordOffset fieldDecl =
  NativeFieldLayout
    { nativeFieldLayoutName = recordFieldDeclName fieldDecl
    , nativeFieldLayoutType = fieldType
    , nativeFieldLayoutStorage = layoutStorageForType recordEnv typeEnv fieldType
    , nativeFieldLayoutWordOffset = wordOffset
    , nativeFieldLayoutWordCount = 1
    }
  where
    fieldType = recordFieldDeclType fieldDecl

buildVariantLayout :: Map.Map Text RecordDecl -> Map.Map Text TypeDecl -> TypeDecl -> NativeVariantLayout
buildVariantLayout recordEnv typeEnv typeDecl =
  NativeVariantLayout
    { nativeVariantLayoutName = typeDeclName typeDecl
    , nativeVariantLayoutTagWord = 0
    , nativeVariantLayoutMaxPayloadWords = maximum (0 : fmap nativeConstructorLayoutPayloadWords constructorLayouts)
    , nativeVariantLayoutWordCount = maximum (1 : fmap nativeConstructorLayoutWordCount constructorLayouts)
    , nativeVariantLayoutConstructors = constructorLayouts
    }
  where
    constructorLayouts =
      fmap (buildConstructorLayout recordEnv typeEnv) (typeDeclConstructors typeDecl)

buildConstructorLayout :: Map.Map Text RecordDecl -> Map.Map Text TypeDecl -> ConstructorDecl -> NativeConstructorLayout
buildConstructorLayout recordEnv typeEnv constructorDecl =
  NativeConstructorLayout
    { nativeConstructorLayoutName = constructorDeclName constructorDecl
    , nativeConstructorLayoutTagWord = 0
    , nativeConstructorLayoutPayloadWords = length payloadLayouts
    , nativeConstructorLayoutWordCount = 1 + length payloadLayouts
    , nativeConstructorLayoutPayloads = payloadLayouts
    }
  where
    payloadLayouts =
      zipWith (buildPayloadLayout recordEnv typeEnv) [1 ..] (constructorDeclFields constructorDecl)

buildPayloadLayout :: Map.Map Text RecordDecl -> Map.Map Text TypeDecl -> Int -> Type -> NativeSlotLayout
buildPayloadLayout recordEnv typeEnv wordOffset slotType =
  NativeSlotLayout
    { nativeSlotLayoutName = "$" <> nativeIndexName (wordOffset - 1)
    , nativeSlotLayoutType = slotType
    , nativeSlotLayoutStorage = layoutStorageForType recordEnv typeEnv slotType
    , nativeSlotLayoutWordOffset = wordOffset
    , nativeSlotLayoutWordCount = 1
    }

nativeIndexName :: Int -> Text
nativeIndexName index =
  T.pack (show index)

layoutStorageForType :: Map.Map Text RecordDecl -> Map.Map Text TypeDecl -> Type -> NativeLayoutStorage
layoutStorageForType recordEnv typeEnv typ =
  case typ of
    TInt ->
      NativeImmediateStorage
    TBool ->
      NativeImmediateStorage
    TStr ->
      NativeHandleStorage
    TList _ ->
      NativeHandleStorage
    TNamed name
      | name `elem` ["Page", "Redirect", "View", "Prompt"] ->
          NativeHandleStorage
      | Map.member name recordEnv ->
          NativeHandleStorage
      | otherwise ->
          case Map.lookup name typeEnv of
            Just typeDecl
              | all (null . constructorDeclFields) (typeDeclConstructors typeDecl) ->
                  NativeImmediateStorage
            Just _ ->
              NativeHandleStorage
            Nothing ->
              NativeHandleStorage
    TFunction _ _ ->
      NativeHandleStorage

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
