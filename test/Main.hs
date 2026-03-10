{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (finally)
import Control.Monad (when)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as LT
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , removePathForcibly
  )
import System.FilePath ((</>), takeDirectory)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit
  ( Assertion
  , assertBool
  , assertEqual
  , assertFailure
  , testCase
  )
import Clasp.Compiler (checkEntry, checkSource, compileEntry, compileSource, parseSource)
import Clasp.Diagnostic
  ( Diagnostic (..)
  , DiagnosticBundle (..)
  , DiagnosticFixHint (..)
  , renderDiagnosticBundle
  , renderDiagnosticBundleJson
  )
import Clasp.Lower
  ( LowerDecl (..)
  , LowerExpr (..)
  , LowerMatchBranch (..)
  , LowerModule (..)
  , LowerRecordField (..)
  , lowerModule
  )
import Clasp.Syntax
  ( ConstructorDecl (..)
  , Decl (..)
  , Expr (..)
  , ForeignDecl (..)
  , IntComparisonOp (..)
  , LetBinding (..)
  , MatchBranch (..)
  , Module (..)
  , ModuleName (..)
  , Pattern (..)
  , PatternBinder (..)
  , Position (..)
  , RecordDecl (..)
  , RecordFieldDecl (..)
  , RouteDecl (..)
  , RouteMethod (..)
  , SourceSpan (..)
  , Type (..)
  , TypeDecl (..)
  )

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "clasp-compiler"
    [ parserTests
    , checkerTests
    , diagnosticTests
    , lowerTests
    , compileTests
    ]

listExamplePath :: FilePath
listExamplePath = "examples/lists.clasp"

parserTests :: TestTree
parserTests =
  testGroup
    "parser"
    [ testCase "parses the list example module" $ do
        source <- TIO.readFile listExamplePath
        case parseSource listExamplePath source of
          Left err ->
            assertFailure ("expected list example parse success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            assertEqual "module name" (ModuleName "Main") (moduleName modl)
            assertEqual "record decl count" 2 (length (moduleRecordDecls modl))
            case findDecl "defaultBatch" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  ERecord _ "Batch" _ ->
                    pure ()
                  other ->
                    assertFailure ("expected Batch record literal, got " <> show other)
              Nothing ->
                assertFailure "expected defaultBatch declaration"
    , testCase "parses declaration annotations with spans" $
        case parseSource "inline" annotatedIdentitySource of
          Left err ->
            assertFailure ("expected parse success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            assertEqual "module name" (ModuleName "Main") (moduleName modl)
            assertEqual "type decl count" 0 (length (moduleTypeDecls modl))
            case moduleDecls modl of
              [decl] -> do
                assertEqual "decl name" "id" (declName decl)
                assertEqual "annotation" (Just (TFunction [TStr] TStr)) (declAnnotation decl)
                assertEqual "param names" ["x"] (declParams decl)
                assertEqual "annotation line" (Just 3) (positionLine . sourceSpanStart <$> declAnnotationSpan decl)
                case declBody decl of
                  EVar span' "x" ->
                    assertEqual "body variable line" 4 (positionLine (sourceSpanStart span'))
                  _ ->
                    assertFailure "expected variable expression body"
              other ->
                assertFailure ("expected one declaration, got " <> show (length other))
    , testCase "parses type declarations and match expressions" $
        case parseSource "inline" adtSource of
          Left err ->
            assertFailure ("expected parse success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            case moduleTypeDecls modl of
              [typeDecl] -> do
                assertEqual "type name" "Status" (typeDeclName typeDecl)
                assertEqual
                  "constructors"
                  [ ConstructorDecl "Idle" dummySpan dummySpan []
                  , ConstructorDecl "Busy" dummySpan dummySpan [TStr]
                  ]
                  (normalizeConstructors (typeDeclConstructors typeDecl))
              other ->
                assertFailure ("expected one type declaration, got " <> show (length other))
            case findDecl "describe" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EMatch _ _ [MatchBranch _ (PConstructor _ "Idle" []) _, MatchBranch _ (PConstructor _ "Busy" [PatternBinder "note" _]) _] ->
                    pure ()
                  other ->
                    assertFailure ("expected match expression, got " <> show other)
              Nothing ->
                assertFailure "expected describe declaration"
    , testCase "parses imports, records, and field access" $
        case parseSource "inline" recordSource of
          Left err ->
            assertFailure ("expected parse success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            assertEqual "import count" 1 (length (moduleImports modl))
            assertEqual "record decl count" 1 (length (moduleRecordDecls modl))
            case moduleRecordDecls modl of
              [recordDecl] -> do
                assertEqual "record name" "User" (recordDeclName recordDecl)
                assertEqual "record field count" 2 (length (recordDeclFields recordDecl))
              other ->
                assertFailure ("expected one record declaration, got " <> show (length other))
            case findDecl "showName" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EFieldAccess _ (EVar _ "user") "name" ->
                    pure ()
                  other ->
                    assertFailure ("expected field access, got " <> show other)
              Nothing ->
                assertFailure "expected showName declaration"
    , testCase "parses foreign declarations, routes, and json boundaries" $
        case parseSource "inline" serviceSource of
          Left err ->
            assertFailure ("expected parse success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            assertEqual "service type decl count" 1 (length (moduleTypeDecls modl))
            case moduleForeignDecls modl of
              [foreignDecl] -> do
                assertEqual "foreign name" "mockLeadSummaryModel" (foreignDeclName foreignDecl)
                assertEqual "foreign runtime name" "mockLeadSummaryModel" (foreignDeclRuntimeName foreignDecl)
              other ->
                assertFailure ("expected one foreign declaration, got " <> show (length other))
            case moduleRouteDecls modl of
              [routeDecl] -> do
                assertEqual "route name" "summarizeLeadRoute" (routeDeclName routeDecl)
                assertEqual "route method" RoutePost (routeDeclMethod routeDecl)
                assertEqual "route path" "/lead/summary" (routeDeclPath routeDecl)
              other ->
                assertFailure ("expected one route declaration, got " <> show (length other))
            case findDecl "summarizeLead" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EDecode _ (TNamed "LeadSummary") (ECall _ (EVar _ "mockLeadSummaryModel") [EVar _ "lead"]) ->
                    pure ()
                  other ->
                    assertFailure ("expected decode expression, got " <> show other)
              Nothing ->
                assertFailure "expected summarizeLead declaration"
    , testCase "parses list types in signatures, constructors, records, and decode" $
        case parseSource "inline" listTypeSource of
          Left err ->
            assertFailure ("expected parse success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            case moduleTypeDecls modl of
              [typeDecl] ->
                assertEqual
                  "constructors"
                  [ConstructorDecl "Batch" dummySpan dummySpan [TList TInt, TList (TList TStr)]]
                  (normalizeConstructors (typeDeclConstructors typeDecl))
              other ->
                assertFailure ("expected one type declaration, got " <> show (length other))
            case moduleRecordDecls modl of
              [recordDecl] ->
                assertEqual
                  "record field types"
                  [TList (TNamed "User"), TList (TList TStr)]
                  (fmap recordFieldDeclType (recordDeclFields recordDecl))
              other ->
                assertFailure ("expected one record declaration, got " <> show (length other))
            case findDecl "decodeUsers" (moduleDecls modl) of
              Just decl ->
                case (declAnnotation decl, declBody decl) of
                  (Just (TFunction [TStr] (TList (TNamed "User"))), EDecode _ (TList (TNamed "User")) (EVar _ "raw")) ->
                    pure ()
                  other ->
                    assertFailure ("expected list-typed declaration and decode, got " <> show other)
              Nothing ->
                assertFailure "expected decodeUsers declaration"
    , testCase "parses list literals" $
        case parseSource "inline" listLiteralSource of
          Left err ->
            assertFailure ("expected parse success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "names" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EList _ [EString _ "Ada", EString _ "Grace"] ->
                    pure ()
                  other ->
                    assertFailure ("expected list literal, got " <> show other)
              Nothing ->
                assertFailure "expected names declaration"
    , testCase "parses equality expressions" $
        case parseSource "inline" equalitySource of
          Left err ->
            assertFailure ("expected parse success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "sameInt" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EEqual _ (EVar _ "left") (EVar _ "right") ->
                    pure ()
                  other ->
                    assertFailure ("expected equality expression, got " <> show other)
              Nothing ->
                assertFailure "expected sameInt declaration"
    , testCase "parses integer comparison expressions" $
        case parseSource "inline" integerComparisonSource of
          Left err ->
            assertFailure ("expected parse success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "lessThan" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EIntCompare _ IntLessThan (EVar _ "left") (EVar _ "right") ->
                    pure ()
                  other ->
                    assertFailure ("expected integer comparison expression, got " <> show other)
              Nothing ->
                assertFailure "expected lessThan declaration"
    , testCase "parses local let expressions" $
        case parseSource "inline" letSource of
          Left err ->
            assertFailure ("expected parse success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "greeting" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  ELet _ (LetBinding "prefix" _ _ (EString _ "hello")) (ELet _ (LetBinding "subject" _ _ (EString _ "world")) (ECall _ (EVar _ "join") [EVar _ "prefix", EVar _ "subject"])) ->
                    pure ()
                  other ->
                    assertFailure ("expected let expression, got " <> show other)
              Nothing ->
                assertFailure "expected greeting declaration"
    , testCase "parses local let expressions in bare argument position" $
        case parseSource "inline" letArgumentSource of
          Left err ->
            assertFailure ("expected parse success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "main" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  ECall _ (EVar _ "id") [ELet _ (LetBinding "value" _ _ (EInt _ 1)) (EVar _ "value")] ->
                    pure ()
                  other ->
                    assertFailure ("expected bare let argument expression, got " <> show other)
              Nothing ->
                assertFailure "expected main declaration"
    ]

checkerTests :: TestTree
checkerTests =
  testGroup
    "checker"
    [ testCase "accepts the list example program" $ do
        result <- checkEntry listExamplePath
        case result of
          Left err ->
            assertFailure ("expected list example to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
    , testCase "accepts the example program" $
        case checkSource "hello" helloSource of
          Left err ->
            assertFailure ("expected hello source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
    , testCase "accepts algebraic data types and exhaustive match" $
        case checkSource "adt" adtSource of
          Left err ->
            assertFailure ("expected adt source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
    , testCase "infers constructor and match-driven function types" $
        case checkSource "inferred" inferredFunctionSource of
          Left err ->
            assertFailure ("expected inferred source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
    , testCase "accepts record literals and field access" $
        case checkSource "record" recordSource of
          Left err ->
            assertFailure ("expected record source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
    , testCase "accepts foreign declarations, routes, and json boundaries" $
        case checkSource "service" serviceSource of
          Left err ->
            assertFailure ("expected service source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
    , testCase "accepts primitive equality" $
        case checkSource "equality" equalitySource of
          Left err ->
            assertFailure ("expected equality source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
    , testCase "accepts integer comparisons" $
        case checkSource "comparisons" integerComparisonSource of
          Left err ->
            assertFailure ("expected integer comparison source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
    , testCase "accepts homogeneous list literals" $
        case checkSource "lists" listLiteralSource of
          Left err ->
            assertFailure ("expected list literal source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
    , testCase "accepts list JSON boundaries and list-valued record fields" $
        case checkSource "json-lists" jsonListSource of
          Left err ->
            assertFailure ("expected list json source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
    , testCase "reports undefined names with a primary span" $
        case checkSource "bad" unboundNameSource of
          Left bundle -> do
            err <- expectFirstDiagnostic bundle
            assertEqual "code" "E_UNBOUND_NAME" (diagnosticCode err)
            assertEqual "primary line" (Just 3) (positionLine . sourceSpanStart <$> diagnosticPrimarySpan err)
            assertEqual "primary column" (Just 8) (positionColumn . sourceSpanStart <$> diagnosticPrimarySpan err)
            assertEqual "fix hint kinds" ["declare_name", "replace_name"] (fmap fixHintKind (diagnosticFixHints err))
          Right _ ->
            assertFailure "expected undefined-name failure"
    , testCase "reports ambiguous function inference" $
        case checkSource "bad" ambiguousFunctionSource of
          Left bundle -> do
            err <- expectFirstDiagnostic bundle
            assertEqual "code" "E_CANNOT_INFER" (diagnosticCode err)
            assertEqual "primary line" (Just 3) (positionLine . sourceSpanStart <$> diagnosticPrimarySpan err)
          Right _ ->
            assertFailure "expected ambiguous inference failure"
    , testCase "reports type mismatches with the argument span" $
        case checkSource "bad" mismatchSource of
          Left bundle -> do
            err <- expectFirstDiagnostic bundle
            assertEqual "code" "E_TYPE_MISMATCH" (diagnosticCode err)
            assertEqual "primary line" (Just 6) (positionLine . sourceSpanStart <$> diagnosticPrimarySpan err)
            assertEqual "primary column" (Just 11) (positionColumn . sourceSpanStart <$> diagnosticPrimarySpan err)
          Right _ ->
            assertFailure "expected type mismatch failure"
    , testCase "reports duplicate declarations with related location" $
        case checkSource "bad" duplicateDeclSource of
          Left bundle -> do
            err <- expectFirstDiagnostic bundle
            assertEqual "code" "E_DUPLICATE_DECL" (diagnosticCode err)
            assertEqual "one related span" 1 (length (diagnosticRelatedSpans err))
          Right _ ->
            assertFailure "expected duplicate declaration failure"
    , testCase "rejects record literals with missing fields" $
        assertHasCode "E_RECORD_MISSING_FIELDS" (checkSource "bad" missingRecordFieldSource)
    , testCase "rejects route handlers with the wrong response type" $
        assertHasCode "E_ROUTE_HANDLER_TYPE" (checkSource "bad" wrongRouteHandlerSource)
    , testCase "reports non-exhaustive match expressions" $
        assertHasCode "E_NONEXHAUSTIVE_MATCH" (checkSource "bad" nonExhaustiveMatchSource)
    , testCase "rejects constructors from the wrong type" $
        assertHasCode "E_PATTERN_TYPE_MISMATCH" (checkSource "bad" wrongConstructorSource)
    , testCase "rejects duplicate match branches" $
        assertHasCode "E_DUPLICATE_MATCH_BRANCH" (checkSource "bad" duplicateBranchSource)
    , testCase "rejects unsupported equality operands" $
        assertHasCode "E_EQUALITY_TYPE" (checkSource "bad" unsupportedEqualitySource)
    , testCase "rejects non-integer comparison operands" $
        assertHasCode "E_INT_COMPARISON_TYPE" (checkSource "bad" unsupportedIntComparisonSource)
    , testCase "rejects mixed-type list literals" $
        assertHasCode "E_LIST_ELEMENT_TYPE" (checkSource "bad" mixedListLiteralSource)
    , testCase "rejects unconstrained empty list literals" $
        assertHasCode "E_CANNOT_INFER" (checkSource "bad" emptyListLiteralSource)
    ]

diagnosticTests :: TestTree
diagnosticTests =
  testGroup
    "diagnostics"
    [ testCase "json rendering includes codes and source spans" $
        case checkSource "bad" unboundNameSource of
          Left bundle -> do
            let jsonText = LT.toStrict (renderDiagnosticBundleJson bundle)
            assertBool "expected code in json" ("\"code\":\"E_UNBOUND_NAME\"" `T.isInfixOf` jsonText)
            assertBool "expected primary span in json" ("\"primarySpan\"" `T.isInfixOf` jsonText)
            assertBool "expected file in json" ("\"file\":\"bad\"" `T.isInfixOf` jsonText)
            assertBool "expected fix hints in json" ("\"fixHints\"" `T.isInfixOf` jsonText)
            assertBool "expected declare-name fix hint in json" ("\"kind\":\"declare_name\"" `T.isInfixOf` jsonText)
          Right _ ->
            assertFailure "expected json diagnostic failure"
    , testCase "pretty rendering includes related locations" $
        case checkSource "bad" duplicateDeclSource of
          Left bundle -> do
            let rendered = renderDiagnosticBundle bundle
            assertBool "expected related marker" ("related previous declaration" `T.isInfixOf` rendered)
          Right _ ->
            assertFailure "expected duplicate declaration failure"
    , testCase "non-exhaustive matches expose missing constructors as fix hints" $
        case checkSource "bad" nonExhaustiveMatchSource of
          Left bundle -> do
            err <- expectFirstDiagnostic bundle
            assertEqual
              "match fix hint"
              [DiagnosticFixHint "add_match_branches" "Add branches for the missing constructors." ["Busy"]]
              (diagnosticFixHints err)
          Right _ ->
            assertFailure "expected non-exhaustive match failure"
    ]

lowerTests :: TestTree
lowerTests =
  testGroup
    "lower"
    [ testCase "lowering materializes constructors as declarations" $
        case lowerChecked "adt" adtSource of
          Left err ->
            assertFailure ("expected lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case lowerModuleDecls lowered of
              LValueDecl "Idle" (LConstruct "Idle" []) : LFunctionDecl "Busy" ["$0"] (LConstruct "Busy" [LVar "$0"]) : _ ->
                pure ()
              other ->
                assertFailure ("unexpected lowered constructors: " <> show other)
    , testCase "lowering preserves match branches as tag dispatch" $
        case lowerChecked "adt" adtSource of
          Left err ->
            assertFailure ("expected lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "describe" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["status"] (LMatch (LVar "status") [LowerMatchBranch "Idle" [] (LString "idle"), LowerMatchBranch "Busy" ["note"] (LVar "note")])) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered describe declaration: " <> show other)
    , testCase "lowering preserves records and field access" $
        case lowerChecked "record" recordSource of
          Left err ->
            assertFailure ("expected lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered -> do
            case findLowerDecl "showName" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["user"] (LFieldAccess (LVar "user") "name")) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered showName declaration: " <> show other)
            case findLowerDecl "defaultUser" (lowerModuleDecls lowered) of
              Just (LValueDecl _ (LRecord [LowerRecordField "name" (LString "Ada"), LowerRecordField "active" (LBool True)])) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered defaultUser declaration: " <> show other)
    , testCase "lowering preserves equality expressions" $
        case lowerChecked "equality" equalitySource of
          Left err ->
            assertFailure ("expected lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "sameStr" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["left", "right"] (LEqual (LVar "left") (LVar "right"))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered sameStr declaration: " <> show other)
    , testCase "lowering preserves integer comparison expressions" $
        case lowerChecked "comparisons" integerComparisonSource of
          Left err ->
            assertFailure ("expected lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "greaterThanOrEqual" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["left", "right"] (LIntCompare IntGreaterThanOrEqual (LVar "left") (LVar "right"))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered greaterThanOrEqual declaration: " <> show other)
    , testCase "lowering preserves list literals" $
        case lowerChecked "lists" listLiteralSource of
          Left err ->
            assertFailure ("expected lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "names" (lowerModuleDecls lowered) of
              Just (LValueDecl _ (LList [LString "Ada", LString "Grace"])) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered names declaration: " <> show other)
    , testCase "lowering uses higher-order codecs for list json boundaries" $
        case lowerChecked "json-lists" jsonListSource of
          Left err ->
            assertFailure ("expected lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered -> do
            case findLowerDecl "decodeUsers" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["raw"] (LCall (LCall (LVar "$decodeList") [LVar "$validate_User"]) [LVar "raw"])) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered decodeUsers declaration: " <> show other)
            case findLowerDecl "encodeUsers" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["users"] (LCall (LCall (LVar "$encodeList") [LVar "$validateInternal_User", LVar "$serialize_User"]) [LVar "users"])) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered encodeUsers declaration: " <> show other)
    ]

compileTests :: TestTree
compileTests =
  testGroup
    "compile"
    [ testCase "compileEntry emits JavaScript for the list example" $ do
        result <- compileEntry listExamplePath
        case result of
          Left err ->
            assertFailure ("expected list example to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected list decoder helper" ("function $decodeList(validateElement)" `T.isInfixOf` emitted)
            assertBool "expected encoded batch export" ("export const batchJson = $encode_Batch(defaultBatch);" `T.isInfixOf` emitted)
            assertBool "expected nested list literal" ("highlights: [[\"core\", \"language\"], []]" `T.isInfixOf` emitted)
    , testCase "compile emits JavaScript for a checked module" $
        case compileSource "hello" helloSource of
          Left err ->
            assertFailure ("expected compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted ->
            assertBool "expected emitted JavaScript to export id" ("export function id" `T.isInfixOf` emitted)
    , testCase "compile lowers constructors and match expressions to JavaScript" $
        case compileSource "adt" adtSource of
          Left err ->
            assertFailure ("expected compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected constructor function" ("export function Busy" `T.isInfixOf` emitted)
            assertBool "expected nullary constructor" ("export const Idle" `T.isInfixOf` emitted)
            assertBool "expected switch for match" ("switch ($match" `T.isInfixOf` emitted)
    , testCase "compile preserves inferred functions" $
        case compileSource "inferred" inferredFunctionSource of
          Left err ->
            assertFailure ("expected compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected inferred function export" ("export function makeBusy" `T.isInfixOf` emitted)
            assertBool "expected inferred matcher export" ("export function describe" `T.isInfixOf` emitted)
    , testCase "compile lowers records and field access to JavaScript" $
        case compileSource "record" recordSource of
          Left err ->
            assertFailure ("expected compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected object literal" ("{ name: \"Ada\", active: true }" `T.isInfixOf` emitted)
            assertBool "expected field access" ("(user).name" `T.isInfixOf` emitted)
    , testCase "compile emits runtime bindings, codecs, and route metadata" $
        case compileSource "service" serviceSource of
          Left err ->
            assertFailure ("expected service compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected foreign runtime wrapper" ("function mockLeadSummaryModel($0) { return $claspRuntime(\"mockLeadSummaryModel\")($0); }" `T.isInfixOf` emitted)
            assertBool "expected enum decoder" ("function $decode_LeadPriority" `T.isInfixOf` emitted)
            assertBool "expected internal enum validator" ("function $validateInternal_LeadPriority" `T.isInfixOf` emitted)
            assertBool "expected record decoder" ("function $decode_LeadSummary" `T.isInfixOf` emitted)
            assertBool "expected record encoder to validate internal values" ("function $encode_LeadSummary(value) { return JSON.stringify($serialize_LeadSummary($validateInternal_LeadSummary(value, \"value\"))); }" `T.isInfixOf` emitted)
            assertBool "expected route registry" ("export const __claspRoutes" `T.isInfixOf` emitted)
            assertBool "expected route path" ("\"/lead/summary\"" `T.isInfixOf` emitted)
    , testCase "compile emits JavaScript equality" $
        case compileSource "equality" equalitySource of
          Left err ->
            assertFailure ("expected equality compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted ->
            assertBool "expected strict equality" ("(left === right)" `T.isInfixOf` emitted)
    , testCase "compile emits JavaScript integer comparisons" $
        case compileSource "comparisons" integerComparisonSource of
          Left err ->
            assertFailure ("expected integer comparison compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected less-than comparison" ("(left < right)" `T.isInfixOf` emitted)
            assertBool "expected greater-than-or-equal comparison" ("(left >= right)" `T.isInfixOf` emitted)
    , testCase "compile emits JavaScript arrays for list literals" $
        case compileSource "lists" listLiteralSource of
          Left err ->
            assertFailure ("expected list literal compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted ->
            assertBool "expected array literal" ("export const names = [\"Ada\", \"Grace\"];" `T.isInfixOf` emitted)
    , testCase "compile emits list JSON codecs for direct boundaries and record fields" $
        case compileSource "json-lists" jsonListSource of
          Left err ->
            assertFailure ("expected list json compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected list decoder helper" ("function $decodeList(validateElement)" `T.isInfixOf` emitted)
            assertBool "expected list validator in record codec" ("$validateList($validate_Str)(tagsValue, path + \".tags\")" `T.isInfixOf` emitted)
            assertBool "expected list serializer in record codec" ("$serializeList($serialize_User)(value.users)" `T.isInfixOf` emitted)
            assertBool "expected direct list decode lowering" ("export function decodeUsers(raw) { return $decodeList($validate_User)(raw); }" `T.isInfixOf` emitted)
            assertBool "expected direct list encode lowering" ("export function encodeUsers(users) { return $encodeList($validateInternal_User, $serialize_User)(users); }" `T.isInfixOf` emitted)
    , testCase "checkEntry resolves imported modules" $
        withProjectFiles "import-success" importSuccessFiles $ \root -> do
          result <- checkEntry (root </> "Main.clasp")
          case result of
            Left err ->
              assertFailure ("expected imported project to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
            Right _ ->
              pure ()
    , testCase "compileEntry compiles imported modules into one JS output" $
        withProjectFiles "compile-import-success" importSuccessFiles $ \root -> do
          result <- compileEntry (root </> "Main.clasp")
          case result of
            Left err ->
              assertFailure ("expected imported project to compile:\n" <> T.unpack (renderDiagnosticBundle err))
            Right emitted -> do
              assertBool "expected imported function export" ("export function formatUser" `T.isInfixOf` emitted)
              assertBool "expected main export" ("export const main" `T.isInfixOf` emitted)
    , testCase "checkEntry reports missing imported modules" $
        withProjectFiles "import-missing" missingImportFiles $ \root -> do
          result <- checkEntry (root </> "Main.clasp")
          assertHasCode "E_IMPORT_NOT_FOUND" result
    ]

assertHasCode :: Text -> Either DiagnosticBundle a -> Assertion
assertHasCode code result =
  case result of
    Left (DiagnosticBundle errs) ->
      assertBool
        ("expected diagnostic code " <> T.unpack code <> " but got:\n" <> T.unpack (renderDiagnosticBundle (DiagnosticBundle errs)))
        (any ((== code) . diagnosticCode) errs)
    Right _ ->
      assertFailure ("expected failure with code " <> T.unpack code)

expectFirstDiagnostic :: DiagnosticBundle -> IO Diagnostic
expectFirstDiagnostic (DiagnosticBundle errs) =
  case errs of
    firstErr : _ ->
      pure firstErr
    [] ->
      assertFailure "expected at least one diagnostic"

findDecl :: Text -> [Decl] -> Maybe Decl
findDecl target =
  go
  where
    go [] = Nothing
    go (decl : rest)
      | declName decl == target = Just decl
      | otherwise = go rest

findLowerDecl :: Text -> [LowerDecl] -> Maybe LowerDecl
findLowerDecl target =
  go
  where
    go [] = Nothing
    go (decl : rest) =
      case decl of
        LValueDecl name _
          | name == target -> Just decl
        LFunctionDecl name _ _
          | name == target -> Just decl
        _ -> go rest

lowerChecked :: FilePath -> Text -> Either DiagnosticBundle LowerModule
lowerChecked path source = do
  checked <- checkSource path source
  pure (lowerModule checked)

withProjectFiles :: FilePath -> [(FilePath, Text)] -> (FilePath -> IO a) -> IO a
withProjectFiles fixtureName files action = do
  let root = "dist/test-projects" </> fixtureName
  cleanupProjectDir root
  createDirectoryIfMissing True root
  mapM_ (writeProjectFile root) files
  action root `finally` cleanupProjectDir root

writeProjectFile :: FilePath -> (FilePath, Text) -> IO ()
writeProjectFile root (relativePath, content) = do
  let absolutePath = root </> relativePath
  createDirectoryIfMissing True (takeDirectory absolutePath)
  TIO.writeFile absolutePath content

cleanupProjectDir :: FilePath -> IO ()
cleanupProjectDir root = do
  exists <- doesDirectoryExist root
  when exists (removePathForcibly root)

normalizeConstructors :: [ConstructorDecl] -> [ConstructorDecl]
normalizeConstructors =
  fmap (\constructorDecl -> constructorDecl {constructorDeclSpan = dummySpan, constructorDeclNameSpan = dummySpan})

dummySpan :: SourceSpan
dummySpan =
  SourceSpan
    { sourceSpanFile = ""
    , sourceSpanStart = Position 0 0
    , sourceSpanEnd = Position 0 0
    }

annotatedIdentitySource :: Text
annotatedIdentitySource =
  T.unlines
    [ "module Main"
    , ""
    , "id : Str -> Str"
    , "id x = x"
    ]

helloSource :: Text
helloSource =
  T.unlines
    [ "module Main"
    , ""
    , "hello = \"Hello from Clasp\""
    , ""
    , "id : Str -> Str"
    , "id v = v"
    , ""
    , "main = id hello"
    ]

adtSource :: Text
adtSource =
  T.unlines
    [ "module Main"
    , ""
    , "type Status = Idle | Busy Str"
    , ""
    , "describe : Status -> Str"
    , "describe status = match status {"
    , "  Idle -> \"idle\","
    , "  Busy note -> note"
    , "}"
    , ""
    , "main : Str"
    , "main = describe (Busy \"loading\")"
    ]

unboundNameSource :: Text
unboundNameSource =
  T.unlines
    [ "module Main"
    , ""
    , "main = missing"
    ]

ambiguousFunctionSource :: Text
ambiguousFunctionSource =
  T.unlines
    [ "module Main"
    , ""
    , "identity value = value"
    ]

inferredFunctionSource :: Text
inferredFunctionSource =
  T.unlines
    [ "module Main"
    , ""
    , "type Status = Idle | Busy Str"
    , ""
    , "makeBusy note = Busy note"
    , ""
    , "describe status = match status {"
    , "  Idle -> \"idle\","
    , "  Busy note -> note"
    , "}"
    , ""
    , "main : Str"
    , "main = describe (makeBusy \"loading\")"
    ]

recordSource :: Text
recordSource =
  T.unlines
    [ "module Main"
    , ""
    , "import Shared.User"
    , ""
    , "record User = {"
    , "  name : Str,"
    , "  active : Bool"
    , "}"
    , ""
    , "defaultUser = User {"
    , "  name = \"Ada\","
    , "  active = true"
    , "}"
    , ""
    , "showName user = user.name"
    , ""
    , "main : Str"
    , "main = showName defaultUser"
    ]

serviceSource :: Text
serviceSource =
  T.unlines
    [ "module Main"
    , ""
    , "type LeadPriority = Low | Medium | High"
    , ""
    , "record LeadRequest = {"
    , "  company : Str,"
    , "  budget : Int,"
    , "  priorityHint : LeadPriority"
    , "}"
    , ""
    , "record LeadSummary = {"
    , "  summary : Str,"
    , "  priority : LeadPriority,"
    , "  followUpRequired : Bool"
    , "}"
    , ""
    , "foreign mockLeadSummaryModel : LeadRequest -> Str = \"mockLeadSummaryModel\""
    , ""
    , "summarizeLead : LeadRequest -> LeadSummary"
    , "summarizeLead lead = decode LeadSummary (mockLeadSummaryModel lead)"
    , ""
    , "encodedDefault : Str"
    , "encodedDefault = encode (LeadSummary {"
    , "  summary = \"ready\","
    , "  priority = High,"
    , "  followUpRequired = true"
    , "})"
    , ""
    , "route summarizeLeadRoute = POST \"/lead/summary\" LeadRequest -> LeadSummary summarizeLead"
    ]

listTypeSource :: Text
listTypeSource =
  T.unlines
    [ "module Main"
    , ""
    , "type Payload = Batch [Int] [[Str]]"
    , ""
    , "record UserGroup = {"
    , "  members : [User],"
    , "  labels : [[Str]]"
    , "}"
    , ""
    , "decodeUsers : Str -> [User]"
    , "decodeUsers raw = decode [User] raw"
    ]

listLiteralSource :: Text
listLiteralSource =
  T.unlines
    [ "module Main"
    , ""
    , "names : [Str]"
    , "names = [\"Ada\", \"Grace\"]"
    , ""
    , "pairs : [[Int]]"
    , "pairs = [[1, 2], [3, 4]]"
    ]

jsonListSource :: Text
jsonListSource =
  T.unlines
    [ "module Main"
    , ""
    , "record User = {"
    , "  name : Str,"
    , "  tags : [Str]"
    , "}"
    , ""
    , "record Payload = {"
    , "  users : [User],"
    , "  flags : [[Bool]]"
    , "}"
    , ""
    , "decodeUsers : Str -> [User]"
    , "decodeUsers raw = decode [User] raw"
    , ""
    , "encodeUsers : [User] -> Str"
    , "encodeUsers users = encode users"
    , ""
    , "payload : Payload"
    , "payload = Payload {"
    , "  users = [User {"
    , "    name = \"Ada\","
    , "    tags = [\"core\", \"lang\"]"
    , "  }],"
    , "  flags = [[true, false], []]"
    , "}"
    , ""
    , "encodedPayload : Str"
    , "encodedPayload = encode payload"
    ]

mixedListLiteralSource :: Text
mixedListLiteralSource =
  T.unlines
    [ "module Main"
    , ""
    , "bad = [1, \"two\"]"
    ]

emptyListLiteralSource :: Text
emptyListLiteralSource =
  T.unlines
    [ "module Main"
    , ""
    , "empty = []"
    ]

equalitySource :: Text
equalitySource =
  T.unlines
    [ "module Main"
    , ""
    , "sameInt : Int -> Int -> Bool"
    , "sameInt left right = left == right"
    , ""
    , "sameStr : Str -> Str -> Bool"
    , "sameStr left right = left == right"
    , ""
    , "sameBool : Bool -> Bool -> Bool"
    , "sameBool left right = left == right"
    ]

integerComparisonSource :: Text
integerComparisonSource =
  T.unlines
    [ "module Main"
    , ""
    , "lessThan : Int -> Int -> Bool"
    , "lessThan left right = left < right"
    , ""
    , "lessThanOrEqual : Int -> Int -> Bool"
    , "lessThanOrEqual left right = left <= right"
    , ""
    , "greaterThan : Int -> Int -> Bool"
    , "greaterThan left right = left > right"
    , ""
    , "greaterThanOrEqual : Int -> Int -> Bool"
    , "greaterThanOrEqual left right = left >= right"
    ]

letSource :: Text
letSource =
  T.unlines
    [ "module Main"
    , ""
    , "join : Str -> Str -> Str"
    , "join left right = left"
    , ""
    , "greeting : Str"
    , "greeting = let prefix = \"hello\" in let subject = \"world\" in join prefix subject"
    ]

letArgumentSource :: Text
letArgumentSource =
  T.unlines
    [ "module Main"
    , ""
    , "id : Int -> Int"
    , "id value = value"
    , ""
    , "main : Int"
    , "main = id let value = 1 in value"
    ]

missingRecordFieldSource :: Text
missingRecordFieldSource =
  T.unlines
    [ "module Main"
    , ""
    , "record User = { name : Str, active : Bool }"
    , ""
    , "main = User { name = \"Ada\" }"
    ]

wrongRouteHandlerSource :: Text
wrongRouteHandlerSource =
  T.unlines
    [ "module Main"
    , ""
    , "record LeadRequest = { company : Str }"
    , "record LeadSummary = { summary : Str }"
    , "record LeadAck = { ok : Bool }"
    , ""
    , "summarizeLead : LeadRequest -> LeadAck"
    , "summarizeLead lead = LeadAck { ok = true }"
    , ""
    , "route summarizeLeadRoute = POST \"/lead/summary\" LeadRequest -> LeadSummary summarizeLead"
    ]

mismatchSource :: Text
mismatchSource =
  T.unlines
    [ "module Main"
    , ""
    , "id : Str -> Str"
    , "id value = value"
    , ""
    , "main = id 42"
    ]

duplicateDeclSource :: Text
duplicateDeclSource =
  T.unlines
    [ "module Main"
    , ""
    , "hello = \"first\""
    , "hello = \"second\""
    ]

nonExhaustiveMatchSource :: Text
nonExhaustiveMatchSource =
  T.unlines
    [ "module Main"
    , ""
    , "type Status = Idle | Busy Str"
    , ""
    , "describe : Status -> Str"
    , "describe status = match status {"
    , "  Idle -> \"idle\""
    , "}"
    ]

wrongConstructorSource :: Text
wrongConstructorSource =
  T.unlines
    [ "module Main"
    , ""
    , "type Status = Idle | Busy Str"
    , "type Mode = Auto"
    , ""
    , "describe : Status -> Str"
    , "describe status = match status {"
    , "  Auto -> \"auto\","
    , "  Busy note -> note"
    , "}"
    ]

duplicateBranchSource :: Text
duplicateBranchSource =
  T.unlines
    [ "module Main"
    , ""
    , "type Status = Idle | Busy Str"
    , ""
    , "describe : Status -> Str"
    , "describe status = match status {"
    , "  Idle -> \"idle\","
    , "  Idle -> \"still idle\","
    , "  Busy note -> note"
    , "}"
    ]

unsupportedEqualitySource :: Text
unsupportedEqualitySource =
  T.unlines
    [ "module Main"
    , ""
    , "record User = { name : Str }"
    , ""
    , "main : User -> User -> Bool"
    , "main left right = left == right"
    ]

unsupportedIntComparisonSource :: Text
unsupportedIntComparisonSource =
  T.unlines
    [ "module Main"
    , ""
    , "main : Str -> Str -> Bool"
    , "main left right = left < right"
    ]

importSuccessFiles :: [(FilePath, Text)]
importSuccessFiles =
  [ ("Main.clasp", importSuccessMainSource)
  , ("Shared/User.clasp", sharedUserSource)
  ]

missingImportFiles :: [(FilePath, Text)]
missingImportFiles =
  [ ("Main.clasp", missingImportMainSource)
  ]

importSuccessMainSource :: Text
importSuccessMainSource =
  T.unlines
    [ "module Main"
    , ""
    , "import Shared.User"
    , ""
    , "main : Str"
    , "main = formatUser defaultUser"
    ]

sharedUserSource :: Text
sharedUserSource =
  T.unlines
    [ "module Shared.User"
    , ""
    , "record User = {"
    , "  name : Str,"
    , "  active : Bool"
    , "}"
    , ""
    , "defaultUser : User"
    , "defaultUser = User {"
    , "  name = \"Ada\","
    , "  active = true"
    , "}"
    , ""
    , "formatUser : User -> Str"
    , "formatUser user = user.name"
    ]

missingImportMainSource :: Text
missingImportMainSource =
  T.unlines
    [ "module Main"
    , ""
    , "import Shared.Missing"
    , ""
    , "main = 1"
    ]
