{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -Wno-missing-local-signatures #-}

module Restyled.Application
    ( runWaiApp

    -- * For use in test
    , waiMiddleware
    ) where

import Restyled.Prelude

import qualified Data.List.NonEmpty as NE
import Lens.Micro (to, (^.))
import Network.Wai (Middleware)
import Network.Wai.Handler.Warp
import Network.Wai.Middleware.ForceSSL
import Network.Wai.Middleware.Logging
import Network.Wai.Middleware.MethodOverridePost
import Network.Wai.Middleware.Routed
import Network.Wai.Middleware.Timeout
import Restyled.Foundation
import Restyled.Handlers.Admin
import Restyled.Handlers.Admin.Marketplace
import Restyled.Handlers.Admin.Marketplace.Accounts
import Restyled.Handlers.Admin.Marketplace.Plans
import Restyled.Handlers.Admin.Offers
import Restyled.Handlers.Admin.Repos
import Restyled.Handlers.Admin.Token
import Restyled.Handlers.Favicon
import Restyled.Handlers.GitHubStudents
import Restyled.Handlers.Home
import Restyled.Handlers.Jobs
import Restyled.Handlers.Marketplace
import Restyled.Handlers.Offers
import Restyled.Handlers.PrivacyPolicy
import Restyled.Handlers.Profile
import Restyled.Handlers.Repos
import Restyled.Handlers.Repos.Jobs
import Restyled.Handlers.Repos.Jobs.LogLines
import Restyled.Handlers.Repos.Pulls
import Restyled.Handlers.Repos.Pulls.Jobs
import Restyled.Handlers.Revision
import Restyled.Handlers.Robots
import Restyled.Handlers.Thanks
import Restyled.Handlers.Webhooks
import Restyled.Settings
import Restyled.Tracing.Middleware
import Restyled.Yesod hiding (LogLevel(..))

mkYesodDispatch "App" resourcesApp

runWaiApp :: App -> IO ()
runWaiApp app = do
    waiApp <- waiMiddleware app <$> toWaiAppPlain app
    runSettings (warpSettings app) waiApp

waiMiddleware :: App -> Middleware
waiMiddleware app =
    transactionMiddleware app
        . traceMiddlewareSegment app "Force SSL" forceSSL
        . traceMiddlewareSegment app "Method override" methodOverridePost
        . traceMiddlewareSegment app "Logger" (requestLogger app)
        . traceMiddlewareSegment app "Default" defaultMiddlewaresNoLogging
        . routedMiddleware
              (not . isWebsocketsLogs)
              (traceMiddlewareSegment app "Timeout" $ timeout timeoutSeconds)
    where timeoutSeconds = app ^. settingsL . to appRequestTimeout

isWebsocketsLogs :: [Text] -> Bool
isWebsocketsLogs = maybe False ((== "log") . NE.last) . NE.nonEmpty

warpSettings :: App -> Settings
warpSettings app =
    setHost host . setPort port . setOnException onEx $ defaultSettings
  where
    port = appPort $ app ^. settingsL
    host = appHost $ app ^. settingsL
    onEx _req ex =
        when (defaultShouldDisplayException ex)
            $ runLoggerLoggingT app
            $ logError
            $ "Warp exception"
            :# ["exception" .= displayException ex]
