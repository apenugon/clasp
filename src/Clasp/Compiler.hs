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
  , explainSource
  , explainEntry
  , formatSource
  , renderNativeSource
  , renderNativeEntry
  , nativeSource
  , nativeEntry
  , parseSource
  , renderAirEntryJson
  , renderAirSourceJson
  , renderContextEntryJson
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
import System.FilePath ((</>), normalise)
import System.Process (readProcessWithExitCode)
import Clasp.Air (AirModule, buildAirModule, renderAirModuleJson)
import Clasp.Checker (checkModule)
import Clasp.ContextGraph (ContextGraph, buildContextGraph, renderContextGraphJson)
import Clasp.Core (CoreModule, SemanticEdit (..), applySemanticEdit, renderCoreModule)
import Clasp.Diagnostic (DiagnosticBundle, singleDiagnostic)
import Clasp.Emit.JavaScript (emitModule)
import Clasp.Loader (loadEntryModule)
import Clasp.Lower (lowerModule)
import Clasp.Native (NativeModule, buildNativeModule, renderNativeModule)
import Clasp.Parser (parseModule)
import Clasp.Syntax (Module, renderModule)

data CompilerImplementation
  = CompilerImplementationClasp
  | CompilerImplementationBootstrap
  deriving (Eq, Show)

data CompilerPreference
  = CompilerPreferenceAuto
  | CompilerPreferenceClasp
  | CompilerPreferenceBootstrap
  deriving (Eq, Show)

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

contextEntry :: FilePath -> IO (Either DiagnosticBundle ContextGraph)
contextEntry entryPath = do
  checkedModule <- checkEntry entryPath
  pure (buildContextGraph <$> checkedModule)

renderContextEntryJson :: FilePath -> IO (Either DiagnosticBundle LT.Text)
renderContextEntryJson entryPath = do
  contextGraph <- contextEntry entryPath
  pure (renderContextGraphJson <$> contextGraph)

nativeEntry :: FilePath -> IO (Either DiagnosticBundle NativeModule)
nativeEntry entryPath = do
  checkedModule <- checkEntry entryPath
  pure ((buildNativeModule . lowerModule) <$> checkedModule)

renderNativeEntry :: FilePath -> IO (Either DiagnosticBundle Text)
renderNativeEntry entryPath = do
  nativeModule <- nativeEntry entryPath
  pure (renderNativeModule <$> nativeModule)

compileSource :: FilePath -> Text -> Either DiagnosticBundle Text
compileSource path source = do
  modl <- checkSource path source
  pure (emitModule (buildAirModule modl) (lowerModule modl))

explainSource :: FilePath -> Text -> Either DiagnosticBundle Text
explainSource path source =
  renderCoreModule <$> checkSource path source

checkEntry :: FilePath -> IO (Either DiagnosticBundle CoreModule)
checkEntry = checkEntryBootstrap

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
      runPrimaryCheck entryPath
    CompilerPreferenceAuto ->
      if supportsPrimaryCheck entryPath
        then do
          (implementation, result) <- runPrimaryCheck entryPath
          case result of
            Right _ ->
              pure (implementation, result)
            Left _ -> do
              bootstrapResult <- checkEntryBootstrap entryPath
              pure (CompilerImplementationBootstrap, bootstrapResult)
        else do
          result <- checkEntryBootstrap entryPath
          pure (CompilerImplementationBootstrap, result)

semanticEditEntry :: SemanticEdit -> FilePath -> IO (Either DiagnosticBundle CoreModule)
semanticEditEntry edit entryPath = do
  checkedModule <- checkEntry entryPath
  pure (checkedModule >>= applySemanticEdit edit)

compileEntry :: FilePath -> IO (Either DiagnosticBundle Text)
compileEntry entryPath = do
  checkedModule <- checkEntryBootstrap entryPath
  pure ((\modl -> emitModule (buildAirModule modl) (lowerModule modl)) <$> checkedModule)

explainEntry :: FilePath -> IO (Either DiagnosticBundle Text)
explainEntry entryPath = do
  checkedModule <- checkEntryBootstrap entryPath
  pure (renderCoreModule <$> checkedModule)

runPrimaryCheck :: FilePath -> IO (CompilerImplementation, Either DiagnosticBundle CoreModule)
runPrimaryCheck entryPath
  | not (supportsPrimaryCheck entryPath) =
      pure
        ( CompilerImplementationClasp
        , Left $
            singleDiagnostic
              "E_PRIMARY_COMPILER_UNSUPPORTED"
              "The primary Clasp compiler does not support this entrypoint yet."
              ["Use --compiler=bootstrap for this command, or run the hosted compiler entrypoint at compiler/hosted/Main.clasp."]
        )
  | otherwise = do
      bootstrapResult <- checkEntryBootstrap entryPath
      case bootstrapResult of
        Left err ->
          pure (CompilerImplementationClasp, Left err)
        Right checkedModule -> do
          primaryResult <- verifyHostedPrimaryCheck entryPath
          pure (CompilerImplementationClasp, checkedModule <$ primaryResult)

supportsPrimaryCheck :: FilePath -> Bool
supportsPrimaryCheck entryPath =
  let target = hostedCompilerEntryPath
      normalizedPath = normalise entryPath
   in normalizedPath == target || target `isSuffixOf` normalizedPath

verifyHostedPrimaryCheck :: FilePath -> IO (Either DiagnosticBundle ())
verifyHostedPrimaryCheck entryPath = do
  tempRoot <- getTemporaryDirectory
  let tempDir = tempRoot </> "clasp-primary-check"
  tempDirExists <- doesDirectoryExist tempDir
  if tempDirExists
    then removePathForcibly tempDir
    else pure ()
  let cleanup = removePathForcibly tempDir
      stage1Path = tempDir </> "stage1.mjs"
      stage2CompilerPath = tempDir </> "stage2-compiler.mjs"
      stage2OutputPath = tempDir </> "stage2-output.mjs"
  flip finally cleanup $ do
    createDirectoryIfMissing True tempDir
    compiledStage1 <- compileEntryBootstrap entryPath
    case compiledStage1 of
      Left err ->
        pure (Left err)
      Right compiledJs -> do
        writeFileText stage1Path compiledJs
        (exitCode, stdoutText, stderrText) <-
          readProcessWithExitCode
            "bun"
            [hostedCompilerDemoPath, stage1Path, stage2CompilerPath, stage2OutputPath]
            ""
        pure $
          case exitCode of
            ExitSuccess ->
              if all (`T.isInfixOf` T.pack stdoutText) expectedChecks
                then Right ()
                else
                  Left $
                    singleDiagnostic
                      "E_PRIMARY_COMPILER_RUNTIME"
                      "The primary Clasp compiler runtime check did not reach a reproducible stage2 result."
                      [T.pack stdoutText]
            ExitFailure _ ->
              Left $
                singleDiagnostic
                  "E_PRIMARY_COMPILER_RUNTIME"
                  "The primary Clasp compiler runtime check failed."
                  [T.pack stderrText]
  where
    expectedChecks =
      [ "\"stage2MatchesStage1Snapshot\":true"
      , "\"stage2CompilerMatchesStage1Snapshot\":true"
      , "\"stage2CheckMatchesStage1\":true"
      , "\"stage2ExplainMatchesStage1\":true"
      , "\"stage2OutputMatchesStage1\":true"
      ]

hostedCompilerEntryPath :: FilePath
hostedCompilerEntryPath =
  normalise ("compiler" </> "hosted" </> "Main.clasp")

hostedCompilerDemoPath :: FilePath
hostedCompilerDemoPath =
  "compiler" </> "hosted" </> "demo.mjs"

compileEntryBootstrap :: FilePath -> IO (Either DiagnosticBundle Text)
compileEntryBootstrap entryPath = do
  checkedModule <- checkEntryBootstrap entryPath
  pure ((\modl -> emitModule (buildAirModule modl) (lowerModule modl)) <$> checkedModule)

writeFileText :: FilePath -> Text -> IO ()
writeFileText = TIO.writeFile
