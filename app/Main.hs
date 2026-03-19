{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Aeson (object, (.=))
import Data.Aeson.Text (encodeToLazyText)
import Data.List (stripPrefix)
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy.IO as LTIO
import System.Environment (getArgs)
import System.Exit (die, exitFailure)
import System.FilePath (replaceExtension)
import System.IO (hPutStrLn, stderr)
import Clasp.Compiler
  ( CompilerImplementation (..)
  , CompilerPreference (..)
  , checkEntryWithPreference
  , compileEntryWithPreference
  , explainEntryWithPreference
  , formatSource
  , nativeEntryBootstrap
  , parseSource
  , renderAirEntryJsonWithPreference
  , renderContextEntryJsonWithPreference
  , renderNativeEntryWithPreference
  )
import Clasp.Diagnostic (DiagnosticBundle, renderDiagnosticBundle, renderDiagnosticBundleJson)
import Clasp.Native (renderNativeModuleImageJson)

data OutputFormat
  = Pretty
  | Json

main :: IO ()
main = do
  rawArgs <- getArgs
  let (format, compilerPreference, args) = parseCliOptions rawArgs
  case args of
    ["parse", inputPath] ->
      runParse format inputPath
    ["format", inputPath] ->
      runFormat format inputPath
    ["check", inputPath] ->
      runCheck format compilerPreference inputPath
    ["explain", inputPath] ->
      runExplain format compilerPreference inputPath
    ["air", inputPath] ->
      runAir format compilerPreference inputPath Nothing
    ["air", inputPath, "-o", outputPath] ->
      runAir format compilerPreference inputPath (Just outputPath)
    ["air", "-o", outputPath, inputPath] ->
      runAir format compilerPreference inputPath (Just outputPath)
    ["context", inputPath] ->
      runContext format compilerPreference inputPath Nothing
    ["context", inputPath, "-o", outputPath] ->
      runContext format compilerPreference inputPath (Just outputPath)
    ["context", "-o", outputPath, inputPath] ->
      runContext format compilerPreference inputPath (Just outputPath)
    ["compile", inputPath] ->
      runCompile format compilerPreference inputPath Nothing
    ["compile", inputPath, "-o", outputPath] ->
      runCompile format compilerPreference inputPath (Just outputPath)
    ["compile", "-o", outputPath, inputPath] ->
      runCompile format compilerPreference inputPath (Just outputPath)
    ["native", inputPath] ->
      runNative format compilerPreference inputPath Nothing
    ["native", inputPath, "-o", outputPath] ->
      runNative format compilerPreference inputPath (Just outputPath)
    ["native", "-o", outputPath, inputPath] ->
      runNative format compilerPreference inputPath (Just outputPath)
    _ ->
      die usage

parseCliOptions :: [String] -> (OutputFormat, CompilerPreference, [String])
parseCliOptions args =
  foldl parseOption (Pretty, CompilerPreferenceClasp, []) args
  where
    parseOption (format, preference, remaining) arg =
      case arg of
        "--json" ->
          (Json, preference, remaining)
        _ ->
          case stripPrefix "--compiler=" arg of
            Just "clasp" ->
              (format, CompilerPreferenceClasp, remaining)
            Just "bootstrap" ->
              (format, CompilerPreferenceBootstrap, remaining)
            Just _ ->
              (format, preference, remaining <> [arg])
            Nothing ->
              (format, preference, remaining <> [arg])

runParse :: OutputFormat -> FilePath -> IO ()
runParse format inputPath = do
  source <- TIO.readFile inputPath
  case parseSource inputPath source of
    Left err -> do
      writeFailure format err
      exitFailure
    Right ast ->
      case format of
        Pretty ->
          print ast
        Json ->
          LTIO.putStrLn $
            encodeToLazyText $
              object
                [ "status" .= ("ok" :: String)
                , "command" .= ("parse" :: String)
                , "input" .= inputPath
                ]

runFormat :: OutputFormat -> FilePath -> IO ()
runFormat format inputPath = do
  source <- TIO.readFile inputPath
  case formatSource inputPath source of
    Left err -> do
      writeFailure format err
      exitFailure
    Right formattedSource ->
      case format of
        Pretty ->
          TIO.putStrLn formattedSource
        Json ->
          LTIO.putStrLn $
            encodeToLazyText $
              object
                [ "status" .= ("ok" :: String)
                , "command" .= ("format" :: String)
                , "input" .= inputPath
                , "source" .= formattedSource
                ]

runCheck :: OutputFormat -> CompilerPreference -> FilePath -> IO ()
runCheck format compilerPreference inputPath = do
  (implementation, result) <- checkEntryWithPreference compilerPreference inputPath
  case result of
    Left err -> do
      writeFailure format err
      exitFailure
    Right _ ->
      case format of
        Pretty ->
          hPutStrLn stderr ("Checked " <> inputPath <> " with " <> renderCompilerImplementation implementation)
        Json ->
          LTIO.putStrLn $
            encodeToLazyText $
              object
                [ "status" .= ("ok" :: String)
                , "command" .= ("check" :: String)
                , "input" .= inputPath
                , "implementation" .= renderCompilerImplementation implementation
                ]

runExplain :: OutputFormat -> CompilerPreference -> FilePath -> IO ()
runExplain format compilerPreference inputPath = do
  (implementation, result) <- explainEntryWithPreference compilerPreference inputPath
  case result of
    Left err -> do
      writeFailure format err
      exitFailure
    Right explanation ->
      case format of
        Pretty ->
          TIO.putStrLn explanation >> hPutStrLn stderr ("Explained " <> inputPath <> " with " <> renderCompilerImplementation implementation)
        Json ->
          LTIO.putStrLn $
            encodeToLazyText $
              object
                [ "status" .= ("ok" :: String)
                , "command" .= ("explain" :: String)
                , "input" .= inputPath
                , "implementation" .= renderCompilerImplementation implementation
                , "explanation" .= explanation
                ]

runAir :: OutputFormat -> CompilerPreference -> FilePath -> Maybe FilePath -> IO ()
runAir format compilerPreference inputPath outputPath = do
  result <- renderAirEntryJsonWithPreference compilerPreference inputPath
  case result of
    Left err -> do
      writeFailure format err
      exitFailure
    Right airJson -> do
      let resolvedOutput = maybe (replaceExtension inputPath "air.json") id outputPath
      LTIO.writeFile resolvedOutput airJson
      case format of
        Pretty ->
          hPutStrLn stderr ("Wrote " <> resolvedOutput)
        Json ->
          LTIO.putStrLn $
            encodeToLazyText $
              object
                [ "status" .= ("ok" :: String)
                , "command" .= ("air" :: String)
                , "input" .= inputPath
                , "output" .= resolvedOutput
                ]

runContext :: OutputFormat -> CompilerPreference -> FilePath -> Maybe FilePath -> IO ()
runContext format compilerPreference inputPath outputPath = do
  result <- renderContextEntryJsonWithPreference compilerPreference inputPath
  case result of
    Left err -> do
      writeFailure format err
      exitFailure
    Right contextJson -> do
      let resolvedOutput = maybe (replaceExtension inputPath "context.json") id outputPath
      LTIO.writeFile resolvedOutput contextJson
      case format of
        Pretty ->
          hPutStrLn stderr ("Wrote " <> resolvedOutput)
        Json ->
          LTIO.putStrLn $
            encodeToLazyText $
              object
                [ "status" .= ("ok" :: String)
                , "command" .= ("context" :: String)
                , "input" .= inputPath
                , "output" .= resolvedOutput
                ]

runCompile :: OutputFormat -> CompilerPreference -> FilePath -> Maybe FilePath -> IO ()
runCompile format compilerPreference inputPath outputPath = do
  (implementation, result) <- compileEntryWithPreference compilerPreference inputPath
  case result of
    Left err -> do
      writeFailure format err
      exitFailure
    Right js -> do
      let resolvedOutput = maybe (replaceExtension inputPath "js") id outputPath
      TIO.writeFile resolvedOutput js
      case format of
        Pretty ->
          hPutStrLn stderr ("Wrote " <> resolvedOutput <> " with " <> renderCompilerImplementation implementation)
        Json ->
          LTIO.putStrLn $
            encodeToLazyText $
              object
                [ "status" .= ("ok" :: String)
                , "command" .= ("compile" :: String)
                , "input" .= inputPath
                , "implementation" .= renderCompilerImplementation implementation
                , "output" .= resolvedOutput
                ]

runNative :: OutputFormat -> CompilerPreference -> FilePath -> Maybe FilePath -> IO ()
runNative format compilerPreference inputPath outputPath = do
  (implementation, result) <- renderNativeEntryWithPreference compilerPreference inputPath
  case result of
    Left err -> do
      writeFailure format err
      exitFailure
    Right nativeIr -> do
      let resolvedOutput = maybe (replaceExtension inputPath "native.ir") id outputPath
      TIO.writeFile resolvedOutput nativeIr
      imageOutputPath <-
        case implementation of
          CompilerImplementationBootstrap -> do
            nativeModuleResult <- nativeEntryBootstrap inputPath
            case nativeModuleResult of
              Left err -> do
                writeFailure format err
                exitFailure
              Right nativeModule -> do
                let resolvedImageOutput = replaceExtension resolvedOutput "native.image.json"
                LTIO.writeFile resolvedImageOutput (renderNativeModuleImageJson nativeModule)
                pure (Just resolvedImageOutput)
          CompilerImplementationClasp ->
            pure Nothing
      case format of
        Pretty ->
          do
            hPutStrLn stderr ("Wrote " <> resolvedOutput <> " with " <> renderCompilerImplementation implementation)
            case imageOutputPath of
              Just resolvedImageOutput ->
                hPutStrLn stderr ("Wrote " <> resolvedImageOutput <> " with " <> renderCompilerImplementation implementation)
              Nothing ->
                pure ()
        Json ->
          LTIO.putStrLn $
            encodeToLazyText $
              object
                [ "status" .= ("ok" :: String)
                , "command" .= ("native" :: String)
                , "input" .= inputPath
                , "implementation" .= renderCompilerImplementation implementation
                , "output" .= resolvedOutput
                , "image" .= imageOutputPath
                ]

writeFailure :: OutputFormat -> DiagnosticBundle -> IO ()
writeFailure format err =
  case format of
    Pretty ->
      TIO.hPutStrLn stderr (renderDiagnosticBundle err)
    Json ->
      LTIO.hPutStrLn stderr (renderDiagnosticBundleJson err)

usage :: String
usage =
  unlines
    [ "claspc usage:"
    , "  claspc parse <input.clasp> [--json]"
    , "  claspc format <input.clasp> [--json]"
    , "  claspc check <input.clasp> [--json] [--compiler=clasp|bootstrap]"
    , "  claspc explain <input.clasp> [--json] [--compiler=clasp|bootstrap]"
    , "  claspc air <input.clasp> [-o output.air.json] [--json] [--compiler=clasp|bootstrap]"
    , "  claspc context <input.clasp> [-o output.context.json] [--json] [--compiler=clasp|bootstrap]"
    , "  claspc compile <input.clasp> [-o output.js] [--json] [--compiler=clasp|bootstrap]"
    , "  claspc native <input.clasp> [-o output.native.ir] [--json] [--compiler=clasp|bootstrap]"
    ]

renderCompilerImplementation :: CompilerImplementation -> String
renderCompilerImplementation implementation =
  case implementation of
    CompilerImplementationClasp ->
      "clasp"
    CompilerImplementationBootstrap ->
      "haskell-bootstrap"
