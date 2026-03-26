{-# LANGUAGE OverloadedStrings #-}

import qualified Data.Text.IO as TIO
import System.Environment (getArgs, lookupEnv)

import Clasp.Compiler (renderHostedPrimaryEntrySource)
import Clasp.Diagnostic (renderDiagnosticBundle)

writeRenderedSource :: FilePath -> FilePath -> IO ()
writeRenderedSource entryPath outputPath = do
  sourceResult <- renderHostedPrimaryEntrySource entryPath
  case sourceResult of
    Left err ->
      error (show (renderDiagnosticBundle err))
    Right source ->
      TIO.writeFile outputPath source

main :: IO ()
main = do
  args <- getArgs
  envEntryPath <- lookupEnv "CLASP_RENDER_ENTRY_PATH"
  envOutputPath <- lookupEnv "CLASP_RENDER_OUTPUT_PATH"
  case args of
    [entryPath, outputPath] ->
      writeRenderedSource entryPath outputPath
    _ ->
      case (envEntryPath, envOutputPath) of
        (Just entryPath, Just outputPath) ->
          writeRenderedSource entryPath outputPath
        _ ->
          error "usage: runghc src/scripts/render-primary-source.hs <entry-path> <output-path>"
