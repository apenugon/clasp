{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (finally)
import Control.Monad (when)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as LT
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , makeAbsolute
  , removePathForcibly
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>), takeDirectory)
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
import Clasp.Compiler (airEntry, airSource, checkEntry, checkSource, compileEntry, compileSource, parseSource, renderAirSourceJson)
import Clasp.Diagnostic
  ( Diagnostic (..)
  , DiagnosticBundle (..)
  , renderDiagnosticBundle
  , renderDiagnosticBundleJson
  )
import Clasp.Lower
  ( LowerDecl (..)
  , LowerExpr (..)
  , LowerMatchBranch (..)
  , LowerModule (..)
  , LowerRecordField (..)
  , LowerRouteContract (..)
  , lowerModule
  )
import Clasp.Syntax
  ( ConstructorDecl (..)
  , Decl (..)
  , Expr (..)
  , ForeignDecl (..)
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
    , airTests
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
    , testCase "parses compiler-known page types through the normal surface" $
        case parseSource "inline" pageSource of
          Left err ->
            assertFailure ("expected page source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case (findDecl "home" (moduleDecls modl), moduleRouteDecls modl) of
              (Just decl, [routeDecl]) -> do
                assertEqual "page annotation" (Just (TFunction [TNamed "Empty"] (TNamed "Page"))) (declAnnotation decl)
                assertEqual "page route response" "Page" (routeDeclResponseType routeDecl)
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
                    (LPage (LString "Inbox") (LViewAppend (LViewLink (LowerRouteContract "leadRoute" "GET" "/lead/primary" "Empty" "Page" "page") "/lead/primary" _) (LViewForm (LowerRouteContract "createLeadRoute" "POST" "/leads" "LeadCreate" "Redirect" "redirect") "POST" "/leads" _)))
                  ) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered interactive page declaration: " <> show other)
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
    , testCase "compile emits runtime bindings, codecs, and route metadata" $
        case compileSource "service" serviceSource of
          Left err ->
            assertFailure ("expected service compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected foreign runtime wrapper" ("function mockLeadSummaryModel($0) { return $claspCallHostBinding(\"mockLeadSummaryModel\", [$0]); }" `T.isInfixOf` emitted)
            assertBool "expected host binding manifest export" ("export const __claspHostBindings = [" `T.isInfixOf` emitted)
            assertBool "expected host binding manifest schema" ("schema: $claspSchema_LeadRequest" `T.isInfixOf` emitted)
            assertBool "expected host binding manifest return type" ("returns: {" `T.isInfixOf` emitted)
            assertBool "expected enum decoder" ("function $decode_LeadPriority" `T.isInfixOf` emitted)
            assertBool "expected internal enum validator" ("function $validateInternal_LeadPriority" `T.isInfixOf` emitted)
            assertBool "expected record decoder" ("function $decode_LeadSummary" `T.isInfixOf` emitted)
            assertBool "expected record encoder to validate internal values" ("function $encode_LeadSummary(value) { return JSON.stringify($serialize_LeadSummary($validateInternal_LeadSummary(value, \"value\"))); }" `T.isInfixOf` emitted)
            assertBool "expected route registry" ("export const __claspRoutes" `T.isInfixOf` emitted)
            assertBool "expected route path" ("\"/lead/summary\"" `T.isInfixOf` emitted)
            assertBool "expected request schema metadata" ("requestSchema: $claspSchema_LeadRequest" `T.isInfixOf` emitted)
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
            assertBool "expected view renderer" ("function $claspRenderView" `T.isInfixOf` emitted)
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
            assertBool "expected redirect contract metadata" ("responseKind: \"redirect\"" `T.isInfixOf` emitted)
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
              assertBool "expected title" ("<title>Inbox</title>" `T.isInfixOf` renderedHtml)
              assertBool "expected escaped subject" ("&lt;Quarterly &lt;review&gt;&gt;" `T.isInfixOf` renderedHtml)
              assertBool "expected escaped ampersand" ("Escaped &amp; archived" `T.isInfixOf` renderedHtml)
              assertBool "expected explicit style ref wrapper" ("data-clasp-style=\"inbox_shell\"" `T.isInfixOf` renderedHtml)
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
                "{\"query\":{\"customerId\":\"00123\",\"quantity\":7},\"form\":{\"customerId\":\"00123\",\"quantity\":7},\"html\":\"<!DOCTYPE html><html><head><meta charset=\\\"utf-8\\\"><title>Order</title></head><body>00123</body></html>\",\"invalid\":\"quantity must be an integer\"}"
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
              "{\"manifestTypes\":[\"LeadIntake\",\"LeadIntake -> LeadSummary\",\"Empty -> Str\",\"LeadReview\"],\"structuredModelArg\":true,\"structuredStoreArg\":true,\"landingHasForm\":true,\"createdHasLead\":true,\"inboxHasLink\":true,\"detailHasLead\":true,\"reviewHasNote\":true,\"invalid\":\"budget must be an integer\"}"
              runtimeOutput
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

leadInboxRuntimeScript :: FilePath -> FilePath -> Text
leadInboxRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { installRuntime, requestPayloadJson } from " <> show ("file://" <> runtimePath) <> ";"
    , "const manifest = Object.fromEntries(compiledModule.__claspHostBindings.map((binding) => [binding.name, binding]));"
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
    , "installRuntime({"
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
    , "  const found = compiledModule.__claspRoutes.find((candidate) => candidate.name === name);"
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
