{-# LANGUAGE TupleSections #-}

module Restyled.Tracing.App
    ( TracingApp(TracingDisabled)
    , HasTracingApp(..)
    , newTracingApp
    , TransactionName(..)
    , startWebTransaction
    , endTransaction
    , withTransaction
    , withTransaction_
    , SegmentName(..)
    , SegmentCategory(..)
    , traceSegment
    ) where

import Restyled.Prelude

import qualified Data.HashMap.Strict as HashMap
import Restyled.Tracing.Config
import Restyled.Tracing.TransactionId
import Tracing.NewRelic hiding (endTransaction, init, startWebTransaction)
import qualified Tracing.NewRelic as NR
import Yesod.Core.Types (HandlerData)
import Yesod.Core.Types.Lens

data TracingApp
    = TracingApp App (IORef (HashMap TransactionId Transaction))
    | TracingDisabled

class HasTracingApp env where
    tracingAppL :: Lens' env TracingApp

instance HasTracingApp TracingApp where
    tracingAppL = id

instance HasTracingApp env => HasTracingApp (HandlerData child env) where
    tracingAppL = envL . siteL . tracingAppL

newTracingApp :: MonadUnliftIO m => TracingConfig -> m TracingApp
newTracingApp TracingConfig {..} =
    handleAny (const $ pure TracingDisabled) $ liftIO $ maybe
        (pure TracingDisabled)
        (newApp <=< go)
        tcLicenseKey
  where
    go key = do
        void $ NR.init tcDaemonSocket $ TimeLimitMs 1000
        config <- createAppConfig tcAppName key
        void $ configureLog tcLog $ unTracingLogLevel tcLogLevel
        createApp config tcTimeoutMs

    newApp :: MonadIO m => App -> m TracingApp
    newApp x = TracingApp x <$> newIORef HashMap.empty

newtype TransactionName = TransactionName
    { unTransactionName :: Text
    }
    deriving newtype IsString

startWebTransaction
    :: (MonadIO m, MonadReader env m, HasTracingApp env)
    => TransactionName
    -> m (Maybe TransactionId)
startWebTransaction name = view tracingAppL >>= \case
    TracingApp app ref -> liftIO $ do
        mTransaction <- NR.startWebTransaction app $ unTransactionName name
        for mTransaction $ \tx -> do
            txId <- newTransactionId
            atomicModifyIORef' ref $ (, txId) . HashMap.insert txId tx
    TracingDisabled -> pure Nothing

endTransaction
    :: (MonadIO m, MonadReader env m, HasTracingApp env)
    => TransactionId
    -> m ()
endTransaction txId = view tracingAppL >>= \case
    TracingApp _ ref -> liftIO $ do
        mTxId <- atomicModifyIORef' ref $ deleteLookup txId
        traverse_ NR.endTransaction mTxId
    TracingDisabled -> pure ()
  where
    deleteLookup
        :: TransactionId
        -> HashMap TransactionId Transaction
        -> (HashMap TransactionId Transaction, Maybe Transaction)
    deleteLookup k hm = (HashMap.delete k hm, HashMap.lookup k hm)

withTransaction
    :: (MonadIO m, MonadReader env m, HasTracingApp env)
    => TransactionId
    -> (Transaction -> m (Maybe a))
    -> m (Maybe a)
withTransaction txId f = view tracingAppL >>= \case
    TracingApp _ ref -> do
        mTx <- HashMap.lookup txId <$> readIORef ref
        join <$> traverse f mTx
    TracingDisabled -> pure Nothing

withTransaction_
    :: (MonadIO m, MonadReader env m, HasTracingApp env)
    => TransactionId
    -> (Transaction -> m a)
    -> m ()
withTransaction_ txId f = view tracingAppL >>= \case
    TracingApp _ ref -> do
        mTx <- HashMap.lookup txId <$> readIORef ref
        traverse_ f mTx
    TracingDisabled -> pure ()

newtype SegmentName = SegmentName
    { unSegmentName :: Text
    }
    deriving newtype IsString

newtype SegmentCategory = SegmentCategory
    { unSegmentCategory :: Text
    }

traceSegment
    :: ( MonadUnliftIO m
       , MonadReader env m
       , HasTracingApp env
       , HasTransactionId env
       )
    => Maybe SegmentName
    -> Maybe SegmentCategory
    -> m a
    -> m a
traceSegment name category untraced = do
    maybe untraced go =<< view transactionIdL
  where
    go txId = do
        mSegment <- withTransaction txId $ \tx -> liftIO $ startSegment
            tx
            (unSegmentName <$> name)
            (unSegmentCategory <$> category)
        untraced `finally` traverse_ (liftIO . endSegment) mSegment
