{-# LANGUAGE FlexibleContexts #-}

--------------------------------------------------------------------------------
-- |
-- Module      : Network.OpenID.Discovery
-- Copyright   : (c) Trevor Elliott, 2008
-- License     : BSD3
--
-- Maintainer  : Trevor Elliott <trevor@geekgateway.com>
-- Stability   :
-- Portability :
--

module OpenId2.Discovery (
    -- * Discovery
    discover
  , Discovery (..)
  ) where

-- Friends
import OpenId2.Types
import OpenId2.XRDS

-- Libraries
import Data.Char
import Data.List
import Data.Maybe
import Network.HTTP.Enumerator
import qualified Data.ByteString.Lazy.UTF8 as BSLU
import qualified Data.ByteString.Char8 as S8
import Control.Arrow (first, (***))
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Failure (Failure (failure))
import Control.Monad (mplus, liftM)
import qualified Data.CaseInsensitive as CI
import Data.Text (Text, pack, unpack)

data Discovery = Discovery1 String (Maybe String)
               | Discovery2 Provider Identifier IdentType
    deriving Show

-- | Attempt to resolve an OpenID endpoint, and user identifier.
discover :: ( MonadIO m
            , Failure AuthenticateException m
            , Failure HttpException m
            )
         => Identifier
         -> m Discovery
discover ident@(Identifier i) = do
    res1 <- discoverYADIS ident Nothing 10
    case res1 of
        Just (x, y, z) -> return $ Discovery2 x y z
        Nothing -> do
            res2 <- discoverHTML ident
            case res2 of
                Just x -> return x
                Nothing -> failure $ DiscoveryException $ unpack i

-- YADIS-Based Discovery -------------------------------------------------------

-- | Attempt a YADIS based discovery, given a valid identifier.  The result is
--   an OpenID endpoint, and the actual identifier for the user.
discoverYADIS :: ( MonadIO m
                 , Failure HttpException m
                 )
              => Identifier
              -> Maybe String
              -> Int -- ^ remaining redirects
              -> m (Maybe (Provider, Identifier, IdentType))
discoverYADIS _ _ 0 = failure TooManyRedirects
discoverYADIS ident mb_loc redirects = do
    let uri = fromMaybe (unpack $ identifier ident) mb_loc
    req <- parseUrl uri
    res <- liftIO $ withManager $ httpLbs req
    let mloc = fmap S8.unpack
             $ lookup "x-xrds-location"
             $ map (first $ map toLower . S8.unpack . CI.original)
             $ responseHeaders res
    let mloc' = if mloc == mb_loc then Nothing else mloc
    case statusCode res of
        200 ->
          case mloc' of
            Just loc -> discoverYADIS ident (Just loc) (redirects - 1)
            Nothing  -> do
              let mdoc = parseXRDS $ BSLU.toString $ responseBody res
              case mdoc of
                  Just doc -> return $ parseYADIS ident doc
                  Nothing -> return Nothing
        _ -> return Nothing


-- | Parse out an OpenID endpoint, and actual identifier from a YADIS xml
-- document.
parseYADIS :: Identifier -> XRDS -> Maybe (Provider, Identifier, IdentType)
parseYADIS ident = listToMaybe . mapMaybe isOpenId . concat
  where
  isOpenId svc = do
    let tys = serviceTypes svc
        localId = maybe ident (Identifier . pack) $ listToMaybe $ serviceLocalIDs svc
        f (x,y) | x `elem` tys = Just y
                | otherwise    = Nothing
    (lid, itype) <- listToMaybe $ mapMaybe f
      [ ("http://specs.openid.net/auth/2.0/server", (ident, OPIdent))
      -- claimed identifiers
      , ("http://specs.openid.net/auth/2.0/signon", (localId, ClaimedIdent))
      , ("http://openid.net/signon/1.0"           , (localId, ClaimedIdent))
      , ("http://openid.net/signon/1.1"           , (localId, ClaimedIdent))
      ]
    uri <- listToMaybe $ serviceURIs svc
    return (Provider uri, lid, itype)


-- HTML-Based Discovery --------------------------------------------------------

-- | Attempt to discover an OpenID endpoint, from an HTML document.  The result
-- will be an endpoint on success, and the actual identifier of the user.
discoverHTML :: ( MonadIO m, Failure HttpException m)
             => Identifier
             -> m (Maybe Discovery)
discoverHTML ident'@(Identifier ident) =
    (parseHTML ident' . BSLU.toString) `liftM` simpleHttp (unpack ident)

-- | Parse out an OpenID endpoint and an actual identifier from an HTML
-- document.
parseHTML :: Identifier -> String -> Maybe Discovery
parseHTML ident = resolve
                . filter isOpenId
                . map (dropQuotes *** dropQuotes)
                . linkTags
                . htmlTags
  where
    isOpenId (rel,_) = "openid" `isPrefixOf` rel
    resolve1 ls = do
      server <- lookup "openid.server" ls
      let delegate = lookup "openid.delegate" ls
      return $ Discovery1 server delegate
    resolve2 ls = do
      prov <- lookup "openid2.provider" ls
      let lid = maybe ident (Identifier . pack) $ lookup "openid2.local_id" ls
      -- Based on OpenID 2.0 spec, section 7.3.3, HTML discovery can only
      -- result in a claimed identifier.
      return $ Discovery2 (Provider prov) lid ClaimedIdent
    resolve ls = resolve2 ls `mplus` resolve1 ls


-- FIXME this would all be a lot better if it used tagsoup
-- | Filter out link tags from a list of html tags.
linkTags :: [String] -> [(String,String)]
linkTags  = mapMaybe f . filter p
  where
    p = ("link " `isPrefixOf`)
    f xs = do
      let ys = unfoldr splitAttr (drop 5 xs)
      x <- lookup "rel"  ys
      y <- lookup "href" ys
      return (x,y)


-- | Split a string into strings of html tags.
htmlTags :: String -> [String]
htmlTags [] = []
htmlTags xs = case break (== '<') xs of
  (as,_:bs) -> fmt as : htmlTags bs
  (as,[])   -> [as]
  where
    fmt as = case break (== '>') as of
      (bs,_) -> bs


-- | Split out values from a key="value" like string, in a way that
-- is suitable for use with unfoldr.
splitAttr :: String -> Maybe ((String,String),String)
splitAttr xs = case break (== '=') xs of
  (_,[])         -> Nothing
  (key,_:'"':ys) -> f key (== '"') ys
  (key,_:ys)     -> f key isSpace  ys
  where
  f key p cs = case break p cs of
      (_,[])         -> Nothing
      (value,_:rest) -> Just ((key,value), dropWhile isSpace rest)

dropQuotes :: String -> String
dropQuotes s@('\'':x:y)
    | last y == '\'' = x : init y
    | otherwise = s
dropQuotes s@('"':x:y)
    | last y == '"' = x : init y
    | otherwise = s
dropQuotes s = s
