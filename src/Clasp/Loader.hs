{-# LANGUAGE OverloadedStrings #-}

module Clasp.Loader
  ( loadEntryModule
  ) where

import Control.Monad (foldM)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, makeAbsolute)
import System.FilePath ((</>), (<.>), joinPath, takeDirectory)
import Clasp.Diagnostic
  ( DiagnosticBundle
  , diagnostic
  , diagnosticBundle
  )
import Clasp.Parser (parseModule)
import Clasp.Syntax
  ( ImportDecl (..)
  , Module (..)
  , ModuleName (..)
  , splitModuleName
  )

data LoadState = LoadState
  { loadStateModules :: Map.Map ModuleName Module
  , loadStateOrder :: [ModuleName]
  }

loadEntryModule :: FilePath -> IO (Either DiagnosticBundle Module)
loadEntryModule entryPath = do
  absoluteEntryPath <- makeAbsolute entryPath
  entrySource <- TIO.readFile absoluteEntryPath
  case parseModule absoluteEntryPath entrySource of
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
      pure (fmap (combineModules entryModule) loadedImports)

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
      case parseModule importedFilePath importedSource of
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
        , moduleGuideDecls = concatMap moduleGuideDecls (importedModules <> [entryModule])
        , moduleHookDecls = concatMap moduleHookDecls (importedModules <> [entryModule])
        , moduleAgentRoleDecls = concatMap moduleAgentRoleDecls (importedModules <> [entryModule])
        , moduleAgentDecls = concatMap moduleAgentDecls (importedModules <> [entryModule])
        , modulePolicyDecls = concatMap modulePolicyDecls (importedModules <> [entryModule])
        , moduleProjectionDecls = concatMap moduleProjectionDecls (importedModules <> [entryModule])
        , moduleForeignDecls = concatMap moduleForeignDecls (importedModules <> [entryModule])
        , moduleRouteDecls = concatMap moduleRouteDecls (importedModules <> [entryModule])
        , moduleDecls = concatMap moduleDecls (importedModules <> [entryModule])
        }
