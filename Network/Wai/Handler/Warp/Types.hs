{-# LANGUAGE DeriveDataTypeable #-}

module Network.Wai.Handler.Warp.Types where

import Control.Exception
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Typeable (Typeable)
import Data.Version (showVersion)
import qualified Paths_warp

warpVersion :: String
warpVersion = showVersion Paths_warp.version

type Port = Int

data InvalidRequest =
    NotEnoughLines [String]
    | BadFirstLine String
    | NonHttp
    | IncompleteHeaders
    | ConnectionClosedByPeer
    | OverLargeHeader
    deriving (Eq, Show, Typeable)

instance Exception InvalidRequest

-- |
--
-- In order to provide slowloris protection, Warp provides timeout handlers. We
-- follow these rules:
--
-- * A timeout is created when a connection is opened.
--
-- * When all request headers are read, the timeout is tickled.
--
-- * Every time at least 2048 bytes of the request body are read, the timeout
--   is tickled.
--
-- * The timeout is paused while executing user code. This will apply to both
--   the application itself, and a ResponseSource response. The timeout is
--   resumed as soon as we return from user code.
--
-- * Every time data is successfully sent to the client, the timeout is tickled.
data Connection = Connection
    { connSendMany :: [B.ByteString] -> IO ()
    , connSendAll  :: B.ByteString -> IO ()
    , connSendFile :: FilePath -> Integer -> Integer -> IO () -> [ByteString] -> IO () -- ^ offset, length
    , connClose    :: IO ()
    , connRecv     :: IO B.ByteString
    }
