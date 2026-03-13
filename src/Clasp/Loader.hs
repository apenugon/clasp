{-# LANGUAGE OverloadedStrings #-}

module Clasp.Loader
  ( loadEntryModule
  ) where

import Control.Monad (foldM)
import Data.Char (isSpace, toUpper)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, makeAbsolute)
import System.FilePath ((</>), (<.>), joinPath, takeDirectory, takeFileName)
import Clasp.Diagnostic
  ( DiagnosticBundle
  , diagnostic
  , diagnosticBundle
  , diagnosticRelated
  )
import Clasp.Parser (parseModule)
import Clasp.Syntax
  ( ConstructorDecl (..)
  , ForeignDecl (..)
  , ForeignPackageImport (..)
  , ImportDecl (..)
  , Module (..)
  , ModuleName (..)
  , RecordDecl (..)
  , RecordFieldDecl (..)
  , SourceSpan (..)
  , Type (..)
  , TypeDecl (..)
  , renderType
  , splitModuleName
  )

data PackageType
  = PackageTypeString
  | PackageTypeNumber
  | PackageTypeBoolean
  | PackageTypeArray PackageType
  | PackageTypeObject [PackageField]
  | PackageTypeOpaque Text
  | PackageTypeUnchecked Text
  deriving (Eq, Show)

data PackageField = PackageField
  { packageFieldName :: Text
  , packageFieldOptional :: Bool
  , packageFieldType :: Maybe PackageType
  }
  deriving (Eq, Show)

data PackageParam = PackageParam
  { packageParamName :: Text
  , packageParamOptional :: Bool
  , packageParamType :: Maybe PackageType
  }
  deriving (Eq, Show)

data PackageFunctionSignature
  = PackageFunctionSignature [PackageParam] (Maybe PackageType)
  | PackageFunctionUnchecked Text
  deriving (Eq, Show)

data SignatureProblem
  = SignatureMismatch Text
  | SignatureRequiresUnsafe Text
  deriving (Eq, Show)

data LoadState = LoadState
  { loadStateModules :: Map.Map ModuleName Module
  , loadStateOrder :: [ModuleName]
  }

loadEntryModule :: FilePath -> IO (Either DiagnosticBundle Module)
loadEntryModule entryPath = do
  absoluteEntryPath <- makeAbsolute entryPath
  entrySource <- TIO.readFile absoluteEntryPath
  case parseModule (takeFileName absoluteEntryPath) entrySource of
    Left err ->
      pure (Left err)
    Right entryModule -> do
      let projectRoot = takeDirectory absoluteEntryPath
      loadedImports <-
        loadImports
          projectRoot
          (LoadState Map.empty [])
          [moduleName entryModule]
          (moduleImports entryModule)
      case loadedImports of
        Left err ->
          pure (Left err)
        Right state ->
          enrichForeignPackageImports projectRoot (combineModules entryModule state)

loadImports :: FilePath -> LoadState -> [ModuleName] -> [ImportDecl] -> IO (Either DiagnosticBundle LoadState)
loadImports projectRoot state stack imports =
  foldM step (Right state) imports
  where
    step acc importDecl =
      case acc of
        Left err ->
          pure (Left err)
        Right currentState ->
          loadImport projectRoot currentState stack importDecl

loadImport :: FilePath -> LoadState -> [ModuleName] -> ImportDecl -> IO (Either DiagnosticBundle LoadState)
loadImport projectRoot state stack importDecl =
  let importedModuleName = importDeclModule importDecl
   in if importedModuleName `elem` stack
        then
          pure . Left . diagnosticBundle $
            [ diagnostic
                "E_IMPORT_CYCLE"
                ("Import cycle detected at `" <> unModuleName importedModuleName <> "`.")
                (Just (importDeclSpan importDecl))
                ["Break the cycle by moving shared declarations into a separate module."]
                []
            ]
        else
          case Map.lookup importedModuleName (loadStateModules state) of
            Just _ ->
              pure (Right state)
            Nothing ->
              loadModule projectRoot state (stack <> [importedModuleName]) importDecl

loadModule :: FilePath -> LoadState -> [ModuleName] -> ImportDecl -> IO (Either DiagnosticBundle LoadState)
loadModule projectRoot state stack importDecl = do
  let importedModuleName = importDeclModule importDecl
      importedFilePath =
        projectRoot
          </> joinPath (fmap T.unpack (splitModuleName importedModuleName))
          <.> "clasp"
  importedExists <- doesFileExist importedFilePath
  if not importedExists
    then
      pure . Left . diagnosticBundle $
        [ diagnostic
            "E_IMPORT_NOT_FOUND"
            ("Could not find imported module `" <> unModuleName importedModuleName <> "`.")
            (Just (importDeclSpan importDecl))
            ["Expected to find " <> T.pack importedFilePath <> "."]
            []
        ]
    else do
      importedSource <- TIO.readFile importedFilePath
      case parseModule (joinPath (fmap T.unpack (splitModuleName importedModuleName)) <.> "clasp") importedSource of
        Left err ->
          pure (Left err)
        Right importedModule ->
          if moduleName importedModule /= importedModuleName
            then
              pure . Left . diagnosticBundle $
                [ diagnostic
                    "E_IMPORT_NAME"
                    ("Imported file declares module `" <> unModuleName (moduleName importedModule) <> "` but was imported as `" <> unModuleName importedModuleName <> "`.")
                    (Just (importDeclSpan importDecl))
                    ["Rename the module declaration or update the import."]
                    []
                ]
            else do
              nestedResult <- loadNestedImports projectRoot state stack importedModule
              pure $
                fmap
                  ( \nestedState ->
                      nestedState
                        { loadStateModules = Map.insert importedModuleName importedModule (loadStateModules nestedState)
                        , loadStateOrder = loadStateOrder nestedState <> [importedModuleName]
                        }
                  )
                  nestedResult

loadNestedImports :: FilePath -> LoadState -> [ModuleName] -> Module -> IO (Either DiagnosticBundle LoadState)
loadNestedImports projectRoot state stack importedModule =
  loadImports projectRoot state stack (moduleImports importedModule)

combineModules :: Module -> LoadState -> Module
combineModules entryModule state =
  let importedModules =
        [ importedModule
        | importedModuleName <- loadStateOrder state
        , Just importedModule <- [Map.lookup importedModuleName (loadStateModules state)]
        ]
   in Module
        { moduleName = moduleName entryModule
        , moduleImports = []
        , moduleTypeDecls = concatMap moduleTypeDecls (importedModules <> [entryModule])
        , moduleRecordDecls = concatMap moduleRecordDecls (importedModules <> [entryModule])
        , moduleDomainObjectDecls = concatMap moduleDomainObjectDecls (importedModules <> [entryModule])
        , moduleDomainEventDecls = concatMap moduleDomainEventDecls (importedModules <> [entryModule])
        , moduleMetricDecls = concatMap moduleMetricDecls (importedModules <> [entryModule])
        , moduleGoalDecls = concatMap moduleGoalDecls (importedModules <> [entryModule])
        , moduleWorkflowDecls = concatMap moduleWorkflowDecls (importedModules <> [entryModule])
        , moduleSupervisorDecls = concatMap moduleSupervisorDecls (importedModules <> [entryModule])
        , moduleGuideDecls = concatMap moduleGuideDecls (importedModules <> [entryModule])
        , moduleHookDecls = concatMap moduleHookDecls (importedModules <> [entryModule])
        , moduleAgentRoleDecls = concatMap moduleAgentRoleDecls (importedModules <> [entryModule])
        , moduleAgentDecls = concatMap moduleAgentDecls (importedModules <> [entryModule])
        , modulePolicyDecls = concatMap modulePolicyDecls (importedModules <> [entryModule])
        , moduleToolServerDecls = concatMap moduleToolServerDecls (importedModules <> [entryModule])
        , moduleToolDecls = concatMap moduleToolDecls (importedModules <> [entryModule])
        , moduleVerifierDecls = concatMap moduleVerifierDecls (importedModules <> [entryModule])
        , moduleMergeGateDecls = concatMap moduleMergeGateDecls (importedModules <> [entryModule])
        , moduleProjectionDecls = concatMap moduleProjectionDecls (importedModules <> [entryModule])
        , moduleForeignDecls = concatMap moduleForeignDecls (importedModules <> [entryModule])
        , moduleRouteDecls = concatMap moduleRouteDecls (importedModules <> [entryModule])
        , moduleDecls = concatMap moduleDecls (importedModules <> [entryModule])
        }

enrichForeignPackageImports :: FilePath -> Module -> IO (Either DiagnosticBundle Module)
enrichForeignPackageImports projectRoot modl = do
  enrichedForeignDecls <- foldM (enrichForeignDecl projectRoot modl) (Right []) (moduleForeignDecls modl)
  pure $
    fmap
      (\foreignDecls -> modl {moduleForeignDecls = reverse foreignDecls})
      enrichedForeignDecls

enrichForeignDecl :: FilePath -> Module -> Either DiagnosticBundle [ForeignDecl] -> ForeignDecl -> IO (Either DiagnosticBundle [ForeignDecl])
enrichForeignDecl projectRoot modl acc foreignDecl =
  case acc of
    Left err ->
      pure (Left err)
    Right foreignDecls ->
      case foreignDeclPackageImport foreignDecl of
        Nothing ->
          pure (Right (foreignDecl : foreignDecls))
        Just packageImport -> do
          signatureResult <- ingestDeclarationSignature projectRoot modl foreignDecl packageImport
          pure $
            fmap
              ( \signature ->
                  foreignDecl
                    { foreignDeclPackageImport =
                        Just packageImport {foreignPackageImportSignature = Just signature}
                    }
                    : foreignDecls
              )
              signatureResult

ingestDeclarationSignature :: FilePath -> Module -> ForeignDecl -> ForeignPackageImport -> IO (Either DiagnosticBundle Text)
ingestDeclarationSignature projectRoot modl foreignDecl packageImport = do
  let declarationPath =
        projectRoot
          </> takeDirectory (T.unpack (sourceSpanFile (foreignDeclSpan foreignDecl)))
          </> T.unpack (foreignPackageImportDeclarationPath packageImport)
  declarationExists <- doesFileExist declarationPath
  if not declarationExists
    then
      pure . Left . diagnosticBundle $
        [ diagnostic
            "E_FOREIGN_PACKAGE_DECLARATION_NOT_FOUND"
            ("Could not find declaration file for foreign package import `" <> foreignDeclName foreignDecl <> "`.")
            (Just (foreignPackageImportDeclarationSpan packageImport))
            ["Expected to find " <> T.pack declarationPath <> "."]
            []
        ]
    else do
      declarationSource <- TIO.readFile declarationPath
      case findDeclarationSignature (foreignDeclRuntimeName foreignDecl) declarationSource of
        Nothing ->
          pure . Left . diagnosticBundle $
            [ diagnostic
                "E_FOREIGN_PACKAGE_EXPORT_NOT_FOUND"
                ("Could not find exported declaration `" <> foreignDeclRuntimeName foreignDecl <> "` in `" <> foreignPackageImportDeclarationPath packageImport <> "`.")
                (Just (foreignPackageImportDeclarationSpan packageImport))
                ["Export the requested symbol from the declaration file or update the foreign declaration runtime name."]
                []
            ]
        Just signature ->
          case validateForeignPackageSignature modl foreignDecl packageImport signature of
            Left err ->
              pure (Left err)
            Right () ->
              pure (Right signature)

findDeclarationSignature :: Text -> Text -> Maybe Text
findDeclarationSignature runtimeName declarationSource =
  find matchesExport (T.lines declarationSource)
  where
    matchesExport line =
      let stripped = T.strip line
          signaturePrefix prefix =
            (prefix <> runtimeName <> "(") `T.isPrefixOf` stripped
       in or
            [ signaturePrefix "export declare function "
            , signaturePrefix "export function "
            , signaturePrefix "declare function "
            ]
            || stripped == ("export {" <> runtimeName <> "};")
            || stripped == ("export { " <> runtimeName <> " };")

validateForeignPackageSignature :: Module -> ForeignDecl -> ForeignPackageImport -> Text -> Either DiagnosticBundle ()
validateForeignPackageSignature modl foreignDecl packageImport signature =
  case parsePackageFunctionSignature (foreignDeclRuntimeName foreignDecl) signature of
    PackageFunctionUnchecked reason ->
      requireUnsafeLeaf reason
    PackageFunctionSignature params maybeResult ->
      case foreignDeclType foreignDecl of
        TFunction argTypes resultType ->
          case compareFunctionSignature modl foreignDecl argTypes resultType params maybeResult of
            Nothing ->
              Right ()
            Just problem ->
              Left (foreignSignatureProblemBundle problem)
        other ->
          Left (foreignSignatureProblemBundle (SignatureMismatch ("Foreign package declarations must use function types, but found `" <> renderType other <> "`.")))
  where
    requireUnsafeLeaf reason
      | foreignDeclUnsafeInterop foreignDecl =
          Right ()
      | otherwise =
          Left (foreignSignatureProblemBundle (SignatureRequiresUnsafe reason))

    foreignSignatureProblemBundle problem =
      diagnosticBundle
        [ diagnostic
            "E_FOREIGN_PACKAGE_SIGNATURE_MISMATCH"
            ("Foreign package declaration `" <> foreignDeclName foreignDecl <> "` does not match `" <> foreignPackageImportDeclarationPath packageImport <> "`.")
            (Just (foreignDeclAnnotationSpan foreignDecl))
            ( [ "Clasp signature: " <> renderType (foreignDeclType foreignDecl)
              , "Declaration signature: " <> signature
              ]
                <> case problem of
                  SignatureMismatch detail ->
                    [detail]
                  SignatureRequiresUnsafe detail ->
                    [ detail
                    , "Mark the declaration as `foreign unsafe` only if that unchecked package value is intentional."
                    ]
            )
            [ diagnosticRelated "package declaration" (foreignPackageImportDeclarationSpan packageImport)
            , diagnosticRelated "foreign declaration" (foreignDeclNameSpan foreignDecl)
            ]
        ]

compareFunctionSignature :: Module -> ForeignDecl -> [Type] -> Type -> [PackageParam] -> Maybe PackageType -> Maybe SignatureProblem
compareFunctionSignature modl foreignDecl argTypes resultType params maybeResult
  | length argTypes /= length params =
      Just
        (SignatureMismatch ("Expected " <> tshow (length argTypes) <> " parameter(s), but the package declaration exposes " <> tshow (length params) <> "."))
  | otherwise =
      firstJust
        (zipWith (compareParam modl foreignDecl) [1 ..] (zip argTypes params) <> [compareResult modl foreignDecl resultType maybeResult])

compareParam :: Module -> ForeignDecl -> Int -> (Type, PackageParam) -> Maybe SignatureProblem
compareParam modl foreignDecl index (expectedType, packageParam)
  | packageParamOptional packageParam =
      Just (SignatureMismatch ("Parameter " <> tshow index <> " (`" <> packageParamName packageParam <> "`) is optional in the package declaration."))
  | otherwise =
      case packageParamType packageParam of
        Nothing ->
          compareUncheckedLeaf foreignDecl ("Parameter " <> tshow index <> " (`" <> packageParamName packageParam <> "`) is untyped in the package declaration.")
        Just packageType ->
          comparePackageType modl foreignDecl ("parameter " <> tshow index) expectedType packageType

compareResult :: Module -> ForeignDecl -> Type -> Maybe PackageType -> Maybe SignatureProblem
compareResult modl foreignDecl expectedType maybePackageType =
  case maybePackageType of
    Nothing ->
      compareUncheckedLeaf foreignDecl "The package declaration return value is untyped."
    Just packageType ->
      comparePackageType modl foreignDecl "return value" expectedType packageType

comparePackageType :: Module -> ForeignDecl -> Text -> Type -> PackageType -> Maybe SignatureProblem
comparePackageType modl foreignDecl path expectedType packageType =
  case packageType of
    PackageTypeUnchecked reason ->
      compareUncheckedLeaf foreignDecl (capitalize path <> " uses `" <> reason <> "`.")
    PackageTypeOpaque rawType ->
      compareUncheckedLeaf foreignDecl (capitalize path <> " uses opaque package type `" <> rawType <> "`.")
    PackageTypeString ->
      case expectedType of
        TStr ->
          Nothing
        TNamed name
          | isJsonEnumType modl name ->
              Nothing
        _ ->
          mismatchPrimitive "string"
    PackageTypeNumber ->
      case expectedType of
        TInt ->
          Nothing
        _ ->
          mismatchPrimitive "number"
    PackageTypeBoolean ->
      case expectedType of
        TBool ->
          Nothing
        _ ->
          mismatchPrimitive "boolean"
    PackageTypeArray itemType ->
      case expectedType of
        TList itemExpected ->
          comparePackageType modl foreignDecl (path <> " item") itemExpected itemType
        _ ->
          Just (SignatureMismatch (capitalize path <> " expected `" <> renderType expectedType <> "`, but the package declaration uses an array."))
    PackageTypeObject fields ->
      case expectedType of
        TNamed recordName ->
          case findRecordDecl modl recordName of
            Just recordDecl ->
              compareRecordFields modl foreignDecl path recordDecl fields
            Nothing ->
              Just (SignatureMismatch (capitalize path <> " expected `" <> renderType expectedType <> "`, but only record-backed package values can be checked structurally."))
        _ ->
          Just (SignatureMismatch (capitalize path <> " expected `" <> renderType expectedType <> "`, but the package declaration uses an object."))
  where
    mismatchPrimitive primitiveName =
      Just (SignatureMismatch (capitalize path <> " expected `" <> renderType expectedType <> "`, but the package declaration uses `" <> primitiveName <> "`."))

compareRecordFields :: Module -> ForeignDecl -> Text -> RecordDecl -> [PackageField] -> Maybe SignatureProblem
compareRecordFields modl foreignDecl path recordDecl packageFields =
  let expectedFields = Map.fromList [(recordFieldDeclName fieldDecl, fieldDecl) | fieldDecl <- recordDeclFields recordDecl]
      actualFields = Map.fromList [(packageFieldName field, field) | field <- packageFields]
      missingFields = Map.keys (Map.difference expectedFields actualFields)
      extraFields = Map.keys (Map.difference actualFields expectedFields)
   in case () of
        _
          | not (null missingFields) ->
              Just
                (SignatureMismatch
                   ( capitalize path
                       <> " is missing field(s) "
                       <> commaList (fmap quoted missingFields)
                       <> " for record `"
                       <> recordDeclName recordDecl
                       <> "`."
                   )
                )
          | not (null extraFields) ->
              Just
                (SignatureMismatch
                   ( capitalize path
                       <> " has extra field(s) "
                       <> commaList (fmap quoted extraFields)
                       <> " that are not present on record `"
                       <> recordDeclName recordDecl
                       <> "`."
                   )
                )
          | otherwise ->
              firstJust
                [ compareRecordField modl foreignDecl path fieldDecl packageField
                | fieldDecl <- recordDeclFields recordDecl
                , Just packageField <- [Map.lookup (recordFieldDeclName fieldDecl) actualFields]
                ]

compareRecordField :: Module -> ForeignDecl -> Text -> RecordFieldDecl -> PackageField -> Maybe SignatureProblem
compareRecordField modl foreignDecl path fieldDecl packageField
  | packageFieldOptional packageField =
      Just (SignatureMismatch (capitalize fieldPath <> " is optional in the package declaration."))
  | otherwise =
      case packageFieldType packageField of
        Nothing ->
          compareUncheckedLeaf foreignDecl (capitalize fieldPath <> " is untyped in the package declaration.")
        Just packageType ->
          comparePackageType modl foreignDecl fieldPath (recordFieldDeclType fieldDecl) packageType
  where
    fieldPath = path <> "." <> recordFieldDeclName fieldDecl

compareUncheckedLeaf :: ForeignDecl -> Text -> Maybe SignatureProblem
compareUncheckedLeaf foreignDecl detail
  | foreignDeclUnsafeInterop foreignDecl =
      Nothing
  | otherwise =
      Just (SignatureRequiresUnsafe detail)

findRecordDecl :: Module -> Text -> Maybe RecordDecl
findRecordDecl modl targetName =
  find ((== targetName) . recordDeclName) (moduleRecordDecls modl)

findTypeDecl :: Module -> Text -> Maybe TypeDecl
findTypeDecl modl targetName =
  find ((== targetName) . typeDeclName) (moduleTypeDecls modl)

isJsonEnumType :: Module -> Text -> Bool
isJsonEnumType modl targetName =
  case findTypeDecl modl targetName of
    Just typeDecl ->
      all (null . constructorDeclFields) (typeDeclConstructors typeDecl)
    Nothing ->
      False

parsePackageFunctionSignature :: Text -> Text -> PackageFunctionSignature
parsePackageFunctionSignature runtimeName signature =
  let stripped = T.strip signature
   in case matchFunctionPrefix stripped of
        Just afterPrefix ->
          case T.stripPrefix runtimeName (T.stripStart afterPrefix) of
            Just afterName ->
              parseFunctionAfterName (T.stripStart afterName)
            Nothing ->
              PackageFunctionUnchecked "an unsupported function declaration"
        Nothing
          | stripped == ("export {" <> runtimeName <> "};")
              || stripped == ("export { " <> runtimeName <> " };") ->
              PackageFunctionUnchecked "a re-export without a declaration signature"
          | otherwise ->
              PackageFunctionUnchecked "an unsupported declaration shape"

parseFunctionAfterName :: Text -> PackageFunctionSignature
parseFunctionAfterName text =
  case takeDelimited '(' ')' text of
    Nothing ->
      PackageFunctionUnchecked "an invalid function parameter list"
    Just (paramsText, afterParams) ->
      let params = parseParams paramsText
          remaining = T.stripStart afterParams
       in case T.uncons remaining of
            Nothing ->
              PackageFunctionSignature params Nothing
            Just (':', rest) ->
              PackageFunctionSignature params (Just (parsePackageType (trimSignatureTerm rest)))
            _ ->
              PackageFunctionUnchecked "an invalid return type annotation"

parseParams :: Text -> [PackageParam]
parseParams text =
  [ parseParam segment
  | segment <- splitTopLevel [','] text
  , not (T.null (T.strip segment))
  ]

parseParam :: Text -> PackageParam
parseParam rawParam =
  let paramText = T.strip rawParam
      (nameText, maybeTypeText) = splitTypeAnnotation paramText
      strippedName = T.strip nameText
      optional = "?" `T.isSuffixOf` strippedName
      paramName = T.dropWhile (== '.') (T.dropWhileEnd (`elem` ['?']) strippedName)
   in PackageParam
        { packageParamName = paramName
        , packageParamOptional = optional
        , packageParamType = fmap parsePackageType maybeTypeText
        }

parsePackageType :: Text -> PackageType
parsePackageType rawType =
  let stripped = stripArraySuffixes (T.strip rawType)
      baseText = fst stripped
      arrayDepth = snd stripped
      baseType =
        case parseBasePackageType baseText of
          Just parsed ->
            parsed
          Nothing ->
            PackageTypeOpaque (T.strip rawType)
   in applyArrayDepth arrayDepth baseType

parseBasePackageType :: Text -> Maybe PackageType
parseBasePackageType text
  | text == "string" =
      Just PackageTypeString
  | text == "number" =
      Just PackageTypeNumber
  | text == "boolean" =
      Just PackageTypeBoolean
  | text == "any" =
      Just (PackageTypeUnchecked "any")
  | text == "unknown" =
      Just (PackageTypeUnchecked "unknown")
  | T.null text =
      Nothing
  | "{" `T.isPrefixOf` text =
      do
        (fieldsText, rest) <- takeDelimited '{' '}' text
        if T.null (T.strip rest)
          then Just (PackageTypeObject (parseObjectFields fieldsText))
          else Nothing
  | Just inner <- extractGenericArg "Array" text =
      Just (PackageTypeArray (parsePackageType inner))
  | Just inner <- extractGenericArg "ReadonlyArray" text =
      Just (PackageTypeArray (parsePackageType inner))
  | otherwise =
      Just (PackageTypeOpaque text)

parseObjectFields :: Text -> [PackageField]
parseObjectFields text =
  [ parseObjectField segment
  | segment <- splitTopLevel [',', ';'] text
  , not (T.null (T.strip segment))
  ]

parseObjectField :: Text -> PackageField
parseObjectField rawField =
  let fieldText = T.strip rawField
      (nameText, maybeTypeText) = splitTypeAnnotation fieldText
      strippedName = T.strip nameText
      optional = "?" `T.isSuffixOf` strippedName
      fieldName = stripFieldName (T.dropWhileEnd (`elem` ['?']) strippedName)
   in PackageField
        { packageFieldName = fieldName
        , packageFieldOptional = optional
        , packageFieldType = fmap parsePackageType maybeTypeText
        }

splitTypeAnnotation :: Text -> (Text, Maybe Text)
splitTypeAnnotation text =
  case findTopLevelChar ':' text of
    Nothing ->
      (text, Nothing)
    Just index ->
      let (beforeColon, afterColon) = T.splitAt index text
       in (beforeColon, Just (T.drop 1 afterColon))

extractGenericArg :: Text -> Text -> Maybe Text
extractGenericArg typeName text = do
  rest <- T.stripPrefix (typeName <> "<") text
  (inner, trailing) <- takeDelimited '<' '>' ("<" <> rest)
  if T.null (T.strip trailing)
    then Just inner
    else Nothing

stripArraySuffixes :: Text -> (Text, Int)
stripArraySuffixes = go 0
  where
    go depth text
      | "[]" `T.isSuffixOf` text =
          go (depth + 1) (T.stripEnd (T.dropEnd 2 text))
      | otherwise =
          (text, depth)

applyArrayDepth :: Int -> PackageType -> PackageType
applyArrayDepth depth packageType =
  iterate PackageTypeArray packageType !! depth

takeDelimited :: Char -> Char -> Text -> Maybe (Text, Text)
takeDelimited open close text = do
  let stripped = T.stripStart text
  (firstChar, rest) <- T.uncons stripped
  if firstChar /= open
    then Nothing
    else go [close] rest ""
  where
    go [] remaining acc =
      Just (acc, remaining)
    go expectedClosers remaining acc = do
      (char, rest) <- T.uncons remaining
      case matchingCloser char of
        Just nestedClose ->
          go (nestedClose : expectedClosers) rest (T.snoc acc char)
        Nothing ->
          case expectedClosers of
            expectedClose : moreClosers
              | char == expectedClose ->
                  case moreClosers of
                    [] ->
                      Just (acc, rest)
                    _ ->
                      go moreClosers rest (T.snoc acc char)
            _ ->
              go expectedClosers rest (T.snoc acc char)

splitTopLevel :: [Char] -> Text -> [Text]
splitTopLevel delimiters text =
  go [] "" [] text
  where
    go expectedClosers current segments remaining =
      case T.uncons remaining of
        Nothing ->
          reverse (finishSegment current segments)
        Just (char, rest) ->
          case matchingCloser char of
            Just nestedClose ->
              go (nestedClose : expectedClosers) (T.snoc current char) segments rest
            Nothing ->
              case expectedClosers of
                expectedClose : moreClosers
                  | char == expectedClose ->
                      go moreClosers (T.snoc current char) segments rest
                []
                  | char `elem` delimiters ->
                      go expectedClosers "" (T.strip current : segments) rest
                _ ->
                  go expectedClosers (T.snoc current char) segments rest

    finishSegment current segments =
      let stripped = T.strip current
       in if T.null stripped
            then segments
            else stripped : segments

findTopLevelChar :: Char -> Text -> Maybe Int
findTopLevelChar target text =
  go [] 0 text
  where
    go _ _ remaining | T.null remaining = Nothing
    go expectedClosers index remaining =
      case T.uncons remaining of
        Nothing ->
          Nothing
        Just (char, rest) ->
          case matchingCloser char of
            Just nestedClose ->
              go (nestedClose : expectedClosers) (index + 1) rest
            Nothing ->
              case expectedClosers of
                expectedClose : moreClosers
                  | char == expectedClose ->
                      go moreClosers (index + 1) rest
                []
                  | char == target ->
                      Just index
                _ ->
                  go expectedClosers (index + 1) rest

matchingCloser :: Char -> Maybe Char
matchingCloser char =
  case char of
    '(' -> Just ')'
    '{' -> Just '}'
    '[' -> Just ']'
    '<' -> Just '>'
    _ -> Nothing

trimSignatureTerm :: Text -> Text
trimSignatureTerm =
  T.dropWhileEnd (\char -> isSpace char || char == ';')

matchFunctionPrefix :: Text -> Maybe Text
matchFunctionPrefix text =
  firstJustValue
    [ T.stripPrefix "export declare function " text
    , T.stripPrefix "export function " text
    , T.stripPrefix "declare function " text
    ]

stripFieldName :: Text -> Text
stripFieldName name =
  case T.uncons stripped of
    Just ('"', rest)
      | "\"" `T.isSuffixOf` rest ->
          T.dropEnd 1 rest
    _ ->
      stripped
  where
    stripped = T.strip name

capitalize :: Text -> Text
capitalize text =
  case T.uncons text of
    Nothing ->
      text
    Just (char, rest) ->
      T.cons (toUpper char) rest

quoted :: Text -> Text
quoted value = "`" <> value <> "`"

commaList :: [Text] -> Text
commaList = T.intercalate ", "

tshow :: Show a => a -> Text
tshow = T.pack . show

firstJust :: [Maybe a] -> Maybe a
firstJust =
  findMaybe id

firstJustValue :: [Maybe a] -> Maybe a
firstJustValue =
  findMaybe id

findMaybe :: (a -> Maybe b) -> [a] -> Maybe b
findMaybe _ [] = Nothing
findMaybe f (item : rest) =
  case f item of
    Just result ->
      Just result
    Nothing ->
      findMaybe f rest
