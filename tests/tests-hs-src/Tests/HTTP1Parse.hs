{-# LANGUAGE OverloadedStrings #-}
module Tests.HTTP1Parse where

import           Control.Lens
import           Control.Concurrent                  hiding (yield)

--import qualified Data.ByteString                     as B
import qualified Data.ByteString.Lazy                as LB
import qualified Data.ByteString.Builder             as Bu
--import           Data.Maybe                          (isJust)
import           Data.Conduit
import qualified Data.Conduit.List                   as DCL

import           Test.HUnit

import           SecondTransfer.IOCallbacks.Types
import           SecondTransfer.IOCallbacks.Coupling

import           SecondTransfer                      (Headers)
import           SecondTransfer.Http1.Parse
import           SecondTransfer.Http1.Types
import           SecondTransfer.Http1.Proxy
import qualified SecondTransfer.Utils.HTTPHeaders    as He


testParse :: Test
testParse = TestCase $ do
    let
        headers_text                       = "GET /helo.html HTTP/1.1\r\nHost: www.auther.com \r\n\r\n"
        headers_text2                      = "POST /helo.html HTTP/1.1\r\nHost: www.auther.com \r\nContent-Length: 1\r\n\r\np"
        a0                                 = newIncrementalHttp1Parser
        isDone (OnlyHeaders_H1PC _ _)      = True
        isDone _                           = False
        a1                                 = addBytes a0 headers_text
        (OnlyHeaders_H1PC h0 leftovers)    = a1
        (HeadersAndBody_H1PC h1 cond0 l2)  = addBytes a0 headers_text2
        --waitForBodyOk (HeadersAndBody_H1PC _ _ _)   = True
        --waitForBodyOk _ = False
    assertBool "testParse.IsDone" (isDone a1)
    assertEqual "testParse.NoLeftovers" leftovers ""
    assertEqual "testParse.YesLeftovers" l2 "p"
    assertEqual "testParse.FinishWellSeen" (UseBodyLength_BSC 1) cond0


testGenerate :: Test
testGenerate = TestCase $ do
    let
        headers_list :: Headers
        headers_list = [
            (":status", "200"),
            ("host", "www.example.com"),
            ("etag", "afrh")
            ]
        fragments = ["hello world"]
        serialized = serializeHTTPResponse headers_list fragments
    assertEqual "testGenerate.1"
        "HTTP/1.1 200 OK\r\ncontent-length: 11\r\nhost: www.example.com\r\netag: afrh\r\n\r\nhello world"
        serialized


testCombineAuthorityAndHost :: Test
testCombineAuthorityAndHost = TestCase $ do
    let
        headers_list :: Headers
        headers_list = [
            (":status", "200"),
            ("host", "www.example.com"),
            (":authority", "www.exampl.com"),
            ("etag", "afrh")
            ]
        he1 = He.fromList headers_list
        he2 = He.combineAuthorityAndHost he1
        h2 = He.toList he2
        fragments = ["hello world"]
        serialized = serializeHTTPResponse h2 fragments
    assertEqual "testGenerate.1"
        "HTTP/1.1 200 OK\r\n:authority: www.exampl.com\r\n:status: 200\r\ncontent-length: 11\r\netag: afrh\r\n\r\nhello world"
        serialized


testCombineAuthorityAndHost2 :: Test
testCombineAuthorityAndHost2 = TestCase $ do
    let
        headers_list :: Headers
        headers_list = [
            (":status", "200"),
            ("host", "www.example.com"),
            ("etag", "afrh")
            ]
        he1 = He.fromList headers_list
        he2 = He.combineAuthorityAndHost he1
        h2 = He.toList he2
        fragments = ["hello world"]
        serialized = serializeHTTPResponse h2 fragments
    assertEqual "testGenerate.1"
        "HTTP/1.1 200 OK\r\ncontent-length: 11\r\nhost: www.example.com\r\netag: afrh\r\n\r\nhello world"
        serialized


testHeadersToRequest :: Test
testHeadersToRequest = TestCase $ do
    let
        headers_list :: Headers
        headers_list = [
            (":status", "200"),
            ("host", "www.example.com"),
            ("etag", "afrh")
            ]
        serialized = LB.toStrict . Bu.toLazyByteString $ headerListToHTTP1RequestText headers_list
    assertEqual "testGenerate.1"
        "GET * HTTP/1.1\r\nhost:www.example.com\r\netag:afrh\r\n"
        serialized


testHeadersToRequest2 :: Test
testHeadersToRequest2 = TestCase $ do
    let
        headers_list :: Headers
        headers_list = [
            (":status", "200"),
            (":authority", "www.example.com"),
            (":path", "/important"),
            (":method", "HEAD"),
            ("etag", "afrh")
            ]
        serialized = LB.toStrict . Bu.toLazyByteString $ headerListToHTTP1RequestText headers_list
    assertEqual "testGenerate.1"
        "HEAD /important HTTP/1.1\r\nhost:www.example.com\r\netag:afrh\r\n"
        serialized


testCycle :: Test
testCycle = TestCase $ do
    let
        headers_list :: Headers
        headers_list = [
            (":authority", "www.example.com"),
            (":path", "/interesting"),
            (":method", "POST"),
            ("etag", "afrh")
            ]
        rqsource = yield "Hello world"
        request = HttpRequest {
            _headers_Rq = headers_list
          , _body_Rq = rqsource
            }
    (ioap, iobp) <- popIOCallbacksIntoExistance
    ioa <- handshake ioap
    iob <- handshake iobp

    let
        controller =  ioa

    finished <- newEmptyMVar
    _ <- forkIO $ do
        request_text <- (iob ^. pullAction_IOC) 74
        --putStrLn . show $ request_text
        assertEqual "test.Request" "POST /interesting HTTP/1.1\r\nhost:www.example.com\r\netag:afrh\r\n\r\nHello world" request_text
        (iob ^. pushAction_IOC)  "HTTP/1.1 200 OK\r\ncontent-length: 11\r\nhost: www.example.com\r\netag: afrh\r\n\r\nhello world"
        putMVar finished ()

    (response, _) <- ioProxyToConnection controller request
    assertEqual "test.Response" (response ^. headers_Rp ) [(":status","200"),("content-length","11"),("host","www.example.com"),("etag","afrh")]
    contents <- (response ^. body_Rp) $$ DCL.consume
    assertEqual "test.rp1Txt" "hello world" (mconcat contents)
