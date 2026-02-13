{-# LANGUAGE OverloadedStrings #-}
module Jobbie.Client
  ( JobbieClient(..)
  , EnqueueResult(..)
  , enqueue
  , getJob
  ) where

import Data.Aeson
import qualified Data.ByteString.Char8 as B
import qualified Data.Text as T
import Network.HTTP.Simple

data JobbieClient = JobbieClient
  { baseUrl :: String
  , apiKey :: Maybe String
  }

data EnqueueResult = EnqueueResult
  { job_id :: T.Text
  , status :: T.Text
  } deriving (Show)

instance FromJSON EnqueueResult where
  parseJSON = withObject "EnqueueResult" $ \o ->
    EnqueueResult <$> o .: "job_id" <*> o .: "status"

enqueue :: JobbieClient -> T.Text -> Value -> IO (Either String EnqueueResult)
enqueue client queue payload = do
  req0 <- parseRequest (baseUrl client ++ "/api/v1/enqueue")
  let req1 = setRequestMethod "POST"
          $ setRequestBodyJSON (object ["queue" .= queue, "payload" .= payload]) req0
      req2 = maybe req1 (\k -> addRequestHeader "X-API-Key" (B.pack k) req1) (apiKey client)
  resp <- httpJSONEither req2
  pure (getResponseBody resp)

getJob :: JobbieClient -> T.Text -> IO (Either String Value)
getJob client jobId = do
  req0 <- parseRequest (baseUrl client ++ "/api/v1/jobs/" ++ T.unpack jobId)
  let req1 = maybe req0 (\k -> addRequestHeader "X-API-Key" (B.pack k) req0) (apiKey client)
  resp <- httpJSONEither req1
  pure (getResponseBody resp)
