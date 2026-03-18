{-# LANGUAGE OverloadedStrings #-}

module Clasp.Parser
  ( parseModule
  ) where

import Control.Monad (foldM, void, when)
import Data.Bifunctor (first)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath (dropExtension, splitDirectories, takeExtension)
import Data.Void (Void)
import Text.Megaparsec
  ( Parsec
  , SourcePos
  , between
  , eof
  , errorBundlePretty
  , getSourcePos
  , many
  , manyTill
  , notFollowedBy
  , optional
  , parse
  , sepBy
  , sepBy1
  , some
  , try
  , (<|>)
  )
import qualified Text.Megaparsec as MP
import Text.Megaparsec.Char
  ( alphaNumChar
  , char
  , eol
  , lowerChar
  , space1
  , string
  , upperChar
  )
import qualified Text.Megaparsec.Char.Lexer as L
import Text.Megaparsec.Pos (unPos)
import Clasp.Diagnostic
  ( DiagnosticBundle
  , diagnostic
  , diagnosticBundle
  , diagnosticRelated
  , singleDiagnostic
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
  , ForeignPackageImport (..)
  , ForeignPackageImportKind (..)
  , GoalDecl (..)
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
  , exprSpan
  , mergeSourceSpans
  )

type Parser = Parsec Void Text

data TopLevelItem
  = TopTypeDecl TypeDecl
  | TopRecordDecl RecordDecl
  | TopDomainObjectDecl DomainObjectDecl
  | TopDomainEventDecl DomainEventDecl
  | TopFeedbackDecl FeedbackDecl
  | TopMetricDecl MetricDecl
  | TopGoalDecl GoalDecl
  | TopExperimentDecl ExperimentDecl
  | TopRolloutDecl RolloutDecl
  | TopWorkflowDecl WorkflowDecl
  | TopSupervisorDecl SupervisorDecl
  | TopGuideDecl GuideDecl
  | TopHookDecl HookDecl
  | TopAgentRoleDecl AgentRoleDecl
  | TopAgentDecl AgentDecl
  | TopPolicyDecl PolicyDecl
  | TopToolServerDecl ToolServerDecl
  | TopToolDecl ToolDecl
  | TopVerifierDecl VerifierDecl
  | TopMergeGateDecl MergeGateDecl
  | TopProjectionDecl ProjectionDecl
  | TopForeignDecl ForeignDecl
  | TopRouteDecl RouteDecl
  | TopSignature Text Type SourceSpan
  | TopDecl Decl

data BlockBinding
  = BlockLetBinding SourcePos SourceSpan Text Expr
  | BlockMutableLetBinding SourcePos SourceSpan Text Expr
  | BlockAssignBinding SourcePos SourceSpan Text Expr
  | BlockForBinding SourcePos SourceSpan Text Expr Expr

data AgentRoleAttr
  = AgentRoleGuideAttr SourceSpan Text
  | AgentRolePolicyAttr SourceSpan Text
  | AgentRoleApprovalAttr AgentRoleApprovalPolicy
  | AgentRoleSandboxAttr AgentRoleSandboxPolicy

parseModule :: FilePath -> Text -> Either DiagnosticBundle Module
parseModule path source =
  attachSignatures =<<
    first
      (\bundle -> singleDiagnostic "E_PARSE" "Failed to parse source." [T.pack (errorBundlePretty bundle)])
      (parse (moduleParser path <* eof) path source)

moduleParser :: FilePath -> Parser (ModuleName, [ImportDecl], [TopLevelItem])
moduleParser path = do
  scn
  explicitHeader <- optional (try moduleDeclParser)
  scn
  imports <- many importParser
  items <- some topLevelItemParser
  let (explicitName, headerImports) = fromMaybe (inferModuleName path, []) explicitHeader
  pure (ModuleName explicitName, headerImports <> imports, items)

moduleDeclParser :: Parser (Text, [ImportDecl])
moduleDeclParser = do
  keyword "module"
  moduleName <- moduleNameParser
  headerImports <- fromMaybe [] <$> optional (try compactImportListParser)
  pure (moduleName, headerImports)

compactImportListParser :: Parser [ImportDecl]
compactImportListParser = do
  keyword "with"
  sepBy1 compactImportParser (symbol ",")

compactImportParser :: Parser ImportDecl
compactImportParser = do
  start <- getSourcePos
  importName <- moduleNameParser
  end <- getSourcePos
  pure
    ImportDecl
      { importDeclModule = ModuleName importName
      , importDeclSpan = makeSourceSpan start end
      }

inferModuleName :: FilePath -> Text
inferModuleName path =
  let extension = takeExtension path
      moduleSegments =
        filter
          (\segment -> not (null segment) && segment /= ".")
          (splitDirectories (dropExtension path))
   in if extension == ".clasp" && not (null moduleSegments)
        then T.intercalate "." (fmap T.pack moduleSegments)
        else "Main"

importParser :: Parser ImportDecl
importParser = do
  start <- getSourcePos
  keyword "import"
  importName <- moduleNameParser
  end <- getSourcePos
  _ <- optional eol
  scn
  pure
    ImportDecl
      { importDeclModule = ModuleName importName
      , importDeclSpan = makeSourceSpan start end
      }

topLevelItemParser :: Parser TopLevelItem
topLevelItemParser =
  try projectionDeclParser
    <|> try policyDeclParser
    <|> try domainDeclParser
    <|> try feedbackDeclParser
    <|> try metricDeclParser
    <|> try goalDeclParser
    <|> try experimentDeclParser
    <|> try rolloutDeclParser
    <|> try agentDeclParser
    <|> try agentRoleDeclParser
    <|> try hookDeclParser
    <|> try guideDeclParser
    <|> try mergeGateDeclParser
    <|> try verifierDeclParser
    <|> try toolDeclParser
    <|> try toolServerDeclParser
    <|> try foreignDeclParser
    <|> try routeDeclParser
    <|> try recordDeclParser
    <|> try workflowDeclParser
    <|> try supervisorDeclParser
    <|> try typeDeclParser
    <|> try typeSignatureParser
    <|> (TopDecl <$> declParser)

hookDeclParser :: Parser TopLevelItem
hookDeclParser = do
  start <- getSourcePos
  keyword "hook"
  (nameSpan, name) <- locatedLowerIdentifier
  _ <- symbol "="
  (triggerSpan, triggerEvent) <- locatedStringLiteral
  (requestTypeSpan, requestTypeName) <- locatedUpperIdentifier
  _ <- symbol "->"
  (responseTypeSpan, responseTypeName) <- locatedUpperIdentifier
  (handlerSpan, handlerName) <- locatedLowerIdentifier
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopHookDecl $
    HookDecl
      { hookDeclName = name
      , hookDeclSpan = makeSourceSpan start end
      , hookDeclNameSpan = nameSpan
      , hookDeclIdentity = "hook:" <> name
      , hookDeclTrigger =
          HookTriggerDecl
            { hookTriggerDeclEvent = triggerEvent
            , hookTriggerDeclSpan = triggerSpan
            }
      , hookDeclRequestType = requestTypeName
      , hookDeclRequestDecl = RouteBoundaryDecl requestTypeName
      , hookDeclRequestTypeSpan = requestTypeSpan
      , hookDeclResponseType = responseTypeName
      , hookDeclResponseDecl = RouteBoundaryDecl responseTypeName
      , hookDeclResponseTypeSpan = responseTypeSpan
      , hookDeclHandlerName = handlerName
      , hookDeclHandlerSpan = handlerSpan
      }

agentRoleDeclParser :: Parser TopLevelItem
agentRoleDeclParser = do
  start <- getSourcePos
  keyword "role"
  (nameSpan, name) <- locatedUpperIdentifier
  _ <- symbol "="
  attrs <- agentRoleAttrParser `sepBy1` symbol ","
  end <- getSourcePos
  _ <- optional eol
  scn
  (guideSpan, guideName, policySpan, policyName, approvalPolicy, sandboxPolicy) <-
    case foldM applyAgentRoleAttr (Nothing, Nothing, Nothing, Nothing) attrs of
      Left message ->
        fail message
      Right (Just guideDecl, Just policyDecl, approvalDecl, sandboxDecl) ->
        pure (fst guideDecl, snd guideDecl, fst policyDecl, snd policyDecl, approvalDecl, sandboxDecl)
      Right (Nothing, _, _, _) ->
        fail "agent role declaration requires a `guide` attribute"
      Right (_, Nothing, _, _) ->
        fail "agent role declaration requires a `policy` attribute"
  pure . TopAgentRoleDecl $
    AgentRoleDecl
      { agentRoleDeclName = name
      , agentRoleDeclSpan = makeSourceSpan start end
      , agentRoleDeclNameSpan = nameSpan
      , agentRoleDeclIdentity = "agent-role:" <> name
      , agentRoleDeclGuideName = guideName
      , agentRoleDeclGuideSpan = guideSpan
      , agentRoleDeclPolicyName = policyName
      , agentRoleDeclPolicySpan = policySpan
      , agentRoleDeclApprovalPolicy = approvalPolicy
      , agentRoleDeclSandboxPolicy = sandboxPolicy
      }

agentRoleAttrParser :: Parser AgentRoleAttr
agentRoleAttrParser =
  try agentRoleGuideAttrParser
    <|> try agentRolePolicyAttrParser
    <|> try agentRoleApprovalAttrParser
    <|> agentRoleSandboxAttrParser

agentRoleGuideAttrParser :: Parser AgentRoleAttr
agentRoleGuideAttrParser = do
  keyword "guide"
  _ <- symbol ":"
  uncurry AgentRoleGuideAttr <$> locatedUpperIdentifier

agentRolePolicyAttrParser :: Parser AgentRoleAttr
agentRolePolicyAttrParser = do
  keyword "policy"
  _ <- symbol ":"
  uncurry AgentRolePolicyAttr <$> locatedUpperIdentifier

agentRoleApprovalAttrParser :: Parser AgentRoleAttr
agentRoleApprovalAttrParser = do
  keyword "approval"
  _ <- symbol ":"
  AgentRoleApprovalAttr <$> agentRoleApprovalPolicyParser

agentRoleSandboxAttrParser :: Parser AgentRoleAttr
agentRoleSandboxAttrParser = do
  keyword "sandbox"
  _ <- symbol ":"
  AgentRoleSandboxAttr <$> agentRoleSandboxPolicyParser

agentRoleApprovalPolicyParser :: Parser AgentRoleApprovalPolicy
agentRoleApprovalPolicyParser =
  keyword "never" *> pure AgentRoleApprovalNever
    <|> keyword "on_failure" *> pure AgentRoleApprovalOnFailure
    <|> keyword "on_request" *> pure AgentRoleApprovalOnRequest
    <|> keyword "untrusted" *> pure AgentRoleApprovalUntrusted

agentRoleSandboxPolicyParser :: Parser AgentRoleSandboxPolicy
agentRoleSandboxPolicyParser =
  keyword "read_only" *> pure AgentRoleSandboxReadOnly
    <|> keyword "workspace_write" *> pure AgentRoleSandboxWorkspaceWrite
    <|> keyword "danger_full_access" *> pure AgentRoleSandboxDangerFullAccess

applyAgentRoleAttr ::
  ( Maybe (SourceSpan, Text)
  , Maybe (SourceSpan, Text)
  , Maybe AgentRoleApprovalPolicy
  , Maybe AgentRoleSandboxPolicy
  ) ->
  AgentRoleAttr ->
  Either String
    ( Maybe (SourceSpan, Text)
    , Maybe (SourceSpan, Text)
    , Maybe AgentRoleApprovalPolicy
    , Maybe AgentRoleSandboxPolicy
    )
applyAgentRoleAttr (guideDecl, policyDecl, approvalDecl, sandboxDecl) attr =
  case attr of
    AgentRoleGuideAttr span' name ->
      case guideDecl of
        Just _ -> Left "agent role declaration cannot declare `guide` more than once"
        Nothing -> Right (Just (span', name), policyDecl, approvalDecl, sandboxDecl)
    AgentRolePolicyAttr span' name ->
      case policyDecl of
        Just _ -> Left "agent role declaration cannot declare `policy` more than once"
        Nothing -> Right (guideDecl, Just (span', name), approvalDecl, sandboxDecl)
    AgentRoleApprovalAttr approvalPolicy ->
      case approvalDecl of
        Just _ -> Left "agent role declaration cannot declare `approval` more than once"
        Nothing -> Right (guideDecl, policyDecl, Just approvalPolicy, sandboxDecl)
    AgentRoleSandboxAttr sandboxPolicy ->
      case sandboxDecl of
        Just _ -> Left "agent role declaration cannot declare `sandbox` more than once"
        Nothing -> Right (guideDecl, policyDecl, approvalDecl, Just sandboxPolicy)

agentDeclParser :: Parser TopLevelItem
agentDeclParser = do
  start <- getSourcePos
  keyword "agent"
  (nameSpan, name) <- locatedLowerIdentifier
  _ <- symbol "="
  (roleSpan, roleName) <- locatedUpperIdentifier
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopAgentDecl $
    AgentDecl
      { agentDeclName = name
      , agentDeclSpan = makeSourceSpan start end
      , agentDeclNameSpan = nameSpan
      , agentDeclIdentity = "agent:" <> name
      , agentDeclRoleName = roleName
      , agentDeclRoleSpan = roleSpan
      }

guideDeclParser :: Parser TopLevelItem
guideDeclParser = do
  start <- getSourcePos
  keyword "guide"
  (nameSpan, name) <- locatedUpperIdentifier
  extendsDecl <- optional (keyword "extends" *> locatedUpperIdentifier)
  _ <- symbol "="
  entries <- braces (guideEntryDeclParser `sepBy` symbolN ",")
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopGuideDecl $
    GuideDecl
      { guideDeclName = name
      , guideDeclSpan = makeSourceSpan start end
      , guideDeclNameSpan = nameSpan
      , guideDeclExtends = snd <$> extendsDecl
      , guideDeclExtendsSpan = fst <$> extendsDecl
      , guideDeclEntries = entries
      }

guideEntryDeclParser :: Parser GuideEntryDecl
guideEntryDeclParser = do
  start <- getSourcePos
  (_, entryName) <- locatedLowerIdentifierN
  _ <- symbolN ":"
  (valueSpan, entryValue) <- locatedStringLiteral
  end <- getSourcePos
  pure
    GuideEntryDecl
      { guideEntryDeclName = entryName
      , guideEntryDeclSpan = makeSourceSpan start end
      , guideEntryDeclValue = entryValue
      , guideEntryDeclValueSpan = valueSpan
      }

foreignDeclParser :: Parser TopLevelItem
foreignDeclParser = do
  start <- getSourcePos
  keyword "foreign"
  unsafeInterop <- maybe False (const True) <$> optional (keyword "unsafe")
  (nameSpan, name) <- locatedLowerIdentifier
  annotationStart <- getSourcePos
  _ <- symbol ":"
  foreignType <- typeParser
  annotationEnd <- getSourcePos
  _ <- symbol "="
  (runtimeSpan, runtimeName) <- locatedStringLiteral
  packageImport <- optional foreignPackageImportParser
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopForeignDecl $
    ForeignDecl
      { foreignDeclName = name
      , foreignDeclSpan = makeSourceSpan start end
      , foreignDeclNameSpan = nameSpan
      , foreignDeclUnsafeInterop = unsafeInterop
      , foreignDeclAnnotationSpan = makeSourceSpan annotationStart annotationEnd
      , foreignDeclType = foreignType
      , foreignDeclRuntimeName = runtimeName
      , foreignDeclRuntimeSpan = runtimeSpan
      , foreignDeclPackageImport = packageImport
      }

foreignPackageImportParser :: Parser ForeignPackageImport
foreignPackageImportParser = do
  keyword "from"
  kindStart <- getSourcePos
  kind <-
    (keyword "npm" >> pure ForeignPackageImportNpm)
      <|> (keyword "typescript" >> pure ForeignPackageImportTypeScript)
  kindEnd <- getSourcePos
  (specifierSpan, specifier) <- locatedStringLiteral
  keyword "declaration"
  (declarationSpan, declarationPath) <- locatedStringLiteral
  pure
    ForeignPackageImport
      { foreignPackageImportKind = kind
      , foreignPackageImportKindSpan = makeSourceSpan kindStart kindEnd
      , foreignPackageImportSpecifier = specifier
      , foreignPackageImportSpecifierSpan = specifierSpan
      , foreignPackageImportDeclarationPath = declarationPath
      , foreignPackageImportDeclarationSpan = declarationSpan
      , foreignPackageImportSignature = Nothing
      }

toolServerDeclParser :: Parser TopLevelItem
toolServerDeclParser = do
  start <- getSourcePos
  keyword "toolserver"
  (nameSpan, name) <- locatedUpperIdentifier
  _ <- symbol "="
  (protocolSpan, protocolName) <- locatedStringLiteral
  (locationSpan, locationName) <- locatedStringLiteral
  keyword "with"
  (policySpan, policyName) <- locatedUpperIdentifier
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopToolServerDecl $
    ToolServerDecl
      { toolServerDeclName = name
      , toolServerDeclSpan = makeSourceSpan start end
      , toolServerDeclNameSpan = nameSpan
      , toolServerDeclIdentity = "toolserver:" <> name
      , toolServerDeclProtocol = protocolName
      , toolServerDeclProtocolSpan = protocolSpan
      , toolServerDeclLocation = locationName
      , toolServerDeclLocationSpan = locationSpan
      , toolServerDeclPolicyName = policyName
      , toolServerDeclPolicySpan = policySpan
      }

toolDeclParser :: Parser TopLevelItem
toolDeclParser = do
  start <- getSourcePos
  keyword "tool"
  (nameSpan, name) <- locatedLowerIdentifier
  _ <- symbol "="
  (serverSpan, serverName) <- locatedUpperIdentifier
  (operationSpan, operationName) <- locatedStringLiteral
  (requestTypeSpan, requestTypeName) <- locatedUpperIdentifier
  _ <- symbol "->"
  (responseTypeSpan, responseTypeName) <- locatedUpperIdentifier
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopToolDecl $
    ToolDecl
      { toolDeclName = name
      , toolDeclSpan = makeSourceSpan start end
      , toolDeclNameSpan = nameSpan
      , toolDeclIdentity = "tool:" <> name
      , toolDeclServerName = serverName
      , toolDeclServerSpan = serverSpan
      , toolDeclOperation = operationName
      , toolDeclOperationSpan = operationSpan
      , toolDeclRequestType = requestTypeName
      , toolDeclRequestDecl = RouteBoundaryDecl requestTypeName
      , toolDeclRequestTypeSpan = requestTypeSpan
      , toolDeclResponseType = responseTypeName
      , toolDeclResponseDecl = RouteBoundaryDecl responseTypeName
      , toolDeclResponseTypeSpan = responseTypeSpan
      }

verifierDeclParser :: Parser TopLevelItem
verifierDeclParser = do
  start <- getSourcePos
  keyword "verifier"
  (nameSpan, name) <- locatedLowerIdentifier
  _ <- symbol "="
  (toolSpan, toolName) <- locatedLowerIdentifier
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopVerifierDecl $
    VerifierDecl
      { verifierDeclName = name
      , verifierDeclSpan = makeSourceSpan start end
      , verifierDeclNameSpan = nameSpan
      , verifierDeclIdentity = "verifier:" <> name
      , verifierDeclToolName = toolName
      , verifierDeclToolSpan = toolSpan
      }

mergeGateDeclParser :: Parser TopLevelItem
mergeGateDeclParser = do
  start <- getSourcePos
  keyword "mergegate"
  (nameSpan, name) <- locatedLowerIdentifier
  _ <- symbol "="
  verifierRefs <- mergeGateVerifierRefParser `sepBy1` symbol ","
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopMergeGateDecl $
    MergeGateDecl
      { mergeGateDeclName = name
      , mergeGateDeclSpan = makeSourceSpan start end
      , mergeGateDeclNameSpan = nameSpan
      , mergeGateDeclIdentity = "mergegate:" <> name
      , mergeGateDeclVerifierRefs = verifierRefs
      }

mergeGateVerifierRefParser :: Parser MergeGateVerifierRef
mergeGateVerifierRefParser = do
  (span', name) <- locatedLowerIdentifierN
  pure
    MergeGateVerifierRef
      { mergeGateVerifierRefName = name
      , mergeGateVerifierRefSpan = span'
      }

routeDeclParser :: Parser TopLevelItem
routeDeclParser = do
  start <- getSourcePos
  keyword "route"
  (nameSpan, name) <- locatedLowerIdentifier
  _ <- symbol "="
  method <- routeMethodParser
  (pathSpan, routePath) <- locatedStringLiteral
  (requestTypeSpan, requestTypeName) <- locatedUpperIdentifier
  _ <- symbol "->"
  (responseTypeSpan, responseTypeName) <- locatedUpperIdentifier
  (handlerSpan, handlerName) <- locatedLowerIdentifier
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopRouteDecl $
    RouteDecl
      { routeDeclName = name
      , routeDeclSpan = makeSourceSpan start end
      , routeDeclNameSpan = nameSpan
      , routeDeclIdentity = "route:" <> name
      , routeDeclMethod = method
      , routeDeclPath = routePath
      , routeDeclPathDecl =
          RoutePathDecl
            { routePathDeclPattern = routePath
            , routePathDeclParams = []
            }
      , routeDeclPathSpan = pathSpan
      , routeDeclRequestType = requestTypeName
      , routeDeclQueryDecl =
          case method of
            RouteGet -> Just (RouteBoundaryDecl requestTypeName)
            RoutePost -> Nothing
      , routeDeclFormDecl =
          case method of
            RoutePost
              | responseTypeName == "Page" || responseTypeName == "Redirect" ->
                  Just (RouteBoundaryDecl requestTypeName)
            _ ->
              Nothing
      , routeDeclBodyDecl =
          case method of
            RoutePost
              | responseTypeName /= "Page" && responseTypeName /= "Redirect" ->
                  Just (RouteBoundaryDecl requestTypeName)
            _ ->
              Nothing
      , routeDeclRequestTypeSpan = requestTypeSpan
      , routeDeclResponseType = responseTypeName
      , routeDeclResponseDecl = RouteBoundaryDecl responseTypeName
      , routeDeclResponseTypeSpan = responseTypeSpan
      , routeDeclHandlerName = handlerName
      , routeDeclHandlerSpan = handlerSpan
      }

routeMethodParser :: Parser RouteMethod
routeMethodParser =
  (keyword "GET" *> pure RouteGet)
    <|> (keyword "POST" *> pure RoutePost)

recordDeclParser :: Parser TopLevelItem
recordDeclParser = do
  start <- getSourcePos
  keyword "record"
  (nameSpan, name) <- locatedUpperIdentifier
  params <- many lowerIdentifier
  _ <- symbol "="
  fields <- braces (recordFieldDeclParser `sepBy` symbolN ",")
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopRecordDecl $
    RecordDecl
      { recordDeclName = name
      , recordDeclSpan = makeSourceSpan start end
      , recordDeclNameSpan = nameSpan
      , recordDeclParams = params
      , recordDeclProjectionSource = Nothing
      , recordDeclProjectionPolicy = Nothing
      , recordDeclFields = fields
      }

recordFieldDeclParser :: Parser RecordFieldDecl
recordFieldDeclParser = do
  start <- getSourcePos
  (_, fieldName) <- locatedLowerIdentifierN
  _ <- symbolN ":"
  fieldType <- typeParser
  classification <- optional (keywordN "classified" *> lowerIdentifier)
  end <- getSourcePos
  pure
    RecordFieldDecl
      { recordFieldDeclName = fieldName
      , recordFieldDeclSpan = makeSourceSpan start end
      , recordFieldDeclType = fieldType
      , recordFieldDeclClassification = fromMaybe "public" classification
      }

domainDeclParser :: Parser TopLevelItem
domainDeclParser = do
  keyword "domain"
  try domainObjectDeclParser <|> domainEventDeclParser

domainObjectDeclParser :: Parser TopLevelItem
domainObjectDeclParser = do
  start <- getSourcePos
  keyword "object"
  (nameSpan, name) <- locatedUpperIdentifier
  _ <- symbol "="
  (schemaSpan, schemaName) <- locatedUpperIdentifier
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopDomainObjectDecl $
    DomainObjectDecl
      { domainObjectDeclName = name
      , domainObjectDeclSpan = makeSourceSpan start end
      , domainObjectDeclNameSpan = nameSpan
      , domainObjectDeclIdentity = "domain-object:" <> name
      , domainObjectDeclSchemaName = schemaName
      , domainObjectDeclSchemaSpan = schemaSpan
      }

domainEventDeclParser :: Parser TopLevelItem
domainEventDeclParser = do
  start <- getSourcePos
  keyword "event"
  (nameSpan, name) <- locatedUpperIdentifier
  _ <- symbol "="
  (schemaSpan, schemaName) <- locatedUpperIdentifier
  keyword "for"
  (objectSpan, objectName) <- locatedUpperIdentifier
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopDomainEventDecl $
    DomainEventDecl
      { domainEventDeclName = name
      , domainEventDeclSpan = makeSourceSpan start end
      , domainEventDeclNameSpan = nameSpan
      , domainEventDeclIdentity = "domain-event:" <> name
      , domainEventDeclSchemaName = schemaName
      , domainEventDeclSchemaSpan = schemaSpan
      , domainEventDeclObjectName = objectName
      , domainEventDeclObjectSpan = objectSpan
      }

metricDeclParser :: Parser TopLevelItem
metricDeclParser = do
  start <- getSourcePos
  keyword "metric"
  (nameSpan, name) <- locatedUpperIdentifier
  _ <- symbol "="
  (schemaSpan, schemaName) <- locatedUpperIdentifier
  keyword "for"
  (objectSpan, objectName) <- locatedUpperIdentifier
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopMetricDecl $
    MetricDecl
      { metricDeclName = name
      , metricDeclSpan = makeSourceSpan start end
      , metricDeclNameSpan = nameSpan
      , metricDeclIdentity = "metric:" <> name
      , metricDeclSchemaName = schemaName
      , metricDeclSchemaSpan = schemaSpan
      , metricDeclObjectName = objectName
      , metricDeclObjectSpan = objectSpan
      }

feedbackDeclParser :: Parser TopLevelItem
feedbackDeclParser = do
  start <- getSourcePos
  keyword "feedback"
  feedbackKind <- feedbackKindParser
  (nameSpan, name) <- locatedUpperIdentifier
  _ <- symbol "="
  (schemaSpan, schemaName) <- locatedUpperIdentifier
  keyword "for"
  (objectSpan, objectName) <- locatedUpperIdentifier
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopFeedbackDecl $
    FeedbackDecl
      { feedbackDeclName = name
      , feedbackDeclSpan = makeSourceSpan start end
      , feedbackDeclNameSpan = nameSpan
      , feedbackDeclIdentity = "feedback:" <> name
      , feedbackDeclKind = feedbackKind
      , feedbackDeclSchemaName = schemaName
      , feedbackDeclSchemaSpan = schemaSpan
      , feedbackDeclObjectName = objectName
      , feedbackDeclObjectSpan = objectSpan
      }

feedbackKindParser :: Parser FeedbackKind
feedbackKindParser =
  (FeedbackOperational <$ keyword "operational")
    <|> (FeedbackBusiness <$ keyword "business")

goalDeclParser :: Parser TopLevelItem
goalDeclParser = do
  start <- getSourcePos
  keyword "goal"
  (nameSpan, name) <- locatedUpperIdentifier
  _ <- symbol "="
  (metricSpan, metricName) <- locatedUpperIdentifier
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopGoalDecl $
    GoalDecl
      { goalDeclName = name
      , goalDeclSpan = makeSourceSpan start end
      , goalDeclNameSpan = nameSpan
      , goalDeclIdentity = "goal:" <> name
      , goalDeclMetricName = metricName
      , goalDeclMetricSpan = metricSpan
      }

experimentDeclParser :: Parser TopLevelItem
experimentDeclParser = do
  start <- getSourcePos
  keyword "experiment"
  (nameSpan, name) <- locatedUpperIdentifier
  _ <- symbol "="
  (goalSpan, goalName) <- locatedUpperIdentifier
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopExperimentDecl $
    ExperimentDecl
      { experimentDeclName = name
      , experimentDeclSpan = makeSourceSpan start end
      , experimentDeclNameSpan = nameSpan
      , experimentDeclIdentity = "experiment:" <> name
      , experimentDeclGoalName = goalName
      , experimentDeclGoalSpan = goalSpan
      }

rolloutDeclParser :: Parser TopLevelItem
rolloutDeclParser = do
  start <- getSourcePos
  keyword "rollout"
  (nameSpan, name) <- locatedUpperIdentifier
  _ <- symbol "="
  (experimentSpan, experimentName) <- locatedUpperIdentifier
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopRolloutDecl $
    RolloutDecl
      { rolloutDeclName = name
      , rolloutDeclSpan = makeSourceSpan start end
      , rolloutDeclNameSpan = nameSpan
      , rolloutDeclIdentity = "rollout:" <> name
      , rolloutDeclExperimentName = experimentName
      , rolloutDeclExperimentSpan = experimentSpan
      }

data WorkflowAttr
  = WorkflowStateAttr SourceSpan Type
  | WorkflowInvariantAttr SourceSpan Text
  | WorkflowPreconditionAttr SourceSpan Text
  | WorkflowPostconditionAttr SourceSpan Text

workflowDeclParser :: Parser TopLevelItem
workflowDeclParser = do
  start <- getSourcePos
  keyword "workflow"
  (nameSpan, name) <- locatedUpperIdentifier
  _ <- symbol "="
  attrs <- braces (workflowAttrParser `sepBy` symbolN ",")
  end <- getSourcePos
  _ <- optional eol
  scn
  (stateTypeSpan, stateType, invariantDecl, preconditionDecl, postconditionDecl) <-
    case foldM applyWorkflowAttr (Nothing, Nothing, Nothing, Nothing) attrs of
      Left message ->
        fail message
      Right (Just stateDecl, invariantDecl, preconditionDecl, postconditionDecl) ->
        pure (fst stateDecl, snd stateDecl, invariantDecl, preconditionDecl, postconditionDecl)
      Right (Nothing, _, _, _) ->
        fail "workflow declaration requires a `state` attribute"
  pure . TopWorkflowDecl $
    WorkflowDecl
      { workflowDeclName = name
      , workflowDeclSpan = makeSourceSpan start end
      , workflowDeclNameSpan = nameSpan
      , workflowDeclIdentity = "workflow:" <> name
      , workflowDeclStateType = stateType
      , workflowDeclStateTypeSpan = stateTypeSpan
      , workflowDeclInvariantName = snd <$> invariantDecl
      , workflowDeclInvariantSpan = fst <$> invariantDecl
      , workflowDeclPreconditionName = snd <$> preconditionDecl
      , workflowDeclPreconditionSpan = fst <$> preconditionDecl
      , workflowDeclPostconditionName = snd <$> postconditionDecl
      , workflowDeclPostconditionSpan = fst <$> postconditionDecl
      }

workflowAttrParser :: Parser WorkflowAttr
workflowAttrParser =
  try workflowStateAttrParser
    <|> try workflowInvariantAttrParser
    <|> try workflowPreconditionAttrParser
    <|> workflowPostconditionAttrParser

workflowStateAttrParser :: Parser WorkflowAttr
workflowStateAttrParser = do
  keywordN "state"
  start <- getSourcePos
  _ <- symbolN ":"
  stateType <- typeParser
  end <- getSourcePos
  pure (WorkflowStateAttr (makeSourceSpan start end) stateType)

workflowInvariantAttrParser :: Parser WorkflowAttr
workflowInvariantAttrParser = do
  keywordN "invariant"
  start <- getSourcePos
  _ <- symbolN ":"
  (_, name) <- locatedLowerIdentifierN
  end <- getSourcePos
  pure (WorkflowInvariantAttr (makeSourceSpan start end) name)

workflowPreconditionAttrParser :: Parser WorkflowAttr
workflowPreconditionAttrParser = do
  keywordN "precondition"
  start <- getSourcePos
  _ <- symbolN ":"
  (_, name) <- locatedLowerIdentifierN
  end <- getSourcePos
  pure (WorkflowPreconditionAttr (makeSourceSpan start end) name)

workflowPostconditionAttrParser :: Parser WorkflowAttr
workflowPostconditionAttrParser = do
  keywordN "postcondition"
  start <- getSourcePos
  _ <- symbolN ":"
  (_, name) <- locatedLowerIdentifierN
  end <- getSourcePos
  pure (WorkflowPostconditionAttr (makeSourceSpan start end) name)

applyWorkflowAttr ::
  ( Maybe (SourceSpan, Type)
  , Maybe (SourceSpan, Text)
  , Maybe (SourceSpan, Text)
  , Maybe (SourceSpan, Text)
  ) ->
  WorkflowAttr ->
  Either
    String
    ( Maybe (SourceSpan, Type)
    , Maybe (SourceSpan, Text)
    , Maybe (SourceSpan, Text)
    , Maybe (SourceSpan, Text)
    )
applyWorkflowAttr (existingState, existingInvariant, existingPrecondition, existingPostcondition) attr =
  case attr of
    WorkflowStateAttr stateTypeSpan stateType ->
      case existingState of
        Just _ ->
          Left "workflow declaration may only declare `state` once"
        Nothing ->
          Right (Just (stateTypeSpan, stateType), existingInvariant, existingPrecondition, existingPostcondition)
    WorkflowInvariantAttr invariantSpan invariantName ->
      case existingInvariant of
        Just _ ->
          Left "workflow declaration may only declare `invariant` once"
        Nothing ->
          Right (existingState, Just (invariantSpan, invariantName), existingPrecondition, existingPostcondition)
    WorkflowPreconditionAttr preconditionSpan preconditionName ->
      case existingPrecondition of
        Just _ ->
          Left "workflow declaration may only declare `precondition` once"
        Nothing ->
          Right (existingState, existingInvariant, Just (preconditionSpan, preconditionName), existingPostcondition)
    WorkflowPostconditionAttr postconditionSpan postconditionName ->
      case existingPostcondition of
        Just _ ->
          Left "workflow declaration may only declare `postcondition` once"
        Nothing ->
          Right (existingState, existingInvariant, existingPrecondition, Just (postconditionSpan, postconditionName))

supervisorDeclParser :: Parser TopLevelItem
supervisorDeclParser = do
  start <- getSourcePos
  keyword "supervisor"
  (nameSpan, name) <- locatedUpperIdentifier
  _ <- symbol "="
  restartStrategy <- supervisorRestartStrategyParser
  children <- braces (supervisorChildParser `sepBy` symbolN ",")
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopSupervisorDecl $
    SupervisorDecl
      { supervisorDeclName = name
      , supervisorDeclSpan = makeSourceSpan start end
      , supervisorDeclNameSpan = nameSpan
      , supervisorDeclIdentity = "supervisor:" <> name
      , supervisorDeclRestartStrategy = restartStrategy
      , supervisorDeclChildren = children
      }

supervisorRestartStrategyParser :: Parser SupervisorRestartStrategy
supervisorRestartStrategyParser =
  keyword "one_for_one" *> pure SupervisorOneForOne
    <|> keyword "one_for_all" *> pure SupervisorOneForAll
    <|> keyword "rest_for_one" *> pure SupervisorRestForOne

supervisorChildParser :: Parser SupervisorChildDecl
supervisorChildParser =
  try workflowChildParser
    <|> supervisorChildSupervisorParser
  where
    workflowChildParser = do
      keywordN "workflow"
      (childSpan, childName) <- locatedUpperIdentifierN
      pure (SupervisorWorkflowChild childName childSpan)
    supervisorChildSupervisorParser = do
      keywordN "supervisor"
      (childSpan, childName) <- locatedUpperIdentifierN
      pure (SupervisorSupervisorChild childName childSpan)

policyDeclParser :: Parser TopLevelItem
policyDeclParser = do
  start <- getSourcePos
  keyword "policy"
  (nameSpan, name) <- locatedUpperIdentifier
  _ <- symbol "="
  classifications <- policyClassificationParser `sepBy1` symbolN ","
  permissions <- fromMaybe [] <$> optional policyPermissionsParser
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopPolicyDecl $
    PolicyDecl
      { policyDeclName = name
      , policyDeclSpan = makeSourceSpan start end
      , policyDeclNameSpan = nameSpan
      , policyDeclAllowedClassifications = classifications
      , policyDeclPermissions = permissions
      }

policyClassificationParser :: Parser PolicyClassificationDecl
policyClassificationParser = do
  (classificationSpan, classificationName) <- locatedLowerIdentifierN
  pure
    PolicyClassificationDecl
      { policyClassificationDeclName = classificationName
      , policyClassificationDeclSpan = classificationSpan
      }

policyPermissionsParser :: Parser [PolicyPermissionDecl]
policyPermissionsParser = do
  keywordN "permits"
  braces (policyPermissionParser `sepBy` symbolN ",")

policyPermissionParser :: Parser PolicyPermissionDecl
policyPermissionParser = do
  start <- getSourcePos
  permissionKind <- policyPermissionKindParser
  (_, permissionValue) <- locatedStringLiteral
  end <- getSourcePos
  pure
    PolicyPermissionDecl
      { policyPermissionDeclKind = permissionKind
      , policyPermissionDeclSpan = makeSourceSpan start end
      , policyPermissionDeclValue = permissionValue
      }

policyPermissionKindParser :: Parser PolicyPermissionKind
policyPermissionKindParser =
  (keywordN "file" *> pure PolicyPermissionFile)
    <|> (keywordN "network" *> pure PolicyPermissionNetwork)
    <|> (keywordN "process" *> pure PolicyPermissionProcess)
    <|> (keywordN "secret" *> pure PolicyPermissionSecret)

projectionDeclParser :: Parser TopLevelItem
projectionDeclParser = do
  start <- getSourcePos
  keyword "projection"
  (nameSpan, name) <- locatedUpperIdentifier
  _ <- symbol "="
  (sourceSpan, sourceRecordName) <- locatedUpperIdentifier
  keyword "with"
  (policySpan, policyName) <- locatedUpperIdentifier
  fields <- braces (projectionFieldDeclParser `sepBy` symbolN ",")
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopProjectionDecl $
    ProjectionDecl
      { projectionDeclName = name
      , projectionDeclSpan = makeSourceSpan start end
      , projectionDeclNameSpan = nameSpan
      , projectionDeclSourceRecordName = sourceRecordName
      , projectionDeclSourceRecordSpan = sourceSpan
      , projectionDeclPolicyName = policyName
      , projectionDeclPolicySpan = policySpan
      , projectionDeclFields = fields
      }

projectionFieldDeclParser :: Parser ProjectionFieldDecl
projectionFieldDeclParser = do
  (fieldSpan, fieldName) <- locatedLowerIdentifierN
  pure
    ProjectionFieldDecl
      { projectionFieldDeclName = fieldName
      , projectionFieldDeclSpan = fieldSpan
      }

typeDeclParser :: Parser TopLevelItem
typeDeclParser = do
  start <- getSourcePos
  keyword "type"
  (nameSpan, name) <- locatedUpperIdentifier
  params <- many lowerIdentifier
  _ <- symbol "="
  constructors <- constructorDeclParser `sepBy1` symbol "|"
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopTypeDecl $
    TypeDecl
      { typeDeclName = name
      , typeDeclSpan = makeSourceSpan start end
      , typeDeclNameSpan = nameSpan
      , typeDeclParams = params
      , typeDeclConstructors = constructors
      }

constructorDeclParser :: Parser ConstructorDecl
constructorDeclParser = do
  start <- getSourcePos
  (nameSpan, name) <- locatedUpperIdentifier
  fields <- many constructorFieldTypeParser
  end <- getSourcePos
  pure
    ConstructorDecl
      { constructorDeclName = name
      , constructorDeclSpan = makeSourceSpan start end
      , constructorDeclNameSpan = nameSpan
      , constructorDeclFields = fields
      }

constructorFieldTypeParser :: Parser Type
constructorFieldTypeParser =
  parens typeParser <|> typeBaseParser

typeSignatureParser :: Parser TopLevelItem
typeSignatureParser = do
  start <- getSourcePos
  (_, name) <- locatedLowerIdentifier
  _ <- symbol ":"
  annotatedType <- typeParser
  end <- getSourcePos
  _ <- optional eol
  scn
  pure (TopSignature name annotatedType (makeSourceSpan start end))

declParser :: Parser Decl
declParser = do
  start <- getSourcePos
  (nameSpan, name) <- locatedLowerIdentifier
  params <- many lowerIdentifier
  _ <- symbol "="
  body <- exprParser
  end <- getSourcePos
  _ <- optional eol
  scn
  pure Decl
    { declName = name
    , declSpan = makeSourceSpan start end
    , declNameSpan = nameSpan
    , declAnnotationSpan = Nothing
    , declAnnotation = Nothing
    , declParams = params
    , declBody = body
    }

exprParser :: Parser Expr
exprParser =
  letExprParser <|> ifExprParser <|> equalityExprParser

ifExprParser :: Parser Expr
ifExprParser = do
  start <- getSourcePos
  keyword "if"
  condition <- exprParser
  keyword "then"
  thenBranch <- exprParser
  keyword "else"
  elseBranch <- exprParser
  pure (EIf (mergeSourceSpans (makeSourceSpan start start) (exprSpan elseBranch)) condition thenBranch elseBranch)

equalityExprParser :: Parser Expr
equalityExprParser = do
  firstTerm <- comparisonExprParser
  rest <- many ((,) <$> equalityOperatorParser <*> comparisonExprParser)
  pure (foldl applyEqualityExpr firstTerm rest)

comparisonExprParser :: Parser Expr
comparisonExprParser = do
  firstTerm <- appExprParser
  rest <- optional ((,) <$> comparisonOperatorParser <*> appExprParser)
  pure $
    case rest of
      Just comparison ->
        applyComparisonExpr firstTerm comparison
      Nothing ->
        firstTerm

appExprParser :: Parser Expr
appExprParser = do
  terms <- some (try termParser)
  case terms of
    firstTerm : remainingTerms ->
      pure (foldl applyExpr firstTerm remainingTerms)
    [] ->
      fail "expected at least one expression term"

letExprParser :: Parser Expr
letExprParser = do
  start <- getSourcePos
  keyword "let"
  (nameSpan, name) <- locatedLowerIdentifier
  _ <- symbol "="
  value <- exprParser
  keyword "in"
  body <- exprParser
  pure (ELet (mergeSourceSpans (makeSourceSpan start start) (exprSpan body)) nameSpan name value body)

termParser :: Parser Expr
termParser = do
  baseExpr <- baseExprParser
  fieldAccesses <- many fieldAccessSuffixParser
  pure (foldl applyFieldAccess baseExpr fieldAccesses)

baseExprParser :: Parser Expr
baseExprParser =
  parens exprParser
    <|> blockExprParser
    <|> returnParser
    <|> decodeParser
    <|> encodeParser
    <|> matchParser
    <|> listExprParser
    <|> boolParser
    <|> intParser
    <|> stringParser
    <|> try recordExprParser
    <|> constructorExprParser
    <|> variableParser

matchParser :: Parser Expr
matchParser = do
  start <- getSourcePos
  keyword "match"
  subject <- exprParser
  branches <- braces (matchBranchParser `sepBy1` symbolN ",")
  end <- getSourcePos
  pure (EMatch (makeSourceSpan start end) subject branches)

matchBranchParser :: Parser MatchBranch
matchBranchParser = do
  start <- getSourcePos
  pattern' <- patternParser
  _ <- symbolN "->"
  body <- exprParser
  end <- getSourcePos
  pure
    MatchBranch
      { matchBranchSpan = makeSourceSpan start end
      , matchBranchPattern = pattern'
      , matchBranchBody = body
      }

blockExprParser :: Parser Expr
blockExprParser = do
  start <- getSourcePos
  _ <- L.symbol scn "{"
  scn
  bindings <- many (try blockBindingParser)
  body <- exprParser
  scn
  _ <- symbol "}"
  end <- getSourcePos
  pure (EBlock (makeSourceSpan start end) (foldr applyBlockBinding body bindings))

blockBindingParser :: Parser BlockBinding
blockBindingParser = do
  try mutableBlockBindingParser
    <|> try immutableBlockBindingParser
    <|> try forBlockBindingParser
    <|> assignmentBlockBindingParser

mutableBlockBindingParser :: Parser BlockBinding
mutableBlockBindingParser = do
  start <- getSourcePos
  keywordN "let"
  keywordN "mut"
  (nameSpan, name) <- locatedLowerIdentifier
  _ <- symbol "="
  value <- exprParser
  blockSeparatorParser
  pure (BlockMutableLetBinding start nameSpan name value)

immutableBlockBindingParser :: Parser BlockBinding
immutableBlockBindingParser = do
  start <- getSourcePos
  keywordN "let"
  (nameSpan, name) <- locatedLowerIdentifier
  _ <- symbol "="
  value <- exprParser
  blockSeparatorParser
  pure (BlockLetBinding start nameSpan name value)

assignmentBlockBindingParser :: Parser BlockBinding
assignmentBlockBindingParser = do
  start <- getSourcePos
  (nameSpan, name) <- locatedLowerIdentifierN
  _ <- symbolN "="
  value <- exprParser
  blockSeparatorParser
  pure (BlockAssignBinding start nameSpan name value)

forBlockBindingParser :: Parser BlockBinding
forBlockBindingParser = do
  start <- getSourcePos
  keywordN "for"
  (nameSpan, name) <- locatedLowerIdentifier
  keyword "in"
  iterable <- forIterableExprParser
  body <- blockExprParser
  blockSeparatorParser
  pure (BlockForBinding start nameSpan name iterable body)

blockSeparatorParser :: Parser ()
blockSeparatorParser =
  void (symbolN ";")
    <|> void (some eol *> scn)

forIterableExprParser :: Parser Expr
forIterableExprParser =
  letExprParser <|> forEqualityExprParser

forEqualityExprParser :: Parser Expr
forEqualityExprParser = do
  firstTerm <- forComparisonExprParser
  rest <- many ((,) <$> equalityOperatorParser <*> forComparisonExprParser)
  pure (foldl applyEqualityExpr firstTerm rest)

forComparisonExprParser :: Parser Expr
forComparisonExprParser = do
  firstTerm <- forAppExprParser
  rest <- optional ((,) <$> comparisonOperatorParser <*> forAppExprParser)
  pure $
    case rest of
      Just comparison ->
        applyComparisonExpr firstTerm comparison
      Nothing ->
        firstTerm

forAppExprParser :: Parser Expr
forAppExprParser = do
  terms <- some (try forTermParser)
  case terms of
    firstTerm : remainingTerms ->
      pure (foldl applyExpr firstTerm remainingTerms)
    [] ->
      fail "expected at least one expression term"

forTermParser :: Parser Expr
forTermParser = do
  baseExpr <- forBaseExprParser
  fieldAccesses <- many fieldAccessSuffixParser
  pure (foldl applyFieldAccess baseExpr fieldAccesses)

forBaseExprParser :: Parser Expr
forBaseExprParser =
  parens exprParser
    <|> returnParser
    <|> decodeParser
    <|> encodeParser
    <|> listExprParser
    <|> boolParser
    <|> intParser
    <|> stringParser
    <|> constructorExprParser
    <|> variableParser

returnParser :: Parser Expr
returnParser = do
  start <- getSourcePos
  keyword "return"
  value <- exprParser
  end <- getSourcePos
  pure (EReturn (makeSourceSpan start end) value)

decodeParser :: Parser Expr
decodeParser = do
  start <- getSourcePos
  keyword "decode"
  targetType <- typeBaseParser
  rawJson <- exprParser
  end <- getSourcePos
  pure (EDecode (makeSourceSpan start end) targetType rawJson)

encodeParser :: Parser Expr
encodeParser = do
  start <- getSourcePos
  keyword "encode"
  value <- exprParser
  end <- getSourcePos
  pure (EEncode (makeSourceSpan start end) value)

listExprParser :: Parser Expr
listExprParser = do
  start <- getSourcePos
  values <- brackets (exprParser `sepBy` symbolN ",")
  end <- getSourcePos
  pure (EList (makeSourceSpan start end) values)

patternParser :: Parser Pattern
patternParser = do
  (constructorSpan, constructorName) <- locatedUpperIdentifierN
  binders <- many patternBinderParser
  pure (PConstructor constructorSpan constructorName binders)

patternBinderParser :: Parser PatternBinder
patternBinderParser = do
  (binderSpan, binderName) <- locatedLowerIdentifier
  pure
    PatternBinder
      { patternBinderName = binderName
      , patternBinderSpan = binderSpan
      }

recordExprParser :: Parser Expr
recordExprParser = do
  start <- getSourcePos
  (_, recordName) <- locatedUpperIdentifier
  fields <- braces (recordFieldExprParser `sepBy` symbolN ",")
  end <- getSourcePos
  pure (ERecord (makeSourceSpan start end) recordName fields)

recordFieldExprParser :: Parser RecordFieldExpr
recordFieldExprParser = do
  start <- getSourcePos
  (_, fieldName) <- locatedLowerIdentifierN
  _ <- symbolN "="
  fieldValue <- exprParser
  end <- getSourcePos
  pure
    RecordFieldExpr
      { recordFieldExprName = fieldName
      , recordFieldExprSpan = makeSourceSpan start end
      , recordFieldExprValue = fieldValue
      }

fieldAccessSuffixParser :: Parser (SourceSpan, Text)
fieldAccessSuffixParser = do
  _ <- char '.'
  locatedLexemeWith sc lowerIdentifierRaw

variableParser :: Parser Expr
variableParser = do
  (span', name) <- locatedLowerIdentifier
  pure (EVar span' name)

constructorExprParser :: Parser Expr
constructorExprParser = do
  (span', name) <- locatedUpperIdentifier
  pure (EVar span' name)

boolParser :: Parser Expr
boolParser =
  locatedKeywordExpr "true" (\span' -> EBool span' True)
    <|> locatedKeywordExpr "false" (\span' -> EBool span' False)

intParser :: Parser Expr
intParser = do
  (span', value) <- locatedLexeme L.decimal
  pure (EInt span' value)

stringParser :: Parser Expr
stringParser = do
  (span', value) <- locatedStringLiteral
  pure (EString span' value)

locatedStringLiteral :: Parser (SourceSpan, Text)
locatedStringLiteral =
  locatedLexeme (T.pack <$> (char '"' *> manyTill L.charLiteral (char '"')))

typeParser :: Parser Type
typeParser = do
  parts <- typeAtomParser `sepBy1` symbol "->"
  pure (buildFunctionType parts)

typeAtomParser :: Parser Type
typeAtomParser = do
  baseType <- typeBaseParser
  case baseType of
    TNamed name -> do
      argTypes <- many (try typeBaseParser)
      pure $
        case argTypes of
          [] ->
            TNamed name
          _ ->
            TApply name argTypes
    _ ->
      pure baseType

typeBaseParser :: Parser Type
typeBaseParser =
  parens typeParser
    <|> (TList <$> brackets typeParser)
    <|> (keyword "Int" *> pure TInt)
    <|> (keyword "Str" *> pure TStr)
    <|> (keyword "Bool" *> pure TBool)
    <|> (TNamed <$> upperIdentifier)
    <|> (TVar <$> lowerIdentifier)

moduleNameParser :: Parser Text
moduleNameParser =
  lexeme $
    T.intercalate "." <$> sepBy1 moduleSegment (char '.')
  where
    moduleSegment = T.pack <$> ((:) <$> upperChar <*> many identTailChar)

lowerIdentifier :: Parser Text
lowerIdentifier = snd <$> locatedLowerIdentifier

upperIdentifier :: Parser Text
upperIdentifier = snd <$> locatedUpperIdentifier

locatedLowerIdentifier :: Parser (SourceSpan, Text)
locatedLowerIdentifier = locatedLexeme lowerIdentifierRaw

locatedLowerIdentifierN :: Parser (SourceSpan, Text)
locatedLowerIdentifierN = locatedLexemeWith scn lowerIdentifierRaw

locatedUpperIdentifier :: Parser (SourceSpan, Text)
locatedUpperIdentifier = locatedLexeme upperIdentifierRaw

locatedUpperIdentifierN :: Parser (SourceSpan, Text)
locatedUpperIdentifierN = locatedLexemeWith scn upperIdentifierRaw

lowerIdentifierRaw :: Parser Text
lowerIdentifierRaw = do
  name <- T.pack <$> ((:) <$> lowerChar <*> many identTailChar)
  when (name `elem` reservedWords) $
    fail ("reserved word " <> show name <> " cannot be used as an identifier")
  pure name

upperIdentifierRaw :: Parser Text
upperIdentifierRaw =
  T.pack <$> ((:) <$> upperChar <*> many identTailChar)

keyword :: Text -> Parser ()
keyword word = lexeme (keywordRaw word)

keywordN :: Text -> Parser ()
keywordN word = locatedLexemeWith scn (keywordRaw word) *> pure ()

keywordRaw :: Text -> Parser ()
keywordRaw word = do
  void (string word)
  notFollowedBy identTailChar

locatedKeywordExpr :: Text -> (SourceSpan -> Expr) -> Parser Expr
locatedKeywordExpr word constructor = do
  (span', _) <- locatedLexeme (keywordRaw word)
  pure (constructor span')

applyExpr :: Expr -> Expr -> Expr
applyExpr fn arg =
  let callSpan = mergeSourceSpans (exprSpan fn) (exprSpan arg)
   in case fn of
        ECall _ target args ->
          ECall callSpan target (args <> [arg])
        _ ->
          ECall callSpan fn [arg]

equalityOperatorParser :: Parser Text
equalityOperatorParser =
  symbol "==" <|> symbol "!="

comparisonOperatorParser :: Parser Text
comparisonOperatorParser =
  symbol "<="
    <|> symbol ">="
    <|> symbol "<"
    <|> symbol ">"

applyEqualityExpr :: Expr -> (Text, Expr) -> Expr
applyEqualityExpr left (operator, right) =
  let equalitySpan = mergeSourceSpans (exprSpan left) (exprSpan right)
   in case operator of
        "==" ->
          EEqual equalitySpan left right
        "!=" ->
          ENotEqual equalitySpan left right
        _ ->
          left

applyComparisonExpr :: Expr -> (Text, Expr) -> Expr
applyComparisonExpr left (operator, right) =
  let comparisonSpan = mergeSourceSpans (exprSpan left) (exprSpan right)
   in case operator of
        "<" ->
          ELessThan comparisonSpan left right
        "<=" ->
          ELessThanOrEqual comparisonSpan left right
        ">" ->
          EGreaterThan comparisonSpan left right
        ">=" ->
          EGreaterThanOrEqual comparisonSpan left right
        _ ->
          left

applyFieldAccess :: Expr -> (SourceSpan, Text) -> Expr
applyFieldAccess subject (fieldSpan, fieldName) =
  EFieldAccess (mergeSourceSpans (exprSpan subject) fieldSpan) subject fieldName

applyBlockBinding :: BlockBinding -> Expr -> Expr
applyBlockBinding binding body =
  case binding of
    BlockLetBinding start nameSpan name value ->
      ELet (mergeSourceSpans (makeSourceSpan start start) (exprSpan body)) nameSpan name value body
    BlockMutableLetBinding start nameSpan name value ->
      EMutableLet (mergeSourceSpans (makeSourceSpan start start) (exprSpan body)) nameSpan name value body
    BlockAssignBinding start nameSpan name value ->
      EAssign (mergeSourceSpans (makeSourceSpan start start) (exprSpan body)) nameSpan name value body
    BlockForBinding start nameSpan name iterable loopBody ->
      EFor (mergeSourceSpans (makeSourceSpan start start) (exprSpan body)) nameSpan name iterable loopBody body

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

locatedLexeme :: Parser a -> Parser (SourceSpan, a)
locatedLexeme = locatedLexemeWith sc

locatedLexemeWith :: Parser () -> Parser a -> Parser (SourceSpan, a)
locatedLexemeWith spaceConsumer parser = do
  start <- getSourcePos
  value <- parser
  end <- getSourcePos
  spaceConsumer
  pure (makeSourceSpan start end, value)

symbol :: Text -> Parser Text
symbol = L.symbol sc

symbolN :: Text -> Parser Text
symbolN = L.symbol scn

parens :: Parser a -> Parser a
parens = between (symbol "(") (symbol ")")

brackets :: Parser a -> Parser a
brackets = between (symbol "[") (symbol "]")

braces :: Parser a -> Parser a
braces parser =
  between openBrace closeBrace (scn *> parser <* scn)
  where
    openBrace = L.symbol scn "{"
    closeBrace = L.symbol sc "}"

sc :: Parser ()
sc = L.space (void $ some (char ' ' <|> char '\t')) lineComment MP.empty

scn :: Parser ()
scn = L.space space1 lineComment MP.empty

lineComment :: Parser ()
lineComment = L.skipLineComment "--"

identTailChar :: Parser Char
identTailChar = alphaNumChar <|> char '_'

buildFunctionType :: [Type] -> Type
buildFunctionType [singleType] = singleType
buildFunctionType manyTypes = TFunction (init manyTypes) (last manyTypes)

attachSignatures :: (ModuleName, [ImportDecl], [TopLevelItem]) -> Either DiagnosticBundle Module
attachSignatures (name, imports, items) = do
  (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures) <-
    foldM step ([], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], Map.empty) items
  if null pendingSignatures
    then
      pure Module
        { moduleName = name
        , moduleImports = imports
        , moduleTypeDecls = reverse typeDecls
        , moduleRecordDecls = reverse recordDecls
        , moduleDomainObjectDecls = reverse domainObjectDecls
        , moduleDomainEventDecls = reverse domainEventDecls
        , moduleFeedbackDecls = reverse feedbackDecls
        , moduleMetricDecls = reverse metricDecls
        , moduleGoalDecls = reverse goalDecls
        , moduleExperimentDecls = reverse experimentDecls
        , moduleRolloutDecls = reverse rolloutDecls
        , moduleWorkflowDecls = reverse workflowDecls
        , moduleSupervisorDecls = reverse supervisorDecls
        , moduleGuideDecls = reverse guideDecls
        , moduleHookDecls = reverse hookDecls
        , moduleAgentRoleDecls = reverse agentRoleDecls
        , moduleAgentDecls = reverse agentDecls
        , modulePolicyDecls = reverse policyDecls
        , moduleToolServerDecls = reverse toolServerDecls
        , moduleToolDecls = reverse toolDecls
        , moduleVerifierDecls = reverse verifierDecls
        , moduleMergeGateDecls = reverse mergeGateDecls
        , moduleProjectionDecls = reverse projectionDecls
        , moduleForeignDecls = reverse foreignDecls
        , moduleRouteDecls = reverse routeDecls
        , moduleDecls = reverse decls
        }
    else
      Left . diagnosticBundle $
        [ diagnostic
            "E_ORPHAN_SIGNATURE"
            ("Found a type signature for `" <> sigName <> "` without a matching declaration.")
            (Just signatureSpan)
            ["Add a matching declaration or remove the signature."]
            []
        | (sigName, (_, signatureSpan)) <- Map.toList pendingSignatures
        ]
  where
    step (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures) item =
      case item of
        TopTypeDecl typeDecl ->
          pure (typeDecl : typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopRecordDecl recordDecl ->
          pure (typeDecls, recordDecl : recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopDomainObjectDecl domainObjectDecl ->
          pure (typeDecls, recordDecls, domainObjectDecl : domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopDomainEventDecl domainEventDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecl : domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopFeedbackDecl feedbackDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecl : feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopMetricDecl metricDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecl : metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopGoalDecl goalDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecl : goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopExperimentDecl experimentDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecl : experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopRolloutDecl rolloutDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecl : rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopWorkflowDecl workflowDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecl : workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopSupervisorDecl supervisorDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecl : supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopGuideDecl guideDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecl : guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopHookDecl hookDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecl : hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopAgentRoleDecl agentRoleDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecl : agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopAgentDecl agentDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecl : agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopPolicyDecl policyDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecl : policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopToolServerDecl toolServerDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecl : toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopToolDecl toolDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecl : toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopVerifierDecl verifierDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecl : verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopMergeGateDecl mergeGateDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecl : mergeGateDecls, projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopProjectionDecl projectionDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecl : projectionDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopForeignDecl foreignDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecl : foreignDecls, routeDecls, decls, pendingSignatures)
        TopRouteDecl routeDecl ->
          pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecl : routeDecls, decls, pendingSignatures)
        TopSignature sigName sigType signatureSpan ->
          case Map.lookup sigName pendingSignatures of
            Just (_, existingSpan) ->
              Left . diagnosticBundle $
                [ diagnostic
                    "E_DUPLICATE_SIGNATURE"
                    ("Duplicate type signature for `" <> sigName <> "`.")
                    (Just signatureSpan)
                    ["Keep only one type signature per declaration."]
                    [diagnosticRelated "previous signature" existingSpan]
                ]
            Nothing ->
              pure
                ( typeDecls
                , recordDecls
                , domainObjectDecls
                , domainEventDecls
                , feedbackDecls
                , metricDecls
                , goalDecls
                , experimentDecls
                , rolloutDecls
                , workflowDecls
                , supervisorDecls
                , guideDecls
                , hookDecls
                , agentRoleDecls
                , agentDecls
                , policyDecls
                , toolServerDecls
                , toolDecls
                , verifierDecls
                , mergeGateDecls
                , projectionDecls
                , foreignDecls
                , routeDecls
                , decls
                , Map.insert sigName (sigType, signatureSpan) pendingSignatures
                )
        TopDecl decl ->
          let annotationData = Map.lookup (declName decl) pendingSignatures
              updatedDecl =
                case annotationData of
                  Just (annotation, annotationSpan) ->
                    decl
                      { declAnnotation = Just annotation
                      , declAnnotationSpan = Just annotationSpan
                      }
                  Nothing ->
                    decl
              remaining = Map.delete (declName decl) pendingSignatures
           in pure (typeDecls, recordDecls, domainObjectDecls, domainEventDecls, feedbackDecls, metricDecls, goalDecls, experimentDecls, rolloutDecls, workflowDecls, supervisorDecls, guideDecls, hookDecls, agentRoleDecls, agentDecls, policyDecls, toolServerDecls, toolDecls, verifierDecls, mergeGateDecls, projectionDecls, foreignDecls, routeDecls, updatedDecl : decls, remaining)

makeSourceSpan :: SourcePos -> SourcePos -> SourceSpan
makeSourceSpan start end =
  SourceSpan
    { sourceSpanFile = T.pack (MP.sourceName start)
    , sourceSpanStart = toPosition start
    , sourceSpanEnd = toPosition end
    }

toPosition :: SourcePos -> Position
toPosition pos =
  Position
    { positionLine = unPos (MP.sourceLine pos)
    , positionColumn = unPos (MP.sourceColumn pos)
    }

reservedWords :: [Text]
reservedWords =
  [ "module"
  , "import"
  , "workflow"
  , "supervisor"
  , "role"
  , "agent"
  , "let"
  , "mut"
  , "for"
  , "in"
  , "type"
  , "record"
  , "domain"
  , "object"
  , "event"
  , "feedback"
  , "operational"
  , "business"
  , "guide"
  , "extends"
  , "policy"
  , "permits"
  , "file"
  , "network"
  , "process"
  , "secret"
  , "toolserver"
  , "tool"
  , "projection"
  , "with"
  , "foreign"
  , "from"
  , "declaration"
  , "npm"
  , "typescript"
  , "route"
  , "decode"
  , "encode"
  , "return"
  , "match"
  , "if"
  , "then"
  , "else"
  , "classified"
  , "true"
  , "false"
  , "Int"
  , "Str"
  , "Bool"
  ]
