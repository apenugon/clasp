{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (die, exitFailure)
import System.FilePath (replaceExtension)
import System.IO (hPutStrLn, stderr)
import Weft.Compiler (checkSource, compileSource, parseSource)
import Weft.Diagnostic (renderDiagnosticBundle)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["parse", inputPath] ->
      runParse inputPath
    ["check", inputPath] ->
      runCheck inputPath
    ["compile", inputPath] ->
      runCompile inputPath Nothing
    ["compile", inputPath, "-o", outputPath] ->
      runCompile inputPath (Just outputPath)
    ["compile", "-o", outputPath, inputPath] ->
      runCompile inputPath (Just outputPath)
    _ ->
      die usage

runParse :: FilePath -> IO ()
runParse inputPath = do
  source <- TIO.readFile inputPath
  case parseSource inputPath source of
    Left err -> do
      TIO.hPutStrLn stderr (renderDiagnosticBundle err)
      exitFailure
    Right ast ->
      print ast

runCheck :: FilePath -> IO ()
runCheck inputPath = do
  source <- TIO.readFile inputPath
  case checkSource inputPath source of
    Left err -> do
      TIO.hPutStrLn stderr (renderDiagnosticBundle err)
      exitFailure
    Right _ ->
      hPutStrLn stderr ("Checked " <> inputPath)

runCompile :: FilePath -> Maybe FilePath -> IO ()
runCompile inputPath outputPath = do
  source <- TIO.readFile inputPath
  case compileSource inputPath source of
    Left err -> do
      TIO.hPutStrLn stderr (renderDiagnosticBundle err)
      exitFailure
    Right js -> do
      let resolvedOutput = maybe (replaceExtension inputPath "js") id outputPath
      TIO.writeFile resolvedOutput js
      hPutStrLn stderr ("Wrote " <> resolvedOutput)

usage :: String
usage =
  unlines
    [ "weftc usage:"
    , "  weftc parse <input.weft>"
    , "  weftc check <input.weft>"
    , "  weftc compile <input.weft> [-o output.js]"
    ]
