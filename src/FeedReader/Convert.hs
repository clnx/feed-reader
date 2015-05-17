{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

-----------------------------------------------------------------------------
-- |
-- Module : FeedReader.Import
-- Copyright : (C) 2015 Călin Ardelean,
-- License : BSD-style (see the file LICENSE)
--
-- Maintainer : Călin Ardelean <calinucs@gmail.com>
-- Stability : experimental
-- Portability : portable
--
-- This module provides DB conversion/import instances for Feed Reader.
----------------------------------------------------------------------------

module FeedReader.Convert
  () where

import           Control.Applicative   ((<|>))
import           Data.List             (find, isPrefixOf)
import           Data.Maybe            (fromMaybe, listToMaybe)
import           FeedReader.DocDB      (Transaction, intValUnique, updateUnique)
import           FeedReader.Types
import           FeedReader.Utils      (text2UTCTime)
import qualified Text.Atom.Feed        as A
import qualified Text.DublinCore.Types as DC
import qualified Text.RSS.Syntax       as R
import qualified Text.RSS1.Syntax      as R1

------------------------------------------------------------------------------
-- Conversion transactions for Atom
------------------------------------------------------------------------------

content2DB :: A.TextContent -> Content
content2DB = \case
  A.TextString  s -> Text s
  A.HTMLString  s -> HTML s
  A.XHTMLString e -> XHTML $ show e

tryContent2DB :: Maybe A.TextContent -> Content
tryContent2DB c = content2DB $ fromMaybe (A.TextString "") c

eContent2DB :: A.EntryContent -> Content
eContent2DB = \case
  A.TextContent       s -> Text s
  A.HTMLContent       s -> HTML s
  A.XHTMLContent      e -> XHTML $ show e
  A.MixedContent   j cs -> Text $ foldl (flip shows) (fromMaybe "" j) cs
  A.ExternalContent j u -> Text . maybe (showString "")
    (\s -> showString "MediaType: " . showString s . showString "\n") j
    . showString "URL: " $ u

tryEContent2DB :: Maybe A.EntryContent -> Content
tryEContent2DB c = eContent2DB $ fromMaybe (A.TextContent "") c

imageFromURL :: URL -> Image
imageFromURL u = Image
  { imageURL         = u
  , imageTitle       = ""
  , imageDescription = ""
  , imageLink        = u
  , imageWidth       = 0
  , imageHeight      = 0
  }

instance ToPerson A.Person where
  toPerson p = do
    let name = Indexable $ A.personName p
    let p' = Person { personName  = Unique name
                    , personURL   = fromMaybe "" $ A.personURI p
                    , personEmail = fromMaybe "" $ A.personEmail p
                    }
    pid <- updateUnique "personName" (intValUnique name) p'
    return (pid, p')

toStr Nothing = ""
toStr (Just (Left x)) = x
toStr (Just (Right x)) = x

isSelf lr = toStr (A.linkRel lr) == "alternate" && isHTMLType (A.linkType lr)

isHTMLType :: Maybe String -> Bool
isHTMLType (Just str) = "lmth" `isPrefixOf` reverse str
isHTMLType _ = True

instance ToFeed A.Feed where
  toFeed f c u df = do
    as <- mapM toPerson $ A.feedAuthors f
    cs <- mapM toPerson $ A.feedContributors f
    let f' = Feed { feedCatID        = c
                  , feedURL          = Unique u
                  , feedWebURL       = maybe "" A.linkHref . listToMaybe .
                                       filter isSelf $ A.feedLinks f
                  , feedTitle        = Indexable . content2DB $ A.feedTitle f
                  , feedDescription  = tryContent2DB $ A.feedSubtitle f
                  , feedLanguage     = ""
                  , feedAuthors      = fst <$> as
                  , feedContributors = fst <$> cs
                  , feedRights       = tryContent2DB $ A.feedRights f
                  , feedImage        = imageFromURL <$> (A.feedLogo f <|> A.feedIcon f)
                  , feedUpdated      = Indexable $ text2UTCTime (A.feedUpdated f) df
                  }
    fid <- updateUnique "feedURL" (intValUnique u) f'
    return (fid, f')

instance ToItem A.Entry where
  toItem i f df = do
    as <- mapM toPerson $ A.entryAuthors i
    cs <- mapM toPerson $ A.entryContributor i
    let date = text2UTCTime (A.entryUpdated i) df
    let url = case A.entryLinks i of
                []    -> ""
                (l:_) -> A.linkHref l
    let i' = Item { itemFeedID       = f
                  , itemURL          = Unique url
                  , itemTitle        = content2DB $ A.entryTitle i
                  , itemSummary      = tryContent2DB $ A.entrySummary i
                  , itemTags         = A.catTerm <$> A.entryCategories i
                  , itemAuthors      = fst <$> as
                  , itemContributors = fst <$> cs
                  , itemRights       = tryContent2DB $ A.entryRights i
                  , itemContent      = tryEContent2DB $ A.entryContent i
                  , itemPublished    = Indexable $ text2UTCTime
                                         (fromMaybe "" $ A.entryPublished i) df
                  , itemUpdated      = Indexable date
                  }
    iid <- updateUnique "itemURL" (intValUnique url) i'
    return (iid, i')

------------------------------------------------------------------------------
-- Conversion transactions for RSS
------------------------------------------------------------------------------

data RSSPerson = RSSPerson { rssPersonName :: String }

instance ToPerson RSSPerson where
  toPerson p = do
    let name = Indexable $ rssPersonName p
    let p' = Person { personName  = Unique name
                    , personURL   = ""
                    , personEmail = ""
                    }
    pid <- updateUnique "personName" (intValUnique name) p'
    return (pid, p')

rssImageToImage i = Image
  { imageURL         = R.rssImageURL i
  , imageTitle       = R.rssImageTitle i
  , imageDescription = fromMaybe "" $ R.rssImageDesc i
  , imageLink        = R.rssImageLink i
  , imageWidth       = fromIntegral . fromMaybe 0 $ R.rssImageWidth i
  , imageHeight      = fromIntegral . fromMaybe 0 $ R.rssImageHeight i
  }

rssPersonToPerson = maybe [] (pure . RSSPerson)

instance ToFeed R.RSSChannel where
  toFeed f c u df = do
    as <- mapM toPerson . rssPersonToPerson $ R.rssEditor f
    cs <- mapM toPerson . rssPersonToPerson $ R.rssWebMaster f
    let f' = Feed { feedCatID        = c
                  , feedURL          = Unique u
                  , feedWebURL       = R.rssLink f
                  , feedTitle        = Indexable . Text $ R.rssTitle f
                  , feedDescription  = HTML $ R.rssDescription f
                  , feedLanguage     = fromMaybe "" $ R.rssLanguage f
                  , feedAuthors      = fst <$> as
                  , feedContributors = fst <$> cs
                  , feedRights       = Text . fromMaybe "" $ R.rssCopyright f
                  , feedImage        = rssImageToImage <$> R.rssImage f
                  , feedUpdated      = Indexable $ case R.rssLastUpdate f of
                                         Nothing -> df
                                         Just d  -> text2UTCTime d df
                  }
    fid <- updateUnique "feedURL" (intValUnique u) f'
    return (fid, f')

instance ToItem R.RSSItem where
  toItem i f df = do
    as <- mapM toPerson . rssPersonToPerson $ R.rssItemAuthor i
    let url = fromMaybe "" $ R.rssItemLink i
    let date = Indexable $ text2UTCTime (fromMaybe "" $ R.rssItemPubDate i) df
    let i' = Item { itemFeedID       = f
                  , itemURL          = Unique url
                  , itemTitle        = Text . fromMaybe "" $ R.rssItemTitle i
                  , itemSummary      = Text ""
                  , itemTags         = R.rssCategoryValue <$> R.rssItemCategories i
                  , itemAuthors      = fst <$> as
                  , itemContributors = []
                  , itemRights       = Text ""
                  , itemContent      = HTML . fromMaybe "" $ R.rssItemDescription i
                  , itemPublished    = date
                  , itemUpdated      = date
                  }
    iid <- updateUnique "itemURL" (intValUnique url) i'
    return (iid, i')

------------------------------------------------------------------------------
-- Conversion transactions for RSS1
------------------------------------------------------------------------------

extractDcPersons dcs con = map (RSSPerson . DC.dcText) $
                           filter (\d -> DC.dcElt d == con) dcs

extractDcInfo dcs con = maybe "" DC.dcText $ find (\d -> DC.dcElt d == con) dcs

rss1ImageToImage i = Image
  { imageURL         = R1.imageURI i
  , imageTitle       = R1.imageTitle i
  , imageDescription = ""
  , imageLink        = R1.imageLink i
  , imageWidth       = 0
  , imageHeight      = 0
  }

instance ToFeed R1.Feed where
  toFeed f c u df = do
    let ch  = R1.feedChannel f
    let dcs = R1.channelDC ch
    as <- mapM toPerson $ extractDcPersons dcs DC.DC_Creator
    cs <- mapM toPerson $ extractDcPersons dcs DC.DC_Contributor
    let f' = Feed { feedCatID        = c
                  , feedURL          = Unique u
                  , feedWebURL       = R1.channelURI ch
                  , feedTitle        = Indexable . Text $ R1.channelTitle ch
                  , feedDescription  = HTML $ R1.channelDesc ch
                  , feedLanguage     = extractDcInfo dcs DC.DC_Language
                  , feedAuthors      = fst <$> as
                  , feedContributors = fst <$> cs
                  , feedRights       = Text $ extractDcInfo dcs DC.DC_Rights
                  , feedImage        = rss1ImageToImage <$> R1.feedImage f
                  , feedUpdated      = Indexable $ text2UTCTime
                                         (extractDcInfo dcs DC.DC_Date) df
                  }
    fid <- updateUnique "feedURL" (intValUnique u) f'
    return (fid, f')

instance ToItem R1.Item where
  toItem i f df = do
    let dcs = R1.itemDC i
    as <- mapM toPerson $ extractDcPersons dcs DC.DC_Creator
    cs <- mapM toPerson $ extractDcPersons dcs DC.DC_Contributor
    let url = if null $ R1.itemLink i then R1.itemURI i else R1.itemLink i
    let date = Indexable $ text2UTCTime (extractDcInfo dcs DC.DC_Date) df
    let i' = Item { itemFeedID       = f
                  , itemURL          = Unique url
                  , itemTitle        = Text $ R1.itemTitle i
                  , itemSummary      = HTML . fromMaybe "" $ R1.itemDesc i
                  , itemTags         = R1.itemTopics i
                  , itemAuthors      = fst <$> as
                  , itemContributors = fst <$> cs
                  , itemRights       = Text $ extractDcInfo dcs DC.DC_Rights
                  , itemContent      = HTML . concat . concatMap (foldMap pure .
                                       R1.contentValue) $ R1.itemContent i
                  , itemPublished    = date
                  , itemUpdated      = date
                  }
    iid <- updateUnique "itemURL" (intValUnique url) i'
    return (iid, i')
