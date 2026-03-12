{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Aeson (object, (.=))
import Data.Aeson.Text (encodeToLazyText)
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy.IO as LTIO
import System.Environment (getArgs)
import System.Exit (die, exitFailure)
import System.FilePath (replaceExtension)
import System.IO (hPutStrLn, stderr)
import Clasp.Compiler (checkEntry, compileEntry, explainEntry, parseSource, renderAirEntryJson, renderContextEntryJson)
import Clasp.Diagnostic (DiagnosticBundle, renderDiagnosticBundle, renderDiagnosticBundleJson)

data OutputFormat
  = Pretty
  | Json

main :: IO ()
main = do
  rawArgs <- getArgs
  let (format, args) = parseOutputFormat rawArgs
  case args of
    ["parse", inputPath] ->
      runParse format inputPath
    ["check", inputPath] ->
      runCheck format inputPath
    ["explain", inputPath] ->
      runExplain format inputPath
    ["air", inputPath] ->
      runAir format inputPath Nothing
    ["air", inputPath, "-o", outputPath] ->
      runAir format inputPath (Just outputPath)
    ["air", "-o", outputPath, inputPath] ->
      runAir format inputPath (Just outputPath)
    ["context", inputPath] ->
      runContext format inputPath Nothing
    ["context", inputPath, "-o", outputPath] ->
      runContext format inputPath (Just outputPath)
    ["context", "-o", outputPath, inputPath] ->
      runContext format inputPath (Just outputPath)
    ["compile", inputPath] ->
      runCompile format inputPath Nothing
    ["compile", inputPath, "-o", outputPath] ->
      runCompile format inputPath (Just outputPath)
    ["compile", "-o", outputPath, inputPath] ->
      runCompile format inputPath (Just outputPath)
    _ ->
      die usage

parseOutputFormat :: [String] -> (OutputFormat, [String])
parseOutputFormat args =
  if "--json" `elem` args
    then (Json, filter (/= "--json") args)
    else (Pretty, args)

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

runCheck :: OutputFormat -> FilePath -> IO ()
runCheck format inputPath = do
  result <- checkEntry inputPath
  case result of
    Left err -> do
      writeFailure format err
      exitFailure
    Right _ ->
      case format of
        Pretty ->
          hPutStrLn stderr ("Checked " <> inputPath)
        Json ->
          LTIO.putStrLn $
            encodeToLazyText $
              object
                [ "status" .= ("ok" :: String)
                , "command" .= ("check" :: String)
                , "input" .= inputPath
                ]

runExplain :: OutputFormat -> FilePath -> IO ()
runExplain format inputPath = do
  result <- explainEntry inputPath
  case result of
    Left err -> do
      writeFailure format err
      exitFailure
    Right explanation ->
      case format of
        Pretty ->
          TIO.putStrLn explanation
        Json ->
          LTIO.putStrLn $
            encodeToLazyText $
              object
                [ "status" .= ("ok" :: String)
                , "command" .= ("explain" :: String)
                , "input" .= inputPath
                , "explanation" .= explanation
                ]

runAir :: OutputFormat -> FilePath -> Maybe FilePath -> IO ()
runAir format inputPath outputPath = do
  result <- renderAirEntryJson inputPath
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

runContext :: OutputFormat -> FilePath -> Maybe FilePath -> IO ()
runContext format inputPath outputPath = do
  result <- renderContextEntryJson inputPath
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

runCompile :: OutputFormat -> FilePath -> Maybe FilePath -> IO ()
runCompile format inputPath outputPath = do
  result <- compileEntry inputPath
  case result of
    Left err -> do
      writeFailure format err
      exitFailure
    Right js -> do
      let resolvedOutput = maybe (replaceExtension inputPath "js") id outputPath
      TIO.writeFile resolvedOutput js
      case format of
        Pretty ->
          hPutStrLn stderr ("Wrote " <> resolvedOutput)
        Json ->
          LTIO.putStrLn $
            encodeToLazyText $
              object
                [ "status" .= ("ok" :: String)
                , "command" .= ("compile" :: String)
                , "input" .= inputPath
                , "output" .= resolvedOutput
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
    , "  claspc check <input.clasp> [--json]"
    , "  claspc explain <input.clasp> [--json]"
    , "  claspc air <input.clasp> [-o output.air.json] [--json]"
    , "  claspc context <input.clasp> [-o output.context.json] [--json]"
    , "  claspc compile <input.clasp> [-o output.js] [--json]"
    ]
