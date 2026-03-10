{-# LANGUAGE OverloadedStrings #-}

module Weft.Diagnostic
  ( Diagnostic (..)
  , DiagnosticBundle (..)
  , DiagnosticRelated (..)
  , diagnostic
  , diagnosticBundle
  , diagnosticRelated
  , renderDiagnosticBundle
  , renderDiagnosticBundleJson
  , singleDiagnostic
  , singleDiagnosticAt
  ) where

import Data.Aeson
  ( ToJSON (toJSON)
  , object
  , (.=)
  )
import Data.Aeson.Text (encodeToLazyText)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import Weft.Syntax
  ( Position (..)
  , SourceSpan (..)
  )

data DiagnosticRelated = DiagnosticRelated
  { relatedMessage :: Text
  , relatedSpan :: SourceSpan
  }
  deriving (Eq, Show)

data Diagnostic = Diagnostic
  { diagnosticCode :: Text
  , diagnosticSummary :: Text
  , diagnosticPrimarySpan :: Maybe SourceSpan
  , diagnosticDetails :: [Text]
  , diagnosticRelatedSpans :: [DiagnosticRelated]
  }
  deriving (Eq, Show)

newtype DiagnosticBundle = DiagnosticBundle
  { diagnostics :: [Diagnostic]
  }
  deriving (Eq, Show)

diagnostic :: Text -> Text -> Maybe SourceSpan -> [Text] -> [DiagnosticRelated] -> Diagnostic
diagnostic = Diagnostic

diagnosticRelated :: Text -> SourceSpan -> DiagnosticRelated
diagnosticRelated = DiagnosticRelated

diagnosticBundle :: [Diagnostic] -> DiagnosticBundle
diagnosticBundle = DiagnosticBundle

singleDiagnostic :: Text -> Text -> [Text] -> DiagnosticBundle
singleDiagnostic code summary details =
  DiagnosticBundle [diagnostic code summary Nothing details []]

singleDiagnosticAt :: Text -> Text -> SourceSpan -> [Text] -> DiagnosticBundle
singleDiagnosticAt code summary primarySpan details =
  DiagnosticBundle [diagnostic code summary (Just primarySpan) details []]

renderDiagnosticBundle :: DiagnosticBundle -> Text
renderDiagnosticBundle (DiagnosticBundle errs) =
  T.intercalate "\n\n" (fmap renderDiagnostic errs)

renderDiagnosticBundleJson :: DiagnosticBundle -> LT.Text
renderDiagnosticBundleJson bundle =
  encodeToLazyText $
    object
      [ "status" .= ("error" :: Text)
      , "diagnostics" .= diagnostics bundle
      ]

renderDiagnostic :: Diagnostic -> Text
renderDiagnostic err =
  T.unlines $
    [ renderHeader err
    ]
      <> fmap ("- " <>) (diagnosticDetails err)
      <> fmap renderRelated (diagnosticRelatedSpans err)

renderHeader :: Diagnostic -> Text
renderHeader err =
  case diagnosticPrimarySpan err of
    Just span' ->
      diagnosticCode err <> " at " <> renderSourceSpan span' <> ": " <> diagnosticSummary err
    Nothing ->
      diagnosticCode err <> ": " <> diagnosticSummary err

renderRelated :: DiagnosticRelated -> Text
renderRelated related =
  "- related " <> relatedMessage related <> ": " <> renderSourceSpan (relatedSpan related)

renderSourceSpan :: SourceSpan -> Text
renderSourceSpan span' =
  sourceSpanFile span'
    <> ":"
    <> renderPosition (sourceSpanStart span')
    <> "-"
    <> renderPosition (sourceSpanEnd span')

renderPosition :: Position -> Text
renderPosition position =
  T.pack (show (positionLine position))
    <> ":"
    <> T.pack (show (positionColumn position))

instance ToJSON DiagnosticRelated where
  toJSON related =
    object
      [ "message" .= relatedMessage related
      , "span" .= relatedSpan related
      ]

instance ToJSON Diagnostic where
  toJSON err =
    object
      [ "code" .= diagnosticCode err
      , "summary" .= diagnosticSummary err
      , "primarySpan" .= diagnosticPrimarySpan err
      , "details" .= diagnosticDetails err
      , "related" .= diagnosticRelatedSpans err
      ]
