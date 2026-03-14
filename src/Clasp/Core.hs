{-# LANGUAGE OverloadedStrings #-}

module Clasp.Core
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
  , CoreMergeGateDecl (..)
  , CoreMatchBranch (..)
  , CoreMetricDecl (..)
  , CoreModule (..)
  , CoreParam (..)
  , CorePolicyDecl (..)
  , CorePattern (..)
  , CorePatternBinder (..)
  , CoreProjectionDecl (..)
  , CoreRecordField (..)
  , CoreRolloutDecl (..)
  , CoreRouteContract (..)
  , CoreSupervisorDecl (..)
  , CoreToolDecl (..)
  , CoreToolServerDecl (..)
  , CoreVerifierDecl (..)
  , CoreWorkflowDecl (..)
  , SemanticEdit (..)
  , applySemanticEdit
  , coreExprType
  , renderCoreModule
  ) where

import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Clasp.Syntax
  ( AgentDecl (..)
  , AgentRoleDecl (..)
  , ConstructorDecl (..)
  , DomainEventDecl (..)
  , DomainObjectDecl (..)
  , ExperimentDecl (..)
  , FeedbackDecl (..)
  , ForeignDecl (..)
  , GoalDecl (..)
  , GuideDecl (..)
  , GuideEntryDecl (..)
  , HookDecl (..)
  , HookTriggerDecl (..)
  , MetricDecl (..)
  , MergeGateDecl (..)
  , MergeGateVerifierRef (..)
  , ModuleName
  , PolicyDecl (..)
  , PolicyClassificationDecl (..)
  , PolicyPermissionDecl (..)
  , PolicyPermissionKind (..)
  , ProjectionDecl (..)
  , ProjectionFieldDecl (..)
  , Position (..)
  , RecordDecl (..)
  , RecordFieldDecl (..)
  , RolloutDecl (..)
  , RouteBoundaryDecl (..)
  , RouteDecl (..)
  , RouteMethod (..)
  , RoutePathDecl
  , SourceSpan (..)
  , SupervisorChildDecl (..)
  , SupervisorDecl (..)
  , renderFeedbackKind
  , renderSupervisorRestartStrategy
  , ToolDecl (..)
  , ToolServerDecl (..)
  , Type (..)
  , TypeDecl (..)
  , VerifierDecl (..)
  , WorkflowDecl (..)
  , renderType
  , splitModuleName
  )
import Clasp.Diagnostic
  ( DiagnosticBundle
  , singleDiagnosticAt
  )

data CoreModule = CoreModule
  { coreModuleName :: ModuleName
  , coreModuleTypeDecls :: [TypeDecl]
  , coreModuleRecordDecls :: [RecordDecl]
  , coreModuleDomainObjectDecls :: [CoreDomainObjectDecl]
  , coreModuleDomainEventDecls :: [CoreDomainEventDecl]
  , coreModuleFeedbackDecls :: [CoreFeedbackDecl]
  , coreModuleMetricDecls :: [CoreMetricDecl]
  , coreModuleGoalDecls :: [CoreGoalDecl]
  , coreModuleExperimentDecls :: [CoreExperimentDecl]
  , coreModuleRolloutDecls :: [CoreRolloutDecl]
  , coreModuleWorkflowDecls :: [CoreWorkflowDecl]
  , coreModuleSupervisorDecls :: [CoreSupervisorDecl]
  , coreModuleGuideDecls :: [GuideDecl]
  , coreModuleHookDecls :: [CoreHookDecl]
  , coreModuleAgentRoleDecls :: [CoreAgentRoleDecl]
  , coreModuleAgentDecls :: [CoreAgentDecl]
  , coreModulePolicyDecls :: [CorePolicyDecl]
  , coreModuleToolServerDecls :: [CoreToolServerDecl]
  , coreModuleToolDecls :: [CoreToolDecl]
  , coreModuleVerifierDecls :: [CoreVerifierDecl]
  , coreModuleMergeGateDecls :: [CoreMergeGateDecl]
  , coreModuleProjectionDecls :: [CoreProjectionDecl]
  , coreModuleForeignDecls :: [ForeignDecl]
  , coreModuleRouteDecls :: [RouteDecl]
  , coreModuleDecls :: [CoreDecl]
  }
  deriving (Eq, Show)

data CorePolicyDecl = CorePolicyDecl
  { corePolicySourceDecl :: PolicyDecl
  }
  deriving (Eq, Show)

data CoreDomainObjectDecl = CoreDomainObjectDecl
  { coreDomainObjectSourceDecl :: DomainObjectDecl
  }
  deriving (Eq, Show)

data CoreDomainEventDecl = CoreDomainEventDecl
  { coreDomainEventSourceDecl :: DomainEventDecl
  }
  deriving (Eq, Show)

data CoreMetricDecl = CoreMetricDecl
  { coreMetricSourceDecl :: MetricDecl
  }
  deriving (Eq, Show)

data CoreFeedbackDecl = CoreFeedbackDecl
  { coreFeedbackSourceDecl :: FeedbackDecl
  }
  deriving (Eq, Show)

data CoreGoalDecl = CoreGoalDecl
  { coreGoalSourceDecl :: GoalDecl
  }
  deriving (Eq, Show)

data CoreExperimentDecl = CoreExperimentDecl
  { coreExperimentSourceDecl :: ExperimentDecl
  }
  deriving (Eq, Show)

data CoreRolloutDecl = CoreRolloutDecl
  { coreRolloutSourceDecl :: RolloutDecl
  }
  deriving (Eq, Show)

data CoreWorkflowDecl = CoreWorkflowDecl
  { coreWorkflowSourceDecl :: WorkflowDecl
  }
  deriving (Eq, Show)

data CoreSupervisorDecl = CoreSupervisorDecl
  { coreSupervisorSourceDecl :: SupervisorDecl
  }
  deriving (Eq, Show)

data CoreAgentRoleDecl = CoreAgentRoleDecl
  { coreAgentRoleSourceDecl :: AgentRoleDecl
  }
  deriving (Eq, Show)

data CoreAgentDecl = CoreAgentDecl
  { coreAgentSourceDecl :: AgentDecl
  }
  deriving (Eq, Show)

data CoreHookDecl = CoreHookDecl
  { coreHookSourceDecl :: HookDecl
  }
  deriving (Eq, Show)

data CoreToolServerDecl = CoreToolServerDecl
  { coreToolServerSourceDecl :: ToolServerDecl
  }
  deriving (Eq, Show)

data CoreToolDecl = CoreToolDecl
  { coreToolSourceDecl :: ToolDecl
  }
  deriving (Eq, Show)

data CoreVerifierDecl = CoreVerifierDecl
  { coreVerifierSourceDecl :: VerifierDecl
  }
  deriving (Eq, Show)

data CoreMergeGateDecl = CoreMergeGateDecl
  { coreMergeGateSourceDecl :: MergeGateDecl
  }
  deriving (Eq, Show)

data CoreProjectionDecl = CoreProjectionDecl
  { coreProjectionSourceDecl :: ProjectionDecl
  , coreProjectionRecordDecl :: RecordDecl
  }
  deriving (Eq, Show)

data CoreDecl = CoreDecl
  { coreDeclName :: Text
  , coreDeclType :: Type
  , coreDeclParams :: [CoreParam]
  , coreDeclBody :: CoreExpr
  }
  deriving (Eq, Show)

data CoreParam = CoreParam
  { coreParamName :: Text
  , coreParamType :: Type
  }
  deriving (Eq, Show)

data CorePatternBinder = CorePatternBinder
  { corePatternBinderName :: Text
  , corePatternBinderSpan :: SourceSpan
  , corePatternBinderType :: Type
  }
  deriving (Eq, Show)

data CorePattern = CConstructorPattern SourceSpan Text [CorePatternBinder]
  deriving (Eq, Show)

data CoreMatchBranch = CoreMatchBranch
  { coreMatchBranchSpan :: SourceSpan
  , coreMatchBranchPattern :: CorePattern
  , coreMatchBranchBody :: CoreExpr
  }
  deriving (Eq, Show)

data CoreRecordField = CoreRecordField
  { coreRecordFieldName :: Text
  , coreRecordFieldValue :: CoreExpr
  }
  deriving (Eq, Show)

data CoreRouteContract = CoreRouteContract
  { coreRouteContractName :: Text
  , coreRouteContractIdentity :: Text
  , coreRouteContractMethod :: Text
  , coreRouteContractPath :: Text
  , coreRouteContractPathDecl :: RoutePathDecl
  , coreRouteContractRequestType :: Text
  , coreRouteContractQueryDecl :: Maybe RouteBoundaryDecl
  , coreRouteContractFormDecl :: Maybe RouteBoundaryDecl
  , coreRouteContractBodyDecl :: Maybe RouteBoundaryDecl
  , coreRouteContractResponseType :: Text
  , coreRouteContractResponseDecl :: RouteBoundaryDecl
  , coreRouteContractResponseKind :: Text
  }
  deriving (Eq, Show)

data CoreExpr
  = CVar SourceSpan Type Text
  | CInt SourceSpan Integer
  | CString SourceSpan Text
  | CBool SourceSpan Bool
  | CList SourceSpan Type [CoreExpr]
  | CReturn SourceSpan Type CoreExpr
  | CEqual SourceSpan CoreExpr CoreExpr
  | CNotEqual SourceSpan CoreExpr CoreExpr
  | CLessThan SourceSpan CoreExpr CoreExpr
  | CLessThanOrEqual SourceSpan CoreExpr CoreExpr
  | CGreaterThan SourceSpan CoreExpr CoreExpr
  | CGreaterThanOrEqual SourceSpan CoreExpr CoreExpr
  | CLet SourceSpan Type Text CoreExpr CoreExpr
  | CMutableLet SourceSpan Type Text CoreExpr CoreExpr
  | CAssign SourceSpan Type Text CoreExpr CoreExpr
  | CFor SourceSpan Type Text CoreExpr CoreExpr CoreExpr
  | CPage SourceSpan CoreExpr CoreExpr
  | CRedirect SourceSpan Text
  | CViewEmpty SourceSpan
  | CViewText SourceSpan CoreExpr
  | CViewAppend SourceSpan CoreExpr CoreExpr
  | CViewElement SourceSpan Text CoreExpr
  | CViewStyled SourceSpan Text CoreExpr
  | CViewLink SourceSpan CoreRouteContract Text CoreExpr
  | CViewForm SourceSpan CoreRouteContract Text Text CoreExpr
  | CViewInput SourceSpan Text Text CoreExpr
  | CViewSubmit SourceSpan CoreExpr
  | CPromptMessage SourceSpan Text CoreExpr
  | CPromptAppend SourceSpan CoreExpr CoreExpr
  | CPromptText SourceSpan CoreExpr
  | CCall SourceSpan Type CoreExpr [CoreExpr]
  | CMatch SourceSpan Type CoreExpr [CoreMatchBranch]
  | CRecord SourceSpan Type Text [CoreRecordField]
  | CFieldAccess SourceSpan Type CoreExpr Text
  | CDecodeJson SourceSpan Type CoreExpr
  | CEncodeJson SourceSpan CoreExpr
  deriving (Eq, Show)

data SemanticEdit
  = RenameDecl Text Text
  | RenameSchema Text Text
  deriving (Eq, Show)

renderCoreModule :: CoreModule -> Text
renderCoreModule modl =
  T.intercalate
    "\n\n"
    ([ "module " <> renderModuleName (coreModuleName modl)
     ]
       <> fmap renderSection (filter (not . null) topLevelSections)
    )
  where
    topLevelSections =
      [ fmap renderTypeDecl (coreModuleTypeDecls modl)
      , fmap renderRecordDecl (coreModuleRecordDecls modl)
      , fmap renderDomainObjectDecl (coreModuleDomainObjectDecls modl)
      , fmap renderDomainEventDecl (coreModuleDomainEventDecls modl)
      , fmap renderFeedbackDecl (coreModuleFeedbackDecls modl)
      , fmap renderMetricDecl (coreModuleMetricDecls modl)
      , fmap renderGoalDecl (coreModuleGoalDecls modl)
      , fmap renderExperimentDecl (coreModuleExperimentDecls modl)
      , fmap renderRolloutDecl (coreModuleRolloutDecls modl)
      , fmap renderWorkflowDecl (coreModuleWorkflowDecls modl)
      , fmap renderSupervisorDecl (coreModuleSupervisorDecls modl)
      , fmap renderGuideDecl (coreModuleGuideDecls modl)
      , fmap renderHookDecl (coreModuleHookDecls modl)
      , fmap renderAgentRoleDecl (coreModuleAgentRoleDecls modl)
      , fmap renderAgentDecl (coreModuleAgentDecls modl)
      , fmap renderPolicyDecl (coreModulePolicyDecls modl)
      , fmap renderToolServerDecl (coreModuleToolServerDecls modl)
      , fmap renderToolDecl (coreModuleToolDecls modl)
      , fmap renderVerifierDecl (coreModuleVerifierDecls modl)
      , fmap renderMergeGateDecl (coreModuleMergeGateDecls modl)
      , fmap renderProjectionDecl (coreModuleProjectionDecls modl)
      , fmap renderForeignDecl (coreModuleForeignDecls modl)
      , fmap renderRouteDecl (coreModuleRouteDecls modl)
      , fmap renderCoreDecl (coreModuleDecls modl)
      ]

renderModuleName :: ModuleName -> Text
renderModuleName = T.intercalate "." . splitModuleName

renderSection :: [Text] -> Text
renderSection =
  T.intercalate "\n"

renderTypeDecl :: TypeDecl -> Text
renderTypeDecl typeDecl =
  "type "
    <> typeDeclName typeDecl
    <> " = "
    <> T.intercalate " | " (fmap renderConstructorDecl (typeDeclConstructors typeDecl))

renderConstructorDecl :: ConstructorDecl -> Text
renderConstructorDecl constructorDecl =
  T.unwords (constructorDeclName constructorDecl : fmap renderAtomicType (constructorDeclFields constructorDecl))

renderRecordDecl :: RecordDecl -> Text
renderRecordDecl recordDecl =
  "record "
    <> recordDeclName recordDecl
    <> " = "
    <> renderBracedInline (fmap renderRecordFieldDecl (recordDeclFields recordDecl))

renderDomainObjectDecl :: CoreDomainObjectDecl -> Text
renderDomainObjectDecl (CoreDomainObjectDecl domainObjectDecl) =
  "domain object "
    <> domainObjectDeclName domainObjectDecl
    <> " = "
    <> domainObjectDeclSchemaName domainObjectDecl

renderDomainEventDecl :: CoreDomainEventDecl -> Text
renderDomainEventDecl (CoreDomainEventDecl domainEventDecl) =
  "domain event "
    <> domainEventDeclName domainEventDecl
    <> " = "
    <> domainEventDeclSchemaName domainEventDecl
    <> " for "
    <> domainEventDeclObjectName domainEventDecl

renderMetricDecl :: CoreMetricDecl -> Text
renderMetricDecl (CoreMetricDecl metricDecl) =
  "metric "
    <> metricDeclName metricDecl
    <> " = "
    <> metricDeclSchemaName metricDecl
    <> " for "
    <> metricDeclObjectName metricDecl

renderFeedbackDecl :: CoreFeedbackDecl -> Text
renderFeedbackDecl (CoreFeedbackDecl feedbackDecl) =
  "feedback "
    <> renderFeedbackKind (feedbackDeclKind feedbackDecl)
    <> " "
    <> feedbackDeclName feedbackDecl
    <> " = "
    <> feedbackDeclSchemaName feedbackDecl
    <> " for "
    <> feedbackDeclObjectName feedbackDecl

renderGoalDecl :: CoreGoalDecl -> Text
renderGoalDecl (CoreGoalDecl goalDecl) =
  "goal "
    <> goalDeclName goalDecl
    <> " = "
    <> goalDeclMetricName goalDecl

renderExperimentDecl :: CoreExperimentDecl -> Text
renderExperimentDecl (CoreExperimentDecl experimentDecl) =
  "experiment "
    <> experimentDeclName experimentDecl
    <> " = "
    <> experimentDeclGoalName experimentDecl

renderRolloutDecl :: CoreRolloutDecl -> Text
renderRolloutDecl (CoreRolloutDecl rolloutDecl) =
  "rollout "
    <> rolloutDeclName rolloutDecl
    <> " = "
    <> rolloutDeclExperimentName rolloutDecl

renderWorkflowDecl :: CoreWorkflowDecl -> Text
renderWorkflowDecl workflowDecl =
  "workflow "
    <> workflowDeclName sourceDecl
    <> " = "
    <> renderBracedInline
      ( [ "state: " <> renderType (workflowDeclStateType sourceDecl)
        ]
          <> maybe [] (\name -> ["invariant: " <> name]) (workflowDeclInvariantName sourceDecl)
          <> maybe [] (\name -> ["precondition: " <> name]) (workflowDeclPreconditionName sourceDecl)
          <> maybe [] (\name -> ["postcondition: " <> name]) (workflowDeclPostconditionName sourceDecl)
      )
  where
    sourceDecl = coreWorkflowSourceDecl workflowDecl

renderSupervisorDecl :: CoreSupervisorDecl -> Text
renderSupervisorDecl supervisorDecl =
  "supervisor "
    <> supervisorDeclName sourceDecl
    <> " = "
    <> renderSupervisorRestartStrategy (supervisorDeclRestartStrategy sourceDecl)
    <> " "
    <> renderBracedInline (fmap renderSupervisorChildDecl (supervisorDeclChildren sourceDecl))
  where
    sourceDecl = coreSupervisorSourceDecl supervisorDecl

renderSupervisorChildDecl :: SupervisorChildDecl -> Text
renderSupervisorChildDecl childDecl =
  case childDecl of
    SupervisorWorkflowChild {supervisorChildName = childName} ->
      "workflow " <> childName
    SupervisorSupervisorChild {supervisorChildName = childName} ->
      "supervisor " <> childName

renderRecordFieldDecl :: RecordFieldDecl -> Text
renderRecordFieldDecl fieldDecl =
  recordFieldDeclName fieldDecl
    <> ": "
    <> renderType (recordFieldDeclType fieldDecl)

renderGuideDecl :: GuideDecl -> Text
renderGuideDecl guideDecl =
  "guide "
    <> guideDeclName guideDecl
    <> maybe "" (" extends " <>) (guideDeclExtends guideDecl)
    <> " = "
    <> renderBracedInline (fmap renderGuideEntryDecl (guideDeclEntries guideDecl))

renderGuideEntryDecl :: GuideEntryDecl -> Text
renderGuideEntryDecl entryDecl =
  guideEntryDeclName entryDecl
    <> ": "
    <> renderStringLiteral (guideEntryDeclValue entryDecl)

renderHookDecl :: CoreHookDecl -> Text
renderHookDecl (CoreHookDecl hookDecl) =
  "hook "
    <> hookDeclName hookDecl
    <> " = "
    <> renderStringLiteral (hookTriggerDeclEvent (hookDeclTrigger hookDecl))
    <> " "
    <> hookDeclRequestType hookDecl
    <> " -> "
    <> hookDeclResponseType hookDecl
    <> " "
    <> hookDeclHandlerName hookDecl

renderAgentRoleDecl :: CoreAgentRoleDecl -> Text
renderAgentRoleDecl (CoreAgentRoleDecl roleDecl) =
  "role "
    <> agentRoleDeclName roleDecl
    <> " = guide: "
    <> agentRoleDeclGuideName roleDecl
    <> ", policy: "
    <> agentRoleDeclPolicyName roleDecl

renderAgentDecl :: CoreAgentDecl -> Text
renderAgentDecl (CoreAgentDecl agentDecl) =
  "agent " <> agentDeclName agentDecl <> " = " <> agentDeclRoleName agentDecl

renderPolicyDecl :: CorePolicyDecl -> Text
renderPolicyDecl (CorePolicyDecl policyDecl) =
  "policy "
    <> policyDeclName policyDecl
    <> " = "
    <> T.intercalate ", " (fmap policyClassificationDeclName (policyDeclAllowedClassifications policyDecl))
    <> renderPolicyPermissionsSuffix (policyDeclPermissions policyDecl)

renderPolicyPermissionsSuffix :: [PolicyPermissionDecl] -> Text
renderPolicyPermissionsSuffix [] = ""
renderPolicyPermissionsSuffix permissions =
  " permits " <> renderBracedInline (fmap renderPolicyPermissionDecl permissions)

renderPolicyPermissionDecl :: PolicyPermissionDecl -> Text
renderPolicyPermissionDecl permissionDecl =
  renderPolicyPermissionKind (policyPermissionDeclKind permissionDecl)
    <> " "
    <> renderStringLiteral (policyPermissionDeclValue permissionDecl)

renderPolicyPermissionKind :: PolicyPermissionKind -> Text
renderPolicyPermissionKind permissionKind =
  case permissionKind of
    PolicyPermissionFile -> "file"
    PolicyPermissionNetwork -> "network"
    PolicyPermissionProcess -> "process"
    PolicyPermissionSecret -> "secret"

renderToolServerDecl :: CoreToolServerDecl -> Text
renderToolServerDecl (CoreToolServerDecl toolServerDecl) =
  "toolserver "
    <> toolServerDeclName toolServerDecl
    <> " = "
    <> renderStringLiteral (toolServerDeclProtocol toolServerDecl)
    <> " "
    <> renderStringLiteral (toolServerDeclLocation toolServerDecl)
    <> " with "
    <> toolServerDeclPolicyName toolServerDecl

renderToolDecl :: CoreToolDecl -> Text
renderToolDecl (CoreToolDecl toolDecl) =
  "tool "
    <> toolDeclName toolDecl
    <> " = "
    <> toolDeclServerName toolDecl
    <> " "
    <> renderStringLiteral (toolDeclOperation toolDecl)
    <> " "
    <> toolDeclRequestType toolDecl
    <> " -> "
    <> toolDeclResponseType toolDecl

renderVerifierDecl :: CoreVerifierDecl -> Text
renderVerifierDecl (CoreVerifierDecl verifierDecl) =
  "verifier " <> verifierDeclName verifierDecl <> " = " <> verifierDeclToolName verifierDecl

renderMergeGateDecl :: CoreMergeGateDecl -> Text
renderMergeGateDecl (CoreMergeGateDecl mergeGateDecl) =
  "mergegate "
    <> mergeGateDeclName mergeGateDecl
    <> " = "
    <> T.intercalate ", " (fmap mergeGateVerifierRefName (mergeGateDeclVerifierRefs mergeGateDecl))

renderProjectionDecl :: CoreProjectionDecl -> Text
renderProjectionDecl coreProjectionDecl =
  let projectionDecl = coreProjectionSourceDecl coreProjectionDecl
   in "projection "
        <> projectionDeclName projectionDecl
        <> " = "
        <> projectionDeclSourceRecordName projectionDecl
        <> " with "
        <> projectionDeclPolicyName projectionDecl
        <> " "
        <> renderBracedInline (fmap projectionFieldDeclName (projectionDeclFields projectionDecl))

renderForeignDecl :: ForeignDecl -> Text
renderForeignDecl foreignDecl =
  "foreign "
    <> (if foreignDeclUnsafeInterop foreignDecl then "unsafe " else "")
    <> foreignDeclName foreignDecl
    <> " : "
    <> renderType (foreignDeclType foreignDecl)
    <> " = "
    <> renderStringLiteral (foreignDeclRuntimeName foreignDecl)

renderRouteDecl :: RouteDecl -> Text
renderRouteDecl routeDecl =
  "route "
    <> routeDeclName routeDecl
    <> " = "
    <> renderRouteMethod (routeDeclMethod routeDecl)
    <> " "
    <> renderStringLiteral (routeDeclPath routeDecl)
    <> " "
    <> routeDeclRequestType routeDecl
    <> " -> "
    <> routeDeclResponseType routeDecl
    <> " "
    <> routeDeclHandlerName routeDecl

renderRouteMethod :: RouteMethod -> Text
renderRouteMethod routeMethod =
  case routeMethod of
    RouteGet -> "GET"
    RoutePost -> "POST"

renderCoreDecl :: CoreDecl -> Text
renderCoreDecl coreDecl =
  T.intercalate
    "\n"
    [ coreDeclName coreDecl <> " : " <> renderType (coreDeclType coreDecl)
    , renderCoreDeclHead coreDecl <> " = " <> renderCoreExpr 0 (coreDeclBody coreDecl)
    ]

renderCoreDeclHead :: CoreDecl -> Text
renderCoreDeclHead coreDecl =
  case coreDeclParams coreDecl of
    [] ->
      coreDeclName coreDecl
    params ->
      T.unwords (coreDeclName coreDecl : fmap renderCoreParam params)

renderCoreParam :: CoreParam -> Text
renderCoreParam param =
  "(" <> coreParamName param <> " : " <> renderType (coreParamType param) <> ")"

renderCoreExpr :: Int -> CoreExpr -> Text
renderCoreExpr parentPrecedence expr =
  case expr of
    CVar _ typ name ->
      renderTypedAtom name typ
    CInt _ value ->
      renderTypedAtom (T.pack (show value)) TInt
    CString _ value ->
      renderTypedAtom (renderStringLiteral value) TStr
    CBool _ value ->
      renderTypedAtom (if value then "true" else "false") TBool
    CList _ typ values ->
      renderTypedAtom ("[" <> T.intercalate ", " (fmap (renderCoreExpr 0) values) <> "]") typ
    CReturn _ typ value ->
      renderTypedExpr parentPrecedence 0 ("return " <> renderCoreExpr 1 value) typ
    CEqual _ left right ->
      renderTypedExpr parentPrecedence 1 (renderBinaryExpr 1 "==" left right) TBool
    CNotEqual _ left right ->
      renderTypedExpr parentPrecedence 1 (renderBinaryExpr 1 "!=" left right) TBool
    CLessThan _ left right ->
      renderTypedExpr parentPrecedence 1 (renderBinaryExpr 2 "<" left right) TBool
    CLessThanOrEqual _ left right ->
      renderTypedExpr parentPrecedence 1 (renderBinaryExpr 2 "<=" left right) TBool
    CGreaterThan _ left right ->
      renderTypedExpr parentPrecedence 1 (renderBinaryExpr 2 ">" left right) TBool
    CGreaterThanOrEqual _ left right ->
      renderTypedExpr parentPrecedence 1 (renderBinaryExpr 2 ">=" left right) TBool
    CLet _ typ name value body ->
      renderTypedExpr parentPrecedence 0 ("let " <> name <> " : " <> renderType (coreExprType value) <> " = " <> renderCoreExpr 0 value <> " in " <> renderCoreExpr 0 body) typ
    CMutableLet _ typ name value body ->
      renderTypedExpr parentPrecedence 0 ("let mut " <> name <> " : " <> renderType (coreExprType value) <> " = " <> renderCoreExpr 0 value <> " in " <> renderCoreExpr 0 body) typ
    CAssign _ typ name value body ->
      renderTypedExpr parentPrecedence 0 ("let " <> name <> " := " <> renderCoreExpr 0 value <> " in " <> renderCoreExpr 0 body) typ
    CFor _ typ name iterable loopBody body ->
      renderTypedExpr parentPrecedence 0 ("for " <> name <> " in " <> renderCoreExpr 0 iterable <> " do " <> renderCoreExpr 0 loopBody <> " then " <> renderCoreExpr 0 body) typ
    CPage _ title body ->
      renderTypedAtom ("page " <> renderCoreExpr 4 title <> " " <> renderCoreExpr 4 body) (TNamed "Page")
    CRedirect _ path ->
      renderTypedAtom ("redirect " <> renderStringLiteral path) (TNamed "Redirect")
    CViewEmpty _ ->
      renderTypedAtom "emptyView" (TNamed "View")
    CViewText _ value ->
      renderTypedAtom ("text " <> renderCoreExpr 4 value) (TNamed "View")
    CViewAppend _ left right ->
      renderTypedAtom ("append " <> renderCoreExpr 4 left <> " " <> renderCoreExpr 4 right) (TNamed "View")
    CViewElement _ tag child ->
      renderTypedAtom ("element " <> renderStringLiteral tag <> " " <> renderCoreExpr 4 child) (TNamed "View")
    CViewStyled _ styleRef child ->
      renderTypedAtom ("styled " <> renderStringLiteral styleRef <> " " <> renderCoreExpr 4 child) (TNamed "View")
    CViewLink _ route href child ->
      renderTypedAtom ("link " <> renderStringLiteral (coreRouteContractName route) <> " " <> renderStringLiteral href <> " " <> renderCoreExpr 4 child) (TNamed "View")
    CViewForm _ route method action child ->
      renderTypedAtom ("form " <> renderStringLiteral (coreRouteContractName route) <> " " <> renderStringLiteral method <> " " <> renderStringLiteral action <> " " <> renderCoreExpr 4 child) (TNamed "View")
    CViewInput _ fieldName inputKind value ->
      renderTypedAtom ("input " <> renderStringLiteral fieldName <> " " <> renderStringLiteral inputKind <> " " <> renderCoreExpr 4 value) (TNamed "View")
    CViewSubmit _ label ->
      renderTypedAtom ("submit " <> renderCoreExpr 4 label) (TNamed "View")
    CPromptMessage _ role content ->
      renderTypedAtom (role <> "Prompt " <> renderCoreExpr 4 content) (TNamed "Prompt")
    CPromptAppend _ left right ->
      renderTypedAtom ("appendPrompt " <> renderCoreExpr 4 left <> " " <> renderCoreExpr 4 right) (TNamed "Prompt")
    CPromptText _ promptExpr ->
      renderTypedAtom ("promptText " <> renderCoreExpr 4 promptExpr) TStr
    CCall _ typ fn args ->
      renderTypedExpr parentPrecedence 3 (T.unwords (renderCoreExpr 3 fn : fmap (renderCoreExpr 4) args)) typ
    CMatch _ typ subject branches ->
      renderTypedExpr parentPrecedence 0 ("match " <> renderCoreExpr 0 subject <> " " <> renderBracedCommaBlock (fmap renderCoreMatchBranch branches)) typ
    CRecord _ typ recordName fields ->
      renderTypedAtom (recordName <> renderBracedInline (fmap renderCoreRecordField fields)) typ
    CFieldAccess _ typ subject fieldName ->
      renderTypedExpr parentPrecedence 4 (renderCoreExpr 4 subject <> "." <> fieldName) typ
    CDecodeJson _ typ rawJson ->
      renderTypedExpr parentPrecedence 4 ("decode " <> renderAtomicType typ <> " " <> renderCoreExpr 4 rawJson) typ
    CEncodeJson _ value ->
      renderTypedAtom ("encode " <> renderCoreExpr 4 value) TStr

renderBinaryExpr :: Int -> Text -> CoreExpr -> CoreExpr -> Text
renderBinaryExpr precedence operator left right =
  renderCoreExpr precedence left
    <> " "
    <> operator
    <> " "
    <> renderCoreExpr precedence right

renderTypedAtom :: Text -> Type -> Text
renderTypedAtom rendered typ =
  "(" <> rendered <> " : " <> renderType typ <> ")"

renderTypedExpr :: Int -> Int -> Text -> Type -> Text
renderTypedExpr parentPrecedence exprPrecedence rendered typ =
  renderTypedAtom (renderWithParensIfNeeded parentPrecedence exprPrecedence rendered) typ

renderCoreMatchBranch :: CoreMatchBranch -> Text
renderCoreMatchBranch branch =
  renderCorePattern (coreMatchBranchPattern branch) <> " -> " <> renderCoreExpr 0 (coreMatchBranchBody branch)

renderCorePattern :: CorePattern -> Text
renderCorePattern pattern' =
  case pattern' of
    CConstructorPattern _ constructorName binders ->
      T.unwords (constructorName : fmap renderCorePatternBinder binders)

renderCorePatternBinder :: CorePatternBinder -> Text
renderCorePatternBinder binder =
  "(" <> corePatternBinderName binder <> " : " <> renderType (corePatternBinderType binder) <> ")"

renderCoreRecordField :: CoreRecordField -> Text
renderCoreRecordField field =
  coreRecordFieldName field <> " = " <> renderCoreExpr 0 (coreRecordFieldValue field)

renderAtomicType :: Type -> Text
renderAtomicType typ =
  case typ of
    TFunction _ _ ->
      "(" <> renderType typ <> ")"
    _ ->
      renderType typ

renderBracedInline :: [Text] -> Text
renderBracedInline entries =
  "{"
    <> ( if null entries
           then ""
           else " " <> T.intercalate ", " entries <> " "
       )
    <> "}"

renderBracedCommaBlock :: [Text] -> Text
renderBracedCommaBlock entries =
  "{\n"
    <> T.intercalate "\n" (fmap (indentText 2) (commaSeparate entries))
    <> "\n}"
  where
    commaSeparate [] = []
    commaSeparate [entry] = [entry]
    commaSeparate (entry : rest) = (entry <> ",") : commaSeparate rest

indentText :: Int -> Text -> Text
indentText spaces =
  T.intercalate "\n" . fmap ((T.replicate spaces " ") <>) . T.lines

renderWithParensIfNeeded :: Int -> Int -> Text -> Text
renderWithParensIfNeeded parentPrecedence exprPrecedence rendered
  | parentPrecedence > exprPrecedence = "(" <> rendered <> ")"
  | otherwise = rendered

renderStringLiteral :: Text -> Text
renderStringLiteral value =
  "\"" <> T.concatMap escapeChar value <> "\""
  where
    escapeChar '"' = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\n' = "\\n"
    escapeChar '\t' = "\\t"
    escapeChar '\r' = "\\r"
    escapeChar char = T.singleton char

coreExprType :: CoreExpr -> Type
coreExprType expr =
  case expr of
    CVar _ typ _ ->
      typ
    CInt _ _ ->
      TInt
    CString _ _ ->
      TStr
    CBool _ _ ->
      TBool
    CList _ typ _ ->
      typ
    CReturn _ typ _ ->
      typ
    CEqual _ _ _ ->
      TBool
    CNotEqual _ _ _ ->
      TBool
    CLessThan _ _ _ ->
      TBool
    CLessThanOrEqual _ _ _ ->
      TBool
    CGreaterThan _ _ _ ->
      TBool
    CGreaterThanOrEqual _ _ _ ->
      TBool
    CLet _ typ _ _ _ ->
      typ
    CMutableLet _ typ _ _ _ ->
      typ
    CAssign _ typ _ _ _ ->
      typ
    CFor _ typ _ _ _ _ ->
      typ
    CPage _ _ _ ->
      TNamed "Page"
    CRedirect _ _ ->
      TNamed "Redirect"
    CViewEmpty _ ->
      TNamed "View"
    CViewText _ _ ->
      TNamed "View"
    CViewAppend _ _ _ ->
      TNamed "View"
    CViewElement _ _ _ ->
      TNamed "View"
    CViewStyled _ _ _ ->
      TNamed "View"
    CViewLink _ _ _ _ ->
      TNamed "View"
    CViewForm _ _ _ _ _ ->
      TNamed "View"
    CViewInput _ _ _ _ ->
      TNamed "View"
    CViewSubmit _ _ ->
      TNamed "View"
    CPromptMessage _ _ _ ->
      TNamed "Prompt"
    CPromptAppend _ _ _ ->
      TNamed "Prompt"
    CPromptText _ _ ->
      TStr
    CCall _ typ _ _ ->
      typ
    CMatch _ typ _ _ ->
      typ
    CRecord _ typ _ _ ->
      typ
    CFieldAccess _ typ _ _ ->
      typ
    CDecodeJson _ typ _ ->
      typ
    CEncodeJson _ _ ->
      TStr

applySemanticEdit :: SemanticEdit -> CoreModule -> Either DiagnosticBundle CoreModule
applySemanticEdit edit modl =
  case edit of
    RenameDecl oldName newName ->
      renameDecl oldName newName modl
    RenameSchema oldName newName ->
      renameSchema oldName newName modl

renameDecl :: Text -> Text -> CoreModule -> Either DiagnosticBundle CoreModule
renameDecl oldName newName modl
  | oldName == newName =
      Right modl
  | not (any ((== oldName) . coreDeclName) (coreModuleDecls modl)) =
      Left (singleDiagnosticAt "E_SEMANTIC_EDIT_TARGET" ("Unknown declaration `" <> oldName <> "`.") builtinEditSpan [])
  | any ((== newName) . coreDeclName) (coreModuleDecls modl) =
      Left (singleDiagnosticAt "E_SEMANTIC_EDIT_CONFLICT" ("Declaration `" <> newName <> "` already exists.") builtinEditSpan [])
  | otherwise =
      Right
        modl
          { coreModuleRouteDecls = fmap renameRouteDeclHandler (coreModuleRouteDecls modl)
          , coreModuleDecls = fmap renameCoreDecl (coreModuleDecls modl)
          }
  where
    renameRouteDeclHandler routeDecl
      | routeDeclHandlerName routeDecl == oldName =
          routeDecl {routeDeclHandlerName = newName}
      | otherwise =
          routeDecl

    renameCoreDecl decl =
      decl
        { coreDeclName = renameIfEqual oldName newName (coreDeclName decl)
        , coreDeclBody = renameDeclExpr (Set.fromList (fmap coreParamName (coreDeclParams decl))) (coreDeclBody decl)
        }

    renameDeclExpr boundNames expr =
      case expr of
        CVar span' typ name
          | name == oldName && not (Set.member name boundNames) ->
              CVar span' typ newName
          | otherwise ->
              expr
        CPage span' title body ->
          CPage span' (renameDeclExpr boundNames title) (renameDeclExpr boundNames body)
        CViewText span' body ->
          CViewText span' (renameDeclExpr boundNames body)
        CViewAppend span' left right ->
          CViewAppend span' (renameDeclExpr boundNames left) (renameDeclExpr boundNames right)
        CViewElement span' tag body ->
          CViewElement span' tag (renameDeclExpr boundNames body)
        CViewStyled span' styleRef body ->
          CViewStyled span' styleRef (renameDeclExpr boundNames body)
        CViewLink span' contract href body ->
          CViewLink span' contract href (renameDeclExpr boundNames body)
        CViewForm span' contract method action body ->
          CViewForm span' contract method action (renameDeclExpr boundNames body)
        CViewInput span' fieldName inputKind body ->
          CViewInput span' fieldName inputKind (renameDeclExpr boundNames body)
        CViewSubmit span' body ->
          CViewSubmit span' (renameDeclExpr boundNames body)
        CPromptMessage span' role content ->
          CPromptMessage span' role (renameDeclExpr boundNames content)
        CPromptAppend span' left right ->
          CPromptAppend span' (renameDeclExpr boundNames left) (renameDeclExpr boundNames right)
        CPromptText span' promptExpr ->
          CPromptText span' (renameDeclExpr boundNames promptExpr)
        CList span' typ items ->
          CList span' typ (fmap (renameDeclExpr boundNames) items)
        CEqual span' left right ->
          CEqual span' (renameDeclExpr boundNames left) (renameDeclExpr boundNames right)
        CNotEqual span' left right ->
          CNotEqual span' (renameDeclExpr boundNames left) (renameDeclExpr boundNames right)
        CLessThan span' left right ->
          CLessThan span' (renameDeclExpr boundNames left) (renameDeclExpr boundNames right)
        CLessThanOrEqual span' left right ->
          CLessThanOrEqual span' (renameDeclExpr boundNames left) (renameDeclExpr boundNames right)
        CGreaterThan span' left right ->
          CGreaterThan span' (renameDeclExpr boundNames left) (renameDeclExpr boundNames right)
        CGreaterThanOrEqual span' left right ->
          CGreaterThanOrEqual span' (renameDeclExpr boundNames left) (renameDeclExpr boundNames right)
        CLet span' typ name value body ->
          CLet span' typ name (renameDeclExpr boundNames value) (renameDeclExpr (Set.insert name boundNames) body)
        CMutableLet span' typ name value body ->
          CMutableLet span' typ name (renameDeclExpr boundNames value) (renameDeclExpr (Set.insert name boundNames) body)
        CAssign span' typ name value body ->
          CAssign span' typ name (renameDeclExpr boundNames value) (renameDeclExpr boundNames body)
        CFor span' typ name iterable loopBody body ->
          CFor
            span'
            typ
            name
            (renameDeclExpr boundNames iterable)
            (renameDeclExpr (Set.insert name boundNames) loopBody)
            (renameDeclExpr boundNames body)
        CCall span' typ fn args ->
          CCall span' typ (renameDeclExpr boundNames fn) (fmap (renameDeclExpr boundNames) args)
        CMatch span' typ subject branches ->
          CMatch span' typ (renameDeclExpr boundNames subject) (fmap (renameDeclBranch boundNames) branches)
        CRecord span' typ recordName fields ->
          CRecord span' typ recordName (fmap (renameRecordField boundNames) fields)
        CFieldAccess span' typ recordExpr fieldName ->
          CFieldAccess span' typ (renameDeclExpr boundNames recordExpr) fieldName
        CDecodeJson span' typ rawJson ->
          CDecodeJson span' typ (renameDeclExpr boundNames rawJson)
        CEncodeJson span' value ->
          CEncodeJson span' (renameDeclExpr boundNames value)
        _ ->
          expr

    renameDeclBranch boundNames branch =
      branch
        { coreMatchBranchBody = renameDeclExpr nextBoundNames (coreMatchBranchBody branch)
        }
      where
        nextBoundNames =
          case coreMatchBranchPattern branch of
            CConstructorPattern _ _ binders ->
              Set.union boundNames (Set.fromList (fmap corePatternBinderName binders))

    renameRecordField boundNames field =
      field
        { coreRecordFieldValue = renameDeclExpr boundNames (coreRecordFieldValue field)
        }

renameSchema :: Text -> Text -> CoreModule -> Either DiagnosticBundle CoreModule
renameSchema oldName newName modl
  | oldName == newName =
      Right modl
  | oldName `elem` builtinSchemaNames =
      Left (singleDiagnosticAt "E_SEMANTIC_EDIT_CONFLICT" ("Schema `" <> oldName <> "` is compiler-known and cannot be renamed.") builtinEditSpan [])
  | not (schemaNameExists oldName modl) =
      Left (singleDiagnosticAt "E_SEMANTIC_EDIT_TARGET" ("Unknown schema `" <> oldName <> "`.") builtinEditSpan [])
  | schemaNameExists newName modl || newName `elem` builtinSchemaNames =
      Left (singleDiagnosticAt "E_SEMANTIC_EDIT_CONFLICT" ("Schema `" <> newName <> "` already exists.") builtinEditSpan [])
  | otherwise =
      Right
        modl
          { coreModuleTypeDecls = fmap renameTypeDecl (coreModuleTypeDecls modl)
          , coreModuleRecordDecls = fmap renameRecordDecl (coreModuleRecordDecls modl)
          , coreModuleWorkflowDecls = fmap renameWorkflowDecl (coreModuleWorkflowDecls modl)
          , coreModuleHookDecls = fmap renameHookDecl (coreModuleHookDecls modl)
          , coreModuleProjectionDecls = fmap renameProjectionDecl (coreModuleProjectionDecls modl)
          , coreModuleToolDecls = fmap renameToolDecl (coreModuleToolDecls modl)
          , coreModuleForeignDecls = fmap renameForeignDecl (coreModuleForeignDecls modl)
          , coreModuleRouteDecls = fmap renameRouteDecl (coreModuleRouteDecls modl)
          , coreModuleDecls = fmap renameCoreDeclTypes (coreModuleDecls modl)
          }
  where
    renameTypeDecl typeDecl =
      typeDecl
        { typeDeclName = renameIfEqual oldName newName (typeDeclName typeDecl)
        , typeDeclConstructors = fmap renameConstructorDecl (typeDeclConstructors typeDecl)
        }

    renameConstructorDecl constructorDecl =
      constructorDecl
        { constructorDeclFields = fmap renameType (constructorDeclFields constructorDecl)
        }

    renameRecordDecl recordDecl =
      recordDecl
        { recordDeclName = renameIfEqual oldName newName (recordDeclName recordDecl)
        , recordDeclProjectionSource = fmap (renameIfEqual oldName newName) (recordDeclProjectionSource recordDecl)
        , recordDeclProjectionPolicy = recordDeclProjectionPolicy recordDecl
        , recordDeclFields = fmap renameRecordFieldDecl (recordDeclFields recordDecl)
        }

    renameRecordFieldDecl fieldDecl =
      fieldDecl {recordFieldDeclType = renameType (recordFieldDeclType fieldDecl)}

    renameProjectionDecl projectionDecl =
      projectionDecl
        { coreProjectionSourceDecl =
            (coreProjectionSourceDecl projectionDecl)
              { projectionDeclName = renameIfEqual oldName newName (projectionDeclName (coreProjectionSourceDecl projectionDecl))
              , projectionDeclSourceRecordName = renameIfEqual oldName newName (projectionDeclSourceRecordName (coreProjectionSourceDecl projectionDecl))
              }
        , coreProjectionRecordDecl = renameRecordDecl (coreProjectionRecordDecl projectionDecl)
        }

    renameForeignDecl foreignDecl =
      foreignDecl {foreignDeclType = renameType (foreignDeclType foreignDecl)}

    renameHookDecl coreHookDecl =
      coreHookDecl
        { coreHookSourceDecl =
            let hookDecl = coreHookSourceDecl coreHookDecl
             in hookDecl
                  { hookDeclRequestType = renameIfEqual oldName newName (hookDeclRequestType hookDecl)
                  , hookDeclRequestDecl = renameBoundaryDecl (hookDeclRequestDecl hookDecl)
                  , hookDeclResponseType = renameIfEqual oldName newName (hookDeclResponseType hookDecl)
                  , hookDeclResponseDecl = renameBoundaryDecl (hookDeclResponseDecl hookDecl)
                  }
        }

    renameWorkflowDecl coreWorkflowDecl =
      coreWorkflowDecl
        { coreWorkflowSourceDecl =
            let workflowDecl = coreWorkflowSourceDecl coreWorkflowDecl
             in workflowDecl
                  { workflowDeclStateType = renameType (workflowDeclStateType workflowDecl)
                  }
        }

    renameToolDecl coreToolDecl =
      coreToolDecl
        { coreToolSourceDecl =
            let toolDecl = coreToolSourceDecl coreToolDecl
             in toolDecl
                  { toolDeclRequestType = renameIfEqual oldName newName (toolDeclRequestType toolDecl)
                  , toolDeclRequestDecl = renameBoundaryDecl (toolDeclRequestDecl toolDecl)
                  , toolDeclResponseType = renameIfEqual oldName newName (toolDeclResponseType toolDecl)
                  , toolDeclResponseDecl = renameBoundaryDecl (toolDeclResponseDecl toolDecl)
                  }
        }

    renameRouteDecl routeDecl =
      routeDecl
        { routeDeclRequestType = renameIfEqual oldName newName (routeDeclRequestType routeDecl)
        , routeDeclQueryDecl = fmap renameBoundaryDecl (routeDeclQueryDecl routeDecl)
        , routeDeclFormDecl = fmap renameBoundaryDecl (routeDeclFormDecl routeDecl)
        , routeDeclBodyDecl = fmap renameBoundaryDecl (routeDeclBodyDecl routeDecl)
        , routeDeclResponseType = renameIfEqual oldName newName (routeDeclResponseType routeDecl)
        , routeDeclResponseDecl = renameBoundaryDecl (routeDeclResponseDecl routeDecl)
        }

    renameBoundaryDecl boundaryDecl =
      boundaryDecl {routeBoundaryDeclType = renameIfEqual oldName newName (routeBoundaryDeclType boundaryDecl)}

    renameCoreDeclTypes decl =
      decl
        { coreDeclType = renameType (coreDeclType decl)
        , coreDeclParams = fmap renameCoreParam (coreDeclParams decl)
        , coreDeclBody = renameExprTypes (coreDeclBody decl)
        }

    renameCoreParam param =
      param {coreParamType = renameType (coreParamType param)}

    renameExprTypes expr =
      case expr of
        CVar span' typ name ->
          CVar span' (renameType typ) name
        CPage span' title body ->
          CPage span' (renameExprTypes title) (renameExprTypes body)
        CViewText span' body ->
          CViewText span' (renameExprTypes body)
        CViewAppend span' left right ->
          CViewAppend span' (renameExprTypes left) (renameExprTypes right)
        CViewElement span' tag body ->
          CViewElement span' tag (renameExprTypes body)
        CViewStyled span' styleRef body ->
          CViewStyled span' styleRef (renameExprTypes body)
        CViewLink span' contract href body ->
          CViewLink span' (renameRouteContract contract) href (renameExprTypes body)
        CViewForm span' contract method action body ->
          CViewForm span' (renameRouteContract contract) method action (renameExprTypes body)
        CViewInput span' fieldName inputKind body ->
          CViewInput span' fieldName inputKind (renameExprTypes body)
        CViewSubmit span' body ->
          CViewSubmit span' (renameExprTypes body)
        CPromptMessage span' role content ->
          CPromptMessage span' role (renameExprTypes content)
        CPromptAppend span' left right ->
          CPromptAppend span' (renameExprTypes left) (renameExprTypes right)
        CPromptText span' promptExpr ->
          CPromptText span' (renameExprTypes promptExpr)
        CList span' typ items ->
          CList span' (renameType typ) (fmap renameExprTypes items)
        CEqual span' left right ->
          CEqual span' (renameExprTypes left) (renameExprTypes right)
        CNotEqual span' left right ->
          CNotEqual span' (renameExprTypes left) (renameExprTypes right)
        CLessThan span' left right ->
          CLessThan span' (renameExprTypes left) (renameExprTypes right)
        CLessThanOrEqual span' left right ->
          CLessThanOrEqual span' (renameExprTypes left) (renameExprTypes right)
        CGreaterThan span' left right ->
          CGreaterThan span' (renameExprTypes left) (renameExprTypes right)
        CGreaterThanOrEqual span' left right ->
          CGreaterThanOrEqual span' (renameExprTypes left) (renameExprTypes right)
        CLet span' typ name value body ->
          CLet span' (renameType typ) name (renameExprTypes value) (renameExprTypes body)
        CMutableLet span' typ name value body ->
          CMutableLet span' (renameType typ) name (renameExprTypes value) (renameExprTypes body)
        CAssign span' typ name value body ->
          CAssign span' (renameType typ) name (renameExprTypes value) (renameExprTypes body)
        CFor span' typ name iterable loopBody body ->
          CFor span' (renameType typ) name (renameExprTypes iterable) (renameExprTypes loopBody) (renameExprTypes body)
        CCall span' typ fn args ->
          CCall span' (renameType typ) (renameExprTypes fn) (fmap renameExprTypes args)
        CMatch span' typ subject branches ->
          CMatch span' (renameType typ) (renameExprTypes subject) (fmap renameBranchTypes branches)
        CRecord span' typ recordName fields ->
          CRecord span' (renameType typ) (renameIfEqual oldName newName recordName) (fmap renameCoreRecordField fields)
        CFieldAccess span' typ recordExpr fieldName ->
          CFieldAccess span' (renameType typ) (renameExprTypes recordExpr) fieldName
        CDecodeJson span' typ rawJson ->
          CDecodeJson span' (renameType typ) (renameExprTypes rawJson)
        CEncodeJson span' value ->
          CEncodeJson span' (renameExprTypes value)
        _ ->
          expr

    renameBranchTypes branch =
      branch
        { coreMatchBranchPattern = renamePattern (coreMatchBranchPattern branch)
        , coreMatchBranchBody = renameExprTypes (coreMatchBranchBody branch)
        }
      where
        renamePattern pattern' =
          case pattern' of
            CConstructorPattern span' constructorName binders ->
              CConstructorPattern span' constructorName (fmap renamePatternBinder binders)

    renamePatternBinder binder =
      binder {corePatternBinderType = renameType (corePatternBinderType binder)}

    renameCoreRecordField field =
      field {coreRecordFieldValue = renameExprTypes (coreRecordFieldValue field)}

    renameRouteContract contract =
      contract
        { coreRouteContractRequestType = renameIfEqual oldName newName (coreRouteContractRequestType contract)
        , coreRouteContractQueryDecl = fmap renameBoundaryDecl (coreRouteContractQueryDecl contract)
        , coreRouteContractFormDecl = fmap renameBoundaryDecl (coreRouteContractFormDecl contract)
        , coreRouteContractBodyDecl = fmap renameBoundaryDecl (coreRouteContractBodyDecl contract)
        , coreRouteContractResponseType = renameIfEqual oldName newName (coreRouteContractResponseType contract)
        , coreRouteContractResponseDecl = renameBoundaryDecl (coreRouteContractResponseDecl contract)
        }

    renameType typ =
      case typ of
        TList itemType ->
          TList (renameType itemType)
        TNamed name ->
          TNamed (renameIfEqual oldName newName name)
        TFunction args result ->
          TFunction (fmap renameType args) (renameType result)
        _ ->
          typ

schemaNameExists :: Text -> CoreModule -> Bool
schemaNameExists target modl =
  any ((== target) . typeDeclName) (coreModuleTypeDecls modl)
    || any ((== target) . recordDeclName) (coreModuleRecordDecls modl)
    || any ((== target) . projectionDeclName . coreProjectionSourceDecl) (coreModuleProjectionDecls modl)

renameIfEqual :: Text -> Text -> Text -> Text
renameIfEqual oldName newName currentName
  | currentName == oldName =
      newName
  | otherwise =
      currentName

builtinSchemaNames :: [Text]
builtinSchemaNames =
  [ "Page"
  , "Redirect"
  , "View"
  , "Prompt"
  , "AuthSession"
  , "Principal"
  , "Tenant"
  , "ResourceIdentity"
  ]

builtinEditSpan :: SourceSpan
builtinEditSpan =
  SourceSpan
    { sourceSpanFile = "<semantic-edit>"
    , sourceSpanStart = Position 1 1
    , sourceSpanEnd = Position 1 1
    }
