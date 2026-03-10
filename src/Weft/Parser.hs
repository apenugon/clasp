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
  , sepBy
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
  , lowerChar
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
  ( ConstructorDecl (..)
  , Decl (..)
  , Expr (..)
  , ForeignDecl (..)
  , ImportDecl (..)
  , MatchBranch (..)
  , Module (..)
  , ModuleName (..)
  , PatternBinder (..)
  , Pattern (..)
  , Position (..)
  , RecordDecl (..)
  , RecordFieldDecl (..)
  , RecordFieldExpr (..)
  , RouteDecl (..)
  , RouteMethod (..)
  , SourceSpan (..)
  , Type (..)
  , TypeDecl (..)
  , exprSpan
  , mergeSourceSpans
  )

type Parser = Parsec Void Text

data TopLevelItem
  = TopTypeDecl TypeDecl
  | TopRecordDecl RecordDecl
  | TopForeignDecl ForeignDecl
  | TopRouteDecl RouteDecl
  | TopSignature Text Type SourceSpan
  | TopDecl Decl

parseModule :: FilePath -> Text -> Either DiagnosticBundle Module
parseModule path source =
  attachSignatures =<<
    first
      (\bundle -> singleDiagnostic "E_PARSE" "Failed to parse source." [T.pack (errorBundlePretty bundle)])
      (parse (moduleParser <* eof) path source)

moduleParser :: Parser (ModuleName, [ImportDecl], [TopLevelItem])
moduleParser = do
  scn
  keyword "module"
  name <- moduleNameParser
  scn
  imports <- many importParser
  items <- some topLevelItemParser
  pure (ModuleName name, imports, items)

importParser :: Parser ImportDecl
importParser = do
  start <- getSourcePos
  keyword "import"
  importName <- moduleNameParser
  end <- getSourcePos
  _ <- optional eol
  scn
  pure
    ImportDecl
      { importDeclModule = ModuleName importName
      , importDeclSpan = makeSourceSpan start end
      }

topLevelItemParser :: Parser TopLevelItem
topLevelItemParser =
  try foreignDeclParser
    <|> try routeDeclParser
    <|> try recordDeclParser
    <|> try typeDeclParser
    <|> try typeSignatureParser
    <|> (TopDecl <$> declParser)

foreignDeclParser :: Parser TopLevelItem
foreignDeclParser = do
  start <- getSourcePos
  keyword "foreign"
  (nameSpan, name) <- locatedLowerIdentifier
  annotationStart <- getSourcePos
  _ <- symbol ":"
  foreignType <- typeParser
  annotationEnd <- getSourcePos
  _ <- symbol "="
  (runtimeSpan, runtimeName) <- locatedStringLiteral
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopForeignDecl $
    ForeignDecl
      { foreignDeclName = name
      , foreignDeclSpan = makeSourceSpan start end
      , foreignDeclNameSpan = nameSpan
      , foreignDeclAnnotationSpan = makeSourceSpan annotationStart annotationEnd
      , foreignDeclType = foreignType
      , foreignDeclRuntimeName = runtimeName
      , foreignDeclRuntimeSpan = runtimeSpan
      }

routeDeclParser :: Parser TopLevelItem
routeDeclParser = do
  start <- getSourcePos
  keyword "route"
  (nameSpan, name) <- locatedLowerIdentifier
  _ <- symbol "="
  method <- routeMethodParser
  (pathSpan, routePath) <- locatedStringLiteral
  (requestTypeSpan, requestTypeName) <- locatedUpperIdentifier
  _ <- symbol "->"
  (responseTypeSpan, responseTypeName) <- locatedUpperIdentifier
  (handlerSpan, handlerName) <- locatedLowerIdentifier
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopRouteDecl $
    RouteDecl
      { routeDeclName = name
      , routeDeclSpan = makeSourceSpan start end
      , routeDeclNameSpan = nameSpan
      , routeDeclMethod = method
      , routeDeclPath = routePath
      , routeDeclPathSpan = pathSpan
      , routeDeclRequestType = requestTypeName
      , routeDeclRequestTypeSpan = requestTypeSpan
      , routeDeclResponseType = responseTypeName
      , routeDeclResponseTypeSpan = responseTypeSpan
      , routeDeclHandlerName = handlerName
      , routeDeclHandlerSpan = handlerSpan
      }

routeMethodParser :: Parser RouteMethod
routeMethodParser =
  (keyword "GET" *> pure RouteGet)
    <|> (keyword "POST" *> pure RoutePost)

recordDeclParser :: Parser TopLevelItem
recordDeclParser = do
  start <- getSourcePos
  keyword "record"
  (nameSpan, name) <- locatedUpperIdentifier
  _ <- symbol "="
  fields <- braces (recordFieldDeclParser `sepBy` symbolN ",")
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopRecordDecl $
    RecordDecl
      { recordDeclName = name
      , recordDeclSpan = makeSourceSpan start end
      , recordDeclNameSpan = nameSpan
      , recordDeclFields = fields
      }

recordFieldDeclParser :: Parser RecordFieldDecl
recordFieldDeclParser = do
  start <- getSourcePos
  (_, fieldName) <- locatedLowerIdentifierN
  _ <- symbolN ":"
  fieldType <- typeParser
  end <- getSourcePos
  pure
    RecordFieldDecl
      { recordFieldDeclName = fieldName
      , recordFieldDeclSpan = makeSourceSpan start end
      , recordFieldDeclType = fieldType
      }

typeDeclParser :: Parser TopLevelItem
typeDeclParser = do
  start <- getSourcePos
  keyword "type"
  (nameSpan, name) <- locatedUpperIdentifier
  _ <- symbol "="
  constructors <- constructorDeclParser `sepBy1` symbol "|"
  end <- getSourcePos
  _ <- optional eol
  scn
  pure . TopTypeDecl $
    TypeDecl
      { typeDeclName = name
      , typeDeclSpan = makeSourceSpan start end
      , typeDeclNameSpan = nameSpan
      , typeDeclConstructors = constructors
      }

constructorDeclParser :: Parser ConstructorDecl
constructorDeclParser = do
  start <- getSourcePos
  (nameSpan, name) <- locatedUpperIdentifier
  fields <- many typeAtomParser
  end <- getSourcePos
  pure
    ConstructorDecl
      { constructorDeclName = name
      , constructorDeclSpan = makeSourceSpan start end
      , constructorDeclNameSpan = nameSpan
      , constructorDeclFields = fields
      }

typeSignatureParser :: Parser TopLevelItem
typeSignatureParser = do
  start <- getSourcePos
  (_, name) <- locatedLowerIdentifier
  _ <- symbol ":"
  annotatedType <- typeParser
  end <- getSourcePos
  _ <- optional eol
  scn
  pure (TopSignature name annotatedType (makeSourceSpan start end))

declParser :: Parser Decl
declParser = do
  start <- getSourcePos
  (nameSpan, name) <- locatedLowerIdentifier
  params <- many lowerIdentifier
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
  terms <- some termParser
  case terms of
    firstTerm : remainingTerms ->
      pure (foldl applyExpr firstTerm remainingTerms)
    [] ->
      fail "expected at least one expression term"

termParser :: Parser Expr
termParser = do
  baseExpr <- baseExprParser
  fieldAccesses <- many fieldAccessSuffixParser
  pure (foldl applyFieldAccess baseExpr fieldAccesses)

baseExprParser :: Parser Expr
baseExprParser =
  parens exprParser
    <|> decodeParser
    <|> encodeParser
    <|> matchParser
    <|> boolParser
    <|> intParser
    <|> stringParser
    <|> try recordExprParser
    <|> constructorExprParser
    <|> variableParser

matchParser :: Parser Expr
matchParser = do
  start <- getSourcePos
  keyword "match"
  subject <- exprParser
  branches <- braces (matchBranchParser `sepBy1` symbolN ",")
  end <- getSourcePos
  pure (EMatch (makeSourceSpan start end) subject branches)

matchBranchParser :: Parser MatchBranch
matchBranchParser = do
  start <- getSourcePos
  pattern' <- patternParser
  _ <- symbolN "->"
  body <- exprParser
  end <- getSourcePos
  pure
    MatchBranch
      { matchBranchSpan = makeSourceSpan start end
      , matchBranchPattern = pattern'
      , matchBranchBody = body
      }

decodeParser :: Parser Expr
decodeParser = do
  start <- getSourcePos
  keyword "decode"
  targetType <- typeAtomParser
  rawJson <- exprParser
  end <- getSourcePos
  pure (EDecode (makeSourceSpan start end) targetType rawJson)

encodeParser :: Parser Expr
encodeParser = do
  start <- getSourcePos
  keyword "encode"
  value <- exprParser
  end <- getSourcePos
  pure (EEncode (makeSourceSpan start end) value)

patternParser :: Parser Pattern
patternParser = do
  (constructorSpan, constructorName) <- locatedUpperIdentifierN
  binders <- many patternBinderParser
  pure (PConstructor constructorSpan constructorName binders)

patternBinderParser :: Parser PatternBinder
patternBinderParser = do
  (binderSpan, binderName) <- locatedLowerIdentifier
  pure
    PatternBinder
      { patternBinderName = binderName
      , patternBinderSpan = binderSpan
      }

recordExprParser :: Parser Expr
recordExprParser = do
  start <- getSourcePos
  (_, recordName) <- locatedUpperIdentifier
  fields <- braces (recordFieldExprParser `sepBy` symbolN ",")
  end <- getSourcePos
  pure (ERecord (makeSourceSpan start end) recordName fields)

recordFieldExprParser :: Parser RecordFieldExpr
recordFieldExprParser = do
  start <- getSourcePos
  (_, fieldName) <- locatedLowerIdentifierN
  _ <- symbolN "="
  fieldValue <- exprParser
  end <- getSourcePos
  pure
    RecordFieldExpr
      { recordFieldExprName = fieldName
      , recordFieldExprSpan = makeSourceSpan start end
      , recordFieldExprValue = fieldValue
      }

fieldAccessSuffixParser :: Parser (SourceSpan, Text)
fieldAccessSuffixParser = do
  _ <- char '.'
  locatedLexemeWith sc lowerIdentifierRaw

variableParser :: Parser Expr
variableParser = do
  (span', name) <- locatedLowerIdentifier
  pure (EVar span' name)

constructorExprParser :: Parser Expr
constructorExprParser = do
  (span', name) <- locatedUpperIdentifier
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
  (span', value) <- locatedStringLiteral
  pure (EString span' value)

locatedStringLiteral :: Parser (SourceSpan, Text)
locatedStringLiteral =
  locatedLexeme (T.pack <$> (char '"' *> manyTill L.charLiteral (char '"')))

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
    <|> (TNamed <$> upperIdentifier)

moduleNameParser :: Parser Text
moduleNameParser =
  lexeme $
    T.intercalate "." <$> sepBy1 moduleSegment (char '.')
  where
    moduleSegment = T.pack <$> ((:) <$> upperChar <*> many identTailChar)

lowerIdentifier :: Parser Text
lowerIdentifier = snd <$> locatedLowerIdentifier

upperIdentifier :: Parser Text
upperIdentifier = snd <$> locatedUpperIdentifier

locatedLowerIdentifier :: Parser (SourceSpan, Text)
locatedLowerIdentifier = locatedLexeme lowerIdentifierRaw

locatedLowerIdentifierN :: Parser (SourceSpan, Text)
locatedLowerIdentifierN = locatedLexemeWith scn lowerIdentifierRaw

locatedUpperIdentifier :: Parser (SourceSpan, Text)
locatedUpperIdentifier = locatedLexeme upperIdentifierRaw

locatedUpperIdentifierN :: Parser (SourceSpan, Text)
locatedUpperIdentifierN = locatedLexemeWith scn upperIdentifierRaw

lowerIdentifierRaw :: Parser Text
lowerIdentifierRaw = do
  name <- T.pack <$> ((:) <$> lowerChar <*> many identTailChar)
  when (name `elem` reservedWords) $
    fail ("reserved word " <> show name <> " cannot be used as an identifier")
  pure name

upperIdentifierRaw :: Parser Text
upperIdentifierRaw =
  T.pack <$> ((:) <$> upperChar <*> many identTailChar)

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

applyFieldAccess :: Expr -> (SourceSpan, Text) -> Expr
applyFieldAccess subject (fieldSpan, fieldName) =
  EFieldAccess (mergeSourceSpans (exprSpan subject) fieldSpan) subject fieldName

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

locatedLexeme :: Parser a -> Parser (SourceSpan, a)
locatedLexeme = locatedLexemeWith sc

locatedLexemeWith :: Parser () -> Parser a -> Parser (SourceSpan, a)
locatedLexemeWith spaceConsumer parser = do
  start <- getSourcePos
  value <- parser
  end <- getSourcePos
  spaceConsumer
  pure (makeSourceSpan start end, value)

symbol :: Text -> Parser Text
symbol = L.symbol sc

symbolN :: Text -> Parser Text
symbolN = L.symbol scn

parens :: Parser a -> Parser a
parens = between (symbol "(") (symbol ")")

braces :: Parser a -> Parser a
braces parser =
  between openBrace closeBrace (scn *> parser <* scn)
  where
    openBrace = L.symbol scn "{"
    closeBrace = L.symbol sc "}"

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

attachSignatures :: (ModuleName, [ImportDecl], [TopLevelItem]) -> Either DiagnosticBundle Module
attachSignatures (name, imports, items) = do
  (typeDecls, recordDecls, foreignDecls, routeDecls, decls, pendingSignatures) <- foldM step ([], [], [], [], [], Map.empty) items
  if null pendingSignatures
    then
      pure Module
        { moduleName = name
        , moduleImports = imports
        , moduleTypeDecls = reverse typeDecls
        , moduleRecordDecls = reverse recordDecls
        , moduleForeignDecls = reverse foreignDecls
        , moduleRouteDecls = reverse routeDecls
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
    step (typeDecls, recordDecls, foreignDecls, routeDecls, decls, pendingSignatures) item =
      case item of
        TopTypeDecl typeDecl ->
          pure (typeDecl : typeDecls, recordDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopRecordDecl recordDecl ->
          pure (typeDecls, recordDecl : recordDecls, foreignDecls, routeDecls, decls, pendingSignatures)
        TopForeignDecl foreignDecl ->
          pure (typeDecls, recordDecls, foreignDecl : foreignDecls, routeDecls, decls, pendingSignatures)
        TopRouteDecl routeDecl ->
          pure (typeDecls, recordDecls, foreignDecls, routeDecl : routeDecls, decls, pendingSignatures)
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
              pure (typeDecls, recordDecls, foreignDecls, routeDecls, decls, Map.insert sigName (sigType, signatureSpan) pendingSignatures)
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
           in pure (typeDecls, recordDecls, foreignDecls, routeDecls, updatedDecl : decls, remaining)

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
  , "import"
  , "type"
  , "record"
  , "foreign"
  , "route"
  , "decode"
  , "encode"
  , "match"
  , "true"
  , "false"
  , "Int"
  , "Str"
  , "Bool"
  ]
