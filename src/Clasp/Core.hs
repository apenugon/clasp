{-# LANGUAGE OverloadedStrings #-}

module Clasp.Core
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
  , CoreRouteContract (..)
  , SemanticEdit (..)
  , applySemanticEdit
  , coreExprType
  ) where

import qualified Data.Set as Set
import Data.Text (Text)
import Clasp.Syntax
  ( ConstructorDecl (..)
  , ForeignDecl (..)
  , ModuleName
  , PolicyDecl (..)
  , ProjectionDecl (..)
  , Position (..)
  , RecordDecl (..)
  , RecordFieldDecl (..)
  , RouteBoundaryDecl (..)
  , RouteDecl (..)
  , RoutePathDecl
  , SourceSpan (..)
  , Type (..)
  , TypeDecl (..)
  )
import Clasp.Diagnostic
  ( DiagnosticBundle
  , singleDiagnosticAt
  )

data CoreModule = CoreModule
  { coreModuleName :: ModuleName
  , coreModuleTypeDecls :: [TypeDecl]
  , coreModuleRecordDecls :: [RecordDecl]
  , coreModulePolicyDecls :: [CorePolicyDecl]
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
        CList span' typ items ->
          CList span' typ (fmap (renameDeclExpr boundNames) items)
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
          , coreModuleProjectionDecls = fmap renameProjectionDecl (coreModuleProjectionDecls modl)
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
        CList span' typ items ->
          CList span' (renameType typ) (fmap renameExprTypes items)
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
