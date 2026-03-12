module Clasp.Compiler
  ( airSource
  , airEntry
  , applySemanticEdit
  , contextSource
  , contextEntry
  , checkSource
  , checkEntry
  , compileSource
  , compileEntry
  , parseSource
  , renderAirEntryJson
  , renderAirSourceJson
  , renderContextEntryJson
  , renderContextSourceJson
  , semanticEditEntry
  , semanticEditSource
  , SemanticEdit (..)
  ) where

import Data.Text (Text)
import qualified Data.Text.Lazy as LT
import Clasp.Air (AirModule, buildAirModule, renderAirModuleJson)
import Clasp.Checker (checkModule)
import Clasp.ContextGraph (ContextGraph, buildContextGraph, renderContextGraphJson)
import Clasp.Core (CoreModule, SemanticEdit (..), applySemanticEdit)
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

compileSource :: FilePath -> Text -> Either DiagnosticBundle Text
compileSource path source = do
  modl <- checkSource path source
  pure (emitModule (lowerModule modl))

checkEntry :: FilePath -> IO (Either DiagnosticBundle CoreModule)
checkEntry entryPath = do
  loadedModule <- loadEntryModule entryPath
  pure (loadedModule >>= checkModule)

semanticEditEntry :: SemanticEdit -> FilePath -> IO (Either DiagnosticBundle CoreModule)
semanticEditEntry edit entryPath = do
  checkedModule <- checkEntry entryPath
  pure (checkedModule >>= applySemanticEdit edit)

compileEntry :: FilePath -> IO (Either DiagnosticBundle Text)
compileEntry entryPath = do
  checkedModule <- checkEntry entryPath
  pure (emitModule . lowerModule <$> checkedModule)
