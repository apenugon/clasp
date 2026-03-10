{-# LANGUAGE OverloadedStrings #-}

module Weft.Diagnostic
  ( Diagnostic (..)
  , DiagnosticBundle (..)
  , diagnostic
  , renderDiagnosticBundle
  , singleDiagnostic
  ) where

import Data.Text (Text)
import qualified Data.Text as T

data Diagnostic = Diagnostic
  { diagnosticCode :: Text
  , diagnosticSummary :: Text
  , diagnosticDetails :: [Text]
  }
  deriving (Eq, Show)

newtype DiagnosticBundle = DiagnosticBundle
  { diagnostics :: [Diagnostic]
  }
  deriving (Eq, Show)

diagnostic :: Text -> Text -> [Text] -> Diagnostic
diagnostic = Diagnostic

singleDiagnostic :: Text -> Text -> [Text] -> DiagnosticBundle
singleDiagnostic code summary details =
  DiagnosticBundle [diagnostic code summary details]

renderDiagnosticBundle :: DiagnosticBundle -> Text
renderDiagnosticBundle (DiagnosticBundle errs) =
  T.intercalate "\n\n" (fmap renderDiagnostic errs)

renderDiagnostic :: Diagnostic -> Text
renderDiagnostic err =
  T.unlines $
    [ diagnosticCode err <> ": " <> diagnosticSummary err
    ]
      <> fmap ("- " <>) (diagnosticDetails err)

