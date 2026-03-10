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
import Weft.Compiler (checkEntry, compileEntry, parseSource)
import Weft.Diagnostic (DiagnosticBundle, renderDiagnosticBundle, renderDiagnosticBundleJson)

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
    [ "weftc usage:"
    , "  weftc parse <input.weft> [--json]"
    , "  weftc check <input.weft> [--json]"
    , "  weftc compile <input.weft> [-o output.js] [--json]"
    ]
