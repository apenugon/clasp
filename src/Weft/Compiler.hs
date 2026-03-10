module Weft.Compiler
  ( checkSource
  , compileSource
  , parseSource
  ) where

import Data.Text (Text)
import Weft.Checker (checkModule)
import Weft.Core (CoreModule)
import Weft.Diagnostic (DiagnosticBundle)
import Weft.Emit.JavaScript (emitModule)
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
