{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit
  ( Assertion
  , assertBool
  , assertEqual
  , assertFailure
  , testCase
  )
import Weft.Compiler (checkSource, compileSource, parseSource)
import Weft.Diagnostic
  ( Diagnostic (..)
  , DiagnosticBundle (..)
  , renderDiagnosticBundle
  , renderDiagnosticBundleJson
  )
import Weft.Syntax
  ( Decl (..)
  , Expr (..)
  , Module (..)
  , ModuleName (..)
  , Position (..)
  , SourceSpan (..)
  , Type (..)
  )

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "weft-compiler"
    [ parserTests
    , checkerTests
    , diagnosticTests
    , compileTests
    ]

parserTests :: TestTree
parserTests =
  testGroup
    "parser"
    [ testCase "parses declaration annotations with spans" $
        case parseSource "inline" annotatedIdentitySource of
          Left err ->
            assertFailure ("expected parse success:\n" <> T.unpack (renderDiagnosticBundle err))
          Right modl -> do
            assertEqual "module name" (ModuleName "Main") (moduleName modl)
            case moduleDecls modl of
              [decl] -> do
                assertEqual "decl name" "id" (declName decl)
                assertEqual "annotation" (Just (TFunction [TStr] TStr)) (declAnnotation decl)
                assertEqual "param names" ["x"] (declParams decl)
                assertEqual "annotation line" (Just 3) (positionLine . sourceSpanStart <$> declAnnotationSpan decl)
                case declBody decl of
                  EVar span' "x" ->
                    assertEqual "body variable line" 4 (positionLine (sourceSpanStart span'))
                  _ ->
                    assertFailure "expected variable expression body"
              other ->
                assertFailure ("expected one declaration, got " <> show (length other))
    ]

checkerTests :: TestTree
checkerTests =
  testGroup
    "checker"
    [ testCase "accepts the example program" $
        case checkSource "hello" helloSource of
          Left err ->
            assertFailure ("expected hello source to typecheck:\n" <> T.unpack (renderDiagnosticBundle err))
          Right _ ->
            pure ()
    , testCase "reports undefined names with a primary span" $
        case checkSource "bad" unboundNameSource of
          Left bundle -> do
            err <- expectFirstDiagnostic bundle
            assertEqual "code" "E_UNBOUND_NAME" (diagnosticCode err)
            assertEqual "primary line" (Just 3) (positionLine . sourceSpanStart <$> diagnosticPrimarySpan err)
            assertEqual "primary column" (Just 8) (positionColumn . sourceSpanStart <$> diagnosticPrimarySpan err)
          Right _ ->
            assertFailure "expected undefined-name failure"
    , testCase "reports missing function annotations" $
        assertHasCode "E_MISSING_ANNOTATION" (checkSource "bad" missingAnnotationSource)
    , testCase "reports type mismatches with the argument span" $
        case checkSource "bad" mismatchSource of
          Left bundle -> do
            err <- expectFirstDiagnostic bundle
            assertEqual "code" "E_TYPE_MISMATCH" (diagnosticCode err)
            assertEqual "primary line" (Just 6) (positionLine . sourceSpanStart <$> diagnosticPrimarySpan err)
            assertEqual "primary column" (Just 11) (positionColumn . sourceSpanStart <$> diagnosticPrimarySpan err)
          Right _ ->
            assertFailure "expected type mismatch failure"
    , testCase "reports duplicate declarations with related location" $
        case checkSource "bad" duplicateDeclSource of
          Left bundle -> do
            err <- expectFirstDiagnostic bundle
            assertEqual "code" "E_DUPLICATE_DECL" (diagnosticCode err)
            assertEqual "one related span" 1 (length (diagnosticRelatedSpans err))
          Right _ ->
            assertFailure "expected duplicate declaration failure"
    ]

diagnosticTests :: TestTree
diagnosticTests =
  testGroup
    "diagnostics"
    [ testCase "json rendering includes codes and source spans" $
        case checkSource "bad" unboundNameSource of
          Left bundle -> do
            let jsonText = LT.toStrict (renderDiagnosticBundleJson bundle)
            assertBool "expected code in json" ("\"code\":\"E_UNBOUND_NAME\"" `T.isInfixOf` jsonText)
            assertBool "expected primary span in json" ("\"primarySpan\"" `T.isInfixOf` jsonText)
            assertBool "expected file in json" ("\"file\":\"bad\"" `T.isInfixOf` jsonText)
          Right _ ->
            assertFailure "expected json diagnostic failure"
    , testCase "pretty rendering includes related locations" $
        case checkSource "bad" duplicateDeclSource of
          Left bundle -> do
            let rendered = renderDiagnosticBundle bundle
            assertBool "expected related marker" ("related previous declaration" `T.isInfixOf` rendered)
          Right _ ->
            assertFailure "expected duplicate declaration failure"
    ]

compileTests :: TestTree
compileTests =
  testGroup
    "compile"
    [ testCase "compile emits JavaScript for a checked module" $
        case compileSource "hello" helloSource of
          Left err ->
            assertFailure ("expected compile to succeed:\n" <> T.unpack (renderDiagnosticBundle err))
          Right emitted ->
            assertBool "expected emitted JavaScript to export id" ("export function id" `T.isInfixOf` emitted)
    ]

assertHasCode :: Text -> Either DiagnosticBundle a -> Assertion
assertHasCode code result =
  case result of
    Left (DiagnosticBundle errs) ->
      assertBool
        ("expected diagnostic code " <> T.unpack code <> " but got:\n" <> T.unpack (renderDiagnosticBundle (DiagnosticBundle errs)))
        (any ((== code) . diagnosticCode) errs)
    Right _ ->
      assertFailure ("expected failure with code " <> T.unpack code)

expectFirstDiagnostic :: DiagnosticBundle -> IO Diagnostic
expectFirstDiagnostic (DiagnosticBundle errs) =
  case errs of
    firstErr : _ ->
      pure firstErr
    [] ->
      assertFailure "expected at least one diagnostic"

annotatedIdentitySource :: Text
annotatedIdentitySource =
  T.unlines
    [ "module Main"
    , ""
    , "id : Str -> Str"
    , "id x = x"
    ]

helloSource :: Text
helloSource =
  T.unlines
    [ "module Main"
    , ""
    , "hello = \"Hello from Weft\""
    , ""
    , "id : Str -> Str"
    , "id v = v"
    , ""
    , "main = id hello"
    ]

unboundNameSource :: Text
unboundNameSource =
  T.unlines
    [ "module Main"
    , ""
    , "main = missing"
    ]

missingAnnotationSource :: Text
missingAnnotationSource =
  T.unlines
    [ "module Main"
    , ""
    , "identity value = value"
    ]

mismatchSource :: Text
mismatchSource =
  T.unlines
    [ "module Main"
    , ""
    , "id : Str -> Str"
    , "id value = value"
    , ""
    , "main = id 42"
    ]

duplicateDeclSource :: Text
duplicateDeclSource =
  T.unlines
    [ "module Main"
    , ""
    , "hello = \"first\""
    , "hello = \"second\""
    ]
