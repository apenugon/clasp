{-# LANGUAGE OverloadedStrings #-}

module Weft.Checker
  ( TypeEnv
  , checkModule
  ) where

import Control.Monad (foldM, when)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
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
  ( Decl (..)
  , Expr (..)
  , Module (..)
  , SourceSpan
  , Type (..)
  , exprSpan
  , renderType
  )

type TypeEnv = Map.Map Text Type

data InferError
  = DeferredName Text SourceSpan
  | FatalError DiagnosticBundle

checkModule :: Module -> Either DiagnosticBundle TypeEnv
checkModule modl = do
  let decls = moduleDecls modl
  ensureUniqueDecls decls
  ensureFunctionAnnotations decls

  let initialEnv =
        Map.fromList
          [ (declName decl, annotatedType)
          | decl <- decls
          , Just annotatedType <- [declAnnotation decl]
          ]
      declMap = Map.fromList [(declName decl, decl) | decl <- decls]

  inferredEnv <- inferValueDecls declMap initialEnv
  mapM_ (checkDecl declMap inferredEnv) decls
  pure inferredEnv

ensureUniqueDecls :: [Decl] -> Either DiagnosticBundle ()
ensureUniqueDecls = go Map.empty
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

inferValueDecls :: Map.Map Text Decl -> TypeEnv -> Either DiagnosticBundle TypeEnv
inferValueDecls declMap initialEnv = loop pendingDecls initialEnv
  where
    pendingDecls =
      [ decl
      | decl <- Map.elems declMap
      , null (declParams decl)
      , isNothing (declAnnotation decl)
      ]

    loop [] env = pure env
    loop pending env = do
      (nextPending, nextEnv, progressed) <- foldM (attemptDecl env) ([], env, False) pending
      if null nextPending
        then pure nextEnv
        else
          if progressed
            then loop (reverse nextPending) nextEnv
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
                  pure nextEnv

    attemptDecl env (remaining, envAcc, progressed) decl =
      case inferExpr declMap env Map.empty (declBody decl) of
        Right inferredType ->
          pure
            ( remaining
            , Map.insert (declName decl) inferredType envAcc
            , True
            )
        Left (DeferredName _ _) ->
          pure (decl : remaining, envAcc, progressed)
        Left (FatalError err) ->
          Left err

checkDecl :: Map.Map Text Decl -> TypeEnv -> Decl -> Either DiagnosticBundle ()
checkDecl declMap env decl =
  case (declParams decl, declAnnotation decl) of
    ([], Nothing) -> do
      _ <- inferExprOrFatal declMap env Map.empty (declBody decl)
      pure ()
    ([], Just annotatedType) -> do
      actualType <- inferExprOrFatal declMap env Map.empty (declBody decl)
      ensureTypeMatches (Just decl) (exprSpan (declBody decl)) annotatedType actualType
    (params, Just annotatedType) -> do
      (argTypes, resultType) <- expectFunctionAnnotation decl params annotatedType
      localEnv <- bindParams params argTypes
      actualType <- inferExprOrFatal declMap env localEnv (declBody decl)
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

inferExprOrFatal :: Map.Map Text Decl -> TypeEnv -> TypeEnv -> Expr -> Either DiagnosticBundle Type
inferExprOrFatal declMap env localEnv expr =
  case inferExpr declMap env localEnv expr of
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

inferExpr :: Map.Map Text Decl -> TypeEnv -> TypeEnv -> Expr -> Either InferError Type
inferExpr declMap env localEnv expr =
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
      fnType <- inferExpr declMap env localEnv fn
      applyCall declMap env localEnv callSpan fn fnType args

applyCall :: Map.Map Text Decl -> TypeEnv -> TypeEnv -> SourceSpan -> Expr -> Type -> [Expr] -> Either InferError Type
applyCall declMap env localEnv callSpan fnExpr fnType args =
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
                  (relatedForFunction fnExpr declMap)
              ]
        else do
          actualArgTypes <- traverse (inferExpr declMap env localEnv) args
          mapM_ (uncurry (ensureArgumentTypeMatches fnExpr declMap)) (zip args (zip paramTypes actualArgTypes))
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

ensureArgumentTypeMatches :: Expr -> Map.Map Text Decl -> Expr -> (Type, Type) -> Either InferError ()
ensureArgumentTypeMatches fnExpr declMap argExpr (expected, actual) =
  when (expected /= actual) $
    Left . FatalError $
      diagnosticBundle
        [ diagnostic
            "E_TYPE_MISMATCH"
            "Argument type does not match the function signature."
            (Just (exprSpan argExpr))
            ["Expected " <> renderType expected <> " but got " <> renderType actual <> "."]
            (relatedForFunction fnExpr declMap)
        ]

annotationRelated :: Maybe Decl -> [DiagnosticRelated]
annotationRelated Nothing = []
annotationRelated (Just decl) =
  case declAnnotationSpan decl of
    Just annotationSpan ->
      [diagnosticRelated "type annotation" annotationSpan]
    Nothing ->
      [diagnosticRelated "declaration" (declNameSpan decl)]

relatedForFunction :: Expr -> Map.Map Text Decl -> [DiagnosticRelated]
relatedForFunction fnExpr declMap =
  case fnExpr of
    EVar _ name ->
      case Map.lookup name declMap of
        Just decl ->
          annotationRelated (Just decl)
        Nothing ->
          []
    _ ->
      []
