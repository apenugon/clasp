{-# LANGUAGE OverloadedStrings #-}

module Clasp.Lower
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
  , LowerRoute (..)
  , lowerPageFlows
  , lowerModule
  ) where

import qualified Data.Map.Strict as Map
import Data.List (find)
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Clasp.Core
  ( CoreDecl (..)
  , CoreAgentDecl (..)
  , CoreAgentRoleDecl (..)
  , CoreExpr (..)
  , CoreHookDecl (..)
  , CoreMergeGateDecl (..)
  , CoreMatchBranch (..)
  , CoreModule (..)
  , CoreParam (..)
  , CorePolicyDecl (..)
  , CorePattern (..)
  , CorePatternBinder (..)
  , CoreRecordField (..)
  , CoreRouteContract (..)
  , CoreSupervisorDecl (..)
  , CoreToolDecl (..)
  , CoreToolServerDecl (..)
  , CoreVerifierDecl (..)
  , CoreWorkflowDecl (..)
  , coreExprType
  )
import Clasp.Syntax
  ( AgentDecl
  , AgentRoleDecl
  , ConstructorDecl (..)
  , ForeignDecl
  , GuideDecl
  , HookDecl
  , MergeGateDecl
  , ModuleName
  , PolicyDecl
  , RecordDecl
  , RouteBoundaryDecl
  , RouteDecl (..)
  , RouteMethod
  , RoutePathDecl
  , ToolDecl
  , ToolServerDecl
  , Type (..)
  , TypeDecl (..)
  , VerifierDecl
  , SupervisorDecl
  , WorkflowDecl
  )

data LowerModule = LowerModule
  { lowerModuleName :: ModuleName
  , lowerModuleTypeDecls :: [TypeDecl]
  , lowerModuleRecordDecls :: [RecordDecl]
  , lowerModuleWorkflowDecls :: [WorkflowDecl]
  , lowerModuleSupervisorDecls :: [SupervisorDecl]
  , lowerModuleGuideDecls :: [GuideDecl]
  , lowerModuleHookDecls :: [HookDecl]
  , lowerModuleAgentRoleDecls :: [AgentRoleDecl]
  , lowerModuleAgentDecls :: [AgentDecl]
  , lowerModulePolicyDecls :: [PolicyDecl]
  , lowerModuleToolServerDecls :: [ToolServerDecl]
  , lowerModuleToolDecls :: [ToolDecl]
  , lowerModuleVerifierDecls :: [VerifierDecl]
  , lowerModuleMergeGateDecls :: [MergeGateDecl]
  , lowerModuleForeignDecls :: [ForeignDecl]
  , lowerModuleRoutes :: [LowerRoute]
  , lowerModuleCodecTypes :: [Type]
  , lowerModuleDecls :: [LowerDecl]
  }
  deriving (Eq, Show)

data LowerDecl
  = LValueDecl Text LowerExpr
  | LFunctionDecl Text [Text] LowerExpr
  deriving (Eq, Show)

data LowerRecordField = LowerRecordField
  { lowerRecordFieldName :: Text
  , lowerRecordFieldValue :: LowerExpr
  }
  deriving (Eq, Show)

data LowerExpr
  = LVar Text
  | LInt Integer
  | LString Text
  | LBool Bool
  | LList [LowerExpr]
  | LReturn LowerExpr
  | LEqual LowerExpr LowerExpr
  | LNotEqual LowerExpr LowerExpr
  | LLessThan LowerExpr LowerExpr
  | LLessThanOrEqual LowerExpr LowerExpr
  | LGreaterThan LowerExpr LowerExpr
  | LGreaterThanOrEqual LowerExpr LowerExpr
  | LLet Text LowerExpr LowerExpr
  | LMutableLet Text LowerExpr LowerExpr
  | LAssign Text LowerExpr LowerExpr
  | LFor Text LowerExpr LowerExpr LowerExpr
  | LPage LowerExpr LowerExpr
  | LRedirect Text
  | LViewEmpty
  | LViewText LowerExpr
  | LViewAppend LowerExpr LowerExpr
  | LViewElement Text LowerExpr
  | LViewStyled Text LowerExpr
  | LViewLink LowerRouteContract Text LowerExpr
  | LViewForm LowerRouteContract Text Text LowerExpr
  | LViewInput Text Text LowerExpr
  | LViewSubmit LowerExpr
  | LCall LowerExpr [LowerExpr]
  | LConstruct Text [LowerExpr]
  | LMatch LowerExpr [LowerMatchBranch]
  | LRecord [LowerRecordField]
  | LFieldAccess LowerExpr Text
  deriving (Eq, Show)

data LowerMatchBranch = LowerMatchBranch
  { lowerMatchBranchTag :: Text
  , lowerMatchBranchBinders :: [Text]
  , lowerMatchBranchBody :: LowerExpr
  }
  deriving (Eq, Show)

data LowerRouteContract = LowerRouteContract
  { lowerRouteContractName :: Text
  , lowerRouteContractIdentity :: Text
  , lowerRouteContractMethod :: Text
  , lowerRouteContractPath :: Text
  , lowerRouteContractPathDecl :: RoutePathDecl
  , lowerRouteContractRequestType :: Text
  , lowerRouteContractQueryDecl :: Maybe RouteBoundaryDecl
  , lowerRouteContractFormDecl :: Maybe RouteBoundaryDecl
  , lowerRouteContractBodyDecl :: Maybe RouteBoundaryDecl
  , lowerRouteContractResponseType :: Text
  , lowerRouteContractResponseDecl :: RouteBoundaryDecl
  , lowerRouteContractResponseKind :: Text
  }
  deriving (Eq, Show)

data LowerRoute = LowerRoute
  { lowerRouteName :: Text
  , lowerRouteIdentity :: Text
  , lowerRouteMethod :: RouteMethod
  , lowerRoutePath :: Text
  , lowerRoutePathDecl :: RoutePathDecl
  , lowerRouteRequestTypeName :: Text
  , lowerRouteQueryDecl :: Maybe RouteBoundaryDecl
  , lowerRouteFormDecl :: Maybe RouteBoundaryDecl
  , lowerRouteBodyDecl :: Maybe RouteBoundaryDecl
  , lowerRouteResponseTypeName :: Text
  , lowerRouteResponseDecl :: RouteBoundaryDecl
  , lowerRouteHandlerName :: Text
  }
  deriving (Eq, Show)

data LowerPageFlow = LowerPageFlow
  { lowerPageFlowRouteName :: Text
  , lowerPageFlowRouteIdentity :: Text
  , lowerPageFlowPath :: Text
  , lowerPageFlowHandlerName :: Text
  , lowerPageFlowTitle :: Text
  , lowerPageFlowTexts :: [Text]
  , lowerPageFlowLinks :: [LowerPageLink]
  , lowerPageFlowForms :: [LowerPageForm]
  }
  deriving (Eq, Show)

data LowerPageLink = LowerPageLink
  { lowerPageLinkRouteName :: Text
  , lowerPageLinkRouteIdentity :: Text
  , lowerPageLinkPath :: Text
  , lowerPageLinkHref :: Text
  , lowerPageLinkLabel :: Text
  }
  deriving (Eq, Show)

data LowerPageForm = LowerPageForm
  { lowerPageFormRouteName :: Text
  , lowerPageFormRouteIdentity :: Text
  , lowerPageFormPath :: Text
  , lowerPageFormMethod :: Text
  , lowerPageFormAction :: Text
  , lowerPageFormRequestType :: Text
  , lowerPageFormResponseType :: Text
  , lowerPageFormResponseKind :: Text
  , lowerPageFormFields :: [LowerFormField]
  , lowerPageFormSubmitLabels :: [Text]
  }
  deriving (Eq, Show)

data LowerFormField = LowerFormField
  { lowerFormFieldName :: Text
  , lowerFormFieldInputKind :: Text
  , lowerFormFieldLabel :: Maybe Text
  , lowerFormFieldValue :: Text
  }
  deriving (Eq, Show)

lowerModule :: CoreModule -> LowerModule
lowerModule modl =
  LowerModule
    { lowerModuleName = coreModuleName modl
    , lowerModuleTypeDecls = coreModuleTypeDecls modl
    , lowerModuleRecordDecls = coreModuleRecordDecls modl
    , lowerModuleWorkflowDecls = fmap coreWorkflowSourceDecl (coreModuleWorkflowDecls modl)
    , lowerModuleSupervisorDecls = fmap coreSupervisorSourceDecl (coreModuleSupervisorDecls modl)
    , lowerModuleGuideDecls = coreModuleGuideDecls modl
    , lowerModuleHookDecls = fmap coreHookSourceDecl (coreModuleHookDecls modl)
    , lowerModuleAgentRoleDecls = fmap coreAgentRoleSourceDecl (coreModuleAgentRoleDecls modl)
    , lowerModuleAgentDecls = fmap coreAgentSourceDecl (coreModuleAgentDecls modl)
    , lowerModulePolicyDecls = fmap corePolicySourceDecl (coreModulePolicyDecls modl)
    , lowerModuleToolServerDecls = fmap coreToolServerSourceDecl (coreModuleToolServerDecls modl)
    , lowerModuleToolDecls = fmap coreToolSourceDecl (coreModuleToolDecls modl)
    , lowerModuleVerifierDecls = fmap coreVerifierSourceDecl (coreModuleVerifierDecls modl)
    , lowerModuleMergeGateDecls = fmap coreMergeGateSourceDecl (coreModuleMergeGateDecls modl)
    , lowerModuleForeignDecls = coreModuleForeignDecls modl
    , lowerModuleRoutes = fmap lowerRouteDecl (coreModuleRouteDecls modl)
    , lowerModuleCodecTypes = collectModuleCodecTypes modl
    , lowerModuleDecls =
        concatMap lowerTypeDeclConstructors (coreModuleTypeDecls modl)
          <> fmap lowerCoreDecl (coreModuleDecls modl)
    }

collectModuleCodecTypes :: CoreModule -> [Type]
collectModuleCodecTypes modl =
  Set.toList $
    Set.fromList $
      concatMap (collectExprCodecTypes . coreDeclBody) (coreModuleDecls modl)

collectExprCodecTypes :: CoreExpr -> [Type]
collectExprCodecTypes expr =
  case expr of
    CVar _ _ _ ->
      []
    CInt _ _ ->
      []
    CString _ _ ->
      []
    CBool _ _ ->
      []
    CList _ _ items ->
      concatMap collectExprCodecTypes items
    CReturn _ _ value ->
      collectExprCodecTypes value
    CEqual _ left right ->
      collectExprCodecTypes left <> collectExprCodecTypes right
    CNotEqual _ left right ->
      collectExprCodecTypes left <> collectExprCodecTypes right
    CLessThan _ left right ->
      collectExprCodecTypes left <> collectExprCodecTypes right
    CLessThanOrEqual _ left right ->
      collectExprCodecTypes left <> collectExprCodecTypes right
    CGreaterThan _ left right ->
      collectExprCodecTypes left <> collectExprCodecTypes right
    CGreaterThanOrEqual _ left right ->
      collectExprCodecTypes left <> collectExprCodecTypes right
    CLet _ _ _ value body ->
      collectExprCodecTypes value <> collectExprCodecTypes body
    CMutableLet _ _ _ value body ->
      collectExprCodecTypes value <> collectExprCodecTypes body
    CAssign _ _ _ value body ->
      collectExprCodecTypes value <> collectExprCodecTypes body
    CFor _ _ _ iterable loopBody body ->
      collectExprCodecTypes iterable <> collectExprCodecTypes loopBody <> collectExprCodecTypes body
    CPage _ title body ->
      collectExprCodecTypes title <> collectExprCodecTypes body
    CRedirect _ _ ->
      []
    CViewEmpty _ ->
      []
    CViewText _ value ->
      collectExprCodecTypes value
    CViewAppend _ left right ->
      collectExprCodecTypes left <> collectExprCodecTypes right
    CViewElement _ _ child ->
      collectExprCodecTypes child
    CViewStyled _ _ child ->
      collectExprCodecTypes child
    CViewLink _ _ _ child ->
      collectExprCodecTypes child
    CViewForm _ _ _ _ child ->
      collectExprCodecTypes child
    CViewInput _ _ _ value ->
      collectExprCodecTypes value
    CViewSubmit _ label ->
      collectExprCodecTypes label
    CCall _ _ fn args ->
      collectExprCodecTypes fn <> concatMap collectExprCodecTypes args
    CMatch _ _ subject branches ->
      collectExprCodecTypes subject <> concatMap (collectExprCodecTypes . coreMatchBranchBody) branches
    CRecord _ _ _ fields ->
      concatMap (collectExprCodecTypes . coreRecordFieldValue) fields
    CFieldAccess _ _ subject _ ->
      collectExprCodecTypes subject
    CDecodeJson _ typ rawJson ->
      typ : collectExprCodecTypes rawJson
    CEncodeJson _ value ->
      coreExprType value : collectExprCodecTypes value

lowerPageFlows :: LowerModule -> [LowerPageFlow]
lowerPageFlows modl =
  mapMaybe buildPageFlow (filter ((== "Page") . lowerRouteResponseTypeName) (lowerModuleRoutes modl))
  where
    declEnv =
      Map.fromList
        [ (name, (params, body))
        | decl <- lowerModuleDecls modl
        , (name, params, body) <- case decl of
            LValueDecl name value ->
              [(name, [], value)]
            LFunctionDecl name params body ->
              [(name, params, body)]
        ]

    buildPageFlow route = do
      (_, handlerBody) <- Map.lookup (lowerRouteHandlerName route) declEnv
      case expandExpr declEnv Map.empty Set.empty handlerBody of
        LPage title body ->
          Just
            LowerPageFlow
              { lowerPageFlowRouteName = lowerRouteName route
              , lowerPageFlowRouteIdentity = lowerRouteIdentity route
              , lowerPageFlowPath = lowerRoutePath route
              , lowerPageFlowHandlerName = lowerRouteHandlerName route
              , lowerPageFlowTitle = summarizeValue title
              , lowerPageFlowTexts = uniqueTexts (collectViewTexts body)
              , lowerPageFlowLinks = collectPageLinks body
              , lowerPageFlowForms = collectPageForms body
              }
        _ ->
          Nothing

lowerTypeDeclConstructors :: TypeDecl -> [LowerDecl]
lowerTypeDeclConstructors typeDecl =
  fmap lowerConstructorDecl (typeDeclConstructors typeDecl)

lowerConstructorDecl :: ConstructorDecl -> LowerDecl
lowerConstructorDecl constructorDecl =
  case constructorDeclFields constructorDecl of
    [] ->
      LValueDecl
        (constructorDeclName constructorDecl)
        (LConstruct (constructorDeclName constructorDecl) [])
    fieldTypes ->
      let fieldNames = fmap (("$" <>) . T.pack . show) [(0 :: Int) .. (length fieldTypes - 1)]
       in LFunctionDecl
            (constructorDeclName constructorDecl)
            fieldNames
            (LConstruct (constructorDeclName constructorDecl) (fmap LVar fieldNames))

lowerCoreDecl :: CoreDecl -> LowerDecl
lowerCoreDecl decl
  | null (coreDeclParams decl) =
      LValueDecl (coreDeclName decl) (lowerCoreExpr (coreDeclBody decl))
  | otherwise =
      LFunctionDecl
        (coreDeclName decl)
        (fmap coreParamName (coreDeclParams decl))
        (lowerCoreExpr (coreDeclBody decl))

lowerCoreExpr :: CoreExpr -> LowerExpr
lowerCoreExpr expr =
  case expr of
    CVar _ _ name ->
      LVar name
    CInt _ value ->
      LInt value
    CString _ value ->
      LString value
    CBool _ value ->
      LBool value
    CList _ _ items ->
      LList (fmap lowerCoreExpr items)
    CReturn _ _ value ->
      LReturn (lowerCoreExpr value)
    CEqual _ left right ->
      LEqual (lowerCoreExpr left) (lowerCoreExpr right)
    CNotEqual _ left right ->
      LNotEqual (lowerCoreExpr left) (lowerCoreExpr right)
    CLessThan _ left right ->
      LLessThan (lowerCoreExpr left) (lowerCoreExpr right)
    CLessThanOrEqual _ left right ->
      LLessThanOrEqual (lowerCoreExpr left) (lowerCoreExpr right)
    CGreaterThan _ left right ->
      LGreaterThan (lowerCoreExpr left) (lowerCoreExpr right)
    CGreaterThanOrEqual _ left right ->
      LGreaterThanOrEqual (lowerCoreExpr left) (lowerCoreExpr right)
    CLet _ _ name value body ->
      LLet name (lowerCoreExpr value) (lowerCoreExpr body)
    CMutableLet _ _ name value body ->
      LMutableLet name (lowerCoreExpr value) (lowerCoreExpr body)
    CAssign _ _ name value body ->
      LAssign name (lowerCoreExpr value) (lowerCoreExpr body)
    CFor _ _ name iterable loopBody body ->
      LFor name (lowerCoreExpr iterable) (lowerCoreExpr loopBody) (lowerCoreExpr body)
    CPage _ title body ->
      LPage (lowerCoreExpr title) (lowerCoreExpr body)
    CRedirect _ targetPath ->
      LRedirect targetPath
    CViewEmpty _ ->
      LViewEmpty
    CViewText _ value ->
      LViewText (lowerCoreExpr value)
    CViewAppend _ left right ->
      LViewAppend (lowerCoreExpr left) (lowerCoreExpr right)
    CViewElement _ tag child ->
      LViewElement tag (lowerCoreExpr child)
    CViewStyled _ styleRef child ->
      LViewStyled styleRef (lowerCoreExpr child)
    CViewLink _ routeContract href child ->
      LViewLink (lowerRouteContract routeContract) href (lowerCoreExpr child)
    CViewForm _ routeContract method action child ->
      LViewForm (lowerRouteContract routeContract) method action (lowerCoreExpr child)
    CViewInput _ fieldName inputKind value ->
      LViewInput fieldName inputKind (lowerCoreExpr value)
    CViewSubmit _ label ->
      LViewSubmit (lowerCoreExpr label)
    CCall _ _ fn args ->
      LCall (lowerCoreExpr fn) (fmap lowerCoreExpr args)
    CMatch _ _ subject branches ->
      LMatch (lowerCoreExpr subject) (fmap lowerMatchBranch branches)
    CRecord _ _ _ fields ->
      LRecord (fmap lowerRecordField fields)
    CFieldAccess _ _ subject fieldName ->
      LFieldAccess (lowerCoreExpr subject) fieldName
    CDecodeJson _ typ rawJson ->
      LCall (LVar (codecDecodeName typ)) [lowerCoreExpr rawJson]
    CEncodeJson _ value ->
      LCall (LVar (codecEncodeName (coreExprType value))) [lowerCoreExpr value]

lowerRecordField :: CoreRecordField -> LowerRecordField
lowerRecordField field =
  LowerRecordField
    { lowerRecordFieldName = coreRecordFieldName field
    , lowerRecordFieldValue = lowerCoreExpr (coreRecordFieldValue field)
    }

lowerMatchBranch :: CoreMatchBranch -> LowerMatchBranch
lowerMatchBranch branch =
  case coreMatchBranchPattern branch of
    CConstructorPattern _ constructorName binders ->
      LowerMatchBranch
        { lowerMatchBranchTag = constructorName
        , lowerMatchBranchBinders = fmap corePatternBinderName binders
        , lowerMatchBranchBody = lowerCoreExpr (coreMatchBranchBody branch)
        }

lowerRouteDecl :: RouteDecl -> LowerRoute
lowerRouteDecl routeDecl =
  LowerRoute
    { lowerRouteName = routeDeclName routeDecl
    , lowerRouteIdentity = routeDeclIdentity routeDecl
    , lowerRouteMethod = routeDeclMethod routeDecl
    , lowerRoutePath = routeDeclPath routeDecl
    , lowerRoutePathDecl = routeDeclPathDecl routeDecl
    , lowerRouteRequestTypeName = routeDeclRequestType routeDecl
    , lowerRouteQueryDecl = routeDeclQueryDecl routeDecl
    , lowerRouteFormDecl = routeDeclFormDecl routeDecl
    , lowerRouteBodyDecl = routeDeclBodyDecl routeDecl
    , lowerRouteResponseTypeName = routeDeclResponseType routeDecl
    , lowerRouteResponseDecl = routeDeclResponseDecl routeDecl
    , lowerRouteHandlerName = routeDeclHandlerName routeDecl
    }

lowerRouteContract :: CoreRouteContract -> LowerRouteContract
lowerRouteContract routeContract =
  LowerRouteContract
    { lowerRouteContractName = coreRouteContractName routeContract
    , lowerRouteContractIdentity = coreRouteContractIdentity routeContract
    , lowerRouteContractMethod = coreRouteContractMethod routeContract
    , lowerRouteContractPath = coreRouteContractPath routeContract
    , lowerRouteContractPathDecl = coreRouteContractPathDecl routeContract
    , lowerRouteContractRequestType = coreRouteContractRequestType routeContract
    , lowerRouteContractQueryDecl = coreRouteContractQueryDecl routeContract
    , lowerRouteContractFormDecl = coreRouteContractFormDecl routeContract
    , lowerRouteContractBodyDecl = coreRouteContractBodyDecl routeContract
    , lowerRouteContractResponseType = coreRouteContractResponseType routeContract
    , lowerRouteContractResponseDecl = coreRouteContractResponseDecl routeContract
    , lowerRouteContractResponseKind = coreRouteContractResponseKind routeContract
    }

type DeclEnv = Map.Map Text ([Text], LowerExpr)
type SubstEnv = Map.Map Text LowerExpr

expandExpr :: DeclEnv -> SubstEnv -> Set.Set Text -> LowerExpr -> LowerExpr
expandExpr declEnv subst visited expr =
  case expr of
    LVar name ->
      case Map.lookup name subst of
        Just value ->
          expandExpr declEnv subst visited value
        Nothing
          | Set.member name visited ->
              LVar name
          | Just ([], body) <- Map.lookup name declEnv ->
              expandExpr declEnv subst (Set.insert name visited) body
          | otherwise ->
              LVar name
    LInt value ->
      LInt value
    LString value ->
      LString value
    LBool value ->
      LBool value
    LList items ->
      LList (fmap (expandExpr declEnv subst visited) items)
    LReturn value ->
      LReturn (expandExpr declEnv subst visited value)
    LEqual left right ->
      LEqual (expandExpr declEnv subst visited left) (expandExpr declEnv subst visited right)
    LNotEqual left right ->
      LNotEqual (expandExpr declEnv subst visited left) (expandExpr declEnv subst visited right)
    LLessThan left right ->
      LLessThan (expandExpr declEnv subst visited left) (expandExpr declEnv subst visited right)
    LLessThanOrEqual left right ->
      LLessThanOrEqual (expandExpr declEnv subst visited left) (expandExpr declEnv subst visited right)
    LGreaterThan left right ->
      LGreaterThan (expandExpr declEnv subst visited left) (expandExpr declEnv subst visited right)
    LGreaterThanOrEqual left right ->
      LGreaterThanOrEqual (expandExpr declEnv subst visited left) (expandExpr declEnv subst visited right)
    LLet name value body ->
      let value' = expandExpr declEnv subst visited value
       in expandExpr declEnv (Map.insert name value' subst) visited body
    LMutableLet name value body ->
      LMutableLet name (expandExpr declEnv subst visited value) (expandExpr declEnv subst visited body)
    LAssign name value body ->
      LAssign name (expandExpr declEnv subst visited value) (expandExpr declEnv subst visited body)
    LFor name iterable loopBody body ->
      LFor
        name
        (expandExpr declEnv subst visited iterable)
        (expandExpr declEnv subst visited loopBody)
        (expandExpr declEnv subst visited body)
    LPage title body ->
      LPage (expandExpr declEnv subst visited title) (expandExpr declEnv subst visited body)
    LRedirect targetPath ->
      LRedirect targetPath
    LViewEmpty ->
      LViewEmpty
    LViewText value ->
      LViewText (expandExpr declEnv subst visited value)
    LViewAppend left right ->
      LViewAppend (expandExpr declEnv subst visited left) (expandExpr declEnv subst visited right)
    LViewElement tag child ->
      LViewElement tag (expandExpr declEnv subst visited child)
    LViewStyled styleRef child ->
      LViewStyled styleRef (expandExpr declEnv subst visited child)
    LViewLink routeContract href child ->
      LViewLink routeContract href (expandExpr declEnv subst visited child)
    LViewForm routeContract method action child ->
      LViewForm routeContract method action (expandExpr declEnv subst visited child)
    LViewInput fieldName inputKind value ->
      LViewInput fieldName inputKind (expandExpr declEnv subst visited value)
    LViewSubmit label ->
      LViewSubmit (expandExpr declEnv subst visited label)
    LCall fn args ->
      let fn' = expandExpr declEnv subst visited fn
          args' = fmap (expandExpr declEnv subst visited) args
       in case fn' of
            LVar name
              | not (Set.member name visited)
              , Just (params, body) <- Map.lookup name declEnv
              , length params == length args' ->
                  expandExpr
                    declEnv
                    (Map.fromList (zip params args') `Map.union` subst)
                    (Set.insert name visited)
                    body
            _ ->
              LCall fn' args'
    LConstruct tag fields ->
      LConstruct tag (fmap (expandExpr declEnv subst visited) fields)
    LMatch subject branches ->
      let subject' = expandExpr declEnv subst visited subject
       in case subject' of
            LConstruct tag fields ->
              case findMatchingBranch tag branches of
                Just branch ->
                  expandExpr
                    declEnv
                    (Map.fromList (zip (lowerMatchBranchBinders branch) fields) `Map.union` subst)
                    visited
                    (lowerMatchBranchBody branch)
                Nothing ->
                  LMatch subject' (fmap (expandBranch declEnv subst visited) branches)
            _ ->
              LMatch subject' (fmap (expandBranch declEnv subst visited) branches)
    LRecord fields ->
      LRecord (fmap (expandRecordField declEnv subst visited) fields)
    LFieldAccess subject fieldName ->
      let subject' = expandExpr declEnv subst visited subject
       in case subject' of
            LRecord fields ->
              case find ((== fieldName) . lowerRecordFieldName) fields of
                Just field ->
                  expandExpr declEnv subst visited (lowerRecordFieldValue field)
                Nothing ->
                  LFieldAccess subject' fieldName
            _ ->
              LFieldAccess subject' fieldName

expandBranch :: DeclEnv -> SubstEnv -> Set.Set Text -> LowerMatchBranch -> LowerMatchBranch
expandBranch declEnv subst visited branch =
  branch
    { lowerMatchBranchBody = expandExpr declEnv subst visited (lowerMatchBranchBody branch)
    }

expandRecordField :: DeclEnv -> SubstEnv -> Set.Set Text -> LowerRecordField -> LowerRecordField
expandRecordField declEnv subst visited field =
  field
    { lowerRecordFieldValue = expandExpr declEnv subst visited (lowerRecordFieldValue field)
    }

findMatchingBranch :: Text -> [LowerMatchBranch] -> Maybe LowerMatchBranch
findMatchingBranch tag =
  find ((== tag) . lowerMatchBranchTag)

collectViewTexts :: LowerExpr -> [Text]
collectViewTexts expr =
  case expr of
    LViewEmpty ->
      []
    LViewText value ->
      [summarizeValue value]
    LViewAppend left right ->
      collectViewTexts left <> collectViewTexts right
    LViewElement _ child ->
      collectViewTexts child
    LViewStyled _ child ->
      collectViewTexts child
    LViewLink _ _ child ->
      collectViewTexts child
    LViewForm _ _ _ child ->
      collectViewTexts child
    LViewInput _ _ _ ->
      []
    LViewSubmit label ->
      [summarizeValue label]
    _ ->
      []

collectPageLinks :: LowerExpr -> [LowerPageLink]
collectPageLinks expr =
  case expr of
    LViewAppend left right ->
      collectPageLinks left <> collectPageLinks right
    LViewElement _ child ->
      collectPageLinks child
    LViewStyled _ child ->
      collectPageLinks child
    LViewLink routeContract href child ->
      LowerPageLink
        { lowerPageLinkRouteName = lowerRouteContractName routeContract
        , lowerPageLinkRouteIdentity = lowerRouteContractIdentity routeContract
        , lowerPageLinkPath = lowerRouteContractPath routeContract
        , lowerPageLinkHref = href
        , lowerPageLinkLabel = summarizeViewLabel child
        }
        : collectPageLinks child
    LViewForm _ _ _ child ->
      collectPageLinks child
    _ ->
      []

collectPageForms :: LowerExpr -> [LowerPageForm]
collectPageForms expr =
  case expr of
    LViewAppend left right ->
      collectPageForms left <> collectPageForms right
    LViewElement _ child ->
      collectPageForms child
    LViewStyled _ child ->
      collectPageForms child
    LViewLink _ _ child ->
      collectPageForms child
    LViewForm routeContract method action child ->
      LowerPageForm
        { lowerPageFormRouteName = lowerRouteContractName routeContract
        , lowerPageFormRouteIdentity = lowerRouteContractIdentity routeContract
        , lowerPageFormPath = lowerRouteContractPath routeContract
        , lowerPageFormMethod = method
        , lowerPageFormAction = action
        , lowerPageFormRequestType = lowerRouteContractRequestType routeContract
        , lowerPageFormResponseType = lowerRouteContractResponseType routeContract
        , lowerPageFormResponseKind = lowerRouteContractResponseKind routeContract
        , lowerPageFormFields = collectFormFields Nothing child
        , lowerPageFormSubmitLabels = uniqueTexts (collectSubmitLabels child)
        }
        : collectPageForms child
    _ ->
      []

collectFormFields :: Maybe Text -> LowerExpr -> [LowerFormField]
collectFormFields currentLabel expr =
  case expr of
    LViewAppend left right ->
      collectFormFields currentLabel left <> collectFormFields currentLabel right
    LViewElement "label" child ->
      let labelText = summarizeViewLabel child
       in collectFormFields (Just labelText) child
    LViewElement _ child ->
      collectFormFields currentLabel child
    LViewStyled _ child ->
      collectFormFields currentLabel child
    LViewLink _ _ child ->
      collectFormFields currentLabel child
    LViewForm _ _ _ child ->
      collectFormFields currentLabel child
    LViewInput fieldName inputKind value ->
      [ LowerFormField
          { lowerFormFieldName = fieldName
          , lowerFormFieldInputKind = inputKind
          , lowerFormFieldLabel = currentLabel
          , lowerFormFieldValue = summarizeValue value
          }
      ]
    _ ->
      []

collectSubmitLabels :: LowerExpr -> [Text]
collectSubmitLabels expr =
  case expr of
    LViewAppend left right ->
      collectSubmitLabels left <> collectSubmitLabels right
    LViewElement _ child ->
      collectSubmitLabels child
    LViewStyled _ child ->
      collectSubmitLabels child
    LViewLink _ _ child ->
      collectSubmitLabels child
    LViewForm _ _ _ child ->
      collectSubmitLabels child
    LViewSubmit label ->
      [summarizeValue label]
    _ ->
      []

summarizeViewLabel :: LowerExpr -> Text
summarizeViewLabel expr =
  case uniqueTexts (collectViewTexts expr) of
    [] ->
      "<dynamic>"
    labels ->
      T.intercalate " " labels

summarizeValue :: LowerExpr -> Text
summarizeValue expr =
  case expr of
    LVar name ->
      normalizeSummaryName name
    LInt value ->
      T.pack (show value)
    LString value ->
      value
    LBool True ->
      "true"
    LBool False ->
      "false"
    LList items ->
      "[" <> T.intercalate ", " (fmap summarizeValue items) <> "]"
    LReturn value ->
      summarizeValue value
    LEqual left right ->
      summarizeValue left <> " == " <> summarizeValue right
    LNotEqual left right ->
      summarizeValue left <> " != " <> summarizeValue right
    LLessThan left right ->
      summarizeValue left <> " < " <> summarizeValue right
    LLessThanOrEqual left right ->
      summarizeValue left <> " <= " <> summarizeValue right
    LGreaterThan left right ->
      summarizeValue left <> " > " <> summarizeValue right
    LGreaterThanOrEqual left right ->
      summarizeValue left <> " >= " <> summarizeValue right
    LLet name _ body ->
      normalizeSummaryName name <> " = " <> summarizeValue body
    LMutableLet name _ body ->
      normalizeSummaryName name <> " = " <> summarizeValue body
    LAssign name _ body ->
      normalizeSummaryName name <> " = " <> summarizeValue body
    LFor _ _ _ body ->
      summarizeValue body
    LConstruct tag _ ->
      tag
    LCall fn _ ->
      summarizeValue fn <> "(...)"
    LFieldAccess subject fieldName ->
      summarizeValue subject <> "." <> fieldName
    _ ->
      "<dynamic>"

normalizeSummaryName :: Text -> Text
normalizeSummaryName name
  | "$decode_" `T.isPrefixOf` name =
      T.drop (T.length ("$decode_" :: Text)) name
  | "$encode_" `T.isPrefixOf` name =
      T.drop (T.length ("$encode_" :: Text)) name
  | otherwise =
      name

uniqueTexts :: [Text] -> [Text]
uniqueTexts =
  go Set.empty
  where
    go _ [] = []
    go seen (value : rest)
      | T.null value =
          go seen rest
      | Set.member value seen =
          go seen rest
      | otherwise =
          value : go (Set.insert value seen) rest

codecDecodeName :: Type -> Text
codecDecodeName typ =
  "$decode_" <> codecSuffix typ

codecEncodeName :: Type -> Text
codecEncodeName typ =
  "$encode_" <> codecSuffix typ

codecSuffix :: Type -> Text
codecSuffix typ =
  case typ of
    TInt ->
      "Int"
    TStr ->
      "Str"
    TBool ->
      "Bool"
    TList itemType ->
      "List_" <> codecSuffix itemType
    TNamed name ->
      name
    TFunction _ _ ->
      error "functions are not JSON codec targets"
