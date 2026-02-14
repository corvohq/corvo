{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Corvo.Client
  ( CorvoClient(..)
  , EnqueueOptions(..)
  , EnqueueResult(..)
  , BatchJob(..)
  , BatchConfig(..)
  , BatchResult(..)
  , FetchedJob(..)
  , HeartbeatResult(..)
  , SearchFilter(..)
  , SearchResult(..)
  , BulkRequest(..)
  , BulkResult(..)
  , BulkTask(..)
  , defaultEnqueueOptions
  , defaultSearchFilter
  , enqueue
  , enqueueWith
  , enqueueBatch
  , fetch
  , ack
  , fail
  , heartbeat
  , getJob
  , retryJob
  , cancelJob
  , moveJob
  , deleteJob
  , search
  , bulk
  , bulkStatus
  ) where

import Prelude hiding (fail)
import Data.Aeson
import Data.Aeson.Types (Pair)
import qualified Data.ByteString.Char8 as B
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import Network.HTTP.Simple

-- | Client configuration.
data CorvoClient = CorvoClient
  { baseUrl     :: String
  , apiKey      :: Maybe String
  , bearerToken :: Maybe String
  }

-- | Options for enqueue with extras.
data EnqueueOptions = EnqueueOptions
  { eoQueue       :: T.Text
  , eoPayload     :: Value
  , eoPriority    :: Maybe T.Text
  , eoUniqueKey   :: Maybe T.Text
  , eoUniquePeriod :: Maybe Int
  , eoMaxRetries  :: Maybe Int
  , eoScheduledAt :: Maybe T.Text
  , eoTags        :: Maybe (HM.HashMap T.Text T.Text)
  , eoExpireAfter :: Maybe T.Text
  , eoChain       :: Maybe Value
  } deriving (Show)

-- | Sensible defaults — caller must set eoQueue and eoPayload.
defaultEnqueueOptions :: T.Text -> Value -> EnqueueOptions
defaultEnqueueOptions q p = EnqueueOptions q p Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

data EnqueueResult = EnqueueResult
  { erJobId  :: T.Text
  , erStatus :: T.Text
  } deriving (Show)

instance FromJSON EnqueueResult where
  parseJSON = withObject "EnqueueResult" $ \o ->
    EnqueueResult <$> o .: "job_id" <*> o .: "status"

data BatchJob = BatchJob
  { bjQueue   :: T.Text
  , bjPayload :: Value
  } deriving (Show)

instance ToJSON BatchJob where
  toJSON BatchJob{..} = object ["queue" .= bjQueue, "payload" .= bjPayload]

data BatchConfig = BatchConfig
  { bcCallbackQueue   :: T.Text
  , bcCallbackPayload :: Maybe Value
  } deriving (Show)

instance ToJSON BatchConfig where
  toJSON BatchConfig{..} = object $
    ["callback_queue" .= bcCallbackQueue] <> maybe [] (\p -> ["callback_payload" .= p]) bcCallbackPayload

data BatchResult = BatchResult
  { brJobIds  :: [T.Text]
  , brBatchId :: T.Text
  } deriving (Show)

instance FromJSON BatchResult where
  parseJSON = withObject "BatchResult" $ \o ->
    BatchResult <$> o .: "job_ids" <*> o .: "batch_id"

data FetchedJob = FetchedJob
  { fjJobId   :: T.Text
  , fjQueue   :: T.Text
  , fjPayload :: Value
  , fjAttempt :: Int
  } deriving (Show)

instance FromJSON FetchedJob where
  parseJSON = withObject "FetchedJob" $ \o ->
    FetchedJob <$> o .: "job_id" <*> o .: "queue" <*> o .: "payload" <*> o .: "attempt"

data HeartbeatResult = HeartbeatResult
  { hrAcked    :: [T.Text]
  , hrUnknown  :: [T.Text]
  , hrCanceled :: [T.Text]
  } deriving (Show)

instance FromJSON HeartbeatResult where
  parseJSON = withObject "HeartbeatResult" $ \o ->
    HeartbeatResult <$> o .: "acked" <*> o .: "unknown" <*> o .: "canceled"

data SearchFilter = SearchFilter
  { sfQueue           :: Maybe T.Text
  , sfState           :: Maybe [T.Text]
  , sfPriority        :: Maybe T.Text
  , sfPayloadContains :: Maybe T.Text
  , sfSort            :: Maybe T.Text
  , sfOrder           :: Maybe T.Text
  , sfLimit           :: Maybe Int
  , sfCursor          :: Maybe T.Text
  } deriving (Show)

defaultSearchFilter :: SearchFilter
defaultSearchFilter = SearchFilter Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

instance ToJSON SearchFilter where
  toJSON SearchFilter{..} = object $ concat
    [ maybe [] (\v -> ["queue" .= v]) sfQueue
    , maybe [] (\v -> ["state" .= v]) sfState
    , maybe [] (\v -> ["priority" .= v]) sfPriority
    , maybe [] (\v -> ["payload_contains" .= v]) sfPayloadContains
    , maybe [] (\v -> ["sort" .= v]) sfSort
    , maybe [] (\v -> ["order" .= v]) sfOrder
    , maybe [] (\v -> ["limit" .= v]) sfLimit
    , maybe [] (\v -> ["cursor" .= v]) sfCursor
    ]

data SearchResult = SearchResult
  { srJobs    :: [Value]
  , srTotal   :: Int
  , srCursor  :: Maybe T.Text
  , srHasMore :: Bool
  } deriving (Show)

instance FromJSON SearchResult where
  parseJSON = withObject "SearchResult" $ \o ->
    SearchResult <$> o .: "jobs" <*> o .: "total" <*> o .:? "cursor" <*> o .: "has_more"

data BulkRequest = BulkRequest
  { buJobIds      :: Maybe [T.Text]
  , buFilter      :: Maybe SearchFilter
  , buAction      :: T.Text
  , buMoveToQueue :: Maybe T.Text
  , buPriority    :: Maybe T.Text
  , buAsync       :: Maybe Bool
  } deriving (Show)

instance ToJSON BulkRequest where
  toJSON BulkRequest{..} = object $ concat
    [ maybe [] (\v -> ["job_ids" .= v]) buJobIds
    , maybe [] (\v -> ["filter" .= v]) buFilter
    , ["action" .= buAction]
    , maybe [] (\v -> ["move_to_queue" .= v]) buMoveToQueue
    , maybe [] (\v -> ["priority" .= v]) buPriority
    , maybe [] (\v -> ["async" .= v]) buAsync
    ]

data BulkResult = BulkResult
  { buResAffected   :: Maybe Int
  , buResErrors     :: Maybe Int
  , buResDurationMs :: Maybe Double
  , buResBulkOpId   :: Maybe T.Text
  } deriving (Show)

instance FromJSON BulkResult where
  parseJSON = withObject "BulkResult" $ \o ->
    BulkResult <$> o .:? "affected" <*> o .:? "errors" <*> o .:? "duration_ms" <*> o .:? "bulk_operation_id"

data BulkTask = BulkTask
  { btId        :: T.Text
  , btStatus    :: T.Text
  , btAction    :: T.Text
  , btTotal     :: Int
  , btProcessed :: Int
  , btAffected  :: Int
  , btErrors    :: Int
  } deriving (Show)

instance FromJSON BulkTask where
  parseJSON = withObject "BulkTask" $ \o ->
    BulkTask <$> o .: "id" <*> o .: "status" <*> o .: "action"
             <*> o .: "total" <*> o .: "processed" <*> o .: "affected" <*> o .: "errors"

-- | Apply auth headers to a request.
applyAuth :: CorvoClient -> Request -> Request
applyAuth client req =
  let r1 = maybe req (\k -> addRequestHeader "X-API-Key" (B.pack k) req) (apiKey client)
      r2 = maybe r1 (\t -> addRequestHeader "Authorization" (B.pack $ "Bearer " <> t) r1) (bearerToken client)
  in r2

-- | Simple enqueue with queue name and payload.
enqueue :: CorvoClient -> T.Text -> Value -> IO (Either String EnqueueResult)
enqueue client queue payload = do
  req0 <- parseRequest (baseUrl client ++ "/api/v1/enqueue")
  let req1 = setRequestMethod "POST"
          $ setRequestBodyJSON (object ["queue" .= queue, "payload" .= payload]) req0
      req2 = applyAuth client req1
  resp <- httpJSONEither req2
  pure (getResponseBody resp)

-- | Enqueue with full options.
enqueueWith :: CorvoClient -> EnqueueOptions -> IO (Either String EnqueueResult)
enqueueWith client EnqueueOptions{..} = do
  req0 <- parseRequest (baseUrl client ++ "/api/v1/enqueue")
  let pairs = concat
        [ ["queue" .= eoQueue, "payload" .= eoPayload]
        , maybe [] (\v -> ["priority" .= v]) eoPriority
        , maybe [] (\v -> ["unique_key" .= v]) eoUniqueKey
        , maybe [] (\v -> ["unique_period" .= v]) eoUniquePeriod
        , maybe [] (\v -> ["max_retries" .= v]) eoMaxRetries
        , maybe [] (\v -> ["scheduled_at" .= v]) eoScheduledAt
        , maybe [] (\v -> ["tags" .= v]) eoTags
        , maybe [] (\v -> ["expire_after" .= v]) eoExpireAfter
        , maybe [] (\v -> ["chain" .= v]) eoChain
        ] :: [Pair]
      req1 = setRequestMethod "POST" $ setRequestBodyJSON (object pairs) req0
      req2 = applyAuth client req1
  resp <- httpJSONEither req2
  pure (getResponseBody resp)

-- | Batch enqueue.
enqueueBatch :: CorvoClient -> [BatchJob] -> Maybe BatchConfig -> IO (Either String BatchResult)
enqueueBatch client jobs mbatch = do
  req0 <- parseRequest (baseUrl client ++ "/api/v1/enqueue/batch")
  let body = object $ ["jobs" .= jobs] <> maybe [] (\b -> ["batch" .= b]) mbatch
      req1 = setRequestMethod "POST" $ setRequestBodyJSON body req0
      req2 = applyAuth client req1
  resp <- httpJSONEither req2
  pure (getResponseBody resp)

-- | Long-poll fetch for a job.
fetch :: CorvoClient -> [T.Text] -> T.Text -> T.Text -> Int -> IO (Either String (Maybe FetchedJob))
fetch client queues workerId hostname timeout = do
  req0 <- parseRequest (baseUrl client ++ "/api/v1/fetch")
  let body = object [ "queues" .= queues, "worker_id" .= workerId
                     , "hostname" .= hostname, "timeout" .= timeout ]
      req1 = setRequestMethod "POST" $ setRequestBodyJSON body req0
      req2 = applyAuth client req1
  resp <- httpJSONEither req2
  case getResponseBody resp of
    Left err -> pure (Left err)
    Right job -> if fjJobId job == "" then pure (Right Nothing) else pure (Right (Just job))

-- | Acknowledge a job as complete.
ack :: CorvoClient -> T.Text -> Value -> IO (Either String Value)
ack client jobId body = do
  req0 <- parseRequest (baseUrl client ++ "/api/v1/ack/" ++ T.unpack jobId)
  let req1 = setRequestMethod "POST" $ setRequestBodyJSON body req0
      req2 = applyAuth client req1
  resp <- httpJSONEither req2
  pure (getResponseBody resp)

-- | Fail a job.
fail :: CorvoClient -> T.Text -> T.Text -> T.Text -> IO (Either String Value)
fail client jobId errMsg backtrace = do
  req0 <- parseRequest (baseUrl client ++ "/api/v1/fail/" ++ T.unpack jobId)
  let body = object ["error" .= errMsg, "backtrace" .= backtrace]
      req1 = setRequestMethod "POST" $ setRequestBodyJSON body req0
      req2 = applyAuth client req1
  resp <- httpJSONEither req2
  pure (getResponseBody resp)

-- | Batched heartbeat.
heartbeat :: CorvoClient -> Value -> IO (Either String HeartbeatResult)
heartbeat client jobs = do
  req0 <- parseRequest (baseUrl client ++ "/api/v1/heartbeat")
  let req1 = setRequestMethod "POST" $ setRequestBodyJSON (object ["jobs" .= jobs]) req0
      req2 = applyAuth client req1
  resp <- httpJSONEither req2
  pure (getResponseBody resp)

-- | Get a job by ID.
getJob :: CorvoClient -> T.Text -> IO (Either String Value)
getJob client jobId = do
  req0 <- parseRequest (baseUrl client ++ "/api/v1/jobs/" ++ T.unpack jobId)
  let req1 = applyAuth client req0
  resp <- httpJSONEither req1
  pure (getResponseBody resp)

-- | Retry a failed/dead job.
retryJob :: CorvoClient -> T.Text -> IO (Either String Value)
retryJob client jobId = postEmpty client ("/api/v1/jobs/" ++ T.unpack jobId ++ "/retry")

-- | Cancel a pending/active job.
cancelJob :: CorvoClient -> T.Text -> IO (Either String Value)
cancelJob client jobId = postEmpty client ("/api/v1/jobs/" ++ T.unpack jobId ++ "/cancel")

-- | Move a job to a different queue.
moveJob :: CorvoClient -> T.Text -> T.Text -> IO (Either String Value)
moveJob client jobId targetQueue = do
  req0 <- parseRequest (baseUrl client ++ "/api/v1/jobs/" ++ T.unpack jobId ++ "/move")
  let req1 = setRequestMethod "POST" $ setRequestBodyJSON (object ["queue" .= targetQueue]) req0
      req2 = applyAuth client req1
  resp <- httpJSONEither req2
  pure (getResponseBody resp)

-- | Delete a job.
deleteJob :: CorvoClient -> T.Text -> IO (Either String Value)
deleteJob client jobId = do
  req0 <- parseRequest (baseUrl client ++ "/api/v1/jobs/" ++ T.unpack jobId)
  let req1 = setRequestMethod "DELETE" $ applyAuth client req0
  resp <- httpJSONEither req1
  pure (getResponseBody resp)

-- | Search for jobs with filters.
search :: CorvoClient -> SearchFilter -> IO (Either String SearchResult)
search client filt = do
  req0 <- parseRequest (baseUrl client ++ "/api/v1/jobs/search")
  let req1 = setRequestMethod "POST" $ setRequestBodyJSON filt req0
      req2 = applyAuth client req1
  resp <- httpJSONEither req2
  pure (getResponseBody resp)

-- | Bulk operation on jobs.
bulk :: CorvoClient -> BulkRequest -> IO (Either String BulkResult)
bulk client bulkReq = do
  req0 <- parseRequest (baseUrl client ++ "/api/v1/jobs/bulk")
  let req1 = setRequestMethod "POST" $ setRequestBodyJSON bulkReq req0
      req2 = applyAuth client req1
  resp <- httpJSONEither req2
  pure (getResponseBody resp)

-- | Check status of an async bulk operation.
bulkStatus :: CorvoClient -> T.Text -> IO (Either String BulkTask)
bulkStatus client bulkId = do
  req0 <- parseRequest (baseUrl client ++ "/api/v1/bulk/" ++ T.unpack bulkId)
  let req1 = applyAuth client req0
  resp <- httpJSONEither req1
  pure (getResponseBody resp)

-- | Helper: POST with empty body.
postEmpty :: CorvoClient -> String -> IO (Either String Value)
postEmpty client path = do
  req0 <- parseRequest (baseUrl client ++ path)
  let req1 = setRequestMethod "POST" $ applyAuth client req0
  resp <- httpJSONEither req1
  pure (getResponseBody resp)
