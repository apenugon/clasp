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
  , SourcePos
  , between
  , eof
  , errorBundlePretty
  , getSourcePos
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
import Text.Megaparsec.Pos (unPos)
import Weft.Diagnostic
  ( DiagnosticBundle
  , diagnostic
  , diagnosticBundle
  , diagnosticRelated
  , singleDiagnostic
  )
import Weft.Syntax
  ( Decl (..)
  , Expr (..)
  , Module (..)
  , ModuleName (..)
  , Position (..)
  , SourceSpan (..)
  , Type (..)
  , exprSpan
  , mergeSourceSpans
  )

type Parser = Parsec Void Text

data TopLevelItem
  = TopSignature Text Type SourceSpan
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
  start <- getSourcePos
  (_, name) <- locatedIdentifier
  _ <- symbol ":"
  annotatedType <- typeParser
  end <- getSourcePos
  _ <- optional eol
  scn
  pure (TopSignature name annotatedType (makeSourceSpan start end))

declParser :: Parser Decl
declParser = do
  start <- getSourcePos
  (nameSpan, name) <- locatedIdentifier
  params <- many identifier
  _ <- symbol "="
  body <- exprParser
  end <- getSourcePos
  _ <- optional eol
  scn
  pure Decl
    { declName = name
    , declSpan = makeSourceSpan start end
    , declNameSpan = nameSpan
    , declAnnotationSpan = Nothing
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
    <|> variableParser

variableParser :: Parser Expr
variableParser = do
  (span', name) <- locatedIdentifier
  pure (EVar span' name)

boolParser :: Parser Expr
boolParser =
  locatedKeywordExpr "true" (\span' -> EBool span' True)
    <|> locatedKeywordExpr "false" (\span' -> EBool span' False)

intParser :: Parser Expr
intParser = do
  (span', value) <- locatedLexeme L.decimal
  pure (EInt span' value)

stringParser :: Parser Expr
stringParser = do
  (span', value) <- locatedLexeme (T.pack <$> (char '"' *> manyTill L.charLiteral (char '"')))
  pure (EString span' value)

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
identifier = snd <$> locatedIdentifier

locatedIdentifier :: Parser (SourceSpan, Text)
locatedIdentifier = locatedLexeme identifierRaw

identifierRaw :: Parser Text
identifierRaw = do
  name <- T.pack <$> ((:) <$> letterChar <*> many identTailChar)
  when (name `elem` reservedWords) $
    fail ("reserved word " <> show name <> " cannot be used as an identifier")
  pure name

keyword :: Text -> Parser ()
keyword word = lexeme (keywordRaw word)

keywordRaw :: Text -> Parser ()
keywordRaw word = do
  void (string word)
  notFollowedBy identTailChar

locatedKeywordExpr :: Text -> (SourceSpan -> Expr) -> Parser Expr
locatedKeywordExpr word constructor = do
  (span', _) <- locatedLexeme (keywordRaw word)
  pure (constructor span')

applyExpr :: Expr -> Expr -> Expr
applyExpr fn arg =
  let callSpan = mergeSourceSpans (exprSpan fn) (exprSpan arg)
   in case fn of
        ECall _ target args ->
          ECall callSpan target (args <> [arg])
        _ ->
          ECall callSpan fn [arg]

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

locatedLexeme :: Parser a -> Parser (SourceSpan, a)
locatedLexeme parser = do
  start <- getSourcePos
  value <- parser
  end <- getSourcePos
  sc
  pure (makeSourceSpan start end, value)

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
      Left . diagnosticBundle $
        [ diagnostic
            "E_ORPHAN_SIGNATURE"
            ("Found a type signature for `" <> sigName <> "` without a matching declaration.")
            (Just signatureSpan)
            ["Add a matching declaration or remove the signature."]
            []
        | (sigName, (_, signatureSpan)) <- Map.toList pendingSignatures
        ]
  where
    step (decls, pendingSignatures) item =
      case item of
        TopSignature sigName sigType signatureSpan ->
          case Map.lookup sigName pendingSignatures of
            Just (_, existingSpan) ->
              Left . diagnosticBundle $
                [ diagnostic
                    "E_DUPLICATE_SIGNATURE"
                    ("Duplicate type signature for `" <> sigName <> "`.")
                    (Just signatureSpan)
                    ["Keep only one type signature per declaration."]
                    [diagnosticRelated "previous signature" existingSpan]
                ]
            Nothing ->
              pure (decls, Map.insert sigName (sigType, signatureSpan) pendingSignatures)
        TopDecl decl ->
          let annotationData = Map.lookup (declName decl) pendingSignatures
              updatedDecl =
                case annotationData of
                  Just (annotation, annotationSpan) ->
                    decl
                      { declAnnotation = Just annotation
                      , declAnnotationSpan = Just annotationSpan
                      }
                  Nothing ->
                    decl
              remaining = Map.delete (declName decl) pendingSignatures
           in pure (updatedDecl : decls, remaining)

makeSourceSpan :: SourcePos -> SourcePos -> SourceSpan
makeSourceSpan start end =
  SourceSpan
    { sourceSpanFile = T.pack (MP.sourceName start)
    , sourceSpanStart = toPosition start
    , sourceSpanEnd = toPosition end
    }

toPosition :: SourcePos -> Position
toPosition pos =
  Position
    { positionLine = unPos (MP.sourceLine pos)
    , positionColumn = unPos (MP.sourceColumn pos)
    }

reservedWords :: [Text]
reservedWords =
  [ "module"
  , "true"
  , "false"
  , "Int"
  , "Str"
  , "Bool"
  ]
