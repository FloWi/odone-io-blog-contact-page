{-# LANGUAGE OverloadedStrings #-}

--------------------------------------------------------------------------------

import Control.Applicative ((<|>))
import Data.Bifunctor (Bifunctor, bimap, first)
import Data.Binary (Binary)
import Data.Bool (bool)
import Data.Foldable (fold, traverse_)
import Data.List (group, nub, partition, sortOn)
import Data.Maybe (fromMaybe)
import Data.Traversable (traverse)
import Data.Typeable (Typeable)
import Hakyll
import System.Environment (getEnvironment)
import System.FilePath (replaceExtension)
import Text.Blaze.Html ((!), toHtml, toValue)
import Text.Blaze.Html.Renderer.String (renderHtml)
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

--------------------------------------------------------------------------------
feedConfiguration :: FeedConfiguration
feedConfiguration =
  FeedConfiguration
    { feedTitle = "odone.io",
      feedDescription = "Rambling on software as a learning tool",
      feedAuthorName = "Riccardo Odone",
      feedAuthorEmail = "",
      feedRoot = "https://odone.io"
    }

previewHost' :: String
previewHost' = previewHost defaultConfiguration

previewPort' :: Int
previewPort' = previewPort defaultConfiguration

previewUrl :: String
previewUrl = fold ["http://", previewHost', ":", show previewPort', "/"]

postsPattern :: Pattern
postsPattern = "posts/*"

main :: IO ()
main = do
  env <- getEnvironment
  let configuration = defaultConfiguration {previewHost = previewHost', previewPort = previewPort'}
  hakyllWith configuration $ do
    match "images/*" $ do
      route idRoute
      compile copyFileCompiler
    match "robots.txt" $ do
      route idRoute
      compile copyFileCompiler
    match "css/*" $ do
      route idRoute
      compile compressCssCompiler
    match "404.md" $ do
      route $ setExtension "html"
      compile $ pandocCompiler >>= loadAndApplyTemplate "templates/default.html" defaultContext
    tags <- buildTags' postsPattern (fromCapture "tags/*.html")
    matchMetadata postsPattern isPublished $ do
      let livePath = (`replaceExtension` "html") . toFilePath
      route . customRoute $ livePath
      compile $
        pandocCompiler
          >>= loadAndApplyTemplate "templates/post.html" (postCtx tags)
          >>= saveSnapshot "content"
          >>= loadAndApplyTemplate "templates/default.html" (postCtx tags)
          >>= relativizeUrls
    matchMetadata postsPattern (not . isPublished) $ do
      let draftPath = ("drafts/" <>) . (`replaceExtension` "html") . toFilePath
      route . customRoute $ draftPath
      let putDraftUrl path =
            traverse_
              (unsafeCompiler . putStrLn)
              [ "----DRAFT----",
                (previewUrl <>) . draftPath . itemIdentifier $ path,
                "-------------"
              ]
      compile $
        pandocCompiler
          >>= loadAndApplyTemplate "templates/post.html" (postCtx tags)
          >>= loadAndApplyTemplate "templates/default.html" (postCtx tags)
          >>= relativizeUrls
          >>= (\x -> putDraftUrl x >> pure x)
    tagsRules tags $ \tag pattern_ -> do
      route idRoute
      compile $ archive env tags (Just tag) postsPattern pattern_
    create ["archive.html"] $ do
      route idRoute
      compile $ archive env tags Nothing postsPattern postsPattern
    create ["sitemap.xml"] $ do
      route idRoute
      compile $ do
        pages <- loadAll (fromList ["archive.html"])
        posts <- recentFirst =<< loadAllPublished env postsPattern
        categoriesAndTags <- uncurry (<>) <$> getCategoriesAndTags posts
        let sitemapCtx =
              listField "pages" defaultContext (pure pages)
                <> listField "posts" (dateField "date" "%F" <> postCtx tags) (pure posts)
                <> listField "tags" (tagsCtx Nothing) (traverse makeItem categoriesAndTags)
        makeItem ""
          >>= loadAndApplyTemplate "templates/sitemap.xml" sitemapCtx
    match "index.html" $ do
      route idRoute
      compile $ do
        let indexCtx = constField "title" "Home" <> constField "index" "" <> defaultContext
        getResourceBody
          >>= applyAsTemplate indexCtx
          >>= loadAndApplyTemplate "templates/default.html" indexCtx
          >>= relativizeUrls
    match "templates/*" $ compile templateBodyCompiler
    create ["atom.xml"] $ do
      route idRoute
      compile $ do
        let feedCtx = mconcat [bodyField "description", defaultContext]
        posts <-
          fmap (take 10) . recentFirst
            =<< loadAllSnapshotsPublished postsPattern "content"
        renderAtom feedConfiguration feedCtx posts

--------------------------------------------------------------------------------

type Tag = (Int, Char, String)

fst' (a, _, _) = a

snd' (_, b, _) = b

trd' (_, _, c) = c

getCategoriesAndTags :: (MonadMetadata m, MonadFail m) => [Item String] -> m ([Tag], [Tag])
getCategoriesAndTags posts = do
  let identifiers = fmap itemIdentifier posts
  tags <- traverse getTags' identifiers
  -- tags -> [[a, b], [d, e], [a, c]]
  -- withLabel -> ([(♕,a), (♔,d), (♕,a)], [(♕,b), (♔,e), (♕,c)])
  -- withLengthAndLabel -> ([(1,♔,d), (2,♕,a)], [(1,♔,e), (1,♕,b), (1,♕,c)])
  pure . withLengthAndLabel . withLabel $ tags
  where
    -- ♔ ♕ ♖ ♗ ♘ ♙
    toLabel "Functional Programming" = '♕'
    toLabel "Essential Skills" = '♔'
    bimap' :: Bifunctor p => (a -> b) -> p a a -> p b b
    bimap' f = bimap f f
    withCategory :: [String] -> [(String, String)]
    withCategory ts@(t : _) = zip (repeat t) ts
    withLabel :: [[String]] -> ([(Char, String)], [(Char, String)])
    withLabel = bimap' (fmap (first toLabel)) . partition (uncurry (==)) . concatMap withCategory
    withLengthAndLabel = bimap' (fmap (\xs -> (length xs, fst . head $ xs, snd . head $ xs)) . group . sortOn snd)

archive :: [(String, String)] -> Tags -> Maybe String -> Pattern -> Pattern -> Compiler (Item String)
archive env allTags mSelectedTag allPattern filterPattern = do
  allPosts <- recentFirst =<< loadAllPublished env allPattern
  (categories, tags) <- getCategoriesAndTags allPosts
  let filteredPosts = filter (matches filterPattern . itemIdentifier) allPosts
  let archiveCtx =
        listField "tags" (tagsCtx mSelectedTag) (traverse makeItem tags)
          <> listField "categories" (tagsCtx mSelectedTag) (traverse makeItem categories)
          <> listField "posts" (postCtx allTags) (pure filteredPosts)
          <> constField "title" "Archives"
          <> defaultContext
  makeItem ""
    >>= loadAndApplyTemplate "templates/archive.html" archiveCtx
    >>= loadAndApplyTemplate "templates/default.html" archiveCtx
    >>= relativizeUrls

tagsCtx :: Maybe String -> Context Tag
tagsCtx mSelectedTag =
  field "url" (pure . toUrl . tagUrl . trd' . itemBody)
    <> field "status" (pure . bool "unselected" "selected" . (==) mSelectedTag . Just . trd' . itemBody)
    <> field "tag" (pure . trd' . itemBody)
    <> field "icon" (pure . (: []) . snd' . itemBody)
    <> field "count" (pure . show . fst' . itemBody)
  where
    tagUrl tag = if Just tag == mSelectedTag then "/archive.html" else "/tags/" <> tag <> ".html"

postCtx :: Tags -> Context String
postCtx tags = tagsField' "tags" tags <> dateField "date" "%B %e, %Y" <> defaultContext

loadAllPublished :: (Binary a, Typeable a) => [(String, String)] -> Pattern -> Compiler [Item a]
loadAllPublished env pattern_ = if isDevelopmentEnv env then all else published
  where
    all = loadAll pattern_
    published = publishedIds pattern_ >>= traverse load
    isDevelopmentEnv env = lookup "HAKYLL_ENV" env == Just "development"

loadAllSnapshotsPublished :: (Binary a, Typeable a) => Pattern -> Snapshot -> Compiler [Item a]
loadAllSnapshotsPublished pattern_ snapshot = publishedIds pattern_ >>= traverse (`loadSnapshot` snapshot)

publishedIds :: MonadMetadata m => Pattern -> m [Identifier]
publishedIds = fmap (fmap fst . filter (isPublished . snd)) . getAllMetadata

isPublished :: Metadata -> Bool
isPublished = maybe True (== "true") . lookupString "published"

tagsField' :: String -> Tags -> Context a
tagsField' = tagsFieldWith getTags' simpleRenderLink' mconcat

simpleRenderLink' :: String -> Maybe FilePath -> Maybe H.Html
simpleRenderLink' _ Nothing = Nothing
simpleRenderLink' tag (Just filePath) =
  Just
    $ H.a
      ! A.href (toValue $ toUrl filePath)
      ! A.class_ "btn btn-tag-unselected btn-sm"
    $ toHtml tag

buildTags' :: MonadMetadata m => Pattern -> (String -> Identifier) -> m Tags
buildTags' = buildTagsWith getTags'

getTags' :: MonadMetadata m => Identifier -> m [String]
getTags' identifier = do
  metadata <- getMetadata identifier
  pure $ fromMaybe ["_untagged_"] $
    lookupStringList "tags" metadata <|> (map trim . splitAll "," <$> lookupString "tags" metadata)
