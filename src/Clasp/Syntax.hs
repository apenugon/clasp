{-# LANGUAGE OverloadedStrings #-}

module Clasp.Syntax
  ( AgentDecl (..)
  , AgentRoleDecl (..)
  , ConstructorDecl (..)
  , Decl (..)
  , Expr (..)
  , ForeignDecl (..)
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
  , renderType
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

data AgentRoleDecl = AgentRoleDecl
  { agentRoleDeclName :: Text
  , agentRoleDeclSpan :: SourceSpan
  , agentRoleDeclNameSpan :: SourceSpan
  , agentRoleDeclIdentity :: Text
  , agentRoleDeclGuideName :: Text
  , agentRoleDeclGuideSpan :: SourceSpan
  , agentRoleDeclPolicyName :: Text
  , agentRoleDeclPolicySpan :: SourceSpan
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

data ForeignDecl = ForeignDecl
  { foreignDeclName :: Text
  , foreignDeclSpan :: SourceSpan
  , foreignDeclNameSpan :: SourceSpan
  , foreignDeclAnnotationSpan :: SourceSpan
  , foreignDeclType :: Type
  , foreignDeclRuntimeName :: Text
  , foreignDeclRuntimeSpan :: SourceSpan
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
