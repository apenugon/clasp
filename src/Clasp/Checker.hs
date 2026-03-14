{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module Clasp.Checker
  ( checkModule
  ) where

import Control.Monad (foldM, unless, when, zipWithM_)
import Control.Monad.Except (ExceptT, MonadError (throwError), runExceptT)
import Control.Monad.State.Strict
  ( MonadState
  , State
  , gets
  , modify'
  , runState
  )
import Data.Bifunctor (first)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Foldable (traverse_)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
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
  , coreExprType
  )
import Clasp.Diagnostic
  ( DiagnosticBundle
  , DiagnosticRelated
  , diagnostic
  , diagnosticBundle
  , diagnosticRelated
  , singleDiagnosticAt
  )
import Clasp.Syntax
  ( AgentDecl (..)
  , AgentRoleDecl (..)
  , ConstructorDecl (..)
  , Decl (..)
  , DomainEventDecl (..)
  , DomainObjectDecl (..)
  , ExperimentDecl (..)
  , Expr (..)
  , FeedbackDecl (..)
  , ForeignDecl (..)
  , GoalDecl (..)
  , GuideDecl (..)
  , GuideEntryDecl (..)
  , HookDecl (..)
  , MatchBranch (..)
  , MetricDecl (..)
  , MergeGateDecl (..)
  , MergeGateVerifierRef (..)
  , Module (..)
  , Pattern (..)
  , PatternBinder (..)
  , PolicyClassificationDecl (..)
  , PolicyDecl (..)
  , PolicyPermissionDecl (..)
  , PolicyPermissionKind (..)
  , RecordDecl (..)
  , RecordFieldDecl (..)
  , RecordFieldExpr (..)
  , ProjectionDecl (..)
  , ProjectionFieldDecl (..)
  , RouteDecl (..)
  , RouteMethod (..)
  , RolloutDecl (..)
  , Position (..)
  , SourceSpan (..)
  , SupervisorChildDecl (..)
  , SupervisorDecl (..)
  , ToolDecl (..)
  , ToolServerDecl (..)
  , Type (..)
  , TypeDecl (..)
  , VerifierDecl (..)
  , WorkflowDecl (..)
  , exprSpan
  , renderType
  )

type DeclTypeEnv = Map.Map Text Type
type TypeDeclEnv = Map.Map Text TypeDecl
type RecordDeclEnv = Map.Map Text RecordDecl
type ForeignDeclEnv = Map.Map Text ForeignDecl
type DeclMap = Map.Map Text Decl
type LocalEnv = Map.Map Text LocalBinding

data ModuleContext = ModuleContext
  { contextTypeDeclEnv :: TypeDeclEnv
  , contextRecordDeclEnv :: RecordDeclEnv
  , contextForeignDeclEnv :: ForeignDeclEnv
  , contextConstructorEnv :: ConstructorEnv
  , contextDeclMap :: DeclMap
  , contextHookDecls :: [HookDecl]
  , contextRouteDecls :: [RouteDecl]
  }

data ConstructorInfo = ConstructorInfo
  { constructorInfoTypeName :: Text
  , constructorInfoDecl :: ConstructorDecl
  }

type ConstructorEnv = Map.Map Text ConstructorInfo

data InferType
  = IInt
  | IStr
  | IBool
  | IList InferType
  | INamed Text
  | IFunction [InferType] InferType
  | IVar Int
  deriving (Eq, Ord, Show)

data InferState = InferState
  { inferNextTypeVar :: Int
  , inferSubstitution :: Map.Map Int InferType
  , inferReturnType :: Maybe InferType
  }

data InferFailure
  = InferDeferredName Text SourceSpan
  | InferDiagnostic DiagnosticBundle

data LocalBinding = LocalBinding
  { localBindingType :: InferType
  , localBindingMutable :: Bool
  }

immutableLocalBinding :: InferType -> LocalBinding
immutableLocalBinding inferType =
  LocalBinding
    { localBindingType = inferType
    , localBindingMutable = False
    }

mutableLocalBinding :: InferType -> LocalBinding
mutableLocalBinding inferType =
  LocalBinding
    { localBindingType = inferType
    , localBindingMutable = True
    }

newtype InferM a = InferM
  { unInferM :: ExceptT InferFailure (State InferState) a
  }
  deriving (Functor, Applicative, Monad, MonadError InferFailure, MonadState InferState)

data DraftDecl = DraftDecl
  { draftDeclName :: Text
  , draftDeclType :: InferType
  , draftDeclParams :: [DraftParam]
  , draftDeclBody :: DraftExpr
  }

data DraftParam = DraftParam
  { draftParamName :: Text
  , draftParamType :: InferType
  }

data DraftExpr = DraftExpr
  { draftExprSpan :: SourceSpan
  , draftExprType :: InferType
  , draftExprNode :: DraftExprNode
  }

data DraftExprNode
  = DraftVar Text
  | DraftInt Integer
  | DraftString Text
  | DraftBool Bool
  | DraftList [DraftExpr]
  | DraftReturn DraftExpr
  | DraftEqual DraftExpr DraftExpr
  | DraftNotEqual DraftExpr DraftExpr
  | DraftLessThan DraftExpr DraftExpr
  | DraftLessThanOrEqual DraftExpr DraftExpr
  | DraftGreaterThan DraftExpr DraftExpr
  | DraftGreaterThanOrEqual DraftExpr DraftExpr
  | DraftLet Text DraftExpr DraftExpr
  | DraftMutableLet Text DraftExpr DraftExpr
  | DraftAssign Text DraftExpr DraftExpr
  | DraftFor Text DraftExpr DraftExpr DraftExpr
  | DraftPage DraftExpr DraftExpr
  | DraftRedirect Text
  | DraftViewEmpty
  | DraftViewText DraftExpr
  | DraftViewAppend DraftExpr DraftExpr
  | DraftViewElement Text DraftExpr
  | DraftViewStyled Text DraftExpr
  | DraftViewLink RouteDecl Text DraftExpr
  | DraftViewForm RouteDecl Text Text DraftExpr
  | DraftViewInput Text Text DraftExpr
  | DraftViewSubmit DraftExpr
  | DraftPromptMessage Text DraftExpr
  | DraftPromptAppend DraftExpr DraftExpr
  | DraftPromptText DraftExpr
  | DraftCall DraftExpr [DraftExpr]
  | DraftMatch DraftExpr [DraftMatchBranch]
  | DraftRecord Text [DraftRecordField]
  | DraftFieldAccess DraftExpr Text
  | DraftDecodeJson Type DraftExpr
  | DraftEncodeJson DraftExpr

data DraftMatchBranch = DraftMatchBranch
  { draftMatchBranchSpan :: SourceSpan
  , draftMatchBranchPattern :: DraftPattern
  , draftMatchBranchBody :: DraftExpr
  }

data DraftPattern = DraftConstructorPattern SourceSpan Text [DraftPatternBinder]

data DraftPatternBinder = DraftPatternBinder
  { draftPatternBinderName :: Text
  , draftPatternBinderSpan :: SourceSpan
  , draftPatternBinderType :: InferType
  }

data DraftRecordField = DraftRecordField
  { draftRecordFieldName :: Text
  , draftRecordFieldValue :: DraftExpr
  }

data MatchResultAccumulator = MatchResultAccumulator
  { accumulatorExpectedTypeName :: Maybe Text
  , accumulatorSeenBranches :: Map.Map Text MatchBranch
  , accumulatorFirstBranchType :: Maybe (InferType, MatchBranch)
  , accumulatorDraftBranches :: [DraftMatchBranch]
  }

data UnifyContext = UnifyContext
  { unifyCode :: Text
  , unifySummary :: Text
  , unifyPrimarySpan :: SourceSpan
  , unifyRelated :: [DiagnosticRelated]
  }

pageTypeName :: Text
pageTypeName = "Page"

redirectTypeName :: Text
redirectTypeName = "Redirect"

viewTypeName :: Text
viewTypeName = "View"

promptTypeName :: Text
promptTypeName = "Prompt"

authSessionTypeName :: Text
authSessionTypeName = "AuthSession"

principalTypeName :: Text
principalTypeName = "Principal"

tenantTypeName :: Text
tenantTypeName = "Tenant"

resourceIdentityTypeName :: Text
resourceIdentityTypeName = "ResourceIdentity"

resultTypeName :: Text
resultTypeName = "Result"

sqliteConnectionTypeName :: Text
sqliteConnectionTypeName = "SqliteConnection"

resultOkConstructorName :: Text
resultOkConstructorName = "Ok"

resultErrConstructorName :: Text
resultErrConstructorName = "Err"

authSessionBuiltinName :: Text
authSessionBuiltinName = "authSession"

principalBuiltinName :: Text
principalBuiltinName = "principal"

tenantBuiltinName :: Text
tenantBuiltinName = "tenant"

resourceIdentityBuiltinName :: Text
resourceIdentityBuiltinName = "resourceIdentity"

hostClassBuiltinName :: Text
hostClassBuiltinName = "hostClass"

hostStyleBuiltinName :: Text
hostStyleBuiltinName = "hostStyle"

systemPromptBuiltinName :: Text
systemPromptBuiltinName = "systemPrompt"

assistantPromptBuiltinName :: Text
assistantPromptBuiltinName = "assistantPrompt"

userPromptBuiltinName :: Text
userPromptBuiltinName = "userPrompt"

appendPromptBuiltinName :: Text
appendPromptBuiltinName = "appendPrompt"

promptTextBuiltinName :: Text
promptTextBuiltinName = "promptText"

builtinSpan :: SourceSpan
builtinSpan =
  SourceSpan
    { sourceSpanFile = "<builtin>"
    , sourceSpanStart = Position 1 1
    , sourceSpanEnd = Position 1 1
    }

builtinRecordFieldDecl :: Text -> Type -> RecordFieldDecl
builtinRecordFieldDecl name typ =
  RecordFieldDecl
    { recordFieldDeclName = name
    , recordFieldDeclSpan = builtinSpan
    , recordFieldDeclType = typ
    , recordFieldDeclClassification = "public"
    }

builtinRecordDecl :: Text -> [(Text, Type)] -> RecordDecl
builtinRecordDecl name fields =
  RecordDecl
    { recordDeclName = name
    , recordDeclSpan = builtinSpan
    , recordDeclNameSpan = builtinSpan
    , recordDeclProjectionSource = Nothing
    , recordDeclProjectionPolicy = Nothing
    , recordDeclFields = fmap (uncurry builtinRecordFieldDecl) fields
    }

builtinConstructorDecl :: Text -> [Type] -> ConstructorDecl
builtinConstructorDecl name fields =
  ConstructorDecl
    { constructorDeclName = name
    , constructorDeclSpan = builtinSpan
    , constructorDeclNameSpan = builtinSpan
    , constructorDeclFields = fields
    }

builtinResultTypeDecl :: TypeDecl
builtinResultTypeDecl =
  TypeDecl
    { typeDeclName = resultTypeName
    , typeDeclSpan = builtinSpan
    , typeDeclNameSpan = builtinSpan
    , typeDeclConstructors =
        [ builtinConstructorDecl resultOkConstructorName [TStr]
        , builtinConstructorDecl resultErrConstructorName [TStr]
        ]
    }

builtinForeignDecl :: Text -> Type -> ForeignDecl
builtinForeignDecl name typ =
  builtinRuntimeForeignDecl name name typ

builtinRuntimeForeignDecl :: Text -> Text -> Type -> ForeignDecl
builtinRuntimeForeignDecl name runtimeName typ =
  ForeignDecl
    { foreignDeclName = name
    , foreignDeclSpan = builtinSpan
    , foreignDeclNameSpan = builtinSpan
    , foreignDeclUnsafeInterop = False
    , foreignDeclAnnotationSpan = builtinSpan
    , foreignDeclType = typ
    , foreignDeclRuntimeName = runtimeName
    , foreignDeclRuntimeSpan = builtinSpan
    , foreignDeclPackageImport = Nothing
    }

builtinStdlibForeignDecls :: [ForeignDecl]
builtinStdlibForeignDecls =
  [ builtinForeignDecl "textConcat" (TFunction [TList TStr] TStr)
  , builtinForeignDecl "textJoin" (TFunction [TStr, TList TStr] TStr)
  , builtinForeignDecl "textSplit" (TFunction [TStr, TStr] (TList TStr))
  , builtinForeignDecl "textPrefix" (TFunction [TStr, TStr] (TNamed resultTypeName))
  , builtinForeignDecl "textSplitFirst" (TFunction [TStr, TStr] (TNamed resultTypeName))
  , builtinForeignDecl "pathJoin" (TFunction [TList TStr] TStr)
  , builtinForeignDecl "pathDirname" (TFunction [TStr] TStr)
  , builtinForeignDecl "pathBasename" (TFunction [TStr] TStr)
  , builtinForeignDecl "fileExists" (TFunction [TStr] TBool)
  , builtinForeignDecl "readFile" (TFunction [TStr] (TNamed resultTypeName))
  , builtinRuntimeForeignDecl "sqliteOpen" "sqlite:open" (TFunction [TStr] (TNamed sqliteConnectionTypeName))
  , builtinRuntimeForeignDecl "sqliteOpenReadonly" "sqlite:openReadonly" (TFunction [TStr] (TNamed sqliteConnectionTypeName))
  ]

builtinStdlibForeignDeclsForModule :: Module -> [ForeignDecl]
builtinStdlibForeignDeclsForModule modl =
  [ foreignDecl
  | foreignDecl <- builtinStdlibForeignDecls
  , moduleUsesBuiltinStdlibForeignDecl (foreignDeclName foreignDecl) modl
  ]

moduleUsesBuiltinStdlibForeignDecl :: Text -> Module -> Bool
moduleUsesBuiltinStdlibForeignDecl name modl =
  any (declUsesBuiltinStdlibForeignDecl name) (moduleDecls modl)

declUsesBuiltinStdlibForeignDecl :: Text -> Decl -> Bool
declUsesBuiltinStdlibForeignDecl name decl =
  exprUsesBuiltinStdlibForeignDecl name (declBody decl)

exprUsesBuiltinStdlibForeignDecl :: Text -> Expr -> Bool
exprUsesBuiltinStdlibForeignDecl name expr =
  case expr of
    EVar _ _ ->
      False
    EInt _ _ ->
      False
    EString _ _ ->
      False
    EBool _ _ ->
      False
    EList _ values ->
      any (exprUsesBuiltinStdlibForeignDecl name) values
    EReturn _ value ->
      exprUsesBuiltinStdlibForeignDecl name value
    EBlock _ body ->
      exprUsesBuiltinStdlibForeignDecl name body
    EEqual _ left right ->
      exprUsesBuiltinStdlibForeignDecl name left || exprUsesBuiltinStdlibForeignDecl name right
    ENotEqual _ left right ->
      exprUsesBuiltinStdlibForeignDecl name left || exprUsesBuiltinStdlibForeignDecl name right
    ELessThan _ left right ->
      exprUsesBuiltinStdlibForeignDecl name left || exprUsesBuiltinStdlibForeignDecl name right
    ELessThanOrEqual _ left right ->
      exprUsesBuiltinStdlibForeignDecl name left || exprUsesBuiltinStdlibForeignDecl name right
    EGreaterThan _ left right ->
      exprUsesBuiltinStdlibForeignDecl name left || exprUsesBuiltinStdlibForeignDecl name right
    EGreaterThanOrEqual _ left right ->
      exprUsesBuiltinStdlibForeignDecl name left || exprUsesBuiltinStdlibForeignDecl name right
    ECall _ fn args ->
      callTargetsBuiltinStdlibForeignDecl name fn
        || exprUsesBuiltinStdlibForeignDecl name fn
        || any (exprUsesBuiltinStdlibForeignDecl name) args
    ELet _ _ _ value body ->
      exprUsesBuiltinStdlibForeignDecl name value || exprUsesBuiltinStdlibForeignDecl name body
    EMutableLet _ _ _ value body ->
      exprUsesBuiltinStdlibForeignDecl name value || exprUsesBuiltinStdlibForeignDecl name body
    EAssign _ _ _ value body ->
      exprUsesBuiltinStdlibForeignDecl name value || exprUsesBuiltinStdlibForeignDecl name body
    EFor _ _ _ iterable loopBody body ->
      exprUsesBuiltinStdlibForeignDecl name iterable
        || exprUsesBuiltinStdlibForeignDecl name loopBody
        || exprUsesBuiltinStdlibForeignDecl name body
    EMatch _ subject branches ->
      exprUsesBuiltinStdlibForeignDecl name subject || any (matchBranchUsesBuiltinStdlibForeignDecl name) branches
    ERecord _ _ fields ->
      any (exprUsesBuiltinStdlibForeignDecl name . recordFieldExprValue) fields
    EFieldAccess _ subject _ ->
      exprUsesBuiltinStdlibForeignDecl name subject
    EDecode _ _ value ->
      exprUsesBuiltinStdlibForeignDecl name value
    EEncode _ value ->
      exprUsesBuiltinStdlibForeignDecl name value

callTargetsBuiltinStdlibForeignDecl :: Text -> Expr -> Bool
callTargetsBuiltinStdlibForeignDecl targetName fn =
  case fn of
    EVar _ name ->
      name == targetName
    _ ->
      False

matchBranchUsesBuiltinStdlibForeignDecl :: Text -> MatchBranch -> Bool
matchBranchUsesBuiltinStdlibForeignDecl name branch =
  exprUsesBuiltinStdlibForeignDecl name (matchBranchBody branch)

builtinRecordDecls :: [RecordDecl]
builtinRecordDecls =
  [ builtinRecordDecl principalTypeName [("id", TStr)]
  , builtinRecordDecl tenantTypeName [("id", TStr)]
  , builtinRecordDecl resourceIdentityTypeName [("resourceType", TStr), ("resourceId", TStr)]
  , builtinRecordDecl
      sqliteConnectionTypeName
      [ ("id", TStr)
      , ("databasePath", TStr)
      , ("readOnly", TBool)
      , ("memory", TBool)
      ]
  , builtinRecordDecl
      authSessionTypeName
      [ ("sessionId", TStr)
      , ("principal", TNamed principalTypeName)
      , ("tenant", TNamed tenantTypeName)
      , ("resource", TNamed resourceIdentityTypeName)
      ]
  ]

builtinRecordDeclEnv :: RecordDeclEnv
builtinRecordDeclEnv = Map.fromList [(recordDeclName recordDecl, recordDecl) | recordDecl <- builtinRecordDecls]

isBuiltinRecordTypeName :: Text -> Bool
isBuiltinRecordTypeName name = Map.member name builtinRecordDeclEnv

isBuiltinTypeName :: Text -> Bool
isBuiltinTypeName name =
  name `elem` [pageTypeName, redirectTypeName, viewTypeName, promptTypeName, resultTypeName] || isBuiltinRecordTypeName name

builtinTypeDeclsForModule :: Module -> [TypeDecl]
builtinTypeDeclsForModule modl
  | moduleUsesBuiltinResult modl =
      [builtinResultTypeDecl]
  | otherwise =
      []

moduleUsesBuiltinResult :: Module -> Bool
moduleUsesBuiltinResult modl =
  let userConstructorNames =
        concatMap (fmap constructorDeclName . typeDeclConstructors) (moduleTypeDecls modl)
   in any typeUsesBuiltinResult (collectModuleTypes modl)
        || any (`notElem` userConstructorNames) (collectBuiltinResultConstructorRefs modl)

collectModuleTypes :: Module -> [Type]
collectModuleTypes modl =
  concatMap collectTypeDeclTypes (moduleTypeDecls modl)
    <> concatMap collectRecordDeclTypes (moduleRecordDecls modl)
    <> fmap workflowDeclStateType (moduleWorkflowDecls modl)
    <> fmap foreignDeclType (moduleForeignDecls modl)
    <> [ annotation
       | decl <- moduleDecls modl
       , Just annotation <- [declAnnotation decl]
       ]

collectTypeDeclTypes :: TypeDecl -> [Type]
collectTypeDeclTypes typeDecl =
  concatMap constructorDeclFields (typeDeclConstructors typeDecl)

collectRecordDeclTypes :: RecordDecl -> [Type]
collectRecordDeclTypes recordDecl =
  fmap recordFieldDeclType (recordDeclFields recordDecl)

collectBuiltinResultConstructorRefs :: Module -> [Text]
collectBuiltinResultConstructorRefs modl =
  concatMap collectDeclResultConstructors (moduleDecls modl)

collectDeclResultConstructors :: Decl -> [Text]
collectDeclResultConstructors decl =
  collectExprResultConstructors (declBody decl)

collectExprResultConstructors :: Expr -> [Text]
collectExprResultConstructors expr =
  case expr of
    EVar _ name
      | name `elem` [resultOkConstructorName, resultErrConstructorName] ->
          [name]
      | otherwise ->
          []
    EInt _ _ ->
      []
    EString _ _ ->
      []
    EBool _ _ ->
      []
    EList _ values ->
      concatMap collectExprResultConstructors values
    EReturn _ value ->
      collectExprResultConstructors value
    EBlock _ body ->
      collectExprResultConstructors body
    EEqual _ left right ->
      collectExprResultConstructors left <> collectExprResultConstructors right
    ENotEqual _ left right ->
      collectExprResultConstructors left <> collectExprResultConstructors right
    ELessThan _ left right ->
      collectExprResultConstructors left <> collectExprResultConstructors right
    ELessThanOrEqual _ left right ->
      collectExprResultConstructors left <> collectExprResultConstructors right
    EGreaterThan _ left right ->
      collectExprResultConstructors left <> collectExprResultConstructors right
    EGreaterThanOrEqual _ left right ->
      collectExprResultConstructors left <> collectExprResultConstructors right
    ECall _ fn args ->
      collectExprResultConstructors fn <> concatMap collectExprResultConstructors args
    ELet _ _ _ value body ->
      collectExprResultConstructors value <> collectExprResultConstructors body
    EMutableLet _ _ _ value body ->
      collectExprResultConstructors value <> collectExprResultConstructors body
    EAssign _ _ _ value body ->
      collectExprResultConstructors value <> collectExprResultConstructors body
    EFor _ _ _ iterable loopBody body ->
      collectExprResultConstructors iterable
        <> collectExprResultConstructors loopBody
        <> collectExprResultConstructors body
    EMatch _ subject branches ->
      collectExprResultConstructors subject <> concatMap collectMatchBranchResultConstructors branches
    ERecord _ _ fields ->
      concatMap (collectExprResultConstructors . recordFieldExprValue) fields
    EFieldAccess _ subject _ ->
      collectExprResultConstructors subject
    EDecode _ _ value ->
      collectExprResultConstructors value
    EEncode _ value ->
      collectExprResultConstructors value

collectMatchBranchResultConstructors :: MatchBranch -> [Text]
collectMatchBranchResultConstructors branch =
  collectPatternResultConstructors (matchBranchPattern branch)
    <> collectExprResultConstructors (matchBranchBody branch)

collectPatternResultConstructors :: Pattern -> [Text]
collectPatternResultConstructors pattern' =
  case pattern' of
    PConstructor _ constructorName _
      | constructorName `elem` [resultOkConstructorName, resultErrConstructorName] ->
          [constructorName]
      | otherwise ->
          []

typeUsesBuiltinResult :: Type -> Bool
typeUsesBuiltinResult typ =
  case typ of
    TInt ->
      False
    TStr ->
      False
    TBool ->
      False
    TList itemType ->
      typeUsesBuiltinResult itemType
    TNamed name ->
      name == resultTypeName
    TFunction args result ->
      any typeUsesBuiltinResult (args <> [result])

isBuiltinViewFunctionName :: Text -> Bool
isBuiltinViewFunctionName name =
  name `elem` ["page", "redirect", "text", "append", "element", "styled", "link", "form", "input", "submit", hostClassBuiltinName, hostStyleBuiltinName]

isBuiltinPromptFunctionName :: Text -> Bool
isBuiltinPromptFunctionName name =
  name `elem`
    [ systemPromptBuiltinName
    , assistantPromptBuiltinName
    , userPromptBuiltinName
    , appendPromptBuiltinName
    , promptTextBuiltinName
    ]

isBuiltinAuthFunctionName :: Text -> Bool
isBuiltinAuthFunctionName name =
  name `elem` [authSessionBuiltinName, principalBuiltinName, tenantBuiltinName, resourceIdentityBuiltinName]

isSafeViewTag :: Text -> Bool
isSafeViewTag tag =
  not (T.null tag)
    && T.all (\char -> isAsciiLower char || isDigit char || char == '-') tag
    && tag `notElem` ["script", "style"]

isSafeStyleRef :: Text -> Bool
isSafeStyleRef styleRef =
  not (T.null styleRef)
    && T.all (\char -> isAsciiLower char || isDigit char || char == '-' || char == '_') styleRef

isSafeNavigationTarget :: Text -> Bool
isSafeNavigationTarget target =
  not (T.null target)
    && T.head target == '/'
    && T.all (\char -> isAsciiLower char || isAsciiUpper char || isDigit char || char `elem` ['/', '-', '_', '?', '&', '=', '#', '.']) target

isSafeFormMethod :: Text -> Bool
isSafeFormMethod method = method `elem` ["GET", "POST"]

isSafeFieldName :: Text -> Bool
isSafeFieldName fieldName =
  not (T.null fieldName)
    && T.all (\char -> isAsciiLower char || isAsciiUpper char || isDigit char || char == '_') fieldName

isSafeInputKind :: Text -> Bool
isSafeInputKind inputKind = inputKind `elem` ["text", "number", "hidden"]

normalizeNavigationTarget :: Text -> Text
normalizeNavigationTarget target =
  T.takeWhile (\char -> char /= '?' && char /= '#') target

isRouteResponseKindAllowed :: [Text] -> RouteDecl -> Bool
isRouteResponseKindAllowed allowedKinds routeDecl =
  routeResponseKind routeDecl `elem` allowedKinds

routeResponseKind :: RouteDecl -> Text
routeResponseKind routeDecl
  | routeDeclResponseType routeDecl == pageTypeName = "page"
  | routeDeclResponseType routeDecl == redirectTypeName = "redirect"
  | otherwise = "json"

resolveNavigationRoute :: ModuleContext -> RouteMethod -> Text -> [Text] -> Maybe RouteDecl
resolveNavigationRoute ctx routeMethod targetPath allowedResponseKinds =
  listToMaybe $
    filter
      ( \routeDecl ->
          routeDeclMethod routeDecl == routeMethod
            && routeDeclPath routeDecl == normalizeNavigationTarget targetPath
            && isRouteResponseKindAllowed allowedResponseKinds routeDecl
      )
      (contextRouteDecls ctx)

freezeRouteContract :: RouteDecl -> CoreRouteContract
freezeRouteContract routeDecl =
  CoreRouteContract
    { coreRouteContractName = routeDeclName routeDecl
    , coreRouteContractIdentity = routeDeclIdentity routeDecl
    , coreRouteContractMethod = emitRouteMethodText (routeDeclMethod routeDecl)
    , coreRouteContractPath = routeDeclPath routeDecl
    , coreRouteContractPathDecl = routeDeclPathDecl routeDecl
    , coreRouteContractRequestType = routeDeclRequestType routeDecl
    , coreRouteContractQueryDecl = routeDeclQueryDecl routeDecl
    , coreRouteContractFormDecl = routeDeclFormDecl routeDecl
    , coreRouteContractBodyDecl = routeDeclBodyDecl routeDecl
    , coreRouteContractResponseType = routeDeclResponseType routeDecl
    , coreRouteContractResponseDecl = routeDeclResponseDecl routeDecl
    , coreRouteContractResponseKind = routeResponseKind routeDecl
    }

emitRouteMethodText :: RouteMethod -> Text
emitRouteMethodText routeMethod =
  case routeMethod of
    RouteGet -> "GET"
    RoutePost -> "POST"

checkModule :: Module -> Either DiagnosticBundle CoreModule
checkModule modl = do
  let typeDecls = moduleTypeDecls modl
      schemaRecordDecls = moduleRecordDecls modl
      domainObjectDecls = moduleDomainObjectDecls modl
      domainEventDecls = moduleDomainEventDecls modl
      feedbackDecls = moduleFeedbackDecls modl
      metricDecls = moduleMetricDecls modl
      goalDecls = moduleGoalDecls modl
      experimentDecls = moduleExperimentDecls modl
      rolloutDecls = moduleRolloutDecls modl
      workflowDecls = moduleWorkflowDecls modl
      supervisorDecls = moduleSupervisorDecls modl
      guideDecls = moduleGuideDecls modl
      hookDecls = moduleHookDecls modl
      agentRoleDecls = moduleAgentRoleDecls modl
      agentDecls = moduleAgentDecls modl
      policyDecls = modulePolicyDecls modl
      toolServerDecls = moduleToolServerDecls modl
      toolDecls = moduleToolDecls modl
      verifierDecls = moduleVerifierDecls modl
      mergeGateDecls = moduleMergeGateDecls modl
      projectionDecls = moduleProjectionDecls modl
      foreignDecls = moduleForeignDecls modl
      routeDecls = moduleRouteDecls modl
      decls = moduleDecls modl
      builtinForeignDecls = builtinStdlibForeignDeclsForModule modl
      allForeignDecls = builtinForeignDecls <> foreignDecls
      moduleWithBuiltinForeignDecls = modl {moduleForeignDecls = allForeignDecls}
      builtinTypeDecls = builtinTypeDeclsForModule moduleWithBuiltinForeignDecls
      allTypeDecls = builtinTypeDecls <> typeDecls

  ensureUniqueTypeDecls typeDecls
  ensureUniqueGuideDecls guideDecls
  ensureUniqueDomainObjectDecls domainObjectDecls
  ensureUniqueDomainEventDecls domainEventDecls
  ensureUniqueFeedbackDecls feedbackDecls
  ensureUniqueMetricDecls metricDecls
  ensureUniqueGoalDecls goalDecls
  ensureUniqueExperimentDecls experimentDecls
  ensureUniqueRolloutDecls rolloutDecls
  ensureUniqueWorkflowDecls workflowDecls
  ensureUniqueSupervisorDecls supervisorDecls
  ensureUniqueHooks hookDecls
  ensureUniqueAgentRoleDecls agentRoleDecls
  ensureUniqueAgentDecls agentDecls
  ensureUniquePolicyDecls policyDecls
  ensureUniqueToolServerDecls toolServerDecls
  ensureUniqueToolDecls toolDecls
  ensureUniqueVerifierDecls verifierDecls
  ensureUniqueMergeGateDecls mergeGateDecls
  ensureGuideHierarchy guideDecls
  ensureKnownDomainObjectSchemaReferences schemaRecordDecls domainObjectDecls
  ensureKnownDomainEventReferences schemaRecordDecls domainObjectDecls domainEventDecls
  ensureKnownFeedbackReferences schemaRecordDecls domainObjectDecls feedbackDecls
  ensureKnownMetricReferences schemaRecordDecls domainObjectDecls metricDecls
  ensureKnownGoalMetricReferences metricDecls goalDecls
  ensureKnownExperimentGoalReferences goalDecls experimentDecls
  ensureKnownRolloutExperimentReferences experimentDecls rolloutDecls
  ensureSupervisorHierarchy workflowDecls supervisorDecls
  ensureKnownAgentRoleReferences guideDecls policyDecls agentRoleDecls
  ensureKnownAgentReferences agentRoleDecls agentDecls
  ensureKnownToolServerReferences policyDecls toolServerDecls
  ensureKnownToolReferences toolServerDecls toolDecls
  ensureKnownVerifierToolReferences toolDecls verifierDecls
  ensureKnownMergeGateVerifierReferences verifierDecls mergeGateDecls
  projectionRecordDecls <- synthesizeProjectionRecordDecls schemaRecordDecls policyDecls projectionDecls
  let recordDecls = schemaRecordDecls <> projectionRecordDecls
  ensureUniqueRecordDecls recordDecls
  let typeDeclEnv = Map.fromList [(typeDeclName typeDecl, typeDecl) | typeDecl <- allTypeDecls]
      recordDeclEnv = Map.union builtinRecordDeclEnv (Map.fromList [(recordDeclName recordDecl, recordDecl) | recordDecl <- recordDecls])
  ensureDistinctNamedTypes typeDeclEnv recordDecls
  ensureKnownTypes typeDeclEnv recordDeclEnv allTypeDecls recordDecls workflowDecls allForeignDecls decls hookDecls toolDecls routeDecls

  constructorEnv <- buildConstructorEnv allTypeDecls
  ensureUniqueForeignDecls allForeignDecls decls constructorEnv
  ensureUniqueDecls decls allForeignDecls constructorEnv
  ensureUniqueRoutes routeDecls
  mapM_ ensureUniqueParams decls

  let foreignDeclEnv = Map.fromList [(foreignDeclName foreignDecl, foreignDecl) | foreignDecl <- allForeignDecls]
      ctx =
        ModuleContext
          { contextTypeDeclEnv = typeDeclEnv
          , contextRecordDeclEnv = recordDeclEnv
          , contextForeignDeclEnv = foreignDeclEnv
          , contextConstructorEnv = constructorEnv
          , contextDeclMap = Map.fromList [(declName decl, decl) | decl <- decls]
          , contextHookDecls = hookDecls
          , contextRouteDecls = routeDecls
          }

  declTypeEnv <- inferDeclTypes ctx decls
  let foreignTypeEnv = Map.fromList [(foreignDeclName foreignDecl, foreignDeclType foreignDecl) | foreignDecl <- allForeignDecls]
      termEnv = Map.unions [declTypeEnv, foreignTypeEnv, Map.map constructorInfoType constructorEnv]

  traverse_ (checkHookDecl ctx termEnv) hookDecls
  traverse_ (checkRouteDecl ctx termEnv) routeDecls
  traverse_ (checkWorkflowDecl ctx termEnv) workflowDecls
  coreDecls <- traverse (checkDecl ctx termEnv) decls
  pure
    CoreModule
      { coreModuleName = moduleName modl
      , coreModuleTypeDecls = allTypeDecls
      , coreModuleRecordDecls = builtinRecordDecls <> recordDecls
      , coreModuleDomainObjectDecls = fmap CoreDomainObjectDecl domainObjectDecls
      , coreModuleDomainEventDecls = fmap CoreDomainEventDecl domainEventDecls
      , coreModuleFeedbackDecls = fmap CoreFeedbackDecl feedbackDecls
      , coreModuleMetricDecls = fmap CoreMetricDecl metricDecls
      , coreModuleGoalDecls = fmap CoreGoalDecl goalDecls
      , coreModuleExperimentDecls = fmap CoreExperimentDecl experimentDecls
      , coreModuleRolloutDecls = fmap CoreRolloutDecl rolloutDecls
      , coreModuleWorkflowDecls = fmap CoreWorkflowDecl workflowDecls
      , coreModuleSupervisorDecls = fmap CoreSupervisorDecl supervisorDecls
      , coreModuleGuideDecls = guideDecls
      , coreModuleHookDecls = fmap CoreHookDecl hookDecls
      , coreModuleAgentRoleDecls = fmap CoreAgentRoleDecl agentRoleDecls
      , coreModuleAgentDecls = fmap CoreAgentDecl agentDecls
      , coreModulePolicyDecls = fmap CorePolicyDecl policyDecls
      , coreModuleToolServerDecls = fmap CoreToolServerDecl toolServerDecls
      , coreModuleToolDecls = fmap CoreToolDecl toolDecls
      , coreModuleVerifierDecls = fmap CoreVerifierDecl verifierDecls
      , coreModuleMergeGateDecls = fmap CoreMergeGateDecl mergeGateDecls
      , coreModuleProjectionDecls =
          zipWith
            (\projectionDecl projectionRecordDecl ->
               CoreProjectionDecl
                 { coreProjectionSourceDecl = projectionDecl
                 , coreProjectionRecordDecl = projectionRecordDecl
                 }
            )
            projectionDecls
            projectionRecordDecls
      , coreModuleForeignDecls = allForeignDecls
      , coreModuleRouteDecls = routeDecls
      , coreModuleDecls = coreDecls
      }

ensureUniqueGuideDecls :: [GuideDecl] -> Either DiagnosticBundle ()
ensureUniqueGuideDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (guideDecl : rest) =
      case Map.lookup (guideDeclName guideDecl) seen of
        Just previousGuideDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_GUIDE"
                ("Duplicate guide declaration for `" <> guideDeclName guideDecl <> "`.")
                (Just (guideDeclNameSpan guideDecl))
                ["Each guide name may only be declared once."]
                [diagnosticRelated "previous guide declaration" (guideDeclNameSpan previousGuideDecl)]
            ]
        Nothing -> do
          ensureUniqueGuideEntries guideDecl
          go (Map.insert (guideDeclName guideDecl) guideDecl seen) rest

ensureUniqueDomainObjectDecls :: [DomainObjectDecl] -> Either DiagnosticBundle ()
ensureUniqueDomainObjectDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (domainObjectDecl : rest) =
      case Map.lookup (domainObjectDeclName domainObjectDecl) seen of
        Just previousDomainObjectDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_DOMAIN_OBJECT"
                ("Duplicate domain object declaration for `" <> domainObjectDeclName domainObjectDecl <> "`.")
                (Just (domainObjectDeclNameSpan domainObjectDecl))
                ["Each domain object name may only be declared once."]
                [diagnosticRelated "previous domain object declaration" (domainObjectDeclNameSpan previousDomainObjectDecl)]
            ]
        Nothing ->
          go (Map.insert (domainObjectDeclName domainObjectDecl) domainObjectDecl seen) rest

ensureUniqueDomainEventDecls :: [DomainEventDecl] -> Either DiagnosticBundle ()
ensureUniqueDomainEventDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (domainEventDecl : rest) =
      case Map.lookup (domainEventDeclName domainEventDecl) seen of
        Just previousDomainEventDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_DOMAIN_EVENT"
                ("Duplicate domain event declaration for `" <> domainEventDeclName domainEventDecl <> "`.")
                (Just (domainEventDeclNameSpan domainEventDecl))
                ["Each domain event name may only be declared once."]
                [diagnosticRelated "previous domain event declaration" (domainEventDeclNameSpan previousDomainEventDecl)]
            ]
        Nothing ->
          go (Map.insert (domainEventDeclName domainEventDecl) domainEventDecl seen) rest

ensureUniqueFeedbackDecls :: [FeedbackDecl] -> Either DiagnosticBundle ()
ensureUniqueFeedbackDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (feedbackDecl : rest) =
      case Map.lookup (feedbackDeclName feedbackDecl) seen of
        Just previousFeedbackDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_FEEDBACK"
                ("Duplicate feedback declaration for `" <> feedbackDeclName feedbackDecl <> "`.")
                (Just (feedbackDeclNameSpan feedbackDecl))
                ["Each feedback name may only be declared once."]
                [diagnosticRelated "previous feedback declaration" (feedbackDeclNameSpan previousFeedbackDecl)]
            ]
        Nothing ->
          go (Map.insert (feedbackDeclName feedbackDecl) feedbackDecl seen) rest

ensureKnownDomainObjectSchemaReferences :: [RecordDecl] -> [DomainObjectDecl] -> Either DiagnosticBundle ()
ensureKnownDomainObjectSchemaReferences recordDecls domainObjectDecls =
  traverse_ checkDomainObject domainObjectDecls
  where
    recordDeclEnv = Map.fromList [(recordDeclName recordDecl, recordDecl) | recordDecl <- recordDecls]
    checkDomainObject domainObjectDecl =
      unless (Map.member (domainObjectDeclSchemaName domainObjectDecl) recordDeclEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_DOMAIN_OBJECT_SCHEMA"
              ("Domain object `" <> domainObjectDeclName domainObjectDecl <> "` references unknown schema `" <> domainObjectDeclSchemaName domainObjectDecl <> "`.")
              (Just (domainObjectDeclSchemaSpan domainObjectDecl))
              ["Declare the referenced record before using it in a domain object."]
              []
          ]

ensureKnownDomainEventReferences :: [RecordDecl] -> [DomainObjectDecl] -> [DomainEventDecl] -> Either DiagnosticBundle ()
ensureKnownDomainEventReferences recordDecls domainObjectDecls domainEventDecls =
  traverse_ checkDomainEvent domainEventDecls
  where
    recordDeclEnv = Map.fromList [(recordDeclName recordDecl, recordDecl) | recordDecl <- recordDecls]
    domainObjectDeclEnv = Map.fromList [(domainObjectDeclName domainObjectDecl, domainObjectDecl) | domainObjectDecl <- domainObjectDecls]
    checkDomainEvent domainEventDecl = do
      unless (Map.member (domainEventDeclSchemaName domainEventDecl) recordDeclEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_DOMAIN_EVENT_SCHEMA"
              ("Domain event `" <> domainEventDeclName domainEventDecl <> "` references unknown schema `" <> domainEventDeclSchemaName domainEventDecl <> "`.")
              (Just (domainEventDeclSchemaSpan domainEventDecl))
              ["Declare the referenced record before using it in a domain event."]
              []
          ]
      unless (Map.member (domainEventDeclObjectName domainEventDecl) domainObjectDeclEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_DOMAIN_EVENT_OBJECT"
              ("Domain event `" <> domainEventDeclName domainEventDecl <> "` references unknown domain object `" <> domainEventDeclObjectName domainEventDecl <> "`.")
              (Just (domainEventDeclObjectSpan domainEventDecl))
              ["Declare the referenced domain object before using it in a domain event."]
              []
          ]

ensureKnownFeedbackReferences :: [RecordDecl] -> [DomainObjectDecl] -> [FeedbackDecl] -> Either DiagnosticBundle ()
ensureKnownFeedbackReferences recordDecls domainObjectDecls feedbackDecls =
  traverse_ checkFeedback feedbackDecls
  where
    recordDeclEnv = Map.fromList [(recordDeclName recordDecl, recordDecl) | recordDecl <- recordDecls]
    domainObjectDeclEnv = Map.fromList [(domainObjectDeclName domainObjectDecl, domainObjectDecl) | domainObjectDecl <- domainObjectDecls]
    checkFeedback feedbackDecl = do
      unless (Map.member (feedbackDeclSchemaName feedbackDecl) recordDeclEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_FEEDBACK_SCHEMA"
              ("Feedback `" <> feedbackDeclName feedbackDecl <> "` references unknown schema `" <> feedbackDeclSchemaName feedbackDecl <> "`.")
              (Just (feedbackDeclSchemaSpan feedbackDecl))
              ["Declare the referenced record before using it in a feedback declaration."]
              []
          ]
      unless (Map.member (feedbackDeclObjectName feedbackDecl) domainObjectDeclEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_FEEDBACK_OBJECT"
              ("Feedback `" <> feedbackDeclName feedbackDecl <> "` references unknown domain object `" <> feedbackDeclObjectName feedbackDecl <> "`.")
              (Just (feedbackDeclObjectSpan feedbackDecl))
              ["Declare the referenced domain object before using it in a feedback declaration."]
              []
          ]

ensureUniqueMetricDecls :: [MetricDecl] -> Either DiagnosticBundle ()
ensureUniqueMetricDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (metricDecl : rest) =
      case Map.lookup (metricDeclName metricDecl) seen of
        Just previousMetricDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_METRIC"
                ("Duplicate metric declaration for `" <> metricDeclName metricDecl <> "`.")
                (Just (metricDeclNameSpan metricDecl))
                ["Each metric name may only be declared once."]
                [diagnosticRelated "previous metric declaration" (metricDeclNameSpan previousMetricDecl)]
            ]
        Nothing ->
          go (Map.insert (metricDeclName metricDecl) metricDecl seen) rest

ensureUniqueGoalDecls :: [GoalDecl] -> Either DiagnosticBundle ()
ensureUniqueGoalDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (goalDecl : rest) =
      case Map.lookup (goalDeclName goalDecl) seen of
        Just previousGoalDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_GOAL"
                ("Duplicate goal declaration for `" <> goalDeclName goalDecl <> "`.")
                (Just (goalDeclNameSpan goalDecl))
                ["Each goal name may only be declared once."]
                [diagnosticRelated "previous goal declaration" (goalDeclNameSpan previousGoalDecl)]
            ]
        Nothing ->
          go (Map.insert (goalDeclName goalDecl) goalDecl seen) rest

ensureKnownMetricReferences :: [RecordDecl] -> [DomainObjectDecl] -> [MetricDecl] -> Either DiagnosticBundle ()
ensureKnownMetricReferences recordDecls domainObjectDecls metricDecls =
  traverse_ checkMetric metricDecls
  where
    recordDeclEnv = Map.fromList [(recordDeclName recordDecl, recordDecl) | recordDecl <- recordDecls]
    domainObjectDeclEnv = Map.fromList [(domainObjectDeclName domainObjectDecl, domainObjectDecl) | domainObjectDecl <- domainObjectDecls]
    checkMetric metricDecl = do
      unless (Map.member (metricDeclSchemaName metricDecl) recordDeclEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_METRIC_SCHEMA"
              ("Metric `" <> metricDeclName metricDecl <> "` references unknown schema `" <> metricDeclSchemaName metricDecl <> "`.")
              (Just (metricDeclSchemaSpan metricDecl))
              ["Declare the referenced record before using it in a metric."]
              []
          ]
      unless (Map.member (metricDeclObjectName metricDecl) domainObjectDeclEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_METRIC_OBJECT"
              ("Metric `" <> metricDeclName metricDecl <> "` references unknown domain object `" <> metricDeclObjectName metricDecl <> "`.")
              (Just (metricDeclObjectSpan metricDecl))
              ["Declare the referenced domain object before using it in a metric."]
              []
          ]

ensureKnownGoalMetricReferences :: [MetricDecl] -> [GoalDecl] -> Either DiagnosticBundle ()
ensureKnownGoalMetricReferences metricDecls goalDecls =
  traverse_ checkGoal goalDecls
  where
    metricDeclEnv = Map.fromList [(metricDeclName metricDecl, metricDecl) | metricDecl <- metricDecls]
    checkGoal goalDecl =
      unless (Map.member (goalDeclMetricName goalDecl) metricDeclEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_GOAL_METRIC"
              ("Goal `" <> goalDeclName goalDecl <> "` references unknown metric `" <> goalDeclMetricName goalDecl <> "`.")
              (Just (goalDeclMetricSpan goalDecl))
              ["Declare the referenced metric before using it in a goal."]
              []
          ]

ensureUniqueExperimentDecls :: [ExperimentDecl] -> Either DiagnosticBundle ()
ensureUniqueExperimentDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (experimentDecl : rest) =
      case Map.lookup (experimentDeclName experimentDecl) seen of
        Just previousExperimentDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_EXPERIMENT"
                ("Duplicate experiment declaration for `" <> experimentDeclName experimentDecl <> "`.")
                (Just (experimentDeclNameSpan experimentDecl))
                ["Each experiment name may only be declared once."]
                [diagnosticRelated "previous experiment declaration" (experimentDeclNameSpan previousExperimentDecl)]
            ]
        Nothing ->
          go (Map.insert (experimentDeclName experimentDecl) experimentDecl seen) rest

ensureKnownExperimentGoalReferences :: [GoalDecl] -> [ExperimentDecl] -> Either DiagnosticBundle ()
ensureKnownExperimentGoalReferences goalDecls experimentDecls =
  traverse_ checkExperiment experimentDecls
  where
    goalDeclEnv = Map.fromList [(goalDeclName goalDecl, goalDecl) | goalDecl <- goalDecls]
    checkExperiment experimentDecl =
      unless (Map.member (experimentDeclGoalName experimentDecl) goalDeclEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_EXPERIMENT_GOAL"
              ("Experiment `" <> experimentDeclName experimentDecl <> "` references unknown goal `" <> experimentDeclGoalName experimentDecl <> "`.")
              (Just (experimentDeclGoalSpan experimentDecl))
              ["Declare the referenced goal before using it in an experiment."]
              []
          ]

ensureUniqueRolloutDecls :: [RolloutDecl] -> Either DiagnosticBundle ()
ensureUniqueRolloutDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (rolloutDecl : rest) =
      case Map.lookup (rolloutDeclName rolloutDecl) seen of
        Just previousRolloutDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_ROLLOUT"
                ("Duplicate rollout declaration for `" <> rolloutDeclName rolloutDecl <> "`.")
                (Just (rolloutDeclNameSpan rolloutDecl))
                ["Each rollout name may only be declared once."]
                [diagnosticRelated "previous rollout declaration" (rolloutDeclNameSpan previousRolloutDecl)]
            ]
        Nothing ->
          go (Map.insert (rolloutDeclName rolloutDecl) rolloutDecl seen) rest

ensureKnownRolloutExperimentReferences :: [ExperimentDecl] -> [RolloutDecl] -> Either DiagnosticBundle ()
ensureKnownRolloutExperimentReferences experimentDecls rolloutDecls =
  traverse_ checkRollout rolloutDecls
  where
    experimentDeclEnv = Map.fromList [(experimentDeclName experimentDecl, experimentDecl) | experimentDecl <- experimentDecls]
    checkRollout rolloutDecl =
      unless (Map.member (rolloutDeclExperimentName rolloutDecl) experimentDeclEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_ROLLOUT_EXPERIMENT"
              ("Rollout `" <> rolloutDeclName rolloutDecl <> "` references unknown experiment `" <> rolloutDeclExperimentName rolloutDecl <> "`.")
              (Just (rolloutDeclExperimentSpan rolloutDecl))
              ["Declare the referenced experiment before using it in a rollout."]
              []
          ]

ensureUniqueWorkflowDecls :: [WorkflowDecl] -> Either DiagnosticBundle ()
ensureUniqueWorkflowDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (workflowDecl : rest) =
      case Map.lookup (workflowDeclName workflowDecl) seen of
        Just previousWorkflowDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_WORKFLOW"
                ("Duplicate workflow declaration for `" <> workflowDeclName workflowDecl <> "`.")
                (Just (workflowDeclNameSpan workflowDecl))
                ["Each workflow name may only be declared once."]
                [diagnosticRelated "previous workflow declaration" (workflowDeclNameSpan previousWorkflowDecl)]
            ]
        Nothing ->
          go (Map.insert (workflowDeclName workflowDecl) workflowDecl seen) rest

ensureUniqueSupervisorDecls :: [SupervisorDecl] -> Either DiagnosticBundle ()
ensureUniqueSupervisorDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (supervisorDecl : rest) =
      case Map.lookup (supervisorDeclName supervisorDecl) seen of
        Just previousSupervisorDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_SUPERVISOR"
                ("Duplicate supervisor declaration for `" <> supervisorDeclName supervisorDecl <> "`.")
                (Just (supervisorDeclNameSpan supervisorDecl))
                ["Each supervisor name may only be declared once."]
                [diagnosticRelated "previous supervisor declaration" (supervisorDeclNameSpan previousSupervisorDecl)]
            ]
        Nothing ->
          go (Map.insert (supervisorDeclName supervisorDecl) supervisorDecl seen) rest

ensureUniqueGuideEntries :: GuideDecl -> Either DiagnosticBundle ()
ensureUniqueGuideEntries guideDecl = go Map.empty (guideDeclEntries guideDecl)
  where
    go _ [] = pure ()
    go seen (entryDecl : rest) =
      case Map.lookup (guideEntryDeclName entryDecl) seen of
        Just previousEntryDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_GUIDE_ENTRY"
                ("Guide `" <> guideDeclName guideDecl <> "` repeats entry `" <> guideEntryDeclName entryDecl <> "`.")
                (Just (guideEntryDeclSpan entryDecl))
                ["Each guide entry name may only appear once per guide."]
                [diagnosticRelated "previous guide entry" (guideEntryDeclSpan previousEntryDecl)]
            ]
        Nothing ->
          go (Map.insert (guideEntryDeclName entryDecl) entryDecl seen) rest

ensureGuideHierarchy :: [GuideDecl] -> Either DiagnosticBundle ()
ensureGuideHierarchy guideDecls =
  traverse_ checkGuide guideDecls
  where
    guideEnv = Map.fromList [(guideDeclName guideDecl, guideDecl) | guideDecl <- guideDecls]

    checkGuide guideDecl = do
      _ <- ensureGuideParentExists guideEnv guideDecl
      ensureGuideAcyclic guideEnv [] guideDecl

    ensureGuideParentExists env guideDecl =
      case guideDeclExtends guideDecl of
        Just parentName
          | Map.notMember parentName env ->
              Left . diagnosticBundle $
                [ diagnostic
                    "E_UNKNOWN_GUIDE_PARENT"
                    ("Guide `" <> guideDeclName guideDecl <> "` extends unknown guide `" <> parentName <> "`.")
                    (guideDeclExtendsSpan guideDecl)
                    ["Declare the parent guide before extending it or fix the guide name."]
                    []
                ]
        _ ->
          pure guideDecl

    ensureGuideAcyclic env seen guideDecl =
      case guideDeclExtends guideDecl of
        Nothing ->
          pure ()
        Just parentName
          | guideDeclName guideDecl `elem` seen ->
              Left . diagnosticBundle $
                [ diagnostic
                    "E_GUIDE_CYCLE"
                    ("Guide `" <> guideDeclName guideDecl <> "` participates in an inheritance cycle.")
                    (Just (guideDeclNameSpan guideDecl))
                    ["Remove the cyclic `extends` chain so guide inheritance stays acyclic."]
                    []
                ]
          | otherwise ->
              case Map.lookup parentName env of
                Nothing ->
                  pure ()
                Just parentGuideDecl ->
                  ensureGuideAcyclic env (guideDeclName guideDecl : seen) parentGuideDecl

ensureSupervisorHierarchy :: [WorkflowDecl] -> [SupervisorDecl] -> Either DiagnosticBundle ()
ensureSupervisorHierarchy workflowDecls supervisorDecls = do
  traverse_ ensureSupervisorChildren supervisorDecls
  ensureUniqueSupervisorParents workflowDecls supervisorDecls
  traverse_ (ensureSupervisorAcyclic supervisorEnv []) supervisorDecls
  where
    workflowEnv = Map.fromList [(workflowDeclName workflowDecl, workflowDecl) | workflowDecl <- workflowDecls]
    supervisorEnv = Map.fromList [(supervisorDeclName supervisorDecl, supervisorDecl) | supervisorDecl <- supervisorDecls]

    ensureSupervisorChildren supervisorDecl
      | null (supervisorDeclChildren supervisorDecl) =
          Left . diagnosticBundle $
            [ diagnostic
                "E_EMPTY_SUPERVISOR"
                ("Supervisor `" <> supervisorDeclName supervisorDecl <> "` must declare at least one child.")
                (Just (supervisorDeclNameSpan supervisorDecl))
                ["Add one or more `workflow` or `supervisor` children to define the hierarchy."]
                []
            ]
      | otherwise =
          ensureDistinctSupervisorChildren supervisorDecl
        *> traverse_ (ensureKnownSupervisorChild workflowEnv supervisorEnv supervisorDecl) (supervisorDeclChildren supervisorDecl)

    ensureDistinctSupervisorChildren supervisorDecl = go Map.empty (supervisorDeclChildren supervisorDecl)
      where
        childKey :: SupervisorChildDecl -> (Text, Text)
        childKey childDecl =
          case childDecl of
            SupervisorWorkflowChild {supervisorChildName = childName} -> ("workflow", childName)
            SupervisorSupervisorChild {supervisorChildName = childName} -> ("supervisor", childName)

        childLabel childDecl =
          case childDecl of
            SupervisorWorkflowChild {supervisorChildName = childName} -> "workflow `" <> childName <> "`"
            SupervisorSupervisorChild {supervisorChildName = childName} -> "supervisor `" <> childName <> "`"

        go _ [] = pure ()
        go seen (childDecl : rest) =
          case Map.lookup (childKey childDecl) seen of
            Just previousChildDecl ->
              Left . diagnosticBundle $
                [ diagnostic
                    "E_DUPLICATE_SUPERVISOR_CHILD"
                    ("Supervisor `" <> supervisorDeclName supervisorDecl <> "` repeats " <> childLabel childDecl <> ".")
                    (Just (supervisorChildSpan childDecl))
                    ["Each child may only appear once per supervisor declaration."]
                    [diagnosticRelated "previous child declaration" (supervisorChildSpan previousChildDecl)]
                ]
            Nothing ->
              go (Map.insert (childKey childDecl) childDecl seen) rest

    ensureKnownSupervisorChild workflowEnv' supervisorEnv' supervisorDecl childDecl =
      case childDecl of
        SupervisorWorkflowChild {supervisorChildName = childName, supervisorChildSpan = childSpan} ->
          unless (Map.member childName workflowEnv') $
            Left . diagnosticBundle $
              [ diagnostic
                  "E_UNKNOWN_SUPERVISOR_WORKFLOW"
                  ("Supervisor `" <> supervisorDeclName supervisorDecl <> "` references unknown workflow `" <> childName <> "`.")
                  (Just childSpan)
                  ["Declare the workflow before attaching it to a supervisor hierarchy."]
                  []
              ]
        SupervisorSupervisorChild {supervisorChildName = childName, supervisorChildSpan = childSpan} ->
          unless (Map.member childName supervisorEnv') $
            Left . diagnosticBundle $
              [ diagnostic
                  "E_UNKNOWN_SUPERVISOR_CHILD"
                  ("Supervisor `" <> supervisorDeclName supervisorDecl <> "` references unknown supervisor `" <> childName <> "`.")
                  (Just childSpan)
                  ["Declare the child supervisor before attaching it to a parent supervisor."]
                  []
              ]

    ensureUniqueSupervisorParents _ supervisorDecls' =
      goWorkflowParents Map.empty (concatMap expandSupervisorChildren supervisorDecls')
        *> goSupervisorParents Map.empty (concatMap expandSupervisorChildren supervisorDecls')
      where
        expandSupervisorChildren supervisorDecl =
          [ (supervisorDecl, childDecl)
          | childDecl <- supervisorDeclChildren supervisorDecl
          ]

        goWorkflowParents _ [] = pure ()
        goWorkflowParents seen ((supervisorDecl, childDecl) : rest) =
          case childDecl of
            SupervisorWorkflowChild {supervisorChildName = childName, supervisorChildSpan = childSpan} ->
              case Map.lookup childName seen of
                Just previousSupervisorDecl ->
                  Left . diagnosticBundle $
                    [ diagnostic
                        "E_MULTIPLE_SUPERVISOR_PARENTS"
                        ("Workflow `" <> childName <> "` is attached to multiple supervisors.")
                        (Just childSpan)
                        ["Attach each workflow to at most one supervisor in the hierarchy."]
                        [diagnosticRelated "previous supervisor declaration" (supervisorDeclNameSpan previousSupervisorDecl)]
                    ]
                Nothing ->
                  goWorkflowParents (Map.insert childName supervisorDecl seen) rest
            SupervisorSupervisorChild {} ->
              goWorkflowParents seen rest

        goSupervisorParents _ [] = pure ()
        goSupervisorParents seen ((supervisorDecl, childDecl) : rest) =
          case childDecl of
            SupervisorSupervisorChild {supervisorChildName = childName, supervisorChildSpan = childSpan} ->
              if childName == supervisorDeclName supervisorDecl
                then
                  Left . diagnosticBundle $
                    [ diagnostic
                        "E_SUPERVISOR_SELF_REFERENCE"
                        ("Supervisor `" <> supervisorDeclName supervisorDecl <> "` cannot supervise itself.")
                        (Just childSpan)
                        ["Remove the self-reference so the supervisor hierarchy remains well-formed."]
                        []
                    ]
                else
                  case Map.lookup childName seen of
                    Just previousSupervisorDecl ->
                      Left . diagnosticBundle $
                        [ diagnostic
                            "E_MULTIPLE_SUPERVISOR_PARENTS"
                            ("Supervisor `" <> childName <> "` is attached to multiple supervisors.")
                            (Just childSpan)
                            ["Attach each child supervisor to at most one parent supervisor."]
                            [diagnosticRelated "previous supervisor declaration" (supervisorDeclNameSpan previousSupervisorDecl)]
                        ]
                    Nothing ->
                      goSupervisorParents (Map.insert childName supervisorDecl seen) rest
            SupervisorWorkflowChild {} ->
              goSupervisorParents seen rest

    ensureSupervisorAcyclic env seen supervisorDecl
      | supervisorDeclName supervisorDecl `elem` seen =
          Left . diagnosticBundle $
            [ diagnostic
                "E_SUPERVISOR_CYCLE"
                ("Supervisor `" <> supervisorDeclName supervisorDecl <> "` participates in a supervision cycle.")
                (Just (supervisorDeclNameSpan supervisorDecl))
                ["Remove the cyclic supervisor references so the hierarchy stays acyclic."]
                []
            ]
      | otherwise =
          traverse_ checkChild (supervisorDeclChildren supervisorDecl)
      where
        checkChild childDecl =
          case childDecl of
            SupervisorWorkflowChild {} ->
              pure ()
            SupervisorSupervisorChild {supervisorChildName = childName} ->
              case Map.lookup childName env of
                Nothing ->
                  pure ()
                Just childSupervisorDecl ->
                  ensureSupervisorAcyclic env (supervisorDeclName supervisorDecl : seen) childSupervisorDecl

ensureUniqueHooks :: [HookDecl] -> Either DiagnosticBundle ()
ensureUniqueHooks = go Map.empty
  where
    go _ [] = pure ()
    go seen (hookDecl : rest) =
      case Map.lookup (hookDeclName hookDecl) seen of
        Just previousHookDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_HOOK"
                ("Duplicate hook declaration for `" <> hookDeclName hookDecl <> "`.")
                (Just (hookDeclNameSpan hookDecl))
                ["Each hook name may only be declared once."]
                [diagnosticRelated "previous hook declaration" (hookDeclNameSpan previousHookDecl)]
            ]
        Nothing ->
          go (Map.insert (hookDeclName hookDecl) hookDecl seen) rest

ensureUniqueAgentRoleDecls :: [AgentRoleDecl] -> Either DiagnosticBundle ()
ensureUniqueAgentRoleDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (agentRoleDecl : rest) =
      case Map.lookup (agentRoleDeclName agentRoleDecl) seen of
        Just previousAgentRoleDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_AGENT_ROLE"
                ("Duplicate agent role declaration for `" <> agentRoleDeclName agentRoleDecl <> "`.")
                (Just (agentRoleDeclNameSpan agentRoleDecl))
                ["Each agent role name may only be declared once."]
                [diagnosticRelated "previous agent role declaration" (agentRoleDeclNameSpan previousAgentRoleDecl)]
            ]
        Nothing ->
          go (Map.insert (agentRoleDeclName agentRoleDecl) agentRoleDecl seen) rest

ensureUniqueAgentDecls :: [AgentDecl] -> Either DiagnosticBundle ()
ensureUniqueAgentDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (agentDecl : rest) =
      case Map.lookup (agentDeclName agentDecl) seen of
        Just previousAgentDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_AGENT"
                ("Duplicate agent declaration for `" <> agentDeclName agentDecl <> "`.")
                (Just (agentDeclNameSpan agentDecl))
                ["Each agent name may only be declared once."]
                [diagnosticRelated "previous agent declaration" (agentDeclNameSpan previousAgentDecl)]
            ]
        Nothing ->
          go (Map.insert (agentDeclName agentDecl) agentDecl seen) rest

ensureKnownAgentRoleReferences :: [GuideDecl] -> [PolicyDecl] -> [AgentRoleDecl] -> Either DiagnosticBundle ()
ensureKnownAgentRoleReferences guideDecls policyDecls =
  mapM_ (checkAgentRole guideEnv policyEnv)
  where
    guideEnv = Map.fromList [(guideDeclName guideDecl, guideDecl) | guideDecl <- guideDecls]
    policyEnv = Map.fromList [(policyDeclName policyDecl, policyDecl) | policyDecl <- policyDecls]

    checkAgentRole guideEnv' policyEnv' agentRoleDecl = do
      unless (Map.member (agentRoleDeclGuideName agentRoleDecl) guideEnv') $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_AGENT_ROLE_GUIDE"
              ("Agent role `" <> agentRoleDeclName agentRoleDecl <> "` references unknown guide `" <> agentRoleDeclGuideName agentRoleDecl <> "`.")
              (Just (agentRoleDeclGuideSpan agentRoleDecl))
              ["Declare the referenced guide before using it in an agent role."]
              []
          ]
      unless (Map.member (agentRoleDeclPolicyName agentRoleDecl) policyEnv') $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_AGENT_ROLE_POLICY"
              ("Agent role `" <> agentRoleDeclName agentRoleDecl <> "` references unknown policy `" <> agentRoleDeclPolicyName agentRoleDecl <> "`.")
              (Just (agentRoleDeclPolicySpan agentRoleDecl))
              ["Declare the referenced policy before using it in an agent role."]
              []
          ]

ensureKnownAgentReferences :: [AgentRoleDecl] -> [AgentDecl] -> Either DiagnosticBundle ()
ensureKnownAgentReferences agentRoleDecls =
  mapM_ checkAgent
  where
    roleEnv = Map.fromList [(agentRoleDeclName agentRoleDecl, agentRoleDecl) | agentRoleDecl <- agentRoleDecls]

    checkAgent agentDecl =
      unless (Map.member (agentDeclRoleName agentDecl) roleEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_AGENT_ROLE"
              ("Agent `" <> agentDeclName agentDecl <> "` references unknown role `" <> agentDeclRoleName agentDecl <> "`.")
              (Just (agentDeclRoleSpan agentDecl))
              ["Declare the referenced role before assigning it to an agent."]
              []
          ]

ensureUniquePolicyDecls :: [PolicyDecl] -> Either DiagnosticBundle ()
ensureUniquePolicyDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (policyDecl : rest) =
      case Map.lookup (policyDeclName policyDecl) seen of
        Just previousPolicyDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_POLICY"
                ("Duplicate policy declaration for `" <> policyDeclName policyDecl <> "`.")
                (Just (policyDeclNameSpan policyDecl))
                ["Each policy name may only be declared once."]
                [diagnosticRelated "previous policy declaration" (policyDeclNameSpan previousPolicyDecl)]
            ]
        Nothing -> do
          ensureUniquePolicyClassifications policyDecl
          ensureUniquePolicyPermissions policyDecl
          go (Map.insert (policyDeclName policyDecl) policyDecl seen) rest

ensureUniquePolicyClassifications :: PolicyDecl -> Either DiagnosticBundle ()
ensureUniquePolicyClassifications policyDecl = go Map.empty (policyDeclAllowedClassifications policyDecl)
  where
    go _ [] = pure ()
    go seen (classificationDecl : rest) =
      case Map.lookup (policyClassificationDeclName classificationDecl) seen of
        Just previousClassificationDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_POLICY_CLASSIFICATION"
                ("Policy `" <> policyDeclName policyDecl <> "` repeats classification `" <> policyClassificationDeclName classificationDecl <> "`.")
                (Just (policyClassificationDeclSpan classificationDecl))
                ["List each disclosure classification at most once per policy."]
                [diagnosticRelated "previous classification" (policyClassificationDeclSpan previousClassificationDecl)]
            ]
        Nothing ->
          go (Map.insert (policyClassificationDeclName classificationDecl) classificationDecl seen) rest

ensureUniquePolicyPermissions :: PolicyDecl -> Either DiagnosticBundle ()
ensureUniquePolicyPermissions policyDecl = go Map.empty (policyDeclPermissions policyDecl)
  where
    go _ [] = pure ()
    go seen (permissionDecl : rest) =
      let permissionKey = (policyPermissionDeclKind permissionDecl, policyPermissionDeclValue permissionDecl)
       in case Map.lookup permissionKey seen of
            Just previousPermissionDecl ->
              Left . diagnosticBundle $
                [ diagnostic
                    "E_DUPLICATE_POLICY_PERMISSION"
                    ("Policy `" <> policyDeclName policyDecl <> "` repeats " <> renderPolicyPermissionKind (policyPermissionDeclKind permissionDecl) <> " permission `" <> policyPermissionDeclValue permissionDecl <> "`.")
                    (Just (policyPermissionDeclSpan permissionDecl))
                    ["List each declared permission target at most once per policy."]
                    [diagnosticRelated "previous permission" (policyPermissionDeclSpan previousPermissionDecl)]
                ]
            Nothing ->
              go (Map.insert permissionKey permissionDecl seen) rest

renderPolicyPermissionKind :: PolicyPermissionKind -> Text
renderPolicyPermissionKind permissionKind =
  case permissionKind of
    PolicyPermissionFile -> "file"
    PolicyPermissionNetwork -> "network"
    PolicyPermissionProcess -> "process"
    PolicyPermissionSecret -> "secret"

ensureUniqueToolServerDecls :: [ToolServerDecl] -> Either DiagnosticBundle ()
ensureUniqueToolServerDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (toolServerDecl : rest) =
      case Map.lookup (toolServerDeclName toolServerDecl) seen of
        Just previousToolServerDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_TOOLSERVER"
                ("Duplicate tool server declaration for `" <> toolServerDeclName toolServerDecl <> "`.")
                (Just (toolServerDeclNameSpan toolServerDecl))
                ["Each tool server name may only be declared once."]
                [diagnosticRelated "previous tool server declaration" (toolServerDeclNameSpan previousToolServerDecl)]
            ]
        Nothing ->
          go (Map.insert (toolServerDeclName toolServerDecl) toolServerDecl seen) rest

ensureUniqueToolDecls :: [ToolDecl] -> Either DiagnosticBundle ()
ensureUniqueToolDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (toolDecl : rest) =
      case Map.lookup (toolDeclName toolDecl) seen of
        Just previousToolDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_TOOL"
                ("Duplicate tool declaration for `" <> toolDeclName toolDecl <> "`.")
                (Just (toolDeclNameSpan toolDecl))
                ["Each tool name may only be declared once."]
                [diagnosticRelated "previous tool declaration" (toolDeclNameSpan previousToolDecl)]
            ]
        Nothing ->
          go (Map.insert (toolDeclName toolDecl) toolDecl seen) rest

ensureKnownToolServerReferences :: [PolicyDecl] -> [ToolServerDecl] -> Either DiagnosticBundle ()
ensureKnownToolServerReferences policyDecls =
  mapM_ checkToolServer
  where
    policyEnv = Map.fromList [(policyDeclName policyDecl, policyDecl) | policyDecl <- policyDecls]

    checkToolServer toolServerDecl =
      unless (Map.member (toolServerDeclPolicyName toolServerDecl) policyEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_TOOLSERVER_POLICY"
              ("Tool server `" <> toolServerDeclName toolServerDecl <> "` references unknown policy `" <> toolServerDeclPolicyName toolServerDecl <> "`.")
              (Just (toolServerDeclPolicySpan toolServerDecl))
              ["Declare the referenced policy before using it on a tool server."]
              []
          ]

ensureKnownToolReferences :: [ToolServerDecl] -> [ToolDecl] -> Either DiagnosticBundle ()
ensureKnownToolReferences toolServerDecls =
  mapM_ checkTool
  where
    toolServerEnv = Map.fromList [(toolServerDeclName toolServerDecl, toolServerDecl) | toolServerDecl <- toolServerDecls]

    checkTool toolDecl =
      unless (Map.member (toolDeclServerName toolDecl) toolServerEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_TOOLSERVER"
              ("Tool `" <> toolDeclName toolDecl <> "` references unknown tool server `" <> toolDeclServerName toolDecl <> "`.")
              (Just (toolDeclServerSpan toolDecl))
              ["Declare the referenced tool server before using it in a tool contract."]
              []
          ]

ensureUniqueVerifierDecls :: [VerifierDecl] -> Either DiagnosticBundle ()
ensureUniqueVerifierDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (verifierDecl : rest) =
      case Map.lookup (verifierDeclName verifierDecl) seen of
        Just previousVerifierDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_VERIFIER"
                ("Duplicate verifier declaration for `" <> verifierDeclName verifierDecl <> "`.")
                (Just (verifierDeclNameSpan verifierDecl))
                ["Each verifier rule name may only be declared once."]
                [diagnosticRelated "previous verifier declaration" (verifierDeclNameSpan previousVerifierDecl)]
            ]
        Nothing ->
          go (Map.insert (verifierDeclName verifierDecl) verifierDecl seen) rest

ensureUniqueMergeGateDecls :: [MergeGateDecl] -> Either DiagnosticBundle ()
ensureUniqueMergeGateDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (mergeGateDecl : rest) =
      case Map.lookup (mergeGateDeclName mergeGateDecl) seen of
        Just previousMergeGateDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_MERGE_GATE"
                ("Duplicate merge gate declaration for `" <> mergeGateDeclName mergeGateDecl <> "`.")
                (Just (mergeGateDeclNameSpan mergeGateDecl))
                ["Each merge gate name may only be declared once."]
                [diagnosticRelated "previous merge gate declaration" (mergeGateDeclNameSpan previousMergeGateDecl)]
            ]
        Nothing -> do
          ensureUniqueMergeGateVerifierRefs mergeGateDecl
          go (Map.insert (mergeGateDeclName mergeGateDecl) mergeGateDecl seen) rest

ensureUniqueMergeGateVerifierRefs :: MergeGateDecl -> Either DiagnosticBundle ()
ensureUniqueMergeGateVerifierRefs mergeGateDecl = go Map.empty (mergeGateDeclVerifierRefs mergeGateDecl)
  where
    go _ [] = pure ()
    go seen (verifierRef : rest) =
      case Map.lookup (mergeGateVerifierRefName verifierRef) seen of
        Just previousVerifierRef ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_MERGE_GATE_VERIFIER"
                ("Merge gate `" <> mergeGateDeclName mergeGateDecl <> "` repeats verifier `" <> mergeGateVerifierRefName verifierRef <> "`.")
                (Just (mergeGateVerifierRefSpan verifierRef))
                ["List each verifier at most once per merge gate."]
                [diagnosticRelated "previous verifier reference" (mergeGateVerifierRefSpan previousVerifierRef)]
            ]
        Nothing ->
          go (Map.insert (mergeGateVerifierRefName verifierRef) verifierRef seen) rest

ensureKnownVerifierToolReferences :: [ToolDecl] -> [VerifierDecl] -> Either DiagnosticBundle ()
ensureKnownVerifierToolReferences toolDecls =
  mapM_ checkVerifier
  where
    toolEnv = Map.fromList [(toolDeclName toolDecl, toolDecl) | toolDecl <- toolDecls]

    checkVerifier verifierDecl =
      unless (Map.member (verifierDeclToolName verifierDecl) toolEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_VERIFIER_TOOL"
              ("Verifier `" <> verifierDeclName verifierDecl <> "` references unknown tool `" <> verifierDeclToolName verifierDecl <> "`.")
              (Just (verifierDeclToolSpan verifierDecl))
              ["Declare the referenced tool before using it in a verifier rule."]
              []
          ]

ensureKnownMergeGateVerifierReferences :: [VerifierDecl] -> [MergeGateDecl] -> Either DiagnosticBundle ()
ensureKnownMergeGateVerifierReferences verifierDecls =
  mapM_ checkMergeGate
  where
    verifierEnv = Map.fromList [(verifierDeclName verifierDecl, verifierDecl) | verifierDecl <- verifierDecls]

    checkMergeGate mergeGateDecl =
      mapM_ (checkVerifierRef mergeGateDecl) (mergeGateDeclVerifierRefs mergeGateDecl)

    checkVerifierRef mergeGateDecl verifierRef =
      unless (Map.member (mergeGateVerifierRefName verifierRef) verifierEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_MERGE_GATE_VERIFIER"
              ("Merge gate `" <> mergeGateDeclName mergeGateDecl <> "` references unknown verifier `" <> mergeGateVerifierRefName verifierRef <> "`.")
              (Just (mergeGateVerifierRefSpan verifierRef))
              ["Declare the referenced verifier before using it in a merge gate."]
              []
          ]

synthesizeProjectionRecordDecls :: [RecordDecl] -> [PolicyDecl] -> [ProjectionDecl] -> Either DiagnosticBundle [RecordDecl]
synthesizeProjectionRecordDecls schemaRecordDecls policyDecls =
  traverse (synthesizeProjectionRecordDecl schemaRecordEnv policyDeclEnv)
  where
    schemaRecordEnv = Map.union builtinRecordDeclEnv (Map.fromList [(recordDeclName recordDecl, recordDecl) | recordDecl <- schemaRecordDecls])
    policyDeclEnv = Map.fromList [(policyDeclName policyDecl, policyDecl) | policyDecl <- policyDecls]

synthesizeProjectionRecordDecl :: RecordDeclEnv -> Map.Map Text PolicyDecl -> ProjectionDecl -> Either DiagnosticBundle RecordDecl
synthesizeProjectionRecordDecl schemaRecordEnv policyDeclEnv projectionDecl = do
  sourceRecordDecl <-
    case Map.lookup (projectionDeclSourceRecordName projectionDecl) schemaRecordEnv of
      Just recordDecl ->
        pure recordDecl
      Nothing ->
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_PROJECTION_SOURCE"
              ("Projection `" <> projectionDeclName projectionDecl <> "` references unknown record `" <> projectionDeclSourceRecordName projectionDecl <> "`.")
              (Just (projectionDeclSourceRecordSpan projectionDecl))
              ["Declare the source record before using it in a projection."]
              []
          ]
  policyDecl <-
    case Map.lookup (projectionDeclPolicyName projectionDecl) policyDeclEnv of
      Just currentPolicyDecl ->
        pure currentPolicyDecl
      Nothing ->
        Left . diagnosticBundle $
          [ diagnostic
              "E_UNKNOWN_POLICY"
              ("Projection `" <> projectionDeclName projectionDecl <> "` references unknown policy `" <> projectionDeclPolicyName projectionDecl <> "`.")
              (Just (projectionDeclPolicySpan projectionDecl))
              ["Declare the disclosure policy before using it in a projection."]
              []
          ]
  projectedFields <- projectRecordFields sourceRecordDecl policyDecl projectionDecl
  pure
    RecordDecl
      { recordDeclName = projectionDeclName projectionDecl
      , recordDeclSpan = projectionDeclSpan projectionDecl
      , recordDeclNameSpan = projectionDeclNameSpan projectionDecl
      , recordDeclProjectionSource = Just (projectionDeclSourceRecordName projectionDecl)
      , recordDeclProjectionPolicy = Just (projectionDeclPolicyName projectionDecl)
      , recordDeclFields = projectedFields
      }

projectRecordFields :: RecordDecl -> PolicyDecl -> ProjectionDecl -> Either DiagnosticBundle [RecordFieldDecl]
projectRecordFields sourceRecordDecl policyDecl projectionDecl = do
  ensureUniqueProjectionFields projectionDecl
  traverse (projectField sourceFieldEnv allowedClassifications) (projectionDeclFields projectionDecl)
  where
    sourceFieldEnv = Map.fromList [(recordFieldDeclName fieldDecl, fieldDecl) | fieldDecl <- recordDeclFields sourceRecordDecl]
    allowedClassifications =
      Map.fromList
        [ (policyClassificationDeclName classificationDecl, ())
        | classificationDecl <- policyDeclAllowedClassifications policyDecl
        ]
    projectField fieldEnv allowed projectionFieldDecl =
      case Map.lookup (projectionFieldDeclName projectionFieldDecl) fieldEnv of
        Nothing ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_UNKNOWN_PROJECTION_FIELD"
                ("Projection `" <> projectionDeclName projectionDecl <> "` references unknown field `" <> projectionFieldDeclName projectionFieldDecl <> "` on `" <> recordDeclName sourceRecordDecl <> "`.")
                (Just (projectionFieldDeclSpan projectionFieldDecl))
                ["Project only fields declared on the source record."]
                [diagnosticRelated "source record" (recordDeclNameSpan sourceRecordDecl)]
            ]
        Just fieldDecl ->
          if Map.member (recordFieldDeclClassification fieldDecl) allowed
            then
              pure fieldDecl
            else
              Left . diagnosticBundle $
                [ diagnostic
                    "E_DISCLOSURE_POLICY"
                    ("Projection `" <> projectionDeclName projectionDecl <> "` cannot disclose `" <> projectionFieldDeclName projectionFieldDecl <> "` classified as `" <> recordFieldDeclClassification fieldDecl <> "` under policy `" <> policyDeclName policyDecl <> "`.")
                    (Just (projectionFieldDeclSpan projectionFieldDecl))
                    ["Choose a policy that allows the field classification or remove the field from the projection."]
                    [ diagnosticRelated "source field" (recordFieldDeclSpan fieldDecl)
                    , diagnosticRelated "policy declaration" (policyDeclNameSpan policyDecl)
                    ]
                ]

ensureUniqueProjectionFields :: ProjectionDecl -> Either DiagnosticBundle ()
ensureUniqueProjectionFields projectionDecl = go Map.empty (projectionDeclFields projectionDecl)
  where
    go _ [] = pure ()
    go seen (fieldDecl : rest) =
      case Map.lookup (projectionFieldDeclName fieldDecl) seen of
        Just previousFieldDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_PROJECTION_FIELD"
                ("Projection `" <> projectionDeclName projectionDecl <> "` repeats field `" <> projectionFieldDeclName fieldDecl <> "`.")
                (Just (projectionFieldDeclSpan fieldDecl))
                ["Each projected field may only appear once."]
                [diagnosticRelated "previous field" (projectionFieldDeclSpan previousFieldDecl)]
            ]
        Nothing ->
          go (Map.insert (projectionFieldDeclName fieldDecl) fieldDecl seen) rest

ensureUniqueTypeDecls :: [TypeDecl] -> Either DiagnosticBundle ()
ensureUniqueTypeDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (typeDecl : rest) =
      if isBuiltinTypeName (typeDeclName typeDecl)
        then
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_TYPE"
                ("Type `" <> typeDeclName typeDecl <> "` conflicts with a compiler-known type.")
                (Just (typeDeclNameSpan typeDecl))
                ["Choose a different type name."]
                []
            ]
        else case Map.lookup (typeDeclName typeDecl) seen of
        Just previousTypeDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_TYPE"
                ("Duplicate type declaration for `" <> typeDeclName typeDecl <> "`.")
                (Just (typeDeclNameSpan typeDecl))
                ["Each type name may only be declared once."]
                [diagnosticRelated "previous type declaration" (typeDeclNameSpan previousTypeDecl)]
            ]
        Nothing ->
          go (Map.insert (typeDeclName typeDecl) typeDecl seen) rest

ensureUniqueRecordDecls :: [RecordDecl] -> Either DiagnosticBundle ()
ensureUniqueRecordDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (recordDecl : rest) =
      if isBuiltinRecordTypeName (recordDeclName recordDecl)
        then
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_RECORD"
                ("Record `" <> recordDeclName recordDecl <> "` conflicts with a compiler-known type.")
                (Just (recordDeclNameSpan recordDecl))
                ["Choose a different record name."]
                []
            ]
        else case Map.lookup (recordDeclName recordDecl) seen of
        Just previousRecordDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_RECORD"
                ("Duplicate record declaration for `" <> recordDeclName recordDecl <> "`.")
                (Just (recordDeclNameSpan recordDecl))
                ["Each record name may only be declared once."]
                [diagnosticRelated "previous record declaration" (recordDeclNameSpan previousRecordDecl)]
            ]
        Nothing ->
          go (Map.insert (recordDeclName recordDecl) recordDecl seen) rest

ensureDistinctNamedTypes :: TypeDeclEnv -> [RecordDecl] -> Either DiagnosticBundle ()
ensureDistinctNamedTypes typeDeclEnv =
  mapM_ checkRecord
  where
    checkRecord recordDecl =
      case Map.lookup (recordDeclName recordDecl) typeDeclEnv of
        Just previousTypeDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_TYPE_NAME"
                ("Record `" <> recordDeclName recordDecl <> "` conflicts with an existing type declaration.")
                (Just (recordDeclNameSpan recordDecl))
                ["Type and record declarations currently share the same named type namespace."]
                [diagnosticRelated "type declaration" (typeDeclNameSpan previousTypeDecl)]
            ]
        Nothing ->
          pure ()

ensureKnownTypes :: TypeDeclEnv -> RecordDeclEnv -> [TypeDecl] -> [RecordDecl] -> [WorkflowDecl] -> [ForeignDecl] -> [Decl] -> [HookDecl] -> [ToolDecl] -> [RouteDecl] -> Either DiagnosticBundle ()
ensureKnownTypes typeDeclEnv recordDeclEnv typeDecls recordDecls workflowDecls foreignDecls decls hookDecls toolDecls routeDecls = do
  mapM_ checkTypeDecl typeDecls
  mapM_ checkRecordDecl recordDecls
  mapM_ checkWorkflowStateDecl workflowDecls
  mapM_ checkForeignDecl foreignDecls
  mapM_ checkDeclAnnotation decls
  mapM_ checkHookDeclTypes hookDecls
  mapM_ checkToolDeclTypes toolDecls
  mapM_ checkRouteDeclTypes routeDecls
  where
    checkTypeDecl typeDecl =
      mapM_ (checkConstructorFields typeDecl) (typeDeclConstructors typeDecl)

    checkConstructorFields typeDecl constructorDecl =
      mapM_
        (ensureKnownType (constructorDeclSpan constructorDecl) [diagnosticRelated "type declaration" (typeDeclNameSpan typeDecl)])
        (constructorDeclFields constructorDecl)

    checkRecordDecl recordDecl = do
      ensureUniqueRecordFields recordDecl
      mapM_
        ( \fieldDecl ->
            do
              ensureKnownType
                (recordFieldDeclSpan fieldDecl)
                [diagnosticRelated "record declaration" (recordDeclNameSpan recordDecl)]
                (recordFieldDeclType fieldDecl)
              ensureSchemaFieldType
                recordDecl
                fieldDecl
        )
        (recordDeclFields recordDecl)

    checkWorkflowStateDecl workflowDecl =
      ensureWorkflowStateType workflowDecl

    checkDeclAnnotation decl =
      case declAnnotation decl of
        Just annotation ->
          ensureKnownType
            (fromMaybe (declNameSpan decl) (declAnnotationSpan decl))
            [diagnosticRelated "declaration" (declNameSpan decl)]
            annotation
        Nothing ->
          pure ()

    checkForeignDecl foreignDecl =
      do
        ensureKnownType
          (foreignDeclAnnotationSpan foreignDecl)
          [diagnosticRelated "foreign declaration" (foreignDeclNameSpan foreignDecl)]
          (foreignDeclType foreignDecl)
        case foreignDeclType foreignDecl of
          TFunction _ _ ->
            pure ()
          _ ->
            Left . diagnosticBundle $
              [ diagnostic
                  "E_FOREIGN_TYPE"
                  ("Foreign declaration `" <> foreignDeclName foreignDecl <> "` must be a function capability.")
                  (Just (foreignDeclAnnotationSpan foreignDecl))
                  ["Use an explicit function type for foreign runtime bindings."]
                  [diagnosticRelated "foreign declaration" (foreignDeclNameSpan foreignDecl)]
              ]

    checkHookDeclTypes hookDecl = do
      ensureHookRecordType hookDecl (hookDeclRequestType hookDecl) (hookDeclRequestTypeSpan hookDecl) "request"
      ensureHookRecordType hookDecl (hookDeclResponseType hookDecl) (hookDeclResponseTypeSpan hookDecl) "response"

    checkToolDeclTypes toolDecl = do
      ensureToolRecordType toolDecl (toolDeclRequestType toolDecl) (toolDeclRequestTypeSpan toolDecl) "request"
      ensureToolRecordType toolDecl (toolDeclResponseType toolDecl) (toolDeclResponseTypeSpan toolDecl) "response"

    checkRouteDeclTypes routeDecl = do
      ensureRecordType routeDecl (routeDeclRequestType routeDecl) (routeDeclRequestTypeSpan routeDecl) "request"
      ensureResponseType routeDecl (routeDeclResponseType routeDecl) (routeDeclResponseTypeSpan routeDecl)

    ensureKnownType primarySpan related typ =
      case typ of
        TInt ->
          pure ()
        TStr ->
          pure ()
        TBool ->
          pure ()
        TList itemType ->
          ensureKnownType primarySpan related itemType
        TNamed name ->
          unless (isBuiltinTypeName name || Map.member name typeDeclEnv || Map.member name recordDeclEnv) $
            Left . diagnosticBundle $
              [ diagnostic
                  "E_UNKNOWN_TYPE"
                  ("Unknown type `" <> name <> "`.")
                  (Just primarySpan)
                  ["Declare the type before using it in a signature or constructor."]
                  related
              ]
        TFunction args result ->
          mapM_ (ensureKnownType primarySpan related) (args <> [result])

    ensureSchemaFieldType recordDecl fieldDecl =
      case recordFieldDeclType fieldDecl of
        TInt ->
          pure ()
        TStr ->
          pure ()
        TBool ->
          pure ()
        TList itemType ->
          ensureSchemaFieldType recordDecl fieldDecl { recordFieldDeclType = itemType }
        TNamed name ->
          unless (Map.member name recordDeclEnv || maybe False isJsonEnumTypeDecl (Map.lookup name typeDeclEnv)) $
            Left . diagnosticBundle $
              [ diagnostic
                  "E_SCHEMA_FIELD_TYPE"
                  ("Record `" <> recordDeclName recordDecl <> "` uses unsupported field type `" <> name <> "` for `" <> recordFieldDeclName fieldDecl <> "`.")
                  (Just (recordFieldDeclSpan fieldDecl))
                  ["Record fields currently support primitive types, list types, nested record types, and nullary enum types only."]
                  [diagnosticRelated "record declaration" (recordDeclNameSpan recordDecl)]
              ]
        TFunction _ _ ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_SCHEMA_FIELD_TYPE"
                ("Record `" <> recordDeclName recordDecl <> "` uses a function field for `" <> recordFieldDeclName fieldDecl <> "`.")
                (Just (recordFieldDeclSpan fieldDecl))
                ["Record fields currently support primitive types, list types, nested record types, and nullary enum types only."]
                [diagnosticRelated "record declaration" (recordDeclNameSpan recordDecl)]
            ]

    ensureHookRecordType hookDecl typeName primarySpan role =
      unless (Map.member typeName recordDeclEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_HOOK_TYPE"
              ("Hook `" <> hookDeclName hookDecl <> "` must use a record type for its " <> role <> " body.")
              (Just primarySpan)
              ["Declare `" <> typeName <> "` as a record before using it in a hook."]
              []
          ]

    ensureToolRecordType toolDecl typeName primarySpan role =
      unless (Map.member typeName recordDeclEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_TOOL_SCHEMA_TYPE"
              ("Tool `" <> toolDeclName toolDecl <> "` must use a record type for its " <> role <> " body.")
              (Just primarySpan)
              ["Declare `" <> typeName <> "` as a record before using it in a tool contract."]
              []
          ]

    ensureWorkflowStateType workflowDecl =
      case workflowDeclStateType workflowDecl of
        TNamed typeName
          | Map.member typeName recordDeclEnv ->
              pure ()
          | otherwise ->
              Left . diagnosticBundle $
                [ diagnostic
                    "E_WORKFLOW_STATE_TYPE"
                    ("Workflow `" <> workflowDeclName workflowDecl <> "` must use a record type for durable state.")
                    (Just (workflowDeclStateTypeSpan workflowDecl))
                    ["Declare `" <> typeName <> "` as a record before using it as workflow state."]
                    []
                ]
        _ ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_WORKFLOW_STATE_TYPE"
                ("Workflow `" <> workflowDeclName workflowDecl <> "` must use a record type for durable state.")
                (Just (workflowDeclStateTypeSpan workflowDecl))
                ["Use a named record type for the workflow `state` field."]
                []
            ]

    ensureRecordType routeDecl typeName primarySpan role =
      unless (Map.member typeName recordDeclEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_ROUTE_TYPE"
              ("Route `" <> routeDeclName routeDecl <> "` must use a record type for its " <> role <> " body.")
              (Just primarySpan)
              ["Declare `" <> typeName <> "` as a record before using it in a route."]
              []
          ]

    ensureResponseType routeDecl typeName primarySpan =
      unless (typeName `elem` [pageTypeName, redirectTypeName] || Map.member typeName recordDeclEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_ROUTE_TYPE"
              ("Route `" <> routeDeclName routeDecl <> "` must use a record type, Page, or Redirect for its response body.")
              (Just primarySpan)
              ["Declare `" <> typeName <> "` as a record or return `Page` or `Redirect` from the route."]
              []
          ]

ensureUniqueRecordFields :: RecordDecl -> Either DiagnosticBundle ()
ensureUniqueRecordFields recordDecl = go Map.empty (recordDeclFields recordDecl)
  where
    go _ [] = pure ()
    go seen (fieldDecl : rest) =
      case Map.lookup (recordFieldDeclName fieldDecl) seen of
        Just previousFieldDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_RECORD_FIELD"
                ("Duplicate field `" <> recordFieldDeclName fieldDecl <> "` in record `" <> recordDeclName recordDecl <> "`.")
                (Just (recordFieldDeclSpan fieldDecl))
                ["Each record field may only appear once."]
                [diagnosticRelated "previous field" (recordFieldDeclSpan previousFieldDecl)]
            ]
        Nothing ->
          go (Map.insert (recordFieldDeclName fieldDecl) fieldDecl seen) rest

ensureUniqueForeignDecls :: [ForeignDecl] -> [Decl] -> ConstructorEnv -> Either DiagnosticBundle ()
ensureUniqueForeignDecls foreignDecls decls constructorEnv = go Map.empty foreignDecls
  where
    declEnv = Map.fromList [(declName decl, decl) | decl <- decls]

    go _ [] = pure ()
    go seen (foreignDecl : rest) =
      case Map.lookup (foreignDeclName foreignDecl) seen of
        Just previousForeignDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_FOREIGN"
                ("Duplicate foreign declaration for `" <> foreignDeclName foreignDecl <> "`.")
                (Just (foreignDeclNameSpan foreignDecl))
                ["Each foreign declaration name may only be declared once."]
                [diagnosticRelated "previous foreign declaration" (foreignDeclNameSpan previousForeignDecl)]
            ]
        Nothing ->
          case Map.lookup (foreignDeclName foreignDecl) declEnv of
            Just decl ->
              Left . diagnosticBundle $
                [ diagnostic
                    "E_DUPLICATE_TERM"
                    ("Foreign declaration `" <> foreignDeclName foreignDecl <> "` collides with declaration `" <> foreignDeclName foreignDecl <> "`.")
                    (Just (foreignDeclNameSpan foreignDecl))
                    ["Choose a different top-level name or rename the foreign declaration."]
                    [diagnosticRelated "declaration" (declNameSpan decl)]
                ]
            Nothing ->
              case Map.lookup (foreignDeclName foreignDecl) constructorEnv of
                Just constructorInfo ->
                  Left . diagnosticBundle $
                    [ diagnostic
                        "E_DUPLICATE_TERM"
                        ("Foreign declaration `" <> foreignDeclName foreignDecl <> "` collides with constructor `" <> foreignDeclName foreignDecl <> "`.")
                        (Just (foreignDeclNameSpan foreignDecl))
                        ["Choose a different top-level name or rename the foreign declaration."]
                        [diagnosticRelated "constructor declaration" (constructorDeclNameSpan (constructorInfoDecl constructorInfo))]
                    ]
                Nothing ->
                  go (Map.insert (foreignDeclName foreignDecl) foreignDecl seen) rest

ensureUniqueRoutes :: [RouteDecl] -> Either DiagnosticBundle ()
ensureUniqueRoutes = go Map.empty Map.empty
  where
    go _ _ [] = pure ()
    go seenNames seenEndpoints (routeDecl : rest) =
      case Map.lookup (routeDeclName routeDecl) seenNames of
        Just previousRouteDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_ROUTE"
                ("Duplicate route declaration for `" <> routeDeclName routeDecl <> "`.")
                (Just (routeDeclNameSpan routeDecl))
                ["Each route name may only be declared once."]
                [diagnosticRelated "previous route declaration" (routeDeclNameSpan previousRouteDecl)]
            ]
        Nothing ->
          let endpointKey = (routeDeclMethod routeDecl, routeDeclPath routeDecl)
           in case Map.lookup endpointKey seenEndpoints of
                Just previousRouteDecl ->
                  Left . diagnosticBundle $
                    [ diagnostic
                        "E_DUPLICATE_ROUTE_ENDPOINT"
                        ("Duplicate route endpoint `" <> routeDeclPath routeDecl <> "`.")
                        (Just (routeDeclPathSpan routeDecl))
                        ["Each method and path pair may only be declared once."]
                        [diagnosticRelated "previous route declaration" (routeDeclPathSpan previousRouteDecl)]
                    ]
                Nothing ->
                  go
                    (Map.insert (routeDeclName routeDecl) routeDecl seenNames)
                    (Map.insert endpointKey routeDecl seenEndpoints)
                    rest

buildConstructorEnv :: [TypeDecl] -> Either DiagnosticBundle ConstructorEnv
buildConstructorEnv = foldM addTypeDecl Map.empty
  where
    addTypeDecl env typeDecl =
      foldM (addConstructor typeDecl) env (typeDeclConstructors typeDecl)

    addConstructor typeDecl env constructorDecl =
      case Map.lookup (constructorDeclName constructorDecl) env of
        Just previousInfo ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_CONSTRUCTOR"
                ("Duplicate constructor `" <> constructorDeclName constructorDecl <> "`.")
                (Just (constructorDeclNameSpan constructorDecl))
                ["Constructor names must be globally unique within a module."]
                [diagnosticRelated "previous constructor" (constructorDeclNameSpan (constructorInfoDecl previousInfo))]
            ]
        Nothing ->
          pure $
            Map.insert
              (constructorDeclName constructorDecl)
              ConstructorInfo
                { constructorInfoTypeName = typeDeclName typeDecl
                , constructorInfoDecl = constructorDecl
                }
              env

ensureUniqueDecls :: [Decl] -> [ForeignDecl] -> ConstructorEnv -> Either DiagnosticBundle ()
ensureUniqueDecls decls foreignDecls constructorEnv = go Map.empty decls
  where
    foreignDeclEnv = Map.fromList [(foreignDeclName foreignDecl, foreignDecl) | foreignDecl <- foreignDecls]

    go _ [] = pure ()
    go seen (decl : rest) =
      case Map.lookup (declName decl) seen of
        Just previousDecl ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_DECL"
                ("Duplicate declaration for `" <> declName decl <> "`.")
                (Just (declNameSpan decl))
                ["Each top-level name may only be declared once."]
                [diagnosticRelated "previous declaration" (declNameSpan previousDecl)]
            ]
        Nothing ->
          case Map.lookup (declName decl) constructorEnv of
            Just constructorInfo ->
              Left . diagnosticBundle $
                [ diagnostic
                    "E_DUPLICATE_TERM"
                    ("Declaration `" <> declName decl <> "` collides with constructor `" <> declName decl <> "`.")
                    (Just (declNameSpan decl))
                    ["Choose a different top-level name or rename the constructor."]
                    [diagnosticRelated "constructor declaration" (constructorDeclNameSpan (constructorInfoDecl constructorInfo))]
                ]
            Nothing ->
              case Map.lookup (declName decl) foreignDeclEnv of
                Just foreignDecl ->
                  Left . diagnosticBundle $
                    [ diagnostic
                        "E_DUPLICATE_TERM"
                        ("Declaration `" <> declName decl <> "` collides with foreign declaration `" <> declName decl <> "`.")
                        (Just (declNameSpan decl))
                        ["Choose a different top-level name or rename the foreign declaration."]
                        [diagnosticRelated "foreign declaration" (foreignDeclNameSpan foreignDecl)]
                    ]
                Nothing ->
                  go (Map.insert (declName decl) decl seen) rest

ensureUniqueParams :: Decl -> Either DiagnosticBundle ()
ensureUniqueParams decl = go Map.empty (declParams decl)
  where
    go _ [] = pure ()
    go seen (paramName : rest) =
      case Map.lookup paramName seen of
        Just _ ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_PARAM"
                ("Duplicate parameter `" <> paramName <> "` in declaration `" <> declName decl <> "`.")
                (Just (declNameSpan decl))
                ["Each parameter name may only appear once within a function declaration."]
                []
            ]
        Nothing ->
          go (Map.insert paramName () seen) rest

inferDeclTypes :: ModuleContext -> [Decl] -> Either DiagnosticBundle DeclTypeEnv
inferDeclTypes ctx decls = loop pendingDecls annotatedDeclEnv initialTermEnv
  where
    annotatedDeclEnv =
      Map.fromList
        [ (declName decl, annotatedType)
        | decl <- decls
        , Just annotatedType <- [declAnnotation decl]
        ]
    foreignTypeEnv =
      Map.fromList
        [ (foreignDeclName foreignDecl, foreignDeclType foreignDecl)
        | foreignDecl <- Map.elems (contextForeignDeclEnv ctx)
        ]
    constructorTypeEnv =
      Map.map constructorInfoType (contextConstructorEnv ctx)
    initialTermEnv =
      Map.unions [annotatedDeclEnv, foreignTypeEnv, constructorTypeEnv]
    pendingDecls =
      [ decl
      | decl <- decls
      , declAnnotation decl == Nothing
      ]

    loop [] declTypeEnv _ = pure declTypeEnv
    loop pending declTypeEnv termEnv = do
      (nextPending, nextDeclTypeEnv, nextTermEnv, progressed) <- foldM (attemptDecl termEnv) ([], declTypeEnv, termEnv, False) pending
      if null nextPending
        then pure nextDeclTypeEnv
        else
          if progressed
            then loop (reverse nextPending) nextDeclTypeEnv nextTermEnv
            else
              case reverse nextPending of
                unresolvedDecl : _ ->
                  Left $
                    singleDiagnosticAt
                      "E_CANNOT_INFER"
                      ("Could not infer the type of `" <> declName unresolvedDecl <> "`.")
                      (declNameSpan unresolvedDecl)
                      ["Add an explicit type annotation or break the dependency cycle."]
                [] ->
                  pure nextDeclTypeEnv

    attemptDecl termEnv (remaining, declTypeEnvAcc, termEnvAcc, progressed) decl =
      case inferDeclType ctx termEnv decl of
        Left (InferDeferredName _ _) ->
          pure (decl : remaining, declTypeEnvAcc, termEnvAcc, progressed)
        Left (InferDiagnostic err) ->
          Left err
        Right inferredType ->
          pure
            ( remaining
            , Map.insert (declName decl) inferredType declTypeEnvAcc
            , Map.insert (declName decl) inferredType termEnvAcc
            , True
            )

inferDeclType :: ModuleContext -> DeclTypeEnv -> Decl -> Either InferFailure Type
inferDeclType ctx termEnv decl = do
  (draftDecl, inferState) <- runInferAction (inferDeclDraft ctx termEnv decl Nothing)
  first InferDiagnostic (freezeInferTypeForDecl decl inferState (draftDeclType draftDecl))

checkDecl :: ModuleContext -> DeclTypeEnv -> Decl -> Either DiagnosticBundle CoreDecl
checkDecl ctx termEnv decl = do
  expectedType <-
    case Map.lookup (declName decl) termEnv of
      Just declType ->
        pure declType
      Nothing ->
        Left $
          singleDiagnosticAt
            "E_INTERNAL"
            ("Missing checked type for `" <> declName decl <> "`.")
            (declNameSpan decl)
            ["The module checker did not retain a final type for this declaration."]
  case runInferAction (inferDeclDraft ctx termEnv decl (Just expectedType)) of
    Left (InferDeferredName deferredName deferredSpan) ->
      Left $
        singleDiagnosticAt
          "E_CANNOT_INFER"
          ("Could not resolve the type of `" <> deferredName <> "` yet.")
          deferredSpan
          ["Add an explicit annotation to break the dependency chain."]
    Left (InferDiagnostic err) ->
      Left err
    Right (draftDecl, inferState) ->
      freezeDraftDecl ctx decl inferState draftDecl

checkRouteDecl :: ModuleContext -> DeclTypeEnv -> RouteDecl -> Either DiagnosticBundle ()
checkRouteDecl ctx termEnv routeDecl =
  case Map.lookup (routeDeclHandlerName routeDecl) termEnv of
    Nothing ->
      Left $
        singleDiagnosticAt
          "E_UNKNOWN_ROUTE_HANDLER"
          ("Unknown route handler `" <> routeDeclHandlerName routeDecl <> "`.")
          (routeDeclHandlerSpan routeDecl)
          ["Declare the handler before using it in a route."]
    Just handlerType ->
      case handlerType of
        TFunction [TNamed requestName] (TNamed responseName)
          | requestName == routeDeclRequestType routeDecl
          , responseName == routeDeclResponseType routeDecl ->
              pure ()
          | otherwise ->
              Left . diagnosticBundle $
                [ diagnostic
                    "E_ROUTE_HANDLER_TYPE"
                    ("Route handler `" <> routeDeclHandlerName routeDecl <> "` does not match the route schema.")
                    (Just (routeDeclHandlerSpan routeDecl))
                    [ "Expected "
                        <> routeDeclRequestType routeDecl
                        <> " -> "
                        <> routeDeclResponseType routeDecl
                        <> " but got "
                        <> renderType handlerType
                        <> "."
                    ]
                    (relatedForHandler (routeDeclHandlerName routeDecl) (contextDeclMap ctx) (contextForeignDeclEnv ctx))
                ]
        _ ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_ROUTE_HANDLER_TYPE"
                ("Route handler `" <> routeDeclHandlerName routeDecl <> "` must be a function from request record to response record.")
                (Just (routeDeclHandlerSpan routeDecl))
                [ "Expected "
                    <> routeDeclRequestType routeDecl
                    <> " -> "
                    <> routeDeclResponseType routeDecl
                    <> " but got "
                    <> renderType handlerType
                    <> "."
                ]
                (relatedForHandler (routeDeclHandlerName routeDecl) (contextDeclMap ctx) (contextForeignDeclEnv ctx))
                ]

checkHookDecl :: ModuleContext -> DeclTypeEnv -> HookDecl -> Either DiagnosticBundle ()
checkHookDecl ctx termEnv hookDecl =
  case Map.lookup (hookDeclHandlerName hookDecl) termEnv of
    Nothing ->
      Left $
        singleDiagnosticAt
          "E_UNKNOWN_HOOK_HANDLER"
          ("Unknown hook handler `" <> hookDeclHandlerName hookDecl <> "`.")
          (hookDeclHandlerSpan hookDecl)
          ["Declare the handler before using it in a hook."]
    Just handlerType ->
      case handlerType of
        TFunction [TNamed requestName] (TNamed responseName)
          | requestName == hookDeclRequestType hookDecl
          , responseName == hookDeclResponseType hookDecl ->
              pure ()
          | otherwise ->
              Left . diagnosticBundle $
                [ diagnostic
                    "E_HOOK_HANDLER_TYPE"
                    ("Hook handler `" <> hookDeclHandlerName hookDecl <> "` does not match the hook schema.")
                    (Just (hookDeclHandlerSpan hookDecl))
                    [ "Expected "
                        <> hookDeclRequestType hookDecl
                        <> " -> "
                        <> hookDeclResponseType hookDecl
                        <> " but got "
                        <> renderType handlerType
                        <> "."
                    ]
                    (relatedForHandler (hookDeclHandlerName hookDecl) (contextDeclMap ctx) (contextForeignDeclEnv ctx))
                ]
        _ ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_HOOK_HANDLER_TYPE"
                ("Hook handler `" <> hookDeclHandlerName hookDecl <> "` must be a function from request record to response record.")
                (Just (hookDeclHandlerSpan hookDecl))
                [ "Expected "
                    <> hookDeclRequestType hookDecl
                    <> " -> "
                    <> hookDeclResponseType hookDecl
                    <> " but got "
                    <> renderType handlerType
                    <> "."
                ]
                (relatedForHandler (hookDeclHandlerName hookDecl) (contextDeclMap ctx) (contextForeignDeclEnv ctx))
            ]

checkWorkflowDecl :: ModuleContext -> DeclTypeEnv -> WorkflowDecl -> Either DiagnosticBundle ()
checkWorkflowDecl ctx termEnv workflowDecl = do
  checkWorkflowConstraintDecl ctx termEnv workflowDecl "invariant" (workflowDeclInvariantName workflowDecl) (workflowDeclInvariantSpan workflowDecl)
  checkWorkflowConstraintDecl ctx termEnv workflowDecl "precondition" (workflowDeclPreconditionName workflowDecl) (workflowDeclPreconditionSpan workflowDecl)
  checkWorkflowConstraintDecl ctx termEnv workflowDecl "postcondition" (workflowDeclPostconditionName workflowDecl) (workflowDeclPostconditionSpan workflowDecl)

checkWorkflowConstraintDecl ::
  ModuleContext ->
  DeclTypeEnv ->
  WorkflowDecl ->
  Text ->
  Maybe Text ->
  Maybe SourceSpan ->
  Either DiagnosticBundle ()
checkWorkflowConstraintDecl ctx termEnv workflowDecl role maybeName maybeSpan =
  case (maybeName, maybeSpan) of
    (Just constraintName, Just constraintSpan) ->
      case Map.lookup constraintName termEnv of
        Nothing ->
          Left $
            singleDiagnosticAt
              "E_UNKNOWN_WORKFLOW_CONSTRAINT"
              ("Workflow `" <> workflowDeclName workflowDecl <> "` references unknown " <> role <> " `" <> constraintName <> "`.")
              constraintSpan
              ["Declare `" <> constraintName <> "` before using it as a workflow " <> role <> "."]
        Just constraintType ->
          let expectedType = TFunction [workflowDeclStateType workflowDecl] TBool
           in unless (constraintType == expectedType) $
                Left . diagnosticBundle $
                  [ diagnostic
                      "E_WORKFLOW_CONSTRAINT_TYPE"
                      ("Workflow `" <> workflowDeclName workflowDecl <> "` " <> role <> " `" <> constraintName <> "` does not match the workflow state schema.")
                      (Just constraintSpan)
                      [ "Expected "
                          <> renderType expectedType
                          <> " but got "
                          <> renderType constraintType
                          <> "."
                      ]
                      (relatedForHandler constraintName (contextDeclMap ctx) (contextForeignDeclEnv ctx))
                  ]
    _ ->
      pure ()

inferDeclDraft :: ModuleContext -> DeclTypeEnv -> Decl -> Maybe Type -> InferM DraftDecl
inferDeclDraft ctx termEnv decl maybeExpectedType = do
  let name = declName decl
      params = declParams decl
  case maybeExpectedType of
    Just expectedType ->
      inferExpectedDecl ctx termEnv decl name params expectedType
    Nothing ->
      inferUnannotatedDecl ctx termEnv decl name params

inferExpectedDecl :: ModuleContext -> DeclTypeEnv -> Decl -> Text -> [Text] -> Type -> InferM DraftDecl
inferExpectedDecl ctx termEnv decl name params expectedType =
  case params of
    [] -> do
      body <- inferExpr ctx termEnv Map.empty (declBody decl)
      unify
        ( UnifyContext
            { unifyCode = "E_TYPE_MISMATCH"
            , unifySummary = "Type mismatch."
            , unifyPrimarySpan = exprSpan (declBody decl)
            , unifyRelated = annotationRelated decl
            }
        )
        (draftExprType body)
        (typeToInferType expectedType)
      pure
        DraftDecl
          { draftDeclName = name
          , draftDeclType = typeToInferType expectedType
          , draftDeclParams = []
          , draftDeclBody = body
          }
    _ ->
      case expectedType of
        TFunction argTypes resultType ->
          if length argTypes /= length params
            then
              throwDiagnostic . diagnosticBundle $
                [ diagnostic
                    "E_ARITY_MISMATCH"
                    ("Type annotation for `" <> declName decl <> "` does not match the declared parameter count.")
                    (declAnnotationSpan decl)
                    [ "Expected "
                        <> T.pack (show (length params))
                        <> " parameter types but got "
                        <> T.pack (show (length argTypes))
                        <> "."
                    ]
                    [diagnosticRelated "declaration" (declNameSpan decl)]
                ]
            else do
              let draftParams = zipWith DraftParam params (fmap typeToInferType argTypes)
                  localEnv = Map.fromList (zip params (fmap (immutableLocalBinding . draftParamType) draftParams))
                  resultInferType = typeToInferType resultType
              body <- withReturnType resultInferType (inferExpr ctx termEnv localEnv (declBody decl))
              unify
                ( UnifyContext
                    { unifyCode = "E_TYPE_MISMATCH"
                    , unifySummary = "Type mismatch."
                    , unifyPrimarySpan = exprSpan (declBody decl)
                    , unifyRelated = annotationRelated decl
                    }
                )
                (draftExprType body)
                resultInferType
              pure
                DraftDecl
                  { draftDeclName = name
                  , draftDeclType = typeToInferType expectedType
                  , draftDeclParams = draftParams
                  , draftDeclBody = body
                  }
        _ ->
          throwDiagnostic . diagnosticBundle $
            [ diagnostic
                "E_ARITY_MISMATCH"
                ("Declaration `" <> declName decl <> "` has parameters but a non-function annotation.")
                (declAnnotationSpan decl)
                ["Use a function type such as `Str -> Str`."]
                [diagnosticRelated "declaration" (declNameSpan decl)]
            ]

inferUnannotatedDecl :: ModuleContext -> DeclTypeEnv -> Decl -> Text -> [Text] -> InferM DraftDecl
inferUnannotatedDecl ctx termEnv decl name params =
  case params of
    [] -> do
      body <- inferExpr ctx termEnv Map.empty (declBody decl)
      pure
        DraftDecl
          { draftDeclName = name
          , draftDeclType = draftExprType body
          , draftDeclParams = []
          , draftDeclBody = body
          }
    _ -> do
      paramTypes <- traverse (const freshTypeVar) params
      resultType <- freshTypeVar
      let draftParams = zipWith DraftParam params paramTypes
          localEnv = Map.fromList (zip params (fmap immutableLocalBinding paramTypes))
      body <- withReturnType resultType (inferExpr ctx termEnv localEnv (declBody decl))
      unify
        ( UnifyContext
            { unifyCode = "E_TYPE_MISMATCH"
            , unifySummary = "Type mismatch."
            , unifyPrimarySpan = exprSpan (declBody decl)
            , unifyRelated = []
            }
        )
        (draftExprType body)
        resultType
      pure
        DraftDecl
          { draftDeclName = name
          , draftDeclType = IFunction paramTypes resultType
          , draftDeclParams = draftParams
          , draftDeclBody = body
          }

inferExpr :: ModuleContext -> DeclTypeEnv -> LocalEnv -> Expr -> InferM DraftExpr
inferExpr ctx termEnv localEnv expr =
  case expr of
    EVar span' name ->
      if name == "empty" && Map.notMember name localEnv && Map.notMember name termEnv
        then pure (DraftExpr span' (INamed viewTypeName) DraftViewEmpty)
        else case Map.lookup name localEnv of
        Just localBinding ->
          pure (DraftExpr span' (localBindingType localBinding) (DraftVar name))
        Nothing ->
          case Map.lookup name termEnv of
            Just topLevelType ->
              pure (DraftExpr span' (typeToInferType topLevelType) (DraftVar name))
            Nothing ->
              if Map.member name (contextDeclMap ctx)
                then throwError (InferDeferredName name span')
                else
                  throwDiagnostic $
                    singleDiagnosticAt
                      "E_UNBOUND_NAME"
                      ("Unknown name `" <> name <> "`.")
                      span'
                      ["Introduce a declaration or fix the spelling of the reference."]
    EInt span' value ->
      pure (DraftExpr span' IInt (DraftInt value))
    EString span' value ->
      pure (DraftExpr span' IStr (DraftString value))
    EBool span' value ->
      pure (DraftExpr span' IBool (DraftBool value))
    EList span' values ->
      inferListExpr ctx termEnv localEnv span' values
    EReturn returnSpan value -> do
      maybeReturnType <- gets inferReturnType
      case maybeReturnType of
        Nothing ->
          throwDiagnostic $
            singleDiagnosticAt
              "E_RETURN_OUTSIDE_FUNCTION"
              "`return` is only allowed inside function bodies."
              returnSpan
              ["Use the final expression value directly, or move the `return` inside a function declaration."]
        Just returnType -> do
          valueExpr <- inferExpr ctx termEnv localEnv value
          unify
            ( UnifyContext
                { unifyCode = "E_TYPE_MISMATCH"
                , unifySummary = "Type mismatch."
                , unifyPrimarySpan = exprSpan value
                , unifyRelated = [diagnosticRelated "function return" returnSpan]
                }
            )
            (draftExprType valueExpr)
            returnType
          pure (DraftExpr returnSpan returnType (DraftReturn valueExpr))
    EBlock blockSpan body -> do
      bodyExpr <- inferExpr ctx termEnv localEnv body
      pure bodyExpr {draftExprSpan = blockSpan}
    EEqual equalitySpan left right ->
      inferEqualityExpr ctx termEnv localEnv equalitySpan True left right
    ENotEqual equalitySpan left right ->
      inferEqualityExpr ctx termEnv localEnv equalitySpan False left right
    ELessThan comparisonSpan left right ->
      inferIntegerComparisonExpr ctx termEnv localEnv comparisonSpan DraftLessThan left right
    ELessThanOrEqual comparisonSpan left right ->
      inferIntegerComparisonExpr ctx termEnv localEnv comparisonSpan DraftLessThanOrEqual left right
    EGreaterThan comparisonSpan left right ->
      inferIntegerComparisonExpr ctx termEnv localEnv comparisonSpan DraftGreaterThan left right
    EGreaterThanOrEqual comparisonSpan left right ->
      inferIntegerComparisonExpr ctx termEnv localEnv comparisonSpan DraftGreaterThanOrEqual left right
    ELet letSpan _ binderName value body -> do
      valueExpr <- inferExpr ctx termEnv localEnv value
      bodyExpr <- inferExpr ctx termEnv (Map.insert binderName (immutableLocalBinding (draftExprType valueExpr)) localEnv) body
      pure (DraftExpr letSpan (draftExprType bodyExpr) (DraftLet binderName valueExpr bodyExpr))
    EMutableLet letSpan _ binderName value body -> do
      valueExpr <- inferExpr ctx termEnv localEnv value
      bodyExpr <- inferExpr ctx termEnv (Map.insert binderName (mutableLocalBinding (draftExprType valueExpr)) localEnv) body
      pure (DraftExpr letSpan (draftExprType bodyExpr) (DraftMutableLet binderName valueExpr bodyExpr))
    EAssign assignSpan targetSpan binderName value body ->
      case Map.lookup binderName localEnv of
        Just localBinding
          | localBindingMutable localBinding -> do
              valueExpr <- inferExpr ctx termEnv localEnv value
              unify
                ( UnifyContext
                    { unifyCode = "E_TYPE_MISMATCH"
                    , unifySummary = "Type mismatch."
                    , unifyPrimarySpan = exprSpan value
                    , unifyRelated = [diagnosticRelated "mutable local" targetSpan]
                    }
                )
                (draftExprType valueExpr)
                (localBindingType localBinding)
              bodyExpr <- inferExpr ctx termEnv (Map.insert binderName localBinding localEnv) body
              pure (DraftExpr assignSpan (draftExprType bodyExpr) (DraftAssign binderName valueExpr bodyExpr))
          | otherwise ->
              throwDiagnostic $
                singleDiagnosticAt
                  "E_ASSIGNMENT_TARGET"
                  ("Assignment target `" <> binderName <> "` is not mutable.")
                  targetSpan
                  ["Declare the local with `let mut " <> binderName <> " = ...;` before assigning to it."]
        Nothing ->
          throwDiagnostic $
            singleDiagnosticAt
              "E_ASSIGNMENT_TARGET"
              ("Assignment target `" <> binderName <> "` is not a mutable local.")
              targetSpan
              ["Declare the name in the current block with `let mut " <> binderName <> " = ...;` before assigning to it."]
    EFor loopSpan _ binderName iterable loopBody body -> do
      itemType <- freshTypeVar
      iterableExpr <- inferExpr ctx termEnv localEnv iterable
      unify
        ( UnifyContext
            { unifyCode = "E_FOR_ITERABLE"
            , unifySummary = "For-loops must iterate over list values."
            , unifyPrimarySpan = exprSpan iterable
            , unifyRelated = []
            }
        )
        (draftExprType iterableExpr)
        (IList itemType)
      loopBodyExpr <- inferExpr ctx termEnv (Map.insert binderName (immutableLocalBinding itemType) localEnv) loopBody
      bodyExpr <- inferExpr ctx termEnv localEnv body
      pure (DraftExpr loopSpan (draftExprType bodyExpr) (DraftFor binderName iterableExpr loopBodyExpr bodyExpr))
    ECall callSpan fn args ->
      case fn of
        EVar _ name
          | isBuiltinViewFunctionName name
          , Map.notMember name localEnv
          , Map.notMember name termEnv ->
              inferBuiltinViewCall ctx termEnv localEnv callSpan name args
          | isBuiltinPromptFunctionName name
          , Map.notMember name localEnv
          , Map.notMember name termEnv ->
              inferBuiltinPromptCall ctx termEnv localEnv callSpan name args
          | isBuiltinAuthFunctionName name
          , Map.notMember name localEnv
          , Map.notMember name termEnv ->
              inferBuiltinAuthCall ctx termEnv localEnv callSpan name args
        _ ->
          inferRegularCall ctx termEnv localEnv callSpan fn args
    ERecord recordSpan recordName fields ->
      inferRecordExpr ctx termEnv localEnv recordSpan recordName fields
    EFieldAccess accessSpan subject fieldName ->
      inferFieldAccessExpr ctx termEnv localEnv accessSpan subject fieldName
    EDecode decodeSpan targetType rawJson ->
      inferDecodeExpr ctx termEnv localEnv decodeSpan targetType rawJson
    EEncode encodeSpan value ->
      inferEncodeExpr ctx termEnv localEnv encodeSpan value
    EMatch matchSpan subject branches -> inferMatchExpr ctx termEnv localEnv matchSpan subject branches

inferListExpr :: ModuleContext -> DeclTypeEnv -> LocalEnv -> SourceSpan -> [Expr] -> InferM DraftExpr
inferListExpr ctx termEnv localEnv listSpan values = do
  itemType <- freshTypeVar
  draftValues <- traverse (inferExpr ctx termEnv localEnv) values
  zipWithM_
    ( \index draftValue ->
        unify
          ( UnifyContext
              { unifyCode = "E_LIST_ITEM_TYPE"
              , unifySummary = "List elements must all have the same type."
              , unifyPrimarySpan = draftExprSpan draftValue
              , unifyRelated =
                  case drop index draftValues of
                    [] ->
                      []
                    _ : _ ->
                      case draftValues of
                        firstValue : _
                          | draftExprSpan firstValue /= draftExprSpan draftValue ->
                              [diagnosticRelated "first list element" (draftExprSpan firstValue)]
                        _ ->
                          []
              }
          )
          (draftExprType draftValue)
          itemType
    )
    [(0 :: Int) ..]
    draftValues
  pure (DraftExpr listSpan (IList itemType) (DraftList draftValues))

inferEqualityExpr :: ModuleContext -> DeclTypeEnv -> LocalEnv -> SourceSpan -> Bool -> Expr -> Expr -> InferM DraftExpr
inferEqualityExpr ctx termEnv localEnv equalitySpan isEqual left right = do
  leftExpr <- inferExpr ctx termEnv localEnv left
  rightExpr <- inferExpr ctx termEnv localEnv right
  unify
    ( UnifyContext
        { unifyCode = "E_EQUALITY_OPERAND"
        , unifySummary = "Equality operands must have the same supported primitive type."
        , unifyPrimarySpan = equalitySpan
        , unifyRelated = []
        }
    )
    (draftExprType leftExpr)
    (draftExprType rightExpr)
  resolvedOperandType <- resolveCurrentType (draftExprType leftExpr)
  case resolvedOperandType of
    IInt ->
      pure (DraftExpr equalitySpan IBool (if isEqual then DraftEqual leftExpr rightExpr else DraftNotEqual leftExpr rightExpr))
    IStr ->
      pure (DraftExpr equalitySpan IBool (if isEqual then DraftEqual leftExpr rightExpr else DraftNotEqual leftExpr rightExpr))
    IBool ->
      pure (DraftExpr equalitySpan IBool (if isEqual then DraftEqual leftExpr rightExpr else DraftNotEqual leftExpr rightExpr))
    _ ->
      throwDiagnostic . diagnosticBundle $
        [ diagnostic
            "E_EQUALITY_OPERAND"
            "Equality operands must have the same supported primitive type."
            (Just equalitySpan)
            ["Only `Int`, `Str`, and `Bool` currently support `==` and `!=`."]
            []
        ]

inferIntegerComparisonExpr :: ModuleContext -> DeclTypeEnv -> LocalEnv -> SourceSpan -> (DraftExpr -> DraftExpr -> DraftExprNode) -> Expr -> Expr -> InferM DraftExpr
inferIntegerComparisonExpr ctx termEnv localEnv comparisonSpan constructor left right = do
  leftExpr <- inferExpr ctx termEnv localEnv left
  rightExpr <- inferExpr ctx termEnv localEnv right
  let unifyContext =
        UnifyContext
          { unifyCode = "E_INTEGER_COMPARISON_OPERAND"
          , unifySummary = "Integer comparison operands must both be Int."
          , unifyPrimarySpan = comparisonSpan
          , unifyRelated = []
          }
  unify unifyContext (draftExprType leftExpr) IInt
  unify unifyContext (draftExprType rightExpr) IInt
  pure (DraftExpr comparisonSpan IBool (constructor leftExpr rightExpr))

inferRegularCall :: ModuleContext -> DeclTypeEnv -> LocalEnv -> SourceSpan -> Expr -> [Expr] -> InferM DraftExpr
inferRegularCall ctx termEnv localEnv callSpan fn args = do
  fnExpr <- inferExpr ctx termEnv localEnv fn
  resolvedFnType <- resolveCurrentType (draftExprType fnExpr)
  case resolvedFnType of
    IFunction paramTypes _ ->
      when (length paramTypes /= length args) $
        throwDiagnostic . diagnosticBundle $
          [ diagnostic
              "E_CALL_ARITY"
              "Function call does not match the declared arity."
              (Just callSpan)
              [ "Expected "
                  <> T.pack (show (length paramTypes))
                  <> " arguments but got "
                  <> T.pack (show (length args))
                  <> "."
              ]
              (relatedForFunction fn (contextDeclMap ctx) (contextForeignDeclEnv ctx) (contextConstructorEnv ctx))
          ]
    IVar _ ->
      pure ()
    _ ->
      throwDiagnostic . diagnosticBundle $
        [ diagnostic
            "E_NOT_A_FUNCTION"
            "Tried to call a non-function value."
            (Just callSpan)
            ["Only function-typed values can be applied to arguments."]
            []
        ]
  argExprs <- traverse (inferExpr ctx termEnv localEnv) args
  expectedParamTypes <- traverse (const freshTypeVar) args
  resultType <- freshTypeVar
  unify
    ( UnifyContext
        { unifyCode = "E_NOT_A_FUNCTION"
        , unifySummary = "Tried to call a non-function value."
        , unifyPrimarySpan = callSpan
        , unifyRelated = []
        }
    )
    (draftExprType fnExpr)
    (IFunction expectedParamTypes resultType)
  zipWithM_
    ( \argExpr expectedParamType ->
        unify
          ( UnifyContext
              { unifyCode = "E_TYPE_MISMATCH"
              , unifySummary = "Argument type does not match the function signature."
              , unifyPrimarySpan = draftExprSpan argExpr
              , unifyRelated = relatedForFunction fn (contextDeclMap ctx) (contextForeignDeclEnv ctx) (contextConstructorEnv ctx)
              }
          )
          (draftExprType argExpr)
          expectedParamType
    )
    argExprs
    expectedParamTypes
  pure (DraftExpr callSpan resultType (DraftCall fnExpr argExprs))

inferBuiltinViewCall :: ModuleContext -> DeclTypeEnv -> LocalEnv -> SourceSpan -> Text -> [Expr] -> InferM DraftExpr
inferBuiltinViewCall ctx termEnv localEnv callSpan builtinName args =
  case builtinName of
    "page" ->
      case args of
        [titleExpr, bodyExpr] -> do
          draftTitle <- inferExpr ctx termEnv localEnv titleExpr
          draftBody <- inferExpr ctx termEnv localEnv bodyExpr
          unifyViewBuiltinArg "page title" draftTitle IStr
          unifyViewBuiltinArg "page body" draftBody (INamed viewTypeName)
          pure (DraftExpr callSpan (INamed pageTypeName) (DraftPage draftTitle draftBody))
        _ ->
          throwViewBuiltinArity callSpan builtinName 2 (length args)
    "redirect" ->
      case args of
        [EString _ targetPath] -> do
          unless (isSafeNavigationTarget targetPath) $
            throwDiagnostic . diagnosticBundle $
              [ diagnostic
                  "E_REDIRECT_TARGET"
                  ("Invalid redirect target `" <> targetPath <> "`.")
                  (Just callSpan)
                  ["Use an absolute in-app path such as `/inbox` or `/lead/primary`."]
                  []
              ]
          case resolveNavigationRoute ctx RouteGet targetPath ["page"] of
            Nothing ->
              throwDiagnostic . diagnosticBundle $
                [ diagnostic
                    "E_REDIRECT_TARGET"
                    ("Redirect target `" <> normalizeNavigationTarget targetPath <> "` does not match any GET Page route.")
                    (Just callSpan)
                    ["Declare a GET route that returns `Page` before using it as a redirect target."]
                    []
                ]
            Just _ ->
              pure (DraftExpr callSpan (INamed redirectTypeName) (DraftRedirect targetPath))
        [_] ->
          throwDiagnostic . diagnosticBundle $
            [ diagnostic
                "E_REDIRECT_TARGET"
                "Redirect targets must be string literals."
                (Just callSpan)
                ["Use `redirect \"/inbox\"` so the compiler can validate the destination route."]
                []
            ]
        _ ->
          throwViewBuiltinArity callSpan builtinName 1 (length args)
    "text" ->
      case args of
        [valueExpr] -> do
          draftValue <- inferExpr ctx termEnv localEnv valueExpr
          unifyViewBuiltinArg "text value" draftValue IStr
          pure (DraftExpr callSpan (INamed viewTypeName) (DraftViewText draftValue))
        _ ->
          throwViewBuiltinArity callSpan builtinName 1 (length args)
    "append" ->
      case args of
        [leftExpr, rightExpr] -> do
          draftLeft <- inferExpr ctx termEnv localEnv leftExpr
          draftRight <- inferExpr ctx termEnv localEnv rightExpr
          unifyViewBuiltinArg "append left child" draftLeft (INamed viewTypeName)
          unifyViewBuiltinArg "append right child" draftRight (INamed viewTypeName)
          pure (DraftExpr callSpan (INamed viewTypeName) (DraftViewAppend draftLeft draftRight))
        _ ->
          throwViewBuiltinArity callSpan builtinName 2 (length args)
    "element" ->
      case args of
        [EString _ tagName, childExpr] -> do
          unless (isSafeViewTag tagName) $
            throwDiagnostic . diagnosticBundle $
              [ diagnostic
                  "E_VIEW_TAG"
                  ("Unsafe or unsupported HTML tag `" <> tagName <> "` in safe view rendering.")
                  (Just callSpan)
                  ["Use an inert lowercase tag such as `div`, `section`, `h1`, or `p`."]
                  []
              ]
          draftChild <- inferExpr ctx termEnv localEnv childExpr
          unifyViewBuiltinArg "element child" draftChild (INamed viewTypeName)
          pure (DraftExpr callSpan (INamed viewTypeName) (DraftViewElement tagName draftChild))
        [_, _] ->
          throwDiagnostic . diagnosticBundle $
            [ diagnostic
                "E_VIEW_TAG"
                "View element tags must be string literals."
                (Just callSpan)
                ["Use `element \"div\" child` style calls so the compiler can validate the tag."]
                []
            ]
        _ ->
          throwViewBuiltinArity callSpan builtinName 2 (length args)
    "styled" ->
      case args of
        [EString _ styleRef, childExpr] -> do
          unless (isSafeStyleRef styleRef) $
            throwDiagnostic . diagnosticBundle $
              [ diagnostic
                  "E_VIEW_STYLE_REF"
                  ("Invalid style reference `" <> styleRef <> "`.")
                  (Just callSpan)
                  ["Use lowercase letters, digits, `-`, and `_` in explicit style references."]
                  []
              ]
          draftChild <- inferExpr ctx termEnv localEnv childExpr
          unifyViewBuiltinArg "styled child" draftChild (INamed viewTypeName)
          pure (DraftExpr callSpan (INamed viewTypeName) (DraftViewStyled styleRef draftChild))
        [_, _] ->
          throwDiagnostic . diagnosticBundle $
            [ diagnostic
                "E_VIEW_STYLE_REF"
                "Style references must be string literals."
                (Just callSpan)
                ["Use `styled \"inbox_shell\" child` so the compiler can keep styling explicit."]
                []
            ]
        _ ->
          throwViewBuiltinArity callSpan builtinName 2 (length args)
    "link" ->
      case args of
        [EString _ href, childExpr] -> do
          unless (isSafeNavigationTarget href) $
            throwDiagnostic . diagnosticBundle $
              [ diagnostic
                  "E_VIEW_LINK_TARGET"
                  ("Invalid link target `" <> href <> "`.")
                  (Just callSpan)
                  ["Use an absolute in-app path such as `/inbox` or `/lead?leadId=lead-1`."]
                  []
              ]
          routeDecl <-
            case resolveNavigationRoute ctx RouteGet href ["page"] of
              Nothing ->
                throwDiagnostic . diagnosticBundle $
                  [ diagnostic
                      "E_VIEW_LINK_TARGET"
                      ("Link target `" <> normalizeNavigationTarget href <> "` does not match any GET Page route.")
                      (Just callSpan)
                      ["Declare a GET route that returns `Page` before linking to it."]
                      []
                  ]
              Just resolvedRoute ->
                pure resolvedRoute
          draftChild <- inferExpr ctx termEnv localEnv childExpr
          unifyViewBuiltinArg "link child" draftChild (INamed viewTypeName)
          pure (DraftExpr callSpan (INamed viewTypeName) (DraftViewLink routeDecl href draftChild))
        [_, _] ->
          throwDiagnostic . diagnosticBundle $
            [ diagnostic
                "E_VIEW_LINK_TARGET"
                "Link targets must be string literals."
                (Just callSpan)
                ["Use `link \"/lead?leadId=lead-1\" child` so the compiler can validate navigation."]
                []
            ]
        _ ->
          throwViewBuiltinArity callSpan builtinName 2 (length args)
    "form" ->
      case args of
        [EString _ method, EString _ action, childExpr] -> do
          unless (isSafeFormMethod method) $
            throwDiagnostic . diagnosticBundle $
              [ diagnostic
                  "E_VIEW_FORM_METHOD"
                  ("Invalid form method `" <> method <> "`.")
                  (Just callSpan)
                  ["Use `GET` or `POST` so the default server renderer can preserve request semantics."]
                  []
              ]
          unless (isSafeNavigationTarget action) $
            throwDiagnostic . diagnosticBundle $
              [ diagnostic
                  "E_VIEW_LINK_TARGET"
                  ("Invalid form action `" <> action <> "`.")
                  (Just callSpan)
                  ["Use an absolute in-app path such as `/leads` or `/review`."]
                  []
              ]
          let routeMethod =
                case method of
                  "GET" -> RouteGet
                  "POST" -> RoutePost
                  _ -> RouteGet
          routeDecl <-
            case resolveNavigationRoute ctx routeMethod action ["page", "redirect"] of
              Nothing ->
                throwDiagnostic . diagnosticBundle $
                  [ diagnostic
                      "E_VIEW_FORM_METHOD"
                      ("Form action `" <> normalizeNavigationTarget action <> "` does not match any " <> method <> " Page or Redirect route.")
                      (Just callSpan)
                      ["Declare a matching route that returns `Page` or `Redirect` before wiring it into a form."]
                      []
                  ]
              Just resolvedRoute ->
                pure resolvedRoute
          draftChild <- inferExpr ctx termEnv localEnv childExpr
          unifyViewBuiltinArg "form child" draftChild (INamed viewTypeName)
          pure (DraftExpr callSpan (INamed viewTypeName) (DraftViewForm routeDecl method action draftChild))
        [_, _, _] ->
          throwDiagnostic . diagnosticBundle $
            [ diagnostic
                "E_VIEW_FORM_METHOD"
                "Form methods and actions must be string literals."
                (Just callSpan)
                ["Use `form \"POST\" \"/leads\" child` so the compiler can validate the submission target."]
                []
            ]
        _ ->
          throwViewBuiltinArity callSpan builtinName 3 (length args)
    "input" ->
      case args of
        [EString _ fieldName, EString _ inputKind, valueExpr] -> do
          unless (isSafeFieldName fieldName) $
            throwDiagnostic . diagnosticBundle $
              [ diagnostic
                  "E_VIEW_INPUT"
                  ("Invalid input field name `" <> fieldName <> "`.")
                  (Just callSpan)
                  ["Use letters, digits, and underscores in generated form field names."]
                  []
              ]
          unless (isSafeInputKind inputKind) $
            throwDiagnostic . diagnosticBundle $
              [ diagnostic
                  "E_VIEW_INPUT"
                  ("Unsupported input kind `" <> inputKind <> "`.")
                  (Just callSpan)
                  ["Use `text`, `number`, or `hidden` in the safe default renderer."]
                  []
              ]
          draftValue <- inferExpr ctx termEnv localEnv valueExpr
          unifyViewBuiltinArg "input value" draftValue IStr
          pure (DraftExpr callSpan (INamed viewTypeName) (DraftViewInput fieldName inputKind draftValue))
        [_, _, _] ->
          throwDiagnostic . diagnosticBundle $
            [ diagnostic
                "E_VIEW_INPUT"
                "Input field names and kinds must be string literals."
                (Just callSpan)
                ["Use `input \"company\" \"text\" companyName` style calls."]
                []
            ]
        _ ->
          throwViewBuiltinArity callSpan builtinName 3 (length args)
    "submit" ->
      case args of
        [labelExpr] -> do
          draftLabel <- inferExpr ctx termEnv localEnv labelExpr
          unifyViewBuiltinArg "submit label" draftLabel IStr
          pure (DraftExpr callSpan (INamed viewTypeName) (DraftViewSubmit draftLabel))
        _ ->
          throwViewBuiltinArity callSpan builtinName 1 (length args)
    name
      | name == hostClassBuiltinName || name == hostStyleBuiltinName ->
          throwDiagnostic . diagnosticBundle $
            [ diagnostic
                "E_UNSAFE_VIEW_ESCAPE"
                ("`" <> name <> "` is not available in the safe default page renderer.")
                (Just callSpan)
                ["Use `styled` with an explicit style reference instead of raw host class or style strings."]
                []
            ]
    _ ->
      inferRegularCall ctx termEnv localEnv callSpan (EVar callSpan builtinName) args

inferBuiltinPromptCall :: ModuleContext -> DeclTypeEnv -> LocalEnv -> SourceSpan -> Text -> [Expr] -> InferM DraftExpr
inferBuiltinPromptCall ctx termEnv localEnv callSpan builtinName args =
  case builtinName of
    name
      | name `elem` [systemPromptBuiltinName, assistantPromptBuiltinName, userPromptBuiltinName] ->
          case args of
            [contentExpr] -> do
              draftContent <- inferExpr ctx termEnv localEnv contentExpr
              unifyPromptBuiltinArg (name <> " content") draftContent IStr
              let role =
                    case name of
                      builtin | builtin == systemPromptBuiltinName -> "system"
                      builtin | builtin == assistantPromptBuiltinName -> "assistant"
                      _ -> "user"
              pure (DraftExpr callSpan (INamed promptTypeName) (DraftPromptMessage role draftContent))
            _ ->
              throwPromptBuiltinArity callSpan builtinName 1 (length args)
      | name == appendPromptBuiltinName ->
          case args of
            [leftExpr, rightExpr] -> do
              draftLeft <- inferExpr ctx termEnv localEnv leftExpr
              draftRight <- inferExpr ctx termEnv localEnv rightExpr
              unifyPromptBuiltinArg "appendPrompt left" draftLeft (INamed promptTypeName)
              unifyPromptBuiltinArg "appendPrompt right" draftRight (INamed promptTypeName)
              pure (DraftExpr callSpan (INamed promptTypeName) (DraftPromptAppend draftLeft draftRight))
            _ ->
              throwPromptBuiltinArity callSpan builtinName 2 (length args)
      | name == promptTextBuiltinName ->
          case args of
            [promptExpr] -> do
              draftPrompt <- inferExpr ctx termEnv localEnv promptExpr
              unifyPromptBuiltinArg "promptText prompt" draftPrompt (INamed promptTypeName)
              pure (DraftExpr callSpan IStr (DraftPromptText draftPrompt))
            _ ->
              throwPromptBuiltinArity callSpan builtinName 1 (length args)
    _ ->
      inferRegularCall ctx termEnv localEnv callSpan (EVar callSpan builtinName) args

unifyPromptBuiltinArg :: Text -> DraftExpr -> InferType -> InferM ()
unifyPromptBuiltinArg _ draftExpr expectedType =
  unify
    ( UnifyContext
        { unifyCode = "E_TYPE_MISMATCH"
        , unifySummary = "Prompt builtin argument type does not match the expected shape."
        , unifyPrimarySpan = draftExprSpan draftExpr
        , unifyRelated = []
        }
    )
    (draftExprType draftExpr)
    expectedType

throwPromptBuiltinArity :: SourceSpan -> Text -> Int -> Int -> InferM a
throwPromptBuiltinArity callSpan builtinName expectedArity actualArity =
  throwDiagnostic . diagnosticBundle $
    [ diagnostic
        "E_CALL_ARITY"
        ("Prompt builtin `" <> builtinName <> "` does not match the expected arity.")
        (Just callSpan)
        [ "Expected "
            <> T.pack (show expectedArity)
            <> " arguments but got "
            <> T.pack (show actualArity)
            <> "."
        ]
        []
    ]

unifyViewBuiltinArg :: Text -> DraftExpr -> InferType -> InferM ()
unifyViewBuiltinArg _ draftExpr expectedType =
  unify
    ( UnifyContext
        { unifyCode = "E_TYPE_MISMATCH"
        , unifySummary = "View primitive argument has the wrong type."
        , unifyPrimarySpan = draftExprSpan draftExpr
        , unifyRelated = []
        }
    )
    (draftExprType draftExpr)
    expectedType

throwViewBuiltinArity :: SourceSpan -> Text -> Int -> Int -> InferM a
throwViewBuiltinArity callSpan builtinName expectedArity actualArity =
  throwDiagnostic . diagnosticBundle $
    [ diagnostic
        "E_CALL_ARITY"
        "Function call does not match the declared arity."
        (Just callSpan)
        [ "Builtin `"
            <> builtinName
            <> "` expects "
            <> T.pack (show expectedArity)
            <> " arguments but got "
            <> T.pack (show actualArity)
            <> "."
        ]
        []
    ]

inferBuiltinAuthCall :: ModuleContext -> DeclTypeEnv -> LocalEnv -> SourceSpan -> Text -> [Expr] -> InferM DraftExpr
inferBuiltinAuthCall ctx termEnv localEnv callSpan builtinName args =
  case builtinName of
    name
      | name == principalBuiltinName ->
          case args of
            [idExpr] -> do
              draftId <- inferExpr ctx termEnv localEnv idExpr
              unifyBuiltinRecordArg "principal id" draftId IStr
              pure
                ( DraftExpr
                    callSpan
                    (INamed principalTypeName)
                    ( DraftRecord
                        principalTypeName
                        [DraftRecordField "id" draftId]
                    )
                )
            _ ->
              throwBuiltinRecordArity callSpan builtinName 1 (length args)
      | name == tenantBuiltinName ->
          case args of
            [idExpr] -> do
              draftId <- inferExpr ctx termEnv localEnv idExpr
              unifyBuiltinRecordArg "tenant id" draftId IStr
              pure
                ( DraftExpr
                    callSpan
                    (INamed tenantTypeName)
                    ( DraftRecord
                        tenantTypeName
                        [DraftRecordField "id" draftId]
                    )
                )
            _ ->
              throwBuiltinRecordArity callSpan builtinName 1 (length args)
      | name == resourceIdentityBuiltinName ->
          case args of
            [resourceTypeExpr, resourceIdExpr] -> do
              draftResourceType <- inferExpr ctx termEnv localEnv resourceTypeExpr
              draftResourceId <- inferExpr ctx termEnv localEnv resourceIdExpr
              unifyBuiltinRecordArg "resource identity type" draftResourceType IStr
              unifyBuiltinRecordArg "resource identity id" draftResourceId IStr
              pure
                ( DraftExpr
                    callSpan
                    (INamed resourceIdentityTypeName)
                    ( DraftRecord
                        resourceIdentityTypeName
                        [ DraftRecordField "resourceType" draftResourceType
                        , DraftRecordField "resourceId" draftResourceId
                        ]
                    )
                )
            _ ->
              throwBuiltinRecordArity callSpan builtinName 2 (length args)
      | name == authSessionBuiltinName ->
          case args of
            [sessionIdExpr, principalExpr, tenantExpr, resourceExpr] -> do
              draftSessionId <- inferExpr ctx termEnv localEnv sessionIdExpr
              draftPrincipal <- inferExpr ctx termEnv localEnv principalExpr
              draftTenant <- inferExpr ctx termEnv localEnv tenantExpr
              draftResource <- inferExpr ctx termEnv localEnv resourceExpr
              unifyBuiltinRecordArg "auth session id" draftSessionId IStr
              unifyBuiltinRecordArg "auth session principal" draftPrincipal (INamed principalTypeName)
              unifyBuiltinRecordArg "auth session tenant" draftTenant (INamed tenantTypeName)
              unifyBuiltinRecordArg "auth session resource" draftResource (INamed resourceIdentityTypeName)
              pure
                ( DraftExpr
                    callSpan
                    (INamed authSessionTypeName)
                    ( DraftRecord
                        authSessionTypeName
                        [ DraftRecordField "sessionId" draftSessionId
                        , DraftRecordField "principal" draftPrincipal
                        , DraftRecordField "tenant" draftTenant
                        , DraftRecordField "resource" draftResource
                        ]
                    )
                )
            _ ->
              throwBuiltinRecordArity callSpan builtinName 4 (length args)
    _ ->
      inferRegularCall ctx termEnv localEnv callSpan (EVar callSpan builtinName) args

unifyBuiltinRecordArg :: Text -> DraftExpr -> InferType -> InferM ()
unifyBuiltinRecordArg _ draftExpr expectedType =
  unify
    ( UnifyContext
        { unifyCode = "E_TYPE_MISMATCH"
        , unifySummary = "Builtin auth identity argument has the wrong type."
        , unifyPrimarySpan = draftExprSpan draftExpr
        , unifyRelated = []
        }
    )
    (draftExprType draftExpr)
    expectedType

throwBuiltinRecordArity :: SourceSpan -> Text -> Int -> Int -> InferM a
throwBuiltinRecordArity callSpan builtinName expectedArity actualArity =
  throwDiagnostic . diagnosticBundle $
    [ diagnostic
        "E_CALL_ARITY"
        "Function call does not match the declared arity."
        (Just callSpan)
        [ "Builtin `"
            <> builtinName
            <> "` expects "
            <> T.pack (show expectedArity)
            <> " arguments but got "
            <> T.pack (show actualArity)
            <> "."
        ]
        []
    ]

inferRecordExpr :: ModuleContext -> DeclTypeEnv -> LocalEnv -> SourceSpan -> Text -> [RecordFieldExpr] -> InferM DraftExpr
inferRecordExpr ctx termEnv localEnv recordSpan recordName fields =
  case Map.lookup recordName (contextRecordDeclEnv ctx) of
    Nothing ->
      throwDiagnostic $
        singleDiagnosticAt
          "E_UNKNOWN_RECORD"
          ("Unknown record `" <> recordName <> "`.")
          recordSpan
          ["Declare the record before constructing it."]
    Just recordDecl -> do
      ensureUniqueRecordExprFields fields
      let expectedFields = recordDeclFields recordDecl
          expectedFieldNames = fmap recordFieldDeclName expectedFields
          actualFieldNames = fmap recordFieldExprName fields
          missingFields = filter (`notElem` actualFieldNames) expectedFieldNames
          extraFields = filter (`notElem` expectedFieldNames) actualFieldNames
      unless (null missingFields) $
        throwDiagnostic . diagnosticBundle $
          [ diagnostic
              "E_RECORD_MISSING_FIELDS"
              ("Record literal for `" <> recordName <> "` is missing fields.")
              (Just recordSpan)
              ["Add fields for: " <> T.intercalate ", " missingFields <> "."]
              [diagnosticRelated "record declaration" (recordDeclNameSpan recordDecl)]
          ]
      unless (null extraFields) $
        throwDiagnostic . diagnosticBundle $
          [ diagnostic
              "E_RECORD_UNKNOWN_FIELDS"
              ("Record literal for `" <> recordName <> "` includes unknown fields.")
              (Just recordSpan)
              ["Remove fields: " <> T.intercalate ", " extraFields <> "."]
              [diagnosticRelated "record declaration" (recordDeclNameSpan recordDecl)]
          ]
      let fieldTypeMap =
            Map.fromList
              [ (recordFieldDeclName fieldDecl, typeToInferType (recordFieldDeclType fieldDecl))
              | fieldDecl <- expectedFields
              ]
      draftFields <-
        traverse
          ( \fieldExpr -> do
              fieldValue <- inferExpr ctx termEnv localEnv (recordFieldExprValue fieldExpr)
              case Map.lookup (recordFieldExprName fieldExpr) fieldTypeMap of
                Just expectedFieldType ->
                  unify
                    ( UnifyContext
                        { unifyCode = "E_TYPE_MISMATCH"
                        , unifySummary = "Record field type does not match the declaration."
                        , unifyPrimarySpan = recordFieldExprSpan fieldExpr
                        , unifyRelated = [diagnosticRelated "record declaration" (recordDeclNameSpan recordDecl)]
                        }
                    )
                    (draftExprType fieldValue)
                    expectedFieldType
                Nothing ->
                  pure ()
              pure
                DraftRecordField
                  { draftRecordFieldName = recordFieldExprName fieldExpr
                  , draftRecordFieldValue = fieldValue
                  }
          )
          fields
      pure
        ( DraftExpr
            recordSpan
            (INamed recordName)
            (DraftRecord recordName draftFields)
        )

inferFieldAccessExpr :: ModuleContext -> DeclTypeEnv -> LocalEnv -> SourceSpan -> Expr -> Text -> InferM DraftExpr
inferFieldAccessExpr ctx termEnv localEnv accessSpan subject fieldName = do
  subjectExpr <- inferExpr ctx termEnv localEnv subject
  recordDecl <- resolveFieldAccessRecord ctx accessSpan fieldName (draftExprType subjectExpr)
  case lookupRecordField fieldName recordDecl of
    Just fieldDecl ->
      pure
        ( DraftExpr
            accessSpan
            (typeToInferType (recordFieldDeclType fieldDecl))
            (DraftFieldAccess subjectExpr fieldName)
        )
    Nothing ->
      throwDiagnostic . diagnosticBundle $
        [ diagnostic
            "E_UNKNOWN_FIELD"
            ("Record `" <> recordDeclName recordDecl <> "` does not define field `" <> fieldName <> "`.")
            (Just accessSpan)
            ["Use one of the declared record fields."]
            [diagnosticRelated "record declaration" (recordDeclNameSpan recordDecl)]
        ]

inferDecodeExpr :: ModuleContext -> DeclTypeEnv -> LocalEnv -> SourceSpan -> Type -> Expr -> InferM DraftExpr
inferDecodeExpr ctx termEnv localEnv decodeSpan targetType rawJson = do
  ensureJsonTypeSupported ctx decodeSpan targetType
  rawJsonExpr <- inferExpr ctx termEnv localEnv rawJson
  unify
    ( UnifyContext
        { unifyCode = "E_JSON_DECODE"
        , unifySummary = "JSON decode expects a string input."
        , unifyPrimarySpan = draftExprSpan rawJsonExpr
        , unifyRelated = []
        }
    )
    (draftExprType rawJsonExpr)
    IStr
  pure
    ( DraftExpr
        decodeSpan
        (typeToInferType targetType)
        (DraftDecodeJson targetType rawJsonExpr)
    )

inferEncodeExpr :: ModuleContext -> DeclTypeEnv -> LocalEnv -> SourceSpan -> Expr -> InferM DraftExpr
inferEncodeExpr ctx termEnv localEnv encodeSpan value = do
  valueExpr <- inferExpr ctx termEnv localEnv value
  resolvedValueType <- resolveCurrentType (draftExprType valueExpr)
  case inferTypeToJsonType ctx resolvedValueType of
    Right _ ->
      pure (DraftExpr encodeSpan IStr (DraftEncodeJson valueExpr))
    Left Nothing ->
      pure (DraftExpr encodeSpan IStr (DraftEncodeJson valueExpr))
    Left (Just bundle) ->
      throwDiagnostic bundle

inferMatchExpr :: ModuleContext -> DeclTypeEnv -> LocalEnv -> SourceSpan -> Expr -> [MatchBranch] -> InferM DraftExpr
inferMatchExpr ctx termEnv localEnv matchSpan subject branches = do
  subjectExpr <- inferExpr ctx termEnv localEnv subject
  subjectType <- resolveCurrentType (draftExprType subjectExpr)
  initialExpectedTypeName <-
    case subjectType of
      INamed typeName ->
        if Map.member typeName (contextTypeDeclEnv ctx)
          then pure (Just typeName)
          else
            if Map.member typeName (contextRecordDeclEnv ctx)
              then
                throwDiagnostic . diagnosticBundle $
                  [ diagnostic
                      "E_MATCH_SUBJECT"
                      "Match expressions require an algebraic data type subject."
                      (Just matchSpan)
                      ["Record type `" <> typeName <> "` does not support constructor matching."]
                      []
                  ]
              else pure (Just typeName)
      IVar _ ->
        pure Nothing
      _ ->
        throwDiagnostic . diagnosticBundle $
          [ diagnostic
              "E_MATCH_SUBJECT"
              "Match expressions require an algebraic data type subject."
              (Just matchSpan)
              ["Expected a named sum type but got " <> renderInferType subjectType <> "."]
              []
          ]

  accumulator <-
    foldM
      (inferMatchBranch ctx termEnv localEnv)
      (MatchResultAccumulator initialExpectedTypeName Map.empty Nothing [])
      branches

  expectedTypeName <-
    case accumulatorExpectedTypeName accumulator of
      Just typeName ->
        pure typeName
      Nothing ->
        throwDiagnostic . diagnosticBundle $
          [ diagnostic
              "E_EMPTY_MATCH"
              "Match expressions require at least one branch."
              (Just matchSpan)
              ["Add branches for each constructor in the matched type."]
              []
          ]

  unify
    ( UnifyContext
        { unifyCode = "E_MATCH_SUBJECT"
        , unifySummary = "Match expressions require an algebraic data type subject."
        , unifyPrimarySpan = matchSpan
        , unifyRelated = []
        }
    )
    (draftExprType subjectExpr)
    (INamed expectedTypeName)

  typeDecl <-
    case Map.lookup expectedTypeName (contextTypeDeclEnv ctx) of
      Just resolvedTypeDecl ->
        pure resolvedTypeDecl
      Nothing ->
        throwDiagnostic $
          singleDiagnosticAt
            "E_UNKNOWN_TYPE"
            ("Unknown type `" <> expectedTypeName <> "`.")
            matchSpan
            ["Declare the type before matching on it."]

  ensureExhaustiveMatch typeDecl (accumulatorSeenBranches accumulator) matchSpan

  resultType <-
    case accumulatorFirstBranchType accumulator of
      Just (branchType, _) ->
        pure branchType
      Nothing ->
        throwDiagnostic . diagnosticBundle $
          [ diagnostic
              "E_EMPTY_MATCH"
              "Match expressions require at least one branch."
              (Just matchSpan)
              ["Add branches for each constructor in the matched type."]
              []
          ]

  pure
    ( DraftExpr
        matchSpan
        resultType
        (DraftMatch subjectExpr (accumulatorDraftBranches accumulator))
    )

inferMatchBranch ::
  ModuleContext ->
  DeclTypeEnv ->
  LocalEnv ->
  MatchResultAccumulator ->
  MatchBranch ->
  InferM MatchResultAccumulator
inferMatchBranch ctx termEnv localEnv accumulator branch = do
  (constructorName, constructorTypeName, draftPattern) <-
    resolveBranchPattern ctx (accumulatorExpectedTypeName accumulator) branch

  case Map.lookup constructorName (accumulatorSeenBranches accumulator) of
    Just previousBranch ->
      throwDiagnostic . diagnosticBundle $
        [ diagnostic
            "E_DUPLICATE_MATCH_BRANCH"
            ("Duplicate match branch for constructor `" <> constructorName <> "`.")
            (Just (matchBranchSpan branch))
            ["Each constructor may appear at most once in a match expression."]
            [diagnosticRelated "previous branch" (matchBranchSpan previousBranch)]
        ]
    Nothing ->
      pure ()

  let binderEnv =
        Map.fromList
          [ (draftPatternBinderName binder, immutableLocalBinding (draftPatternBinderType binder))
          | binder <- patternBinders draftPattern
          ]

  branchBody <- inferExpr ctx termEnv (Map.union binderEnv localEnv) (matchBranchBody branch)

  nextFirstBranchType <-
    case accumulatorFirstBranchType accumulator of
      Nothing ->
        pure (Just (draftExprType branchBody, branch))
      Just (expectedBranchType, expectedBranch) -> do
        unify
          ( UnifyContext
              { unifyCode = "E_MATCH_RESULT_TYPE"
              , unifySummary = "Match branches must all return the same type."
              , unifyPrimarySpan = matchBranchSpan branch
              , unifyRelated = [diagnosticRelated "first branch" (matchBranchSpan expectedBranch)]
              }
          )
          expectedBranchType
          (draftExprType branchBody)
        pure (accumulatorFirstBranchType accumulator)

  let nextExpectedTypeName =
        case accumulatorExpectedTypeName accumulator of
          Just existingTypeName ->
            Just existingTypeName
          Nothing ->
            Just constructorTypeName

  pure
    MatchResultAccumulator
      { accumulatorExpectedTypeName = nextExpectedTypeName
      , accumulatorSeenBranches = Map.insert constructorName branch (accumulatorSeenBranches accumulator)
      , accumulatorFirstBranchType = nextFirstBranchType
      , accumulatorDraftBranches =
          accumulatorDraftBranches accumulator
            <> [ DraftMatchBranch
                   { draftMatchBranchSpan = matchBranchSpan branch
                   , draftMatchBranchPattern = draftPattern
                   , draftMatchBranchBody = branchBody
                   }
               ]
      }

resolveBranchPattern ::
  ModuleContext ->
  Maybe Text ->
  MatchBranch ->
  InferM (Text, Text, DraftPattern)
resolveBranchPattern ctx maybeExpectedTypeName branch =
  case matchBranchPattern branch of
    PConstructor constructorSpan constructorName binders ->
      case Map.lookup constructorName (contextConstructorEnv ctx) of
        Nothing ->
          throwDiagnostic $
            singleDiagnosticAt
              "E_UNKNOWN_CONSTRUCTOR"
              ("Unknown constructor `" <> constructorName <> "`.")
              constructorSpan
              ["Declare the constructor before using it in a match branch."]
        Just constructorInfo -> do
          let actualTypeName = constructorInfoTypeName constructorInfo
          case maybeExpectedTypeName of
            Just expectedTypeName ->
              when (expectedTypeName /= actualTypeName) $
                throwDiagnostic . diagnosticBundle $
                  [ diagnostic
                      "E_PATTERN_TYPE_MISMATCH"
                      ("Constructor `" <> constructorName <> "` does not belong to type `" <> expectedTypeName <> "`.")
                      (Just constructorSpan)
                      ["Use a constructor declared by the matched type."]
                      [diagnosticRelated "constructor declaration" (constructorDeclNameSpan (constructorInfoDecl constructorInfo))]
                  ]
            Nothing ->
              pure ()
          let fieldTypes = fmap typeToInferType (constructorDeclFields (constructorInfoDecl constructorInfo))
          when (length binders /= length fieldTypes) $
            throwDiagnostic . diagnosticBundle $
              [ diagnostic
                  "E_PATTERN_ARITY"
                  ("Pattern for `" <> constructorName <> "` binds the wrong number of fields.")
                  (Just constructorSpan)
                  [ "Expected "
                      <> T.pack (show (length fieldTypes))
                      <> " binders but got "
                      <> T.pack (show (length binders))
                      <> "."
                  ]
                  [diagnosticRelated "constructor declaration" (constructorDeclNameSpan (constructorInfoDecl constructorInfo))]
              ]
          ensureUniquePatternBinders binders
          let draftBinders =
                zipWith
                  ( \binder binderType ->
                      DraftPatternBinder
                        { draftPatternBinderName = patternBinderName binder
                        , draftPatternBinderSpan = patternBinderSpan binder
                        , draftPatternBinderType = binderType
                        }
                  )
                  binders
                  fieldTypes
          pure
            ( constructorName
            , actualTypeName
            , DraftConstructorPattern constructorSpan constructorName draftBinders
            )

patternBinders :: DraftPattern -> [DraftPatternBinder]
patternBinders pattern' =
  case pattern' of
    DraftConstructorPattern _ _ binders ->
      binders

ensureUniquePatternBinders :: [PatternBinder] -> InferM ()
ensureUniquePatternBinders = go Map.empty
  where
    go _ [] = pure ()
    go seen (binder : rest) =
      case Map.lookup (patternBinderName binder) seen of
        Just previousBinder ->
          throwDiagnostic . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_PATTERN_BINDER"
                ("Duplicate pattern binder `" <> patternBinderName binder <> "`.")
                (Just (patternBinderSpan binder))
                ["Each bound name may only appear once within a single match pattern."]
                [diagnosticRelated "previous binder" (patternBinderSpan previousBinder)]
            ]
        Nothing ->
          go (Map.insert (patternBinderName binder) binder seen) rest

ensureUniqueRecordExprFields :: [RecordFieldExpr] -> InferM ()
ensureUniqueRecordExprFields = go Map.empty
  where
    go _ [] = pure ()
    go seen (fieldExpr : rest) =
      case Map.lookup (recordFieldExprName fieldExpr) seen of
        Just previousFieldExpr ->
          throwDiagnostic . diagnosticBundle $
            [ diagnostic
                "E_DUPLICATE_RECORD_FIELD_EXPR"
                ("Duplicate field `" <> recordFieldExprName fieldExpr <> "` in record literal.")
                (Just (recordFieldExprSpan fieldExpr))
                ["Each record field may only be set once."]
                [diagnosticRelated "previous field" (recordFieldExprSpan previousFieldExpr)]
            ]
        Nothing ->
          go (Map.insert (recordFieldExprName fieldExpr) fieldExpr seen) rest

lookupRecordField :: Text -> RecordDecl -> Maybe RecordFieldDecl
lookupRecordField fieldName recordDecl =
  go (recordDeclFields recordDecl)
  where
    go [] = Nothing
    go (fieldDecl : rest)
      | recordFieldDeclName fieldDecl == fieldName = Just fieldDecl
      | otherwise = go rest

resolveFieldAccessRecord :: ModuleContext -> SourceSpan -> Text -> InferType -> InferM RecordDecl
resolveFieldAccessRecord ctx accessSpan fieldName subjectType = do
  resolvedSubjectType <- resolveCurrentType subjectType
  case resolvedSubjectType of
    INamed typeName ->
      case Map.lookup typeName (contextRecordDeclEnv ctx) of
        Just recordDecl ->
          pure recordDecl
        Nothing ->
          throwDiagnostic . diagnosticBundle $
            [ diagnostic
                "E_FIELD_ACCESS"
                "Field access requires a record value."
                (Just accessSpan)
                ["Expected a record type but got `" <> typeName <> "`."]
                []
            ]
    IVar _ ->
      case recordsWithField ctx fieldName of
        [] ->
          throwDiagnostic . diagnosticBundle $
            [ diagnostic
                "E_UNKNOWN_FIELD"
                ("Unknown field `" <> fieldName <> "`.")
                (Just accessSpan)
                ["Declare the field on a record or fix the field name."]
                []
            ]
        [recordDecl] -> do
          unify
            ( UnifyContext
                { unifyCode = "E_FIELD_ACCESS"
                , unifySummary = "Field access requires a record value."
                , unifyPrimarySpan = accessSpan
                , unifyRelated = [diagnosticRelated "record declaration" (recordDeclNameSpan recordDecl)]
                }
            )
            resolvedSubjectType
            (INamed (recordDeclName recordDecl))
          pure recordDecl
        candidates ->
          throwDiagnostic . diagnosticBundle $
            [ diagnostic
                "E_CANNOT_INFER"
                ("Could not infer which record defines field `" <> fieldName <> "`.")
                (Just accessSpan)
                ["Candidate records: " <> T.intercalate ", " (fmap recordDeclName candidates) <> "."]
                []
            ]
    _ ->
      throwDiagnostic . diagnosticBundle $
        [ diagnostic
            "E_FIELD_ACCESS"
            "Field access requires a record value."
            (Just accessSpan)
            ["Expected a record type but got " <> renderInferType resolvedSubjectType <> "."]
            []
        ]

recordsWithField :: ModuleContext -> Text -> [RecordDecl]
recordsWithField ctx fieldName =
  filter (hasField fieldName) (Map.elems (contextRecordDeclEnv ctx))
  where
    hasField target recordDecl =
      any ((== target) . recordFieldDeclName) (recordDeclFields recordDecl)

ensureJsonTypeSupported :: ModuleContext -> SourceSpan -> Type -> InferM ()
ensureJsonTypeSupported ctx primarySpan typ =
  case jsonTypeSupportError ctx primarySpan typ of
    Just err ->
      throwDiagnostic err
    Nothing ->
      pure ()

ensureJsonTypeSupportedType :: ModuleContext -> SourceSpan -> Type -> Either DiagnosticBundle ()
ensureJsonTypeSupportedType ctx primarySpan typ =
  case jsonTypeSupportError ctx primarySpan typ of
    Just err ->
      Left err
    Nothing ->
      Right ()

inferTypeToJsonType :: ModuleContext -> InferType -> Either (Maybe DiagnosticBundle) Type
inferTypeToJsonType ctx inferType =
  case inferType of
    IInt ->
      Right TInt
    IStr ->
      Right TStr
    IBool ->
      Right TBool
    IList itemType ->
      TList <$> inferTypeToJsonType ctx itemType
    INamed name
      | Map.member name (contextRecordDeclEnv ctx) ->
          Right (TNamed name)
      | maybe False isJsonEnumTypeDecl (Map.lookup name (contextTypeDeclEnv ctx)) ->
          Right (TNamed name)
      | otherwise ->
          Left (Just (jsonTypeUnsupportedBundle (Just "<inferred value>") (TNamed name)))
    IFunction args result ->
      Left (Just (jsonTypeUnsupportedBundle (Just "<inferred value>") (TFunction (fmap inferTypeToTypeUnsafe args) (inferTypeToTypeUnsafe result))))
    IVar _ ->
      Left Nothing
  where
    inferTypeToTypeUnsafe current =
      case current of
        IInt -> TInt
        IStr -> TStr
        IBool -> TBool
        IList itemType -> TList (inferTypeToTypeUnsafe itemType)
        INamed name -> TNamed name
        IFunction args result -> TFunction (fmap inferTypeToTypeUnsafe args) (inferTypeToTypeUnsafe result)
        IVar _ -> TNamed "<unknown>"

jsonTypeSupportError :: ModuleContext -> SourceSpan -> Type -> Maybe DiagnosticBundle
jsonTypeSupportError ctx primarySpan typ =
  case typ of
    TInt ->
      Nothing
    TStr ->
      Nothing
    TBool ->
      Nothing
    TList itemType ->
      jsonTypeSupportError ctx primarySpan itemType
    TNamed name
      | Map.member name (contextRecordDeclEnv ctx) ->
          Nothing
      | maybe False isJsonEnumTypeDecl (Map.lookup name (contextTypeDeclEnv ctx)) ->
          Nothing
      | otherwise ->
          Just . diagnosticBundle $
              [ diagnostic
                  "E_JSON_TYPE"
                  ("JSON codecs currently support record and primitive types, but got `" <> name <> "`.")
                  (Just primarySpan)
                  ["Use a record type, a primitive type, a list type, or a nullary enum type at the JSON boundary."]
                  []
              ]
    TFunction _ _ ->
      Just . diagnosticBundle $
        [ diagnostic
            "E_JSON_TYPE"
            "JSON codecs do not support function values."
            (Just primarySpan)
            ["Use a record type, a primitive type, a list type, or a nullary enum type at the JSON boundary."]
            []
        ]

jsonTypeUnsupportedBundle :: Maybe Text -> Type -> DiagnosticBundle
jsonTypeUnsupportedBundle maybeContext typ =
  diagnosticBundle
    [ diagnostic
        "E_JSON_TYPE"
        summary
        Nothing
        ["Use a record type, a primitive type, a list type, or a nullary enum type at the JSON boundary."]
        []
    ]
  where
    prefix =
      case maybeContext of
        Just label ->
          label <> " "
        Nothing ->
          ""
    summary =
      case typ of
        TFunction _ _ ->
          prefix <> "JSON codecs do not support function values."
        _ ->
          prefix <> "JSON codecs currently support record, primitive, list, and nullary enum types, but got `" <> renderType typ <> "`."

isJsonEnumTypeDecl :: TypeDecl -> Bool
isJsonEnumTypeDecl typeDecl =
  all (null . constructorDeclFields) (typeDeclConstructors typeDecl)

ensureExhaustiveMatch :: TypeDecl -> Map.Map Text MatchBranch -> SourceSpan -> InferM ()
ensureExhaustiveMatch typeDecl seenBranches matchSpan =
  let expectedConstructors = fmap constructorDeclName (typeDeclConstructors typeDecl)
      missingConstructors =
        filter (`Map.notMember` seenBranches) expectedConstructors
   in unless (null missingConstructors) $
        throwDiagnostic . diagnosticBundle $
          [ diagnostic
              "E_NONEXHAUSTIVE_MATCH"
              "Match expression is missing constructors."
              (Just matchSpan)
              ["Add branches for: " <> T.intercalate ", " missingConstructors <> "."]
              [diagnosticRelated "type declaration" (typeDeclNameSpan typeDecl)]
          ]

freezeDraftDecl :: ModuleContext -> Decl -> InferState -> DraftDecl -> Either DiagnosticBundle CoreDecl
freezeDraftDecl ctx decl inferState draftDecl = do
  declType <- freezeInferTypeForDecl decl inferState (draftDeclType draftDecl)
  params <- traverse (freezeDraftParam decl inferState) (draftDeclParams draftDecl)
  body <- freezeDraftExpr ctx decl inferState (draftDeclBody draftDecl)
  pure
    CoreDecl
      { coreDeclName = draftDeclName draftDecl
      , coreDeclType = declType
      , coreDeclParams = params
      , coreDeclBody = body
      }

freezeDraftParam :: Decl -> InferState -> DraftParam -> Either DiagnosticBundle CoreParam
freezeDraftParam decl inferState draftParam = do
  paramType <- freezeInferTypeForDecl decl inferState (draftParamType draftParam)
  pure
    CoreParam
      { coreParamName = draftParamName draftParam
      , coreParamType = paramType
      }

freezeDraftExpr :: ModuleContext -> Decl -> InferState -> DraftExpr -> Either DiagnosticBundle CoreExpr
freezeDraftExpr ctx decl inferState draftExpr =
  case draftExprNode draftExpr of
    DraftVar name -> do
      exprType <- freezeInferTypeForDecl decl inferState (draftExprType draftExpr)
      pure (CVar (draftExprSpan draftExpr) exprType name)
    DraftInt value ->
      pure (CInt (draftExprSpan draftExpr) value)
    DraftString value ->
      pure (CString (draftExprSpan draftExpr) value)
    DraftBool value ->
      pure (CBool (draftExprSpan draftExpr) value)
    DraftList items -> do
      exprType <- freezeInferTypeForDecl decl inferState (draftExprType draftExpr)
      frozenItems <- traverse (freezeDraftExpr ctx decl inferState) items
      pure (CList (draftExprSpan draftExpr) exprType frozenItems)
    DraftReturn value -> do
      exprType <- freezeInferTypeForDecl decl inferState (draftExprType draftExpr)
      frozenValue <- freezeDraftExpr ctx decl inferState value
      pure (CReturn (draftExprSpan draftExpr) exprType frozenValue)
    DraftEqual left right -> do
      frozenLeft <- freezeDraftExpr ctx decl inferState left
      frozenRight <- freezeDraftExpr ctx decl inferState right
      pure (CEqual (draftExprSpan draftExpr) frozenLeft frozenRight)
    DraftNotEqual left right -> do
      frozenLeft <- freezeDraftExpr ctx decl inferState left
      frozenRight <- freezeDraftExpr ctx decl inferState right
      pure (CNotEqual (draftExprSpan draftExpr) frozenLeft frozenRight)
    DraftLessThan left right -> do
      frozenLeft <- freezeDraftExpr ctx decl inferState left
      frozenRight <- freezeDraftExpr ctx decl inferState right
      pure (CLessThan (draftExprSpan draftExpr) frozenLeft frozenRight)
    DraftLessThanOrEqual left right -> do
      frozenLeft <- freezeDraftExpr ctx decl inferState left
      frozenRight <- freezeDraftExpr ctx decl inferState right
      pure (CLessThanOrEqual (draftExprSpan draftExpr) frozenLeft frozenRight)
    DraftGreaterThan left right -> do
      frozenLeft <- freezeDraftExpr ctx decl inferState left
      frozenRight <- freezeDraftExpr ctx decl inferState right
      pure (CGreaterThan (draftExprSpan draftExpr) frozenLeft frozenRight)
    DraftGreaterThanOrEqual left right -> do
      frozenLeft <- freezeDraftExpr ctx decl inferState left
      frozenRight <- freezeDraftExpr ctx decl inferState right
      pure (CGreaterThanOrEqual (draftExprSpan draftExpr) frozenLeft frozenRight)
    DraftLet name value body -> do
      exprType <- freezeInferTypeForDecl decl inferState (draftExprType draftExpr)
      frozenValue <- freezeDraftExpr ctx decl inferState value
      frozenBody <- freezeDraftExpr ctx decl inferState body
      pure (CLet (draftExprSpan draftExpr) exprType name frozenValue frozenBody)
    DraftMutableLet name value body -> do
      exprType <- freezeInferTypeForDecl decl inferState (draftExprType draftExpr)
      frozenValue <- freezeDraftExpr ctx decl inferState value
      frozenBody <- freezeDraftExpr ctx decl inferState body
      pure (CMutableLet (draftExprSpan draftExpr) exprType name frozenValue frozenBody)
    DraftAssign name value body -> do
      exprType <- freezeInferTypeForDecl decl inferState (draftExprType draftExpr)
      frozenValue <- freezeDraftExpr ctx decl inferState value
      frozenBody <- freezeDraftExpr ctx decl inferState body
      pure (CAssign (draftExprSpan draftExpr) exprType name frozenValue frozenBody)
    DraftFor name iterable loopBody body -> do
      exprType <- freezeInferTypeForDecl decl inferState (draftExprType draftExpr)
      frozenIterable <- freezeDraftExpr ctx decl inferState iterable
      frozenLoopBody <- freezeDraftExpr ctx decl inferState loopBody
      frozenBody <- freezeDraftExpr ctx decl inferState body
      pure (CFor (draftExprSpan draftExpr) exprType name frozenIterable frozenLoopBody frozenBody)
    DraftPage title body -> do
      frozenTitle <- freezeDraftExpr ctx decl inferState title
      frozenBody <- freezeDraftExpr ctx decl inferState body
      pure (CPage (draftExprSpan draftExpr) frozenTitle frozenBody)
    DraftRedirect targetPath ->
      pure (CRedirect (draftExprSpan draftExpr) targetPath)
    DraftViewEmpty ->
      pure (CViewEmpty (draftExprSpan draftExpr))
    DraftViewText value -> do
      frozenValue <- freezeDraftExpr ctx decl inferState value
      pure (CViewText (draftExprSpan draftExpr) frozenValue)
    DraftViewAppend left right -> do
      frozenLeft <- freezeDraftExpr ctx decl inferState left
      frozenRight <- freezeDraftExpr ctx decl inferState right
      pure (CViewAppend (draftExprSpan draftExpr) frozenLeft frozenRight)
    DraftViewElement tagName child -> do
      frozenChild <- freezeDraftExpr ctx decl inferState child
      pure (CViewElement (draftExprSpan draftExpr) tagName frozenChild)
    DraftViewStyled styleRef child -> do
      frozenChild <- freezeDraftExpr ctx decl inferState child
      pure (CViewStyled (draftExprSpan draftExpr) styleRef frozenChild)
    DraftViewLink routeDecl href child -> do
      frozenChild <- freezeDraftExpr ctx decl inferState child
      pure (CViewLink (draftExprSpan draftExpr) (freezeRouteContract routeDecl) href frozenChild)
    DraftViewForm routeDecl method action child -> do
      frozenChild <- freezeDraftExpr ctx decl inferState child
      pure (CViewForm (draftExprSpan draftExpr) (freezeRouteContract routeDecl) method action frozenChild)
    DraftViewInput fieldName inputKind value -> do
      frozenValue <- freezeDraftExpr ctx decl inferState value
      pure (CViewInput (draftExprSpan draftExpr) fieldName inputKind frozenValue)
    DraftViewSubmit label -> do
      frozenLabel <- freezeDraftExpr ctx decl inferState label
      pure (CViewSubmit (draftExprSpan draftExpr) frozenLabel)
    DraftPromptMessage role content -> do
      frozenContent <- freezeDraftExpr ctx decl inferState content
      pure (CPromptMessage (draftExprSpan draftExpr) role frozenContent)
    DraftPromptAppend left right -> do
      frozenLeft <- freezeDraftExpr ctx decl inferState left
      frozenRight <- freezeDraftExpr ctx decl inferState right
      pure (CPromptAppend (draftExprSpan draftExpr) frozenLeft frozenRight)
    DraftPromptText promptExpr -> do
      frozenPrompt <- freezeDraftExpr ctx decl inferState promptExpr
      pure (CPromptText (draftExprSpan draftExpr) frozenPrompt)
    DraftCall fn args -> do
      exprType <- freezeInferTypeForDecl decl inferState (draftExprType draftExpr)
      frozenFn <- freezeDraftExpr ctx decl inferState fn
      frozenArgs <- traverse (freezeDraftExpr ctx decl inferState) args
      pure (CCall (draftExprSpan draftExpr) exprType frozenFn frozenArgs)
    DraftMatch subject branches -> do
      exprType <- freezeInferTypeForDecl decl inferState (draftExprType draftExpr)
      frozenSubject <- freezeDraftExpr ctx decl inferState subject
      frozenBranches <- traverse (freezeDraftMatchBranch ctx decl inferState) branches
      pure (CMatch (draftExprSpan draftExpr) exprType frozenSubject frozenBranches)
    DraftRecord recordName fields -> do
      exprType <- freezeInferTypeForDecl decl inferState (draftExprType draftExpr)
      frozenFields <- traverse (freezeDraftRecordField ctx decl inferState) fields
      pure (CRecord (draftExprSpan draftExpr) exprType recordName frozenFields)
    DraftFieldAccess subject fieldName -> do
      exprType <- freezeInferTypeForDecl decl inferState (draftExprType draftExpr)
      frozenSubject <- freezeDraftExpr ctx decl inferState subject
      pure (CFieldAccess (draftExprSpan draftExpr) exprType frozenSubject fieldName)
    DraftDecodeJson targetType rawJson -> do
      frozenRawJson <- freezeDraftExpr ctx decl inferState rawJson
      pure (CDecodeJson (draftExprSpan draftExpr) targetType frozenRawJson)
    DraftEncodeJson value -> do
      frozenValue <- freezeDraftExpr ctx decl inferState value
      case ensureJsonTypeSupportedType ctx (draftExprSpan draftExpr) (coreExprType frozenValue) of
        Left err ->
          Left err
        Right () ->
          pure (CEncodeJson (draftExprSpan draftExpr) frozenValue)

freezeDraftMatchBranch :: ModuleContext -> Decl -> InferState -> DraftMatchBranch -> Either DiagnosticBundle CoreMatchBranch
freezeDraftMatchBranch ctx decl inferState branch = do
  frozenPattern <- freezeDraftPattern decl inferState (draftMatchBranchPattern branch)
  frozenBody <- freezeDraftExpr ctx decl inferState (draftMatchBranchBody branch)
  pure
    CoreMatchBranch
      { coreMatchBranchSpan = draftMatchBranchSpan branch
      , coreMatchBranchPattern = frozenPattern
      , coreMatchBranchBody = frozenBody
      }

freezeDraftPattern :: Decl -> InferState -> DraftPattern -> Either DiagnosticBundle CorePattern
freezeDraftPattern decl inferState pattern' =
  case pattern' of
    DraftConstructorPattern span' constructorName binders -> do
      frozenBinders <- traverse (freezeDraftPatternBinder decl inferState) binders
      pure (CConstructorPattern span' constructorName frozenBinders)

freezeDraftPatternBinder :: Decl -> InferState -> DraftPatternBinder -> Either DiagnosticBundle CorePatternBinder
freezeDraftPatternBinder decl inferState binder = do
  binderType <- freezeInferTypeForDecl decl inferState (draftPatternBinderType binder)
  pure
    CorePatternBinder
      { corePatternBinderName = draftPatternBinderName binder
      , corePatternBinderSpan = draftPatternBinderSpan binder
      , corePatternBinderType = binderType
      }

freezeDraftRecordField :: ModuleContext -> Decl -> InferState -> DraftRecordField -> Either DiagnosticBundle CoreRecordField
freezeDraftRecordField ctx decl inferState field = do
  frozenValue <- freezeDraftExpr ctx decl inferState (draftRecordFieldValue field)
  pure
    CoreRecordField
      { coreRecordFieldName = draftRecordFieldName field
      , coreRecordFieldValue = frozenValue
      }

freezeInferTypeForDecl :: Decl -> InferState -> InferType -> Either DiagnosticBundle Type
freezeInferTypeForDecl decl inferState inferType =
  case inferTypeToType inferState inferType of
    Left unresolvedVars ->
      Left $
        singleDiagnosticAt
          "E_CANNOT_INFER"
          ("Could not infer the type of `" <> declName decl <> "`.")
          (declNameSpan decl)
          ["Remaining unconstrained type variables: " <> T.intercalate ", " (fmap renderTypeVar unresolvedVars) <> "."]
    Right typ ->
      Right typ

inferTypeToType :: InferState -> InferType -> Either [Int] Type
inferTypeToType inferState inferType =
  case resolveInferType (inferSubstitution inferState) inferType of
    IInt ->
      Right TInt
    IStr ->
      Right TStr
    IBool ->
      Right TBool
    IList itemType ->
      TList <$> inferTypeToType inferState itemType
    INamed name ->
      Right (TNamed name)
    IFunction args result ->
      TFunction <$> traverse (inferTypeToType inferState) args <*> inferTypeToType inferState result
    IVar varId ->
      Left [varId]

typeToInferType :: Type -> InferType
typeToInferType typ =
  case typ of
    TInt ->
      IInt
    TStr ->
      IStr
    TBool ->
      IBool
    TList itemType ->
      IList (typeToInferType itemType)
    TNamed name ->
      INamed name
    TFunction args result ->
      IFunction (fmap typeToInferType args) (typeToInferType result)

freshTypeVar :: InferM InferType
freshTypeVar = do
  nextVar <- gets inferNextTypeVar
  modify' (\state -> state {inferNextTypeVar = nextVar + 1})
  pure (IVar nextVar)

withReturnType :: InferType -> InferM a -> InferM a
withReturnType returnType action = do
  previousReturnType <- gets inferReturnType
  modify' (\state -> state {inferReturnType = Just returnType})
  result <- action
  modify' (\state -> state {inferReturnType = previousReturnType})
  pure result

resolveCurrentType :: InferType -> InferM InferType
resolveCurrentType inferType =
  gets (\state -> resolveInferType (inferSubstitution state) inferType)

resolveInferType :: Map.Map Int InferType -> InferType -> InferType
resolveInferType substitution inferType =
  case inferType of
    IInt ->
      IInt
    IStr ->
      IStr
    IBool ->
      IBool
    IList itemType ->
      IList (resolveInferType substitution itemType)
    INamed name ->
      INamed name
    IFunction args result ->
      IFunction (fmap (resolveInferType substitution) args) (resolveInferType substitution result)
    IVar varId ->
      case Map.lookup varId substitution of
        Just substitutedType ->
          resolveInferType substitution substitutedType
        Nothing ->
          IVar varId

unify :: UnifyContext -> InferType -> InferType -> InferM ()
unify context leftType rightType = do
  resolvedLeft <- resolveCurrentType leftType
  resolvedRight <- resolveCurrentType rightType
  case (resolvedLeft, resolvedRight) of
    (IVar leftVar, IVar rightVar)
      | leftVar == rightVar ->
          pure ()
    (IVar leftVar, _) ->
      bindTypeVar context leftVar resolvedRight
    (_, IVar rightVar) ->
      bindTypeVar context rightVar resolvedLeft
    (IInt, IInt) ->
      pure ()
    (IStr, IStr) ->
      pure ()
    (IBool, IBool) ->
      pure ()
    (IList leftItem, IList rightItem) ->
      unify context leftItem rightItem
    (INamed leftName, INamed rightName)
      | leftName == rightName ->
          pure ()
    (IFunction leftArgs leftResult, IFunction rightArgs rightResult)
      | length leftArgs == length rightArgs -> do
          zipWithM_ (unify context) leftArgs rightArgs
          unify context leftResult rightResult
    _ ->
      throwTypeMismatch context resolvedLeft resolvedRight

bindTypeVar :: UnifyContext -> Int -> InferType -> InferM ()
bindTypeVar context varId inferType = do
  resolvedType <- resolveCurrentType inferType
  if resolvedType == IVar varId
    then pure ()
    else
      if occursInType varId resolvedType
        then
          throwDiagnostic . diagnosticBundle $
            [ diagnostic
                "E_INFINITE_TYPE"
                "Type inference produced an infinite type."
                (Just (unifyPrimarySpan context))
                ["This expression would require " <> renderTypeVar varId <> " to contain itself."]
                (unifyRelated context)
            ]
        else modify' (\state -> state {inferSubstitution = Map.insert varId resolvedType (inferSubstitution state)})

occursInType :: Int -> InferType -> Bool
occursInType varId inferType =
  case inferType of
    IInt ->
      False
    IStr ->
      False
    IBool ->
      False
    IList itemType ->
      occursInType varId itemType
    INamed _ ->
      False
    IFunction args result ->
      any (occursInType varId) args || occursInType varId result
    IVar otherVarId ->
      varId == otherVarId

throwTypeMismatch :: UnifyContext -> InferType -> InferType -> InferM ()
throwTypeMismatch context expectedType actualType =
  throwDiagnostic . diagnosticBundle $
    [ diagnostic
        (unifyCode context)
        (unifySummary context)
        (Just (unifyPrimarySpan context))
        ["Expected " <> renderInferType expectedType <> " but got " <> renderInferType actualType <> "."]
        (unifyRelated context)
    ]

renderInferType :: InferType -> Text
renderInferType inferType =
  case inferType of
    IInt ->
      "Int"
    IStr ->
      "Str"
    IBool ->
      "Bool"
    IList itemType ->
      "[" <> renderInferType itemType <> "]"
    INamed name ->
      name
    IFunction args result ->
      T.intercalate " -> " (fmap renderAtomicInferType (args <> [result]))
    IVar varId ->
      renderTypeVar varId

renderAtomicInferType :: InferType -> Text
renderAtomicInferType inferType =
  case inferType of
    IFunction _ _ ->
      "(" <> renderInferType inferType <> ")"
    _ ->
      renderInferType inferType

renderTypeVar :: Int -> Text
renderTypeVar varId =
  "t" <> T.pack (show varId)

runInferAction :: InferM a -> Either InferFailure (a, InferState)
runInferAction action =
  case runState (runExceptT (unInferM action)) (InferState 0 Map.empty Nothing) of
    (Left err, _) ->
      Left err
    (Right result, inferState) ->
      Right (result, inferState)

throwDiagnostic :: DiagnosticBundle -> InferM a
throwDiagnostic = throwError . InferDiagnostic

annotationRelated :: Decl -> [DiagnosticRelated]
annotationRelated decl =
  case declAnnotationSpan decl of
    Just annotationSpan ->
      [diagnosticRelated "type annotation" annotationSpan]
    Nothing ->
      [diagnosticRelated "declaration" (declNameSpan decl)]

relatedForFunction :: Expr -> DeclMap -> ForeignDeclEnv -> ConstructorEnv -> [DiagnosticRelated]
relatedForFunction fnExpr declMap foreignDeclEnv constructorEnv =
  case fnExpr of
    EVar _ name ->
      case Map.lookup name declMap of
        Just decl ->
          annotationRelated decl
        Nothing ->
          case Map.lookup name foreignDeclEnv of
            Just foreignDecl ->
              [diagnosticRelated "foreign declaration" (foreignDeclNameSpan foreignDecl)]
            Nothing ->
              case Map.lookup name constructorEnv of
                Just constructorInfo ->
                  [diagnosticRelated "constructor declaration" (constructorDeclNameSpan (constructorInfoDecl constructorInfo))]
                Nothing ->
                  []
    _ ->
      []

relatedForHandler :: Text -> DeclMap -> ForeignDeclEnv -> [DiagnosticRelated]
relatedForHandler handlerName declMap foreignDeclEnv =
  case Map.lookup handlerName declMap of
    Just decl ->
      annotationRelated decl
    Nothing ->
      case Map.lookup handlerName foreignDeclEnv of
        Just foreignDecl ->
          [diagnosticRelated "foreign declaration" (foreignDeclNameSpan foreignDecl)]
        Nothing ->
          []

constructorInfoType :: ConstructorInfo -> Type
constructorInfoType constructorInfo =
  let fieldTypes = constructorDeclFields (constructorInfoDecl constructorInfo)
      resultType = TNamed (constructorInfoTypeName constructorInfo)
   in case fieldTypes of
        [] ->
          resultType
        _ ->
          TFunction fieldTypes resultType
