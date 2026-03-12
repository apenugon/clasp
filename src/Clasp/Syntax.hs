{-# LANGUAGE OverloadedStrings #-}

module Clasp.Syntax
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
  , ImportDecl (..)
  , MatchBranch (..)
  , Module (..)
  , ModuleName (..)
  , MergeGateDecl (..)
  , MergeGateVerifierRef (..)
  , PatternBinder (..)
  , Pattern (..)
  , PolicyClassificationDecl (..)
  , PolicyDecl (..)
  , PolicyPermissionDecl (..)
  , PolicyPermissionKind (..)
  , Position (..)
  , ProjectionDecl (..)
  , ProjectionFieldDecl (..)
  , RecordDecl (..)
  , RecordFieldDecl (..)
  , RecordFieldExpr (..)
  , RouteBoundaryDecl (..)
  , RouteDecl (..)
  , RouteMethod (..)
  , RoutePathDecl (..)
  , RoutePathParamDecl (..)
  , SourceSpan (..)
  , ToolDecl (..)
  , ToolServerDecl (..)
  , TypeDecl (..)
  , Type (..)
  , VerifierDecl (..)
  , exprSpan
  , mergeSourceSpans
  , renderModule
  , renderType
  , renderAgentRoleApprovalPolicy
  , renderAgentRoleSandboxPolicy
  , splitModuleName
  ) where

import Data.Aeson
  ( ToJSON (toJSON)
  , object
  , (.=)
  )
import Data.Text (Text)
import qualified Data.Text as T

newtype ModuleName = ModuleName
  { unModuleName :: Text
  }
  deriving (Eq, Ord, Show)

splitModuleName :: ModuleName -> [Text]
splitModuleName =
  T.splitOn "." . unModuleName

data Position = Position
  { positionLine :: Int
  , positionColumn :: Int
  }
  deriving (Eq, Ord, Show)

instance ToJSON Position where
  toJSON position =
    object
      [ "line" .= positionLine position
      , "column" .= positionColumn position
      ]

data SourceSpan = SourceSpan
  { sourceSpanFile :: Text
  , sourceSpanStart :: Position
  , sourceSpanEnd :: Position
  }
  deriving (Eq, Ord, Show)

instance ToJSON SourceSpan where
  toJSON span' =
    object
      [ "file" .= sourceSpanFile span'
      , "start" .= sourceSpanStart span'
      , "end" .= sourceSpanEnd span'
      ]

data ImportDecl = ImportDecl
  { importDeclModule :: ModuleName
  , importDeclSpan :: SourceSpan
  }
  deriving (Eq, Show)

data Module = Module
  { moduleName :: ModuleName
  , moduleImports :: [ImportDecl]
  , moduleTypeDecls :: [TypeDecl]
  , moduleRecordDecls :: [RecordDecl]
  , moduleGuideDecls :: [GuideDecl]
  , moduleHookDecls :: [HookDecl]
  , moduleAgentRoleDecls :: [AgentRoleDecl]
  , moduleAgentDecls :: [AgentDecl]
  , modulePolicyDecls :: [PolicyDecl]
  , moduleToolServerDecls :: [ToolServerDecl]
  , moduleToolDecls :: [ToolDecl]
  , moduleVerifierDecls :: [VerifierDecl]
  , moduleMergeGateDecls :: [MergeGateDecl]
  , moduleProjectionDecls :: [ProjectionDecl]
  , moduleForeignDecls :: [ForeignDecl]
  , moduleRouteDecls :: [RouteDecl]
  , moduleDecls :: [Decl]
  }
  deriving (Eq, Show)

data GuideEntryDecl = GuideEntryDecl
  { guideEntryDeclName :: Text
  , guideEntryDeclSpan :: SourceSpan
  , guideEntryDeclValue :: Text
  , guideEntryDeclValueSpan :: SourceSpan
  }
  deriving (Eq, Show)

data GuideDecl = GuideDecl
  { guideDeclName :: Text
  , guideDeclSpan :: SourceSpan
  , guideDeclNameSpan :: SourceSpan
  , guideDeclExtends :: Maybe Text
  , guideDeclExtendsSpan :: Maybe SourceSpan
  , guideDeclEntries :: [GuideEntryDecl]
  }
  deriving (Eq, Show)

data HookTriggerDecl = HookTriggerDecl
  { hookTriggerDeclEvent :: Text
  , hookTriggerDeclSpan :: SourceSpan
  }
  deriving (Eq, Show)

data HookDecl = HookDecl
  { hookDeclName :: Text
  , hookDeclSpan :: SourceSpan
  , hookDeclNameSpan :: SourceSpan
  , hookDeclIdentity :: Text
  , hookDeclTrigger :: HookTriggerDecl
  , hookDeclRequestType :: Text
  , hookDeclRequestDecl :: RouteBoundaryDecl
  , hookDeclRequestTypeSpan :: SourceSpan
  , hookDeclResponseType :: Text
  , hookDeclResponseDecl :: RouteBoundaryDecl
  , hookDeclResponseTypeSpan :: SourceSpan
  , hookDeclHandlerName :: Text
  , hookDeclHandlerSpan :: SourceSpan
  }
  deriving (Eq, Show)

data AgentRoleApprovalPolicy
  = AgentRoleApprovalNever
  | AgentRoleApprovalOnFailure
  | AgentRoleApprovalOnRequest
  | AgentRoleApprovalUntrusted
  deriving (Eq, Show)

renderAgentRoleApprovalPolicy :: AgentRoleApprovalPolicy -> Text
renderAgentRoleApprovalPolicy approvalPolicy =
  case approvalPolicy of
    AgentRoleApprovalNever -> "never"
    AgentRoleApprovalOnFailure -> "on_failure"
    AgentRoleApprovalOnRequest -> "on_request"
    AgentRoleApprovalUntrusted -> "untrusted"

data AgentRoleSandboxPolicy
  = AgentRoleSandboxReadOnly
  | AgentRoleSandboxWorkspaceWrite
  | AgentRoleSandboxDangerFullAccess
  deriving (Eq, Show)

renderAgentRoleSandboxPolicy :: AgentRoleSandboxPolicy -> Text
renderAgentRoleSandboxPolicy sandboxPolicy =
  case sandboxPolicy of
    AgentRoleSandboxReadOnly -> "read_only"
    AgentRoleSandboxWorkspaceWrite -> "workspace_write"
    AgentRoleSandboxDangerFullAccess -> "danger_full_access"

data AgentRoleDecl = AgentRoleDecl
  { agentRoleDeclName :: Text
  , agentRoleDeclSpan :: SourceSpan
  , agentRoleDeclNameSpan :: SourceSpan
  , agentRoleDeclIdentity :: Text
  , agentRoleDeclGuideName :: Text
  , agentRoleDeclGuideSpan :: SourceSpan
  , agentRoleDeclPolicyName :: Text
  , agentRoleDeclPolicySpan :: SourceSpan
  , agentRoleDeclApprovalPolicy :: Maybe AgentRoleApprovalPolicy
  , agentRoleDeclSandboxPolicy :: Maybe AgentRoleSandboxPolicy
  }
  deriving (Eq, Show)

data AgentDecl = AgentDecl
  { agentDeclName :: Text
  , agentDeclSpan :: SourceSpan
  , agentDeclNameSpan :: SourceSpan
  , agentDeclIdentity :: Text
  , agentDeclRoleName :: Text
  , agentDeclRoleSpan :: SourceSpan
  }
  deriving (Eq, Show)

data ToolServerDecl = ToolServerDecl
  { toolServerDeclName :: Text
  , toolServerDeclSpan :: SourceSpan
  , toolServerDeclNameSpan :: SourceSpan
  , toolServerDeclIdentity :: Text
  , toolServerDeclProtocol :: Text
  , toolServerDeclProtocolSpan :: SourceSpan
  , toolServerDeclLocation :: Text
  , toolServerDeclLocationSpan :: SourceSpan
  , toolServerDeclPolicyName :: Text
  , toolServerDeclPolicySpan :: SourceSpan
  }
  deriving (Eq, Show)

data ToolDecl = ToolDecl
  { toolDeclName :: Text
  , toolDeclSpan :: SourceSpan
  , toolDeclNameSpan :: SourceSpan
  , toolDeclIdentity :: Text
  , toolDeclServerName :: Text
  , toolDeclServerSpan :: SourceSpan
  , toolDeclOperation :: Text
  , toolDeclOperationSpan :: SourceSpan
  , toolDeclRequestType :: Text
  , toolDeclRequestDecl :: RouteBoundaryDecl
  , toolDeclRequestTypeSpan :: SourceSpan
  , toolDeclResponseType :: Text
  , toolDeclResponseDecl :: RouteBoundaryDecl
  , toolDeclResponseTypeSpan :: SourceSpan
  }
  deriving (Eq, Show)

data VerifierDecl = VerifierDecl
  { verifierDeclName :: Text
  , verifierDeclSpan :: SourceSpan
  , verifierDeclNameSpan :: SourceSpan
  , verifierDeclIdentity :: Text
  , verifierDeclToolName :: Text
  , verifierDeclToolSpan :: SourceSpan
  }
  deriving (Eq, Show)

data MergeGateVerifierRef = MergeGateVerifierRef
  { mergeGateVerifierRefName :: Text
  , mergeGateVerifierRefSpan :: SourceSpan
  }
  deriving (Eq, Show)

data MergeGateDecl = MergeGateDecl
  { mergeGateDeclName :: Text
  , mergeGateDeclSpan :: SourceSpan
  , mergeGateDeclNameSpan :: SourceSpan
  , mergeGateDeclIdentity :: Text
  , mergeGateDeclVerifierRefs :: [MergeGateVerifierRef]
  }
  deriving (Eq, Show)

data TypeDecl = TypeDecl
  { typeDeclName :: Text
  , typeDeclSpan :: SourceSpan
  , typeDeclNameSpan :: SourceSpan
  , typeDeclConstructors :: [ConstructorDecl]
  }
  deriving (Eq, Show)

data ConstructorDecl = ConstructorDecl
  { constructorDeclName :: Text
  , constructorDeclSpan :: SourceSpan
  , constructorDeclNameSpan :: SourceSpan
  , constructorDeclFields :: [Type]
  }
  deriving (Eq, Show)

data RecordDecl = RecordDecl
  { recordDeclName :: Text
  , recordDeclSpan :: SourceSpan
  , recordDeclNameSpan :: SourceSpan
  , recordDeclProjectionSource :: Maybe Text
  , recordDeclProjectionPolicy :: Maybe Text
  , recordDeclFields :: [RecordFieldDecl]
  }
  deriving (Eq, Show)

data RecordFieldDecl = RecordFieldDecl
  { recordFieldDeclName :: Text
  , recordFieldDeclSpan :: SourceSpan
  , recordFieldDeclType :: Type
  , recordFieldDeclClassification :: Text
  }
  deriving (Eq, Show)

data PolicyClassificationDecl = PolicyClassificationDecl
  { policyClassificationDeclName :: Text
  , policyClassificationDeclSpan :: SourceSpan
  }
  deriving (Eq, Show)

data PolicyPermissionKind
  = PolicyPermissionFile
  | PolicyPermissionNetwork
  | PolicyPermissionProcess
  | PolicyPermissionSecret
  deriving (Eq, Ord, Show)

data PolicyPermissionDecl = PolicyPermissionDecl
  { policyPermissionDeclKind :: PolicyPermissionKind
  , policyPermissionDeclSpan :: SourceSpan
  , policyPermissionDeclValue :: Text
  }
  deriving (Eq, Show)

data PolicyDecl = PolicyDecl
  { policyDeclName :: Text
  , policyDeclSpan :: SourceSpan
  , policyDeclNameSpan :: SourceSpan
  , policyDeclAllowedClassifications :: [PolicyClassificationDecl]
  , policyDeclPermissions :: [PolicyPermissionDecl]
  }
  deriving (Eq, Show)

data ProjectionFieldDecl = ProjectionFieldDecl
  { projectionFieldDeclName :: Text
  , projectionFieldDeclSpan :: SourceSpan
  }
  deriving (Eq, Show)

data ProjectionDecl = ProjectionDecl
  { projectionDeclName :: Text
  , projectionDeclSpan :: SourceSpan
  , projectionDeclNameSpan :: SourceSpan
  , projectionDeclSourceRecordName :: Text
  , projectionDeclSourceRecordSpan :: SourceSpan
  , projectionDeclPolicyName :: Text
  , projectionDeclPolicySpan :: SourceSpan
  , projectionDeclFields :: [ProjectionFieldDecl]
  }
  deriving (Eq, Show)

data Decl = Decl
  { declName :: Text
  , declSpan :: SourceSpan
  , declNameSpan :: SourceSpan
  , declAnnotationSpan :: Maybe SourceSpan
  , declAnnotation :: Maybe Type
  , declParams :: [Text]
  , declBody :: Expr
  }
  deriving (Eq, Show)

data ForeignPackageImportKind
  = ForeignPackageImportNpm
  | ForeignPackageImportTypeScript
  deriving (Eq, Show)

data ForeignPackageImport = ForeignPackageImport
  { foreignPackageImportKind :: ForeignPackageImportKind
  , foreignPackageImportKindSpan :: SourceSpan
  , foreignPackageImportSpecifier :: Text
  , foreignPackageImportSpecifierSpan :: SourceSpan
  , foreignPackageImportDeclarationPath :: Text
  , foreignPackageImportDeclarationSpan :: SourceSpan
  , foreignPackageImportSignature :: Maybe Text
  }
  deriving (Eq, Show)

data ForeignDecl = ForeignDecl
  { foreignDeclName :: Text
  , foreignDeclSpan :: SourceSpan
  , foreignDeclNameSpan :: SourceSpan
  , foreignDeclAnnotationSpan :: SourceSpan
  , foreignDeclType :: Type
  , foreignDeclRuntimeName :: Text
  , foreignDeclRuntimeSpan :: SourceSpan
  , foreignDeclPackageImport :: Maybe ForeignPackageImport
  }
  deriving (Eq, Show)

data Type
  = TInt
  | TStr
  | TBool
  | TList Type
  | TNamed Text
  | TFunction [Type] Type
  deriving (Eq, Ord, Show)

data PatternBinder = PatternBinder
  { patternBinderName :: Text
  , patternBinderSpan :: SourceSpan
  }
  deriving (Eq, Show)

data Pattern = PConstructor SourceSpan Text [PatternBinder]
  deriving (Eq, Show)

data MatchBranch = MatchBranch
  { matchBranchSpan :: SourceSpan
  , matchBranchPattern :: Pattern
  , matchBranchBody :: Expr
  }
  deriving (Eq, Show)

data RouteMethod
  = RouteGet
  | RoutePost
  deriving (Eq, Ord, Show)

data RoutePathParamDecl = RoutePathParamDecl
  { routePathParamDeclName :: Text
  , routePathParamDeclType :: Text
  }
  deriving (Eq, Show)

data RoutePathDecl = RoutePathDecl
  { routePathDeclPattern :: Text
  , routePathDeclParams :: [RoutePathParamDecl]
  }
  deriving (Eq, Show)

data RouteBoundaryDecl = RouteBoundaryDecl
  { routeBoundaryDeclType :: Text
  }
  deriving (Eq, Show)

data RouteDecl = RouteDecl
  { routeDeclName :: Text
  , routeDeclSpan :: SourceSpan
  , routeDeclNameSpan :: SourceSpan
  , routeDeclIdentity :: Text
  , routeDeclMethod :: RouteMethod
  , routeDeclPath :: Text
  , routeDeclPathDecl :: RoutePathDecl
  , routeDeclPathSpan :: SourceSpan
  , routeDeclRequestType :: Text
  , routeDeclQueryDecl :: Maybe RouteBoundaryDecl
  , routeDeclFormDecl :: Maybe RouteBoundaryDecl
  , routeDeclBodyDecl :: Maybe RouteBoundaryDecl
  , routeDeclRequestTypeSpan :: SourceSpan
  , routeDeclResponseType :: Text
  , routeDeclResponseDecl :: RouteBoundaryDecl
  , routeDeclResponseTypeSpan :: SourceSpan
  , routeDeclHandlerName :: Text
  , routeDeclHandlerSpan :: SourceSpan
  }
  deriving (Eq, Show)

data RecordFieldExpr = RecordFieldExpr
  { recordFieldExprName :: Text
  , recordFieldExprSpan :: SourceSpan
  , recordFieldExprValue :: Expr
  }
  deriving (Eq, Show)

data Expr
  = EVar SourceSpan Text
  | EInt SourceSpan Integer
  | EString SourceSpan Text
  | EBool SourceSpan Bool
  | EList SourceSpan [Expr]
  | EReturn SourceSpan Expr
  | EBlock SourceSpan Expr
  | EEqual SourceSpan Expr Expr
  | ENotEqual SourceSpan Expr Expr
  | ELessThan SourceSpan Expr Expr
  | ELessThanOrEqual SourceSpan Expr Expr
  | EGreaterThan SourceSpan Expr Expr
  | EGreaterThanOrEqual SourceSpan Expr Expr
  | ECall SourceSpan Expr [Expr]
  | ELet SourceSpan SourceSpan Text Expr Expr
  | EMutableLet SourceSpan SourceSpan Text Expr Expr
  | EAssign SourceSpan SourceSpan Text Expr Expr
  | EFor SourceSpan SourceSpan Text Expr Expr Expr
  | EMatch SourceSpan Expr [MatchBranch]
  | ERecord SourceSpan Text [RecordFieldExpr]
  | EFieldAccess SourceSpan Expr Text
  | EDecode SourceSpan Type Expr
  | EEncode SourceSpan Expr
  deriving (Eq, Show)

exprSpan :: Expr -> SourceSpan
exprSpan expr =
  case expr of
    EVar span' _ ->
      span'
    EInt span' _ ->
      span'
    EString span' _ ->
      span'
    EBool span' _ ->
      span'
    EList span' _ ->
      span'
    EReturn span' _ ->
      span'
    EBlock span' _ ->
      span'
    EEqual span' _ _ ->
      span'
    ENotEqual span' _ _ ->
      span'
    ELessThan span' _ _ ->
      span'
    ELessThanOrEqual span' _ _ ->
      span'
    EGreaterThan span' _ _ ->
      span'
    EGreaterThanOrEqual span' _ _ ->
      span'
    ECall span' _ _ ->
      span'
    ELet span' _ _ _ _ ->
      span'
    EMutableLet span' _ _ _ _ ->
      span'
    EAssign span' _ _ _ _ ->
      span'
    EFor span' _ _ _ _ _ ->
      span'
    EMatch span' _ _ ->
      span'
    ERecord span' _ _ ->
      span'
    EFieldAccess span' _ _ ->
      span'
    EDecode span' _ _ ->
      span'
    EEncode span' _ ->
      span'

mergeSourceSpans :: SourceSpan -> SourceSpan -> SourceSpan
mergeSourceSpans left right =
  SourceSpan
    { sourceSpanFile = sourceSpanFile left
    , sourceSpanStart = sourceSpanStart left
    , sourceSpanEnd = sourceSpanEnd right
    }

renderType :: Type -> Text
renderType typ =
  case typ of
    TInt ->
      "Int"
    TStr ->
      "Str"
    TBool ->
      "Bool"
    TList itemType ->
      "[" <> renderType itemType <> "]"
    TNamed name ->
      name
    TFunction args result ->
      T.intercalate " -> " (fmap renderAtomicType (args <> [result]))

renderAtomicType :: Type -> Text
renderAtomicType typ =
  case typ of
    TFunction _ _ ->
      "(" <> renderType typ <> ")"
    _ ->
      renderType typ

renderModule :: Module -> Text
renderModule modl =
  T.intercalate
    "\n\n"
    (["module " <> unModuleName (moduleName modl)] <> importSections <> topLevelSections)
  where
    importSections =
      case moduleImports modl of
        [] -> []
        imports ->
          [T.dropWhileEnd (== '\n') (T.unlines (fmap renderImportDecl imports))]
    topLevelSections =
      fmap renderSection . filter (not . null) $
        [ fmap renderTypeDecl (moduleTypeDecls modl)
        , fmap renderRecordDecl (moduleRecordDecls modl)
        , fmap renderGuideDecl (moduleGuideDecls modl)
        , fmap renderHookDecl (moduleHookDecls modl)
        , fmap renderAgentRoleDecl (moduleAgentRoleDecls modl)
        , fmap renderAgentDecl (moduleAgentDecls modl)
        , fmap renderPolicyDecl (modulePolicyDecls modl)
        , fmap renderToolServerDecl (moduleToolServerDecls modl)
        , fmap renderToolDecl (moduleToolDecls modl)
        , fmap renderVerifierDecl (moduleVerifierDecls modl)
        , fmap renderMergeGateDecl (moduleMergeGateDecls modl)
        , fmap renderProjectionDecl (moduleProjectionDecls modl)
        , fmap renderForeignDecl (moduleForeignDecls modl)
        , fmap renderRouteDecl (moduleRouteDecls modl)
        , fmap renderDecl (moduleDecls modl)
        ]

renderSection :: [Text] -> Text
renderSection entries =
  T.dropWhileEnd (== '\n') (T.unlines entries)

renderImportDecl :: ImportDecl -> Text
renderImportDecl importDecl =
  "import " <> unModuleName (importDeclModule importDecl)

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

renderRecordFieldDecl :: RecordFieldDecl -> Text
renderRecordFieldDecl fieldDecl =
  recordFieldDeclName fieldDecl
    <> ": "
    <> renderType (recordFieldDeclType fieldDecl)
    <> renderClassificationSuffix (recordFieldDeclClassification fieldDecl)

renderClassificationSuffix :: Text -> Text
renderClassificationSuffix classification
  | classification == "public" = ""
  | otherwise = " classified " <> classification

renderGuideDecl :: GuideDecl -> Text
renderGuideDecl guideDecl =
  "guide "
    <> guideDeclName guideDecl
    <> renderGuideExtends (guideDeclExtends guideDecl)
    <> " = "
    <> renderBracedInline (fmap renderGuideEntryDecl (guideDeclEntries guideDecl))

renderGuideExtends :: Maybe Text -> Text
renderGuideExtends Nothing = ""
renderGuideExtends (Just parentName) = " extends " <> parentName

renderGuideEntryDecl :: GuideEntryDecl -> Text
renderGuideEntryDecl entryDecl =
  guideEntryDeclName entryDecl <> ": " <> renderStringLiteral (guideEntryDeclValue entryDecl)

renderHookDecl :: HookDecl -> Text
renderHookDecl hookDecl =
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

renderAgentRoleDecl :: AgentRoleDecl -> Text
renderAgentRoleDecl roleDecl =
  "role "
    <> agentRoleDeclName roleDecl
    <> " = guide: "
    <> agentRoleDeclGuideName roleDecl
    <> ", policy: "
    <> agentRoleDeclPolicyName roleDecl

renderAgentDecl :: AgentDecl -> Text
renderAgentDecl agentDecl =
  "agent " <> agentDeclName agentDecl <> " = " <> agentDeclRoleName agentDecl

renderPolicyDecl :: PolicyDecl -> Text
renderPolicyDecl policyDecl =
  "policy "
    <> policyDeclName policyDecl
    <> " = "
    <> T.intercalate ", " (fmap renderPolicyClassificationDecl (policyDeclAllowedClassifications policyDecl))
    <> renderPolicyPermissionsSuffix (policyDeclPermissions policyDecl)

renderPolicyClassificationDecl :: PolicyClassificationDecl -> Text
renderPolicyClassificationDecl = policyClassificationDeclName

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

renderToolServerDecl :: ToolServerDecl -> Text
renderToolServerDecl toolServerDecl =
  "toolserver "
    <> toolServerDeclName toolServerDecl
    <> " = "
    <> renderStringLiteral (toolServerDeclProtocol toolServerDecl)
    <> " "
    <> renderStringLiteral (toolServerDeclLocation toolServerDecl)
    <> " with "
    <> toolServerDeclPolicyName toolServerDecl

renderToolDecl :: ToolDecl -> Text
renderToolDecl toolDecl =
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

renderVerifierDecl :: VerifierDecl -> Text
renderVerifierDecl verifierDecl =
  "verifier " <> verifierDeclName verifierDecl <> " = " <> verifierDeclToolName verifierDecl

renderMergeGateDecl :: MergeGateDecl -> Text
renderMergeGateDecl mergeGateDecl =
  "mergegate "
    <> mergeGateDeclName mergeGateDecl
    <> " = "
    <> T.intercalate ", " (fmap renderMergeGateVerifierRef (mergeGateDeclVerifierRefs mergeGateDecl))

renderMergeGateVerifierRef :: MergeGateVerifierRef -> Text
renderMergeGateVerifierRef = mergeGateVerifierRefName

renderProjectionDecl :: ProjectionDecl -> Text
renderProjectionDecl projectionDecl =
  "projection "
    <> projectionDeclName projectionDecl
    <> " = "
    <> projectionDeclSourceRecordName projectionDecl
    <> " with "
    <> projectionDeclPolicyName projectionDecl
    <> " "
    <> renderBracedInline (fmap renderProjectionFieldDecl (projectionDeclFields projectionDecl))

renderProjectionFieldDecl :: ProjectionFieldDecl -> Text
renderProjectionFieldDecl = projectionFieldDeclName

renderForeignDecl :: ForeignDecl -> Text
renderForeignDecl foreignDecl =
  "foreign "
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

renderDecl :: Decl -> Text
renderDecl decl =
  T.intercalate
    "\n"
    (annotationLine <> [definitionLine])
  where
    annotationLine =
      case declAnnotation decl of
        Nothing -> []
        Just annotation ->
          [declName decl <> " : " <> renderType annotation]
    definitionLine =
      T.unwords (declName decl : declParams decl)
        <> " = "
        <> renderExpr 0 (declBody decl)

renderExpr :: Int -> Expr -> Text
renderExpr parentPrecedence expr =
  case expr of
    EVar _ name ->
      name
    EInt _ value ->
      T.pack (show value)
    EString _ value ->
      renderStringLiteral value
    EBool _ value ->
      if value then "true" else "false"
    EList _ values ->
      "[" <> T.intercalate ", " (fmap (renderExpr 0) values) <> "]"
    EReturn _ value ->
      "return " <> renderExpr 4 value
    EBlock _ body ->
      renderBlockExpr body
    EEqual _ left right ->
      renderInfixExpr parentPrecedence 1 "==" left right
    ENotEqual _ left right ->
      renderInfixExpr parentPrecedence 1 "!=" left right
    ELessThan _ left right ->
      renderInfixExpr parentPrecedence 2 "<" left right
    ELessThanOrEqual _ left right ->
      renderInfixExpr parentPrecedence 2 "<=" left right
    EGreaterThan _ left right ->
      renderInfixExpr parentPrecedence 2 ">" left right
    EGreaterThanOrEqual _ left right ->
      renderInfixExpr parentPrecedence 2 ">=" left right
    ECall _ fn args ->
      renderWithParensIfNeeded parentPrecedence 3 $
        T.unwords (renderExpr 3 fn : fmap (renderExpr 4) args)
    ELet _ _ name value body ->
      renderWithParensIfNeeded parentPrecedence 0 $
        "let " <> name <> " = " <> renderExpr 0 value <> " in " <> renderExpr 0 body
    EMutableLet _ _ name value body ->
      renderWithParensIfNeeded parentPrecedence 4 $
        renderSyntheticBlock [RenderMutableLetBinding name value] body
    EAssign _ _ name value body ->
      renderWithParensIfNeeded parentPrecedence 4 $
        renderSyntheticBlock [RenderAssignBinding name value] body
    EFor _ _ name iterable loopBody body ->
      renderWithParensIfNeeded parentPrecedence 4 $
        renderSyntheticBlock [RenderForBinding name iterable loopBody] body
    EMatch _ subject branches ->
      "match " <> renderExpr 0 subject <> " " <> renderBracedCommaBlock (fmap renderMatchBranch branches)
    ERecord _ recordName fields ->
      recordName <> renderBracedInline (fmap renderRecordFieldExpr fields)
    EFieldAccess _ subject fieldName ->
      renderWithParensIfNeeded parentPrecedence 4 $
        renderExpr 4 subject <> "." <> fieldName
    EDecode _ targetType rawJson ->
      "decode " <> renderAtomicType targetType <> " " <> renderExpr 4 rawJson
    EEncode _ value ->
      "encode " <> renderExpr 4 value

renderInfixExpr :: Int -> Int -> Text -> Expr -> Expr -> Text
renderInfixExpr parentPrecedence operatorPrecedence operatorText left right =
  renderWithParensIfNeeded parentPrecedence operatorPrecedence $
    renderExpr operatorPrecedence left
      <> " "
      <> operatorText
      <> " "
      <> renderExpr operatorPrecedence right

renderBlockExpr :: Expr -> Text
renderBlockExpr body =
  renderSyntheticBlock bindings finalExpr
  where
    (bindings, finalExpr) = collectBlockBindings body

renderSyntheticBlock :: [RenderBlockBinding] -> Expr -> Text
renderSyntheticBlock bindings finalExpr =
  renderBracedBlock (fmap renderBlockBinding bindings <> [renderExpr 0 finalExpr])

data RenderBlockBinding
  = RenderLetBinding Text Expr
  | RenderMutableLetBinding Text Expr
  | RenderAssignBinding Text Expr
  | RenderForBinding Text Expr Expr

collectBlockBindings :: Expr -> ([RenderBlockBinding], Expr)
collectBlockBindings expr =
  case expr of
    ELet _ _ name value body ->
      prependBinding (RenderLetBinding name value) body
    EMutableLet _ _ name value body ->
      prependBinding (RenderMutableLetBinding name value) body
    EAssign _ _ name value body ->
      prependBinding (RenderAssignBinding name value) body
    EFor _ _ name iterable loopBody body ->
      prependBinding (RenderForBinding name iterable loopBody) body
    _ ->
      ([], expr)
  where
    prependBinding binding body =
      let (bindings, finalExpr) = collectBlockBindings body
       in (binding : bindings, finalExpr)

renderBlockBinding :: RenderBlockBinding -> Text
renderBlockBinding binding =
  case binding of
    RenderLetBinding name value ->
      "let " <> name <> " = " <> renderExpr 0 value <> ";"
    RenderMutableLetBinding name value ->
      "let mut " <> name <> " = " <> renderExpr 0 value <> ";"
    RenderAssignBinding name value ->
      name <> " = " <> renderExpr 0 value <> ";"
    RenderForBinding name iterable loopBody ->
      "for " <> name <> " in " <> renderExpr 0 iterable <> " " <> renderLoopBody loopBody <> ";"

renderLoopBody :: Expr -> Text
renderLoopBody loopBody =
  case loopBody of
    EBlock _ blockBody ->
      renderBlockExpr blockBody
    _ ->
      renderBracedBlock [renderExpr 0 loopBody]

renderMatchBranch :: MatchBranch -> Text
renderMatchBranch branch =
  renderPattern (matchBranchPattern branch) <> " -> " <> renderExpr 0 (matchBranchBody branch)

renderPattern :: Pattern -> Text
renderPattern pattern' =
  case pattern' of
    PConstructor _ constructorName binders ->
      T.unwords (constructorName : fmap patternBinderName binders)

renderRecordFieldExpr :: RecordFieldExpr -> Text
renderRecordFieldExpr fieldExpr =
  recordFieldExprName fieldExpr <> " = " <> renderExpr 0 (recordFieldExprValue fieldExpr)

renderBracedInline :: [Text] -> Text
renderBracedInline entries =
  "{"
    <> ( if null entries
           then ""
           else " " <> T.intercalate ", " entries <> " "
       )
    <> "}"

renderBracedBlock :: [Text] -> Text
renderBracedBlock entries =
  "{\n"
    <> T.intercalate "\n" (fmap (indentText 2) entries)
    <> "\n}"

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
