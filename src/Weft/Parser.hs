{-# LANGUAGE OverloadedStrings #-}

module Weft.Parser
  ( parseModule
  ) where

import Control.Monad (foldM, void, when)
import Data.Bifunctor (first)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (Void)
import Text.Megaparsec
  ( Parsec
  , between
  , eof
  , errorBundlePretty
  , many
  , manyTill
  , notFollowedBy
  , optional
  , parse
  , sepBy1
  , some
  , try
  , (<|>)
  )
import qualified Text.Megaparsec as MP
import Text.Megaparsec.Char
  ( alphaNumChar
  , char
  , eol
  , letterChar
  , space1
  , string
  , upperChar
  )
import qualified Text.Megaparsec.Char.Lexer as L
import Weft.Diagnostic
  ( DiagnosticBundle
  , singleDiagnostic
  )
import Weft.Syntax
  ( Decl (..)
  , Expr (..)
  , Module (..)
  , ModuleName (..)
  , Type (..)
  )

type Parser = Parsec Void Text

data TopLevelItem
  = TopSignature Text Type
  | TopDecl Decl

parseModule :: FilePath -> Text -> Either DiagnosticBundle Module
parseModule path source =
  attachSignatures =<<
    first
      (\bundle -> singleDiagnostic "E_PARSE" "Failed to parse source." [T.pack (errorBundlePretty bundle)])
      (parse (moduleParser <* eof) path source)

moduleParser :: Parser (ModuleName, [TopLevelItem])
moduleParser = do
  scn
  keyword "module"
  name <- moduleNameParser
  scn
  items <- some topLevelItemParser
  pure (ModuleName name, items)

topLevelItemParser :: Parser TopLevelItem
topLevelItemParser =
  try typeSignatureParser
    <|> (TopDecl <$> declParser)

typeSignatureParser :: Parser TopLevelItem
typeSignatureParser = do
  name <- identifier
  _ <- symbol ":"
  annotatedType <- typeParser
  _ <- optional eol
  scn
  pure (TopSignature name annotatedType)

declParser :: Parser Decl
declParser = do
  name <- identifier
  params <- many identifier
  _ <- symbol "="
  body <- exprParser
  _ <- optional eol
  scn
  pure Decl
    { declName = name
    , declAnnotation = Nothing
    , declParams = params
    , declBody = body
    }

exprParser :: Parser Expr
exprParser = do
  atoms <- some atomParser
  case atoms of
    firstAtom : remainingAtoms ->
      pure (foldl applyExpr firstAtom remainingAtoms)
    [] ->
      fail "expected at least one expression atom"

atomParser :: Parser Expr
atomParser =
  parens exprParser
    <|> boolParser
    <|> intParser
    <|> stringParser
    <|> (EVar <$> identifier)

boolParser :: Parser Expr
boolParser =
  (keyword "true" *> pure (EBool True))
    <|> (keyword "false" *> pure (EBool False))

intParser :: Parser Expr
intParser = EInt <$> lexeme L.decimal

stringParser :: Parser Expr
stringParser = EString . T.pack <$> lexeme (char '"' *> manyTill L.charLiteral (char '"'))

typeParser :: Parser Type
typeParser = do
  parts <- typeAtomParser `sepBy1` symbol "->"
  pure (buildFunctionType parts)

typeAtomParser :: Parser Type
typeAtomParser =
  parens typeParser
    <|> (keyword "Int" *> pure TInt)
    <|> (keyword "Str" *> pure TStr)
    <|> (keyword "Bool" *> pure TBool)

moduleNameParser :: Parser Text
moduleNameParser =
  lexeme $
    T.intercalate "." <$> sepBy1 moduleSegment (char '.')
  where
    moduleSegment = T.pack <$> ((:) <$> upperChar <*> many identTailChar)

identifier :: Parser Text
identifier = lexeme . try $ do
  name <- T.pack <$> ((:) <$> letterChar <*> many identTailChar)
  when (name `elem` reservedWords) $
    fail ("reserved word " <> show name <> " cannot be used as an identifier")
  pure name

keyword :: Text -> Parser ()
keyword word = lexeme . try $ do
  void (string word)
  notFollowedBy identTailChar

reservedWords :: [Text]
reservedWords =
  [ "module"
  , "true"
  , "false"
  , "Int"
  , "Str"
  , "Bool"
  ]

applyExpr :: Expr -> Expr -> Expr
applyExpr fn arg =
  case fn of
    ECall target args -> ECall target (args <> [arg])
    _ -> ECall fn [arg]

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

symbol :: Text -> Parser Text
symbol = L.symbol sc

parens :: Parser a -> Parser a
parens = between (symbol "(") (symbol ")")

sc :: Parser ()
sc = L.space (void $ some (char ' ' <|> char '\t')) lineComment MP.empty

scn :: Parser ()
scn = L.space space1 lineComment MP.empty

lineComment :: Parser ()
lineComment = L.skipLineComment "--"

identTailChar :: Parser Char
identTailChar = alphaNumChar <|> char '_'

buildFunctionType :: [Type] -> Type
buildFunctionType [singleType] = singleType
buildFunctionType manyTypes = TFunction (init manyTypes) (last manyTypes)

attachSignatures :: (ModuleName, [TopLevelItem]) -> Either DiagnosticBundle Module
attachSignatures (name, items) = do
  (decls, pendingSignatures) <- foldM step ([], Map.empty) items
  if null pendingSignatures
    then
      pure Module
        { moduleName = name
        , moduleDecls = reverse decls
        }
    else
      let orphanNames = T.intercalate ", " (Map.keys pendingSignatures)
       in Left $
            singleDiagnostic
              "E_ORPHAN_SIGNATURE"
              "Found type signatures without matching declarations."
              ["Missing declarations for: " <> orphanNames <> "."]
  where
    step (decls, pendingSignatures) item =
      case item of
        TopSignature sigName sigType ->
          if Map.member sigName pendingSignatures
            then
              Left $
                singleDiagnostic
                  "E_DUPLICATE_SIGNATURE"
                  ("Duplicate type signature for `" <> sigName <> "`.")
                  ["Keep only one type signature per declaration."]
            else
              pure (decls, Map.insert sigName sigType pendingSignatures)
        TopDecl decl ->
          let annotation = Map.lookup (declName decl) pendingSignatures
              updatedDecl = decl {declAnnotation = annotation}
              remaining = Map.delete (declName decl) pendingSignatures
           in pure (updatedDecl : decls, remaining)
