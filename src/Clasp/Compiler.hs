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
  , semanticEditEntry
  , semanticEditSource
  , SemanticEdit (..)
  ) where

import Control.Exception (finally)
import Data.List (isSuffixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as LT
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, getTemporaryDirectory, removePathForcibly)
import System.Exit (ExitCode (..))
import System.FilePath ((<.>), (</>), normalise)
import System.Process (readProcessWithExitCode)
import Clasp.Air (AirModule, buildAirModule, renderAirModuleJson)
import Clasp.Checker (checkModule)
import Clasp.ContextGraph (ContextGraph, buildContextGraph, renderContextGraphJson)
import Clasp.Core (CoreDecl (..), CoreModule (..), SemanticEdit (..), applySemanticEdit, renderCoreModule)
import Clasp.Diagnostic (DiagnosticBundle, singleDiagnostic)
import Clasp.Emit.JavaScript (emitModule)
import Clasp.Loader (loadEntryModule)
import Clasp.Lower (lowerModule)
import Clasp.Native (NativeModule, buildNativeModule, renderNativeModule)
import Clasp.Parser (parseModule)
import Clasp.Syntax (Module (..), renderModule, renderType)

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
  | HostedToolCompile
  | HostedToolExplain
  | HostedToolNative
  deriving (Eq, Show)

renderHostedPrimaryModuleSource :: Module -> Text
renderHostedPrimaryModuleSource modl =
  renderModule modl {moduleImports = []}

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
      preferPrimaryTool supportsPrimaryTool entryPath (flip (runPrimaryTextTool HostedToolNative) renderNativeEntryBootstrap) renderNativeEntryBootstrap

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

checkEntryWithPreference :: CompilerPreference -> FilePath -> IO (CompilerImplementation, Either DiagnosticBundle CoreModule)
checkEntryWithPreference preference entryPath =
  case preference of
    CompilerPreferenceBootstrap -> do
      result <- checkEntryBootstrap entryPath
      pure (CompilerImplementationBootstrap, result)
    CompilerPreferenceClasp ->
      runPrimaryCheckEntry entryPath
    CompilerPreferenceAuto ->
      preferPrimaryTool supportsPrimaryTool entryPath runPrimaryCheckEntry checkEntryBootstrap

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
      preferPrimaryTool supportsPrimaryTool entryPath (flip (runPrimaryTextTool HostedToolCompile) compileEntryBootstrap) compileEntryBootstrap

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
      preferPrimaryTool supportsPrimaryTool entryPath (flip (runPrimaryTextTool HostedToolExplain) hostedExplainEntryBootstrap) explainEntryBootstrap

runPrimaryCheckEntry :: FilePath -> IO (CompilerImplementation, Either DiagnosticBundle CoreModule)
runPrimaryCheckEntry entryPath = do
  sourceResult <- prepareHostedPrimarySource entryPath
  case sourceResult of
    Left err ->
      pure (CompilerImplementationClasp, Left err)
    Right hostedSource ->
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
          bootstrapResult <- checkEntryBootstrap entryPath
          case bootstrapResult of
            Left err ->
              pure (CompilerImplementationClasp, Left err)
            Right checkedModule -> do
              primaryResult <- runHostedTool HostedToolCheck hostedSource (renderCoreModuleSummary checkedModule)
              pure (CompilerImplementationClasp, checkedModule <$ primaryResult)

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
        else do
          bootstrapResult <- bootstrapAction entryPath
          case bootstrapResult of
            Left err ->
              pure (CompilerImplementationClasp, Left err)
            Right output -> do
              primaryResult <- runHostedTool command hostedSource output
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

supportsHostedPrimaryCommand :: HostedToolCommand -> FilePath -> Text -> Bool
supportsHostedPrimaryCommand command entryPath hostedSource =
  case command of
    HostedToolCheck ->
      supportsPrimaryTool entryPath || isHostedSubsetCandidate hostedSource
    HostedToolExplain ->
      supportsPrimaryTool entryPath || isHostedSubsetCandidate hostedSource
    HostedToolCompile ->
      supportsPrimaryTool entryPath || isHostedSubsetCandidate hostedSource
    HostedToolNative ->
      supportsPrimaryTool entryPath || isHostedNativeCandidate hostedSource

isHostedNativeCandidate :: Text -> Bool
isHostedNativeCandidate source =
  let disallowedPrefixes =
        [ "record "
        , "type "
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
        , "foreign "
        , "policy "
        , "guide "
        , "memory "
        ]
      startsWithDisallowed line =
        any (`T.isPrefixOf` T.stripStart line) disallowedPrefixes
   in not (any startsWithDisallowed (T.lines source))

preferPrimaryTool ::
     (FilePath -> Bool)
  -> FilePath
  -> (FilePath -> IO (CompilerImplementation, Either DiagnosticBundle a))
  -> (FilePath -> IO (Either DiagnosticBundle a))
  -> IO (CompilerImplementation, Either DiagnosticBundle a)
preferPrimaryTool supports entryPath primaryAction bootstrapAction =
  if supports entryPath
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

runHostedTool :: HostedToolCommand -> Text -> Text -> IO (Either DiagnosticBundle Text)
runHostedTool command hostedSource bootstrapOutput = do
  tempRoot <- getTemporaryDirectory
  let tempDir = tempRoot </> "clasp-primary-tool"
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
    compiledStage1 <- compileEntryBootstrap hostedCompilerEntryPath
    case compiledStage1 of
      Left err ->
        pure (Left err)
      Right compiledJs -> do
        writeFileText entrySourcePath hostedSource
        writeFileText stage1Path compiledJs
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

hostedToolOutputExtension :: HostedToolCommand -> String
hostedToolOutputExtension command =
  case command of
    HostedToolCheck ->
      "check.txt"
    HostedToolCompile ->
      "mjs"
    HostedToolExplain ->
      "txt"
    HostedToolNative ->
      "native.ir"

renderHostedToolCommand :: HostedToolCommand -> String
renderHostedToolCommand command =
  case command of
    HostedToolCheck ->
      "check"
    HostedToolCompile ->
      "compile"
    HostedToolExplain ->
      "explain"
    HostedToolNative ->
      "native"

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

hostedCompilerEntryPath :: FilePath
hostedCompilerEntryPath =
  normalise ("compiler" </> "hosted" </> "Main.clasp")

compileEntryBootstrap :: FilePath -> IO (Either DiagnosticBundle Text)
compileEntryBootstrap entryPath = do
  checkedModule <- checkEntryBootstrap entryPath
  pure ((\modl -> emitModule (buildAirModule modl) (lowerModule modl)) <$> checkedModule)

renderNativeEntryBootstrap :: FilePath -> IO (Either DiagnosticBundle Text)
renderNativeEntryBootstrap entryPath = do
  nativeModule <- nativeEntryBootstrap entryPath
  pure (renderNativeModule <$> nativeModule)

writeFileText :: FilePath -> Text -> IO ()
writeFileText = TIO.writeFile
