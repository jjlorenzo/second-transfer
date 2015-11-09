{-# LANGUAGE OverloadedStrings, TemplateHaskell, FunctionalDependencies #-}
module SecondTransfer.Http1.Proxy (
                 ioProxyToConnection

               , IOCallbacksConn                                          (..)
        ) where

import           Control.Lens
import qualified Control.Exception                                         as E
import           Control.Monad                                             (when)
import           Control.Monad.IO.Class                                    (liftIO)

import qualified Data.ByteString                                           as B
import           Data.List                                                 (foldl')
import qualified Data.ByteString.Builder                                   as Bu
import           Data.ByteString.Char8                                     (pack, unpack)
import qualified Data.ByteString.Char8                                     as Ch8
import qualified Data.ByteString.Lazy                                      as LB
import           Data.Char                                                 (toLower)
import           Data.Maybe                                                (isJust, fromMaybe)

import           Data.Conduit

--import           SecondTransfer.MainLoop.CoherentWorker                    (Headers)

import qualified SecondTransfer.Utils.HTTPHeaders                          as He
import           SecondTransfer.Http1.Types
import           SecondTransfer.Http1.Parse                                (
                                                                              headerListToHTTP1RequestText
                                                                            , methodHasRequestBody
                                                                            , newIncrementalHttp1Parser
                                                                            , IncrementalHttp1Parser
                                                                            , Http1ParserCompletion(..)
                                                                            , addBytes
                                                                            , BodyStopCondition(..)
                                                                            )
import           SecondTransfer.IOCallbacks.Types
import           SecondTransfer.IOCallbacks.Coupling                       (sendSourceToIO)
import           SecondTransfer.Exception                                  (
                                                                              HTTP11SyntaxException(..)
                                                                            , NoMoreDataException
                                                                            , IOProblem (..)
                                                                            , GatewayAbortedException (..)
                                                                            , keyedReportExceptions
                                                                            , ignoreException
                                                                            , ioProblem
                                                                           )

#include "instruments.cpphs"

newtype IOCallbacksConn = IOCallbacksConn IOCallbacks


instance Http1CycleController IO IOCallbacksConn where
    releaseResponseResources (IOCallbacksConn conn) = (conn ^. closeAction_IOC)


-- | Takes an IOCallbacksConn (not straight IOCallbacks since we plan on adding controllabiility)
--   features on top of this type), and serializes a request (encoded HTTP/2 style in headers and streams)
--   on top of the callback, waits for the results, and returns the response. Notice that this proxy
--   may fail for any reason, do take measures and handle exceptions. Also, must headers manipulations
--   (e.g. removing the "Connection" header) are left to the upper layers
ioProxyToConnection :: IOCallbacksConn -> HttpRequest IO -> IO (HttpResponse IO, IOCallbacksConn)
ioProxyToConnection c@(IOCallbacksConn ioc) request =
  do
    let
       h1 = request ^. headers_Rq
       he1 = He.fromList h1
       he2 = He.combineAuthorityAndHost he1
       h3 = He.toList he2
       headers_bu = headerListToHTTP1RequestText h3
       separator = "\r\n"

       -- Contents of the head, including the separator, which should always
       -- be there.
       cnt1 = headers_bu `mappend` separator
       cnt1_lbz = Bu.toLazyByteString cnt1

       method = fromMaybe "GET" $ He.fetchHeader h3 ":method"

    -- Send the headers and the separator

    -- This code can throw an exception, in that case, just let it
    -- bubble. But the upper layer should deal with it.
    --LB.putStr cnt1_lbz
    --LB.putStr "\n"
    (ioc ^. pushAction_IOC) cnt1_lbz

    -- Send the rest only if the method has something ....
    if methodHasRequestBody method
      then
        -- We also need to send the body
        sendSourceToIO  (mapOutput LB.fromStrict $ request ^. body_Rq)  ioc
      else
        return ()

    -- So, say that we are here, that means we haven't exploded
    -- in the process of sending this request. now let's Try to
    -- fetch the answer...
    let
        incremental_http_parser = newIncrementalHttp1Parser

        pump0 :: IncrementalHttp1Parser -> IO Http1ParserCompletion
        pump0 p =
         do
            some_bytes <- (ioc ^. bestEffortPullAction_IOC) True
            let completion = addBytes p some_bytes
            case completion of
               MustContinue_H1PC new_parser -> pump0 new_parser

               -- In any other case, just return
               a -> return a

        pumpout fragment n = do
            when (B.length fragment > 0) $  yield fragment
            when (n > 0 ) $ pull n

       -- ATTENTION: This is letting data to accumulate in this side,
       -- buffering it!! TODO: Fix that to decrease server memory
       -- usage!
       -- (but should be ok for relatively small responses)
        pull :: Int -> Source IO B.ByteString
        pull n = do
            either_ioproblem_or_s <- liftIO $ keyedReportExceptions "pll-" $ E.try  $ (ioc ^. pullAction_IOC ) n
            s <- case either_ioproblem_or_s :: Either IOProblem B.ByteString of
                Left exc -> liftIO $ E.throwIO GatewayAbortedException
                Right datum -> return datum
            -- After getting all that sweet data close the connection
            -- TODO: KEEP alive connections won't appreciate this!!
            liftIO $ ignoreException ioProblem () (ioc ^. closeAction_IOC)
            yield s

        pump_until_exception fragment = do
            if B.length fragment > 0
              then do
                yield fragment
                pump_until_exception mempty
              else do
                s <- liftIO $ keyedReportExceptions "ue-" $ E.try $ (ioc ^. bestEffortPullAction_IOC) True
                case (s :: Either NoMoreDataException B.ByteString) of
                    Left _ -> do
                        -- Just ensure a close
                        liftIO $ ignoreException ioProblem () (ioc ^. closeAction_IOC)
                        return ()

                    Right datum -> do
                        yield datum
                        pump_until_exception mempty

    parser_completion <- pump0 incremental_http_parser

    case parser_completion of

        OnlyHeaders_H1PC headers leftovers -> do
            when (B.length leftovers > 0) $ do
                REPORT_EVENT("suspicious-leftovers")
                return ()
            return (HttpResponse {
                _headers_Rp = headers
              , _body_Rp = return ()
                }, c)

        HeadersAndBody_H1PC headers (UseBodyLength_BSC n) leftovers -> do
            return (HttpResponse {
                _headers_Rp = headers
              , _body_Rp = pumpout leftovers (n - (fromIntegral $ B.length leftovers ) )
                }, c)

        HeadersAndBody_H1PC headers ConnectionClosedByPeer_BSC leftovers -> do
            return (HttpResponse {
                _headers_Rp = headers
              , _body_Rp = pump_until_exception leftovers
                }, c)

        -- TODO: See what happens when this exception passes from place to place.
        RequestIsMalformed_H1PC msg -> do
            E.throwIO $ HTTP11SyntaxException msg
