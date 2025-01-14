module Restyled.Queues
    ( Queues
    , readQueues
    , defaultQueues
    , HasQueues(..)

    -- * Enqueuing
    , enqueue
    ) where

import Restyled.Prelude

import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import Restyled.Redis
import Test.QuickCheck
import Yesod.Core.Types (HandlerData)
import Yesod.Core.Types.Lens

newtype Queues = Queues
    { _unQueues :: NonEmpty Queue
    }

data Queue = Queue
    { queueName :: ByteString
    , queueFrequency :: Natural
    }

class HasQueues env where
    queuesL :: Lens' env  Queues

instance HasQueues Queues where
    queuesL = id

instance HasQueues env => HasQueues (HandlerData child env) where
    queuesL = envL . siteL . queuesL

-- | Read a 'Queues' value, e.g. from @ENV@
--
-- Format:
--
-- > {queue}(/{frequency})(, ...)
--
-- - Multiple values can be comma-separated
-- - @queue@ cannot contain @/@ or @,@
-- - @frequency@ can be any number, and determines frequency to use that queue
--
-- Examples:
--
-- > -- Default, just a single queue
-- > RESTYLER_QUEUES=restyled:hooks:webhooks
-- >
-- > -- Send 50% to the new "agent" queue
-- > RESTYLER_QUEUES=restyled:agent:webhooks/1,restyled:hooks:webhooks/2
--
readQueues :: String -> Either String Queues
readQueues = first unpack . go . pack
  where
    go t = case NE.nonEmpty $ map T.strip $ T.splitOn "," t of
        Nothing -> Left "Queues value cannot be empty"
        Just ts -> Queues <$> traverse readQueue ts

defaultQueues :: Queues
defaultQueues = Queues $ pure $ Queue
    { queueName = "restyled:agent:webhooks"
    , queueFrequency = 1
    }

readQueue :: Text -> Either Text Queue
readQueue t = case T.breakOn "/" t of
    (q, _) | T.null q -> Left "Queue name cannot be empty"
    (q, f) | T.null f -> Right $ Queue (encodeUtf8 q) 1
    (q, f) -> Queue (encodeUtf8 q) <$> readEither (unpack $ T.drop 1 f)

enqueue :: Queues -> ByteString -> Redis ()
enqueue qs body = do
    q <- liftIO $ selectQueue qs
    void $ lpush (queueName q) $ pure body

selectQueue :: MonadIO m => Queues -> m Queue
selectQueue (Queues qs)
    | length qs == 1 = pure $ NE.head qs
    | otherwise = liftIO $ generate $ frequency $ NE.toList $ toPair <$> qs
  where
    toPair :: Queue -> (Int, Gen Queue)
    toPair q = (fromIntegral $ queueFrequency q, pure q)
