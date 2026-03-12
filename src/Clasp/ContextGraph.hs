{-# LANGUAGE OverloadedStrings #-}

module Clasp.ContextGraph
  ( ContextAttr (..)
  , ContextEdge (..)
  , ContextGraph (..)
  , ContextNode (..)
  , ContextNodeId (..)
  , buildContextGraph
  , renderContextGraphJson
  ) where

import Data.Aeson
  ( ToJSON (toJSON)
  , Value (Bool, String)
  , object
  , (.=)
  )
import qualified Data.Aeson.Key as Key
import Data.Aeson.Text (encodeToLazyText)
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text, pack)
import qualified Data.Text.Lazy as LT
import Clasp.Core
  ( CoreAgentDecl (..)
  , CoreAgentRoleDecl (..)
  , CoreHookDecl (..)
  , CoreMergeGateDecl (..)
  , CoreModule (..)
  , CorePolicyDecl (..)
  , CoreToolDecl (..)
  , CoreToolServerDecl (..)
  , CoreVerifierDecl (..)
  )
import Clasp.Lower
  ( LowerFormField (..)
  , LowerPageFlow (..)
  , LowerPageForm (..)
  , LowerPageLink (..)
  , lowerModule
  , lowerPageFlows
  )
import Clasp.Syntax
  ( AgentDecl (..)
  , AgentRoleDecl (..)
  , ForeignDecl (..)
  , GuideDecl (..)
  , GuideEntryDecl (..)
  , HookDecl (..)
  , HookTriggerDecl (..)
  , MergeGateDecl (..)
  , MergeGateVerifierRef (..)
  , ModuleName (..)
  , PolicyClassificationDecl (..)
  , PolicyDecl (..)
  , PolicyPermissionDecl (..)
  , PolicyPermissionKind (..)
  , RecordDecl (..)
  , RecordFieldDecl (..)
  , RouteBoundaryDecl (..)
  , RouteDecl (..)
  , RouteMethod (..)
  , SourceSpan (..)
  , ToolDecl (..)
  , ToolServerDecl (..)
  , Type (..)
  , VerifierDecl (..)
  )

newtype ContextNodeId = ContextNodeId
  { unContextNodeId :: Text
  }
  deriving (Eq, Ord, Show)

data ContextAttr
  = ContextAttrText Text
  | ContextAttrMaybeText (Maybe Text)
  | ContextAttrTexts [Text]
  | ContextAttrBool Bool
  | ContextAttrObject [(Text, ContextAttr)]
  | ContextAttrList [ContextAttr]
  deriving (Eq, Show)

data ContextNode = ContextNode
  { contextNodeId :: ContextNodeId
  , contextNodeKind :: Text
  , contextNodeSpan :: Maybe SourceSpan
  , contextNodeAttrs :: [(Text, ContextAttr)]
  }
  deriving (Eq, Show)

data ContextEdge = ContextEdge
  { contextEdgeKind :: Text
  , contextEdgeFrom :: ContextNodeId
  , contextEdgeTo :: ContextNodeId
  , contextEdgeAttrs :: [(Text, ContextAttr)]
  }
  deriving (Eq, Show)

data ContextGraph = ContextGraph
  { contextGraphModuleName :: ModuleName
  , contextGraphNodes :: [ContextNode]
  , contextGraphEdges :: [ContextEdge]
  }
  deriving (Eq, Show)

buildContextGraph :: CoreModule -> ContextGraph
buildContextGraph modl =
  ContextGraph
    { contextGraphModuleName = coreModuleName modl
    , contextGraphNodes = allNodes
    , contextGraphEdges = filterValidEdges allNodeIds allEdges
    }
  where
    lowered = lowerModule modl
    pageFlows = lowerPageFlows lowered
    routeBoundaryNames = collectRouteBoundaryNames (coreModuleRouteDecls modl)
    builtinSchemaNodes = mapMaybe builtinSchemaNode (Set.toList routeBoundaryNames)
    schemaNodes = concatMap buildSchemaNodes (coreModuleRecordDecls modl) <> builtinSchemaNodes
    guideNodes = concatMap buildGuideNodes (coreModuleGuideDecls modl)
    hookNodes = concatMap buildHookNodes (coreModuleHookDecls modl)
    policyNodes = concatMap buildPolicyNodes (coreModulePolicyDecls modl)
    toolServerNodes = fmap buildToolServerNode (coreModuleToolServerDecls modl)
    toolNodes = fmap buildToolNode (coreModuleToolDecls modl)
    verifierNodes = fmap buildVerifierNode (coreModuleVerifierDecls modl)
    mergeGateNodes = fmap buildMergeGateNode (coreModuleMergeGateDecls modl)
    agentRoleNodes = fmap buildAgentRoleNode (coreModuleAgentRoleDecls modl)
    agentNodes = fmap buildAgentNode (coreModuleAgentDecls modl)
    routeNodes = fmap buildRouteNode (coreModuleRouteDecls modl)
    pageNodes = fmap buildPageNode pageFlows
    actionNodes = concatMap buildActionNodes pageFlows
    foreignNodes = fmap buildForeignNode (coreModuleForeignDecls modl)
    runtimeNodes = buildRuntimeNodes (coreModuleForeignDecls modl)
    allNodes = schemaNodes <> guideNodes <> hookNodes <> policyNodes <> toolServerNodes <> toolNodes <> verifierNodes <> mergeGateNodes <> agentRoleNodes <> agentNodes <> routeNodes <> pageNodes <> actionNodes <> foreignNodes <> runtimeNodes
    allNodeIds = Set.fromList (fmap contextNodeId allNodes)
    allEdges =
      concatMap buildSchemaEdges (coreModuleRecordDecls modl)
        <> concatMap buildGuideEdges (coreModuleGuideDecls modl)
        <> concatMap buildHookEdges (coreModuleHookDecls modl)
        <> concatMap buildPolicyEdges (coreModulePolicyDecls modl)
        <> concatMap buildToolServerEdges (coreModuleToolServerDecls modl)
        <> concatMap buildToolEdges (coreModuleToolDecls modl)
        <> concatMap buildVerifierEdges (coreModuleVerifierDecls modl)
        <> concatMap buildMergeGateEdges (coreModuleMergeGateDecls modl)
        <> concatMap buildAgentRoleEdges (coreModuleAgentRoleDecls modl)
        <> concatMap buildAgentEdges (coreModuleAgentDecls modl)
        <> concatMap buildRouteEdges (coreModuleRouteDecls modl)
        <> concatMap buildPageEdges pageFlows
        <> concatMap buildForeignEdges (coreModuleForeignDecls modl)

renderContextGraphJson :: ContextGraph -> LT.Text
renderContextGraphJson = encodeToLazyText

buildSchemaNodes :: RecordDecl -> [ContextNode]
buildSchemaNodes recordDecl =
  schemaNode : fmap (buildSchemaFieldNode (recordDeclName recordDecl)) (recordDeclFields recordDecl)
  where
    schemaNode =
      ContextNode
        { contextNodeId = schemaNodeId (recordDeclName recordDecl)
        , contextNodeKind = "schema"
        , contextNodeSpan = Just (recordDeclSpan recordDecl)
        , contextNodeAttrs =
            [ ("name", ContextAttrText (recordDeclName recordDecl))
            , ("schemaKind", ContextAttrText "record")
            , ("builtin", ContextAttrBool (sourceSpanFile (recordDeclSpan recordDecl) == "<builtin>"))
            ]
        }

buildSchemaFieldNode :: Text -> RecordFieldDecl -> ContextNode
buildSchemaFieldNode schemaName fieldDecl =
  ContextNode
    { contextNodeId = schemaFieldNodeId schemaName (recordFieldDeclName fieldDecl)
    , contextNodeKind = "schemaField"
    , contextNodeSpan = Just (recordFieldDeclSpan fieldDecl)
    , contextNodeAttrs =
        [ ("name", ContextAttrText (recordFieldDeclName fieldDecl))
        , ("schemaName", ContextAttrText schemaName)
        , ("classification", ContextAttrText (recordFieldDeclClassification fieldDecl))
        , ("type", ContextAttrText (renderContextType (recordFieldDeclType fieldDecl)))
        ]
    }

buildGuideNodes :: GuideDecl -> [ContextNode]
buildGuideNodes guideDecl =
  guideNode : fmap (buildGuideEntryNode (guideDeclName guideDecl)) (guideDeclEntries guideDecl)
  where
    guideNode =
      ContextNode
        { contextNodeId = guideNodeId (guideDeclName guideDecl)
        , contextNodeKind = "guide"
        , contextNodeSpan = Just (guideDeclSpan guideDecl)
        , contextNodeAttrs =
            [ ("name", ContextAttrText (guideDeclName guideDecl))
            , ("extends", ContextAttrMaybeText (guideDeclExtends guideDecl))
            ]
        }

buildGuideEntryNode :: Text -> GuideEntryDecl -> ContextNode
buildGuideEntryNode guideName entryDecl =
  ContextNode
    { contextNodeId = guideEntryNodeId guideName (guideEntryDeclName entryDecl)
    , contextNodeKind = "guideEntry"
    , contextNodeSpan = Just (guideEntryDeclSpan entryDecl)
    , contextNodeAttrs =
        [ ("name", ContextAttrText (guideEntryDeclName entryDecl))
        , ("guideName", ContextAttrText guideName)
        , ("value", ContextAttrText (guideEntryDeclValue entryDecl))
        ]
    }

buildHookNodes :: CoreHookDecl -> [ContextNode]
buildHookNodes coreHookDecl =
  [ hookNode
  , triggerNode
  ]
  where
    hookDecl = coreHookSourceDecl coreHookDecl
    triggerDecl = hookDeclTrigger hookDecl
    hookNode =
      ContextNode
        { contextNodeId = hookNodeId (hookDeclName hookDecl)
        , contextNodeKind = "hook"
        , contextNodeSpan = Just (hookDeclSpan hookDecl)
        , contextNodeAttrs =
            [ ("name", ContextAttrText (hookDeclName hookDecl))
            , ("identity", ContextAttrText (hookDeclIdentity hookDecl))
            , ("requestType", ContextAttrText (hookDeclRequestType hookDecl))
            , ("responseType", ContextAttrText (hookDeclResponseType hookDecl))
            , ("handlerName", ContextAttrText (hookDeclHandlerName hookDecl))
            ]
        }
    triggerNode =
      ContextNode
        { contextNodeId = hookTriggerNodeId (hookDeclName hookDecl)
        , contextNodeKind = "hookTrigger"
        , contextNodeSpan = Just (hookTriggerDeclSpan triggerDecl)
        , contextNodeAttrs =
            [ ("hookName", ContextAttrText (hookDeclName hookDecl))
            , ("event", ContextAttrText (hookTriggerDeclEvent triggerDecl))
            ]
        }

buildPolicyNodes :: CorePolicyDecl -> [ContextNode]
buildPolicyNodes corePolicyDecl =
  policyNode : fmap (buildPolicyClassificationNode (policyDeclName policyDecl)) (policyDeclAllowedClassifications policyDecl)
  where
    policyDecl = corePolicySourceDecl corePolicyDecl
    policyNode =
      ContextNode
        { contextNodeId = policyNodeId (policyDeclName policyDecl)
        , contextNodeKind = "policy"
        , contextNodeSpan = Just (policyDeclSpan policyDecl)
        , contextNodeAttrs =
            [ ("name", ContextAttrText (policyDeclName policyDecl))
            , ("allowedClassifications", ContextAttrTexts (fmap policyClassificationDeclName (policyDeclAllowedClassifications policyDecl)))
            , ("filePermissions", ContextAttrTexts (policyPermissionValues PolicyPermissionFile policyDecl))
            , ("networkPermissions", ContextAttrTexts (policyPermissionValues PolicyPermissionNetwork policyDecl))
            , ("processPermissions", ContextAttrTexts (policyPermissionValues PolicyPermissionProcess policyDecl))
            , ("secretPermissions", ContextAttrTexts (policyPermissionValues PolicyPermissionSecret policyDecl))
            ]
        }

buildPolicyClassificationNode :: Text -> PolicyClassificationDecl -> ContextNode
buildPolicyClassificationNode policyName classificationDecl =
  ContextNode
    { contextNodeId = policyClassificationNodeId policyName (policyClassificationDeclName classificationDecl)
    , contextNodeKind = "policyClassification"
    , contextNodeSpan = Just (policyClassificationDeclSpan classificationDecl)
    , contextNodeAttrs =
        [ ("name", ContextAttrText (policyClassificationDeclName classificationDecl))
        , ("policyName", ContextAttrText policyName)
        ]
    }

buildToolServerNode :: CoreToolServerDecl -> ContextNode
buildToolServerNode coreToolServerDecl =
  ContextNode
    { contextNodeId = toolServerNodeId (toolServerDeclName toolServerDecl)
    , contextNodeKind = "toolServer"
    , contextNodeSpan = Just (toolServerDeclSpan toolServerDecl)
    , contextNodeAttrs =
        [ ("name", ContextAttrText (toolServerDeclName toolServerDecl))
        , ("identity", ContextAttrText (toolServerDeclIdentity toolServerDecl))
        , ("protocol", ContextAttrText (toolServerDeclProtocol toolServerDecl))
        , ("location", ContextAttrText (toolServerDeclLocation toolServerDecl))
        , ("policyName", ContextAttrText (toolServerDeclPolicyName toolServerDecl))
        ]
    }
  where
    toolServerDecl = coreToolServerSourceDecl coreToolServerDecl

buildToolNode :: CoreToolDecl -> ContextNode
buildToolNode coreToolDecl =
  ContextNode
    { contextNodeId = toolNodeId (toolDeclName toolDecl)
    , contextNodeKind = "tool"
    , contextNodeSpan = Just (toolDeclSpan toolDecl)
    , contextNodeAttrs =
        [ ("name", ContextAttrText (toolDeclName toolDecl))
        , ("identity", ContextAttrText (toolDeclIdentity toolDecl))
        , ("serverName", ContextAttrText (toolDeclServerName toolDecl))
        , ("operation", ContextAttrText (toolDeclOperation toolDecl))
        , ("requestType", ContextAttrText (toolDeclRequestType toolDecl))
        , ("responseType", ContextAttrText (toolDeclResponseType toolDecl))
        ]
    }
  where
    toolDecl = coreToolSourceDecl coreToolDecl

buildVerifierNode :: CoreVerifierDecl -> ContextNode
buildVerifierNode coreVerifierDecl =
  ContextNode
    { contextNodeId = verifierNodeId (verifierDeclName verifierDecl)
    , contextNodeKind = "verifier"
    , contextNodeSpan = Just (verifierDeclSpan verifierDecl)
    , contextNodeAttrs =
        [ ("name", ContextAttrText (verifierDeclName verifierDecl))
        , ("identity", ContextAttrText (verifierDeclIdentity verifierDecl))
        , ("toolName", ContextAttrText (verifierDeclToolName verifierDecl))
        ]
    }
  where
    verifierDecl = coreVerifierSourceDecl coreVerifierDecl

buildMergeGateNode :: CoreMergeGateDecl -> ContextNode
buildMergeGateNode coreMergeGateDecl =
  ContextNode
    { contextNodeId = mergeGateNodeId (mergeGateDeclName mergeGateDecl)
    , contextNodeKind = "mergeGate"
    , contextNodeSpan = Just (mergeGateDeclSpan mergeGateDecl)
    , contextNodeAttrs =
        [ ("name", ContextAttrText (mergeGateDeclName mergeGateDecl))
        , ("identity", ContextAttrText (mergeGateDeclIdentity mergeGateDecl))
        , ("verifierNames", ContextAttrTexts (fmap mergeGateVerifierRefName (mergeGateDeclVerifierRefs mergeGateDecl)))
        ]
    }
  where
    mergeGateDecl = coreMergeGateSourceDecl coreMergeGateDecl

buildAgentRoleNode :: CoreAgentRoleDecl -> ContextNode
buildAgentRoleNode coreAgentRoleDecl =
  ContextNode
    { contextNodeId = agentRoleNodeId (agentRoleDeclName agentRoleDecl)
    , contextNodeKind = "agentRole"
    , contextNodeSpan = Just (agentRoleDeclSpan agentRoleDecl)
    , contextNodeAttrs =
        [ ("name", ContextAttrText (agentRoleDeclName agentRoleDecl))
        , ("identity", ContextAttrText (agentRoleDeclIdentity agentRoleDecl))
        , ("guideName", ContextAttrText (agentRoleDeclGuideName agentRoleDecl))
        , ("policyName", ContextAttrText (agentRoleDeclPolicyName agentRoleDecl))
        ]
    }
  where
    agentRoleDecl = coreAgentRoleSourceDecl coreAgentRoleDecl

buildAgentNode :: CoreAgentDecl -> ContextNode
buildAgentNode coreAgentDecl =
  ContextNode
    { contextNodeId = agentNodeId (agentDeclName agentDecl)
    , contextNodeKind = "agent"
    , contextNodeSpan = Just (agentDeclSpan agentDecl)
    , contextNodeAttrs =
        [ ("name", ContextAttrText (agentDeclName agentDecl))
        , ("identity", ContextAttrText (agentDeclIdentity agentDecl))
        , ("roleName", ContextAttrText (agentDeclRoleName agentDecl))
        ]
    }
  where
    agentDecl = coreAgentSourceDecl coreAgentDecl

builtinSchemaNode :: Text -> Maybe ContextNode
builtinSchemaNode name =
  case name of
    "Page" ->
      Just (buildBuiltinBoundarySchemaNode name "page")
    "Redirect" ->
      Just (buildBuiltinBoundarySchemaNode name "redirect")
    _ ->
      Nothing

buildBuiltinBoundarySchemaNode :: Text -> Text -> ContextNode
buildBuiltinBoundarySchemaNode name schemaKind =
  ContextNode
    { contextNodeId = schemaNodeId name
    , contextNodeKind = "schema"
    , contextNodeSpan = Nothing
    , contextNodeAttrs =
        [ ("name", ContextAttrText name)
        , ("schemaKind", ContextAttrText schemaKind)
        , ("builtin", ContextAttrBool True)
        ]
    }

buildRouteNode :: RouteDecl -> ContextNode
buildRouteNode routeDecl =
  ContextNode
    { contextNodeId = routeNodeId (routeDeclName routeDecl)
    , contextNodeKind = "route"
    , contextNodeSpan = Just (routeDeclSpan routeDecl)
    , contextNodeAttrs =
        [ ("name", ContextAttrText (routeDeclName routeDecl))
        , ("identity", ContextAttrText (routeDeclIdentity routeDecl))
        , ("method", ContextAttrText (renderRouteMethod routeDecl))
        , ("path", ContextAttrText (routeDeclPath routeDecl))
        , ("requestType", ContextAttrText (routeDeclRequestType routeDecl))
        , ("responseType", ContextAttrText (routeDeclResponseType routeDecl))
        , ("responseKind", ContextAttrText (routeResponseKind routeDecl))
        , ("handlerName", ContextAttrText (routeDeclHandlerName routeDecl))
        ]
    }

buildPageNode :: LowerPageFlow -> ContextNode
buildPageNode pageFlow =
  ContextNode
    { contextNodeId = pageNodeId (lowerPageFlowRouteName pageFlow)
    , contextNodeKind = "page"
    , contextNodeSpan = Nothing
    , contextNodeAttrs =
        [ ("routeName", ContextAttrText (lowerPageFlowRouteName pageFlow))
        , ("routeIdentity", ContextAttrText (lowerPageFlowRouteIdentity pageFlow))
        , ("path", ContextAttrText (lowerPageFlowPath pageFlow))
        , ("handlerName", ContextAttrText (lowerPageFlowHandlerName pageFlow))
        , ("title", ContextAttrText (lowerPageFlowTitle pageFlow))
        , ("texts", ContextAttrTexts (lowerPageFlowTexts pageFlow))
        ]
    }

buildActionNodes :: LowerPageFlow -> [ContextNode]
buildActionNodes pageFlow =
  zipWith (buildActionNode pageFlow) [(0 :: Int) ..] (lowerPageFlowForms pageFlow)

buildActionNode :: LowerPageFlow -> Int -> LowerPageForm -> ContextNode
buildActionNode pageFlow index form =
  ContextNode
    { contextNodeId = actionNodeId (lowerPageFlowRouteName pageFlow) index
    , contextNodeKind = "action"
    , contextNodeSpan = Nothing
    , contextNodeAttrs =
        [ ("pageRouteName", ContextAttrText (lowerPageFlowRouteName pageFlow))
        , ("routeName", ContextAttrText (lowerPageFormRouteName form))
        , ("routeIdentity", ContextAttrText (lowerPageFormRouteIdentity form))
        , ("path", ContextAttrText (lowerPageFormPath form))
        , ("method", ContextAttrText (lowerPageFormMethod form))
        , ("action", ContextAttrText (lowerPageFormAction form))
        , ("requestType", ContextAttrText (lowerPageFormRequestType form))
        , ("responseType", ContextAttrText (lowerPageFormResponseType form))
        , ("responseKind", ContextAttrText (lowerPageFormResponseKind form))
        , ("fields", ContextAttrList (fmap formFieldAttr (lowerPageFormFields form)))
        , ("submitLabels", ContextAttrTexts (lowerPageFormSubmitLabels form))
        ]
    }

buildForeignNode :: ForeignDecl -> ContextNode
buildForeignNode foreignDecl =
  ContextNode
    { contextNodeId = foreignNodeId (foreignDeclName foreignDecl)
    , contextNodeKind = "foreign"
    , contextNodeSpan = Just (foreignDeclSpan foreignDecl)
    , contextNodeAttrs =
        [ ("name", ContextAttrText (foreignDeclName foreignDecl))
        , ("runtimeName", ContextAttrText (foreignDeclRuntimeName foreignDecl))
        , ("type", ContextAttrText (renderContextType (foreignDeclType foreignDecl)))
        ]
    }

buildRuntimeNodes :: [ForeignDecl] -> [ContextNode]
buildRuntimeNodes foreignDecls =
  fmap buildRuntimeNode (Set.toList (Set.fromList (fmap foreignDeclRuntimeName foreignDecls)))

buildRuntimeNode :: Text -> ContextNode
buildRuntimeNode runtimeName =
  ContextNode
    { contextNodeId = runtimeNodeId runtimeName
    , contextNodeKind = "runtime"
    , contextNodeSpan = Nothing
    , contextNodeAttrs = [("name", ContextAttrText runtimeName)]
    }

buildSchemaEdges :: RecordDecl -> [ContextEdge]
buildSchemaEdges recordDecl =
  concatMap buildFieldEdges (recordDeclFields recordDecl)
  where
    buildFieldEdges fieldDecl =
      ContextEdge
        { contextEdgeKind = "schema-has-field"
        , contextEdgeFrom = schemaNodeId (recordDeclName recordDecl)
        , contextEdgeTo = schemaFieldNodeId (recordDeclName recordDecl) (recordFieldDeclName fieldDecl)
        , contextEdgeAttrs = []
        }
        : maybe [] pure (schemaFieldTypeEdge (recordDeclName recordDecl) fieldDecl)

schemaFieldTypeEdge :: Text -> RecordFieldDecl -> Maybe ContextEdge
schemaFieldTypeEdge schemaName fieldDecl =
  case recordFieldDeclType fieldDecl of
    TNamed targetName ->
      Just
        ContextEdge
          { contextEdgeKind = "field-type"
          , contextEdgeFrom = schemaFieldNodeId schemaName (recordFieldDeclName fieldDecl)
          , contextEdgeTo = schemaNodeId targetName
          , contextEdgeAttrs = []
          }
    _ ->
      Nothing

buildGuideEdges :: GuideDecl -> [ContextEdge]
buildGuideEdges guideDecl =
  entryEdges <> parentEdges
  where
    entryEdges =
      fmap
        ( \entryDecl ->
            ContextEdge
              { contextEdgeKind = "guide-has-entry"
              , contextEdgeFrom = guideNodeId (guideDeclName guideDecl)
              , contextEdgeTo = guideEntryNodeId (guideDeclName guideDecl) (guideEntryDeclName entryDecl)
              , contextEdgeAttrs = []
              }
        )
        (guideDeclEntries guideDecl)
    parentEdges =
      case guideDeclExtends guideDecl of
        Just parentName ->
          [ ContextEdge
              { contextEdgeKind = "guide-extends"
              , contextEdgeFrom = guideNodeId (guideDeclName guideDecl)
              , contextEdgeTo = guideNodeId parentName
              , contextEdgeAttrs = []
              }
          ]
        Nothing ->
          []

buildHookEdges :: CoreHookDecl -> [ContextEdge]
buildHookEdges coreHookDecl =
  [ ContextEdge
      { contextEdgeKind = "hook-trigger"
      , contextEdgeFrom = hookNodeId (hookDeclName hookDecl)
      , contextEdgeTo = hookTriggerNodeId (hookDeclName hookDecl)
      , contextEdgeAttrs = []
      }
  , ContextEdge
      { contextEdgeKind = "hook-request-schema"
      , contextEdgeFrom = hookNodeId (hookDeclName hookDecl)
      , contextEdgeTo = schemaNodeId (hookDeclRequestType hookDecl)
      , contextEdgeAttrs = []
      }
  , ContextEdge
      { contextEdgeKind = "hook-response-schema"
      , contextEdgeFrom = hookNodeId (hookDeclName hookDecl)
      , contextEdgeTo = schemaNodeId (hookDeclResponseType hookDecl)
      , contextEdgeAttrs = []
      }
  ]
  where
    hookDecl = coreHookSourceDecl coreHookDecl

buildPolicyEdges :: CorePolicyDecl -> [ContextEdge]
buildPolicyEdges corePolicyDecl =
  fmap buildClassificationEdge (policyDeclAllowedClassifications policyDecl)
  where
    policyDecl = corePolicySourceDecl corePolicyDecl
    buildClassificationEdge classificationDecl =
      ContextEdge
        { contextEdgeKind = "policy-allows-classification"
        , contextEdgeFrom = policyNodeId (policyDeclName policyDecl)
        , contextEdgeTo = policyClassificationNodeId (policyDeclName policyDecl) (policyClassificationDeclName classificationDecl)
        , contextEdgeAttrs = []
        }

buildToolServerEdges :: CoreToolServerDecl -> [ContextEdge]
buildToolServerEdges coreToolServerDecl =
  [ ContextEdge
      { contextEdgeKind = "toolserver-policy"
      , contextEdgeFrom = toolServerNodeId (toolServerDeclName toolServerDecl)
      , contextEdgeTo = policyNodeId (toolServerDeclPolicyName toolServerDecl)
      , contextEdgeAttrs = []
      }
  ]
  where
    toolServerDecl = coreToolServerSourceDecl coreToolServerDecl

buildToolEdges :: CoreToolDecl -> [ContextEdge]
buildToolEdges coreToolDecl =
  [ ContextEdge
      { contextEdgeKind = "tool-server"
      , contextEdgeFrom = toolNodeId (toolDeclName toolDecl)
      , contextEdgeTo = toolServerNodeId (toolDeclServerName toolDecl)
      , contextEdgeAttrs = []
      }
  , ContextEdge
      { contextEdgeKind = "tool-request-schema"
      , contextEdgeFrom = toolNodeId (toolDeclName toolDecl)
      , contextEdgeTo = schemaNodeId (toolDeclRequestType toolDecl)
      , contextEdgeAttrs = []
      }
  , ContextEdge
      { contextEdgeKind = "tool-response-schema"
      , contextEdgeFrom = toolNodeId (toolDeclName toolDecl)
      , contextEdgeTo = schemaNodeId (toolDeclResponseType toolDecl)
      , contextEdgeAttrs = []
      }
  ]
  where
    toolDecl = coreToolSourceDecl coreToolDecl

buildVerifierEdges :: CoreVerifierDecl -> [ContextEdge]
buildVerifierEdges coreVerifierDecl =
  [ ContextEdge
      { contextEdgeKind = "verifier-tool"
      , contextEdgeFrom = verifierNodeId (verifierDeclName verifierDecl)
      , contextEdgeTo = toolNodeId (verifierDeclToolName verifierDecl)
      , contextEdgeAttrs = []
      }
  ]
  where
    verifierDecl = coreVerifierSourceDecl coreVerifierDecl

buildMergeGateEdges :: CoreMergeGateDecl -> [ContextEdge]
buildMergeGateEdges coreMergeGateDecl =
  fmap buildVerifierEdge (mergeGateDeclVerifierRefs mergeGateDecl)
  where
    mergeGateDecl = coreMergeGateSourceDecl coreMergeGateDecl
    buildVerifierEdge verifierRef =
      ContextEdge
        { contextEdgeKind = "merge-gate-verifier"
        , contextEdgeFrom = mergeGateNodeId (mergeGateDeclName mergeGateDecl)
        , contextEdgeTo = verifierNodeId (mergeGateVerifierRefName verifierRef)
        , contextEdgeAttrs = []
        }

buildAgentRoleEdges :: CoreAgentRoleDecl -> [ContextEdge]
buildAgentRoleEdges coreAgentRoleDecl =
  [ ContextEdge
      { contextEdgeKind = "agent-role-guide"
      , contextEdgeFrom = agentRoleNodeId (agentRoleDeclName agentRoleDecl)
      , contextEdgeTo = guideNodeId (agentRoleDeclGuideName agentRoleDecl)
      , contextEdgeAttrs = []
      }
  , ContextEdge
      { contextEdgeKind = "agent-role-policy"
      , contextEdgeFrom = agentRoleNodeId (agentRoleDeclName agentRoleDecl)
      , contextEdgeTo = policyNodeId (agentRoleDeclPolicyName agentRoleDecl)
      , contextEdgeAttrs = []
      }
  ]
  where
    agentRoleDecl = coreAgentRoleSourceDecl coreAgentRoleDecl

buildAgentEdges :: CoreAgentDecl -> [ContextEdge]
buildAgentEdges coreAgentDecl =
  [ ContextEdge
      { contextEdgeKind = "agent-role"
      , contextEdgeFrom = agentNodeId (agentDeclName agentDecl)
      , contextEdgeTo = agentRoleNodeId (agentDeclRoleName agentDecl)
      , contextEdgeAttrs = []
      }
  ]
  where
    agentDecl = coreAgentSourceDecl coreAgentDecl

buildRouteEdges :: RouteDecl -> [ContextEdge]
buildRouteEdges routeDecl =
  mapMaybe id
    [ fmap (routeBoundaryEdge "route-query-schema" routeDecl) (routeDeclQueryDecl routeDecl)
    , fmap (routeBoundaryEdge "route-form-schema" routeDecl) (routeDeclFormDecl routeDecl)
    , fmap (routeBoundaryEdge "route-body-schema" routeDecl) (routeDeclBodyDecl routeDecl)
    , Just (routeBoundaryEdge "route-response-schema" routeDecl (routeDeclResponseDecl routeDecl))
    ]

routeBoundaryEdge :: Text -> RouteDecl -> RouteBoundaryDecl -> ContextEdge
routeBoundaryEdge edgeKind routeDecl boundaryDecl =
  ContextEdge
    { contextEdgeKind = edgeKind
    , contextEdgeFrom = routeNodeId (routeDeclName routeDecl)
    , contextEdgeTo = schemaNodeId (routeBoundaryDeclType boundaryDecl)
    , contextEdgeAttrs = []
    }

buildPageEdges :: LowerPageFlow -> [ContextEdge]
buildPageEdges pageFlow =
  pageRouteEdge : linkEdges <> actionEdges
  where
    pageRouteEdge =
      ContextEdge
        { contextEdgeKind = "page-route"
        , contextEdgeFrom = pageNodeId (lowerPageFlowRouteName pageFlow)
        , contextEdgeTo = routeNodeId (lowerPageFlowRouteName pageFlow)
        , contextEdgeAttrs = []
        }
    linkEdges =
      fmap
        ( \link ->
            ContextEdge
              { contextEdgeKind = "page-link"
              , contextEdgeFrom = pageNodeId (lowerPageFlowRouteName pageFlow)
              , contextEdgeTo = routeNodeId (lowerPageLinkRouteName link)
              , contextEdgeAttrs =
                  [ ("href", ContextAttrText (lowerPageLinkHref link))
                  , ("label", ContextAttrText (lowerPageLinkLabel link))
                  ]
              }
        )
        (lowerPageFlowLinks pageFlow)
    actionEdges =
      concat (zipWith (buildFormEdges (lowerPageFlowRouteName pageFlow) (pageNodeId (lowerPageFlowRouteName pageFlow))) [(0 :: Int) ..] (lowerPageFlowForms pageFlow))

buildFormEdges :: Text -> ContextNodeId -> Int -> LowerPageForm -> [ContextEdge]
buildFormEdges pageRouteName pageId index form =
  ContextEdge
    { contextEdgeKind = "page-action"
    , contextEdgeFrom = pageId
    , contextEdgeTo = actionId
    , contextEdgeAttrs = []
    }
    : [ ContextEdge
          { contextEdgeKind = "action-route"
          , contextEdgeFrom = actionId
          , contextEdgeTo = routeNodeId (lowerPageFormRouteName form)
          , contextEdgeAttrs = []
          }
      , ContextEdge
          { contextEdgeKind = "action-request-schema"
          , contextEdgeFrom = actionId
          , contextEdgeTo = schemaNodeId (lowerPageFormRequestType form)
          , contextEdgeAttrs = []
          }
      , ContextEdge
          { contextEdgeKind = "action-response-schema"
          , contextEdgeFrom = actionId
          , contextEdgeTo = schemaNodeId (lowerPageFormResponseType form)
          , contextEdgeAttrs = []
          }
      ]
  where
    actionId = actionNodeId pageRouteName index

buildForeignEdges :: ForeignDecl -> [ContextEdge]
buildForeignEdges foreignDecl =
  [ ContextEdge
      { contextEdgeKind = "foreign-runtime"
      , contextEdgeFrom = foreignNodeId (foreignDeclName foreignDecl)
      , contextEdgeTo = runtimeNodeId (foreignDeclRuntimeName foreignDecl)
      , contextEdgeAttrs = []
      }
  ]

collectRouteBoundaryNames :: [RouteDecl] -> Set.Set Text
collectRouteBoundaryNames routeDecls =
  Set.fromList (concatMap routeBoundaryNames routeDecls)
  where
    routeBoundaryNames routeDecl =
      routeBoundaryDeclType (routeDeclResponseDecl routeDecl)
        : map routeBoundaryDeclType (mapMaybe id [routeDeclQueryDecl routeDecl, routeDeclFormDecl routeDecl, routeDeclBodyDecl routeDecl])

filterValidEdges :: Set.Set ContextNodeId -> [ContextEdge] -> [ContextEdge]
filterValidEdges nodeIds =
  filter (\edge -> Set.member (contextEdgeFrom edge) nodeIds && Set.member (contextEdgeTo edge) nodeIds)

schemaNodeId :: Text -> ContextNodeId
schemaNodeId name = ContextNodeId ("schema:" <> name)

schemaFieldNodeId :: Text -> Text -> ContextNodeId
schemaFieldNodeId schemaName fieldName = ContextNodeId ("schema-field:" <> schemaName <> ":" <> fieldName)

guideNodeId :: Text -> ContextNodeId
guideNodeId name = ContextNodeId ("guide:" <> name)

guideEntryNodeId :: Text -> Text -> ContextNodeId
guideEntryNodeId guideName entryName = ContextNodeId ("guide-entry:" <> guideName <> ":" <> entryName)

policyNodeId :: Text -> ContextNodeId
policyNodeId name = ContextNodeId ("policy:" <> name)

policyClassificationNodeId :: Text -> Text -> ContextNodeId
policyClassificationNodeId policyName classificationName = ContextNodeId ("policy-classification:" <> policyName <> ":" <> classificationName)

policyPermissionValues :: PolicyPermissionKind -> PolicyDecl -> [Text]
policyPermissionValues permissionKind policyDecl =
  [ policyPermissionDeclValue permissionDecl
  | permissionDecl <- policyDeclPermissions policyDecl
  , policyPermissionDeclKind permissionDecl == permissionKind
  ]

hookNodeId :: Text -> ContextNodeId
hookNodeId name = ContextNodeId ("hook:" <> name)

hookTriggerNodeId :: Text -> ContextNodeId
hookTriggerNodeId hookName = ContextNodeId ("hook-trigger:" <> hookName)

toolServerNodeId :: Text -> ContextNodeId
toolServerNodeId name = ContextNodeId ("toolserver:" <> name)

toolNodeId :: Text -> ContextNodeId
toolNodeId name = ContextNodeId ("tool:" <> name)

verifierNodeId :: Text -> ContextNodeId
verifierNodeId name = ContextNodeId ("verifier:" <> name)

mergeGateNodeId :: Text -> ContextNodeId
mergeGateNodeId name = ContextNodeId ("mergegate:" <> name)

agentRoleNodeId :: Text -> ContextNodeId
agentRoleNodeId name = ContextNodeId ("agent-role:" <> name)

agentNodeId :: Text -> ContextNodeId
agentNodeId name = ContextNodeId ("agent:" <> name)

routeNodeId :: Text -> ContextNodeId
routeNodeId name = ContextNodeId ("route:" <> name)

pageNodeId :: Text -> ContextNodeId
pageNodeId routeName = ContextNodeId ("page:" <> routeName)

actionNodeId :: Text -> Int -> ContextNodeId
actionNodeId routeName index = ContextNodeId ("action:" <> routeName <> ":" <> showText index)

foreignNodeId :: Text -> ContextNodeId
foreignNodeId name = ContextNodeId ("foreign:" <> name)

runtimeNodeId :: Text -> ContextNodeId
runtimeNodeId runtimeName = ContextNodeId ("runtime:" <> runtimeName)

formFieldAttr :: LowerFormField -> ContextAttr
formFieldAttr field =
  ContextAttrObject
    [ ("name", ContextAttrText (lowerFormFieldName field))
    , ("inputKind", ContextAttrText (lowerFormFieldInputKind field))
    , ("label", ContextAttrMaybeText (lowerFormFieldLabel field))
    , ("value", ContextAttrText (lowerFormFieldValue field))
    ]

renderContextType :: Type -> Text
renderContextType typ =
  case typ of
    TInt ->
      "Int"
    TStr ->
      "Str"
    TBool ->
      "Bool"
    TList itemType ->
      "[" <> renderContextType itemType <> "]"
    TNamed name ->
      name
    TFunction args result ->
      mconcat (renderArgs args <> [" -> ", renderContextType result])
  where
    renderArgs [] = []
    renderArgs [arg] = [renderContextType arg]
    renderArgs args = ["(", joinWith ", " (fmap renderContextType args), ")"]

routeResponseKind :: RouteDecl -> Text
routeResponseKind routeDecl =
  case routeDeclResponseType routeDecl of
    "Page" ->
      "page"
    "Redirect" ->
      "redirect"
    _ ->
      "schema"

renderRouteMethod :: RouteDecl -> Text
renderRouteMethod routeDecl =
  case routeDeclMethod routeDecl of
    RouteGet ->
      "GET"
    RoutePost ->
      "POST"

joinWith :: Text -> [Text] -> Text
joinWith separator values =
  case values of
    [] ->
      ""
    firstValue : rest ->
      foldl (\acc value -> acc <> separator <> value) firstValue rest

showText :: Show a => a -> Text
showText = pack . show

instance ToJSON ContextNodeId where
  toJSON = String . unContextNodeId

instance ToJSON ContextAttr where
  toJSON attr =
    case attr of
      ContextAttrText value
        -> String value
      ContextAttrMaybeText maybeValue ->
        toJSON maybeValue
      ContextAttrTexts values ->
        toJSON values
      ContextAttrBool value ->
        Bool value
      ContextAttrObject fields ->
        object [Key.fromText label .= value | (label, value) <- fields]
      ContextAttrList values ->
        toJSON values

instance ToJSON ContextNode where
  toJSON node =
    object
      [ "id" .= contextNodeId node
      , "kind" .= contextNodeKind node
      , "span" .= contextNodeSpan node
      , "attrs" .= fmap (\(label, value) -> object ["name" .= label, "value" .= value]) (contextNodeAttrs node)
      ]

instance ToJSON ContextEdge where
  toJSON edge =
    object
      [ "kind" .= contextEdgeKind edge
      , "from" .= contextEdgeFrom edge
      , "to" .= contextEdgeTo edge
      , "attrs" .= fmap (\(label, value) -> object ["name" .= label, "value" .= value]) (contextEdgeAttrs edge)
      ]

instance ToJSON ContextGraph where
  toJSON graph =
    object
      [ "format" .= ("clasp-context-v1" :: Text)
      , "module" .= unModuleName (contextGraphModuleName graph)
      , "nodeCount" .= length (contextGraphNodes graph)
      , "edgeCount" .= length (contextGraphEdges graph)
      , "nodes" .= contextGraphNodes graph
      , "edges" .= contextGraphEdges graph
      ]
