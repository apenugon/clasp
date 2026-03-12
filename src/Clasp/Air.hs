{-# LANGUAGE OverloadedStrings #-}

module Clasp.Air
  ( AirAttr (..)
  , AirModule (..)
  , AirNode (..)
  , AirNodeId (..)
  , airModuleNodeCount
  , buildAirModule
  , renderAirModuleJson
  ) where

import Data.Aeson
  ( ToJSON (toJSON)
  , Value (Bool, String)
  , object
  , (.=)
  )
import Data.Aeson.Text (encodeToLazyText)
import Data.Text (Text, pack)
import qualified Data.Text.Lazy as LT
import Clasp.Core
  ( CoreDecl (..)
  , CoreExpr (..)
  , CoreMatchBranch (..)
  , CoreModule (..)
  , CoreParam (..)
  , CorePolicyDecl (..)
  , CorePattern (..)
  , CorePatternBinder (..)
  , CoreProjectionDecl (..)
  , CoreRecordField (..)
  , coreExprType
  )
import Clasp.Syntax
  ( ConstructorDecl (..)
  , ForeignDecl (..)
  , ModuleName (..)
  , PolicyClassificationDecl (..)
  , PolicyDecl (..)
  , ProjectionDecl (..)
  , ProjectionFieldDecl (..)
  , RecordDecl (..)
  , RecordFieldDecl (..)
  , RouteDecl (..)
  , RouteMethod (..)
  , SourceSpan
  , Type
  , TypeDecl (..)
  , renderType
  )

newtype AirNodeId = AirNodeId
  { unAirNodeId :: Text
  }
  deriving (Eq, Ord, Show)

data AirAttr
  = AirAttrText Text
  | AirAttrTexts [Text]
  | AirAttrInt Integer
  | AirAttrBool Bool
  | AirAttrNode AirNodeId
  | AirAttrNodes [AirNodeId]
  deriving (Eq, Show)

data AirNode = AirNode
  { airNodeId :: AirNodeId
  , airNodeKind :: Text
  , airNodeSpan :: Maybe SourceSpan
  , airNodeType :: Maybe Type
  , airNodeAttrs :: [(Text, AirAttr)]
  }
  deriving (Eq, Show)

data AirModule = AirModule
  { airModuleName :: ModuleName
  , airModuleRootIds :: [AirNodeId]
  , airModuleNodes :: [AirNode]
  }
  deriving (Eq, Show)

buildAirModule :: CoreModule -> AirModule
buildAirModule modl =
  AirModule
    { airModuleName = coreModuleName modl
    , airModuleRootIds = fmap airNodeId topLevelNodes
    , airModuleNodes = topLevelNodes <> nestedNodes
    }
  where
    typeNodes = concatMap buildTypeDeclNodes (coreModuleTypeDecls modl)
    recordNodes = concatMap buildRecordDeclNodes (coreModuleRecordDecls modl)
    policyNodes = concatMap buildPolicyDeclNodes (coreModulePolicyDecls modl)
    projectionNodes = concatMap buildProjectionDeclNodes (coreModuleProjectionDecls modl)
    foreignNodes = fmap buildForeignDeclNode (coreModuleForeignDecls modl)
    routeNodes = fmap buildRouteDeclNode (coreModuleRouteDecls modl)
    declGraphs = fmap buildDeclGraph (coreModuleDecls modl)
    topLevelNodes =
      typeNodes
        <> recordNodes
        <> policyNodes
        <> projectionNodes
        <> foreignNodes
        <> routeNodes
        <> fmap declGraphDeclNode declGraphs
    nestedNodes = concatMap declGraphNestedNodes declGraphs

airModuleNodeCount :: AirModule -> Int
airModuleNodeCount = length . airModuleNodes

renderAirModuleJson :: AirModule -> LT.Text
renderAirModuleJson = encodeToLazyText

buildTypeDeclNodes :: TypeDecl -> [AirNode]
buildTypeDeclNodes typeDecl =
  AirNode
    { airNodeId = typeDeclId (typeDeclName typeDecl)
    , airNodeKind = "typeDecl"
    , airNodeSpan = Just (typeDeclSpan typeDecl)
    , airNodeType = Nothing
    , airNodeAttrs =
        [ ("name", AirAttrText (typeDeclName typeDecl))
        , ("constructors", AirAttrNodes (fmap (\constructorDecl -> constructorDeclId (typeDeclName typeDecl) (constructorDeclName constructorDecl)) (typeDeclConstructors typeDecl)))
        ]
    }
    : fmap (buildConstructorDeclNode (typeDeclName typeDecl)) (typeDeclConstructors typeDecl)

buildConstructorDeclNode :: Text -> ConstructorDecl -> AirNode
buildConstructorDeclNode typeName constructorDecl =
  AirNode
    { airNodeId = constructorDeclId typeName (constructorDeclName constructorDecl)
    , airNodeKind = "constructorDecl"
    , airNodeSpan = Just (constructorDeclSpan constructorDecl)
    , airNodeType = Nothing
    , airNodeAttrs =
        [ ("name", AirAttrText (constructorDeclName constructorDecl))
        , ("typeName", AirAttrText typeName)
        , ("fieldTypes", AirAttrTexts (fmap renderType (constructorDeclFields constructorDecl)))
        ]
    }

buildRecordDeclNodes :: RecordDecl -> [AirNode]
buildRecordDeclNodes recordDecl =
  AirNode
    { airNodeId = recordDeclId (recordDeclName recordDecl)
    , airNodeKind = "recordDecl"
    , airNodeSpan = Just (recordDeclSpan recordDecl)
    , airNodeType = Nothing
    , airNodeAttrs =
        [ ("name", AirAttrText (recordDeclName recordDecl))
        , ("fields", AirAttrNodes (fmap (\fieldDecl -> recordFieldDeclId (recordDeclName recordDecl) (recordFieldDeclName fieldDecl)) (recordDeclFields recordDecl)))
        ]
    }
    : fmap (buildRecordFieldDeclNode (recordDeclName recordDecl)) (recordDeclFields recordDecl)

buildRecordFieldDeclNode :: Text -> RecordFieldDecl -> AirNode
buildRecordFieldDeclNode recordName fieldDecl =
  AirNode
    { airNodeId = recordFieldDeclId recordName (recordFieldDeclName fieldDecl)
    , airNodeKind = "recordFieldDecl"
    , airNodeSpan = Just (recordFieldDeclSpan fieldDecl)
    , airNodeType = Just (recordFieldDeclType fieldDecl)
    , airNodeAttrs =
        [ ("name", AirAttrText (recordFieldDeclName fieldDecl))
        , ("recordName", AirAttrText recordName)
        , ("classification", AirAttrText (recordFieldDeclClassification fieldDecl))
        ]
    }

buildPolicyDeclNodes :: CorePolicyDecl -> [AirNode]
buildPolicyDeclNodes corePolicyDecl =
  policyNode : classificationNodes
  where
    policyDecl = corePolicySourceDecl corePolicyDecl
    classificationIds =
      fmap
        (\classificationDecl -> policyClassificationDeclId (policyDeclName policyDecl) (policyClassificationDeclName classificationDecl))
        (policyDeclAllowedClassifications policyDecl)
    policyNode =
      AirNode
        { airNodeId = policyDeclId (policyDeclName policyDecl)
        , airNodeKind = "policyDecl"
        , airNodeSpan = Just (policyDeclSpan policyDecl)
        , airNodeType = Nothing
        , airNodeAttrs =
            [ ("name", AirAttrText (policyDeclName policyDecl))
            , ("allowedClassifications", AirAttrNodes classificationIds)
            ]
        }
    classificationNodes =
      fmap (buildPolicyClassificationDeclNode (policyDeclName policyDecl)) (policyDeclAllowedClassifications policyDecl)

buildPolicyClassificationDeclNode :: Text -> PolicyClassificationDecl -> AirNode
buildPolicyClassificationDeclNode policyName classificationDecl =
  AirNode
    { airNodeId = policyClassificationDeclId policyName (policyClassificationDeclName classificationDecl)
    , airNodeKind = "policyClassificationDecl"
    , airNodeSpan = Just (policyClassificationDeclSpan classificationDecl)
    , airNodeType = Nothing
    , airNodeAttrs =
        [ ("name", AirAttrText (policyClassificationDeclName classificationDecl))
        , ("policyName", AirAttrText policyName)
        ]
    }

buildProjectionDeclNodes :: CoreProjectionDecl -> [AirNode]
buildProjectionDeclNodes coreProjectionDecl =
  projectionNode : fieldNodes
  where
    projectionDecl = coreProjectionSourceDecl coreProjectionDecl
    recordDecl = coreProjectionRecordDecl coreProjectionDecl
    fieldIds =
      fmap
        (\fieldDecl -> projectionFieldDeclId (projectionDeclName projectionDecl) (projectionFieldDeclName fieldDecl))
        (projectionDeclFields projectionDecl)
    projectionNode =
      AirNode
        { airNodeId = projectionDeclId (projectionDeclName projectionDecl)
        , airNodeKind = "projectionDecl"
        , airNodeSpan = Just (projectionDeclSpan projectionDecl)
        , airNodeType = Nothing
        , airNodeAttrs =
            [ ("name", AirAttrText (projectionDeclName projectionDecl))
            , ("sourceRecordName", AirAttrText (projectionDeclSourceRecordName projectionDecl))
            , ("policyName", AirAttrText (projectionDeclPolicyName projectionDecl))
            , ("recordDecl", AirAttrNode (recordDeclId (recordDeclName recordDecl)))
            , ("fields", AirAttrNodes fieldIds)
            ]
        }
    fieldNodes =
      fmap (buildProjectionFieldDeclNode projectionDecl recordDecl) (projectionDeclFields projectionDecl)

buildProjectionFieldDeclNode :: ProjectionDecl -> RecordDecl -> ProjectionFieldDecl -> AirNode
buildProjectionFieldDeclNode projectionDecl recordDecl fieldDecl =
  AirNode
    { airNodeId = projectionFieldDeclId (projectionDeclName projectionDecl) (projectionFieldDeclName fieldDecl)
    , airNodeKind = "projectionFieldDecl"
    , airNodeSpan = Just (projectionFieldDeclSpan fieldDecl)
    , airNodeType = Nothing
    , airNodeAttrs =
        [ ("name", AirAttrText (projectionFieldDeclName fieldDecl))
        , ("projectionName", AirAttrText (projectionDeclName projectionDecl))
        , ("recordFieldDecl", AirAttrNode (recordFieldDeclId (recordDeclName recordDecl) (projectionFieldDeclName fieldDecl)))
        ]
    }

buildForeignDeclNode :: ForeignDecl -> AirNode
buildForeignDeclNode foreignDecl =
  AirNode
    { airNodeId = foreignDeclId (foreignDeclName foreignDecl)
    , airNodeKind = "foreignDecl"
    , airNodeSpan = Just (foreignDeclSpan foreignDecl)
    , airNodeType = Just (foreignDeclType foreignDecl)
    , airNodeAttrs =
        [ ("name", AirAttrText (foreignDeclName foreignDecl))
        , ("runtimeName", AirAttrText (foreignDeclRuntimeName foreignDecl))
        ]
    }

buildRouteDeclNode :: RouteDecl -> AirNode
buildRouteDeclNode routeDecl =
  AirNode
    { airNodeId = routeDeclId (routeDeclName routeDecl)
    , airNodeKind = "routeDecl"
    , airNodeSpan = Just (routeDeclSpan routeDecl)
    , airNodeType = Nothing
    , airNodeAttrs =
        [ ("name", AirAttrText (routeDeclName routeDecl))
        , ("method", AirAttrText (renderRouteMethod routeDecl))
        , ("path", AirAttrText (routeDeclPath routeDecl))
        , ("requestType", AirAttrText (routeDeclRequestType routeDecl))
        , ("responseType", AirAttrText (routeDeclResponseType routeDecl))
        , ("handlerName", AirAttrText (routeDeclHandlerName routeDecl))
        ]
    }

data DeclGraph = DeclGraph
  { declGraphDeclNode :: AirNode
  , declGraphNestedNodes :: [AirNode]
  }

buildDeclGraph :: CoreDecl -> DeclGraph
buildDeclGraph decl =
  DeclGraph
    { declGraphDeclNode =
        AirNode
          { airNodeId = declId (coreDeclName decl)
          , airNodeKind = "decl"
          , airNodeSpan = Nothing
          , airNodeType = Just (coreDeclType decl)
          , airNodeAttrs =
              [ ("name", AirAttrText (coreDeclName decl))
              , ("params", AirAttrNodes paramIds)
              , ("body", AirAttrNode bodyId)
              ]
          }
    , declGraphNestedNodes = paramNodes <> exprNodes
    }
  where
    paramIds = fmap (\param -> paramId (coreDeclName decl) (coreParamName param)) (coreDeclParams decl)
    paramNodes = fmap (buildParamNode (coreDeclName decl)) (coreDeclParams decl)
    bodyId = exprId (coreDeclName decl) "body"
    exprNodes = buildExprGraph bodyId (coreDeclBody decl)

buildParamNode :: Text -> CoreParam -> AirNode
buildParamNode declName param =
  AirNode
    { airNodeId = paramId declName (coreParamName param)
    , airNodeKind = "param"
    , airNodeSpan = Nothing
    , airNodeType = Just (coreParamType param)
    , airNodeAttrs = [("name", AirAttrText (coreParamName param))]
    }

buildExprGraph :: AirNodeId -> CoreExpr -> [AirNode]
buildExprGraph nodeId expr =
  exprNode : childNodes
  where
    (attrs, childNodes) =
      case expr of
        CVar _ _ name ->
          ([("name", AirAttrText name)], [])
        CInt _ value ->
          ([("value", AirAttrInt value)], [])
        CString _ value ->
          ([("value", AirAttrText value)], [])
        CBool _ value ->
          ([("value", AirAttrBool value)], [])
        CPage _ title body ->
          let titleId = exprChildId "title"
              bodyId = exprChildId "body"
           in ( [("title", AirAttrNode titleId), ("body", AirAttrNode bodyId)]
              , buildExprGraph titleId title <> buildExprGraph bodyId body
              )
        CViewEmpty _ ->
          ([], [])
        CViewText _ value ->
          let valueId = exprChildId "value"
           in ([("value", AirAttrNode valueId)], buildExprGraph valueId value)
        CViewAppend _ left right ->
          let leftId = exprChildId "left"
              rightId = exprChildId "right"
           in ( [("left", AirAttrNode leftId), ("right", AirAttrNode rightId)]
              , buildExprGraph leftId left <> buildExprGraph rightId right
              )
        CViewElement _ tag child ->
          let childId = exprChildId "child"
           in ([("tag", AirAttrText tag), ("child", AirAttrNode childId)], buildExprGraph childId child)
        CViewStyled _ styleRef child ->
          let childId = exprChildId "child"
           in ([("styleRef", AirAttrText styleRef), ("child", AirAttrNode childId)], buildExprGraph childId child)
        CViewLink _ href child ->
          let childId = exprChildId "child"
           in ([("href", AirAttrText href), ("child", AirAttrNode childId)], buildExprGraph childId child)
        CViewForm _ method action child ->
          let childId = exprChildId "child"
           in ([("method", AirAttrText method), ("action", AirAttrText action), ("child", AirAttrNode childId)], buildExprGraph childId child)
        CViewInput _ fieldName inputKind value ->
          let valueId = exprChildId "value"
           in ([("fieldName", AirAttrText fieldName), ("inputKind", AirAttrText inputKind), ("value", AirAttrNode valueId)], buildExprGraph valueId value)
        CViewSubmit _ label ->
          let labelId = exprChildId "label"
           in ([("label", AirAttrNode labelId)], buildExprGraph labelId label)
        CCall _ _ fn args ->
          let calleeId = exprChildId "callee"
              argIds = fmap (\index -> childSegmentId nodeId ("arg" <> showText index)) [(0 :: Int) .. length args - 1]
              argNodes = concat (zipWith buildExprGraph argIds args)
           in ( [("callee", AirAttrNode calleeId), ("args", AirAttrNodes argIds)]
              , buildExprGraph calleeId fn <> argNodes
              )
        CMatch _ _ subject branches ->
          let subjectId = exprChildId "subject"
              branchIds = fmap (\index -> childSegmentId nodeId ("branch" <> showText index)) [(0 :: Int) .. length branches - 1]
              branchNodes = concat (zipWith buildMatchBranchGraph branchIds branches)
           in ( [("subject", AirAttrNode subjectId), ("branches", AirAttrNodes branchIds)]
              , buildExprGraph subjectId subject <> branchNodes
              )
        CRecord _ _ recordName fields ->
          let fieldIds = fmap (\field -> childSegmentId nodeId ("field:" <> coreRecordFieldName field)) fields
              fieldNodes = concat (zipWith buildRecordFieldGraph fieldIds fields)
           in ([("recordName", AirAttrText recordName), ("fields", AirAttrNodes fieldIds)], fieldNodes)
        CFieldAccess _ _ subject fieldName ->
          let subjectId = exprChildId "subject"
           in ([("subject", AirAttrNode subjectId), ("fieldName", AirAttrText fieldName)], buildExprGraph subjectId subject)
        CDecodeJson _ targetType rawJson ->
          let rawJsonId = exprChildId "rawJson"
           in ([("targetType", AirAttrText (renderType targetType)), ("rawJson", AirAttrNode rawJsonId)], buildExprGraph rawJsonId rawJson)
        CEncodeJson _ value ->
          let valueId = exprChildId "value"
           in ([("value", AirAttrNode valueId)], buildExprGraph valueId value)
    exprNode =
      AirNode
        { airNodeId = nodeId
        , airNodeKind = exprKind expr
        , airNodeSpan = Just (exprSpan expr)
        , airNodeType = Just (coreExprType expr)
        , airNodeAttrs = attrs
        }
    exprChildId = childSegmentId nodeId

buildMatchBranchGraph :: AirNodeId -> CoreMatchBranch -> [AirNode]
buildMatchBranchGraph nodeId branch =
  branchNode : patternNodes <> bodyNodes
  where
    patternId = childSegmentId nodeId "pattern"
    bodyId = childSegmentId nodeId "body"
    branchNode =
      AirNode
        { airNodeId = nodeId
        , airNodeKind = "matchBranch"
        , airNodeSpan = Just (coreMatchBranchSpan branch)
        , airNodeType = Just (coreExprType (coreMatchBranchBody branch))
        , airNodeAttrs =
            [ ("pattern", AirAttrNode patternId)
            , ("body", AirAttrNode bodyId)
            ]
        }
    patternNodes = buildPatternGraph patternId (coreMatchBranchPattern branch)
    bodyNodes = buildExprGraph bodyId (coreMatchBranchBody branch)

buildPatternGraph :: AirNodeId -> CorePattern -> [AirNode]
buildPatternGraph nodeId pattern' =
  case pattern' of
    CConstructorPattern span' constructorName binders ->
      let binderIds = fmap (\index -> childSegmentId nodeId ("binder" <> showText index)) [(0 :: Int) .. length binders - 1]
          binderNodes = concat (zipWith buildPatternBinderGraph binderIds binders)
       in [ AirNode
              { airNodeId = nodeId
              , airNodeKind = "constructorPattern"
              , airNodeSpan = Just span'
              , airNodeType = Nothing
              , airNodeAttrs =
                  [ ("constructorName", AirAttrText constructorName)
                  , ("binders", AirAttrNodes binderIds)
                  ]
              }
          ]
            <> binderNodes

buildPatternBinderGraph :: AirNodeId -> CorePatternBinder -> [AirNode]
buildPatternBinderGraph nodeId binder =
  [ AirNode
      { airNodeId = nodeId
      , airNodeKind = "patternBinder"
      , airNodeSpan = Just (corePatternBinderSpan binder)
      , airNodeType = Just (corePatternBinderType binder)
      , airNodeAttrs = [("name", AirAttrText (corePatternBinderName binder))]
      }
  ]

buildRecordFieldGraph :: AirNodeId -> CoreRecordField -> [AirNode]
buildRecordFieldGraph nodeId field =
  fieldNode : valueNodes
  where
    valueId = childSegmentId nodeId "value"
    fieldNode =
      AirNode
        { airNodeId = nodeId
        , airNodeKind = "recordField"
        , airNodeSpan = Nothing
        , airNodeType = Just (coreExprType (coreRecordFieldValue field))
        , airNodeAttrs =
            [ ("name", AirAttrText (coreRecordFieldName field))
            , ("value", AirAttrNode valueId)
            ]
        }
    valueNodes = buildExprGraph valueId (coreRecordFieldValue field)

exprKind :: CoreExpr -> Text
exprKind expr =
  case expr of
    CVar {} -> "var"
    CInt {} -> "int"
    CString {} -> "string"
    CBool {} -> "bool"
    CPage {} -> "page"
    CViewEmpty {} -> "viewEmpty"
    CViewText {} -> "viewText"
    CViewAppend {} -> "viewAppend"
    CViewElement {} -> "viewElement"
    CViewStyled {} -> "viewStyled"
    CViewLink {} -> "viewLink"
    CViewForm {} -> "viewForm"
    CViewInput {} -> "viewInput"
    CViewSubmit {} -> "viewSubmit"
    CCall {} -> "call"
    CMatch {} -> "match"
    CRecord {} -> "record"
    CFieldAccess {} -> "fieldAccess"
    CDecodeJson {} -> "decodeJson"
    CEncodeJson {} -> "encodeJson"

exprSpan :: CoreExpr -> SourceSpan
exprSpan expr =
  case expr of
    CVar span' _ _ -> span'
    CInt span' _ -> span'
    CString span' _ -> span'
    CBool span' _ -> span'
    CPage span' _ _ -> span'
    CViewEmpty span' -> span'
    CViewText span' _ -> span'
    CViewAppend span' _ _ -> span'
    CViewElement span' _ _ -> span'
    CViewStyled span' _ _ -> span'
    CViewLink span' _ _ -> span'
    CViewForm span' _ _ _ -> span'
    CViewInput span' _ _ _ -> span'
    CViewSubmit span' _ -> span'
    CCall span' _ _ _ -> span'
    CMatch span' _ _ _ -> span'
    CRecord span' _ _ _ -> span'
    CFieldAccess span' _ _ _ -> span'
    CDecodeJson span' _ _ -> span'
    CEncodeJson span' _ -> span'

typeDeclId :: Text -> AirNodeId
typeDeclId name = AirNodeId ("type:" <> name)

constructorDeclId :: Text -> Text -> AirNodeId
constructorDeclId typeName constructorName =
  AirNodeId ("constructor:" <> typeName <> ":" <> constructorName)

recordDeclId :: Text -> AirNodeId
recordDeclId name = AirNodeId ("record:" <> name)

recordFieldDeclId :: Text -> Text -> AirNodeId
recordFieldDeclId recordName fieldName =
  AirNodeId ("record-field:" <> recordName <> ":" <> fieldName)

foreignDeclId :: Text -> AirNodeId
foreignDeclId name = AirNodeId ("foreign:" <> name)

policyDeclId :: Text -> AirNodeId
policyDeclId name = AirNodeId ("policy:" <> name)

policyClassificationDeclId :: Text -> Text -> AirNodeId
policyClassificationDeclId policyName classificationName =
  AirNodeId ("policy-classification:" <> policyName <> ":" <> classificationName)

projectionDeclId :: Text -> AirNodeId
projectionDeclId name = AirNodeId ("projection:" <> name)

projectionFieldDeclId :: Text -> Text -> AirNodeId
projectionFieldDeclId projectionName fieldName =
  AirNodeId ("projection-field:" <> projectionName <> ":" <> fieldName)

routeDeclId :: Text -> AirNodeId
routeDeclId name = AirNodeId ("route:" <> name)

declId :: Text -> AirNodeId
declId name = AirNodeId ("decl:" <> name)

paramId :: Text -> Text -> AirNodeId
paramId declName name = AirNodeId ("param:" <> declName <> ":" <> name)

exprId :: Text -> Text -> AirNodeId
exprId declName label = AirNodeId ("expr:" <> declName <> ":" <> label)

childSegmentId :: AirNodeId -> Text -> AirNodeId
childSegmentId (AirNodeId parent) segment = AirNodeId (parent <> "." <> segment)

renderRouteMethod :: RouteDecl -> Text
renderRouteMethod routeDecl =
  case routeDeclMethod routeDecl of
    RouteGet ->
      "GET"
    RoutePost ->
      "POST"

showText :: Show a => a -> Text
showText = pack . show

instance ToJSON AirNodeId where
  toJSON = String . unAirNodeId

instance ToJSON AirAttr where
  toJSON attr =
    case attr of
      AirAttrText value ->
        String value
      AirAttrTexts values ->
        toJSON values
      AirAttrInt value ->
        toJSON value
      AirAttrBool value ->
        Bool value
      AirAttrNode refId ->
        object ["ref" .= refId]
      AirAttrNodes refIds ->
        toJSON (fmap (\refId -> object ["ref" .= refId]) refIds)

instance ToJSON AirNode where
  toJSON node =
    object
      [ "id" .= airNodeId node
      , "kind" .= airNodeKind node
      , "span" .= airNodeSpan node
      , "type" .= fmap renderType (airNodeType node)
      , "attrs" .= fmap (\(label, value) -> object ["name" .= label, "value" .= value]) (airNodeAttrs node)
      ]

instance ToJSON AirModule where
  toJSON airModule =
    object
      [ "format" .= ("clasp-air-v1" :: Text)
      , "module" .= unModuleName (airModuleName airModule)
      , "nodeCount" .= airModuleNodeCount airModule
      , "roots" .= airModuleRootIds airModule
      , "nodes" .= airModuleNodes airModule
      ]
