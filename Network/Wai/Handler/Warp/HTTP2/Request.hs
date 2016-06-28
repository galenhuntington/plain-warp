{-# LANGUAGE OverloadedStrings, CPP #-}
{-# LANGUAGE BangPatterns #-}

module Network.Wai.Handler.Warp.HTTP2.Request (
    mkRequest
  , MkReq
  , getHTTP2Data
  , setHTTP2Data
  ) where

import Control.Applicative ((<|>))
import Control.Arrow (first)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B8
import Data.Maybe (fromJust)
import qualified Data.Vault.Lazy as Vault
import Network.HPACK
import Network.HPACK.Token
import qualified Network.HTTP.Types as H
import Network.Socket (SockAddr)
import Network.Wai
import Network.Wai.Handler.Warp.HTTP2.Types
import Network.Wai.Handler.Warp.HashMap (hashByteString)
import Network.Wai.Handler.Warp.IORef
import Network.Wai.Handler.Warp.Request (pauseTimeoutKey, getFileInfoKey)
import qualified Network.Wai.Handler.Warp.Settings as S (Settings, settingsNoParsePath)
import qualified Network.Wai.Handler.Warp.Timeout as Timeout
import Network.Wai.Handler.Warp.Types
import Network.Wai.Internal (Request(..))
import System.IO.Unsafe (unsafePerformIO)

type MkReq = (TokenHeaderList,ValueTable) -> IO ByteString -> IO (Request,InternalInfo)

mkRequest :: InternalInfo1 -> S.Settings -> SockAddr -> MkReq
mkRequest ii1 settings addr (reqths,reqvt) body = do
    ref <- newIORef Nothing
    mkRequest' ii1 settings addr ref (reqths,reqvt) body

mkRequest' :: InternalInfo1 -> S.Settings -> SockAddr
           -> IORef (Maybe HTTP2Data)
           -> MkReq
mkRequest' ii1 settings addr ref (reqths,reqvt) body = return (req,ii)
  where
    !req = Request {
        requestMethod = colonMethod
      , httpVersion = http2ver
      , rawPathInfo = rawPath
      , pathInfo = H.decodePathSegments path
      , rawQueryString = query
      , queryString = H.parseQuery query
      , requestHeaders = headers
      , isSecure = True
      , remoteHost = addr
      , requestBody = body
      , vault = vaultValue
      , requestBodyLength = ChunkedBody -- fixme
      , requestHeaderHost      = mHost <|> mAuth
      , requestHeaderRange     = mRange
      , requestHeaderReferer   = mReferer
      , requestHeaderUserAgent = mUserAgent
      }
    headers = map (first tokenKey) ths
      where
        ths = case mHost of
            Just _  -> reqths
            Nothing -> case mAuth of
              Just auth -> (tokenHost, auth) : reqths
              _         -> reqths
    !colonPath = fromJust $ getHeaderValue tokenPath reqvt -- MUST
    !colonMethod = fromJust $ getHeaderValue tokenMethod reqvt -- MUST
    !mAuth = getHeaderValue tokenAuthority reqvt -- SHOULD
    !mHost = getHeaderValue tokenHost reqvt
    !mRange = getHeaderValue tokenRange reqvt
    !mReferer = getHeaderValue tokenReferer reqvt
    !mUserAgent = getHeaderValue tokenUserAgent reqvt
    (unparsedPath,query) = B8.break (=='?') colonPath
    !path = H.extractPath unparsedPath
    !rawPath = if S.settingsNoParsePath settings then unparsedPath else path
    !h = hashByteString rawPath
    !ii = toInternalInfo ii1 h
    !th = threadHandle ii
    !vaultValue = Vault.insert pauseTimeoutKey (Timeout.pause th)
                $ Vault.insert getFileInfoKey (getFileInfo ii)
                $ Vault.insert getHTTP2DataKey (readIORef ref)
                $ Vault.insert setHTTP2DataKey (writeIORef ref)
                  Vault.empty

getHTTP2DataKey :: Vault.Key (IO (Maybe HTTP2Data))
getHTTP2DataKey = unsafePerformIO Vault.newKey
{-# NOINLINE getHTTP2Data #-}

getHTTP2Data :: Request -> IO (Maybe HTTP2Data)
getHTTP2Data req = case Vault.lookup getHTTP2DataKey (vault req) of
  Nothing     -> return Nothing
  Just getter -> getter

setHTTP2DataKey :: Vault.Key (Maybe HTTP2Data -> IO ())
setHTTP2DataKey = unsafePerformIO Vault.newKey
{-# NOINLINE setHTTP2Data #-}

setHTTP2Data :: Request -> Maybe HTTP2Data -> IO ()
setHTTP2Data req mh2d = case Vault.lookup setHTTP2DataKey (vault req) of
  Nothing     -> return ()
  Just setter -> setter mh2d
