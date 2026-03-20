{-# LANGUAGE OverloadedStrings #-}

module Clasp.Compiler
  ( airSource
  , airEntry
  , applySemanticEdit
  , CompilerImplementation (..)
  , CompilerPreference (..)
  , contextSource
  , contextEntry
  , checkSource
  , checkEntry
  , checkEntryWithPreference
  , checkEntrySummaryWithPreference
  , compileSource
  , compileEntry
  , compileEntryWithPreference
  , explainSource
  , explainEntry
  , explainEntryWithPreference
  , formatSource
  , renderNativeSource
  , renderNativeEntry
  , renderNativeEntryWithPreference
  , renderNativeImageEntryWithPreference
  , nativeSource
  , nativeEntry
  , nativeEntryBootstrap
  , parseSource
  , renderAirEntryJson
  , renderAirEntryJsonWithPreference
  , renderAirSourceJson
  , renderContextEntryJson
  , renderContextEntryJsonWithPreference
  , renderContextSourceJson
  , renderHostedPrimaryEntrySource
  , semanticEditEntry
  , semanticEditSource
  , SemanticEdit (..)
  ) where

import Control.Exception (finally)
import Data.Aeson
  ( FromJSON (parseJSON)
  , Value (..)
  , eitherDecodeStrictText
  , withObject
  , (.:)
  )
import qualified Data.Aeson.KeyMap as KM
import Data.List (isSuffixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Read as TR
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getTemporaryDirectory, removePathForcibly)
import System.Exit (ExitCode (..))
import System.FilePath ((<.>), (</>), normalise, takeDirectory)
import System.Process (readProcessWithExitCode)
import Clasp.Air (AirModule, buildAirModule, renderAirModuleJson)
import Clasp.Checker (checkModule)
import Clasp.ContextGraph (ContextGraph, buildContextGraph, renderContextGraphJson)
import Clasp.Core
  ( CoreDecl (..)
  , CoreExpr (..)
  , CoreMatchBranch (..)
  , CoreModule (..)
  , CoreParam (..)
  , CorePattern (..)
  , CorePatternBinder (..)
  , CoreRecordField (..)
  , SemanticEdit (..)
  , applySemanticEdit
  , renderCoreModule
  )
import Clasp.Diagnostic (DiagnosticBundle, singleDiagnostic)
import Clasp.Emit.JavaScript (emitModule)
import Clasp.Loader (loadEntryModule)
import Clasp.Lower (lowerModule)
import Clasp.Native (NativeModule, buildNativeModule, renderNativeModule, renderNativeModuleImageJson)
import Clasp.Parser (parseModule)
import Clasp.Syntax
  ( ForeignDecl (..)
  , ForeignPackageImport (..)
  , Module (..)
  , Position (..)
  , SourceSpan (..)
  , Type (..)
  , renderModule
  , renderType
  )

data CompilerImplementation
  = CompilerImplementationClasp
  | CompilerImplementationBootstrap
  deriving (Eq, Show)

data CompilerPreference
  = CompilerPreferenceAuto
  | CompilerPreferenceClasp
  | CompilerPreferenceBootstrap
  deriving (Eq, Show)

data HostedToolCommand
  = HostedToolCheck
  | HostedToolCheckCore
  | HostedToolCompile
  | HostedToolExplain
  | HostedToolNative
  | HostedToolNativeImage
  deriving (Eq, Show)

data HostedCoreArtifactResult
  = HostedCoreArtifactOk [HostedCoreDeclArtifact]
  | HostedCoreArtifactError Text
  deriving (Eq, Show)

data HostedCoreDeclArtifact = HostedCoreDeclArtifact
  { hostedCoreDeclArtifactName :: Text
  , hostedCoreDeclArtifactType :: HostedCoreTypeArtifact
  , hostedCoreDeclArtifactParams :: [HostedCoreParamArtifact]
  , hostedCoreDeclArtifactBody :: HostedCoreExprArtifact
  }
  deriving (Eq, Show)

data HostedCoreParamArtifact = HostedCoreParamArtifact
  { hostedCoreParamArtifactName :: Text
  , hostedCoreParamArtifactType :: HostedCoreTypeArtifact
  }
  deriving (Eq, Show)

data HostedCoreTypeArtifact
  = HostedCoreTypeInt
  | HostedCoreTypeStr
  | HostedCoreTypeBool
  | HostedCoreTypeList HostedCoreTypeArtifact
  | HostedCoreTypeFunction HostedCoreTypeArtifact HostedCoreTypeArtifact
  | HostedCoreTypeNamed Text
  | HostedCoreTypeUnknown Text
  deriving (Eq, Show)

data HostedCorePatternBinderArtifact = HostedCorePatternBinderArtifact
  { hostedCorePatternBinderArtifactName :: Text
  , hostedCorePatternBinderArtifactType :: HostedCoreTypeArtifact
  }
  deriving (Eq, Show)

data HostedCorePatternArtifact
  = HostedCoreConstructorPatternArtifact Text [HostedCorePatternBinderArtifact]
  deriving (Eq, Show)

data HostedCoreMatchBranchArtifact = HostedCoreMatchBranchArtifact
  { hostedCoreMatchBranchArtifactPattern :: HostedCorePatternArtifact
  , hostedCoreMatchBranchArtifactBody :: HostedCoreExprArtifact
  }
  deriving (Eq, Show)

data HostedCoreRecordFieldArtifact = HostedCoreRecordFieldArtifact
  { hostedCoreRecordFieldArtifactName :: Text
  , hostedCoreRecordFieldArtifactValue :: HostedCoreExprArtifact
  }
  deriving (Eq, Show)

data HostedCoreExprArtifact
  = HostedCoreVarArtifact HostedCoreTypeArtifact Text
  | HostedCoreIntArtifact Text
  | HostedCoreStringArtifact Text
  | HostedCoreBoolArtifact Bool
  | HostedCoreListArtifact HostedCoreTypeArtifact [HostedCoreExprArtifact]
  | HostedCoreIfArtifact HostedCoreTypeArtifact HostedCoreExprArtifact HostedCoreExprArtifact HostedCoreExprArtifact
  | HostedCoreReturnArtifact HostedCoreTypeArtifact HostedCoreExprArtifact
  | HostedCoreEqualArtifact HostedCoreExprArtifact HostedCoreExprArtifact
  | HostedCoreNotEqualArtifact HostedCoreExprArtifact HostedCoreExprArtifact
  | HostedCoreLessThanArtifact HostedCoreExprArtifact HostedCoreExprArtifact
  | HostedCoreLessThanOrEqualArtifact HostedCoreExprArtifact HostedCoreExprArtifact
  | HostedCoreGreaterThanArtifact HostedCoreExprArtifact HostedCoreExprArtifact
  | HostedCoreGreaterThanOrEqualArtifact HostedCoreExprArtifact HostedCoreExprArtifact
  | HostedCoreLetArtifact HostedCoreTypeArtifact Text HostedCoreExprArtifact HostedCoreExprArtifact
  | HostedCoreMutableLetArtifact HostedCoreTypeArtifact Text HostedCoreExprArtifact HostedCoreExprArtifact
  | HostedCoreAssignArtifact HostedCoreTypeArtifact Text HostedCoreExprArtifact HostedCoreExprArtifact
  | HostedCoreForArtifact HostedCoreTypeArtifact Text HostedCoreExprArtifact HostedCoreExprArtifact HostedCoreExprArtifact
  | HostedCoreCallArtifact HostedCoreTypeArtifact Text HostedCoreTypeArtifact [HostedCoreExprArtifact]
  | HostedCoreMatchArtifact HostedCoreTypeArtifact HostedCoreExprArtifact [HostedCoreMatchBranchArtifact]
  | HostedCoreRecordArtifact HostedCoreTypeArtifact Text [HostedCoreRecordFieldArtifact]
  | HostedCoreFieldAccessArtifact HostedCoreTypeArtifact HostedCoreExprArtifact Text
  deriving (Eq, Show)

instance FromJSON HostedCoreArtifactResult where
  parseJSON =
    withObject "HostedCoreArtifactResult" $ \obj -> do
      tag <- obj .: "$tag"
      case (tag :: Text) of
        "CheckedCoreArtifactOk" ->
          HostedCoreArtifactOk <$> obj .: "$0"
        "CheckedCoreArtifactError" ->
          HostedCoreArtifactError <$> obj .: "$0"
        other ->
          fail ("unknown hosted core artifact result tag: " <> T.unpack other)

instance FromJSON HostedCoreDeclArtifact where
  parseJSON =
    withObject "HostedCoreDeclArtifact" $ \obj -> do
      tag <- obj .: "$tag"
      case (tag :: Text) of
        "CheckedCoreDeclArtifact" ->
          HostedCoreDeclArtifact <$> obj .: "$0" <*> obj .: "$1" <*> obj .: "$2" <*> obj .: "$3"
        other ->
          fail ("unknown hosted core decl tag: " <> T.unpack other)

instance FromJSON HostedCoreParamArtifact where
  parseJSON =
    withObject "HostedCoreParamArtifact" $ \obj -> do
      tag <- obj .: "$tag"
      case (tag :: Text) of
        "CheckedCoreParamArtifact" ->
          HostedCoreParamArtifact <$> obj .: "$0" <*> obj .: "$1"
        other ->
          fail ("unknown hosted core param tag: " <> T.unpack other)

instance FromJSON HostedCoreTypeArtifact where
  parseJSON =
    withObject "HostedCoreTypeArtifact" $ \obj -> do
      tag <- obj .: "$tag"
      case (tag :: Text) of
        "TInt" ->
          pure HostedCoreTypeInt
        "TStr" ->
          pure HostedCoreTypeStr
        "TBool" ->
          pure HostedCoreTypeBool
        "TList" ->
          HostedCoreTypeList <$> obj .: "$0"
        "TFunction" ->
          HostedCoreTypeFunction <$> obj .: "$0" <*> obj .: "$1"
        "TNamed" ->
          HostedCoreTypeNamed <$> obj .: "$0"
        "TUnknown" ->
          HostedCoreTypeUnknown <$> obj .: "$0"
        other ->
          fail ("unknown hosted core type tag: " <> T.unpack other)

instance FromJSON HostedCorePatternBinderArtifact where
  parseJSON =
    withObject "HostedCorePatternBinderArtifact" $ \obj -> do
      tag <- obj .: "$tag"
      case (tag :: Text) of
        "CheckedCorePatternBinderArtifact" ->
          HostedCorePatternBinderArtifact <$> obj .: "$0" <*> obj .: "$1"
        other ->
          fail ("unknown hosted core pattern binder tag: " <> T.unpack other)

instance FromJSON HostedCorePatternArtifact where
  parseJSON =
    withObject "HostedCorePatternArtifact" $ \obj -> do
      tag <- obj .: "$tag"
      case (tag :: Text) of
        "CheckedCoreConstructorPatternArtifact" ->
          HostedCoreConstructorPatternArtifact <$> obj .: "$0" <*> obj .: "$1"
        other ->
          fail ("unknown hosted core pattern tag: " <> T.unpack other)

instance FromJSON HostedCoreMatchBranchArtifact where
  parseJSON =
    withObject "HostedCoreMatchBranchArtifact" $ \obj -> do
      tag <- obj .: "$tag"
      case (tag :: Text) of
        "CheckedCoreMatchBranchArtifact" ->
          HostedCoreMatchBranchArtifact <$> obj .: "$0" <*> obj .: "$1"
        other ->
          fail ("unknown hosted core match branch tag: " <> T.unpack other)

instance FromJSON HostedCoreRecordFieldArtifact where
  parseJSON =
    withObject "HostedCoreRecordFieldArtifact" $ \obj -> do
      tag <- obj .: "$tag"
      case (tag :: Text) of
        "CheckedCoreRecordFieldArtifact" ->
          HostedCoreRecordFieldArtifact <$> obj .: "$0" <*> obj .: "$1"
        other ->
          fail ("unknown hosted core record field tag: " <> T.unpack other)

instance FromJSON HostedCoreExprArtifact where
  parseJSON =
    withObject "HostedCoreExprArtifact" $ \obj -> do
      tag <- obj .: "$tag"
      case (tag :: Text) of
        "CheckedCoreVarArtifact" ->
          HostedCoreVarArtifact <$> obj .: "$0" <*> obj .: "$1"
        "CheckedCoreIntArtifact" ->
          HostedCoreIntArtifact <$> obj .: "$0"
        "CheckedCoreStringArtifact" ->
          HostedCoreStringArtifact <$> obj .: "$0"
        "CheckedCoreBoolArtifact" ->
          HostedCoreBoolArtifact <$> obj .: "$0"
        "CheckedCoreListArtifact" ->
          HostedCoreListArtifact <$> obj .: "$0" <*> obj .: "$1"
        "CheckedCoreIfArtifact" ->
          HostedCoreIfArtifact <$> obj .: "$0" <*> obj .: "$1" <*> obj .: "$2" <*> obj .: "$3"
        "CheckedCoreReturnArtifact" ->
          HostedCoreReturnArtifact <$> obj .: "$0" <*> obj .: "$1"
        "CheckedCoreEqualArtifact" ->
          HostedCoreEqualArtifact <$> obj .: "$0" <*> obj .: "$1"
        "CheckedCoreNotEqualArtifact" ->
          HostedCoreNotEqualArtifact <$> obj .: "$0" <*> obj .: "$1"
        "CheckedCoreLessThanArtifact" ->
          HostedCoreLessThanArtifact <$> obj .: "$0" <*> obj .: "$1"
        "CheckedCoreLessThanOrEqualArtifact" ->
          HostedCoreLessThanOrEqualArtifact <$> obj .: "$0" <*> obj .: "$1"
        "CheckedCoreGreaterThanArtifact" ->
          HostedCoreGreaterThanArtifact <$> obj .: "$0" <*> obj .: "$1"
        "CheckedCoreGreaterThanOrEqualArtifact" ->
          HostedCoreGreaterThanOrEqualArtifact <$> obj .: "$0" <*> obj .: "$1"
        "CheckedCoreLetArtifact" ->
          HostedCoreLetArtifact <$> obj .: "$0" <*> obj .: "$1" <*> obj .: "$2" <*> obj .: "$3"
        "CheckedCoreMutableLetArtifact" ->
          HostedCoreMutableLetArtifact <$> obj .: "$0" <*> obj .: "$1" <*> obj .: "$2" <*> obj .: "$3"
        "CheckedCoreAssignArtifact" ->
          HostedCoreAssignArtifact <$> obj .: "$0" <*> obj .: "$1" <*> obj .: "$2" <*> obj .: "$3"
        "CheckedCoreForArtifact" ->
          HostedCoreForArtifact <$> obj .: "$0" <*> obj .: "$1" <*> obj .: "$2" <*> obj .: "$3" <*> obj .: "$4"
        "CheckedCoreCallArtifact" ->
          HostedCoreCallArtifact <$> obj .: "$0" <*> obj .: "$1" <*> obj .: "$2" <*> obj .: "$3"
        "CheckedCoreMatchArtifact" ->
          HostedCoreMatchArtifact <$> obj .: "$0" <*> obj .: "$1" <*> obj .: "$2"
        "CheckedCoreRecordArtifact" ->
          HostedCoreRecordArtifact <$> obj .: "$0" <*> obj .: "$1" <*> obj .: "$2"
        "CheckedCoreFieldAccessArtifact" ->
          HostedCoreFieldAccessArtifact <$> obj .: "$0" <*> obj .: "$1" <*> obj .: "$2"
        other ->
          fail ("unknown hosted core expr tag: " <> T.unpack other)

syntheticHostedCoreSpan :: FilePath -> SourceSpan
syntheticHostedCoreSpan entryPath =
  SourceSpan
    { sourceSpanFile = T.pack entryPath
    , sourceSpanStart = Position 1 1
    , sourceSpanEnd = Position 1 1
    }

decodeHostedCoreInteger :: Text -> Either Text Integer
decodeHostedCoreInteger value =
  case TR.signed TR.decimal value of
    Right (parsed, rest)
      | T.null rest -> Right parsed
    _ ->
      Left ("invalid hosted core integer literal: " <> value)

decodeHostedCoreType :: HostedCoreTypeArtifact -> Type
decodeHostedCoreType hostedType =
  case hostedType of
    HostedCoreTypeInt ->
      TInt
    HostedCoreTypeStr ->
      TStr
    HostedCoreTypeBool ->
      TBool
    HostedCoreTypeList itemType ->
      TList (decodeHostedCoreType itemType)
    HostedCoreTypeFunction inputType resultType ->
      let (args, finalResult) = flattenHostedCoreFunction inputType resultType
       in TFunction args finalResult
    HostedCoreTypeNamed name ->
      TNamed name
    HostedCoreTypeUnknown name ->
      TVar name

flattenHostedCoreFunction :: HostedCoreTypeArtifact -> HostedCoreTypeArtifact -> ([Type], Type)
flattenHostedCoreFunction inputType resultType =
  case resultType of
    HostedCoreTypeFunction nextInputType nextResultType ->
      let (remainingArgs, finalResult) = flattenHostedCoreFunction nextInputType nextResultType
       in (decodeHostedCoreType inputType : remainingArgs, finalResult)
    _ ->
      ([decodeHostedCoreType inputType], decodeHostedCoreType resultType)

decodeHostedCorePatternBinder ::
     FilePath
  -> HostedCorePatternBinderArtifact
  -> CorePatternBinder
decodeHostedCorePatternBinder entryPath binder =
  CorePatternBinder
    { corePatternBinderName = hostedCorePatternBinderArtifactName binder
    , corePatternBinderSpan = syntheticHostedCoreSpan entryPath
    , corePatternBinderType = decodeHostedCoreType (hostedCorePatternBinderArtifactType binder)
    }

decodeHostedCorePattern ::
     FilePath
  -> HostedCorePatternArtifact
  -> CorePattern
decodeHostedCorePattern entryPath patternArtifact =
  case patternArtifact of
    HostedCoreConstructorPatternArtifact constructorName binders ->
      CConstructorPattern
        (syntheticHostedCoreSpan entryPath)
        constructorName
        (fmap (decodeHostedCorePatternBinder entryPath) binders)

decodeHostedCoreRecordField ::
     FilePath
  -> HostedCoreRecordFieldArtifact
  -> Either Text CoreRecordField
decodeHostedCoreRecordField entryPath fieldArtifact =
  CoreRecordField
    (hostedCoreRecordFieldArtifactName fieldArtifact)
    <$> decodeHostedCoreExpr entryPath (hostedCoreRecordFieldArtifactValue fieldArtifact)

decodeHostedCoreMatchBranch ::
     FilePath
  -> HostedCoreMatchBranchArtifact
  -> Either Text CoreMatchBranch
decodeHostedCoreMatchBranch entryPath branchArtifact =
  CoreMatchBranch
    (syntheticHostedCoreSpan entryPath)
    (decodeHostedCorePattern entryPath (hostedCoreMatchBranchArtifactPattern branchArtifact))
    <$> decodeHostedCoreExpr entryPath (hostedCoreMatchBranchArtifactBody branchArtifact)

decodeHostedCoreExpr ::
     FilePath
  -> HostedCoreExprArtifact
  -> Either Text CoreExpr
decodeHostedCoreExpr entryPath exprArtifact =
  let span' = syntheticHostedCoreSpan entryPath
   in case exprArtifact of
        HostedCoreVarArtifact exprType name ->
          Right (CVar span' (decodeHostedCoreType exprType) name)
        HostedCoreIntArtifact value ->
          CInt span' <$> decodeHostedCoreInteger value
        HostedCoreStringArtifact value ->
          Right (CString span' value)
        HostedCoreBoolArtifact value ->
          Right (CBool span' value)
        HostedCoreListArtifact exprType values ->
          CList span' (decodeHostedCoreType exprType) <$> traverse (decodeHostedCoreExpr entryPath) values
        HostedCoreIfArtifact exprType condition thenBranch elseBranch ->
          CIf span' (decodeHostedCoreType exprType)
            <$> decodeHostedCoreExpr entryPath condition
            <*> decodeHostedCoreExpr entryPath thenBranch
            <*> decodeHostedCoreExpr entryPath elseBranch
        HostedCoreReturnArtifact exprType value ->
          CReturn span' (decodeHostedCoreType exprType)
            <$> decodeHostedCoreExpr entryPath value
        HostedCoreEqualArtifact left right ->
          CEqual span'
            <$> decodeHostedCoreExpr entryPath left
            <*> decodeHostedCoreExpr entryPath right
        HostedCoreNotEqualArtifact left right ->
          CNotEqual span'
            <$> decodeHostedCoreExpr entryPath left
            <*> decodeHostedCoreExpr entryPath right
        HostedCoreLessThanArtifact left right ->
          CLessThan span'
            <$> decodeHostedCoreExpr entryPath left
            <*> decodeHostedCoreExpr entryPath right
        HostedCoreLessThanOrEqualArtifact left right ->
          CLessThanOrEqual span'
            <$> decodeHostedCoreExpr entryPath left
            <*> decodeHostedCoreExpr entryPath right
        HostedCoreGreaterThanArtifact left right ->
          CGreaterThan span'
            <$> decodeHostedCoreExpr entryPath left
            <*> decodeHostedCoreExpr entryPath right
        HostedCoreGreaterThanOrEqualArtifact left right ->
          CGreaterThanOrEqual span'
            <$> decodeHostedCoreExpr entryPath left
            <*> decodeHostedCoreExpr entryPath right
        HostedCoreLetArtifact exprType binder value body ->
          CLet span' (decodeHostedCoreType exprType) binder
            <$> decodeHostedCoreExpr entryPath value
            <*> decodeHostedCoreExpr entryPath body
        HostedCoreMutableLetArtifact exprType binder value body ->
          CMutableLet span' (decodeHostedCoreType exprType) binder
            <$> decodeHostedCoreExpr entryPath value
            <*> decodeHostedCoreExpr entryPath body
        HostedCoreAssignArtifact exprType binder value body ->
          CAssign span' (decodeHostedCoreType exprType) binder
            <$> decodeHostedCoreExpr entryPath value
            <*> decodeHostedCoreExpr entryPath body
        HostedCoreForArtifact exprType binder iterable loopBody body ->
          CFor span' (decodeHostedCoreType exprType) binder
            <$> decodeHostedCoreExpr entryPath iterable
            <*> decodeHostedCoreExpr entryPath loopBody
            <*> decodeHostedCoreExpr entryPath body
        HostedCoreCallArtifact exprType calleeName calleeType args ->
          CCall span' (decodeHostedCoreType exprType)
            (CVar span' (decodeHostedCoreType calleeType) calleeName)
            <$> traverse (decodeHostedCoreExpr entryPath) args
        HostedCoreMatchArtifact exprType subject branches ->
          CMatch span' (decodeHostedCoreType exprType)
            <$> decodeHostedCoreExpr entryPath subject
            <*> traverse (decodeHostedCoreMatchBranch entryPath) branches
        HostedCoreRecordArtifact exprType recordName fields ->
          CRecord span' (decodeHostedCoreType exprType) recordName
            <$> traverse (decodeHostedCoreRecordField entryPath) fields
        HostedCoreFieldAccessArtifact exprType subject fieldName ->
          CFieldAccess span' (decodeHostedCoreType exprType)
            <$> decodeHostedCoreExpr entryPath subject
            <*> pure fieldName

decodeHostedCoreDecl ::
     FilePath
  -> HostedCoreDeclArtifact
  -> Either Text CoreDecl
decodeHostedCoreDecl entryPath declArtifact = do
  bodyExpr <- decodeHostedCoreExpr entryPath (hostedCoreDeclArtifactBody declArtifact)
  pure
    CoreDecl
      { coreDeclName = hostedCoreDeclArtifactName declArtifact
      , coreDeclType = decodeHostedCoreType (hostedCoreDeclArtifactType declArtifact)
      , coreDeclParams =
          [ CoreParam
              { coreParamName = hostedCoreParamArtifactName paramArtifact
              , coreParamType = decodeHostedCoreType (hostedCoreParamArtifactType paramArtifact)
              }
          | paramArtifact <- hostedCoreDeclArtifactParams declArtifact
          ]
      , coreDeclBody = bodyExpr
      }

decodeHostedCoreModule ::
     FilePath
  -> Module
  -> Text
  -> Either DiagnosticBundle CoreModule
decodeHostedCoreModule entryPath loadedModule artifactText =
  case eitherDecodeStrictText artifactText of
    Left decodeErr ->
      Left $
        singleDiagnostic
          "E_PRIMARY_COMPILER_CHECK_ARTIFACT"
          "The primary Clasp compiler emitted an invalid checked-core artifact."
          [T.pack decodeErr]
    Right artifactResult ->
      case artifactResult of
        HostedCoreArtifactError message ->
          Left $
            singleDiagnostic
              "E_PRIMARY_COMPILER_CHECK_ARTIFACT"
              "The primary Clasp compiler could not build a checked-core artifact."
              [message]
        HostedCoreArtifactOk declArtifacts ->
          case traverse (decodeHostedCoreDecl entryPath) declArtifacts of
            Left decodeErr ->
              Left $
                singleDiagnostic
                  "E_PRIMARY_COMPILER_CHECK_ARTIFACT"
                  "The primary Clasp compiler emitted a checked-core artifact that could not be reconstructed."
                  [decodeErr]
            Right coreDecls ->
              Right
                CoreModule
                  { coreModuleName = moduleName loadedModule
                  , coreModuleImports = moduleImports loadedModule
                  , coreModuleTypeDecls = moduleTypeDecls loadedModule
                  , coreModuleRecordDecls = moduleRecordDecls loadedModule
                  , coreModuleDomainObjectDecls = []
                  , coreModuleDomainEventDecls = []
                  , coreModuleFeedbackDecls = []
                  , coreModuleMetricDecls = []
                  , coreModuleGoalDecls = []
                  , coreModuleExperimentDecls = []
                  , coreModuleRolloutDecls = []
                  , coreModuleWorkflowDecls = []
                  , coreModuleSupervisorDecls = []
                  , coreModuleGuideDecls = []
                  , coreModuleHookDecls = []
                  , coreModuleAgentRoleDecls = []
                  , coreModuleAgentDecls = []
                  , coreModulePolicyDecls = []
                  , coreModuleToolServerDecls = []
                  , coreModuleToolDecls = []
                  , coreModuleVerifierDecls = []
                  , coreModuleMergeGateDecls = []
                  , coreModuleProjectionDecls = []
                  , coreModuleForeignDecls = moduleForeignDecls loadedModule
                  , coreModuleRouteDecls = []
                  , coreModuleDecls = coreDecls
                  }


renderHostedStringLiteral :: Text -> Text
renderHostedStringLiteral value =
  T.pack (show value)

renderHostedPrimaryModuleSource :: Module -> Text
renderHostedPrimaryModuleSource modl =
  let renderedModule = renderModule modl {moduleImports = []}
      signatureLines =
        [ "hosted foreign-signature "
            <> foreignDeclName foreignDecl
            <> " = "
            <> renderHostedStringLiteral signature
        | foreignDecl <- moduleForeignDecls modl
        , Just packageImport <- [foreignDeclPackageImport foreignDecl]
        , Just signature <- [foreignPackageImportSignature packageImport]
        ]
   in if null signatureLines
        then renderedModule
        else T.intercalate "\n\n" [renderedModule, T.unlines signatureLines]

parseSource :: FilePath -> Text -> Either DiagnosticBundle Module
parseSource = parseModule

formatSource :: FilePath -> Text -> Either DiagnosticBundle Text
formatSource path source =
  renderModule <$> parseSource path source

checkSource :: FilePath -> Text -> Either DiagnosticBundle CoreModule
checkSource path source = do
  modl <- parseModule path source
  checkModule modl

semanticEditSource :: SemanticEdit -> FilePath -> Text -> Either DiagnosticBundle CoreModule
semanticEditSource edit path source =
  applySemanticEdit edit =<< checkSource path source

airSource :: FilePath -> Text -> Either DiagnosticBundle AirModule
airSource path source =
  buildAirModule <$> checkSource path source

renderAirSourceJson :: FilePath -> Text -> Either DiagnosticBundle LT.Text
renderAirSourceJson path source =
  renderAirModuleJson <$> airSource path source

contextSource :: FilePath -> Text -> Either DiagnosticBundle ContextGraph
contextSource path source =
  buildContextGraph <$> checkSource path source

renderContextSourceJson :: FilePath -> Text -> Either DiagnosticBundle LT.Text
renderContextSourceJson path source =
  renderContextGraphJson <$> contextSource path source

nativeSource :: FilePath -> Text -> Either DiagnosticBundle NativeModule
nativeSource path source =
  buildNativeModule . lowerModule <$> checkSource path source

renderNativeSource :: FilePath -> Text -> Either DiagnosticBundle Text
renderNativeSource path source =
  renderNativeModule <$> nativeSource path source

airEntry :: FilePath -> IO (Either DiagnosticBundle AirModule)
airEntry entryPath = do
  checkedModule <- checkEntry entryPath
  pure (buildAirModule <$> checkedModule)

renderAirEntryJson :: FilePath -> IO (Either DiagnosticBundle LT.Text)
renderAirEntryJson entryPath = do
  airModule <- airEntry entryPath
  pure (renderAirModuleJson <$> airModule)

renderAirEntryJsonWithPreference :: CompilerPreference -> FilePath -> IO (Either DiagnosticBundle LT.Text)
renderAirEntryJsonWithPreference preference entryPath = do
  (_implementation, checkedModule) <- checkEntryWithPreference preference entryPath
  pure (renderAirModuleJson . buildAirModule <$> checkedModule)

contextEntry :: FilePath -> IO (Either DiagnosticBundle ContextGraph)
contextEntry entryPath = do
  checkedModule <- checkEntry entryPath
  pure (buildContextGraph <$> checkedModule)

renderContextEntryJson :: FilePath -> IO (Either DiagnosticBundle LT.Text)
renderContextEntryJson entryPath = do
  contextGraph <- contextEntry entryPath
  pure (renderContextGraphJson <$> contextGraph)

renderContextEntryJsonWithPreference :: CompilerPreference -> FilePath -> IO (Either DiagnosticBundle LT.Text)
renderContextEntryJsonWithPreference preference entryPath = do
  (_implementation, checkedModule) <- checkEntryWithPreference preference entryPath
  pure (renderContextGraphJson . buildContextGraph <$> checkedModule)

nativeEntry :: FilePath -> IO (Either DiagnosticBundle NativeModule)
nativeEntry entryPath = do
  checkedModule <- checkEntry entryPath
  pure ((buildNativeModule . lowerModule) <$> checkedModule)

nativeEntryBootstrap :: FilePath -> IO (Either DiagnosticBundle NativeModule)
nativeEntryBootstrap entryPath = do
  checkedModule <- checkEntryBootstrap entryPath
  pure ((buildNativeModule . lowerModule) <$> checkedModule)

renderNativeEntry :: FilePath -> IO (Either DiagnosticBundle Text)
renderNativeEntry entryPath = snd <$> renderNativeEntryWithPreference CompilerPreferenceAuto entryPath

renderNativeEntryWithPreference :: CompilerPreference -> FilePath -> IO (CompilerImplementation, Either DiagnosticBundle Text)
renderNativeEntryWithPreference preference entryPath =
  case preference of
    CompilerPreferenceBootstrap -> do
      result <- renderNativeEntryBootstrap entryPath
      pure (CompilerImplementationBootstrap, result)
    CompilerPreferenceClasp ->
      runPrimaryTextTool HostedToolNative entryPath renderNativeEntryBootstrap
    CompilerPreferenceAuto ->
      preferPrimaryTool
        (supportsHostedPrimaryCommandAtPath HostedToolNative)
        entryPath
        (flip (runPrimaryTextTool HostedToolNative) renderNativeEntryBootstrap)
        renderNativeEntryBootstrap

renderNativeImageEntryWithPreference :: CompilerPreference -> FilePath -> IO (CompilerImplementation, Either DiagnosticBundle Text)
renderNativeImageEntryWithPreference preference entryPath =
  case preference of
    CompilerPreferenceBootstrap -> do
      result <- renderNativeImageEntryBootstrap entryPath
      pure (CompilerImplementationBootstrap, result)
    CompilerPreferenceClasp ->
      runPrimaryTextTool HostedToolNativeImage entryPath renderNativeImageEntryBootstrap
    CompilerPreferenceAuto ->
      preferPrimaryTool
        (supportsHostedPrimaryCommandAtPath HostedToolNativeImage)
        entryPath
        (flip (runPrimaryTextTool HostedToolNativeImage) renderNativeImageEntryBootstrap)
        renderNativeImageEntryBootstrap

compileSource :: FilePath -> Text -> Either DiagnosticBundle Text
compileSource path source = do
  modl <- checkSource path source
  pure (emitModule (buildAirModule modl) (lowerModule modl))

explainSource :: FilePath -> Text -> Either DiagnosticBundle Text
explainSource path source =
  renderCoreModule <$> checkSource path source

renderCoreModuleSummary :: CoreModule -> Text
renderCoreModuleSummary checkedModule =
  T.intercalate
    "\n"
    [ coreDeclName coreDecl <> " : " <> renderType (coreDeclType coreDecl)
    | coreDecl <- coreModuleDecls checkedModule
    ]

checkEntry :: FilePath -> IO (Either DiagnosticBundle CoreModule)
checkEntry entryPath = snd <$> checkEntryWithPreference CompilerPreferenceAuto entryPath

checkEntryBootstrap :: FilePath -> IO (Either DiagnosticBundle CoreModule)
checkEntryBootstrap entryPath = do
  loadedModule <- loadEntryModule entryPath
  pure (loadedModule >>= checkModule)

checkEntrySummaryBootstrap :: FilePath -> IO (Either DiagnosticBundle Text)
checkEntrySummaryBootstrap entryPath = do
  checkedModule <- checkEntryBootstrap entryPath
  pure (renderCoreModuleSummary <$> checkedModule)

checkEntryWithPreference :: CompilerPreference -> FilePath -> IO (CompilerImplementation, Either DiagnosticBundle CoreModule)
checkEntryWithPreference preference entryPath =
  case preference of
    CompilerPreferenceBootstrap -> do
      result <- checkEntryBootstrap entryPath
      pure (CompilerImplementationBootstrap, result)
    CompilerPreferenceClasp ->
      runPrimaryCheckEntry entryPath
    CompilerPreferenceAuto ->
      preferPrimaryTool
        (supportsHostedPrimaryCommandAtPath HostedToolCheck)
        entryPath
        runPrimaryCheckEntry
        checkEntryBootstrap

checkEntrySummaryWithPreference :: CompilerPreference -> FilePath -> IO (CompilerImplementation, Either DiagnosticBundle Text)
checkEntrySummaryWithPreference preference entryPath =
  case preference of
    CompilerPreferenceBootstrap -> do
      result <- checkEntrySummaryBootstrap entryPath
      pure (CompilerImplementationBootstrap, result)
    CompilerPreferenceClasp ->
      runPrimaryTextTool HostedToolCheck entryPath checkEntrySummaryBootstrap
    CompilerPreferenceAuto ->
      preferPrimaryTool
        (supportsHostedPrimaryCommandAtPath HostedToolCheck)
        entryPath
        (flip (runPrimaryTextTool HostedToolCheck) checkEntrySummaryBootstrap)
        checkEntrySummaryBootstrap

semanticEditEntry :: SemanticEdit -> FilePath -> IO (Either DiagnosticBundle CoreModule)
semanticEditEntry edit entryPath = do
  checkedModule <- checkEntry entryPath
  pure (checkedModule >>= applySemanticEdit edit)

compileEntry :: FilePath -> IO (Either DiagnosticBundle Text)
compileEntry entryPath = snd <$> compileEntryWithPreference CompilerPreferenceAuto entryPath

compileEntryWithPreference :: CompilerPreference -> FilePath -> IO (CompilerImplementation, Either DiagnosticBundle Text)
compileEntryWithPreference preference entryPath =
  case preference of
    CompilerPreferenceBootstrap -> do
      result <- compileEntryBootstrap entryPath
      pure (CompilerImplementationBootstrap, result)
    CompilerPreferenceClasp ->
      runPrimaryTextTool HostedToolCompile entryPath compileEntryBootstrap
    CompilerPreferenceAuto ->
      preferPrimaryTool
        (supportsHostedPrimaryCommandAtPath HostedToolCompile)
        entryPath
        (flip (runPrimaryTextTool HostedToolCompile) compileEntryBootstrap)
        compileEntryBootstrap

explainEntry :: FilePath -> IO (Either DiagnosticBundle Text)
explainEntry entryPath = snd <$> explainEntryWithPreference CompilerPreferenceAuto entryPath

explainEntryWithPreference :: CompilerPreference -> FilePath -> IO (CompilerImplementation, Either DiagnosticBundle Text)
explainEntryWithPreference preference entryPath =
  case preference of
    CompilerPreferenceBootstrap -> do
      result <- explainEntryBootstrap entryPath
      pure (CompilerImplementationBootstrap, result)
    CompilerPreferenceClasp ->
      runPrimaryTextTool HostedToolExplain entryPath hostedExplainEntryBootstrap
    CompilerPreferenceAuto ->
      preferPrimaryTool
        supportsHostedAutoExplainAtPath
        entryPath
        (flip (runPrimaryTextTool HostedToolExplain) hostedExplainEntryBootstrap)
        explainEntryBootstrap

runPrimaryCheckEntry :: FilePath -> IO (CompilerImplementation, Either DiagnosticBundle CoreModule)
runPrimaryCheckEntry entryPath = do
  loadedModuleResult <- loadEntryModule entryPath
  case loadedModuleResult of
    Left err ->
      pure (CompilerImplementationClasp, Left err)
    Right loadedModule -> do
      let hostedSource = renderHostedPrimaryModuleSource loadedModule
      if not (supportsHostedPrimaryCommand HostedToolCheck entryPath hostedSource)
        then
          pure
            ( CompilerImplementationClasp
            , Left $
                singleDiagnostic
                  "E_PRIMARY_COMPILER_UNSUPPORTED"
                  "The primary Clasp compiler does not support this entrypoint yet."
                  ["Use --compiler=bootstrap for this command, or run the hosted compiler entrypoint at compiler/hosted/Main.clasp."]
            )
        else do
          primaryResult <- runHostedTool HostedToolCheckCore entryPath hostedSource ""
          pure (CompilerImplementationClasp, primaryResult >>= decodeHostedCoreModule entryPath loadedModule)

runPrimaryTextTool ::
     HostedToolCommand
  -> FilePath
  -> (FilePath -> IO (Either DiagnosticBundle Text))
  -> IO (CompilerImplementation, Either DiagnosticBundle Text)
runPrimaryTextTool command entryPath bootstrapAction = do
  sourceResult <- prepareHostedPrimarySource entryPath
  case sourceResult of
    Left err ->
      pure (CompilerImplementationClasp, Left err)
    Right hostedSource ->
      if not (supportsHostedPrimaryCommand command entryPath hostedSource)
        then
          pure
            ( CompilerImplementationClasp
            , Left $
                singleDiagnostic
                  "E_PRIMARY_COMPILER_UNSUPPORTED"
                  "The primary Clasp compiler does not support this entrypoint yet."
                  ["Use --compiler=bootstrap for this command, or run the hosted compiler entrypoint at compiler/hosted/Main.clasp."]
            )
        else
          if not (supportsPrimaryTool entryPath)
            then do
              primaryResult <- runHostedTool command entryPath hostedSource ""
              pure (CompilerImplementationClasp, primaryResult)
            else do
              bootstrapResult <- bootstrapAction entryPath
              case bootstrapResult of
                Left err ->
                  pure (CompilerImplementationClasp, Left err)
                Right output -> do
                  primaryResult <- runHostedTool command entryPath hostedSource output
                  pure (CompilerImplementationClasp, primaryResult)

supportsPrimaryTool :: FilePath -> Bool
supportsPrimaryTool entryPath =
  let target = hostedCompilerEntryPath
      normalizedPath = normalise entryPath
   in normalizedPath == target || target `isSuffixOf` normalizedPath

prepareHostedPrimarySource :: FilePath -> IO (Either DiagnosticBundle Text)
prepareHostedPrimarySource entryPath
  | supportsPrimaryTool entryPath = Right <$> TIO.readFile entryPath
  | otherwise = do
      loadedModule <- loadEntryModule entryPath
      pure (renderHostedPrimaryModuleSource <$> loadedModule)

renderHostedPrimaryEntrySource :: FilePath -> IO (Either DiagnosticBundle Text)
renderHostedPrimaryEntrySource entryPath = do
  loadedModule <- loadEntryModule entryPath
  pure (renderHostedPrimaryModuleSource <$> loadedModule)

supportsHostedPrimaryCommand :: HostedToolCommand -> FilePath -> Text -> Bool
supportsHostedPrimaryCommand command entryPath hostedSource =
  case command of
    HostedToolCheck ->
      supportsPrimaryTool entryPath || isHostedSubsetCandidate hostedSource
    HostedToolCheckCore ->
      supportsPrimaryTool entryPath || isHostedSubsetCandidate hostedSource
    HostedToolExplain ->
      supportsPrimaryTool entryPath || isHostedSubsetCandidate hostedSource
    HostedToolCompile ->
      supportsPrimaryTool entryPath || isHostedSubsetCandidate hostedSource
    HostedToolNative ->
      supportsPrimaryTool entryPath || isHostedNativeCandidate hostedSource
    HostedToolNativeImage ->
      supportsPrimaryTool entryPath || isHostedNativeCandidate hostedSource

supportsHostedPrimaryCommandAtPath :: HostedToolCommand -> FilePath -> IO Bool
supportsHostedPrimaryCommandAtPath command entryPath = do
  sourceResult <- prepareHostedPrimarySource entryPath
  pure $
    case sourceResult of
      Left _ ->
        False
      Right hostedSource ->
        supportsHostedPrimaryCommand command entryPath hostedSource

supportsHostedAutoExplainAtPath :: FilePath -> IO Bool
supportsHostedAutoExplainAtPath entryPath
  | supportsPrimaryTool entryPath =
      pure True
  | otherwise = do
      loadedModule <- loadEntryModule entryPath
      pure $
        case loadedModule of
          Left _ ->
            False
          Right modl ->
            null (moduleImports modl)
              && supportsHostedPrimaryCommand HostedToolExplain entryPath (renderHostedPrimaryModuleSource modl)

isHostedNativeCandidate :: Text -> Bool
isHostedNativeCandidate source =
  let disallowedPrefixes =
        [ "foreign "
        ]
      startsWithDisallowed line =
        any (`T.isPrefixOf` T.stripStart line) disallowedPrefixes
   in isHostedSubsetCandidate source && not (any startsWithDisallowed (T.lines source))

isHostedSubsetCandidate :: Text -> Bool
isHostedSubsetCandidate source =
  let disallowedPrefixes =
        [ "import "
        , "page "
        , "route "
        , "json "
        , "hook "
        , "workflow "
        , "domain "
        , "feedback "
        , "metric "
        , "goal "
        , "experiment "
        , "rollout "
        , "supervisor "
        , "agent "
        , "toolserver "
        , "tool "
        , "verifier "
        , "mergegate "
        , "policy "
        , "guide "
        , "memory "
        ]
      startsWithDisallowed line =
        any (`T.isPrefixOf` T.stripStart line) disallowedPrefixes
   in not (any startsWithDisallowed (T.lines source))

preferPrimaryTool ::
     (FilePath -> IO Bool)
  -> FilePath
  -> (FilePath -> IO (CompilerImplementation, Either DiagnosticBundle a))
  -> (FilePath -> IO (Either DiagnosticBundle a))
  -> IO (CompilerImplementation, Either DiagnosticBundle a)
preferPrimaryTool supports entryPath primaryAction bootstrapAction = do
  primarySupported <- supports entryPath
  if primarySupported
    then do
      (implementation, result) <- primaryAction entryPath
      case result of
        Right _ ->
          pure (implementation, result)
        Left _ -> do
          bootstrapResult <- bootstrapAction entryPath
          pure (CompilerImplementationBootstrap, bootstrapResult)
    else do
      result <- bootstrapAction entryPath
      pure (CompilerImplementationBootstrap, result)

runHostedTool :: HostedToolCommand -> FilePath -> Text -> Text -> IO (Either DiagnosticBundle Text)
runHostedTool command entryPath hostedSource bootstrapOutput = do
  if T.null bootstrapOutput
    then runHostedToolNative command entryPath hostedSource
    else runHostedToolJs command entryPath hostedSource bootstrapOutput

runHostedToolNative :: HostedToolCommand -> FilePath -> Text -> IO (Either DiagnosticBundle Text)
runHostedToolNative command _entryPath hostedSource = do
  tempRoot <- getTemporaryDirectory
  let tempDir = tempRoot </> "clasp-primary-tool"
      entrySourcePath = tempDir </> "entry.clasp"
      primaryOutputPath = tempDir </> ("primary-output" <.> hostedToolOutputExtension command)
  tempDirExists <- doesDirectoryExist tempDir
  if tempDirExists
    then removePathForcibly tempDir
    else pure ()
  let cleanup = removePathForcibly tempDir
  flip finally cleanup $ do
    nativeSeedExists <- doesFileExist hostedCompilerNativeSeedPath
    if not nativeSeedExists
      then
        pure $
          Left $
            singleDiagnostic
              "E_PRIMARY_COMPILER_NATIVE_SEED_MISSING"
              "The promoted hosted native compiler seed is missing."
              ["Regenerate compiler/hosted/stage1.native.image.json before running the primary Clasp compiler."]
      else do
        createDirectoryIfMissing True tempDir
        writeFileText entrySourcePath hostedSource
        (exitCode, _stdoutText, stderrText) <-
          readProcessWithExitCode
            "bash"
            [ hostedCompilerNativeToolRunnerPath
            , hostedCompilerNativeSeedPath
            , renderHostedToolExportName command
            , entrySourcePath
            , primaryOutputPath
            ]
            ""
        case exitCode of
          ExitSuccess -> do
            primaryOutput <- TIO.readFile primaryOutputPath
            pure $
              case validateHostedToolOutput command primaryOutput of
                Left err ->
                  Left err
                Right () ->
                  Right primaryOutput
          ExitFailure _ ->
            pure $
              Left $
                singleDiagnostic
                  "E_PRIMARY_COMPILER_RUNTIME"
                  "The primary Clasp compiler native runtime check failed."
                  [T.pack stderrText]

runHostedToolJs :: HostedToolCommand -> FilePath -> Text -> Text -> IO (Either DiagnosticBundle Text)
runHostedToolJs command entryPath hostedSource bootstrapOutput = do
  tempRoot <- getTemporaryDirectory
  let tempDir = tempRoot </> "clasp-primary-tool"
      validationDir = takeDirectory entryPath
  tempDirExists <- doesDirectoryExist tempDir
  if tempDirExists
    then removePathForcibly tempDir
    else pure ()
  let cleanup = removePathForcibly tempDir
      entrySourcePath = tempDir </> "entry.clasp"
      stage1Path = tempDir </> "stage1.mjs"
      bootstrapOutputPath = tempDir </> ("bootstrap-output" <.> hostedToolOutputExtension command)
      primaryOutputPath = tempDir </> ("primary-output" <.> hostedToolOutputExtension command)
  flip finally cleanup $ do
    createDirectoryIfMissing True tempDir
    promotedStage1 <- readHostedStage1Seed
    case promotedStage1 of
      Left err ->
        pure (Left err)
      Right stage1Seed -> do
        writeFileText entrySourcePath hostedSource
        writeFileText stage1Path stage1Seed
        writeFileText bootstrapOutputPath bootstrapOutput
        (exitCode, _stdoutText, stderrText) <-
          readProcessWithExitCode
            "node"
            [ hostedCompilerToolRunnerPath
            , renderHostedToolCommand command
            , entrySourcePath
            , stage1Path
            , bootstrapOutputPath
            , primaryOutputPath
            , validationDir
            ]
            ""
        case exitCode of
          ExitSuccess ->
            Right <$> TIO.readFile primaryOutputPath
          ExitFailure _ ->
            pure $
              Left $
                singleDiagnostic
                  "E_PRIMARY_COMPILER_RUNTIME"
                  "The primary Clasp compiler runtime check failed."
                  [T.pack stderrText]

validateHostedToolOutput :: HostedToolCommand -> Text -> Either DiagnosticBundle ()
validateHostedToolOutput command output =
  case command of
    HostedToolCheck ->
      validateHostedSummaryOutput "check" output
    HostedToolCheckCore ->
      validateHostedCheckCoreOutput output
    HostedToolCompile ->
      validateHostedCompileOutput output
    HostedToolExplain ->
      validateHostedSummaryOutput "explain" output
    HostedToolNative ->
      validateHostedNativeOutput output
    HostedToolNativeImage ->
      validateHostedNativeImageOutput output

validateHostedSummaryOutput :: Text -> Text -> Either DiagnosticBundle ()
validateHostedSummaryOutput commandName summaryText =
  let linesText =
        filter (not . T.null) $
          map T.strip (T.lines summaryText)
      invalidLine =
        findHostedInvalidSummaryLine linesText
   in if null linesText
        then
          Left $
            singleDiagnostic
              "E_PRIMARY_COMPILER_RUNTIME"
              "The primary Clasp compiler runtime check failed."
              ["hosted " <> commandName <> " compatibility check emitted an empty summary"]
        else
          case invalidLine of
            Just badLine ->
              Left $
                singleDiagnostic
                  "E_PRIMARY_COMPILER_RUNTIME"
                  "The primary Clasp compiler runtime check failed."
                  ["hosted " <> commandName <> " compatibility check emitted an invalid summary line", badLine]
            Nothing ->
              Right ()

findHostedInvalidSummaryLine :: [Text] -> Maybe Text
findHostedInvalidSummaryLine [] = Nothing
findHostedInvalidSummaryLine (line:rest)
  | isHostedValidSummaryLine line = findHostedInvalidSummaryLine rest
  | otherwise = Just line

isHostedValidSummaryLine :: Text -> Bool
isHostedValidSummaryLine line =
  let (name, remainder) = T.breakOn " : " line
   in not (T.null name) && remainder /= "" && T.length remainder > 3

validateHostedCheckCoreOutput :: Text -> Either DiagnosticBundle ()
validateHostedCheckCoreOutput output =
  case eitherDecodeStrictText output :: Either String HostedCoreArtifactResult of
    Left err ->
      Left $
        singleDiagnostic
          "E_PRIMARY_COMPILER_RUNTIME"
          "The primary Clasp compiler runtime check failed."
          ["hosted check-core compatibility check emitted invalid JSON", T.pack err]
    Right _ ->
      Right ()

validateHostedCompileOutput :: Text -> Either DiagnosticBundle ()
validateHostedCompileOutput output =
  if T.isPrefixOf "// Generated by compiler-selfhost" output && "export " `T.isInfixOf` output
    then Right ()
    else
      Left $
        singleDiagnostic
          "E_PRIMARY_COMPILER_RUNTIME"
          "The primary Clasp compiler runtime check failed."
          ["hosted compile compatibility check emitted an invalid JavaScript module"]

validateHostedNativeOutput :: Text -> Either DiagnosticBundle ()
validateHostedNativeOutput output =
  let requiredChecks =
        [ ("format header", "format clasp-native-ir-v1" `T.isInfixOf` output)
        , ("module header", any ("module " `T.isPrefixOf`) (T.lines output))
        , ("exports section", any ("exports [" `T.isPrefixOf`) (T.lines output))
        , ("abi section", "abi {" `T.isInfixOf` output)
        , ("runtime section", "runtime {" `T.isInfixOf` output)
        ]
      missing = map fst (filter (not . snd) requiredChecks)
   in if null missing
        then Right ()
        else
          Left $
            singleDiagnostic
              "E_PRIMARY_COMPILER_RUNTIME"
              "The primary Clasp compiler runtime check failed."
              ["hosted native compatibility check emitted an invalid native module artifact", "missing " <> T.intercalate ", " missing]

validateHostedNativeImageOutput :: Text -> Either DiagnosticBundle ()
validateHostedNativeImageOutput output =
  case eitherDecodeStrictText output :: Either String Value of
    Left err ->
      Left $
        singleDiagnostic
          "E_PRIMARY_COMPILER_RUNTIME"
          "The primary Clasp compiler runtime check failed."
          ["hosted native-image compatibility check emitted invalid JSON", T.pack err]
    Right (Object imageArtifact) ->
      let lookupField name = KM.lookup name imageArtifact
          lookupText name =
            case lookupField name of
              Just (String value) -> Just value
              _ -> Nothing
          lookupArray name =
            case lookupField name of
              Just (Array values) -> Just values
              _ -> Nothing
          lookupObject name =
            case lookupField name of
              Just (Object value) -> Just value
              _ -> Nothing
          runtimeProfile =
            lookupObject "runtime"
              >>= (\runtimeArtifact -> case KM.lookup "profile" runtimeArtifact of
                    Just (String value) -> Just value
                    _ -> Nothing)
          compatibilityKind =
            lookupObject "compatibility"
              >>= (\compatibilityArtifact -> case KM.lookup "kind" compatibilityArtifact of
                    Just (String value) -> Just value
                    _ -> Nothing)
          declHasBody declValue =
            case declValue of
              Object declObject -> case KM.lookup "body" declObject of
                Just Null -> False
                Just _ -> True
                Nothing -> False
              _ -> False
          declsWithBodies =
            case lookupArray "decls" of
              Just decls -> any declHasBody decls
              Nothing -> False
          missing =
            concat
              [ if lookupText "format" == Just "clasp-native-image-v1" then [] else ["format"]
              , if lookupText "irFormat" == Just "clasp-native-ir-v1" then [] else ["irFormat"]
              , if maybe True T.null (lookupText "module") then ["module"] else []
              , if maybe True null (lookupArray "exports") then ["exports"] else []
              , if maybe True null (lookupArray "entrypoints") then ["entrypoints"] else []
              , if maybe True T.null runtimeProfile then ["runtime.profile"] else []
              , if compatibilityKind == Just "clasp-native-compatibility-v1" then [] else ["compatibility.kind"]
              , if maybe True null (lookupArray "decls") then ["decls"] else []
              , if declsWithBodies then [] else ["decls.body"]
              ]
       in if null missing
            then Right ()
            else
              Left $
                singleDiagnostic
                  "E_PRIMARY_COMPILER_RUNTIME"
                  "The primary Clasp compiler runtime check failed."
                  ["hosted native-image compatibility check emitted an invalid native image artifact", "missing " <> T.intercalate ", " missing]
    Right _ ->
      Left $
        singleDiagnostic
          "E_PRIMARY_COMPILER_RUNTIME"
          "The primary Clasp compiler runtime check failed."
          ["hosted native-image compatibility check emitted invalid JSON", "root value was not an object"]

readHostedStage1Seed :: IO (Either DiagnosticBundle Text)
readHostedStage1Seed = do
  seedExists <- doesFileExist hostedCompilerSeedPath
  if seedExists
    then
      Right <$> TIO.readFile hostedCompilerSeedPath
    else
      pure $
        Left $
          singleDiagnostic
            "E_PRIMARY_COMPILER_SEED_MISSING"
            "The promoted hosted compiler seed is missing."
            ["Regenerate compiler/hosted/stage1.mjs before running the primary Clasp compiler."]

hostedToolOutputExtension :: HostedToolCommand -> String
hostedToolOutputExtension command =
  case command of
    HostedToolCheck ->
      "check.txt"
    HostedToolCheckCore ->
      "check-core.json"
    HostedToolCompile ->
      "mjs"
    HostedToolExplain ->
      "txt"
    HostedToolNative ->
      "native.ir"
    HostedToolNativeImage ->
      "native.image.json"

renderHostedToolCommand :: HostedToolCommand -> String
renderHostedToolCommand command =
  case command of
    HostedToolCheck ->
      "check"
    HostedToolCheckCore ->
      "check-core"
    HostedToolCompile ->
      "compile"
    HostedToolExplain ->
      "explain"
    HostedToolNative ->
      "native"
    HostedToolNativeImage ->
      "native-image"

renderHostedToolExportName :: HostedToolCommand -> String
renderHostedToolExportName command =
  case command of
    HostedToolCheck ->
      "checkSourceText"
    HostedToolCheckCore ->
      "checkCoreSourceText"
    HostedToolCompile ->
      "compileSourceText"
    HostedToolExplain ->
      "explainSourceText"
    HostedToolNative ->
      "nativeSourceText"
    HostedToolNativeImage ->
      "nativeImageSourceText"

explainEntryBootstrap :: FilePath -> IO (Either DiagnosticBundle Text)
explainEntryBootstrap entryPath = do
  checkedModule <- checkEntryBootstrap entryPath
  pure (renderCoreModule <$> checkedModule)

hostedExplainEntryBootstrap :: FilePath -> IO (Either DiagnosticBundle Text)
hostedExplainEntryBootstrap entryPath = do
  checkedModule <- checkEntryBootstrap entryPath
  pure (renderCoreModuleSummary <$> checkedModule)

hostedCompilerToolRunnerPath :: FilePath
hostedCompilerToolRunnerPath =
  "compiler" </> "hosted" </> "run-tool.mjs"

hostedCompilerNativeToolRunnerPath :: FilePath
hostedCompilerNativeToolRunnerPath =
  "compiler" </> "hosted" </> "scripts" </> "run-native-tool.sh"

hostedCompilerEntryPath :: FilePath
hostedCompilerEntryPath =
  normalise ("compiler" </> "hosted" </> "Main.clasp")

hostedCompilerSeedPath :: FilePath
hostedCompilerSeedPath =
  normalise ("compiler" </> "hosted" </> "stage1.mjs")

hostedCompilerNativeSeedPath :: FilePath
hostedCompilerNativeSeedPath =
  normalise ("compiler" </> "hosted" </> "stage1.native.image.json")

compileEntryBootstrap :: FilePath -> IO (Either DiagnosticBundle Text)
compileEntryBootstrap entryPath = do
  checkedModule <- checkEntryBootstrap entryPath
  pure ((\modl -> emitModule (buildAirModule modl) (lowerModule modl)) <$> checkedModule)

renderNativeEntryBootstrap :: FilePath -> IO (Either DiagnosticBundle Text)
renderNativeEntryBootstrap entryPath = do
  nativeModule <- nativeEntryBootstrap entryPath
  pure (renderNativeModule <$> nativeModule)

renderNativeImageEntryBootstrap :: FilePath -> IO (Either DiagnosticBundle Text)
renderNativeImageEntryBootstrap entryPath = do
  nativeModule <- nativeEntryBootstrap entryPath
  pure (LT.toStrict . renderNativeModuleImageJson <$> nativeModule)

writeFileText :: FilePath -> Text -> IO ()
writeFileText = TIO.writeFile
