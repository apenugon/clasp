{-# LANGUAGE OverloadedStrings #-}

module Weft.Checker
  ( TypeEnv
  , checkModule
  ) where

import Control.Monad (foldM, unless, when)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Weft.Diagnostic
  ( DiagnosticBundle
  , DiagnosticRelated
  , diagnostic
  , diagnosticBundle
  , diagnosticRelated
  , singleDiagnosticAt
  )
import Weft.Syntax
  ( ConstructorDecl (..)
  , Decl (..)
  , Expr (..)
  , MatchBranch (..)
  , Module (..)
  , Pattern (..)
  , PatternBinder (..)
  , SourceSpan
  , Type (..)
  , TypeDecl (..)
  , exprSpan
  , renderType
  )

type TypeEnv = Map.Map Text Type
type TypeDeclEnv = Map.Map Text TypeDecl

data ConstructorInfo = ConstructorInfo
  { constructorInfoTypeName :: Text
  , constructorInfoDecl :: ConstructorDecl
  }

type ConstructorEnv = Map.Map Text ConstructorInfo

data InferError
  = DeferredName Text SourceSpan
  | FatalError DiagnosticBundle

checkModule :: Module -> Either DiagnosticBundle TypeEnv
checkModule modl = do
  let typeDecls = moduleTypeDecls modl
      decls = moduleDecls modl

  ensureUniqueTypeDecls typeDecls
  let typeDeclEnv = Map.fromList [(typeDeclName typeDecl, typeDecl) | typeDecl <- typeDecls]
  ensureKnownTypes typeDeclEnv typeDecls decls

  constructorEnv <- buildConstructorEnv typeDecls
  ensureUniqueDecls decls constructorEnv
  ensureFunctionAnnotations decls

  let annotatedDeclEnv =
        Map.fromList
          [ (declName decl, annotatedType)
          | decl <- decls
          , Just annotatedType <- [declAnnotation decl]
          ]
      constructorTypeEnv =
        Map.map constructorInfoType constructorEnv
      initialTermEnv =
        Map.union annotatedDeclEnv constructorTypeEnv
      declMap = Map.fromList [(declName decl, decl) | decl <- decls]

  inferredDeclEnv <-
    inferValueDecls
      typeDeclEnv
      constructorEnv
      declMap
      initialTermEnv
      annotatedDeclEnv

  let checkedTermEnv = Map.union inferredDeclEnv constructorTypeEnv
  mapM_ (checkDecl typeDeclEnv constructorEnv declMap checkedTermEnv) decls
  pure inferredDeclEnv

ensureUniqueTypeDecls :: [TypeDecl] -> Either DiagnosticBundle ()
ensureUniqueTypeDecls = go Map.empty
  where
    go _ [] = pure ()
    go seen (typeDecl : rest) =
      case Map.lookup (typeDeclName typeDecl) seen of
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

ensureKnownTypes :: TypeDeclEnv -> [TypeDecl] -> [Decl] -> Either DiagnosticBundle ()
ensureKnownTypes typeDeclEnv typeDecls decls = do
  mapM_ checkTypeDecl typeDecls
  mapM_ checkDeclAnnotation decls
  where
    checkTypeDecl typeDecl =
      mapM_ (checkConstructorFields typeDecl) (typeDeclConstructors typeDecl)

    checkConstructorFields typeDecl constructorDecl =
      mapM_
        (ensureKnownType (constructorDeclSpan constructorDecl) [diagnosticRelated "type declaration" (typeDeclNameSpan typeDecl)])
        (constructorDeclFields constructorDecl)

    checkDeclAnnotation decl =
      case declAnnotation decl of
        Just annotation ->
          ensureKnownType
            (fromMaybe (declNameSpan decl) (declAnnotationSpan decl))
            [diagnosticRelated "declaration" (declNameSpan decl)]
            annotation
        Nothing ->
          pure ()

    ensureKnownType primarySpan related typ =
      case typ of
        TInt ->
          pure ()
        TStr ->
          pure ()
        TBool ->
          pure ()
        TNamed name ->
          unless (Map.member name typeDeclEnv) $
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

ensureUniqueDecls :: [Decl] -> ConstructorEnv -> Either DiagnosticBundle ()
ensureUniqueDecls decls constructorEnv = go Map.empty decls
  where
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
              go (Map.insert (declName decl) decl seen) rest

ensureFunctionAnnotations :: [Decl] -> Either DiagnosticBundle ()
ensureFunctionAnnotations decls =
  case missing of
    [] ->
      pure ()
    _ ->
      Left . diagnosticBundle $
        [ diagnostic
            "E_MISSING_ANNOTATION"
            ("Function declaration `" <> declName decl <> "` requires a type annotation.")
            (Just (declNameSpan decl))
            ["Add a declaration signature such as `name : Str -> Str` above the definition."]
            []
        | decl <- missing
        ]
  where
    missing =
      [ decl
      | decl <- decls
      , not (null (declParams decl))
      , isNothing (declAnnotation decl)
      ]

inferValueDecls ::
  TypeDeclEnv ->
  ConstructorEnv ->
  Map.Map Text Decl ->
  TypeEnv ->
  TypeEnv ->
  Either DiagnosticBundle TypeEnv
inferValueDecls typeDeclEnv constructorEnv declMap initialTermEnv initialDeclEnv = loop pendingDecls initialDeclEnv initialTermEnv
  where
    pendingDecls =
      [ decl
      | decl <- Map.elems declMap
      , null (declParams decl)
      , isNothing (declAnnotation decl)
      ]

    loop [] declEnv _ = pure declEnv
    loop pending declEnv termEnv = do
      (nextPending, nextDeclEnv, nextTermEnv, progressed) <- foldM (attemptDecl termEnv) ([], declEnv, termEnv, False) pending
      if null nextPending
        then pure nextDeclEnv
        else
          if progressed
            then loop (reverse nextPending) nextDeclEnv nextTermEnv
            else
              case reverse nextPending of
                unresolvedDecl : _ ->
                  Left $
                    singleDiagnosticAt
                      "E_CANNOT_INFER"
                      ("Could not infer the type of `" <> declName unresolvedDecl <> "`.")
                      (declNameSpan unresolvedDecl)
                      ["Add an explicit type annotation or reorder dependent declarations."]
                [] ->
                  pure nextDeclEnv

    attemptDecl termEnv (remaining, declEnvAcc, termEnvAcc, progressed) decl =
      case inferExpr typeDeclEnv constructorEnv declMap termEnv Map.empty (declBody decl) of
        Right inferredType ->
          pure
            ( remaining
            , Map.insert (declName decl) inferredType declEnvAcc
            , Map.insert (declName decl) inferredType termEnvAcc
            , True
            )
        Left (DeferredName _ _) ->
          pure (decl : remaining, declEnvAcc, termEnvAcc, progressed)
        Left (FatalError err) ->
          Left err

checkDecl :: TypeDeclEnv -> ConstructorEnv -> Map.Map Text Decl -> TypeEnv -> Decl -> Either DiagnosticBundle ()
checkDecl typeDeclEnv constructorEnv declMap env decl =
  case (declParams decl, declAnnotation decl) of
    ([], Nothing) -> do
      _ <- inferExprOrFatal typeDeclEnv constructorEnv declMap env Map.empty (declBody decl)
      pure ()
    ([], Just annotatedType) -> do
      actualType <- inferExprOrFatal typeDeclEnv constructorEnv declMap env Map.empty (declBody decl)
      ensureTypeMatches (Just decl) (exprSpan (declBody decl)) annotatedType actualType
    (params, Just annotatedType) -> do
      (argTypes, resultType) <- expectFunctionAnnotation decl params annotatedType
      localEnv <- bindParams params argTypes
      actualType <- inferExprOrFatal typeDeclEnv constructorEnv declMap env localEnv (declBody decl)
      ensureTypeMatches (Just decl) (exprSpan (declBody decl)) resultType actualType
    (_, Nothing) ->
      pure ()

expectFunctionAnnotation :: Decl -> [Text] -> Type -> Either DiagnosticBundle ([Type], Type)
expectFunctionAnnotation decl params annotatedType =
  case annotatedType of
    TFunction argTypes resultType -> do
      when (length argTypes /= length params) $
        Left . diagnosticBundle $
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
      pure (argTypes, resultType)
    _ ->
      Left . diagnosticBundle $
        [ diagnostic
            "E_ARITY_MISMATCH"
            ("Declaration `" <> declName decl <> "` has parameters but a non-function annotation.")
            (declAnnotationSpan decl)
            ["Use a function type such as `Str -> Str`."]
            [diagnosticRelated "declaration" (declNameSpan decl)]
        ]

bindParams :: [Text] -> [Type] -> Either DiagnosticBundle TypeEnv
bindParams params argTypes =
  pure (Map.fromList (zip params argTypes))

inferExprOrFatal ::
  TypeDeclEnv ->
  ConstructorEnv ->
  Map.Map Text Decl ->
  TypeEnv ->
  TypeEnv ->
  Expr ->
  Either DiagnosticBundle Type
inferExprOrFatal typeDeclEnv constructorEnv declMap env localEnv expr =
  case inferExpr typeDeclEnv constructorEnv declMap env localEnv expr of
    Right inferredType ->
      Right inferredType
    Left (DeferredName deferredName deferredSpan) ->
      Left $
        singleDiagnosticAt
          "E_CANNOT_INFER"
          ("Could not resolve the type of `" <> deferredName <> "` yet.")
          deferredSpan
          ["Add an explicit annotation to break the dependency chain."]
    Left (FatalError err) ->
      Left err

inferExpr ::
  TypeDeclEnv ->
  ConstructorEnv ->
  Map.Map Text Decl ->
  TypeEnv ->
  TypeEnv ->
  Expr ->
  Either InferError Type
inferExpr typeDeclEnv constructorEnv declMap env localEnv expr =
  case expr of
    EVar span' name ->
      case Map.lookup name localEnv of
        Just localType ->
          Right localType
        Nothing ->
          case Map.lookup name env of
            Just topLevelType ->
              Right topLevelType
            Nothing ->
              if Map.member name declMap
                then Left (DeferredName name span')
                else
                  Left . FatalError $
                    singleDiagnosticAt
                      "E_UNBOUND_NAME"
                      ("Unknown name `" <> name <> "`.")
                      span'
                      ["Introduce a declaration or fix the spelling of the reference."]
    EInt _ _ ->
      Right TInt
    EString _ _ ->
      Right TStr
    EBool _ _ ->
      Right TBool
    ECall callSpan fn args -> do
      fnType <- inferExpr typeDeclEnv constructorEnv declMap env localEnv fn
      applyCall typeDeclEnv constructorEnv declMap env localEnv callSpan fn fnType args
    EMatch matchSpan subject branches -> do
      subjectType <- inferExpr typeDeclEnv constructorEnv declMap env localEnv subject
      inferMatch typeDeclEnv constructorEnv declMap env localEnv matchSpan subjectType branches

inferMatch ::
  TypeDeclEnv ->
  ConstructorEnv ->
  Map.Map Text Decl ->
  TypeEnv ->
  TypeEnv ->
  SourceSpan ->
  Type ->
  [MatchBranch] ->
  Either InferError Type
inferMatch typeDeclEnv constructorEnv declMap env localEnv matchSpan subjectType branches =
  case subjectType of
    TNamed typeName ->
      case Map.lookup typeName typeDeclEnv of
        Just typeDecl -> do
          resultType <- inferMatchBranches typeDeclEnv constructorEnv declMap env localEnv typeDecl branches
          ensureExhaustiveMatch typeDecl branches matchSpan
          pure resultType
        Nothing ->
          Left . FatalError $
            singleDiagnosticAt
              "E_UNKNOWN_TYPE"
              ("Unknown type `" <> typeName <> "`.")
              matchSpan
              ["Declare the type before matching on it."]
    _ ->
      Left . FatalError $
        diagnosticBundle
          [ diagnostic
              "E_MATCH_SUBJECT"
              "Match expressions require an algebraic data type subject."
              (Just matchSpan)
              ["Expected a named sum type but got " <> renderType subjectType <> "."]
              []
          ]

inferMatchBranches ::
  TypeDeclEnv ->
  ConstructorEnv ->
  Map.Map Text Decl ->
  TypeEnv ->
  TypeEnv ->
  TypeDecl ->
  [MatchBranch] ->
  Either InferError Type
inferMatchBranches typeDeclEnv constructorEnv declMap env localEnv typeDecl branches = do
  (_, firstBranchType) <- foldM step (Map.empty, Nothing) branches
  case firstBranchType of
    Just (typ, _) ->
      pure typ
    Nothing ->
      Left . FatalError $
        diagnosticBundle
          [ diagnostic
              "E_EMPTY_MATCH"
              "Match expressions require at least one branch."
              (Just (typeDeclSpan typeDecl))
              ["Add branches for each constructor in the matched type."]
              []
          ]
  where
    step (seenConstructors, firstType) branch = do
      (constructorName, fieldTypes) <- resolveBranchPattern typeDecl branch
      case Map.lookup constructorName seenConstructors of
        Just previousBranch ->
          Left . FatalError $
            diagnosticBundle
              [ diagnostic
                  "E_DUPLICATE_MATCH_BRANCH"
                  ("Duplicate match branch for constructor `" <> constructorName <> "`.")
                  (Just (matchBranchSpan branch))
                  ["Each constructor may appear at most once in a match expression."]
                  [diagnosticRelated "previous branch" (matchBranchSpan previousBranch)]
              ]
        Nothing ->
          pure ()

      binderEnv <- bindPatternFields branch fieldTypes
      branchType <- inferExpr typeDeclEnv constructorEnv declMap env (Map.union binderEnv localEnv) (matchBranchBody branch)
      case firstType of
        Nothing ->
          pure (Map.insert constructorName branch seenConstructors, Just (branchType, branch))
        Just (expectedType, expectedBranch) ->
          if branchType == expectedType
            then pure (Map.insert constructorName branch seenConstructors, firstType)
            else
              Left . FatalError $
                diagnosticBundle
                  [ diagnostic
                      "E_MATCH_RESULT_TYPE"
                      "Match branches must all return the same type."
                      (Just (matchBranchSpan branch))
                      [ "Expected " <> renderType expectedType <> " but got " <> renderType branchType <> "." ]
                      [diagnosticRelated "first branch" (matchBranchSpan expectedBranch)]
                  ]

    resolveBranchPattern expectedTypeDecl branch =
      case matchBranchPattern branch of
        PConstructor constructorSpan constructorName binders ->
          case Map.lookup constructorName constructorEnv of
            Nothing ->
              Left . FatalError $
                singleDiagnosticAt
                  "E_UNKNOWN_CONSTRUCTOR"
                  ("Unknown constructor `" <> constructorName <> "`.")
                  constructorSpan
                  ["Declare the constructor before using it in a match branch."]
            Just constructorInfo ->
              if constructorInfoTypeName constructorInfo /= typeDeclName expectedTypeDecl
                then
                  Left . FatalError $
                    diagnosticBundle
                      [ diagnostic
                          "E_PATTERN_TYPE_MISMATCH"
                          ("Constructor `" <> constructorName <> "` does not belong to type `" <> typeDeclName expectedTypeDecl <> "`.")
                          (Just constructorSpan)
                          ["Use a constructor declared by the matched type."]
                          [diagnosticRelated "constructor declaration" (constructorDeclNameSpan (constructorInfoDecl constructorInfo))]
                      ]
                else
                  let fieldTypes = constructorDeclFields (constructorInfoDecl constructorInfo)
                   in if length binders /= length fieldTypes
                        then
                          Left . FatalError $
                            diagnosticBundle
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
                        else
                          Right (constructorName, fieldTypes)

    bindPatternFields branch fieldTypes =
      case matchBranchPattern branch of
        PConstructor _ _ binders -> do
          ensureUniquePatternBinders binders
          pure (Map.fromList (zip (fmap patternBinderName binders) fieldTypes))

ensureUniquePatternBinders :: [PatternBinder] -> Either InferError ()
ensureUniquePatternBinders = go Map.empty
  where
    go _ [] = pure ()
    go seen (binder : rest) =
      case Map.lookup (patternBinderName binder) seen of
        Just previousBinder ->
          Left . FatalError $
            diagnosticBundle
              [ diagnostic
                  "E_DUPLICATE_PATTERN_BINDER"
                  ("Duplicate pattern binder `" <> patternBinderName binder <> "`.")
                  (Just (patternBinderSpan binder))
                  ["Each bound name may only appear once within a single match pattern."]
                  [diagnosticRelated "previous binder" (patternBinderSpan previousBinder)]
              ]
        Nothing ->
          go (Map.insert (patternBinderName binder) binder seen) rest

ensureExhaustiveMatch :: TypeDecl -> [MatchBranch] -> SourceSpan -> Either InferError ()
ensureExhaustiveMatch typeDecl branches matchSpan =
  let expectedConstructors = fmap constructorDeclName (typeDeclConstructors typeDecl)
      branchConstructors =
        [ constructorName
        | MatchBranch _ (PConstructor _ constructorName _) _ <- branches
        ]
      missingConstructors =
        filter (`notElem` branchConstructors) expectedConstructors
   in unless (null missingConstructors) $
        Left . FatalError $
          diagnosticBundle
            [ diagnostic
                "E_NONEXHAUSTIVE_MATCH"
                "Match expression is missing constructors."
                (Just matchSpan)
                ["Add branches for: " <> T.intercalate ", " missingConstructors <> "."]
                [diagnosticRelated "type declaration" (typeDeclNameSpan typeDecl)]
            ]

applyCall ::
  TypeDeclEnv ->
  ConstructorEnv ->
  Map.Map Text Decl ->
  TypeEnv ->
  TypeEnv ->
  SourceSpan ->
  Expr ->
  Type ->
  [Expr] ->
  Either InferError Type
applyCall typeDeclEnv constructorEnv declMap env localEnv callSpan fnExpr fnType args =
  case fnType of
    TFunction paramTypes resultType ->
      if length paramTypes /= length args
        then
          Left . FatalError $
            diagnosticBundle
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
                  (relatedForFunction fnExpr declMap constructorEnv)
              ]
        else do
          actualArgTypes <- traverse (inferExpr typeDeclEnv constructorEnv declMap env localEnv) args
          mapM_ (uncurry (ensureArgumentTypeMatches fnExpr declMap constructorEnv)) (zip args (zip paramTypes actualArgTypes))
          Right resultType
    _ ->
      Left . FatalError $
        diagnosticBundle
          [ diagnostic
              "E_NOT_A_FUNCTION"
              "Tried to call a non-function value."
              (Just callSpan)
              ["Only function-typed values can be applied to arguments."]
              []
          ]

ensureTypeMatches :: Maybe Decl -> SourceSpan -> Type -> Type -> Either DiagnosticBundle ()
ensureTypeMatches declContext primarySpan expected actual =
  when (expected /= actual) $
    Left . diagnosticBundle $
      [ diagnostic
          "E_TYPE_MISMATCH"
          "Type mismatch."
          (Just primarySpan)
          ["Expected " <> renderType expected <> " but got " <> renderType actual <> "."]
          (annotationRelated declContext)
      ]

ensureArgumentTypeMatches :: Expr -> Map.Map Text Decl -> ConstructorEnv -> Expr -> (Type, Type) -> Either InferError ()
ensureArgumentTypeMatches fnExpr declMap constructorEnv argExpr (expected, actual) =
  when (expected /= actual) $
    Left . FatalError $
      diagnosticBundle
        [ diagnostic
            "E_TYPE_MISMATCH"
            "Argument type does not match the function signature."
            (Just (exprSpan argExpr))
            ["Expected " <> renderType expected <> " but got " <> renderType actual <> "."]
            (relatedForFunction fnExpr declMap constructorEnv)
        ]

annotationRelated :: Maybe Decl -> [DiagnosticRelated]
annotationRelated Nothing = []
annotationRelated (Just decl) =
  case declAnnotationSpan decl of
    Just annotationSpan ->
      [diagnosticRelated "type annotation" annotationSpan]
    Nothing ->
      [diagnosticRelated "declaration" (declNameSpan decl)]

relatedForFunction :: Expr -> Map.Map Text Decl -> ConstructorEnv -> [DiagnosticRelated]
relatedForFunction fnExpr declMap constructorEnv =
  case fnExpr of
    EVar _ name ->
      case Map.lookup name declMap of
        Just decl ->
          annotationRelated (Just decl)
        Nothing ->
          case Map.lookup name constructorEnv of
            Just constructorInfo ->
              [diagnosticRelated "constructor declaration" (constructorDeclNameSpan (constructorInfoDecl constructorInfo))]
            Nothing ->
              []
    _ ->
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
