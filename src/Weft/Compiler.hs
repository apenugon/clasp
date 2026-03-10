module Weft.Compiler
  ( checkSource
  , compileSource
  , parseSource
  ) where

import Data.Text (Text)
import Weft.Checker (TypeEnv, checkModule)
import Weft.Diagnostic (DiagnosticBundle)
import Weft.Emit.JavaScript (emitModule)
import Weft.Parser (parseModule)
import Weft.Syntax (Module)

parseSource :: FilePath -> Text -> Either DiagnosticBundle Module
parseSource = parseModule

checkSource :: FilePath -> Text -> Either DiagnosticBundle TypeEnv
checkSource path source = do
  modl <- parseModule path source
  checkModule modl

compileSource :: FilePath -> Text -> Either DiagnosticBundle Text
compileSource path source = do
  modl <- parseModule path source
  _ <- checkModule modl
  pure (emitModule modl)
