{-# LANGUAGE OverloadedStrings #-}
module PartialFileSpec (main, spec) where

import Control.Concurrent (threadDelay)
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import Data.Maybe (mapMaybe)
import Network (connectTo, PortID (PortNumber))
import Network.HTTP.Types (status200)
import Network.Wai
import Network.Wai.Handler.Warp
import RunSpec (withApp)
import System.IO (hClose, hFlush)
import Test.Hspec

main :: IO ()
main = hspec spec

testRange :: S.ByteString -- ^ range value
          -> String -- ^ expected output
          -> String -- ^ expected content-range value
          -> Spec
testRange range out crange = it title $ withApp defaultSettings app $ \port -> do
    handle <- connectTo "127.0.0.1" $ PortNumber $ fromIntegral port
    S.hPutStr handle "GET / HTTP/1.0\r\n"
    S.hPutStr handle "Range: bytes="
    S.hPutStr handle range
    S.hPutStr handle "\r\n\r\n"
    hFlush handle
    threadDelay 10000
    bss <- fmap (lines . filter (/= '\r') . S8.unpack) $ S.hGetSome handle 1024
    hClose handle
    out `shouldBe` last bss
    let hs = mapMaybe toHeader bss
    lookup "Content-Range" hs `shouldBe` Just ("bytes " ++ crange)
    lookup "Content-Length" hs `shouldBe` Just (show $ length $ last bss)
  where
    app _ = return $ responseFile status200 [] "attic/hex" Nothing
    title = show (range, out, crange)
    toHeader s =
        case break (== ':') s of
            (x, ':':y) -> Just (x, dropWhile (== ' ') y)
            _ -> Nothing

testPartial :: Integer -- ^ file size
            -> Integer -- ^ offset
            -> Integer -- ^ byte count
            -> String -- ^ expected output
            -> Spec
testPartial size offset count out = it title $ withApp defaultSettings app $ \port -> do
    handle <- connectTo "127.0.0.1" $ PortNumber $ fromIntegral port
    S.hPutStr handle "GET / HTTP/1.0\r\n\r\n"
    hFlush handle
    threadDelay 10000
    bss <- fmap (lines . filter (/= '\r') . S8.unpack) $ S.hGetSome handle 1024
    hClose handle
    out `shouldBe` last bss
    let hs = mapMaybe toHeader bss
    lookup "Content-Length" hs `shouldBe` Just (show $ length $ last bss)
  where
    app _ = return $ responseFile status200 [] "attic/hex" $ Just $ FilePart offset count size
    title = show (offset, count, out)
    toHeader s =
        case break (== ':') s of
            (x, ':':y) -> Just (x, dropWhile (== ' ') y)
            _ -> Nothing

spec :: Spec
spec = do
    describe "range requests" $ do
        testRange "2-3" "23" "2-3/16"
        testRange "5-" "56789abcdef" "5-15/16"
        testRange "5-8" "5678" "5-8/16"
        testRange "-3" "def" "13-15/16"
    describe "partial files" $ do
        testPartial 16 2 2 "23"
        testPartial 16 0 2 "01"
        testPartial 16 3 8 "3456789a"
