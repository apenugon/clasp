{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit
  ( Assertion
  , assertBool
  , assertEqual
  , assertFailure
  , testCase
  )
import Weft.Compiler (checkSource, compileSource, parseSource)
import Weft.Diagnostic (Diagnostic (..), DiagnosticBundle (..), renderDiagnosticBundle)
import Weft.Syntax
  ( Decl (..)
  , Expr (..)
  , Module (..)
  , ModuleName (..)
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
    , compileTests
    ]

parserTests :: TestTree
parserTests =
  testGroup
    "parser"
    [ testCase "parses declaration annotations" $
        assertEqual
          "annotation should attach to following declaration"
          (Right expectedModule)
          (parseSource "inline" annotatedIdentitySource)
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
    , testCase "reports undefined names" $
        assertHasCode "E_UNBOUND_NAME" (checkSource "bad" unboundNameSource)
    , testCase "reports missing function annotations" $
        assertHasCode "E_MISSING_ANNOTATION" (checkSource "bad" missingAnnotationSource)
    , testCase "reports type mismatches" $
        assertHasCode "E_TYPE_MISMATCH" (checkSource "bad" mismatchSource)
    , testCase "reports duplicate declarations" $
        assertHasCode "E_DUPLICATE_DECL" (checkSource "bad" duplicateDeclSource)
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

annotatedIdentitySource :: Text
annotatedIdentitySource =
  T.unlines
    [ "module Main"
    , ""
    , "id : Str -> Str"
    , "id x = x"
    ]

expectedModule :: Module
expectedModule =
  Module
    { moduleName = ModuleName "Main"
    , moduleDecls =
        [ Decl
            { declName = "id"
            , declAnnotation = Just (TFunction [TStr] TStr)
            , declParams = ["x"]
            , declBody = EVar "x"
            }
        ]
    }

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
