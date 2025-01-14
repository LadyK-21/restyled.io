-- | Facilities for tracing 'Middleware'
module Restyled.Tracing.Middleware
    ( transactionMiddleware
    , traceMiddlewareSegment
    ) where

import Restyled.Prelude

import qualified Data.Text as T
import Lens.Micro (_1, _2, (?~))
import Network.HTTP.Types.Status (statusCode, statusIsServerError)
import Network.Wai
    (Middleware, Request, Response, pathInfo, requestMethod, responseStatus)
import Restyled.Tracing.App
import Restyled.Tracing.TransactionId
import qualified Tracing.NewRelic as NR

-- Wrap everything this a Web Transaction, accessible in the 'TracingApp'
--
-- This should be the outermost 'Middleware'. Inner 'Middleware' (and your App)
-- can find the request-specific 'TransactionId' in the headers, which can be
-- used to look up the actual 'Transaction' in the 'TracingApp' and used for
-- tracing segments against it.
--
transactionMiddleware :: HasTracingApp env => env -> Middleware
transactionMiddleware env app req respond = do
    mTxId <-
        flip runReaderT env
        $ startWebTransaction
        $ TransactionName
        $ decodeUtf8With lenientDecode (requestMethod req)
        <> " /"
        <> T.intercalate "/" (pathInfo req)

    let
        (setup, after, finish) = case mTxId of
            Nothing -> (id, pure, pure ())
            Just txId ->
                ( transactionIdL ?~ txId
                , \resp -> runReaderT (updateTracedResponse txId resp) env
                , runReaderT (endTransaction txId) env
                )

    modifyResponseM after app (setup req) respond `finally` finish

modifyResponseM :: (Response -> IO Response) -> Middleware
modifyResponseM f app req respond = app req $ respond <=< f

updateTracedResponse
    :: (MonadIO m, MonadReader env m, HasTracingApp env)
    => TransactionId
    -> Response
    -> m Response
updateTracedResponse txId resp = do
    withTransaction_ txId $ \tx -> liftIO $ do
        void $ NR.addAttributeInt tx "http.status" statusInt
        when (statusIsServerError status) $ do
            void $ NR.noticeError tx 99 "Server Error" $ pack $ show statusInt
    pure $ resp & transactionIdL ?~ txId
  where
    statusInt :: Int32
    statusInt = fromIntegral $ statusCode status
    status = responseStatus resp

traceMiddlewareSegment
    :: HasTracingApp env => env -> SegmentName -> Middleware -> Middleware
traceMiddlewareSegment env name middle app req respond = do
    flip runReaderT (withRequest env req)
        $ traceSegment (Just name) (Just $ SegmentCategory "Middleware")
        $ lift
        $ middle app req respond

newtype WithRequest env = WithRequest (env, Request)

unL :: Lens' (WithRequest env) (env, Request)
unL = lens coerce $ const coerce

instance HasTracingApp env => HasTracingApp (WithRequest env) where
    tracingAppL = unL . _1 . tracingAppL

instance HasTransactionId (WithRequest env) where
    transactionIdL = unL . _2 . transactionIdL

withRequest :: env -> Request -> WithRequest env
withRequest x req = WithRequest (x, req)
