{-# LANGUAGE OverloadedStrings #-}

module Clasp.Native
  ( NativeAbi (..)
  , NativeAllocationModel (..)
  , NativeAllocationRegion (..)
  , NativeBinaryCodec (..)
  , NativeBuiltinLayout (..)
  , NativeCompareOp (..)
  , NativeConstructorLayout (..)
  , NativeDecl (..)
  , NativeFieldLayout (..)
  , NativeJsonCodec (..)
  , NativeBoundaryContract (..)
  , NativeRouteBoundary (..)
  , NativeHookBoundary (..)
  , NativeToolServerBoundary (..)
  , NativeToolBoundary (..)
  , NativeWorkflowBoundary (..)
  , NativeExpr (..)
  , NativeField (..)
  , NativeFunction (..)
  , NativeGlobal (..)
  , NativeIntrinsic (..)
  , NativeLayoutStorage (..)
  , NativeLiteral (..)
  , NativeMatchBranch (..)
  , NativeModule (..)
  , NativeObjectKind (..)
  , NativeObjectLayout (..)
  , NativeOwnershipRule (..)
  , NativeMemoryStrategy (..)
  , NativeMutability (..)
  , NativeRecordLayout (..)
  , NativeRuntime (..)
  , NativeRuntimeBinding (..)
  , NativeRootDiscoveryRule (..)
  , NativeServiceTransport (..)
  , NativeSlotLayout (..)
  , NativeLifetimeInvariant (..)
  , NativeVariantLayout (..)
  , buildNativeModule
  , renderNativeModule
  ) where

import Data.Char (isAlphaNum, isUpper, toLower)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Clasp.Lower
  ( LowerDecl (..)
  , LowerExpr (..)
  , LowerMatchBranch (..)
  , LowerModule (..)
  , LowerRecordField (..)
  , LowerRoute (..)
  , LowerRouteContract (..)
  )
import Clasp.Syntax
  ( ConstructorDecl (..)
  , ForeignDecl (..)
  , HookDecl (..)
  , HookTriggerDecl (..)
  , ModuleName
  , RecordDecl (..)
  , RecordFieldDecl (..)
  , ToolDecl (..)
  , ToolServerDecl (..)
  , Type (..)
  , TypeDecl (..)
  , WorkflowDecl (..)
  , renderType
  , splitModuleName
  )

data NativeModule = NativeModule
  { nativeModuleName :: ModuleName
  , nativeModuleExports :: [Text]
  , nativeModuleAbi :: NativeAbi
  , nativeModuleRuntime :: NativeRuntime
  , nativeModuleDecls :: [NativeDecl]
  }
  deriving (Eq, Show)

data NativeAbi = NativeAbi
  { nativeAbiVersion :: Text
  , nativeAbiWordBytes :: Int
  , nativeAbiMemoryStrategy :: NativeMemoryStrategy
  , nativeAbiAllocationModel :: NativeAllocationModel
  , nativeAbiOwnershipRules :: [NativeOwnershipRule]
  , nativeAbiRootDiscoveryRules :: [NativeRootDiscoveryRule]
  , nativeAbiLifetimeInvariants :: [NativeLifetimeInvariant]
  , nativeAbiBuiltinLayouts :: [NativeBuiltinLayout]
  , nativeAbiRecordLayouts :: [NativeRecordLayout]
  , nativeAbiVariantLayouts :: [NativeVariantLayout]
  , nativeAbiObjectLayouts :: [NativeObjectLayout]
  }
  deriving (Eq, Show)

data NativeMemoryStrategy
  = NativeReferenceCounting
  deriving (Eq, Show)

data NativeAllocationRegion
  = NativeStackRegion
  | NativeHeapRegion
  | NativeStaticRegion
  deriving (Eq, Show)

data NativeAllocationModel = NativeAllocationModel
  { nativeAllocationImmediateRegion :: NativeAllocationRegion
  , nativeAllocationHandleRegion :: NativeAllocationRegion
  , nativeAllocationGlobalRegion :: NativeAllocationRegion
  }
  deriving (Eq, Show)

data NativeOwnershipRule
  = NativeCallerOwnsReturns
  | NativeCalleeBorrowsArguments
  | NativeAggregatesRetainHandleFields
  | NativeGlobalsAreStaticRoots
  deriving (Eq, Show)

data NativeRootDiscoveryRule
  = NativeDiscoverStaticRootsFromGlobals
  | NativeDiscoverStackRootsFromHandleSlots
  | NativeDiscoverHeapRootsFromObjectLayouts
  deriving (Eq, Show)

data NativeLifetimeInvariant
  = NativeHeapObjectsCarryLayoutAndRetainHeaders
  | NativeOnlyDeclaredRootOffsetsRetainChildren
  | NativeReleaseTraversesRootOffsetsBeforeFree
  | NativeBorrowedHandlesDoNotMutateRetainCounts
  deriving (Eq, Show)

data NativeLayoutStorage
  = NativeImmediateStorage
  | NativeHandleStorage
  deriving (Eq, Show)

data NativeBuiltinLayout = NativeBuiltinLayout
  { nativeBuiltinLayoutName :: Text
  , nativeBuiltinLayoutStorage :: NativeLayoutStorage
  , nativeBuiltinLayoutWordCount :: Int
  }
  deriving (Eq, Show)

data NativeSlotLayout = NativeSlotLayout
  { nativeSlotLayoutName :: Text
  , nativeSlotLayoutType :: Type
  , nativeSlotLayoutStorage :: NativeLayoutStorage
  , nativeSlotLayoutWordOffset :: Int
  , nativeSlotLayoutWordCount :: Int
  }
  deriving (Eq, Show)

data NativeFieldLayout = NativeFieldLayout
  { nativeFieldLayoutName :: Text
  , nativeFieldLayoutType :: Type
  , nativeFieldLayoutStorage :: NativeLayoutStorage
  , nativeFieldLayoutWordOffset :: Int
  , nativeFieldLayoutWordCount :: Int
  }
  deriving (Eq, Show)

data NativeRecordLayout = NativeRecordLayout
  { nativeRecordLayoutName :: Text
  , nativeRecordLayoutWordCount :: Int
  , nativeRecordLayoutFields :: [NativeFieldLayout]
  }
  deriving (Eq, Show)

data NativeObjectKind
  = NativeRecordObject
  | NativeVariantObject
  deriving (Eq, Show)

data NativeObjectLayout = NativeObjectLayout
  { nativeObjectLayoutName :: Text
  , nativeObjectLayoutKind :: NativeObjectKind
  , nativeObjectLayoutHeaderWords :: Int
  , nativeObjectLayoutWordCount :: Int
  , nativeObjectLayoutRootOffsets :: [Int]
  }
  deriving (Eq, Show)

data NativeConstructorLayout = NativeConstructorLayout
  { nativeConstructorLayoutName :: Text
  , nativeConstructorLayoutTagWord :: Int
  , nativeConstructorLayoutPayloadWords :: Int
  , nativeConstructorLayoutWordCount :: Int
  , nativeConstructorLayoutPayloads :: [NativeSlotLayout]
  }
  deriving (Eq, Show)

data NativeVariantLayout = NativeVariantLayout
  { nativeVariantLayoutName :: Text
  , nativeVariantLayoutTagWord :: Int
  , nativeVariantLayoutMaxPayloadWords :: Int
  , nativeVariantLayoutWordCount :: Int
  , nativeVariantLayoutConstructors :: [NativeConstructorLayout]
  }
  deriving (Eq, Show)

data NativeRuntime = NativeRuntime
  { nativeRuntimeProfile :: Text
  , nativeRuntimeArtifacts :: [Text]
  , nativeRuntimeMemorySymbols :: [Text]
  , nativeRuntimeBindings :: [NativeRuntimeBinding]
  , nativeRuntimeJsonCodecs :: [NativeJsonCodec]
  , nativeRuntimeBinaryCodecs :: [NativeBinaryCodec]
  , nativeRuntimeBoundaryContracts :: [NativeBoundaryContract]
  , nativeRuntimeServiceTransports :: [NativeServiceTransport]
  }
  deriving (Eq, Show)

data NativeJsonCodec = NativeJsonCodec
  { nativeJsonCodecType :: Type
  , nativeJsonCodecEncodeSymbol :: Text
  , nativeJsonCodecDecodeSymbol :: Text
  }
  deriving (Eq, Show)

data NativeBinaryCodec = NativeBinaryCodec
  { nativeBinaryCodecType :: Type
  , nativeBinaryCodecEncodeSymbol :: Text
  , nativeBinaryCodecDecodeSymbol :: Text
  , nativeBinaryCodecFraming :: Text
  }
  deriving (Eq, Show)

data NativeBoundaryContract
  = NativeRouteContract NativeRouteBoundary
  | NativeHookContract NativeHookBoundary
  | NativeToolServerContract NativeToolServerBoundary
  | NativeToolContract NativeToolBoundary
  | NativeWorkflowContract NativeWorkflowBoundary
  deriving (Eq, Show)

data NativeRouteBoundary = NativeRouteBoundary
  { nativeRouteBoundaryName :: Text
  , nativeRouteBoundaryIdentity :: Text
  , nativeRouteBoundaryMethod :: Text
  , nativeRouteBoundaryPath :: Text
  , nativeRouteBoundaryRequestType :: Text
  , nativeRouteBoundaryResponseType :: Text
  , nativeRouteBoundaryResponseKind :: Text
  , nativeRouteBoundaryEncodeSymbol :: Text
  , nativeRouteBoundaryDecodeSymbol :: Text
  }
  deriving (Eq, Show)

data NativeHookBoundary = NativeHookBoundary
  { nativeHookBoundaryName :: Text
  , nativeHookBoundaryIdentity :: Text
  , nativeHookBoundaryEvent :: Text
  , nativeHookBoundaryRequestType :: Text
  , nativeHookBoundaryResponseType :: Text
  , nativeHookBoundaryHandler :: Text
  , nativeHookBoundaryEncodeSymbol :: Text
  , nativeHookBoundaryDecodeSymbol :: Text
  }
  deriving (Eq, Show)

data NativeToolServerBoundary = NativeToolServerBoundary
  { nativeToolServerBoundaryName :: Text
  , nativeToolServerBoundaryIdentity :: Text
  , nativeToolServerBoundaryProtocol :: Text
  , nativeToolServerBoundaryLocation :: Text
  , nativeToolServerBoundaryPolicy :: Text
  }
  deriving (Eq, Show)

data NativeToolBoundary = NativeToolBoundary
  { nativeToolBoundaryName :: Text
  , nativeToolBoundaryIdentity :: Text
  , nativeToolBoundaryServer :: Text
  , nativeToolBoundaryOperation :: Text
  , nativeToolBoundaryRequestType :: Text
  , nativeToolBoundaryResponseType :: Text
  , nativeToolBoundaryEncodeSymbol :: Text
  , nativeToolBoundaryDecodeSymbol :: Text
  }
  deriving (Eq, Show)

data NativeWorkflowBoundary = NativeWorkflowBoundary
  { nativeWorkflowBoundaryName :: Text
  , nativeWorkflowBoundaryIdentity :: Text
  , nativeWorkflowBoundaryStateType :: Type
  , nativeWorkflowBoundaryCheckpointSymbol :: Text
  , nativeWorkflowBoundaryRestoreSymbol :: Text
  }
  deriving (Eq, Show)

data NativeRuntimeBinding = NativeRuntimeBinding
  { nativeRuntimeBindingName :: Text
  , nativeRuntimeBindingRuntimeName :: Text
  , nativeRuntimeBindingSymbol :: Text
  , nativeRuntimeBindingType :: Type
  }
  deriving (Eq, Show)

data NativeServiceTransport = NativeServiceTransport
  { nativeServiceTransportKind :: Text
  , nativeServiceTransportName :: Text
  , nativeServiceTransportIdentity :: Text
  , nativeServiceTransportMode :: Text
  , nativeServiceTransportRequestType :: Text
  , nativeServiceTransportRequestEncodeSymbol :: Text
  , nativeServiceTransportRequestDecodeSymbol :: Text
  , nativeServiceTransportResponseType :: Text
  , nativeServiceTransportResponseEncodeSymbol :: Text
  , nativeServiceTransportResponseDecodeSymbol :: Text
  , nativeServiceTransportFraming :: Text
  }
  deriving (Eq, Show)

data NativeDecl
  = NativeGlobalDecl NativeGlobal
  | NativeFunctionDecl NativeFunction
  deriving (Eq, Show)

data NativeGlobal = NativeGlobal
  { nativeGlobalName :: Text
  , nativeGlobalBody :: NativeExpr
  }
  deriving (Eq, Show)

data NativeFunction = NativeFunction
  { nativeFunctionName :: Text
  , nativeFunctionParams :: [Text]
  , nativeFunctionBody :: NativeExpr
  }
  deriving (Eq, Show)

data NativeLiteral
  = NativeInt Integer
  | NativeString Text
  | NativeBool Bool
  deriving (Eq, Show)

data NativeCompareOp
  = NativeEqual
  | NativeNotEqual
  | NativeLessThan
  | NativeLessThanOrEqual
  | NativeGreaterThan
  | NativeGreaterThanOrEqual
  deriving (Eq, Show)

data NativeMutability
  = NativeImmutable
  | NativeMutable
  deriving (Eq, Show)

data NativeExpr
  = NativeLocal Text
  | NativeLiteralExpr NativeLiteral
  | NativeList [NativeExpr]
  | NativeReturn NativeExpr
  | NativeCompare NativeCompareOp NativeExpr NativeExpr
  | NativeLet NativeMutability Text NativeExpr NativeExpr
  | NativeAssign Text NativeExpr NativeExpr
  | NativeForEach Text NativeExpr NativeExpr NativeExpr
  | NativeIntrinsic NativeIntrinsic
  | NativeCall NativeExpr [NativeExpr]
  | NativeConstruct Text [NativeExpr]
  | NativeMatch NativeExpr [NativeMatchBranch]
  | NativeRecord Text [NativeField]
  | NativeFieldAccess Text NativeExpr Text
  deriving (Eq, Show)

data NativeIntrinsic
  = NativePageIntrinsic NativeExpr NativeExpr
  | NativeRedirectIntrinsic Text
  | NativeViewEmptyIntrinsic
  | NativeViewTextIntrinsic NativeExpr
  | NativeViewAppendIntrinsic NativeExpr NativeExpr
  | NativeViewElementIntrinsic Text NativeExpr
  | NativeViewStyledIntrinsic Text NativeExpr
  | NativeViewLinkIntrinsic LowerRouteContract Text NativeExpr
  | NativeViewFormIntrinsic LowerRouteContract Text Text NativeExpr
  | NativeViewInputIntrinsic Text Text NativeExpr
  | NativeViewSubmitIntrinsic NativeExpr
  | NativePromptMessageIntrinsic Text NativeExpr
  | NativePromptAppendIntrinsic NativeExpr NativeExpr
  | NativePromptTextIntrinsic NativeExpr
  deriving (Eq, Show)

data NativeMatchBranch = NativeMatchBranch
  { nativeMatchBranchTag :: Text
  , nativeMatchBranchBinders :: [Text]
  , nativeMatchBranchBody :: NativeExpr
  }
  deriving (Eq, Show)

data NativeField = NativeField
  { nativeFieldName :: Text
  , nativeFieldValue :: NativeExpr
  }
  deriving (Eq, Show)

buildNativeModule :: LowerModule -> NativeModule
buildNativeModule modl =
  NativeModule
    { nativeModuleName = lowerModuleName modl
    , nativeModuleExports = fmap lowerDeclName (lowerModuleDecls modl)
    , nativeModuleAbi = buildNativeAbi modl
    , nativeModuleRuntime = buildNativeRuntime modl
    , nativeModuleDecls = fmap lowerDeclToNative (lowerModuleDecls modl)
    }

renderNativeModule :: NativeModule -> Text
renderNativeModule nativeMod =
  T.unlines $
    [ "format clasp-native-ir-v1"
    , "module " <> renderModuleNameText (nativeModuleName nativeMod)
    , "exports [" <> commaSeparated (nativeModuleExports nativeMod) <> "]"
    , ""
    , "abi {"
    ]
      <> indentBlock (renderNativeAbi (nativeModuleAbi nativeMod))
      <> [ "}"
         , ""
         , "runtime {"
         ]
      <> indentBlock (renderNativeRuntime (nativeModuleRuntime nativeMod))
      <> [ "}"
         , ""
         ]
      <> concatMap renderNativeDecl (nativeModuleDecls nativeMod)

renderNativeAbi :: NativeAbi -> [Text]
renderNativeAbi abi =
  [ "version " <> nativeAbiVersion abi
  , "word_bytes " <> renderInt (nativeAbiWordBytes abi)
  , "memory_strategy " <> renderMemoryStrategy (nativeAbiMemoryStrategy abi)
  , "allocation { immediate = " <> renderAllocationRegion (nativeAllocationImmediateRegion allocation) <> ", handle = " <> renderAllocationRegion (nativeAllocationHandleRegion allocation) <> ", global = " <> renderAllocationRegion (nativeAllocationGlobalRegion allocation) <> " }"
  , "ownership_rules [" <> commaSeparated (fmap renderOwnershipRule (nativeAbiOwnershipRules abi)) <> "]"
  , "root_discovery_rules [" <> commaSeparated (fmap renderRootDiscoveryRule (nativeAbiRootDiscoveryRules abi)) <> "]"
  , "lifetime_invariants [" <> commaSeparated (fmap renderLifetimeInvariant (nativeAbiLifetimeInvariants abi)) <> "]"
  ]
    <> fmap renderBuiltinLayout (nativeAbiBuiltinLayouts abi)
    <> fmap renderRecordLayout (nativeAbiRecordLayouts abi)
    <> fmap renderVariantLayout (nativeAbiVariantLayouts abi)
    <> fmap renderObjectLayout (nativeAbiObjectLayouts abi)
  where
    allocation = nativeAbiAllocationModel abi

renderNativeDecl :: NativeDecl -> [Text]
renderNativeDecl decl =
  case decl of
    NativeGlobalDecl globalDecl ->
      [ "global " <> nativeGlobalName globalDecl <> " = " <> renderNativeExpr (nativeGlobalBody globalDecl)
      , ""
      ]
    NativeFunctionDecl functionDecl ->
      [ "function " <> nativeFunctionName functionDecl <> "(" <> commaSeparated (nativeFunctionParams functionDecl) <> ") = " <> renderNativeExpr (nativeFunctionBody functionDecl)
      , ""
      ]

renderBuiltinLayout :: NativeBuiltinLayout -> Text
renderBuiltinLayout layout =
  "builtin_layout " <> nativeBuiltinLayoutName layout <> " { storage = " <> renderLayoutStorage (nativeBuiltinLayoutStorage layout) <> ", words = " <> renderInt (nativeBuiltinLayoutWordCount layout) <> " }"

renderRecordLayout :: NativeRecordLayout -> Text
renderRecordLayout layout =
  "record_layout " <> nativeRecordLayoutName layout <> " { words = " <> renderInt (nativeRecordLayoutWordCount layout) <> ", fields = [" <> commaSeparated (fmap renderFieldLayout (nativeRecordLayoutFields layout)) <> "] }"

renderVariantLayout :: NativeVariantLayout -> Text
renderVariantLayout layout =
  "variant_layout " <> nativeVariantLayoutName layout <> " { tag_word = " <> renderInt (nativeVariantLayoutTagWord layout) <> ", max_payload_words = " <> renderInt (nativeVariantLayoutMaxPayloadWords layout) <> ", words = " <> renderInt (nativeVariantLayoutWordCount layout) <> ", constructors = [" <> commaSeparated (fmap renderConstructorLayout (nativeVariantLayoutConstructors layout)) <> "] }"

renderObjectLayout :: NativeObjectLayout -> Text
renderObjectLayout layout =
  "object_layout " <> nativeObjectLayoutName layout <> " { kind = " <> renderObjectKind (nativeObjectLayoutKind layout) <> ", header_words = " <> renderInt (nativeObjectLayoutHeaderWords layout) <> ", words = " <> renderInt (nativeObjectLayoutWordCount layout) <> ", roots = [" <> commaSeparated (fmap renderInt (nativeObjectLayoutRootOffsets layout)) <> "] }"

renderNativeRuntime :: NativeRuntime -> [Text]
renderNativeRuntime runtime =
  [ "profile " <> nativeRuntimeProfile runtime
  , "artifacts [" <> commaSeparated (fmap renderQuoted (nativeRuntimeArtifacts runtime)) <> "]"
  , "memory_symbols [" <> commaSeparated (nativeRuntimeMemorySymbols runtime) <> "]"
  , "bindings [" <> commaSeparated (fmap renderRuntimeBinding (nativeRuntimeBindings runtime)) <> "]"
  , "json_codecs [" <> commaSeparated (fmap renderJsonCodec (nativeRuntimeJsonCodecs runtime)) <> "]"
  , "binary_codecs [" <> commaSeparated (fmap renderBinaryCodec (nativeRuntimeBinaryCodecs runtime)) <> "]"
  , "boundaries [" <> commaSeparated (fmap renderBoundaryContract (nativeRuntimeBoundaryContracts runtime)) <> "]"
  , "service_transports [" <> commaSeparated (fmap renderServiceTransport (nativeRuntimeServiceTransports runtime)) <> "]"
  ]

renderRuntimeBinding :: NativeRuntimeBinding -> Text
renderRuntimeBinding binding =
  nativeRuntimeBindingName binding
    <> "{runtime="
    <> nativeRuntimeBindingRuntimeName binding
    <> ", symbol="
    <> nativeRuntimeBindingSymbol binding
    <> ", type="
    <> renderType (nativeRuntimeBindingType binding)
    <> "}"

renderJsonCodec :: NativeJsonCodec -> Text
renderJsonCodec codec =
  renderType (nativeJsonCodecType codec)
    <> "{encode="
    <> nativeJsonCodecEncodeSymbol codec
    <> ", decode="
    <> nativeJsonCodecDecodeSymbol codec
    <> "}"

renderBinaryCodec :: NativeBinaryCodec -> Text
renderBinaryCodec codec =
  renderType (nativeBinaryCodecType codec)
    <> "{encode="
    <> nativeBinaryCodecEncodeSymbol codec
    <> ", decode="
    <> nativeBinaryCodecDecodeSymbol codec
    <> ", framing="
    <> nativeBinaryCodecFraming codec
    <> "}"

renderBoundaryContract :: NativeBoundaryContract -> Text
renderBoundaryContract contract =
  case contract of
    NativeRouteContract routeBoundary ->
      "route "
        <> nativeRouteBoundaryName routeBoundary
        <> "{id="
        <> nativeRouteBoundaryIdentity routeBoundary
        <> ", method="
        <> nativeRouteBoundaryMethod routeBoundary
        <> ", path="
        <> renderQuoted (nativeRouteBoundaryPath routeBoundary)
        <> ", request="
        <> nativeRouteBoundaryRequestType routeBoundary
        <> ", response="
        <> nativeRouteBoundaryResponseType routeBoundary
        <> ", response_kind="
        <> nativeRouteBoundaryResponseKind routeBoundary
        <> ", encode="
        <> nativeRouteBoundaryEncodeSymbol routeBoundary
        <> ", decode="
        <> nativeRouteBoundaryDecodeSymbol routeBoundary
        <> "}"
    NativeHookContract hookBoundary ->
      "hook "
        <> nativeHookBoundaryName hookBoundary
        <> "{id="
        <> nativeHookBoundaryIdentity hookBoundary
        <> ", event="
        <> renderQuoted (nativeHookBoundaryEvent hookBoundary)
        <> ", request="
        <> nativeHookBoundaryRequestType hookBoundary
        <> ", response="
        <> nativeHookBoundaryResponseType hookBoundary
        <> ", handler="
        <> nativeHookBoundaryHandler hookBoundary
        <> ", encode="
        <> nativeHookBoundaryEncodeSymbol hookBoundary
        <> ", decode="
        <> nativeHookBoundaryDecodeSymbol hookBoundary
        <> "}"
    NativeToolServerContract toolServerBoundary ->
      "toolserver "
        <> nativeToolServerBoundaryName toolServerBoundary
        <> "{id="
        <> nativeToolServerBoundaryIdentity toolServerBoundary
        <> ", protocol="
        <> renderQuoted (nativeToolServerBoundaryProtocol toolServerBoundary)
        <> ", location="
        <> renderQuoted (nativeToolServerBoundaryLocation toolServerBoundary)
        <> ", policy="
        <> nativeToolServerBoundaryPolicy toolServerBoundary
        <> "}"
    NativeToolContract toolBoundary ->
      "tool "
        <> nativeToolBoundaryName toolBoundary
        <> "{id="
        <> nativeToolBoundaryIdentity toolBoundary
        <> ", server="
        <> nativeToolBoundaryServer toolBoundary
        <> ", operation="
        <> renderQuoted (nativeToolBoundaryOperation toolBoundary)
        <> ", request="
        <> nativeToolBoundaryRequestType toolBoundary
        <> ", response="
        <> nativeToolBoundaryResponseType toolBoundary
        <> ", encode="
        <> nativeToolBoundaryEncodeSymbol toolBoundary
        <> ", decode="
        <> nativeToolBoundaryDecodeSymbol toolBoundary
        <> "}"
    NativeWorkflowContract workflowBoundary ->
      "workflow "
        <> nativeWorkflowBoundaryName workflowBoundary
        <> "{id="
        <> nativeWorkflowBoundaryIdentity workflowBoundary
        <> ", state="
        <> renderType (nativeWorkflowBoundaryStateType workflowBoundary)
        <> ", checkpoint="
        <> nativeWorkflowBoundaryCheckpointSymbol workflowBoundary
        <> ", restore="
        <> nativeWorkflowBoundaryRestoreSymbol workflowBoundary
        <> "}"

renderServiceTransport :: NativeServiceTransport -> Text
renderServiceTransport transport =
  nativeServiceTransportKind transport
    <> " "
    <> nativeServiceTransportName transport
    <> "{id="
    <> nativeServiceTransportIdentity transport
    <> ", mode="
    <> nativeServiceTransportMode transport
    <> ", request="
    <> nativeServiceTransportRequestType transport
    <> ", request_encode="
    <> nativeServiceTransportRequestEncodeSymbol transport
    <> ", request_decode="
    <> nativeServiceTransportRequestDecodeSymbol transport
    <> ", response="
    <> nativeServiceTransportResponseType transport
    <> ", response_encode="
    <> nativeServiceTransportResponseEncodeSymbol transport
    <> ", response_decode="
    <> nativeServiceTransportResponseDecodeSymbol transport
    <> ", framing="
    <> nativeServiceTransportFraming transport
    <> "}"

renderFieldLayout :: NativeFieldLayout -> Text
renderFieldLayout fieldLayout =
  nativeFieldLayoutName fieldLayout <> ":" <> renderType (nativeFieldLayoutType fieldLayout) <> "@word" <> renderInt (nativeFieldLayoutWordOffset fieldLayout) <> "/" <> renderLayoutStorage (nativeFieldLayoutStorage fieldLayout)

renderConstructorLayout :: NativeConstructorLayout -> Text
renderConstructorLayout layout =
  nativeConstructorLayoutName layout <> "{tag_word=" <> renderInt (nativeConstructorLayoutTagWord layout) <> ", payload_words=" <> renderInt (nativeConstructorLayoutPayloadWords layout) <> ", words=" <> renderInt (nativeConstructorLayoutWordCount layout) <> ", payloads=[" <> commaSeparated (fmap renderSlotLayout (nativeConstructorLayoutPayloads layout)) <> "]}"

renderSlotLayout :: NativeSlotLayout -> Text
renderSlotLayout slotLayout =
  nativeSlotLayoutName slotLayout <> ":" <> renderType (nativeSlotLayoutType slotLayout) <> "@word" <> renderInt (nativeSlotLayoutWordOffset slotLayout) <> "/" <> renderLayoutStorage (nativeSlotLayoutStorage slotLayout)

renderNativeExpr :: NativeExpr -> Text
renderNativeExpr expr =
  case expr of
    NativeLocal name ->
      "local(" <> name <> ")"
    NativeLiteralExpr literal ->
      renderLiteral literal
    NativeList items ->
      "list[" <> commaSeparated (fmap renderNativeExpr items) <> "]"
    NativeReturn value ->
      "return(" <> renderNativeExpr value <> ")"
    NativeCompare op left right ->
      "compare." <> renderCompareOp op <> "(" <> renderNativeExpr left <> ", " <> renderNativeExpr right <> ")"
    NativeLet mutability name value body ->
      "let." <> renderMutability mutability <> " " <> name <> " = " <> renderNativeExpr value <> " in " <> renderNativeExpr body
    NativeAssign name value body ->
      "assign " <> name <> " = " <> renderNativeExpr value <> " then " <> renderNativeExpr body
    NativeForEach name iterable loopBody body ->
      "for_each " <> name <> " in " <> renderNativeExpr iterable <> " do " <> renderNativeExpr loopBody <> " then " <> renderNativeExpr body
    NativeIntrinsic intrinsic ->
      renderIntrinsic intrinsic
    NativeCall callee args ->
      "call(" <> renderNativeExpr callee <> ", [" <> commaSeparated (fmap renderNativeExpr args) <> "])"
    NativeConstruct name args ->
      "construct " <> name <> "(" <> commaSeparated (fmap renderNativeExpr args) <> ")"
    NativeMatch scrutinee branches ->
      "match " <> renderNativeExpr scrutinee <> " [" <> commaSeparated (fmap renderMatchBranch branches) <> "]"
    NativeRecord recordName fields ->
      "record " <> recordName <> " {" <> commaSeparated (fmap renderField fields) <> "}"
    NativeFieldAccess recordName target fieldName ->
      "field(" <> recordName <> ", " <> renderNativeExpr target <> ", " <> fieldName <> ")"

renderLiteral :: NativeLiteral -> Text
renderLiteral literal =
  case literal of
    NativeInt value ->
      "int(" <> renderInteger value <> ")"
    NativeString value ->
      "string(" <> renderQuoted value <> ")"
    NativeBool value ->
      "bool(" <> renderBool value <> ")"

renderIntrinsic :: NativeIntrinsic -> Text
renderIntrinsic intrinsic =
  case intrinsic of
    NativePageIntrinsic title body ->
      "intrinsic.page(" <> renderNativeExpr title <> ", " <> renderNativeExpr body <> ")"
    NativeRedirectIntrinsic targetPath ->
      "intrinsic.redirect(" <> renderQuoted targetPath <> ")"
    NativeViewEmptyIntrinsic ->
      "intrinsic.view.empty"
    NativeViewTextIntrinsic value ->
      "intrinsic.view.text(" <> renderNativeExpr value <> ")"
    NativeViewAppendIntrinsic left right ->
      "intrinsic.view.append(" <> renderNativeExpr left <> ", " <> renderNativeExpr right <> ")"
    NativeViewElementIntrinsic tagName body ->
      "intrinsic.view.element(" <> renderQuoted tagName <> ", " <> renderNativeExpr body <> ")"
    NativeViewStyledIntrinsic className body ->
      "intrinsic.view.styled(" <> renderQuoted className <> ", " <> renderNativeExpr body <> ")"
    NativeViewLinkIntrinsic routeContract href body ->
      "intrinsic.view.link(" <> renderRouteContract routeContract <> ", " <> renderQuoted href <> ", " <> renderNativeExpr body <> ")"
    NativeViewFormIntrinsic routeContract method action body ->
      "intrinsic.view.form(" <> renderRouteContract routeContract <> ", " <> renderQuoted method <> ", " <> renderQuoted action <> ", " <> renderNativeExpr body <> ")"
    NativeViewInputIntrinsic name inputKind value ->
      "intrinsic.view.input(" <> renderQuoted name <> ", " <> renderQuoted inputKind <> ", " <> renderNativeExpr value <> ")"
    NativeViewSubmitIntrinsic value ->
      "intrinsic.view.submit(" <> renderNativeExpr value <> ")"
    NativePromptMessageIntrinsic role value ->
      "intrinsic.prompt.message(" <> renderQuoted role <> ", " <> renderNativeExpr value <> ")"
    NativePromptAppendIntrinsic left right ->
      "intrinsic.prompt.append(" <> renderNativeExpr left <> ", " <> renderNativeExpr right <> ")"
    NativePromptTextIntrinsic value ->
      "intrinsic.prompt.text(" <> renderNativeExpr value <> ")"

renderMatchBranch :: NativeMatchBranch -> Text
renderMatchBranch branch =
  nativeMatchBranchTag branch <> "(" <> commaSeparated (nativeMatchBranchBinders branch) <> ") -> " <> renderNativeExpr (nativeMatchBranchBody branch)

renderField :: NativeField -> Text
renderField field =
  nativeFieldName field <> " = " <> renderNativeExpr (nativeFieldValue field)

renderRouteContract :: LowerRouteContract -> Text
renderRouteContract routeContract =
  "route[" <> lowerRouteContractIdentity routeContract <> " " <> lowerRouteContractMethod routeContract <> " " <> renderQuoted (lowerRouteContractPath routeContract) <> "]"

renderModuleNameText :: ModuleName -> Text
renderModuleNameText =
  T.intercalate "." . splitModuleName

renderMemoryStrategy :: NativeMemoryStrategy -> Text
renderMemoryStrategy NativeReferenceCounting = "reference_counting"

renderAllocationRegion :: NativeAllocationRegion -> Text
renderAllocationRegion region =
  case region of
    NativeStackRegion -> "stack"
    NativeHeapRegion -> "heap"
    NativeStaticRegion -> "static"

renderOwnershipRule :: NativeOwnershipRule -> Text
renderOwnershipRule rule =
  case rule of
    NativeCallerOwnsReturns -> "caller_owns_returns"
    NativeCalleeBorrowsArguments -> "callee_borrows_arguments"
    NativeAggregatesRetainHandleFields -> "aggregates_retain_handle_fields"
    NativeGlobalsAreStaticRoots -> "globals_are_static_roots"

renderRootDiscoveryRule :: NativeRootDiscoveryRule -> Text
renderRootDiscoveryRule rule =
  case rule of
    NativeDiscoverStaticRootsFromGlobals -> "static_globals"
    NativeDiscoverStackRootsFromHandleSlots -> "stack_handle_slots"
    NativeDiscoverHeapRootsFromObjectLayouts -> "heap_object_layouts"

renderLifetimeInvariant :: NativeLifetimeInvariant -> Text
renderLifetimeInvariant invariant =
  case invariant of
    NativeHeapObjectsCarryLayoutAndRetainHeaders -> "layout_and_retain_headers"
    NativeOnlyDeclaredRootOffsetsRetainChildren -> "declared_root_offsets_only"
    NativeReleaseTraversesRootOffsetsBeforeFree -> "release_children_before_free"
    NativeBorrowedHandlesDoNotMutateRetainCounts -> "borrowed_handles_do_not_retain"

renderLayoutStorage :: NativeLayoutStorage -> Text
renderLayoutStorage storage =
  case storage of
    NativeImmediateStorage -> "immediate"
    NativeHandleStorage -> "handle"

renderObjectKind :: NativeObjectKind -> Text
renderObjectKind kind =
  case kind of
    NativeRecordObject -> "record"
    NativeVariantObject -> "variant"

renderCompareOp :: NativeCompareOp -> Text
renderCompareOp op =
  case op of
    NativeEqual -> "eq"
    NativeNotEqual -> "ne"
    NativeLessThan -> "lt"
    NativeLessThanOrEqual -> "le"
    NativeGreaterThan -> "gt"
    NativeGreaterThanOrEqual -> "ge"

renderMutability :: NativeMutability -> Text
renderMutability mutability =
  case mutability of
    NativeImmutable -> "immutable"
    NativeMutable -> "mutable"

commaSeparated :: [Text] -> Text
commaSeparated =
  T.intercalate ", "

indentBlock :: [Text] -> [Text]
indentBlock =
  fmap ("  " <>)

renderQuoted :: Text -> Text
renderQuoted value =
  T.pack (show (T.unpack value))

renderInt :: Int -> Text
renderInt =
  T.pack . show

renderInteger :: Integer -> Text
renderInteger =
  T.pack . show

renderBool :: Bool -> Text
renderBool value =
  if value then "true" else "false"

buildNativeAbi :: LowerModule -> NativeAbi
buildNativeAbi modl =
  NativeAbi
    { nativeAbiVersion = "clasp-native-v1"
    , nativeAbiWordBytes = 8
    , nativeAbiMemoryStrategy = NativeReferenceCounting
    , nativeAbiAllocationModel =
        NativeAllocationModel
          { nativeAllocationImmediateRegion = NativeStackRegion
          , nativeAllocationHandleRegion = NativeHeapRegion
          , nativeAllocationGlobalRegion = NativeStaticRegion
          }
    , nativeAbiOwnershipRules =
        [ NativeCallerOwnsReturns
        , NativeCalleeBorrowsArguments
        , NativeAggregatesRetainHandleFields
        , NativeGlobalsAreStaticRoots
        ]
    , nativeAbiRootDiscoveryRules =
        [ NativeDiscoverStaticRootsFromGlobals
        , NativeDiscoverStackRootsFromHandleSlots
        , NativeDiscoverHeapRootsFromObjectLayouts
        ]
    , nativeAbiLifetimeInvariants =
        [ NativeHeapObjectsCarryLayoutAndRetainHeaders
        , NativeOnlyDeclaredRootOffsetsRetainChildren
        , NativeReleaseTraversesRootOffsetsBeforeFree
        , NativeBorrowedHandlesDoNotMutateRetainCounts
        ]
    , nativeAbiBuiltinLayouts = builtinLayouts
    , nativeAbiRecordLayouts = fmap (buildRecordLayout recordEnv typeEnv) recordDecls
    , nativeAbiVariantLayouts = fmap (buildVariantLayout recordEnv typeEnv) typeDecls
    , nativeAbiObjectLayouts =
        fmap (buildRecordObjectLayout recordEnv typeEnv) recordDecls
          <> concatMap (buildVariantObjectLayouts recordEnv typeEnv) typeDecls
    }
  where
    typeDecls = lowerModuleTypeDecls modl
    recordDecls = lowerModuleRecordDecls modl
    typeEnv = Map.fromList [(typeDeclName typeDecl, typeDecl) | typeDecl <- typeDecls]
    recordEnv = Map.fromList [(recordDeclName recordDecl, recordDecl) | recordDecl <- recordDecls]
    builtinLayouts =
      [ NativeBuiltinLayout "Int" NativeImmediateStorage 1
      , NativeBuiltinLayout "Bool" NativeImmediateStorage 1
      , NativeBuiltinLayout "Str" NativeHandleStorage 1
      , NativeBuiltinLayout "List" NativeHandleStorage 1
      , NativeBuiltinLayout "Page" NativeHandleStorage 1
      , NativeBuiltinLayout "Redirect" NativeHandleStorage 1
      , NativeBuiltinLayout "View" NativeHandleStorage 1
      , NativeBuiltinLayout "Prompt" NativeHandleStorage 1
      ]

buildNativeRuntime :: LowerModule -> NativeRuntime
buildNativeRuntime modl =
  NativeRuntime
    { nativeRuntimeProfile = "compiler_backend_minimal"
    , nativeRuntimeArtifacts =
        [ "runtime/native/clasp_runtime.h"
        , "runtime/native/clasp_runtime.c"
        ]
    , nativeRuntimeMemorySymbols =
        [ "clasp_rt_init"
        , "clasp_rt_register_static_root"
        , "clasp_rt_alloc_object"
        , "clasp_rt_retain"
        , "clasp_rt_release"
        , "clasp_rt_string_from_utf8"
        , "clasp_rt_bytes_new"
        , "clasp_rt_string_list_new"
        , "clasp_rt_result_ok_string"
        , "clasp_rt_result_err_string"
        , "clasp_rt_json_from_string"
        , "clasp_rt_json_to_string"
        , "clasp_rt_binary_from_json"
        , "clasp_rt_json_from_binary"
        , "clasp_rt_transport_frame"
        , "clasp_rt_transport_unframe"
        ]
    , nativeRuntimeBindings = fmap lowerForeignDeclToRuntimeBinding (lowerModuleForeignDecls modl)
    , nativeRuntimeJsonCodecs = fmap nativeJsonCodecForType (lowerModuleCodecTypes modl)
    , nativeRuntimeBinaryCodecs = fmap nativeBinaryCodecForType (lowerModuleCodecTypes modl)
    , nativeRuntimeBoundaryContracts =
        fmap (NativeRouteContract . lowerRouteToBoundary) (lowerModuleRoutes modl)
          <> fmap (NativeHookContract . hookDeclToBoundary) (lowerModuleHookDecls modl)
          <> fmap (NativeToolServerContract . toolServerDeclToBoundary) (lowerModuleToolServerDecls modl)
          <> fmap (NativeToolContract . toolDeclToBoundary) (lowerModuleToolDecls modl)
          <> fmap (NativeWorkflowContract . workflowDeclToBoundary) (lowerModuleWorkflowDecls modl)
    , nativeRuntimeServiceTransports =
        fmap lowerRouteToServiceTransport (filter isBinaryServiceRoute (lowerModuleRoutes modl))
          <> fmap hookDeclToServiceTransport (lowerModuleHookDecls modl)
          <> fmap toolDeclToServiceTransport (lowerModuleToolDecls modl)
    }

lowerForeignDeclToRuntimeBinding :: ForeignDecl -> NativeRuntimeBinding
lowerForeignDeclToRuntimeBinding foreignDecl =
  NativeRuntimeBinding
    { nativeRuntimeBindingName = foreignDeclName foreignDecl
    , nativeRuntimeBindingRuntimeName = foreignDeclRuntimeName foreignDecl
    , nativeRuntimeBindingSymbol = nativeRuntimeSymbol (foreignDeclRuntimeName foreignDecl)
    , nativeRuntimeBindingType = foreignDeclType foreignDecl
    }

nativeRuntimeSymbol :: Text -> Text
nativeRuntimeSymbol runtimeName =
  "clasp_rt_" <> normalizeRuntimeName runtimeName

nativeJsonCodecForType :: Type -> NativeJsonCodec
nativeJsonCodecForType typ =
  NativeJsonCodec
    { nativeJsonCodecType = typ
    , nativeJsonCodecEncodeSymbol = "$encode_" <> nativeCodecSuffix typ
    , nativeJsonCodecDecodeSymbol = "$decode_" <> nativeCodecSuffix typ
    }

nativeBinaryCodecForType :: Type -> NativeBinaryCodec
nativeBinaryCodecForType typ =
  NativeBinaryCodec
    { nativeBinaryCodecType = typ
    , nativeBinaryCodecEncodeSymbol = "$encode_binary_" <> nativeCodecSuffix typ
    , nativeBinaryCodecDecodeSymbol = "$decode_binary_" <> nativeCodecSuffix typ
    , nativeBinaryCodecFraming = "length_prefixed"
    }

lowerRouteToBoundary :: LowerRoute -> NativeRouteBoundary
lowerRouteToBoundary route =
  NativeRouteBoundary
    { nativeRouteBoundaryName = lowerRouteName route
    , nativeRouteBoundaryIdentity = lowerRouteIdentity route
    , nativeRouteBoundaryMethod = renderRouteMethodText (lowerRouteMethod route)
    , nativeRouteBoundaryPath = lowerRoutePath route
    , nativeRouteBoundaryRequestType = lowerRouteRequestTypeName route
    , nativeRouteBoundaryResponseType = lowerRouteResponseTypeName route
    , nativeRouteBoundaryResponseKind = routeBoundaryKind (lowerRouteResponseTypeName route)
    , nativeRouteBoundaryEncodeSymbol = "$encode_" <> lowerRouteResponseTypeName route
    , nativeRouteBoundaryDecodeSymbol = "$decode_" <> lowerRouteRequestTypeName route
    }

hookDeclToBoundary :: HookDecl -> NativeHookBoundary
hookDeclToBoundary hookDecl =
  NativeHookBoundary
    { nativeHookBoundaryName = hookDeclName hookDecl
    , nativeHookBoundaryIdentity = hookDeclIdentity hookDecl
    , nativeHookBoundaryEvent = hookTriggerDeclEvent (hookDeclTrigger hookDecl)
    , nativeHookBoundaryRequestType = hookDeclRequestType hookDecl
    , nativeHookBoundaryResponseType = hookDeclResponseType hookDecl
    , nativeHookBoundaryHandler = hookDeclHandlerName hookDecl
    , nativeHookBoundaryEncodeSymbol = "$encode_" <> hookDeclResponseType hookDecl
    , nativeHookBoundaryDecodeSymbol = "$decode_" <> hookDeclRequestType hookDecl
    }

toolServerDeclToBoundary :: ToolServerDecl -> NativeToolServerBoundary
toolServerDeclToBoundary toolServerDecl =
  NativeToolServerBoundary
    { nativeToolServerBoundaryName = toolServerDeclName toolServerDecl
    , nativeToolServerBoundaryIdentity = toolServerDeclIdentity toolServerDecl
    , nativeToolServerBoundaryProtocol = toolServerDeclProtocol toolServerDecl
    , nativeToolServerBoundaryLocation = toolServerDeclLocation toolServerDecl
    , nativeToolServerBoundaryPolicy = toolServerDeclPolicyName toolServerDecl
    }

toolDeclToBoundary :: ToolDecl -> NativeToolBoundary
toolDeclToBoundary toolDecl =
  NativeToolBoundary
    { nativeToolBoundaryName = toolDeclName toolDecl
    , nativeToolBoundaryIdentity = toolDeclIdentity toolDecl
    , nativeToolBoundaryServer = toolDeclServerName toolDecl
    , nativeToolBoundaryOperation = toolDeclOperation toolDecl
    , nativeToolBoundaryRequestType = toolDeclRequestType toolDecl
    , nativeToolBoundaryResponseType = toolDeclResponseType toolDecl
    , nativeToolBoundaryEncodeSymbol = "$encode_" <> toolDeclResponseType toolDecl
    , nativeToolBoundaryDecodeSymbol = "$decode_" <> toolDeclRequestType toolDecl
    }

workflowDeclToBoundary :: WorkflowDecl -> NativeWorkflowBoundary
workflowDeclToBoundary workflowDecl =
  NativeWorkflowBoundary
    { nativeWorkflowBoundaryName = workflowDeclName workflowDecl
    , nativeWorkflowBoundaryIdentity = workflowDeclIdentity workflowDecl
    , nativeWorkflowBoundaryStateType = workflowDeclStateType workflowDecl
    , nativeWorkflowBoundaryCheckpointSymbol = "$encode_" <> nativeCodecSuffix (workflowDeclStateType workflowDecl)
    , nativeWorkflowBoundaryRestoreSymbol = "$decode_" <> nativeCodecSuffix (workflowDeclStateType workflowDecl)
    }

lowerRouteToServiceTransport :: LowerRoute -> NativeServiceTransport
lowerRouteToServiceTransport route =
  NativeServiceTransport
    { nativeServiceTransportKind = "route"
    , nativeServiceTransportName = lowerRouteName route
    , nativeServiceTransportIdentity = lowerRouteIdentity route
    , nativeServiceTransportMode = "request_response"
    , nativeServiceTransportRequestType = lowerRouteRequestTypeName route
    , nativeServiceTransportRequestEncodeSymbol = "$encode_binary_" <> lowerRouteRequestTypeName route
    , nativeServiceTransportRequestDecodeSymbol = "$decode_binary_" <> lowerRouteRequestTypeName route
    , nativeServiceTransportResponseType = lowerRouteResponseTypeName route
    , nativeServiceTransportResponseEncodeSymbol = "$encode_binary_" <> lowerRouteResponseTypeName route
    , nativeServiceTransportResponseDecodeSymbol = "$decode_binary_" <> lowerRouteResponseTypeName route
    , nativeServiceTransportFraming = "length_prefixed"
    }

hookDeclToServiceTransport :: HookDecl -> NativeServiceTransport
hookDeclToServiceTransport hookDecl =
  NativeServiceTransport
    { nativeServiceTransportKind = "hook"
    , nativeServiceTransportName = hookDeclName hookDecl
    , nativeServiceTransportIdentity = hookDeclIdentity hookDecl
    , nativeServiceTransportMode = "event"
    , nativeServiceTransportRequestType = hookDeclRequestType hookDecl
    , nativeServiceTransportRequestEncodeSymbol = "$encode_binary_" <> hookDeclRequestType hookDecl
    , nativeServiceTransportRequestDecodeSymbol = "$decode_binary_" <> hookDeclRequestType hookDecl
    , nativeServiceTransportResponseType = hookDeclResponseType hookDecl
    , nativeServiceTransportResponseEncodeSymbol = "$encode_binary_" <> hookDeclResponseType hookDecl
    , nativeServiceTransportResponseDecodeSymbol = "$decode_binary_" <> hookDeclResponseType hookDecl
    , nativeServiceTransportFraming = "length_prefixed"
    }

toolDeclToServiceTransport :: ToolDecl -> NativeServiceTransport
toolDeclToServiceTransport toolDecl =
  NativeServiceTransport
    { nativeServiceTransportKind = "tool"
    , nativeServiceTransportName = toolDeclName toolDecl
    , nativeServiceTransportIdentity = toolDeclIdentity toolDecl
    , nativeServiceTransportMode = "rpc"
    , nativeServiceTransportRequestType = toolDeclRequestType toolDecl
    , nativeServiceTransportRequestEncodeSymbol = "$encode_binary_" <> toolDeclRequestType toolDecl
    , nativeServiceTransportRequestDecodeSymbol = "$decode_binary_" <> toolDeclRequestType toolDecl
    , nativeServiceTransportResponseType = toolDeclResponseType toolDecl
    , nativeServiceTransportResponseEncodeSymbol = "$encode_binary_" <> toolDeclResponseType toolDecl
    , nativeServiceTransportResponseDecodeSymbol = "$decode_binary_" <> toolDeclResponseType toolDecl
    , nativeServiceTransportFraming = "length_prefixed"
    }

normalizeRuntimeName :: Text -> Text
normalizeRuntimeName =
  T.dropWhileEnd (== '_')
    . T.dropWhile (== '_')
    . snd
    . T.foldl' step (False, "")
  where
    step (seenAlphaNum, acc) char
      | isAlphaNum char =
          let needsSeparator = seenAlphaNum && isUpper char && not (T.null acc) && T.last acc /= '_'
              nextAcc =
                if needsSeparator
                  then acc <> "_" <> T.singleton (toLower char)
                  else acc <> T.singleton (toLower char)
           in (True, nextAcc)
      | otherwise =
          let nextAcc =
                if T.null acc || T.last acc == '_'
                  then acc
                  else acc <> "_"
           in (seenAlphaNum, nextAcc)

nativeCodecSuffix :: Type -> Text
nativeCodecSuffix typ =
  case typ of
    TInt ->
      "Int"
    TStr ->
      "Str"
    TBool ->
      "Bool"
    TList itemType ->
      "List_" <> nativeCodecSuffix itemType
    TNamed name ->
      name
    TFunction _ _ ->
      error "functions are not JSON codec targets"

routeBoundaryKind :: Text -> Text
routeBoundaryKind responseType
  | responseType == "Page" = "page"
  | responseType == "Redirect" = "redirect"
  | otherwise = "json"

isBinaryServiceRoute :: LowerRoute -> Bool
isBinaryServiceRoute route =
  routeBoundaryKind (lowerRouteResponseTypeName route) == "json"

renderRouteMethodText :: Show a => a -> Text
renderRouteMethodText method =
  case T.pack (show method) of
    "RouteGet" -> "GET"
    "RoutePost" -> "POST"
    other -> other

buildRecordLayout :: Map.Map Text RecordDecl -> Map.Map Text TypeDecl -> RecordDecl -> NativeRecordLayout
buildRecordLayout recordEnv typeEnv recordDecl =
  NativeRecordLayout
    { nativeRecordLayoutName = recordDeclName recordDecl
    , nativeRecordLayoutWordCount = length fieldLayouts
    , nativeRecordLayoutFields = fieldLayouts
    }
  where
    fieldLayouts =
      zipWith (buildFieldLayout recordEnv typeEnv) [0 ..] (recordDeclFields recordDecl)

buildRecordObjectLayout :: Map.Map Text RecordDecl -> Map.Map Text TypeDecl -> RecordDecl -> NativeObjectLayout
buildRecordObjectLayout recordEnv typeEnv recordDecl =
  NativeObjectLayout
    { nativeObjectLayoutName = recordDeclName recordDecl
    , nativeObjectLayoutKind = NativeRecordObject
    , nativeObjectLayoutHeaderWords = nativeObjectHeaderWords
    , nativeObjectLayoutWordCount = nativeObjectHeaderWords + nativeRecordLayoutWordCount recordLayout
    , nativeObjectLayoutRootOffsets =
        [ nativeObjectHeaderWords + nativeFieldLayoutWordOffset fieldLayout
        | fieldLayout <- nativeRecordLayoutFields recordLayout
        , nativeFieldLayoutStorage fieldLayout == NativeHandleStorage
        ]
    }
  where
    recordLayout = buildRecordLayout recordEnv typeEnv recordDecl

buildFieldLayout :: Map.Map Text RecordDecl -> Map.Map Text TypeDecl -> Int -> RecordFieldDecl -> NativeFieldLayout
buildFieldLayout recordEnv typeEnv wordOffset fieldDecl =
  NativeFieldLayout
    { nativeFieldLayoutName = recordFieldDeclName fieldDecl
    , nativeFieldLayoutType = fieldType
    , nativeFieldLayoutStorage = layoutStorageForType recordEnv typeEnv fieldType
    , nativeFieldLayoutWordOffset = wordOffset
    , nativeFieldLayoutWordCount = 1
    }
  where
    fieldType = recordFieldDeclType fieldDecl

buildVariantLayout :: Map.Map Text RecordDecl -> Map.Map Text TypeDecl -> TypeDecl -> NativeVariantLayout
buildVariantLayout recordEnv typeEnv typeDecl =
  NativeVariantLayout
    { nativeVariantLayoutName = typeDeclName typeDecl
    , nativeVariantLayoutTagWord = 0
    , nativeVariantLayoutMaxPayloadWords = maximum (0 : fmap nativeConstructorLayoutPayloadWords constructorLayouts)
    , nativeVariantLayoutWordCount = maximum (1 : fmap nativeConstructorLayoutWordCount constructorLayouts)
    , nativeVariantLayoutConstructors = constructorLayouts
    }
  where
    constructorLayouts =
      fmap (buildConstructorLayout recordEnv typeEnv) (typeDeclConstructors typeDecl)

buildVariantObjectLayouts :: Map.Map Text RecordDecl -> Map.Map Text TypeDecl -> TypeDecl -> [NativeObjectLayout]
buildVariantObjectLayouts recordEnv typeEnv typeDecl =
  fmap buildObjectLayout (typeDeclConstructors typeDecl)
  where
    buildObjectLayout constructorDecl =
      let constructorLayout = buildConstructorLayout recordEnv typeEnv constructorDecl
       in NativeObjectLayout
            { nativeObjectLayoutName = typeDeclName typeDecl <> "." <> constructorDeclName constructorDecl
            , nativeObjectLayoutKind = NativeVariantObject
            , nativeObjectLayoutHeaderWords = nativeObjectHeaderWords
            , nativeObjectLayoutWordCount = nativeObjectHeaderWords + nativeConstructorLayoutWordCount constructorLayout
            , nativeObjectLayoutRootOffsets =
                [ nativeObjectHeaderWords + nativeSlotLayoutWordOffset payloadLayout
                | payloadLayout <- nativeConstructorLayoutPayloads constructorLayout
                , nativeSlotLayoutStorage payloadLayout == NativeHandleStorage
                ]
            }

buildConstructorLayout :: Map.Map Text RecordDecl -> Map.Map Text TypeDecl -> ConstructorDecl -> NativeConstructorLayout
buildConstructorLayout recordEnv typeEnv constructorDecl =
  NativeConstructorLayout
    { nativeConstructorLayoutName = constructorDeclName constructorDecl
    , nativeConstructorLayoutTagWord = 0
    , nativeConstructorLayoutPayloadWords = length payloadLayouts
    , nativeConstructorLayoutWordCount = 1 + length payloadLayouts
    , nativeConstructorLayoutPayloads = payloadLayouts
    }
  where
    payloadLayouts =
      zipWith (buildPayloadLayout recordEnv typeEnv) [1 ..] (constructorDeclFields constructorDecl)

buildPayloadLayout :: Map.Map Text RecordDecl -> Map.Map Text TypeDecl -> Int -> Type -> NativeSlotLayout
buildPayloadLayout recordEnv typeEnv wordOffset slotType =
  NativeSlotLayout
    { nativeSlotLayoutName = "$" <> nativeIndexName (wordOffset - 1)
    , nativeSlotLayoutType = slotType
    , nativeSlotLayoutStorage = layoutStorageForType recordEnv typeEnv slotType
    , nativeSlotLayoutWordOffset = wordOffset
    , nativeSlotLayoutWordCount = 1
    }

nativeIndexName :: Int -> Text
nativeIndexName index =
  T.pack (show index)

nativeObjectHeaderWords :: Int
nativeObjectHeaderWords = 2

layoutStorageForType :: Map.Map Text RecordDecl -> Map.Map Text TypeDecl -> Type -> NativeLayoutStorage
layoutStorageForType recordEnv typeEnv typ =
  case typ of
    TInt ->
      NativeImmediateStorage
    TBool ->
      NativeImmediateStorage
    TStr ->
      NativeHandleStorage
    TList _ ->
      NativeHandleStorage
    TNamed name
      | name `elem` ["Page", "Redirect", "View", "Prompt"] ->
          NativeHandleStorage
      | Map.member name recordEnv ->
          NativeHandleStorage
      | otherwise ->
          case Map.lookup name typeEnv of
            Just typeDecl
              | all (null . constructorDeclFields) (typeDeclConstructors typeDecl) ->
                  NativeImmediateStorage
            Just _ ->
              NativeHandleStorage
            Nothing ->
              NativeHandleStorage
    TFunction _ _ ->
      NativeHandleStorage

lowerDeclName :: LowerDecl -> Text
lowerDeclName decl =
  case decl of
    LValueDecl name _ ->
      name
    LFunctionDecl name _ _ ->
      name

lowerDeclToNative :: LowerDecl -> NativeDecl
lowerDeclToNative decl =
  case decl of
    LValueDecl name body ->
      NativeGlobalDecl
        NativeGlobal
          { nativeGlobalName = name
          , nativeGlobalBody = lowerExprToNative body
          }
    LFunctionDecl name params body ->
      NativeFunctionDecl
        NativeFunction
          { nativeFunctionName = name
          , nativeFunctionParams = params
          , nativeFunctionBody = lowerExprToNative body
          }

lowerExprToNative :: LowerExpr -> NativeExpr
lowerExprToNative expr =
  case expr of
    LVar name ->
      NativeLocal name
    LInt value ->
      NativeLiteralExpr (NativeInt value)
    LString value ->
      NativeLiteralExpr (NativeString value)
    LBool value ->
      NativeLiteralExpr (NativeBool value)
    LList items ->
      NativeList (fmap lowerExprToNative items)
    LReturn value ->
      NativeReturn (lowerExprToNative value)
    LEqual left right ->
      NativeCompare NativeEqual (lowerExprToNative left) (lowerExprToNative right)
    LNotEqual left right ->
      NativeCompare NativeNotEqual (lowerExprToNative left) (lowerExprToNative right)
    LLessThan left right ->
      NativeCompare NativeLessThan (lowerExprToNative left) (lowerExprToNative right)
    LLessThanOrEqual left right ->
      NativeCompare NativeLessThanOrEqual (lowerExprToNative left) (lowerExprToNative right)
    LGreaterThan left right ->
      NativeCompare NativeGreaterThan (lowerExprToNative left) (lowerExprToNative right)
    LGreaterThanOrEqual left right ->
      NativeCompare NativeGreaterThanOrEqual (lowerExprToNative left) (lowerExprToNative right)
    LLet name value body ->
      NativeLet NativeImmutable name (lowerExprToNative value) (lowerExprToNative body)
    LMutableLet name value body ->
      NativeLet NativeMutable name (lowerExprToNative value) (lowerExprToNative body)
    LAssign name value body ->
      NativeAssign name (lowerExprToNative value) (lowerExprToNative body)
    LFor name iterable loopBody body ->
      NativeForEach name (lowerExprToNative iterable) (lowerExprToNative loopBody) (lowerExprToNative body)
    LPage title body ->
      NativeIntrinsic (NativePageIntrinsic (lowerExprToNative title) (lowerExprToNative body))
    LRedirect targetPath ->
      NativeIntrinsic (NativeRedirectIntrinsic targetPath)
    LViewEmpty ->
      NativeIntrinsic NativeViewEmptyIntrinsic
    LViewText value ->
      NativeIntrinsic (NativeViewTextIntrinsic (lowerExprToNative value))
    LViewAppend left right ->
      NativeIntrinsic (NativeViewAppendIntrinsic (lowerExprToNative left) (lowerExprToNative right))
    LViewElement tag child ->
      NativeIntrinsic (NativeViewElementIntrinsic tag (lowerExprToNative child))
    LViewStyled styleRef child ->
      NativeIntrinsic (NativeViewStyledIntrinsic styleRef (lowerExprToNative child))
    LViewLink routeContract href child ->
      NativeIntrinsic (NativeViewLinkIntrinsic routeContract href (lowerExprToNative child))
    LViewForm routeContract method action child ->
      NativeIntrinsic (NativeViewFormIntrinsic routeContract method action (lowerExprToNative child))
    LViewInput fieldName inputKind value ->
      NativeIntrinsic (NativeViewInputIntrinsic fieldName inputKind (lowerExprToNative value))
    LViewSubmit label ->
      NativeIntrinsic (NativeViewSubmitIntrinsic (lowerExprToNative label))
    LPromptMessage role content ->
      NativeIntrinsic (NativePromptMessageIntrinsic role (lowerExprToNative content))
    LPromptAppend left right ->
      NativeIntrinsic (NativePromptAppendIntrinsic (lowerExprToNative left) (lowerExprToNative right))
    LPromptText promptExpr ->
      NativeIntrinsic (NativePromptTextIntrinsic (lowerExprToNative promptExpr))
    LCall fn args ->
      NativeCall (lowerExprToNative fn) (fmap lowerExprToNative args)
    LConstruct tag args ->
      NativeConstruct tag (fmap lowerExprToNative args)
    LMatch subject branches ->
      NativeMatch (lowerExprToNative subject) (fmap lowerBranchToNative branches)
    LRecord recordName fields ->
      NativeRecord recordName (fmap lowerFieldToNative fields)
    LFieldAccess subjectType subject fieldName ->
      NativeFieldAccess (recordTypeName subjectType) (lowerExprToNative subject) fieldName

lowerBranchToNative :: LowerMatchBranch -> NativeMatchBranch
lowerBranchToNative branch =
  NativeMatchBranch
    { nativeMatchBranchTag = lowerMatchBranchTag branch
    , nativeMatchBranchBinders = lowerMatchBranchBinders branch
    , nativeMatchBranchBody = lowerExprToNative (lowerMatchBranchBody branch)
    }

lowerFieldToNative :: LowerRecordField -> NativeField
lowerFieldToNative field =
  NativeField
    { nativeFieldName = lowerRecordFieldName field
    , nativeFieldValue = lowerExprToNative (lowerRecordFieldValue field)
    }

recordTypeName :: Type -> Text
recordTypeName typ =
  case typ of
    TNamed name -> name
    _ -> renderType typ
