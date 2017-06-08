{-# LANGUAGE OverloadedStrings #-}

module FileDB (FileDB(..), Page(..), Mode(..), TemplateName, Params, listPages,
    makePage, makePreview, getPagesNoContent, makePages, getStaticDirRoutes,
    defaultFileDB, getTemplate, title, slug, tags, keywords, categories,
    description, author, setFileDBMode, makeContent, isHiddenPage, PageInfo, mkPageInfo, renderPreviewWith
) where

import qualified Control.Exception                    as Exception
import           Control.Monad                        (filterM, when)
import           Data.Aeson                           ((.=))
import qualified Data.Aeson                           as Y (object, pairs)
import qualified Data.Aeson.Types                     as Y (Pair)
import qualified Data.ByteString                      as BS
import qualified Data.ByteString.Char8                as BS8
import qualified Data.ByteString.Lazy                 as BL
import           Data.Maybe                           (fromMaybe)
import           Data.Monoid                          ((<>))
import qualified Data.Text                            as T
import qualified Data.Text.Lazy                       as TL
import           Data.Yaml                            ((.:), (.:?))
import qualified Data.Yaml.Aeson                      as Y
import           GHC.Exts                             (fromString)
import           Network.HTTP.Types.Status            (Status)
import           Network.URI                          (isAbsoluteURI)
import           Network.Wai.Middleware.RequestLogger (logStdoutDev)
import           Network.Wai.Middleware.Static
import           System.FilePath.Posix                (joinPath, makeRelative,
                                                       replaceExtension,
                                                       splitFileName)
import qualified System.IO.Error                      as Error
import           Text.Blaze.Html.Renderer.Text        (renderHtml)
import qualified Text.Mustache                        as M
import qualified Text.Mustache.Compile                as M
import           Text.Pandoc
import           Text.Parsec.Error                    (errorMessages,
                                                       messageString)
import           Text.XML.HXT.Core                    as HXT hiding (app, when)
import           Web.Spock                            ((<//>))
import qualified Web.Spock                            as Sp
import qualified Web.Spock.Config                     as Sp
-- nanoPage imports
import           Internal.FileDB
import qualified Internal.FileDB                      as FileDB (Mode (..),
                                                                 mode)
import           Internal.Helpers
import           Internal.HtmlOps                     (markdownToHtmlString,
                                                       transformHtml)
import           Internal.Partial
-- partials
import           Partials.AdminBlock
import           Partials.CategoryList
import           Partials.KeywordList
import           Partials.TagCloud
import           Partials.TagList

makePreview :: Page -> Params -> FileDB -> IO TL.Text
makePreview p params db = return $ Internal.FileDB.mdPreview p

-- |Turn a page created by makePage into content.
makeContent :: Page -> Params -> FileDB -> IO TL.Text
makeContent page params db = do
    let t = fromMaybe (error "INTERNAL ERROR") (template page)
    -- 5. instantiate the partials (if any)
    let tagListInstance =      renderHtml $ partial TagList      db page params :: TL.Text
    let categoryListInstance = renderHtml $ partial CategoryList db page params :: TL.Text
    let keywordListInstance =  renderHtml $ partial KeywordList  db page params :: TL.Text
    let adminBLockInstance =   renderHtml $ partial AdminBlock   db page params :: TL.Text
    let tagCloudInstance =     renderHtml $ partial TagCloud     db page params :: TL.Text
    -- 6. Treat the htmlContent as a template and let  Mustache render it with
    --    the standard pairs
    let cfg = config page
    let default_pairs = [
            "title"       .= _title cfg,
            "keywords"    .= keywordsString cfg,
            "description" .= descriptionString cfg,
            "author"      .= authorString cfg
            ] :: [Y.Pair]
    let partials_pairs = [
            "taglist"      .= tagListInstance,
            "categorylist" .= categoryListInstance,
            "keywordlist"  .= keywordListInstance,
            "tagcloud"     .= tagCloudInstance
            ] :: [Y.Pair]
    let admin_pairs | FileDB.mode db == FileDB.ADMIN = ["adminblock" .= adminBLockInstance] :: [Y.Pair]
                    | otherwise                      = []
    let other_pairs = default_pairs ++ partials_pairs ++ admin_pairs
    let htmlContentsRendered = other_pairs `renderWithTemplate` mdContent page
    -- 7. Now render the template, using all pairs. In particular, plug in the
    --    {{content}}
    let content_pairs = [
            "content" .= htmlContentsRendered
            ] :: [Y.Pair]
    let yObjs = Y.object $ content_pairs ++ other_pairs
    let content' = M.renderMustache t yObjs
    -- 8. Update the records content and return
    return content'
