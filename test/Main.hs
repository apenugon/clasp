{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (finally)
import Control.Monad (when)
import Data.Aeson (Value (..), eitherDecodeStrictText)
import Data.Aeson.Key (fromText)
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Foldable (toList)
import Data.List (find)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as LT
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , makeAbsolute
  , removePathForcibly
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>), replaceExtension, takeDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit
  ( Assertion
  , assertBool
  , assertEqual
  , assertFailure
  , testCase
  )
import Clasp.Air
  ( AirAttr (..)
  , AirModule (..)
  , AirNode (..)
  , AirNodeId (..)
  )
import Clasp.Compiler
  ( SemanticEdit (..)
  , airEntry
  , airSource
  , checkEntry
  , checkSource
  , compileEntry
  , compileSource
  , parseSource
  , renderAirSourceJson
  , renderContextSourceJson
  , semanticEditSource
  )
import Clasp.Core
  ( CoreDecl (..)
  , CoreExpr (..)
  , CoreModule (..)
  )
import Clasp.Diagnostic
  ( Diagnostic (..)
  , DiagnosticBundle (..)
  , renderDiagnosticBundle
  , renderDiagnosticBundleJson
  )
import Clasp.Lower
  ( LowerDecl (..)
  , LowerFormField (..)
  , LowerExpr (..)
  , LowerMatchBranch (..)
  , LowerModule (..)
  , LowerPageFlow (..)
  , LowerPageForm (..)
  , LowerPageLink (..)
  , LowerRecordField (..)
  , LowerRouteContract (..)
  , lowerPageFlows
  , lowerModule
  )
import Clasp.Syntax
  ( ConstructorDecl (..)
  , Decl (..)
  , Expr (..)
  , ForeignDecl (..)
  , GuideDecl (..)
  , GuideEntryDecl (..)
  , MatchBranch (..)
  , Module (..)
  , ModuleName (..)
  , Pattern (..)
  , PatternBinder (..)
  , Position (..)
  , PolicyDecl (..)
  , ProjectionDecl (..)
  , RecordDecl (..)
  , RecordFieldDecl (..)
  , RecordFieldExpr (..)
  , RouteBoundaryDecl (..)
  , RouteDecl (..)
  , RouteMethod (..)
  , RoutePathDecl (..)
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
    , semanticEditTests
    , airTests
    , contextTests
    , diagnosticTests
    , lowerTests
    , compileTests
    ]

parserTests :: TestTree
parserTests =
  testGroup
    "parser"
    [ testCase "parses declaration annotations with spans" $
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
    , testCase "parses classified fields, policies, and projections" $
        case parseSource "inline" classifiedProjectionSource of
          Left err ->
            assertFailure ("expected classified projection source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            case find ((== "Customer") . recordDeclName) (moduleRecordDecls modl) of
              Just recordDecl ->
                case recordDeclFields recordDecl of
                  _ : RecordFieldDecl {recordFieldDeclClassification = classification} : _ ->
                    assertEqual "classified field" "pii" classification
                  _ ->
                    assertFailure "expected classified email field"
              Nothing ->
                assertFailure "expected Customer schema record declaration"
            case modulePolicyDecls modl of
              [policyDecl] ->
                assertEqual "policy name" "SupportDisclosure" (policyDeclName policyDecl)
              other ->
                assertFailure ("expected one policy declaration, got " <> show (length other))
            case moduleProjectionDecls modl of
              [projectionDecl] -> do
                assertEqual "projection name" "SupportCustomer" (projectionDeclName projectionDecl)
                assertEqual "projection source" "Customer" (projectionDeclSourceRecordName projectionDecl)
                assertEqual "projection policy" "SupportDisclosure" (projectionDeclPolicyName projectionDecl)
              other ->
                assertFailure ("expected one projection declaration, got " <> show (length other))
    , testCase "parses repo memory guides with inheritance" $
        case parseSource "inline" guideSource of
          Left err ->
            assertFailure ("expected guide source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case moduleGuideDecls modl of
              [baseGuide, childGuide] -> do
                assertEqual "base guide name" "Repo" (guideDeclName baseGuide)
                assertEqual "base guide entry count" 2 (length (guideDeclEntries baseGuide))
                assertEqual "child guide extends" (Just "Repo") (guideDeclExtends childGuide)
                assertEqual
                  "child entries"
                  [GuideEntryDecl "verification" dummySpan "Run bash scripts/verify-all.sh before finishing." dummySpan]
                  (normalizeGuideEntries (guideDeclEntries childGuide))
              other ->
                assertFailure ("expected two guide declarations, got " <> show (length other))
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
                assertEqual "route identity" "route:summarizeLeadRoute" (routeDeclIdentity routeDecl)
                assertEqual "route method" RoutePost (routeDeclMethod routeDecl)
                assertEqual "route path" "/lead/summary" (routeDeclPath routeDecl)
                assertEqual "route path decl" (RoutePathDecl "/lead/summary" []) (routeDeclPathDecl routeDecl)
                assertEqual "route body decl" (Just (RouteBoundaryDecl "LeadRequest")) (routeDeclBodyDecl routeDecl)
                assertEqual "route form decl" Nothing (routeDeclFormDecl routeDecl)
                assertEqual "route response decl" (RouteBoundaryDecl "LeadSummary") (routeDeclResponseDecl routeDecl)
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
    , testCase "parses compiler-known page types through the normal surface" $
        case parseSource "inline" pageSource of
          Left err ->
            assertFailure ("expected page source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case (findDecl "home" (moduleDecls modl), moduleRouteDecls modl) of
              (Just decl, [routeDecl]) -> do
                assertEqual "page annotation" (Just (TFunction [TNamed "Empty"] (TNamed "Page"))) (declAnnotation decl)
                assertEqual "page route response" "Page" (routeDeclResponseType routeDecl)
                assertEqual "page route query decl" (Just (RouteBoundaryDecl "Empty")) (routeDeclQueryDecl routeDecl)
              _ ->
                assertFailure "expected page declaration and route"
    , testCase "parses compiler-known auth identity types through the normal surface" $
        case parseSource "inline" authIdentitySource of
          Left err ->
            assertFailure ("expected auth identity source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "sessionTenantId" (moduleDecls modl) of
              Just decl ->
                assertEqual
                  "session field access annotation"
                  (Just (TFunction [TNamed "AuthSession"] TStr))
                  (declAnnotation decl)
              Nothing ->
                assertFailure "expected sessionTenantId declaration"
    , testCase "parses list types in signatures, constructors, and record fields" $
        case parseSource "inline" listTypeSource of
          Left err ->
            assertFailure ("expected list type source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            case moduleTypeDecls modl of
              [typeDecl] ->
                assertEqual
                  "list constructor field"
                  [ConstructorDecl "Batch" dummySpan dummySpan [TList (TNamed "User")]]
                  (normalizeConstructors (typeDeclConstructors typeDecl))
              other ->
                assertFailure ("expected one type declaration, got " <> show (length other))
            case moduleRecordDecls modl of
              [recordDecl] ->
                assertEqual
                  "record list field"
                  [TList TStr, TList (TList TInt)]
                  (fmap recordFieldDeclType (recordDeclFields recordDecl))
              other ->
                assertFailure ("expected one record declaration, got " <> show (length other))
            case findDecl "flattened" (moduleDecls modl) of
              Just decl ->
                assertEqual
                  "list annotation"
                  (Just (TFunction [TList (TNamed "BatchResult")] (TList TStr)))
                  (declAnnotation decl)
              Nothing ->
                assertFailure "expected flattened declaration"
    , testCase "parses list literals" $
        case parseSource "inline" listLiteralSource of
          Left err ->
            assertFailure ("expected list literal source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "roster" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EList _ [EString _ "Ada", EString _ "Grace"] ->
                    pure ()
                  other ->
                    assertFailure ("expected list literal body, got " <> show other)
              Nothing ->
                assertFailure "expected roster declaration"
    , testCase "parses local let expressions" $
        case parseSource "inline" letExpressionSource of
          Left err ->
            assertFailure ("expected let expression source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "greeting" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  ELet letSpan binderSpan "message" (EString _ "Ada") (EVar _ "message") -> do
                    assertEqual "let starts on declaration line" 4 (positionLine (sourceSpanStart letSpan))
                    assertEqual "binder line" 4 (positionLine (sourceSpanStart binderSpan))
                  other ->
                    assertFailure ("expected let expression body, got " <> show other)
              Nothing ->
                assertFailure "expected greeting declaration"
    , testCase "parses nested let expressions in match branches" $
        case parseSource "inline" letInMatchSource of
          Left err ->
            assertFailure ("expected let-in-match source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "describe" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EMatch _ _ [MatchBranch _ (PConstructor _ "Busy" [PatternBinder "note" _]) (ELet _ _ "copy" (EVar _ "note") (EVar _ "copy"))] ->
                    pure ()
                  other ->
                    assertFailure ("expected nested let expression inside match branch, got " <> show other)
              Nothing ->
                assertFailure "expected describe declaration"
    , testCase "parses the let example file" $ do
        source <- readExampleSource "let.clasp"
        case parseSource "examples/let.clasp" source of
          Left err ->
            assertFailure ("expected let example source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "main" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  ELet _ _ "current" (ECall _ (EVar _ "Busy") [EString _ "loading"]) (ECall _ (EVar _ "describe") [EVar _ "current"]) ->
                    pure ()
                  other ->
                    assertFailure ("expected top-level let expression in example main, got " <> show other)
              Nothing ->
                assertFailure "expected main declaration"
    , testCase "parses equality operators" $
        case parseSource "inline" equalitySource of
          Left err ->
            assertFailure ("expected equality source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            case findDecl "sameNumber" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EEqual _ (EVar _ "left") (EVar _ "right") ->
                    pure ()
                  other ->
                    assertFailure ("expected equality expression, got " <> show other)
              Nothing ->
                assertFailure "expected sameNumber declaration"
            case findDecl "differentFlag" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  ENotEqual _ (EVar _ "left") (EVar _ "right") ->
                    pure ()
                  other ->
                    assertFailure ("expected inequality expression, got " <> show other)
              Nothing ->
                assertFailure "expected differentFlag declaration"
    , testCase "parses integer comparison operators" $
        case parseSource "inline" integerComparisonSource of
          Left err ->
            assertFailure ("expected integer comparison source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            case findDecl "isEarlier" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  ELessThan _ (EVar _ "left") (EVar _ "right") ->
                    pure ()
                  other ->
                    assertFailure ("expected less-than expression, got " <> show other)
              Nothing ->
                assertFailure "expected isEarlier declaration"
            case findDecl "isLatest" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EGreaterThanOrEqual _ (EVar _ "left") (EVar _ "right") ->
                    pure ()
                  other ->
                    assertFailure ("expected greater-than-or-equal expression, got " <> show other)
              Nothing ->
                assertFailure "expected isLatest declaration"
    , testCase "parses the list example file" $ do
        source <- readExampleSource "lists.clasp"
        case parseSource "examples/lists.clasp" source of
          Left err ->
            assertFailure ("expected list example source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            assertEqual "record decl count" 2 (length (moduleRecordDecls modl))
            case find ((== "UserDirectory") . recordDeclName) (moduleRecordDecls modl) of
              Just recordDecl ->
                assertEqual
                  "nested list record fields"
                  [TList TStr, TList (TList TInt)]
                  (fmap recordFieldDeclType (recordDeclFields recordDecl))
              Nothing ->
                assertFailure "expected UserDirectory record"
            case findDecl "directory" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  ERecord
                    _
                    "UserDirectory"
                    [ RecordFieldExpr "names" _ (EList _ [EString _ "Ada", EString _ "Grace"])
                    , RecordFieldExpr "scoreBuckets" _ (EList _ [EList _ [EInt _ 10, EInt _ 20], EList _ [EInt _ 30]])
                    ] ->
                      pure ()
                  other ->
                    assertFailure ("expected list-focused record literal, got " <> show other)
              Nothing ->
                assertFailure "expected directory declaration"
            case findDecl "usersFromJson" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EDecode _ (TList (TNamed "User")) (EVar _ "raw") ->
                    pure ()
                  other ->
                    assertFailure ("expected list decode boundary, got " <> show other)
              Nothing ->
                assertFailure "expected usersFromJson declaration"
    ]

checkerTests :: TestTree
checkerTests =
  testGroup
    "checker"
    [ testCase "accepts the example program" $
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
    , testCase "accepts classified projections that disclose only policy-approved fields" $
        case checkSource "projection" classifiedProjectionSource of
          Left err ->
            assertFailure ("expected classified projection source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
    , testCase "accepts repo memory guides with inheritance" $
        case checkSource "guide" guideSource of
          Left err ->
            assertFailure ("expected guide source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            assertEqual "guide count" 2 (length (coreModuleGuideDecls checked))
    , testCase "accepts compiler-known page primitives" $
        case checkSource "page" pageSource of
          Left err ->
            assertFailure ("expected page source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
    , testCase "accepts compiler-known auth identity primitives" $
        case checkSource "auth" authIdentitySource of
          Left err ->
            assertFailure ("expected auth identity source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
    , testCase "accepts homogeneous list literals" $
        case checkSource "lists" listLiteralSource of
          Left err ->
            assertFailure ("expected list literal source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
    , testCase "typechecks local let expressions" $
        case checkSource "let" letExpressionSource of
          Left err ->
            assertFailure ("expected let source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case find ((== "greeting") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CLet _ typ "message" (CString _ "Ada") (CVar _ bodyType "message") -> do
                    assertEqual "let result type" TStr typ
                    assertEqual "let body variable type" TStr bodyType
                  other ->
                    assertFailure ("expected checked let expression, got " <> show other)
              Nothing ->
                assertFailure "expected greeting declaration"
    , testCase "typechecks the let example file" $ do
        source <- readExampleSource "let.clasp"
        case checkSource "examples/let.clasp" source of
          Left err ->
            assertFailure ("expected let example source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case find ((== "main") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                assertEqual "main type" TStr (coreDeclType decl)
              Nothing ->
                assertFailure "expected main declaration"
    , testCase "typechecks the list example file" $ do
        source <- readExampleSource "lists.clasp"
        case checkSource "examples/lists.clasp" source of
          Left err ->
            assertFailure ("expected list example source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case find ((== "main") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                assertEqual "main type" (TList (TNamed "User")) (coreDeclType decl)
              Nothing ->
                assertFailure "expected main declaration"
    , testCase "typechecks equality operators for primitive values" $
        case checkSource "equality" equalitySource of
          Left err ->
            assertFailure ("expected equality source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            case find ((== "sameNumber") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CEqual _ (CVar _ TInt "left") (CVar _ TInt "right") ->
                    pure ()
                  other ->
                    assertFailure ("expected checked equality expression, got " <> show other)
              Nothing ->
                assertFailure "expected sameNumber declaration"
            case find ((== "differentFlag") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CNotEqual _ (CVar _ TBool "left") (CVar _ TBool "right") ->
                    pure ()
                  other ->
                    assertFailure ("expected checked inequality expression, got " <> show other)
              Nothing ->
                assertFailure "expected differentFlag declaration"
    , testCase "typechecks integer comparison operators for Int values" $
        case checkSource "comparison" integerComparisonSource of
          Left err ->
            assertFailure ("expected integer comparison source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            case find ((== "isEarlier") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CLessThan _ (CVar _ TInt "left") (CVar _ TInt "right") ->
                    pure ()
                  other ->
                    assertFailure ("expected checked less-than expression, got " <> show other)
              Nothing ->
                assertFailure "expected isEarlier declaration"
            case find ((== "isLatest") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CGreaterThanOrEqual _ (CVar _ TInt "left") (CVar _ TInt "right") ->
                    pure ()
                  other ->
                    assertFailure ("expected checked greater-than-or-equal expression, got " <> show other)
              Nothing ->
                assertFailure "expected isLatest declaration"
    , testCase "reports undefined names with a primary span" $
        case checkSource "bad" unboundNameSource of
          Left bundle -> do
            err <- expectFirstDiagnostic bundle
            assertEqual "code" "E_UNBOUND_NAME" (diagnosticCode err)
            assertEqual "primary line" (Just 3) (positionLine . sourceSpanStart <$> diagnosticPrimarySpan err)
            assertEqual "primary column" (Just 8) (positionColumn . sourceSpanStart <$> diagnosticPrimarySpan err)
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
    , testCase "rejects projections that disclose disallowed classified fields" $
        assertHasCode "E_DISCLOSURE_POLICY" (checkSource "bad" disallowedProjectionSource)
    , testCase "reports non-exhaustive match expressions" $
        assertHasCode "E_NONEXHAUSTIVE_MATCH" (checkSource "bad" nonExhaustiveMatchSource)
    , testCase "rejects constructors from the wrong type" $
        assertHasCode "E_PATTERN_TYPE_MISMATCH" (checkSource "bad" wrongConstructorSource)
    , testCase "rejects duplicate match branches" $
        assertHasCode "E_DUPLICATE_MATCH_BRANCH" (checkSource "bad" duplicateBranchSource)
    , testCase "rejects guide inheritance that targets an unknown parent" $
        assertHasCode "E_UNKNOWN_GUIDE_PARENT" (checkSource "bad" missingGuideParentSource)
    , testCase "rejects cyclic guide inheritance" $
        assertHasCode "E_GUIDE_CYCLE" (checkSource "bad" cyclicGuideSource)
    , testCase "rejects heterogeneous list literals" $
        assertHasCode "E_LIST_ITEM_TYPE" (checkSource "bad" heterogeneousListSource)
    , testCase "rejects equality over unsupported or mismatched types" $
        assertHasCode "E_EQUALITY_OPERAND" (checkSource "bad" badEqualitySource)
    , testCase "rejects integer comparison over non-integer operands" $
        assertHasCode "E_INTEGER_COMPARISON_OPERAND" (checkSource "bad" badIntegerComparisonSource)
    , testCase "rejects active script tags in safe views" $
        assertHasCode "E_VIEW_TAG" (checkSource "bad" unsafeScriptSource)
    , testCase "rejects raw host class escapes in safe views" $
        assertHasCode "E_UNSAFE_VIEW_ESCAPE" (checkSource "bad" hostClassSource)
    , testCase "rejects raw host style escapes in safe views" $
        assertHasCode "E_UNSAFE_VIEW_ESCAPE" (checkSource "bad" hostStyleSource)
    , testCase "rejects unsafe link targets in safe views" $
        assertHasCode "E_VIEW_LINK_TARGET" (checkSource "bad" unsafeLinkSource)
    , testCase "rejects links that do not resolve to a GET page route" $
        assertHasCode "E_VIEW_LINK_TARGET" (checkSource "bad" missingLinkRouteSource)
    , testCase "rejects forms that do not resolve to a page or redirect route" $
        assertHasCode "E_VIEW_FORM_METHOD" (checkSource "bad" missingFormRouteSource)
    , testCase "accepts compiler-known redirects" $
        case checkSource "redirect" redirectSource of
          Left err ->
            assertFailure ("expected redirect source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
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
          Right _ ->
            assertFailure "expected json diagnostic failure"
    , testCase "pretty rendering includes related locations" $
        case checkSource "bad" duplicateDeclSource of
          Left bundle -> do
            let rendered = renderDiagnosticBundle bundle
            assertBool "expected related marker" ("related previous declaration" `T.isInfixOf` rendered)
          Right _ ->
            assertFailure "expected duplicate declaration failure"
    ]

semanticEditTests :: TestTree
semanticEditTests =
  testGroup
    "semantic-edits"
    [ testCase "rename declaration updates call sites without touching shadowed locals" $
        case semanticEditSource (RenameDecl "id" "identity") "rename-decl" shadowedDeclRenameSource of
          Left err ->
            assertFailure ("expected semantic declaration rename to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            assertBool "expected renamed declaration" (any ((== "identity") . coreDeclName) (coreModuleDecls modl))
            case find ((== "use") . coreDeclName) (coreModuleDecls modl) of
              Just useDecl ->
                case coreDeclBody useDecl of
                  CVar _ _ "id" ->
                    pure ()
                  other ->
                    assertFailure ("expected shadowed local to remain unchanged, got " <> show other)
              Nothing ->
                assertFailure "expected use declaration"
            case find ((== "main") . coreDeclName) (coreModuleDecls modl) of
              Just mainDecl ->
                case coreDeclBody mainDecl of
                  CCall _ _ (CVar _ _ "identity") [CString _ "hello"] ->
                    pure ()
                  other ->
                    assertFailure ("expected renamed call site, got " <> show other)
              Nothing ->
                assertFailure "expected main declaration"
    , testCase "rename schema updates declarations, route contracts, and decode surfaces" $
        case semanticEditSource (RenameSchema "LeadSummary" "LeadDigest") "service" serviceSource of
          Left err ->
            assertFailure ("expected semantic schema rename to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            assertBool "expected renamed record schema" (any ((== "LeadDigest") . recordDeclName) (coreModuleRecordDecls modl))
            case find ((== "summarizeLead") . coreDeclName) (coreModuleDecls modl) of
              Just decl -> do
                assertEqual "renamed declaration type" (TFunction [TNamed "LeadRequest"] (TNamed "LeadDigest")) (coreDeclType decl)
                case coreDeclBody decl of
                  CDecodeJson _ (TNamed "LeadDigest") (CCall _ _ _ _) ->
                    pure ()
                  other ->
                    assertFailure ("expected renamed decode surface, got " <> show other)
              Nothing ->
                assertFailure "expected summarizeLead declaration"
            case coreModuleRouteDecls modl of
              [routeDecl] -> do
                assertEqual "renamed route response type" "LeadDigest" (routeDeclResponseType routeDecl)
                assertEqual "renamed route response boundary" (RouteBoundaryDecl "LeadDigest") (routeDeclResponseDecl routeDecl)
              other ->
                assertFailure ("expected one route declaration, got " <> show (length other))
    , testCase "semantic schema rename rejects compiler-known builtin schemas" $
        assertHasCode "E_SEMANTIC_EDIT_CONFLICT" (semanticEditSource (RenameSchema "AuthSession" "Session") "auth" authIdentitySource)
    ]

airTests :: TestTree
airTests =
  testGroup
    "air"
    [ testCase "air builds a stable graph with explicit identities" $
        case airSource "service" serviceSource of
          Left err ->
            assertFailure ("expected AIR generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right airModule -> do
            assertBool "expected top-level decl root" (AirNodeId "decl:summarizeLead" `elem` airModuleRootIds airModule)
            case findAirNode (AirNodeId "decl:summarizeLead") (airModuleNodes airModule) of
              Just node -> do
                assertEqual "decl kind" "decl" (airNodeKind node)
                assertBool "expected body ref" (("body", AirAttrNode (AirNodeId "expr:summarizeLead:body")) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected summarizeLead AIR node"
            case findAirNode (AirNodeId "expr:summarizeLead:body") (airModuleNodes airModule) of
              Just node -> do
                assertEqual "decode node kind" "decodeJson" (airNodeKind node)
                assertBool "expected rawJson ref" (("rawJson", AirAttrNode (AirNodeId "expr:summarizeLead:body.rawJson")) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected summarizeLead body AIR node"
            case findAirNode (AirNodeId "route:summarizeLeadRoute") (airModuleNodes airModule) of
              Just node -> do
                assertBool "expected route identity" (("identity", AirAttrText "route:summarizeLeadRoute") `elem` airNodeAttrs node)
                assertBool
                  "expected structured path declaration"
                  ( ("path", AirAttrObject [("pattern", AirAttrText "/lead/summary"), ("params", AirAttrList [])])
                      `elem` airNodeAttrs node
                  )
                assertBool
                  "expected structured body declaration"
                  (("body", AirAttrObject [("type", AirAttrText "LeadRequest")]) `elem` airNodeAttrs node)
                assertBool
                  "expected structured response declaration"
                  (("response", AirAttrObject [("type", AirAttrText "LeadSummary")]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected summarizeLeadRoute AIR node"
    , testCase "air keeps view flow edges attached to route identities" $
        case airSource "interactive" interactivePageSource of
          Left err ->
            assertFailure ("expected AIR generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right airModule -> do
            case find ((== "viewLink") . airNodeKind) (airModuleNodes airModule) of
              Just node -> do
                assertBool "expected link route ref" (("routeDecl", AirAttrNode (AirNodeId "route:leadRoute")) `elem` airNodeAttrs node)
                assertBool "expected link route identity" (("routeIdentity", AirAttrText "route:leadRoute") `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected viewLink AIR node"
            case find ((== "viewForm") . airNodeKind) (airModuleNodes airModule) of
              Just node -> do
                assertBool "expected form route ref" (("routeDecl", AirAttrNode (AirNodeId "route:createLeadRoute")) `elem` airNodeAttrs node)
                assertBool "expected form route identity" (("routeIdentity", AirAttrText "route:createLeadRoute") `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected viewForm AIR node"
    , testCase "air retains policy and projection graph identity" $
        case airSource "projection" classifiedProjectionSource of
          Left err ->
            assertFailure ("expected AIR generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right airModule -> do
            assertBool "expected policy root" (AirNodeId "policy:SupportDisclosure" `elem` airModuleRootIds airModule)
            assertBool "expected projection root" (AirNodeId "projection:SupportCustomer" `elem` airModuleRootIds airModule)
            case findAirNode (AirNodeId "policy:SupportDisclosure") (airModuleNodes airModule) of
              Just node ->
                assertBool
                  "expected policy classification refs"
                  (("allowedClassifications", AirAttrNodes [AirNodeId "policy-classification:SupportDisclosure:public", AirNodeId "policy-classification:SupportDisclosure:pii"]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected policy AIR node"
            case findAirNode (AirNodeId "projection:SupportCustomer") (airModuleNodes airModule) of
              Just node -> do
                assertBool "expected record link" (("recordDecl", AirAttrNode (AirNodeId "record:SupportCustomer")) `elem` airNodeAttrs node)
                assertBool "expected field refs" (("fields", AirAttrNodes [AirNodeId "projection-field:SupportCustomer:id", AirNodeId "projection-field:SupportCustomer:email", AirNodeId "projection-field:SupportCustomer:tier"]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected projection AIR node"
    , testCase "air retains repo memory guide inheritance and entry text" $
        case airSource "guide" guideSource of
          Left err ->
            assertFailure ("expected AIR generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right airModule -> do
            assertBool "expected guide root" (AirNodeId "guide:Worker" `elem` airModuleRootIds airModule)
            case findAirNode (AirNodeId "guide:Worker") (airModuleNodes airModule) of
              Just node -> do
                assertBool
                  "expected extends ref"
                  (("extends", AirAttrObject [("name", AirAttrText "Repo"), ("ref", AirAttrNode (AirNodeId "guide:Repo"))]) `elem` airNodeAttrs node)
                assertBool
                  "expected entry refs"
                  (("entries", AirAttrNodes [AirNodeId "guide-entry:Worker:verification"]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected worker guide AIR node"
            case findAirNode (AirNodeId "guide-entry:Worker:verification") (airModuleNodes airModule) of
              Just node ->
                assertBool
                  "expected guide entry value"
                  (("value", AirAttrText "Run bash scripts/verify-all.sh before finishing.") `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected worker verification guide entry AIR node"
    , testCase "air serialization is replay-friendly and deterministic" $
        case renderAirSourceJson "adt" adtSource of
          Left err ->
            assertFailure ("expected AIR json generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right rendered -> do
            let jsonText = LT.toStrict rendered
            assertBool "expected format version in json" ("\"format\":\"clasp-air-v1\"" `T.isInfixOf` jsonText)
            assertBool "expected decl id in json" ("\"decl:describe\"" `T.isInfixOf` jsonText)
            assertBool "expected branch id in json" ("\"expr:describe:body.branch0\"" `T.isInfixOf` jsonText)
            assertBool "expected explicit ref encoding" ("{\"ref\":\"expr:describe:body.subject\"}" `T.isInfixOf` jsonText)
            assertBool "expected constructor pattern binder id" ("\"expr:describe:body.branch1.pattern.binder0\"" `T.isInfixOf` jsonText)
    , testCase "airEntry emits a merged AIR graph for imported projects" $
        withProjectFiles "air-entry-imports" importSuccessFiles $ \root -> do
          result <- airEntry (root </> "Main.clasp")
          case result of
            Left err ->
              assertFailure ("expected imported project AIR generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
            Right airModule -> do
              assertEqual "merged module name" (ModuleName "Main") (airModuleName airModule)
              assertBool "expected imported declaration root" (AirNodeId "decl:formatUser" `elem` airModuleRootIds airModule)
              assertBool "expected main declaration root" (AirNodeId "decl:main" `elem` airModuleRootIds airModule)
    ]

contextTests :: TestTree
contextTests =
  testGroup
    "context"
    [ testCase "context graph keeps edges referentially intact and materializes builtin boundary schemas" $
        case renderContextSourceJson "interactive" interactivePageSource of
          Left err ->
            assertFailure ("expected context graph generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right rendered -> do
            let jsonText = LT.toStrict rendered
            graphValue <- case eitherDecodeStrictText jsonText of
              Left decodeErr ->
                assertFailure ("expected context graph json to decode:\n" <> decodeErr)
              Right value ->
                pure value
            assertEqual "format version" (Just (String "clasp-context-v1")) (lookupObjectKey "format" graphValue)
            let nodeIds = Set.fromList (extractNodeIds graphValue)
                edges = extractEdges graphValue
            assertBool "expected builtin Page schema node" (Set.member "schema:Page" nodeIds)
            assertBool "expected builtin Redirect schema node" (Set.member "schema:Redirect" nodeIds)
            assertBool
              "expected all edge endpoints to resolve to nodes"
              (all (\(fromId, toId) -> Set.member fromId nodeIds && Set.member toId nodeIds) edges)
    , testCase "context graph includes guide inheritance and guide entries" $
        case renderContextSourceJson "guide" guideSource of
          Left err ->
            assertFailure ("expected context graph generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right rendered -> do
            let jsonText = LT.toStrict rendered
            assertBool "expected repo guide node" ("\"guide:Repo\"" `T.isInfixOf` jsonText)
            assertBool "expected guide entry node" ("\"guide-entry:Repo:scope\"" `T.isInfixOf` jsonText)
            assertBool "expected guide extends edge" ("\"guide-extends\"" `T.isInfixOf` jsonText)
            assertBool "expected guide entry edge" ("\"guide-has-entry\"" `T.isInfixOf` jsonText)
    , testCase "claspc context writes the default context artifact when -o is omitted" $
        withProjectFiles "context-cli-default" [("Main.clasp", interactivePageSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = replaceExtension inputPath "context.json"
          (exitCode, _stdoutText, stderrText) <- runClaspc ["context", inputPath]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("claspc context failed:\n" <> stderrText)
          exists <- doesFileExist outputPath
          assertBool "expected default context artifact to be written" exists
          outputText <- TIO.readFile outputPath
          assertBool "expected context format marker" ("\"format\":\"clasp-context-v1\"" `T.isInfixOf` outputText)
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
    , testCase "lowering preserves list literals" $
        case lowerChecked "lists" listLiteralSource of
          Left err ->
            assertFailure ("expected list lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "roster" (lowerModuleDecls lowered) of
              Just (LValueDecl _ (LList [LString "Ada", LString "Grace"])) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered roster declaration: " <> show other)
    , testCase "lowering preserves list json codec boundaries" $
        case lowerChecked "list-json" listJsonBoundarySource of
          Left err ->
            assertFailure ("expected list json lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered -> do
            case findLowerDecl "encodeUsers" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["users"] (LCall (LVar "$encode_List_User") [LVar "users"])) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered encodeUsers declaration: " <> show other)
            case findLowerDecl "decodeUsers" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["raw"] (LCall (LVar "$decode_List_User") [LVar "raw"])) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered decodeUsers declaration: " <> show other)
    , testCase "lowering preserves local let expressions" $
        case lowerChecked "let" letExpressionSource of
          Left err ->
            assertFailure ("expected let lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "greeting" (lowerModuleDecls lowered) of
              Just (LValueDecl _ (LLet "message" (LString "Ada") (LVar "message"))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered let declaration: " <> show other)
    , testCase "lowering preserves equality operators" $
        case lowerChecked "equality" equalitySource of
          Left err ->
            assertFailure ("expected equality lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered -> do
            case findLowerDecl "sameNumber" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["left", "right"] (LEqual (LVar "left") (LVar "right"))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered sameNumber declaration: " <> show other)
            case findLowerDecl "differentFlag" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["left", "right"] (LNotEqual (LVar "left") (LVar "right"))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered differentFlag declaration: " <> show other)
    , testCase "lowering preserves integer comparison operators" $
        case lowerChecked "comparison" integerComparisonSource of
          Left err ->
            assertFailure ("expected comparison lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered -> do
            case findLowerDecl "isEarlier" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["left", "right"] (LLessThan (LVar "left") (LVar "right"))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered isEarlier declaration: " <> show other)
            case findLowerDecl "isLatest" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["left", "right"] (LGreaterThanOrEqual (LVar "left") (LVar "right"))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered isLatest declaration: " <> show other)
    , testCase "lowering preserves page and view primitives" $
        case lowerChecked "page" pageSource of
          Left err ->
            assertFailure ("expected page lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered -> do
            case findLowerDecl "welcomeView" (lowerModuleDecls lowered) of
              Just (LValueDecl _ (LViewStyled "inbox_shell" _)) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered welcomeView declaration: " <> show other)
            case findLowerDecl "home" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["req"] (LPage (LString "Inbox") (LVar "welcomeView"))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered page declaration: " <> show other)
    , testCase "lowering preserves interactive page primitives" $
        case lowerChecked "interactive" interactivePageSource of
          Left err ->
            assertFailure ("expected interactive page lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "home" (lowerModuleDecls lowered) of
              Just
                ( LFunctionDecl
                    _ ["req"]
                    (LPage (LString "Inbox") (LViewAppend (LViewLink routeLink "/lead/primary" _) (LViewForm routeForm "POST" "/leads" _)))
                  ) -> do
                    assertEqual
                      "link route contract"
                      ( LowerRouteContract
                          "leadRoute"
                          "route:leadRoute"
                          "GET"
                          "/lead/primary"
                          (RoutePathDecl "/lead/primary" [])
                          "Empty"
                          (Just (RouteBoundaryDecl "Empty"))
                          Nothing
                          Nothing
                          "Page"
                          (RouteBoundaryDecl "Page")
                          "page"
                      )
                      routeLink
                    assertEqual
                      "form route contract"
                      ( LowerRouteContract
                          "createLeadRoute"
                          "route:createLeadRoute"
                          "POST"
                          "/leads"
                          (RoutePathDecl "/leads" [])
                          "LeadCreate"
                          Nothing
                          (Just (RouteBoundaryDecl "LeadCreate"))
                          Nothing
                          "Redirect"
                          (RouteBoundaryDecl "Redirect")
                          "redirect"
                      )
                      routeForm
              other ->
                assertFailure ("unexpected lowered interactive page declaration: " <> show other)
    , testCase "lowering extracts machine-readable page flow artifacts" $
        case lowerChecked "interactive" interactivePageSource of
          Left err ->
            assertFailure ("expected interactive page lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            assertEqual
              "expected page flow summary"
              [ LowerPageFlow
                  { lowerPageFlowRouteName = "homeRoute"
                  , lowerPageFlowRouteIdentity = "route:homeRoute"
                  , lowerPageFlowPath = "/"
                  , lowerPageFlowHandlerName = "home"
                  , lowerPageFlowTitle = "Inbox"
                  , lowerPageFlowTexts = ["Open lead", "Save"]
                  , lowerPageFlowLinks =
                      [ LowerPageLink
                          { lowerPageLinkRouteName = "leadRoute"
                          , lowerPageLinkRouteIdentity = "route:leadRoute"
                          , lowerPageLinkPath = "/lead/primary"
                          , lowerPageLinkHref = "/lead/primary"
                          , lowerPageLinkLabel = "Open lead"
                          }
                      ]
                  , lowerPageFlowForms =
                      [ LowerPageForm
                          { lowerPageFormRouteName = "createLeadRoute"
                          , lowerPageFormRouteIdentity = "route:createLeadRoute"
                          , lowerPageFormPath = "/leads"
                          , lowerPageFormMethod = "POST"
                          , lowerPageFormAction = "/leads"
                          , lowerPageFormRequestType = "LeadCreate"
                          , lowerPageFormResponseType = "Redirect"
                          , lowerPageFormResponseKind = "redirect"
                          , lowerPageFormFields =
                              [ LowerFormField
                                  { lowerFormFieldName = "company"
                                  , lowerFormFieldInputKind = "text"
                                  , lowerFormFieldLabel = Nothing
                                  , lowerFormFieldValue = ""
                                  }
                              ]
                          , lowerPageFormSubmitLabels = ["Save"]
                          }
                      ]
                  }
              , LowerPageFlow
                  { lowerPageFlowRouteName = "leadRoute"
                  , lowerPageFlowRouteIdentity = "route:leadRoute"
                  , lowerPageFlowPath = "/lead/primary"
                  , lowerPageFlowHandlerName = "leadPage"
                  , lowerPageFlowTitle = "Lead"
                  , lowerPageFlowTexts = ["Primary"]
                  , lowerPageFlowLinks = []
                  , lowerPageFlowForms = []
                  }
              ]
              (lowerPageFlows lowered)
    , testCase "lowering preserves redirect responses" $
        case lowerChecked "redirect" redirectSource of
          Left err ->
            assertFailure ("expected redirect lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "submitLead" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["req"] (LRedirect "/inbox")) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered redirect declaration: " <> show other)
    , testCase "lowering preserves auth identity primitive field access" $
        case lowerChecked "auth" authIdentitySource of
          Left err ->
            assertFailure ("expected auth identity lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "sessionTenantId" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["session"] (LFieldAccess (LFieldAccess (LVar "session") "tenant") "id")) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered auth identity declaration: " <> show other)
    ]

compileTests :: TestTree
compileTests =
  testGroup
    "compile"
    [ testCase "compile emits JavaScript for a checked module" $
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
    , testCase "compile lowers list literals to JavaScript arrays" $
        case compileSource "lists" listLiteralSource of
          Left err ->
            assertFailure ("expected list compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted ->
            assertBool "expected array literal" ("[\"Ada\", \"Grace\"]" `T.isInfixOf` emitted)
    , testCase "compile emits list json codecs for explicit encode and decode boundaries" $
        case compileSource "list-json" listJsonBoundarySource of
          Left err ->
            assertFailure ("expected list json compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected list decoder" ("function $decode_List_User(jsonText)" `T.isInfixOf` emitted)
            assertBool "expected list encoder" ("function $encode_List_User(value)" `T.isInfixOf` emitted)
    , testCase "compile evaluates local let expressions" $
        case compileSource "let" letExpressionSource of
          Left err ->
            assertFailure ("expected let compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected let IIFE emission" ("const message = \"Ada\";" `T.isInfixOf` emitted)
            let compiledPath = "dist/let-expression.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(compiledModule.greeting);"
                ]
            assertEqual "expected let result" "Ada" runtimeOutput
    , testCase "compile lowers equality operators to JavaScript and evaluates them" $
        case compileSource "equality" equalitySource of
          Left err ->
            assertFailure ("expected equality compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected strict equality emission" ("(left === right)" `T.isInfixOf` emitted)
            assertBool "expected strict inequality emission" ("(left !== right)" `T.isInfixOf` emitted)
            let compiledPath = "dist/equality-expression.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(JSON.stringify({"
                , "  number: compiledModule.sameNumber(7, 7),"
                , "  word: compiledModule.sameWord(\"Ada\", \"Grace\"),"
                , "  flag: compiledModule.differentFlag(true, false),"
                , "  main: compiledModule.main"
                , "}));"
                ]
            assertEqual "expected equality runtime result" "{\"number\":true,\"word\":false,\"flag\":true,\"main\":true}" runtimeOutput
    , testCase "compile lowers integer comparison operators to JavaScript and evaluates them" $
        case compileSource "comparison" integerComparisonSource of
          Left err ->
            assertFailure ("expected integer comparison compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected less-than emission" ("(left < right)" `T.isInfixOf` emitted)
            assertBool "expected less-than-or-equal emission" ("(left <= right)" `T.isInfixOf` emitted)
            assertBool "expected greater-than emission" ("(left > right)" `T.isInfixOf` emitted)
            assertBool "expected greater-than-or-equal emission" ("(left >= right)" `T.isInfixOf` emitted)
            let compiledPath = "dist/integer-comparison-expression.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(JSON.stringify({"
                , "  earlier: compiledModule.isEarlier(3, 5),"
                , "  boundary: compiledModule.isAtMost(5, 5),"
                , "  later: compiledModule.isLater(7, 5),"
                , "  latest: compiledModule.isLatest(7, 7),"
                , "  main: compiledModule.main"
                , "}));"
                ]
            assertEqual "expected integer comparison runtime result" "{\"earlier\":true,\"boundary\":true,\"later\":true,\"latest\":true,\"main\":true}" runtimeOutput
    , testCase "compile round-trips list values through generated json codecs" $
        case compileSource "list-json" listJsonBoundarySource of
          Left err ->
            assertFailure ("expected list json compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/list-json-boundaries.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            encoded <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "const raw = compiledModule.encodeUsers(compiledModule.defaultUsers);"
                , "const decoded = compiledModule.decodeUsers(raw);"
                , "console.log(JSON.stringify({ raw, decoded }));"
                ]
            assertBool "expected encoded list payload" ("\\\"name\\\":\\\"Ada\\\"" `T.isInfixOf` encoded)
            assertBool "expected decoded first user" ("\"name\":\"Ada\"" `T.isInfixOf` encoded)
            assertBool "expected decoded second user boolean" ("\"active\":false" `T.isInfixOf` encoded)
    , testCase "compile emits list-focused helpers for the list example file" $ do
        source <- readExampleSource "lists.clasp"
        case compileSource "examples/lists.clasp" source of
          Left err ->
            assertFailure ("expected list example compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected record array literal" ("[{ name: \"Ada\", active: true }, { name: \"Grace\", active: false }]" `T.isInfixOf` emitted)
            assertBool "expected nested list literal" ("[[10, 20], [30]]" `T.isInfixOf` emitted)
            assertBool "expected list decoder" ("function $decode_List_User(jsonText)" `T.isInfixOf` emitted)
            assertBool "expected list encoder" ("function $encode_List_User(value)" `T.isInfixOf` emitted)
            assertBool "expected nested list schema" ("kind: \"list\", item: { kind: \"list\", item: $claspSchema_Int }" `T.isInfixOf` emitted)
    , testCase "compile evaluates the let example file" $ do
        source <- readExampleSource "let.clasp"
        case compileSource "examples/let.clasp" source of
          Left err ->
            assertFailure ("expected let example compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected let binding from main" ("const current = Busy(\"loading\");" `T.isInfixOf` emitted)
            assertBool "expected let binding from match branch" ("const copy = note;" `T.isInfixOf` emitted)
            let compiledPath = "dist/let-example.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(compiledModule.main);"
                ]
            assertEqual "expected let example result" "loading" runtimeOutput
    , testCase "compile emits runtime bindings, codecs, and route metadata" $
        case compileSource "service" serviceSource of
          Left err ->
            assertFailure ("expected service compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected foreign runtime wrapper" ("function mockLeadSummaryModel($0) { return $claspCallHostBinding(\"mockLeadSummaryModel\", [$0]); }" `T.isInfixOf` emitted)
            assertBool "expected host binding manifest export" ("export const __claspHostBindings = [" `T.isInfixOf` emitted)
            assertBool "expected host binding adapter export" ("export function __claspAdaptHostBindings" `T.isInfixOf` emitted)
            assertBool "expected host binding manifest schema" ("schema: $claspSchema_LeadRequest" `T.isInfixOf` emitted)
            assertBool "expected host binding manifest fromHost adapter" ("fromHost(value, path = \"value\")" `T.isInfixOf` emitted)
            assertBool "expected host binding manifest toHost adapter" ("toHost(value, path = \"result\")" `T.isInfixOf` emitted)
            assertBool "expected host binding manifest return type" ("returns: {" `T.isInfixOf` emitted)
            assertBool "expected enum decoder" ("function $decode_LeadPriority" `T.isInfixOf` emitted)
            assertBool "expected internal enum validator" ("function $validateInternal_LeadPriority" `T.isInfixOf` emitted)
            assertBool "expected record decoder" ("function $decode_LeadSummary" `T.isInfixOf` emitted)
            assertBool "expected record encoder to validate internal values" ("function $encode_LeadSummary(value) { return JSON.stringify($serialize_LeadSummary($validateInternal_LeadSummary(value, \"value\"))); }" `T.isInfixOf` emitted)
            assertBool "expected route registry" ("export const __claspRoutes" `T.isInfixOf` emitted)
            assertBool "expected seeded fixture export" ("export const __claspSeededFixtures = [" `T.isInfixOf` emitted)
            assertBool "expected route path" ("\"/lead/summary\"" `T.isInfixOf` emitted)
            assertBool "expected request schema metadata" ("requestSchema: $claspSchema_LeadRequest" `T.isInfixOf` emitted)
            assertBool "expected response schema metadata in seeded fixtures" ("responseSchema: $claspSchema_LeadSummary" `T.isInfixOf` emitted)
            assertBool "expected response seed metadata in seeded fixtures" ("responseSeed: { summary: \"seed\", priority: \"Low\", followUpRequired: false }" `T.isInfixOf` emitted)
            assertBool "expected route identity metadata" ("id: \"route:summarizeLeadRoute\"" `T.isInfixOf` emitted)
            assertBool "expected path declaration metadata" ("pathDecl: { pattern: \"/lead/summary\", params: [] }" `T.isInfixOf` emitted)
            assertBool "expected body declaration metadata" ("bodyDecl: { type: \"LeadRequest\", schema: $claspSchema_LeadRequest }" `T.isInfixOf` emitted)
            assertBool "expected response declaration metadata" ("responseDecl: { type: \"LeadSummary\", schema: $claspSchema_LeadSummary }" `T.isInfixOf` emitted)
            assertBool "expected route client export" ("export const summarizeLeadRouteClient = {" `T.isInfixOf` emitted)
            assertBool "expected route clients registry" ("export const __claspRouteClients = [" `T.isInfixOf` emitted)
            assertBool "expected schema registry export" ("export const __claspSchemas = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected schema registry entry" ("\"LeadRequest\": {" `T.isInfixOf` emitted)
            assertBool "expected generated binding contract export" ("export const __claspBindings = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected generated binding contract version" ("version: 1," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract routes" ("routes: __claspRoutes," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract host bindings" ("hostBindings: __claspHostBindings," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract schemas" ("schemas: __claspSchemas," `T.isInfixOf` emitted)
            assertBool "expected request preparation helper" ("prepareRequest(value) {" `T.isInfixOf` emitted)
            assertBool "expected response parsing helper" ("async parseResponse(response) {" `T.isInfixOf` emitted)
    , testCase "compile emits field classifications and projection disclosure metadata" $
        case compileSource "projection" classifiedProjectionSource of
          Left err ->
            assertFailure ("expected classified projection source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected classified source field metadata" ("email: { schema: $claspSchema_Str, classification: \"pii\" }" `T.isInfixOf` emitted)
            assertBool "expected projection metadata" ("classificationPolicy: \"SupportDisclosure\"" `T.isInfixOf` emitted)
            assertBool "expected projection source metadata" ("projectionSource: \"Customer\"" `T.isInfixOf` emitted)
            assertBool "expected foreign manifest to use projection schema" ("schema: $claspSchema_SupportCustomer" `T.isInfixOf` emitted)
    , testCase "compile emits safe page rendering helpers and page route metadata" $
        case compileSource "page" pageSource of
          Left err ->
            assertFailure ("expected page compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected page renderer" ("function $render_Page" `T.isInfixOf` emitted)
            assertBool "expected render mode export" ("export { __claspPageRenderModes };" `T.isInfixOf` emitted)
            assertBool "expected opt-in render helper" ("export function __claspRenderPage" `T.isInfixOf` emitted)
            assertBool "expected page head helper" ("export function __claspPageHead" `T.isInfixOf` emitted)
            assertBool "expected view renderer" ("function $claspRenderView" `T.isInfixOf` emitted)
            assertBool "expected static asset strategy export" ("export const __claspStaticAssetStrategy" `T.isInfixOf` emitted)
            assertBool "expected static asset registry" ("export const __claspStaticAssets" `T.isInfixOf` emitted)
            assertBool "expected style bundle registry" ("export const __claspStyleBundles" `T.isInfixOf` emitted)
            assertBool "expected head strategy export" ("export const __claspHeadStrategy" `T.isInfixOf` emitted)
            assertBool "expected default viewport meta" ("viewport: \"width=device-width, initial-scale=1\"" `T.isInfixOf` emitted)
            assertBool "expected generated stylesheet href" ("href: \"/assets/clasp/Main.styles.css\"" `T.isInfixOf` emitted)
            assertBool "expected page response kind" ("responseKind: \"page\"" `T.isInfixOf` emitted)
            assertBool "expected page route encoder" ("encodeResponse: $render_Page" `T.isInfixOf` emitted)
    , testCase "compile emits link and form renderers for interactive pages" $
        case compileSource "interactive" interactivePageSource of
          Left err ->
            assertFailure ("expected interactive page compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected link renderer" ("case \"link\":" `T.isInfixOf` emitted)
            assertBool "expected form renderer" ("case \"form\":" `T.isInfixOf` emitted)
            assertBool "expected input renderer" ("case \"input\":" `T.isInfixOf` emitted)
            assertBool "expected submit renderer" ("case \"submit\":" `T.isInfixOf` emitted)
            assertBool "expected link contract attrs" ("data-clasp-route=" `T.isInfixOf` emitted)
            assertBool "expected link route identity attrs" ("data-clasp-route-id=" `T.isInfixOf` emitted)
            assertBool "expected link query declaration metadata" ("queryDecl: { type: \"Empty\", schema: $claspSchema_Empty }" `T.isInfixOf` emitted)
            assertBool "expected form declaration metadata" ("formDecl: { type: \"LeadCreate\", schema: $claspSchema_LeadCreate }" `T.isInfixOf` emitted)
            assertBool "expected redirect contract metadata" ("responseKind: \"redirect\"" `T.isInfixOf` emitted)
            assertBool "expected ui graph export" ("export const __claspUiGraph = [" `T.isInfixOf` emitted)
            assertBool "expected navigation graph export" ("export const __claspNavigationGraph = [" `T.isInfixOf` emitted)
            assertBool "expected action graph export" ("export const __claspActionGraph = [" `T.isInfixOf` emitted)
            assertBool "expected link label in ui graph" ("label: \"Open lead\"" `T.isInfixOf` emitted)
            assertBool "expected form field metadata in action graph" ("fields: [{ name: \"company\", inputKind: \"text\", label: null, value: \"\" }]" `T.isInfixOf` emitted)
    , testCase "compile emits redirect helpers and redirect route metadata" $
        case compileSource "redirect" redirectSource of
          Left err ->
            assertFailure ("expected redirect compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected redirect validator" ("function $claspExpectRedirect" `T.isInfixOf` emitted)
            assertBool "expected redirect encoder" ("encodeResponse: $prepare_Redirect" `T.isInfixOf` emitted)
            assertBool "expected redirect response kind" ("responseKind: \"redirect\"" `T.isInfixOf` emitted)
    , testCase "compile emits auth identity codecs and preserves nested field access" $
        case compileSource "auth" authIdentitySource of
          Left err ->
            assertFailure ("expected auth identity compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected auth session decoder" ("function $decode_AuthSession" `T.isInfixOf` emitted)
            assertBool "expected principal schema" ("const $claspSchema_Principal" `T.isInfixOf` emitted)
            assertBool "expected auth session constructor object" ("sessionId: \"sess-1\"" `T.isInfixOf` emitted)
            assertBool "expected nested field access" ("((session).tenant).id" `T.isInfixOf` emitted)
    , testCase "compile round-trips auth identity primitives through JSON codecs" $
        case compileSource "auth" authIdentitySource of
          Left err ->
            assertFailure ("expected auth identity compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/auth-identities.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            encoded <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "const raw = compiledModule.encodeAudit(compiledModule.defaultAudit);"
                , "const decoded = compiledModule.decodeAudit(raw);"
                , "console.log(JSON.stringify({"
                , "  sessionId: decoded.session.sessionId,"
                , "  tenantId: compiledModule.sessionTenantId(decoded.session),"
                , "  resource: decoded.resource.resourceType + ':' + decoded.resource.resourceId"
                , "}));"
                ]
            assertBool "expected decoded auth session" ("\"sessionId\":\"sess-1\"" `T.isInfixOf` encoded)
            assertBool "expected tenant id" ("\"tenantId\":\"tenant-1\"" `T.isInfixOf` encoded)
            assertBool "expected resource identity" ("\"resource\":\"lead:lead-1\"" `T.isInfixOf` encoded)
    , testCase "generated auth identity contracts stay available across app runtimes" $
        case compileSource "auth-runtime" authIdentitySource of
          Left err ->
            assertFailure ("expected auth identity compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/auth-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteServerRuntimePath <- makeAbsolute "runtime/bun/server.mjs"
            absoluteWorkerRuntimePath <- makeAbsolute "runtime/bun/worker.mjs"
            runtimeOutput <- runNodeScript (authIdentityRuntimeScript absoluteCompiledPath absoluteServerRuntimePath absoluteWorkerRuntimePath)
            assertEqual
              "expected auth identity contract exports across server and worker runtimes"
              "{\"contractVersion\":1,\"schemaNames\":[\"AuditEnvelope\",\"AuthSession\",\"Bool\",\"Int\",\"Principal\",\"ResourceIdentity\",\"Str\",\"Tenant\"],\"sessionSchemaKind\":\"record\",\"principalFieldType\":\"Principal\",\"tenantSeed\":\"seed\",\"workerSessionId\":\"sess-1\",\"workerPrincipalId\":\"user-1\",\"workerTenantId\":\"tenant-1\",\"workerResource\":\"lead:lead-1\"}"
              runtimeOutput
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
    , testCase "compileEntry renders an inbox-style shared page safely" $
        withProjectFiles "render-inbox-page" inboxPageFiles $ \root -> do
          result <- compileEntry (root </> "Main.clasp")
          case result of
            Left err ->
              assertFailure ("expected inbox page project to compile:\n" <> T.unpack (renderDiagnosticBundle err))
            Right emitted -> do
              let compiledPath = root </> "compiled.mjs"
              TIO.writeFile compiledPath emitted
              renderedHtml <- runNodeModule compiledPath
              assertBool "expected doctype" ("<!DOCTYPE html>" `T.isInfixOf` renderedHtml)
              assertBool "expected viewport head tag" ("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" `T.isInfixOf` renderedHtml)
              assertBool "expected title" ("<title>Inbox</title>" `T.isInfixOf` renderedHtml)
              assertBool "expected stylesheet link" ("<link rel=\"stylesheet\" href=\"/assets/clasp/Main.styles.css\" data-clasp-asset-kind=\"style-bundle\" data-clasp-style-bundle=\"module:Main:styles\">" `T.isInfixOf` renderedHtml)
              assertBool "expected escaped subject" ("&lt;Quarterly &lt;review&gt;&gt;" `T.isInfixOf` renderedHtml)
              assertBool "expected escaped ampersand" ("Escaped &amp; archived" `T.isInfixOf` renderedHtml)
              assertBool "expected explicit style ref wrapper" ("data-clasp-style=\"inbox_shell\"" `T.isInfixOf` renderedHtml)
              assertBool "expected stable default html without flow metadata attrs" (not ("data-clasp-route=" `T.isInfixOf` renderedHtml))
    , testCase "generated page head and style bundle assets stay machine-readable" $
        case compileSource "page-head-assets" pageSource of
          Left err ->
            assertFailure ("expected page compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/page-head-assets/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "runtime/bun/server.mjs"
            runtimeOutput <- runNodeScript (pageAssetRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected generated asset, head, and style bundle strategy"
              "{\"assetBasePath\":\"/assets\",\"generatedAssetBasePath\":\"/assets/clasp\",\"headTitle\":\"Inbox\",\"headViewport\":\"width=device-width, initial-scale=1\",\"headStylesheet\":\"/assets/clasp/Main.styles.css\",\"bundleId\":\"module:Main:styles\",\"bundleHref\":\"/assets/clasp/Main.styles.css\",\"bundleRefs\":[\"inbox_shell\"],\"assetContentType\":\"text/css; charset=utf-8\",\"assetHasRefComment\":true}"
              runtimeOutput
    , testCase "opt-in page render mode emits flow metadata while default html stays stable" $
        case compileSource "interactive-render" interactivePageSource of
          Left err ->
            assertFailure ("expected interactive page compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/interactive-render/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            renderOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "const page = compiledModule.home({});"
                , "const defaultHtml = compiledModule.__claspRenderPage(page);"
                , "const flowHtml = compiledModule.__claspRenderPage(page, compiledModule.__claspPageRenderModes.htmlWithFlowMetadata);"
                , "console.log(JSON.stringify({"
                , "  defaultHasRoute: defaultHtml.includes('data-clasp-route='),"
                , "  defaultHasFlow: defaultHtml.includes('data-clasp-flow='),"
                , "  flowHasRoute: flowHtml.includes('data-clasp-route='),"
                , "  flowHasFlow: flowHtml.includes('data-clasp-flow='),"
                , "  sameTitle: defaultHtml.includes('<title>Inbox</title>') && flowHtml.includes('<title>Inbox</title>')"
                , "}));"
                ]
            assertEqual
              "expected stable default html and opt-in metadata projection"
              "{\"defaultHasRoute\":false,\"defaultHasFlow\":false,\"flowHasRoute\":true,\"flowHasFlow\":true,\"sameTitle\":true}"
              renderOutput
    , testCase "runtime preserves numeric-looking Str values in page form and query flows" $
        withProjectFiles "page-form-runtime" pageFormRuntimeFiles $ \root -> do
          result <- compileEntry (root </> "Main.clasp")
          case result of
            Left err ->
              assertFailure ("expected page form project to compile:\n" <> T.unpack (renderDiagnosticBundle err))
            Right emitted -> do
              let compiledPath = root </> "compiled.mjs"
              TIO.writeFile compiledPath emitted
              absoluteCompiledPath <- makeAbsolute compiledPath
              absoluteRuntimePath <- makeAbsolute "runtime/bun/server.mjs"
              runtimeOutput <- runNodeScript (pageFormRuntimeScript absoluteCompiledPath absoluteRuntimePath)
              assertEqual
                "expected query decode, form decode, and invalid form failure"
                "{\"query\":{\"customerId\":\"00123\",\"quantity\":7},\"form\":{\"customerId\":\"00123\",\"quantity\":7},\"html\":\"<!DOCTYPE html><html><head><meta charset=\\\"utf-8\\\"><meta name=\\\"viewport\\\" content=\\\"width=device-width, initial-scale=1\\\"><title>Order</title></head><body>00123</body></html>\",\"invalid\":\"quantity must be an integer\"}"
                runtimeOutput
    , testCase "generated json route clients prepare requests and decode responses" $
        case compileSource "service-client" serviceSource of
          Left err ->
            assertFailure ("expected service compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/service-client/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript (routeClientJsonRuntimeScript absoluteCompiledPath)
            assertEqual
              "expected json route client transport contract"
              "{\"method\":\"POST\",\"path\":\"/lead/summary\",\"href\":\"/lead/summary\",\"contentType\":\"application/json\",\"body\":\"{\\\"company\\\":\\\"Acme\\\",\\\"budget\\\":42,\\\"priorityHint\\\":\\\"high\\\"}\",\"parsedSummary\":\"Ready\",\"parsedPriority\":\"High\",\"parsedFollowUpRequired\":true}"
              runtimeOutput
    , testCase "client runtime executes generated json route clients over fetch" $
        case compileSource "service-client-runtime" serviceSource of
          Left err ->
            assertFailure ("expected service compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/service-client-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "runtime/bun/client.mjs"
            runtimeOutput <- runNodeScript (routeClientFetchRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected json route client fetch runtime contract"
              "{\"preparedUrl\":\"https://app.example.test/lead/summary\",\"preparedCredentials\":\"same-origin\",\"fetchUrl\":\"https://app.example.test/lead/summary\",\"fetchMethod\":\"POST\",\"fetchContentType\":\"application/json\",\"fetchBody\":\"{\\\"company\\\":\\\"Acme\\\",\\\"budget\\\":42,\\\"priorityHint\\\":\\\"high\\\"}\",\"parsedSummary\":\"Queued\",\"parsedPriority\":\"Medium\",\"parsedFollowUpRequired\":false}"
              runtimeOutput
    , testCase "worker runtime registers typed jobs against generated schema contracts" $
        case compileSource "service-worker-runtime" serviceSource of
          Left err ->
            assertFailure ("expected service compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/service-worker-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "runtime/bun/worker.mjs"
            runtimeOutput <- runNodeScript (workerJobRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected typed worker job contract and dispatch"
              "{\"contractVersion\":1,\"schemaKind\":\"record\",\"seedBudget\":0,\"jobCount\":1,\"jobInputType\":\"LeadRequest\",\"jobOutputType\":\"LeadSummary\",\"outputSchemaKind\":\"record\",\"outputSeedPriority\":\"Low\",\"resultPriority\":\"high\",\"resultFollowUpRequired\":true,\"invalid\":\"budget must be an integer\"}"
              runtimeOutput
    , testCase "generated page route clients build query and form requests" $
        withProjectFiles "route-client-page-runtime" pageFormRuntimeFiles $ \root -> do
          result <- compileEntry (root </> "Main.clasp")
          case result of
            Left err ->
              assertFailure ("expected page form project to compile:\n" <> T.unpack (renderDiagnosticBundle err))
            Right emitted -> do
              let compiledPath = root </> "compiled.mjs"
              TIO.writeFile compiledPath emitted
              absoluteCompiledPath <- makeAbsolute compiledPath
              runtimeOutput <- runNodeScript (routeClientPageRuntimeScript absoluteCompiledPath)
              assertEqual
                "expected page route client transport contract"
                "{\"lookupHref\":\"/order?customerId=00123&quantity=7\",\"lookupBody\":null,\"submitContentType\":\"application/x-www-form-urlencoded\",\"submitBody\":\"customerId=00123&quantity=7\",\"pageHtml\":\"<!DOCTYPE html><html><head><meta charset=\\\"utf-8\\\"><title>Order</title></head><body>00123</body></html>\"}"
                runtimeOutput
    , testCase "generated redirect route clients decode redirect responses" $
        withProjectFiles "route-client-redirect-runtime" pageRedirectRuntimeFiles $ \root -> do
          result <- compileEntry (root </> "Main.clasp")
          case result of
            Left err ->
              assertFailure ("expected redirect project to compile:\n" <> T.unpack (renderDiagnosticBundle err))
            Right emitted -> do
              let compiledPath = root </> "compiled.mjs"
              TIO.writeFile compiledPath emitted
              absoluteCompiledPath <- makeAbsolute compiledPath
              runtimeOutput <- runNodeScript (routeClientRedirectRuntimeScript absoluteCompiledPath)
              assertEqual
                "expected redirect route client response contract"
                "{\"method\":\"POST\",\"path\":\"/submit\",\"body\":\"\",\"redirect\":{\"status\":303,\"location\":\"/inbox\"}}"
                runtimeOutput
    , testCase "client runtime preserves page html and manual redirect parsing" $
        withProjectFiles "route-client-browser-runtime" pageFormRuntimeFiles $ \pageRoot -> do
          pageResult <- compileEntry (pageRoot </> "Main.clasp")
          case pageResult of
            Left err ->
              assertFailure ("expected page form project to compile:\n" <> T.unpack (renderDiagnosticBundle err))
            Right pageEmitted -> do
              let pageCompiledPath = pageRoot </> "compiled.mjs"
              TIO.writeFile pageCompiledPath pageEmitted
              absolutePageCompiledPath <- makeAbsolute pageCompiledPath
              withProjectFiles "route-client-browser-redirect-runtime" pageRedirectRuntimeFiles $ \redirectRoot -> do
                redirectResult <- compileEntry (redirectRoot </> "Main.clasp")
                case redirectResult of
                  Left err ->
                    assertFailure ("expected redirect project to compile:\n" <> T.unpack (renderDiagnosticBundle err))
                  Right redirectEmitted -> do
                    let redirectCompiledPath = redirectRoot </> "compiled.mjs"
                    TIO.writeFile redirectCompiledPath redirectEmitted
                    absoluteRedirectCompiledPath <- makeAbsolute redirectCompiledPath
                    absoluteRuntimePath <- makeAbsolute "runtime/bun/client.mjs"
                    runtimeOutput <- runNodeScript (routeClientBrowserRuntimeScript absolutePageCompiledPath absoluteRedirectCompiledPath absoluteRuntimePath)
                    assertEqual
                      "expected page html fetch and manual redirect mode"
                      "{\"pageUrl\":\"https://app.example.test/order?customerId=00123&quantity=7\",\"pageMethod\":\"GET\",\"pageHtml\":\"<!DOCTYPE html><html><head><meta charset=\\\"utf-8\\\"><title>Order</title></head><body>00123</body></html>\",\"redirectUrl\":\"https://app.example.test/submit\",\"redirectMode\":\"manual\",\"redirectLocation\":\"/inbox\",\"redirectStatus\":303}"
                      runtimeOutput
    , testCase "runtime turns redirect route results into http redirects" $
        withProjectFiles "page-redirect-runtime" pageRedirectRuntimeFiles $ \root -> do
          result <- compileEntry (root </> "Main.clasp")
          case result of
            Left err ->
              assertFailure ("expected redirect project to compile:\n" <> T.unpack (renderDiagnosticBundle err))
            Right emitted -> do
              let compiledPath = root </> "compiled.mjs"
              TIO.writeFile compiledPath emitted
              absoluteCompiledPath <- makeAbsolute compiledPath
              absoluteRuntimePath <- makeAbsolute "runtime/bun/server.mjs"
              runtimeOutput <- runNodeScript (pageRedirectRuntimeScript absoluteCompiledPath absoluteRuntimePath)
              assertEqual
                "expected redirect response contract"
                "{\"status\":303,\"location\":\"/inbox\"}"
                runtimeOutput
    , testCase "lead inbox app supports intake, inbox, detail, and invalid form flows" $ do
        result <- compileEntry ("examples" </> "lead-app" </> "Main.clasp")
        case result of
          Left err ->
            assertFailure ("expected lead inbox app to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/lead-app/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "runtime/bun/server.mjs"
            runtimeOutput <- runNodeScript (leadInboxRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected landing, create, inbox, detail, review, and invalid form behavior"
              "{\"contractKind\":\"clasp-generated-bindings\",\"contractVersion\":1,\"contractRouteCount\":6,\"contractAssetBasePath\":\"/assets\",\"manifestTypes\":[\"LeadIntake\",\"LeadIntake -> LeadSummary\",\"Empty -> Str\",\"LeadReview\"],\"structuredModelArg\":true,\"structuredStoreArg\":true,\"landingHasForm\":true,\"createdHasLead\":true,\"inboxHasLink\":true,\"detailHasLead\":true,\"reviewHasNote\":true,\"invalid\":\"budget must be an integer\"}"
              runtimeOutput
    , testCase "lead app browser shell keeps POST results on stable GET history entries" $ do
        absoluteShellPath <- makeAbsolute ("examples" </> "lead-app" </> "app-shell.mjs")
        shellOutput <- runNodeScript (leadAppBrowserShellScript absoluteShellPath)
        assertEqual
          "expected browser shell to preserve stable GET history across create and review flows"
          "{\"history\":[\"https://app.example.test/\",\"https://app.example.test/inbox\",\"https://app.example.test/lead/primary\"],\"fetches\":[{\"method\":\"POST\",\"pathname\":\"/leads\"},{\"method\":\"GET\",\"pathname\":\"/inbox\"},{\"method\":\"GET\",\"pathname\":\"/lead/primary\"},{\"method\":\"POST\",\"pathname\":\"/review\"},{\"method\":\"GET\",\"pathname\":\"/lead/primary\"},{\"method\":\"GET\",\"pathname\":\"/inbox\"},{\"method\":\"GET\",\"pathname\":\"/lead/primary\"}],\"afterCreate\":\"https://app.example.test/\",\"afterReview\":\"https://app.example.test/lead/primary\",\"afterRefresh\":\"https://app.example.test/lead/primary\",\"afterBack\":\"https://app.example.test/inbox\",\"afterForward\":\"https://app.example.test/lead/primary\",\"title\":\"Primary lead\",\"html\":\"<main><h1>Primary lead</h1></main>\"}"
          shellOutput
    , testCase "lead inbox app emits machine-readable ui, navigation, and action graphs" $ do
        result <- compileEntry ("examples" </> "lead-app" </> "Main.clasp")
        case result of
          Left err ->
            assertFailure ("expected lead inbox app to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/lead-app/compiled-graph.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            graphOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "const uiLanding = compiledModule.__claspUiGraph.find((page) => page.routeName === 'landingRoute');"
                , "const action = compiledModule.__claspActionGraph.find((edge) => edge.actionRoute === 'createLeadRoute');"
                , "const navigation = compiledModule.__claspNavigationGraph.find((edge) => edge.targetRoute === 'secondaryLeadRoute');"
                , "console.log(JSON.stringify({"
                , "  pageCount: compiledModule.__claspUiGraph.length,"
                , "  navigationCount: compiledModule.__claspNavigationGraph.length,"
                , "  actionCount: compiledModule.__claspActionGraph.length,"
                , "  landingTitle: uiLanding?.title ?? null,"
                , "  landingTexts: uiLanding?.texts ?? [],"
                , "  landingForms: uiLanding?.forms ?? [],"
                , "  reviewSubmit: compiledModule.__claspActionGraph.find((edge) => edge.actionRoute === 'reviewLeadRoute')?.submitLabels ?? [],"
                , "  navigationLabel: navigation?.label ?? null"
                , "}));"
                ]
            assertEqual
              "expected exported ui graphs to summarize benchmark app flows"
              "{\"pageCount\":6,\"navigationCount\":10,\"actionCount\":5,\"landingTitle\":\"Lead inbox\",\"landingTexts\":[\"Lead inbox\",\"Capture a lead, score it once, and review it on the server.\",\"New lead\",\"Company\",\"Contact\",\"Budget\",\"Segment\",\"Create lead\",\"InboxSnapshot(...).headline\",\"InboxSnapshot(...).primaryLeadLabel\",\"InboxSnapshot(...).secondaryLeadLabel\",\"Open the inbox page\"],\"landingForms\":[{\"routeName\":\"createLeadRoute\",\"routeId\":\"route:createLeadRoute\",\"path\":\"/leads\",\"method\":\"POST\",\"action\":\"/leads\",\"requestType\":\"LeadIntake\",\"responseType\":\"Page\",\"responseKind\":\"page\",\"fields\":[{\"name\":\"company\",\"inputKind\":\"text\",\"label\":\"Company\",\"value\":\"\"},{\"name\":\"contact\",\"inputKind\":\"text\",\"label\":\"Contact\",\"value\":\"\"},{\"name\":\"budget\",\"inputKind\":\"number\",\"label\":\"Budget\",\"value\":\"\"},{\"name\":\"segment\",\"inputKind\":\"text\",\"label\":\"Segment\",\"value\":\"\"}],\"submitLabels\":[\"Create lead\"]}],\"reviewSubmit\":[\"Save review\"],\"navigationLabel\":\"InboxSnapshot(...).secondaryLeadLabel\"}"
              graphOutput
    , testCase "lead inbox app exports response-side seeded fixtures for routes" $ do
        result <- compileEntry ("examples" </> "lead-app" </> "Main.clasp")
        case result of
          Left err ->
            assertFailure ("expected lead inbox app to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/lead-app/compiled-fixtures.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            fixtureOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "const landing = compiledModule.__claspSeededFixtures.find((fixture) => fixture.routeName === 'landingRoute');"
                , "const createLead = compiledModule.__claspSeededFixtures.find((fixture) => fixture.routeName === 'createLeadRoute');"
                , "console.log(JSON.stringify({"
                , "  fixtureCount: compiledModule.__claspSeededFixtures.length,"
                , "  landingResponseType: landing?.responseType ?? null,"
                , "  landingResponseSchema: landing?.responseSchema ?? null,"
                , "  landingResponseSeed: landing?.responseSeed ?? null,"
                , "  createLeadRequestSeed: createLead?.requestSeed ?? null"
                , "}));"
                ]
            assertEqual
              "expected seeded fixtures to expose stable request and response seeds"
              "{\"fixtureCount\":6,\"landingResponseType\":\"Page\",\"landingResponseSchema\":null,\"landingResponseSeed\":{\"$kind\":\"page\",\"title\":\"Seeded Page\",\"body\":{\"$kind\":\"text\",\"text\":\"seed\"}},\"createLeadRequestSeed\":{\"company\":\"seed\",\"contact\":\"seed\",\"budget\":0,\"segment\":\"Startup\"}}"
              fixtureOutput
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

findAirNode :: AirNodeId -> [AirNode] -> Maybe AirNode
findAirNode target =
  go
  where
    go [] = Nothing
    go (node : rest)
      | airNodeId node == target = Just node
      | otherwise = go rest

lowerChecked :: FilePath -> Text -> Either DiagnosticBundle LowerModule
lowerChecked path source = do
  checked <- checkSource path source
  pure (lowerModule checked)

runNodeModule :: FilePath -> IO Text
runNodeModule compiledPath = do
  absolutePath <- makeAbsolute compiledPath
  runNodeScript $
    T.pack . unlines $
      [ "import * as compiledModule from " <> show ("file://" <> absolutePath) <> ";"
      , "const route = compiledModule.__claspRoutes.find((candidate) => candidate.name === 'inboxRoute');"
      , "if (!route) { throw new Error('missing inboxRoute'); }"
      , "const html = await route.encodeResponse(await route.handler({}));"
      , "console.log(html);"
      ]

runNodeScript :: Text -> IO Text
runNodeScript script = do
  (exitCode, stdoutText, stderrText) <-
    readProcessWithExitCode
      "node"
      [ "--input-type=module"
      , "--eval"
      , T.unpack script
      ]
      ""
  case exitCode of
    ExitSuccess ->
      pure (T.strip (T.pack stdoutText))
    ExitFailure _ ->
      assertFailure ("node script failed:\n" <> stderrText)

runClaspc :: [String] -> IO (ExitCode, String, String)
runClaspc args =
  readProcessWithExitCode
    "cabal"
    (["run", "claspc", "--"] <> args)
    ""

lookupObjectKey :: Text -> Value -> Maybe Value
lookupObjectKey key value =
  case value of
    Object obj ->
      KeyMap.lookup (fromText key) obj
    _ ->
      Nothing

extractNodeIds :: Value -> [Text]
extractNodeIds value =
  case lookupObjectKey "nodes" value of
    Just (Array nodes) ->
      foldMap extractNodeId (toList nodes)
    _ ->
      []
  where
    extractNodeId nodeValue =
      case lookupObjectKey "id" nodeValue of
        Just (String nodeId) ->
          [nodeId]
        _ ->
          []

extractEdges :: Value -> [(Text, Text)]
extractEdges value =
  case lookupObjectKey "edges" value of
    Just (Array edges) ->
      foldMap extractEdge (toList edges)
    _ ->
      []
  where
    extractEdge edgeValue =
      case (lookupObjectKey "from" edgeValue, lookupObjectKey "to" edgeValue) of
        (Just (String fromId), Just (String toId)) ->
          [(fromId, toId)]
        _ ->
          []

withProjectFiles :: FilePath -> [(FilePath, Text)] -> (FilePath -> IO a) -> IO a
withProjectFiles fixtureName files action = do
  let root = "dist/test-projects" </> fixtureName
  cleanupProjectDir root
  createDirectoryIfMissing True root
  mapM_ (writeProjectFile root) files
  action root `finally` cleanupProjectDir root

readExampleSource :: FilePath -> IO Text
readExampleSource relativePath =
  TIO.readFile ("examples" </> relativePath)

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

normalizeGuideEntries :: [GuideEntryDecl] -> [GuideEntryDecl]
normalizeGuideEntries =
  fmap
    ( \entryDecl ->
        entryDecl
          { guideEntryDeclSpan = dummySpan
          , guideEntryDeclValueSpan = dummySpan
          }
    )

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

shadowedDeclRenameSource :: Text
shadowedDeclRenameSource =
  T.unlines
    [ "module Main"
    , ""
    , "id : Str -> Str"
    , "id value = value"
    , ""
    , "use : Str -> Str"
    , "use id = id"
    , ""
    , "main : Str"
    , "main = id \"hello\""
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

guideSource :: Text
guideSource =
  T.unlines
    [ "module Main"
    , ""
    , "guide Repo = {"
    , "  scope: \"Stay inside the current checkout.\","
    , "  edits: \"Keep changes small and local.\""
    , "}"
    , ""
    , "guide Worker extends Repo = {"
    , "  verification: \"Run bash scripts/verify-all.sh before finishing.\""
    , "}"
    , ""
    , "main = \"ok\""
    ]

missingGuideParentSource :: Text
missingGuideParentSource =
  T.unlines
    [ "module Main"
    , ""
    , "guide Worker extends Repo = {"
    , "  scope: \"Stay inside the current checkout.\""
    , "}"
    , ""
    , "main = \"ok\""
    ]

cyclicGuideSource :: Text
cyclicGuideSource =
  T.unlines
    [ "module Main"
    , ""
    , "guide Repo extends Worker = {"
    , "  scope: \"Stay inside the current checkout.\""
    , "}"
    , ""
    , "guide Worker extends Repo = {"
    , "  verification: \"Run bash scripts/verify-all.sh before finishing.\""
    , "}"
    , ""
    , "main = \"ok\""
    ]

classifiedProjectionSource :: Text
classifiedProjectionSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Empty = {}"
    , ""
    , "record Customer = {"
    , "  id : Str,"
    , "  email : Str classified pii,"
    , "  tier : Str"
    , "}"
    , ""
    , "policy SupportDisclosure = public, pii"
    , ""
    , "projection SupportCustomer = Customer with SupportDisclosure { id, email, tier }"
    , ""
    , "currentCustomer : SupportCustomer"
    , "currentCustomer = SupportCustomer {"
    , "  id = \"cust-1\","
    , "  email = \"ada@example.com\","
    , "  tier = \"gold\""
    , "}"
    , ""
    , "foreign publishCustomer : SupportCustomer -> Str = \"publishCustomer\""
    , ""
    , "shareCustomer : Empty -> SupportCustomer"
    , "shareCustomer req = currentCustomer"
    , ""
    , "encodedCustomer : Str"
    , "encodedCustomer = encode currentCustomer"
    , ""
    , "route shareCustomerRoute = GET \"/customer\" Empty -> SupportCustomer shareCustomer"
    ]

disallowedProjectionSource :: Text
disallowedProjectionSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Customer = {"
    , "  id : Str,"
    , "  email : Str classified pii"
    , "}"
    , ""
    , "policy PublicDisclosure = public"
    , ""
    , "projection PublicCustomer = Customer with PublicDisclosure { id, email }"
    ]

pageSource :: Text
pageSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Empty = {}"
    , ""
    , "welcomeView : View"
    , "welcomeView = styled \"inbox_shell\" (element \"section\" (append (element \"h1\" (text \"Inbox\")) (element \"p\" (text \"Safe <markup>\"))))"
    , ""
    , "home : Empty -> Page"
    , "home req = page \"Inbox\" welcomeView"
    , ""
    , "route homeRoute = GET \"/inbox\" Empty -> Page home"
    ]

interactivePageSource :: Text
interactivePageSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Empty = {}"
    , "record LeadCreate = { company : Str }"
    , ""
    , "home : Empty -> Page"
    , "home req = page \"Inbox\" (append (link \"/lead/primary\" (text \"Open lead\")) (form \"POST\" \"/leads\" (append (input \"company\" \"text\" \"\") (submit \"Save\"))))"
    , ""
    , "leadPage : Empty -> Page"
    , "leadPage req = page \"Lead\" (text \"Primary\")"
    , ""
    , "createLead : LeadCreate -> Redirect"
    , "createLead req = redirect \"/lead/primary\""
    , ""
    , "route homeRoute = GET \"/\" Empty -> Page home"
    , "route leadRoute = GET \"/lead/primary\" Empty -> Page leadPage"
    , "route createLeadRoute = POST \"/leads\" LeadCreate -> Redirect createLead"
    ]

redirectSource :: Text
redirectSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Empty = {}"
    , ""
    , "inbox : Empty -> Page"
    , "inbox req = page \"Inbox\" (text \"ok\")"
    , ""
    , "submitLead : Empty -> Redirect"
    , "submitLead req = redirect \"/inbox\""
    , ""
    , "route inboxRoute = GET \"/inbox\" Empty -> Page inbox"
    , "route submitLeadRoute = POST \"/submit\" Empty -> Redirect submitLead"
    ]

authIdentitySource :: Text
authIdentitySource =
  T.unlines
    [ "module Main"
    , ""
    , "record AuditEnvelope = {"
    , "  session : AuthSession,"
    , "  resource : ResourceIdentity"
    , "}"
    , ""
    , "defaultAudit : AuditEnvelope"
    , "defaultAudit = AuditEnvelope {"
    , "  session = authSession \"sess-1\" (principal \"user-1\") (tenant \"tenant-1\") (resourceIdentity \"lead\" \"lead-1\"),"
    , "  resource = resourceIdentity \"lead\" \"lead-1\""
    , "}"
    , ""
    , "sessionTenantId : AuthSession -> Str"
    , "sessionTenantId session = session.tenant.id"
    , ""
    , "encodeAudit : AuditEnvelope -> Str"
    , "encodeAudit audit = encode audit"
    , ""
    , "decodeAudit : Str -> AuditEnvelope"
    , "decodeAudit raw = decode AuditEnvelope raw"
    ]

listTypeSource :: Text
listTypeSource =
  T.unlines
    [ "module Main"
    , ""
    , "type BatchResult = Batch [User]"
    , ""
    , "record UserDirectory = {"
    , "  names : [Str],"
    , "  scoreBuckets : [[Int]]"
    , "}"
    , ""
    , "flattened : [BatchResult] -> [Str]"
    , "flattened batches = batches"
    ]

listLiteralSource :: Text
listLiteralSource =
  T.unlines
    [ "module Main"
    , ""
    , "roster : [Str]"
    , "roster = [\"Ada\", \"Grace\"]"
    , ""
    , "emptyRoster : [Str]"
    , "emptyRoster = []"
    ]

listJsonBoundarySource :: Text
listJsonBoundarySource =
  T.unlines
    [ "module Main"
    , ""
    , "record User = {"
    , "  name : Str,"
    , "  active : Bool"
    , "}"
    , ""
    , "defaultUsers : [User]"
    , "defaultUsers = [User { name = \"Ada\", active = true }, User { name = \"Grace\", active = false }]"
    , ""
    , "encodeUsers : [User] -> Str"
    , "encodeUsers users = encode users"
    , ""
    , "decodeUsers : Str -> [User]"
    , "decodeUsers raw = decode [User] raw"
    ]

letExpressionSource :: Text
letExpressionSource =
  T.unlines
    [ "module Main"
    , ""
    , "greeting : Str"
    , "greeting = let message = \"Ada\" in message"
    ]

equalitySource :: Text
equalitySource =
  T.unlines
    [ "module Main"
    , ""
    , "sameNumber : Int -> Int -> Bool"
    , "sameNumber left right = left == right"
    , ""
    , "sameWord : Str -> Str -> Bool"
    , "sameWord left right = left == right"
    , ""
    , "differentFlag : Bool -> Bool -> Bool"
    , "differentFlag left right = left != right"
    , ""
    , "main : Bool"
    , "main = sameNumber 7 7"
    ]

integerComparisonSource :: Text
integerComparisonSource =
  T.unlines
    [ "module Main"
    , ""
    , "isEarlier : Int -> Int -> Bool"
    , "isEarlier left right = left < right"
    , ""
    , "isAtMost : Int -> Int -> Bool"
    , "isAtMost left right = left <= right"
    , ""
    , "isLater : Int -> Int -> Bool"
    , "isLater left right = left > right"
    , ""
    , "isLatest : Int -> Int -> Bool"
    , "isLatest left right = left >= right"
    , ""
    , "main : Bool"
    , "main = isEarlier 3 5"
    ]

letInMatchSource :: Text
letInMatchSource =
  T.unlines
    [ "module Main"
    , ""
    , "type Status = Busy Str"
    , ""
    , "describe : Status -> Str"
    , "describe status = match status {"
    , "  Busy note -> let copy = note in copy"
    , "}"
    ]

heterogeneousListSource :: Text
heterogeneousListSource =
  T.unlines
    [ "module Main"
    , ""
    , "bad = [\"Ada\", 1]"
    ]

badEqualitySource :: Text
badEqualitySource =
  T.unlines
    [ "module Main"
    , ""
    , "badList : Bool"
    , "badList = [1] == [1]"
    , ""
    , "badMixed : Bool"
    , "badMixed = 1 == \"1\""
    ]

badIntegerComparisonSource :: Text
badIntegerComparisonSource =
  T.unlines
    [ "module Main"
    , ""
    , "bad : Str -> Str -> Bool"
    , "bad left right = left < right"
    ]

unsafeScriptSource :: Text
unsafeScriptSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Empty = {}"
    , ""
    , "bad : Empty -> Page"
    , "bad req = page \"Inbox\" (element \"script\" (text \"alert(1)\"))"
    , ""
    , "route badRoute = GET \"/bad\" Empty -> Page bad"
    ]

hostClassSource :: Text
hostClassSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Empty = {}"
    , ""
    , "bad : Empty -> Page"
    , "bad req = page \"Inbox\" (hostClass \"hero\" (text \"hello\"))"
    , ""
    , "route badRoute = GET \"/bad\" Empty -> Page bad"
    ]

hostStyleSource :: Text
hostStyleSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Empty = {}"
    , ""
    , "bad : Empty -> Page"
    , "bad req = page \"Inbox\" (hostStyle \"display:none\" (text \"hello\"))"
    , ""
    , "route badRoute = GET \"/bad\" Empty -> Page bad"
    ]

unsafeLinkSource :: Text
unsafeLinkSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Empty = {}"
    , ""
    , "bad : Empty -> Page"
    , "bad req = page \"Inbox\" (link \"javascript:alert(1)\" (text \"bad\"))"
    , ""
    , "route badRoute = GET \"/bad\" Empty -> Page bad"
    ]

missingLinkRouteSource :: Text
missingLinkRouteSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Empty = {}"
    , ""
    , "bad : Empty -> Page"
    , "bad req = page \"Inbox\" (link \"/missing\" (text \"bad\"))"
    , ""
    , "route badRoute = GET \"/bad\" Empty -> Page bad"
    ]

missingFormRouteSource :: Text
missingFormRouteSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Empty = {}"
    , ""
    , "bad : Empty -> Page"
    , "bad req = page \"Inbox\" (form \"POST\" \"/missing\" (submit \"Save\"))"
    , ""
    , "route badRoute = GET \"/bad\" Empty -> Page bad"
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

importSuccessFiles :: [(FilePath, Text)]
importSuccessFiles =
  [ ("Main.clasp", importSuccessMainSource)
  , ("Shared/User.clasp", sharedUserSource)
  ]

inboxPageFiles :: [(FilePath, Text)]
inboxPageFiles =
  [ ("Main.clasp", inboxPageMainSource)
  , ("Shared/Inbox.clasp", sharedInboxSource)
  ]

pageFormRuntimeFiles :: [(FilePath, Text)]
pageFormRuntimeFiles =
  [ ("Main.clasp", pageFormRuntimeSource)
  ]

pageRedirectRuntimeFiles :: [(FilePath, Text)]
pageRedirectRuntimeFiles =
  [ ("Main.clasp", redirectSource)
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

inboxPageMainSource :: Text
inboxPageMainSource =
  T.unlines
    [ "module Main"
    , ""
    , "import Shared.Inbox"
    , ""
    , "record Empty = {}"
    , ""
    , "seed : InboxData"
    , "seed = InboxData {"
    , "  headline = \"Inbox\","
    , "  primarySubject = \"<Quarterly <review>>\","
    , "  secondarySubject = \"Escaped & archived\""
    , "}"
    , ""
    , "inboxRouteHandler : Empty -> Page"
    , "inboxRouteHandler req = renderInbox seed"
    , ""
    , "route inboxRoute = GET \"/inbox\" Empty -> Page inboxRouteHandler"
    ]

sharedInboxSource :: Text
sharedInboxSource =
  T.unlines
    [ "module Shared.Inbox"
    , ""
    , "record InboxData = {"
    , "  headline : Str,"
    , "  primarySubject : Str,"
    , "  secondarySubject : Str"
    , "}"
    , ""
    , "renderInbox : InboxData -> Page"
    , "renderInbox data = page data.headline (styled \"inbox_shell\" (element \"main\" (append (element \"h1\" (text data.headline)) (append (element \"article\" (text data.primarySubject)) (element \"article\" (text data.secondarySubject))))))"
    ]

pageFormRuntimeSource :: Text
pageFormRuntimeSource =
  T.unlines
    [ "module Main"
    , ""
    , "record OrderLookup = {"
    , "  customerId : Str,"
    , "  quantity : Int"
    , "}"
    , ""
    , "orderPage : OrderLookup -> Page"
    , "orderPage lookup = page \"Order\" (text lookup.customerId)"
    , ""
    , "route lookupRoute = GET \"/order\" OrderLookup -> Page orderPage"
    , "route submitRoute = POST \"/order\" OrderLookup -> Page orderPage"
    ]

pageFormRuntimeScript :: FilePath -> FilePath -> Text
pageFormRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { requestPayloadJson } from " <> show ("file://" <> runtimePath) <> ";"
    , "const lookupRoute = compiledModule.__claspRoutes.find((candidate) => candidate.name === 'lookupRoute');"
    , "const submitRoute = compiledModule.__claspRoutes.find((candidate) => candidate.name === 'submitRoute');"
    , "if (!lookupRoute || !submitRoute) { throw new Error('missing routes'); }"
    , "const queryRequest = new Request('http://example.test/order?customerId=00123&quantity=7', { method: 'GET' });"
    , "const formRequest = new Request('http://example.test/order', {"
    , "  method: 'POST',"
    , "  headers: { 'content-type': 'application/x-www-form-urlencoded' },"
    , "  body: 'customerId=00123&quantity=7'"
    , "});"
    , "const invalidFormRequest = new Request('http://example.test/order', {"
    , "  method: 'POST',"
    , "  headers: { 'content-type': 'application/x-www-form-urlencoded' },"
    , "  body: 'customerId=00123&quantity=oops'"
    , "});"
    , "const queryPayload = lookupRoute.decodeRequest(await requestPayloadJson(lookupRoute, queryRequest));"
    , "const formPayload = submitRoute.decodeRequest(await requestPayloadJson(submitRoute, formRequest));"
    , "const html = submitRoute.encodeResponse(await submitRoute.handler(formPayload));"
    , "let invalidMessage = null;"
    , "try {"
    , "  submitRoute.decodeRequest(await requestPayloadJson(submitRoute, invalidFormRequest));"
    , "} catch (error) {"
    , "  invalidMessage = error instanceof Error ? error.message : String(error);"
    , "}"
    , "console.log(JSON.stringify({ query: queryPayload, form: formPayload, html, invalid: invalidMessage }));"
    ]

pageRedirectRuntimeScript :: FilePath -> FilePath -> Text
pageRedirectRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { responseForRouteResult } from " <> show ("file://" <> runtimePath) <> ";"
    , "const submitRoute = compiledModule.__claspRoutes.find((candidate) => candidate.name === 'submitLeadRoute');"
    , "if (!submitRoute) { throw new Error('missing submitLeadRoute'); }"
    , "const response = responseForRouteResult(submitRoute, await submitRoute.handler({}));"
    , "console.log(JSON.stringify({ status: response.status, location: response.headers.get('location') }));"
    ]

leadAppBrowserShellScript :: FilePath -> Text
leadAppBrowserShellScript shellPath =
  T.pack . unlines $
    [ "import { createLeadAppShell } from " <> show ("file://" <> shellPath) <> ";"
    , "const listeners = new Map();"
    , "const fetches = [];"
    , "const document = {"
    , "  title: 'Lead inbox',"
    , "  body: { innerHTML: '<main><h1>Lead inbox</h1></main>' },"
    , "  location: { href: 'https://app.example.test/', pathname: '/' }"
    , "};"
    , "const historyEntries = ['https://app.example.test/'];"
    , "let historyIndex = 0;"
    , "const window = {"
    , "  location: document.location,"
    , "  addEventListener(name, listener) {"
    , "    listeners.set(name, listener);"
    , "  },"
    , "  history: {"
    , "    pushState(_state, _title, href) {"
    , "      historyEntries.splice(historyIndex + 1);"
    , "      historyEntries.push(String(href));"
    , "      historyIndex = historyEntries.length - 1;"
    , "      document.location.href = historyEntries[historyIndex];"
    , "      document.location.pathname = new URL(historyEntries[historyIndex]).pathname;"
    , "    },"
    , "    replaceState(_state, _title, href) {"
    , "      historyEntries[historyIndex] = String(href);"
    , "      document.location.href = historyEntries[historyIndex];"
    , "      document.location.pathname = new URL(historyEntries[historyIndex]).pathname;"
    , "    }"
    , "  }"
    , "};"
    , "window.dispatchPopState = async () => {"
    , "  const listener = listeners.get('popstate');"
    , "  if (listener) {"
    , "    await listener({ type: 'popstate' });"
    , "  }"
    , "};"
    , "window.back = async () => {"
    , "  historyIndex = Math.max(0, historyIndex - 1);"
    , "  document.location.href = historyEntries[historyIndex];"
    , "  document.location.pathname = new URL(historyEntries[historyIndex]).pathname;"
    , "  await window.dispatchPopState();"
    , "};"
    , "window.forward = async () => {"
    , "  historyIndex = Math.min(historyEntries.length - 1, historyIndex + 1);"
    , "  document.location.href = historyEntries[historyIndex];"
    , "  document.location.pathname = new URL(historyEntries[historyIndex]).pathname;"
    , "  await window.dispatchPopState();"
    , "};"
    , "const pages = new Map(["
    , "  ['/leads', '<!DOCTYPE html><html><head><title>Created lead</title></head><body><main><h1>Created lead</h1></main></body></html>'],"
    , "  ['/inbox', '<!DOCTYPE html><html><head><title>Inbox</title></head><body><main><h1>Inbox</h1></main></body></html>'],"
    , "  ['/lead/primary', '<!DOCTYPE html><html><head><title>Primary lead</title></head><body><main><h1>Primary lead</h1></main></body></html>'],"
    , "  ['/review', '<!DOCTYPE html><html><head><title>Reviewed lead</title></head><body><main><h1>Reviewed lead</h1></main></body></html>']"
    , "]);"
    , "const shell = createLeadAppShell({"
    , "  document,"
    , "  window,"
    , "  fetch: async (href, init = {}) => {"
    , "    const url = new URL(href);"
    , "    fetches.push({ method: init.method ?? 'GET', pathname: url.pathname });"
    , "    return {"
    , "      url: url.toString(),"
    , "      async text() {"
    , "        return pages.get(url.pathname) ?? '<!DOCTYPE html><html><head><title>Missing</title></head><body><main><h1>Missing</h1></main></body></html>';"
    , "      }"
    , "    };"
    , "  }"
    , "});"
    , "await shell.start();"
    , "await shell.submit({ method: 'POST', action: '/leads', fields: { company: 'SynthSpeak' } });"
    , "const afterCreate = shell.currentHref;"
    , "await shell.navigate('/inbox');"
    , "await shell.navigate('/lead/primary');"
    , "await shell.submit({ method: 'POST', action: '/review', fields: { leadId: 'lead-1', note: 'Ready' } });"
    , "const afterReview = shell.currentHref;"
    , "await shell.reload();"
    , "const afterRefresh = shell.currentHref;"
    , "await window.back();"
    , "const afterBack = shell.currentHref;"
    , "await window.forward();"
    , "const afterForward = shell.currentHref;"
    , "console.log(JSON.stringify({"
    , "  history: historyEntries,"
    , "  fetches,"
    , "  afterCreate,"
    , "  afterReview,"
    , "  afterRefresh,"
    , "  afterBack,"
    , "  afterForward,"
    , "  title: document.title,"
    , "  html: document.body.innerHTML"
    , "}));"
    , ""
    ]

routeClientJsonRuntimeScript :: FilePath -> Text
routeClientJsonRuntimeScript compiledPath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "const client = compiledModule.summarizeLeadRouteClient;"
    , "const request = client.prepareRequest({ company: 'Acme', budget: 42, priorityHint: compiledModule.High });"
    , "const parsed = await client.parseResponse(new Response(JSON.stringify({"
    , "  summary: 'Ready',"
    , "  priority: 'high',"
    , "  followUpRequired: true"
    , "})));"
    , "console.log(JSON.stringify({"
    , "  method: request.method,"
    , "  path: request.path,"
    , "  href: request.href,"
    , "  contentType: request.headers['content-type'] ?? null,"
    , "  body: request.body,"
    , "  parsedSummary: parsed.summary,"
    , "  parsedPriority: parsed.priority?.$tag ?? parsed.priority,"
    , "  parsedFollowUpRequired: parsed.followUpRequired"
    , "}));"
    ]

routeClientFetchRuntimeScript :: FilePath -> FilePath -> Text
routeClientFetchRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { callRouteClient, prepareRouteFetch } from " <> show ("file://" <> runtimePath) <> ";"
    , "const client = compiledModule.summarizeLeadRouteClient;"
    , "const payload = { company: 'Acme', budget: 42, priorityHint: compiledModule.High };"
    , "const prepared = prepareRouteFetch(client, payload, { baseUrl: 'https://app.example.test/root' });"
    , "const calls = [];"
    , "const parsed = await callRouteClient(client, payload, {"
    , "  baseUrl: 'https://app.example.test/root',"
    , "  fetch: async (url, init) => {"
    , "    calls.push({"
    , "      url,"
    , "      method: init.method,"
    , "      contentType: init.headers['content-type'] ?? null,"
    , "      body: init.body ?? null"
    , "    });"
    , "    return new Response(JSON.stringify({"
    , "      summary: 'Queued',"
    , "      priority: 'medium',"
    , "      followUpRequired: false"
    , "    }), {"
    , "      status: 200,"
    , "      headers: { 'content-type': 'application/json' }"
    , "    });"
    , "  }"
    , "});"
    , "console.log(JSON.stringify({"
    , "  preparedUrl: prepared.url,"
    , "  preparedCredentials: prepared.init.credentials ?? null,"
    , "  fetchUrl: calls[0]?.url ?? null,"
    , "  fetchMethod: calls[0]?.method ?? null,"
    , "  fetchContentType: calls[0]?.contentType ?? null,"
    , "  fetchBody: calls[0]?.body ?? null,"
    , "  parsedSummary: parsed.summary,"
    , "  parsedPriority: parsed.priority?.$tag ?? parsed.priority,"
    , "  parsedFollowUpRequired: parsed.followUpRequired"
    , "}));"
    ]

routeClientPageRuntimeScript :: FilePath -> Text
routeClientPageRuntimeScript compiledPath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "const lookupClient = compiledModule.lookupRouteClient;"
    , "const submitClient = compiledModule.submitRouteClient;"
    , "const payload = { customerId: '00123', quantity: 7 };"
    , "const lookupRequest = lookupClient.prepareRequest(payload);"
    , "const submitRequest = submitClient.prepareRequest(payload);"
    , "const pageHtml = await lookupClient.parseResponse(new Response('<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Order</title></head><body>00123</body></html>'));"
    , "console.log(JSON.stringify({"
    , "  lookupHref: lookupRequest.href,"
    , "  lookupBody: lookupRequest.body,"
    , "  submitContentType: submitRequest.headers['content-type'] ?? null,"
    , "  submitBody: submitRequest.body,"
    , "  pageHtml"
    , "}));"
    ]

routeClientRedirectRuntimeScript :: FilePath -> Text
routeClientRedirectRuntimeScript compiledPath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "const client = compiledModule.submitLeadRouteClient;"
    , "const request = client.prepareRequest({});"
    , "const redirect = await client.parseResponse(new Response('', {"
    , "  status: 303,"
    , "  headers: { location: '/inbox' }"
    , "}));"
    , "console.log(JSON.stringify({"
    , "  method: request.method,"
    , "  path: request.path,"
    , "  body: request.body,"
    , "  redirect"
    , "}));"
    ]

pageAssetRuntimeScript :: FilePath -> FilePath -> Text
pageAssetRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { responseForAssetRequest } from " <> show ("file://" <> runtimePath) <> ";"
    , "const page = compiledModule.home({});"
    , "const head = compiledModule.__claspPageHead(page);"
    , "const bundle = compiledModule.__claspStyleBundles[0] ?? null;"
    , "const assetResponse = bundle ? await responseForAssetRequest(compiledModule, bundle.href) : null;"
    , "const assetBody = assetResponse ? await assetResponse.text() : '';"
    , "console.log(JSON.stringify({"
    , "  assetBasePath: compiledModule.__claspStaticAssetStrategy.assetBasePath,"
    , "  generatedAssetBasePath: compiledModule.__claspStaticAssetStrategy.generatedAssetBasePath,"
    , "  headTitle: head.title,"
    , "  headViewport: head.meta.find((entry) => entry.name === 'viewport')?.content ?? null,"
    , "  headStylesheet: head.links[0]?.href ?? null,"
    , "  bundleId: bundle?.id ?? null,"
    , "  bundleHref: bundle?.href ?? null,"
    , "  bundleRefs: bundle?.refs ?? [],"
    , "  assetContentType: assetResponse?.headers.get('content-type') ?? null,"
    , "  assetHasRefComment: assetBody.includes('inbox_shell')"
    , "}));"
    ]

routeClientBrowserRuntimeScript :: FilePath -> FilePath -> FilePath -> Text
routeClientBrowserRuntimeScript pageCompiledPath redirectCompiledPath runtimePath =
  T.pack . unlines $
    [ "import * as pageModule from " <> show ("file://" <> pageCompiledPath) <> ";"
    , "import * as redirectModule from " <> show ("file://" <> redirectCompiledPath) <> ";"
    , "import { createRouteClientRuntime, fetchRouteClient } from " <> show ("file://" <> runtimePath) <> ";"
    , "const pageCalls = [];"
    , "const pageRuntime = createRouteClientRuntime({"
    , "  baseUrl: 'https://app.example.test/app/',"
    , "  fetch: async (url, init) => {"
    , "    pageCalls.push({ url, method: init.method });"
    , "    return new Response('<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Order</title></head><body>00123</body></html>', {"
    , "      status: 200,"
    , "      headers: { 'content-type': 'text/html; charset=utf-8' }"
    , "    });"
    , "  }"
    , "});"
    , "const pageHtml = await pageRuntime.call(pageModule.lookupRouteClient, { customerId: '00123', quantity: 7 });"
    , "let redirectMode = null;"
    , "const redirectResult = await fetchRouteClient(redirectModule.submitLeadRouteClient, {}, {"
    , "  baseUrl: 'https://app.example.test/app/',"
    , "  fetch: async (url, init) => {"
    , "    redirectMode = init.redirect ?? null;"
    , "    return new Response('', {"
    , "      status: 303,"
    , "      headers: { location: '/inbox' }"
    , "    });"
    , "  }"
    , "});"
    , "console.log(JSON.stringify({"
    , "  pageUrl: pageCalls[0]?.url ?? null,"
    , "  pageMethod: pageCalls[0]?.method ?? null,"
    , "  pageHtml,"
    , "  redirectUrl: redirectResult.url,"
    , "  redirectMode,"
    , "  redirectLocation: redirectResult.data.location,"
    , "  redirectStatus: redirectResult.data.status"
    , "}));"
    ]

workerJobRuntimeScript :: FilePath -> FilePath -> Text
workerJobRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createWorkerRuntime } from " <> show ("file://" <> runtimePath) <> ";"
    , "const runtime = createWorkerRuntime(compiledModule);"
    , "const contract = runtime.contract;"
    , "const leadRequest = runtime.schema('LeadRequest');"
    , "const job = runtime.registerJob({"
    , "  name: 'summarizeLeadJob',"
    , "  inputType: 'LeadRequest',"
    , "  outputType: 'LeadSummary',"
    , "  async handler(payload) {"
    , "    return {"
    , "      summary: `${payload.company}:${payload.budget}`,"
    , "      priority: payload.priorityHint,"
    , "      followUpRequired: payload.budget >= 40"
    , "    };"
    , "  }"
    , "});"
    , "const encoded = await runtime.dispatch('summarizeLeadJob', JSON.stringify({"
    , "  company: 'Acme',"
    , "  budget: 42,"
    , "  priorityHint: 'high'"
    , "}));"
    , "const decoded = JSON.parse(encoded);"
    , "let invalid = null;"
    , "try {"
    , "  await runtime.dispatch('summarizeLeadJob', JSON.stringify({ company: 'Acme', budget: 'oops', priorityHint: 'high' }));"
    , "} catch (error) {"
    , "  invalid = error instanceof Error ? error.message : String(error);"
    , "}"
    , "console.log(JSON.stringify({"
    , "  contractVersion: contract.version,"
    , "  schemaKind: leadRequest.schema.kind,"
    , "  seedBudget: leadRequest.seed.budget,"
    , "  jobCount: runtime.listJobs().length,"
    , "  jobInputType: job.inputType,"
    , "  jobOutputType: job.outputType,"
    , "  outputSchemaKind: job.outputSchema.kind,"
    , "  outputSeedPriority: job.outputSeed.priority,"
    , "  resultPriority: decoded.priority,"
    , "  resultFollowUpRequired: decoded.followUpRequired,"
    , "  invalid"
    , "}));"
    ]

authIdentityRuntimeScript :: FilePath -> FilePath -> FilePath -> Text
authIdentityRuntimeScript compiledPath serverRuntimePath workerRuntimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { bindingContractFor } from " <> show ("file://" <> serverRuntimePath) <> ";"
    , "import { createWorkerRuntime } from " <> show ("file://" <> workerRuntimePath) <> ";"
    , "const contract = bindingContractFor(compiledModule);"
    , "const workerRuntime = createWorkerRuntime(compiledModule);"
    , "const authSession = workerRuntime.schema('AuthSession');"
    , "const decodedAudit = workerRuntime.schema('AuditEnvelope').decodeJson(compiledModule.encodeAudit(compiledModule.defaultAudit));"
    , "console.log(JSON.stringify({"
    , "  contractVersion: contract.version,"
    , "  schemaNames: Object.keys(contract.schemas).sort(),"
    , "  sessionSchemaKind: contract.schemas.AuthSession?.schema?.kind ?? null,"
    , "  principalFieldType: contract.schemas.AuthSession?.schema?.fields?.principal?.schema?.name ?? null,"
    , "  tenantSeed: authSession.seed.tenant.id,"
    , "  workerSessionId: decodedAudit.session.sessionId,"
    , "  workerPrincipalId: decodedAudit.session.principal.id,"
    , "  workerTenantId: decodedAudit.session.tenant.id,"
    , "  workerResource: decodedAudit.resource.resourceType + ':' + decodedAudit.resource.resourceId"
    , "}));"
    ]

leadInboxRuntimeScript :: FilePath -> FilePath -> Text
leadInboxRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { bindingContractFor, installCompiledModule, requestPayloadJson } from " <> show ("file://" <> runtimePath) <> ";"
    , "const contract = bindingContractFor(compiledModule);"
    , "const manifest = Object.fromEntries(contract.hostBindings.map((binding) => [binding.name, binding]));"
    , "let structuredModelArg = false;"
    , "let structuredStoreArg = false;"
    , "const leads = ["
    , "  {"
    , "    leadId: 'lead-2',"
    , "    company: 'Northwind Studio',"
    , "    contact: 'Morgan Lee',"
    , "    summary: 'Northwind Studio is ready for a design-system migration this quarter.',"
    , "    priority: 'medium',"
    , "    segment: 'growth',"
    , "    followUpRequired: true,"
    , "    reviewStatus: 'reviewed',"
    , "    reviewNote: 'Confirmed budget window and asked for a migration timeline.'"
    , "  },"
    , "  {"
    , "    leadId: 'lead-1',"
    , "    company: 'Acme Labs',"
    , "    contact: 'Jordan Kim',"
    , "    summary: 'Acme Labs is exploring an internal AI pilot for support operations.',"
    , "    priority: 'high',"
    , "    segment: 'enterprise',"
    , "    followUpRequired: true,"
    , "    reviewStatus: 'new',"
    , "    reviewNote: ''"
    , "  }"
    , "];"
    , "installCompiledModule(compiledModule, {"
    , "  mockLeadSummaryModel(intake) {"
    , "    structuredModelArg = typeof intake.segment === 'string' && intake.segment === 'enterprise';"
    , "    const priority = intake.budget >= 50000 ? 'High' : intake.budget >= 20000 ? 'Medium' : 'Low';"
    , "    return JSON.stringify({"
    , "      summary: `${intake.company} led by ${intake.contact} fits the ${priority.toLowerCase()} priority pipeline.`,"
    , "      priority: priority.toLowerCase(),"
    , "      segment: intake.segment ?? 'startup',"
    , "      followUpRequired: intake.budget >= 20000"
    , "    });"
    , "  },"
    , "  storeLead(intake, summary) {"
    , "    structuredStoreArg = typeof summary.priority === 'string' && typeof summary.segment === 'string';"
    , "    const lead = {"
    , "      leadId: `lead-${leads.length + 1}`,"
    , "      company: intake.company,"
    , "      contact: intake.contact,"
    , "      summary: summary.summary,"
    , "      priority: summary.priority ?? 'low',"
    , "      segment: summary.segment ?? 'startup',"
    , "      followUpRequired: summary.followUpRequired,"
    , "      reviewStatus: 'new',"
    , "      reviewNote: ''"
    , "    };"
    , "    leads.unshift(lead);"
    , "    return JSON.stringify(lead);"
    , "  },"
    , "  loadInbox() {"
    , "    return JSON.stringify({"
    , "      headline: 'Priority inbox',"
    , "      primaryLeadLabel: `${leads[0].company} (${leads[0].priority.toLowerCase()}, ${leads[0].segment.toLowerCase()})`,"
    , "      secondaryLeadLabel: `${(leads[1] ?? leads[0]).company} (${(leads[1] ?? leads[0]).priority.toLowerCase()}, ${(leads[1] ?? leads[0]).segment.toLowerCase()})`"
    , "    });"
    , "  },"
    , "  loadPrimaryLead() {"
    , "    return JSON.stringify(leads[0]);"
    , "  },"
    , "  loadSecondaryLead() {"
    , "    return JSON.stringify(leads[1] ?? leads[0]);"
    , "  },"
    , "  reviewLead(review) {"
    , "    const lead = leads.find((candidate) => candidate.leadId === review.leadId);"
    , "    if (!lead) { throw new Error(`Unknown lead: ${review.leadId}`); }"
    , "    lead.reviewStatus = 'reviewed';"
    , "    lead.reviewNote = review.note;"
    , "    return JSON.stringify(lead);"
    , "  }"
    , "});"
    , "const route = (name) => {"
    , "  const found = contract.routes.find((candidate) => candidate.name === name);"
    , "  if (!found) { throw new Error(`missing route ${name}`); }"
    , "  return found;"
    , "};"
    , "const landingRoute = route('landingRoute');"
    , "const inboxRoute = route('inboxRoute');"
    , "const primaryLeadRoute = route('primaryLeadRoute');"
    , "const createLeadRoute = route('createLeadRoute');"
    , "const reviewLeadRoute = route('reviewLeadRoute');"
    , "const landingHtml = landingRoute.encodeResponse(await landingRoute.handler({}));"
    , "const createRequest = new Request('http://example.test/leads', {"
    , "  method: 'POST',"
    , "  headers: { 'content-type': 'application/x-www-form-urlencoded' },"
    , "  body: 'company=SynthSpeak&contact=Ada+Lovelace&budget=65000&segment=enterprise'"
    , "});"
    , "const createPayload = createLeadRoute.decodeRequest(await requestPayloadJson(createLeadRoute, createRequest));"
    , "const createdHtml = createLeadRoute.encodeResponse(await createLeadRoute.handler(createPayload));"
    , "const inboxHtml = inboxRoute.encodeResponse(await inboxRoute.handler({}));"
    , "const detailHtml = primaryLeadRoute.encodeResponse(await primaryLeadRoute.handler({}));"
    , "const reviewRequest = new Request('http://example.test/review', {"
    , "  method: 'POST',"
    , "  headers: { 'content-type': 'application/x-www-form-urlencoded' },"
    , "  body: 'leadId=lead-3&note=Call+tomorrow'"
    , "});"
    , "const reviewPayload = reviewLeadRoute.decodeRequest(await requestPayloadJson(reviewLeadRoute, reviewRequest));"
    , "const reviewHtml = reviewLeadRoute.encodeResponse(await reviewLeadRoute.handler(reviewPayload));"
    , "const invalidRequest = new Request('http://example.test/leads', {"
    , "  method: 'POST',"
    , "  headers: { 'content-type': 'application/x-www-form-urlencoded' },"
    , "  body: 'company=SynthSpeak&contact=Ada+Lovelace&budget=oops'"
    , "});"
    , "let invalidMessage = null;"
    , "try {"
    , "  createLeadRoute.decodeRequest(await requestPayloadJson(createLeadRoute, invalidRequest));"
    , "} catch (error) {"
    , "  invalidMessage = error instanceof Error ? error.message : String(error);"
    , "}"
    , "console.log(JSON.stringify({"
    , "  contractKind: contract.kind,"
    , "  contractVersion: contract.version,"
    , "  contractRouteCount: contract.routes.length,"
    , "  contractAssetBasePath: contract.staticAssetStrategy.assetBasePath,"
    , "  manifestTypes: ["
    , "    manifest.mockLeadSummaryModel.params[0].type,"
    , "    `${manifest.storeLead.params[0].type} -> ${manifest.storeLead.params[1].type}`,"
    , "    `${manifest.loadInbox.params[0].type} -> ${manifest.loadInbox.returns.type}`,"
    , "    manifest.reviewLead.params[0].type"
    , "  ],"
    , "  structuredModelArg,"
    , "  structuredStoreArg,"
    , "  landingHasForm: landingHtml.includes('action=\"/leads\"') && landingHtml.includes('name=\"segment\"'),"
    , "  createdHasLead: createdHtml.includes('SynthSpeak') && createdHtml.includes('Ada Lovelace'),"
    , "  inboxHasLink: inboxHtml.includes('href=\"/lead/primary\"') && inboxHtml.includes('SynthSpeak (high, enterprise)'),"
    , "  detailHasLead: detailHtml.includes('SynthSpeak') && detailHtml.includes('Priority: high') && detailHtml.includes('Segment: enterprise'),"
    , "  reviewHasNote: reviewHtml.includes('Call tomorrow') && reviewHtml.includes('Review status: reviewed'),"
    , "  invalid: invalidMessage"
    , "}));"
    ]
