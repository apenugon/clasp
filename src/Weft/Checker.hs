{-# LANGUAGE OverloadedStrings #-}

module Weft.Checker
  ( TypeEnv
  , checkModule
  ) where

import Control.Monad (foldM, unless, when)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Weft.Diagnostic
  ( DiagnosticBundle
  , singleDiagnostic
  )
import Weft.Syntax
  ( Decl (..)
  , Expr (..)
  , Module (..)
  , Type (..)
  , renderType
  )

type TypeEnv = Map.Map Text Type

data InferError
  = DeferredName Text
  | FatalError DiagnosticBundle

checkModule :: Module -> Either DiagnosticBundle TypeEnv
checkModule modl = do
  let decls = moduleDecls modl
  ensureUniqueDecls decls
  let missingFunctionAnnotations =
        [ declName decl
        | decl <- decls
        , not (null (declParams decl))
        , isNothing (declAnnotation decl)
        ]
  unless (null missingFunctionAnnotations) $
    Left $
      singleDiagnostic
        "E_MISSING_ANNOTATION"
        "Function declarations currently require type annotations."
        ["Add signatures for: " <> T.intercalate ", " missingFunctionAnnotations <> "."]

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
      if Map.member (declName decl) seen
        then
          Left $
            singleDiagnostic
              "E_DUPLICATE_DECL"
              ("Duplicate declaration for `" <> declName decl <> "`.")
              ["Each top-level name may only be declared once."]
        else
          go (Map.insert (declName decl) () seen) rest

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
                    singleDiagnostic
                      "E_CANNOT_INFER"
                      ("Could not infer the type of `" <> declName unresolvedDecl <> "`.")
                      ["Add an explicit type annotation or reorder dependent declarations."]
                [] ->
                  pure nextEnv

    attemptDecl env (remaining, envAcc, progressed) decl =
      case inferExpr declMap env Map.empty (declBody decl) of
        Right inferredType ->
          pure
            ( remaining
            , Map.insert (declName decl) inferredType envAcc
            , True || progressed
            )
        Left (DeferredName _) ->
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
      ensureTypeMatches (declName decl) annotatedType actualType
    (params, Just annotatedType) -> do
      (argTypes, resultType) <- expectFunctionAnnotation (declName decl) params annotatedType
      localEnv <- bindParams params argTypes
      actualType <- inferExprOrFatal declMap env localEnv (declBody decl)
      ensureTypeMatches (declName decl) resultType actualType
    (_, Nothing) ->
      pure ()

expectFunctionAnnotation :: Text -> [Text] -> Type -> Either DiagnosticBundle ([Type], Type)
expectFunctionAnnotation declName' params annotatedType =
  case annotatedType of
    TFunction argTypes resultType -> do
      when (length argTypes /= length params) $
        Left $
          singleDiagnostic
            "E_ARITY_MISMATCH"
            ("Type annotation for `" <> declName' <> "` does not match the declared parameter count.")
            [ "Expected "
                <> T.pack (show (length params))
                <> " parameter types but got "
                <> T.pack (show (length argTypes))
                <> "."
            ]
      pure (argTypes, resultType)
    _ ->
      Left $
        singleDiagnostic
          "E_ARITY_MISMATCH"
          ("Declaration `" <> declName' <> "` has parameters but a non-function annotation.")
          ["Use a function type such as `Str -> Str`."]

bindParams :: [Text] -> [Type] -> Either DiagnosticBundle TypeEnv
bindParams params argTypes =
  pure (Map.fromList (zip params argTypes))

inferExprOrFatal :: Map.Map Text Decl -> TypeEnv -> TypeEnv -> Expr -> Either DiagnosticBundle Type
inferExprOrFatal declMap env localEnv expr =
  case inferExpr declMap env localEnv expr of
    Right inferredType ->
      Right inferredType
    Left (DeferredName deferredName) ->
      Left $
        singleDiagnostic
          "E_CANNOT_INFER"
          ("Could not resolve the type of `" <> deferredName <> "` yet.")
          ["Add an explicit annotation to break the dependency chain."]
    Left (FatalError err) ->
      Left err

inferExpr :: Map.Map Text Decl -> TypeEnv -> TypeEnv -> Expr -> Either InferError Type
inferExpr declMap env localEnv expr =
  case expr of
    EVar name ->
      case Map.lookup name localEnv of
        Just localType ->
          Right localType
        Nothing ->
          case Map.lookup name env of
            Just topLevelType ->
              Right topLevelType
            Nothing ->
              if Map.member name declMap
                then Left (DeferredName name)
                else
                  Left . FatalError $
                    singleDiagnostic
                      "E_UNBOUND_NAME"
                      ("Unknown name `" <> name <> "`.")
                      ["Introduce a declaration or fix the spelling of the reference."]
    EInt _ ->
      Right TInt
    EString _ ->
      Right TStr
    EBool _ ->
      Right TBool
    ECall fn args -> do
      fnType <- inferExpr declMap env localEnv fn
      applyCall declMap env localEnv fnType args

applyCall :: Map.Map Text Decl -> TypeEnv -> TypeEnv -> Type -> [Expr] -> Either InferError Type
applyCall declMap env localEnv fnType args =
  case fnType of
    TFunction paramTypes resultType ->
      if length paramTypes /= length args
        then
          Left . FatalError $
            singleDiagnostic
              "E_CALL_ARITY"
              "Function call does not match the declared arity."
              [ "Expected "
                  <> T.pack (show (length paramTypes))
                  <> " arguments but got "
                  <> T.pack (show (length args))
                  <> "."
              ]
        else do
          actualArgTypes <- traverse (inferExpr declMap env localEnv) args
          mapM_ (uncurry ensureTypeMatchesInInfer) (zip paramTypes actualArgTypes)
          Right resultType
    _ ->
      Left . FatalError $
        singleDiagnostic
          "E_NOT_A_FUNCTION"
          "Tried to call a non-function value."
          ["Only function-typed values can be applied to arguments."]

ensureTypeMatches :: Text -> Type -> Type -> Either DiagnosticBundle ()
ensureTypeMatches name expected actual =
  when (expected /= actual) $
    Left $
      singleDiagnostic
        "E_TYPE_MISMATCH"
        ("Type mismatch in `" <> name <> "`.")
        [ "Expected " <> renderType expected <> " but got " <> renderType actual <> "." ]

ensureTypeMatchesInInfer :: Type -> Type -> Either InferError ()
ensureTypeMatchesInInfer expected actual =
  when (expected /= actual) $
    Left . FatalError $
      singleDiagnostic
        "E_TYPE_MISMATCH"
        "Argument type does not match the function signature."
        [ "Expected " <> renderType expected <> " but got " <> renderType actual <> "." ]
