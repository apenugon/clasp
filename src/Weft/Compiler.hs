module Weft.Compiler
  ( checkSource
  , checkEntry
  , compileSource
  , compileEntry
  , parseSource
  ) where

import Data.Text (Text)
import Weft.Checker (checkModule)
import Weft.Core (CoreModule)
import Weft.Diagnostic (DiagnosticBundle)
import Weft.Emit.JavaScript (emitModule)
import Weft.Loader (loadEntryModule)
import Weft.Lower (lowerModule)
import Weft.Parser (parseModule)
import Weft.Syntax (Module)

parseSource :: FilePath -> Text -> Either DiagnosticBundle Module
parseSource = parseModule

checkSource :: FilePath -> Text -> Either DiagnosticBundle CoreModule
checkSource path source = do
  modl <- parseModule path source
  checkModule modl

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
