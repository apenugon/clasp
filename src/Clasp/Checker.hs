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
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Clasp.Core
  ( CoreDecl (..)
  , CoreExpr (..)
  , CoreMatchBranch (..)
  , CoreModule (..)
  , CoreParam (..)
  , CorePattern (..)
  , CorePatternBinder (..)
  , CoreRecordField (..)
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
  ( ConstructorDecl (..)
  , Decl (..)
  , Expr (..)
  , ForeignDecl (..)
  , MatchBranch (..)
  , Module (..)
  , Pattern (..)
  , PatternBinder (..)
  , RecordDecl (..)
  , RecordFieldDecl (..)
  , RecordFieldExpr (..)
  , RouteDecl (..)
  , Position (..)
  , SourceSpan (..)
  , Type (..)
  , TypeDecl (..)
  , exprSpan
  , renderType
  )

type DeclTypeEnv = Map.Map Text Type
type TypeDeclEnv = Map.Map Text TypeDecl
type RecordDeclEnv = Map.Map Text RecordDecl
type ForeignDeclEnv = Map.Map Text ForeignDecl
type DeclMap = Map.Map Text Decl

data ModuleContext = ModuleContext
  { contextTypeDeclEnv :: TypeDeclEnv
  , contextRecordDeclEnv :: RecordDeclEnv
  , contextForeignDeclEnv :: ForeignDeclEnv
  , contextConstructorEnv :: ConstructorEnv
  , contextDeclMap :: DeclMap
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
  | INamed Text
  | IFunction [InferType] InferType
  | IVar Int
  deriving (Eq, Ord, Show)

data InferState = InferState
  { inferNextTypeVar :: Int
  , inferSubstitution :: Map.Map Int InferType
  }

data InferFailure
  = InferDeferredName Text SourceSpan
  | InferDiagnostic DiagnosticBundle

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
  | DraftPage DraftExpr DraftExpr
  | DraftViewEmpty
  | DraftViewText DraftExpr
  | DraftViewAppend DraftExpr DraftExpr
  | DraftViewElement Text DraftExpr
  | DraftViewStyled Text DraftExpr
  | DraftViewLink Text DraftExpr
  | DraftViewForm Text Text DraftExpr
  | DraftViewInput Text Text DraftExpr
  | DraftViewSubmit DraftExpr
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

viewTypeName :: Text
viewTypeName = "View"

authSessionTypeName :: Text
authSessionTypeName = "AuthSession"

principalTypeName :: Text
principalTypeName = "Principal"

tenantTypeName :: Text
tenantTypeName = "Tenant"

resourceIdentityTypeName :: Text
resourceIdentityTypeName = "ResourceIdentity"

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
    }

builtinRecordDecl :: Text -> [(Text, Type)] -> RecordDecl
builtinRecordDecl name fields =
  RecordDecl
    { recordDeclName = name
    , recordDeclSpan = builtinSpan
    , recordDeclNameSpan = builtinSpan
    , recordDeclFields = fmap (uncurry builtinRecordFieldDecl) fields
    }

builtinRecordDecls :: [RecordDecl]
builtinRecordDecls =
  [ builtinRecordDecl principalTypeName [("id", TStr)]
  , builtinRecordDecl tenantTypeName [("id", TStr)]
  , builtinRecordDecl resourceIdentityTypeName [("resourceType", TStr), ("resourceId", TStr)]
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
  name == pageTypeName || name == viewTypeName || isBuiltinRecordTypeName name

isBuiltinViewFunctionName :: Text -> Bool
isBuiltinViewFunctionName name =
  name `elem` ["page", "text", "append", "element", "styled", "link", "form", "input", "submit", hostClassBuiltinName, hostStyleBuiltinName]

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

checkModule :: Module -> Either DiagnosticBundle CoreModule
checkModule modl = do
  let typeDecls = moduleTypeDecls modl
      recordDecls = moduleRecordDecls modl
      foreignDecls = moduleForeignDecls modl
      routeDecls = moduleRouteDecls modl
      decls = moduleDecls modl

  ensureUniqueTypeDecls typeDecls
  ensureUniqueRecordDecls recordDecls
  let typeDeclEnv = Map.fromList [(typeDeclName typeDecl, typeDecl) | typeDecl <- typeDecls]
      recordDeclEnv = Map.union builtinRecordDeclEnv (Map.fromList [(recordDeclName recordDecl, recordDecl) | recordDecl <- recordDecls])
  ensureDistinctNamedTypes typeDeclEnv recordDecls
  ensureKnownTypes typeDeclEnv recordDeclEnv typeDecls recordDecls foreignDecls decls routeDecls

  constructorEnv <- buildConstructorEnv typeDecls
  ensureUniqueForeignDecls foreignDecls decls constructorEnv
  ensureUniqueDecls decls foreignDecls constructorEnv
  ensureUniqueRoutes routeDecls
  mapM_ ensureUniqueParams decls

  let foreignDeclEnv = Map.fromList [(foreignDeclName foreignDecl, foreignDecl) | foreignDecl <- foreignDecls]
      ctx =
        ModuleContext
          { contextTypeDeclEnv = typeDeclEnv
          , contextRecordDeclEnv = recordDeclEnv
          , contextForeignDeclEnv = foreignDeclEnv
          , contextConstructorEnv = constructorEnv
          , contextDeclMap = Map.fromList [(declName decl, decl) | decl <- decls]
          }

  declTypeEnv <- inferDeclTypes ctx decls
  let foreignTypeEnv = Map.fromList [(foreignDeclName foreignDecl, foreignDeclType foreignDecl) | foreignDecl <- foreignDecls]
      termEnv = Map.unions [declTypeEnv, foreignTypeEnv, Map.map constructorInfoType constructorEnv]

  traverse_ (checkRouteDecl ctx termEnv) routeDecls
  coreDecls <- traverse (checkDecl ctx termEnv) decls
  pure
    CoreModule
      { coreModuleName = moduleName modl
      , coreModuleTypeDecls = typeDecls
      , coreModuleRecordDecls = builtinRecordDecls <> recordDecls
      , coreModuleForeignDecls = foreignDecls
      , coreModuleRouteDecls = routeDecls
      , coreModuleDecls = coreDecls
      }

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

ensureKnownTypes :: TypeDeclEnv -> RecordDeclEnv -> [TypeDecl] -> [RecordDecl] -> [ForeignDecl] -> [Decl] -> [RouteDecl] -> Either DiagnosticBundle ()
ensureKnownTypes typeDeclEnv recordDeclEnv typeDecls recordDecls foreignDecls decls routeDecls = do
  mapM_ checkTypeDecl typeDecls
  mapM_ checkRecordDecl recordDecls
  mapM_ checkForeignDecl foreignDecls
  mapM_ checkDeclAnnotation decls
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
        TNamed name ->
          unless (Map.member name recordDeclEnv || maybe False isJsonEnumTypeDecl (Map.lookup name typeDeclEnv)) $
            Left . diagnosticBundle $
              [ diagnostic
                  "E_SCHEMA_FIELD_TYPE"
                  ("Record `" <> recordDeclName recordDecl <> "` uses unsupported field type `" <> name <> "` for `" <> recordFieldDeclName fieldDecl <> "`.")
                  (Just (recordFieldDeclSpan fieldDecl))
                  ["Record fields currently support primitive types, nested record types, and nullary enum types only."]
                  [diagnosticRelated "record declaration" (recordDeclNameSpan recordDecl)]
              ]
        TFunction _ _ ->
          Left . diagnosticBundle $
            [ diagnostic
                "E_SCHEMA_FIELD_TYPE"
                ("Record `" <> recordDeclName recordDecl <> "` uses a function field for `" <> recordFieldDeclName fieldDecl <> "`.")
                (Just (recordFieldDeclSpan fieldDecl))
                ["Record fields currently support primitive types, nested record types, and nullary enum types only."]
                [diagnosticRelated "record declaration" (recordDeclNameSpan recordDecl)]
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
      unless (typeName == pageTypeName || Map.member typeName recordDeclEnv) $
        Left . diagnosticBundle $
          [ diagnostic
              "E_ROUTE_TYPE"
              ("Route `" <> routeDeclName routeDecl <> "` must use a record type or Page for its response body.")
              (Just primarySpan)
              ["Declare `" <> typeName <> "` as a record or return `Page` from the route."]
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
                  localEnv = Map.fromList (zip params (fmap draftParamType draftParams))
              body <- inferExpr ctx termEnv localEnv (declBody decl)
              unify
                ( UnifyContext
                    { unifyCode = "E_TYPE_MISMATCH"
                    , unifySummary = "Type mismatch."
                    , unifyPrimarySpan = exprSpan (declBody decl)
                    , unifyRelated = annotationRelated decl
                    }
                )
                (draftExprType body)
                (typeToInferType resultType)
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
      let draftParams = zipWith DraftParam params paramTypes
          localEnv = Map.fromList (zip params paramTypes)
      body <- inferExpr ctx termEnv localEnv (declBody decl)
      pure
        DraftDecl
          { draftDeclName = name
          , draftDeclType = IFunction paramTypes (draftExprType body)
          , draftDeclParams = draftParams
          , draftDeclBody = body
          }

inferExpr :: ModuleContext -> DeclTypeEnv -> Map.Map Text InferType -> Expr -> InferM DraftExpr
inferExpr ctx termEnv localEnv expr =
  case expr of
    EVar span' name ->
      if name == "empty" && Map.notMember name localEnv && Map.notMember name termEnv
        then pure (DraftExpr span' (INamed viewTypeName) DraftViewEmpty)
        else case Map.lookup name localEnv of
        Just localType ->
          pure (DraftExpr span' localType (DraftVar name))
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
    ECall callSpan fn args ->
      case fn of
        EVar _ name
          | isBuiltinViewFunctionName name
          , Map.notMember name localEnv
          , Map.notMember name termEnv ->
              inferBuiltinViewCall ctx termEnv localEnv callSpan name args
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

inferRegularCall :: ModuleContext -> DeclTypeEnv -> Map.Map Text InferType -> SourceSpan -> Expr -> [Expr] -> InferM DraftExpr
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

inferBuiltinViewCall :: ModuleContext -> DeclTypeEnv -> Map.Map Text InferType -> SourceSpan -> Text -> [Expr] -> InferM DraftExpr
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
          draftChild <- inferExpr ctx termEnv localEnv childExpr
          unifyViewBuiltinArg "link child" draftChild (INamed viewTypeName)
          pure (DraftExpr callSpan (INamed viewTypeName) (DraftViewLink href draftChild))
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
          draftChild <- inferExpr ctx termEnv localEnv childExpr
          unifyViewBuiltinArg "form child" draftChild (INamed viewTypeName)
          pure (DraftExpr callSpan (INamed viewTypeName) (DraftViewForm method action draftChild))
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

inferBuiltinAuthCall :: ModuleContext -> DeclTypeEnv -> Map.Map Text InferType -> SourceSpan -> Text -> [Expr] -> InferM DraftExpr
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

inferRecordExpr :: ModuleContext -> DeclTypeEnv -> Map.Map Text InferType -> SourceSpan -> Text -> [RecordFieldExpr] -> InferM DraftExpr
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

inferFieldAccessExpr :: ModuleContext -> DeclTypeEnv -> Map.Map Text InferType -> SourceSpan -> Expr -> Text -> InferM DraftExpr
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

inferDecodeExpr :: ModuleContext -> DeclTypeEnv -> Map.Map Text InferType -> SourceSpan -> Type -> Expr -> InferM DraftExpr
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

inferEncodeExpr :: ModuleContext -> DeclTypeEnv -> Map.Map Text InferType -> SourceSpan -> Expr -> InferM DraftExpr
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

inferMatchExpr :: ModuleContext -> DeclTypeEnv -> Map.Map Text InferType -> SourceSpan -> Expr -> [MatchBranch] -> InferM DraftExpr
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
  Map.Map Text InferType ->
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
          [ (draftPatternBinderName binder, draftPatternBinderType binder)
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
                  ["Use a record type, a primitive type, or a nullary enum type at the JSON boundary."]
                  []
              ]
    TFunction _ _ ->
      Just . diagnosticBundle $
        [ diagnostic
            "E_JSON_TYPE"
            "JSON codecs do not support function values."
            (Just primarySpan)
            ["Use a record type, a primitive type, or a nullary enum type at the JSON boundary."]
            []
        ]

jsonTypeUnsupportedBundle :: Maybe Text -> Type -> DiagnosticBundle
jsonTypeUnsupportedBundle maybeContext typ =
  diagnosticBundle
    [ diagnostic
        "E_JSON_TYPE"
        summary
        Nothing
        ["Use a record type, a primitive type, or a nullary enum type at the JSON boundary."]
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
          prefix <> "JSON codecs currently support record, primitive, and nullary enum types, but got `" <> renderType typ <> "`."

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
    DraftPage title body -> do
      frozenTitle <- freezeDraftExpr ctx decl inferState title
      frozenBody <- freezeDraftExpr ctx decl inferState body
      pure (CPage (draftExprSpan draftExpr) frozenTitle frozenBody)
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
    DraftViewLink href child -> do
      frozenChild <- freezeDraftExpr ctx decl inferState child
      pure (CViewLink (draftExprSpan draftExpr) href frozenChild)
    DraftViewForm method action child -> do
      frozenChild <- freezeDraftExpr ctx decl inferState child
      pure (CViewForm (draftExprSpan draftExpr) method action frozenChild)
    DraftViewInput fieldName inputKind value -> do
      frozenValue <- freezeDraftExpr ctx decl inferState value
      pure (CViewInput (draftExprSpan draftExpr) fieldName inputKind frozenValue)
    DraftViewSubmit label -> do
      frozenLabel <- freezeDraftExpr ctx decl inferState label
      pure (CViewSubmit (draftExprSpan draftExpr) frozenLabel)
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
    TNamed name ->
      INamed name
    TFunction args result ->
      IFunction (fmap typeToInferType args) (typeToInferType result)

freshTypeVar :: InferM InferType
freshTypeVar = do
  nextVar <- gets inferNextTypeVar
  modify' (\state -> state {inferNextTypeVar = nextVar + 1})
  pure (IVar nextVar)

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
  case runState (runExceptT (unInferM action)) (InferState 0 Map.empty) of
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
