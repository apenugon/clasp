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
  , explainSource
  , formatSource
  , parseSource
  , renderAirSourceJson
  , renderContextSourceJson
  , semanticEditSource
  )
import Clasp.Core
  ( CoreAgentDecl (..)
  , CoreAgentRoleDecl (..)
  , CoreDecl (..)
  , CoreExpr (..)
  , CoreHookDecl (..)
  , CoreMatchBranch (..)
  , CoreMergeGateDecl (..)
  , CoreModule (..)
  , CorePattern (..)
  , CoreToolDecl (..)
  , CoreToolServerDecl (..)
  , CoreVerifierDecl (..)
  , CoreWorkflowDecl (..)
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
  ( AgentDecl (..)
  , AgentRoleApprovalPolicy (..)
  , AgentRoleDecl (..)
  , AgentRoleSandboxPolicy (..)
  , ConstructorDecl (..)
  , Decl (..)
  , Expr (..)
  , ForeignDecl (..)
  , ForeignPackageImport (..)
  , ForeignPackageImportKind (..)
  , GuideDecl (..)
  , GuideEntryDecl (..)
  , HookDecl (..)
  , HookTriggerDecl (..)
  , MatchBranch (..)
  , MergeGateDecl (..)
  , MergeGateVerifierRef (..)
  , Module (..)
  , ModuleName (..)
  , Pattern (..)
  , PatternBinder (..)
  , Position (..)
  , PolicyDecl (..)
  , PolicyPermissionDecl (..)
  , PolicyPermissionKind (..)
  , ProjectionDecl (..)
  , RecordDecl (..)
  , RecordFieldDecl (..)
  , RecordFieldExpr (..)
  , RouteBoundaryDecl (..)
  , RouteDecl (..)
  , RouteMethod (..)
  , RoutePathDecl (..)
  , SourceSpan (..)
  , ToolDecl (..)
  , ToolServerDecl (..)
  , Type (..)
  , TypeDecl (..)
  , VerifierDecl (..)
  , WorkflowDecl (..)
  )

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "clasp-compiler"
    [ parserTests
    , formatterTests
    , checkerTests
    , explainTests
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
    , testCase "infers the module name when the file header is omitted" $
        case parseSource "Main.clasp" headerlessMainSource of
          Left err ->
            assertFailure ("expected headerless source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            assertEqual "inferred module name" (ModuleName "Main") (moduleName modl)
            assertEqual "import count" 1 (length (moduleImports modl))
            case findDecl "main" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EString _ "ready" ->
                    pure ()
                  other ->
                    assertFailure ("expected string literal body, got " <> show other)
              Nothing ->
                assertFailure "expected main declaration"
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
              [policyDecl] -> do
                assertEqual "policy name" "SupportDisclosure" (policyDeclName policyDecl)
                assertEqual
                  "policy permissions"
                  [ PolicyPermissionDecl PolicyPermissionFile dummySpan "/workspace"
                  , PolicyPermissionDecl PolicyPermissionNetwork dummySpan "api.openai.com"
                  , PolicyPermissionDecl PolicyPermissionProcess dummySpan "rg"
                  , PolicyPermissionDecl PolicyPermissionSecret dummySpan "OPENAI_API_KEY"
                  ]
                  (normalizePolicyPermissions (policyDeclPermissions policyDecl))
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
    , testCase "parses hooks with lifecycle triggers" $
        case parseSource "inline" hookSource of
          Left err ->
            assertFailure ("expected hook source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case moduleHookDecls modl of
              [hookDecl] -> do
                assertEqual "hook name" "workerStart" (hookDeclName hookDecl)
                assertEqual "hook identity" "hook:workerStart" (hookDeclIdentity hookDecl)
                assertEqual "hook trigger" (HookTriggerDecl "worker.start" dummySpan) ((hookDeclTrigger hookDecl) {hookTriggerDeclSpan = dummySpan})
                assertEqual "hook request" "WorkerBoot" (hookDeclRequestType hookDecl)
                assertEqual "hook response" "HookAck" (hookDeclResponseType hookDecl)
                assertEqual "hook handler" "bootstrapWorker" (hookDeclHandlerName hookDecl)
              other ->
                assertFailure ("expected one hook declaration, got " <> show (length other))
    , testCase "parses workflow declarations with typed state" $
        case parseSource "inline" workflowSource of
          Left err ->
            assertFailure ("expected workflow source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case moduleWorkflowDecls modl of
              [workflowDecl] -> do
                assertEqual "workflow name" "CounterFlow" (workflowDeclName workflowDecl)
                assertEqual "workflow identity" "workflow:CounterFlow" (workflowDeclIdentity workflowDecl)
                assertEqual "workflow state type" (TNamed "Counter") (workflowDeclStateType workflowDecl)
              other ->
                assertFailure ("expected one workflow declaration, got " <> show (length other))
    , testCase "parses agent roles and agent bindings" $
        case parseSource "inline" agentSource of
          Left err ->
            assertFailure ("expected agent source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            case moduleAgentRoleDecls modl of
              [agentRoleDecl] -> do
                assertEqual "agent role name" "WorkerRole" (agentRoleDeclName agentRoleDecl)
                assertEqual "agent role identity" "agent-role:WorkerRole" (agentRoleDeclIdentity agentRoleDecl)
                assertEqual "agent role guide" "Worker" (agentRoleDeclGuideName agentRoleDecl)
                assertEqual "agent role policy" "SupportDisclosure" (agentRoleDeclPolicyName agentRoleDecl)
                assertEqual "agent role approval" (Just AgentRoleApprovalOnRequest) (agentRoleDeclApprovalPolicy agentRoleDecl)
                assertEqual "agent role sandbox" (Just AgentRoleSandboxWorkspaceWrite) (agentRoleDeclSandboxPolicy agentRoleDecl)
              other ->
                assertFailure ("expected one agent role declaration, got " <> show (length other))
            case moduleAgentDecls modl of
              [agentDecl] -> do
                assertEqual "agent name" "builder" (agentDeclName agentDecl)
                assertEqual "agent identity" "agent:builder" (agentDeclIdentity agentDecl)
                assertEqual "agent role" "WorkerRole" (agentDeclRoleName agentDecl)
              other ->
                assertFailure ("expected one agent declaration, got " <> show (length other))
    , testCase "parses sandbox-only agent role attributes" $
        case parseSource "inline" agentSandboxOnlySource of
          Left err ->
            assertFailure ("expected sandbox-only agent source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case moduleAgentRoleDecls modl of
              [agentRoleDecl] -> do
                assertEqual "agent role guide" "Worker" (agentRoleDeclGuideName agentRoleDecl)
                assertEqual "agent role policy" "SupportDisclosure" (agentRoleDeclPolicyName agentRoleDecl)
                assertEqual "agent role approval" Nothing (agentRoleDeclApprovalPolicy agentRoleDecl)
                assertEqual "agent role sandbox" (Just AgentRoleSandboxReadOnly) (agentRoleDeclSandboxPolicy agentRoleDecl)
              other ->
                assertFailure ("expected one agent role declaration, got " <> show (length other))
    , testCase "parses agent role approval and sandbox attributes in either order" $
        case parseSource "inline" agentMixedOrderingSource of
          Left err ->
            assertFailure ("expected mixed-order agent source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case moduleAgentRoleDecls modl of
              [agentRoleDecl] -> do
                assertEqual "agent role approval" (Just AgentRoleApprovalOnRequest) (agentRoleDeclApprovalPolicy agentRoleDecl)
                assertEqual "agent role sandbox" (Just AgentRoleSandboxWorkspaceWrite) (agentRoleDeclSandboxPolicy agentRoleDecl)
              other ->
                assertFailure ("expected one agent role declaration, got " <> show (length other))
    , testCase "parses tool servers and tool contracts" $
        case parseSource "inline" toolSource of
          Left err ->
            assertFailure ("expected tool source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            case moduleToolServerDecls modl of
              [toolServerDecl] -> do
                assertEqual "tool server name" "RepoTools" (toolServerDeclName toolServerDecl)
                assertEqual "tool server identity" "toolserver:RepoTools" (toolServerDeclIdentity toolServerDecl)
                assertEqual "tool server protocol" "mcp" (toolServerDeclProtocol toolServerDecl)
                assertEqual "tool server location" "stdio://repo-tools" (toolServerDeclLocation toolServerDecl)
                assertEqual "tool server policy" "SupportDisclosure" (toolServerDeclPolicyName toolServerDecl)
              other ->
                assertFailure ("expected one tool server declaration, got " <> show (length other))
            case moduleToolDecls modl of
              [toolDecl] -> do
                assertEqual "tool name" "searchRepo" (toolDeclName toolDecl)
                assertEqual "tool identity" "tool:searchRepo" (toolDeclIdentity toolDecl)
                assertEqual "tool server" "RepoTools" (toolDeclServerName toolDecl)
                assertEqual "tool operation" "search_repo" (toolDeclOperation toolDecl)
                assertEqual "tool request" "SearchRequest" (toolDeclRequestType toolDecl)
                assertEqual "tool response" "SearchResponse" (toolDeclResponseType toolDecl)
              other ->
                assertFailure ("expected one tool declaration, got " <> show (length other))
    , testCase "parses verifier rules and merge gates" $
        case parseSource "inline" verifierSource of
          Left err ->
            assertFailure ("expected verifier source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            case moduleVerifierDecls modl of
              [verifierDecl] -> do
                assertEqual "verifier name" "repoChecks" (verifierDeclName verifierDecl)
                assertEqual "verifier identity" "verifier:repoChecks" (verifierDeclIdentity verifierDecl)
                assertEqual "verifier tool" "searchRepo" (verifierDeclToolName verifierDecl)
              other ->
                assertFailure ("expected one verifier declaration, got " <> show (length other))
            case moduleMergeGateDecls modl of
              [mergeGateDecl] -> do
                assertEqual "merge gate name" "trunk" (mergeGateDeclName mergeGateDecl)
                assertEqual "merge gate identity" "mergegate:trunk" (mergeGateDeclIdentity mergeGateDecl)
                assertEqual
                  "merge gate verifiers"
                  [MergeGateVerifierRef "repoChecks" dummySpan]
                  (fmap (\ref -> ref {mergeGateVerifierRefSpan = dummySpan}) (mergeGateDeclVerifierRefs mergeGateDecl))
              other ->
                assertFailure ("expected one merge gate declaration, got " <> show (length other))
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
    , testCase "parses package-backed foreign declarations" $
        case parseSource "inline" packageForeignSource of
          Left err ->
            assertFailure ("expected parse success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case moduleForeignDecls modl of
              [npmDecl, tsDecl] -> do
                assertEqual "npm foreign name" "upperCase" (foreignDeclName npmDecl)
                assertEqual
                  "npm package import"
                  ( Just
                      ForeignPackageImport
                        { foreignPackageImportKind = ForeignPackageImportNpm
                        , foreignPackageImportKindSpan = dummySpan
                        , foreignPackageImportSpecifier = "local-upper"
                        , foreignPackageImportSpecifierSpan = dummySpan
                        , foreignPackageImportDeclarationPath = "./node_modules/local-upper/index.d.ts"
                        , foreignPackageImportDeclarationSpan = dummySpan
                        , foreignPackageImportSignature = Nothing
                        }
                  )
                  (fmap normalizeForeignPackageImport (foreignDeclPackageImport npmDecl))
                assertEqual "typescript foreign runtime name" "formatLead" (foreignDeclRuntimeName tsDecl)
              other ->
                assertFailure ("expected two foreign declarations, got " <> show (length other))
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

    , testCase "parses block expressions" $
        case parseSource "inline" blockExpressionSource of
          Left err ->
            assertFailure ("expected block expression source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "greeting" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EBlock blockSpan (ELet _ _ "message" (EString _ "Ada") (EVar _ "message")) ->
                    assertEqual "block starts on declaration line" 4 (positionLine (sourceSpanStart blockSpan))
                  other ->
                    assertFailure ("expected block expression body, got " <> show other)
              Nothing ->
                assertFailure "expected greeting declaration"
    , testCase "parses local variable declarations inside blocks" $
        case parseSource "inline" blockLocalDeclarationsSource of
          Left err ->
            assertFailure ("expected block locals source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "greeting" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EBlock blockSpan (ELet _ firstBinder "message" (EString _ "Ada") (ELet _ secondBinder "alias" (EVar _ "message") (EVar _ "alias"))) -> do
                    assertEqual "block starts on declaration line" 4 (positionLine (sourceSpanStart blockSpan))
                    assertEqual "first binder line" 5 (positionLine (sourceSpanStart firstBinder))
                    assertEqual "second binder line" 6 (positionLine (sourceSpanStart secondBinder))
                  other ->
                    assertFailure ("expected block locals body, got " <> show other)
              Nothing ->
                assertFailure "expected greeting declaration"
    , testCase "parses mutable local assignments inside blocks" $
        case parseSource "inline" mutableBlockAssignmentSource of
          Left err ->
            assertFailure ("expected mutable block assignment source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "greeting" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EBlock blockSpan (EMutableLet _ binderSpan "message" (EString _ "Ada") (EAssign _ assignSpan "message" (EString _ "Grace") (EVar _ "message"))) -> do
                    assertEqual "block starts on declaration line" 4 (positionLine (sourceSpanStart blockSpan))
                    assertEqual "mutable binder line" 5 (positionLine (sourceSpanStart binderSpan))
                    assertEqual "assignment line" 6 (positionLine (sourceSpanStart assignSpan))
                  other ->
                    assertFailure ("expected mutable block assignment body, got " <> show other)
              Nothing ->
                assertFailure "expected greeting declaration"
    , testCase "parses for-loops over list values inside blocks" $
        case parseSource "inline" loopIterationSource of
          Left err ->
            assertFailure ("expected loop iteration source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "pickLast" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EBlock blockSpan (EMutableLet _ binderSpan "current" (EString _ "nobody") (EFor _ loopBinder "name" (EVar _ "names") (EBlock _ (EAssign _ assignSpan "current" (EVar _ "name") (EVar _ "current"))) (EVar _ "current"))) -> do
                    assertEqual "block starts on declaration line" 4 (positionLine (sourceSpanStart blockSpan))
                    assertEqual "mutable binder line" 5 (positionLine (sourceSpanStart binderSpan))
                    assertEqual "loop binder line" 6 (positionLine (sourceSpanStart loopBinder))
                    assertEqual "assignment line" 7 (positionLine (sourceSpanStart assignSpan))
                  other ->
                    assertFailure ("expected parsed for-loop body, got " <> show other)
              Nothing ->
                assertFailure "expected pickLast declaration"
    , testCase "parses early return expressions inside function bodies" $
        case parseSource "inline" earlyReturnSource of
          Left err ->
            assertFailure ("expected early return source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "choose" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EBlock _ (ELet _ _ "alias" (EVar _ "name") (EMatch _ (EVar _ "decision") [MatchBranch _ (PConstructor _ "Exit" []) (EReturn _ (EVar _ "alias")), MatchBranch _ (PConstructor _ "Continue" []) (EString _ "fallback")])) ->
                    pure ()
                  other ->
                    assertFailure ("expected early return in match branch, got " <> show other)
              Nothing ->
                assertFailure "expected choose declaration"
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
    , testCase "parses operator precedence with comparisons tighter than equality" $
        case parseSource "inline" operatorPrecedenceSource of
          Left err ->
            assertFailure ("expected operator precedence source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "main" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EEqual
                    _
                    (ELessThan _ (EInt _ 1) (EInt _ 2))
                    (EGreaterThan _ (EInt _ 3) (EInt _ 2)) ->
                      pure ()
                  other ->
                    assertFailure ("expected equality over comparison expressions, got " <> show other)
              Nothing ->
                assertFailure "expected main declaration"
    , testCase "parses equality operators as left-associative" $
        case parseSource "inline" equalityAssociativitySource of
          Left err ->
            assertFailure ("expected equality associativity source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "main" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EEqual _ (EEqual _ (EBool _ True) (EBool _ False)) (EBool _ True) ->
                    pure ()
                  other ->
                    assertFailure ("expected left-associated equality chain, got " <> show other)
              Nothing ->
                assertFailure "expected main declaration"
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

formatterTests :: TestTree
formatterTests =
  testGroup
    "formatter"
    [ testCase "adds inferred module headers and normalizes top-level ordering" $
        case formatSource "Main.clasp" formatterCanonicalizationSource of
          Left err ->
            assertFailure ("expected formatter success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right formatted ->
            assertEqual "canonical source" formatterCanonicalizationExpected formatted
    , testCase "formats composite modules stably" $
        case formatSource "Main.clasp" formatterRoundTripSource of
          Left err ->
            assertFailure ("expected formatter success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right formatted ->
            case formatSource "Main.clasp" formatted of
              Left err ->
                assertFailure ("expected formatted output to parse:\n" <> T.unpack (renderDiagnosticBundle err))
              Right reformatted ->
                assertEqual "formatter should be idempotent" formatted reformatted
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
    , testCase "accepts hooks with typed lifecycle handlers" $
        case checkSource "hook" hookSource of
          Left err ->
            assertFailure ("expected hook source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case coreModuleHookDecls checked of
              [CoreHookDecl hookDecl] ->
                assertEqual "hook trigger event" "worker.start" (hookTriggerDeclEvent (hookDeclTrigger hookDecl))
              other ->
                assertFailure ("expected one checked hook declaration, got " <> show (length other))
    , testCase "accepts workflows with record-typed durable state" $
        case checkSource "workflow" workflowSource of
          Left err ->
            assertFailure ("expected workflow source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case coreModuleWorkflowDecls checked of
              [CoreWorkflowDecl workflowDecl] ->
                assertEqual "workflow state type" (TNamed "Counter") (workflowDeclStateType workflowDecl)
              other ->
                assertFailure ("expected one checked workflow declaration, got " <> show (length other))
    , testCase "accepts agent roles that bind guides and policies to agents" $
        case checkSource "agent" agentSource of
          Left err ->
            assertFailure ("expected agent source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            case coreModuleAgentRoleDecls checked of
              [CoreAgentRoleDecl agentRoleDecl] ->
                do
                  assertEqual "agent role policy" "SupportDisclosure" (agentRoleDeclPolicyName agentRoleDecl)
                  assertEqual "agent role approval" (Just AgentRoleApprovalOnRequest) (agentRoleDeclApprovalPolicy agentRoleDecl)
                  assertEqual "agent role sandbox" (Just AgentRoleSandboxWorkspaceWrite) (agentRoleDeclSandboxPolicy agentRoleDecl)
              other ->
                assertFailure ("expected one checked agent role declaration, got " <> show (length other))
            case coreModuleAgentDecls checked of
              [CoreAgentDecl agentDecl] ->
                assertEqual "agent role binding" "WorkerRole" (agentDeclRoleName agentDecl)
              other ->
                assertFailure ("expected one checked agent declaration, got " <> show (length other))
    , testCase "accepts tool servers and tool contracts with typed schemas" $
        case checkSource "tool" toolSource of
          Left err ->
            assertFailure ("expected tool source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            case coreModuleToolServerDecls checked of
              [CoreToolServerDecl toolServerDecl] ->
                assertEqual "tool server policy" "SupportDisclosure" (toolServerDeclPolicyName toolServerDecl)
              other ->
                assertFailure ("expected one checked tool server declaration, got " <> show (length other))
            case coreModuleToolDecls checked of
              [CoreToolDecl toolDecl] ->
                assertEqual "tool contract response" "SearchResponse" (toolDeclResponseType toolDecl)
              other ->
                assertFailure ("expected one checked tool declaration, got " <> show (length other))
    , testCase "accepts verifier rules that bind tools into merge gates" $
        case checkSource "verifier" verifierSource of
          Left err ->
            assertFailure ("expected verifier source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            case coreModuleVerifierDecls checked of
              [CoreVerifierDecl verifierDecl] ->
                assertEqual "verifier tool binding" "searchRepo" (verifierDeclToolName verifierDecl)
              other ->
                assertFailure ("expected one checked verifier declaration, got " <> show (length other))
            case coreModuleMergeGateDecls checked of
              [CoreMergeGateDecl mergeGateDecl] ->
                assertEqual "merge gate verifier count" 1 (length (mergeGateDeclVerifierRefs mergeGateDecl))
              other ->
                assertFailure ("expected one checked merge gate declaration, got " <> show (length other))
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
    , testCase "typechecks block expressions by desugaring to the inner expression" $
        case checkSource "block" blockExpressionSource of
          Left err ->
            assertFailure ("expected block source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case find ((== "greeting") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CLet _ typ "message" (CString _ "Ada") (CVar _ bodyType "message") -> do
                    assertEqual "block let result type" TStr typ
                    assertEqual "block let body variable type" TStr bodyType
                  other ->
                    assertFailure ("expected checked block expression to lower to let, got " <> show other)
              Nothing ->
                assertFailure "expected greeting declaration"
    , testCase "typechecks block-local declarations by desugaring to nested lets" $
        case checkSource "block-locals" blockLocalDeclarationsSource of
          Left err ->
            assertFailure ("expected block locals source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case find ((== "greeting") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CLet _ typ "message" (CString _ "Ada") (CLet _ aliasType "alias" (CVar _ messageType "message") (CVar _ bodyType "alias")) -> do
                    assertEqual "outer let result type" TStr typ
                    assertEqual "inner let result type" TStr aliasType
                    assertEqual "message variable type" TStr messageType
                    assertEqual "body variable type" TStr bodyType
                  other ->
                    assertFailure ("expected checked block locals to lower to nested lets, got " <> show other)
              Nothing ->
                assertFailure "expected greeting declaration"
    , testCase "typechecks mutable block assignments by rebinding the local" $
        case checkSource "mutable-block" mutableBlockAssignmentSource of
          Left err ->
            assertFailure ("expected mutable block assignment source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case find ((== "greeting") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CMutableLet _ outerType "message" (CString _ "Ada") (CAssign _ innerType "message" (CString _ "Grace") (CVar _ bodyType "message")) -> do
                    assertEqual "outer let result type" TStr outerType
                    assertEqual "assignment result type" TStr innerType
                    assertEqual "body variable type" TStr bodyType
                  other ->
                    assertFailure ("expected checked mutable block assignment to preserve mutability, got " <> show other)
              Nothing ->
                assertFailure "expected greeting declaration"
    , testCase "typechecks for-loops over list values while preserving outer mutable locals" $
        case checkSource "for-loop" loopIterationSource of
          Left err ->
            assertFailure ("expected loop iteration source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case find ((== "pickLast") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CMutableLet _ outerType "current" (CString _ "nobody") (CFor _ loopType "name" (CVar _ (TList TStr) "names") (CAssign _ innerType "current" (CVar _ TStr "name") (CVar _ bodyType "current")) (CVar _ resultType "current")) -> do
                    assertEqual "outer let result type" TStr outerType
                    assertEqual "loop result type" TStr loopType
                    assertEqual "assignment result type" TStr innerType
                    assertEqual "inner body variable type" TStr bodyType
                    assertEqual "final variable type" TStr resultType
                  other ->
                    assertFailure ("expected checked for-loop expression, got " <> show other)
              Nothing ->
                assertFailure "expected pickLast declaration"
    , testCase "typechecks early returns against the enclosing function result" $
        case checkSource "return" earlyReturnSource of
          Left err ->
            assertFailure ("expected early return source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case find ((== "choose") . coreDeclName) (coreModuleDecls checked) of
              Just decl -> do
                assertEqual "choose type" (TFunction [TNamed "Decision", TStr] TStr) (coreDeclType decl)
                case coreDeclBody decl of
                  CLet _ TStr "alias" (CVar _ TStr "name") (CMatch _ TStr (CVar _ (TNamed "Decision") "decision") [CoreMatchBranch _ (CConstructorPattern _ "Exit" []) (CReturn _ TStr (CVar _ TStr "alias")), CoreMatchBranch _ (CConstructorPattern _ "Continue" []) (CString _ "fallback")]) ->
                    pure ()
                  other ->
                    assertFailure ("expected checked early return expression, got " <> show other)
              Nothing ->
                assertFailure "expected choose declaration"
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
    , testCase "rejects assignment to immutable block locals" $
        assertHasCode "E_ASSIGNMENT_TARGET" (checkSource "bad" immutableBlockAssignmentSource)
    , testCase "rejects assignment to names that are not mutable block locals" $
        assertHasCode "E_ASSIGNMENT_TARGET" (checkSource "bad" nonLocalAssignmentSource)
    , testCase "rejects for-loops over non-list iterables" $
        assertHasCode "E_FOR_ITERABLE" (checkSource "bad" invalidForIterableSource)
    , testCase "rejects return outside function bodies" $
        assertHasCode "E_RETURN_OUTSIDE_FUNCTION" (checkSource "bad" invalidEarlyReturnSource)
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
    , testCase "rejects hooks whose handlers do not match declared schemas" $
        assertHasCode "E_HOOK_HANDLER_TYPE" (checkSource "bad" badHookHandlerSource)
    , testCase "rejects workflows whose state is not a record schema" $
        assertHasCode "E_WORKFLOW_STATE_TYPE" (checkSource "bad" badWorkflowStateSource)
    , testCase "rejects agents that reference unknown roles" $
        assertHasCode "E_UNKNOWN_AGENT_ROLE" (checkSource "bad" unknownAgentRoleSource)
    , testCase "rejects tool servers that reference unknown policies" $
        assertHasCode "E_UNKNOWN_TOOLSERVER_POLICY" (checkSource "bad" unknownToolServerPolicySource)
    , testCase "rejects duplicate policy permission grants" $
        assertHasCode "E_DUPLICATE_POLICY_PERMISSION" (checkSource "bad" duplicatePolicyPermissionSource)
    , testCase "rejects tools that reference unknown servers" $
        assertHasCode "E_UNKNOWN_TOOLSERVER" (checkSource "bad" unknownToolServerSource)
    , testCase "rejects verifiers that reference unknown tools" $
        assertHasCode "E_UNKNOWN_VERIFIER_TOOL" (checkSource "bad" unknownVerifierToolSource)
    , testCase "rejects merge gates that reference unknown verifiers" $
        assertHasCode "E_UNKNOWN_MERGE_GATE_VERIFIER" (checkSource "bad" unknownMergeGateVerifierSource)
    , testCase "rejects tools that use non-record schemas" $
        assertHasCode "E_TOOL_SCHEMA_TYPE" (checkSource "bad" badToolSchemaSource)
    , testCase "rejects heterogeneous list literals" $
        assertHasCode "E_LIST_ITEM_TYPE" (checkSource "bad" heterogeneousListSource)
    , testCase "rejects equality over unsupported or mismatched types" $
        assertHasCode "E_EQUALITY_OPERAND" (checkSource "bad" badEqualitySource)
    , testCase "rejects equality without primitive operand constraints" $
        assertHasCode "E_EQUALITY_OPERAND" (checkSource "bad" unconstrainedEqualitySource)
    , testCase "rejects invalid operator combinations after precedence is applied" $
        assertHasCode "E_EQUALITY_OPERAND" (checkSource "bad" badOperatorCombinationSource)
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

explainTests :: TestTree
explainTests =
  testGroup
    "explain"
    [ testCase "explain renders typed lets and desugared block structure" $
        case explainSource "block" blockExpressionSource of
          Left err ->
            assertFailure ("expected explain rendering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right rendered -> do
            assertBool "expected declaration signature" ("greeting : Str" `T.isInfixOf` rendered)
            assertBool "expected typed let binding" ("let message : Str =" `T.isInfixOf` rendered)
            assertBool "expected typed variable reference" ("(message : Str)" `T.isInfixOf` rendered)
    , testCase "explain renders typed decode flows for checked programs" $
        case explainSource "service" serviceSource of
          Left err ->
            assertFailure ("expected explain rendering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right rendered -> do
            assertBool "expected summarizeLead signature" ("summarizeLead : LeadRequest -> LeadSummary" `T.isInfixOf` rendered)
            assertBool "expected typed parameter" ("summarizeLead (lead : LeadRequest)" `T.isInfixOf` rendered)
            assertBool "expected typed decode" ("decode LeadSummary" `T.isInfixOf` rendered && ": LeadSummary" `T.isInfixOf` rendered)
    , testCase "claspc explain emits json output when requested" $
        withProjectFiles "explain-cli-json" [("Main.clasp", blockExpressionSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
          (exitCode, stdoutText, stderrText) <- runClaspc ["explain", inputPath, "--json"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("claspc explain failed:\n" <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected explain json to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "explain")) (lookupObjectKey "command" jsonValue)
          case lookupObjectKey "explanation" jsonValue of
            Just (String explanation) ->
              assertBool "expected typed let in json payload" ("let message : Str =" `T.isInfixOf` explanation)
            _ ->
              assertFailure "expected explanation string in explain json"
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
    , testCase "parse failures include dedicated fix hints in json" $
        case parseSource "bad" parseFailureSource of
          Left bundle -> do
            let jsonText = LT.toStrict (renderDiagnosticBundleJson bundle)
                expectedParseHint = "Check the syntax near the reported location and complete any missing delimiters, separators, or expressions."
            jsonValue <- case eitherDecodeStrictText jsonText of
              Left decodeErr ->
                assertFailure ("expected diagnostic json to decode:\n" <> decodeErr)
              Right value ->
                pure value
            diagnosticValue <- case lookupObjectKey "diagnostics" jsonValue of
              Just (Array diagnosticsJson) ->
                case toList diagnosticsJson of
                  firstDiagnostic : _ ->
                    pure firstDiagnostic
                  [] ->
                    assertFailure "expected at least one diagnostic in json"
              _ ->
                assertFailure "expected diagnostics array in diagnostic json"
            assertEqual "parse code" (Just (String "E_PARSE")) (lookupObjectKey "code" diagnosticValue)
            case lookupObjectKey "fixHints" diagnosticValue of
              Just (Array fixHintsJson) -> do
                assertEqual "expected dedicated parse fix hint" [String expectedParseHint] (toList fixHintsJson)
                assertBool
                  "expected fix hint to stay distinct from megaparsec detail text"
                  (all
                    (\hintValue ->
                        case hintValue of
                          String hintText -> not ("unexpected" `T.isInfixOf` T.toLower hintText)
                          _ -> False
                    )
                    (toList fixHintsJson)
                  )
              _ ->
                assertFailure "expected fixHints array in diagnostic json"
            case lookupObjectKey "details" diagnosticValue of
              Just (Array detailsJson) ->
                assertBool
                  "expected parser details to retain megaparsec output"
                  (any
                    (\detailValue ->
                        case detailValue of
                          String detailText -> "unexpected" `T.isInfixOf` T.toLower detailText
                          _ -> False
                    )
                    (toList detailsJson)
                  )
              _ ->
                assertFailure "expected details array in diagnostic json"
          Right _ ->
            assertFailure "expected parse failure"
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
              Just node -> do
                assertBool
                  "expected policy classification refs"
                  (("allowedClassifications", AirAttrNodes [AirNodeId "policy-classification:SupportDisclosure:public", AirNodeId "policy-classification:SupportDisclosure:pii"]) `elem` airNodeAttrs node)
                assertBool
                  "expected policy file permissions"
                  (("filePermissions", AirAttrTexts ["/workspace"]) `elem` airNodeAttrs node)
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
    , testCase "air retains hook triggers and typed boundaries" $
        case airSource "hook" hookSource of
          Left err ->
            assertFailure ("expected AIR generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right airModule -> do
            assertBool "expected hook root" (AirNodeId "hook:workerStart" `elem` airModuleRootIds airModule)
            case findAirNode (AirNodeId "hook:workerStart") (airModuleNodes airModule) of
              Just node -> do
                assertBool "expected hook trigger ref" (("trigger", AirAttrNode (AirNodeId "hook-trigger:workerStart")) `elem` airNodeAttrs node)
                assertBool "expected hook request boundary" (("request", AirAttrObject [("type", AirAttrText "WorkerBoot")]) `elem` airNodeAttrs node)
                assertBool "expected hook response boundary" (("response", AirAttrObject [("type", AirAttrText "HookAck")]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected workerStart hook AIR node"
            case findAirNode (AirNodeId "hook-trigger:workerStart") (airModuleNodes airModule) of
              Just node ->
                assertBool "expected lifecycle event" (("event", AirAttrText "worker.start") `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected hook trigger AIR node"
    , testCase "air retains agent roles and agent-to-role bindings" $
        case airSource "agent" agentSource of
          Left err ->
            assertFailure ("expected AIR generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right airModule -> do
            assertBool "expected agent role root" (AirNodeId "agent-role:WorkerRole" `elem` airModuleRootIds airModule)
            assertBool "expected agent root" (AirNodeId "agent:builder" `elem` airModuleRootIds airModule)
            case findAirNode (AirNodeId "agent-role:WorkerRole") (airModuleNodes airModule) of
              Just node -> do
                assertBool
                  "expected guide ref"
                  (("guide", AirAttrObject [("name", AirAttrText "Worker"), ("ref", AirAttrNode (AirNodeId "guide:Worker"))]) `elem` airNodeAttrs node)
                assertBool
                  "expected policy ref"
                  (("policy", AirAttrObject [("name", AirAttrText "SupportDisclosure"), ("ref", AirAttrNode (AirNodeId "policy:SupportDisclosure"))]) `elem` airNodeAttrs node)
                assertBool
                  "expected approval policy"
                  (("approvalPolicy", AirAttrText "on_request") `elem` airNodeAttrs node)
                assertBool
                  "expected sandbox policy"
                  (("sandboxPolicy", AirAttrText "workspace_write") `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected agent role AIR node"
            case findAirNode (AirNodeId "agent:builder") (airModuleNodes airModule) of
              Just node ->
                assertBool
                  "expected role ref"
                  (("role", AirAttrObject [("name", AirAttrText "WorkerRole"), ("ref", AirAttrNode (AirNodeId "agent-role:WorkerRole"))]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected agent AIR node"
    , testCase "air retains tool servers, policies, and typed tool contracts" $
        case airSource "tool" toolSource of
          Left err ->
            assertFailure ("expected AIR generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right airModule -> do
            assertBool "expected tool server root" (AirNodeId "toolserver:RepoTools" `elem` airModuleRootIds airModule)
            assertBool "expected tool root" (AirNodeId "tool:searchRepo" `elem` airModuleRootIds airModule)
            case findAirNode (AirNodeId "toolserver:RepoTools") (airModuleNodes airModule) of
              Just node ->
                assertBool
                  "expected tool server policy ref"
                  (("policy", AirAttrObject [("name", AirAttrText "SupportDisclosure"), ("ref", AirAttrNode (AirNodeId "policy:SupportDisclosure"))]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected tool server AIR node"
            case findAirNode (AirNodeId "tool:searchRepo") (airModuleNodes airModule) of
              Just node -> do
                assertBool
                  "expected tool server ref"
                  (("server", AirAttrObject [("name", AirAttrText "RepoTools"), ("ref", AirAttrNode (AirNodeId "toolserver:RepoTools"))]) `elem` airNodeAttrs node)
                assertBool "expected request boundary" (("request", AirAttrObject [("type", AirAttrText "SearchRequest")]) `elem` airNodeAttrs node)
                assertBool "expected response boundary" (("response", AirAttrObject [("type", AirAttrText "SearchResponse")]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected tool AIR node"
    , testCase "air retains verifier rule and merge gate references" $
        case airSource "verifier" verifierSource of
          Left err ->
            assertFailure ("expected AIR generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right airModule -> do
            assertBool "expected verifier root" (AirNodeId "verifier:repoChecks" `elem` airModuleRootIds airModule)
            assertBool "expected merge gate root" (AirNodeId "mergegate:trunk" `elem` airModuleRootIds airModule)
            case findAirNode (AirNodeId "verifier:repoChecks") (airModuleNodes airModule) of
              Just node ->
                assertBool
                  "expected verifier tool ref"
                  (("tool", AirAttrObject [("name", AirAttrText "searchRepo"), ("ref", AirAttrNode (AirNodeId "tool:searchRepo"))]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected verifier AIR node"
            case findAirNode (AirNodeId "mergegate:trunk") (airModuleNodes airModule) of
              Just node ->
                assertBool
                  "expected merge gate verifier refs"
                  (("verifiers", AirAttrNodes [AirNodeId "verifier:repoChecks"]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected merge gate AIR node"
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
    , testCase "context graph includes hooks, lifecycle triggers, and schema edges" $
        case renderContextSourceJson "hook" hookSource of
          Left err ->
            assertFailure ("expected context graph generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right rendered -> do
            let jsonText = LT.toStrict rendered
            assertBool "expected hook node" ("\"hook:workerStart\"" `T.isInfixOf` jsonText)
            assertBool "expected hook trigger node" ("\"hook-trigger:workerStart\"" `T.isInfixOf` jsonText)
            assertBool "expected hook trigger edge" ("\"hook-trigger\"" `T.isInfixOf` jsonText)
            assertBool "expected hook request edge" ("\"hook-request-schema\"" `T.isInfixOf` jsonText)
    , testCase "context graph includes agent roles, policies, and agent bindings" $
        case renderContextSourceJson "agent" agentSource of
          Left err ->
            assertFailure ("expected context graph generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right rendered -> do
            let jsonText = LT.toStrict rendered
            assertBool "expected policy node" ("\"policy:SupportDisclosure\"" `T.isInfixOf` jsonText)
            assertBool "expected agent role node" ("\"agent-role:WorkerRole\"" `T.isInfixOf` jsonText)
            assertBool "expected agent node" ("\"agent:builder\"" `T.isInfixOf` jsonText)
            assertBool "expected approval policy attr" ("\"name\":\"approvalPolicy\"" `T.isInfixOf` jsonText && "\"value\":\"on_request\"" `T.isInfixOf` jsonText)
            assertBool "expected sandbox policy attr" ("\"name\":\"sandboxPolicy\"" `T.isInfixOf` jsonText && "\"value\":\"workspace_write\"" `T.isInfixOf` jsonText)
            assertBool "expected agent role guide edge" ("\"agent-role-guide\"" `T.isInfixOf` jsonText)
            assertBool "expected agent role policy edge" ("\"agent-role-policy\"" `T.isInfixOf` jsonText)
            assertBool "expected agent role edge" ("\"agent-role\"" `T.isInfixOf` jsonText)
    , testCase "context graph includes policy permission attributes" $
        case renderContextSourceJson "policy" policyPermissionSource of
          Left err ->
            assertFailure ("expected context graph generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right rendered -> do
            let jsonText = LT.toStrict rendered
            assertBool "expected file permissions attr" ("\"filePermissions\"" `T.isInfixOf` jsonText && "\"/workspace\"" `T.isInfixOf` jsonText)
            assertBool "expected secret permissions attr" ("\"secretPermissions\"" `T.isInfixOf` jsonText && "\"OPENAI_API_KEY\"" `T.isInfixOf` jsonText)
    , testCase "context graph includes tool servers, policy edges, and tool schema edges" $
        case renderContextSourceJson "tool" toolSource of
          Left err ->
            assertFailure ("expected context graph generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right rendered -> do
            let jsonText = LT.toStrict rendered
            assertBool "expected tool server node" ("\"toolserver:RepoTools\"" `T.isInfixOf` jsonText)
            assertBool "expected tool node" ("\"tool:searchRepo\"" `T.isInfixOf` jsonText)
            assertBool "expected tool server policy edge" ("\"toolserver-policy\"" `T.isInfixOf` jsonText)
            assertBool "expected tool server edge" ("\"tool-server\"" `T.isInfixOf` jsonText)
            assertBool "expected tool request edge" ("\"tool-request-schema\"" `T.isInfixOf` jsonText)
            assertBool "expected tool response edge" ("\"tool-response-schema\"" `T.isInfixOf` jsonText)
    , testCase "context graph includes verifier-tool and merge-gate edges" $
        case renderContextSourceJson "verifier" verifierSource of
          Left err ->
            assertFailure ("expected context graph generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right rendered -> do
            let jsonText = LT.toStrict rendered
            assertBool "expected verifier node" ("\"verifier:repoChecks\"" `T.isInfixOf` jsonText)
            assertBool "expected merge gate node" ("\"mergegate:trunk\"" `T.isInfixOf` jsonText)
            assertBool "expected verifier tool edge" ("\"verifier-tool\"" `T.isInfixOf` jsonText)
            assertBool "expected merge gate verifier edge" ("\"merge-gate-verifier\"" `T.isInfixOf` jsonText)
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
    , testCase "lowering preserves workflow declarations for later runtime emission" $
        case lowerChecked "workflow" workflowSource of
          Left err ->
            assertFailure ("expected workflow lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case lowerModuleWorkflowDecls lowered of
              [workflowDecl] ->
                assertEqual "lowered workflow state type" (TNamed "Counter") (workflowDeclStateType workflowDecl)
              other ->
                assertFailure ("expected one lowered workflow declaration, got " <> show (length other))
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
    , testCase "lowering block expressions preserves the lowered inner expression" $
        case lowerChecked "block" blockExpressionSource of
          Left err ->
            assertFailure ("expected block lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "greeting" (lowerModuleDecls lowered) of
              Just (LValueDecl _ (LLet "message" (LString "Ada") (LVar "message"))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered block declaration: " <> show other)
    , testCase "lowering block-local declarations preserves nested lets" $
        case lowerChecked "block-locals" blockLocalDeclarationsSource of
          Left err ->
            assertFailure ("expected block locals lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "greeting" (lowerModuleDecls lowered) of
              Just (LValueDecl _ (LLet "message" (LString "Ada") (LLet "alias" (LVar "message") (LVar "alias")))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered block locals declaration: " <> show other)
    , testCase "lowering mutable block assignments preserves rebinding order" $
        case lowerChecked "mutable-block" mutableBlockAssignmentSource of
          Left err ->
            assertFailure ("expected mutable block assignment lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "greeting" (lowerModuleDecls lowered) of
              Just (LValueDecl _ (LMutableLet "message" (LString "Ada") (LAssign "message" (LString "Grace") (LVar "message")))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered mutable block assignment declaration: " <> show other)
    , testCase "lowering preserves for-loops over list values" $
        case lowerChecked "for-loop" loopIterationSource of
          Left err ->
            assertFailure ("expected loop iteration lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "pickLast" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["names"] (LMutableLet "current" (LString "nobody") (LFor "name" (LVar "names") (LAssign "current" (LVar "name") (LVar "current")) (LVar "current")))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered for-loop declaration: " <> show other)
    , testCase "lowering preserves early returns inside nested control flow" $
        case lowerChecked "return" earlyReturnSource of
          Left err ->
            assertFailure ("expected early return lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "choose" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["decision", "name"] (LLet "alias" (LVar "name") (LMatch (LVar "decision") [LowerMatchBranch "Exit" [] (LReturn (LVar "alias")), LowerMatchBranch "Continue" [] (LString "fallback")]))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered early return declaration: " <> show other)
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
    , testCase "compile emits workflow lifecycle, retry, and idempotency helpers" $
        case compileSource "workflow" workflowSource of
          Left err ->
            assertFailure ("expected workflow compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected workflow checkpoint helper" ("checkpoint(value) { return $encode_Counter(value); }" `T.isInfixOf` emitted)
            assertBool "expected workflow resume helper" ("resume(snapshot) { return $decode_Counter(snapshot); }" `T.isInfixOf` emitted)
            assertBool "expected workflow start helper" ("start(snapshot, options) { return $claspWorkflowStart(\"CounterFlow\", snapshot, $decode_Counter, options); }" `T.isInfixOf` emitted)
            assertBool "expected workflow deadline helper" ("withDeadline(run, deadlineAt) { return $claspWorkflowWithDeadline(\"CounterFlow\", run, deadlineAt); }" `T.isInfixOf` emitted)
            assertBool "expected workflow cancel helper" ("cancel(run, reason) { return $claspWorkflowCancel(\"CounterFlow\", run, reason); }" `T.isInfixOf` emitted)
            assertBool "expected workflow degrade helper" ("degrade(run, reason, options) { return $claspWorkflowDegrade(\"CounterFlow\", run, reason, options); }" `T.isInfixOf` emitted)
            assertBool "expected workflow handoff helper" ("handoff(run, operator, reason, options) { return $claspWorkflowHandoff(\"CounterFlow\", run, operator, reason, options); }" `T.isInfixOf` emitted)
            assertBool "expected workflow deliver helper" ("deliver(run, message, handler, options) { return $claspWorkflowDeliver(\"CounterFlow\", run, message, handler, $encode_Counter, false, options); }" `T.isInfixOf` emitted)
            assertBool "expected workflow replay helper" ("replay(snapshot, messages, handler, options) { return $claspWorkflowReplay(\"CounterFlow\", snapshot, messages, handler, $decode_Counter, $encode_Counter, options); }" `T.isInfixOf` emitted)
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
    , testCase "compile evaluates block expressions" $
        case compileSource "block" blockExpressionSource of
          Left err ->
            assertFailure ("expected block compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected block to compile through let emission" ("const message = \"Ada\";" `T.isInfixOf` emitted)
            let compiledPath = "dist/block-expression.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(compiledModule.greeting);"
                ]
            assertEqual "expected block result" "Ada" runtimeOutput
    , testCase "compile evaluates block-local declarations" $
        case compileSource "block-locals" blockLocalDeclarationsSource of
          Left err ->
            assertFailure ("expected block locals compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected first block local emission" ("const message = \"Ada\";" `T.isInfixOf` emitted)
            assertBool "expected second block local emission" ("const alias = message;" `T.isInfixOf` emitted)
            let compiledPath = "dist/block-local-declarations.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(compiledModule.greeting);"
                ]
            assertEqual "expected block locals result" "Ada" runtimeOutput
    , testCase "compile evaluates mutable block assignments" $
        case compileSource "mutable-block" mutableBlockAssignmentSource of
          Left err ->
            assertFailure ("expected mutable block assignment compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected initial mutable binding emission" ("let message = \"Ada\";" `T.isInfixOf` emitted)
            assertBool "expected rebound mutable assignment emission" ("message = \"Grace\";" `T.isInfixOf` emitted)
            let compiledPath = "dist/mutable-block-assignment.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(compiledModule.greeting);"
                ]
            assertEqual "expected mutable block assignment result" "Grace" runtimeOutput
    , testCase "compile evaluates for-loops over list values" $
        case compileSource "for-loop" loopIterationSource of
          Left err ->
            assertFailure ("expected for-loop compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected for-of emission" ("for (const name of names)" `T.isInfixOf` emitted)
            let compiledPath = "dist/for-loop.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(compiledModule.pickLast([\"Ada\", \"Grace\"]));"
                ]
            assertEqual "expected for-loop result" "Grace" runtimeOutput
    , testCase "compile implements early returns in function bodies" $
        case compileSource "return" earlyReturnSource of
          Left err ->
            assertFailure ("expected early return compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected early return helper" ("function $claspEarlyReturn(value)" `T.isInfixOf` emitted)
            assertBool "expected function wrapper catch" ("if (error && error.$claspEarlyReturn === true)" `T.isInfixOf` emitted)
            let compiledPath = "dist/early-return.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(compiledModule.choose(compiledModule.Exit, 'Ada'));"
                , "console.log(compiledModule.choose(compiledModule.Continue, 'Ada'));"
                ]
            assertEqual "expected early return results" "Ada\nfallback" runtimeOutput
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
            assertBool "expected native interop manifest export" ("export const __claspNativeInterop = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected native interop capability id" ("id: \"capability:foreign:mockLeadSummaryModel\"" `T.isInfixOf` emitted)
            assertBool "expected native interop rust crate metadata" ("crateName: \"clasp_mockleadsummarymodel\"" `T.isInfixOf` emitted)
            assertBool "expected native interop bun target metadata" ("bun: Object.freeze({ runtime: \"bun\", loader: \"bun:ffi\", crateType: \"cdylib\", manifestPath: \"native/mockleadsummarymodel/Cargo.toml\" })" `T.isInfixOf` emitted)
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
            assertBool "expected platform bridge export" ("export const __claspPlatformBridges = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected react native bridge descriptor" ("reactNative: Object.freeze({ module: \"runtime/bun/react.mjs\", entry: \"createReactNativeBridge\" })" `T.isInfixOf` emitted)
            assertBool "expected expo bridge descriptor" ("expo: Object.freeze({ module: \"runtime/bun/react.mjs\", entry: \"createExpoBridge\" })" `T.isInfixOf` emitted)
            assertBool "expected generated binding contract export" ("export const __claspBindings = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected generated binding contract version" ("version: 1," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract routes" ("routes: __claspRoutes," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract host bindings" ("hostBindings: __claspHostBindings," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract native interop" ("nativeInterop: __claspNativeInterop," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract schemas" ("schemas: __claspSchemas," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract platform bridges" ("platformBridges: __claspPlatformBridges," `T.isInfixOf` emitted)
            assertBool "expected request preparation helper" ("prepareRequest(value) {" `T.isInfixOf` emitted)
            assertBool "expected response parsing helper" ("async parseResponse(response) {" `T.isInfixOf` emitted)
    , testCase "compile emits executable control-plane manifests and protocol helpers" $
        case compileSource "control-plane" controlPlaneSource of
          Left err ->
            assertFailure ("expected control-plane compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected guides export" ("export const __claspGuides = [" `T.isInfixOf` emitted)
            assertBool "expected hooks export" ("export const __claspHooks = [" `T.isInfixOf` emitted)
            assertBool "expected tools export" ("export const __claspTools = [" `T.isInfixOf` emitted)
            assertBool "expected human-readable control-plane docs export" ("export const __claspControlPlaneDocs = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected control-plane contract export" ("export const __claspControlPlane = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected control-plane contract docs entry" ("docs: __claspControlPlaneDocs" `T.isInfixOf` emitted)
            assertBool "expected agent role approval metadata" ("approvalPolicy: \"on_request\"" `T.isInfixOf` emitted)
            assertBool "expected agent role sandbox metadata" ("sandboxPolicy: \"workspace_write\"" `T.isInfixOf` emitted)
            assertBool "expected policy permission helpers" ("allowsFile(target) { return this.allows(\"file\", target); }" `T.isInfixOf` emitted)
            assertBool "expected policy decision helper" ("decideFile(target, context = null) { return this.decide(\"file\", target, context); }" `T.isInfixOf` emitted)
            assertBool "expected policy trace helper" ("traceFile(target, context = null) { return this.trace(\"file\", target, context); }" `T.isInfixOf` emitted)
            assertBool "expected policy audit helper" ("auditFile(target, context = null) { return this.audit(\"file\", target, context); }" `T.isInfixOf` emitted)
            assertBool "expected hook invoke helper" ("invoke(value) { return this.encodeResponse(this.handler(this.decodeRequest(value))); }" `T.isInfixOf` emitted)
            assertBool "expected tool request preparation" ("prepareCall(value, id = null) {" `T.isInfixOf` emitted)
            assertBool "expected merge gate planning helper" ("plan(value, idSeed = this.name) {" `T.isInfixOf` emitted)
            assertBool "expected generated binding contract control plane entry" ("controlPlane: __claspControlPlane" `T.isInfixOf` emitted)
            assertBool "expected generated binding contract control plane docs entry" ("controlPlaneDocs: __claspControlPlaneDocs" `T.isInfixOf` emitted)
            let compiledPath = "dist/control-plane.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "const guide = compiledModule.__claspGuides[1];"
                , "const agent = compiledModule.__claspAgents[0];"
                , "const hook = compiledModule.__claspHooks[0];"
                , "const tool = compiledModule.__claspTools[0];"
                , "const verifier = compiledModule.__claspVerifiers[0];"
                , "const mergeGate = compiledModule.__claspMergeGates[0];"
                , "const docs = compiledModule.__claspControlPlaneDocs;"
                , "const policy = agent.policy;"
                , "const context = { actor: { id: 'worker-7', tags: ['initial'] }, requestId: 'req-1' };"
                , "const decision = policy.decideFile('/workspace/src/Main.clasp', context);"
                , "const trace = policy.traceFile('/workspace/src/Main.clasp', context);"
                , "const audit = policy.auditFile('/workspace/src/Main.clasp', context);"
                , "context.actor.id = 'mutated';"
                , "context.actor.tags.push('later');"
                , "context.requestId = 'req-2';"
                , "let deniedFile = null;"
                , "try {"
                , "  policy.assertFile('/tmp');"
                , "} catch (error) {"
                , "  deniedFile = error.message;"
                , "}"
                , "console.log(JSON.stringify({"
                , "  guideExtends: guide.extends,"
                , "  guideScope: guide.resolvedEntries.scope,"
                , "  agentPolicy: agent.policy.name,"
                , "  agentApproval: agent.role.approvalPolicy,"
                , "  agentSandbox: agent.role.sandboxPolicy,"
                , "  fileAllowed: policy.allowsFile('/workspace/src/Main.clasp'),"
                , "  fileDenied: policy.allowsFile('/tmp'),"
                , "  networkAllowed: policy.allowsNetwork('api.openai.com'),"
                , "  processAllowed: policy.allowsProcess('rg'),"
                , "  secretAllowed: policy.allowsSecret('OPENAI_API_KEY'),"
                , "  decisionAllowed: decision.allowed,"
                , "  decisionActor: decision.context.actor.id,"
                , "  traceActor: trace.context.actor.id,"
                , "  traceTags: trace.context.actor.tags.join(','),"
                , "  auditActor: audit.context.actor.id,"
                , "  auditRequestId: audit.context.requestId,"
                , "  traceFrozen: Object.isFrozen(trace.context) && Object.isFrozen(trace.context.actor) && Object.isFrozen(trace.context.actor.tags),"
                , "  auditFrozen: Object.isFrozen(audit.context) && Object.isFrozen(audit.context.actor) && Object.isFrozen(audit.context.actor.tags),"
                , "  deniedFile,"
                , "  hookEvent: hook.event,"
                , "  hookAccepted: hook.invoke({ workerId: 'worker-7' }).accepted,"
                , "  toolMethod: tool.prepareCall({ query: 'search' }, 7).method,"
                , "  toolParam: tool.prepareCall({ query: 'search' }, 7).params.query,"
                , "  parsedSummary: tool.parseResult({ summary: 'done' }).summary,"
                , "  verifierMethod: verifier.prepareRun({ query: 'check' }, 8).method,"
                , "  mergeGatePlan: mergeGate.plan({ query: 'gate' }, 'trunk').map((request) => request.id).join(','),"
                , "  docsFormat: docs.format,"
                , "  docsHasGuides: docs.markdown.includes('## Guides'),"
                , "  docsHasPermissions: docs.markdown.includes('File permissions: /workspace'),"
                , "  docsHasApproval: docs.markdown.includes('Approval: on_request'),"
                , "  docsHasSandbox: docs.markdown.includes('Sandbox: workspace_write'),"
                , "  docsHasHookEvent: docs.markdown.includes('worker.start'),"
                , "  bindingControlPlaneVersion: compiledModule.__claspBindings.controlPlane.version,"
                , "  bindingControlPlaneDocsVersion: compiledModule.__claspBindings.controlPlaneDocs.version"
                , "}));"
                ]
            assertEqual
              "expected executable control-plane runtime result"
              "{\"guideExtends\":\"Repo\",\"guideScope\":\"Stay inside the current checkout.\",\"agentPolicy\":\"SupportDisclosure\",\"agentApproval\":\"on_request\",\"agentSandbox\":\"workspace_write\",\"fileAllowed\":true,\"fileDenied\":false,\"networkAllowed\":true,\"processAllowed\":true,\"secretAllowed\":true,\"decisionAllowed\":true,\"decisionActor\":\"worker-7\",\"traceActor\":\"worker-7\",\"traceTags\":\"initial\",\"auditActor\":\"worker-7\",\"auditRequestId\":\"req-1\",\"traceFrozen\":true,\"auditFrozen\":true,\"deniedFile\":\"Policy SupportDisclosure denies file access to /tmp\",\"hookEvent\":\"worker.start\",\"hookAccepted\":true,\"toolMethod\":\"search_repo\",\"toolParam\":\"search\",\"parsedSummary\":\"done\",\"verifierMethod\":\"search_repo\",\"mergeGatePlan\":\"trunk:0\",\"docsFormat\":\"markdown\",\"docsHasGuides\":true,\"docsHasPermissions\":true,\"docsHasApproval\":true,\"docsHasSandbox\":true,\"docsHasHookEvent\":true,\"bindingControlPlaneVersion\":1,\"bindingControlPlaneDocsVersion\":1}"
              runtimeOutput
    , testCase "control-plane example drives one repo-level agent loop" $ do
        result <- compileEntry ("examples" </> "control-plane" </> "Main.clasp")
        case result of
          Left err ->
            assertFailure ("expected control-plane example to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/control-plane/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteDemoPath <- makeAbsolute ("examples" </> "control-plane" </> "demo.mjs")
            (exitCode, stdoutText, stderrText) <-
              readProcessWithExitCode
                "node"
                [ absoluteDemoPath
                , absoluteCompiledPath
                ]
                ""
            case exitCode of
              ExitSuccess ->
                assertEqual
                  "expected repo-level control-plane demo loop result"
                  "{\"agent\":\"builder\",\"approval\":\"on_request\",\"sandbox\":\"workspace_write\",\"hookAccepted\":true,\"fileAllowed\":true,\"taskQueue\":\"Inspect the repo first, then run the merge gate.\",\"verificationGuide\":\"Run bash scripts/verify-all.sh before finishing.\",\"mergeGateRequest\":\"release:0\",\"steps\":[{\"step\":\"inspect\",\"requestId\":\"release:inspect\",\"method\":\"search_repo\",\"allowed\":true,\"summary\":\"src/Clasp/Compiler.hs\\ntest/Main.hs\"},{\"step\":\"verify\",\"requestId\":\"release:0\",\"method\":\"search_repo\",\"allowed\":true,\"summary\":\"verification:ok\"}]}"
                  (T.strip (T.pack stdoutText))
              ExitFailure _ ->
                assertFailure ("control-plane demo script failed:\n" <> stderrText)
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
    , testCase "compileEntry emits package manifests and installs generated package adapters" $
        withProjectFiles "package-import-runtime" packageImportFiles $ \root -> do
          result <- compileEntry (root </> "Main.clasp")
          case result of
            Left err ->
              assertFailure ("expected package-backed project to compile:\n" <> T.unpack (renderDiagnosticBundle err))
            Right emitted -> do
              assertBool "expected npm import emission" ("import { upperCase as $claspPackageBinding_upperCase } from \"local-upper\";" `T.isInfixOf` emitted)
              assertBool "expected typescript import emission" ("import { formatLead as $claspPackageBinding_formatLead } from \"./support/formatLead.mjs\";" `T.isInfixOf` emitted)
              assertBool "expected package imports export" ("export const __claspPackageImports = [" `T.isInfixOf` emitted)
              assertBool "expected ingested npm signature" ("signature: \"export declare function upperCase(value: string): string;\"" `T.isInfixOf` emitted)
              assertBool "expected package host bindings export" ("export function __claspPackageHostBindings()" `T.isInfixOf` emitted)
              let compiledPath = root </> "compiled.mjs"
              TIO.writeFile compiledPath emitted
              absoluteCompiledPath <- makeAbsolute compiledPath
              absoluteRuntimePath <- makeAbsolute "runtime/bun/server.mjs"
              runtimeOutput <- runNodeScript (packageImportRuntimeScript absoluteCompiledPath absoluteRuntimePath)
              assertEqual
                "expected package-backed foreign declarations to run through generated adapters"
                "{\"packageKinds\":[\"npm\",\"typescript\"],\"upper\":\"HELLO ADA\",\"formatted\":\"Acme Labs:7\"}"
                runtimeOutput
    , testCase "checkEntry ingests package declaration signatures" $
        withProjectFiles "package-import-signatures" packageImportFiles $ \root -> do
          result <- checkEntry (root </> "Main.clasp")
          case result of
            Left err ->
              assertFailure ("expected package-backed project to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
            Right modl ->
              case coreModuleForeignDecls modl of
                [npmDecl, tsDecl] -> do
                  assertEqual
                    "npm declaration signature"
                    (Just "export declare function upperCase(value: string): string;")
                    (foreignPackageImportSignature =<< foreignDeclPackageImport npmDecl)
                  assertEqual
                    "typescript declaration signature"
                    (Just "export declare function formatLead(request: { company: string; budget: number }): string;")
                    (foreignPackageImportSignature =<< foreignDeclPackageImport tsDecl)
                other ->
                  assertFailure ("expected two foreign declarations, got " <> show (length other))
    , testCase "checkEntry infers module names from headerless project files" $
        withProjectFiles "import-success-headerless" headerlessImportSuccessFiles $ \root -> do
          result <- checkEntry (root </> "Main.clasp")
          case result of
            Left err ->
              assertFailure ("expected headerless imported project to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
            Right checkedModule ->
              assertEqual "merged module name" (ModuleName "Main") (coreModuleName checkedModule)
    , testCase "checkEntry reports missing imported modules" $
        withProjectFiles "import-missing" missingImportFiles $ \root -> do
          result <- checkEntry (root </> "Main.clasp")
          assertHasCode "E_IMPORT_NOT_FOUND" result
    , testCase "checkEntry reports missing package export declarations" $
        withProjectFiles "package-import-missing-export" packageImportMissingExportFiles $ \root -> do
          result <- checkEntry (root </> "Main.clasp")
          assertHasCode "E_FOREIGN_PACKAGE_EXPORT_NOT_FOUND" result
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
    , testCase "react interop page component works when extracted from the interop object" $
        case compileSource "react-interop" pageSource of
          Left err ->
            assertFailure ("expected page compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/react-interop/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "runtime/bun/react.mjs"
            runtimeOutput <- runNodeScript (reactInteropRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected extracted react page component to render without relying on this binding"
              "{\"headCount\":4,\"headTitle\":\"Inbox\",\"hasDoctype\":true,\"bodyHasSection\":true,\"bodyHasEscapedMarkup\":true,\"elementType\":\"div\",\"rootMarker\":\"\",\"renderedHtmlMatches\":true}"
              runtimeOutput
    , testCase "react native bridge exposes a stable mobile page model" $
        case compileSource "react-native-bridge" pageSource of
          Left err ->
            assertFailure ("expected page compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/react-native-bridge/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "runtime/bun/react.mjs"
            runtimeOutput <- runNodeScript (reactNativeBridgeRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected react native and expo bridge models to stay stable for future mobile reuse"
              "{\"modulePath\":\"runtime/bun/react.mjs\",\"nativeEntry\":\"createReactNativeBridge\",\"expoEntry\":\"createExpoBridge\",\"nativeKind\":\"clasp-native-bridge\",\"nativePlatform\":\"react-native\",\"expoPlatform\":\"expo\",\"pageKind\":\"clasp-native-page\",\"pageTitle\":\"Inbox\",\"bodyKind\":\"styled\",\"styleRef\":\"inbox_shell\",\"childKind\":\"element\",\"childTag\":\"section\",\"textKind\":\"text\",\"textValue\":\"Safe <markup>\",\"linkHref\":null}"
              runtimeOutput
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
    , testCase "worker runtime exposes workflow deadlines, cancellation, retries, and bounded backoff" $
        case compileSource "workflow-worker-runtime" workflowSource of
          Left err ->
            assertFailure ("expected workflow compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/workflow-worker-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "runtime/bun/worker.mjs"
            runtimeOutput <- runNodeScript (workflowRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected workflow lifecycle and retry runtime contract"
              "{\"workflowName\":\"CounterFlow\",\"stateType\":\"Counter\",\"checkpoint\":\"{\\\"count\\\":7}\",\"resumedValue\":7,\"deadlineAt\":1200,\"duplicateSuppressed\":true,\"duplicateResult\":2,\"retriedStatus\":\"delivered\",\"retriedAttempts\":3,\"retriedDelays\":[50,80],\"retriedResult\":3,\"deadlineStatus\":\"deadline_exceeded\",\"deadlineAttempts\":2,\"deadlineFailure\":\"slow-2\",\"cancelledStatus\":\"cancelled\",\"cancelReason\":\"manual-stop\",\"degradedStatus\":\"degraded\",\"degradedReason\":\"provider-outage\",\"degradedSupervisor\":\"SupportSupervisor\",\"degradedFallbackStatus\":\"delivered\",\"degradedFallbackResult\":\"fallback-1\",\"degradedFallbackMode\":\"degraded\",\"handoffStatus\":\"operator_handoff\",\"handoffOperator\":\"case-ops\",\"handoffReason\":\"manual-review\",\"handoffSupervisor\":\"SupportSupervisor\",\"replayedCount\":12,\"replayedDeliveries\":2,\"replayedIds\":[\"m1\",\"m2\"]}"
              runtimeOutput
    , testCase "server runtime resolves target-aware native interop build plans" $
        case compileSource "service-native-interop-runtime" serviceSource of
          Left err ->
            assertFailure ("expected service compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/service-native-interop-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "runtime/bun/server.mjs"
            runtimeOutput <- runNodeScript (nativeInteropRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected native interop contract and build plan"
              "{\"abi\":\"clasp-native-v1\",\"supportedTargets\":[\"bun\",\"worker\",\"react-native\",\"expo\"],\"bindingName\":\"mockLeadSummaryModel\",\"capabilityId\":\"capability:foreign:mockLeadSummaryModel\",\"crateName\":\"lead_summary_bridge\",\"loader\":\"bun:ffi\",\"crateType\":\"cdylib\",\"manifestPath\":\"native/lead-summary/Cargo.toml\",\"artifactFileName\":\"liblead_summary_bridge.so\",\"cargoCommand\":[\"cargo\",\"build\",\"--manifest-path\",\"native/lead-summary/Cargo.toml\",\"--release\",\"--target\",\"x86_64-unknown-linux-gnu\"],\"capabilities\":[\"capability:foreign:mockLeadSummaryModel\",\"capability:ml:lead-summary\"]}"
              runtimeOutput
    , testCase "compile emits Python worker and service interop contracts" $
        case compileSource "python-interop" pythonInteropSource of
          Left err ->
            assertFailure ("expected python interop compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected python interop export" ("export const __claspPythonInterop = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected python runtime descriptor" ("runtime: Object.freeze({ module: \"runtime/bun/python.mjs\", entry: \"createPythonInteropRuntime\" })" `T.isInfixOf` emitted)
            assertBool "expected worker boundary descriptor" ("kind: \"worker\"" `T.isInfixOf` emitted)
            assertBool "expected service boundary descriptor" ("kind: \"service\"" `T.isInfixOf` emitted)
            assertBool "expected python binding contract entry" ("python: __claspPythonInterop," `T.isInfixOf` emitted)
    , testCase "python interop runtime manages typed worker and service boundaries" $
        withProjectFiles "python-interop-runtime"
          [ ("compiled-source.clasp", pythonInteropSource)
          , ("clasp_worker_bridge.py", pythonWorkerModuleSource)
          , ("clasp_service_pkg/__main__.py", pythonServicePackageSource)
          ] $ \root -> do
            result <- compileEntry (root </> "compiled-source.clasp")
            case result of
              Left err ->
                assertFailure ("expected python interop project to compile:\n" <> T.unpack (renderDiagnosticBundle err))
              Right emitted -> do
                let compiledPath = root </> "compiled.mjs"
                TIO.writeFile compiledPath emitted
                absoluteCompiledPath <- makeAbsolute compiledPath
                absoluteRuntimePath <- makeAbsolute "runtime/bun/python.mjs"
                absoluteRoot <- makeAbsolute root
                runtimeOutput <- runNodeScript (pythonInteropRuntimeScript absoluteCompiledPath absoluteRuntimePath absoluteRoot)
                assertEqual
                  "expected python worker/service lifecycle contract"
                  "{\"runtimeModule\":\"runtime/bun/python.mjs\",\"workerCount\":1,\"serviceCount\":1,\"workerRunning\":true,\"workerAccepted\":true,\"workerLabel\":\"py:worker-7\",\"workerStopped\":false,\"workerRestarted\":true,\"serviceSummary\":\"py:Acme:42\",\"serviceAccepted\":true,\"serviceStopped\":false,\"invalid\":\"budget must be an integer\"}"
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
    , testCase "lead app mobile demo reuses compiled route logic through the native bridge" $ do
        result <- compileEntry ("examples" </> "lead-app" </> "Main.clasp")
        case result of
          Left err ->
            assertFailure ("expected lead inbox app to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/lead-app/compiled-mobile.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteDemoPath <- makeAbsolute ("examples" </> "lead-app" </> "mobile-demo.mjs")
            runtimeOutput <- runNodeScript (leadAppMobileDemoScript absoluteCompiledPath absoluteDemoPath)
            assertEqual
              "expected mobile demo to project shared lead flows into a stable native model"
              "{\"platform\":\"react-native\",\"landingTitle\":\"Lead inbox\",\"landingFormAction\":\"/leads\",\"landingFieldNames\":[\"company\",\"contact\",\"budget\",\"segment\"],\"createdTexts\":[\"SynthSpeak Mobile\",\"Taylor Rivera\",\"Priority: medium\",\"Segment: growth\",\"SynthSpeak Mobile led by Taylor Rivera fits the medium priority pipeline.\",\"Review status: new\",\"Add an internal note before handing this lead off.\",\"Review note\",\"Back to inbox\"],\"reviewedTexts\":[\"SynthSpeak Mobile\",\"Taylor Rivera\",\"Priority: medium\",\"Segment: growth\",\"SynthSpeak Mobile led by Taylor Rivera fits the medium priority pipeline.\",\"Review status: reviewed\",\"Ready for field pilot\",\"Review note\",\"Back to inbox\"]}"
              runtimeOutput
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

packageImportRuntimeScript :: FilePath -> FilePath -> Text
packageImportRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { bindingContractFor, installCompiledModule } from " <> show ("file://" <> runtimePath) <> ";"
    , "const contract = bindingContractFor(compiledModule);"
    , "installCompiledModule(compiledModule);"
    , "console.log(JSON.stringify({"
    , "  packageKinds: contract.packageImports.map((entry) => entry.kind).sort(),"
    , "  upper: compiledModule.shout('hello ada'),"
    , "  formatted: compiledModule.describe({ company: 'Acme Labs', budget: 7 })"
    , "}));"
    ]

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
    (["run", "-v0", "claspc", "--"] <> args)
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

normalizePolicyPermissions :: [PolicyPermissionDecl] -> [PolicyPermissionDecl]
normalizePolicyPermissions =
  fmap (\permissionDecl -> permissionDecl {policyPermissionDeclSpan = dummySpan})

normalizeForeignPackageImport :: ForeignPackageImport -> ForeignPackageImport
normalizeForeignPackageImport packageImport =
  packageImport
    { foreignPackageImportKindSpan = dummySpan
    , foreignPackageImportSpecifierSpan = dummySpan
    , foreignPackageImportDeclarationSpan = dummySpan
    }

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

parseFailureSource :: Text
parseFailureSource =
  T.unlines
    [ "module Main"
    , ""
    , "main ="
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

packageForeignSource :: Text
packageForeignSource =
  T.unlines
    [ "module Main"
    , ""
    , "record LeadRequest = {"
    , "  company : Str,"
    , "  budget : Int"
    , "}"
    , ""
    , "foreign upperCase : Str -> Str = \"upperCase\" from npm \"local-upper\" declaration \"./node_modules/local-upper/index.d.ts\""
    , "foreign formatLead : LeadRequest -> Str = \"formatLead\" from typescript \"./support/formatLead.mjs\" declaration \"./support/formatLead.d.ts\""
    , ""
    , "main = \"ok\""
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

hookSource :: Text
hookSource =
  T.unlines
    [ "module Main"
    , ""
    , "record WorkerBoot = { workerId : Str }"
    , "record HookAck = { accepted : Bool }"
    , ""
    , "bootstrapWorker : WorkerBoot -> HookAck"
    , "bootstrapWorker req = HookAck { accepted = true }"
    , ""
    , "hook workerStart = \"worker.start\" WorkerBoot -> HookAck bootstrapWorker"
    , ""
    , "main = \"ok\""
    ]

workflowSource :: Text
workflowSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Counter = { count : Int }"
    , ""
    , "workflow CounterFlow = { state : Counter }"
    , ""
    , "main = \"ok\""
    ]

agentSource :: Text
agentSource =
  T.unlines
    [ "module Main"
    , ""
    , "guide Repo = {"
    , "  scope: \"Stay inside the current checkout.\""
    , "}"
    , ""
    , "guide Worker extends Repo = {"
    , "  verification: \"Run bash scripts/verify-all.sh before finishing.\""
    , "}"
    , ""
    , "policy SupportDisclosure = public"
    , ""
    , "role WorkerRole = guide: Worker, policy: SupportDisclosure, approval: on_request, sandbox: workspace_write"
    , ""
    , "agent builder = WorkerRole"
    , ""
    , "main = \"ok\""
    ]

agentSandboxOnlySource :: Text
agentSandboxOnlySource =
  T.unlines
    [ "module Main"
    , ""
    , "guide Worker = {"
    , "  verification: \"Run bash scripts/verify-all.sh before finishing.\""
    , "}"
    , ""
    , "policy SupportDisclosure = public"
    , ""
    , "role WorkerRole = guide: Worker, policy: SupportDisclosure, sandbox: read_only"
    , ""
    , "agent builder = WorkerRole"
    , ""
    , "main = \"ok\""
    ]

agentMixedOrderingSource :: Text
agentMixedOrderingSource =
  T.unlines
    [ "module Main"
    , ""
    , "guide Worker = {"
    , "  verification: \"Run bash scripts/verify-all.sh before finishing.\""
    , "}"
    , ""
    , "policy SupportDisclosure = public"
    , ""
    , "role WorkerRole = guide: Worker, policy: SupportDisclosure, sandbox: workspace_write, approval: on_request"
    , ""
    , "agent builder = WorkerRole"
    , ""
    , "main = \"ok\""
    ]

toolSource :: Text
toolSource =
  T.unlines
    [ "module Main"
    , ""
    , "record SearchRequest = { query : Str }"
    , "record SearchResponse = { summary : Str }"
    , ""
    , "policy SupportDisclosure = public"
    , ""
    , "toolserver RepoTools = \"mcp\" \"stdio://repo-tools\" with SupportDisclosure"
    , ""
    , "tool searchRepo = RepoTools \"search_repo\" SearchRequest -> SearchResponse"
    , ""
    , "main = \"ok\""
    ]

verifierSource :: Text
verifierSource =
  T.unlines
    [ "module Main"
    , ""
    , "record SearchRequest = { query : Str }"
    , "record SearchResponse = { summary : Str }"
    , ""
    , "policy SupportDisclosure = public"
    , ""
    , "toolserver RepoTools = \"mcp\" \"stdio://repo-tools\" with SupportDisclosure"
    , ""
    , "tool searchRepo = RepoTools \"search_repo\" SearchRequest -> SearchResponse"
    , ""
    , "verifier repoChecks = searchRepo"
    , "mergegate trunk = repoChecks"
    , ""
    , "main = \"ok\""
    ]

formatterCanonicalizationSource :: Text
formatterCanonicalizationSource =
  T.unlines
    [ "import Shared.User"
    , ""
    , "main=let message = \"Ada\" in message"
    , ""
    , "record User={name:Str, aliases:[Str]}"
    , "type Status=Busy Str|Idle"
    ]

formatterCanonicalizationExpected :: Text
formatterCanonicalizationExpected =
  T.intercalate
    "\n"
    [ "module Main"
    , ""
    , "import Shared.User"
    , ""
    , "type Status = Busy Str | Idle"
    , ""
    , "record User = { name: Str, aliases: [Str] }"
    , ""
    , "main = let message = \"Ada\" in message"
    ]

formatterRoundTripSource :: Text
formatterRoundTripSource =
  T.unlines
    [ "import Shared.User"
    , ""
    , "record Worker={name:Str classified pii, aliases:[Str]}"
    , "record LeadRequest={company:Str, budget:Int}"
    , "record LeadSummary={summary:Str}"
    , "type Status=Idle|Busy Str"
    , "guide Repo extends Base={verification:\"Run bash scripts/verify-all.sh\"}"
    , "hook workerStart=\"worker.start\" WorkerBoot -> HookAck bootstrapWorker"
    , "role WorkerRole=guide: Repo, policy: SupportDisclosure"
    , "agent builder=WorkerRole"
    , "policy SupportDisclosure=public, pii permits{file \"/workspace\", network \"api.openai.com\"}"
    , "toolserver RepoTools=\"mcp\" \"stdio://repo-tools\" with SupportDisclosure"
    , "tool searchRepo=RepoTools \"search_repo\" SearchRequest -> SearchResponse"
    , "verifier repoChecks=searchRepo"
    , "mergegate trunk=repoChecks"
    , "projection WorkerView=Worker with SupportDisclosure{name}"
    , "foreign mockLeadSummaryModel : LeadRequest -> Str = \"mockLeadSummaryModel\""
    , "route summarizeLeadRoute = POST \"/lead/summary\" LeadRequest -> LeadSummary summarizeLead"
    , ""
    , "summarizeLead : LeadRequest -> LeadSummary"
    , "summarizeLead lead={"
    , " let mut status=Busy lead.company;"
    , " for alias in [\"Ada\",\"Grace\"] {"
    , "  status=Busy alias;"
    , "  status"
    , " };"
    , " match status {"
    , "  Busy note -> return note,"
    , "  Idle -> decode LeadSummary (mockLeadSummaryModel (LeadRequest {company=lead.company, budget=1}))"
    , " }"
    , "}"
    ]

controlPlaneSource :: Text
controlPlaneSource =
  T.unlines
    [ "module Main"
    , ""
    , "record WorkerBoot = { workerId : Str }"
    , "record HookAck = { accepted : Bool }"
    , "record SearchRequest = { query : Str }"
    , "record SearchResponse = { summary : Str }"
    , ""
    , "bootstrapWorker : WorkerBoot -> HookAck"
    , "bootstrapWorker req = HookAck { accepted = true }"
    , ""
    , "guide Repo = {"
    , "  scope: \"Stay inside the current checkout.\""
    , "}"
    , ""
    , "guide Worker extends Repo = {"
    , "  verification: \"Run bash scripts/verify-all.sh before finishing.\""
    , "}"
    , ""
    , "policy SupportDisclosure = public permits {"
    , "  file \"/workspace\","
    , "  network \"api.openai.com\","
    , "  process \"rg\","
    , "  secret \"OPENAI_API_KEY\""
    , "}"
    , ""
    , "role WorkerRole = guide: Worker, policy: SupportDisclosure, approval: on_request, sandbox: workspace_write"
    , ""
    , "agent builder = WorkerRole"
    , ""
    , "hook workerStart = \"worker.start\" WorkerBoot -> HookAck bootstrapWorker"
    , ""
    , "toolserver RepoTools = \"mcp\" \"stdio://repo-tools\" with SupportDisclosure"
    , ""
    , "tool searchRepo = RepoTools \"search_repo\" SearchRequest -> SearchResponse"
    , ""
    , "verifier repoChecks = searchRepo"
    , "mergegate trunk = repoChecks"
    , ""
    , "main = \"ok\""
    ]

pythonInteropSource :: Text
pythonInteropSource =
  T.unlines
    [ "module Main"
    , ""
    , "record WorkerBoot = { workerId : Str }"
    , "record HookAck = { accepted : Bool, workerLabel : Str }"
    , "record LeadRequest = { company : Str, budget : Int }"
    , "record LeadSummary = { summary : Str, accepted : Bool }"
    , ""
    , "bootstrapWorker : WorkerBoot -> HookAck"
    , "bootstrapWorker req = HookAck { accepted = true, workerLabel = req.workerId }"
    , ""
    , "summarizeLead : LeadRequest -> LeadSummary"
    , "summarizeLead req = LeadSummary { summary = req.company, accepted = req.budget >= 40 }"
    , ""
    , "hook workerStart = \"worker.start\" WorkerBoot -> HookAck bootstrapWorker"
    , "route summarizeRoute = POST \"/lead/summary\" LeadRequest -> LeadSummary summarizeLead"
    , ""
    , "main = \"ok\""
    ]

pythonWorkerModuleSource :: Text
pythonWorkerModuleSource =
  T.unlines
    [ "import json"
    , "import sys"
    , ""
    , "for raw in sys.stdin:"
    , "    message = json.loads(raw)"
    , "    request = message[\"request\"]"
    , "    response = {"
    , "        \"accepted\": True,"
    , "        \"workerLabel\": f\"py:{request['workerId']}\""
    , "    }"
    , "    sys.stdout.write(json.dumps({\"response\": response}) + \"\\n\")"
    , "    sys.stdout.flush()"
    ]

pythonServicePackageSource :: Text
pythonServicePackageSource =
  T.unlines
    [ "import json"
    , "import sys"
    , ""
    , "for raw in sys.stdin:"
    , "    message = json.loads(raw)"
    , "    request = message[\"request\"]"
    , "    response = {"
    , "        \"summary\": f\"py:{request['company']}:{request['budget']}\","
    , "        \"accepted\": request[\"budget\"] >= 40"
    , "    }"
    , "    sys.stdout.write(json.dumps({\"response\": response}) + \"\\n\")"
    , "    sys.stdout.flush()"
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

badHookHandlerSource :: Text
badHookHandlerSource =
  T.unlines
    [ "module Main"
    , ""
    , "record WorkerBoot = { workerId : Str }"
    , "record HookAck = { accepted : Bool }"
    , "record WrongAck = { note : Str }"
    , ""
    , "bootstrapWorker : WorkerBoot -> WrongAck"
    , "bootstrapWorker req = WrongAck { note = req.workerId }"
    , ""
    , "hook workerStart = \"worker.start\" WorkerBoot -> HookAck bootstrapWorker"
    , ""
    , "main = \"ok\""
    ]

badWorkflowStateSource :: Text
badWorkflowStateSource =
  T.unlines
    [ "module Main"
    , ""
    , "type Counter = CounterValue"
    , ""
    , "workflow CounterFlow = { state : Counter }"
    , ""
    , "main = \"ok\""
    ]

unknownAgentRoleSource :: Text
unknownAgentRoleSource =
  T.unlines
    [ "module Main"
    , ""
    , "guide Repo = {"
    , "  scope: \"Stay inside the current checkout.\""
    , "}"
    , ""
    , "policy SupportDisclosure = public"
    , ""
    , "agent builder = WorkerRole"
    , ""
    , "main = \"ok\""
    ]

policyPermissionSource :: Text
policyPermissionSource =
  T.unlines
    [ "module Main"
    , ""
    , "policy SupportDisclosure = public permits {"
    , "  file \"/workspace\","
    , "  network \"api.openai.com\","
    , "  process \"rg\","
    , "  secret \"OPENAI_API_KEY\""
    , "}"
    , ""
    , "main = \"ok\""
    ]

unknownToolServerPolicySource :: Text
unknownToolServerPolicySource =
  T.unlines
    [ "module Main"
    , ""
    , "record SearchRequest = { query : Str }"
    , "record SearchResponse = { summary : Str }"
    , ""
    , "toolserver RepoTools = \"mcp\" \"stdio://repo-tools\" with MissingPolicy"
    , ""
    , "tool searchRepo = RepoTools \"search_repo\" SearchRequest -> SearchResponse"
    , ""
    , "main = \"ok\""
    ]

duplicatePolicyPermissionSource :: Text
duplicatePolicyPermissionSource =
  T.unlines
    [ "module Main"
    , ""
    , "policy SupportDisclosure = public permits {"
    , "  file \"/workspace\","
    , "  file \"/workspace\""
    , "}"
    , ""
    , "main = \"ok\""
    ]

unknownToolServerSource :: Text
unknownToolServerSource =
  T.unlines
    [ "module Main"
    , ""
    , "record SearchRequest = { query : Str }"
    , "record SearchResponse = { summary : Str }"
    , ""
    , "policy SupportDisclosure = public"
    , ""
    , "tool searchRepo = RepoTools \"search_repo\" SearchRequest -> SearchResponse"
    , ""
    , "main = \"ok\""
    ]

unknownVerifierToolSource :: Text
unknownVerifierToolSource =
  T.unlines
    [ "module Main"
    , ""
    , "record SearchRequest = { query : Str }"
    , "record SearchResponse = { summary : Str }"
    , ""
    , "policy SupportDisclosure = public"
    , ""
    , "toolserver RepoTools = \"mcp\" \"stdio://repo-tools\" with SupportDisclosure"
    , ""
    , "verifier repoChecks = searchRepo"
    , ""
    , "main = \"ok\""
    ]

unknownMergeGateVerifierSource :: Text
unknownMergeGateVerifierSource =
  T.unlines
    [ "module Main"
    , ""
    , "record SearchRequest = { query : Str }"
    , "record SearchResponse = { summary : Str }"
    , ""
    , "policy SupportDisclosure = public"
    , ""
    , "toolserver RepoTools = \"mcp\" \"stdio://repo-tools\" with SupportDisclosure"
    , ""
    , "tool searchRepo = RepoTools \"search_repo\" SearchRequest -> SearchResponse"
    , ""
    , "mergegate trunk = repoChecks"
    , ""
    , "main = \"ok\""
    ]

badToolSchemaSource :: Text
badToolSchemaSource =
  T.unlines
    [ "module Main"
    , ""
    , "type SearchRequest = Pending"
    , "record SearchResponse = { summary : Str }"
    , ""
    , "policy SupportDisclosure = public"
    , ""
    , "toolserver RepoTools = \"mcp\" \"stdio://repo-tools\" with SupportDisclosure"
    , ""
    , "tool searchRepo = RepoTools \"search_repo\" SearchRequest -> SearchResponse"
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
    , "policy SupportDisclosure = public, pii permits {"
    , "  file \"/workspace\","
    , "  network \"api.openai.com\","
    , "  process \"rg\","
    , "  secret \"OPENAI_API_KEY\""
    , "}"
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

blockExpressionSource :: Text
blockExpressionSource =
  T.unlines
    [ "module Main"
    , ""
    , "greeting : Str"
    , "greeting = { let message = \"Ada\" in message }"
    ]

blockLocalDeclarationsSource :: Text
blockLocalDeclarationsSource =
  T.unlines
    [ "module Main"
    , ""
    , "greeting : Str"
    , "greeting = {"
    , "  let message = \"Ada\";"
    , "  let alias = message;"
    , "  alias"
    , "}"
    ]

mutableBlockAssignmentSource :: Text
mutableBlockAssignmentSource =
  T.unlines
    [ "module Main"
    , ""
    , "greeting : Str"
    , "greeting = {"
    , "  let mut message = \"Ada\";"
    , "  message = \"Grace\";"
    , "  message"
    , "}"
    ]

loopIterationSource :: Text
loopIterationSource =
  T.unlines
    [ "module Main"
    , ""
    , "pickLast : [Str] -> Str"
    , "pickLast names = {"
    , "  let mut current = \"nobody\";"
    , "  for name in names {"
    , "    current = name;"
    , "    current"
    , "  };"
    , "  current"
    , "}"
    ]

earlyReturnSource :: Text
earlyReturnSource =
  T.unlines
    [ "module Main"
    , ""
    , "type Decision = Exit | Continue"
    , ""
    , "choose : Decision -> Str -> Str"
    , "choose decision name = {"
    , "  let alias = name;"
    , "  match decision {"
    , "    Exit -> return alias,"
    , "    Continue -> \"fallback\""
    , "  }"
    , "}"
    ]

immutableBlockAssignmentSource :: Text
immutableBlockAssignmentSource =
  T.unlines
    [ "module Main"
    , ""
    , "greeting : Str"
    , "greeting = {"
    , "  let message = \"Ada\";"
    , "  message = \"Grace\";"
    , "  message"
    , "}"
    ]

invalidEarlyReturnSource :: Text
invalidEarlyReturnSource =
  T.unlines
    [ "module Main"
    , ""
    , "greeting : Str"
    , "greeting = return \"Ada\""
    ]

nonLocalAssignmentSource :: Text
nonLocalAssignmentSource =
  T.unlines
    [ "module Main"
    , ""
    , "message : Str"
    , "message = \"Ada\""
    , ""
    , "greeting : Str"
    , "greeting = {"
    , "  message = \"Grace\";"
    , "  message"
    , "}"
    ]

invalidForIterableSource :: Text
invalidForIterableSource =
  T.unlines
    [ "module Main"
    , ""
    , "greeting : Str"
    , "greeting = {"
    , "  for char in \"Ada\" {"
    , "    char"
    , "  };"
    , "  \"done\""
    , "}"
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

operatorPrecedenceSource :: Text
operatorPrecedenceSource =
  T.unlines
    [ "module Main"
    , ""
    , "main : Bool"
    , "main = 1 < 2 == 3 > 2"
    ]

equalityAssociativitySource :: Text
equalityAssociativitySource =
  T.unlines
    [ "module Main"
    , ""
    , "main : Bool"
    , "main = true == false == true"
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

unconstrainedEqualitySource :: Text
unconstrainedEqualitySource =
  T.unlines
    [ "module Main"
    , ""
    , "same left right = left == right"
    ]

badOperatorCombinationSource :: Text
badOperatorCombinationSource =
  T.unlines
    [ "module Main"
    , ""
    , "bad : Bool"
    , "bad = 1 == 2 < 3"
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

headerlessImportSuccessFiles :: [(FilePath, Text)]
headerlessImportSuccessFiles =
  [ ("Main.clasp", headerlessImportSuccessMainSource)
  , ("Shared/User.clasp", headerlessSharedUserSource)
  ]

packageImportFiles :: [(FilePath, Text)]
packageImportFiles =
  [ ("Main.clasp", packageImportMainSource)
  , ("support/formatLead.mjs", packageImportTsModuleSource)
  , ("support/formatLead.d.ts", packageImportTsDeclarationSource)
  , ("node_modules/local-upper/package.json", packageImportNpmPackageSource)
  , ("node_modules/local-upper/index.mjs", packageImportNpmModuleSource)
  , ("node_modules/local-upper/index.d.ts", packageImportNpmDeclarationSource)
  ]

packageImportMissingExportFiles :: [(FilePath, Text)]
packageImportMissingExportFiles =
  [ ("Main.clasp", packageImportMissingExportMainSource)
  , ("node_modules/local-upper/index.d.ts", packageImportNpmDeclarationSource)
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

headerlessMainSource :: Text
headerlessMainSource =
  T.unlines
    [ "import Shared.User"
    , ""
    , "main : Str"
    , "main = \"ready\""
    ]

headerlessImportSuccessMainSource :: Text
headerlessImportSuccessMainSource =
  T.unlines
    [ "import Shared.User"
    , ""
    , "main : Str"
    , "main = formatUser defaultUser"
    ]

packageImportMainSource :: Text
packageImportMainSource =
  T.unlines
    [ "module Main"
    , ""
    , "record LeadRequest = {"
    , "  company : Str,"
    , "  budget : Int"
    , "}"
    , ""
    , "foreign upperCase : Str -> Str = \"upperCase\" from npm \"local-upper\" declaration \"./node_modules/local-upper/index.d.ts\""
    , "foreign formatLead : LeadRequest -> Str = \"formatLead\" from typescript \"./support/formatLead.mjs\" declaration \"./support/formatLead.d.ts\""
    , ""
    , "shout : Str -> Str"
    , "shout value = upperCase value"
    , ""
    , "describe : LeadRequest -> Str"
    , "describe request = formatLead request"
    , ""
    , "main = \"ready\""
    ]

packageImportMissingExportMainSource :: Text
packageImportMissingExportMainSource =
  T.unlines
    [ "module Main"
    , ""
    , "foreign missing : Str -> Str = \"missing\" from npm \"local-upper\" declaration \"./node_modules/local-upper/index.d.ts\""
    , ""
    , "main = \"ready\""
    ]

packageImportTsModuleSource :: Text
packageImportTsModuleSource =
  T.unlines
    [ "export function formatLead(request) {"
    , "  return `${request.company}:${request.budget}`;"
    , "}"
    ]

packageImportTsDeclarationSource :: Text
packageImportTsDeclarationSource =
  T.unlines
    [ "export declare function formatLead(request: { company: string; budget: number }): string;"
    ]

packageImportNpmPackageSource :: Text
packageImportNpmPackageSource =
  T.unlines
    [ "{"
    , "  \"name\": \"local-upper\","
    , "  \"type\": \"module\","
    , "  \"exports\": \"./index.mjs\""
    , "}"
    ]

packageImportNpmModuleSource :: Text
packageImportNpmModuleSource =
  T.unlines
    [ "export function upperCase(value) {"
    , "  return String(value).toUpperCase();"
    , "}"
    ]

packageImportNpmDeclarationSource :: Text
packageImportNpmDeclarationSource =
  T.unlines
    [ "export declare function upperCase(value: string): string;"
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

headerlessSharedUserSource :: Text
headerlessSharedUserSource =
  T.unlines
    [ "record User = {"
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

leadAppMobileDemoScript :: FilePath -> FilePath -> Text
leadAppMobileDemoScript compiledPath demoPath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { renderLeadMobileDemo } from " <> show ("file://" <> demoPath) <> ";"
    , "console.log(JSON.stringify(await renderLeadMobileDemo(compiledModule)));"
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

reactInteropRuntimeScript :: FilePath -> FilePath -> Text
reactInteropRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createReactInterop } from " <> show ("file://" <> runtimePath) <> ";"
    , "const React = {"
    , "  createElement(type, props, ...children) {"
    , "    return { type, props: props ?? {}, children };"
    , "  }"
    , "};"
    , "const page = compiledModule.home({});"
    , "const interop = createReactInterop(compiledModule, React);"
    , "const ExtractedPage = interop.Page;"
    , "const rendered = interop.renderPage(page);"
    , "const componentElement = ExtractedPage({ value: page });"
    , "console.log(JSON.stringify({"
    , "  headCount: rendered.headElements.length,"
    , "  headTitle: rendered.head.title,"
    , "  hasDoctype: rendered.html.startsWith('<!DOCTYPE html>'),"
    , "  bodyHasSection: rendered.bodyHtml.includes('<section>'),"
    , "  bodyHasEscapedMarkup: rendered.bodyHtml.includes('&lt;markup&gt;'),"
    , "  elementType: componentElement.type,"
    , "  rootMarker: componentElement.props['data-clasp-page-root'],"
    , "  renderedHtmlMatches: componentElement.props.dangerouslySetInnerHTML.__html === rendered.bodyHtml"
    , "}));"
    ]

reactNativeBridgeRuntimeScript :: FilePath -> FilePath -> Text
reactNativeBridgeRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createExpoBridge, createReactNativeBridge } from " <> show ("file://" <> runtimePath) <> ";"
    , "const page = compiledModule.home({});"
    , "const nativeBridge = createReactNativeBridge(compiledModule);"
    , "const expoBridge = createExpoBridge(compiledModule);"
    , "const pageModel = nativeBridge.renderPageModel(page);"
    , "const firstText = pageModel.body.child.child.children[1]?.child ?? null;"
    , "console.log(JSON.stringify({"
    , "  modulePath: compiledModule.__claspBindings.platformBridges.reactNative.module,"
    , "  nativeEntry: compiledModule.__claspBindings.platformBridges.reactNative.entry,"
    , "  expoEntry: compiledModule.__claspBindings.platformBridges.expo.entry,"
    , "  nativeKind: nativeBridge.kind,"
    , "  nativePlatform: nativeBridge.platform,"
    , "  expoPlatform: expoBridge.platform,"
    , "  pageKind: pageModel.kind,"
    , "  pageTitle: pageModel.title,"
    , "  bodyKind: pageModel.body.kind,"
    , "  styleRef: pageModel.body.styleRef,"
    , "  childKind: pageModel.body.child.kind,"
    , "  childTag: pageModel.body.child.tag,"
    , "  textKind: firstText?.kind ?? null,"
    , "  textValue: firstText?.text ?? null,"
    , "  linkHref: pageModel.body.child.child.children.find((child) => child.kind === 'link')?.href ?? null"
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

workflowRuntimeScript :: FilePath -> FilePath -> Text
workflowRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createWorkerRuntime } from " <> show ("file://" <> runtimePath) <> ";"
    , "const runtime = createWorkerRuntime(compiledModule);"
    , "const workflow = runtime.workflow('CounterFlow');"
    , "const checkpoint = workflow.checkpoint({ count: 7 });"
    , "const resumed = workflow.resume(checkpoint);"
    , "const run = workflow.start(checkpoint, {"
    , "  deadlineAt: 1200,"
    , "  retry: { maxAttempts: 3, initialBackoffMs: 50, backoffMultiplier: 2, maxBackoffMs: 80 }"
    , "});"
    , "const deliverOnce = workflow.deliver(run, { id: 'm1', payload: 2 }, (state, payload) => ({"
    , "  state: { count: state.count + payload },"
    , "  result: payload"
    , "}), { now: 1000 });"
    , "const deliverDuplicate = workflow.deliver(deliverOnce.run, { id: 'm1', payload: 99 }, (state, payload) => ({"
    , "  state: { count: state.count + payload },"
    , "  result: payload"
    , "}), { now: 1000 });"
    , "const retried = workflow.deliver(run, { id: 'm2', payload: 4 }, (state, payload, message, meta) => {"
    , "  if (meta.attempt < 3) {"
    , "    throw new Error(`retry-${meta.attempt}`);"
    , "  }"
    , "  return {"
    , "    state: { count: state.count + payload },"
    , "    result: meta.attempt"
    , "  };"
    , "}, { now: 1000 });"
    , "const deadlineExceeded = workflow.deliver(run, { id: 'm3', payload: 1 }, (state, payload, message, meta) => {"
    , "  throw new Error(`slow-${meta.attempt}`);"
    , "}, {"
    , "  now: 1000,"
    , "  retry: { maxAttempts: 4, initialBackoffMs: 150, backoffMultiplier: 2, maxBackoffMs: 200 }"
    , "});"
    , "const cancelled = workflow.cancel(run, 'manual-stop');"
    , "const cancelledDelivery = workflow.deliver(cancelled, { id: 'm4', payload: 1 }, (state, payload) => ({"
    , "  count: state.count + payload"
    , "}), { now: 1000 });"
    , "const degraded = workflow.degrade(run, 'provider-outage', {"
    , "  supervisor: 'SupportSupervisor',"
    , "  updatedAt: 1100"
    , "});"
    , "const degradedDelivery = workflow.deliver(degraded, { id: 'm5', payload: 1 }, (state, payload) => ({"
    , "  state: { count: state.count + payload },"
    , "  result: 'primary'"
    , "}), { now: 1000 });"
    , "const degradedFallback = workflow.deliver(degraded, { id: 'm6', payload: 1 }, (state, payload) => ({"
    , "  state: { count: state.count + payload },"
    , "  result: 'primary'"
    , "}), {"
    , "  now: 1000,"
    , "  degradedHandler: (state, payload, message, meta) => ({"
    , "    state: { count: state.count + 10 },"
    , "    result: `fallback-${payload}`"
    , "  })"
    , "});"
    , "const handedOff = workflow.handoff(run, 'case-ops', 'manual-review', {"
    , "  supervisor: 'SupportSupervisor',"
    , "  updatedAt: 1150"
    , "});"
    , "const handoffDelivery = workflow.deliver(handedOff, { id: 'm7', payload: 1 }, (state, payload) => ({"
    , "  state: { count: state.count + payload },"
    , "  result: payload"
    , "}), { now: 1000 });"
    , "const replayed = workflow.replay(checkpoint, ["
    , "  { id: 'm1', payload: 2 },"
    , "  { id: 'm1', payload: 99 },"
    , "  { id: 'm2', payload: 3 }"
    , "], (state, payload) => ({ count: state.count + payload }));"
    , "console.log(JSON.stringify({"
    , "  workflowName: workflow.name,"
    , "  stateType: workflow.stateType,"
    , "  checkpoint,"
    , "  resumedValue: resumed.count,"
    , "  deadlineAt: run.deadlineAt,"
    , "  duplicateSuppressed: deliverDuplicate.duplicate,"
    , "  duplicateResult: deliverDuplicate.result,"
    , "  retriedStatus: retried.status,"
    , "  retriedAttempts: retried.attempts,"
    , "  retriedDelays: retried.retryDelaysMs,"
    , "  retriedResult: retried.result,"
    , "  deadlineStatus: deadlineExceeded.status,"
    , "  deadlineAttempts: deadlineExceeded.attempts,"
    , "  deadlineFailure: deadlineExceeded.failure?.message ?? null,"
    , "  cancelledStatus: cancelledDelivery.status,"
    , "  cancelReason: cancelled.cancelReason,"
    , "  degradedStatus: degradedDelivery.status,"
    , "  degradedReason: degraded.supervision.reason,"
    , "  degradedSupervisor: degraded.supervision.supervisor,"
    , "  degradedFallbackStatus: degradedFallback.status,"
    , "  degradedFallbackResult: degradedFallback.result,"
    , "  degradedFallbackMode: degradedFallback.supervision.status,"
    , "  handoffStatus: handoffDelivery.status,"
    , "  handoffOperator: handedOff.supervision.operator,"
    , "  handoffReason: handedOff.supervision.reason,"
    , "  handoffSupervisor: handedOff.supervision.supervisor,"
    , "  replayedCount: replayed.state.count,"
    , "  replayedDeliveries: replayed.deliveries.length,"
    , "  replayedIds: replayed.processedIds"
    , "}));"
    ]

nativeInteropRuntimeScript :: FilePath -> FilePath -> Text
nativeInteropRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { nativeInteropContractFor, resolveNativeInteropPlan } from " <> show ("file://" <> runtimePath) <> ";"
    , "const contract = nativeInteropContractFor(compiledModule);"
    , "const plan = resolveNativeInteropPlan(compiledModule, {"
    , "  target: 'bun',"
    , "  targetTriple: 'x86_64-unknown-linux-gnu',"
    , "  bindings: {"
    , "    mockLeadSummaryModel: {"
    , "      crateName: 'lead_summary_bridge',"
    , "      libName: 'lead_summary_bridge',"
    , "      manifestPath: 'native/lead-summary/Cargo.toml',"
    , "      capabilities: ['capability:foreign:mockLeadSummaryModel', 'capability:ml:lead-summary']"
    , "    }"
    , "  }"
    , "});"
    , "const binding = contract.bindings[0];"
    , "const bindingPlan = plan.bindings[0];"
    , "console.log(JSON.stringify({"
    , "  abi: contract.abi,"
    , "  supportedTargets: contract.supportedTargets,"
    , "  bindingName: binding.name,"
    , "  capabilityId: binding.capability.id,"
    , "  crateName: bindingPlan.crateName,"
    , "  loader: bindingPlan.loader,"
    , "  crateType: bindingPlan.crateType,"
    , "  manifestPath: bindingPlan.manifestPath,"
    , "  artifactFileName: bindingPlan.artifactFileName,"
    , "  cargoCommand: bindingPlan.cargo.command,"
    , "  capabilities: bindingPlan.capabilities"
    , "}));"
    ]

pythonInteropRuntimeScript :: FilePath -> FilePath -> FilePath -> Text
pythonInteropRuntimeScript compiledPath runtimePath projectRoot =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createPythonInteropRuntime } from " <> show ("file://" <> runtimePath) <> ";"
    , "const runtime = createPythonInteropRuntime(compiledModule);"
    , "const worker = runtime.worker('workerStart', { cwd: " <> show projectRoot <> ", module: 'clasp_worker_bridge' });"
    , "const service = runtime.service('summarizeRoute', { cwd: " <> show projectRoot <> ", package: 'clasp_service_pkg' });"
    , "const workerStart = await worker.start();"
    , "const workerResult = await worker.invoke({ workerId: 'worker-7' });"
    , "const workerStop = await worker.stop();"
    , "await worker.restart();"
    , "const workerRestart = worker.status();"
    , "await worker.stop();"
    , "await service.start();"
    , "const serviceResult = await service.invoke({ company: 'Acme', budget: 42 });"
    , "let invalid = null;"
    , "try {"
    , "  await service.invoke({ company: 'Acme', budget: 'oops' });"
    , "} catch (error) {"
    , "  invalid = error instanceof Error ? error.message : String(error);"
    , "}"
    , "const serviceStop = await service.stop();"
    , "console.log(JSON.stringify({"
    , "  runtimeModule: runtime.contract.runtime.module,"
    , "  workerCount: runtime.listWorkers().length,"
    , "  serviceCount: runtime.listServices().length,"
    , "  workerRunning: workerStart.running,"
    , "  workerAccepted: workerResult.accepted,"
    , "  workerLabel: workerResult.workerLabel,"
    , "  workerStopped: workerStop.running,"
    , "  workerRestarted: workerRestart.running,"
    , "  serviceSummary: serviceResult.summary,"
    , "  serviceAccepted: serviceResult.accepted,"
    , "  serviceStopped: serviceStop.running,"
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
