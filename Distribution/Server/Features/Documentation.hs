{-# LANGUAGE RankNTypes, NamedFieldPuns, RecordWildCards, PatternGuards #-}
module Distribution.Server.Features.Documentation (
    DocumentationFeature(..),
    DocumentationResource(..),
    initDocumentationFeature
  ) where

import Distribution.Server.Framework

import Distribution.Server.Features.Documentation.State
import Distribution.Server.Features.Upload
import Distribution.Server.Features.Core

import Distribution.Server.Framework.BackupRestore
import qualified Distribution.Server.Framework.ResponseContentTypes as Resource
import Distribution.Server.Framework.BlobStorage (BlobId)
import qualified Distribution.Server.Framework.BlobStorage as BlobStorage
import qualified Distribution.Server.Util.ServeTarball as TarIndex
import Data.TarIndex (TarIndex)

import Distribution.Text
import Distribution.Package

import Data.Function
import qualified Data.Map as Map

-- TODO:
-- 1. Write an HTML view for organizing uploads
-- 2. Have cabal generate a standard doc tarball, and serve that here
data DocumentationFeature = DocumentationFeature {
    documentationFeatureInterface :: HackageFeature,

    queryHasDocumentation :: MonadIO m => PackageIdentifier -> m Bool,

    documentationResource :: DocumentationResource
}

instance IsHackageFeature DocumentationFeature where
    getFeatureInterface = documentationFeatureInterface

data DocumentationResource = DocumentationResource {
    packageDocsContent :: Resource,
    packageDocsWhole   :: Resource
}

initDocumentationFeature :: ServerEnv -> CoreFeature -> UploadFeature -> IO DocumentationFeature
initDocumentationFeature env@ServerEnv{serverStateDir, serverVerbosity = verbosity}
                         core upload = do
    loginfo verbosity "Initialising documentation feature, start"
    documentationState <- documentationStateComponent serverStateDir
    let feature = documentationFeature env core upload documentationState
    loginfo verbosity "Initialising documentation feature, end"
    return feature

documentationStateComponent :: FilePath -> IO (StateComponent Documentation)
documentationStateComponent stateDir = do
  st <- openLocalStateFrom (stateDir </> "db" </> "Documentation") initialDocumentation
  return StateComponent {
      stateDesc    = "Package documentation"
    , acidState    = st
    , getState     = query st GetDocumentation
    , putState     = update st . ReplaceDocumentation
    , backupState  = dumpBackup
    , restoreState = updateDocumentation (Documentation Map.empty)
    , resetState   = documentationStateComponent
    , getStateSize = memSize <$> query st GetDocumentation
    }
  where
    dumpBackup doc =
        let exportFunc (pkgid, (blob, _)) = BackupBlob ([display pkgid, "documentation.tar"]) blob
        in map exportFunc . Map.toList $ documentation doc

    updateDocumentation :: Documentation -> RestoreBackup Documentation
    updateDocumentation docs = RestoreBackup {
        restoreEntry = \entry ->
          case entry of
            BackupBlob [str, "documentation.tar"] blobId | Just pkgId <- simpleParse str -> do
              docs' <- importDocumentation pkgId blobId docs
              return (updateDocumentation docs')
            _ ->
              return (updateDocumentation docs)
      , restoreFinalize = return docs
      }

    importDocumentation :: PackageId -> BlobId -> Documentation -> Restore Documentation
    importDocumentation pkgId blobId (Documentation docs) = do
      tar <- restoreGetBlob blobId
      case TarIndex.constructTarIndex tar of
        Left err ->
          fail err
        Right tarIndex ->
          return (Documentation (Map.insert pkgId (blobId, tarIndex) docs))

documentationFeature :: ServerEnv
                     -> CoreFeature
                     -> UploadFeature
                     -> StateComponent Documentation
                     -> DocumentationFeature
documentationFeature ServerEnv{serverBlobStore = store}
                     CoreFeature{..} UploadFeature{..}
                     documentationState
  = DocumentationFeature{..}
  where
    documentationFeatureInterface = (emptyHackageFeature "documentation") {
        featureResources =
          map ($ documentationResource) [
              packageDocsContent
            , packageDocsWhole
            ]
        -- We don't really want to check that the tar index is the same (probably)
      , featureState = [abstractStateComponent' (compareState `on` (Map.map fst . documentation)) documentationState]
      }

    queryHasDocumentation :: MonadIO m => PackageIdentifier -> m Bool
    queryHasDocumentation pkgid = queryState documentationState (HasDocumentation pkgid)

    documentationResource = DocumentationResource {
        packageDocsContent = (resourceAt "/package/:package/docs/..") {
                               resourceGet = [("", serveDocumentation)]
                             }
      , packageDocsWhole   = (resourceAt "/package/:package/docs.:format") {
                               resourceGet = [("tar", serveDocumentationTar)],
                               resourcePut = [("tar", uploadDocumentation)]
                             }
      }

    serveDocumentationTar :: DynamicPath -> ServerPart Response
    serveDocumentationTar dpath = runServerPartE $ withDocumentation dpath $ \_ blob _ -> do
        file <- liftIO $ BlobStorage.fetch store blob
        return $ toResponse $ Resource.DocTarball file blob


    -- return: not-found error or tarball
    serveDocumentation :: DynamicPath -> ServerPart Response
    serveDocumentation dpath = do
      runServerPartE $ withDocumentation dpath $ \pkgid blob index -> do
        let tarball = BlobStorage.filepath store blob
        -- if given a directory, the default page is index.html
        -- the root directory within the tarball is e.g. foo-1.0-docs/
        TarIndex.serveTarball ["index.html"] (display pkgid ++ "-docs") tarball index

    -- return: not-found error (parsing) or see other uri
    uploadDocumentation :: DynamicPath -> ServerPart Response
    uploadDocumentation dpath =
      runServerPartE $
        withPackagePath dpath $ \pkg _ -> do
        let pkgid = packageId pkg
        withPackageAuth pkgid $ \_ _ -> do
            -- The order of operations:
            -- * Insert new documentation into blob store
            -- * Generate the new index
            -- * Drop the index for the old tar-file
            -- * Link the new documentation to the package
            fileContents <- expectUncompressedTarball
            blob <- liftIO $ BlobStorage.add store fileContents
            --TODO: validate the tarball here.
            -- Check all files in the tarball are under the dir foo-1.0-docs/
            tarIndex <- liftIO $ TarIndex.constructTarIndexFromFile (BlobStorage.filepath store blob)
            void $ updateState documentationState $ InsertDocumentation pkgid blob tarIndex
            noContent (toResponse ())

    -- curl -u mgruen:admin -X PUT --data-binary @gtk.tar.gz http://localhost:8080/package/gtk-0.11.0

    withDocumentation :: DynamicPath -> (PackageId -> BlobId -> TarIndex -> ServerPartE a) -> ServerPartE a
    withDocumentation dpath func =
        withPackagePath dpath $ \pkg _ -> do
        let pkgid = packageId pkg
        mdocs <- queryState documentationState $ LookupDocumentation pkgid
        case mdocs of
          Nothing -> errNotFound "Not Found" [MText $ "There is no documentation for " ++ display pkgid]
          Just (blob, index) -> func pkgid blob index

