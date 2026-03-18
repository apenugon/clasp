{-# LANGUAGE OverloadedStrings #-}

module Clasp.Diagnostic
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
import Clasp.Syntax
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
  , diagnosticFixHints :: [Text]
  , diagnosticRelatedSpans :: [DiagnosticRelated]
  }
  deriving (Eq, Show)

newtype DiagnosticBundle = DiagnosticBundle
  { diagnostics :: [Diagnostic]
  }
  deriving (Eq, Show)

diagnostic :: Text -> Text -> Maybe SourceSpan -> [Text] -> [DiagnosticRelated] -> Diagnostic
diagnostic code summary primarySpan details related =
  Diagnostic code summary primarySpan details (defaultFixHints code) related

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
      <> fmap ("- hint: " <>) (diagnosticFixHints err)
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
      , "fixHints" .= diagnosticFixHints err
      , "related" .= diagnosticRelatedSpans err
      ]

defaultFixHints :: Text -> [Text]
defaultFixHints code =
  case code of
    "E_PARSE" ->
      ["Check the syntax near the reported location and complete any missing delimiters, separators, or expressions."]
    "E_ORPHAN_SIGNATURE" ->
      ["Move the type signature so it appears directly above the declaration it annotates."]
    "E_DUPLICATE_SIGNATURE" ->
      ["Keep a single type signature for the declaration and remove the duplicate annotation."]
    "E_UNBOUND_NAME" ->
      ["Define the referenced name in scope, import it, or correct the spelling."]
    "E_UNKNOWN_CONSTRUCTOR" ->
      ["Use a constructor defined by the matched type, or correct the constructor name."]
    "E_UNKNOWN_FIELD" ->
      ["Use a field declared on the target record, or update the record type to include it."]
    "E_UNKNOWN_GUIDE_PARENT" ->
      ["Declare the parent guide before extending it, or correct the guide name."]
    "E_UNKNOWN_POLICY" ->
      ["Declare the referenced policy before use, or correct the policy name."]
    "E_UNKNOWN_PROJECTION_SOURCE" ->
      ["Point the projection at an existing record or route response type."]
    "E_UNKNOWN_PROJECTION_FIELD" ->
      ["Select a field that exists on the projection source, or update the source schema."]
    "E_UNKNOWN_RECORD" ->
      ["Use a declared record type, or rename the reference to an existing schema."]
    "E_UNKNOWN_ROUTE_HANDLER" ->
      ["Define the route handler first, or update the route to call an existing declaration."]
    "E_UNKNOWN_TYPE" ->
      ["Use a declared type name, or add the missing type declaration."]
    "E_ASSIGNMENT_TARGET" ->
      ["Assign only to mutable block locals, or change the binding so the updated name is introduced with `let mut` in the current scope."]
    "E_EMPTY_SUPERVISOR" ->
      ["Add at least one child workflow or supervisor to the supervisor declaration."]
    "E_FOR_ITERABLE" ->
      ["Iterate over a list value, or change the loop source so it produces a list."]
    "E_HOOK_HANDLER_TYPE" ->
      ["Make the hook handler accept the declared input schema and return the declared output schema."]
    "E_HOOK_TYPE" ->
      ["Declare hook input and output schemas with named record types."]
    "E_IF_BRANCH_TYPE" ->
      ["Make both `if` branches return the same type, or add annotations that force a shared result type."]
    "E_IF_CONDITION" ->
      ["Use a `Bool` condition in the `if`, or rewrite the condition so it evaluates to `true` or `false`."]
    "E_MULTIPLE_SUPERVISOR_PARENTS" ->
      ["Attach each workflow or child supervisor to exactly one parent supervisor."]
    "E_PRIMARY_COMPILER_RUNTIME" ->
      ["Fix the hosted compiler runtime failure, or rerun with `--compiler=bootstrap` while the hosted path is unavailable."]
    "E_PRIMARY_COMPILER_UNSUPPORTED" ->
      ["Use `--compiler=bootstrap` for sources the hosted compiler does not support yet, or switch to a supported entrypoint."]
    "E_RETURN_OUTSIDE_FUNCTION" ->
      ["Move the `return` into a function body, or rewrite the block as a plain expression."]
    "E_SQLITE_UNSAFE_DECL" ->
      ["Mark the foreign declaration as `unsafe sqlite`, or switch to a supported storage primitive."]
    "E_SQLITE_UNSAFE_ROW_CONTRACT" ->
      ["Use named record schemas for sqlite row inputs and outputs so the boundary contract stays explicit."]
    "E_STORAGE_BOUNDARY_TYPE" ->
      ["Wrap storage-facing inputs and outputs in named record schemas instead of bare primitive types."]
    "E_SUPERVISOR_CYCLE" ->
      ["Remove the cyclic supervisor edge so the hierarchy forms a tree."]
    "E_SUPERVISOR_SELF_REFERENCE" ->
      ["Remove the self-reference, or introduce a distinct child supervisor instead of reusing the same declaration."]
    "E_TOOL_SCHEMA_TYPE" ->
      ["Use named record schemas for tool inputs and outputs."]
    "E_UNKNOWN_AGENT_ROLE" ->
      ["Declare the referenced agent role before assigning it to an agent, or correct the role name."]
    "E_UNKNOWN_AGENT_ROLE_GUIDE" ->
      ["Declare the referenced guide before attaching it to the agent role, or correct the guide name."]
    "E_UNKNOWN_AGENT_ROLE_POLICY" ->
      ["Declare the referenced policy before attaching it to the agent role, or correct the policy name."]
    "E_UNKNOWN_DOMAIN_EVENT_OBJECT" ->
      ["Point the domain event at an existing domain object declaration."]
    "E_UNKNOWN_DOMAIN_EVENT_SCHEMA" ->
      ["Use a declared record schema for the domain event payload."]
    "E_UNKNOWN_DOMAIN_OBJECT_SCHEMA" ->
      ["Use a declared record schema for the domain object state."]
    "E_UNKNOWN_EXPERIMENT_GOAL" ->
      ["Reference a declared goal from the experiment, or correct the goal name."]
    "E_UNKNOWN_FEEDBACK_OBJECT" ->
      ["Reference an existing domain object from the feedback declaration."]
    "E_UNKNOWN_FEEDBACK_SCHEMA" ->
      ["Use a declared record schema for the feedback payload."]
    "E_UNKNOWN_GOAL_METRIC" ->
      ["Reference a declared metric from the goal, or correct the metric name."]
    "E_UNKNOWN_HOOK_HANDLER" ->
      ["Define the hook handler first, or update the hook to call an existing declaration."]
    "E_UNKNOWN_MERGE_GATE_VERIFIER" ->
      ["Reference a declared verifier from the merge gate, or correct the verifier name."]
    "E_UNKNOWN_METRIC_OBJECT" ->
      ["Reference an existing domain object from the metric declaration."]
    "E_UNKNOWN_METRIC_SCHEMA" ->
      ["Use a declared record schema for the metric input payload."]
    "E_UNKNOWN_ROLLOUT_EXPERIMENT" ->
      ["Reference a declared experiment from the rollout, or correct the experiment name."]
    "E_UNKNOWN_SUPERVISOR_CHILD" ->
      ["Reference an existing workflow or supervisor as the child entry, or correct the child name."]
    "E_UNKNOWN_SUPERVISOR_WORKFLOW" ->
      ["Reference a declared workflow from the supervisor, or correct the workflow name."]
    "E_UNKNOWN_TOOLSERVER" ->
      ["Declare the referenced tool server before binding tools to it, or correct the server name."]
    "E_UNKNOWN_TOOLSERVER_POLICY" ->
      ["Declare the referenced policy before attaching it to the tool server, or correct the policy name."]
    "E_UNKNOWN_VERIFIER_TOOL" ->
      ["Reference a declared tool from the verifier, or correct the tool name."]
    "E_UNKNOWN_WORKFLOW_CONSTRAINT" ->
      ["Define the workflow constraint handler first, or update the workflow to use an existing declaration."]
    "E_WORKFLOW_CONSTRAINT_TYPE" ->
      ["Make each workflow constraint handler accept the workflow state schema and return `Bool`."]
    "E_WORKFLOW_STATE_TYPE" ->
      ["Declare workflow state with a named record schema."]
    "E_IMPORT_NOT_FOUND" ->
      ["Create the imported module, or update the import path to an existing file."]
    "E_IMPORT_NAME" ->
      ["Make the imported module name match the file and import statement."]
    "E_IMPORT_CYCLE" ->
      ["Break the import cycle by extracting shared declarations into a separate module."]
    "E_FOREIGN_PACKAGE_DECLARATION_NOT_FOUND" ->
      ["Add the missing exported declaration to the foreign package, or update the import to target an existing declaration."]
    "E_FOREIGN_PACKAGE_EXPORT_NOT_FOUND" ->
      ["Export the requested value from the foreign package, or update the import to a valid export name."]
    "E_FOREIGN_PACKAGE_SIGNATURE_MISMATCH" ->
      ["Make the Clasp foreign declaration signature match the runtime package export."]
    "E_SEMANTIC_EDIT_TARGET" ->
      ["Choose an existing declaration or schema as the semantic edit target."]
    "E_SEMANTIC_EDIT_CONFLICT" ->
      ["Pick a new name that does not collide with another declaration or schema in scope."]
    "E_INTERNAL" ->
      ["This indicates a compiler bug; reduce the input if possible and inspect the surrounding declarations."]
    other
      | "E_DUPLICATE_" `T.isPrefixOf` other ->
          ["Rename or remove the duplicate definition so each name is declared only once in its scope."]
      | other `elem` typeMismatchCodes ->
          ["Align the expression and annotation types, or add annotations that make the intended types explicit."]
      | other `elem` arityCodes ->
          ["Update the call or pattern so the number of arguments matches the declared shape."]
      | other `elem` fieldCodes ->
          ["Make the record fields line up with the schema by adding missing fields and removing unknown ones."]
      | other `elem` routeCodes ->
          ["Make the route contract and handler agree on request and response shapes."]
      | other `elem` viewCodes ->
          ["Adjust the view so it only uses allowed tags, attributes, handlers, and route targets."]
      | other `elem` jsonCodes ->
          ["Update the schema or payload so the JSON shape matches the declared record fields and types."]
      | otherwise ->
          ["Review the diagnostic details and the highlighted code, then update the program to satisfy the reported constraint."]
  where
    typeMismatchCodes =
      [ "E_ARITY_MISMATCH"
      , "E_CANNOT_INFER"
      , "E_DISCLOSURE_POLICY"
      , "E_EMPTY_MATCH"
      , "E_EQUALITY_OPERAND"
      , "E_FIELD_ACCESS"
      , "E_FOREIGN_TYPE"
      , "E_GUIDE_CYCLE"
      , "E_INFINITE_TYPE"
      , "E_INTEGER_COMPARISON_OPERAND"
      , "E_LIST_ITEM_TYPE"
      , "E_MATCH_RESULT_TYPE"
      , "E_MATCH_SUBJECT"
      , "E_NONEXHAUSTIVE_MATCH"
      , "E_NOT_A_FUNCTION"
      , "E_PATTERN_TYPE_MISMATCH"
      , "E_SCHEMA_FIELD_TYPE"
      , "E_TYPE_MISMATCH"
      ]
    arityCodes =
      [ "E_CALL_ARITY"
      , "E_PATTERN_ARITY"
      ]
    fieldCodes =
      [ "E_RECORD_MISSING_FIELDS"
      , "E_RECORD_UNKNOWN_FIELDS"
      ]
    routeCodes =
      [ "E_REDIRECT_TARGET"
      , "E_ROUTE_HANDLER_TYPE"
      , "E_ROUTE_TYPE"
      ]
    viewCodes =
      [ "E_UNSAFE_VIEW_ESCAPE"
      , "E_VIEW_FORM_METHOD"
      , "E_VIEW_INPUT"
      , "E_VIEW_LINK_TARGET"
      , "E_VIEW_STYLE_REF"
      , "E_VIEW_TAG"
      ]
    jsonCodes =
      [ "E_JSON_DECODE"
      , "E_JSON_TYPE"
      ]
