{-# LANGUAGE OverloadedStrings, CPP #-}
{-# LANGUAGE NamedFieldPuns, RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}

module Network.Wai.Handler.Warp.HTTP2.Types where

import Data.ByteString.Builder (Builder)
#if __GLASGOW_HASKELL__ < 709
import Control.Applicative ((<$>),(<*>))
#endif
import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Exception (SomeException, bracket)
import Control.Monad (void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.IntMap.Strict (IntMap, IntMap)
import qualified Data.IntMap.Strict as M
import qualified Network.HTTP.Types as H
import Network.Wai (Request, FilePart)
import Network.Wai.Handler.Warp.HTTP2.Manager
import Network.Wai.Handler.Warp.IORef
import Network.Wai.Handler.Warp.Types

import Network.HTTP2
import Network.HTTP2.Priority
import Network.HPACK hiding (Buffer)

----------------------------------------------------------------

http2ver :: H.HttpVersion
http2ver = H.HttpVersion 2 0

isHTTP2 :: Transport -> Bool
isHTTP2 TCP = False
isHTTP2 tls = useHTTP2
  where
    useHTTP2 = case tlsNegotiatedProtocol tls of
        Nothing    -> False
        Just proto -> "h2-" `BS.isPrefixOf` proto

----------------------------------------------------------------

data Input = Input Stream Request ValueTable InternalInfo

----------------------------------------------------------------

type DynaNext = Buffer -> BufSize -> WindowSize -> IO Next

type BytesFilled = Int

data Next = Next !BytesFilled (Maybe DynaNext)

data Rspn = RspnNobody    H.Status (TokenHeaderList, ValueTable)
          | RspnStreaming H.Status (TokenHeaderList, ValueTable) (TBQueue Sequence)
          | RspnBuilder   H.Status (TokenHeaderList, ValueTable) Builder
          | RspnFile      H.Status (TokenHeaderList, ValueTable) FilePath (Maybe FilePart)

rspnStatus :: Rspn -> H.Status
rspnStatus (RspnNobody    s _)      = s
rspnStatus (RspnStreaming s _ _)    = s
rspnStatus (RspnBuilder   s _ _)    = s
rspnStatus (RspnFile      s _ _ _ ) = s

rspnHeaders :: Rspn -> (TokenHeaderList, ValueTable)
rspnHeaders (RspnNobody    _ t)      = t
rspnHeaders (RspnStreaming _ t _)    = t
rspnHeaders (RspnBuilder   _ t _)    = t
rspnHeaders (RspnFile      _ t _ _ ) = t

data Output = ORspn !Stream !Rspn !InternalInfo (IO ()) -- done
            | OWait !Stream !Rspn !InternalInfo (IO ()) -- done
            | OPush !Stream -- stream for this push from this server
                    TokenHeaderList
                    !Rspn {- RspnFile only-}
                    !InternalInfo (IO ()) -- wait for done
                    !StreamId -- associated stream id from client
            | ONext !Stream !DynaNext !(Maybe (TBQueue Sequence)) (IO ()) -- done

outputStream :: Output -> Stream
outputStream (ORspn strm _ _ _)     = strm
outputStream (OPush strm _ _ _ _ _) = strm
outputStream (OWait strm _ _ _)     = strm
outputStream (ONext strm _ _ _)     = strm

outputMaybeTBQueue :: Output -> Maybe (TBQueue Sequence)
outputMaybeTBQueue (ORspn _ (RspnStreaming _ _ tbq) _ _) = Just tbq
outputMaybeTBQueue (ORspn _ _ _ _)                       = Nothing
outputMaybeTBQueue (OPush _ _ _ _ _ _)                   = Nothing
outputMaybeTBQueue (OWait _ _ _ _)                       = Nothing
outputMaybeTBQueue (ONext _ _ mtbq _)                    = mtbq

data Control = CFinish
             | CGoaway    !ByteString
             | CFrame     !ByteString
             | CSettings  !ByteString !SettingsList
             | CSettings0 !ByteString !ByteString !SettingsList

----------------------------------------------------------------

data Sequence = SFinish
              | SFlush
              | SBuilder Builder

----------------------------------------------------------------

-- | The context for HTTP/2 connection.
data Context = Context {
  -- HTTP/2 settings received from a browser
    http2settings      :: !(IORef Settings)
  , firstSettings      :: !(IORef Bool)
  , streamTable        :: !StreamTable
  , concurrency        :: !(IORef Int)
  , priorityTreeSize   :: !(IORef Int)
  -- | RFC 7540 says "Other frames (from any stream) MUST NOT
  --   occur between the HEADERS frame and any CONTINUATION
  --   frames that might follow". This field is used to implement
  --   this requirement.
  , continued          :: !(IORef (Maybe StreamId))
  , clientStreamId     :: !(IORef StreamId)
  , serverStreamId     :: !(IORef StreamId)
  , inputQ             :: !(TQueue Input)
  , outputQ            :: !(PriorityTree Output)
  , controlQ           :: !(TQueue Control)
  , encodeDynamicTable :: !DynamicTable
  , decodeDynamicTable :: !DynamicTable
  -- the connection window for data from a server to a browser.
  , connectionWindow   :: !(TVar WindowSize)
  }

----------------------------------------------------------------

newContext :: IO Context
newContext = Context <$> newIORef defaultSettings
                     <*> newIORef False
                     <*> newStreamTable
                     <*> newIORef 0
                     <*> newIORef 0
                     <*> newIORef Nothing
                     <*> newIORef 0
                     <*> newIORef 0
                     <*> newTQueueIO
                     <*> newPriorityTree
                     <*> newTQueueIO
                     <*> newDynamicTableForEncoding defaultDynamicTableSize
                     <*> newDynamicTableForDecoding defaultDynamicTableSize 4096
                     <*> newTVarIO defaultInitialWindowSize

clearContext :: Context -> IO ()
clearContext _ctx = return ()

----------------------------------------------------------------

data OpenState =
    JustOpened
  | Continued [HeaderBlockFragment]
              !Int  -- Total size
              !Int  -- The number of continuation frames
              !Bool -- End of stream
              !Priority
  | NoBody (TokenHeaderList,ValueTable) !Priority
  | HasBody (TokenHeaderList,ValueTable) !Priority
  | Body !(TQueue ByteString)
         !(Maybe Int) -- received Content-Length
                      -- compared the body length for error checking
         !(IORef Int) -- actual body length

data ClosedCode = Finished
                | Killed
                | Reset !ErrorCodeId
                | ResetByMe SomeException
                deriving Show

data StreamState =
    Idle
  | Open !OpenState
  | HalfClosed
  | Closed !ClosedCode
  | Reserved

isIdle :: StreamState -> Bool
isIdle Idle = True
isIdle _    = False

isOpen :: StreamState -> Bool
isOpen Open{} = True
isOpen _      = False

isHalfClosed :: StreamState -> Bool
isHalfClosed HalfClosed = True
isHalfClosed _          = False

isClosed :: StreamState -> Bool
isClosed Closed{} = True
isClosed _        = False

instance Show StreamState where
    show Idle        = "Idle"
    show Open{}      = "Open"
    show HalfClosed  = "HalfClosed"
    show (Closed e)  = "Closed: " ++ show e
    show Reserved    = "Reserved"

----------------------------------------------------------------

data Stream = Stream {
    streamNumber     :: !StreamId
  , streamState      :: !(IORef StreamState)
  , streamWindow     :: !(TVar WindowSize)
  , streamPrecedence :: !(IORef Precedence)
  }

instance Show Stream where
  show s = show (streamNumber s)

newStream :: StreamId -> WindowSize -> IO Stream
newStream sid win = Stream sid <$> newIORef Idle
                               <*> newTVarIO win
                               <*> newIORef defaultPrecedence

newPushStream :: Context -> WindowSize -> Precedence -> IO Stream
newPushStream Context{serverStreamId} win pre = do
    sid <- atomicModifyIORef' serverStreamId inc2
    Stream sid <$> newIORef Reserved
               <*> newTVarIO win
               <*> newIORef pre
  where
    inc2 x = let !x' = x + 2 in (x', x')

----------------------------------------------------------------

opened :: Context -> Stream -> IO ()
opened Context{concurrency} Stream{streamState} = do
    atomicModifyIORef' concurrency (\x -> (x+1,()))
    writeIORef streamState (Open JustOpened)

closed :: Context -> Stream -> ClosedCode -> IO ()
closed Context{concurrency,streamTable} Stream{streamState,streamNumber} cc = do
    remove streamTable streamNumber
    atomicModifyIORef' concurrency (\x -> (x-1,()))
    writeIORef streamState (Closed cc) -- anyway

----------------------------------------------------------------

newtype StreamTable = StreamTable (IORef (IntMap Stream))

newStreamTable :: IO StreamTable
newStreamTable = StreamTable <$> newIORef M.empty

insert :: StreamTable -> M.Key -> Stream -> IO ()
insert (StreamTable ref) k v = atomicModifyIORef' ref $ \m ->
    let !m' = M.insert k v m
    in (m', ())

remove :: StreamTable -> M.Key -> IO ()
remove (StreamTable ref) k = atomicModifyIORef' ref $ \m ->
    let !m' = M.delete k m
    in (m', ())

search :: StreamTable -> M.Key -> IO (Maybe Stream)
search (StreamTable ref) k = M.lookup k <$> readIORef ref

{-# INLINE forkAndEnqueueWhenReady #-}
forkAndEnqueueWhenReady :: IO () -> PriorityTree Output -> Output -> Manager -> IO ()
forkAndEnqueueWhenReady wait outQ out mgr = bracket setup teardown $ \_ ->
    void . forkIO $ do
        wait
        enqueueOutput outQ out
  where
    setup = addMyId mgr
    teardown _ = deleteMyId mgr

{-# INLINE enqueueOutput #-}
enqueueOutput :: PriorityTree Output -> Output -> IO ()
enqueueOutput outQ out = do
    let Stream{..} = outputStream out
    pre <- readIORef streamPrecedence
    enqueue outQ streamNumber pre out

{-# INLINE enqueueControl #-}
enqueueControl :: TQueue Control -> Control -> IO ()
enqueueControl ctlQ ctl = atomically $ writeTQueue ctlQ ctl

----------------------------------------------------------------

newtype HTTP2Data = HTTP2Data {
      http2dataPushPromise :: [PushPromise]
    }

defaultHTTP2Data :: HTTP2Data
defaultHTTP2Data = HTTP2Data []

data PushPromise = PushPromise {
      promisedPath            :: ByteString
    , promisedFile            :: FilePath
    , promisedResponseHeaders :: H.ResponseHeaders
    , promisedWeight          :: Weight
    }

defaultPushPromise :: PushPromise
defaultPushPromise = PushPromise "" "" [] 16
