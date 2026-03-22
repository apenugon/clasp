{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (finally)
import Control.Monad (when)
import Data.Aeson (Value (..), eitherDecodeStrictText)
import Data.Aeson.Key (fromText)
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Foldable (toList)
import Data.List (find, isInfixOf)
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
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode, readProcessWithExitCode)
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
  ( CompilerImplementation (..)
  , CompilerPreference (..)
  , SemanticEdit (..)
  , airEntry
  , airSource
  , checkEntry
  , checkEntrySummaryWithPreference
  , checkEntryWithPreference
  , checkSource
  , compileEntry
  , compileEntryWithPreference
  , compileSource
  , explainEntry
  , explainEntryWithPreference
  , explainSource
  , formatSource
  , nativeEntry
  , renderNativeEntryWithPreference
  , renderNativeSource
  , nativeSource
  , parseSource
  , renderAirSourceJson
  , renderContextSourceJson
  , renderHostedPrimaryEntrySource
  , semanticEditSource
  )
import Clasp.Core
  ( CoreAgentDecl (..)
  , CoreAgentRoleDecl (..)
  , CoreDecl (..)
  , CoreDomainEventDecl (..)
  , CoreDomainObjectDecl (..)
  , CoreExperimentDecl (..)
  , CoreExpr (..)
  , CoreFeedbackDecl (..)
  , CoreGoalDecl (..)
  , CoreHookDecl (..)
  , CoreMatchBranch (..)
  , CoreMergeGateDecl (..)
  , CoreModule (..)
  , CoreMetricDecl (..)
  , CorePattern (..)
  , CorePatternBinder (..)
  , CoreRecordField (..)
  , CoreRolloutDecl (..)
  , CoreSupervisorDecl (..)
  , CoreToolDecl (..)
  , CoreToolServerDecl (..)
  , CoreVerifierDecl (..)
  , CoreWorkflowDecl (..)
  )
import Clasp.Diagnostic
  ( Diagnostic (..)
  , DiagnosticBundle (..)
  , diagnostic
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
import Clasp.Native
  ( NativeAbi (..)
  , NativeAllocationModel (..)
  , NativeAllocationRegion (..)
  , NativeBinaryCodec (..)
  , NativeBuiltinLayout (..)
  , NativeCompareOp (..)
  , NativeConstructorLayout (..)
  , NativeDecl (..)
  , NativeBoundaryContract (..)
  , NativeExpr (..)
  , NativeField (..)
  , NativeFieldLayout (..)
  , NativeFunction (..)
  , NativeGlobal (..)
  , NativeHookBoundary (..)
  , NativeIntrinsic (..)
  , NativeJsonCodec (..)
  , NativeLayoutStorage (..)
  , NativeLiteral (..)
  , NativeLifetimeInvariant (..)
  , NativeMatchBranch (..)
  , NativeMemoryStrategy (..)
  , NativeModule (..)
  , NativeMutability (..)
  , NativeObjectKind (..)
  , NativeObjectLayout (..)
  , NativeOwnershipRule (..)
  , NativeRecordLayout (..)
  , NativeRouteBoundary (..)
  , NativeRuntime (..)
  , NativeRuntimeBinding (..)
  , NativeRootDiscoveryRule (..)
  , NativeServiceTransport (..)
  , NativeSlotLayout (..)
  , NativeToolBoundary (..)
  , NativeToolServerBoundary (..)
  , NativeVariantLayout (..)
  , NativeWorkflowBoundary (..)
  , renderNativeModuleImageJson
  )
import Clasp.Syntax
  ( AgentDecl (..)
  , AgentRoleApprovalPolicy (..)
  , AgentRoleDecl (..)
  , AgentRoleSandboxPolicy (..)
  , ConstructorDecl (..)
  , Decl (..)
  , DomainEventDecl (..)
  , DomainObjectDecl (..)
  , ExperimentDecl (..)
  , Expr (..)
  , FeedbackDecl (..)
  , FeedbackKind (..)
  , ForeignDecl (..)
  , GoalDecl (..)
  , ForeignPackageImport (..)
  , ForeignPackageImportKind (..)
  , GuideDecl (..)
  , GuideEntryDecl (..)
  , HookDecl (..)
  , HookTriggerDecl (..)
  , ImportDecl (..)
  , MatchBranch (..)
  , MetricDecl (..)
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
  , RolloutDecl (..)
  , RouteBoundaryDecl (..)
  , RouteDecl (..)
  , RouteMethod (..)
  , RoutePathDecl (..)
  , SourceSpan (..)
  , SupervisorChildDecl (..)
  , SupervisorDecl (..)
  , SupervisorRestartStrategy (..)
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
    , nativeTests
    , docsTests
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
    , testCase "parses type parameters on records, ADTs, and function signatures" $
        case parseSource "inline" genericTypeSource of
          Left err ->
            assertFailure ("expected generic type source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            case find ((== "Choice") . typeDeclName) (moduleTypeDecls modl) of
              Just typeDecl -> do
                assertEqual "type params" ["a"] (typeDeclParams typeDecl)
                assertEqual
                  "constructors"
                  [ ConstructorDecl "Some" dummySpan dummySpan [TVar "a"]
                  , ConstructorDecl "None" dummySpan dummySpan []
                  ]
                  (normalizeConstructors (typeDeclConstructors typeDecl))
              Nothing ->
                assertFailure "expected generic Choice declaration"
            case find ((== "Box") . recordDeclName) (moduleRecordDecls modl) of
              Just recordDecl -> do
                assertEqual "record params" ["a"] (recordDeclParams recordDecl)
                case recordDeclFields recordDecl of
                  [RecordFieldDecl {recordFieldDeclType = TVar "a"}] ->
                    pure ()
                  other ->
                    assertFailure ("expected generic Box field, got " <> show other)
              Nothing ->
                assertFailure "expected generic Box declaration"
            case findDecl "identity" (moduleDecls modl) of
              Just decl ->
                assertEqual "identity annotation" (Just (TFunction [TVar "a"] (TVar "a"))) (declAnnotation decl)
              Nothing ->
                assertFailure "expected identity declaration"
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
    , testCase "parses compact module headers with imports" $
        case parseSource "Main.clasp" compactHeaderMainSource of
          Left err ->
            assertFailure ("expected compact header source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            assertEqual "module name" (ModuleName "Main") (moduleName modl)
            assertEqual
              "header imports"
              [ModuleName "Shared.User", ModuleName "Shared.Team"]
              (fmap importDeclModule (moduleImports modl))
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
    , testCase "parses workflow declarations with invariant, precondition, and postcondition handlers" $
        case parseSource "inline" workflowConstraintSource of
          Left err ->
            assertFailure ("expected constrained workflow source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case moduleWorkflowDecls modl of
              [workflowDecl] -> do
                assertEqual "workflow invariant" (Just "nonNegative") (workflowDeclInvariantName workflowDecl)
                assertEqual "workflow precondition" (Just "belowLimit") (workflowDeclPreconditionName workflowDecl)
                assertEqual "workflow postcondition" (Just "withinLimit") (workflowDeclPostconditionName workflowDecl)
              other ->
                assertFailure ("expected one workflow declaration, got " <> show (length other))
    , testCase "parses domain object, domain event, feedback, metric, goal, experiment, and rollout declarations" $
        case parseSource "inline" domainModelSource of
          Left err ->
            assertFailure ("expected domain model source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            case moduleDomainObjectDecls modl of
              [domainObjectDecl] -> do
                assertEqual "domain object name" "Customer" (domainObjectDeclName domainObjectDecl)
                assertEqual "domain object identity" "domain-object:Customer" (domainObjectDeclIdentity domainObjectDecl)
                assertEqual "domain object schema" "CustomerRecord" (domainObjectDeclSchemaName domainObjectDecl)
              other ->
                assertFailure ("expected one domain object declaration, got " <> show (length other))
            case moduleDomainEventDecls modl of
              [domainEventDecl] -> do
                assertEqual "domain event name" "CustomerChurned" (domainEventDeclName domainEventDecl)
                assertEqual "domain event identity" "domain-event:CustomerChurned" (domainEventDeclIdentity domainEventDecl)
                assertEqual "domain event schema" "CustomerChurnEvent" (domainEventDeclSchemaName domainEventDecl)
                assertEqual "domain event object" "Customer" (domainEventDeclObjectName domainEventDecl)
              other ->
                assertFailure ("expected one domain event declaration, got " <> show (length other))
            case moduleFeedbackDecls modl of
              [operationalFeedbackDecl, businessFeedbackDecl] -> do
                assertEqual "operational feedback name" "CustomerEscalation" (feedbackDeclName operationalFeedbackDecl)
                assertEqual "operational feedback identity" "feedback:CustomerEscalation" (feedbackDeclIdentity operationalFeedbackDecl)
                assertEqual "operational feedback kind" FeedbackOperational (feedbackDeclKind operationalFeedbackDecl)
                assertEqual "business feedback kind" FeedbackBusiness (feedbackDeclKind businessFeedbackDecl)
                assertEqual "business feedback schema" "CustomerRetentionFeedback" (feedbackDeclSchemaName businessFeedbackDecl)
                assertEqual "business feedback object" "Customer" (feedbackDeclObjectName businessFeedbackDecl)
              other ->
                assertFailure ("expected two feedback declarations, got " <> show (length other))
            case moduleMetricDecls modl of
              [metricDecl] -> do
                assertEqual "metric name" "CustomerChurnRate" (metricDeclName metricDecl)
                assertEqual "metric identity" "metric:CustomerChurnRate" (metricDeclIdentity metricDecl)
                assertEqual "metric schema" "CustomerMetric" (metricDeclSchemaName metricDecl)
                assertEqual "metric object" "Customer" (metricDeclObjectName metricDecl)
              other ->
                assertFailure ("expected one metric declaration, got " <> show (length other))
            case moduleGoalDecls modl of
              [goalDecl] -> do
                assertEqual "goal name" "RetainCustomers" (goalDeclName goalDecl)
                assertEqual "goal identity" "goal:RetainCustomers" (goalDeclIdentity goalDecl)
                assertEqual "goal metric" "CustomerChurnRate" (goalDeclMetricName goalDecl)
              other ->
                assertFailure ("expected one goal declaration, got " <> show (length other))
            case moduleExperimentDecls modl of
              [experimentDecl] -> do
                assertEqual "experiment name" "RetentionPromptTrial" (experimentDeclName experimentDecl)
                assertEqual "experiment identity" "experiment:RetentionPromptTrial" (experimentDeclIdentity experimentDecl)
                assertEqual "experiment goal" "RetainCustomers" (experimentDeclGoalName experimentDecl)
              other ->
                assertFailure ("expected one experiment declaration, got " <> show (length other))
            case moduleRolloutDecls modl of
              [rolloutDecl] -> do
                assertEqual "rollout name" "RetentionPromptCanary" (rolloutDeclName rolloutDecl)
                assertEqual "rollout identity" "rollout:RetentionPromptCanary" (rolloutDeclIdentity rolloutDecl)
                assertEqual "rollout experiment" "RetentionPromptTrial" (rolloutDeclExperimentName rolloutDecl)
              other ->
                assertFailure ("expected one rollout declaration, got " <> show (length other))
    , testCase "parses supervisor declarations with restart strategies and nested children" $
        case parseSource "inline" supervisorSource of
          Left err ->
            assertFailure ("expected supervisor source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case moduleSupervisorDecls modl of
              [rootSupervisor, childSupervisor] -> do
                assertEqual "root supervisor name" "RootSupervisor" (supervisorDeclName rootSupervisor)
                assertEqual "root supervisor identity" "supervisor:RootSupervisor" (supervisorDeclIdentity rootSupervisor)
                assertEqual "root supervisor restart strategy" SupervisorOneForAll (supervisorDeclRestartStrategy rootSupervisor)
                assertEqual
                  "root supervisor children"
                  [ SupervisorWorkflowChild "CounterFlow" dummySpan
                  , SupervisorSupervisorChild "WorkerSupervisor" dummySpan
                  ]
                  (normalizeSupervisorChildren (supervisorDeclChildren rootSupervisor))
                assertEqual "child supervisor restart strategy" SupervisorRestForOne (supervisorDeclRestartStrategy childSupervisor)
              other ->
                assertFailure ("expected two supervisor declarations, got " <> show (length other))
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
    , testCase "parses explicit unsafe package foreign declarations" $
        case parseSource "inline" packageUnsafeForeignSource of
          Left err ->
            assertFailure ("expected parse success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case moduleForeignDecls modl of
              [foreignDecl] ->
                assertBool "expected unsafe package interop flag" (foreignDeclUnsafeInterop foreignDecl)
              other ->
                assertFailure ("expected one foreign declaration, got " <> show (length other))
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
    , testCase "parses multiline list literals" $
        case parseSource "inline" multilineListLiteralSource of
          Left err ->
            assertFailure ("expected multiline list literal source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "roster" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EList _ [EString _ "Ada", EString _ "Grace"] ->
                    pure ()
                  other ->
                    assertFailure ("expected multiline list literal body, got " <> show other)
              Nothing ->
                assertFailure "expected roster declaration"
    , testCase "parses trailing commas in structured literals and record fields" $
        case parseSource "inline" trailingCommaStructuredSource of
          Left err ->
            assertFailure ("expected trailing-comma source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            case moduleRecordDecls modl of
              [recordDecl] ->
                assertEqual
                  "record field names"
                  ["name", "active"]
                  (fmap recordFieldDeclName (recordDeclFields recordDecl))
              other ->
                assertFailure ("expected one record declaration, got " <> show (length other))
            case findDecl "defaultUsers" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EList _ [ERecord _ "User" [RecordFieldExpr "name" _ (EString _ "Ada"), RecordFieldExpr "active" _ (EBool _ True)]] ->
                    pure ()
                  other ->
                    assertFailure ("expected trailing-comma record list body, got " <> show other)
              Nothing ->
                assertFailure "expected defaultUsers declaration"
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
    , testCase "parses if expressions" $
        case parseSource "inline" ifExpressionSource of
          Left err ->
            assertFailure ("expected if source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "main" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EIf _ (EVar _ "isReady") (EString _ "ready") (EString _ "waiting") ->
                    pure ()
                  other ->
                    assertFailure ("expected if expression body, got " <> show other)
              Nothing ->
                assertFailure "expected main declaration"
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
    , testCase "parses for-loops over string values inside blocks" $
        case parseSource "inline" stringLoopIterationSource of
          Left err ->
            assertFailure ("expected string loop iteration source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl ->
            case findDecl "pickLastChar" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EBlock _ (EMutableLet _ _ "current" (EString _ "") (EFor _ loopBinder "char" (EVar _ "name") (EBlock _ (EAssign _ assignSpan "current" (EVar _ "char") (EVar _ "current"))) (EVar _ "current"))) -> do
                    assertEqual "loop binder line" 6 (positionLine (sourceSpanStart loopBinder))
                    assertEqual "assignment line" 7 (positionLine (sourceSpanStart assignSpan))
                  other ->
                    assertFailure ("expected parsed string for-loop body, got " <> show other)
              Nothing ->
                assertFailure "expected pickLastChar declaration"
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
    , testCase "parses the comparisons example file" $ do
        source <- readExampleSource "comparisons.clasp"
        case parseSource "examples/comparisons.clasp" source of
          Left err ->
            assertFailure ("expected comparisons example source to parse:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            case findDecl "isEarlier" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  ELessThan _ (EVar _ "left") (EVar _ "right") ->
                    pure ()
                  other ->
                    assertFailure ("expected less-than expression in comparisons example, got " <> show other)
              Nothing ->
                assertFailure "expected isEarlier declaration in comparisons example"
            case findDecl "main" (moduleDecls modl) of
              Just decl ->
                case declBody decl of
                  EEqual _ (ECall _ (EVar _ "isEarlier") [EInt _ 3, EInt _ 5]) (ECall _ (EVar _ "isLatest") [EInt _ 7, EInt _ 7]) ->
                    pure ()
                  other ->
                    assertFailure ("expected equality over comparison calls in comparisons example, got " <> show other)
              Nothing ->
                assertFailure "expected main declaration in comparisons example"
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
    , testCase "renders current source forms including role policies and package imports" $
        case formatSource "Main.clasp" formatterCurrentSurfaceSource of
          Left err ->
            assertFailure ("expected formatter success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right formatted ->
            assertEqual "current surface should round-trip canonically" formatterCurrentSurfaceExpected formatted
    , testCase "format CLI rewrites a project file canonically" $
        withProjectFiles "format-cli" [("Main.clasp", formatterCliSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
          (exitCode, stdoutText, stderrText) <- runClaspc ["format", inputPath]
          case exitCode of
            ExitFailure code ->
              assertFailure ("expected format CLI success, got exit code " <> show code <> ":\n" <> stderrText)
            ExitSuccess ->
              assertEqual "formatted CLI output" formatterCliExpected (T.stripEnd (T.pack stdoutText))
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
    , testCase "accepts workflows with typed invariant, precondition, and postcondition handlers" $
        case checkSource "workflow-constraints" workflowConstraintSource of
          Left err ->
            assertFailure ("expected constrained workflow source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case coreModuleWorkflowDecls checked of
              [CoreWorkflowDecl workflowDecl] -> do
                assertEqual "workflow invariant" (Just "nonNegative") (workflowDeclInvariantName workflowDecl)
                assertEqual "workflow precondition" (Just "belowLimit") (workflowDeclPreconditionName workflowDecl)
                assertEqual "workflow postcondition" (Just "withinLimit") (workflowDeclPostconditionName workflowDecl)
              other ->
                assertFailure ("expected one checked workflow declaration, got " <> show (length other))
    , testCase "accepts domain objects, domain events, feedback, metrics, goals, experiments, and rollouts bound to typed declarations" $
        case checkSource "domain" domainModelSource of
          Left err ->
            assertFailure ("expected domain model source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            case coreModuleDomainObjectDecls checked of
              [CoreDomainObjectDecl domainObjectDecl] ->
                assertEqual "domain object schema" "CustomerRecord" (domainObjectDeclSchemaName domainObjectDecl)
              other ->
                assertFailure ("expected one checked domain object declaration, got " <> show (length other))
            case coreModuleDomainEventDecls checked of
              [CoreDomainEventDecl domainEventDecl] ->
                assertEqual "domain event object" "Customer" (domainEventDeclObjectName domainEventDecl)
              other ->
                assertFailure ("expected one checked domain event declaration, got " <> show (length other))
            case coreModuleFeedbackDecls checked of
              [CoreFeedbackDecl operationalFeedbackDecl, CoreFeedbackDecl businessFeedbackDecl] -> do
                assertEqual "operational feedback kind" FeedbackOperational (feedbackDeclKind operationalFeedbackDecl)
                assertEqual "operational feedback object" "Customer" (feedbackDeclObjectName operationalFeedbackDecl)
                assertEqual "business feedback kind" FeedbackBusiness (feedbackDeclKind businessFeedbackDecl)
              other ->
                assertFailure ("expected two checked feedback declarations, got " <> show (length other))
            case coreModuleMetricDecls checked of
              [CoreMetricDecl metricDecl] -> do
                assertEqual "metric schema" "CustomerMetric" (metricDeclSchemaName metricDecl)
                assertEqual "metric object" "Customer" (metricDeclObjectName metricDecl)
              other ->
                assertFailure ("expected one checked metric declaration, got " <> show (length other))
            case coreModuleGoalDecls checked of
              [CoreGoalDecl goalDecl] ->
                assertEqual "goal metric" "CustomerChurnRate" (goalDeclMetricName goalDecl)
              other ->
                assertFailure ("expected one checked goal declaration, got " <> show (length other))
            case coreModuleExperimentDecls checked of
              [CoreExperimentDecl experimentDecl] ->
                assertEqual "experiment goal" "RetainCustomers" (experimentDeclGoalName experimentDecl)
              other ->
                assertFailure ("expected one checked experiment declaration, got " <> show (length other))
            case coreModuleRolloutDecls checked of
              [CoreRolloutDecl rolloutDecl] ->
                assertEqual "rollout experiment" "RetentionPromptTrial" (rolloutDeclExperimentName rolloutDecl)
              other ->
                assertFailure ("expected one checked rollout declaration, got " <> show (length other))
    , testCase "accepts supervisor hierarchies with BEAM-style restart strategies" $
        case checkSource "supervisor" supervisorSource of
          Left err ->
            assertFailure ("expected supervisor source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case coreModuleSupervisorDecls checked of
              [CoreSupervisorDecl rootSupervisor, CoreSupervisorDecl childSupervisor] -> do
                assertEqual "root restart strategy" SupervisorOneForAll (supervisorDeclRestartStrategy rootSupervisor)
                assertEqual "child restart strategy" SupervisorRestForOne (supervisorDeclRestartStrategy childSupervisor)
              other ->
                assertFailure ("expected two checked supervisor declarations, got " <> show (length other))
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
          Right checked -> do
            case find ((== "roster") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CList _ (TList TStr) [CString _ "Ada", CString _ "Grace"] ->
                    assertEqual "roster type" (TList TStr) (coreDeclType decl)
                  other ->
                    assertFailure ("unexpected checked roster declaration: " <> show other)
              Nothing ->
                assertFailure "expected roster declaration"
            case find ((== "emptyRoster") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CList _ (TList TStr) [] ->
                    assertEqual "empty roster type" (TList TStr) (coreDeclType decl)
                  other ->
                    assertFailure ("unexpected checked emptyRoster declaration: " <> show other)
              Nothing ->
                assertFailure "expected emptyRoster declaration"
    , testCase "uses surrounding list annotations to typecheck nested empty list literals" $
        case checkSource "nested-lists" nestedEmptyListSource of
          Left err ->
            assertFailure ("expected nested empty list source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case find ((== "matrix") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CList _ (TList (TList TInt)) [CList _ (TList TInt) [], CList _ (TList TInt) [CInt _ 1, CInt _ 2]] ->
                    assertEqual "matrix type" (TList (TList TInt)) (coreDeclType decl)
                  other ->
                    assertFailure ("unexpected checked matrix declaration: " <> show other)
              Nothing ->
                assertFailure "expected matrix declaration"
    , testCase "accepts multiline list literals" $
        case checkSource "multiline-lists" multilineListLiteralSource of
          Left err ->
            assertFailure ("expected multiline list literal source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            case find ((== "roster") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CList _ (TList TStr) [CString _ "Ada", CString _ "Grace"] ->
                    assertEqual "multiline roster type" (TList TStr) (coreDeclType decl)
                  other ->
                    assertFailure ("unexpected checked multiline roster declaration: " <> show other)
              Nothing ->
                assertFailure "expected multiline roster declaration"
            case find ((== "emptyRoster") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CList _ (TList TStr) [] ->
                    assertEqual "multiline empty roster type" (TList TStr) (coreDeclType decl)
                  other ->
                    assertFailure ("unexpected checked multiline emptyRoster declaration: " <> show other)
              Nothing ->
                assertFailure "expected multiline emptyRoster declaration"
    , testCase "accepts trailing commas in structured literals and record fields" $
        case checkSource "trailing-commas" trailingCommaStructuredSource of
          Left err ->
            assertFailure ("expected trailing-comma source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            case find ((== "defaultUsers") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CList _ (TList (TNamed "User")) [CRecord _ (TNamed "User") "User" [CoreRecordField "name" (CString _ "Ada"), CoreRecordField "active" (CBool _ True)]] ->
                    assertEqual "defaultUsers type" (TList (TNamed "User")) (coreDeclType decl)
                  other ->
                    assertFailure ("unexpected checked trailing-comma declaration: " <> show other)
              Nothing ->
                assertFailure "expected defaultUsers declaration"
    , testCase "typechecks general list append expressions" $
        case checkSource "list-append" listAppendSource of
          Left err ->
            assertFailure ("expected list append source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case find ((== "main") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CListAppend _ (TList TStr) (CVar _ (TList TStr) "leading") (CVar _ (TList TStr) "trailing") ->
                    assertEqual "list append result type" (TList TStr) (coreDeclType decl)
                  other ->
                    assertFailure ("unexpected checked list append declaration: " <> show other)
              Nothing ->
                assertFailure "expected main declaration"
    , testCase "typechecks if expressions" $
        case checkSource "if-expression" ifExpressionSource of
          Left err ->
            assertFailure ("expected if source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case find ((== "main") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CIf _ TStr (CVar _ TBool "isReady") (CString _ "ready") (CString _ "waiting") ->
                    assertEqual "if result type" TStr (coreDeclType decl)
                  other ->
                    assertFailure ("unexpected checked if declaration: " <> show other)
              Nothing ->
                assertFailure "expected main declaration"
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
    , testCase "typechecks for-loops over string values with string binders" $
        case checkSource "string-for-loop" stringLoopIterationSource of
          Left err ->
            assertFailure ("expected string loop iteration source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case find ((== "pickLastChar") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CMutableLet _ outerType "current" (CString _ "") (CFor _ loopType "char" (CVar _ TStr "name") (CAssign _ innerType "current" (CVar _ TStr "char") (CVar _ bodyType "current")) (CVar _ resultType "current")) -> do
                    assertEqual "outer let result type" TStr outerType
                    assertEqual "loop result type" TStr loopType
                    assertEqual "assignment result type" TStr innerType
                    assertEqual "inner body variable type" TStr bodyType
                    assertEqual "final variable type" TStr resultType
                  other ->
                    assertFailure ("expected checked string for-loop expression, got " <> show other)
              Nothing ->
                assertFailure "expected pickLastChar declaration"
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
    , testCase "typechecks early returns from inside for-loops against the enclosing function result" $
        case checkSource "loop-return" loopEarlyReturnSource of
          Left err ->
            assertFailure ("expected loop early return source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case find ((== "pickUntilStop") . coreDeclName) (coreModuleDecls checked) of
              Just decl -> do
                assertEqual "pickUntilStop type" (TFunction [TList (TNamed "Decision")] TStr) (coreDeclType decl)
                case coreDeclBody decl of
                  CMutableLet _ TStr "winner" (CString _ "none") (CFor _ TStr "decision" (CVar _ (TList (TNamed "Decision")) "decisions") (CMatch _ TStr (CVar _ (TNamed "Decision") "decision") [CoreMatchBranch _ (CConstructorPattern _ "Stop" []) (CReturn _ TStr (CString _ "stopped")), CoreMatchBranch _ (CConstructorPattern _ "Keep" [CorePatternBinder "name" _ TStr]) (CAssign _ TStr "winner" (CVar _ TStr "name") (CVar _ TStr "winner"))]) (CVar _ TStr "winner")) ->
                    pure ()
                  other ->
                    assertFailure ("expected checked loop early return expression, got " <> show other)
              Nothing ->
                assertFailure "expected pickUntilStop declaration"
    , testCase "typechecks compiler-known Result constructors and matches" $
        case checkSource "result" builtinResultSource of
          Left err ->
            assertFailure ("expected builtin Result source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            case find ((== "Result") . typeDeclName) (coreModuleTypeDecls checked) of
              Just typeDecl ->
                assertEqual
                  "builtin Result constructors"
                  [ ConstructorDecl "Ok" dummySpan dummySpan [TStr]
                  , ConstructorDecl "Err" dummySpan dummySpan [TStr]
                  ]
                  (normalizeConstructors (typeDeclConstructors typeDecl))
              Nothing ->
                assertFailure "expected compiler-known Result type declaration"
            case find ((== "unwrap") . coreDeclName) (coreModuleDecls checked) of
              Just decl -> do
                assertEqual "unwrap type" (TFunction [TNamed "Result"] TStr) (coreDeclType decl)
                case coreDeclBody decl of
                  CMatch _ TStr (CVar _ (TNamed "Result") "result") [CoreMatchBranch _ (CConstructorPattern _ "Ok" [CorePatternBinder "value" _ TStr]) (CVar _ TStr "value"), CoreMatchBranch _ (CConstructorPattern _ "Err" [CorePatternBinder "message" _ TStr]) (CVar _ TStr "message")] ->
                    pure ()
                  other ->
                    assertFailure ("expected checked Result match expression, got " <> show other)
              Nothing ->
                assertFailure "expected unwrap declaration"
    , testCase "typechecks compiler-known Option constructors and matches" $
        case checkSource "option" builtinOptionSource of
          Left err ->
            assertFailure ("expected builtin Option source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            case find ((== "Option") . typeDeclName) (coreModuleTypeDecls checked) of
              Just typeDecl ->
                assertEqual
                  "builtin Option constructors"
                  [ ConstructorDecl "Some" dummySpan dummySpan [TStr]
                  , ConstructorDecl "None" dummySpan dummySpan []
                  ]
                  (normalizeConstructors (typeDeclConstructors typeDecl))
              Nothing ->
                assertFailure "expected compiler-known Option type declaration"
            case find ((== "unwrap") . coreDeclName) (coreModuleDecls checked) of
              Just decl -> do
                assertEqual "unwrap type" (TFunction [TNamed "Option"] TStr) (coreDeclType decl)
                case coreDeclBody decl of
                  CMatch _ TStr (CVar _ (TNamed "Option") "value") [CoreMatchBranch _ (CConstructorPattern _ "Some" [CorePatternBinder "present" _ TStr]) (CVar _ TStr "present"), CoreMatchBranch _ (CConstructorPattern _ "None" []) (CString _ "missing")] ->
                    pure ()
                  other ->
                    assertFailure ("expected checked Option match expression, got " <> show other)
              Nothing ->
                assertFailure "expected unwrap declaration"
    , testCase "typechecks compiler-known self-hosting stdlib helpers" $
        case checkSource "compiler-stdlib" compilerStdlibSource of
          Left err ->
            assertFailure ("expected compiler stdlib source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            let foreignNames = fmap foreignDeclName (coreModuleForeignDecls checked)
            assertBool "expected textJoin builtin" ("textJoin" `elem` foreignNames)
            assertBool "expected textChars builtin" ("textChars" `elem` foreignNames)
            assertBool "expected textPrefix builtin" ("textPrefix" `elem` foreignNames)
            assertBool "expected textSplitFirst builtin" ("textSplitFirst" `elem` foreignNames)
            assertBool "expected pathJoin builtin" ("pathJoin" `elem` foreignNames)
            assertBool "expected readFile builtin" ("readFile" `elem` foreignNames)
            case find ((== "loadSummary") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                assertEqual "loadSummary type" (TFunction [TStr] TStr) (coreDeclType decl)
              Nothing ->
                assertFailure "expected loadSummary declaration"
    , testCase "typechecks generic records, ADTs, and annotated functions" $
        case checkSource "generic" genericTypeSource of
          Left err ->
            assertFailure ("expected generic type source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            case find ((== "Choice") . typeDeclName) (coreModuleTypeDecls checked) of
              Just typeDecl ->
                assertEqual "generic adt params" ["a"] (typeDeclParams typeDecl)
              Nothing ->
                assertFailure "expected generic Choice declaration"
            case find ((== "Box") . recordDeclName) (coreModuleRecordDecls checked) of
              Just recordDecl ->
                assertEqual "generic record params" ["a"] (recordDeclParams recordDecl)
              Nothing ->
                assertFailure "expected generic Box declaration"
            case find ((== "wrap") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                assertEqual "wrap type" (TFunction [TVar "a"] (TApply "Box" [TVar "a"])) (coreDeclType decl)
              Nothing ->
                assertFailure "expected wrap declaration"
            case find ((== "readBox") . coreDeclName) (coreModuleDecls checked) of
              Just decl -> do
                assertEqual "readBox type" (TFunction [TApply "Box" [TVar "a"]] (TVar "a")) (coreDeclType decl)
                case coreDeclBody decl of
                  CFieldAccess _ (TVar "a") (CVar _ (TApply "Box" [TVar "a"]) "box") "value" ->
                    pure ()
                  other ->
                    assertFailure ("expected generic field access, got " <> show other)
              Nothing ->
                assertFailure "expected readBox declaration"
            case find ((== "unwrapOr") . coreDeclName) (coreModuleDecls checked) of
              Just decl -> do
                assertEqual "unwrapOr type" (TFunction [TApply "Choice" [TVar "a"], TVar "a"] (TVar "a")) (coreDeclType decl)
                case coreDeclBody decl of
                  CMatch _ (TVar "a") (CVar _ (TApply "Choice" [TVar "a"]) "value") [CoreMatchBranch _ (CConstructorPattern _ "Some" [CorePatternBinder "present" _ (TVar "a")]) (CVar _ (TVar "a") "present"), CoreMatchBranch _ (CConstructorPattern _ "None" []) (CVar _ (TVar "a") "fallback")] ->
                    pure ()
                  other ->
                    assertFailure ("expected generic match expression, got " <> show other)
              Nothing ->
                assertFailure "expected unwrapOr declaration"
    , testCase "typechecks compiler-known sqlite connection helpers" $
        case checkSource "sqlite-runtime" sqliteRuntimeSource of
          Left err ->
            assertFailure ("expected sqlite runtime source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            let foreignDecls = coreModuleForeignDecls checked
                foreignNames = fmap foreignDeclName foreignDecls
            assertBool "expected sqliteOpen builtin" ("sqliteOpen" `elem` foreignNames)
            assertBool "expected sqliteOpenReadonly builtin" ("sqliteOpenReadonly" `elem` foreignNames)
            case find ((== "SqliteConnection") . recordDeclName) (coreModuleRecordDecls checked) of
              Just recordDecl ->
                assertEqual
                  "sqlite connection fields"
                  ["id", "databasePath", "readOnly", "memory"]
                  (fmap recordFieldDeclName (recordDeclFields recordDecl))
              Nothing ->
                assertFailure "expected compiler-known SqliteConnection record declaration"
            case find ((== "describeConnection") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                assertEqual
                  "describeConnection type"
                  (TFunction [TStr] (TNamed "SqliteConnection"))
                  (coreDeclType decl)
              Nothing ->
                assertFailure "expected describeConnection declaration"
    , testCase "typechecks storage bindings that use shared schema types" $
        case checkSource "provider-runtime" providerRuntimeSource of
          Left err ->
            assertFailure ("expected storage binding source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            let foreignDecls = coreModuleForeignDecls checked
            case find ((== "publishCustomer") . foreignDeclName) foreignDecls of
              Just foreignDecl ->
                assertEqual
                  "publishCustomer type"
                  (TFunction [TNamed "SupportCustomer"] (TNamed "SupportCustomer"))
                  (foreignDeclType foreignDecl)
              Nothing ->
                assertFailure "expected publishCustomer foreign declaration"
    , testCase "typechecks sqlite mutation bindings that keep semantic schema types at the boundary" $
        case checkSource "sqlite-mutation-runtime" sqliteMutationRuntimeSource of
          Left err ->
            assertFailure ("expected sqlite mutation source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            let foreignDecls = coreModuleForeignDecls checked
            case find ((== "insertNote") . foreignDeclName) foreignDecls of
              Just foreignDecl ->
                assertEqual
                  "insertNote type"
                  (TFunction [TNamed "SqliteConnection", TStr, TNamed "NoteInput"] (TNamed "NoteRow"))
                  (foreignDeclType foreignDecl)
              Nothing ->
                assertFailure "expected insertNote foreign declaration"
    , testCase "typechecks explicit unsafe sqlite bindings with named row contracts" $
        case checkSource "sqlite-unsafe-runtime" sqliteUnsafeRuntimeSource of
          Left err ->
            assertFailure ("expected unsafe sqlite source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            let foreignDecls = coreModuleForeignDecls checked
            case find ((== "fetchUnsafeFirstNote") . foreignDeclName) foreignDecls of
              Just foreignDecl -> do
                assertBool "expected explicit unsafe flag" (foreignDeclUnsafeInterop foreignDecl)
                assertEqual
                  "unsafe fetch type"
                  (TFunction [TNamed "SqliteConnection", TStr] (TNamed "UnsafeNoteRow"))
                  (foreignDeclType foreignDecl)
              Nothing ->
                assertFailure "expected unsafe sqlite foreign declaration"
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
    , testCase "typechecks the comparisons example file" $ do
        source <- readExampleSource "comparisons.clasp"
        case checkSource "examples/comparisons.clasp" source of
          Left err ->
            assertFailure ("expected comparisons example source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked -> do
            case find ((== "isAtMost") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CLessThanOrEqual _ (CVar _ TInt "left") (CVar _ TInt "right") ->
                    pure ()
                  other ->
                    assertFailure ("expected checked less-than-or-equal expression in comparisons example, got " <> show other)
              Nothing ->
                assertFailure "expected isAtMost declaration in comparisons example"
            case find ((== "main") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CEqual _ (CCall _ TBool (CVar _ (TFunction [TInt, TInt] TBool) "isEarlier") [CInt _ 3, CInt _ 5]) (CCall _ TBool (CVar _ (TFunction [TInt, TInt] TBool) "isLatest") [CInt _ 7, CInt _ 7]) ->
                    pure ()
                  other ->
                    assertFailure ("expected checked equality over comparison calls in comparisons example, got " <> show other)
              Nothing ->
                assertFailure "expected main declaration in comparisons example"
    , testCase "typechecks the compiler stdlib example file" $ do
        source <- readExampleSource "compiler-stdlib.clasp"
        case checkSource "examples/compiler-stdlib.clasp" source of
          Left err ->
            assertFailure ("expected compiler stdlib example source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case find ((== "main") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                assertEqual "main type" TStr (coreDeclType decl)
              Nothing ->
                assertFailure "expected main declaration"
    , testCase "typechecks the compiler renderers example file on the hosted Clasp path" $ do
        (exitCode, stdoutText, stderrText) <- runClaspc ["check", "examples/compiler-renderers.clasp"]
        case exitCode of
          ExitSuccess ->
            pure ()
          ExitFailure _ ->
            assertFailure ("expected compiler renderers example source to typecheck:\n" <> stdoutText <> stderrText)
    , testCase "typechecks the compiler loader example file on the hosted Clasp path" $ do
        (exitCode, stdoutText, stderrText) <- runClaspc ["check", "examples/compiler-loader.clasp"]
        case exitCode of
          ExitSuccess ->
            pure ()
          ExitFailure _ ->
            assertFailure ("expected compiler loader example source to typecheck:\n" <> stdoutText <> stderrText)
    , testCase "typechecks the compiler parser example file on the hosted Clasp path" $ do
        (exitCode, stdoutText, stderrText) <- runClaspc ["check", "examples/compiler-parser.clasp"]
        case exitCode of
          ExitSuccess ->
            pure ()
          ExitFailure _ ->
            assertFailure ("expected compiler parser example source to typecheck:\n" <> stdoutText <> stderrText)
    , testCase "typechecks the compiler checker example file on the hosted Clasp path" $ do
        (exitCode, stdoutText, stderrText) <- runClaspc ["check", "examples/compiler-checker.clasp"]
        case exitCode of
          ExitSuccess ->
            pure ()
          ExitFailure _ ->
            assertFailure ("expected compiler checker example source to typecheck:\n" <> stdoutText <> stderrText)
    , testCase "typechecks the compiler emitter example file on the hosted Clasp path" $ do
        (exitCode, stdoutText, stderrText) <- runClaspc ["check", "examples/compiler-emitter.clasp"]
        case exitCode of
          ExitSuccess ->
            pure ()
          ExitFailure _ ->
            assertFailure ("expected compiler emitter example source to typecheck:\n" <> stdoutText <> stderrText)
    , testCase "typechecks the hosted compiler entrypoint file" $ do
        (exitCode, stdoutText, stderrText) <- runClaspc ["check", "src/Main.clasp"]
        case exitCode of
          ExitSuccess ->
            pure ()
          ExitFailure _ ->
            assertFailure ("expected hosted compiler entrypoint source to typecheck:\n" <> stdoutText <> stderrText)
    , testCase "claspc check prefers the hosted Clasp compiler for the hosted compiler entrypoint" $ do
        (exitCode, stdoutText, stderrText) <- runClaspc ["check", "src/Main.clasp", "--json"]
        case exitCode of
          ExitSuccess ->
            pure ()
          ExitFailure _ ->
            assertFailure ("expected hosted primary compiler check to succeed:\n" <> stdoutText <> stderrText)
        jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
          Left decodeErr ->
            assertFailure ("expected hosted primary compiler json output to decode:\n" <> decodeErr)
          Right value ->
            pure value
        assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
        assertEqual "command" (Just (String "check")) (lookupObjectKey "command" jsonValue)
        assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
    , testCase "claspc check supports simple ordinary programs on the hosted Clasp path" $ do
        (exitCode, stdoutText, stderrText) <- runClaspc ["check", "examples/hello.clasp", "--json"]
        case exitCode of
          ExitSuccess ->
            pure ()
          ExitFailure _ ->
            assertFailure ("expected hosted primary compiler check for a simple ordinary program to succeed:\n" <> stdoutText <> stderrText)
        jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
          Left decodeErr ->
            assertFailure ("expected hosted ordinary check json output to decode:\n" <> decodeErr)
          Right value ->
            pure value
        assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
        assertEqual "command" (Just (String "check")) (lookupObjectKey "command" jsonValue)
        assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
    , testCase "claspc check supports imported subset projects on the hosted Clasp path" $
        withProjectFiles "check-primary-import-success" importSuccessFiles $ \root -> do
          let inputPath = root </> "Main.clasp"
          (exitCode, stdoutText, stderrText) <- runClaspc ["check", inputPath, "--json"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted primary compiler check for an imported subset project to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted imported check json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "check")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
    , testCase "claspc check keeps local binders ahead of imported globals on the hosted Clasp path" $
        withProjectFiles "check-primary-shadowed-import-success" shadowedImportFiles $ \root -> do
          let inputPath = root </> "Main.clasp"
          (exitCode, stdoutText, stderrText) <- runClaspc ["check", inputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted primary compiler check for a shadowed imported project to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted shadowed-import check json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "check")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
    , testCase "claspc check rejects deprecated bootstrap compiler selection" $ do
        (exitCode, stdoutText, stderrText) <- runClaspc ["check", "examples/hello.clasp", "--json", "--compiler=bootstrap"]
        case exitCode of
          ExitSuccess ->
            assertFailure ("expected deprecated bootstrap compiler selection to fail:\n" <> stdoutText <> stderrText)
          ExitFailure _ ->
            assertBool
              "expected bootstrap rejection message"
              ("deprecated compiler selection is gone" `isInfixOf` stdoutText || "deprecated compiler selection is gone" `isInfixOf` stderrText)
    , testCase "claspc check rejects deprecated bootstrap compiler selection for the hosted compiler entrypoint" $ do
        (exitCode, stdoutText, stderrText) <- runClaspc ["check", "src/Main.clasp", "--json", "--compiler=bootstrap"]
        case exitCode of
          ExitSuccess ->
            assertFailure ("expected deprecated bootstrap compiler selection to fail:\n" <> stdoutText <> stderrText)
          ExitFailure _ ->
            assertBool
              "expected bootstrap rejection message"
              ("deprecated compiler selection is gone" `isInfixOf` stdoutText || "deprecated compiler selection is gone" `isInfixOf` stderrText)
    , testCase "claspc check supports explicit Clasp-primary requests for package-backed imports" $
        withProjectFiles "check-primary-package-imports-unsupported" packageImportFiles $ \root -> do
          let inputPath = root </> "Main.clasp"
          (exitCode, stdoutText, stderrText) <- runClaspc ["check", inputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler check for package-backed imports to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted package-import check json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "check")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
    , testCase "checkEntryWithPreference Auto prefers the hosted Clasp compiler for hosted-subset projects" $ do
        (implementation, result) <- checkEntryWithPreference CompilerPreferenceAuto ("examples" </> "hello.clasp")
        assertEqual "implementation" CompilerImplementationClasp implementation
        case result of
          Left err ->
            assertFailure ("expected hosted auto check to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            assertBool "expected main declaration in checked module" (any ((== "main") . coreDeclName) (coreModuleDecls checked))
    , testCase "checkEntryWithPreference Clasp reconstructs typed core for hosted ordinary programs" $ do
        (implementation, result) <- checkEntryWithPreference CompilerPreferenceClasp ("examples" </> "hello.clasp")
        assertEqual "implementation" CompilerImplementationClasp implementation
        case result of
          Left err ->
            assertFailure ("expected explicit hosted check to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            case find ((== "main") . coreDeclName) (coreModuleDecls checked) of
              Just decl ->
                case coreDeclBody decl of
                  CCall _ TStr (CVar _ (TFunction [TStr] TStr) "id") [CVar _ TStr "hello"] ->
                    pure ()
                  other ->
                    assertFailure ("expected hosted checked core to preserve the typed main call, got " <> show other)
              Nothing ->
                assertFailure "expected hosted checked module to contain main"
    , testCase "checkEntryWithPreference Auto prefers the hosted Clasp compiler for control-plane metadata projects" $ do
        (implementation, result) <- checkEntryWithPreference CompilerPreferenceAuto ("examples" </> "control-plane" </> "Main.clasp")
        assertEqual "implementation" CompilerImplementationClasp implementation
        case result of
          Left err ->
            assertFailure ("expected hosted auto check for control-plane to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right checked ->
            assertBool "expected main declaration in checked module" (any ((== "main") . coreDeclName) (coreModuleDecls checked))
    , testCase "checkEntrySummaryWithPreference Auto prefers the hosted Clasp compiler for hosted-subset projects" $ do
        (implementation, result) <- checkEntrySummaryWithPreference CompilerPreferenceAuto ("examples" </> "hello.clasp")
        assertEqual "implementation" CompilerImplementationClasp implementation
        case result of
          Left err ->
            assertFailure ("expected hosted auto check summary to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right summary -> do
            assertBool "expected hosted summary hello declaration" ("hello : Str" `T.isInfixOf` summary)
            assertBool "expected hosted summary main declaration" ("main : Str" `T.isInfixOf` summary)
    , testCase "checkEntrySummaryWithPreference Auto prefers the hosted Clasp compiler for control-plane metadata projects" $ do
        (implementation, result) <- checkEntrySummaryWithPreference CompilerPreferenceAuto ("examples" </> "control-plane" </> "Main.clasp")
        assertEqual "implementation" CompilerImplementationClasp implementation
        case result of
          Left err ->
            assertFailure ("expected hosted auto check summary for control-plane to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right summary ->
            assertBool "expected control-plane summary to mention the hook handler" ("bootstrapWorker : WorkerBoot -> HookAck" `T.isInfixOf` summary)
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
    , testCase "reports ambiguous empty list inference with an annotation hint" $
        case checkSource "bad" ambiguousEmptyListSource of
          Left bundle -> do
            err <- expectFirstDiagnostic bundle
            assertEqual "code" "E_CANNOT_INFER" (diagnosticCode err)
            assertBool
              "expected empty list annotation hint"
              (any ("Empty list literals need a surrounding list type" `T.isInfixOf`) (diagnosticFixHints err))
          Right _ ->
            assertFailure "expected ambiguous empty list failure"
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
    , testCase "rejects storage bindings that use bare primitive types" $
        assertHasCode "E_STORAGE_BOUNDARY_TYPE" (checkSource "bad" badStoragePrimitiveSource)
    , testCase "rejects sqlite query bindings that use bare primitive storage-facing types" $
        assertHasCode "E_STORAGE_BOUNDARY_TYPE" (checkSource "bad" badSqliteQueryPrimitiveSource)
    , testCase "rejects sqlite mutation bindings that use bare primitive storage-facing types" $
        assertHasCode "E_STORAGE_BOUNDARY_TYPE" (checkSource "bad" badSqliteMutationPrimitiveSource)
    , testCase "rejects sqlite unsafe bindings that are not declared as explicit unsafe foreign declarations" $
        assertHasCode "E_SQLITE_UNSAFE_DECL" (checkSource "bad" badSqliteUnsafeMissingExplicitSource)
    , testCase "rejects sqlite unsafe bindings without named record row contracts" $
        assertHasCode "E_SQLITE_UNSAFE_ROW_CONTRACT" (checkSource "bad" badSqliteUnsafeRowContractSource)
    , testCase "rejects projections that disclose disallowed classified fields" $
        assertHasCode "E_DISCLOSURE_POLICY" (checkSource "bad" disallowedProjectionSource)
    , testCase "rejects assignment to immutable block locals" $
        assertHasCode "E_ASSIGNMENT_TARGET" (checkSource "bad" immutableBlockAssignmentSource)
    , testCase "rejects assignment to names that are not mutable block locals" $
        assertHasCode "E_ASSIGNMENT_TARGET" (checkSource "bad" nonLocalAssignmentSource)
    , testCase "rejects for-loops over non-iterable values" $
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
    , testCase "rejects goals that reference unknown metrics" $
        assertHasCode "E_UNKNOWN_GOAL_METRIC" (checkSource "bad" unknownGoalMetricSource)
    , testCase "rejects feedback declarations that reference unknown domain objects" $
        assertHasCode "E_UNKNOWN_FEEDBACK_OBJECT" (checkSource "bad" unknownFeedbackObjectSource)
    , testCase "rejects experiments that reference unknown goals" $
        assertHasCode "E_UNKNOWN_EXPERIMENT_GOAL" (checkSource "bad" unknownExperimentGoalSource)
    , testCase "rejects rollouts that reference unknown experiments" $
        assertHasCode "E_UNKNOWN_ROLLOUT_EXPERIMENT" (checkSource "bad" unknownRolloutExperimentSource)
    , testCase "rejects hooks whose handlers do not match declared schemas" $
        assertHasCode "E_HOOK_HANDLER_TYPE" (checkSource "bad" badHookHandlerSource)
    , testCase "rejects workflows whose state is not a record schema" $
        assertHasCode "E_WORKFLOW_STATE_TYPE" (checkSource "bad" badWorkflowStateSource)
    , testCase "rejects workflows whose declared constraint handlers do not match the state schema" $
        assertHasCode "E_WORKFLOW_CONSTRAINT_TYPE" (checkSource "bad" badWorkflowConstraintSource)
    , testCase "rejects supervisor hierarchies that attach a workflow to multiple parents" $
        assertHasCode "E_MULTIPLE_SUPERVISOR_PARENTS" (checkSource "bad" duplicateSupervisorParentSource)
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
    , testCase "explain preserves entry-module imports in expanded rendering" $
        withProjectFiles "explain-import-header" compactHeaderImportSuccessFiles $ \root -> do
          let inputPath = root </> "Main.clasp"
          result <- explainEntry inputPath
          case result of
            Left err ->
              assertFailure ("expected explain rendering with imports to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
            Right explanation ->
              assertBool "expected expanded header to retain imports" ("module Main with Shared.User" `T.isInfixOf` explanation)
    , testCase "claspc explain prints imported module headers in pretty mode" $
        withProjectFiles "explain-cli-import-header" compactHeaderImportSuccessFiles $ \root -> do
          let inputPath = root </> "Main.clasp"
          (exitCode, stdoutText, stderrText) <- runClaspc ["explain", inputPath]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("claspc explain failed:\n" <> stderrText)
          assertBool "expected pretty explain output to retain import header" ("module Main with Shared.User" `isInfixOf` stdoutText)
          assertBool "expected pretty explain output to report success" ("Explained " `isInfixOf` stderrText)
    , testCase "claspc explain prefers the hosted Clasp compiler for the hosted compiler entrypoint" $ do
        (exitCode, stdoutText, stderrText) <- runClaspc ["explain", "src/Main.clasp", "--json"]
        case exitCode of
          ExitSuccess ->
            pure ()
          ExitFailure _ ->
            assertFailure ("expected hosted primary compiler explain to succeed:\n" <> stdoutText <> stderrText)
        jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
          Left decodeErr ->
            assertFailure ("expected hosted explain json output to decode:\n" <> decodeErr)
          Right value ->
            pure value
        assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
        assertEqual "command" (Just (String "explain")) (lookupObjectKey "command" jsonValue)
        assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
    , testCase "claspc explain supports simple ordinary programs on the hosted Clasp path" $ do
        (exitCode, stdoutText, stderrText) <- runClaspc ["explain", "examples/hello.clasp", "--json"]
        case exitCode of
          ExitSuccess ->
            pure ()
          ExitFailure _ ->
            assertFailure ("expected hosted primary compiler explain for a simple ordinary program to succeed:\n" <> stdoutText <> stderrText)
        jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
          Left decodeErr ->
            assertFailure ("expected hosted ordinary explain json output to decode:\n" <> decodeErr)
          Right value ->
            pure value
        assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
        assertEqual "command" (Just (String "explain")) (lookupObjectKey "command" jsonValue)
        assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
    , testCase "claspc explain supports imported subset projects on the hosted Clasp path" $
        withProjectFiles "explain-primary-import-success" importSuccessFiles $ \root -> do
          let inputPath = root </> "Main.clasp"
          (exitCode, stdoutText, stderrText) <- runClaspc ["explain", inputPath, "--json"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted primary compiler explain for an imported subset project to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted imported explain json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "explain")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          case lookupObjectKey "explanation" jsonValue of
            Just (String explanation) -> do
              assertBool "expected imported helper declaration in explanation" ("formatUser : User -> Str" `T.isInfixOf` explanation)
              assertBool "expected entry declaration in explanation" ("main : Str" `T.isInfixOf` explanation)
            _ ->
              assertFailure "expected explanation string in hosted imported explain json"
    , testCase "claspc explain rejects deprecated bootstrap compiler selection" $ do
        (exitCode, stdoutText, stderrText) <- runClaspc ["explain", "examples/hello.clasp", "--json", "--compiler=bootstrap"]
        case exitCode of
          ExitSuccess ->
            assertFailure ("expected deprecated bootstrap compiler selection to fail:\n" <> stdoutText <> stderrText)
          ExitFailure _ ->
            assertBool
              "expected bootstrap rejection message"
              ("deprecated compiler selection is gone" `isInfixOf` stdoutText || "deprecated compiler selection is gone" `isInfixOf` stderrText)
    , testCase "claspc explain supports explicit Clasp-primary requests for package-backed imports" $
        withProjectFiles "explain-primary-package-imports-unsupported" packageImportFiles $ \root -> do
          let inputPath = root </> "Main.clasp"
          (exitCode, stdoutText, stderrText) <- runClaspc ["explain", inputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler explain for package-backed imports to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted package-import explain json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "explain")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          case lookupObjectKey "explanation" jsonValue of
            Just (String explanation) -> do
              assertBool "expected package-backed foreign helper in explanation" ("shout : Str -> Str" `T.isInfixOf` explanation)
              assertBool "expected package-backed describe helper in explanation" ("describe : LeadRequest -> Str" `T.isInfixOf` explanation)
            _ ->
              assertFailure "expected explanation string in hosted package-import explain json"
    , testCase "explainEntryWithPreference Auto prefers the hosted Clasp compiler for simple ordinary projects" $ do
        (implementation, result) <- explainEntryWithPreference CompilerPreferenceAuto ("examples" </> "hello.clasp")
        assertEqual "implementation" CompilerImplementationClasp implementation
        case result of
          Left err ->
            assertFailure ("expected hosted auto explain to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right explanation ->
            assertBool "expected hello declaration in explanation" ("hello : Str" `T.isInfixOf` explanation)
    , testCase "explainEntryWithPreference Auto prefers the hosted Clasp compiler for control-plane metadata projects" $ do
        (implementation, result) <- explainEntryWithPreference CompilerPreferenceAuto ("examples" </> "control-plane" </> "Main.clasp")
        assertEqual "implementation" CompilerImplementationClasp implementation
        case result of
          Left err ->
            assertFailure ("expected hosted auto explain for control-plane to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right explanation ->
            assertBool "expected control-plane explanation to mention the main declaration" ("main :" `T.isInfixOf` explanation)
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
    , testCase "current structured diagnostic codes avoid the generic fallback hint" $ do
        codes <- currentStructuredDiagnosticCodes
        let uncoveredCodes =
              filter
                (\code ->
                    diagnosticFixHints (diagnostic code "summary" Nothing [] [])
                      == [genericDiagnosticFixHint]
                )
                codes
        assertEqual "expected dedicated hints for current diagnostic codes" [] uncoveredCodes
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
    , testCase "air retains domain object, domain event, feedback, metric, goal, experiment, and rollout graph identity" $
        case airSource "domain" domainModelSource of
          Left err ->
            assertFailure ("expected AIR generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right airModule -> do
            assertBool "expected domain object root" (AirNodeId "domain-object:Customer" `elem` airModuleRootIds airModule)
            assertBool "expected domain event root" (AirNodeId "domain-event:CustomerChurned" `elem` airModuleRootIds airModule)
            assertBool "expected feedback root" (AirNodeId "feedback:CustomerEscalation" `elem` airModuleRootIds airModule)
            assertBool "expected metric root" (AirNodeId "metric:CustomerChurnRate" `elem` airModuleRootIds airModule)
            assertBool "expected goal root" (AirNodeId "goal:RetainCustomers" `elem` airModuleRootIds airModule)
            assertBool "expected experiment root" (AirNodeId "experiment:RetentionPromptTrial" `elem` airModuleRootIds airModule)
            assertBool "expected rollout root" (AirNodeId "rollout:RetentionPromptCanary" `elem` airModuleRootIds airModule)
            case findAirNode (AirNodeId "domain-object:Customer") (airModuleNodes airModule) of
              Just node ->
                assertBool
                  "expected domain object schema ref"
                  (("schema", AirAttrObject [("name", AirAttrText "CustomerRecord"), ("ref", AirAttrNode (AirNodeId "record:CustomerRecord"))]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected domain object AIR node"
            case findAirNode (AirNodeId "domain-event:CustomerChurned") (airModuleNodes airModule) of
              Just node ->
                assertBool
                  "expected domain event object ref"
                  (("domainObject", AirAttrObject [("name", AirAttrText "Customer"), ("ref", AirAttrNode (AirNodeId "domain-object:Customer"))]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected domain event AIR node"
            case findAirNode (AirNodeId "feedback:CustomerEscalation") (airModuleNodes airModule) of
              Just node -> do
                assertBool
                  "expected feedback kind"
                  (("kind", AirAttrText "operational") `elem` airNodeAttrs node)
                assertBool
                  "expected feedback object ref"
                  (("domainObject", AirAttrObject [("name", AirAttrText "Customer"), ("ref", AirAttrNode (AirNodeId "domain-object:Customer"))]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected feedback AIR node"
            case findAirNode (AirNodeId "metric:CustomerChurnRate") (airModuleNodes airModule) of
              Just node ->
                assertBool
                  "expected metric object ref"
                  (("domainObject", AirAttrObject [("name", AirAttrText "Customer"), ("ref", AirAttrNode (AirNodeId "domain-object:Customer"))]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected metric AIR node"
            case findAirNode (AirNodeId "goal:RetainCustomers") (airModuleNodes airModule) of
              Just node ->
                assertBool
                  "expected goal metric ref"
                  (("metric", AirAttrObject [("name", AirAttrText "CustomerChurnRate"), ("ref", AirAttrNode (AirNodeId "metric:CustomerChurnRate"))]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected goal AIR node"
            case findAirNode (AirNodeId "experiment:RetentionPromptTrial") (airModuleNodes airModule) of
              Just node ->
                assertBool
                  "expected experiment goal ref"
                  (("goal", AirAttrObject [("name", AirAttrText "RetainCustomers"), ("ref", AirAttrNode (AirNodeId "goal:RetainCustomers"))]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected experiment AIR node"
            case findAirNode (AirNodeId "rollout:RetentionPromptCanary") (airModuleNodes airModule) of
              Just node ->
                assertBool
                  "expected rollout experiment ref"
                  (("experiment", AirAttrObject [("name", AirAttrText "RetentionPromptTrial"), ("ref", AirAttrNode (AirNodeId "experiment:RetentionPromptTrial"))]) `elem` airNodeAttrs node)
              Nothing ->
                assertFailure "expected rollout AIR node"
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
    , testCase "context graph includes domain object, domain event, feedback, metric, goal, experiment, and rollout objective edges" $
        case renderContextSourceJson "domain" domainModelSource of
          Left err ->
            assertFailure ("expected context graph generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right rendered -> do
            let jsonText = LT.toStrict rendered
            assertBool "expected domain object node" ("\"domain-object:Customer\"" `T.isInfixOf` jsonText)
            assertBool "expected domain event node" ("\"domain-event:CustomerChurned\"" `T.isInfixOf` jsonText)
            assertBool "expected feedback node" ("\"feedback:CustomerEscalation\"" `T.isInfixOf` jsonText)
            assertBool "expected metric node" ("\"metric:CustomerChurnRate\"" `T.isInfixOf` jsonText)
            assertBool "expected goal node" ("\"goal:RetainCustomers\"" `T.isInfixOf` jsonText)
            assertBool "expected experiment node" ("\"experiment:RetentionPromptTrial\"" `T.isInfixOf` jsonText)
            assertBool "expected rollout node" ("\"rollout:RetentionPromptCanary\"" `T.isInfixOf` jsonText)
            assertBool "expected domain object schema edge" ("\"domain-object-schema\"" `T.isInfixOf` jsonText)
            assertBool "expected domain event object edge" ("\"domain-event-object\"" `T.isInfixOf` jsonText)
            assertBool "expected feedback object edge" ("\"feedback-object\"" `T.isInfixOf` jsonText)
            assertBool "expected metric object edge" ("\"metric-object\"" `T.isInfixOf` jsonText)
            assertBool "expected goal metric edge" ("\"goal-metric\"" `T.isInfixOf` jsonText)
            assertBool "expected experiment goal edge" ("\"experiment-goal\"" `T.isInfixOf` jsonText)
            assertBool "expected rollout experiment edge" ("\"rollout-experiment\"" `T.isInfixOf` jsonText)
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
    , testCase "context graph ties secret inputs back to policies and consuming boundaries" $
        case renderContextSourceJson "control-plane" controlPlaneSource of
          Left err ->
            assertFailure ("expected context graph generation to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right rendered -> do
            let jsonText = LT.toStrict rendered
            assertBool "expected secret input node" ("\"secret-input:OPENAI_API_KEY\"" `T.isInfixOf` jsonText)
            assertBool "expected secret input policy names" ("\"policyNames\"" `T.isInfixOf` jsonText && "\"SupportDisclosure\"" `T.isInfixOf` jsonText)
            assertBool "expected policy secret edge" ("\"policy-permits-secret\"" `T.isInfixOf` jsonText)
            assertBool "expected agent role secret edge" ("\"agent-role-secret-input\"" `T.isInfixOf` jsonText)
            assertBool "expected toolserver secret edge" ("\"toolserver-secret-input\"" `T.isInfixOf` jsonText)
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
    , testCase "claspc air rejects ordinary programs unless bootstrap recovery mode is requested" $
        withProjectFiles "air-cli-default" [("Main.clasp", interactivePageSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = replaceExtension inputPath "air.json"
          (exitCode, _stdoutText, stderrText) <- runClaspc ["air", inputPath, "--json"]
          case exitCode of
            ExitSuccess ->
              assertFailure "expected default air command for an ordinary program to fail"
            ExitFailure _ ->
              pure ()
          assertUnsupportedPrimaryCompilerJson stderrText
          exists <- doesFileExist outputPath
          assertBool "expected default air command not to write an artifact" (not exists)
    , testCase "claspc air rejects deprecated bootstrap compiler selection when -o is omitted" $
        withProjectFiles "air-cli-bootstrap" [("Main.clasp", interactivePageSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = replaceExtension inputPath "air.json"
          (exitCode, _stdoutText, stderrText) <- runClaspc ["air", inputPath, "--compiler=bootstrap"]
          case exitCode of
            ExitSuccess ->
              assertFailure "expected deprecated bootstrap compiler selection to fail for air"
            ExitFailure _ ->
              assertBool
                "expected bootstrap rejection message"
                ("deprecated compiler selection is gone" `isInfixOf` stderrText)
          exists <- doesFileExist outputPath
          assertBool "expected deprecated bootstrap air command not to write an artifact" (not exists)
    , testCase "claspc context rejects ordinary programs unless bootstrap recovery mode is requested" $
        withProjectFiles "context-cli-default" [("Main.clasp", interactivePageSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = replaceExtension inputPath "context.json"
          (exitCode, _stdoutText, stderrText) <- runClaspc ["context", inputPath, "--json"]
          case exitCode of
            ExitSuccess ->
              assertFailure "expected default context command for an ordinary program to fail"
            ExitFailure _ ->
              pure ()
          assertUnsupportedPrimaryCompilerJson stderrText
          exists <- doesFileExist outputPath
          assertBool "expected default context command not to write an artifact" (not exists)
    , testCase "claspc context rejects deprecated bootstrap compiler selection when -o is omitted" $
        withProjectFiles "context-cli-bootstrap" [("Main.clasp", interactivePageSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = replaceExtension inputPath "context.json"
          (exitCode, _stdoutText, stderrText) <- runClaspc ["context", inputPath, "--compiler=bootstrap"]
          case exitCode of
            ExitSuccess ->
              assertFailure "expected deprecated bootstrap compiler selection to fail for context"
            ExitFailure _ ->
              assertBool
                "expected bootstrap rejection message"
                ("deprecated compiler selection is gone" `isInfixOf` stderrText)
          exists <- doesFileExist outputPath
          assertBool "expected deprecated bootstrap context command not to write an artifact" (not exists)
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
    , testCase "lowering materializes compiler-known Result constructors" $
        case lowerChecked "result" builtinResultSource of
          Left err ->
            assertFailure ("expected builtin Result lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case lowerModuleDecls lowered of
              LFunctionDecl "Ok" ["$0"] (LConstruct "Ok" [LVar "$0"]) : LFunctionDecl "Err" ["$0"] (LConstruct "Err" [LVar "$0"]) : _ ->
                pure ()
              other ->
                assertFailure ("unexpected lowered Result constructors: " <> show other)
    , testCase "lowering materializes compiler-known Option constructors" $
        case lowerChecked "option" builtinOptionSource of
          Left err ->
            assertFailure ("expected builtin Option lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case lowerModuleDecls lowered of
              LFunctionDecl "Some" ["$0"] (LConstruct "Some" [LVar "$0"]) : LValueDecl "None" (LConstruct "None" []) : _ ->
                pure ()
              other ->
                assertFailure ("unexpected lowered Option constructors: " <> show other)
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
              Just (LFunctionDecl _ ["user"] (LFieldAccess (TNamed "User") (LVar "user") "name")) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered showName declaration: " <> show other)
            case findLowerDecl "defaultUser" (lowerModuleDecls lowered) of
              Just (LValueDecl _ (LRecord "User" [LowerRecordField "name" (LString "Ada"), LowerRecordField "active" (LBool True)])) ->
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
    , testCase "lowering preserves supervisor declarations for runtime metadata emission" $
        case lowerChecked "supervisor" supervisorSource of
          Left err ->
            assertFailure ("expected supervisor lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case lowerModuleSupervisorDecls lowered of
              [rootSupervisor, childSupervisor] -> do
                assertEqual "lowered root strategy" SupervisorOneForAll (supervisorDeclRestartStrategy rootSupervisor)
                assertEqual "lowered child strategy" SupervisorRestForOne (supervisorDeclRestartStrategy childSupervisor)
              other ->
                assertFailure ("expected two lowered supervisor declarations, got " <> show (length other))
    , testCase "lowering preserves list literals" $
        case lowerChecked "lists" listLiteralSource of
          Left err ->
            assertFailure ("expected list lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered -> do
            case findLowerDecl "roster" (lowerModuleDecls lowered) of
              Just (LValueDecl _ (LList [LString "Ada", LString "Grace"])) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered roster declaration: " <> show other)
            case findLowerDecl "emptyRoster" (lowerModuleDecls lowered) of
              Just (LValueDecl _ (LList [])) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered emptyRoster declaration: " <> show other)
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
    , testCase "lowering tracks codec types for route, hook, tool, and workflow boundaries" $
        case lowerChecked "native-boundaries" nativeBoundarySource of
          Left err ->
            assertFailure ("expected native boundary lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            assertEqual
              "boundary codec types"
              [ TNamed "Counter"
              , TNamed "HookAck"
              , TNamed "LeadRequest"
              , TNamed "LeadSummary"
              , TNamed "SearchRequest"
              , TNamed "SearchResponse"
              , TNamed "WorkerBoot"
              ]
              (lowerModuleCodecTypes lowered)
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
    , testCase "lowering preserves the let example file" $ do
        source <- readExampleSource "let.clasp"
        case lowerChecked "examples/let.clasp" source of
          Left err ->
            assertFailure ("expected let example lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered -> do
            case findLowerDecl "describe" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["status"] (LMatch (LVar "status") [LowerMatchBranch "Idle" [] (LLet "label" (LString "idle") (LVar "label")), LowerMatchBranch "Busy" ["note"] (LLet "copy" (LVar "note") (LVar "copy"))])) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered let example describe declaration: " <> show other)
            case findLowerDecl "main" (lowerModuleDecls lowered) of
              Just (LValueDecl _ (LLet "current" (LCall (LVar "Busy") [LString "loading"]) (LCall (LVar "describe") [LVar "current"]))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered let example main declaration: " <> show other)
    , testCase "lowering preserves the comparisons example file" $ do
        source <- readExampleSource "comparisons.clasp"
        case lowerChecked "examples/comparisons.clasp" source of
          Left err ->
            assertFailure ("expected comparisons example lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered -> do
            case findLowerDecl "isLater" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["left", "right"] (LGreaterThan (LVar "left") (LVar "right"))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered isLater declaration in comparisons example: " <> show other)
            case findLowerDecl "main" (lowerModuleDecls lowered) of
              Just (LValueDecl _ (LEqual (LCall (LVar "isEarlier") [LInt 3, LInt 5]) (LCall (LVar "isLatest") [LInt 7, LInt 7]))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered comparisons example main declaration: " <> show other)
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
    , testCase "lowering preserves for-loops over string values" $
        case lowerChecked "string-for-loop" stringLoopIterationSource of
          Left err ->
            assertFailure ("expected string loop iteration lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "pickLastChar" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["name"] (LMutableLet "current" (LString "") (LFor "char" (LVar "name") (LAssign "current" (LVar "char") (LVar "current")) (LVar "current")))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered string for-loop declaration: " <> show other)
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
    , testCase "lowering preserves early returns from inside for-loops" $
        case lowerChecked "loop-return" loopEarlyReturnSource of
          Left err ->
            assertFailure ("expected loop early return lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right lowered ->
            case findLowerDecl "pickUntilStop" (lowerModuleDecls lowered) of
              Just (LFunctionDecl _ ["decisions"] (LMutableLet "winner" (LString "none") (LFor "decision" (LVar "decisions") (LMatch (LVar "decision") [LowerMatchBranch "Stop" [] (LReturn (LString "stopped")), LowerMatchBranch "Keep" ["name"] (LAssign "winner" (LVar "name") (LVar "winner"))]) (LVar "winner")))) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered loop early return declaration: " <> show other)
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
              Just (LFunctionDecl _ ["session"] (LFieldAccess (TNamed "Tenant") (LFieldAccess (TNamed "AuthSession") (LVar "session") "tenant") "id")) ->
                pure ()
              other ->
                assertFailure ("unexpected lowered auth identity declaration: " <> show other)
    ]

nativeTests :: TestTree
nativeTests =
  testGroup
    "native"
    [ testCase "native lowering defines backend-native globals and functions" $
        case nativeSource "adt" adtSource of
          Left err ->
            assertFailure ("expected native lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right nativeMod -> do
            assertEqual "native exports" ["Idle", "Busy", "describe", "main"] (nativeModuleExports nativeMod)
            case findNativeDecl "Idle" (nativeModuleDecls nativeMod) of
              Just (NativeGlobalDecl (NativeGlobal _ (NativeConstruct "Idle" []))) ->
                pure ()
              other ->
                assertFailure ("unexpected native Idle declaration: " <> show other)
            case findNativeDecl "Busy" (nativeModuleDecls nativeMod) of
              Just (NativeFunctionDecl (NativeFunction _ ["$0"] (NativeConstruct "Busy" [NativeLocal "$0"]))) ->
                pure ()
              other ->
                assertFailure ("unexpected native Busy declaration: " <> show other)
            case findNativeDecl "describe" (nativeModuleDecls nativeMod) of
              Just (NativeFunctionDecl (NativeFunction _ ["status"] (NativeMatch (NativeLocal "status") [NativeMatchBranch "Idle" [] (NativeLiteralExpr (NativeString "idle")), NativeMatchBranch "Busy" ["note"] (NativeLocal "note")]))) ->
                pure ()
              other ->
                assertFailure ("unexpected native describe declaration: " <> show other)
    , testCase "native lowering preserves mutable bindings and backend equality/comparison ops" $ do
        case nativeSource "mutable-block" mutableBlockAssignmentSource of
          Left err ->
            assertFailure ("expected mutable native lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right nativeMod ->
            case findNativeDecl "greeting" (nativeModuleDecls nativeMod) of
              Just (NativeGlobalDecl (NativeGlobal _ (NativeLet NativeMutable "message" (NativeLiteralExpr (NativeString "Ada")) (NativeAssign "message" (NativeLiteralExpr (NativeString "Grace")) (NativeLocal "message"))))) ->
                pure ()
              other ->
                assertFailure ("unexpected native greeting declaration: " <> show other)
        case nativeSource "equality" equalitySource of
          Left err ->
            assertFailure ("expected equality native lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right nativeMod ->
            case findNativeDecl "sameWord" (nativeModuleDecls nativeMod) of
              Just (NativeFunctionDecl (NativeFunction _ ["left", "right"] (NativeCompare NativeEqual (NativeLocal "left") (NativeLocal "right")))) ->
                pure ()
              other ->
                assertFailure ("unexpected native sameWord declaration: " <> show other)
        case nativeSource "comparison" integerComparisonSource of
          Left err ->
            assertFailure ("expected comparison native lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right nativeMod ->
            case findNativeDecl "isLatest" (nativeModuleDecls nativeMod) of
              Just (NativeFunctionDecl (NativeFunction _ ["left", "right"] (NativeCompare NativeGreaterThanOrEqual (NativeLocal "left") (NativeLocal "right")))) ->
                pure ()
              other ->
                assertFailure ("unexpected native isLatest declaration: " <> show other)
    , testCase "native entry lowers page runtime forms into explicit intrinsics" $
        withProjectFiles "native-entry" [("Main.clasp", interactivePageSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
          nativeResult <- nativeEntry inputPath
          case nativeResult of
            Left err ->
              assertFailure ("expected native entry to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
            Right nativeMod ->
              case findNativeDecl "home" (nativeModuleDecls nativeMod) of
                Just
                  ( NativeFunctionDecl
                      ( NativeFunction
                          _ ["req"]
                          ( NativeIntrinsic
                              ( NativePageIntrinsic
                                  (NativeLiteralExpr (NativeString "Inbox"))
                                  ( NativeIntrinsic
                                      (NativeViewAppendIntrinsic (NativeIntrinsic (NativeViewLinkIntrinsic routeLink "/lead/primary" _)) (NativeIntrinsic (NativeViewFormIntrinsic routeForm "POST" "/leads" _))
                                      )
                                  )
                              )
                          )
                      )
                    ) -> do
                      assertEqual "link route contract" "route:leadRoute" (lowerRouteContractIdentity routeLink)
                      assertEqual "form route contract" "route:createLeadRoute" (lowerRouteContractIdentity routeForm)
                other ->
                  assertFailure ("unexpected native home declaration: " <> show other)
    , testCase "native lowering keeps static record types for same-shape records" $
        case nativeSource "same-shape-records" nativeSameShapeRecordSource of
          Left err ->
            assertFailure ("expected native lowering for same-shape records to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right nativeMod -> do
            case findNativeDecl "defaultUser" (nativeModuleDecls nativeMod) of
              Just (NativeGlobalDecl (NativeGlobal _ (NativeRecord "User" [NativeField "name" (NativeLiteralExpr (NativeString "Ada")), NativeField "active" (NativeLiteralExpr (NativeBool True))]))) ->
                pure ()
              other ->
                assertFailure ("unexpected native defaultUser declaration: " <> show other)
            case findNativeDecl "defaultTeam" (nativeModuleDecls nativeMod) of
              Just (NativeGlobalDecl (NativeGlobal _ (NativeRecord "Team" [NativeField "name" (NativeLiteralExpr (NativeString "Compiler")), NativeField "active" (NativeLiteralExpr (NativeBool False))]))) ->
                pure ()
              other ->
                assertFailure ("unexpected native defaultTeam declaration: " <> show other)
            case findNativeDecl "userName" (nativeModuleDecls nativeMod) of
              Just (NativeFunctionDecl (NativeFunction _ ["user"] (NativeFieldAccess "User" (NativeLocal "user") "name"))) ->
                pure ()
              other ->
                assertFailure ("unexpected native userName declaration: " <> show other)
            case findNativeDecl "teamName" (nativeModuleDecls nativeMod) of
              Just (NativeFunctionDecl (NativeFunction _ ["team"] (NativeFieldAccess "Team" (NativeLocal "team") "name"))) ->
                pure ()
              other ->
                assertFailure ("unexpected native teamName declaration: " <> show other)
    , testCase "native lowering keeps compiler-known Result as a first-class variant model" $
        case nativeSource "result" builtinResultSource of
          Left err ->
            assertFailure ("expected builtin Result native lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right nativeMod -> do
            let abi = nativeModuleAbi nativeMod
                runtime = nativeModuleRuntime nativeMod
            case findVariantLayout "Result" (nativeAbiVariantLayouts abi) of
              Just layout ->
                assertEqual
                  "result variant layout"
                  ( NativeVariantLayout
                      "Result"
                      0
                      1
                      2
                      [ NativeConstructorLayout "Ok" 0 1 2 [NativeSlotLayout "$0" TStr NativeHandleStorage 1 1]
                      , NativeConstructorLayout "Err" 0 1 2 [NativeSlotLayout "$0" TStr NativeHandleStorage 1 1]
                      ]
                  )
                  layout
              Nothing ->
                assertFailure "expected Result variant layout"
            case findObjectLayout "Result.Ok" (nativeAbiObjectLayouts abi) of
              Just layout ->
                assertEqual
                  "result ok object layout"
                  (NativeObjectLayout "Result.Ok" NativeVariantObject 2 4 [3])
                  layout
              Nothing ->
                assertFailure "expected Result.Ok object layout"
            case findObjectLayout "Result.Err" (nativeAbiObjectLayouts abi) of
              Just layout ->
                assertEqual
                  "result err object layout"
                  (NativeObjectLayout "Result.Err" NativeVariantObject 2 4 [3])
                  layout
              Nothing ->
                assertFailure "expected Result.Err object layout"
            assertBool "expected native Result ok helper" ("clasp_rt_result_ok_string" `elem` nativeRuntimeMemorySymbols runtime)
            assertBool "expected native Result err helper" ("clasp_rt_result_err_string" `elem` nativeRuntimeMemorySymbols runtime)
            case findNativeDecl "Ok" (nativeModuleDecls nativeMod) of
              Just (NativeFunctionDecl (NativeFunction _ ["$0"] (NativeConstruct "Ok" [NativeLocal "$0"]))) ->
                pure ()
              other ->
                assertFailure ("unexpected native Ok declaration: " <> show other)
            case findNativeDecl "Err" (nativeModuleDecls nativeMod) of
              Just (NativeFunctionDecl (NativeFunction _ ["$0"] (NativeConstruct "Err" [NativeLocal "$0"]))) ->
                pure ()
              other ->
                assertFailure ("unexpected native Err declaration: " <> show other)
    , testCase "native ABI uses handle slots for handle-like record fields and variant payloads" $
        case nativeSource "native-abi" nativeAbiSource of
          Left err ->
            assertFailure ("expected native ABI lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right nativeMod -> do
            let abi = nativeModuleAbi nativeMod
            assertEqual "memory strategy" NativeReferenceCounting (nativeAbiMemoryStrategy abi)
            assertEqual
              "allocation model"
              ( NativeAllocationModel
                  { nativeAllocationImmediateRegion = NativeStackRegion
                  , nativeAllocationHandleRegion = NativeHeapRegion
                  , nativeAllocationGlobalRegion = NativeStaticRegion
                  }
              )
              (nativeAbiAllocationModel abi)
            assertEqual
              "ownership rules"
              [ NativeCallerOwnsReturns
              , NativeCalleeBorrowsArguments
              , NativeAggregatesRetainHandleFields
              , NativeGlobalsAreStaticRoots
              ]
              (nativeAbiOwnershipRules abi)
            assertEqual
              "root discovery rules"
              [ NativeDiscoverStaticRootsFromGlobals
              , NativeDiscoverStackRootsFromHandleSlots
              , NativeDiscoverHeapRootsFromObjectLayouts
              ]
              (nativeAbiRootDiscoveryRules abi)
            assertEqual
              "lifetime invariants"
              [ NativeHeapObjectsCarryLayoutAndRetainHeaders
              , NativeOnlyDeclaredRootOffsetsRetainChildren
              , NativeReleaseTraversesRootOffsetsBeforeFree
              , NativeBorrowedHandlesDoNotMutateRetainCounts
              ]
              (nativeAbiLifetimeInvariants abi)
            case findBuiltinLayout "Str" (nativeAbiBuiltinLayouts abi) of
              Just layout -> do
                assertEqual "string builtin storage" NativeHandleStorage (nativeBuiltinLayoutStorage layout)
                assertEqual "string builtin words" 1 (nativeBuiltinLayoutWordCount layout)
              Nothing ->
                assertFailure "expected Str builtin layout"
            case findBuiltinLayout "List" (nativeAbiBuiltinLayouts abi) of
              Just layout ->
                assertEqual "list builtin storage" NativeHandleStorage (nativeBuiltinLayoutStorage layout)
              Nothing ->
                assertFailure "expected List builtin layout"
            case findRecordLayout "LeadEnvelope" (nativeAbiRecordLayouts abi) of
              Just layout -> do
                assertEqual "record word count" 3 (nativeRecordLayoutWordCount layout)
                assertEqual
                  "record field layouts"
                  [ NativeFieldLayout "title" TStr NativeHandleStorage 0 1
                  , NativeFieldLayout "tags" (TList TStr) NativeHandleStorage 1 1
                  , NativeFieldLayout "owner" (TNamed "Principal") NativeHandleStorage 2 1
                  ]
                  (nativeRecordLayoutFields layout)
              Nothing ->
                assertFailure "expected LeadEnvelope layout"
            case findVariantLayout "RenderResult" (nativeAbiVariantLayouts abi) of
              Just layout -> do
                assertEqual "variant tag word" 0 (nativeVariantLayoutTagWord layout)
                assertEqual "variant payload width" 1 (nativeVariantLayoutMaxPayloadWords layout)
                assertEqual "variant total word count" 2 (nativeVariantLayoutWordCount layout)
                assertEqual
                  "variant constructor layouts"
                  [ NativeConstructorLayout "RenderedPage" 0 1 2 [NativeSlotLayout "$0" (TNamed "Page") NativeHandleStorage 1 1]
                  , NativeConstructorLayout "RenderedPrompt" 0 1 2 [NativeSlotLayout "$0" (TNamed "Prompt") NativeHandleStorage 1 1]
                  , NativeConstructorLayout "RenderedList" 0 1 2 [NativeSlotLayout "$0" (TList TStr) NativeHandleStorage 1 1]
                  , NativeConstructorLayout "RenderedOwner" 0 1 2 [NativeSlotLayout "$0" (TNamed "Principal") NativeHandleStorage 1 1]
                  , NativeConstructorLayout "RenderedFlag" 0 1 2 [NativeSlotLayout "$0" TBool NativeImmediateStorage 1 1]
                  , NativeConstructorLayout "RenderIdle" 0 0 1 []
                  ]
                  (nativeVariantLayoutConstructors layout)
              Nothing ->
                assertFailure "expected RenderResult layout"
            case findObjectLayout "LeadEnvelope" (nativeAbiObjectLayouts abi) of
              Just layout ->
                assertEqual
                  "lead envelope object layout"
                  (NativeObjectLayout "LeadEnvelope" NativeRecordObject 2 5 [2, 3, 4])
                  layout
              Nothing ->
                assertFailure "expected LeadEnvelope object layout"
            case findObjectLayout "RenderResult.RenderedPage" (nativeAbiObjectLayouts abi) of
              Just layout ->
                assertEqual
                  "rendered page object layout"
                  (NativeObjectLayout "RenderResult.RenderedPage" NativeVariantObject 2 4 [3])
                  layout
              Nothing ->
                assertFailure "expected RenderResult.RenderedPage object layout"
            case findObjectLayout "RenderResult.RenderedFlag" (nativeAbiObjectLayouts abi) of
              Just layout ->
                assertEqual
                  "rendered flag object layout"
                  (NativeObjectLayout "RenderResult.RenderedFlag" NativeVariantObject 2 4 [])
                  layout
              Nothing ->
                assertFailure "expected RenderResult.RenderedFlag object layout"
            case findObjectLayout "RenderResult.RenderIdle" (nativeAbiObjectLayouts abi) of
              Just layout ->
                assertEqual
                  "render idle object layout"
                  (NativeObjectLayout "RenderResult.RenderIdle" NativeVariantObject 2 3 [])
                  layout
              Nothing ->
                assertFailure "expected RenderResult.RenderIdle object layout"
    , testCase "native entry exposes ABI metadata for a routed module end to end" $
        withProjectFiles "native-abi-entry" [("Main.clasp", nativeAbiScenarioSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
          nativeResult <- nativeEntry inputPath
          case nativeResult of
            Left err ->
              assertFailure ("expected native entry ABI lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
            Right nativeMod -> do
              let abi = nativeModuleAbi nativeMod
              assertEqual "abi version" "clasp-native-v1" (nativeAbiVersion abi)
              assertEqual "abi word bytes" 8 (nativeAbiWordBytes abi)
              assertEqual "abi memory strategy" NativeReferenceCounting (nativeAbiMemoryStrategy abi)
              assertEqual "handle allocation region" NativeHeapRegion (nativeAllocationHandleRegion (nativeAbiAllocationModel abi))
              assertEqual
                "abi ownership rules"
                [ NativeCallerOwnsReturns
                , NativeCalleeBorrowsArguments
                , NativeAggregatesRetainHandleFields
                , NativeGlobalsAreStaticRoots
                ]
                (nativeAbiOwnershipRules abi)
              assertEqual
                "abi root discovery rules"
                [ NativeDiscoverStaticRootsFromGlobals
                , NativeDiscoverStackRootsFromHandleSlots
                , NativeDiscoverHeapRootsFromObjectLayouts
                ]
                (nativeAbiRootDiscoveryRules abi)
              assertEqual
                "abi lifetime invariants"
                [ NativeHeapObjectsCarryLayoutAndRetainHeaders
                , NativeOnlyDeclaredRootOffsetsRetainChildren
                , NativeReleaseTraversesRootOffsetsBeforeFree
                , NativeBorrowedHandlesDoNotMutateRetainCounts
                ]
                (nativeAbiLifetimeInvariants abi)
              case findVariantLayout "UiSurface" (nativeAbiVariantLayouts abi) of
                Just layout -> do
                  assertEqual "ui surface max payload words" 1 (nativeVariantLayoutMaxPayloadWords layout)
                  assertEqual
                    "ui surface payload storage"
                    [ NativeHandleStorage
                    , NativeHandleStorage
                    , NativeHandleStorage
                    , NativeHandleStorage
                    ]
                    [ nativeSlotLayoutStorage payload
                    | constructorLayout <- nativeVariantLayoutConstructors layout
                    , payload <- nativeConstructorLayoutPayloads constructorLayout
                    ]
                Nothing ->
                  assertFailure "expected UiSurface layout"
              case findRecordLayout "InboxModel" (nativeAbiRecordLayouts abi) of
                Just layout ->
                  assertEqual
                    "inbox model field storage"
                    [NativeHandleStorage, NativeHandleStorage, NativeImmediateStorage]
                    (fmap nativeFieldLayoutStorage (nativeRecordLayoutFields layout))
                Nothing ->
                  assertFailure "expected InboxModel layout"
              case findObjectLayout "InboxModel" (nativeAbiObjectLayouts abi) of
                Just layout ->
                  assertEqual
                    "inbox model root offsets"
                    (NativeObjectLayout "InboxModel" NativeRecordObject 2 5 [2, 3])
                    layout
                Nothing ->
                  assertFailure "expected InboxModel object layout"
              case findObjectLayout "UiSurface.Next" (nativeAbiObjectLayouts abi) of
                Just layout ->
                  assertEqual
                    "redirect constructor roots"
                    (NativeObjectLayout "UiSurface.Next" NativeVariantObject 2 4 [3])
                    layout
                Nothing ->
                  assertFailure "expected UiSurface.Next object layout"
    , testCase "native renderer emits a stable textual IR artifact" $
        case renderNativeSource "native-abi" nativeAbiSource of
          Left err ->
            assertFailure ("expected native IR rendering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right nativeIr -> do
            assertBool "expected native IR format header" ("format clasp-native-ir-v1" `T.isInfixOf` nativeIr)
            assertBool "expected native IR module header" ("module Main" `T.isInfixOf` nativeIr)
            assertBool "expected native IR entrypoint table" ("entrypoints [" `T.isInfixOf` nativeIr)
            assertBool "expected native IR main entrypoint" ("main{symbol=clasp_native__Main__main, kind=global, arity=0}" `T.isInfixOf` nativeIr)
            assertBool "expected native IR ABI version" ("version clasp-native-v1" `T.isInfixOf` nativeIr)
            assertBool "expected native runtime profile" ("profile compiler_backend_minimal" `T.isInfixOf` nativeIr)
            assertBool "expected native runtime artifact" ("\"runtime/clasp_runtime.rs\"" `T.isInfixOf` nativeIr)
            assertBool "expected native IR record layout" ("record_layout LeadEnvelope { words = 3, fields = [title:Str@word0/handle, tags:[Str]@word1/handle, owner:Principal@word2/handle] }" `T.isInfixOf` nativeIr)
            assertBool "expected native IR object layout" ("object_layout RenderResult.RenderedFlag { kind = variant, header_words = 2, words = 4, roots = [] }" `T.isInfixOf` nativeIr)
            assertBool "expected native IR decl emission" ("global main = string(\"ok\")" `T.isInfixOf` nativeIr)
    , testCase "native renderer emits a machine-readable module image artifact" $
        case nativeSource "native-abi" nativeAbiSource of
          Left err ->
            assertFailure ("expected native image rendering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right nativeMod -> do
            let imageJsonText = LT.toStrict (renderNativeModuleImageJson nativeMod)
            imageValue <- case eitherDecodeStrictText imageJsonText of
              Left decodeErr ->
                assertFailure ("expected native image json output to decode:\n" <> decodeErr)
              Right value ->
                pure value
            assertEqual "image format" (Just (String "clasp-native-image-v1")) (lookupObjectKey "format" imageValue)
            assertEqual "image ir format" (Just (String "clasp-native-ir-v1")) (lookupObjectKey "irFormat" imageValue)
            assertEqual "image module" (Just (String "Main")) (lookupObjectKey "module" imageValue)
            case lookupObjectKey "entrypoints" imageValue of
              Just (Array entrypoints) ->
                assertBool
                  "expected native image main entrypoint symbol"
                  (objectHasTextField [("name", "main"), ("symbol", "clasp_native__Main__main")] `any` toList entrypoints)
              _ ->
                assertFailure "expected native image entrypoints array"
            case lookupObjectKey "runtime" imageValue of
              Just runtimeValue -> do
                assertEqual "runtime profile" (Just (String "compiler_backend_minimal")) (lookupObjectKey "profile" runtimeValue)
                case lookupObjectKey "artifacts" runtimeValue of
                  Just (Array artifacts) ->
                    assertBool "expected native runtime source artifact in image" (String "runtime/clasp_runtime.rs" `elem` toList artifacts)
                  _ ->
                    assertFailure "expected runtime artifacts array"
              _ ->
                assertFailure "expected runtime object in native image"
            case lookupObjectKey "compatibility" imageValue of
              Just compatibilityValue -> do
                assertEqual "compatibility kind" (Just (String "clasp-native-compatibility-v1")) (lookupObjectKey "kind" compatibilityValue)
                case lookupObjectKey "interfaceFingerprint" compatibilityValue of
                  Just (String fingerprint) ->
                    assertBool "expected native compatibility fingerprint prefix" ("native-compat:" `T.isPrefixOf` fingerprint)
                  _ ->
                    assertFailure "expected native image interface fingerprint"
                case lookupObjectKey "acceptedPreviousFingerprints" compatibilityValue of
                  Just (Array acceptedFingerprints) ->
                    assertBool "expected accepted previous fingerprints in native image" (not (null (toList acceptedFingerprints)))
                  _ ->
                    assertFailure "expected accepted previous fingerprints array"
                case lookupObjectKey "migration" compatibilityValue of
                  Just migrationValue -> do
                    assertEqual "migration kind" (Just (String "clasp-native-migration-v1")) (lookupObjectKey "kind" migrationValue)
                    assertEqual "migration strategy" (Just (String "exact-interface-only")) (lookupObjectKey "strategy" migrationValue)
                    assertEqual "migration state type" (Just Null) (lookupObjectKey "stateType" migrationValue)
                    assertEqual "migration snapshot symbol" (Just Null) (lookupObjectKey "snapshotSymbol" migrationValue)
                    assertEqual "migration handoff symbol" (Just Null) (lookupObjectKey "handoffSymbol" migrationValue)
                  _ ->
                    assertFailure "expected migration object in native image"
              _ ->
                assertFailure "expected compatibility object in native image"
            case lookupObjectKey "decls" imageValue of
              Just (Array decls) -> do
                assertBool "expected at least one declaration in native image" (not (null (toList decls)))
                assertBool
                  "expected structured declaration bodies in native image"
                  (any
                     (\declValue ->
                        case lookupObjectKey "body" declValue of
                          Just bodyValue ->
                            lookupObjectKey "kind" bodyValue /= Nothing
                              && lookupObjectKey "bodyText" declValue /= Nothing
                          Nothing ->
                            False
                     )
                     (toList decls))
              _ ->
                assertFailure "expected declaration array in native image"
    , testCase "claspc native preserves static record types for same-shape record access end to end" $
        withProjectFiles "native-same-shape-records" [("Main.clasp", nativeSameShapeRecordSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "dist" </> "Main.native.ir"
          createDirectoryIfMissing True (takeDirectory outputPath)
          (exitCode, stdoutText, stderrText) <- runClaspc ["native", inputPath, "-o", outputPath]
          case exitCode of
            ExitFailure _ ->
              assertFailure ("expected same-shape native emission to succeed:\n" <> stdoutText <> stderrText)
            ExitSuccess -> do
              nativeIr <- TIO.readFile outputPath
              assertBool "expected typed user record literal" ("global defaultUser = record User {name = string(\"Ada\"), active = bool(true)}" `T.isInfixOf` nativeIr)
              assertBool "expected typed team record literal" ("global defaultTeam = record Team {name = string(\"Compiler\"), active = bool(false)}" `T.isInfixOf` nativeIr)
              assertBool "expected typed user field access" ("function userName(user) = field(User, local(user), name)" `T.isInfixOf` nativeIr)
              assertBool "expected typed team field access" ("function teamName(team) = field(Team, local(team), name)" `T.isInfixOf` nativeIr)
    , testCase "claspc native emits compiler-known Result layouts and constructors end to end" $
        withProjectFiles "native-result" [("Main.clasp", builtinResultSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "dist" </> "Main.native.ir"
          createDirectoryIfMissing True (takeDirectory outputPath)
          (exitCode, stdoutText, stderrText) <- runClaspc ["native", inputPath, "-o", outputPath]
          case exitCode of
            ExitFailure _ ->
              assertFailure ("expected Result native emission to succeed:\n" <> stdoutText <> stderrText)
            ExitSuccess -> do
              nativeIr <- TIO.readFile outputPath
              assertBool "expected result variant layout" ("variant_layout Result { tag_word = 0, max_payload_words = 1, words = 2, constructors = [Ok{tag_word=0, payload_words=1, words=2, payloads=[$0:Str@word1/handle]}, Err{tag_word=0, payload_words=1, words=2, payloads=[$0:Str@word1/handle]}] }" `T.isInfixOf` nativeIr)
              assertBool "expected result ok object layout" ("object_layout Result.Ok { kind = variant, header_words = 2, words = 4, roots = [3] }" `T.isInfixOf` nativeIr)
              assertBool "expected result constructors" ("function Ok($0) = construct Ok(local($0))" `T.isInfixOf` nativeIr)
              assertBool "expected result unwrap match" ("function unwrap(result) = match local(result) [Ok(value) -> local(value), Err(message) -> local(message)]" `T.isInfixOf` nativeIr)
    , testCase "native runtime exposes compiler stdlib bindings and bundled runtime artifacts" $
        case nativeSource "compiler-stdlib" compilerStdlibSource of
          Left err ->
            assertFailure ("expected compiler stdlib native lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right nativeMod -> do
            let runtime = nativeModuleRuntime nativeMod
            assertEqual "runtime profile" "compiler_backend_minimal" (nativeRuntimeProfile runtime)
            assertEqual
              "runtime artifacts"
              ["runtime/clasp_runtime.h", "runtime/clasp_runtime.rs"]
              (nativeRuntimeArtifacts runtime)
            assertBool "expected alloc symbol" ("clasp_rt_alloc_object" `elem` nativeRuntimeMemorySymbols runtime)
            assertBool "expected release symbol" ("clasp_rt_release" `elem` nativeRuntimeMemorySymbols runtime)
            case findRuntimeBinding "textSplit" (nativeRuntimeBindings runtime) of
              Just binding -> do
                assertEqual "textSplit runtime name" "textSplit" (nativeRuntimeBindingRuntimeName binding)
                assertEqual "textSplit symbol" "clasp_rt_text_split" (nativeRuntimeBindingSymbol binding)
                assertEqual "textSplit type" (TFunction [TStr, TStr] (TList TStr)) (nativeRuntimeBindingType binding)
              Nothing ->
                assertFailure "expected textSplit runtime binding"
            case findRuntimeBinding "textChars" (nativeRuntimeBindings runtime) of
              Just binding -> do
                assertEqual "textChars runtime name" "textChars" (nativeRuntimeBindingRuntimeName binding)
                assertEqual "textChars symbol" "clasp_rt_text_chars" (nativeRuntimeBindingSymbol binding)
                assertEqual "textChars type" (TFunction [TStr] (TList TStr)) (nativeRuntimeBindingType binding)
              Nothing ->
                assertFailure "expected textChars runtime binding"
            case findRuntimeBinding "readFile" (nativeRuntimeBindings runtime) of
              Just binding ->
                assertEqual "readFile symbol" "clasp_rt_read_file" (nativeRuntimeBindingSymbol binding)
              Nothing ->
                assertFailure "expected readFile runtime binding"
    , testCase "native lowering preserves list append as a dedicated intrinsic" $
        case nativeSource "list-append" listAppendSource of
          Left err ->
            assertFailure ("expected list append native lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right nativeMod ->
            case findNativeDecl "main" (nativeModuleDecls nativeMod) of
              Just (NativeGlobalDecl globalDecl) ->
                case nativeGlobalBody globalDecl of
                  NativeIntrinsic (NativeListAppendIntrinsic (NativeLocal "leading") (NativeLocal "trailing")) ->
                    pure ()
                  other ->
                    assertFailure ("unexpected native list append body: " <> show other)
              Just other ->
                assertFailure ("expected native global main declaration, got " <> show other)
              Nothing ->
                assertFailure "expected native main declaration"
    , testCase "native lowering preserves if expressions" $
        case nativeSource "if-expression" ifExpressionSource of
          Left err ->
            assertFailure ("expected if source native lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right nativeMod ->
            case findNativeDecl "main" (nativeModuleDecls nativeMod) of
              Just (NativeGlobalDecl globalDecl) ->
                case nativeGlobalBody globalDecl of
                  NativeIf (NativeLocal "isReady") (NativeLiteralExpr (NativeString "ready")) (NativeLiteralExpr (NativeString "waiting")) ->
                    pure ()
                  other ->
                    assertFailure ("unexpected native if body: " <> show other)
              Just other ->
                assertFailure ("expected native global main declaration, got " <> show other)
              Nothing ->
                assertFailure "expected native main declaration"
    , testCase "native runtime tracks json codecs and runtime boundaries for app surfaces" $
        case nativeSource "native-boundaries" nativeBoundarySource of
          Left err ->
            assertFailure ("expected native boundary lowering to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right nativeMod -> do
            let runtime = nativeModuleRuntime nativeMod
            assertEqual
              "json codecs"
              [ NativeJsonCodec (TNamed "Counter") "$encode_Counter" "$decode_Counter"
              , NativeJsonCodec (TNamed "HookAck") "$encode_HookAck" "$decode_HookAck"
              , NativeJsonCodec (TNamed "LeadRequest") "$encode_LeadRequest" "$decode_LeadRequest"
              , NativeJsonCodec (TNamed "LeadSummary") "$encode_LeadSummary" "$decode_LeadSummary"
              , NativeJsonCodec (TNamed "SearchRequest") "$encode_SearchRequest" "$decode_SearchRequest"
              , NativeJsonCodec (TNamed "SearchResponse") "$encode_SearchResponse" "$decode_SearchResponse"
              , NativeJsonCodec (TNamed "WorkerBoot") "$encode_WorkerBoot" "$decode_WorkerBoot"
              ]
              (nativeRuntimeJsonCodecs runtime)
            assertEqual
              "binary codecs"
              [ NativeBinaryCodec (TNamed "Counter") "$encode_binary_Counter" "$decode_binary_Counter" "length_prefixed"
              , NativeBinaryCodec (TNamed "HookAck") "$encode_binary_HookAck" "$decode_binary_HookAck" "length_prefixed"
              , NativeBinaryCodec (TNamed "LeadRequest") "$encode_binary_LeadRequest" "$decode_binary_LeadRequest" "length_prefixed"
              , NativeBinaryCodec (TNamed "LeadSummary") "$encode_binary_LeadSummary" "$decode_binary_LeadSummary" "length_prefixed"
              , NativeBinaryCodec (TNamed "SearchRequest") "$encode_binary_SearchRequest" "$decode_binary_SearchRequest" "length_prefixed"
              , NativeBinaryCodec (TNamed "SearchResponse") "$encode_binary_SearchResponse" "$decode_binary_SearchResponse" "length_prefixed"
              , NativeBinaryCodec (TNamed "WorkerBoot") "$encode_binary_WorkerBoot" "$decode_binary_WorkerBoot" "length_prefixed"
              ]
              (nativeRuntimeBinaryCodecs runtime)
            assertBool "expected json runtime symbol" ("clasp_rt_json_from_string" `elem` nativeRuntimeMemorySymbols runtime)
            assertBool "expected json boundary symbol" ("clasp_rt_json_to_string" `elem` nativeRuntimeMemorySymbols runtime)
            assertBool "expected binary codec runtime symbol" ("clasp_rt_binary_from_json" `elem` nativeRuntimeMemorySymbols runtime)
            assertBool "expected transport framing runtime symbol" ("clasp_rt_transport_frame" `elem` nativeRuntimeMemorySymbols runtime)
            assertEqual
              "boundary contracts"
              [ NativeRouteContract (NativeRouteBoundary "summarizeLeadRoute" "route:summarizeLeadRoute" "POST" "/lead/summary" "LeadRequest" "LeadSummary" "json" "$encode_LeadSummary" "$decode_LeadRequest")
              , NativeHookContract (NativeHookBoundary "workerStart" "hook:workerStart" "worker.start" "WorkerBoot" "HookAck" "bootstrapWorker" "$encode_HookAck" "$decode_WorkerBoot")
              , NativeToolServerContract (NativeToolServerBoundary "RepoTools" "toolserver:RepoTools" "mcp" "stdio://repo-tools" "SupportDisclosure")
              , NativeToolContract (NativeToolBoundary "searchRepo" "tool:searchRepo" "RepoTools" "search_repo" "SearchRequest" "SearchResponse" "$encode_SearchResponse" "$decode_SearchRequest")
              , NativeWorkflowContract (NativeWorkflowBoundary "CounterFlow" "workflow:CounterFlow" (TNamed "Counter") "$encode_Counter" "$decode_Counter" "clasp_native__Main__CounterFlow__handoff")
              ]
              (nativeRuntimeBoundaryContracts runtime)
            assertEqual
              "service transports"
              [ NativeServiceTransport "route" "summarizeLeadRoute" "route:summarizeLeadRoute" "request_response" "LeadRequest" "$encode_binary_LeadRequest" "$decode_binary_LeadRequest" "LeadSummary" "$encode_binary_LeadSummary" "$decode_binary_LeadSummary" "length_prefixed"
              , NativeServiceTransport "hook" "workerStart" "hook:workerStart" "event" "WorkerBoot" "$encode_binary_WorkerBoot" "$decode_binary_WorkerBoot" "HookAck" "$encode_binary_HookAck" "$decode_binary_HookAck" "length_prefixed"
              , NativeServiceTransport "tool" "searchRepo" "tool:searchRepo" "rpc" "SearchRequest" "$encode_binary_SearchRequest" "$decode_binary_SearchRequest" "SearchResponse" "$encode_binary_SearchResponse" "$decode_binary_SearchResponse" "length_prefixed"
              ]
              (nativeRuntimeServiceTransports runtime)
    , testCase "claspc native emits json codec and runtime-boundary metadata end to end" $
        withProjectFiles "native-boundaries" [("Main.clasp", nativeBoundarySource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "dist" </> "Main.native.ir"
          createDirectoryIfMissing True (takeDirectory outputPath)
          (exitCode, stdoutText, stderrText) <- runClaspc ["native", inputPath, "-o", outputPath]
          case exitCode of
            ExitFailure _ ->
              assertFailure ("expected native boundary emission to succeed:\n" <> stdoutText <> stderrText)
            ExitSuccess -> do
              nativeIr <- TIO.readFile outputPath
              assertBool "expected json codecs section" ("json_codecs [Counter{encode=$encode_Counter, decode=$decode_Counter}" `T.isInfixOf` nativeIr)
              assertBool "expected binary codecs section" ("binary_codecs [Counter{encode=$encode_binary_Counter, decode=$decode_binary_Counter, framing=length_prefixed}" `T.isInfixOf` nativeIr)
              assertBool "expected route boundary contract" ("route summarizeLeadRoute{id=route:summarizeLeadRoute, method=POST, path=\"/lead/summary\", request=LeadRequest, response=LeadSummary, response_kind=json, encode=$encode_LeadSummary, decode=$decode_LeadRequest}" `T.isInfixOf` nativeIr)
              assertBool "expected hook boundary contract" ("hook workerStart{id=hook:workerStart, event=\"worker.start\", request=WorkerBoot, response=HookAck, handler=bootstrapWorker, encode=$encode_HookAck, decode=$decode_WorkerBoot}" `T.isInfixOf` nativeIr)
              assertBool "expected tool boundary contract" ("tool searchRepo{id=tool:searchRepo, server=RepoTools, operation=\"search_repo\", request=SearchRequest, response=SearchResponse, encode=$encode_SearchResponse, decode=$decode_SearchRequest}" `T.isInfixOf` nativeIr)
              assertBool "expected workflow boundary contract" ("workflow CounterFlow{id=workflow:CounterFlow, state=Counter, checkpoint=$encode_Counter, restore=$decode_Counter, handoff=clasp_native__Main__CounterFlow__handoff}" `T.isInfixOf` nativeIr)
              assertBool "expected service transport contract" ("service_transports [route summarizeLeadRoute{id=route:summarizeLeadRoute, mode=request_response, request=LeadRequest, request_encode=$encode_binary_LeadRequest, request_decode=$decode_binary_LeadRequest, response=LeadSummary, response_encode=$encode_binary_LeadSummary, response_decode=$decode_binary_LeadSummary, framing=length_prefixed}" `T.isInfixOf` nativeIr)
    , testCase "claspc native emits workflow snapshot symbols in native image metadata" $
        withProjectFiles "native-workflow-image" [("Main.clasp", nativeBoundarySource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "dist" </> "Main.native.ir"
          createDirectoryIfMissing True (takeDirectory outputPath)
          (exitCode, stdoutText, stderrText) <- runClaspc ["native", inputPath, "-o", outputPath, "--json"]
          case exitCode of
            ExitFailure _ ->
              assertFailure ("expected workflow native image emission to succeed:\n" <> stdoutText <> stderrText)
            ExitSuccess -> do
              jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
                Left decodeErr ->
                  assertFailure ("expected workflow native json output to decode:\n" <> decodeErr)
                Right value ->
                  pure value
              imagePath <- case lookupObjectKey "image" jsonValue of
                Just (String value) -> pure (T.unpack value)
                _ -> assertFailure "expected workflow native image path in json output"
              imageJsonText <- TIO.readFile imagePath
              imageValue <- case eitherDecodeStrictText imageJsonText of
                Left decodeErr ->
                  assertFailure ("expected workflow native image to decode:\n" <> decodeErr)
                Right value ->
                  pure value
              case lookupObjectKey "compatibility" imageValue of
                Just compatibilityValue ->
                  case lookupObjectKey "migration" compatibilityValue of
                    Just migrationValue -> do
                      assertEqual "workflow migration state type" (Just (String "Counter")) (lookupObjectKey "stateType" migrationValue)
                      assertEqual "workflow migration snapshot symbol" (Just (String "$encode_Counter")) (lookupObjectKey "snapshotSymbol" migrationValue)
                      assertEqual "workflow migration handoff symbol" (Just (String "clasp_native__Main__CounterFlow__handoff")) (lookupObjectKey "handoffSymbol" migrationValue)
                    _ ->
                      assertFailure "expected workflow migration object in native image"
                _ ->
                  assertFailure "expected workflow compatibility object in native image"
    , testCase "claspc native emits a native IR artifact for compiler workloads on the hosted Clasp path" $ do
        let outputPath = "dist/compiler-parser.native.ir"
        let imagePath = replaceExtension outputPath "native.image.json"
        createDirectoryIfMissing True (takeDirectory outputPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["native", "examples/compiler-parser.clasp", "-o", outputPath, "--json"]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected compiler parser native emission to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
              Left decodeErr ->
                assertFailure ("expected native bootstrap json output to decode:\n" <> decodeErr)
              Right value ->
                pure value
            assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
            assertEqual "command" (Just (String "native")) (lookupObjectKey "command" jsonValue)
            assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
            assertEqual "image path" (Just (String (T.pack imagePath))) (lookupObjectKey "image" jsonValue)
            outputExists <- doesFileExist outputPath
            assertBool "expected native IR artifact to exist" outputExists
            imageExists <- doesFileExist imagePath
            assertBool "expected native image artifact to exist" imageExists
            nativeIr <- TIO.readFile outputPath
            assertBool "expected native IR format header" ("format clasp-native-ir-v1" `T.isInfixOf` nativeIr)
            assertBool "expected native IR entrypoint table" ("entrypoints [" `T.isInfixOf` nativeIr)
            assertBool "expected native IR parser entrypoint symbol" ("parseModuleSummary{symbol=clasp_native__Main__parseModuleSummary, kind=function, arity=1}" `T.isInfixOf` nativeIr)
            assertBool "expected native runtime section" ("runtime {" `T.isInfixOf` nativeIr)
            assertBool "expected native runtime header artifact" ("\"runtime/clasp_runtime.h\"" `T.isInfixOf` nativeIr)
            assertBool "expected native runtime textSplit binding" ("textSplit{runtime=textSplit, symbol=clasp_rt_text_split, type=Str -> Str -> [Str]}" `T.isInfixOf` nativeIr)
            assertBool "expected native runtime textPrefix binding" ("textPrefix{runtime=textPrefix, symbol=clasp_rt_text_prefix, type=Str -> Str -> Result}" `T.isInfixOf` nativeIr)
            assertBool "expected parser state record layout" ("record_layout ParserState { words = 4, fields = [moduleName:Str@word0/handle, imports:Str@word1/handle, signatures:Str@word2/handle, declarations:Str@word3/handle] }" `T.isInfixOf` nativeIr)
            assertBool "expected parser variant object layout" ("object_layout LineKind.ModuleLine { kind = variant, header_words = 2, words = 4, roots = [3] }" `T.isInfixOf` nativeIr)
            assertBool "expected parser function emission" ("function parseModuleSummary(source) =" `T.isInfixOf` nativeIr)
            imageJsonText <- TIO.readFile imagePath
            imageValue <- case eitherDecodeStrictText imageJsonText of
              Left decodeErr ->
                assertFailure ("expected native image artifact to decode:\n" <> decodeErr)
              Right value ->
                pure value
            assertEqual "image format" (Just (String "clasp-native-image-v1")) (lookupObjectKey "format" imageValue)
            case lookupObjectKey "entrypoints" imageValue of
              Just (Array entrypoints) ->
                assertBool
                  "expected compiler parser main entrypoint symbol"
                  (objectHasTextField [("name", "main"), ("symbol", "clasp_native__Main__main")] `any` toList entrypoints)
              _ ->
                assertFailure "expected native image entrypoints array"
            case lookupObjectKey "runtime" imageValue of
              Just runtimeValue ->
                assertEqual "image runtime profile" (Just (String "compiler_backend_minimal")) (lookupObjectKey "profile" runtimeValue)
              _ ->
                assertFailure "expected native image runtime object"
            case lookupObjectKey "compatibility" imageValue of
              Just compatibilityValue ->
                assertEqual "image compatibility kind" (Just (String "clasp-native-compatibility-v1")) (lookupObjectKey "kind" compatibilityValue)
              _ ->
                assertFailure "expected native image compatibility object"
            case lookupObjectKey "decls" imageValue of
              Just (Array decls) ->
                assertBool
                  "expected compiler native image decl bodies to stay machine-readable"
                  (any
                     (\declValue ->
                        case lookupObjectKey "body" declValue of
                          Just bodyValue ->
                            lookupObjectKey "kind" bodyValue /= Nothing
                          Nothing ->
                            False
                     )
                     (toList decls))
              _ ->
                assertFailure "expected native image declaration array"
    , testCase "claspc native emits a machine-readable image artifact on the hosted Clasp path" $ do
        let outputPath = "dist/compiler-hosted-clasp.native.ir"
        let imagePath = replaceExtension outputPath "native.image.json"
        createDirectoryIfMissing True (takeDirectory outputPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["native", "src/Main.clasp", "-o", outputPath, "--compiler=clasp", "--json"]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected hosted primary compiler native emission to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
              Left decodeErr ->
                assertFailure ("expected hosted primary native json output to decode:\n" <> decodeErr)
              Right value ->
                pure value
            assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
            assertEqual "command" (Just (String "native")) (lookupObjectKey "command" jsonValue)
            assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
            assertEqual "image path" (Just (String (T.pack imagePath))) (lookupObjectKey "image" jsonValue)
            outputExists <- doesFileExist outputPath
            assertBool "expected hosted primary native IR artifact to exist" outputExists
            imageExists <- doesFileExist imagePath
            assertBool "expected hosted primary native image artifact to exist" imageExists
            imageJsonText <- TIO.readFile imagePath
            imageValue <- case eitherDecodeStrictText imageJsonText of
              Left decodeErr ->
                assertFailure ("expected hosted primary native image artifact to decode:\n" <> decodeErr)
              Right value ->
                pure value
            assertEqual "image format" (Just (String "clasp-native-image-v1")) (lookupObjectKey "format" imageValue)
            case lookupObjectKey "runtime" imageValue of
              Just runtimeValue ->
                assertEqual "image runtime profile" (Just (String "compiler_backend_minimal")) (lookupObjectKey "profile" runtimeValue)
              _ ->
                assertFailure "expected hosted primary native image runtime object"
            case lookupObjectKey "decls" imageValue of
              Just (Array decls) ->
                assertBool
                  "expected hosted primary native image decl bodies to stay machine-readable"
                  (any
                     (\declValue ->
                        case lookupObjectKey "body" declValue of
                          Just bodyValue ->
                            lookupObjectKey "kind" bodyValue /= Nothing
                          Nothing ->
                            False
                     )
                     (toList decls))
              _ ->
                assertFailure "expected hosted primary native image declaration array"
    , testCase "claspc native emits workflow migration metadata on the hosted Clasp path for backend workflows" $ do
        let outputPath = "dist/durable-workflow-clasp.native.ir"
        let imagePath = replaceExtension outputPath "native.image.json"
        createDirectoryIfMissing True (takeDirectory outputPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["native", "examples/durable-workflow/Main.clasp", "-o", outputPath, "--compiler=clasp", "--json"]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected durable workflow native emission on the hosted Clasp path to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            imageJsonText <- TIO.readFile imagePath
            imageValue <- case eitherDecodeStrictText imageJsonText of
              Left decodeErr ->
                assertFailure ("expected hosted durable workflow native image to decode:\n" <> decodeErr)
              Right value ->
                pure value
            case lookupObjectKey "compatibility" imageValue of
              Just compatibilityValue ->
                case lookupObjectKey "migration" compatibilityValue of
                  Just migrationValue -> do
                    assertEqual "workflow migration state type" (Just (String "Counter")) (lookupObjectKey "stateType" migrationValue)
                    assertEqual "workflow migration snapshot symbol" (Just (String "$encode_Counter")) (lookupObjectKey "snapshotSymbol" migrationValue)
                    assertEqual "workflow migration handoff symbol" (Just (String "clasp_native__Main__CounterFlow__handoff")) (lookupObjectKey "handoffSymbol" migrationValue)
                  _ ->
                    assertFailure "expected hosted durable workflow migration object"
              _ ->
                assertFailure "expected hosted durable workflow compatibility object"
            case lookupObjectKey "runtime" imageValue of
              Just runtimeValue -> do
                case lookupObjectKey "jsonCodecs" runtimeValue of
                  Just (Array codecs) ->
                    assertBool
                      "expected workflow state json codec in hosted durable workflow image"
                      (objectHasTextField [("type", "Counter"), ("encode", "$encode_Counter"), ("decode", "$decode_Counter")] `any` toList codecs)
                  _ ->
                    assertFailure "expected hosted durable workflow json codecs array"
                case lookupObjectKey "boundaries" runtimeValue of
                  Just (Array boundaries) ->
                    assertBool
                      "expected workflow boundary in hosted durable workflow image"
                      (objectHasTextField [("kind", "workflow"), ("name", "CounterFlow"), ("id", "workflow:CounterFlow"), ("state", "Counter"), ("checkpoint", "$encode_Counter"), ("restore", "$decode_Counter"), ("handoff", "clasp_native__Main__CounterFlow__handoff")] `any` toList boundaries)
                  _ ->
                    assertFailure "expected hosted durable workflow boundaries array"
              _ ->
                assertFailure "expected hosted durable workflow runtime object"
    , testCase "claspc native emits the compiler text traversal helper when a workload uses textChars" $
        withProjectFiles "native-text-chars" [("Main.clasp", textCharsNativeSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "dist" </> "Main.native.ir"
          createDirectoryIfMissing True (takeDirectory outputPath)
          (exitCode, stdoutText, stderrText) <- runClaspc ["native", inputPath, "-o", outputPath]
          case exitCode of
            ExitFailure _ ->
              assertFailure ("expected native textChars emission to succeed:\n" <> stdoutText <> stderrText)
            ExitSuccess -> do
              nativeIr <- TIO.readFile outputPath
              assertBool "expected native runtime textChars binding" ("textChars{runtime=textChars, symbol=clasp_rt_text_chars, type=Str -> [Str]}" `T.isInfixOf` nativeIr)
              assertBool "expected textChars call in emitted native function" ("function charsSummary(value) = call(local(textChars), [local(value)])" `T.isInfixOf` nativeIr)
    , testCase "native runtime bundle files declare the compiler/backend runtime surface" $ do
        headerExists <- doesFileExist ("runtime" </> "clasp_runtime.h")
        sourceExists <- doesFileExist ("runtime" </> "clasp_runtime.rs")
        harnessExists <- doesFileExist ("runtime" </> "test_native_image.c")
        assertBool "expected native runtime header to exist" headerExists
        assertBool "expected native runtime source to exist" sourceExists
        assertBool "expected native runtime smoke harness to exist" harnessExists
        header <- TIO.readFile ("runtime" </> "clasp_runtime.h")
        source <- TIO.readFile ("runtime" </> "clasp_runtime.rs")
        harness <- TIO.readFile ("runtime" </> "test_native_image.c")
        assertBool "expected runtime init export" ("void clasp_rt_init(ClaspRtRuntime *runtime);" `T.isInfixOf` header)
        assertBool "expected runtime shutdown export" ("void clasp_rt_shutdown(ClaspRtRuntime *runtime);" `T.isInfixOf` header)
        assertBool "expected runtime object allocator export" ("ClaspRtObject *clasp_rt_alloc_object(const ClaspRtObjectLayout *layout);" `T.isInfixOf` header)
        assertBool "expected runtime json helper export" ("ClaspRtJson *clasp_rt_json_from_string(ClaspRtString *value);" `T.isInfixOf` header)
        assertBool "expected runtime bytes helper export" ("ClaspRtBytes *clasp_rt_bytes_new(size_t length);" `T.isInfixOf` header)
        assertBool "expected runtime binary codec export" ("ClaspRtBytes *clasp_rt_binary_from_json(ClaspRtJson *value);" `T.isInfixOf` header)
        assertBool "expected runtime transport export" ("ClaspRtBytes *clasp_rt_transport_frame(ClaspRtBytes *payload);" `T.isInfixOf` header)
        assertBool "expected native image validation export" ("bool clasp_rt_native_image_validate(ClaspRtJson *image);" `T.isInfixOf` header)
        assertBool "expected native image module export" ("ClaspRtResultString *clasp_rt_native_image_module_name(ClaspRtJson *image);" `T.isInfixOf` header)
        assertBool "expected native image decl count export" ("size_t clasp_rt_native_image_decl_count(ClaspRtJson *image);" `T.isInfixOf` header)
        assertBool "expected native module image load export" ("ClaspRtNativeModuleImage *clasp_rt_native_module_image_load(ClaspRtJson *image);" `T.isInfixOf` header)
        assertBool "expected native module image interface fingerprint export" ("ClaspRtString *clasp_rt_native_module_image_interface_fingerprint(ClaspRtNativeModuleImage *image);" `T.isInfixOf` header)
        assertBool "expected native module image migration strategy export" ("ClaspRtString *clasp_rt_native_module_image_migration_strategy(ClaspRtNativeModuleImage *image);" `T.isInfixOf` header)
        assertBool "expected native module image state type export" ("ClaspRtString *clasp_rt_native_module_image_state_type(ClaspRtNativeModuleImage *image);" `T.isInfixOf` header)
        assertBool "expected native module image snapshot symbol export" ("ClaspRtString *clasp_rt_native_module_image_snapshot_symbol(ClaspRtNativeModuleImage *image);" `T.isInfixOf` header)
        assertBool "expected native module image handoff symbol export" ("ClaspRtString *clasp_rt_native_module_image_handoff_symbol(ClaspRtNativeModuleImage *image);" `T.isInfixOf` header)
        assertBool "expected native module image export query export" ("bool clasp_rt_native_module_image_has_export(ClaspRtNativeModuleImage *image, ClaspRtString *export_name);" `T.isInfixOf` header)
        assertBool "expected native module image fingerprint acceptance export" ("bool clasp_rt_native_module_image_accepts_previous_fingerprint(" `T.isInfixOf` header)
        assertBool "expected native module image entrypoint symbol export" ("ClaspRtResultString *clasp_rt_native_module_image_entrypoint_symbol(" `T.isInfixOf` header)
        assertBool "expected native module activation export" ("bool clasp_rt_activate_native_module_image(ClaspRtRuntime *runtime, ClaspRtNativeModuleImage *image);" `T.isInfixOf` header)
        assertBool "expected active generation export" ("size_t clasp_rt_active_native_module_generation(ClaspRtRuntime *runtime, ClaspRtString *module_name);" `T.isInfixOf` header)
        assertBool "expected active generation count export" ("size_t clasp_rt_active_native_module_generation_count(ClaspRtRuntime *runtime, ClaspRtString *module_name);" `T.isInfixOf` header)
        assertBool "expected active generation query export" ("bool clasp_rt_has_active_native_module_generation(" `T.isInfixOf` header)
        assertBool "expected generation retirement export" ("bool clasp_rt_retire_native_module_generation(" `T.isInfixOf` header)
        assertBool "expected native dispatch export" ("ClaspRtResultString *clasp_rt_resolve_native_dispatch(" `T.isInfixOf` header)
        assertBool "expected generation-specific native dispatch export" ("ClaspRtResultString *clasp_rt_resolve_native_dispatch_generation(" `T.isInfixOf` header)
        assertBool "expected native entrypoint bind export" ("bool clasp_rt_bind_native_entrypoint(" `T.isInfixOf` header)
        assertBool "expected native entrypoint symbol bind export" ("bool clasp_rt_bind_native_entrypoint_symbol(" `T.isInfixOf` header)
        assertBool "expected native snapshot bind export" ("bool clasp_rt_bind_native_snapshot(" `T.isInfixOf` header)
        assertBool "expected native snapshot symbol bind export" ("bool clasp_rt_bind_native_snapshot_symbol(" `T.isInfixOf` header)
        assertBool "expected native handoff bind export" ("bool clasp_rt_bind_native_handoff(" `T.isInfixOf` header)
        assertBool "expected native handoff symbol bind export" ("bool clasp_rt_bind_native_handoff_symbol(" `T.isInfixOf` header)
        assertBool "expected native entrypoint resolve export" ("ClaspRtNativeEntrypointFn clasp_rt_resolve_native_entrypoint(" `T.isInfixOf` header)
        assertBool "expected generation-specific native entrypoint resolve export" ("ClaspRtNativeEntrypointFn clasp_rt_resolve_native_entrypoint_generation(" `T.isInfixOf` header)
        assertBool "expected native snapshot resolve export" ("ClaspRtNativeSnapshotFn clasp_rt_resolve_native_snapshot(" `T.isInfixOf` header)
        assertBool "expected native handoff resolve export" ("ClaspRtNativeHandoffFn clasp_rt_resolve_native_handoff(" `T.isInfixOf` header)
        assertBool "expected native state snapshot store export" ("bool clasp_rt_store_native_module_state_snapshot(" `T.isInfixOf` header)
        assertBool "expected native generation state type export" ("ClaspRtString *clasp_rt_native_module_generation_state_type(" `T.isInfixOf` header)
        assertBool "expected native generation state snapshot export" ("ClaspRtJson *clasp_rt_native_module_generation_state_snapshot(" `T.isInfixOf` header)
        assertBool "expected native dispatch call export" ("ClaspRtHeader *clasp_rt_call_native_dispatch(" `T.isInfixOf` header)
        assertBool "expected generation-specific native dispatch call export" ("ClaspRtHeader *clasp_rt_call_native_dispatch_generation(" `T.isInfixOf` header)
        assertBool "expected runtime stdlib text split export" ("ClaspRtStringList *clasp_rt_text_split(ClaspRtString *value, ClaspRtString *separator);" `T.isInfixOf` header)
        assertBool "expected runtime stdlib text chars export" ("ClaspRtStringList *clasp_rt_text_chars(ClaspRtString *value);" `T.isInfixOf` header)
        assertBool "expected runtime safe module image helpers" ("impl ClaspRtNativeModuleImage {" `T.isInfixOf` source)
        assertBool "expected runtime safe registry helpers" ("impl ClaspRtRuntime {" `T.isInfixOf` source)
        assertBool "expected runtime safe activation helper" ("fn activate_native_module_image(&mut self, image: NonNull<ClaspRtNativeModuleImage>) -> bool {" `T.isInfixOf` source)
        assertBool "expected runtime safe retirement helper" ("fn retire_native_module_generation(&mut self, module_name: *mut ClaspRtString, generation: usize) -> bool {" `T.isInfixOf` source)
        assertBool "expected runtime safe snapshot helper" ("fn store_native_module_state_snapshot(" `T.isInfixOf` source)
        assertBool "expected runtime shutdown implementation" ("pub unsafe extern \"C\" fn clasp_rt_shutdown(runtime: *mut ClaspRtRuntime)" `T.isInfixOf` source)
        assertBool "expected runtime static root registration" ("pub unsafe extern \"C\" fn clasp_rt_register_static_root(runtime: *mut ClaspRtRuntime, slot: *mut *mut ClaspRtHeader)" `T.isInfixOf` source)
        assertBool "expected runtime json helper implementation" ("pub unsafe extern \"C\" fn clasp_rt_json_from_string(value: *mut ClaspRtString) -> *mut ClaspRtJson" `T.isInfixOf` source)
        assertBool "expected runtime binary codec implementation" ("pub unsafe extern \"C\" fn clasp_rt_binary_from_json(value: *mut ClaspRtJson) -> *mut ClaspRtBytes" `T.isInfixOf` source)
        assertBool "expected runtime transport unframe implementation" ("pub unsafe extern \"C\" fn clasp_rt_transport_unframe(frame: *mut ClaspRtBytes) -> *mut ClaspRtBytes" `T.isInfixOf` source)
        assertBool "expected native image validation implementation" ("pub unsafe extern \"C\" fn clasp_rt_native_image_validate(image: *mut ClaspRtJson) -> bool" `T.isInfixOf` source)
        assertBool "expected native image artifact query implementation" ("pub unsafe extern \"C\" fn clasp_rt_native_image_has_runtime_artifact(" `T.isInfixOf` source)
        assertBool "expected native module image load implementation" ("pub unsafe extern \"C\" fn clasp_rt_native_module_image_load(" `T.isInfixOf` source)
        assertBool "expected native module image interface fingerprint implementation" ("pub unsafe extern \"C\" fn clasp_rt_native_module_image_interface_fingerprint(" `T.isInfixOf` source)
        assertBool "expected native module image migration strategy implementation" ("pub unsafe extern \"C\" fn clasp_rt_native_module_image_migration_strategy(" `T.isInfixOf` source)
        assertBool "expected native module image state type implementation" ("pub unsafe extern \"C\" fn clasp_rt_native_module_image_state_type(" `T.isInfixOf` source)
        assertBool "expected native module image snapshot symbol implementation" ("pub unsafe extern \"C\" fn clasp_rt_native_module_image_snapshot_symbol(" `T.isInfixOf` source)
        assertBool "expected native module image handoff symbol implementation" ("pub unsafe extern \"C\" fn clasp_rt_native_module_image_handoff_symbol(" `T.isInfixOf` source)
        assertBool "expected native module image export query implementation" ("pub unsafe extern \"C\" fn clasp_rt_native_module_image_has_export(" `T.isInfixOf` source)
        assertBool "expected native module image fingerprint acceptance implementation" ("pub unsafe extern \"C\" fn clasp_rt_native_module_image_accepts_previous_fingerprint(" `T.isInfixOf` source)
        assertBool "expected native module image entrypoint symbol implementation" ("pub unsafe extern \"C\" fn clasp_rt_native_module_image_entrypoint_symbol(" `T.isInfixOf` source)
        assertBool "expected native module activation implementation" ("pub unsafe extern \"C\" fn clasp_rt_activate_native_module_image(" `T.isInfixOf` source)
        assertBool "expected active generation implementation" ("pub unsafe extern \"C\" fn clasp_rt_active_native_module_generation(" `T.isInfixOf` source)
        assertBool "expected active generation count implementation" ("pub unsafe extern \"C\" fn clasp_rt_active_native_module_generation_count(" `T.isInfixOf` source)
        assertBool "expected active generation query implementation" ("pub unsafe extern \"C\" fn clasp_rt_has_active_native_module_generation(" `T.isInfixOf` source)
        assertBool "expected generation retirement implementation" ("pub unsafe extern \"C\" fn clasp_rt_retire_native_module_generation(" `T.isInfixOf` source)
        assertBool "expected native dispatch implementation" ("pub unsafe extern \"C\" fn clasp_rt_resolve_native_dispatch(" `T.isInfixOf` source)
        assertBool "expected generation-specific native dispatch implementation" ("pub unsafe extern \"C\" fn clasp_rt_resolve_native_dispatch_generation(" `T.isInfixOf` source)
        assertBool "expected native entrypoint bind implementation" ("pub unsafe extern \"C\" fn clasp_rt_bind_native_entrypoint(" `T.isInfixOf` source)
        assertBool "expected native entrypoint symbol bind implementation" ("pub unsafe extern \"C\" fn clasp_rt_bind_native_entrypoint_symbol(" `T.isInfixOf` source)
        assertBool "expected native snapshot bind implementation" ("pub unsafe extern \"C\" fn clasp_rt_bind_native_snapshot(" `T.isInfixOf` source)
        assertBool "expected native snapshot symbol bind implementation" ("pub unsafe extern \"C\" fn clasp_rt_bind_native_snapshot_symbol(" `T.isInfixOf` source)
        assertBool "expected native handoff bind implementation" ("pub unsafe extern \"C\" fn clasp_rt_bind_native_handoff(" `T.isInfixOf` source)
        assertBool "expected native handoff symbol bind implementation" ("pub unsafe extern \"C\" fn clasp_rt_bind_native_handoff_symbol(" `T.isInfixOf` source)
        assertBool "expected native entrypoint resolve implementation" ("pub unsafe extern \"C\" fn clasp_rt_resolve_native_entrypoint(" `T.isInfixOf` source)
        assertBool "expected generation-specific native entrypoint resolve implementation" ("pub unsafe extern \"C\" fn clasp_rt_resolve_native_entrypoint_generation(" `T.isInfixOf` source)
        assertBool "expected native snapshot resolve implementation" ("pub unsafe extern \"C\" fn clasp_rt_resolve_native_snapshot(" `T.isInfixOf` source)
        assertBool "expected native handoff resolve implementation" ("pub unsafe extern \"C\" fn clasp_rt_resolve_native_handoff(" `T.isInfixOf` source)
        assertBool "expected native state snapshot store implementation" ("pub unsafe extern \"C\" fn clasp_rt_store_native_module_state_snapshot(" `T.isInfixOf` source)
        assertBool "expected native generation state type implementation" ("pub unsafe extern \"C\" fn clasp_rt_native_module_generation_state_type(" `T.isInfixOf` source)
        assertBool "expected native generation state snapshot implementation" ("pub unsafe extern \"C\" fn clasp_rt_native_module_generation_state_snapshot(" `T.isInfixOf` source)
        assertBool "expected native dispatch call implementation" ("pub unsafe extern \"C\" fn clasp_rt_call_native_dispatch(" `T.isInfixOf` source)
        assertBool "expected generation-specific native dispatch call implementation" ("pub unsafe extern \"C\" fn clasp_rt_call_native_dispatch_generation(" `T.isInfixOf` source)
        assertBool "expected runtime object destroy path" ("unsafe extern \"C\" fn destroy_object(runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader)" `T.isInfixOf` source)
        assertBool "expected runtime text chars implementation" ("pub unsafe extern \"C\" fn clasp_rt_text_chars(value: *mut ClaspRtString) -> *mut ClaspRtStringList" `T.isInfixOf` source)
        assertBool "expected runtime file read helper" ("pub unsafe extern \"C\" fn clasp_rt_read_file(path: *mut ClaspRtString) -> *mut ClaspRtResultString" `T.isInfixOf` source)
        assertBool "expected generic runtime list layout" ("const CLASP_RT_LAYOUT_LIST_VALUE: u32 = 11;" `T.isInfixOf` source)
        assertBool "expected interpreted if support" ("ClaspRtInterpretedExpr::If(" `T.isInfixOf` source)
        assertBool "expected interpreted compare support" ("ClaspRtInterpretedExpr::Compare(" `T.isInfixOf` source)
        assertBool "expected interpreted list append intrinsic" ("ClaspRtInterpretedIntrinsic::ListAppend" `T.isInfixOf` source)
        assertBool "expected native runtime smoke harness summary" ("native-image-ok module=%s profile=%s fingerprint=%s next_fingerprint=%s handoff_strategy=%s state_type=%s snapshot_symbol=%s handoff_symbol=%s snapshot=%s snapshot_hook=%d handoff=%d active_modules=%zu latest_generation=%zu overlap=%zu rejected_incompatible_upgrade=%d symbol=%s dispatch=%s old_dispatch=%s call=%s old_call=%s exports=%zu decls=%zu" `T.isInfixOf` harness)
    ]

docsTests :: TestTree
docsTests =
  testGroup
    "docs"
    [ testCase "v0 spec documents compiler-known Option and Result bootstrap types" $ do
        spec <- TIO.readFile ("docs" </> "clasp-spec-v0.md")
        assertBool "expected Option bootstrap type note" ("`Option` is compiler-known in `v0` as a bootstrap absence model equivalent to `type Option = Some Str | None`." `T.isInfixOf` spec)
        assertBool "expected Result bootstrap type note" ("`Result` is also compiler-known in `v0` as a bootstrap failure model equivalent to `type Result = Ok Str | Err Str`." `T.isInfixOf` spec)
    , testCase "v0 spec documents the compiler-support text traversal helper" $ do
        spec <- TIO.readFile ("docs" </> "clasp-spec-v0.md")
        assertBool "expected textChars bootstrap helper" ("- `textChars : Str -> [Str]`" `T.isInfixOf` spec)
    , testCase "v0 spec documents the bootstrap native image sidecar" $ do
        spec <- TIO.readFile ("docs" </> "clasp-spec-v0.md")
        assertBool "expected bootstrap native image artifact note" ("- `claspc native` currently writes an inspectable `.native.ir` artifact and a companion `.native.image.json` artifact on both the bootstrap-native path and the Clasp-primary native path for supported programs. The image carries generated export entrypoint symbols, a native compatibility fingerprint, and explicit migration metadata including workflow snapshot and handoff symbols so the Rust runtime can activate compatible module generations, require declared typed state snapshots plus state-handoff hooks for type-surface upgrades, resolve those symbols, bind native entrypoints, dispatch the newest live generation, and retire older generations without reparsing debug text." `T.isInfixOf` spec)
        assertBool "expected compiler image runtime execution note" ("- The Rust native runtime can already execute machine-readable compiler-image exports such as the hosted compiler's `compileSourceText` directly from structured native image bodies without depending on `bodyText` reparsing or a JS host at execution time." `T.isInfixOf` spec)
    , testCase "v0 spec documents homogeneous list literals and contextual empty lists" $ do
        spec <- TIO.readFile ("docs" </> "clasp-spec-v0.md")
        assertBool "expected homogeneous list rule" ("List literals use the same brackets and must stay homogeneous." `T.isInfixOf` spec)
        assertBool "expected empty list context rule" ("Empty lists need surrounding type information from an annotation or another checked context:" `T.isInfixOf` spec)
    , testCase "v0 spec documents type parameters for records, ADTs, and functions" $ do
        spec <- TIO.readFile ("docs" </> "clasp-spec-v0.md")
        assertBool "expected generic record example" ("record Box a = { value : a }" `T.isInfixOf` spec)
        assertBool "expected generic function example" ("unwrapOr : Option a -> a -> a" `T.isInfixOf` spec)
        assertBool "expected generic grammar" ("type-decl   ::= \"type\" upper-ident lower-ident*" `T.isInfixOf` spec)
    , testCase "self-hosting plan defines the subset and bootstrap boundary" $ do
        plan <- TIO.readFile ("docs" </> "clasp-self-hosting-plan.md")
        assertBool "expected self-hosting subset section" ("## Self-Hosting Subset" `T.isInfixOf` plan)
        assertBool "expected subset to include compiler-oriented language forms" ("- package-aware modules and imports" `T.isInfixOf` plan)
        assertBool "expected subset to exclude app-facing runtime features" ("- workflow, worker, or durable execution features" `T.isInfixOf` plan)
        assertBool "expected bootstrap boundary section" ("## Bootstrap And Primary Compiler Boundary" `T.isInfixOf` plan)
        assertBool "expected bootstrap compiler responsibility" ("- remaining the release-producing and fallback compiler until stage0/stage1/stage2 checks pass" `T.isInfixOf` plan)
        assertBool "expected primary compiler responsibility" ("- staying within the self-hosting subset until `SH-010` promotes it to the default compiler path" `T.isInfixOf` plan)
        assertBool "expected subset admission rule" ("A language or runtime feature enters the self-hosting subset only when:" `T.isInfixOf` plan)
    , testCase "self-hosting plan defines the native runtime boundary and language choice" $ do
        plan <- TIO.readFile ("docs" </> "clasp-self-hosting-plan.md")
        assertBool "expected native runtime boundary section" ("## Native Runtime Boundary" `T.isInfixOf` plan)
        assertBool "expected kernel module loading rule" ("- loading compiled module images into native module descriptors with stable export tables and runtime activation records while maintaining a stable native ABI between generated code and the runtime" `T.isInfixOf` plan)
        assertBool "expected kernel image validation rule" ("- validating machine-readable native module image headers, runtime profile metadata, and bundled runtime artifacts before binding or dispatch" `T.isInfixOf` plan)
        assertBool "expected kernel entrypoint binding rule" ("- binding stable native entrypoints plus workflow snapshot and handoff hooks onto activated module exports through generated image-declared symbols instead of reparsing debug IR" `T.isInfixOf` plan)
        assertBool "expected kernel compatibility rule" ("- compatibility checks over native interface fingerprints so a new generation can overlap only when it explicitly accepts the previous generation's type surface" `T.isInfixOf` plan)
        assertBool "expected kernel handoff rule" ("- explicit migration metadata, typed state snapshot payloads, and runtime-bound handoff hooks so changed type surfaces can retire older generations only after a supervised state handoff succeeds" `T.isInfixOf` plan)
        assertBool "expected versioned overlap rule" ("- versioned dispatch indirection so old and new module generations can overlap during supervised upgrades, with default dispatch targeting the newest live generation until older generations are retired" `T.isInfixOf` plan)
        assertBool "expected kernel supervision rule" ("- supervision-tree execution, restart rules, operator handoff, rollback, and kill-switch enforcement" `T.isInfixOf` plan)
        assertBool "expected parser exclusion" ("- parser, checker, lowering, emitters, or other compiler-pass logic" `T.isInfixOf` plan)
        assertBool "expected implementation language section" ("## Native Runtime Implementation Language" `T.isInfixOf` plan)
        assertBool "expected Rust runtime decision" ("The lowest native runtime layer should stay `Rust`, not `Haskell`." `T.isInfixOf` plan)
        assertBool "expected Haskell demotion to bootstrap tooling" ("`Haskell` still makes sense for the bootstrap compiler, recovery tooling, and offline developer tooling" `T.isInfixOf` plan)
    , testCase "roadmap defines the first native memory-management model" $ do
        roadmap <- TIO.readFile ("docs" </> "clasp-roadmap.md")
        assertBool "expected native memory model section" ("### First Native Memory Model" `T.isInfixOf` roadmap)
        assertBool "expected reference-counted handle strategy" ("- handle-backed values use deterministic reference counting" `T.isInfixOf` roadmap)
        assertBool "expected stack and heap allocation split" ("- immediate values and activation records stay in stack storage while handle-backed values allocate in heap storage" `T.isInfixOf` roadmap)
        assertBool "expected ownership rule for calls" ("- callees borrow incoming arguments and transfer returned handle ownership back to the caller" `T.isInfixOf` roadmap)
        assertBool "expected ownership rule for globals" ("- module globals stay in static storage and act as permanent roots for shared runtime state" `T.isInfixOf` roadmap)
        assertBool "expected object header layout" ("- every heap object starts with a two-word header containing a layout identifier and retain count before the object payload" `T.isInfixOf` roadmap)
        assertBool "expected root discovery rule" ("- root discovery walks static globals, active stack handle slots, and layout-declared child offsets inside heap objects" `T.isInfixOf` roadmap)
        assertBool "expected release invariant" ("- retain and release only visit handle slots declared by the object layout, and release walks those child roots before freeing storage" `T.isInfixOf` roadmap)
        assertBool "expected runtime bundle rule" ("- ship a small native runtime bundle with explicit retain/release helpers, static-root registration, generic object allocation, and compiler-support text/path/file primitives" `T.isInfixOf` roadmap)
        assertBool "expected native image rule" ("- emit both inspectable `.native.ir` output and a machine-readable `.native.image.json` module image so the kernel can load, validate, compare compatibility fingerprints, require explicit generated snapshot plus handoff symbols and typed state snapshot payloads for changed interfaces, activate, resolve generated export symbols, bind native entrypoints, dispatch the newest live generation, and retire drained generations without depending on debug text" `T.isInfixOf` roadmap)
        assertBool "expected compiler image execution rule" ("- make the kernel execute structured compiler-image exports directly so compiler entrypoints like `compileSourceText` stop depending on a JS host at runtime" `T.isInfixOf` roadmap)
        assertBool "expected Rust kernel rule" ("- keep the lowest native runtime layer in `Rust` behind a narrow C-shaped ABI instead of embedding the Haskell RTS into production server/runtime targets" `T.isInfixOf` roadmap)
        assertBool "expected Clasp-above-kernel rule" ("- build higher-level supervision, upgrade, workflow, and compiler behavior in `Clasp` on top of that kernel rather than growing the kernel into a second application platform" `T.isInfixOf` roadmap)
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
    , testCase "compile emits compiler-known Result constructors and evaluates matches" $
        case compileSource "result" builtinResultSource of
          Left err ->
            assertFailure ("expected builtin Result compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected Ok constructor function" ("export function Ok" `T.isInfixOf` emitted)
            assertBool "expected Err constructor function" ("export function Err" `T.isInfixOf` emitted)
            let compiledPath = "dist/result-expression.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(compiledModule.main);"
                , "console.log(compiledModule.unwrap(compiledModule.Err(\"problem\")));"
                ]
            assertEqual "expected Result runtime output" "done\nproblem" runtimeOutput
    , testCase "compile emits compiler-known Option constructors and evaluates matches" $
        case compileSource "option" builtinOptionSource of
          Left err ->
            assertFailure ("expected builtin Option compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected Some constructor function" ("export function Some" `T.isInfixOf` emitted)
            assertBool "expected None constructor value" ("export const None" `T.isInfixOf` emitted)
            let compiledPath = "dist/option-expression.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(compiledModule.main);"
                , "console.log(compiledModule.unwrap(compiledModule.None));"
                ]
            assertEqual "expected Option runtime output" "present\nmissing" runtimeOutput
    , testCase "compile emits compiler-known self-hosting stdlib helpers and evaluates them end-to-end" $
        case compileSource "compiler-stdlib" compilerStdlibSource of
          Left err ->
            assertFailure ("expected compiler stdlib compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected textJoin host binding" ("\"textJoin\"" `T.isInfixOf` emitted)
            assertBool "expected pathJoin builtin runtime" ("pathJoin(parts) {" `T.isInfixOf` emitted)
            assertBool "expected readFile host binding" ("\"readFile\"" `T.isInfixOf` emitted)
            assertBool "expected textChars builtin runtime" ("textChars(value) {" `T.isInfixOf` emitted)
            let compiledPath = "dist/compiler-stdlib.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "globalThis.__claspRuntime = {"
                , "  fileExists(path) { return path === 'fixtures/ok.txt'; },"
                , "  readFile(path) {"
                , "    return path === 'fixtures/ok.txt' ? compiledModule.Ok('ready') : compiledModule.Err('missing');"
                , "  }"
                , "};"
                , "console.log(JSON.stringify({"
                , "  main: compiledModule.main,"
                , "  chars: compiledModule.charsSummary('abc'),"
                , "  split: compiledModule.splitSummary('alpha:beta'),"
                , "  prefixOk: compiledModule.prefixSummary('deprecated/bootstrap/src/Clasp/Parser.hs'),"
                , "  prefixMiss: compiledModule.prefixSummary('examples/hello.clasp'),"
                , "  splitOnce: compiledModule.splitOnceSummary('left::right'),"
                , "  splitOnceMiss: compiledModule.splitOnceSummary('plain-text'),"
                , "  existsOk: compiledModule.filePresent('fixtures/ok.txt'),"
                , "  existsMissing: compiledModule.filePresent('fixtures/missing.txt'),"
                , "  readOk: compiledModule.loadSummary('fixtures/ok.txt'),"
                , "  readMissing: compiledModule.loadSummary('fixtures/missing.txt')"
                , "}));"
                ]
            assertEqual
              "expected compiler stdlib runtime output"
              "{\"main\":\"src/Clasp :: Checker.hs\",\"chars\":[\"a\",\"b\",\"c\"],\"split\":[\"alpha\",\"beta\"],\"prefixOk\":\"deprecated/bootstrap/src/Clasp/Parser.hs\",\"prefixMiss\":\"examples/hello.clasp\",\"splitOnce\":\"left\\nright\",\"splitOnceMiss\":\"plain-text\",\"existsOk\":true,\"existsMissing\":false,\"readOk\":\"ok.txt::ready\",\"readMissing\":\"missing\"}"
              runtimeOutput
    , testCase "native evaluates the compiler renderers example end-to-end on the hosted Clasp path" $ do
        let compiledPath = "dist/compiler-renderers.native.ir"
            compiledImagePath = replaceExtension compiledPath "native.image.json"
            formattedDeclPath = "dist/compiler-renderers.formatted.txt"
            renderedDiagnosticPath = "dist/compiler-renderers.diagnostic.txt"
            diagnosticJsonPath = "dist/compiler-renderers.json.txt"
            mainPath = "dist/compiler-renderers.main.txt"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["native", "examples/compiler-renderers.clasp", "-o", compiledPath]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected compiler renderers native emit to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            formattedDecl <- runHostedNativeTool compiledImagePath "formattedDecl" Nothing formattedDeclPath
            renderedDiagnostic <- runHostedNativeTool compiledImagePath "renderedDiagnostic" Nothing renderedDiagnosticPath
            diagnosticJson <- runHostedNativeTool compiledImagePath "diagnosticJson" Nothing diagnosticJsonPath
            renderedMain <- runHostedNativeTool compiledImagePath "main" Nothing mainPath
            diagnosticValue <- case eitherDecodeStrictText diagnosticJson of
              Left decodeErr ->
                assertFailure ("expected compiler renderers diagnostic json to decode:\n" <> decodeErr)
              Right value ->
                pure value
            assertEqual
              "expected formatted decl"
              "renderPosition : PositionText -> Str\nrenderPosition position = textJoin \":\" [position.line, position.column]"
              formattedDecl
            assertEqual
              "expected rendered diagnostic"
              "E_DUPLICATE_DECL at Compiler/Formatter.clasp:3:1-3:18: Declaration `renderPosition` is already defined.\n- Formatter helper names must be unique within a module.\n- hint: Rename the helper or merge the duplicate definitions.\n- related previous declaration: Compiler/Formatter.clasp:1:1-1:16"
              renderedDiagnostic
            assertEqual "expected diagnostic json code" (Just (String "E_DUPLICATE_DECL")) (lookupObjectKey "code" diagnosticValue)
            assertEqual
              "expected diagnostic json primary span"
              (Just (String "Compiler/Formatter.clasp:3:1-3:18"))
              (lookupObjectKey "primarySpan" diagnosticValue)
            assertEqual
              "expected diagnostic json related line"
              (Just (String "- related previous declaration: Compiler/Formatter.clasp:1:1-1:16"))
              (lookupObjectKey "related" diagnosticValue)
            assertEqual
              "expected main render"
              "renderPosition : PositionText -> Str\nrenderPosition position = textJoin \":\" [position.line, position.column]\n\nE_DUPLICATE_DECL at Compiler/Formatter.clasp:3:1-3:18: Declaration `renderPosition` is already defined.\n- Formatter helper names must be unique within a module.\n- hint: Rename the helper or merge the duplicate definitions.\n- related previous declaration: Compiler/Formatter.clasp:1:1-1:16\n\n{\"code\":\"E_DUPLICATE_DECL\",\"summary\":\"Declaration `renderPosition` is already defined.\",\"primarySpan\":\"Compiler/Formatter.clasp:3:1-3:18\",\"detail\":\"Formatter helper names must be unique within a module.\",\"fixHint\":\"Rename the helper or merge the duplicate definitions.\",\"related\":\"- related previous declaration: Compiler/Formatter.clasp:1:1-1:16\"}"
              renderedMain
    , testCase "native evaluates the compiler loader example end-to-end on the hosted Clasp path" $ do
        let compiledPath = "dist/compiler-loader.native.ir"
            compiledImagePath = replaceExtension compiledPath "native.image.json"
            snapshotPath = "dist/compiler-loader.snapshot.json"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["native", "examples/compiler-loader.clasp", "-o", compiledPath]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected compiler loader native emit to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess ->
            withProjectFiles
              "compiler-loader-runtime"
              [ ("workspace/src/App/Main.clasp", "module App.Main\n\nmain : Str\nmain = \"local\"\n")
              , ("packages/stdlib/clasp/Compiler/Loader.clasp", "module Compiler.Loader\n\nmain : Str\nmain = \"stdlib\"\n")
              ]
              $ \root -> do
                snapshotText <- runHostedNativeToolInDirectory root compiledImagePath "snapshotJson" Nothing snapshotPath
                runtimeValue <- case eitherDecodeStrictText snapshotText of
                  Left decodeErr ->
                    assertFailure ("expected compiler loader runtime output json to decode:\n" <> decodeErr)
                  Right value ->
                    pure value
                assertEqual
                  "expected local module resolution"
                  (Just (String "workspace|App.Main|workspace/src/App/Main.clasp|module App.Main"))
                  (lookupObjectKey "localModule" runtimeValue)
                assertEqual
                  "expected package module resolution"
                  (Just (String "stdlib|Compiler.Loader|packages/stdlib/clasp/Compiler/Loader.clasp|module Compiler.Loader"))
                  (lookupObjectKey "packageModule" runtimeValue)
                assertEqual
                  "expected missing module summary"
                  (Just (String "missing:Compiler.Emit"))
                  (lookupObjectKey "missingModule" runtimeValue)
    , testCase "native evaluates the compiler parser example end-to-end on the hosted Clasp path" $ do
        let compiledPath = "dist/compiler-parser.native.ir"
            compiledImagePath = replaceExtension compiledPath "native.image.json"
            snapshotPath = "dist/compiler-parser.snapshot.json"
            listSnapshotPath = "dist/compiler-parser.list-snapshot.json"
            moduleBodyPath = "dist/compiler-parser.module-body.txt"
            firstDeclarationPayloadPath = "dist/compiler-parser.payload.txt"
            firstDeclarationNamePath = "dist/compiler-parser.decl-name.txt"
            firstDeclarationBodyPath = "dist/compiler-parser.decl-body.txt"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["native", "examples/compiler-parser.clasp", "-o", compiledPath]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected compiler parser native emit to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            snapshotText <- runHostedNativeTool compiledImagePath "main" Nothing snapshotPath
            listSnapshotText <- runHostedNativeTool compiledImagePath "listSnapshotJson" Nothing listSnapshotPath
            moduleBody <- runHostedNativeTool compiledImagePath "moduleBody" Nothing moduleBodyPath
            _ <- runHostedNativeTool compiledImagePath "firstDeclarationPayload" Nothing firstDeclarationPayloadPath
            firstDeclarationName <- runHostedNativeTool compiledImagePath "firstSegment" (Just firstDeclarationPayloadPath) firstDeclarationNamePath
            firstDeclarationBody <- runHostedNativeTool compiledImagePath "remainingSegments" (Just firstDeclarationPayloadPath) firstDeclarationBodyPath
            snapshotValue <- case eitherDecodeStrictText snapshotText of
              Left decodeErr ->
                assertFailure ("expected compiler parser snapshot json to decode:\n" <> decodeErr)
              Right value ->
                pure value
            listSnapshotValue <- case eitherDecodeStrictText listSnapshotText of
              Left decodeErr ->
                assertFailure ("expected compiler parser list snapshot json to decode:\n" <> decodeErr)
              Right value ->
                pure value
            assertEqual
              "expected parsed module name"
              (Just (String "Compiler.Parser"))
              (lookupObjectKey "moduleName" snapshotValue)
            assertEqual
              "expected parsed imports"
              (Just (String "|Compiler.Loader|Compiler.Renderers"))
              (lookupObjectKey "imports" snapshotValue)
            assertEqual
              "expected parsed signatures"
              (Just (String "|parseModule : Str -> Str|main : Str"))
              (lookupObjectKey "signatures" snapshotValue)
            assertEqual
              "expected parsed declarations"
              (Just (String "|parseModule source|main"))
              (lookupObjectKey "declarations" snapshotValue)
            assertEqual
              "expected parsed list items"
              (Just (String "module|import|declaration"))
              (lookupObjectKey "items" listSnapshotValue)
            assertEqual
              "expected parsed list count"
              (Just (String "3"))
              (lookupObjectKey "count" listSnapshotValue)
            assertEqual
              "expected module body after prefix split"
              "import Compiler.Loader\nimport Compiler.Renderers\n\nparseModule : Str -> Str\nparseModule source = source\n\nmain : Str\nmain = encode (parseModuleSummary sampleSource)"
              moduleBody
            assertEqual
              "expected first declaration name"
              "parseModule source"
              firstDeclarationName
            assertEqual
              "expected first declaration body"
              "source"
              firstDeclarationBody
    , testCase "native evaluates the compiler checker example end-to-end on the hosted Clasp path" $ do
        let compiledPath = "dist/compiler-checker.native.ir"
            compiledImagePath = replaceExtension compiledPath "native.image.json"
            snapshotPath = "dist/compiler-checker.snapshot.json"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["native", "examples/compiler-checker.clasp", "-o", compiledPath]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected compiler checker native emit to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            snapshotText <- runHostedNativeTool compiledImagePath "snapshotJson" Nothing snapshotPath
            runtimeValue <- case eitherDecodeStrictText snapshotText of
              Left decodeErr ->
                assertFailure ("expected compiler checker runtime output json to decode:\n" <> decodeErr)
              Right value ->
                pure value
            assertEqual
              "expected homogeneous roster inference"
              (Just (String "ok:[Str]"))
              (lookupObjectKey "roster" runtimeValue)
            assertEqual
              "expected nested list inference"
              (Just (String "ok:[[Int]]"))
              (lookupObjectKey "matrix" runtimeValue)
            assertEqual
              "expected mixed list rejection"
              (Just (String "error:expected Str but found Int"))
              (lookupObjectKey "mixed" runtimeValue)
    , testCase "native evaluates the compiler emitter example end-to-end on the hosted Clasp path" $ do
        let compiledPath = "dist/compiler-emitter.native.ir"
            compiledImagePath = replaceExtension compiledPath "native.image.json"
            snapshotPath = "dist/compiler-emitter.snapshot.json"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["native", "examples/compiler-emitter.clasp", "-o", compiledPath]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected compiler emitter native emit to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            snapshotText <- runHostedNativeTool compiledImagePath "snapshotJson" Nothing snapshotPath
            runtimeValue <- case eitherDecodeStrictText snapshotText of
              Left decodeErr ->
                assertFailure ("expected compiler emitter runtime output json to decode:\n" <> decodeErr)
              Right value ->
                pure value
            assertEqual
              "expected emitted array literal"
              (Just (String "[\"Ada\", \"Grace\", \"Linus\"]"))
              (lookupObjectKey "arrayLiteral" runtimeValue)
            assertEqual
              "expected emitted module text"
              (Just (String "// Generated by compiler-emitter\nexport const names = [\"Ada\", \"Grace\", \"Linus\"];\nexport function renderNames(names) { return JSON.stringify(names); }"))
              (lookupObjectKey "moduleText" runtimeValue)
    , testCase "native evaluates the hosted compiler entrypoint end-to-end" $ do
        let compiledPath = "dist/compiler-selfhost.native.ir"
            compiledImagePath = replaceExtension compiledPath "native.image.json"
            snapshotPath = "dist/compiler-selfhost.snapshot.json"
            checkPath = "dist/compiler-selfhost.check.txt"
            explainPath = "dist/compiler-selfhost.explain.txt"
            compilePath = "dist/compiler-selfhost-emitted.mjs"
            nativePath = "dist/compiler-selfhost-emitted.native.ir"
            nativeImagePath = "dist/compiler-selfhost-emitted.native.image.json"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["native", "src/Main.clasp", "-o", compiledPath]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected hosted compiler entrypoint native emit to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            hostedEntryPath <- makeAbsolute "src/Main.clasp"
            snapshotText <- runHostedNativeTool compiledImagePath "main" Nothing snapshotPath
            runtimeValue <- case eitherDecodeStrictText snapshotText of
              Left decodeErr ->
                assertFailure ("expected hosted compiler native runtime output json to decode:\n" <> decodeErr)
              Right value ->
                pure value
            checkEntrypointOutput <- runHostedNativeTool compiledImagePath "checkEntrypoint" Nothing checkPath
            explainEntrypointOutput <- runHostedNativeTool compiledImagePath "explainEntrypoint" Nothing explainPath
            compileEntrypointOutput <- runHostedNativeTool compiledImagePath "compileEntrypoint" Nothing compilePath
            nativeEntrypointOutput <- runHostedNativeTool compiledImagePath "nativeEntrypoint" Nothing nativePath
            nativeImageEntrypointOutput <- runHostedNativeTool compiledImagePath "nativeImageEntrypoint" Nothing nativeImagePath
            assertEqual
              "expected native check entrypoint to match the self-hosted snapshot"
              (Just (String checkEntrypointOutput))
              (lookupObjectKey "checkedModule" runtimeValue)
            assertEqual
              "expected native explain entrypoint to match the self-hosted snapshot"
              (Just (String explainEntrypointOutput))
              (lookupObjectKey "explainModule" runtimeValue)
            assertEqual
              "expected native compile entrypoint to match the self-hosted snapshot"
              (Just (String (T.strip compileEntrypointOutput)))
              (String . T.strip <$> lookupObjectText "emittedModule" runtimeValue)
            assertEqual
              "expected native IR entrypoint to match the self-hosted snapshot"
              (Just (T.strip nativeEntrypointOutput))
              (T.strip <$> lookupObjectText "emittedNativeModule" runtimeValue)
            assertEqual
              "expected native image entrypoint to match the self-hosted snapshot"
              (Just (T.strip nativeImageEntrypointOutput))
              (T.strip <$> lookupObjectText "emittedNativeImageModule" runtimeValue)
            checkOutput <- runHostedNativeTool compiledImagePath "checkProjectText" (Just ("--project-entry=" <> hostedEntryPath)) checkPath
            explainOutput <- runHostedNativeTool compiledImagePath "explainProjectText" (Just ("--project-entry=" <> hostedEntryPath)) explainPath
            compileOutput <- runHostedNativeTool compiledImagePath "compileProjectText" (Just ("--project-entry=" <> hostedEntryPath)) compilePath
            nativeOutput <- runHostedNativeTool compiledImagePath "nativeProjectText" (Just ("--project-entry=" <> hostedEntryPath)) nativePath
            nativeImageOutput <- runHostedNativeTool compiledImagePath "nativeImageProjectText" (Just ("--project-entry=" <> hostedEntryPath)) nativeImagePath
            assertBool "expected project check output to describe the hosted compiler module" ("checkEntrypoint : Str" `T.isInfixOf` checkOutput)
            assertBool "expected project explain output to describe the hosted compiler module" ("nativeImageProjectText : Str -> Str" `T.isInfixOf` explainOutput)
            assertBool "expected project compile output to emit the hosted compiler entrypoint exports" ("export function checkEntrypoint()" `T.isInfixOf` compileOutput)
            assertBool "expected project native output to emit the hosted compiler module" ("module Main" `T.isInfixOf` nativeOutput)
            assertBool "expected project native image output format" ("\"format\": \"clasp-native-image-v1\"" `T.isInfixOf` nativeImageOutput)
            assertEqual
              "expected lowered value declaration"
              (Just (String "const hello = literal:Hello from Clasp"))
              (lookupObjectKey "loweredValue" runtimeValue)
            assertEqual
              "expected lowered function declaration"
              (Just (String "function id(value) = name:value"))
              (lookupObjectKey "loweredFunction" runtimeValue)
            assertEqual
              "expected lowered module summary"
              (Just (String "const hello = literal:Hello from Clasp\nfunction id(value) = name:value\nconst main = call id(name:hello)"))
              (lookupObjectKey "loweredModule" runtimeValue)
            assertEqual
              "expected checked value type"
              (Just (String "Str"))
              (lookupObjectKey "checkedValueType" runtimeValue)
            assertEqual
              "expected checked function type"
              (Just (String "Str -> Str"))
              (lookupObjectKey "checkedFunctionType" runtimeValue)
            assertEqual
              "expected checked module summary"
              (Just (String "hello : Str\nid : Str -> Str\nmain : Str"))
              (lookupObjectKey "checkedModule" runtimeValue)
            assertEqual
              "expected explain module summary"
              (Just (String "hello : Str\nid : Str -> Str\nmain : Str\n\nconst hello = literal:Hello from Clasp\nfunction id(value) = name:value\nconst main = call id(name:hello)"))
              (lookupObjectKey "explainModule" runtimeValue)
            assertEqual
              "expected mismatch diagnostic"
              (Just (String "In `greeting`: Type mismatch for `greeting`: expected Int, found Str."))
              (lookupObjectKey "mismatchDiagnostic" runtimeValue)
            case lookupObjectText "emittedModule" runtimeValue of
              Just emittedModuleText -> do
                assertBool "expected emitted module header" ("// Generated by compiler-selfhost" `T.isPrefixOf` emittedModuleText)
                assertBool "expected emitted module hello export" ("export const hello = \"Hello from Clasp\";" `T.isInfixOf` emittedModuleText)
                assertBool "expected emitted module id export" ("export function id(value) { return value; }" `T.isInfixOf` emittedModuleText)
                assertBool "expected emitted module main export" ("export const main = id(hello);" `T.isInfixOf` emittedModuleText)
              _ ->
                assertFailure "expected emittedModule field"
            case lookupObjectText "stage2EmittedModule" runtimeValue of
              Just stage2EmittedModuleText -> do
                assertBool "expected stage2 emitted module header" ("// Generated by compiler-selfhost" `T.isPrefixOf` stage2EmittedModuleText)
                assertBool "expected stage2 emitted module hello export" ("export const hello = \"Hello from Clasp\";" `T.isInfixOf` stage2EmittedModuleText)
                assertBool "expected stage2 emitted module id export" ("export function id(value) { return value; }" `T.isInfixOf` stage2EmittedModuleText)
                assertBool "expected stage2 emitted module main export" ("export const main = id(hello);" `T.isInfixOf` stage2EmittedModuleText)
              _ ->
                assertFailure "expected stage2EmittedModule field"
            assertEqual
              "expected stage2 check output"
              (Just (String "hello : Str\nid : Str -> Str\nmain : Str"))
              (lookupObjectKey "stage2CheckOutput" runtimeValue)
            assertEqual
              "expected stage2 explain output"
              (Just (String "hello : Str\nid : Str -> Str\nmain : Str\n\nconst hello = literal:Hello from Clasp\nfunction id(value) = name:value\nconst main = call id(name:hello)"))
              (lookupObjectKey "stage2ExplainOutput" runtimeValue)
            case lookupObjectKey "emittedNativeModule" runtimeValue of
              Just (String nativeText) -> do
                assertBool "expected emitted native module format header" ("format clasp-native-ir-v1" `T.isInfixOf` nativeText)
                assertBool "expected emitted native module runtime section" ("runtime {" `T.isInfixOf` nativeText)
                assertBool "expected emitted native global" ("global hello = string(\"Hello from Clasp\")" `T.isInfixOf` nativeText)
                assertBool "expected emitted native function" ("function id(value) = local(value)" `T.isInfixOf` nativeText)
              _ ->
                assertFailure "expected emittedNativeModule field"
            case lookupObjectKey "stage2NativeOutput" runtimeValue of
              Just (String nativeText) -> do
                assertBool "expected stage2 native format header" ("format clasp-native-ir-v1" `T.isInfixOf` nativeText)
                assertBool "expected stage2 native global" ("global hello = string(\"Hello from Clasp\")" `T.isInfixOf` nativeText)
              _ ->
                assertFailure "expected stage2NativeOutput field"
            assertEqual
              "expected emitted hello export"
              (Just (String "Hello from Clasp"))
              (lookupObjectKey "emittedHello" runtimeValue)
            assertEqual
              "expected emitted identity export"
              (Just (String "Ada"))
              (lookupObjectKey "emittedIdentity" runtimeValue)
            assertEqual
              "expected emitted main export"
              (Just (String "Hello from Clasp"))
              (lookupObjectKey "emittedMain" runtimeValue)
            assertEqual
              "expected parsed sample module name"
              (Just (String "Main"))
              (lookupObjectKey "parsedSampleModuleName" runtimeValue)
            case lookupObjectKey "parsedSampleImports" runtimeValue of
              Just (Array importsValue) ->
                assertEqual
                  "expected parsed sample imports"
                  [String "Compiler.Lower"]
                  (toList importsValue)
              _ ->
                assertFailure "expected parsedSampleImports field"
            case lookupObjectKey "parsedSampleDeclNames" runtimeValue of
              Just (Array declNamesValue) ->
                assertEqual
                  "expected parsed sample declaration names"
                  [String "hello", String "id", String "main"]
                  (toList declNamesValue)
              _ ->
                assertFailure "expected parsedSampleDeclNames field"
            assertEqual
              "expected parsed sample main expression"
              (Just (String "call id(hello)"))
              (lookupObjectKey "parsedSampleMainExpr" runtimeValue)
            assertEqual
              "expected secondary parsed module name"
              (Just (String "Secondary"))
              (lookupObjectKey "secondaryParsedModuleName" runtimeValue)
            case lookupObjectKey "secondaryParsedDeclNames" runtimeValue of
              Just (Array declNamesValue) ->
                assertEqual
                  "expected secondary parsed declaration names"
                  [String "salute", String "echo", String "main"]
                  (toList declNamesValue)
              _ ->
                assertFailure "expected secondaryParsedDeclNames field"
            assertEqual
              "expected secondary checked module summary"
              (Just (String "salute : Str\necho : Str -> Str\nmain : Str"))
              (lookupObjectKey "secondaryCheckedModule" runtimeValue)
            assertEqual
              "expected secondary lowered module summary"
              (Just (String "const salute = literal:Hi\nfunction echo(value) = name:value\nconst main = call echo(name:salute)"))
              (lookupObjectKey "secondaryLoweredModule" runtimeValue)
            case lookupObjectText "secondaryEmittedModule" runtimeValue of
              Just secondaryEmittedModuleText -> do
                assertBool "expected secondary emitted module header" ("// Generated by compiler-selfhost" `T.isPrefixOf` secondaryEmittedModuleText)
                assertBool "expected secondary salute export" ("export const salute = \"Hi\";" `T.isInfixOf` secondaryEmittedModuleText)
                assertBool "expected secondary echo export" ("export function echo(value) { return value; }" `T.isInfixOf` secondaryEmittedModuleText)
                assertBool "expected secondary main export" ("export const main = echo(salute);" `T.isInfixOf` secondaryEmittedModuleText)
              _ ->
                assertFailure "expected secondaryEmittedModule field"
            assertEqual
              "expected tertiary parsed module name"
              (Just (String "Collections"))
              (lookupObjectKey "tertiaryParsedModuleName" runtimeValue)
            case lookupObjectKey "tertiaryParsedDeclNames" runtimeValue of
              Just (Array declNamesValue) ->
                assertEqual
                  "expected tertiary parsed declaration names"
                  [String "flags", String "scores", String "main"]
                  (toList declNamesValue)
              _ ->
                assertFailure "expected tertiaryParsedDeclNames field"
            assertEqual
              "expected tertiary checked module summary"
              (Just (String "flags : [Bool]\nscores : [Int]\nmain : [Int]"))
              (lookupObjectKey "tertiaryCheckedModule" runtimeValue)
            assertEqual
              "expected tertiary lowered module summary"
              (Just (String "const flags = list:[bool:true, bool:false]\nconst scores = list:[int:7, int:9]\nconst main = name:scores"))
              (lookupObjectKey "tertiaryLoweredModule" runtimeValue)
            case lookupObjectText "tertiaryEmittedModule" runtimeValue of
              Just tertiaryEmittedModuleText -> do
                assertBool "expected tertiary emitted module header" ("// Generated by compiler-selfhost" `T.isPrefixOf` tertiaryEmittedModuleText)
                assertBool "expected tertiary flags export" ("export const flags = [true, false];" `T.isInfixOf` tertiaryEmittedModuleText)
                assertBool "expected tertiary scores export" ("export const scores = [7, 9];" `T.isInfixOf` tertiaryEmittedModuleText)
                assertBool "expected tertiary main export" ("export const main = scores;" `T.isInfixOf` tertiaryEmittedModuleText)
              _ ->
                assertFailure "expected tertiaryEmittedModule field"
            assertEqual
              "expected quaternary parsed module name"
              (Just (String "Pairing"))
              (lookupObjectKey "quaternaryParsedModuleName" runtimeValue)
            case lookupObjectKey "quaternaryParsedDeclNames" runtimeValue of
              Just (Array declNamesValue) ->
                assertEqual
                  "expected quaternary parsed declaration names"
                  [String "select", String "wrap", String "labels", String "main"]
                  (toList declNamesValue)
              _ ->
                assertFailure "expected quaternaryParsedDeclNames field"
            assertEqual
              "expected quaternary checked module summary"
              (Just (String "select : Str -> Str -> Str\nwrap : Str -> Str\nlabels : [Str]\nmain : Str"))
              (lookupObjectKey "quaternaryCheckedModule" runtimeValue)
            assertEqual
              "expected quaternary lowered module summary"
              (Just (String "function select(left, right) = name:right\nfunction wrap(value) = name:value\nconst labels = list:[call wrap(call select(literal:left, literal:right)), literal:done]\nconst main = call wrap(call select(literal:alpha, literal:beta))"))
              (lookupObjectKey "quaternaryLoweredModule" runtimeValue)
            case lookupObjectText "quaternaryEmittedModule" runtimeValue of
              Just quaternaryEmittedModuleText -> do
                assertBool "expected quaternary emitted module header" ("// Generated by compiler-selfhost" `T.isPrefixOf` quaternaryEmittedModuleText)
                assertBool "expected quaternary select export" ("export function select(left, right) { return right; }" `T.isInfixOf` quaternaryEmittedModuleText)
                assertBool "expected quaternary wrap export" ("export function wrap(value) { return value; }" `T.isInfixOf` quaternaryEmittedModuleText)
                assertBool "expected quaternary labels export" ("export const labels = [wrap(select(\"left\", \"right\")), \"done\"];" `T.isInfixOf` quaternaryEmittedModuleText)
                assertBool "expected quaternary main export" ("export const main = wrap(select(\"alpha\", \"beta\"));" `T.isInfixOf` quaternaryEmittedModuleText)
              _ ->
                assertFailure "expected quaternaryEmittedModule field"
            assertEqual
              "expected quinary parsed module name"
              (Just (String "Records"))
              (lookupObjectKey "quinaryParsedModuleName" runtimeValue)
            case lookupObjectKey "quinaryParsedRecordNames" runtimeValue of
              Just (Array recordNamesValue) ->
                assertEqual
                  "expected quinary parsed record names"
                  [String "User"]
                  (toList recordNamesValue)
              _ ->
                assertFailure "expected quinaryParsedRecordNames field"
            case lookupObjectKey "quinaryParsedRecordFieldTypes" runtimeValue of
              Just (Array fieldTypesValue) ->
                assertEqual
                  "expected quinary parsed record field types"
                  [String "name : Str", String "active : Bool"]
                  (toList fieldTypesValue)
              _ ->
                assertFailure "expected quinaryParsedRecordFieldTypes field"
            case lookupObjectKey "quinaryParsedDeclNames" runtimeValue of
              Just (Array declNamesValue) ->
                assertEqual
                  "expected quinary parsed declaration names"
                  [String "defaultUser", String "userName", String "main"]
                  (toList declNamesValue)
              _ ->
                assertFailure "expected quinaryParsedDeclNames field"
            assertEqual
              "expected quinary checked module summary"
              (Just (String "defaultUser : User\nuserName : User -> Str\nmain : Str"))
              (lookupObjectKey "quinaryCheckedModule" runtimeValue)
            assertEqual
              "expected quinary lowered module summary"
              (Just (String "const defaultUser = record User {name = literal:Ada, active = bool:true}\nfunction userName(user) = field(User, name:user, name)\nconst main = call userName(name:defaultUser)"))
              (lookupObjectKey "quinaryLoweredModule" runtimeValue)
            case lookupObjectText "quinaryEmittedModule" runtimeValue of
              Just quinaryEmittedModuleText -> do
                assertBool "expected quinary emitted module header" ("// Generated by compiler-selfhost" `T.isPrefixOf` quinaryEmittedModuleText)
                assertBool "expected quinary defaultUser export" ("export const defaultUser = { name: \"Ada\", active: true };" `T.isInfixOf` quinaryEmittedModuleText)
                assertBool "expected quinary userName export" ("export function userName(user) { return (user).name; }" `T.isInfixOf` quinaryEmittedModuleText)
                assertBool "expected quinary main export" ("export const main = userName(defaultUser);" `T.isInfixOf` quinaryEmittedModuleText)
              _ ->
                assertFailure "expected quinaryEmittedModule field"
            assertEqual
              "expected senary parsed module name"
              (Just (String "Decisions"))
              (lookupObjectKey "senaryParsedModuleName" runtimeValue)
            case lookupObjectKey "senaryParsedTypeNames" runtimeValue of
              Just (Array typeNamesValue) ->
                assertEqual
                  "expected senary parsed type names"
                  [String "Decision"]
                  (toList typeNamesValue)
              _ ->
                assertFailure "expected senaryParsedTypeNames field"
            case lookupObjectKey "senaryParsedConstructorSummaries" runtimeValue of
              Just (Array constructorValue) ->
                assertEqual
                  "expected senary parsed constructor summaries"
                  [String "Keep Str Str", String "Drop"]
                  (toList constructorValue)
              _ ->
                assertFailure "expected senaryParsedConstructorSummaries field"
            assertEqual
              "expected senary choose annotation"
              (Just (String "Decision -> Str"))
              (lookupObjectKey "senaryChooseAnnotation" runtimeValue)
            case lookupObjectKey "senaryParsedDeclNames" runtimeValue of
              Just (Array declNamesValue) ->
                assertEqual
                  "expected senary parsed declaration names"
                  [String "choose", String "main"]
                  (toList declNamesValue)
              _ ->
                assertFailure "expected senaryParsedDeclNames field"
            assertEqual
              "expected senary checked module summary"
              (Just (String "choose : Decision -> Str\nmain : Str"))
              (lookupObjectKey "senaryCheckedModule" runtimeValue)
            assertEqual
              "expected senary lowered module summary"
              (Just (String "function choose(decision) = match name:decision [Keep(left, right) -> name:left, Drop() -> literal:drop]\nconst main = call choose(ctor Keep(literal:alpha, literal:beta))"))
              (lookupObjectKey "senaryLoweredModule" runtimeValue)
            case lookupObjectText "senaryEmittedModule" runtimeValue of
              Just senaryEmittedModuleText -> do
                assertBool "expected senary emitted module header" ("// Generated by compiler-selfhost" `T.isPrefixOf` senaryEmittedModuleText)
                assertBool "expected senary choose export" ("export function choose(decision)" `T.isInfixOf` senaryEmittedModuleText)
                assertBool "expected senary Keep branch" ("if (__match[0] === \"Keep\")" `T.isInfixOf` senaryEmittedModuleText)
                assertBool "expected senary Drop branch" ("if (__match[0] === \"Drop\")" `T.isInfixOf` senaryEmittedModuleText)
                assertBool "expected senary main export" ("export const main = choose([\"Keep\", \"alpha\", \"beta\"]);" `T.isInfixOf` senaryEmittedModuleText)
              _ ->
                assertFailure "expected senaryEmittedModule field"
            assertEqual
              "expected septenary parsed module name"
              (Just (String "Lettings"))
              (lookupObjectKey "septenaryParsedModuleName" runtimeValue)
            case lookupObjectKey "septenaryParsedDeclNames" runtimeValue of
              Just (Array declNamesValue) ->
                assertEqual
                  "expected septenary parsed declaration names"
                  [String "describe", String "main"]
                  (toList declNamesValue)
              _ ->
                assertFailure "expected septenaryParsedDeclNames field"
            assertEqual
              "expected septenary checked module summary"
              (Just (String "describe : Str -> Str\nmain : Str"))
              (lookupObjectKey "septenaryCheckedModule" runtimeValue)
            assertEqual
              "expected septenary lowered module summary"
              (Just (String "function describe(name) = let alias = name:name in name:alias\nconst main = let current = call describe(literal:Ada) in name:current"))
              (lookupObjectKey "septenaryLoweredModule" runtimeValue)
            case lookupObjectText "septenaryEmittedModule" runtimeValue of
              Just septenaryEmittedModuleText -> do
                assertBool "expected septenary emitted module header" ("// Generated by compiler-selfhost" `T.isPrefixOf` septenaryEmittedModuleText)
                assertBool "expected septenary describe export" ("export function describe(name)" `T.isInfixOf` septenaryEmittedModuleText)
                assertBool "expected septenary alias binding" ("const alias = name;" `T.isInfixOf` septenaryEmittedModuleText)
                assertBool "expected septenary main export" ("const current = describe(\"Ada\");" `T.isInfixOf` septenaryEmittedModuleText)
              _ ->
                assertFailure "expected septenaryEmittedModule field"
    , testCase "promoted hosted native seed rebuilds end-to-end without JS staging" $ do
        stage1Path <- makeAbsolute "src/stage1.native.image.json"
        hostedEntryPath <- makeAbsolute "src/Main.clasp"
        let rebuiltImagePath = "dist/compiler-selfhost-promoted.verify.native.image.json"
            promotedSnapshotPath = "dist/compiler-selfhost-promoted.snapshot.json"
            rebuiltSnapshotPath = "dist/compiler-selfhost-rebuilt.snapshot.json"
            promotedCheckPath = "dist/compiler-selfhost-promoted.check.txt"
            rebuiltCheckPath = "dist/compiler-selfhost-rebuilt.check.txt"
            promotedExplainPath = "dist/compiler-selfhost-promoted.explain.txt"
            rebuiltExplainPath = "dist/compiler-selfhost-rebuilt.explain.txt"
            promotedCompilePath = "dist/compiler-selfhost-promoted.compile.mjs"
            rebuiltCompilePath = "dist/compiler-selfhost-rebuilt.compile.mjs"
            promotedNativePath = "dist/compiler-selfhost-promoted.native.ir"
            rebuiltNativePath = "dist/compiler-selfhost-rebuilt.native.ir"
            promotedImagePath = "dist/compiler-selfhost-promoted.native.image.json"
            rebuiltProjectImagePath = "dist/compiler-selfhost-rebuilt-project.native.image.json"
        createDirectoryIfMissing True "dist"
        rebuiltImageOutput <- runHostedNativeTool stage1Path "nativeImageProjectText" (Just ("--project-entry=" <> hostedEntryPath)) rebuiltImagePath
        promotedImageBytes <- TIO.readFile stage1Path
        promotedSnapshot <- runHostedNativeTool stage1Path "main" Nothing promotedSnapshotPath
        rebuiltSnapshot <- runHostedNativeTool rebuiltImagePath "main" Nothing rebuiltSnapshotPath
        assertEqual "expected rebuilt native image bytes to match promoted seed" promotedImageBytes rebuiltImageOutput
        assertEqual "expected rebuilt snapshot to match promoted snapshot" promotedSnapshot rebuiltSnapshot
        promotedCheck <- runHostedNativeTool stage1Path "checkEntrypoint" Nothing promotedCheckPath
        rebuiltCheck <- runHostedNativeTool rebuiltImagePath "checkEntrypoint" Nothing rebuiltCheckPath
        assertEqual "expected rebuilt check entrypoint to match promoted seed" promotedCheck rebuiltCheck
        promotedExplain <- runHostedNativeTool stage1Path "explainEntrypoint" Nothing promotedExplainPath
        rebuiltExplain <- runHostedNativeTool rebuiltImagePath "explainEntrypoint" Nothing rebuiltExplainPath
        assertEqual "expected rebuilt explain entrypoint to match promoted seed" promotedExplain rebuiltExplain
        promotedCompile <- runHostedNativeTool stage1Path "compileEntrypoint" Nothing promotedCompilePath
        rebuiltCompile <- runHostedNativeTool rebuiltImagePath "compileEntrypoint" Nothing rebuiltCompilePath
        assertEqual "expected rebuilt compile entrypoint to match promoted seed" promotedCompile rebuiltCompile
        promotedNative <- runHostedNativeTool stage1Path "nativeEntrypoint" Nothing promotedNativePath
        rebuiltNative <- runHostedNativeTool rebuiltImagePath "nativeEntrypoint" Nothing rebuiltNativePath
        assertEqual "expected rebuilt native entrypoint to match promoted seed" promotedNative rebuiltNative
        promotedImage <- runHostedNativeTool stage1Path "nativeImageEntrypoint" Nothing promotedImagePath
        rebuiltImage <- runHostedNativeTool rebuiltImagePath "nativeImageEntrypoint" Nothing rebuiltProjectImagePath
        assertEqual "expected rebuilt native-image entrypoint to match promoted seed" promotedImage rebuiltImage
    , testCase "hosted verify scripts avoid Haskell and Node in the promoted native self-check loop" $ do
        verifyScript <- TIO.readFile "src/scripts/verify.sh"
        verifyAllScript <- TIO.readFile "scripts/verify-all.sh"
        assertBool
          "expected hosted verify script to rebuild via nativeProjectText"
          ("nativeProjectText" `T.isInfixOf` verifyScript)
        assertBool
          "expected hosted verify script to rebuild via nativeImageProjectText"
          ("nativeImageProjectText" `T.isInfixOf` verifyScript)
        assertBool
          "expected hosted verify script to use project-entry bundling instead of a flattened seed"
          ("--project-entry=" `T.isInfixOf` verifyScript)
        assertBool
          "expected hosted verify script to call the native tool runner"
          ("run-native-tool.sh" `T.isInfixOf` verifyScript)
        assertBool
          "expected hosted verify script to avoid cabal-driven hosted verification"
          (not ("cabal run claspc" `T.isInfixOf` verifyScript))
        assertBool
          "expected hosted verify script to avoid node-driven hosted verification"
          (not ("node src/demo.mjs" `T.isInfixOf` verifyScript))
        assertBool
          "expected top-level verify-all to defer hosted verification to the native hosted loop"
          (not ("cabal run claspc -- check src/Main.clasp" `T.isInfixOf` verifyAllScript))
    , testCase "primary compiler driver avoids the Node hosted tool runner in the live execution path" $ do
        compilerSource <- TIO.readFile "deprecated/bootstrap/src/Clasp/Compiler.hs"
        assertBool
          "expected compiler driver to avoid the Node hosted tool runner"
          (not ("run-tool.mjs" `T.isInfixOf` compilerSource))
        assertBool
          "expected compiler driver to avoid stage1.mjs in the live execution path"
          (not ("stage1.mjs" `T.isInfixOf` compilerSource))
        assertBool
          "expected compiler driver to avoid Haskell hosted-source preflight helpers in the live text-tool path"
          (not ("prepareHostedPrimarySource" `T.isInfixOf` compilerSource))
        assertBool
          "expected compiler driver to avoid hosted primary support preflights in the live text-tool path"
          (not ("supportsHostedPrimaryCommandAtPath" `T.isInfixOf` compilerSource))
        assertBool
          "expected compiler driver to avoid the explain-specific hosted support preflight in the live text-tool path"
          (not ("supportsHostedAutoExplainAtPath" `T.isInfixOf` compilerSource))
    , testCase "renderHostedPrimaryEntrySource flattens the hosted compiler entrypoint for self-hosted verification" $ do
        renderedResult <- renderHostedPrimaryEntrySource "src/Main.clasp"
        renderedSource <- case renderedResult of
          Left err ->
            assertFailure ("expected hosted primary entry source render to succeed:\n" <> show (renderDiagnosticBundle err))
          Right source ->
            pure source
        assertBool
          "expected flattened hosted source to keep the hosted entrypoint declarations"
          ("checkEntrypoint : Str" `T.isInfixOf` renderedSource)
        assertBool
          "expected flattened hosted source to inline imported compiler declarations"
          ("type HostedTypeAst = HostedTypeName Str" `T.isInfixOf` renderedSource)
        assertBool
          "expected flattened hosted source to remove import declarations"
          (not ("import Compiler.Ast" `T.isInfixOf` renderedSource))
    , testCase "hosted native tool runner compiles compiler-entrypoint-shaped sources without a bootstrap oracle" $
        withProjectFiles
          "hosted-primary-marker-no-bootstrap"
          [ ( "Main.clasp"
            , "module Main\n\ncompileEntrypoint : Str\ncompileEntrypoint = \"compiler-marker\"\n\nmain : Str\nmain = \"hello\"\n"
            )
          ]
          $ \root -> do
          stage1Path <- makeAbsolute "src/stage1.native.image.json"
          let renderedPath = root </> "Main.clasp"
              resultPath = root </> "result.mjs"
          rebuiltModule <- runHostedNativeTool stage1Path "compileSourceText" (Just renderedPath) resultPath
          assertBool "expected emitted compileEntrypoint export" ("export const compileEntrypoint = \"compiler-marker\";" `T.isInfixOf` rebuiltModule)
          assertBool "expected emitted main export" ("export const main = \"hello\";" `T.isInfixOf` rebuiltModule)
    , testCase "compiled hosted compiler accepts multiline continuation formatting" $ do
        let compiledPath = "dist/compiler-selfhost-layout.mjs"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["compile", "src/Main.clasp", "-o", compiledPath]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected hosted compiler entrypoint compile to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            absoluteCompiledPath <- makeAbsolute compiledPath
            let multilineSource :: Text
                multilineSource = "module Main\n\nselect : Str -> Str -> Str\nselect left right =\n  right\n\nwrap : Str -> Str\nwrap value =\n  value\n\nlabels =\n  [\n    wrap\n      (select\n        \"left\"\n        \"right\"),\n    \"done\"\n  ]\n\nmain =\n  wrap\n    (select\n      \"alpha\"\n      \"beta\")\n"
                runtimeScript :: Text
                runtimeScript =
                  T.unlines
                    [ "import { pathToFileURL } from \"node:url\";"
                    , "const compiledModule = await import(pathToFileURL(" <> T.pack (show absoluteCompiledPath) <> ").href);"
                    , "const multilineSource = " <> T.pack (show multilineSource) <> ";"
                    , "console.log(compiledModule.compileSourceText(multilineSource));"
                    ]
            runtimeOutput <- runNodeScript runtimeScript
            assertBool "expected multiline labels output" ("export const labels = [wrap(select(\"left\", \"right\")), \"done\"];" `T.isInfixOf` runtimeOutput)
            assertBool "expected multiline main output" ("export const main = wrap(select(\"alpha\", \"beta\"));" `T.isInfixOf` runtimeOutput)
    , testCase "compiled hosted compiler accepts trailing commas in structured literals" $ do
        let compiledPath = "dist/compiler-selfhost-trailing-commas.mjs"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["compile", "src/Main.clasp", "-o", compiledPath]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected hosted compiler entrypoint compile to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            absoluteCompiledPath <- makeAbsolute compiledPath
            let trailingCommaSource :: Text
                trailingCommaSource = trailingCommaStructuredSource
                runtimeScript :: Text
                runtimeScript =
                  T.unlines
                    [ "import { pathToFileURL } from \"node:url\";"
                    , "const compiledModule = await import(pathToFileURL(" <> T.pack (show absoluteCompiledPath) <> ").href);"
                    , "const source = " <> T.pack (show trailingCommaSource) <> ";"
                    , "console.log(compiledModule.compileSourceText(source));"
                    ]
            runtimeOutput <- runNodeScript runtimeScript
            assertBool "expected trailing-comma record output" ("export const defaultUsers = [{ name: \"Ada\", active: true }];" `T.isInfixOf` runtimeOutput)
            assertBool "expected trailing-comma main output" ("export const main = defaultUsers;" `T.isInfixOf` runtimeOutput)
    , testCase "compiled hosted compiler handles block expressions and block-local declarations end to end" $ do
        let compiledPath = "dist/compiler-selfhost-blocks.mjs"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["compile", "src/Main.clasp", "-o", compiledPath]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected hosted compiler entrypoint compile to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            absoluteCompiledPath <- makeAbsolute compiledPath
            let runtimeScript =
                  T.unlines
                    [ "import { pathToFileURL } from \"node:url\";"
                    , "const compiledModule = await import(pathToFileURL(" <> T.pack (show absoluteCompiledPath) <> ").href);"
                    , "const blockSource = " <> T.pack (show blockLocalDeclarationsSource) <> ";"
                    , "console.log(JSON.stringify({"
                    , "  checked: compiledModule.checkSourceText(blockSource),"
                    , "  compiled: compiledModule.compileSourceText(blockSource)"
                    , "}));"
                    ]
            runtimeOutput <- runNodeScript runtimeScript
            runtimeValue <- case eitherDecodeStrictText runtimeOutput of
              Left decodeErr ->
                assertFailure ("expected hosted compiler block runtime output json to decode:\n" <> decodeErr)
              Right value ->
                pure value
            assertEqual
              "expected hosted block check output"
              (Just (String "greeting : Str"))
              (lookupObjectKey "checked" runtimeValue)
            case lookupObjectKey "compiled" runtimeValue of
              Just (String compiledText) -> do
                assertBool "expected hosted block local message binding" ("const message = \"Ada\";" `T.isInfixOf` compiledText)
                assertBool "expected hosted block local alias binding" ("const alias = message;" `T.isInfixOf` compiledText)
                assertBool "expected hosted block local return" ("return alias;" `T.isInfixOf` compiledText)
              _ ->
                assertFailure "expected compiled block text"
    , testCase "compiled hosted compiler handles mutable block assignments end to end" $ do
        let compiledPath = "dist/compiler-selfhost-mutable-blocks.mjs"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["compile", "src/Main.clasp", "-o", compiledPath]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected hosted compiler entrypoint compile to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            absoluteCompiledPath <- makeAbsolute compiledPath
            let runtimeScript =
                  T.unlines
                    [ "import { pathToFileURL } from \"node:url\";"
                    , "const compiledModule = await import(pathToFileURL(" <> T.pack (show absoluteCompiledPath) <> ").href);"
                    , "const mutableBlockSource = " <> T.pack (show mutableBlockAssignmentSource) <> ";"
                    , "console.log(JSON.stringify({"
                    , "  compiled: compiledModule.compileSourceText(mutableBlockSource),"
                    , "  native: compiledModule.nativeSourceText(mutableBlockSource)"
                    , "}));"
                    ]
            runtimeOutput <- runNodeScript runtimeScript
            runtimeValue <- case eitherDecodeStrictText runtimeOutput of
              Left decodeErr ->
                assertFailure ("expected hosted compiler mutable block runtime output json to decode:\n" <> decodeErr)
              Right value ->
                pure value
            case lookupObjectKey "compiled" runtimeValue of
              Just (String compiledText) -> do
                assertBool "expected hosted mutable block initial binding" ("let message = \"Ada\";" `T.isInfixOf` compiledText)
                assertBool "expected hosted mutable block reassignment" ("message = \"Grace\";" `T.isInfixOf` compiledText)
                assertBool "expected hosted mutable block return" ("return message;" `T.isInfixOf` compiledText)
              _ ->
                assertFailure "expected compiled mutable block text"
            case lookupObjectKey "native" runtimeValue of
              Just (String nativeText) -> do
                assertBool "expected hosted mutable block native binding" ("let.mutable message = string(\"Ada\")" `T.isInfixOf` nativeText)
                assertBool "expected hosted mutable block native assignment" ("assign message = string(\"Grace\") then local(message)" `T.isInfixOf` nativeText)
              _ ->
                assertFailure "expected native mutable block text"
    , testCase "compiled hosted compiler handles for-loops over list and string values end to end" $ do
        let compiledPath = "dist/compiler-selfhost-for-loops.mjs"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["compile", "src/Main.clasp", "-o", compiledPath]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected hosted compiler entrypoint compile to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            absoluteCompiledPath <- makeAbsolute compiledPath
            let runtimeScript =
                  T.unlines
                    [ "import { pathToFileURL } from \"node:url\";"
                    , "const compiledModule = await import(pathToFileURL(" <> T.pack (show absoluteCompiledPath) <> ").href);"
                    , "const listLoopSource = " <> T.pack (show loopIterationSource) <> ";"
                    , "const stringLoopSource = " <> T.pack (show stringLoopIterationSource) <> ";"
                    , "console.log(JSON.stringify({"
                    , "  checked: compiledModule.checkSourceText(listLoopSource),"
                    , "  compiled: compiledModule.compileSourceText(listLoopSource),"
                    , "  listNative: compiledModule.nativeSourceText(listLoopSource),"
                    , "  stringNative: compiledModule.nativeSourceText(stringLoopSource)"
                    , "}));"
                    ]
            runtimeOutput <- runNodeScript runtimeScript
            runtimeValue <- case eitherDecodeStrictText runtimeOutput of
              Left decodeErr ->
                assertFailure ("expected hosted compiler loop runtime output json to decode:\n" <> decodeErr)
              Right value ->
                pure value
            assertEqual
              "expected hosted list loop check output"
              (Just (String "pickLast : [Str] -> Str"))
              (lookupObjectKey "checked" runtimeValue)
            case lookupObjectKey "compiled" runtimeValue of
              Just (String compiledText) -> do
                assertBool "expected hosted loop compile mutable binding" ("let current = \"nobody\";" `T.isInfixOf` compiledText)
                assertBool "expected hosted loop compile for-of" ("for (const name of names)" `T.isInfixOf` compiledText)
                assertBool "expected hosted loop compile assignment" ("current = name;" `T.isInfixOf` compiledText)
              _ ->
                assertFailure "expected compiled loop text"
            case lookupObjectKey "listNative" runtimeValue of
              Just (String nativeText) ->
                assertBool "expected hosted list loop native for_each" ("for_each name in local(names) do assign current = local(name) then local(current) then local(current)" `T.isInfixOf` nativeText)
              _ ->
                assertFailure "expected listNative field"
            case lookupObjectKey "stringNative" runtimeValue of
              Just (String nativeText) ->
                assertBool "expected hosted string loop native for_each" ("for_each char in local(name) do assign current = local(char) then local(current) then local(current)" `T.isInfixOf` nativeText)
              _ ->
                assertFailure "expected stringNative field"
    , testCase "compiled hosted compiler handles early returns end to end" $ do
        let compiledPath = "dist/compiler-selfhost-early-return.mjs"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["compile", "src/Main.clasp", "-o", compiledPath]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected hosted compiler entrypoint compile to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            absoluteCompiledPath <- makeAbsolute compiledPath
            let runtimeScript =
                  T.unlines
                    [ "import { pathToFileURL } from \"node:url\";"
                    , "const compiledModule = await import(pathToFileURL(" <> T.pack (show absoluteCompiledPath) <> ").href);"
                    , "const returnSource = " <> T.pack (show earlyReturnSource) <> ";"
                    , "const loopReturnSource = " <> T.pack (show loopEarlyReturnSource) <> ";"
                    , "console.log(JSON.stringify({"
                    , "  checked: compiledModule.checkSourceText(returnSource),"
                    , "  compiled: compiledModule.compileSourceText(returnSource),"
                    , "  loopCompiled: compiledModule.compileSourceText(loopReturnSource),"
                    , "  native: compiledModule.nativeSourceText(returnSource),"
                    , "  loopNative: compiledModule.nativeSourceText(loopReturnSource)"
                    , "}));"
                    ]
            runtimeOutput <- runNodeScript runtimeScript
            runtimeValue <- case eitherDecodeStrictText runtimeOutput of
              Left decodeErr ->
                assertFailure ("expected hosted compiler early return runtime output json to decode:\n" <> decodeErr)
              Right value ->
                pure value
            case lookupObjectKey "checked" runtimeValue of
              Just (String checkedText) ->
                assertBool "expected hosted early return check output" ("choose : Decision -> Str -> Str" `T.isInfixOf` checkedText)
              _ ->
                assertFailure "expected checked early return text"
            case lookupObjectKey "compiled" runtimeValue of
              Just (String compiledText) -> do
                assertBool "expected hosted early return helper" ("function $claspEarlyReturn(value)" `T.isInfixOf` compiledText)
                assertBool "expected hosted early return catch wrapper" ("if (error && error.$claspEarlyReturn === true)" `T.isInfixOf` compiledText)
                assertBool "expected hosted early return throw" ("throw $claspEarlyReturn(alias)" `T.isInfixOf` compiledText)
              _ ->
                assertFailure "expected compiled early return text"
            case lookupObjectKey "loopCompiled" runtimeValue of
              Just (String compiledText) -> do
                assertBool "expected hosted loop early return helper" ("function $claspEarlyReturn(value)" `T.isInfixOf` compiledText)
                assertBool "expected hosted loop early return throw" ("throw $claspEarlyReturn(\"stopped\")" `T.isInfixOf` compiledText)
                assertBool "expected hosted loop early return for-of" ("for (const decision of decisions)" `T.isInfixOf` compiledText)
              _ ->
                assertFailure "expected compiled loop early return text"
            case lookupObjectKey "native" runtimeValue of
              Just (String nativeText) ->
                assertBool "expected hosted native early return" ("return(local(alias))" `T.isInfixOf` nativeText)
              _ ->
                assertFailure "expected native early return text"
            case lookupObjectKey "loopNative" runtimeValue of
              Just (String nativeText) ->
                assertBool "expected hosted native loop early return" ("return(string(\"stopped\"))" `T.isInfixOf` nativeText)
              _ ->
                assertFailure "expected native loop early return text"
    , testCase "compiled hosted compiler handles if expressions end to end" $ do
        let compiledPath = "dist/compiler-selfhost-if.mjs"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["compile", "src/Main.clasp", "-o", compiledPath]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected hosted compiler entrypoint compile to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            absoluteCompiledPath <- makeAbsolute compiledPath
            let runtimeScript =
                  T.unlines
                    [ "import { pathToFileURL } from \"node:url\";"
                    , "const compiledModule = await import(pathToFileURL(" <> T.pack (show absoluteCompiledPath) <> ").href);"
                    , "const ifSource = " <> T.pack (show ifExpressionSource) <> ";"
                    , "console.log(JSON.stringify({"
                    , "  checked: compiledModule.checkSourceText(ifSource),"
                    , "  compiled: compiledModule.compileSourceText(ifSource),"
                    , "  native: compiledModule.nativeSourceText(ifSource)"
                    , "}));"
                    ]
            runtimeOutput <- runNodeScript runtimeScript
            runtimeValue <- case eitherDecodeStrictText runtimeOutput of
              Left decodeErr ->
                assertFailure ("expected hosted compiler if runtime output json to decode:\n" <> decodeErr)
              Right value ->
                pure value
            assertEqual
              "expected hosted if check output"
              (Just (String "isReady : Bool\nmain : Str"))
              (lookupObjectKey "checked" runtimeValue)
            case lookupObjectKey "compiled" runtimeValue of
              Just (String compiledText) -> do
                assertBool "expected hosted if compile bool global" ("export const isReady = true;" `T.isInfixOf` compiledText)
                assertBool "expected hosted if compile condition" ("if (isReady) {" `T.isInfixOf` compiledText)
                assertBool "expected hosted if compile else branch" ("return \"waiting\";" `T.isInfixOf` compiledText)
              _ ->
                assertFailure "expected compiled if text"
            case lookupObjectKey "native" runtimeValue of
              Just (String nativeText) -> do
                assertBool "expected hosted if native bool global" ("global isReady = bool(true)" `T.isInfixOf` nativeText)
                assertBool "expected hosted if native conditional" ("global main = if local(isReady) then string(\"ready\") else string(\"waiting\")" `T.isInfixOf` nativeText)
              _ ->
                assertFailure "expected native if text"
    , testCase "compiled hosted compiler handles equality and integer comparisons end to end" $ do
        let compiledPath = "dist/compiler-selfhost-operators.mjs"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["compile", "src/Main.clasp", "-o", compiledPath]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected hosted compiler entrypoint compile to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            absoluteCompiledPath <- makeAbsolute compiledPath
            let runtimeScript =
                  T.unlines
                    [ "import { pathToFileURL } from \"node:url\";"
                    , "const compiledModule = await import(pathToFileURL(" <> T.pack (show absoluteCompiledPath) <> ").href);"
                    , "const equalitySource = " <> T.pack (show equalitySource) <> ";"
                    , "const comparisonSource = " <> T.pack (show integerComparisonSource) <> ";"
                    , "console.log(JSON.stringify({"
                    , "  equalityJs: compiledModule.compileSourceText(equalitySource),"
                    , "  comparisonNative: compiledModule.nativeSourceText(comparisonSource)"
                    , "}));"
                    ]
            runtimeOutput <- runNodeScript runtimeScript
            runtimeValue <- case eitherDecodeStrictText runtimeOutput of
              Left decodeErr ->
                assertFailure ("expected hosted compiler operator runtime output json to decode:\n" <> decodeErr)
              Right value ->
                pure value
            case lookupObjectKey "equalityJs" runtimeValue of
              Just (String compiledText) -> do
                assertBool "expected hosted equality js strict equality" ("(left === right)" `T.isInfixOf` compiledText)
                assertBool "expected hosted equality js strict inequality" ("(left !== right)" `T.isInfixOf` compiledText)
              _ ->
                assertFailure "expected equalityJs field"
            case lookupObjectKey "comparisonNative" runtimeValue of
              Just (String nativeText) -> do
                assertBool "expected hosted native less-than comparison" ("compare.lt(local(left), local(right))" `T.isInfixOf` nativeText)
                assertBool "expected hosted native less-than-or-equal comparison" ("compare.le(local(left), local(right))" `T.isInfixOf` nativeText)
                assertBool "expected hosted native greater-than comparison" ("compare.gt(local(left), local(right))" `T.isInfixOf` nativeText)
                assertBool "expected hosted native greater-than-or-equal comparison" ("compare.ge(local(left), local(right))" `T.isInfixOf` nativeText)
              _ ->
                assertFailure "expected comparisonNative field"
    , testCase "claspc compile prefers the hosted Clasp compiler for the hosted compiler entrypoint" $ do
        let compiledPath = "dist/compiler-selfhost-json.mjs"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["compile", "src/Main.clasp", "-o", compiledPath, "--json"]
        case exitCode of
          ExitSuccess ->
            pure ()
          ExitFailure _ ->
            assertFailure ("expected hosted primary compiler compile to succeed:\n" <> stdoutText <> stderrText)
        jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
          Left decodeErr ->
            assertFailure ("expected hosted compile json output to decode:\n" <> decodeErr)
          Right value ->
            pure value
        assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
        assertEqual "command" (Just (String "compile")) (lookupObjectKey "command" jsonValue)
        assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
    , testCase "claspc native prefers the hosted Clasp compiler for the hosted compiler entrypoint" $ do
        let outputPath = "dist/compiler-selfhost.native.ir"
        createDirectoryIfMissing True (takeDirectory outputPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["native", "src/Main.clasp", "-o", outputPath, "--json"]
        case exitCode of
          ExitSuccess ->
            pure ()
          ExitFailure _ ->
            assertFailure ("expected hosted primary compiler native emission to succeed:\n" <> stdoutText <> stderrText)
        jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
          Left decodeErr ->
            assertFailure ("expected hosted native json output to decode:\n" <> decodeErr)
          Right value ->
            pure value
        assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
        assertEqual "command" (Just (String "native")) (lookupObjectKey "command" jsonValue)
        assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
        nativeIr <- TIO.readFile outputPath
        assertBool "expected hosted native bootstrap artifact format header" ("format clasp-native-ir-v1" `T.isInfixOf` nativeIr)
        assertBool "expected hosted native bootstrap artifact module header" ("module Main" `T.isInfixOf` nativeIr)
        assertBool "expected hosted native bootstrap artifact compiler snapshot layout" ("record_layout HostedCompilerSnapshot" `T.isInfixOf` nativeIr)
    , testCase "claspc native supports simple ordinary programs on the hosted Clasp path" $ do
        let outputPath = "dist/hello-default.native.ir"
        createDirectoryIfMissing True (takeDirectory outputPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["native", "examples/hello.clasp", "-o", outputPath, "--json"]
        case exitCode of
          ExitSuccess ->
            pure ()
          ExitFailure _ ->
            assertFailure ("expected hosted primary compiler native emission for a simple ordinary program to succeed:\n" <> stdoutText <> stderrText)
        jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
          Left decodeErr ->
            assertFailure ("expected hosted ordinary native json output to decode:\n" <> decodeErr)
          Right value ->
            pure value
        assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
        assertEqual "command" (Just (String "native")) (lookupObjectKey "command" jsonValue)
        assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
        nativeIr <- TIO.readFile outputPath
        assertBool "expected hosted ordinary native format header" ("format clasp-native-ir-v1" `T.isInfixOf` nativeIr)
        assertBool "expected hosted ordinary native global" ("global hello = string(\"Hello from Clasp\")" `T.isInfixOf` nativeIr)
        assertBool "expected hosted ordinary native exports to stay source-shaped" ("exports [hello, id, main]" `T.isInfixOf` nativeIr)
        assertBool "expected hosted ordinary native output to omit builtin Result layout noise" ("variant_layout Result" `T.isInfixOf` nativeIr == False)
    , testCase "renderNativeEntryWithPreference Auto prefers the hosted Clasp compiler for simple ordinary projects" $ do
        (implementation, result) <- renderNativeEntryWithPreference CompilerPreferenceAuto ("examples" </> "hello.clasp")
        assertEqual "implementation" CompilerImplementationClasp implementation
        case result of
          Left err ->
            assertFailure ("expected hosted auto native emission for a simple ordinary project to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right nativeIr -> do
            assertBool "expected hosted ordinary native format header" ("format clasp-native-ir-v1" `T.isInfixOf` nativeIr)
            assertBool "expected hosted ordinary native global" ("global hello = string(\"Hello from Clasp\")" `T.isInfixOf` nativeIr)
    , testCase "claspc native supports explicit Clasp-primary requests for ordinary if programs" $
        withProjectFiles "native-primary-if" [("Main.clasp", ifExpressionSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.native.ir"
          (exitCode, stdoutText, stderrText) <- runClaspc ["native", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler native if request to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted if native json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "native")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          nativeIr <- TIO.readFile outputPath
          assertBool "expected hosted if native bool global" ("global isReady = bool(true)" `T.isInfixOf` nativeIr)
          assertBool "expected hosted if native conditional" ("global main = if local(isReady) then string(\"ready\") else string(\"waiting\")" `T.isInfixOf` nativeIr)
    , testCase "claspc native supports explicit Clasp-primary requests for integer comparison programs" $
        withProjectFiles "native-primary-comparisons" [("Main.clasp", integerComparisonSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.native.ir"
          (exitCode, stdoutText, stderrText) <- runClaspc ["native", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler native comparison request to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted comparison native json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "native")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          nativeIr <- TIO.readFile outputPath
          assertBool "expected hosted native less-than comparison" ("compare.lt(local(left), local(right))" `T.isInfixOf` nativeIr)
          assertBool "expected hosted native greater-than-or-equal comparison" ("compare.ge(local(left), local(right))" `T.isInfixOf` nativeIr)
    , testCase "claspc native supports explicit Clasp-primary requests for block-local declarations" $
        withProjectFiles "native-primary-block-locals" [("Main.clasp", blockLocalDeclarationsSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.native.ir"
          (exitCode, stdoutText, stderrText) <- runClaspc ["native", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler native block request to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted block native json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "native")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          nativeIr <- TIO.readFile outputPath
          assertBool "expected hosted block native first binding" ("let.immutable message = string(\"Ada\")" `T.isInfixOf` nativeIr)
          assertBool "expected hosted block native second binding" ("let.immutable alias = local(message)" `T.isInfixOf` nativeIr)
    , testCase "claspc native supports explicit Clasp-primary requests for mutable block assignments" $
        withProjectFiles "native-primary-mutable-block" [("Main.clasp", mutableBlockAssignmentSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.native.ir"
          (exitCode, stdoutText, stderrText) <- runClaspc ["native", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler native mutable block request to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted mutable block native json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "native")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          nativeIr <- TIO.readFile outputPath
          assertBool "expected hosted mutable block native binding" ("let.mutable message = string(\"Ada\")" `T.isInfixOf` nativeIr)
          assertBool "expected hosted mutable block native assignment" ("assign message = string(\"Grace\") then local(message)" `T.isInfixOf` nativeIr)
    , testCase "claspc native supports explicit Clasp-primary requests for for-loops over list values" $
        withProjectFiles "native-primary-for-loop" [("Main.clasp", loopIterationSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.native.ir"
          (exitCode, stdoutText, stderrText) <- runClaspc ["native", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler native for-loop request to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted for-loop native json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "native")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          nativeIr <- TIO.readFile outputPath
          assertBool "expected hosted loop native mutable binding" ("let.mutable current = string(\"nobody\")" `T.isInfixOf` nativeIr)
          assertBool "expected hosted loop native for_each" ("for_each name in local(names) do assign current = local(name) then local(current) then local(current)" `T.isInfixOf` nativeIr)
    , testCase "claspc native supports explicit Clasp-primary requests for for-loops over string values" $
        withProjectFiles "native-primary-string-for-loop" [("Main.clasp", stringLoopIterationSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.native.ir"
          (exitCode, stdoutText, stderrText) <- runClaspc ["native", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler native string for-loop request to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted string for-loop native json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "native")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          nativeIr <- TIO.readFile outputPath
          assertBool "expected hosted string loop native mutable binding" ("let.mutable current = string(\"\")" `T.isInfixOf` nativeIr)
          assertBool "expected hosted string loop native for_each" ("for_each char in local(name) do assign current = local(char) then local(current) then local(current)" `T.isInfixOf` nativeIr)
    , testCase "claspc native supports explicit Clasp-primary requests for early returns" $
        withProjectFiles "native-primary-early-return" [("Main.clasp", earlyReturnSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.native.ir"
          (exitCode, stdoutText, stderrText) <- runClaspc ["native", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler native early return request to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted early return native json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "native")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          nativeIr <- TIO.readFile outputPath
          assertBool "expected hosted early return native match" ("match local(decision)" `T.isInfixOf` nativeIr)
          assertBool "expected hosted early return native return" ("return(local(alias))" `T.isInfixOf` nativeIr)
    , testCase "claspc native supports explicit Clasp-primary requests for imported record projects" $
        withProjectFiles "native-primary-record-imports-unsupported" importSuccessFiles $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.native.ir"
          (exitCode, stdoutText, stderrText) <- runClaspc ["native", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler native request to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted imported native json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "native")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          nativeIr <- TIO.readFile outputPath
          assertBool "expected hosted imported native module header" ("module Main" `T.isInfixOf` nativeIr)
          assertBool "expected hosted imported native record layout" ("record_layout User" `T.isInfixOf` nativeIr)
          assertBool "expected hosted imported typed field access" ("function formatUser(user) = field(User, local(user), name)" `T.isInfixOf` nativeIr)
          assertBool "expected hosted imported native main call" ("global main = call(local(formatUser), [local(defaultUser)])" `T.isInfixOf` nativeIr)
    , testCase "claspc native supports explicit Clasp-primary requests for ordinary ADT programs" $
        withProjectFiles "native-primary-adt" [("Main.clasp", hostedNativeDecisionSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.native.ir"
          (exitCode, stdoutText, stderrText) <- runClaspc ["native", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler native ADT request to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted ADT native json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "native")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          nativeIr <- TIO.readFile outputPath
          assertBool "expected hosted ADT native variant layout" ("variant_layout Decision { tag_word = 0, max_payload_words = 2, words = 3, constructors = [Keep{tag_word=0, payload_words=2, words=3, payloads=[$0:Str@word1/handle, $1:Str@word2/handle]}, Drop{tag_word=0, payload_words=0, words=1, payloads=[]}] }" `T.isInfixOf` nativeIr)
          assertBool "expected hosted ADT native object layout" ("object_layout Decision.Keep { kind = variant, header_words = 2, words = 5, roots = [3, 4] }" `T.isInfixOf` nativeIr)
          assertBool "expected hosted ADT native constructor call" ("global main = call(local(choose), [call(local(Keep), [string(\"alpha\"), string(\"beta\")])])" `T.isInfixOf` nativeIr)
    , testCase "claspc compile supports simple ordinary programs on the hosted Clasp path" $ do
        let compiledPath = "dist/hello-default.mjs"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["compile", "examples/hello.clasp", "-o", compiledPath, "--json"]
        case exitCode of
          ExitSuccess ->
            pure ()
          ExitFailure _ ->
            assertFailure ("expected hosted primary compiler compile for a simple ordinary program to succeed:\n" <> stdoutText <> stderrText)
        jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
          Left decodeErr ->
            assertFailure ("expected hosted ordinary compile json output to decode:\n" <> decodeErr)
          Right value ->
            pure value
        assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
        assertEqual "command" (Just (String "compile")) (lookupObjectKey "command" jsonValue)
        assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
        compiledJs <- TIO.readFile compiledPath
        assertBool "expected hosted ordinary compile output" ("export const hello = \"Hello from Clasp\";" `T.isInfixOf` compiledJs)
    , testCase "claspc compile supports explicit Clasp-primary requests for ordinary if programs" $
        withProjectFiles "compile-primary-if" [("Main.clasp", ifExpressionSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.mjs"
          (exitCode, stdoutText, stderrText) <- runClaspc ["compile", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler compile for if programs to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted if compile json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "compile")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          compiledJs <- TIO.readFile outputPath
          assertBool "expected hosted if compile condition" ("if (isReady) {" `T.isInfixOf` compiledJs)
          assertBool "expected hosted if compile then branch" ("return \"ready\";" `T.isInfixOf` compiledJs)
          assertBool "expected hosted if compile else branch" ("return \"waiting\";" `T.isInfixOf` compiledJs)
    , testCase "claspc compile supports explicit Clasp-primary requests for equality programs" $
        withProjectFiles "compile-primary-equality" [("Main.clasp", equalitySource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.mjs"
          (exitCode, stdoutText, stderrText) <- runClaspc ["compile", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler compile for equality programs to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted equality compile json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "compile")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          compiledJs <- TIO.readFile outputPath
          assertBool "expected hosted equality strict equality" ("(left === right)" `T.isInfixOf` compiledJs)
          assertBool "expected hosted equality strict inequality" ("(left !== right)" `T.isInfixOf` compiledJs)
    , testCase "claspc compile supports explicit Clasp-primary requests for block-local declarations" $
        withProjectFiles "compile-primary-block-locals" [("Main.clasp", blockLocalDeclarationsSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.mjs"
          (exitCode, stdoutText, stderrText) <- runClaspc ["compile", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler compile for block locals to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted block compile json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "compile")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          compiledJs <- TIO.readFile outputPath
          assertBool "expected hosted block compile first binding" ("const message = \"Ada\";" `T.isInfixOf` compiledJs)
          assertBool "expected hosted block compile second binding" ("const alias = message;" `T.isInfixOf` compiledJs)
          assertBool "expected hosted block compile return" ("return alias;" `T.isInfixOf` compiledJs)
    , testCase "claspc compile supports explicit Clasp-primary requests for mutable block assignments" $
        withProjectFiles "compile-primary-mutable-block" [("Main.clasp", mutableBlockAssignmentSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.mjs"
          (exitCode, stdoutText, stderrText) <- runClaspc ["compile", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler compile for mutable blocks to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted mutable block compile json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "compile")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          compiledJs <- TIO.readFile outputPath
          assertBool "expected hosted mutable block compile binding" ("let message = \"Ada\";" `T.isInfixOf` compiledJs)
          assertBool "expected hosted mutable block compile assignment" ("message = \"Grace\";" `T.isInfixOf` compiledJs)
          assertBool "expected hosted mutable block compile return" ("return message;" `T.isInfixOf` compiledJs)
    , testCase "claspc compile supports explicit Clasp-primary requests for for-loops over list values" $
        withProjectFiles "compile-primary-for-loop" [("Main.clasp", loopIterationSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.mjs"
          (exitCode, stdoutText, stderrText) <- runClaspc ["compile", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler compile for for-loops to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted for-loop compile json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "compile")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          compiledJs <- TIO.readFile outputPath
          assertBool "expected hosted loop compile mutable binding" ("let current = \"nobody\";" `T.isInfixOf` compiledJs)
          assertBool "expected hosted loop compile for-of" ("for (const name of names)" `T.isInfixOf` compiledJs)
          assertBool "expected hosted loop compile assignment" ("current = name;" `T.isInfixOf` compiledJs)
    , testCase "claspc compile supports explicit Clasp-primary requests for loop early returns" $
        withProjectFiles "compile-primary-loop-early-return" [("Main.clasp", loopEarlyReturnSource)] $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.mjs"
          (exitCode, stdoutText, stderrText) <- runClaspc ["compile", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler compile for loop early returns to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted loop early return compile json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "compile")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          compiledJs <- TIO.readFile outputPath
          assertBool "expected hosted loop early return helper" ("function $claspEarlyReturn(value)" `T.isInfixOf` compiledJs)
          assertBool "expected hosted loop early return catch" ("if (error && error.$claspEarlyReturn === true)" `T.isInfixOf` compiledJs)
          assertBool "expected hosted loop early return throw" ("throw $claspEarlyReturn(\"stopped\")" `T.isInfixOf` compiledJs)
    , testCase "claspc compile rejects deprecated bootstrap compiler selection" $ do
        let compiledPath = "dist/hello-bootstrap.mjs"
        createDirectoryIfMissing True (takeDirectory compiledPath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["compile", "examples/hello.clasp", "-o", compiledPath, "--json", "--compiler=bootstrap"]
        case exitCode of
          ExitSuccess ->
            assertFailure ("expected deprecated bootstrap compiler selection to fail:\n" <> stdoutText <> stderrText)
          ExitFailure _ ->
            assertBool
              "expected bootstrap rejection message"
              ("deprecated compiler selection is gone" `isInfixOf` stdoutText || "deprecated compiler selection is gone" `isInfixOf` stderrText)
    , testCase "claspc compile supports imported subset projects on the hosted Clasp path" $
        withProjectFiles "compile-primary-import-success" importSuccessFiles $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.mjs"
          (exitCode, stdoutText, stderrText) <- runClaspc ["compile", inputPath, "-o", outputPath, "--json"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted primary compiler compile for an imported subset project to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted imported compile json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "compile")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          compiledJs <- TIO.readFile outputPath
          assertBool "expected hosted imported compile output" ("export const defaultUser = { name: \"Ada\", active: true };" `T.isInfixOf` compiledJs)
          assertBool "expected hosted imported compile main" ("export const main = formatUser(defaultUser);" `T.isInfixOf` compiledJs)
    , testCase "claspc compile keeps local binders ahead of imported globals on the hosted Clasp path" $
        withProjectFiles "compile-primary-shadowed-import-success" shadowedImportFiles $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.mjs"
          (exitCode, stdoutText, stderrText) <- runClaspc ["compile", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted primary compiler compile for a shadowed imported project to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted shadowed-import compile json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "compile")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          compiledJs <- TIO.readFile outputPath
          assertBool "expected hosted shadowed import compile parameter binding" ("export function render(declName) { return declName; }" `T.isInfixOf` compiledJs)
          assertBool "expected hosted shadowed import compile main" ("export const main = render(\"local\");" `T.isInfixOf` compiledJs)
    , testCase "claspc compile supports explicit Clasp-primary requests for package-backed imports" $
        withProjectFiles "compile-primary-package-imports-unsupported" packageImportFiles $ \root -> do
          let inputPath = root </> "Main.clasp"
              outputPath = root </> "main.mjs"
          (exitCode, stdoutText, stderrText) <- runClaspc ["compile", inputPath, "-o", outputPath, "--json", "--compiler=clasp"]
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected explicit hosted primary compiler compile for package-backed imports to succeed:\n" <> stdoutText <> stderrText)
          jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
            Left decodeErr ->
              assertFailure ("expected hosted package-import compile json output to decode:\n" <> decodeErr)
            Right value ->
              pure value
          assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
          assertEqual "command" (Just (String "compile")) (lookupObjectKey "command" jsonValue)
          assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
          compiledJs <- TIO.readFile outputPath
          assertBool "expected hosted package npm import" ("import { upperCase as $claspPackageBinding_upperCase } from \"local-upper\";" `T.isInfixOf` compiledJs)
          assertBool "expected hosted package ts import" ("import { formatLead as $claspPackageBinding_formatLead } from \"./support/formatLead.mjs\";" `T.isInfixOf` compiledJs)
          assertBool "expected hosted package imports export" ("export const __claspPackageImports = [" `T.isInfixOf` compiledJs)
          assertBool "expected hosted package host bindings export" ("export function __claspPackageHostBindings()" `T.isInfixOf` compiledJs)
          assertBool "expected hosted package signature metadata" ("signature: \"export declare function upperCase(value: string): string;\"" `T.isInfixOf` compiledJs)
          absoluteCompiledPath <- makeAbsolute outputPath
          absoluteRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
          runtimeOutput <- runNodeScript (hostedPackageImportRuntimeScript absoluteCompiledPath absoluteRuntimePath)
          assertEqual
            "expected hosted package-backed foreign declarations to execute through emitted imports"
            "{\"formatted\":\"Acme Labs:7\",\"upper\":\"HELLO ADA\"}"
            runtimeOutput
    , testCase "compileEntryWithPreference Auto falls back to bootstrap for package-backed subset projects" $
        withProjectFiles "compile-entry-auto-package-imports" packageImportFiles $ \root -> do
          let inputPath = root </> "Main.clasp"
          (implementation, result) <- compileEntryWithPreference CompilerPreferenceAuto inputPath
          assertEqual "implementation" CompilerImplementationBootstrap implementation
          case result of
            Left err ->
              assertFailure ("expected auto compile with bootstrap fallback to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
            Right compiledJs -> do
              assertBool "expected package imports export" ("export const __claspPackageImports = [" `T.isInfixOf` compiledJs)
              assertBool "expected package host bindings export" ("export function __claspPackageHostBindings()" `T.isInfixOf` compiledJs)
    , testCase "compileEntryWithPreference Auto prefers the hosted Clasp compiler for simple ordinary projects" $ do
        (implementation, result) <- compileEntryWithPreference CompilerPreferenceAuto ("examples" </> "hello.clasp")
        assertEqual "implementation" CompilerImplementationClasp implementation
        case result of
          Left err ->
            assertFailure ("expected hosted auto compile for a simple ordinary project to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right compiledJs ->
            assertBool "expected hosted ordinary compile output" ("export const hello = \"Hello from Clasp\";" `T.isInfixOf` compiledJs)
    , testCase "compileEntryWithPreference Auto rejects backend control-plane projects and requires native" $ do
        (implementation, result) <- compileEntryWithPreference CompilerPreferenceAuto ("examples" </> "control-plane" </> "Main.clasp")
        assertEqual "implementation" CompilerImplementationClasp implementation
        assertHasCode "E_BACKEND_TARGET_REQUIRES_NATIVE" result
    , testCase "claspc native emits companion native image artifacts for backend workflow projects" $ do
        let nativePath = "dist/durable-workflow.native.ir"
            imagePath = replaceExtension nativePath "native.image.json"
        createDirectoryIfMissing True (takeDirectory nativePath)
        (exitCode, stdoutText, stderrText) <- runClaspc ["native", "examples/durable-workflow/Main.clasp", "-o", nativePath, "--json"]
        case exitCode of
          ExitFailure _ ->
            assertFailure ("expected backend workflow native emission to succeed:\n" <> stdoutText <> stderrText)
          ExitSuccess -> do
            jsonValue <- case eitherDecodeStrictText (T.pack stdoutText) of
              Left decodeErr ->
                assertFailure ("expected backend workflow native json output to decode:\n" <> decodeErr)
              Right value ->
                pure value
            assertEqual "status" (Just (String "ok")) (lookupObjectKey "status" jsonValue)
            assertEqual "command" (Just (String "native")) (lookupObjectKey "command" jsonValue)
            assertEqual "output" (Just (String (T.pack nativePath))) (lookupObjectKey "output" jsonValue)
            assertEqual "native" (Just (String (T.pack nativePath))) (lookupObjectKey "native" jsonValue)
            assertEqual "image" (Just (String (T.pack imagePath))) (lookupObjectKey "image" jsonValue)
            nativeExists <- doesFileExist nativePath
            imageExists <- doesFileExist imagePath
            assertEqual "implementation" (Just (String "clasp")) (lookupObjectKey "implementation" jsonValue)
            assertBool "expected native ir artifact" nativeExists
            assertBool "expected native image artifact" imageExists
    , testCase "hosted native tool runner rejects compiler artifacts that do not expose the requested command" $
        withProjectFiles "hosted-tool-runner-entrypoint" [("Fake.clasp", "module Main\n\nmain : Str\nmain = \"fake\"\n")] $ \root -> do
          let stage1IrPath = root </> "Fake.native.ir"
              stage1ImagePath = replaceExtension stage1IrPath "native.image.json"
              resultPath = root </> "result.txt"
          (compileExitCode, compileStdout, compileStderr) <- runClaspc ["native", root </> "Fake.clasp", "-o", stage1IrPath]
          case compileExitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected bootstrap native compile for hosted runner setup to succeed:\n" <> compileStdout <> compileStderr)
          (exitCode, _stdoutText, stderrText) <-
            readProcessWithExitCode
              "bash"
              [ "src/scripts/run-native-tool.sh"
              , stage1ImagePath
              , "checkEntrypoint"
              , resultPath
              ]
              ""
          case exitCode of
            ExitSuccess ->
              assertFailure "expected hosted native tool runner to reject a compiler artifact without the requested command support"
            ExitFailure _ ->
              assertBool "expected hosted native tool runner to report missing export support" ("runtime failed to execute native compiler export" `isInfixOf` stderrText)
    , testCase "hosted native tool runner accepts ordinary native output without a bootstrap oracle" $
        withProjectFiles "hosted-native-tool-runner-native-no-bootstrap" [("Main.clasp", "module Main\n\nmain : Str\nmain = \"hello\"\n")] $ \root -> do
          stage1Path <- makeAbsolute "src/stage1.native.image.json"
          let resultPath = root </> "result.native.ir"
          (exitCode, _stdoutText, stderrText) <-
            readProcessWithExitCode
              "bash"
              [ "src/scripts/run-native-tool.sh"
              , stage1Path
              , "nativeSourceText"
              , root </> "Main.clasp"
              , resultPath
              ]
              ""
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted native tool runner without a bootstrap oracle to succeed:\n" <> stderrText)
          nativeIr <- TIO.readFile resultPath
          assertBool "expected hosted native format header" ("format clasp-native-ir-v1" `T.isInfixOf` nativeIr)
          assertBool "expected hosted native global" ("global main = string(\"hello\")" `T.isInfixOf` nativeIr)
    , testCase "hosted native tool runner accepts ordinary compile output without a bootstrap oracle" $
        withProjectFiles "hosted-native-tool-runner-compile-no-bootstrap" [("Main.clasp", "module Main\n\nmain : Str\nmain = \"hello\"\n")] $ \root -> do
          stage1Path <- makeAbsolute "src/stage1.native.image.json"
          let resultPath = root </> "result.mjs"
          (exitCode, _stdoutText, stderrText) <-
            readProcessWithExitCode
              "bash"
              [ "src/scripts/run-native-tool.sh"
              , stage1Path
              , "compileSourceText"
              , root </> "Main.clasp"
              , resultPath
              ]
              ""
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted native compile runner without a bootstrap oracle to succeed:\n" <> stderrText)
          compiledJs <- TIO.readFile resultPath
          assertBool "expected hosted compile output" ("export const main = \"hello\";" `T.isInfixOf` compiledJs)
    , testCase "hosted native tool runner rejects route-style backend source from frontend JS compile" $
        withProjectFiles "hosted-native-tool-runner-route-needs-native" [("Main.clasp", T.unlines ["module Main", "", "route inboxRoute = GET \"/inbox\" Empty -> Page inbox"])] $ \root -> do
          stage1Path <- makeAbsolute "src/stage1.native.image.json"
          let resultPath = root </> "result.mjs"
          (exitCode, _stdoutText, stderrText) <-
            readProcessWithExitCode
              "bash"
              [ "src/scripts/run-native-tool.sh"
              , stage1Path
              , "compileSourceText"
              , root </> "Main.clasp"
              , resultPath
              ]
              ""
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted native frontend compile guard to return a JS error stub:\n" <> stderrText)
          compiledJs <- TIO.readFile resultPath
          assertBool "expected frontend-only compile error" ("frontend-only compile error" `T.isInfixOf` compiledJs)
          assertBool "expected native entrypoint hint" ("nativeSourceText or nativeProjectText" `T.isInfixOf` compiledJs)
    , testCase "hosted native tool runner rejects backend workflow projects from frontend JS compile" $
        withProjectFiles "hosted-native-tool-runner-project-needs-native" [] $ \root -> do
          stage1Path <- makeAbsolute "src/stage1.native.image.json"
          workflowEntryPath <- makeAbsolute ("examples" </> "durable-workflow" </> "Main.clasp")
          let resultPath = root </> "result.mjs"
          (exitCode, _stdoutText, stderrText) <-
            readProcessWithExitCode
              "bash"
              [ "src/scripts/run-native-tool.sh"
              , stage1Path
              , "compileProjectText"
              , "--project-entry=" <> workflowEntryPath
              , resultPath
              ]
              ""
          case exitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted native project frontend compile guard to return a JS error stub:\n" <> stderrText)
          compiledJs <- TIO.readFile resultPath
          assertBool "expected frontend-only project compile error" ("frontend-only compile error" `T.isInfixOf` compiledJs)
          assertBool "expected native project entrypoint hint" ("nativeSourceText or nativeProjectText" `T.isInfixOf` compiledJs)
    , testCase "hosted native tool runner handles examples/hello.clasp end to end" $ do
        stage1Path <- makeAbsolute "src/stage1.native.image.json"
        helloExampleSource <- readExampleSource "hello.clasp"
        withProjectFiles "hosted-native-tool-runner-hello" [("Main.clasp", helloExampleSource)] $ \root -> do
          helloPath <- makeAbsolute (root </> "Main.clasp")
          let checkPath = root </> "hello.check"
          let checkCorePath = root </> "hello.core.json"
          let compilePath = root </> "hello.mjs"
          let nativePath = root </> "hello.native.ir"
          let nativeImagePath = root </> "hello.native.image.json"
          (checkExitCode, _checkStdout, checkStderr) <-
            readProcessWithExitCode
              "bash"
              [ "src/scripts/run-native-tool.sh"
              , stage1Path
              , "checkSourceText"
              , helloPath
              , checkPath
              ]
              ""
          case checkExitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted native hello check to succeed:\n" <> checkStderr)
          checkedSummary <- TIO.readFile checkPath
          assertBool "expected hello summary" ("hello : Str" `T.isInfixOf` checkedSummary)
          assertBool "expected id summary" ("id : Str -> Str" `T.isInfixOf` checkedSummary)
          assertBool "expected main summary" ("main : Str" `T.isInfixOf` checkedSummary)
          (checkCoreExitCode, _checkCoreStdout, checkCoreStderr) <-
            readProcessWithExitCode
              "bash"
              [ "src/scripts/run-native-tool.sh"
              , stage1Path
              , "checkCoreSourceText"
              , helloPath
              , checkCorePath
              ]
              ""
          case checkCoreExitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted native hello check-core to succeed:\n" <> checkCoreStderr)
          checkedCore <- TIO.readFile checkCorePath
          assertBool "expected checked-core decl tag" ("CheckedCoreDeclArtifact" `T.isInfixOf` checkedCore)
          assertBool "expected checked-core hello decl" ("\"hello\"" `T.isInfixOf` checkedCore)
          assertBool "expected checked-core main decl" ("\"main\"" `T.isInfixOf` checkedCore)
          (compileExitCode, _compileStdout, compileStderr) <-
            readProcessWithExitCode
              "bash"
              [ "src/scripts/run-native-tool.sh"
              , stage1Path
              , "compileSourceText"
              , helloPath
              , compilePath
              ]
              ""
          case compileExitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted native hello compile to succeed:\n" <> compileStderr)
          compiledJs <- TIO.readFile compilePath
          assertBool "expected hello const" ("export const hello = \"Hello from Clasp\";" `T.isInfixOf` compiledJs)
          assertBool "expected id function" ("export function id(v) { return v; }" `T.isInfixOf` compiledJs)
          assertBool "expected main call" ("export const main = id(hello);" `T.isInfixOf` compiledJs)
          (nativeExitCode, _nativeStdout, nativeStderr) <-
            readProcessWithExitCode
              "bash"
              [ "src/scripts/run-native-tool.sh"
              , stage1Path
              , "nativeSourceText"
              , helloPath
              , nativePath
              ]
              ""
          case nativeExitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted native hello native emit to succeed:\n" <> nativeStderr)
          nativeIr <- TIO.readFile nativePath
          assertBool "expected hello exports" ("exports [hello, id, main]" `T.isInfixOf` nativeIr)
          assertBool "expected hello native global" ("global hello = string(\"Hello from Clasp\")" `T.isInfixOf` nativeIr)
          assertBool "expected id native function" ("function id(v) = local(v)" `T.isInfixOf` nativeIr)
          assertBool "expected hello main native call" ("global main = call(local(id), [local(hello)])" `T.isInfixOf` nativeIr)
          assertBool "expected hello native output to omit builtin Result constructor exports" ("function Ok($0) = construct Ok(local($0))" `T.isInfixOf` nativeIr == False)
          (nativeImageExitCode, _nativeImageStdout, nativeImageStderr) <-
            readProcessWithExitCode
              "bash"
              [ "src/scripts/run-native-tool.sh"
              , stage1Path
              , "nativeImageSourceText"
              , helloPath
              , nativeImagePath
              ]
              ""
          case nativeImageExitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted native hello native-image emit to succeed:\n" <> nativeImageStderr)
          nativeImage <- TIO.readFile nativeImagePath
          assertBool "expected hello native image format" ("clasp-native-image-v1" `T.isInfixOf` nativeImage)
          assertBool "expected hello native image module" ("\"module\": \"Main\"" `T.isInfixOf` nativeImage)
          assertBool "expected hello native image main entry" ("\"name\": \"main\"" `T.isInfixOf` nativeImage)
    , testCase "hosted native tool runner rebuilds the hosted compiler project with native list append intrinsics" $ do
        stage1Path <- makeAbsolute "src/stage1.native.image.json"
        hostedCompilerPath <- makeAbsolute "src/Main.clasp"
        withProjectFiles "hosted-native-tool-runner-self-rebuild" [] $ \root -> do
          let nativePath = root </> "hosted.native.ir"
          let nativeImagePath = root </> "hosted.native.image.json"
          (nativeExitCode, _nativeStdout, nativeStderr) <-
            readProcessWithExitCode
              "bash"
              [ "src/scripts/run-native-tool.sh"
              , stage1Path
              , "nativeProjectText"
              , "--project-entry=" <> hostedCompilerPath
              , nativePath
              ]
              ""
          case nativeExitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted native self-rebuild to succeed:\n" <> nativeStderr)
          nativeIr <- TIO.readFile nativePath
          assertBool "expected hosted native self-rebuild to preserve list append intrinsics" ("intrinsic.list.append(" `T.isInfixOf` nativeIr)
          (nativeImageExitCode, _nativeImageStdout, nativeImageStderr) <-
            readProcessWithExitCode
              "bash"
              [ "src/scripts/run-native-tool.sh"
              , stage1Path
              , "nativeImageProjectText"
              , "--project-entry=" <> hostedCompilerPath
              , nativeImagePath
              ]
              ""
          case nativeImageExitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted native self-rebuild native image to succeed:\n" <> nativeImageStderr)
          nativeImage <- TIO.readFile nativeImagePath
          assertBool "expected hosted native self-rebuild native image to preserve list append intrinsics" ("\"name\": \"list.append\"" `T.isInfixOf` nativeImage)
    , testCase "promoted hosted native seed preserves escaped string literals across self-hosted compile" $ do
        stage1Path <- makeAbsolute "src/stage1.native.image.json"
        withProjectFiles "hosted-native-tool-runner-escaped-string" [("Main.clasp", "module Main\n\nmain : Str\nmain = textJoin \"\\n\" [\"left\", \"right\"]\n")] $ \root -> do
          let compilePath = root </> "escaped.mjs"
          (compileExitCode, _compileStdout, compileStderr) <-
            readProcessWithExitCode
              "bash"
              [ "src/scripts/run-native-tool.sh"
              , stage1Path
              , "compileSourceText"
              , root </> "Main.clasp"
              , compilePath
              ]
              ""
          case compileExitCode of
            ExitSuccess ->
              pure ()
            ExitFailure _ ->
              assertFailure ("expected hosted native compile with escaped string literals to succeed:\n" <> compileStderr)
          compiledJs <- TIO.readFile compilePath
          assertBool
            "expected escaped newline literal to survive the promoted hosted native seed"
            ("textJoin(\"\\n\", [\"left\", \"right\"])" `T.isInfixOf` compiledJs)
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
          Right emitted -> do
            assertBool "expected array literal" ("[\"Ada\", \"Grace\"]" `T.isInfixOf` emitted)
            assertBool "expected empty array literal" ("const emptyRoster = [];" `T.isInfixOf` emitted)
    , testCase "compile preserves nested empty lists once annotations fix the item type" $
        case compileSource "nested-lists" nestedEmptyListSource of
          Left err ->
            assertFailure ("expected nested list compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted ->
            assertBool "expected nested array literal" ("[[], [1, 2]]" `T.isInfixOf` emitted)
    , testCase "compile lowers list append to JavaScript spread arrays" $
        case compileSource "list-append" listAppendSource of
          Left err ->
            assertFailure ("expected list append compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted ->
            assertBool "expected list append spread expression" ("export const main = [...leading, ...trailing];" `T.isInfixOf` emitted)
    , testCase "compile lowers if expressions to JavaScript conditionals" $
        case compileSource "if-expression" ifExpressionSource of
          Left err ->
            assertFailure ("expected if source compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected if expression iife" ("export const main = (() => {" `T.isInfixOf` emitted)
            assertBool "expected if condition" ("if (isReady) {" `T.isInfixOf` emitted)
            assertBool "expected then branch" ("return \"ready\";" `T.isInfixOf` emitted)
            assertBool "expected else branch" ("return \"waiting\";" `T.isInfixOf` emitted)
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
            assertBool "expected workflow constraints metadata" ("constraints: Object.freeze({ invariant: null, precondition: null, postcondition: null })," `T.isInfixOf` emitted)
            assertBool "expected workflow checkpoint helper" ("checkpoint(value) {" `T.isInfixOf` emitted)
            assertBool "expected workflow checkpoint constraint assertion" ("$claspWorkflowAssertConstraints(\"CounterFlow\", this.constraints, null, state, \"checkpoint\");" `T.isInfixOf` emitted)
            assertBool "expected workflow resume helper" ("resume(snapshot) {" `T.isInfixOf` emitted)
            assertBool "expected module metadata export" ("export const __claspModule = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected workflow module version metadata" ("moduleVersionId: $claspModuleVersionId," `T.isInfixOf` emitted)
            assertBool "expected workflow upgrade window metadata" ("upgradeWindow: $claspModuleUpgradeWindow," `T.isInfixOf` emitted)
            assertBool "expected workflow compatibility metadata" ("compatibleModuleVersionIds: $claspModuleUpgradeWindow.fromVersionIds" `T.isInfixOf` emitted)
            assertBool "expected workflow temporal clock helper" ("clock(seedNow) { return $claspTemporalClock(seedNow); }" `T.isInfixOf` emitted)
            assertBool "expected workflow temporal ttl helper" ("ttl(ttl, options) { return $claspTemporalTtl(ttl, options); }" `T.isInfixOf` emitted)
            assertBool "expected workflow temporal cache helper" ("cache(cacheEntry, options) { return $claspTemporalCache(cacheEntry, options); }" `T.isInfixOf` emitted)
            assertBool "expected workflow start helper" ("start(snapshot, options) { return $claspWorkflowStart(\"CounterFlow\", snapshot, $decode_Counter, this.constraints, options); }" `T.isInfixOf` emitted)
            assertBool "expected workflow deadline helper" ("withDeadline(run, deadlineAt) { return $claspWorkflowWithDeadline(\"CounterFlow\", run, deadlineAt); }" `T.isInfixOf` emitted)
            assertBool "expected workflow cancel helper" ("cancel(run, reason) { return $claspWorkflowCancel(\"CounterFlow\", run, reason); }" `T.isInfixOf` emitted)
            assertBool "expected workflow degrade helper" ("degrade(run, reason, options) { return $claspWorkflowDegrade(\"CounterFlow\", run, reason, options); }" `T.isInfixOf` emitted)
            assertBool "expected workflow handoff helper" ("handoff(run, operator, reason, options) { return $claspWorkflowHandoff(\"CounterFlow\", run, operator, reason, options); }" `T.isInfixOf` emitted)
            assertBool "expected workflow enqueue helper" ("enqueue(run, message) { return $claspWorkflowEnqueue(\"CounterFlow\", run, message); }" `T.isInfixOf` emitted)
            assertBool "expected workflow process-next helper" ("processNext(run, handler, options) { return $claspWorkflowProcessNext(\"CounterFlow\", run, handler, $encode_Counter, this.constraints, options); }" `T.isInfixOf` emitted)
            assertBool "expected workflow drain-mailbox helper" ("drainMailbox(run, handler, options) { return $claspWorkflowDrainMailbox(\"CounterFlow\", run, handler, $encode_Counter, this.constraints, options); }" `T.isInfixOf` emitted)
            assertBool "expected workflow deliver helper" ("deliver(run, message, handler, options) { return $claspWorkflowDeliver(\"CounterFlow\", run, message, handler, $encode_Counter, this.constraints, false, options); }" `T.isInfixOf` emitted)
            assertBool "expected workflow deliver clock support" ("now: $claspTemporalResolveNow(rawOptions, `${workflowName}.delivery`)," `T.isInfixOf` emitted)
            assertBool "expected workflow replay helper" ("replay(snapshot, messages, handler, options) { return $claspWorkflowReplay(\"CounterFlow\", snapshot, messages, handler, $decode_Counter, $encode_Counter, this.constraints, options); }" `T.isInfixOf` emitted)
            assertBool "expected workflow hot-swap compatibility metadata" ("explicitUpgradeHandlers: true," `T.isInfixOf` emitted)
            assertBool "expected workflow migration helper" ("migrate(snapshot, targetWorkflow, options) { return $claspWorkflowMigrateSnapshot(this, targetWorkflow ?? this, snapshot, options); }" `T.isInfixOf` emitted)
            assertBool "expected workflow upgrade helper" ("upgrade(run, targetWorkflow, options) { return $claspWorkflowUpgrade(this, targetWorkflow ?? this, run, options); }" `T.isInfixOf` emitted)
    , testCase "compile emits workflow state constraint handlers" $
        case compileSource "workflow-constraints" workflowConstraintSource of
          Left err ->
            assertFailure ("expected constrained workflow compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected workflow invariant metadata" ("invariant: Object.freeze({ name: \"nonNegative\", check: nonNegative })" `T.isInfixOf` emitted)
            assertBool "expected workflow precondition metadata" ("precondition: Object.freeze({ name: \"belowLimit\", check: belowLimit })" `T.isInfixOf` emitted)
            assertBool "expected workflow postcondition metadata" ("postcondition: Object.freeze({ name: \"withinLimit\", check: withinLimit })" `T.isInfixOf` emitted)
            assertBool "expected workflow constraint runtime helper" ("function $claspWorkflowAssertConstraints(workflowName, constraints, currentState, nextState, stage) {" `T.isInfixOf` emitted)
    , testCase "compile emits supervisor hierarchy metadata and restart strategies" $
        case compileSource "supervisor" supervisorSource of
          Left err ->
            assertFailure ("expected supervisor compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected supervisors export" ("export const __claspSupervisors = [" `T.isInfixOf` emitted)
            assertBool "expected root supervisor metadata" ("name: \"RootSupervisor\"" `T.isInfixOf` emitted)
            assertBool "expected root restart strategy" ("restartStrategy: \"one_for_all\"" `T.isInfixOf` emitted)
            assertBool "expected nested supervisor child" ("kind: \"supervisor\"" `T.isInfixOf` emitted)
            assertBool "expected workflow child reference" ("name: \"CounterFlow\"" `T.isInfixOf` emitted)
            assertBool "expected module supervisor count" ("supervisorCount: 2," `T.isInfixOf` emitted)
            assertBool "expected control plane supervisors contract" ("supervisors: __claspSupervisors," `T.isInfixOf` emitted)
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
    , testCase "compile evaluates for-loops over string values" $
        case compileSource "string-for-loop" stringLoopIterationSource of
          Left err ->
            assertFailure ("expected string for-loop compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected string for-of emission" ("for (const char of name)" `T.isInfixOf` emitted)
            let compiledPath = "dist/string-for-loop.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(compiledModule.pickLastChar(\"Ada\"));"
                ]
            assertEqual "expected string for-loop result" "a" runtimeOutput
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
    , testCase "compile exits enclosing functions when returns occur inside for-loops" $
        case compileSource "loop-return" loopEarlyReturnSource of
          Left err ->
            assertFailure ("expected loop early return compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected loop emission" ("for (const decision of decisions)" `T.isInfixOf` emitted)
            assertBool "expected loop early return helper" ("throw $claspEarlyReturn(\"stopped\")" `T.isInfixOf` emitted)
            let compiledPath = "dist/loop-early-return.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(compiledModule.pickUntilStop([compiledModule.Keep('Ada'), compiledModule.Keep('Grace')]));"
                , "console.log(compiledModule.pickUntilStop([compiledModule.Keep('Ada'), compiledModule.Stop, compiledModule.Keep('Grace')]));"
                ]
            assertEqual "expected loop early return results" "Grace\nstopped" runtimeOutput
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
            assertBool "expected nested list schema" ("$claspCreateListSchema($claspCreateListSchema($claspSchema_Int))" `T.isInfixOf` emitted)
    , testCase "compile evaluates the list example file end to end" $ do
        source <- readExampleSource "lists.clasp"
        case compileSource "examples/lists.clasp" source of
          Left err ->
            assertFailure ("expected list example compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/lists-example.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(JSON.stringify({"
                , "  main: compiledModule.main,"
                , "  usersJson: compiledModule.usersJson,"
                , "  directory: compiledModule.directory"
                , "}));"
                ]
            assertEqual
              "expected list example runtime result"
              "{\"main\":[{\"name\":\"Ada\",\"active\":true},{\"name\":\"Grace\",\"active\":false}],\"usersJson\":\"[{\\\"name\\\":\\\"Ada\\\",\\\"active\\\":true},{\\\"name\\\":\\\"Grace\\\",\\\"active\\\":false}]\",\"directory\":{\"names\":[\"Ada\",\"Grace\"],\"scoreBuckets\":[[10,20],[30]]}}"
              runtimeOutput
    , testCase "compile evaluates list append end to end" $
        case compileSource "list-append" listAppendSource of
          Left err ->
            assertFailure ("expected list append compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/list-append-example.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(JSON.stringify(compiledModule.main));"
                ]
            assertEqual "expected appended list runtime result" "[\"Ada\",\"Grace\",\"Linus\"]" runtimeOutput
    , testCase "compile evaluates if expressions end to end" $
        case compileSource "if-expression" ifExpressionSource of
          Left err ->
            assertFailure ("expected if source compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/if-expression-example.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript $
              T.pack . unlines $
                [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                , "console.log(JSON.stringify(compiledModule.main));"
                ]
            assertEqual "expected if runtime result" "\"ready\"" runtimeOutput
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
    , testCase "compile evaluates the comparisons example file" $ do
        source <- readExampleSource "comparisons.clasp"
        case compileSource "examples/comparisons.clasp" source of
          Left err ->
            assertFailure ("expected comparisons example compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected less-than emission in comparisons example" ("(left < right)" `T.isInfixOf` emitted)
            assertBool "expected equality emission in comparisons example" ("(isEarlier(3, 5) === isLatest(7, 7))" `T.isInfixOf` emitted)
            let compiledPath = "dist/comparisons-example.mjs"
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
            assertEqual
              "expected comparisons example runtime result"
              "{\"earlier\":true,\"boundary\":true,\"later\":true,\"latest\":true,\"main\":true}"
              runtimeOutput
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
            assertBool "expected binary schema codec helper" ("schemaContract.binary = $claspCreateSchemaBinaryCodec(schemaContract);" `T.isInfixOf` emitted)
            assertBool "expected framed binary schema helper" ("schemaContract.encodeFramedBinary = function (value) { return this.binary.frame(value); };" `T.isInfixOf` emitted)
            assertBool "expected platform bridge export" ("export const __claspPlatformBridges = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected react native bridge descriptor" ("reactNative: Object.freeze({ module: \"src/runtime/react.mjs\", entry: \"createReactNativeBridge\" })" `T.isInfixOf` emitted)
            assertBool "expected expo bridge descriptor" ("expo: Object.freeze({ module: \"src/runtime/react.mjs\", entry: \"createExpoBridge\" })" `T.isInfixOf` emitted)
            assertBool "expected generated binding contract export" ("export const __claspBindings = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected generated binding contract version" ("version: 1," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract routes" ("routes: __claspRoutes," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract host bindings" ("hostBindings: __claspHostBindings," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract native interop" ("nativeInterop: __claspNativeInterop," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract schemas" ("schemas: __claspSchemas," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract boundary transports" ("boundaryTransports: __claspBoundaryTransports," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract platform bridges" ("platformBridges: __claspPlatformBridges," `T.isInfixOf` emitted)
            assertBool "expected request preparation helper" ("prepareRequest(value) {" `T.isInfixOf` emitted)
            assertBool "expected response parsing helper" ("async parseResponse(response) {" `T.isInfixOf` emitted)
    , testCase "compile emits executable control-plane manifests and protocol helpers" $
        case compileSource "control-plane" controlPlaneSource of
          Left err ->
            assertFailure ("expected control-plane compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected partial response schema metadata" ("responsePartialSchema: $claspPartialSchema_SearchResponse" `T.isInfixOf` emitted)
            assertBool "expected partial response decoder" ("decodePartialResponse(value, path = \"result\")" `T.isInfixOf` emitted)
            assertBool "expected partial response parser" ("parsePartialResponse(jsonText) { return $decodePartial_SearchResponse(jsonText); }" `T.isInfixOf` emitted)
            assertBool "expected stream result helper" ("streamResult(initial = null) {" `T.isInfixOf` emitted)
            assertBool "expected boundary transport export" ("export const __claspBoundaryTransports = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected service binary transport helper" ("kind: \"tool\"," `T.isInfixOf` emitted)
            assertBool "expected agent channel helper" ("channel(typeName, peer = null) {" `T.isInfixOf` emitted)
            assertBool "expected guides export" ("export const __claspGuides = [" `T.isInfixOf` emitted)
            assertBool "expected hooks export" ("export const __claspHooks = [" `T.isInfixOf` emitted)
            assertBool "expected tools export" ("export const __claspTools = [" `T.isInfixOf` emitted)
            assertBool "expected tool-call contracts export" ("export const __claspToolCallContracts = Object.freeze(__claspTools.map((tool) => tool.callContract));" `T.isInfixOf` emitted)
            assertBool "expected control-plane module metadata export" ("export const __claspModule = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected human-readable control-plane docs export" ("export const __claspControlPlaneDocs = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected control-plane contract export" ("export const __claspControlPlane = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected control-plane contract module entry" ("module: __claspModule," `T.isInfixOf` emitted)
            assertBool "expected control-plane contract docs entry" ("docs: __claspControlPlaneDocs" `T.isInfixOf` emitted)
            assertBool "expected agent role approval metadata" ("approvalPolicy: \"on_request\"" `T.isInfixOf` emitted)
            assertBool "expected agent role sandbox metadata" ("sandboxPolicy: \"workspace_write\"" `T.isInfixOf` emitted)
            assertBool "expected policy permission helpers" ("allowsFile(target) { return this.allows(\"file\", target); }" `T.isInfixOf` emitted)
            assertBool "expected policy decision helper" ("decideFile(target, context = null) { return this.decide(\"file\", target, context); }" `T.isInfixOf` emitted)
            assertBool "expected policy trace helper" ("traceFile(target, context = null) { return this.trace(\"file\", target, context); }" `T.isInfixOf` emitted)
            assertBool "expected policy audit helper" ("auditFile(target, context = null) { return this.audit(\"file\", target, context); }" `T.isInfixOf` emitted)
            assertBool "expected audit log declarations export" ("export const __claspAuditLogs = [" `T.isInfixOf` emitted)
            assertBool "expected audit log runtime helper" ("createRuntime(options = null) { return $claspCreateAuditLogRuntime(this, options); }" `T.isInfixOf` emitted)
            assertBool "expected secret inputs export" ("export const __claspSecretInputs = [" `T.isInfixOf` emitted)
            assertBool "expected secret boundaries export" ("export const __claspSecretBoundaries = [" `T.isInfixOf` emitted)
            assertBool "expected secret trace helper" ("traceAccess(boundary, provider, context = null, options = null) { return this.decideAccess(boundary, provider, context, options).trace; }" `T.isInfixOf` emitted)
            assertBool "expected delegated secret audit provenance" ("consumingBoundary: boundarySnapshot," `T.isInfixOf` emitted && "attenuation: $claspSnapshotValue(rawOptions.delegation.attenuation ?? null)" `T.isInfixOf` emitted)
            assertBool "expected missing secret diagnostic helper" ("Missing secret ${decision.secret} for ${decision.boundary.kind} ${decision.boundary.name} under policy ${decision.policy}" `T.isInfixOf` emitted)
            assertBool "expected eval hooks export" ("export const __claspEvalHooks = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected trace collector export" ("export const __claspTraceCollector = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected traceability export" ("export const __claspTraceability = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected bounded change planner export" ("proposeChange(observation, proposal, options = null) { return $claspProposeBoundedChange(observation, proposal, options); }" `T.isInfixOf` emitted)
            assertBool "expected learning loop linker export" ("linkLearningLoop(loop, options = null) { return $claspLinkLearningLoop(loop, options); }" `T.isInfixOf` emitted)
            assertBool "expected AIR export" ("export const __claspAir = __claspAirSource;" `T.isInfixOf` emitted)
            assertBool "expected AIR projector export" ("export const __claspAirProjectors = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected source AIR projector hook" ("projectSource() { return __claspAir; }" `T.isInfixOf` emitted)
            assertBool "expected prompt AIR projector hook" ("projectPrompt(value, options = null) { return $claspProjectPromptToAir(value, options); }" `T.isInfixOf` emitted)
            assertBool "expected plan AIR projector hook" ("projectPlan(value, options = null) { return $claspProjectPlanToAir(value, options); }" `T.isInfixOf` emitted)
            assertBool "expected hook evaluate helper" ("evaluate(value, options = null) {" `T.isInfixOf` emitted)
            assertBool "expected hook invoke helper" ("invoke(value, options = null) { return this.evaluate(value, options).encoded; }" `T.isInfixOf` emitted)
            assertBool "expected tool request preparation" ("prepareCall(value, id = null, options = null) {" `T.isInfixOf` emitted)
            assertBool "expected tool call evaluation helper" ("evaluateCall(value, id = null, options = null) {" `T.isInfixOf` emitted)
            assertBool "expected tool result evaluation helper" ("evaluateResult(payload, options = null) {" `T.isInfixOf` emitted)
            assertBool "expected tool call parser" ("parseCall(jsonText) { return this.decodeCall(JSON.parse(jsonText)); }" `T.isInfixOf` emitted)
            assertBool "expected tool result envelope parser" ("parseResultEnvelope(jsonText) { return this.decodeResultEnvelope(JSON.parse(jsonText)); }" `T.isInfixOf` emitted)
            assertBool "expected merge gate planning helper" ("plan(value, idSeed = this.name) {" `T.isInfixOf` emitted)
            assertBool "expected generated binding contract control plane entry" ("controlPlane: __claspControlPlane" `T.isInfixOf` emitted)
            assertBool "expected generated binding contract audit logs entry" ("auditLogs: __claspAuditLogs," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract control plane docs entry" ("controlPlaneDocs: __claspControlPlaneDocs" `T.isInfixOf` emitted)
            assertBool "expected generated binding contract AIR entry" ("air: __claspAir," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract AIR projector entry" ("airProjectors: __claspAirProjectors," `T.isInfixOf` emitted)
            assertBool "expected generated binding contract tool-call entry" ("toolCallContracts: __claspToolCallContracts" `T.isInfixOf` emitted)
            assertBool "expected generated binding contract eval-hooks entry" ("evalHooks: __claspEvalHooks" `T.isInfixOf` emitted)
            assertBool "expected generated binding contract trace entry" ("traces: __claspTraceCollector" `T.isInfixOf` emitted)
            assertBool "expected generated binding contract traceability entry" ("traceability: __claspTraceability" `T.isInfixOf` emitted)
            assertBool "expected generated control-plane traceability entry" ("traceability: __claspTraceability," `T.isInfixOf` emitted)
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
                , "const toolCall = compiledModule.__claspToolCallContracts[0];"
                , "const verifier = compiledModule.__claspVerifiers[0];"
                , "const mergeGate = compiledModule.__claspMergeGates[0];"
                , "const docs = compiledModule.__claspControlPlaneDocs;"
                , "const auditLog = compiledModule.__claspControlPlane.auditLogs[0];"
                , "const auditRuntime = auditLog.createRuntime({ retention: { traceability: { maxEntries: 2 } } });"
                , "const sourceAir = compiledModule.__claspAirProjectors.projectSource();"
                , "const promptAir = compiledModule.__claspAirProjectors.projectPrompt({ $kind: 'prompt', messages: [{ role: 'system', content: 'Inspect the repo.' }, { role: 'user', content: 'Run verification.' }] }, { name: 'builder-loop' });"
                , "const planAir = compiledModule.__claspAirProjectors.projectPromptOrPlan(['inspect repo', 'run bash scripts/verify-all.sh'], { name: 'release' });"
                , "const policy = agent.policy;"
                , "const collector = compiledModule.__claspTraceCollector.create();"
                , "const evalLifecycle = [];"
                , "const evalHooks = compiledModule.__claspEvalHooks.create({"
                , "  before(event) { evalLifecycle.push(`${event.kind}:${event.action}:before`); },"
                , "  after(event) { evalLifecycle.push(`${event.kind}:${event.action}:after:${event.trace.status}`); },"
                , "  trace(trace) { evalLifecycle.push(`trace:${trace.kind}:${trace.action}:${trace.status}`); }"
                , "});"
                , "const secretInput = compiledModule.__claspControlPlane.secretInputs[0];"
                , "const agentSecretBoundary = compiledModule.__claspControlPlane.secretBoundaries.find((boundary) => boundary.kind === 'agentRole');"
                , "const toolSecretBoundary = compiledModule.__claspControlPlane.secretBoundaries.find((boundary) => boundary.kind === 'toolServer');"
                , "const context = { actor: { id: 'worker-7', tags: ['initial'] }, requestId: 'req-1' };"
                , "const decision = policy.decideFile('/workspace/src/Main.clasp', context);"
                , "const trace = policy.traceFile('/workspace/src/Main.clasp', context);"
                , "const audit = policy.auditFile('/workspace/src/Main.clasp', context);"
                , "const secretDecision = secretInput.decideAccess(agentSecretBoundary, { OPENAI_API_KEY: 'sk-live' }, context);"
                , "const secretTrace = secretInput.traceAccess(agentSecretBoundary, { OPENAI_API_KEY: 'sk-live' }, context);"
                , "const secretAudit = secretInput.auditAccess(toolSecretBoundary, { OPENAI_API_KEY: 'sk-live' }, context);"
                , "const secretValue = secretInput.resolve(agentSecretBoundary, { OPENAI_API_KEY: 'sk-live' }, context);"
                , "const routedPolicyAudit = auditRuntime.record(audit);"
                , "const routedSecretAudit = auditRuntime.record({ ...secretAudit, resolvedValue: 'sk-live', authorization: 'Bearer sk-live' });"
                , "context.actor.id = 'mutated';"
                , "context.actor.tags.push('later');"
                , "context.requestId = 'req-2';"
                , "let deniedFile = null;"
                , "let missingSecret = null;"
                , "try {"
                , "  policy.assertFile('/tmp');"
                , "} catch (error) {"
                , "  deniedFile = error.message;"
                , "}"
                , "try {"
                , "  secretInput.resolve(toolSecretBoundary, {}, context);"
                , "} catch (error) {"
                , "  missingSecret = error.message;"
                , "}"
                , "const hookEval = hook.evaluate({ workerId: 'worker-7' }, { traceId: 'hook-1', collector, hooks: evalHooks, context: { actor: { id: 'runner-1' } } });"
                , "const toolEval = tool.evaluateCall({ query: 'search' }, 7, { traceId: 'tool-1', collector, hooks: evalHooks, context: { actor: { id: 'runner-2' } } });"
                , "const toolResultEval = tool.evaluateResult({ summary: 'done' }, { traceId: 'tool-2', collector, hooks: evalHooks, context: { actor: { id: 'runner-3' } } });"
                , "const routedHookAudit = auditRuntime.record(hookEval.trace);"
                , "const objectiveSignal = compiledModule.__claspTraceability.recordSignal({ name: 'repo_checks_flaky', summary: 'Repo checks are intermittently failing in CI.', severity: 'warn', source: 'test/control-plane-runtime' }, { policies: ['SupportDisclosure'], tests: [{ name: 'control-plane.demo', file: 'examples/control-plane/demo.mjs' }] }, { traceId: 'signal-1', collector, context: { actor: { id: 'runner-4' } } });"
                , "let invalidChange = null;"
                , "try {"
                , "  compiledModule.__claspTraceability.proposeChange(objectiveSignal, {"
                , "    name: 'too-broad',"
                , "    summary: 'Touch an unrelated route.',"
                , "    targets: { tests: ['other-test'] },"
                , "    steps: ['Expand the scope beyond the observed signal.']"
                , "  }, { traceId: 'change-err', collector, context: { actor: { id: 'runner-5' } } });"
                , "} catch (error) {"
                , "  invalidChange = error instanceof Error ? error.message : String(error);"
                , "}"
                , "const changePlan = compiledModule.__claspTraceability.proposeChange(objectiveSignal, {"
                , "  name: 'tighten-repo-check-loop',"
                , "  summary: 'Keep the remediation inside the observed policy and demo test surfaces.',"
                , "  rationale: 'The failing signal is already linked to the current policy gate and demo verification path.',"
                , "  targets: { policies: ['SupportDisclosure'], tests: [{ name: 'control-plane.demo', file: 'examples/control-plane/demo.mjs' }] },"
                , "  steps: ["
                , "    { title: 'Tighten the repo-check guidance.', detail: 'Keep the remediation scoped to the support disclosure policy and the current verifier path.' },"
                , "    { title: 'Re-run the control-plane demo.', detail: 'Verify the bounded change against the linked demo test before widening scope.' }"
                , "  ],"
                , "  bounds: { maxSteps: 2, requireTests: true, requireReview: true }"
                , "}, { traceId: 'change-1', collector, context: { actor: { id: 'runner-6' } } });"
                , "let invalidLearningLoop = null;"
                , "try {"
                , "  compiledModule.__claspTraceability.linkLearningLoop({"
                , "    name: 'repo-check-loop-over-budget',"
                , "    objective: { name: 'repo-stability', summary: 'Reduce flaky repo checks.', metric: 'repo_checks_flaky' },"
                , "    incident: objectiveSignal,"
                , "    evals: [{ name: 'control-plane.demo', file: 'examples/control-plane/demo.mjs' }],"
                , "    benchmarks: [{ name: 'clasp-external-adaptation', harness: 'codex', baseline: 'objective-a' }],"
                , "    budget: { maxRemediationSteps: 1, evalRuns: 1, benchmarkRuns: 1 },"
                , "    remediation: changePlan"
                , "  }, { traceId: 'loop-err', collector, context: { actor: { id: 'runner-7' } } });"
                , "} catch (error) {"
                , "  invalidLearningLoop = error instanceof Error ? error.message : String(error);"
                , "}"
                , "const learningLoop = compiledModule.__claspTraceability.linkLearningLoop({"
                , "  name: 'repo-check-loop',"
                , "  objective: { name: 'repo-stability', summary: 'Reduce flaky repo checks.', metric: 'repo_checks_flaky' },"
                , "  incident: objectiveSignal,"
                , "  evals: [{ name: 'control-plane.demo', file: 'examples/control-plane/demo.mjs' }],"
                , "  benchmarks: [{ name: 'clasp-external-adaptation', harness: 'codex', baseline: 'objective-a' }],"
                , "  budget: { maxRemediationSteps: 2, evalRuns: 1, benchmarkRuns: 1 },"
                , "  remediation: changePlan"
                , "}, { traceId: 'loop-1', collector, context: { actor: { id: 'runner-8' } } });"
                , "auditRuntime.record(objectiveSignal);"
                , "auditRuntime.record(changePlan);"
                , "auditRuntime.record(learningLoop);"
                , "const auditEntries = auditRuntime.entries();"
                , "const collected = collector.entries();"
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
                , "  secretPolicy: secretDecision.policy,"
                , "  secretBoundaryKind: secretDecision.boundary.kind,"
                , "  secretBoundaryName: secretDecision.boundary.name,"
                , "  secretMissing: secretDecision.missing,"
                , "  secretTraceActor: secretTrace.context.actor.id,"
                , "  secretAuditBoundary: secretAudit.boundary.name,"
                , "  secretResolvedName: secretValue.name,"
                , "  secretResolvedValue: secretValue.reveal({ reason: 'control-plane-demo' }),"
                , "  secretConsumerBoundary: secretInput.consumerBoundaries.join(','),"
                , "  auditLogName: auditLog.name,"
                , "  auditPolicySink: routedPolicyAudit.sink.name,"
                , "  auditSecretSink: routedSecretAudit.sink.name,"
                , "  auditHookSink: routedHookAudit.sink.name,"
                , "  auditSecretRedactedValue: routedSecretAudit.entry.resolvedValue,"
                , "  auditSecretRedactedAuth: routedSecretAudit.entry.authorization,"
                , "  auditTraceabilityRetained: auditEntries.traceability.length,"
                , "  auditTraceabilityTailKinds: auditEntries.traceability.map((entry) => entry.kind ?? entry.eventType),"
                , "  traceFrozen: Object.isFrozen(trace.context) && Object.isFrozen(trace.context.actor) && Object.isFrozen(trace.context.actor.tags),"
                , "  auditFrozen: Object.isFrozen(audit.context) && Object.isFrozen(audit.context.actor) && Object.isFrozen(audit.context.actor.tags),"
                , "  secretTraceFrozen: Object.isFrozen(secretTrace.context) && Object.isFrozen(secretTrace.boundary),"
                , "  deniedFile,"
                , "  missingSecret,"
                , "  hookEvent: hook.event,"
                , "  hookAccepted: hook.invoke({ workerId: 'worker-7' }).accepted,"
                , "  hookEvalRequest: hookEval.request.workerId,"
                , "  hookEvalTraceStatus: hookEval.trace.status,"
                , "  toolMethod: tool.prepareCall({ query: 'search' }, 7).method,"
                , "  toolParam: tool.prepareCall({ query: 'search' }, 7).params.query,"
                , "  parsedSummary: tool.parseResult({ summary: 'done' }).summary,"
                , "  toolEvalTraceAction: toolEval.trace.action,"
                , "  toolEvalMethod: toolEval.call.method,"
                , "  toolResultTraceStatus: toolResultEval.trace.status,"
                , "  toolResultSummary: toolResultEval.result.summary,"
                , "  toolCallVersion: toolCall.version,"
                , "  toolCallProtocol: toolCall.serverProtocol,"
                , "  toolCallType: toolCall.requestType,"
                , "  parsedCallQuery: toolCall.parseCall('{\"jsonrpc\":\"2.0\",\"id\":\"req-9\",\"method\":\"search_repo\",\"params\":{\"query\":\"search\"}}').params.query,"
                , "  parsedEnvelopeSummary: toolCall.parseResultEnvelope('{\"jsonrpc\":\"2.0\",\"id\":\"req-9\",\"result\":{\"summary\":\"framed\"}}').result.summary,"
                , "  formattedEnvelope: toolCall.formatResultEnvelope({ summary: 'wrapped' }, 'req-10'),"
                , "  verifierMethod: verifier.prepareRun({ query: 'check' }, 8).method,"
                , "  mergeGatePlan: mergeGate.plan({ query: 'gate' }, 'trunk').map((request) => request.id).join(','),"
                , "  sourceAirFormat: sourceAir.format,"
                , "  sourceAirHasMergeGate: sourceAir.roots.includes('mergegate:trunk'),"
                , "  promptAirRootKind: promptAir.nodes.find((node) => node.id === 'prompt:builder-loop')?.kind ?? null,"
                , "  promptAirMessageRole: promptAir.nodes.find((node) => node.id === 'prompt:builder-loop.message1')?.attrs.find((entry) => entry.name === 'role')?.value ?? null,"
                , "  planAirRootKind: planAir.nodes.find((node) => node.id === 'plan:release')?.kind ?? null,"
                , "  planAirStepCount: planAir.nodes.filter((node) => node.kind === 'planStepProjection').length,"
                , "  docsFormat: docs.format,"
                , "  docsHasGuides: docs.markdown.includes('## Guides'),"
                , "  docsHasAuditLogs: docs.markdown.includes('## Audit Logs'),"
                , "  docsHasPermissions: docs.markdown.includes('File permissions: /workspace'),"
                , "  docsHasSecretInputs: docs.markdown.includes('## Secret Inputs'),"
                , "  docsHasSecretBoundary: docs.markdown.includes('toolServer:RepoTools'),"
                , "  docsHasApproval: docs.markdown.includes('Approval: on_request'),"
                , "  docsHasSandbox: docs.markdown.includes('Sandbox: workspace_write'),"
                , "  docsHasHookEvent: docs.markdown.includes('worker.start'),"
                , "  docsHasModuleVersion: docs.markdown.includes('Version id: module:Main:'),"
                , "  controlPlaneModuleVersionTagged: compiledModule.__claspControlPlane.module.versionId.startsWith('module:Main:'),"
                , "  bindingModuleVersionTagged: compiledModule.__claspBindings.module.versionId.startsWith('module:Main:'),"
                , "  bindingControlPlaneVersion: compiledModule.__claspBindings.controlPlane.version,"
                , "  bindingControlPlaneDocsVersion: compiledModule.__claspBindings.controlPlaneDocs.version,"
                , "  bindingAuditLogCount: compiledModule.__claspBindings.auditLogs.length,"
                , "  bindingToolCallContracts: compiledModule.__claspBindings.toolCallContracts.length,"
                , "  controlPlaneAuditLogCount: compiledModule.__claspControlPlane.auditLogs.length,"
                , "  controlPlaneToolCallContracts: compiledModule.__claspControlPlane.toolCallContracts.length,"
                , "  bindingEvalHooksVersion: compiledModule.__claspBindings.evalHooks.version,"
                , "  bindingTraceVersion: compiledModule.__claspBindings.traces.version,"
                , "  controlPlaneEvalHooksVersion: compiledModule.__claspControlPlane.evalHooks.version,"
                , "  controlPlaneTraceVersion: compiledModule.__claspControlPlane.traces.version,"
                , "  boundedSignalName: objectiveSignal.signal.name,"
                , "  boundedChangeKind: changePlan.kind,"
                , "  boundedChangeName: changePlan.change.name,"
                , "  boundedChangeTargetIds: changePlan.change.targets.ids,"
                , "  boundedChangeStepCount: changePlan.change.steps.length,"
                , "  boundedChangeAirRootKind: changePlan.air.nodes.find((node) => node.id === 'plan:tighten-repo-check-loop')?.kind ?? null,"
                , "  invalidChange,"
                , "  learningLoopKind: learningLoop.kind,"
                , "  learningLoopName: learningLoop.loop.name,"
                , "  learningLoopObjective: learningLoop.objective.name,"
                , "  learningLoopIncidentSignal: learningLoop.incident.signal.name,"
                , "  learningLoopEvalIds: learningLoop.evals.map((entry) => entry.id),"
                , "  learningLoopBenchmarkIds: learningLoop.benchmarks.map((entry) => entry.id),"
                , "  learningLoopBudgetStepCap: learningLoop.budget.maxRemediationSteps,"
                , "  learningLoopRemediationName: learningLoop.remediation.change.name,"
                , "  learningLoopAirRootKind: learningLoop.air.nodes.find((node) => node.id === 'learning-loop:repo-check-loop')?.kind ?? null,"
                , "  invalidLearningLoop,"
                , "  collectedTraceCount: collected.length,"
                , "  collectedKinds: collected.map((entry) => `${entry.kind}:${entry.action}:${entry.status}`),"
                , "  collectedActors: collected.map((entry) => entry.context?.actor?.id ?? null),"
                , "  collectedFrozen: collected.every((entry) => Object.isFrozen(entry) && Object.isFrozen(entry.surface)),"
                , "  evalLifecycle"
                , "}));"
                ]
            assertEqual
              "expected executable control-plane runtime result"
              "{\"guideExtends\":\"Repo\",\"guideScope\":\"Stay inside the current checkout.\",\"agentPolicy\":\"SupportDisclosure\",\"agentApproval\":\"on_request\",\"agentSandbox\":\"workspace_write\",\"fileAllowed\":true,\"fileDenied\":false,\"networkAllowed\":true,\"processAllowed\":true,\"secretAllowed\":true,\"decisionAllowed\":true,\"decisionActor\":\"worker-7\",\"traceActor\":\"worker-7\",\"traceTags\":\"initial\",\"auditActor\":\"worker-7\",\"auditRequestId\":\"req-1\",\"secretPolicy\":\"SupportDisclosure\",\"secretBoundaryKind\":\"agentRole\",\"secretBoundaryName\":\"WorkerRole\",\"secretMissing\":false,\"secretTraceActor\":\"worker-7\",\"secretAuditBoundary\":\"RepoTools\",\"secretResolvedName\":\"OPENAI_API_KEY\",\"secretResolvedValue\":\"sk-live\",\"secretConsumerBoundary\":\"agentRole:WorkerRole,toolServer:RepoTools\",\"auditLogName\":\"CompilerOwnedAudit\",\"auditPolicySink\":\"policy_decisions\",\"auditSecretSink\":\"secret_access\",\"auditHookSink\":\"compiler_execution\",\"auditSecretRedactedValue\":\"[redacted by compiler audit policy]\",\"auditSecretRedactedAuth\":\"[redacted by compiler audit policy]\",\"auditTraceabilityRetained\":2,\"auditTraceabilityTailKinds\":[\"bounded_change_plan\",\"learning_loop\"],\"traceFrozen\":true,\"auditFrozen\":true,\"secretTraceFrozen\":true,\"deniedFile\":\"Policy SupportDisclosure denies file access to /tmp\",\"missingSecret\":\"Missing secret OPENAI_API_KEY for toolServer RepoTools under policy SupportDisclosure\",\"hookEvent\":\"worker.start\",\"hookAccepted\":true,\"hookEvalRequest\":\"worker-7\",\"hookEvalTraceStatus\":\"ok\",\"toolMethod\":\"search_repo\",\"toolParam\":\"search\",\"parsedSummary\":\"done\",\"toolEvalTraceAction\":\"prepare_call\",\"toolEvalMethod\":\"search_repo\",\"toolResultTraceStatus\":\"ok\",\"toolResultSummary\":\"done\",\"toolCallVersion\":1,\"toolCallProtocol\":\"mcp\",\"toolCallType\":\"SearchRequest\",\"parsedCallQuery\":\"search\",\"parsedEnvelopeSummary\":\"framed\",\"formattedEnvelope\":\"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":\\\"req-10\\\",\\\"result\\\":{\\\"summary\\\":\\\"wrapped\\\"}}\",\"verifierMethod\":\"search_repo\",\"mergeGatePlan\":\"trunk:0\",\"sourceAirFormat\":\"clasp-air-v1\",\"sourceAirHasMergeGate\":true,\"promptAirRootKind\":\"promptProjection\",\"promptAirMessageRole\":\"user\",\"planAirRootKind\":\"planProjection\",\"planAirStepCount\":2,\"docsFormat\":\"markdown\",\"docsHasGuides\":true,\"docsHasAuditLogs\":true,\"docsHasPermissions\":true,\"docsHasSecretInputs\":true,\"docsHasSecretBoundary\":true,\"docsHasApproval\":true,\"docsHasSandbox\":true,\"docsHasHookEvent\":true,\"docsHasModuleVersion\":true,\"controlPlaneModuleVersionTagged\":true,\"bindingModuleVersionTagged\":true,\"bindingControlPlaneVersion\":1,\"bindingControlPlaneDocsVersion\":1,\"bindingAuditLogCount\":1,\"bindingToolCallContracts\":1,\"controlPlaneAuditLogCount\":1,\"controlPlaneToolCallContracts\":1,\"bindingEvalHooksVersion\":1,\"bindingTraceVersion\":1,\"controlPlaneEvalHooksVersion\":1,\"controlPlaneTraceVersion\":1,\"boundedSignalName\":\"repo_checks_flaky\",\"boundedChangeKind\":\"bounded_change_plan\",\"boundedChangeName\":\"tighten-repo-check-loop\",\"boundedChangeTargetIds\":[\"policy:SupportDisclosure\",\"test:control-plane.demo\"],\"boundedChangeStepCount\":2,\"boundedChangeAirRootKind\":\"planProjection\",\"invalidChange\":\"Change target test:other-test is outside the observed signal scope\",\"learningLoopKind\":\"learning_loop\",\"learningLoopName\":\"repo-check-loop\",\"learningLoopObjective\":\"repo-stability\",\"learningLoopIncidentSignal\":\"repo_checks_flaky\",\"learningLoopEvalIds\":[\"eval:control-plane.demo\"],\"learningLoopBenchmarkIds\":[\"benchmark:clasp-external-adaptation\"],\"learningLoopBudgetStepCap\":2,\"learningLoopRemediationName\":\"tighten-repo-check-loop\",\"learningLoopAirRootKind\":\"learningLoopProjection\",\"invalidLearningLoop\":\"Learning loop budget allows at most 1 remediation steps\",\"collectedTraceCount\":6,\"collectedKinds\":[\"hook:invoke:ok\",\"tool:prepare_call:ok\",\"tool:parse_result:ok\",\"runtime_signal:observe:ok\",\"bounded_change_plan:propose:ok\",\"learning_loop:link:ok\"],\"collectedActors\":[\"runner-1\",\"runner-2\",\"runner-3\",\"runner-4\",\"runner-6\",\"runner-8\"],\"collectedFrozen\":true,\"evalLifecycle\":[\"hook:invoke:before\",\"trace:hook:invoke:ok\",\"hook:invoke:after:ok\",\"tool:prepare_call:before\",\"trace:tool:prepare_call:ok\",\"tool:prepare_call:after:ok\",\"tool:parse_result:before\",\"trace:tool:parse_result:ok\",\"tool:parse_result:after:ok\"]}"
              runtimeOutput
    , testCase "typed schema streams merge nested partial results and require completion" $
        case compileSource "streaming-partials" streamingToolSource of
          Left err ->
            assertFailure ("expected streaming partial source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected partial schema registry entry" ("partialSchema: $claspPartialSchema_StreamReply" `T.isInfixOf` emitted)
            assertBool "expected partial record decoder" ("function $decodePartial_StreamReply(jsonText)" `T.isInfixOf` emitted)
            assertBool "expected schema stream helper" ("stream(initial = null) { return $claspCreateSchemaStream(this, initial); }" `T.isInfixOf` emitted)
            let compiledPath = "dist/test-projects/streaming-partials/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript (streamingPartialRuntimeScript absoluteCompiledPath)
            assertEqual
              "expected nested partial merge and completion checks"
              "{\"parsedPartial\":{\"summary\":\"Ready\",\"usage\":{\"prompt\":12}},\"first\":{\"summary\":\"Ready\"},\"second\":{\"summary\":\"Ready\",\"usage\":{\"prompt\":12}},\"third\":{\"summary\":\"Ready\",\"usage\":{\"prompt\":12,\"completion\":7},\"done\":true},\"final\":{\"summary\":\"Ready\",\"usage\":{\"prompt\":12,\"completion\":7},\"done\":true},\"formattedPartial\":\"{\\\"usage\\\":{\\\"completion\\\":7}}\",\"incomplete\":\"completion must be an integer\"}"
              runtimeOutput
    , testCase "control-plane example requires native backend emission" $
        assertBackendEntryRequiresNative ("examples" </> "control-plane" </> "Main.clasp")
    , testCase "support-agent example requires native backend emission" $
        assertBackendEntryRequiresNative ("examples" </> "support-agent" </> "Main.clasp")
    , testCase "support-console example requires native backend emission" $
        assertBackendEntryRequiresNative ("examples" </> "support-console" </> "Main.clasp")
    , testCase "release-gate example requires native backend emission" $
        assertBackendEntryRequiresNative ("examples" </> "release-gate" </> "Main.clasp")
    , testCase "durable workflow example requires native backend emission" $
        flip finally (cleanupProjectDir stateDir) $ do
          oldResult <- compileEntry ("examples" </> "durable-workflow" </> "Main.clasp")
          newResult <- compileEntry ("examples" </> "durable-workflow" </> "Main.next.clasp")
          assertHasCode "E_BACKEND_TARGET_REQUIRES_NATIVE" oldResult
          assertHasCode "E_BACKEND_TARGET_REQUIRES_NATIVE" newResult
    , testCase "compile emits field classifications and projection disclosure metadata" $
        case compileSource "projection" classifiedProjectionSource of
          Left err ->
            assertFailure ("expected classified projection source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected classified source field metadata" ("email: { schema: $claspSchema_Str, classification: \"pii\" }" `T.isInfixOf` emitted)
            assertBool "expected projection metadata" ("classificationPolicy: \"SupportDisclosure\"" `T.isInfixOf` emitted)
            assertBool "expected projection source metadata" ("projectionSource: \"Customer\"" `T.isInfixOf` emitted)
            assertBool "expected foreign manifest to use projection schema" ("schema: $claspSchema_SupportCustomer" `T.isInfixOf` emitted)
    , testCase "projection field helpers preserve fingerprints for projected list fields" $
        case compileSource "projection-list" classifiedProjectionListSource of
          Left err ->
            assertFailure ("expected projected list source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/projection-list/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript (projectionSchemaRuntimeScript absoluteCompiledPath)
            assertEqual
              "expected stable fingerprints for projected list field helpers"
              "{\"fieldIdentity\":\"Customer.emails\",\"projectionFingerprint\":\"list:str\",\"partialFingerprint\":\"partial-list:str\",\"schemaProjectionFingerprint\":\"list:str\",\"schemaPartialProjectionFingerprint\":\"partial-list:str\",\"itemFingerprint\":\"str\",\"partialItemFingerprint\":\"str\"}"
              runtimeOutput
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
            assertBool "expected style ir export" ("export const __claspStyleIR" `T.isInfixOf` emitted)
            assertBool "expected style bundle registry" ("export const __claspStyleBundles" `T.isInfixOf` emitted)
            assertBool "expected style ir kind" ("kind: \"clasp-style-ir\"" `T.isInfixOf` emitted)
            assertBool "expected style escape hatch metadata" ("safeViewStatus: \"rejected\"" `T.isInfixOf` emitted)
            assertBool "expected style ir in generated bindings" ("styleIR: __claspStyleIR" `T.isInfixOf` emitted)
            assertBool "expected head strategy export" ("export const __claspHeadStrategy" `T.isInfixOf` emitted)
            assertBool "expected default viewport meta" ("viewport: \"width=device-width, initial-scale=1\"" `T.isInfixOf` emitted)
            assertBool "expected generated stylesheet href" ("href: \"/assets/clasp/Main.styles.css\"" `T.isInfixOf` emitted)
            assertBool "expected generated css tokens" ("--clasp-color-background-surface: #ffffff;" `T.isInfixOf` emitted)
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
            assertBool "expected audit actor schema" ("const $claspSchema_AuditActor" `T.isInfixOf` emitted)
            assertBool "expected standard audit envelope decoder" ("function $decode_StandardAuditEnvelope" `T.isInfixOf` emitted)
            assertBool "expected audit provenance constructor object" ("source: \"worker-runtime\"" `T.isInfixOf` emitted)
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
                , "  actorId: decoded.actor.actorId,"
                , "  actorType: decoded.actor.actorType,"
                , "  tenantId: compiledModule.sessionTenantId(compiledModule.defaultSession),"
                , "  actionType: decoded.action.actionType,"
                , "  provenanceRequestId: decoded.provenance.requestId,"
                , "  resource: decoded.resource.resourceType + ':' + decoded.resource.resourceId"
                , "}));"
                ]
            assertBool "expected decoded actor id" ("\"actorId\":\"user-1\"" `T.isInfixOf` encoded)
            assertBool "expected decoded actor type" ("\"actorType\":\"principal\"" `T.isInfixOf` encoded)
            assertBool "expected tenant id" ("\"tenantId\":\"tenant-1\"" `T.isInfixOf` encoded)
            assertBool "expected action type" ("\"actionType\":\"read\"" `T.isInfixOf` encoded)
            assertBool "expected provenance request id" ("\"provenanceRequestId\":\"sess-1\"" `T.isInfixOf` encoded)
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
            absoluteServerRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
            absoluteWorkerRuntimePath <- makeAbsolute "deprecated/runtime/worker.mjs"
            runtimeOutput <- runNodeScript (authIdentityRuntimeScript absoluteCompiledPath absoluteServerRuntimePath absoluteWorkerRuntimePath)
            assertEqual
              "expected auth identity contract exports across server and worker runtimes"
              "{\"contractVersion\":1,\"schemaNames\":[\"AuditAction\",\"AuditActor\",\"AuditProvenance\",\"AuthSession\",\"Bool\",\"Int\",\"Principal\",\"ResourceIdentity\",\"SqliteConnection\",\"StandardAuditEnvelope\",\"Str\",\"Tenant\"],\"sessionSchemaKind\":\"record\",\"principalFieldType\":\"Principal\",\"tenantSeed\":\"seed\",\"workerActorType\":\"principal\",\"workerActorId\":\"user-1\",\"workerActionType\":\"read\",\"workerTimestamp\":1710000000,\"workerProvenanceSource\":\"worker-runtime\",\"workerResource\":\"lead:lead-1\"}"
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
              absoluteRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
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
    , testCase "checkEntryWithPreference Clasp preserves package declaration signatures" $
        withProjectFiles "package-import-signatures-clasp" packageImportFiles $ \root -> do
          let entryPath = root </> "Main.clasp"
          (implementation, result) <- checkEntryWithPreference CompilerPreferenceClasp entryPath
          assertEqual "implementation" CompilerImplementationClasp implementation
          case result of
            Left err ->
              assertFailure ("expected explicit hosted package-backed project to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
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
    , testCase "compileEntry runs compact header imports end to end" $
        withProjectFiles "compile-import-compact-header" compactHeaderImportSuccessFiles $ \root -> do
          result <- compileEntry (root </> "Main.clasp")
          case result of
            Left err ->
              assertFailure ("expected compact-header project to compile:\n" <> T.unpack (renderDiagnosticBundle err))
            Right emitted -> do
              let compiledPath = root </> "compiled.mjs"
              TIO.writeFile compiledPath emitted
              absoluteCompiledPath <- makeAbsolute compiledPath
              runtimeOutput <-
                runNodeScript $
                  T.pack . unlines $
                    [ "import * as compiledModule from " <> show ("file://" <> absoluteCompiledPath) <> ";"
                    , "console.log(compiledModule.main);"
                    ]
              assertEqual "expected compact-header import project to execute" "Ada" runtimeOutput
    , testCase "checkEntry reports missing imported modules" $
        withProjectFiles "import-missing" missingImportFiles $ \root -> do
          result <- checkEntry (root </> "Main.clasp")
          assertHasCode "E_IMPORT_NOT_FOUND" result
    , testCase "checkEntry reports missing package export declarations" $
        withProjectFiles "package-import-missing-export" packageImportMissingExportFiles $ \root -> do
          result <- checkEntry (root </> "Main.clasp")
          assertHasCode "E_FOREIGN_PACKAGE_EXPORT_NOT_FOUND" result
    , testCase "checkEntry accepts explicit unsafe package leaves when structure still matches" $
        withProjectFiles "package-import-unsafe-leaf" packageImportUnsafeLeafFiles $ \root -> do
          result <- checkEntry (root </> "Main.clasp")
          case result of
            Left err ->
              assertFailure ("expected unsafe leaf package import to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
            Right _ ->
              pure ()
    , testCase "checkEntry still rejects structural mismatches around unsafe package leaves" $
        withProjectFiles "package-import-unsafe-structural-mismatch" packageImportUnsafeStructuralMismatchFiles $ \root -> do
          result <- checkEntry (root </> "Main.clasp")
          assertHasCode "E_FOREIGN_PACKAGE_SIGNATURE_MISMATCH" result
    , testCase "compileEntry rejects inbox-style shared page routes and requires native" $
        withProjectFiles "render-inbox-page" inboxPageFiles $ \root ->
          assertBackendEntryRequiresNative (root </> "Main.clasp")
    , testCase "generated page head and style bundle assets stay machine-readable" $
        case compileSource "page-head-assets" pageSource of
          Left err ->
            assertFailure ("expected page compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/page-head-assets/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
            runtimeOutput <- runNodeScript (pageAssetRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected generated asset, head, and style bundle strategy"
              "{\"assetBasePath\":\"/assets\",\"generatedAssetBasePath\":\"/assets/clasp\",\"headTitle\":\"Inbox\",\"headViewport\":\"width=device-width, initial-scale=1\",\"headStylesheet\":\"/assets/clasp/Main.styles.css\",\"styleIrKind\":\"clasp-style-ir\",\"styleRef\":\"inbox_shell\",\"styleToken\":\"color.backgroundSurface\",\"styleVariant\":\"breakpoint:base\",\"styleEscape\":\"hostStyle\",\"bindingHasStyleIR\":true,\"bundleId\":\"module:Main:styles\",\"bundleHref\":\"/assets/clasp/Main.styles.css\",\"bundleRefs\":[\"inbox_shell\"],\"assetContentType\":\"text/css; charset=utf-8\",\"assetHasRefComment\":true,\"assetHasCssToken\":true}"
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
            absoluteRuntimePath <- makeAbsolute "src/runtime/react.mjs"
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
            absoluteRuntimePath <- makeAbsolute "src/runtime/react.mjs"
            runtimeOutput <- runNodeScript (reactNativeBridgeRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected react native and expo bridge models to stay stable for future mobile reuse"
              "{\"modulePath\":\"src/runtime/react.mjs\",\"nativeEntry\":\"createReactNativeBridge\",\"expoEntry\":\"createExpoBridge\",\"nativeKind\":\"clasp-native-bridge\",\"nativePlatform\":\"react-native\",\"expoPlatform\":\"expo\",\"pageKind\":\"clasp-native-page\",\"pageTitle\":\"Inbox\",\"bodyKind\":\"styled\",\"styleRef\":\"inbox_shell\",\"stylePadding\":16,\"styleVariantCount\":3,\"styleEscape\":\"hostStyle\",\"childKind\":\"element\",\"childTag\":\"section\",\"textKind\":\"text\",\"textValue\":\"Safe <markup>\",\"linkHref\":null}"
              runtimeOutput
    , testCase "page form runtime example requires native backend emission" $
        withProjectFiles "page-form-runtime" pageFormRuntimeFiles $ \root ->
          assertBackendEntryRequiresNative (root </> "Main.clasp")
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
    , testCase "generated binary transports round-trip service, worker, tool, and workflow boundaries" $
        case compileSource "native-boundary-binary-runtime" nativeBoundarySource of
          Left err ->
            assertFailure ("expected native boundary source compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/native-boundary-binary-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript (boundaryBinaryRuntimeScript absoluteCompiledPath)
            assertEqual
              "expected binary service, worker, tool, and workflow transport contracts"
              "{\"schemaFingerprint\":\"record:LeadRequest\",\"schemaRoundTripCompany\":\"Acme\",\"serviceMode\":\"request_response\",\"serviceRequestBudget\":42,\"serviceResponseSummary\":\"Queued\",\"workerEvent\":\"worker.start\",\"workerAck\":true,\"toolMode\":\"rpc\",\"toolQuery\":\"rg worker runtime\",\"workflowMode\":\"checkpoint\",\"workflowCount\":9,\"bindingsTransportVersion\":1}"
              runtimeOutput
    , testCase "generated binary transports support agent-to-agent channels from shared schemas" $
        case compileSource "agent-binary-runtime" delegatedSecretHandoffSource of
          Left err ->
            assertFailure ("expected delegated secret handoff source compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/agent-binary-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript (agentBinaryRuntimeScript absoluteCompiledPath)
            assertEqual
              "expected agent-to-agent binary channel contract"
              "{\"agentName\":\"builder\",\"agentId\":\"agent:builder\",\"peer\":\"agent:reviewer\",\"messageType\":\"SearchRequest\",\"query\":\"needs review\",\"framing\":\"length_prefixed\"}"
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
            absoluteRuntimePath <- makeAbsolute "src/runtime/client.mjs"
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
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/worker.mjs"
            runtimeOutput <- runNodeScript (workerJobRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected typed worker job contract and dispatch"
              "{\"contractVersion\":1,\"schemaKind\":\"record\",\"seedBudget\":0,\"jobCount\":1,\"jobInputType\":\"LeadRequest\",\"jobOutputType\":\"LeadSummary\",\"outputSchemaKind\":\"record\",\"outputSeedPriority\":\"Low\",\"resultPriority\":\"high\",\"resultFollowUpRequired\":true,\"invalid\":\"budget must be an integer\"}"
              runtimeOutput
    , testCase "worker runtime constrains runtime-selected job outputs to declared schemas" $
        case compileSource "dynamic-schema-worker-runtime" dynamicSchemaSource of
          Left err ->
            assertFailure ("expected dynamic schema source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/dynamic-schema-worker-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/worker.mjs"
            runtimeOutput <- runNodeScript (dynamicSchemaWorkerRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected constrained dynamic worker outputs"
              "{\"schemaNames\":[\"LeadEscalation\",\"LeadSummary\"],\"jobOutputTypes\":[\"LeadSummary\",\"LeadEscalation\"],\"lowPriority\":\"low\",\"lowFollowUpRequired\":false,\"highOwner\":\"ae-team\",\"highReason\":\"enterprise-budget\",\"invalid\":\"result did not match any dynamic schema candidate: LeadSummary, LeadEscalation\"}"
              runtimeOutput
    , testCase "worker runtime simulates dry-run routes, workflows, policy decisions, agent loops, and temporal behavior" $
        case compileSource "simulation-worker-runtime" simulationSource of
          Left err ->
            assertFailure ("expected simulation source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/simulation-worker-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/worker.mjs"
            runtimeOutput <- runNodeScript (simulationRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected deterministic simulation runtime output"
              "{\"contractRoutes\":1,\"fixtureRoute\":\"summarizeLeadRoute\",\"controlPlaneAgents\":1,\"worldKind\":\"clasp-world-snapshot\",\"worldHasModuleVersion\":true,\"worldFixtureCount\":1,\"worldStorageOpenCount\":1,\"worldEnvironmentRegion\":\"local\",\"worldDeploymentStage\":\"staging\",\"worldProviderSummary\":\"cached-preview\",\"worldTimeNow\":1000,\"routeStatus\":\"dry_run\",\"routeSummary\":\"seed\",\"routeRequestCompany\":\"seed\",\"routeWorldFixtureRoute\":\"summarizeLeadRoute\",\"policyAllowed\":true,\"policyTraceActor\":\"builder-7\",\"policyWorldTarget\":\"rg\",\"temporalExpired\":false,\"temporalRemaining\":175,\"temporalWorldOperation\":\"ttl\",\"workflowStatus\":\"dry_run\",\"workflowCount\":10,\"workflowDeliveries\":2,\"workflowAuditCount\":3,\"workflowWorldMessageCount\":2,\"agentStatus\":\"dry_run\",\"agentApproval\":\"on_request\",\"agentSandbox\":\"workspace_write\",\"agentAllowed\":true,\"agentStepKinds\":[\"process\",\"process\"],\"agentWorldStepCount\":2,\"traceKinds\":[\"route\",\"policy\",\"temporal\",\"workflow\",\"agent_loop\"],\"auditKinds\":[\"route_dry_run\",\"policy_dry_run\",\"temporal_dry_run\",\"workflow_dry_run\",\"agent_loop_dry_run\"]}"
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
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/worker.mjs"
            runtimeOutput <- runNodeScript (workflowRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            case eitherDecodeStrictText runtimeOutput of
              Left err ->
                assertFailure ("expected workflow runtime output to be valid JSON:\n" <> err)
              Right (Object value) -> do
                assertEqual "workflow name" (Just (String "CounterFlow")) (KeyMap.lookup "workflowName" value)
                assertEqual "state type" (Just (String "Counter")) (KeyMap.lookup "stateType" value)
                assertEqual "module version tagged" (Just (Bool True)) (KeyMap.lookup "moduleVersionTagged" value)
                assertEqual "upgrade window policy" (Just (String "bounded-overlap")) (KeyMap.lookup "upgradeWindowPolicy" value)
                assertEqual "compatible version count" (Just (Number 1)) (KeyMap.lookup "compatibleVersionCount" value)
                assertEqual "hot swap handlers explicit" (Just (Bool True)) (KeyMap.lookup "hotSwapHandlersExplicit" value)
                assertEqual "hot swap migration hooks" (Just (Bool True)) (KeyMap.lookup "hotSwapMigrationHooks" value)
                assertEqual "runtime module version tagged" (Just (Bool True)) (KeyMap.lookup "runtimeModuleVersionTagged" value)
                assertEqual "runtime workflow count" (Just (Number 1)) (KeyMap.lookup "runtimeWorkflowCount" value)
                assertEqual "checkpoint" (Just (String "{\"count\":7}")) (KeyMap.lookup "checkpoint" value)
                assertEqual "resumed value" (Just (Number 7)) (KeyMap.lookup "resumedValue" value)
                assertEqual "deadline" (Just (Number 1200)) (KeyMap.lookup "deadlineAt" value)
                assertEqual "simulated clock kind" (Just (String "clasp-simulated-clock")) (KeyMap.lookup "temporalClockKind" value)
                assertEqual "simulated clock start" (Just (Number 1000)) (KeyMap.lookup "temporalClockStart" value)
                assertEqual "deadline remaining with simulated clock" (Just (Number 100)) (KeyMap.lookup "temporalDeadlineRemaining" value)
                assertEqual "ttl active remaining" (Just (Number 25)) (KeyMap.lookup "ttlActiveRemaining" value)
                assertEqual "ttl expired" (Just (Bool True)) (KeyMap.lookup "ttlExpired" value)
                assertEqual "expiration active status" (Just (String "active")) (KeyMap.lookup "expirationActiveStatus" value)
                assertEqual "expiration expired status" (Just (String "expired")) (KeyMap.lookup "expirationExpiredStatus" value)
                assertEqual "schedule status" (Just (String "active")) (KeyMap.lookup "scheduleStatus" value)
                assertEqual "schedule last at" (Just (Number 1100)) (KeyMap.lookup "scheduleLastAt" value)
                assertEqual "schedule next at" (Just (Number 1200)) (KeyMap.lookup "scheduleNextAt" value)
                assertEqual "rollout pending status" (Just (String "pending")) (KeyMap.lookup "rolloutPendingStatus" value)
                assertEqual "rollout active status" (Just (String "active")) (KeyMap.lookup "rolloutActiveStatus" value)
                assertEqual "rollout expired status" (Just (String "expired")) (KeyMap.lookup "rolloutExpiredStatus" value)
                assertEqual "cache active status" (Just (String "stale")) (KeyMap.lookup "cacheActiveStatus" value)
                assertEqual "cache expired status" (Just (String "expired")) (KeyMap.lookup "cacheExpiredStatus" value)
                assertEqual "capability pending status" (Just (String "pending")) (KeyMap.lookup "capabilityPendingStatus" value)
                assertEqual "capability active status" (Just (String "active")) (KeyMap.lookup "capabilityActiveStatus" value)
                assertEqual "capability expired status" (Just (String "expired")) (KeyMap.lookup "capabilityExpiredStatus" value)
                assertEqual "simulated deadline status" (Just (String "deadline_exceeded")) (KeyMap.lookup "simulatedDeadlineStatus" value)
                assertEqual "simulated clock end" (Just (Number 1350)) (KeyMap.lookup "temporalClockEnd" value)
                assertEqual "initial queue size" (Just (Number 1)) (KeyMap.lookup "initiallyQueued" value)
                assertEqual "queued status" (Just (String "queued")) (KeyMap.lookup "queuedStatus" value)
                assertEqual "queued mailbox size" (Just (Number 2)) (KeyMap.lookup "queuedMailboxSize" value)
                assertEqual "queued duplicate" (Just (Bool True)) (KeyMap.lookup "queuedDuplicate" value)
                assertEqual "processed queued status" (Just (String "delivered")) (KeyMap.lookup "processedQueuedStatus" value)
                assertEqual "processed queued result" (Just (String "queued-1")) (KeyMap.lookup "processedQueuedResult" value)
                assertEqual "drained status" (Just (String "drained")) (KeyMap.lookup "drainedStatus" value)
                assertEqual "drained mailbox size" (Just (Number 0)) (KeyMap.lookup "drainedMailboxSize" value)
                assertEqual "blocked mailbox status" (Just (String "operator_handoff")) (KeyMap.lookup "blockedMailboxStatus" value)
                assertEqual "blocked mailbox size" (Just (Number 2)) (KeyMap.lookup "blockedMailboxSize" value)
                assertEqual "duplicate suppressed" (Just (Bool True)) (KeyMap.lookup "duplicateSuppressed" value)
                assertEqual "duplicate result" (Just (Number 2)) (KeyMap.lookup "duplicateResult" value)
                assertEqual "retried status" (Just (String "delivered")) (KeyMap.lookup "retriedStatus" value)
                assertEqual "retried attempts" (Just (Number 3)) (KeyMap.lookup "retriedAttempts" value)
                assertEqual "retried result" (Just (Number 3)) (KeyMap.lookup "retriedResult" value)
                assertEqual "deadline status" (Just (String "deadline_exceeded")) (KeyMap.lookup "deadlineStatus" value)
                assertEqual "deadline attempts" (Just (Number 2)) (KeyMap.lookup "deadlineAttempts" value)
                assertEqual "deadline failure" (Just (String "slow-2")) (KeyMap.lookup "deadlineFailure" value)
                assertEqual "failed status" (Just (String "failed")) (KeyMap.lookup "failedStatus" value)
                assertEqual "failed attempts" (Just (Number 2)) (KeyMap.lookup "failedAttempts" value)
                assertEqual "failed failure" (Just (String "fatal-2")) (KeyMap.lookup "failedFailure" value)
                assertEqual "cancelled status" (Just (String "cancelled")) (KeyMap.lookup "cancelledStatus" value)
                assertEqual "cancel reason" (Just (String "manual-stop")) (KeyMap.lookup "cancelReason" value)
                assertEqual "degraded status" (Just (String "degraded")) (KeyMap.lookup "degradedStatus" value)
                assertEqual "degraded reason" (Just (String "provider-outage")) (KeyMap.lookup "degradedReason" value)
                assertEqual "degraded supervisor" (Just (String "SupportSupervisor")) (KeyMap.lookup "degradedSupervisor" value)
                assertEqual "degraded fallback status" (Just (String "delivered")) (KeyMap.lookup "degradedFallbackStatus" value)
                assertEqual "degraded fallback result" (Just (String "fallback-1")) (KeyMap.lookup "degradedFallbackResult" value)
                assertEqual "degraded fallback mode" (Just (String "degraded")) (KeyMap.lookup "degradedFallbackMode" value)
                assertEqual "handoff status" (Just (String "operator_handoff")) (KeyMap.lookup "handoffStatus" value)
                assertEqual "handoff operator" (Just (String "case-ops")) (KeyMap.lookup "handoffOperator" value)
                assertEqual "handoff reason" (Just (String "manual-review")) (KeyMap.lookup "handoffReason" value)
                assertEqual "handoff supervisor" (Just (String "SupportSupervisor")) (KeyMap.lookup "handoffSupervisor" value)
                assertEqual "replayed count" (Just (Number 12)) (KeyMap.lookup "replayedCount" value)
                assertEqual "replayed deliveries" (Just (Number 2)) (KeyMap.lookup "replayedDeliveries" value)
                assertEqual "replayed audit count" (Just (Number 4)) (KeyMap.lookup "replayedAuditCount" value)
                assertEqual "replayed first audit" (Just (String "started")) (KeyMap.lookup "replayedAuditFirst" value)
                assertEqual "replayed excludes cancelled audit" (Just (Bool False)) (KeyMap.lookup "replayedHasCancelledAudit" value)
                assertEqual "replay seed audit count" (Just (Number 3)) (KeyMap.lookup "replaySeedAuditCount" value)
                assertEqual "migrated status" (Just (String "migrated")) (KeyMap.lookup "migratedStatus" value)
                assertEqual "migrated count" (Just (Number 12)) (KeyMap.lookup "migratedCount" value)
                assertEqual "migrated hook" (Just (Bool True)) (KeyMap.lookup "migratedHook" value)
                assertEqual "migrated audit type" (Just (String "upgrade")) (KeyMap.lookup "migratedAuditType" value)
                assertEqual "upgraded status" (Just (String "upgraded")) (KeyMap.lookup "upgradedStatus" value)
                assertEqual "upgraded count" (Just (Number 27)) (KeyMap.lookup "upgradedCount" value)
                assertEqual "upgraded deadline" (Just (Number 1250)) (KeyMap.lookup "upgradedDeadlineAt" value)
                assertEqual "upgraded supervisor" (Just (String "UpgradeSupervisor")) (KeyMap.lookup "upgradedSupervisor" value)
                assertEqual "upgraded prepare hook" (Just (Bool True)) (KeyMap.lookup "upgradedPrepareHook" value)
                assertEqual "upgraded activate hook" (Just (Bool True)) (KeyMap.lookup "upgradedActivateHook" value)
                assertEqual "upgraded audit type" (Just (String "upgrade")) (KeyMap.lookup "upgradedAuditType" value)
                assertEqual "retried delays" (Just [Number 50, Number 80]) (jsonArrayValues (KeyMap.lookup "retriedDelays" value))
                assertEqual "retried audit kinds" (Just [String "retry", String "retry", String "transition"]) (jsonArrayValues (KeyMap.lookup "retriedAuditKinds" value))
                assertEqual "retried audit tail" (Just [String "retry", String "retry", String "transition"]) (jsonArrayValues (KeyMap.lookup "retriedAuditLogTail" value))
                assertEqual "deadline audit kinds" (Just [String "retry", String "retry", String "retry"]) (jsonArrayValues (KeyMap.lookup "deadlineAuditKinds" value))
                assertEqual "deadline audit outcome" (Just (String "deadline_exceeded")) (KeyMap.lookup "deadlineAuditOutcome" value)
                assertEqual "failed audit kinds" (Just [String "retry", String "retry"]) (jsonArrayValues (KeyMap.lookup "failedAuditKinds" value))
                assertEqual "failed audit outcome" (Just (String "failed")) (KeyMap.lookup "failedAuditOutcome" value)
                assertEqual "failed audit exhausted" (Just (Bool True)) (KeyMap.lookup "failedAuditExhausted" value)
                assertEqual "replayed ids" (Just [String "m1", String "m2"]) (jsonArrayValues (KeyMap.lookup "replayedIds" value))
                assertEqual "drained queued results" (Just [Number 4]) (jsonArrayValues (KeyMap.lookup "drainedQueuedResults" value))
                assertEqual "upgraded audit log tail" (Just [String "upgrade"]) (jsonArrayValues (KeyMap.lookup "upgradedAuditLogTail" value))
              Right other ->
                assertFailure ("expected JSON object from workflow runtime, got " <> show other)
    , testCase "worker runtime enforces declared workflow invariants, preconditions, and postconditions" $
        case compileSource "workflow-constraint-runtime" workflowConstraintSource of
          Left err ->
            assertFailure ("expected constrained workflow compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/workflow-constraint-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/worker.mjs"
            runtimeOutput <- runNodeScript (workflowConstraintRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected workflow constraint runtime output"
              "{\"constraintNames\":[\"belowLimit\",\"nonNegative\",\"withinLimit\"],\"deliveredStatus\":\"delivered\",\"deliveredResult\":4,\"resumedCount\":2,\"invariantError\":\"Workflow CounterFlow invariant nonNegative failed during start.\",\"preconditionStatus\":\"failed\",\"preconditionError\":\"Workflow CounterFlow precondition belowLimit failed during deliver.\",\"postconditionStatus\":\"failed\",\"postconditionError\":\"Workflow CounterFlow postcondition withinLimit failed during deliver.\"}"
              runtimeOutput
    , testCase "worker runtime schedules isolated workflow units in parallel while preserving mailbox and upgrade ordering" $
        case (compileSource "workflow-parallel-old" workflowSource, compileSource "workflow-parallel-new" workflowHotSwapTargetSource) of
          (Left err, _) ->
            assertFailure ("expected old workflow compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          (_, Left err) ->
            assertFailure ("expected new workflow compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          (Right oldEmitted, Right newEmitted) -> do
            let oldCompiledPath = "dist/test-projects/workflow-parallel-runtime/old-compiled.mjs"
            let newCompiledPath = "dist/test-projects/workflow-parallel-runtime/new-compiled.mjs"
            createDirectoryIfMissing True (takeDirectory oldCompiledPath)
            TIO.writeFile oldCompiledPath oldEmitted
            TIO.writeFile newCompiledPath newEmitted
            absoluteOldCompiledPath <- makeAbsolute oldCompiledPath
            absoluteNewCompiledPath <- makeAbsolute newCompiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/worker.mjs"
            runtimeOutput <- runNodeScript (workflowParallelRuntimeScript absoluteOldCompiledPath absoluteNewCompiledPath absoluteRuntimePath)
            case eitherDecodeStrictText runtimeOutput of
              Left err ->
                assertFailure ("expected parallel runtime output to be valid JSON:\n" <> err)
              Right (Object value) -> do
                assertEqual "scheduler kind" (Just (String "clasp-parallel-scheduler")) (KeyMap.lookup "schedulerKind" value)
                assertEqual "max parallelism" (Just (Number 2)) (KeyMap.lookup "maxParallelism" value)
                assertEqual "max active" (Just (Number 2)) (KeyMap.lookup "maxActive" value)
                assertEqual "beta overlapped alpha" (Just (Bool True)) (KeyMap.lookup "betaOverlappedAlpha" value)
                assertEqual "same unit serialized" (Just (Bool True)) (KeyMap.lookup "sameUnitSerialized" value)
                assertEqual "upgrade serialized" (Just (Bool True)) (KeyMap.lookup "upgradeSerialized" value)
                assertEqual "scheduler drained" (Just (Number 0)) (KeyMap.lookup "activeAfter" value)
                assertEqual "unit count" (Just (Number 2)) (KeyMap.lookup "unitCount" value)
                assertEqual "alpha first status" (Just (String "delivered")) (KeyMap.lookup "alphaFirstStatus" value)
                assertEqual "alpha second status" (Just (String "delivered")) (KeyMap.lookup "alphaSecondStatus" value)
                assertEqual "alpha upgrade status" (Just (String "upgraded")) (KeyMap.lookup "alphaUpgradeStatus" value)
                assertEqual "alpha upgrade protocol" (Just (String "clasp-module-hot-swap")) (KeyMap.lookup "alphaUpgradeProtocol" value)
                assertEqual "alpha final count" (Just (Number 106)) (KeyMap.lookup "alphaFinalCount" value)
                assertEqual "alpha supervisor" (Just (String "UpgradeSupervisor")) (KeyMap.lookup "alphaSupervisor" value)
                assertEqual "alpha target tagged" (Just (Bool True)) (KeyMap.lookup "alphaTargetTagged" value)
                assertEqual "alpha processed ids" (Just [String "alpha-1", String "alpha-2"]) (jsonArrayValues (KeyMap.lookup "alphaProcessedIds" value))
                assertEqual "beta status" (Just (String "delivered")) (KeyMap.lookup "betaStatus" value)
                assertEqual "beta final count" (Just (Number 14)) (KeyMap.lookup "betaFinalCount" value)
                assertEqual "beta processed ids" (Just [String "beta-1"]) (jsonArrayValues (KeyMap.lookup "betaProcessedIds" value))
              Right other ->
                assertFailure ("expected JSON object from parallel runtime, got " <> show other)
    , testCase "worker runtime stages supervised module hot swaps with bounded overlap" $
        case (compileSource "workflow-hot-swap-old" workflowSource, compileSource "workflow-hot-swap-new" workflowHotSwapTargetSource) of
          (Left err, _) ->
            assertFailure ("expected old workflow compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          (_, Left err) ->
            assertFailure ("expected new workflow compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          (Right oldEmitted, Right newEmitted) -> do
            let oldCompiledPath = "dist/test-projects/workflow-hot-swap-runtime/old-compiled.mjs"
            let newCompiledPath = "dist/test-projects/workflow-hot-swap-runtime/new-compiled.mjs"
            createDirectoryIfMissing True (takeDirectory oldCompiledPath)
            TIO.writeFile oldCompiledPath oldEmitted
            TIO.writeFile newCompiledPath newEmitted
            absoluteOldCompiledPath <- makeAbsolute oldCompiledPath
            absoluteNewCompiledPath <- makeAbsolute newCompiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/worker.mjs"
            runtimeOutput <- runNodeScript (workflowHotSwapRuntimeScript absoluteOldCompiledPath absoluteNewCompiledPath absoluteRuntimePath)
            case eitherDecodeStrictText runtimeOutput of
              Left err ->
                assertFailure ("expected hot-swap runtime output to be valid JSON:\n" <> err)
              Right (Object value) -> do
                assertEqual "protocol kind" (Just (String "clasp-module-hot-swap")) (KeyMap.lookup "protocolKind" value)
                assertEqual "supervisor" (Just (String "UpgradeSupervisor")) (KeyMap.lookup "supervisor" value)
                assertEqual "source version tagged" (Just (Bool True)) (KeyMap.lookup "sourceVersionTagged" value)
                assertEqual "target version tagged" (Just (Bool True)) (KeyMap.lookup "targetVersionTagged" value)
                assertEqual "max active versions" (Just (Number 2)) (KeyMap.lookup "maxActiveVersions" value)
                assertEqual "active version count" (Just (Number 2)) (KeyMap.lookup "activeVersionCount" value)
                assertEqual "accepts source version" (Just (Bool True)) (KeyMap.lookup "acceptsSourceVersion" value)
                assertEqual "workflow count" (Just (Number 1)) (KeyMap.lookup "workflowCount" value)
                assertEqual "workflow name" (Just (String "CounterFlow")) (KeyMap.lookup "workflowName" value)
                assertEqual "workflow handlers explicit" (Just (Bool True)) (KeyMap.lookup "workflowHotSwapHandlers" value)
                assertEqual "overlap status" (Just (String "overlap")) (KeyMap.lookup "overlapStatus" value)
                assertEqual "overlap started at" (Just (Number 1000)) (KeyMap.lookup "overlapStartedAt" value)
                assertEqual "retired status" (Just (String "retired")) (KeyMap.lookup "retiredStatus" value)
                assertEqual "retired reason" (Just (String "drained")) (KeyMap.lookup "retiredReason" value)
                assertEqual "remaining version count" (Just (Number 1)) (KeyMap.lookup "remainingVersionCount" value)
                assertEqual "upgraded status" (Just (String "upgraded")) (KeyMap.lookup "upgradedStatus" value)
                assertEqual "upgraded count" (Just (Number 8)) (KeyMap.lookup "upgradedCount" value)
                assertEqual "upgraded mailbox size" (Just (Number 1)) (KeyMap.lookup "upgradedMailboxSize" value)
                assertEqual "upgraded queued id" (Just (String "queued-upgrade")) (KeyMap.lookup "upgradedQueuedId" value)
                assertEqual "upgraded supervisor" (Just (String "UpgradeSupervisor")) (KeyMap.lookup "upgradedSupervisor" value)
                assertEqual "upgraded target version tagged" (Just (Bool True)) (KeyMap.lookup "upgradedTargetVersionTagged" value)
              Right other ->
                assertFailure ("expected JSON object from hot-swap runtime, got " <> show other)
    , testCase "worker runtime exposes self-update handoff, draining, and rollback rules" $
        case (compileSource "workflow-self-update-old" workflowSource, compileSource "workflow-self-update-new" workflowHotSwapTargetSource) of
          (Left err, _) ->
            assertFailure ("expected old workflow compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          (_, Left err) ->
            assertFailure ("expected new workflow compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          (Right oldEmitted, Right newEmitted) -> do
            let oldCompiledPath = "dist/test-projects/workflow-self-update-runtime/old-compiled.mjs"
            let newCompiledPath = "dist/test-projects/workflow-self-update-runtime/new-compiled.mjs"
            createDirectoryIfMissing True (takeDirectory oldCompiledPath)
            TIO.writeFile oldCompiledPath oldEmitted
            TIO.writeFile newCompiledPath newEmitted
            absoluteOldCompiledPath <- makeAbsolute oldCompiledPath
            absoluteNewCompiledPath <- makeAbsolute newCompiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/worker.mjs"
            runtimeOutput <- runNodeScript (workflowSelfUpdateRuntimeScript absoluteOldCompiledPath absoluteNewCompiledPath absoluteRuntimePath)
            case eitherDecodeStrictText runtimeOutput of
              Left err ->
                assertFailure ("expected self-update runtime output to be valid JSON:\n" <> err)
              Right (Object value) -> do
                assertEqual "handoff status" (Just (String "handoff")) (KeyMap.lookup "handoffStatus" value)
                assertEqual "handoff operator" (Just (String "release-bot")) (KeyMap.lookup "handoffOperator" value)
                assertEqual "handoff reason" (Just (String "self-update")) (KeyMap.lookup "handoffReason" value)
                assertEqual "handoff rollback available" (Just (Bool True)) (KeyMap.lookup "handoffRollbackAvailable" value)
                assertEqual "draining status" (Just (String "draining")) (KeyMap.lookup "drainingStatus" value)
                assertEqual "draining version tagged" (Just (Bool True)) (KeyMap.lookup "drainingVersionTagged" value)
                assertEqual "draining supervisor" (Just (String "UpgradeSupervisor")) (KeyMap.lookup "drainingSupervisor" value)
                assertEqual "draining rollback available" (Just (Bool True)) (KeyMap.lookup "drainingRollbackAvailable" value)
                assertEqual "upgraded status" (Just (String "upgraded")) (KeyMap.lookup "upgradedStatus" value)
                assertEqual "upgraded count" (Just (Number 8)) (KeyMap.lookup "upgradedCount" value)
                assertEqual "upgraded supervision" (Just (String "operator_handoff")) (KeyMap.lookup "upgradedSupervision" value)
                assertEqual "rollback status" (Just (String "rolled_back")) (KeyMap.lookup "rollbackStatus" value)
                assertEqual "rollback count" (Just (Number 5)) (KeyMap.lookup "rollbackCount" value)
                assertEqual "rollback supervisor" (Just (String "RollbackSupervisor")) (KeyMap.lookup "rollbackSupervisor" value)
                assertEqual "rollback source tagged" (Just (Bool True)) (KeyMap.lookup "rollbackSourceTagged" value)
                assertEqual "rollback target tagged" (Just (Bool True)) (KeyMap.lookup "rollbackTargetTagged" value)
                assertEqual "rollback handoff preserved" (Just (String "operator_handoff")) (KeyMap.lookup "rollbackSupervision" value)
                assertEqual "rollback migration hook" (Just (Bool True)) (KeyMap.lookup "rollbackMigrationHook" value)
                assertEqual "rollback activation hook" (Just (Bool True)) (KeyMap.lookup "rollbackActivationHook" value)
                assertEqual "rollback audit type" (Just (String "rollback")) (KeyMap.lookup "rollbackAuditType" value)
                assertEqual "rollback audit trigger kind" (Just Null) (KeyMap.lookup "rollbackAuditTriggerKind" value)
                assertEqual "rollback audit log tail" (Just [String "upgrade", String "rollback"]) (jsonArrayValues (KeyMap.lookup "rollbackAuditLogTail" value))
              Right other ->
                assertFailure ("expected JSON object from self-update runtime, got " <> show other)
    , testCase "worker runtime health-gates activation and attaches rollback triggers" $
        case (compileSource "workflow-health-gated-old" workflowSource, compileSource "workflow-health-gated-new" workflowHotSwapTargetSource) of
          (Left err, _) ->
            assertFailure ("expected old workflow compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          (_, Left err) ->
            assertFailure ("expected new workflow compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          (Right oldEmitted, Right newEmitted) -> do
            let oldCompiledPath = "dist/test-projects/workflow-health-gated-runtime/old-compiled.mjs"
            let newCompiledPath = "dist/test-projects/workflow-health-gated-runtime/new-compiled.mjs"
            createDirectoryIfMissing True (takeDirectory oldCompiledPath)
            TIO.writeFile oldCompiledPath oldEmitted
            TIO.writeFile newCompiledPath newEmitted
            absoluteOldCompiledPath <- makeAbsolute oldCompiledPath
            absoluteNewCompiledPath <- makeAbsolute newCompiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/worker.mjs"
            runtimeOutput <- runNodeScript (workflowHealthGatedRuntimeScript absoluteOldCompiledPath absoluteNewCompiledPath absoluteRuntimePath)
            case eitherDecodeStrictText runtimeOutput of
              Left err ->
                assertFailure ("expected health-gated runtime output to be valid JSON:\n" <> err)
              Right (Object value) -> do
                assertEqual "activated status" (Just (String "activated")) (KeyMap.lookup "activatedStatus" value)
                assertEqual "activated health" (Just (String "healthy")) (KeyMap.lookup "activatedHealthStatus" value)
                assertEqual "activated rollback available" (Just (Bool True)) (KeyMap.lookup "activatedRollbackAvailable" value)
                assertEqual "activated count" (Just (Number 8)) (KeyMap.lookup "activatedCount" value)
                assertEqual "activated target tagged" (Just (Bool True)) (KeyMap.lookup "activatedTargetTagged" value)
                assertEqual "blocked status" (Just (String "blocked")) (KeyMap.lookup "blockedStatus" value)
                assertEqual "blocked health" (Just (String "probe-warming")) (KeyMap.lookup "blockedHealthStatus" value)
                assertEqual "blocked rollback available" (Just (Bool True)) (KeyMap.lookup "blockedRollbackAvailable" value)
                assertEqual "blocked count" (Just (Number 8)) (KeyMap.lookup "blockedCount" value)
                assertEqual "auto rollback status" (Just (String "rolled_back")) (KeyMap.lookup "autoRollbackStatus" value)
                assertEqual "auto rollback trigger" (Just (String "health_check_failed")) (KeyMap.lookup "autoRollbackTriggerKind" value)
                assertEqual "auto rollback reason" (Just (String "probe-failed")) (KeyMap.lookup "autoRollbackTriggerReason" value)
                assertEqual "auto rollback at" (Just (Number 1004)) (KeyMap.lookup "autoRollbackTriggerAt" value)
                assertEqual "auto rollback count" (Just (Number 5)) (KeyMap.lookup "autoRollbackCount" value)
                assertEqual "manual rollback status" (Just (String "rolled_back")) (KeyMap.lookup "manualRollbackStatus" value)
                assertEqual "manual rollback trigger" (Just (String "error_budget")) (KeyMap.lookup "manualRollbackTriggerKind" value)
                assertEqual "manual rollback reason" (Just (String "latency-spike")) (KeyMap.lookup "manualRollbackTriggerReason" value)
                assertEqual "manual rollback at" (Just (Number 1005)) (KeyMap.lookup "manualRollbackTriggerAt" value)
                assertEqual "manual rollback count" (Just (Number 5)) (KeyMap.lookup "manualRollbackCount" value)
                assertEqual "manual rollback supervisor" (Just (String "RollbackSupervisor")) (KeyMap.lookup "manualRollbackSupervisor" value)
                assertEqual "auto rollback audit type" (Just (String "rollback")) (KeyMap.lookup "autoRollbackAuditType" value)
                assertEqual "auto rollback audit trigger kind" (Just (String "health_check_failed")) (KeyMap.lookup "autoRollbackAuditTriggerKind" value)
                assertEqual "manual rollback audit type" (Just (String "rollback")) (KeyMap.lookup "manualRollbackAuditType" value)
                assertEqual "manual rollback audit trigger kind" (Just (String "error_budget")) (KeyMap.lookup "manualRollbackAuditTriggerKind" value)
              Right other ->
                assertFailure ("expected JSON object from health-gated runtime, got " <> show other)
    , testCase "worker runtime kill switch latches rollback and disables further swaps" $
        case (compileSource "workflow-kill-switch-old" workflowSource, compileSource "workflow-kill-switch-new" workflowHotSwapTargetSource) of
          (Left err, _) ->
            assertFailure ("expected old workflow compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          (_, Left err) ->
            assertFailure ("expected new workflow compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          (Right oldEmitted, Right newEmitted) -> do
            let oldCompiledPath = "dist/test-projects/workflow-kill-switch-runtime/old-compiled.mjs"
            let newCompiledPath = "dist/test-projects/workflow-kill-switch-runtime/new-compiled.mjs"
            createDirectoryIfMissing True (takeDirectory oldCompiledPath)
            TIO.writeFile oldCompiledPath oldEmitted
            TIO.writeFile newCompiledPath newEmitted
            absoluteOldCompiledPath <- makeAbsolute oldCompiledPath
            absoluteNewCompiledPath <- makeAbsolute newCompiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/worker.mjs"
            runtimeOutput <- runNodeScript (workflowKillSwitchRuntimeScript absoluteOldCompiledPath absoluteNewCompiledPath absoluteRuntimePath)
            case eitherDecodeStrictText runtimeOutput of
              Left err ->
                assertFailure ("expected kill-switch runtime output to be valid JSON:\n" <> err)
              Right (Object value) -> do
                assertEqual "kill status" (Just (String "killed")) (KeyMap.lookup "killStatus" value)
                assertEqual "kill rollback status" (Just (String "rolled_back")) (KeyMap.lookup "killRollbackStatus" value)
                assertEqual "kill active" (Just (Bool True)) (KeyMap.lookup "killActive" value)
                assertEqual "kill trigger kind" (Just (String "policy_breach")) (KeyMap.lookup "killTriggerKind" value)
                assertEqual "kill trigger reason" (Just (String "policy-breach")) (KeyMap.lookup "killTriggerReason" value)
                assertEqual "kill trigger at" (Just (Number 1006)) (KeyMap.lookup "killTriggerAt" value)
                assertEqual "kill count" (Just (Number 5)) (KeyMap.lookup "killCount" value)
                assertEqual "kill supervisor" (Just (String "RollbackSupervisor")) (KeyMap.lookup "killSupervisor" value)
                assertEqual "kill operator" (Just (String "safety-bot")) (KeyMap.lookup "killOperator" value)
                assertEqual "kill reason" (Just (String "policy-breach")) (KeyMap.lookup "killReason" value)
                assertEqual "kill state rollback applied" (Just (Bool True)) (KeyMap.lookup "killStateRollbackApplied" value)
                assertEqual "kill state trigger kind" (Just (String "policy_breach")) (KeyMap.lookup "killStateTriggerKind" value)
                assertEqual "kill audit type" (Just (String "kill_switch")) (KeyMap.lookup "killAuditType" value)
                assertEqual "kill audit rollback status" (Just (String "rolled_back")) (KeyMap.lookup "killAuditRollbackStatus" value)
                assertEqual "kill audit log tail" (Just [String "rollback", String "kill_switch"]) (jsonArrayValues (KeyMap.lookup "killAuditLogTail" value))
                assertEqual "blocked operation mentions kill switch" (Just (Bool True)) (KeyMap.lookup "blockedOperationMentionsKillSwitch" value)
              Right other ->
                assertFailure ("expected JSON object from kill-switch runtime, got " <> show other)
    , testCase "server runtime resolves target-aware native interop build plans" $
        case compileSource "service-native-interop-runtime" serviceSource of
          Left err ->
            assertFailure ("expected service compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/service-native-interop-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
            runtimeOutput <- runNodeScript (nativeInteropRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected native interop contract and build plan"
              "{\"abi\":\"clasp-native-v1\",\"supportedTargets\":[\"bun\",\"worker\",\"react-native\",\"expo\"],\"bindingName\":\"mockLeadSummaryModel\",\"capabilityId\":\"capability:foreign:mockLeadSummaryModel\",\"crateName\":\"lead_summary_bridge\",\"loader\":\"bun:ffi\",\"crateType\":\"cdylib\",\"manifestPath\":\"native/lead-summary/Cargo.toml\",\"artifactFileName\":\"liblead_summary_bridge.so\",\"cargoCommand\":[\"cargo\",\"build\",\"--manifest-path\",\"native/lead-summary/Cargo.toml\",\"--release\",\"--target\",\"x86_64-unknown-linux-gnu\"],\"capabilities\":[\"capability:foreign:mockLeadSummaryModel\",\"capability:ml:lead-summary\"]}"
              runtimeOutput
    , testCase "provider runtime abstracts provider-backed foreign bindings for app routes" $ do
        case compileSource "provider-runtime" providerRuntimeSource of
          Left err ->
            assertFailure ("expected provider runtime source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/provider-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
            runtimeOutput <- runNodeScript (providerRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected provider contract and provider-backed page flow"
              "{\"providerKind\":\"clasp-provider-contract\",\"providerVersion\":1,\"providerNames\":[\"provider\"],\"providerOperation\":\"replyPreview\",\"providerBinding\":\"generateReplyPreview\",\"runtimeInstalled\":true,\"runtimeBindingVisible\":true,\"seenProvider\":\"provider\",\"seenOperation\":\"replyPreview\",\"seenCustomerId\":\"cust-42\",\"previewHasReply\":true,\"customerHasExport\":true}"
              runtimeOutput
    , testCase "storage contract derives schema-backed tables and semantic storage types from storage bindings" $ do
        case compileSource "storage-runtime" providerRuntimeSource of
          Left err ->
            assertFailure ("expected storage runtime source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/storage-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
            runtimeOutput <- runNodeScript (storageRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected derived storage contract output"
              "{\"storageKind\":\"clasp-storage-contract\",\"storageVersion\":1,\"bindingNames\":[\"publishCustomer\"],\"runtimeNames\":[\"storage:publishCustomer\"],\"tableNames\":[\"support_customer\"],\"paramSemanticType\":\"SupportCustomer\",\"returnSemanticType\":\"SupportCustomer\",\"tableSchemaType\":\"SupportCustomer\",\"tableColumnNames\":[\"company\",\"contactEmail\"],\"tableColumnTypes\":[\"Str\",\"Str\"],\"columnConstraintKinds\":[[\"not_null\"],[\"not_null\"]],\"tableDeclaration\":\"create table if not exists \\\"support_customer\\\" (\\\"company\\\" TEXT NOT NULL, \\\"contactEmail\\\" TEXT NOT NULL);\"}"
              runtimeOutput
    , testCase "sqlite runtime installs typed connection bindings and keeps live sqlite handles addressable by typed connection ids" $ do
        case compileSource "sqlite-runtime" sqliteRuntimeSource of
          Left err ->
            assertFailure ("expected sqlite runtime source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/sqlite-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
            runtimeOutput <- runNodeScript (sqliteRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected sqlite contract and live connection runtime output"
              "{\"sqliteKind\":\"clasp-sqlite-contract\",\"sqliteVersion\":1,\"bindingNames\":[\"sqliteOpen\",\"sqliteOpenReadonly\"],\"runtimeNames\":[\"sqlite:open\",\"sqlite:openReadonly\"],\"runtimeInstalled\":true,\"memoryPath\":\":memory:\",\"memoryIsMemory\":true,\"readonlyPath\":\"dist/test-projects/sqlite-runtime/runtime.db\",\"readonlyFlag\":true,\"liveConnectionCount\":4,\"rowCount\":1,\"lookupPath\":\"dist/test-projects/sqlite-runtime/runtime.db\",\"closed\":true,\"closedLookup\":\"Unknown Clasp sqlite connection: sqlite-connection-2\"}"
              runtimeOutput
    , testCase "sqlite runtime exposes schema migration and compatibility hooks when typed connections open app databases" $ do
        case compileSource "sqlite-schema-runtime" sqliteRuntimeSource of
          Left err ->
            assertFailure ("expected sqlite schema runtime source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/sqlite-schema-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
            runtimeOutput <- runNodeScript (sqliteSchemaRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected sqlite schema hooks runtime output"
              "{\"runtimeInstalled\":true,\"migratedVersion\":2,\"migratedColumns\":[\"archived\",\"value\"],\"archivedValue\":0,\"readonlyVersion\":2,\"incompatibleError\":\"Incompatible SQLite schema for dist/test-projects/sqlite-schema-runtime/incompatible.db: expected notes.archived at schema 2\",\"events\":[\"migrate:sqlite-connection-1:1->2\",\"migrated:2\",\"compatible:sqlite-connection-1:2:true\",\"open:sqlite-connection-1:2\",\"compatible:sqlite-connection-2:2:true\",\"open:sqlite-connection-2:2\",\"compatible:sqlite-connection-3:1:false\"]}"
              runtimeOutput
    , testCase "sqlite runtime executes typed query bindings and maps query rows through declared result schemas" $ do
        case compileSource "sqlite-query-runtime" sqliteQueryRuntimeSource of
          Left err ->
            assertFailure ("expected sqlite query runtime source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/sqlite-query-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
            runtimeOutput <- runNodeScript (sqliteQueryRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected typed sqlite query runtime output"
              "{\"sqliteKind\":\"clasp-sqlite-contract\",\"sqliteVersion\":1,\"bindingNames\":[\"fetchFirstNote\",\"fetchNoteCount\",\"fetchNoteRows\",\"fetchNotesByValue\"],\"runtimeNames\":[\"sqlite:queryOne\",\"sqlite:queryOne\",\"sqlite:queryAll\",\"sqlite:queryAll\"],\"operations\":[\"queryOne\",\"queryOne\",\"queryAll\",\"queryAll\"],\"runtimeInstalled\":true,\"firstNote\":\"alpha\",\"noteCount\":3,\"noteValues\":[\"alpha\",\"beta\",\"gamma\"],\"filteredNotes\":[{\"note\":\"beta\"}]}"
              runtimeOutput
    , testCase "sqlite runtime executes typed mutation bindings inside typed transaction boundaries with isolation and rollback semantics" $ do
        case compileSource "sqlite-mutation-runtime" sqliteMutationRuntimeSource of
          Left err ->
            assertFailure ("expected sqlite mutation runtime source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/sqlite-mutation-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
            runtimeOutput <- runNodeScript (sqliteMutationRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected typed sqlite mutation runtime output"
              "{\"sqliteKind\":\"clasp-sqlite-contract\",\"sqliteVersion\":1,\"bindingNames\":[\"insertNote\",\"replaceNotes\"],\"runtimeNames\":[\"sqlite:mutateOne:immediate\",\"sqlite:mutateAll:exclusive\"],\"operations\":[\"mutateOne\",\"mutateAll\"],\"isolations\":[\"immediate\",\"exclusive\"],\"mutationKinds\":[\"one\",\"many\"],\"paramSemanticTypes\":[\"NoteInput\",\"NoteInput\"],\"returnSemanticTypes\":[\"NoteRow\",\"[NoteRow]\"],\"runtimeInstalled\":true,\"insertedNote\":\"beta\",\"replacedNotes\":[{\"note\":\"BETA\"}],\"committedTransaction\":{\"kind\":\"clasp-sqlite-transaction\",\"isolation\":\"immediate\",\"boundary\":\"connection\",\"depth\":1},\"nestedTransaction\":{\"kind\":\"clasp-sqlite-transaction\",\"isolation\":\"exclusive\",\"boundary\":\"savepoint\",\"depth\":2},\"rolledBack\":\"rollback mutation\",\"finalNotes\":[\"BETA\",\"alpha\"]}"
              runtimeOutput
    , testCase "sqlite query and mutation contracts preserve policy-gated projected row and field metadata" $ do
        case compileSource "sqlite-protected-runtime" sqliteProtectedRuntimeSource of
          Left err ->
            assertFailure ("expected protected sqlite runtime source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/sqlite-protected-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
            runtimeOutput <- runNodeScript (sqliteProtectedRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected protected sqlite contract output"
              "{\"queryReturnSemanticType\":\"[SupportCustomer]\",\"queryRowPolicy\":\"SupportDisclosure\",\"queryRowProjectionSource\":\"Customer\",\"queryProtectedFields\":[\"email\"],\"queryEmailClassification\":\"pii\",\"queryEmailFieldIdentity\":\"Customer.email\",\"queryEmailPolicy\":\"SupportDisclosure\",\"queryEmailRequiresProof\":true,\"mutationParamSemanticType\":\"SupportCustomer\",\"mutationParamPolicy\":\"SupportDisclosure\",\"mutationReturnPolicy\":\"SupportDisclosure\",\"savedEmail\":\"ops@northwind.example\",\"loadedEmails\":[\"ops@northwind.example\"]}"
              runtimeOutput
    , testCase "sqlite runtime exposes explicit unsafe SQL bindings with row-contract metadata and audit entries" $ do
        case compileSource "sqlite-unsafe-runtime" sqliteUnsafeRuntimeSource of
          Left err ->
            assertFailure ("expected unsafe sqlite runtime source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/sqlite-unsafe-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
            runtimeOutput <- runNodeScript (sqliteUnsafeRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected unsafe sqlite runtime output"
              "{\"sqliteKind\":\"clasp-sqlite-contract\",\"sqliteVersion\":1,\"bindingNames\":[\"fetchUnsafeFirstNote\",\"fetchUnsafeNotes\",\"rewriteUnsafeNotes\"],\"runtimeNames\":[\"sqlite:unsafeQueryOne\",\"sqlite:unsafeQueryAll\",\"sqlite:unsafeMutateAll:immediate\"],\"operations\":[\"unsafeQueryOne\",\"unsafeQueryAll\",\"unsafeMutateAll\"],\"unsafeBaseOperations\":[\"queryOne\",\"queryAll\",\"mutateAll\"],\"unsafeRowContracts\":[\"UnsafeNoteRow\",\"[UnsafeNoteRow]\",\"[UnsafeNoteRow]\"],\"unsafeAuditKinds\":[\"clasp-sqlite-unsafe-sql-audit-metadata\",\"clasp-sqlite-unsafe-sql-audit-metadata\",\"clasp-sqlite-unsafe-sql-audit-metadata\"],\"runtimeInstalled\":true,\"firstNote\":\"alpha\",\"allNotes\":[\"alpha\",\"beta\"],\"rewrittenNotes\":[\"BETA\"],\"auditCount\":3,\"auditOperations\":[\"unsafeQueryOne\",\"unsafeQueryAll\",\"unsafeMutateAll\"],\"auditRowContracts\":[\"UnsafeNoteRow\",\"[UnsafeNoteRow]\",\"[UnsafeNoteRow]\"],\"auditParameterCounts\":[0,0,1],\"finalNotes\":[\"BETA\",\"alpha\"],\"clearedAuditCount\":0}"
              runtimeOutput
    , testCase "provider runtime validates structured JSON-text outputs against declared schemas" $ do
        case compileSource "provider-runtime-invalid" providerRuntimeSource of
          Left err ->
            assertFailure ("expected provider runtime source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/provider-runtime-invalid/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
            runtimeOutput <- runNodeScript (providerRuntimeInvalidOutputScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected structured output validation failure"
              "suggestedReply must be a string"
              runtimeOutput
    , testCase "server runtime routes can decode constrained dynamic-schema outputs across request boundaries" $ do
        case compileSource "dynamic-schema-server-runtime" dynamicSchemaSource of
          Left err ->
            assertFailure ("expected dynamic schema source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/dynamic-schema-server-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
            runtimeOutput <- runNodeScript (dynamicSchemaServerRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected route-level constrained dynamic schema decoding"
              "{\"routePath\":\"/lead/triage\",\"schemaNames\":[\"LeadEscalation\",\"LeadSummary\"],\"lowType\":\"LeadSummary\",\"lowPriority\":\"low\",\"highType\":\"LeadEscalation\",\"highOwner\":\"ae-team\",\"invalid\":\"result did not match any dynamic schema candidate: LeadSummary, LeadEscalation\"}"
              runtimeOutput
    , testCase "support-agent BAML shim example requires native backend emission" $
        assertBackendEntryRequiresNative ("examples" </> "support-agent" </> "Main.clasp")
    , testCase "compile emits app-facing secret consumers for routes tools workflows and provider bindings" $
        case compileSource "secret-surface" secretSurfaceSource of
          Left err ->
            assertFailure ("expected secret surface source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected secret consumer export helper" ("export function __claspCreateSecretConsumerSurface(config = {}) {" `T.isInfixOf` emitted)
            assertBool "expected prompt input export helper" ("export function __claspCreatePromptInputSurface(config = {}) {" `T.isInfixOf` emitted)
            assertBool "expected secret delegation helper" ("delegate(secretHandleOrName, options = null) {" `T.isInfixOf` emitted)
            assertBool "expected secret handoff helper" ("handoff(consumer, options = null) {" `T.isInfixOf` emitted)
            assertBool "expected secret declaration export" ("export const __claspSecretDeclarations = __claspSecretInputs;" `T.isInfixOf` emitted)
            assertBool "expected secret injector export" ("export const __claspSecretInjectors = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected secret environment injector helper" ("fromEnvironment(environment = null, options = null) {" `T.isInfixOf` emitted)
            assertBool "expected secret provider injector helper" ("fromProvider(provider, options = null) {" `T.isInfixOf` emitted)
            assertBool "expected route secret consumer helper" ("secretConsumer(boundary) { return $claspCreateSecretConsumer({ kind: \"route\", name: this.name, id: this.id, boundary }); }" `T.isInfixOf` emitted)
            assertBool "expected workflow secret consumer helper" ("secretConsumer(boundary) { return $claspCreateSecretConsumer({ kind: \"workflow\", name: this.name, id: this.id, boundary }); }" `T.isInfixOf` emitted)
            assertBool "expected tool secret consumer helper" ("secretConsumer(boundary = this.server ?? null) { return $claspCreateSecretConsumer({ kind: \"tool\", name: this.name, id: this.id, boundary, secretNames: this.secretNames }); }" `T.isInfixOf` emitted)
            assertBool "expected tool input surface helper" ("inputSurface(value, options = null) { return $claspCreateToolInputSurface(this, value, options); }" `T.isInfixOf` emitted)
    , testCase "compile emits agent secret consumers for delegated handoffs" $
        case compileSource "delegated-secret-handoff" delegatedSecretHandoffSource of
          Left err ->
            assertFailure ("expected delegated secret handoff source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted ->
            assertBool
              "expected agent secret consumer helper"
              ("secretConsumer(boundary = this.role ?? null) { return $claspCreateSecretConsumer({ kind: \"agent\", name: this.name, id: this.id, boundary, secretNames: this.role?.policy?.permissions?.secret ?? [] }); }" `T.isInfixOf` emitted)
    , testCase "app-facing secret consumers resolve declared handles across routes tools workflows and providers" $ do
        case compileSource "secret-surface-runtime" secretSurfaceSource of
          Left err ->
            assertFailure ("expected secret surface source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/secret-surface-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            absoluteRuntimePath <- makeAbsolute "deprecated/runtime/server.mjs"
            runtimeOutput <- runNodeScript (secretSurfaceRuntimeScript absoluteCompiledPath absoluteRuntimePath)
            assertEqual
              "expected declared secret-handle runtime output"
              "{\"declarationKind\":\"clasp-secret-declaration\",\"environmentKey\":\"OPENAI_API_KEY\",\"injectorVersion\":1,\"routeSecretNames\":[\"OPENAI_API_KEY\",\"SEARCH_API_TOKEN\"],\"routeSourceKind\":\"environment\",\"routeSecretValue\":\"sk-env-openai\",\"routeSecretRedaction\":\"[secret OPENAI_API_KEY redacted: route-preview]\",\"routeSecretReadError\":\"Cannot read secret OPENAI_API_KEY from toolServer RepoTools under policy SupportSecrets; use reveal({ reason }) or redact({ reason }).\",\"routeSecretSerializeError\":\"Cannot serialize secret OPENAI_API_KEY from toolServer RepoTools under policy SupportSecrets; use reveal({ reason }) or redact({ reason }).\",\"routeSecretCoerceError\":\"Cannot coerce secret OPENAI_API_KEY from toolServer RepoTools under policy SupportSecrets; use reveal({ reason }) or redact({ reason }).\",\"routeSecretInspectError\":\"Cannot inspect or log secret OPENAI_API_KEY from toolServer RepoTools under policy SupportSecrets; use reveal({ reason }) or redact({ reason }).\",\"routeSecretLogError\":\"Cannot inspect or log secret OPENAI_API_KEY from toolServer RepoTools under policy SupportSecrets; use reveal({ reason }) or redact({ reason }).\",\"routeSecretLogged\":false,\"workflowTracePolicy\":\"SupportSecrets\",\"workflowSecretValue\":\"tok-env-1\",\"toolSecretCount\":2,\"toolHasOpenAI\":true,\"providerSecretNames\":[\"OPENAI_API_KEY\",\"SEARCH_API_TOKEN\"],\"providerSourceKind\":\"provider\",\"providerResolvedName\":\"SEARCH_API_TOKEN\",\"providerResolvedValue\":\"tok-provider-1\",\"providerRequestSecretNames\":[\"OPENAI_API_KEY\",\"SEARCH_API_TOKEN\"],\"providerRequestResolvedValue\":\"tok-provider-1\",\"providerPreview\":\"preview: tok-provider-1\"}"
              runtimeOutput
    , testCase "delegated secret handoffs pass handles across agent tool and workflow boundaries without raw values" $ do
        case compileSource "delegated-secret-handoff-runtime" delegatedSecretHandoffSource of
          Left err ->
            assertFailure ("expected delegated secret handoff source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            let compiledPath = "dist/test-projects/delegated-secret-handoff-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript (delegatedSecretHandoffRuntimeScript absoluteCompiledPath)
            assertEqual
              "expected delegated handoff runtime output"
              "{\"agentHandoffKind\":\"clasp-secret-handoff\",\"agentSecretNames\":[\"OPENAI_API_KEY\",\"SEARCH_API_TOKEN\"],\"agentDelegationTarget\":\"tool:searchRepo\",\"agentDelegated\":true,\"agentHasRawValue\":false,\"agentRawValueLeaked\":false,\"repeatDelegationIdsDistinct\":true,\"toolTraceDelegator\":\"agent:builder\",\"toolTraceConsumer\":\"tool:searchRepo\",\"toolTraceBoundary\":\"toolServer:RepoTools\",\"toolAuditDelegatedAt\":1700,\"toolAuditAttenuationAction\":\"resolve\",\"toolAuditAttenuationTtl\":300,\"toolAuditAttenuationMaxUses\":1,\"toolResolvedName\":\"OPENAI_API_KEY\",\"toolResolvedValue\":\"sk-agent-live\",\"workflowRejected\":\"workflow SearchFlow targets tool searchRepo, not workflow SearchFlow.\",\"workflowAcceptedName\":\"SEARCH_API_TOKEN\",\"workflowResolvedValue\":\"tok-workflow-live\",\"workflowTracePolicy\":\"SupportSecrets\"}"
              runtimeOutput
    , testCase "prompt-functions example requires native backend emission" $
        assertBackendEntryRequiresNative ("examples" </> "prompt-functions" </> "Main.clasp")
    , testCase "typed prompt functions compile to stable prompt values and text rendering" $ do
        case compileSource "prompt-runtime" promptFunctionSource of
          Left err ->
            assertFailure ("expected prompt runtime source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected prompt helper" ("function $claspPromptMessage(role, content)" `T.isInfixOf` emitted)
            assertBool "expected Prompt serializer" ("function $serialize_Prompt(value)" `T.isInfixOf` emitted)
            let compiledPath = "dist/test-projects/prompt-runtime/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript (promptRuntimeScript absoluteCompiledPath)
            assertEqual
              "expected prompt payload and rendered text"
              "{\"messageCount\":3,\"roles\":[\"system\",\"assistant\",\"user\"],\"content\":[\"You are a support agent.\",\"Draft a concise reply.\",\"Renewal is blocked on legal review.\"],\"text\":\"system: You are a support agent.\\n\\nassistant: Draft a concise reply.\\n\\nuser: Renewal is blocked on legal review.\"}"
              runtimeOutput
    , testCase "prompt runtime rejects authority-bearing policy and tool grant fields" $ do
        case compileSource "prompt-authority-boundary" promptAuthorityBoundarySource of
          Left err ->
            assertFailure ("expected prompt authority source to compile:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected prompt authority helper" ("function $claspAssertPromptFields(objectValue, allowedFields, path)" `T.isInfixOf` emitted)
            let compiledPath = "dist/test-projects/prompt-authority-boundary/compiled.mjs"
            createDirectoryIfMissing True (takeDirectory compiledPath)
            TIO.writeFile compiledPath emitted
            absoluteCompiledPath <- makeAbsolute compiledPath
            runtimeOutput <- runNodeScript (promptAuthorityBoundaryRuntimeScript absoluteCompiledPath)
            assertEqual
              "expected prompt authority boundary failures"
              "{\"topLevelError\":\"value.tools is authority-bearing metadata; keep prompt content separate from policy and tool grants\",\"messageError\":\"value.messages[0].policy is authority-bearing metadata; keep prompt content separate from policy and tool grants\"}"
              runtimeOutput
    , testCase "compile emits Python worker and service interop contracts" $
        case compileSource "python-interop" pythonInteropSource of
          Left err ->
            assertFailure ("expected python interop compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted -> do
            assertBool "expected python interop export" ("export const __claspPythonInterop = Object.freeze({" `T.isInfixOf` emitted)
            assertBool "expected python runtime descriptor" ("runtime: Object.freeze({ module: \"src/runtime/python.mjs\", entry: \"createPythonInteropRuntime\" })" `T.isInfixOf` emitted)
            assertBool "expected worker boundary descriptor" ("kind: \"worker\"" `T.isInfixOf` emitted)
            assertBool "expected service boundary descriptor" ("kind: \"service\"" `T.isInfixOf` emitted)
            assertBool "expected python binding contract entry" ("python: __claspPythonInterop," `T.isInfixOf` emitted)
    , testCase "python interop runtime example requires native backend emission" $
        withProjectFiles "python-interop-runtime"
          [ ("compiled-source.clasp", pythonInteropSource)
          , ("clasp_worker_bridge.py", pythonWorkerModuleSource)
          , ("clasp_service_pkg/__main__.py", pythonServicePackageSource)
          ] $ \root ->
            assertBackendEntryRequiresNative (root </> "compiled-source.clasp")
    , testCase "page route client examples require native backend emission" $
        withProjectFiles "route-client-page-runtime" pageFormRuntimeFiles $ \root ->
          assertBackendEntryRequiresNative (root </> "Main.clasp")
    , testCase "redirect route client examples require native backend emission" $
        withProjectFiles "route-client-redirect-runtime" pageRedirectRuntimeFiles $ \root ->
          assertBackendEntryRequiresNative (root </> "Main.clasp")
    , testCase "page and redirect browser client examples require native backend emission" $
        withProjectFiles "route-client-browser-runtime" pageFormRuntimeFiles $ \pageRoot -> do
          assertBackendEntryRequiresNative (pageRoot </> "Main.clasp")
          withProjectFiles "route-client-browser-redirect-runtime" pageRedirectRuntimeFiles $ \redirectRoot ->
            assertBackendEntryRequiresNative (redirectRoot </> "Main.clasp")
    , testCase "redirect runtime example requires native backend emission" $
        withProjectFiles "page-redirect-runtime" pageRedirectRuntimeFiles $ \root ->
          assertBackendEntryRequiresNative (root </> "Main.clasp")
    , testCase "lead app backend example requires native backend emission" $
        assertBackendEntryRequiresNative ("examples" </> "lead-app" </> "Main.clasp")
    , testCase "lead app generated clients require native backend emission at the module boundary" $
        assertBackendEntryRequiresNative ("examples" </> "lead-app" </> "Main.clasp")
    , testCase "lead app browser shell keeps POST results on stable GET history entries" $ do
        absoluteShellPath <- makeAbsolute ("examples" </> "lead-app" </> "app-shell.mjs")
        shellOutput <- runNodeScript (leadAppBrowserShellScript absoluteShellPath)
        assertEqual
          "expected browser shell to preserve stable GET history across create and review flows"
          "{\"history\":[\"https://app.example.test/\",\"https://app.example.test/inbox\",\"https://app.example.test/lead/primary\"],\"fetches\":[{\"method\":\"POST\",\"pathname\":\"/leads\"},{\"method\":\"GET\",\"pathname\":\"/inbox\"},{\"method\":\"GET\",\"pathname\":\"/lead/primary\"},{\"method\":\"POST\",\"pathname\":\"/review\"},{\"method\":\"GET\",\"pathname\":\"/lead/primary\"},{\"method\":\"GET\",\"pathname\":\"/inbox\"},{\"method\":\"GET\",\"pathname\":\"/lead/primary\"}],\"afterCreate\":\"https://app.example.test/\",\"afterReview\":\"https://app.example.test/lead/primary\",\"afterRefresh\":\"https://app.example.test/lead/primary\",\"afterBack\":\"https://app.example.test/inbox\",\"afterForward\":\"https://app.example.test/lead/primary\",\"title\":\"Primary lead\",\"html\":\"<main><h1>Primary lead</h1></main>\"}"
          shellOutput
    , testCase "lead app mobile demo requires native backend emission" $
        assertBackendEntryRequiresNative ("examples" </> "lead-app" </> "Main.clasp")
    , testCase "lead app workflow demo requires native backend emission" $
        assertBackendEntryRequiresNative ("examples" </> "lead-app" </> "Main.clasp")
    , testCase "lead app ai demo requires native backend emission" $
        assertBackendEntryRequiresNative ("examples" </> "lead-app" </> "Main.clasp")
    , testCase "lead app ui graph export requires native backend emission" $
        assertBackendEntryRequiresNative ("examples" </> "lead-app" </> "Main.clasp")
    , testCase "lead app seeded fixture export requires native backend emission" $
        assertBackendEntryRequiresNative ("examples" </> "lead-app" </> "Main.clasp")
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

assertBackendEntryRequiresNative :: FilePath -> Assertion
assertBackendEntryRequiresNative inputPath = do
  result <- compileEntry inputPath
  assertHasCode "E_BACKEND_TARGET_REQUIRES_NATIVE" result

expectFirstDiagnostic :: DiagnosticBundle -> IO Diagnostic
expectFirstDiagnostic (DiagnosticBundle errs) =
  case errs of
    firstErr : _ ->
      pure firstErr
    [] ->
      assertFailure "expected at least one diagnostic"

assertUnsupportedPrimaryCompilerJson :: String -> Assertion
assertUnsupportedPrimaryCompilerJson stderrText = do
  jsonValue <- case eitherDecodeStrictText (T.pack stderrText) of
    Left decodeErr ->
      assertFailure ("expected unsupported primary compiler failure json to decode:\n" <> decodeErr)
    Right value ->
      pure value
  diagnosticValue <- case lookupObjectKey "diagnostics" jsonValue of
    Just (Array diagnosticsJson) ->
      case toList diagnosticsJson of
        firstDiagnostic : _ ->
          pure firstDiagnostic
        [] ->
          assertFailure "expected at least one diagnostic for unsupported primary compiler request"
    _ ->
      assertFailure "expected diagnostics array for unsupported primary compiler request"
  assertEqual "status" (Just (String "error")) (lookupObjectKey "status" jsonValue)
  assertEqual "diagnostic code" (Just (String "E_PRIMARY_COMPILER_UNSUPPORTED")) (lookupObjectKey "code" diagnosticValue)

assertDiagnosticJsonCode :: Text -> String -> Assertion
assertDiagnosticJsonCode code stderrText = do
  jsonValue <- case eitherDecodeStrictText (T.pack stderrText) of
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
          assertFailure "expected at least one diagnostic"
    _ ->
      assertFailure "expected diagnostics array"
  assertEqual "status" (Just (String "error")) (lookupObjectKey "status" jsonValue)
  assertEqual "diagnostic code" (Just (String code)) (lookupObjectKey "code" diagnosticValue)

currentStructuredDiagnosticCodes :: IO [Text]
currentStructuredDiagnosticCodes = do
  sourceFiles <- mapM TIO.readFile ["deprecated/bootstrap/src/Clasp/Checker.hs", "deprecated/bootstrap/src/Clasp/Compiler.hs", "deprecated/bootstrap/src/Clasp/Core.hs", "deprecated/bootstrap/src/Clasp/Loader.hs", "deprecated/bootstrap/src/Clasp/Parser.hs"]
  let codes =
        Set.toAscList $
          Set.fromList
            [ quoted
            | quoted <- concatMap (T.splitOn "\"") sourceFiles
            , T.isPrefixOf "E_" quoted
            , T.all (\char -> char == '_' || ('A' <= char && char <= 'Z') || ('0' <= char && char <= '9')) quoted
            ]
  pure codes

genericDiagnosticFixHint :: Text
genericDiagnosticFixHint =
  "Review the diagnostic details and the highlighted code, then update the program to satisfy the reported constraint."

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

findNativeDecl :: Text -> [NativeDecl] -> Maybe NativeDecl
findNativeDecl target =
  find matchesName
  where
    matchesName decl =
      case decl of
        NativeGlobalDecl globalDecl ->
          nativeGlobalName globalDecl == target
        NativeFunctionDecl functionDecl ->
          nativeFunctionName functionDecl == target

findRuntimeBinding :: Text -> [NativeRuntimeBinding] -> Maybe NativeRuntimeBinding
findRuntimeBinding target =
  find ((== target) . nativeRuntimeBindingName)

findBuiltinLayout :: Text -> [NativeBuiltinLayout] -> Maybe NativeBuiltinLayout
findBuiltinLayout target =
  find ((== target) . nativeBuiltinLayoutName)

findRecordLayout :: Text -> [NativeRecordLayout] -> Maybe NativeRecordLayout
findRecordLayout target =
  find ((== target) . nativeRecordLayoutName)

findVariantLayout :: Text -> [NativeVariantLayout] -> Maybe NativeVariantLayout
findVariantLayout target =
  find ((== target) . nativeVariantLayoutName)

findObjectLayout :: Text -> [NativeObjectLayout] -> Maybe NativeObjectLayout
findObjectLayout target =
  find ((== target) . nativeObjectLayoutName)

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

hostedPackageImportRuntimeScript :: FilePath -> FilePath -> Text
hostedPackageImportRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { installCompiledModule } from " <> show ("file://" <> runtimePath) <> ";"
    , "installCompiledModule(compiledModule);"
    , "console.log(JSON.stringify({"
    , "  formatted: compiledModule.describe({ company: 'Acme Labs', budget: 7 }),"
    , "  upper: compiledModule.shout('hello ada')"
    , "}));"
    ]

promptRuntimeScript :: FilePath -> Text
promptRuntimeScript compiledPath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "console.log(JSON.stringify({"
    , "  messageCount: compiledModule.replyPromptValue.messages.length,"
    , "  roles: compiledModule.replyPromptValue.messages.map((message) => message.role),"
    , "  content: compiledModule.replyPromptValue.messages.map((message) => message.content),"
    , "  text: compiledModule.replyPromptText"
    , "}));"
    ]

promptAuthorityBoundaryRuntimeScript :: FilePath -> Text
promptAuthorityBoundaryRuntimeScript compiledPath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "let topLevelError = null;"
    , "let messageError = null;"
    , "try {"
    , "  compiledModule.renderPrompt({"
    , "    $kind: 'prompt',"
    , "    messages: [{ role: 'user', content: 'show draft' }],"
    , "    tools: ['searchRepo']"
    , "  });"
    , "} catch (error) {"
    , "  topLevelError = error.message;"
    , "}"
    , "try {"
    , "  compiledModule.renderPrompt({"
    , "    $kind: 'prompt',"
    , "    messages: [{ role: 'user', content: 'show draft', policy: 'SupportDisclosure' }]"
    , "  });"
    , "} catch (error) {"
    , "  messageError = error.message;"
    , "}"
    , "console.log(JSON.stringify({ topLevelError, messageError }));"
    ]

streamingPartialRuntimeScript :: FilePath -> Text
streamingPartialRuntimeScript compiledPath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "const tool = compiledModule.__claspTools[0];"
    , "const stream = tool.streamResult();"
    , "const parsedPartial = tool.parsePartialResponse('{\"summary\":\"Ready\",\"usage\":{\"prompt\":12}}');"
    , "const first = stream.push({ summary: 'Ready' });"
    , "const second = stream.push({ usage: { prompt: 12 } });"
    , "const third = stream.push({ usage: { completion: 7 }, done: true });"
    , "const final = stream.result();"
    , "const formattedPartial = tool.formatPartialResponse({ usage: { completion: 7 } });"
    , "let incomplete = null;"
    , "try {"
    , "  tool.streamResult({ summary: 'Ready', usage: { prompt: 12 }, done: true }).finish();"
    , "} catch (error) {"
    , "  incomplete = error.message;"
    , "}"
    , "console.log(JSON.stringify({ parsedPartial, first, second, third, final, formattedPartial, incomplete }));"
    ]

projectionSchemaRuntimeScript :: FilePath -> Text
projectionSchemaRuntimeScript compiledPath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "const schemaEntry = compiledModule.__claspSchemas['SupportCustomer'];"
    , "if (!schemaEntry) { throw new Error('missing SupportCustomer schema'); }"
    , "const field = schemaEntry.schema.fields.emails;"
    , "const projection = field.projection();"
    , "const partialProjection = field.partialProjection();"
    , "const schemaProjection = field.schema.projection(field.fieldIdentity);"
    , "const schemaPartialProjection = field.schema.partialProjection(field.fieldIdentity);"
    , "console.log(JSON.stringify({"
    , "  fieldIdentity: field.fieldIdentity,"
    , "  projectionFingerprint: projection.schemaFingerprint,"
    , "  partialFingerprint: partialProjection.schemaFingerprint,"
    , "  schemaProjectionFingerprint: schemaProjection.schemaFingerprint,"
    , "  schemaPartialProjectionFingerprint: schemaPartialProjection.schemaFingerprint,"
    , "  itemFingerprint: projection.item?.schemaFingerprint ?? null,"
    , "  partialItemFingerprint: partialProjection.item?.schemaFingerprint ?? null"
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

jsonArrayValues :: Maybe Value -> Maybe [Value]
jsonArrayValues (Just (Array items)) = Just (toList items)
jsonArrayValues _ = Nothing

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
    "claspc"
    args
    ""

runHostedNativeTool :: FilePath -> String -> Maybe String -> FilePath -> IO Text
runHostedNativeTool imagePath exportName inputArg outputPath =
  runHostedNativeToolFromDirectory Nothing imagePath exportName inputArg outputPath

runHostedNativeToolInDirectory :: FilePath -> FilePath -> String -> Maybe String -> FilePath -> IO Text
runHostedNativeToolInDirectory workingDirectory imagePath exportName inputArg outputPath =
  runHostedNativeToolFromDirectory (Just workingDirectory) imagePath exportName inputArg outputPath

runHostedNativeToolFromDirectory :: Maybe FilePath -> FilePath -> String -> Maybe String -> FilePath -> IO Text
runHostedNativeToolFromDirectory maybeWorkingDirectory imagePath exportName inputArg outputPath = do
  toolScriptPath <- makeAbsolute ("src" </> "scripts" </> "run-native-tool.sh")
  absoluteImagePath <- makeAbsolute imagePath
  absoluteOutputPath <- makeAbsolute outputPath
  absoluteWorkingDirectory <-
    case maybeWorkingDirectory of
      Just workingDirectory ->
        Just <$> makeAbsolute workingDirectory
      Nothing ->
        pure Nothing
  let args =
        [ toolScriptPath
        , absoluteImagePath
        , exportName
        ]
          <> maybe [] pure inputArg
          <> [absoluteOutputPath]
  (exitCode, _stdoutText, stderrText) <-
    readCreateProcessWithExitCode
      ((proc "bash" args) {cwd = absoluteWorkingDirectory})
      ""
  case exitCode of
    ExitSuccess ->
      T.strip <$> TIO.readFile absoluteOutputPath
    ExitFailure _ ->
      assertFailure ("hosted native tool failed:\n" <> stderrText)

lookupObjectKey :: Text -> Value -> Maybe Value
lookupObjectKey key value =
  case value of
    Object obj ->
      KeyMap.lookup (fromText key) obj
    _ ->
      Nothing

lookupObjectText :: Text -> Value -> Maybe Text
lookupObjectText key value =
  case lookupObjectKey key value of
    Just (String textValue) ->
      Just textValue
    _ ->
      Nothing

objectHasTextField :: [(Text, Text)] -> Value -> Bool
objectHasTextField expectedFields value =
  all fieldMatches expectedFields
  where
    fieldMatches (fieldName, expectedValue) =
      lookupObjectKey fieldName value == Just (String expectedValue)

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

normalizeSupervisorChildren :: [SupervisorChildDecl] -> [SupervisorChildDecl]
normalizeSupervisorChildren =
  fmap (\childDecl -> childDecl {supervisorChildSpan = dummySpan})

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

genericTypeSource :: Text
genericTypeSource =
  T.unlines
    [ "module Main"
    , ""
    , "type Choice a = Some a | None"
    , ""
    , "record Box a = {"
    , "  value : a"
    , "}"
    , ""
    , "identity : a -> a"
    , "identity value = value"
    , ""
    , "wrap : a -> Box a"
    , "wrap value = Box { value = value }"
    , ""
    , "readBox : Box a -> a"
    , "readBox box = box.value"
    , ""
    , "unwrapOr : Choice a -> a -> a"
    , "unwrapOr value fallback = match value {"
    , "  Some present -> present,"
    , "  None -> fallback"
    , "}"
    , ""
    , "main : Str"
    , "main = readBox (wrap \"ok\")"
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

ambiguousEmptyListSource :: Text
ambiguousEmptyListSource =
  T.unlines
    [ "module Main"
    , ""
    , "empty = []"
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

builtinResultSource :: Text
builtinResultSource =
  T.unlines
    [ "module Main"
    , ""
    , "unwrap : Result -> Str"
    , "unwrap result = match result {"
    , "  Ok value -> value,"
    , "  Err message -> message"
    , "}"
    , ""
    , "main : Str"
    , "main = unwrap (Ok \"done\")"
    ]

builtinOptionSource :: Text
builtinOptionSource =
  T.unlines
    [ "module Main"
    , ""
    , "unwrap : Option -> Str"
    , "unwrap value = match value {"
    , "  Some present -> present,"
    , "  None -> \"missing\""
    , "}"
    , ""
    , "main : Str"
    , "main = unwrap (Some \"present\")"
    ]

hostedNativeDecisionSource :: Text
hostedNativeDecisionSource =
  T.unlines
    [ "module Main"
    , ""
    , "type Decision = Keep Str Str | Drop"
    , ""
    , "choose : Decision -> Str"
    , "choose decision = match decision { Keep left right -> left, Drop -> \"drop\" }"
    , ""
    , "main : Str"
    , "main = choose (Keep \"alpha\" \"beta\")"
    ]

compilerStdlibSource :: Text
compilerStdlibSource =
  T.unlines
    [ "module Main"
    , ""
    , "joinedPath : Str"
    , "joinedPath = pathJoin [\"src\", \"Clasp\", \"Checker.hs\"]"
    , ""
    , "splitSummary : Str -> [Str]"
    , "splitSummary value = textSplit value \":\""
    , ""
    , "charsSummary : Str -> [Str]"
    , "charsSummary value = textChars value"
    , ""
    , "prefixSummary : Str -> Str"
    , "prefixSummary value = match textPrefix value \"src/\" {"
    , "  Ok rest -> rest,"
    , "  Err original -> original"
    , "}"
    , ""
    , "splitOnceSummary : Str -> Str"
    , "splitOnceSummary value = match textSplitFirst value \"::\" {"
    , "  Ok payload -> payload,"
    , "  Err original -> original"
    , "}"
    , ""
    , "filePresent : Str -> Bool"
    , "filePresent path = fileExists path"
    , ""
    , "loadSummary : Str -> Str"
    , "loadSummary path = match readFile path {"
    , "  Ok contents -> textJoin \"::\" [pathBasename path, contents],"
    , "  Err message -> message"
    , "}"
    , ""
    , "main : Str"
    , "main = textJoin \" :: \" [pathDirname joinedPath, pathBasename joinedPath]"
    ]

textCharsNativeSource :: Text
textCharsNativeSource =
  T.unlines
    [ "module Main"
    , ""
    , "charsSummary : Str -> [Str]"
    , "charsSummary value = textChars value"
    , ""
    , "main : [Str]"
    , "main = charsSummary \"abc\""
    ]

sqliteRuntimeSource :: Text
sqliteRuntimeSource =
  T.unlines
    [ "module Main"
    , ""
    , "describeConnection : Str -> SqliteConnection"
    , "describeConnection path = sqliteOpen path"
    , ""
    , "describeReadonlyConnection : Str -> SqliteConnection"
    , "describeReadonlyConnection path = sqliteOpenReadonly path"
    , ""
    , "main : Str"
    , "main = \"ok\""
    ]

sqliteQueryRuntimeSource :: Text
sqliteQueryRuntimeSource =
  T.unlines
    [ "module Main"
    , ""
    , "record NoteRow = {"
    , "  note : Str"
    , "}"
    , ""
    , "record NoteFilter = {"
    , "  wanted : Str"
    , "}"
    , ""
    , "record CountRow = {"
    , "  count : Int"
    , "}"
    , ""
    , "foreign fetchFirstNote : SqliteConnection -> Str -> NoteRow = \"sqlite:queryOne\""
    , "foreign fetchNoteCount : SqliteConnection -> Str -> CountRow = \"sqlite:queryOne\""
    , "foreign fetchNoteRows : SqliteConnection -> Str -> [NoteRow] = \"sqlite:queryAll\""
    , "foreign fetchNotesByValue : SqliteConnection -> Str -> NoteFilter -> [NoteRow] = \"sqlite:queryAll\""
    , ""
    , "firstNote : SqliteConnection -> Str -> NoteRow"
    , "firstNote connection sql = fetchFirstNote connection sql"
    , ""
    , "noteCount : SqliteConnection -> Str -> CountRow"
    , "noteCount connection sql = fetchNoteCount connection sql"
    , ""
    , "noteRows : SqliteConnection -> Str -> [NoteRow]"
    , "noteRows connection sql = fetchNoteRows connection sql"
    , ""
    , "notesByValue : SqliteConnection -> Str -> NoteFilter -> [NoteRow]"
    , "notesByValue connection sql filter = fetchNotesByValue connection sql filter"
    , ""
    , "main : Str"
    , "main = \"ok\""
    ]

sqliteMutationRuntimeSource :: Text
sqliteMutationRuntimeSource =
  T.unlines
    [ "module Main"
    , ""
    , "record NoteInput = {"
    , "  wanted : Str"
    , "}"
    , ""
    , "record NoteRow = {"
    , "  note : Str"
    , "}"
    , ""
    , "foreign insertNote : SqliteConnection -> Str -> NoteInput -> NoteRow = \"sqlite:mutateOne:immediate\""
    , "foreign replaceNotes : SqliteConnection -> Str -> NoteInput -> [NoteRow] = \"sqlite:mutateAll:exclusive\""
    , ""
    , "saveNote : SqliteConnection -> Str -> NoteInput -> NoteRow"
    , "saveNote connection sql input = insertNote connection sql input"
    , ""
    , "rewriteNotes : SqliteConnection -> Str -> NoteInput -> [NoteRow]"
    , "rewriteNotes connection sql input = replaceNotes connection sql input"
    , ""
    , "main : Str"
    , "main = \"ok\""
    ]

sqliteProtectedRuntimeSource :: Text
sqliteProtectedRuntimeSource =
  T.unlines
    [ "module Main"
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
    , "foreign fetchCustomers : SqliteConnection -> Str -> [SupportCustomer] = \"sqlite:queryAll\""
    , "foreign saveCustomer : SqliteConnection -> Str -> SupportCustomer -> SupportCustomer = \"sqlite:mutateOne:immediate\""
    , ""
    , "loadCustomers : SqliteConnection -> Str -> [SupportCustomer]"
    , "loadCustomers connection sql = fetchCustomers connection sql"
    , ""
    , "persistCustomer : SqliteConnection -> Str -> SupportCustomer -> SupportCustomer"
    , "persistCustomer connection sql customer = saveCustomer connection sql customer"
    , ""
    , "main : Str"
    , "main = \"ok\""
    ]

sqliteUnsafeRuntimeSource :: Text
sqliteUnsafeRuntimeSource =
  T.unlines
    [ "module Main"
    , ""
    , "record UnsafeNoteInput = {"
    , "  wanted : Str"
    , "}"
    , ""
    , "record UnsafeNoteRow = {"
    , "  note : Str"
    , "}"
    , ""
    , "foreign unsafe fetchUnsafeFirstNote : SqliteConnection -> Str -> UnsafeNoteRow = \"sqlite:unsafeQueryOne\""
    , "foreign unsafe fetchUnsafeNotes : SqliteConnection -> Str -> [UnsafeNoteRow] = \"sqlite:unsafeQueryAll\""
    , "foreign unsafe rewriteUnsafeNotes : SqliteConnection -> Str -> UnsafeNoteInput -> [UnsafeNoteRow] = \"sqlite:unsafeMutateAll:immediate\""
    , ""
    , "main : Str"
    , "main = \"ok\""
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

dynamicSchemaSource :: Text
dynamicSchemaSource =
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
    , "record LeadEscalation = {"
    , "  escalationReason : Str,"
    , "  owner : Str"
    , "}"
    , ""
    , "foreign classifyLead : LeadRequest -> Str = \"classifyLead\""
    , ""
    , "triageLead : LeadRequest -> Str"
    , "triageLead lead = classifyLead lead"
    , ""
    , "triagePage : LeadRequest -> Page"
    , "triagePage lead = page \"Lead triage\" (element \"main\" (text lead.company))"
    , ""
    , "route triageLeadRoute = POST \"/lead/triage\" LeadRequest -> Page triagePage"
    , ""
    , "main = \"ok\""
    ]

providerRuntimeSource :: Text
providerRuntimeSource =
  T.unlines
    [ "module Main"
    , ""
    , "record TicketDraft = {"
    , "  customerId : Str,"
    , "  summary : Str"
    , "}"
    , ""
    , "record TicketPreview = {"
    , "  suggestedReply : Str"
    , "}"
    , ""
    , "record SupportCustomer = {"
    , "  company : Str,"
    , "  contactEmail : Str"
    , "}"
    , ""
    , "record Empty = {}"
    , ""
    , "foreign generateReplyPreview : TicketDraft -> TicketPreview = \"provider:replyPreview\""
    , "foreign publishCustomer : SupportCustomer -> SupportCustomer = \"storage:publishCustomer\""
    , ""
    , "currentCustomer : SupportCustomer"
    , "currentCustomer = SupportCustomer {"
    , "  company = \"Northwind Studio\","
    , "  contactEmail = \"ops@northwind.example\""
    , "}"
    , ""
    , "previewText : TicketDraft -> Str"
    , "previewText draft = (generateReplyPreview draft).suggestedReply"
    , ""
    , "previewPage : TicketDraft -> Page"
    , "previewPage draft = page \"Reply preview\" (element \"main\" (element \"p\" (text (previewText draft))))"
    , ""
    , "customerPage : Empty -> Page"
    , "customerPage req = page \"Customer export\" (element \"main\" (append (element \"p\" (text currentCustomer.company)) (element \"p\" (text (publishCustomer currentCustomer).contactEmail))))"
    , ""
    , "route previewRoute = POST \"/preview\" TicketDraft -> Page previewPage"
    , "route customerRoute = GET \"/customer\" Empty -> Page customerPage"
    ]

secretSurfaceSource :: Text
secretSurfaceSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Empty = {}"
    , "record SearchRequest = { query : Str }"
    , "record SearchResponse = { summary : Str }"
    , "record SearchState = { summary : Str }"
    , ""
    , "workflow SearchFlow = { state : SearchState }"
    , ""
    , "policy SupportSecrets = public permits {"
    , "  secret \"OPENAI_API_KEY\","
    , "  secret \"SEARCH_API_TOKEN\""
    , "}"
    , ""
    , "toolserver RepoTools = \"mcp\" \"stdio://repo-tools\" with SupportSecrets"
    , ""
    , "tool searchRepo = RepoTools \"search_repo\" SearchRequest -> SearchResponse"
    , ""
    , "foreign generateReplyPreview : SearchRequest -> SearchResponse = \"provider:replyPreview\""
    , ""
    , "providerPreview : SearchRequest -> SearchResponse"
    , "providerPreview req = generateReplyPreview req"
    , ""
    , "preview : Empty -> SearchResponse"
    , "preview req = SearchResponse { summary = \"ready\" }"
    , ""
    , "route previewRoute = GET \"/preview\" Empty -> SearchResponse preview"
    , ""
    , "main = \"ok\""
    ]

delegatedSecretHandoffSource :: Text
delegatedSecretHandoffSource =
  T.unlines
    [ "module Main"
    , ""
    , "record SearchRequest = { query : Str }"
    , "record SearchResponse = { summary : Str }"
    , "record SearchState = { summary : Str }"
    , ""
    , "workflow SearchFlow = { state : SearchState }"
    , ""
    , "guide Worker = {"
    , "  scope: \"Handle repo work.\""
    , "}"
    , ""
    , "policy SupportSecrets = public permits {"
    , "  secret \"OPENAI_API_KEY\","
    , "  secret \"SEARCH_API_TOKEN\""
    , "}"
    , ""
    , "role WorkerRole = guide: Worker, policy: SupportSecrets"
    , ""
    , "agent builder = WorkerRole"
    , ""
    , "toolserver RepoTools = \"mcp\" \"stdio://repo-tools\" with SupportSecrets"
    , ""
    , "tool searchRepo = RepoTools \"search_repo\" SearchRequest -> SearchResponse"
    , ""
    , "main = \"ok\""
    ]

promptFunctionSource :: Text
promptFunctionSource =
  T.unlines
    [ "module Main"
    , ""
    , "record TicketDraft = {"
    , "  customerId : Str,"
    , "  summary : Str"
    , "}"
    , ""
    , "sampleDraft : TicketDraft"
    , "sampleDraft = TicketDraft {"
    , "  customerId = \"cust-42\","
    , "  summary = \"Renewal is blocked on legal review.\""
    , "}"
    , ""
    , "replyPrompt : TicketDraft -> Prompt"
    , "replyPrompt draft = appendPrompt (appendPrompt (systemPrompt \"You are a support agent.\") (assistantPrompt \"Draft a concise reply.\")) (userPrompt draft.summary)"
    , ""
    , "replyPromptValue : Prompt"
    , "replyPromptValue = replyPrompt sampleDraft"
    , ""
    , "replyPromptText : Str"
    , "replyPromptText = promptText replyPromptValue"
    , ""
    , "main : Str"
    , "main = replyPromptText"
    ]

promptAuthorityBoundarySource :: Text
promptAuthorityBoundarySource =
  T.unlines
    [ "module Main"
    , ""
    , "renderPrompt : Prompt -> Str"
    , "renderPrompt prompt = promptText prompt"
    , ""
    , "main : Str"
    , "main = \"ok\""
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

packageUnsafeForeignSource :: Text
packageUnsafeForeignSource =
  T.unlines
    [ "module Main"
    , ""
    , "record LeadRequest = {"
    , "  company : Str,"
    , "  budget : Int"
    , "}"
    , ""
    , "foreign unsafe formatLead : LeadRequest -> Str = \"formatLead\" from typescript \"./support/formatLead.mjs\" declaration \"./support/formatLead.d.ts\""
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

workflowConstraintSource :: Text
workflowConstraintSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Counter = { count : Int }"
    , ""
    , "nonNegative : Counter -> Bool"
    , "nonNegative counter = counter.count >= 0"
    , ""
    , "belowLimit : Counter -> Bool"
    , "belowLimit counter = counter.count < 5"
    , ""
    , "withinLimit : Counter -> Bool"
    , "withinLimit counter = counter.count <= 5"
    , ""
    , "workflow CounterFlow = {"
    , "  state : Counter,"
    , "  invariant : nonNegative,"
    , "  precondition : belowLimit,"
    , "  postcondition : withinLimit"
    , "}"
    , ""
    , "main = \"ok\""
    ]

domainModelSource :: Text
domainModelSource =
  T.unlines
    [ "module Main"
    , ""
    , "record CustomerRecord = { customerId : Str, tier : Str }"
    , "record CustomerChurnEvent = { customerId : Str, reason : Str }"
    , "record CustomerEscalationFeedback = { customerId : Str, severity : Str }"
    , "record CustomerRetentionFeedback = { customerId : Str, summary : Str }"
    , "record CustomerMetric = { customerId : Str, churnRate : Int }"
    , ""
    , "domain object Customer = CustomerRecord"
    , "domain event CustomerChurned = CustomerChurnEvent for Customer"
    , "feedback operational CustomerEscalation = CustomerEscalationFeedback for Customer"
    , "feedback business CustomerRetentionSignal = CustomerRetentionFeedback for Customer"
    , "metric CustomerChurnRate = CustomerMetric for Customer"
    , "goal RetainCustomers = CustomerChurnRate"
    , "experiment RetentionPromptTrial = RetainCustomers"
    , "rollout RetentionPromptCanary = RetentionPromptTrial"
    , ""
    , "main = \"ok\""
    ]

simulationSource :: Text
simulationSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Counter = { count : Int }"
    , "record LeadRequest = { company : Str, budget : Int }"
    , "record LeadSummary = { summary : Str, followUpRequired : Bool }"
    , ""
    , "workflow CounterFlow = { state : Counter }"
    , ""
    , "summarizeLead : LeadRequest -> LeadSummary"
    , "summarizeLead lead = LeadSummary { summary = lead.company, followUpRequired = lead.budget >= 40 }"
    , ""
    , "guide Repo = {"
    , "  verification: \"Run bash scripts/verify-all.sh before finishing.\""
    , "}"
    , ""
    , "policy SupportDisclosure = public permits {"
    , "  file \"/workspace\","
    , "  process \"rg\","
    , "  process \"bash\""
    , "}"
    , ""
    , "role WorkerRole = guide: Repo, policy: SupportDisclosure, approval: on_request, sandbox: workspace_write"
    , ""
    , "agent builder = WorkerRole"
    , ""
    , "route summarizeLeadRoute = POST \"/lead/summary\" LeadRequest -> LeadSummary summarizeLead"
    , ""
    , "main = \"ok\""
    ]

stateDir :: FilePath
stateDir = "dist/test-projects/durable-workflow/state"

supervisorSource :: Text
supervisorSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Counter = { count : Int }"
    , "record WorkerState = { active : Bool }"
    , ""
    , "workflow CounterFlow = { state : Counter }"
    , "workflow WorkerFlow = { state : WorkerState }"
    , ""
    , "supervisor RootSupervisor = one_for_all {"
    , "  workflow CounterFlow,"
    , "  supervisor WorkerSupervisor"
    , "}"
    , ""
    , "supervisor WorkerSupervisor = rest_for_one {"
    , "  workflow WorkerFlow"
    , "}"
    , ""
    , "main = \"ok\""
    ]

workflowHotSwapTargetSource :: Text
workflowHotSwapTargetSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Counter = { count : Int }"
    , ""
    , "workflow CounterFlow = { state : Counter }"
    , ""
    , "versionMarker = \"v2\""
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
    [ "module Main with Shared.User"
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
    , "record LeadFeedback={company:Str, summary:Str}"
    , "record LeadMetric={workerId:Str, conversionRate:Int}"
    , "domain object WorkerProfile=Worker"
    , "domain event LeadRequested=LeadRequest for WorkerProfile"
    , "feedback business LeadQualitySignal=LeadFeedback for WorkerProfile"
    , "metric LeadConversionRate=LeadMetric for WorkerProfile"
    , "goal ImproveLeadConversion=LeadConversionRate"
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

formatterCurrentSurfaceSource :: Text
formatterCurrentSurfaceSource =
  T.unlines
    [ "foreign unsafe formatLead : LeadRequest -> Str = \"formatLead\" from typescript \"./support/formatLead.mjs\" declaration \"./support/formatLead.d.ts\""
    , "role WorkerRole = guide: Repo, policy: SupportDisclosure, sandbox: workspace_write, approval: on_request"
    , "agent builder = WorkerRole"
    , "main = formatLead defaultLead"
    ]

formatterCurrentSurfaceExpected :: Text
formatterCurrentSurfaceExpected =
  T.intercalate
    "\n"
    [ "module Main"
    , ""
    , "role WorkerRole = guide: Repo, policy: SupportDisclosure, approval: on_request, sandbox: workspace_write"
    , ""
    , "agent builder = WorkerRole"
    , ""
    , "foreign unsafe formatLead : LeadRequest -> Str = \"formatLead\" from typescript \"./support/formatLead.mjs\" declaration \"./support/formatLead.d.ts\""
    , ""
    , "main = formatLead defaultLead"
    ]

formatterCliSource :: Text
formatterCliSource =
  T.unlines
    [ "module Main"
    , ""
    , "import Shared.User"
    , ""
    , "main=let message = \"Ada\" in message"
    , ""
    , "record User={name:Str, aliases:[Str]}"
    , "type Status=Busy Str|Idle"
    ]

formatterCliExpected :: Text
formatterCliExpected = formatterCanonicalizationExpected

unknownGoalMetricSource :: Text
unknownGoalMetricSource =
  T.unlines
    [ "module Main"
    , ""
    , "record CustomerRecord = { customerId : Str }"
    , ""
    , "domain object Customer = CustomerRecord"
    , "goal RetainCustomers = MissingMetric"
    , ""
    , "main = \"ok\""
    ]

unknownFeedbackObjectSource :: Text
unknownFeedbackObjectSource =
  T.unlines
    [ "module Main"
    , ""
    , "record CustomerFeedback = { customerId : Str }"
    , ""
    , "feedback operational CustomerEscalation = CustomerFeedback for MissingCustomer"
    , ""
    , "main = \"ok\""
    ]

unknownExperimentGoalSource :: Text
unknownExperimentGoalSource =
  T.unlines
    [ "module Main"
    , ""
    , "experiment RetentionPromptTrial = MissingGoal"
    , ""
    , "main = \"ok\""
    ]

unknownRolloutExperimentSource :: Text
unknownRolloutExperimentSource =
  T.unlines
    [ "module Main"
    , ""
    , "rollout RetentionPromptCanary = MissingExperiment"
    , ""
    , "main = \"ok\""
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

nativeBoundarySource :: Text
nativeBoundarySource =
  T.unlines
    [ "module Main"
    , ""
    , "record WorkerBoot = { workerId : Str }"
    , "record HookAck = { accepted : Bool }"
    , "record SearchRequest = { query : Str }"
    , "record SearchResponse = { summary : Str }"
    , "record Counter = { count : Int }"
    , "record LeadRequest = { company : Str, budget : Int }"
    , "record LeadSummary = { summary : Str }"
    , ""
    , "bootstrapWorker : WorkerBoot -> HookAck"
    , "bootstrapWorker req = HookAck { accepted = true }"
    , ""
    , "summarizeLead : LeadRequest -> LeadSummary"
    , "summarizeLead lead = LeadSummary { summary = lead.company }"
    , ""
    , "policy SupportDisclosure = public"
    , ""
    , "hook workerStart = \"worker.start\" WorkerBoot -> HookAck bootstrapWorker"
    , "toolserver RepoTools = \"mcp\" \"stdio://repo-tools\" with SupportDisclosure"
    , "tool searchRepo = RepoTools \"search_repo\" SearchRequest -> SearchResponse"
    , "workflow CounterFlow = { state : Counter }"
    , "route summarizeLeadRoute = POST \"/lead/summary\" LeadRequest -> LeadSummary summarizeLead"
    , ""
    , "main = \"ok\""
    ]

streamingToolSource :: Text
streamingToolSource =
  T.unlines
    [ "module Main"
    , ""
    , "record SearchRequest = { query : Str }"
    , "record TokenUsage = { prompt : Int, completion : Int }"
    , "record StreamReply = { summary : Str, usage : TokenUsage, done : Bool }"
    , ""
    , "policy SupportDisclosure = public permits {"
    , "  network \"api.openai.com\""
    , "}"
    , ""
    , "toolserver RepoTools = \"mcp\" \"stdio://repo-tools\" with SupportDisclosure"
    , ""
    , "tool streamReply = RepoTools \"stream_reply\" SearchRequest -> StreamReply"
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

badWorkflowConstraintSource :: Text
badWorkflowConstraintSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Counter = { count : Int }"
    , ""
    , "badInvariant : Counter -> Int"
    , "badInvariant counter = counter.count"
    , ""
    , "workflow CounterFlow = { state : Counter, invariant : badInvariant }"
    , ""
    , "main = \"ok\""
    ]

duplicateSupervisorParentSource :: Text
duplicateSupervisorParentSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Counter = { count : Int }"
    , ""
    , "workflow CounterFlow = { state : Counter }"
    , ""
    , "supervisor RootSupervisor = one_for_one {"
    , "  workflow CounterFlow"
    , "}"
    , ""
    , "supervisor BackupSupervisor = one_for_one {"
    , "  workflow CounterFlow"
    , "}"
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

classifiedProjectionListSource :: Text
classifiedProjectionListSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Customer = {"
    , "  id : Str,"
    , "  emails : [Str] classified pii,"
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
    , "projection SupportCustomer = Customer with SupportDisclosure { id, emails, tier }"
    , ""
    , "currentCustomer : SupportCustomer"
    , "currentCustomer = SupportCustomer {"
    , "  id = \"cust-1\","
    , "  emails = [\"ada@example.com\", \"ops@example.com\"],"
    , "  tier = \"gold\""
    , "}"
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

nativeAbiSource :: Text
nativeAbiSource =
  T.unlines
    [ "module Main"
    , ""
    , "record LeadEnvelope = {"
    , "  title : Str,"
    , "  tags : [Str],"
    , "  owner : Principal"
    , "}"
    , ""
    , "type RenderResult = RenderedPage Page | RenderedPrompt Prompt | RenderedList [Str] | RenderedOwner Principal | RenderedFlag Bool | RenderIdle"
    , ""
    , "main = \"ok\""
    ]

nativeAbiScenarioSource :: Text
nativeAbiScenarioSource =
  T.unlines
    [ "module Main"
    , ""
    , "record Empty = {}"
    , "record InboxModel = {"
    , "  title : Str,"
    , "  messages : [Str],"
    , "  unread : Bool"
    , "}"
    , ""
    , "type UiSurface = Landing Page | Detail View | Draft Prompt | Next Redirect"
    , ""
    , "defaultModel : InboxModel"
    , "defaultModel = InboxModel {"
    , "  title = \"Inbox\","
    , "  messages = [\"Ada\", \"Grace\"],"
    , "  unread = true"
    , "}"
    , ""
    , "home : Empty -> Page"
    , "home req = page defaultModel.title (text \"Mailbox\")"
    , ""
    , "route homeRoute = GET \"/\" Empty -> Page home"
    ]

nativeSameShapeRecordSource :: Text
nativeSameShapeRecordSource =
  T.unlines
    [ "module Main"
    , ""
    , "record User = {"
    , "  name : Str,"
    , "  active : Bool"
    , "}"
    , ""
    , "record Team = {"
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
    , "defaultTeam : Team"
    , "defaultTeam = Team {"
    , "  name = \"Compiler\","
    , "  active = false"
    , "}"
    , ""
    , "userName : User -> Str"
    , "userName user = user.name"
    , ""
    , "teamName : Team -> Str"
    , "teamName team = team.name"
    , ""
    , "main = userName defaultUser"
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
    , "defaultSession : AuthSession"
    , "defaultSession = authSession \"sess-1\" (principal \"user-1\") (tenant \"tenant-1\") (resourceIdentity \"lead\" \"lead-1\")"
    , ""
    , "defaultAudit : StandardAuditEnvelope"
    , "defaultAudit = auditEnvelope (auditActor \"principal\" \"user-1\") defaultSession.resource (auditAction \"read\" \"Opened lead record\") 1710000000 (auditProvenance \"worker-runtime\" defaultSession.sessionId \"trace-7\")"
    , ""
    , "sessionTenantId : AuthSession -> Str"
    , "sessionTenantId session = session.tenant.id"
    , ""
    , "encodeAudit : StandardAuditEnvelope -> Str"
    , "encodeAudit audit = encode audit"
    , ""
    , "decodeAudit : Str -> StandardAuditEnvelope"
    , "decodeAudit raw = decode StandardAuditEnvelope raw"
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

multilineListLiteralSource :: Text
multilineListLiteralSource =
  T.unlines
    [ "module Main"
    , ""
    , "roster : [Str]"
    , "roster = ["
    , "  \"Ada\","
    , "  \"Grace\""
    , "]"
    , ""
    , "emptyRoster : [Str]"
    , "emptyRoster = ["
    , "]"
    ]

trailingCommaStructuredSource :: Text
trailingCommaStructuredSource =
  T.unlines
    [ "module Main"
    , ""
    , "record User = {"
    , "  name : Str,"
    , "  active : Bool,"
    , "}"
    , ""
    , "defaultUsers : [User]"
    , "defaultUsers = ["
    , "  User {"
    , "    name = \"Ada\","
    , "    active = true,"
    , "  },"
    , "]"
    , ""
    , "main : [User]"
    , "main = defaultUsers"
    ]

nestedEmptyListSource :: Text
nestedEmptyListSource =
  T.unlines
    [ "module Main"
    , ""
    , "matrix : [[Int]]"
    , "matrix = [[], [1, 2]]"
    ]

listAppendSource :: Text
listAppendSource =
  T.unlines
    [ "module Main"
    , ""
    , "leading : [Str]"
    , "leading = [\"Ada\"]"
    , ""
    , "trailing : [Str]"
    , "trailing = [\"Grace\", \"Linus\"]"
    , ""
    , "main : [Str]"
    , "main = append leading trailing"
    ]

ifExpressionSource :: Text
ifExpressionSource =
  T.unlines
    [ "module Main"
    , ""
    , "isReady : Bool"
    , "isReady = true"
    , ""
    , "main : Str"
    , "main = if isReady then \"ready\" else \"waiting\""
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

stringLoopIterationSource :: Text
stringLoopIterationSource =
  T.unlines
    [ "module Main"
    , ""
    , "pickLastChar : Str -> Str"
    , "pickLastChar name = {"
    , "  let mut current = \"\";"
    , "  for char in name {"
    , "    current = char;"
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

loopEarlyReturnSource :: Text
loopEarlyReturnSource =
  T.unlines
    [ "module Main"
    , ""
    , "type Decision = Stop | Keep Str"
    , ""
    , "pickUntilStop : [Decision] -> Str"
    , "pickUntilStop decisions = {"
    , "  let mut winner = \"none\";"
    , "  for decision in decisions {"
    , "    match decision {"
    , "      Stop -> return \"stopped\","
    , "      Keep name -> {"
    , "        winner = name;"
    , "        winner"
    , "      }"
    , "    }"
    , "  };"
    , "  winner"
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
    , "  for count in 3 {"
    , "    count"
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

badStoragePrimitiveSource :: Text
badStoragePrimitiveSource =
  T.unlines
    [ "module Main"
    , ""
    , "foreign loadCustomer : Str -> Str = \"storage:loadCustomer\""
    , ""
    , "main : Str -> Str"
    , "main value = loadCustomer value"
    ]

badSqliteQueryPrimitiveSource :: Text
badSqliteQueryPrimitiveSource =
  T.unlines
    [ "module Main"
    , ""
    , "foreign fetchCount : SqliteConnection -> Str -> Int = \"sqlite:queryOne\""
    , ""
    , "main : Str"
    , "main = \"ok\""
    ]

badSqliteMutationPrimitiveSource :: Text
badSqliteMutationPrimitiveSource =
  T.unlines
    [ "module Main"
    , ""
    , "record NoteRow = {"
    , "  note : Str"
    , "}"
    , ""
    , "foreign saveCount : SqliteConnection -> Str -> Int -> NoteRow = \"sqlite:mutateOne\""
    , ""
    , "main : Str"
    , "main = \"ok\""
    ]

badSqliteUnsafeMissingExplicitSource :: Text
badSqliteUnsafeMissingExplicitSource =
  T.unlines
    [ "module Main"
    , ""
    , "record NoteRow = {"
    , "  note : Str"
    , "}"
    , ""
    , "foreign fetchUnsafeNote : SqliteConnection -> Str -> NoteRow = \"sqlite:unsafeQueryOne\""
    , ""
    , "main : Str"
    , "main = \"ok\""
    ]

badSqliteUnsafeRowContractSource :: Text
badSqliteUnsafeRowContractSource =
  T.unlines
    [ "module Main"
    , ""
    , "foreign unsafe fetchUnsafeCount : SqliteConnection -> Str -> Int = \"sqlite:unsafeQueryOne\""
    , ""
    , "main : Str"
    , "main = \"ok\""
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

compactHeaderImportSuccessFiles :: [(FilePath, Text)]
compactHeaderImportSuccessFiles =
  [ ("Main.clasp", compactHeaderImportSuccessMainSource)
  , ("Shared/User.clasp", headerlessSharedUserSource)
  ]

shadowedImportFiles :: [(FilePath, Text)]
shadowedImportFiles =
  [ ("Main.clasp", shadowedImportMainSource)
  , ("Shared/Support.clasp", shadowedImportSupportSource)
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

packageImportUnsafeLeafFiles :: [(FilePath, Text)]
packageImportUnsafeLeafFiles =
  [ ("Main.clasp", packageImportUnsafeLeafMainSource)
  , ("support/formatLead.mjs", packageImportTsModuleSource)
  , ("support/formatLead.d.ts", packageImportUnsafeLeafTsDeclarationSource)
  ]

packageImportUnsafeStructuralMismatchFiles :: [(FilePath, Text)]
packageImportUnsafeStructuralMismatchFiles =
  [ ("Main.clasp", packageImportUnsafeLeafMainSource)
  , ("support/formatLead.mjs", packageImportTsModuleSource)
  , ("support/formatLead.d.ts", packageImportUnsafeStructuralMismatchTsDeclarationSource)
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

compactHeaderMainSource :: Text
compactHeaderMainSource =
  T.unlines
    [ "module Main with Shared.User, Shared.Team"
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

compactHeaderImportSuccessMainSource :: Text
compactHeaderImportSuccessMainSource =
  T.unlines
    [ "module Main with Shared.User"
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

packageImportUnsafeLeafMainSource :: Text
packageImportUnsafeLeafMainSource =
  T.unlines
    [ "module Main"
    , ""
    , "record LeadRequest = {"
    , "  company : Str,"
    , "  budget : Int"
    , "}"
    , ""
    , "foreign unsafe formatLead : LeadRequest -> Str = \"formatLead\" from typescript \"./support/formatLead.mjs\" declaration \"./support/formatLead.d.ts\""
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

packageImportUnsafeLeafTsDeclarationSource :: Text
packageImportUnsafeLeafTsDeclarationSource =
  T.unlines
    [ "export declare function formatLead(request: { company: string; budget: any }): string;"
    ]

packageImportUnsafeStructuralMismatchTsDeclarationSource :: Text
packageImportUnsafeStructuralMismatchTsDeclarationSource =
  T.unlines
    [ "export declare function formatLead(request: Array<{ company: string; budget: any }>): string;"
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

boundaryBinaryRuntimeScript :: FilePath -> Text
boundaryBinaryRuntimeScript compiledPath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "const leadSchema = compiledModule.__claspSchemas.LeadRequest;"
    , "const schemaFrame = leadSchema.encodeFramedBinary({ company: 'Acme', budget: 42 });"
    , "const schemaRoundTrip = leadSchema.decodeFramedBinary(schemaFrame);"
    , "const service = compiledModule.__claspBoundaryTransports.services[0];"
    , "const serviceRequest = service.decodeRequestFrame(service.encodeRequestFrame({ company: 'Acme', budget: 42 }));"
    , "const serviceResponse = service.decodeResponseFrame(service.encodeResponseFrame({ summary: 'Queued' }));"
    , "const worker = compiledModule.__claspBoundaryTransports.workers.find((entry) => entry.kind === 'worker');"
    , "const workerResponse = worker.decodeResponseFrame(worker.encodeResponseFrame({ accepted: true }));"
    , "const tool = compiledModule.__claspBoundaryTransports.tools[0];"
    , "const toolRequest = tool.decodeRequestFrame(tool.encodeRequestFrame({ query: 'rg worker runtime' }));"
    , "const workflow = compiledModule.__claspBoundaryTransports.workers.find((entry) => entry.kind === 'workflow');"
    , "const workflowState = workflow.decodeCheckpointFrame(workflow.encodeCheckpointFrame({ count: 9 }));"
    , "console.log(JSON.stringify({"
    , "  schemaFingerprint: leadSchema.binary.schemaFingerprint,"
    , "  schemaRoundTripCompany: schemaRoundTrip.company,"
    , "  serviceMode: service.mode,"
    , "  serviceRequestBudget: serviceRequest.budget,"
    , "  serviceResponseSummary: serviceResponse.summary,"
    , "  workerEvent: worker.event,"
    , "  workerAck: workerResponse.accepted,"
    , "  toolMode: tool.mode,"
    , "  toolQuery: toolRequest.query,"
    , "  workflowMode: workflow.mode,"
    , "  workflowCount: workflowState.count,"
    , "  bindingsTransportVersion: compiledModule.__claspBindings.boundaryTransports.version"
    , "}));"
    ]

agentBinaryRuntimeScript :: FilePath -> Text
agentBinaryRuntimeScript compiledPath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "const agent = compiledModule.__claspBoundaryTransports.agentChannels[0];"
    , "const channel = agent.channel('SearchRequest', 'agent:reviewer');"
    , "const message = channel.decodeMessageFrame(channel.encodeMessageFrame({ query: 'needs review' }));"
    , "console.log(JSON.stringify({"
    , "  agentName: agent.name,"
    , "  agentId: agent.id,"
    , "  peer: channel.peer,"
    , "  messageType: channel.messageType,"
    , "  query: message.query,"
    , "  framing: channel.framing"
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
    , "const styleEntry = compiledModule.__claspStyleIR.styles[0] ?? null;"
    , "const assetResponse = bundle ? await responseForAssetRequest(compiledModule, bundle.href) : null;"
    , "const assetBody = assetResponse ? await assetResponse.text() : '';"
    , "console.log(JSON.stringify({"
    , "  assetBasePath: compiledModule.__claspStaticAssetStrategy.assetBasePath,"
    , "  generatedAssetBasePath: compiledModule.__claspStaticAssetStrategy.generatedAssetBasePath,"
    , "  headTitle: head.title,"
    , "  headViewport: head.meta.find((entry) => entry.name === 'viewport')?.content ?? null,"
    , "  headStylesheet: head.links[0]?.href ?? null,"
    , "  styleIrKind: compiledModule.__claspStyleIR.kind,"
    , "  styleRef: styleEntry?.ref ?? null,"
    , "  styleToken: styleEntry?.tokens?.[0] ?? null,"
    , "  styleVariant: styleEntry ? `${styleEntry.variants?.[0]?.axis ?? ''}:${styleEntry.variants?.[0]?.value ?? ''}` : null,"
    , "  styleEscape: styleEntry?.hostEscapes?.rawStyle ?? null,"
    , "  bindingHasStyleIR: compiledModule.__claspBindings.styleIR === compiledModule.__claspStyleIR,"
    , "  bundleId: bundle?.id ?? null,"
    , "  bundleHref: bundle?.href ?? null,"
    , "  bundleRefs: bundle?.refs ?? [],"
    , "  assetContentType: assetResponse?.headers.get('content-type') ?? null,"
    , "  assetHasRefComment: assetBody.includes('inbox_shell'),"
    , "  assetHasCssToken: assetBody.includes('--clasp-color-background-surface')"
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
    , "  stylePadding: pageModel.body.style?.lowered?.padding ?? null,"
    , "  styleVariantCount: pageModel.body.style?.variants?.length ?? 0,"
    , "  styleEscape: pageModel.body.style?.hostEscapes?.rawStyle ?? null,"
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

dynamicSchemaWorkerRuntimeScript :: FilePath -> FilePath -> Text
dynamicSchemaWorkerRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createWorkerRuntime } from " <> show ("file://" <> runtimePath) <> ";"
    , "const runtime = createWorkerRuntime(compiledModule);"
    , "const outputSchema = runtime.dynamicSchema(['LeadSummary', 'LeadEscalation']);"
    , "const job = runtime.registerJob({"
    , "  name: 'triageLeadJob',"
    , "  inputType: 'LeadRequest',"
    , "  outputType: outputSchema,"
    , "  async handler(payload) {"
    , "    if (payload.budget >= 50000) {"
    , "      return { escalationReason: 'enterprise-budget', owner: 'ae-team' };"
    , "    }"
    , "    return {"
    , "      summary: `${payload.company}:${payload.budget}`,"
    , "      priority: payload.priorityHint,"
    , "      followUpRequired: false"
    , "    };"
    , "  }"
    , "});"
    , "const low = job.decodeOutput(await runtime.dispatch('triageLeadJob', JSON.stringify({"
    , "  company: 'Acme',"
    , "  budget: 25,"
    , "  priorityHint: 'low'"
    , "})));"
    , "const high = job.decodeOutput(await runtime.dispatch('triageLeadJob', JSON.stringify({"
    , "  company: 'SynthSpeak',"
    , "  budget: 90000,"
    , "  priorityHint: 'high'"
    , "})));"
    , "let invalid = null;"
    , "try {"
    , "  job.encodeOutput({ summary: 42 });"
    , "} catch (error) {"
    , "  invalid = error instanceof Error ? error.message : String(error);"
    , "}"
    , "console.log(JSON.stringify({"
    , "  schemaNames: Object.keys(outputSchema.schemas).sort(),"
    , "  jobOutputTypes: job.outputTypes,"
    , "  lowPriority: low.priority,"
    , "  lowFollowUpRequired: low.followUpRequired,"
    , "  highOwner: high.owner,"
    , "  highReason: high.escalationReason,"
    , "  invalid"
    , "}));"
    ]

simulationRuntimeScript :: FilePath -> FilePath -> Text
simulationRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createWorkerRuntime } from " <> show ("file://" <> runtimePath) <> ";"
    , "const runtime = createWorkerRuntime(compiledModule);"
    , "const simulation = runtime.simulation({"
    , "  traceId: 'sim-1',"
    , "  now: 1000,"
    , "  storage: { leads: { open: ['lead-1'] } },"
    , "  environment: { region: 'local', apiBaseUrl: 'https://api.example.test' },"
    , "  deployment: { deploymentId: 'deploy-42', stage: 'staging' },"
    , "  providerResponses: { provider: { replyPreview: { summary: 'cached-preview' } } }"
    , "});"
    , "const baseWorld = simulation.worldSnapshot();"
    , "const routeDryRun = simulation.route('summarizeLeadRoute').dryRun();"
    , "const policyDecision = simulation.policy('SupportDisclosure').decide('process', 'rg', { actor: { id: 'builder-7' } });"
    , "const temporalClock = simulation.temporal.clock(1000);"
    , "temporalClock.advanceBy(125);"
    , "const temporalTtl = simulation.temporal.ttl('CounterFlow', { issuedAt: 1000, ttlMs: 300 }, { clock: temporalClock });"
    , "const workflowDryRun = simulation.workflow('CounterFlow').dryRun({"
    , "  state: { count: 5 },"
    , "  messages: [{ id: 'm1', payload: 2 }, { id: 'm2', payload: 3 }]"
    , "}, (state, payload) => ({"
    , "  state: { count: state.count + payload },"
    , "  result: payload"
    , "}), { clock: temporalClock });"
    , "const agentDryRun = simulation.agent('builder').dryRun({"
    , "  steps: ["
    , "    {"
    , "      step: 'inspect',"
    , "      kind: 'process',"
    , "      target: 'rg',"
    , "      request: { query: 'rg --files src test' },"
    , "      result: { summary: 'deprecated/bootstrap/src/Clasp/Compiler.hs' }"
    , "    },"
    , "    {"
    , "      step: 'verify',"
    , "      kind: 'process',"
    , "      target: 'bash',"
    , "      request: { query: 'bash scripts/verify-all.sh' },"
    , "      result: { summary: 'verification:ok' }"
    , "    }"
    , "  ]"
    , "}, { now: temporalClock.now() });"
    , "console.log(JSON.stringify({"
    , "  contractRoutes: runtime.contract.routes.length,"
    , "  fixtureRoute: runtime.contract.seededFixtures[0]?.routeName ?? null,"
    , "  controlPlaneAgents: runtime.contract.controlPlane?.agents.length ?? 0,"
    , "  worldKind: baseWorld.kind,"
    , "  worldHasModuleVersion: typeof baseWorld.module?.versionId === 'string' && baseWorld.module.versionId.length > 0,"
    , "  worldFixtureCount: Object.keys(baseWorld.fixtures).length,"
    , "  worldStorageOpenCount: baseWorld.storage.leads.open.length,"
    , "  worldEnvironmentRegion: baseWorld.environment.region,"
    , "  worldDeploymentStage: baseWorld.deployment.stage,"
    , "  worldProviderSummary: baseWorld.providerResponses.provider.replyPreview.summary,"
    , "  worldTimeNow: baseWorld.time.now,"
    , "  routeStatus: routeDryRun.status,"
    , "  routeSummary: routeDryRun.response.summary,"
    , "  routeRequestCompany: routeDryRun.request.company,"
    , "  routeWorldFixtureRoute: routeDryRun.worldSnapshot.fixtures.summarizeLeadRoute.routeName,"
    , "  policyAllowed: policyDecision.allowed,"
    , "  policyTraceActor: policyDecision.trace.context.actor.id,"
    , "  policyWorldTarget: policyDecision.worldSnapshot.surface.target,"
    , "  temporalExpired: temporalTtl.expired,"
    , "  temporalRemaining: temporalTtl.remainingMs,"
    , "  temporalWorldOperation: temporalTtl.worldSnapshot.surface.operation,"
    , "  workflowStatus: workflowDryRun.status,"
    , "  workflowCount: workflowDryRun.run.state.count,"
    , "  workflowDeliveries: workflowDryRun.run.deliveries.length,"
    , "  workflowAuditCount: workflowDryRun.run.auditLog.length,"
    , "  workflowWorldMessageCount: workflowDryRun.worldSnapshot.surface.messages.length,"
    , "  agentStatus: agentDryRun.status,"
    , "  agentApproval: agentDryRun.approvalPolicy,"
    , "  agentSandbox: agentDryRun.sandboxPolicy,"
    , "  agentAllowed: agentDryRun.steps.every((step) => step.allowed),"
    , "  agentStepKinds: agentDryRun.steps.map((step) => step.kind),"
    , "  agentWorldStepCount: agentDryRun.worldSnapshot.surface.steps.length,"
    , "  traceKinds: simulation.traces().map((entry) => entry.kind),"
    , "  auditKinds: simulation.audits().map((entry) => entry.eventType)"
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
    , "  retry: { maxAttempts: 3, initialBackoffMs: 50, backoffMultiplier: 2, maxBackoffMs: 80 },"
    , "  mailbox: [{ id: 'queued-0', payload: 1 }]"
    , "});"
    , "const temporalClock = workflow.temporal.clock(1000);"
    , "const temporalRun = workflow.start(checkpoint, { deadlineAt: 1100 });"
    , "const temporalDeadline = workflow.temporal.deadline(temporalRun.deadlineAt, { clock: temporalClock });"
    , "const capabilityPending = workflow.temporal.capability({ delegatedAt: 1000, ttlMs: 300, notBefore: 1050 }, { clock: temporalClock });"
    , "const rolloutPending = workflow.temporal.rollout({ startAt: 1100, endAt: 1300 }, { clock: temporalClock });"
    , "temporalClock.advanceBy(125);"
    , "const ttlActive = workflow.temporal.ttl({ issuedAt: 1000, ttlMs: 150 }, { clock: temporalClock });"
    , "const expirationActive = workflow.temporal.expiration({ notBefore: 1050, expiresAt: 1200 }, { clock: temporalClock });"
    , "const scheduleActive = workflow.temporal.schedule({ startAt: 900, everyMs: 100, endAt: 1400 }, { clock: temporalClock });"
    , "const rolloutActive = workflow.temporal.rollout({ startAt: 1100, endAt: 1300 }, { clock: temporalClock });"
    , "const cacheActive = workflow.temporal.cache({ refreshedAt: 1000, staleAfterMs: 75, expireAfterMs: 200 }, { clock: temporalClock });"
    , "const capabilityActive = workflow.temporal.capability({ delegatedAt: 1000, ttlMs: 300, notBefore: 1050 }, { clock: temporalClock });"
    , "const simulatedDeadline = workflow.deliver(temporalRun, { id: 'm-clock', payload: 1 }, (state, payload) => ({"
    , "  state: { count: state.count + payload },"
    , "  result: payload"
    , "}), { clock: temporalClock });"
    , "temporalClock.advanceBy(225);"
    , "const ttlExpired = workflow.temporal.ttl({ issuedAt: 1000, ttlMs: 150 }, { clock: temporalClock });"
    , "const expirationExpired = workflow.temporal.expiration({ notBefore: 1050, expiresAt: 1200 }, { clock: temporalClock });"
    , "const rolloutExpired = workflow.temporal.rollout({ startAt: 1100, endAt: 1300 }, { clock: temporalClock });"
    , "const cacheExpired = workflow.temporal.cache({ refreshedAt: 1000, staleAfterMs: 75, expireAfterMs: 200 }, { clock: temporalClock });"
    , "const capabilityExpired = workflow.temporal.capability({ delegatedAt: 1000, ttlMs: 300, notBefore: 1050 }, { clock: temporalClock });"
    , "const initiallyQueued = run.mailbox.length;"
    , "const queued = workflow.enqueue(run, { id: 'queued-1', payload: 4 });"
    , "const queuedDuplicate = workflow.enqueue(queued.run, { id: 'queued-1', payload: 9 });"
    , "const processNext = workflow.processNext(queued.run, (state, payload) => ({"
    , "  state: { count: state.count + payload },"
    , "  result: `queued-${payload}`"
    , "}), { now: 1000 });"
    , "const queueDrained = workflow.drainMailbox(processNext.run, (state, payload) => ({"
    , "  state: { count: state.count + payload },"
    , "  result: payload"
    , "}), { now: 1000 });"
    , "const blockedMailbox = workflow.drainMailbox(workflow.handoff(queued.run, 'queue-ops', 'manual-drain'), (state, payload) => ({"
    , "  state: { count: state.count + payload },"
    , "  result: payload"
    , "}));"
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
    , "const failedRetried = workflow.deliver(run, { id: 'm8', payload: 1 }, (state, payload, message, meta) => {"
    , "  throw new Error(`fatal-${meta.attempt}`);"
    , "}, {"
    , "  now: 1000,"
    , "  retry: { maxAttempts: 2, initialBackoffMs: 25, backoffMultiplier: 2, maxBackoffMs: 25 }"
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
    , "const replaySeed = workflow.handoff(workflow.cancel(run, 'pre-replay-stop'), 'queue-ops', 'pre-replay-review');"
    , "const migrated = workflow.migrate(checkpoint, workflow, {"
    , "  migrateState: (state, meta) => ({"
    , "    count: state.count + (meta.toModuleVersionId === meta.fromModuleVersionId ? 5 : 10)"
    , "  })"
    , "});"
    , "const upgraded = workflow.upgrade(run, workflow, {"
    , "  migrateState: (state, meta) => ({"
    , "    count: state.count + (meta.toWorkflowName === meta.fromWorkflowName ? 20 : 1)"
    , "  }),"
    , "  prepare: (currentRun, meta) => ({"
    , "    ...currentRun,"
    , "    deadlineAt: currentRun.deadlineAt + (meta.toStateType === meta.fromStateType ? 50 : 0)"
    , "  }),"
    , "  activate: (nextRun) => ({"
    , "    ...nextRun,"
    , "    supervision: {"
    , "      ...nextRun.supervision,"
    , "      supervisor: 'UpgradeSupervisor'"
    , "    }"
    , "  })"
    , "});"
    , "console.log(JSON.stringify({"
    , "  workflowName: workflow.name,"
    , "  stateType: workflow.stateType,"
    , "  moduleVersionTagged: workflow.moduleVersionId.startsWith('module:Main:'),"
    , "  upgradeWindowPolicy: workflow.upgradeWindow.policy,"
    , "  compatibleVersionCount: workflow.compatibility.compatibleModuleVersionIds.length,"
    , "  hotSwapHandlersExplicit: workflow.compatibility.hotSwap.explicitUpgradeHandlers,"
    , "  hotSwapMigrationHooks: workflow.compatibility.hotSwap.stateMigrationHooks,"
    , "  runtimeModuleVersionTagged: runtime.contract.module.versionId.startsWith('module:Main:'),"
    , "  runtimeWorkflowCount: runtime.contract.module.compatibility.workflowCount,"
    , "  checkpoint,"
    , "  resumedValue: resumed.count,"
    , "  deadlineAt: run.deadlineAt,"
    , "  temporalClockKind: temporalClock.kind,"
    , "  temporalClockStart: 1000,"
    , "  temporalDeadlineRemaining: temporalDeadline.remainingMs,"
    , "  ttlActiveRemaining: ttlActive.remainingMs,"
    , "  ttlExpired: ttlExpired.expired,"
    , "  expirationActiveStatus: expirationActive.status,"
    , "  expirationExpiredStatus: expirationExpired.status,"
    , "  scheduleStatus: scheduleActive.status,"
    , "  scheduleLastAt: scheduleActive.lastAt,"
    , "  scheduleNextAt: scheduleActive.nextAt,"
    , "  rolloutPendingStatus: rolloutPending.status,"
    , "  rolloutActiveStatus: rolloutActive.status,"
    , "  rolloutExpiredStatus: rolloutExpired.status,"
    , "  cacheActiveStatus: cacheActive.status,"
    , "  cacheExpiredStatus: cacheExpired.status,"
    , "  capabilityPendingStatus: capabilityPending.status,"
    , "  capabilityActiveStatus: capabilityActive.status,"
    , "  capabilityExpiredStatus: capabilityExpired.status,"
    , "  simulatedDeadlineStatus: simulatedDeadline.status,"
    , "  temporalClockEnd: temporalClock.now(),"
    , "  initiallyQueued,"
    , "  queuedStatus: queued.status,"
    , "  queuedMailboxSize: queued.mailboxSize,"
    , "  queuedDuplicate: queuedDuplicate.duplicate,"
    , "  processedQueuedStatus: processNext.status,"
    , "  processedQueuedResult: processNext.delivery?.result ?? null,"
    , "  drainedStatus: queueDrained.status,"
    , "  drainedMailboxSize: queueDrained.mailboxSize,"
    , "  drainedQueuedResults: queueDrained.deliveries.map((delivery) => delivery.result),"
    , "  blockedMailboxStatus: blockedMailbox.status,"
    , "  blockedMailboxSize: blockedMailbox.mailboxSize,"
    , "  duplicateSuppressed: deliverDuplicate.duplicate,"
    , "  duplicateResult: deliverDuplicate.result,"
    , "  retriedStatus: retried.status,"
    , "  retriedAttempts: retried.attempts,"
    , "  retriedDelays: retried.retryDelaysMs,"
    , "  retriedResult: retried.result,"
    , "  retriedAuditKinds: retried.audit.map((entry) => entry.eventType),"
    , "  retriedAuditLogTail: retried.run.auditLog.slice(-3).map((entry) => entry.eventType),"
    , "  deadlineStatus: deadlineExceeded.status,"
    , "  deadlineAttempts: deadlineExceeded.attempts,"
    , "  deadlineFailure: deadlineExceeded.failure?.message ?? null,"
    , "  deadlineAuditKinds: deadlineExceeded.audit.map((entry) => entry.eventType),"
    , "  deadlineAuditOutcome: deadlineExceeded.audit[deadlineExceeded.audit.length - 1]?.outcome ?? null,"
    , "  failedStatus: failedRetried.status,"
    , "  failedAttempts: failedRetried.attempts,"
    , "  failedFailure: failedRetried.failure?.message ?? null,"
    , "  failedAuditKinds: failedRetried.audit.map((entry) => entry.eventType),"
    , "  failedAuditOutcome: failedRetried.audit[failedRetried.audit.length - 1]?.outcome ?? null,"
    , "  failedAuditExhausted: failedRetried.audit[failedRetried.audit.length - 1]?.exhausted ?? null,"
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
    , "  replayedIds: replayed.processedIds,"
    , "  replayedAuditCount: replayed.auditLog.length,"
    , "  replayedAuditFirst: replayed.auditLog[0]?.transition ?? null,"
    , "  replayedHasCancelledAudit: replayed.auditLog.some((entry) => entry.transition === 'cancelled'),"
    , "  replaySeedAuditCount: replaySeed.auditLog.length,"
    , "  migratedStatus: migrated.status,"
    , "  migratedCount: migrated.state.count,"
    , "  migratedHook: migrated.handlers.migrateState,"
    , "  migratedAuditType: migrated.audit.eventType,"
    , "  upgradedStatus: upgraded.status,"
    , "  upgradedCount: upgraded.run.state.count,"
    , "  upgradedDeadlineAt: upgraded.run.deadlineAt,"
    , "  upgradedSupervisor: upgraded.run.supervision.supervisor,"
    , "  upgradedPrepareHook: upgraded.handlers.prepare,"
    , "  upgradedActivateHook: upgraded.handlers.activate,"
    , "  upgradedAuditType: upgraded.audit.eventType,"
    , "  upgradedAuditLogTail: upgraded.run.auditLog.slice(-1).map((entry) => entry.eventType)"
    , "}));"
    ]

workflowConstraintRuntimeScript :: FilePath -> FilePath -> Text
workflowConstraintRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createWorkerRuntime } from " <> show ("file://" <> runtimePath) <> ";"
    , "const runtime = createWorkerRuntime(compiledModule);"
    , "const workflow = runtime.workflow('CounterFlow');"
    , "const started = workflow.start('{\"count\":2}');"
    , "const resumed = workflow.resume('{\"count\":2}');"
    , "const delivered = workflow.deliver(started, { id: 'ok', payload: 2 }, (state, payload) => ({"
    , "  state: { count: state.count + payload },"
    , "  result: state.count + payload"
    , "}));"
    , "let invariantError = null;"
    , "try {"
    , "  workflow.start('{\"count\":-1}');"
    , "} catch (error) {"
    , "  invariantError = error.message;"
    , "}"
    , "const preconditionFailure = workflow.deliver(workflow.start('{\"count\":5}'), { id: 'pre', payload: 1 }, (state, payload) => ({"
    , "  state: { count: state.count + payload },"
    , "  result: state.count + payload"
    , "}));"
    , "const postconditionFailure = workflow.deliver(workflow.start('{\"count\":4}'), { id: 'post', payload: 2 }, (state, payload) => ({"
    , "  state: { count: state.count + payload },"
    , "  result: state.count + payload"
    , "}));"
    , "console.log(JSON.stringify({"
    , "  constraintNames: Object.values(workflow.constraints).filter(Boolean).map((entry) => entry.name).sort(),"
    , "  deliveredStatus: delivered.status,"
    , "  deliveredResult: delivered.result,"
    , "  resumedCount: resumed.count,"
    , "  invariantError,"
    , "  preconditionStatus: preconditionFailure.status,"
    , "  preconditionError: preconditionFailure.failure?.message ?? null,"
    , "  postconditionStatus: postconditionFailure.status,"
    , "  postconditionError: postconditionFailure.failure?.message ?? null"
    , "}));"
    ]

workflowParallelRuntimeScript :: FilePath -> FilePath -> FilePath -> Text
workflowParallelRuntimeScript oldCompiledPath newCompiledPath runtimePath =
  T.pack . unlines $
    [ "import * as oldCompiledModule from " <> show ("file://" <> oldCompiledPath) <> ";"
    , "import * as newCompiledModule from " <> show ("file://" <> newCompiledPath) <> ";"
    , "import { createWorkerRuntime } from " <> show ("file://" <> runtimePath) <> ";"
    , "function patchTargetCompiledModule(sourceCompiledModule, targetCompiledModule) {"
    , "  const sourceVersionId = sourceCompiledModule.__claspModule.versionId;"
    , "  const patchedTargetModule = Object.freeze({"
    , "    ...targetCompiledModule.__claspModule,"
    , "    upgradeWindow: Object.freeze({"
    , "      ...targetCompiledModule.__claspModule.upgradeWindow,"
    , "      fromVersionIds: Object.freeze(["
    , "        ...new Set(["
    , "          ...(targetCompiledModule.__claspModule.upgradeWindow.fromVersionIds ?? []),"
    , "          sourceVersionId"
    , "        ])"
    , "      ])"
    , "    })"
    , "  });"
    , "  const patchedTargetWorkflows = Object.freeze((targetCompiledModule.__claspWorkflows ?? []).map((workflow) => Object.freeze({"
    , "    ...workflow,"
    , "    compatibility: Object.freeze({"
    , "      ...workflow.compatibility,"
    , "      compatibleModuleVersionIds: Object.freeze(["
    , "        ...new Set(["
    , "          ...(workflow.compatibility?.compatibleModuleVersionIds ?? []),"
    , "          sourceVersionId"
    , "        ])"
    , "      ])"
    , "    })"
    , "  })));"
    , "  const patchedTargetBindings = Object.freeze({"
    , "    ...(targetCompiledModule.__claspBindings ?? {}),"
    , "    module: patchedTargetModule"
    , "  });"
    , "  return Object.freeze({"
    , "    ...targetCompiledModule,"
    , "    __claspModule: patchedTargetModule,"
    , "    __claspWorkflows: patchedTargetWorkflows,"
    , "    __claspBindings: patchedTargetBindings"
    , "  });"
    , "}"
    , "function reduceCounter(state, payload) {"
    , "  return {"
    , "    state: { count: state.count + payload },"
    , "    result: payload"
    , "  };"
    , "}"
    , "const patchedTargetCompiledModule = patchTargetCompiledModule(oldCompiledModule, newCompiledModule);"
    , "const runtime = createWorkerRuntime(oldCompiledModule);"
    , "const workflow = runtime.workflow('CounterFlow');"
    , "let active = 0;"
    , "let maxActive = 0;"
    , "const trace = [];"
    , "const scheduler = runtime.parallel({"
    , "  maxParallelism: 2,"
    , "  executor: async (task, meta) => {"
    , "    active += 1;"
    , "    maxActive = Math.max(maxActive, active);"
    , "    trace.push(`start:${meta.unitId}:${meta.operation}:${meta.sequence}`);"
    , "    const delayMs = meta.operation === 'upgrade' ? 10 : (meta.unitId === 'beta' ? 70 : 30);"
    , "    try {"
    , "      await new Promise((resolve) => setTimeout(resolve, delayMs));"
    , "      return await task();"
    , "    } finally {"
    , "      trace.push(`end:${meta.unitId}:${meta.operation}:${meta.sequence}`);"
    , "      active -= 1;"
    , "    }"
    , "  }"
    , "});"
    , "const alpha = scheduler.workflow('CounterFlow', 'alpha', workflow.checkpoint({ count: 1 }), {"
    , "  supervisor: 'ParallelSupervisor'"
    , "});"
    , "const beta = scheduler.workflow('CounterFlow', 'beta', workflow.checkpoint({ count: 10 }), {"
    , "  supervisor: 'ParallelSupervisor'"
    , "});"
    , "const alphaFirst = alpha.deliver({ id: 'alpha-1', payload: 2 }, reduceCounter);"
    , "const alphaSecond = alpha.deliver({ id: 'alpha-2', payload: 3 }, reduceCounter);"
    , "const alphaUpgrade = alpha.upgrade(patchedTargetCompiledModule, {"
    , "  migrateState: (state) => ({ count: state.count + 100 }),"
    , "  activate: (nextRun) => ({"
    , "    ...nextRun,"
    , "    supervision: {"
    , "      ...nextRun.supervision,"
    , "      supervisor: 'UpgradeSupervisor'"
    , "    }"
    , "  })"
    , "}, { supervisor: 'UpgradeSupervisor' });"
    , "const betaDelivery = beta.deliver({ id: 'beta-1', payload: 4 }, reduceCounter);"
    , "const [alphaFirstResult, alphaSecondResult, alphaUpgradeResult, betaResult] = await Promise.all(["
    , "  alphaFirst,"
    , "  alphaSecond,"
    , "  alphaUpgrade,"
    , "  betaDelivery"
    , "]);"
    , "const alphaRun = alpha.run();"
    , "const betaRun = beta.run();"
    , "const metrics = scheduler.metrics();"
    , "const alphaFirstStart = trace.indexOf('start:alpha:deliver:1');"
    , "const alphaFirstEnd = trace.indexOf('end:alpha:deliver:1');"
    , "const alphaSecondStart = trace.indexOf('start:alpha:deliver:2');"
    , "const alphaSecondEnd = trace.indexOf('end:alpha:deliver:2');"
    , "const alphaUpgradeStart = trace.indexOf('start:alpha:upgrade:3');"
    , "const betaStart = trace.indexOf('start:beta:deliver:4');"
    , "console.log(JSON.stringify({"
    , "  schedulerKind: scheduler.kind,"
    , "  maxParallelism: scheduler.maxParallelism,"
    , "  maxActive,"
    , "  betaOverlappedAlpha: betaStart > alphaFirstStart && betaStart < alphaFirstEnd,"
    , "  sameUnitSerialized: alphaSecondStart > alphaFirstEnd,"
    , "  upgradeSerialized: alphaUpgradeStart > alphaSecondEnd,"
    , "  activeAfter: metrics.activeCount,"
    , "  unitCount: metrics.unitCount,"
    , "  alphaFirstStatus: alphaFirstResult.status,"
    , "  alphaSecondStatus: alphaSecondResult.status,"
    , "  alphaUpgradeStatus: alphaUpgradeResult.status,"
    , "  alphaUpgradeProtocol: alphaUpgradeResult.protocol.kind,"
    , "  alphaFinalCount: alphaRun.state.count,"
    , "  alphaSupervisor: alphaRun.supervision.supervisor,"
    , "  alphaTargetTagged: alphaUpgradeResult.protocol.targetVersionId.startsWith('module:Main:'),"
    , "  alphaProcessedIds: alphaRun.processedIds,"
    , "  betaStatus: betaResult.status,"
    , "  betaFinalCount: betaRun.state.count,"
    , "  betaProcessedIds: betaRun.processedIds"
    , "}));"
    ]

workflowHotSwapRuntimeScript :: FilePath -> FilePath -> FilePath -> Text
workflowHotSwapRuntimeScript oldCompiledPath newCompiledPath runtimePath =
  T.pack . unlines $
    [ "import * as oldCompiledModule from " <> show ("file://" <> oldCompiledPath) <> ";"
    , "import * as newCompiledModule from " <> show ("file://" <> newCompiledPath) <> ";"
    , "import { createWorkerRuntime } from " <> show ("file://" <> runtimePath) <> ";"
    , "const runtime = createWorkerRuntime(oldCompiledModule);"
    , "const sourceVersionId = oldCompiledModule.__claspModule.versionId;"
    , "const patchedTargetModule = Object.freeze({"
    , "  ...newCompiledModule.__claspModule,"
    , "  upgradeWindow: Object.freeze({"
    , "    ...newCompiledModule.__claspModule.upgradeWindow,"
    , "    fromVersionIds: Object.freeze(["
    , "      ...new Set(["
    , "        ...(newCompiledModule.__claspModule.upgradeWindow.fromVersionIds ?? []),"
    , "        sourceVersionId"
    , "      ])"
    , "    ])"
    , "  })"
    , "});"
    , "const patchedTargetWorkflows = Object.freeze((newCompiledModule.__claspWorkflows ?? []).map((workflow) => Object.freeze({"
    , "  ...workflow,"
    , "  compatibility: Object.freeze({"
    , "    ...workflow.compatibility,"
    , "    compatibleModuleVersionIds: Object.freeze(["
    , "      ...new Set(["
    , "        ...(workflow.compatibility?.compatibleModuleVersionIds ?? []),"
    , "        sourceVersionId"
    , "      ])"
    , "    ])"
    , "  })"
    , "})));"
    , "const patchedTargetBindings = Object.freeze({"
    , "  ...(newCompiledModule.__claspBindings ?? {}),"
    , "  module: patchedTargetModule"
    , "});"
    , "const patchedTargetCompiledModule = Object.freeze({"
    , "  ...newCompiledModule,"
    , "  __claspModule: patchedTargetModule,"
    , "  __claspWorkflows: patchedTargetWorkflows,"
    , "  __claspBindings: patchedTargetBindings"
    , "});"
    , "const protocol = runtime.hotSwap(patchedTargetCompiledModule, { supervisor: 'UpgradeSupervisor' });"
    , "const workflow = runtime.workflow('CounterFlow');"
    , "const run = workflow.start(workflow.checkpoint({ count: 5 }), {"
    , "  deadlineAt: 100,"
    , "  mailbox: [{ id: 'queued-upgrade', payload: 4 }]"
    , "});"
    , "const overlap = protocol.begin({ startedAt: 1000 });"
    , "const upgraded = protocol.upgrade('CounterFlow', run, {"
    , "  migrateState: (state) => ({ count: state.count + 3 }),"
    , "  prepare: (currentRun) => currentRun,"
    , "  activate: (nextRun) => ({"
    , "    ...nextRun,"
    , "    supervision: {"
    , "      ...nextRun.supervision,"
    , "      supervisor: 'UpgradeSupervisor'"
    , "    }"
    , "  })"
    , "});"
    , "const retired = protocol.retire({ retiredAt: 1010, reason: 'drained' });"
    , "console.log(JSON.stringify({"
    , "  protocolKind: protocol.kind,"
    , "  supervisor: protocol.supervisor,"
    , "  sourceVersionTagged: protocol.source.versionId.startsWith('module:Main:'),"
    , "  targetVersionTagged: protocol.target.versionId.startsWith('module:Main:'),"
    , "  maxActiveVersions: protocol.overlap.maxActiveVersions,"
    , "  activeVersionCount: protocol.overlap.activeVersionIds.length,"
    , "  acceptsSourceVersion: protocol.overlap.acceptedSourceVersionIds.includes(protocol.source.versionId),"
    , "  workflowCount: protocol.workflows.length,"
    , "  workflowName: protocol.workflow('CounterFlow').name,"
    , "  workflowHotSwapHandlers: protocol.workflow('CounterFlow').hotSwap?.explicitUpgradeHandlers ?? false,"
    , "  overlapStatus: overlap.status,"
    , "  overlapStartedAt: overlap.startedAt,"
    , "  retiredStatus: retired.status,"
    , "  retiredReason: retired.reason,"
    , "  remainingVersionCount: retired.activeVersionIds.length,"
    , "  upgradedStatus: upgraded.status,"
    , "  upgradedCount: upgraded.run.state.count,"
    , "  upgradedMailboxSize: upgraded.run.mailbox.length,"
    , "  upgradedQueuedId: upgraded.run.mailbox[0]?.id ?? null,"
    , "  upgradedSupervisor: upgraded.run.supervision.supervisor,"
    , "  upgradedTargetVersionTagged: upgraded.context.toModuleVersionId.startsWith('module:Main:')"
    , "}));"
    ]

workflowSelfUpdateRuntimeScript :: FilePath -> FilePath -> FilePath -> Text
workflowSelfUpdateRuntimeScript oldCompiledPath newCompiledPath runtimePath =
  T.pack . unlines $
    [ "import * as oldCompiledModule from " <> show ("file://" <> oldCompiledPath) <> ";"
    , "import * as newCompiledModule from " <> show ("file://" <> newCompiledPath) <> ";"
    , "import { createWorkerRuntime } from " <> show ("file://" <> runtimePath) <> ";"
    , "const runtime = createWorkerRuntime(oldCompiledModule);"
    , "const sourceVersionId = oldCompiledModule.__claspModule.versionId;"
    , "const patchedTargetModule = Object.freeze({"
    , "  ...newCompiledModule.__claspModule,"
    , "  upgradeWindow: Object.freeze({"
    , "    ...newCompiledModule.__claspModule.upgradeWindow,"
    , "    fromVersionIds: Object.freeze(["
    , "      ...new Set(["
    , "        ...(newCompiledModule.__claspModule.upgradeWindow.fromVersionIds ?? []),"
    , "        sourceVersionId"
    , "      ])"
    , "    ])"
    , "  })"
    , "});"
    , "const patchedTargetWorkflows = Object.freeze((newCompiledModule.__claspWorkflows ?? []).map((workflow) => Object.freeze({"
    , "  ...workflow,"
    , "  compatibility: Object.freeze({"
    , "    ...workflow.compatibility,"
    , "    compatibleModuleVersionIds: Object.freeze(["
    , "      ...new Set(["
    , "        ...(workflow.compatibility?.compatibleModuleVersionIds ?? []),"
    , "        sourceVersionId"
    , "      ])"
    , "    ])"
    , "  })"
    , "})));"
    , "const patchedTargetBindings = Object.freeze({"
    , "  ...(newCompiledModule.__claspBindings ?? {}),"
    , "  module: patchedTargetModule"
    , "});"
    , "const patchedTargetCompiledModule = Object.freeze({"
    , "  ...newCompiledModule,"
    , "  __claspModule: patchedTargetModule,"
    , "  __claspWorkflows: patchedTargetWorkflows,"
    , "  __claspBindings: patchedTargetBindings"
    , "});"
    , "const protocol = runtime.hotSwap(patchedTargetCompiledModule, { supervisor: 'UpgradeSupervisor' });"
    , "const workflow = runtime.workflow('CounterFlow');"
    , "const run = workflow.start(workflow.checkpoint({ count: 5 }), { deadlineAt: 100 });"
    , "const handoff = protocol.handoff('CounterFlow', run, 'release-bot', 'self-update', { updatedAt: 1001 });"
    , "const draining = protocol.drain('CounterFlow', handoff.run, { updatedAt: 1002 });"
    , "const upgraded = protocol.upgrade('CounterFlow', draining.run, {"
    , "  migrateState: (state) => ({ count: state.count + 3 }),"
    , "  activate: (nextRun) => ({"
    , "    ...nextRun,"
    , "    supervision: {"
    , "      ...nextRun.supervision,"
    , "      supervisor: 'UpgradeSupervisor'"
    , "    }"
    , "  })"
    , "});"
    , "const rolledBack = protocol.rollback('CounterFlow', upgraded.run, {"
    , "  migrateState: (state) => ({ count: state.count - 3 }),"
    , "  activate: (nextRun) => ({"
    , "    ...nextRun,"
    , "    supervision: {"
    , "      ...nextRun.supervision,"
    , "      supervisor: 'RollbackSupervisor'"
    , "    }"
    , "  })"
    , "});"
    , "console.log(JSON.stringify({"
    , "  handoffStatus: handoff.status,"
    , "  handoffOperator: handoff.run.supervision.operator,"
    , "  handoffReason: handoff.run.supervision.reason,"
    , "  handoffRollbackAvailable: handoff.rollbackAvailable,"
    , "  drainingStatus: draining.status,"
    , "  drainingVersionTagged: draining.drainingVersionId.startsWith('module:Main:'),"
    , "  drainingSupervisor: draining.supervisor,"
    , "  drainingRollbackAvailable: draining.rollbackAvailable,"
    , "  upgradedStatus: upgraded.status,"
    , "  upgradedCount: upgraded.run.state.count,"
    , "  upgradedSupervision: upgraded.run.supervision.status,"
    , "  rollbackStatus: rolledBack.status,"
    , "  rollbackCount: rolledBack.run.state.count,"
    , "  rollbackSupervisor: rolledBack.run.supervision.supervisor,"
    , "  rollbackSourceTagged: rolledBack.sourceVersionId.startsWith('module:Main:'),"
    , "  rollbackTargetTagged: rolledBack.targetVersionId.startsWith('module:Main:'),"
    , "  rollbackSupervision: rolledBack.run.supervision.status,"
    , "  rollbackMigrationHook: rolledBack.handlers.migrateState,"
    , "  rollbackActivationHook: rolledBack.handlers.activate,"
    , "  rollbackAuditType: rolledBack.audit.eventType,"
    , "  rollbackAuditTriggerKind: rolledBack.audit.trigger?.kind ?? null,"
    , "  rollbackAuditLogTail: rolledBack.run.auditLog.slice(-2).map((entry) => entry.eventType)"
    , "}));"
    ]

workflowHealthGatedRuntimeScript :: FilePath -> FilePath -> FilePath -> Text
workflowHealthGatedRuntimeScript oldCompiledPath newCompiledPath runtimePath =
  T.pack . unlines $
    [ "import * as oldCompiledModule from " <> show ("file://" <> oldCompiledPath) <> ";"
    , "import * as newCompiledModule from " <> show ("file://" <> newCompiledPath) <> ";"
    , "import { createWorkerRuntime } from " <> show ("file://" <> runtimePath) <> ";"
    , "const runtime = createWorkerRuntime(oldCompiledModule);"
    , "const sourceVersionId = oldCompiledModule.__claspModule.versionId;"
    , "const patchedTargetModule = Object.freeze({"
    , "  ...newCompiledModule.__claspModule,"
    , "  upgradeWindow: Object.freeze({"
    , "    ...newCompiledModule.__claspModule.upgradeWindow,"
    , "    fromVersionIds: Object.freeze(["
    , "      ...new Set(["
    , "        ...(newCompiledModule.__claspModule.upgradeWindow.fromVersionIds ?? []),"
    , "        sourceVersionId"
    , "      ])"
    , "    ])"
    , "  })"
    , "});"
    , "const patchedTargetWorkflows = Object.freeze((newCompiledModule.__claspWorkflows ?? []).map((workflow) => Object.freeze({"
    , "  ...workflow,"
    , "  compatibility: Object.freeze({"
    , "    ...workflow.compatibility,"
    , "    compatibleModuleVersionIds: Object.freeze(["
    , "      ...new Set(["
    , "        ...(workflow.compatibility?.compatibleModuleVersionIds ?? []),"
    , "        sourceVersionId"
    , "      ])"
    , "    ])"
    , "  })"
    , "})));"
    , "const patchedTargetBindings = Object.freeze({"
    , "  ...(newCompiledModule.__claspBindings ?? {}),"
    , "  module: patchedTargetModule"
    , "});"
    , "const patchedTargetCompiledModule = Object.freeze({"
    , "  ...newCompiledModule,"
    , "  __claspModule: patchedTargetModule,"
    , "  __claspWorkflows: patchedTargetWorkflows,"
    , "  __claspBindings: patchedTargetBindings"
    , "});"
    , "const protocol = runtime.hotSwap(patchedTargetCompiledModule, { supervisor: 'UpgradeSupervisor' });"
    , "const workflow = runtime.workflow('CounterFlow');"
    , "const baseRun = workflow.start(workflow.checkpoint({ count: 5 }), { deadlineAt: 100 });"
    , "const handoff = protocol.handoff('CounterFlow', baseRun, 'release-bot', 'self-update', { updatedAt: 1001 });"
    , "const draining = protocol.drain('CounterFlow', handoff.run, { updatedAt: 1002 });"
    , "const activated = protocol.activate('CounterFlow', draining.run, {"
    , "  migrateState: (state) => ({ count: state.count + 3 }),"
    , "  activate: (nextRun) => ({"
    , "    ...nextRun,"
    , "    supervision: {"
    , "      ...nextRun.supervision,"
    , "      supervisor: 'UpgradeSupervisor'"
    , "    }"
    , "  }),"
    , "  healthCheck: (nextRun, meta) => ({"
    , "    healthy: nextRun.state.count === 8 && meta.targetVersionId.startsWith('module:Main:'),"
    , "    status: 'healthy'"
    , "  })"
    , "});"
    , "const blocked = protocol.activate('CounterFlow', draining.run, {"
    , "  migrateState: (state) => ({ count: state.count + 3 }),"
    , "  activate: (nextRun) => ({"
    , "    ...nextRun,"
    , "    supervision: {"
    , "      ...nextRun.supervision,"
    , "      supervisor: 'UpgradeSupervisor'"
    , "    }"
    , "  }),"
    , "  healthCheck: () => ({ healthy: false, status: 'probe-warming', reason: 'probe-warming' }),"
    , "  rollbackOnFail: false"
    , "});"
    , "const autoRolledBack = protocol.activate('CounterFlow', draining.run, {"
    , "  migrateState: (state) => ({ count: state.count + 3 }),"
    , "  activate: (nextRun) => ({"
    , "    ...nextRun,"
    , "    supervision: {"
    , "      ...nextRun.supervision,"
    , "      supervisor: 'UpgradeSupervisor'"
    , "    }"
    , "  }),"
    , "  healthCheck: () => ({ healthy: false, status: 'unhealthy', reason: 'probe-failed' }),"
    , "  rollbackTrigger: { kind: 'health_check_failed', reason: 'probe-failed', at: 1004 },"
    , "  rollback: {"
    , "    migrateState: (state) => ({ count: state.count - 3 }),"
    , "    activate: (nextRun) => ({"
    , "      ...nextRun,"
    , "      supervision: {"
    , "        ...nextRun.supervision,"
    , "        supervisor: 'RollbackSupervisor'"
    , "      }"
    , "    })"
    , "  }"
    , "});"
    , "const manualRolledBack = protocol.triggerRollback('CounterFlow', activated.run, {"
    , "  kind: 'error_budget',"
    , "  reason: 'latency-spike',"
    , "  at: 1005"
    , "}, {"
    , "  migrateState: (state) => ({ count: state.count - 3 }),"
    , "  activate: (nextRun) => ({"
    , "    ...nextRun,"
    , "    supervision: {"
    , "      ...nextRun.supervision,"
    , "      supervisor: 'RollbackSupervisor'"
    , "    }"
    , "  })"
    , "});"
    , "console.log(JSON.stringify({"
    , "  activatedStatus: activated.status,"
    , "  activatedHealthStatus: activated.health.status,"
    , "  activatedRollbackAvailable: activated.rollbackAvailable,"
    , "  activatedCount: activated.run.state.count,"
    , "  activatedTargetTagged: activated.targetVersionId.startsWith('module:Main:'),"
    , "  blockedStatus: blocked.status,"
    , "  blockedHealthStatus: blocked.health.status,"
    , "  blockedRollbackAvailable: blocked.rollbackAvailable,"
    , "  blockedCount: blocked.run.state.count,"
    , "  autoRollbackStatus: autoRolledBack.status,"
    , "  autoRollbackTriggerKind: autoRolledBack.trigger.kind,"
    , "  autoRollbackTriggerReason: autoRolledBack.trigger.reason,"
    , "  autoRollbackTriggerAt: autoRolledBack.trigger.at,"
    , "  autoRollbackCount: autoRolledBack.run.state.count,"
    , "  manualRollbackStatus: manualRolledBack.status,"
    , "  manualRollbackTriggerKind: manualRolledBack.trigger.kind,"
    , "  manualRollbackTriggerReason: manualRolledBack.trigger.reason,"
    , "  manualRollbackTriggerAt: manualRolledBack.trigger.at,"
    , "  manualRollbackCount: manualRolledBack.run.state.count,"
    , "  manualRollbackSupervisor: manualRolledBack.run.supervision.supervisor,"
    , "  autoRollbackAuditType: autoRolledBack.audit.eventType,"
    , "  autoRollbackAuditTriggerKind: autoRolledBack.audit.trigger?.kind ?? null,"
    , "  manualRollbackAuditType: manualRolledBack.audit.eventType,"
    , "  manualRollbackAuditTriggerKind: manualRolledBack.audit.trigger?.kind ?? null"
    , "}));"
    ]

workflowKillSwitchRuntimeScript :: FilePath -> FilePath -> FilePath -> Text
workflowKillSwitchRuntimeScript oldCompiledPath newCompiledPath runtimePath =
  T.pack . unlines $
    [ "import * as oldCompiledModule from " <> show ("file://" <> oldCompiledPath) <> ";"
    , "import * as newCompiledModule from " <> show ("file://" <> newCompiledPath) <> ";"
    , "import { createWorkerRuntime } from " <> show ("file://" <> runtimePath) <> ";"
    , "const runtime = createWorkerRuntime(oldCompiledModule);"
    , "const sourceVersionId = oldCompiledModule.__claspModule.versionId;"
    , "const patchedTargetModule = Object.freeze({"
    , "  ...newCompiledModule.__claspModule,"
    , "  upgradeWindow: Object.freeze({"
    , "    ...newCompiledModule.__claspModule.upgradeWindow,"
    , "    fromVersionIds: Object.freeze(["
    , "      ...new Set(["
    , "        ...(newCompiledModule.__claspModule.upgradeWindow.fromVersionIds ?? []),"
    , "        sourceVersionId"
    , "      ])"
    , "    ])"
    , "  })"
    , "});"
    , "const patchedTargetWorkflows = Object.freeze((newCompiledModule.__claspWorkflows ?? []).map((workflow) => Object.freeze({"
    , "  ...workflow,"
    , "  compatibility: Object.freeze({"
    , "    ...workflow.compatibility,"
    , "    compatibleModuleVersionIds: Object.freeze(["
    , "      ...new Set(["
    , "        ...(workflow.compatibility?.compatibleModuleVersionIds ?? []),"
    , "        sourceVersionId"
    , "      ])"
    , "    ])"
    , "  })"
    , "})));"
    , "const patchedTargetBindings = Object.freeze({"
    , "  ...(newCompiledModule.__claspBindings ?? {}),"
    , "  module: patchedTargetModule"
    , "});"
    , "const patchedTargetCompiledModule = Object.freeze({"
    , "  ...newCompiledModule,"
    , "  __claspModule: patchedTargetModule,"
    , "  __claspWorkflows: patchedTargetWorkflows,"
    , "  __claspBindings: patchedTargetBindings"
    , "});"
    , "const protocol = runtime.hotSwap(patchedTargetCompiledModule, { supervisor: 'UpgradeSupervisor' });"
    , "const workflow = runtime.workflow('CounterFlow');"
    , "const baseRun = workflow.start(workflow.checkpoint({ count: 5 }), { deadlineAt: 100 });"
    , "const handoff = protocol.handoff('CounterFlow', baseRun, 'release-bot', 'self-update', { updatedAt: 1001 });"
    , "const activated = protocol.activate('CounterFlow', handoff.run, {"
    , "  migrateState: (state) => ({ count: state.count + 3 }),"
    , "  activate: (nextRun) => ({"
    , "    ...nextRun,"
    , "    supervision: {"
    , "      ...nextRun.supervision,"
    , "      supervisor: 'UpgradeSupervisor'"
    , "    }"
    , "  })"
    , "});"
    , "const killed = protocol.killSwitch('CounterFlow', activated.run, {"
    , "  trigger: { kind: 'policy_breach', reason: 'policy-breach', at: 1006 },"
    , "  operator: 'safety-bot',"
    , "  rollbackOptions: {"
    , "    migrateState: (state) => ({ count: state.count - 3 }),"
    , "    activate: (nextRun) => ({"
    , "      ...nextRun,"
    , "      supervision: {"
    , "        ...nextRun.supervision,"
    , "        supervisor: 'RollbackSupervisor'"
    , "      }"
    , "    })"
    , "  }"
    , "});"
    , "let blockedMessage = '';"
    , "try {"
    , "  protocol.activate('CounterFlow', killed.run, {"
    , "    migrateState: (state) => state"
    , "  });"
    , "} catch (error) {"
    , "  blockedMessage = error instanceof Error ? error.message : String(error);"
    , "}"
    , "const killState = protocol.killSwitchState();"
    , "console.log(JSON.stringify({"
    , "  killStatus: killed.status,"
    , "  killRollbackStatus: killed.rollback?.status ?? null,"
    , "  killActive: killed.killSwitchActive,"
    , "  killTriggerKind: killed.trigger.kind,"
    , "  killTriggerReason: killed.trigger.reason,"
    , "  killTriggerAt: killed.trigger.at,"
    , "  killCount: killed.run.state.count,"
    , "  killSupervisor: killed.run.supervision.supervisor,"
    , "  killOperator: killed.run.supervision.operator,"
    , "  killReason: killed.run.supervision.reason,"
    , "  killStateRollbackApplied: killState?.rollbackApplied ?? false,"
    , "  killStateTriggerKind: killState?.trigger?.kind ?? null,"
    , "  killAuditType: killed.audit.eventType,"
    , "  killAuditRollbackStatus: killed.audit.rollback?.status ?? null,"
    , "  killAuditLogTail: killed.run.auditLog.slice(-2).map((entry) => entry.eventType),"
    , "  blockedOperationMentionsKillSwitch: blockedMessage.includes('kill switch')"
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

providerRuntimeScript :: FilePath -> FilePath -> Text
providerRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { bindingContractFor, createProviderRuntime, installCompiledModule, providerContractFor, requestPayloadJson } from " <> show ("file://" <> runtimePath) <> ";"
    , "const contract = bindingContractFor(compiledModule);"
    , "const providerContract = providerContractFor(compiledModule);"
    , "let seen = null;"
    , "const providerRuntime = createProviderRuntime(compiledModule, {"
    , "  provider: {"
    , "    invoke(request) {"
    , "      seen = {"
    , "        provider: request.provider,"
    , "        operation: request.operation,"
    , "        customerId: request.args[0].customerId"
    , "      };"
    , "      return JSON.stringify({"
    , "        suggestedReply: `Reply for ${request.args[0].customerId}: ${request.args[0].summary}`"
    , "      });"
    , "    }"
    , "  }"
    , "});"
    , "const installed = providerRuntime.install();"
    , "installCompiledModule(compiledModule, {"
    , "  publishCustomer(customer) {"
    , "    return JSON.stringify(customer);"
    , "  }"
    , "});"
    , "const previewRoute = contract.routes.find((candidate) => candidate.name === 'previewRoute');"
    , "const customerRoute = contract.routes.find((candidate) => candidate.name === 'customerRoute');"
    , "if (!previewRoute || !customerRoute) { throw new Error('missing provider runtime routes'); }"
    , "const previewRequest = new Request('http://example.test/preview', {"
    , "  method: 'POST',"
    , "  headers: { 'content-type': 'application/x-www-form-urlencoded' },"
    , "  body: 'customerId=cust-42&summary=Renewal+is+blocked+on+legal+review.'"
    , "});"
    , "const previewPayload = previewRoute.decodeRequest(await requestPayloadJson(previewRoute, previewRequest));"
    , "const previewHtml = previewRoute.encodeResponse(await previewRoute.handler(previewPayload));"
    , "const customerHtml = customerRoute.encodeResponse(await customerRoute.handler({}));"
    , "console.log(JSON.stringify({"
    , "  providerKind: providerContract.kind,"
    , "  providerVersion: providerContract.version,"
    , "  providerNames: providerContract.providers.map((provider) => provider.name),"
    , "  providerOperation: providerContract.bindings[0]?.operation ?? null,"
    , "  providerBinding: providerContract.bindings[0]?.name ?? null,"
    , "  runtimeInstalled: typeof installed['provider:replyPreview'] === 'function',"
    , "  runtimeBindingVisible: typeof globalThis.__claspRuntime['provider:replyPreview'] === 'function',"
    , "  seenProvider: seen?.provider ?? null,"
    , "  seenOperation: seen?.operation ?? null,"
    , "  seenCustomerId: seen?.customerId ?? null,"
    , "  previewHasReply: previewHtml.includes('Reply for cust-42: Renewal is blocked on legal review.'),"
    , "  customerHasExport: customerHtml.includes('Northwind Studio') && customerHtml.includes('ops@northwind.example')"
    , "}));"
    ]

storageRuntimeScript :: FilePath -> FilePath -> Text
storageRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import { pathToFileURL } from 'node:url';"
    , "import { bindingContractFor } from " <> show ("file://" <> runtimePath) <> ";"
    , "const compiledModule = await import(pathToFileURL(" <> show compiledPath <> ").href);"
    , "const storageContract = bindingContractFor(compiledModule).storage;"
    , "const binding = storageContract.bindings[0] ?? null;"
    , "const table = storageContract.tables[0] ?? null;"
    , "console.log(JSON.stringify({"
    , "  storageKind: storageContract.kind,"
    , "  storageVersion: storageContract.version,"
    , "  bindingNames: storageContract.bindings.map((entry) => entry.name),"
    , "  runtimeNames: storageContract.bindings.map((entry) => entry.runtimeName),"
    , "  tableNames: storageContract.tables.map((entry) => entry.name),"
    , "  paramSemanticType: binding?.params?.[0]?.storageType?.semanticType ?? null,"
    , "  returnSemanticType: binding?.returns?.storageType?.semanticType ?? null,"
    , "  tableSchemaType: table?.schemaType ?? null,"
    , "  tableColumnNames: table?.columns?.map((column) => column.name) ?? [],"
    , "  tableColumnTypes: table?.columns?.map((column) => column.semanticType) ?? [],"
    , "  columnConstraintKinds: table?.columns?.map((column) => column.constraints.map((constraint) => constraint.kind)) ?? [],"
    , "  tableDeclaration: table?.declaration ?? null"
    , "}));"
    ]

sqliteRuntimeScript :: FilePath -> FilePath -> Text
sqliteRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createSqliteRuntime, sqliteContractFor } from " <> show ("file://" <> runtimePath) <> ";"
    , "const sqliteContract = sqliteContractFor(compiledModule);"
    , "const sqliteRuntime = createSqliteRuntime(compiledModule);"
    , "const databasePath = 'dist/test-projects/sqlite-runtime/runtime.db';"
    , "const seededConnection = sqliteRuntime.open(databasePath);"
    , "sqliteRuntime.database(seededConnection).exec('drop table if exists notes;');"
    , "sqliteRuntime.database(seededConnection).exec('create table notes (value text not null);');"
    , "sqliteRuntime.database(seededConnection).exec(\"insert into notes(value) values ('ready');\");"
    , "const installed = sqliteRuntime.install();"
    , "const appConnection = compiledModule.describeConnection(databasePath);"
    , "const memoryConnection = compiledModule.describeConnection(':memory:');"
    , "const readonlyConnection = compiledModule.describeReadonlyConnection(databasePath);"
    , "const row = sqliteRuntime.database(appConnection).prepare('select count(*) as count from notes;').get();"
    , "const liveConnectionCount = sqliteRuntime.listConnections().length;"
    , "const lookupPath = sqliteRuntime.connection(appConnection.id).databasePath;"
    , "const closed = sqliteRuntime.close(appConnection.id);"
    , "let closedLookup = null;"
    , "try {"
    , "  sqliteRuntime.connection(appConnection.id);"
    , "} catch (error) {"
    , "  closedLookup = error instanceof Error ? error.message : String(error);"
    , "}"
    , "sqliteRuntime.close(readonlyConnection.id);"
    , "sqliteRuntime.close(memoryConnection.id);"
    , "sqliteRuntime.close(seededConnection.id);"
    , "console.log(JSON.stringify({"
    , "  sqliteKind: sqliteContract.kind,"
    , "  sqliteVersion: sqliteContract.version,"
    , "  bindingNames: sqliteContract.bindings.map((binding) => binding.name),"
    , "  runtimeNames: sqliteContract.bindings.map((binding) => binding.runtimeName),"
    , "  runtimeInstalled: typeof installed['sqlite:open'] === 'function',"
    , "  memoryPath: memoryConnection.databasePath,"
    , "  memoryIsMemory: memoryConnection.memory,"
    , "  readonlyPath: readonlyConnection.databasePath,"
    , "  readonlyFlag: readonlyConnection.readOnly,"
    , "  liveConnectionCount,"
    , "  rowCount: row.count,"
    , "  lookupPath,"
    , "  closed,"
    , "  closedLookup"
    , "}));"
    ]

sqliteQueryRuntimeScript :: FilePath -> FilePath -> Text
sqliteQueryRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createSqliteRuntime, sqliteContractFor } from " <> show ("file://" <> runtimePath) <> ";"
    , "const sqliteContract = sqliteContractFor(compiledModule);"
    , "const sqliteRuntime = createSqliteRuntime(compiledModule);"
    , "const databasePath = 'dist/test-projects/sqlite-query-runtime/runtime.db';"
    , "const seedConnection = sqliteRuntime.open(databasePath);"
    , "sqliteRuntime.database(seedConnection).exec('drop table if exists notes;');"
    , "sqliteRuntime.database(seedConnection).exec('create table notes (value text not null);');"
    , "sqliteRuntime.database(seedConnection).exec(\"insert into notes(value) values ('alpha'), ('beta'), ('gamma');\");"
    , "const installed = sqliteRuntime.install();"
    , "const queryConnection = sqliteRuntime.open(databasePath);"
    , "const firstNote = compiledModule.firstNote(queryConnection, 'select value as note from notes order by value asc limit 1');"
    , "const noteCount = compiledModule.noteCount(queryConnection, 'select count(*) as count from notes');"
    , "const noteRows = compiledModule.noteRows(queryConnection, 'select value as note from notes order by value asc');"
    , "const filteredNotes = compiledModule.notesByValue(queryConnection, 'select value as note from notes where value = :wanted', { wanted: 'beta' });"
    , "sqliteRuntime.close(queryConnection.id);"
    , "sqliteRuntime.close(seedConnection.id);"
    , "console.log(JSON.stringify({"
    , "  sqliteKind: sqliteContract.kind,"
    , "  sqliteVersion: sqliteContract.version,"
    , "  bindingNames: sqliteContract.bindings.map((binding) => binding.name),"
    , "  runtimeNames: sqliteContract.bindings.map((binding) => binding.runtimeName),"
    , "  operations: sqliteContract.bindings.map((binding) => binding.operation),"
    , "  runtimeInstalled: typeof installed['sqlite:queryOne'] === 'function' && typeof installed['sqlite:queryAll'] === 'function',"
    , "  firstNote: firstNote.note,"
    , "  noteCount: noteCount.count,"
    , "  noteValues: noteRows.map((row) => row.note),"
    , "  filteredNotes"
    , "}));"
    ]

sqliteMutationRuntimeScript :: FilePath -> FilePath -> Text
sqliteMutationRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createSqliteRuntime, sqliteContractFor } from " <> show ("file://" <> runtimePath) <> ";"
    , "const sqliteContract = sqliteContractFor(compiledModule);"
    , "const sqliteRuntime = createSqliteRuntime(compiledModule);"
    , "const databasePath = 'dist/test-projects/sqlite-mutation-runtime/runtime.db';"
    , "const connection = sqliteRuntime.open(databasePath);"
    , "sqliteRuntime.database(connection).exec('drop table if exists notes;');"
    , "sqliteRuntime.database(connection).exec('create table notes (value text not null);');"
    , "sqliteRuntime.database(connection).exec(\"insert into notes(value) values ('alpha');\");"
    , "const installed = sqliteRuntime.install();"
    , "let committedTransaction = null;"
    , "let nestedTransaction = null;"
    , "const committed = sqliteRuntime.transaction(connection, { isolation: 'immediate' }, (tx) => {"
    , "  committedTransaction = { kind: tx.kind, isolation: tx.isolation, boundary: tx.boundary, depth: tx.depth };"
    , "  const inserted = compiledModule.saveNote(connection, 'insert into notes(value) values (:wanted) returning value as note', { wanted: 'beta' });"
    , "  const nested = sqliteRuntime.transaction(connection, { isolation: 'exclusive' }, (nestedTx) => {"
    , "    nestedTransaction = { kind: nestedTx.kind, isolation: nestedTx.isolation, boundary: nestedTx.boundary, depth: nestedTx.depth };"
    , "    return compiledModule.rewriteNotes(connection, 'update notes set value = upper(value) where value = :wanted returning value as note', { wanted: 'beta' });"
    , "  });"
    , "  return { inserted, nested };"
    , "});"
    , "let rolledBack = null;"
    , "try {"
    , "  sqliteRuntime.transaction(connection, { isolation: 'immediate' }, () => {"
    , "    compiledModule.saveNote(connection, 'insert into notes(value) values (:wanted) returning value as note', { wanted: 'gamma' });"
    , "    throw new Error('rollback mutation');"
    , "  });"
    , "} catch (error) {"
    , "  rolledBack = error.message;"
    , "}"
    , "const finalNotes = sqliteRuntime.queryAll(connection, 'select value as note from notes order by lower(value) desc').map((row) => row.note);"
    , "sqliteRuntime.close(connection.id);"
    , "console.log(JSON.stringify({"
    , "  sqliteKind: sqliteContract.kind,"
    , "  sqliteVersion: sqliteContract.version,"
    , "  bindingNames: sqliteContract.bindings.map((binding) => binding.name),"
    , "  runtimeNames: sqliteContract.bindings.map((binding) => binding.runtimeName),"
    , "  operations: sqliteContract.bindings.map((binding) => binding.operation),"
    , "  isolations: sqliteContract.bindings.map((binding) => binding.transaction?.isolation ?? null),"
    , "  mutationKinds: sqliteContract.bindings.map((binding) => binding.mutation?.cardinality ?? null),"
    , "  paramSemanticTypes: sqliteContract.bindings.map((binding) => binding.params[2].storageType.semanticType),"
    , "  returnSemanticTypes: sqliteContract.bindings.map((binding) => binding.returns.storageType.semanticType),"
    , "  runtimeInstalled: typeof installed['sqlite:mutateOne:immediate'] === 'function' && typeof installed['sqlite:mutateAll:exclusive'] === 'function',"
    , "  insertedNote: committed.inserted.note,"
    , "  replacedNotes: committed.nested,"
    , "  committedTransaction,"
    , "  nestedTransaction,"
    , "  rolledBack,"
    , "  finalNotes"
    , "}));"
    ]

sqliteProtectedRuntimeScript :: FilePath -> FilePath -> Text
sqliteProtectedRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createSqliteRuntime, sqliteContractFor } from " <> show ("file://" <> runtimePath) <> ";"
    , "const sqliteContract = sqliteContractFor(compiledModule);"
    , "const sqliteRuntime = createSqliteRuntime(compiledModule);"
    , "const databasePath = 'dist/test-projects/sqlite-protected-runtime/runtime.db';"
    , "const connection = sqliteRuntime.open(databasePath);"
    , "sqliteRuntime.database(connection).exec('drop table if exists customers;');"
    , "sqliteRuntime.database(connection).exec('create table customers (id text not null, email text not null, tier text not null);');"
    , "sqliteRuntime.database(connection).exec(\"insert into customers(id, email, tier) values ('cust-1', 'ops@northwind.example', 'enterprise');\");"
    , "sqliteRuntime.install();"
    , "const queryBinding = sqliteContract.bindings.find((binding) => binding.name === 'fetchCustomers');"
    , "const mutationBinding = sqliteContract.bindings.find((binding) => binding.name === 'saveCustomer');"
    , "const fetched = compiledModule.loadCustomers(connection, 'select id, email, tier from customers order by id asc');"
    , "const saved = compiledModule.persistCustomer(connection, 'update customers set email = :email, tier = :tier where id = :id returning id, email, tier', { id: 'cust-1', email: 'ops@northwind.example', tier: 'enterprise' });"
    , "sqliteRuntime.close(connection.id);"
    , "console.log(JSON.stringify({"
    , "  queryReturnSemanticType: queryBinding?.returns?.storageType?.semanticType ?? null,"
    , "  queryRowPolicy: queryBinding?.returns?.storageType?.item?.proof?.policy ?? null,"
    , "  queryRowProjectionSource: queryBinding?.returns?.storageType?.item?.proof?.projectionSource ?? null,"
    , "  queryProtectedFields: queryBinding?.returns?.storageType?.item?.proof?.protectedFields ?? [],"
    , "  queryEmailClassification: queryBinding?.returns?.storageType?.item?.fields?.email?.classification ?? null,"
    , "  queryEmailFieldIdentity: queryBinding?.returns?.storageType?.item?.fields?.email?.fieldIdentity ?? null,"
    , "  queryEmailPolicy: queryBinding?.returns?.storageType?.item?.fields?.email?.proof?.policy ?? null,"
    , "  queryEmailRequiresProof: queryBinding?.returns?.storageType?.item?.fields?.email?.proof?.requiresPolicyProof ?? null,"
    , "  mutationParamSemanticType: mutationBinding?.params?.[2]?.storageType?.semanticType ?? null,"
    , "  mutationParamPolicy: mutationBinding?.params?.[2]?.storageType?.proof?.policy ?? null,"
    , "  mutationReturnPolicy: mutationBinding?.returns?.storageType?.proof?.policy ?? null,"
    , "  savedEmail: saved.email,"
    , "  loadedEmails: fetched.map((row) => row.email)"
    , "}));"
    ]

sqliteUnsafeRuntimeScript :: FilePath -> FilePath -> Text
sqliteUnsafeRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createSqliteRuntime, sqliteContractFor } from " <> show ("file://" <> runtimePath) <> ";"
    , "const sqliteContract = sqliteContractFor(compiledModule);"
    , "const sqliteRuntime = createSqliteRuntime(compiledModule);"
    , "const databasePath = 'dist/test-projects/sqlite-unsafe-runtime/runtime.db';"
    , "const connection = sqliteRuntime.open(databasePath);"
    , "sqliteRuntime.database(connection).exec('drop table if exists notes;');"
    , "sqliteRuntime.database(connection).exec('create table notes (value text not null);');"
    , "sqliteRuntime.database(connection).exec(\"insert into notes(value) values ('alpha'), ('beta');\");"
    , "const installed = sqliteRuntime.install();"
    , "const unsafeConnection = sqliteRuntime.open(databasePath);"
    , "const firstNote = sqliteRuntime.call('fetchUnsafeFirstNote', unsafeConnection, 'select value as note from notes order by value asc limit 1').note;"
    , "const allNotes = sqliteRuntime.call('fetchUnsafeNotes', unsafeConnection, 'select value as note from notes order by value asc').map((row) => row.note);"
    , "const rewrittenNotes = sqliteRuntime.call('rewriteUnsafeNotes', unsafeConnection, \"update notes set value = upper(:wanted) where lower(value) = lower(:wanted) returning value as note\", { wanted: 'beta' }).map((row) => row.note);"
    , "const auditEntries = sqliteRuntime.auditEntries();"
    , "const finalNotes = sqliteRuntime.queryAll(unsafeConnection, 'select value as note from notes order by lower(value) desc').map((row) => row.note);"
    , "sqliteRuntime.clearAuditEntries();"
    , "const clearedAuditCount = sqliteRuntime.auditEntries().length;"
    , "sqliteRuntime.close(unsafeConnection.id);"
    , "sqliteRuntime.close(connection.id);"
    , "console.log(JSON.stringify({"
    , "  sqliteKind: sqliteContract.kind,"
    , "  sqliteVersion: sqliteContract.version,"
    , "  bindingNames: sqliteContract.bindings.map((binding) => binding.name),"
    , "  runtimeNames: sqliteContract.bindings.map((binding) => binding.runtimeName),"
    , "  operations: sqliteContract.bindings.map((binding) => binding.operation),"
    , "  unsafeBaseOperations: sqliteContract.bindings.map((binding) => binding.unsafe?.baseOperation ?? null),"
    , "  unsafeRowContracts: sqliteContract.bindings.map((binding) => binding.unsafe?.rowContract?.semanticType ?? null),"
    , "  unsafeAuditKinds: sqliteContract.bindings.map((binding) => binding.unsafe?.audit?.kind ?? null),"
    , "  runtimeInstalled: typeof installed['sqlite:unsafeQueryOne'] === 'function' && typeof installed['sqlite:unsafeQueryAll'] === 'function' && typeof installed['sqlite:unsafeMutateAll:immediate'] === 'function',"
    , "  firstNote,"
    , "  allNotes,"
    , "  rewrittenNotes,"
    , "  auditCount: auditEntries.length,"
    , "  auditOperations: auditEntries.map((entry) => entry.binding.operation),"
    , "  auditRowContracts: auditEntries.map((entry) => entry.rowContract?.semanticType ?? null),"
    , "  auditParameterCounts: auditEntries.map((entry) => entry.parameterCount),"
    , "  finalNotes,"
    , "  clearedAuditCount"
    , "}));"
    ]

sqliteSchemaRuntimeScript :: FilePath -> FilePath -> Text
sqliteSchemaRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import { DatabaseSync } from 'node:sqlite';"
    , "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createSqliteRuntime } from " <> show ("file://" <> runtimePath) <> ";"
    , "const legacyPath = 'dist/test-projects/sqlite-schema-runtime/legacy.db';"
    , "const incompatiblePath = 'dist/test-projects/sqlite-schema-runtime/incompatible.db';"
    , "function seedLegacyDatabase(path, includeArchived = false) {"
    , "  const database = new DatabaseSync(path);"
    , "  database.exec('drop table if exists notes;');"
    , "  database.exec(includeArchived ? 'create table notes (value text not null, archived integer not null default 0);' : 'create table notes (value text not null);');"
    , "  database.exec(\"insert into notes(value) values ('alpha');\");"
    , "  database.exec(`pragma user_version = 1;`);"
    , "  database.close();"
    , "}"
    , "seedLegacyDatabase(legacyPath);"
    , "seedLegacyDatabase(incompatiblePath);"
    , "const events = [];"
    , "const sqliteRuntime = createSqliteRuntime(compiledModule, {"
    , "  schema: {"
    , "    version: 2,"
    , "    migrate(context) {"
    , "      events.push(`migrate:${context.connection.id}:${context.fromVersion}->${context.toVersion}`);"
    , "      const columns = context.database.prepare(\"pragma table_info('notes');\").all().map((row) => row.name);"
    , "      if (!columns.includes('archived')) {"
    , "        context.database.exec('alter table notes add column archived integer not null default 0;');"
    , "      }"
    , "      context.writeVersion(context.toVersion);"
    , "      events.push(`migrated:${context.readVersion()}`);"
    , "    },"
    , "    compatibility(context) {"
    , "      const columns = context.database.prepare(\"pragma table_info('notes');\").all().map((row) => row.name);"
    , "      const compatible = context.currentVersion === context.expectedVersion && columns.includes('archived');"
    , "      events.push(`compatible:${context.connection.id}:${context.currentVersion}:${compatible}`);"
    , "      return compatible || `expected notes.archived at schema ${context.expectedVersion}`;"
    , "    }"
    , "  },"
    , "  onOpen({ connection, database }) {"
    , "    const row = database.prepare('pragma user_version;').get();"
    , "    events.push(`open:${connection.id}:${row.user_version}`);"
    , "  }"
    , "});"
    , "const installed = sqliteRuntime.install();"
    , "const migratedConnection = compiledModule.describeConnection(legacyPath);"
    , "const migratedDatabase = sqliteRuntime.database(migratedConnection);"
    , "const migratedVersion = migratedDatabase.prepare('pragma user_version;').get().user_version;"
    , "const migratedColumns = migratedDatabase.prepare(\"pragma table_info('notes');\").all().map((row) => row.name).sort();"
    , "const archivedValue = migratedDatabase.prepare('select archived from notes limit 1;').get().archived;"
    , "sqliteRuntime.close(migratedConnection.id);"
    , "const readonlyConnection = compiledModule.describeReadonlyConnection(legacyPath);"
    , "const readonlyVersion = sqliteRuntime.database(readonlyConnection).prepare('pragma user_version;').get().user_version;"
    , "sqliteRuntime.close(readonlyConnection.id);"
    , "let incompatibleError = null;"
    , "try {"
    , "  compiledModule.describeReadonlyConnection(incompatiblePath);"
    , "} catch (error) {"
    , "  incompatibleError = error.message;"
    , "}"
    , "console.log(JSON.stringify({"
    , "  runtimeInstalled: typeof installed['sqlite:open'] === 'function' && typeof installed['sqlite:openReadonly'] === 'function',"
    , "  migratedVersion,"
    , "  migratedColumns,"
    , "  archivedValue,"
    , "  readonlyVersion,"
    , "  incompatibleError,"
    , "  events"
    , "}));"
    ]

providerRuntimeInvalidOutputScript :: FilePath -> FilePath -> Text
providerRuntimeInvalidOutputScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createProviderRuntime, installCompiledModule } from " <> show ("file://" <> runtimePath) <> ";"
    , "const providerRuntime = createProviderRuntime(compiledModule, {"
    , "  provider: {"
    , "    invoke() {"
    , "      return JSON.stringify({ suggestedReply: 42 });"
    , "    }"
    , "  }"
    , "});"
    , "providerRuntime.install();"
    , "installCompiledModule(compiledModule, {"
    , "  publishCustomer(customer) {"
    , "    return JSON.stringify(customer);"
    , "  }"
    , "});"
    , "try {"
    , "  compiledModule.previewText({ customerId: 'cust-42', summary: 'Renewal is blocked.' });"
    , "} catch (error) {"
    , "  console.log(error.message);"
    , "}"
    ]

dynamicSchemaServerRuntimeScript :: FilePath -> FilePath -> Text
dynamicSchemaServerRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { bindingContractFor, createDynamicSchema, installCompiledModule, requestPayloadJson } from " <> show ("file://" <> runtimePath) <> ";"
    , "const contract = bindingContractFor(compiledModule);"
    , "const route = contract.routes.find((candidate) => candidate.name === 'triageLeadRoute');"
    , "if (!route) { throw new Error('missing triage route'); }"
    , "const outputSchema = createDynamicSchema(compiledModule, ['LeadSummary', 'LeadEscalation']);"
    , "installCompiledModule(compiledModule, {"
    , "  classifyLead(lead) {"
    , "    if (lead.budget >= 50000) {"
    , "      return JSON.stringify({ escalationReason: 'enterprise-budget', owner: 'ae-team' });"
    , "    }"
    , "    return JSON.stringify({"
    , "      summary: `${lead.company}:${lead.budget}`,"
    , "      priority: lead.priorityHint,"
    , "      followUpRequired: false"
    , "    });"
    , "  }"
    , "});"
    , "const lowRequest = new Request('http://example.test/lead/triage', {"
    , "  method: 'POST',"
    , "  headers: { 'content-type': 'application/json' },"
    , "  body: JSON.stringify({ company: 'Acme', budget: 25, priorityHint: 'low' })"
    , "});"
    , "const highRequest = new Request('http://example.test/lead/triage', {"
    , "  method: 'POST',"
    , "  headers: { 'content-type': 'application/json' },"
    , "  body: JSON.stringify({ company: 'SynthSpeak', budget: 90000, priorityHint: 'high' })"
    , "});"
    , "const lowPayload = route.decodeRequest(await requestPayloadJson(route, lowRequest));"
    , "const highPayload = route.decodeRequest(await requestPayloadJson(route, highRequest));"
    , "const lowSelection = outputSchema.selectJson(compiledModule.triageLead(lowPayload), 'result');"
    , "const highSelection = outputSchema.selectJson(compiledModule.triageLead(highPayload), 'result');"
    , "let invalid = null;"
    , "try {"
    , "  outputSchema.selectJson(JSON.stringify({ summary: 42 }), 'result');"
    , "} catch (error) {"
    , "  invalid = error instanceof Error ? error.message : String(error);"
    , "}"
    , "console.log(JSON.stringify({"
    , "  routePath: route.path,"
    , "  schemaNames: Object.keys(outputSchema.schemas).sort(),"
    , "  lowType: lowSelection.typeName,"
    , "  lowPriority: lowSelection.value.priority,"
    , "  highType: highSelection.typeName,"
    , "  highOwner: highSelection.value.owner,"
    , "  invalid"
    , "}));"
    ]

bamlShimRuntimeScript :: FilePath -> FilePath -> Text
bamlShimRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createBamlShim } from " <> show ("file://" <> runtimePath) <> ";"
    , "const baml = createBamlShim(compiledModule, {"
    , "  functions: {"
    , "    decideDraft: {"
    , "      input: 'TicketDraft',"
    , "      output: ['ReplyDraft', 'EscalationDraft'],"
    , "      execute(ticket) {"
    , "        if (ticket.priority === 'high') {"
    , "          return JSON.stringify({"
    , "            action: 'escalate',"
    , "            customerId: ticket.customerId,"
    , "            queue: 'renewals-desk',"
    , "            reason: 'legal-review-deadline',"
    , "            brief: 'Enterprise renewal blocked on legal review.'"
    , "          });"
    , "        }"
    , "        return JSON.stringify({"
    , "          action: 'reply',"
    , "          customerId: ticket.customerId,"
    , "          subject: 'Renewal update',"
    , "          reply: 'We are coordinating with legal and will send the next update window shortly.'"
    , "        });"
    , "      }"
    , "    }"
    , "  }"
    , "});"
    , "const lookupCustomer = baml.tool('lookupCustomer');"
    , "const prepared = lookupCustomer.call({ customerId: 'cust-42' }, 'call-7');"
    , "const parsed = lookupCustomer.parse({"
    , "  customerId: 'cust-42',"
    , "  company: 'Northwind Studio',"
    , "  plan: 'standard',"
    , "  renewalAtRisk: false"
    , "});"
    , "const reply = baml.function('decideDraft').call({"
    , "  customerId: 'cust-42',"
    , "  issue: 'Renewal is blocked on legal review.',"
    , "  priority: 'normal'"
    , "});"
    , "const escalate = baml.function('decideDraft').parseJson(JSON.stringify({"
    , "  action: 'escalate',"
    , "  customerId: 'cust-99',"
    , "  queue: 'renewals-desk',"
    , "  reason: 'legal-review-deadline',"
    , "  brief: 'Enterprise renewal blocked on legal review.'"
    , "}));"
    , "const selection = baml.dynamicSchema(['ReplyDraft', 'EscalationDraft']).select({"
    , "  action: 'reply',"
    , "  customerId: 'cust-42',"
    , "  subject: 'Renewal update',"
    , "  reply: 'Pending legal update.'"
    , "});"
    , "console.log(JSON.stringify({"
    , "  kind: baml.kind,"
    , "  schemaKind: baml.type('CustomerProfile').schema.kind,"
    , "  toolNames: Object.keys(baml.tools),"
    , "  preparedMethod: prepared.method,"
    , "  preparedCustomerId: prepared.params.customerId,"
    , "  parsedCompany: parsed.company,"
    , "  replyAction: reply.action,"
    , "  escalateQueue: escalate.queue,"
    , "  dynamicType: selection.typeName"
    , "}));"
    ]

secretSurfaceRuntimeScript :: FilePath -> FilePath -> Text
secretSurfaceRuntimeScript compiledPath runtimePath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "import { createProviderRuntime, providerContractFor } from " <> show ("file://" <> runtimePath) <> ";"
    , "import { Console } from 'node:console';"
    , "import { Writable } from 'node:stream';"
    , "import { inspect } from 'node:util';"
    , "const boundary = compiledModule.__claspSecretBoundaries.find((candidate) => candidate.kind === 'toolServer');"
    , "if (!boundary) { throw new Error('missing tool-server secret boundary'); }"
    , "const environmentSecrets = compiledModule.__claspSecretInjectors.environment({ OPENAI_API_KEY: 'sk-env-openai', SEARCH_API_TOKEN: 'tok-env-1' });"
    , "const hostSecrets = compiledModule.__claspSecretInjectors.provider((secretHandle) => {"
    , "  if (secretHandle.name === 'OPENAI_API_KEY') { return 'sk-provider-openai'; }"
    , "  if (secretHandle.name === 'SEARCH_API_TOKEN') { return 'tok-provider-1'; }"
    , "  return null;"
    , "});"
    , "const route = compiledModule.__claspRoutes.find((candidate) => candidate.name === 'previewRoute');"
    , "const workflow = compiledModule.__claspWorkflows.find((candidate) => candidate.name === 'SearchFlow');"
    , "const tool = compiledModule.__claspTools.find((candidate) => candidate.name === 'searchRepo');"
    , "if (!route || !workflow || !tool) { throw new Error('missing secret consumer surfaces'); }"
    , "const declaration = compiledModule.__claspSecretDeclarations[0];"
    , "const routeSecrets = route.secretConsumer(boundary).fromEnvironment({ OPENAI_API_KEY: 'sk-env-openai', SEARCH_API_TOKEN: 'tok-env-1' });"
    , "const workflowSecrets = workflow.secretConsumer(boundary).fromEnvironment({ OPENAI_API_KEY: 'sk-env-openai', SEARCH_API_TOKEN: 'tok-env-1' });"
    , "const toolSecrets = tool.secretConsumer().fromEnvironment({ OPENAI_API_KEY: 'sk-env-openai', SEARCH_API_TOKEN: 'tok-env-1' });"
    , "const providerContract = providerContractFor(compiledModule);"
    , "const providerBinding = providerContract.bindings.find((candidate) => candidate.name === 'generateReplyPreview');"
    , "if (!providerBinding) { throw new Error('missing provider binding'); }"
    , "const providerSecrets = providerBinding.secretConsumer(boundary).fromProvider((secretHandle) => {"
    , "  if (secretHandle.name === 'OPENAI_API_KEY') { return 'sk-provider-openai'; }"
    , "  if (secretHandle.name === 'SEARCH_API_TOKEN') { return 'tok-provider-1'; }"
    , "  return null;"
    , "});"
    , "let seenRequest = null;"
    , "const providerRuntime = createProviderRuntime(compiledModule, {"
    , "  providers: {"
    , "    provider: {"
    , "      invoke(request) {"
    , "        const resolved = request.resolveSecret(request.secretHandles[1]);"
    , "        seenRequest = {"
    , "          secretNames: request.secretHandles.map((secretHandle) => secretHandle.name),"
    , "          resolvedValue: resolved.reveal({ reason: 'provider-request' })"
    , "        };"
    , "        return JSON.stringify({ summary: `preview: ${resolved.reveal({ reason: 'provider-preview' })}` });"
    , "      }"
    , "    }"
    , "  },"
    , "  secretProvider(secretHandle) {"
    , "    if (secretHandle.name === 'OPENAI_API_KEY') { return 'sk-provider-openai'; }"
    , "    if (secretHandle.name === 'SEARCH_API_TOKEN') { return 'tok-provider-1'; }"
    , "    return null;"
    , "  },"
    , "  secretBoundary: boundary"
    , "});"
    , "providerRuntime.install();"
    , "const routeSecret = routeSecrets.resolve('OPENAI_API_KEY');"
    , "let routeSecretReadError = null;"
    , "let routeSecretSerializeError = null;"
    , "let routeSecretCoerceError = null;"
    , "let routeSecretInspectError = null;"
    , "let routeSecretLogError = null;"
    , "try {"
    , "  routeSecret.value;"
    , "} catch (error) {"
    , "  routeSecretReadError = error.message;"
    , "}"
    , "try {"
    , "  JSON.stringify(routeSecret);"
    , "} catch (error) {"
    , "  routeSecretSerializeError = error.message;"
    , "}"
    , "try {"
    , "  `${routeSecret}`;"
    , "} catch (error) {"
    , "  routeSecretCoerceError = error.message;"
    , "}"
    , "try {"
    , "  inspect(routeSecret);"
    , "} catch (error) {"
    , "  routeSecretInspectError = error.message;"
    , "}"
    , "const logSink = [];"
    , "const logger = new Console({"
    , "  stdout: new Writable({ write(chunk, encoding, callback) { logSink.push(String(chunk)); callback(); } }),"
    , "  stderr: new Writable({ write(chunk, encoding, callback) { logSink.push(String(chunk)); callback(); } })"
    , "});"
    , "try {"
    , "  logger.log(routeSecret);"
    , "} catch (error) {"
    , "  routeSecretLogError = error.message;"
    , "}"
    , "const providerResult = compiledModule.providerPreview({ query: 'renewal' });"
    , "console.log(JSON.stringify({"
    , "  declarationKind: declaration.declarationKind,"
    , "  environmentKey: declaration.environmentKey,"
    , "  injectorVersion: compiledModule.__claspSecretInjectors.version,"
    , "  routeSecretNames: routeSecrets.secretHandles.map((secretHandle) => secretHandle.name),"
    , "  routeSourceKind: routeSecrets.source.sourceKind,"
    , "  routeSecretValue: routeSecret.reveal({ reason: 'route-preview' }),"
    , "  routeSecretRedaction: routeSecret.redact({ reason: 'route-preview' }).text,"
    , "  routeSecretReadError,"
    , "  routeSecretSerializeError,"
    , "  routeSecretCoerceError,"
    , "  routeSecretInspectError,"
    , "  routeSecretLogError,"
    , "  routeSecretLogged: logSink.length > 0,"
    , "  workflowTracePolicy: workflowSecrets.traceAccess('SEARCH_API_TOKEN').policy,"
    , "  workflowSecretValue: workflowSecrets.resolve('SEARCH_API_TOKEN').reveal({ reason: 'workflow-preview' }),"
    , "  toolSecretCount: toolSecrets.secretHandles.length,"
    , "  toolHasOpenAI: toolSecrets.consumer.hasSecret('OPENAI_API_KEY'),"
    , "  providerSecretNames: providerSecrets.secretHandles.map((secretHandle) => secretHandle.name),"
    , "  providerSourceKind: providerSecrets.source.sourceKind,"
    , "  providerResolvedName: providerSecrets.consumer.handle('SEARCH_API_TOKEN').name,"
    , "  providerResolvedValue: providerSecrets.resolve('SEARCH_API_TOKEN').reveal({ reason: 'provider-preview' }),"
    , "  providerRequestSecretNames: seenRequest?.secretNames ?? [],"
    , "  providerRequestResolvedValue: seenRequest?.resolvedValue ?? null,"
    , "  providerPreview: providerResult.summary"
    , "}));"
    ]

delegatedSecretHandoffRuntimeScript :: FilePath -> Text
delegatedSecretHandoffRuntimeScript compiledPath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "const agent = compiledModule.__claspAgents[0];"
    , "const tool = compiledModule.__claspTools[0];"
    , "const workflow = compiledModule.__claspWorkflows[0];"
    , "if (!agent || !tool || !workflow) { throw new Error('missing delegated handoff surfaces'); }"
    , "const agentBoundary = compiledModule.__claspSecretBoundaries.find((boundary) => boundary.kind === 'agentRole');"
    , "if (!agentBoundary) { throw new Error('missing agent secret boundary'); }"
    , "const provider = { OPENAI_API_KEY: 'sk-agent-live', SEARCH_API_TOKEN: 'tok-workflow-live' };"
    , "const agentSecrets = agent.secretConsumer();"
    , "const toolSecrets = tool.secretConsumer();"
    , "const workflowSecrets = workflow.secretConsumer(agentBoundary);"
    , "const agentToTool = agentSecrets.handoff(toolSecrets, { reason: 'invoke-tool', delegatedAt: 1700, attenuation: { action: 'resolve', ttlMs: 300, maxUses: 1 } });"
    , "const repeatDelegationA = agentSecrets.delegate(agentSecrets.secretHandles[0], { consumer: toolSecrets, reason: 'repeat-a' });"
    , "const repeatDelegationB = agentSecrets.delegate(agentSecrets.secretHandles[0], { consumer: toolSecrets, reason: 'repeat-b' });"
    , "const toolTrace = toolSecrets.traceAccess(agentToTool.secretHandles[0], provider, { context: { actor: { id: 'tool-operator' } } });"
    , "const toolAudit = toolSecrets.auditAccess(agentToTool.secretHandles[0], provider, { context: { actor: { id: 'tool-operator' } } });"
    , "const toolResolved = toolSecrets.resolve(agentToTool.secretHandles[0], provider);"
    , "let workflowRejected = null;"
    , "try {"
    , "  workflowSecrets.resolve(agentToTool.secretHandles[1], provider);"
    , "} catch (error) {"
    , "  workflowRejected = error.message;"
    , "}"
    , "const toolToWorkflow = toolSecrets.handoff(workflowSecrets, {"
    , "  reason: 'resume-workflow',"
    , "  secretHandles: [agentToTool.secretHandles[1]]"
    , "});"
    , "const workflowAccepted = workflowSecrets.handle(toolToWorkflow.secretHandles[0]);"
    , "const workflowResolved = workflowSecrets.resolve(toolToWorkflow.secretHandles[0], provider);"
    , "console.log(JSON.stringify({"
    , "  agentHandoffKind: agentToTool.kind,"
    , "  agentSecretNames: agentToTool.secretHandles.map((secretHandle) => secretHandle.name),"
    , "  agentDelegationTarget: `${agentToTool.secretHandles[0].target.kind}:${agentToTool.secretHandles[0].target.name}`,"
    , "  agentDelegated: agentToTool.secretHandles[0].kind === 'clasp-secret-delegation',"
    , "  agentHasRawValue: Object.prototype.hasOwnProperty.call(agentToTool.secretHandles[0], 'value'),"
    , "  agentRawValueLeaked: JSON.stringify(agentToTool).includes('sk-agent-live'),"
    , "  repeatDelegationIdsDistinct: repeatDelegationA.id !== repeatDelegationB.id,"
    , "  toolTraceDelegator: `${toolTrace.delegation.delegator.kind}:${toolTrace.delegation.delegator.name}`,"
    , "  toolTraceConsumer: `${toolTrace.consumer.kind}:${toolTrace.consumer.name}`,"
    , "  toolTraceBoundary: `${toolTrace.delegation.consumingBoundary.kind}:${toolTrace.delegation.consumingBoundary.name}`,"
    , "  toolAuditDelegatedAt: toolAudit.delegation.delegatedAt,"
    , "  toolAuditAttenuationAction: toolAudit.delegation.attenuation.action,"
    , "  toolAuditAttenuationTtl: toolAudit.delegation.attenuation.ttlMs,"
    , "  toolAuditAttenuationMaxUses: toolAudit.delegation.attenuation.maxUses,"
    , "  toolResolvedName: toolResolved.name,"
    , "  toolResolvedValue: toolResolved.reveal({ reason: 'tool-run' }),"
    , "  workflowRejected,"
    , "  workflowAcceptedName: workflowAccepted.name,"
    , "  workflowResolvedValue: workflowResolved.reveal({ reason: 'workflow-run' }),"
    , "  workflowTracePolicy: workflowResolved.trace.policy"
    , "}));"
    ]

promptInputSurfaceRuntimeScript :: FilePath -> Text
promptInputSurfaceRuntimeScript compiledPath =
  T.pack . unlines $
    [ "import * as compiledModule from " <> show ("file://" <> compiledPath) <> ";"
    , "const tool = compiledModule.__claspTools[0];"
    , "const secretBoundary = compiledModule.__claspSecretBoundaries.find((boundary) => boundary.kind === 'toolServer');"
    , "if (!tool || !secretBoundary) { throw new Error('missing prompt input surfaces'); }"
    , "const toolInput = tool.inputSurface({ query: compiledModule.replyPromptText }, { boundary: secretBoundary });"
    , "const promptInput = toolInput.promptSurface(compiledModule.replyPromptValue);"
    , "const secretHandle = toolInput.secretHandles[0];"
    , "let invalidHandle = null;"
    , "try {"
    , "  promptInput.resolveSecret('OPENAI_API_KEY', { OPENAI_API_KEY: 'sk-live-openai' });"
    , "} catch (error) {"
    , "  invalidHandle = error.message;"
    , "}"
    , "console.log(JSON.stringify({"
    , "  promptKind: promptInput.kind,"
    , "  promptText: promptInput.text,"
    , "  promptHandleName: promptInput.resolveSecret(secretHandle, { OPENAI_API_KEY: 'sk-live-openai' }).name,"
    , "  toolKind: toolInput.kind,"
    , "  toolHandleName: toolInput.resolveSecret(secretHandle, { OPENAI_API_KEY: 'sk-live-openai' }).name,"
    , "  toolMethod: toolInput.prepare('prompt-call-1').method,"
    , "  toolQuery: toolInput.prepare('prompt-call-1').params.query,"
    , "  invalidHandle"
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
    , "const decodedAudit = workerRuntime.schema('StandardAuditEnvelope').decodeJson(compiledModule.encodeAudit(compiledModule.defaultAudit));"
    , "console.log(JSON.stringify({"
    , "  contractVersion: contract.version,"
    , "  schemaNames: Object.keys(contract.schemas).sort(),"
    , "  sessionSchemaKind: contract.schemas.AuthSession?.schema?.kind ?? null,"
    , "  principalFieldType: contract.schemas.AuthSession?.schema?.fields?.principal?.schema?.name ?? null,"
    , "  tenantSeed: authSession.seed.tenant.id,"
    , "  workerActorType: decodedAudit.actor.actorType,"
    , "  workerActorId: decodedAudit.actor.actorId,"
    , "  workerActionType: decodedAudit.action.actionType,"
    , "  workerTimestamp: decodedAudit.timestamp,"
    , "  workerProvenanceSource: decodedAudit.provenance.source,"
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
shadowedImportMainSource :: Text
shadowedImportMainSource =
  T.unlines
    [ "module Main"
    , ""
    , "import Shared.Support"
    , ""
    , "render : Str -> Str"
    , "render declName = declName"
    , ""
    , "main : Str"
    , "main = render \"local\""
    ]

shadowedImportSupportSource :: Text
shadowedImportSupportSource =
  T.unlines
    [ "module Shared.Support"
    , ""
    , "declName : Int"
    , "declName = 7"
    ]
