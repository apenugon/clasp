module Clasp.Compiler
  ( airSource
  , checkSource
  , checkEntry
  , compileSource
  , compileEntry
  , parseSource
  , renderAirSourceJson
  ) where

import Data.Text (Text)
import qualified Data.Text.Lazy as LT
import Clasp.Air (AirModule, buildAirModule, renderAirModuleJson)
import Clasp.Checker (checkModule)
import Clasp.Core (CoreModule)
import Clasp.Diagnostic (DiagnosticBundle)
import Clasp.Emit.JavaScript (emitModule)
import Clasp.Loader (loadEntryModule)
import Clasp.Lower (lowerModule)
import Clasp.Parser (parseModule)
import Clasp.Syntax (Module)

parseSource :: FilePath -> Text -> Either DiagnosticBundle Module
parseSource = parseModule

checkSource :: FilePath -> Text -> Either DiagnosticBundle CoreModule
checkSource path source = do
  modl <- parseModule path source
  checkModule modl

airSource :: FilePath -> Text -> Either DiagnosticBundle AirModule
airSource path source =
  buildAirModule <$> checkSource path source

renderAirSourceJson :: FilePath -> Text -> Either DiagnosticBundle LT.Text
renderAirSourceJson path source =
  renderAirModuleJson <$> airSource path source

compileSource :: FilePath -> Text -> Either DiagnosticBundle Text
compileSource path source = do
  modl <- checkSource path source
  pure (emitModule (lowerModule modl))

checkEntry :: FilePath -> IO (Either DiagnosticBundle CoreModule)
checkEntry entryPath = do
  loadedModule <- loadEntryModule entryPath
  pure (loadedModule >>= checkModule)

compileEntry :: FilePath -> IO (Either DiagnosticBundle Text)
compileEntry entryPath = do
  checkedModule <- checkEntry entryPath
  pure (emitModule . lowerModule <$> checkedModule)
