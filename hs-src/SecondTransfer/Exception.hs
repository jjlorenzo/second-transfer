{-# LANGUAGE
    DeriveDataTypeable, FlexibleContexts, GADTs,
    ExistentialQuantification, ScopedTypeVariables #-}
{-|
Module      : SecondTransfer.Exception
-}
module SecondTransfer.Exception (
    -- * Exceptions thrown by the HTTP/2 sessions
      HTTP2SessionException                       (..)
    , FramerException                             (..)
    , BadPrefaceException                         (..)
    , HTTP11Exception                             (..)
    , HTTP11SyntaxException                       (..)
    , ClientSessionAbortedException               (..)
    , HTTP500PrecursorException                   (..)
    , GatewayAbortedException                     (..)
    , ConnectionCloseReason                       (..)
    , convertHTTP500PrecursorExceptionToException
    , getHTTP500PrecursorExceptionFromException
    , ContentLengthMissingException               (..)
    , ForwardedGatewayException                   (..)

      -- * Exceptions related to the IO layer
    , IOProblem                                   (..)
    , GenericIOProblem                            (..)
    , StreamCancelledException                    (..)
    , NoMoreDataException                         (..)
    , TLSEncodingIssue                            (..)
    , BadAddressException                         (..)
    , DerivedDataException                        (..)

      -- * Exceptions related to SOCKS5
    , SOCKS5ProtocolException                     (..)

      -- * Internal exceptions
    , HTTP2ProtocolException                      (..)

    , TLSLibraryIssue                             (..)

      -- * Utility functions
    , ignoreException
    , reportExceptions
    , keyedReportExceptions
    , forkIOExc
    , traceIOExc
    , mKeyedReportExceptions
    , resourceForkIOExc

      -- * Proxies
    , blockedIndefinitelyOnMVar
    , blockedIndefinitelyOnSTM
    , noMoreDataException
    , ioProblem
    , gatewayAbortedException
    , ioException
    , badAddressException
    , threadKilled   -- NOTE: Will capture other excepitons :-(
    ) where

import           Control.Exception
import           Data.Typeable
import           Control.Concurrent               (forkIO, ThreadId)
import qualified Control.Monad.Trans.Resource     as ReT
import qualified Control.Monad.Catch              as CMC
import           Control.Monad.IO.Class                                    (liftIO, MonadIO)

import           GHC.Stack

-- | Abstract exception. All HTTP/2 exceptions derive from here
data HTTP2SessionException = forall e . Exception e => HTTP2SessionException e
    deriving Typeable

instance Show HTTP2SessionException where
    show (HTTP2SessionException e) = show e

instance Exception HTTP2SessionException


convertHTTP2SessionExceptionToException :: Exception e => e -> SomeException
convertHTTP2SessionExceptionToException = toException . HTTP2SessionException


getHTTP2SessionExceptionFromException :: Exception e => SomeException -> Maybe e
getHTTP2SessionExceptionFromException x = do
    HTTP2SessionException a <- fromException x
    cast a


-- | Concrete exception. Used internally to signal that the client violated
--   the protocol. Clients of the library shall never see this exception.
data HTTP2ProtocolException = HTTP2ProtocolException
    deriving (Typeable, Show)

instance Exception HTTP2ProtocolException where
    toException   = convertHTTP2SessionExceptionToException
    fromException = getHTTP2SessionExceptionFromException

-- TODO below: add the other protocol reasons

-- | Reasons for a remote server interrupting a connectionn of this client
data ConnectionCloseReason =
    NormalTermination_CCR     -- ^ Corresponds to NO_ERROR
    |SessionAlreadyClosed_CCR -- ^ A request was done after the session was previously closed.
    |IOChannelClosed_CCR      -- ^ This one happens when one of the IO channels is closed and a BlockedIndefinitelyOnMVar bubbles up. It should only happen in the test suite, as the OpenSSL_TLS channel uses a specialized exception type. If you see it in the wild, it is a bug.
    |ProtocolError_CCR        -- ^ Any other reason
    deriving Show


-- | Concrete Exception. Used internally to signal that the server broke
--   the connection. This is a public exception that clients of the library
--   will see when acting as an HTTP client.
data ClientSessionAbortedException = ClientSessionAbortedException ConnectionCloseReason
    deriving (Typeable, Show)


instance Exception ClientSessionAbortedException where
    toException = convertHTTP2SessionExceptionToException
    fromException = getHTTP2SessionExceptionFromException

-- | Abstract exception. Thrown when encoding/decoding of a frame fails
data FramerException = forall e . Exception e => FramerException e
    deriving Typeable


instance Show FramerException where
    show (FramerException e) = show e


instance Exception FramerException where
    toException = convertHTTP2SessionExceptionToException
    fromException = getHTTP2SessionExceptionFromException


convertFramerExceptionToException :: Exception e => e -> SomeException
convertFramerExceptionToException = toException . FramerException

getFramerExceptionFromException :: Exception e => SomeException -> Maybe e
getFramerExceptionFromException x = do
    FramerException a <- fromException x
    cast a


-- | Thrown when the HTTP/2 connection prefix doesn't
--   match the expected prefix.
data BadPrefaceException = BadPrefaceException
    deriving (Typeable, Show)


instance Exception BadPrefaceException where
    toException   = convertFramerExceptionToException
    fromException = getFramerExceptionFromException


-- | Abstract exception. All HTTP/1.1 related exceptions derive from here.
--   Notice that this includes a lot of logical errors and they can be
--   raised when handling HTTP/2 sessions as well
data HTTP11Exception = forall e . Exception e => HTTP11Exception e
    deriving Typeable


instance Show HTTP11Exception where
    show (HTTP11Exception e) = show e


instance Exception HTTP11Exception


convertHTTP11ExceptionToException :: Exception e => e -> SomeException
convertHTTP11ExceptionToException = toException . HTTP11Exception


getHTTP11ExceptionFromException :: Exception e => SomeException -> Maybe e
getHTTP11ExceptionFromException x = do
    HTTP11Exception a <- fromException x
    cast a


-- | Abstract exception. It is an error if an exception of this type bubbles
--   to this library, but we will do our best to handle it gracefully in the
--   Session engines.
--   All internal error precursors at the workers can thus inherit from here
--   to have a fallback option in case they forget to handle the error. It should
--   also be used for the case of streaming requests that are interrupted by the
--   upstream server.
--   This exception inherits from HTTP11Exception
data HTTP500PrecursorException = forall e . Exception e => HTTP500PrecursorException e
    deriving Typeable

instance Show HTTP500PrecursorException where
    show (HTTP500PrecursorException e) = show e


-- | Use the traditional idiom if you need to derive from 'HTTP500PrecursorException',
--   this is one of the helpers
convertHTTP500PrecursorExceptionToException :: Exception e => e -> SomeException
convertHTTP500PrecursorExceptionToException = toException . HTTP500PrecursorException


-- | Use the traditional idiom if you need to derive from 'HTTP500PrecursorException',
--   this is one of the helpers
getHTTP500PrecursorExceptionFromException :: Exception e => SomeException -> Maybe e
getHTTP500PrecursorExceptionFromException x = do
    HTTP500PrecursorException a <- fromException x
    cast a


-- Here we say how we go with these exceptions....
instance Exception HTTP500PrecursorException where
    toException = convertHTTP11ExceptionToException
    fromException = getHTTP11ExceptionFromException


-- | Used by the ReverseProxy to signal an error from the upstream/Gateway
data GatewayAbortedException = GatewayAbortedException
    deriving (Typeable, Show)


instance Exception GatewayAbortedException where
    toException = convertHTTP500PrecursorExceptionToException
    fromException = getHTTP500PrecursorExceptionFromException


gatewayAbortedException :: Proxy GatewayAbortedException
gatewayAbortedException = Proxy


-- | Thrown with HTTP/1.1 over HTTP/1.1 sessions when the response body
--   or the request body doesn't include a Content-Length header field,
--   given that should have included it
data ContentLengthMissingException = ContentLengthMissingException
    deriving (Typeable, Show)


instance Exception ContentLengthMissingException where
    toException = convertHTTP11ExceptionToException
    fromException = getHTTP11ExceptionFromException


-- Concrete exception
data HTTP11SyntaxException = HTTP11SyntaxException String
    deriving (Typeable, Show)


instance Exception HTTP11SyntaxException where
    toException = convertHTTP11ExceptionToException
    fromException = getHTTP11ExceptionFromException


-- | Throw exceptions derived from this (e.g, `GenericIOProblem` below)
--   to have the HTTP/2 session to terminate gracefully.
data IOProblem = forall e . Exception e => IOProblem e
    deriving Typeable


instance  Show IOProblem where
    show (IOProblem e) = show e


instance Exception IOProblem


ioProblem :: Proxy IOProblem
ioProblem = Proxy


-- | This is a little bit too general, let's hope for the best
threadKilled :: Proxy AsyncException
threadKilled = Proxy


-- | A concrete case of the above exception. Throw one of this
--   if you don't want to implement your own type. Use
--   `IOProblem` in catch signatures.
data GenericIOProblem = GenericIOProblem
    deriving (Show, Typeable)


instance Exception GenericIOProblem where
    toException = toException . IOProblem
    fromException x = do
        IOProblem a <- fromException x
        cast a


-- | Used for TLS layer issues; this exception is somewhat generic
--   in case we need to accomodate a different TLS library in the future.
data TLSLibraryIssue =
    TLSLibraryIssue String
    deriving (Show, Typeable)


instance Exception TLSLibraryIssue where
    toException = toException . IOProblem
    fromException x = do
        IOProblem a <- fromException x
        cast a


-- | This is raised by the IOCallbacks when the endpoint
--   is not willing to return or to accept more data
data NoMoreDataException = NoMoreDataException
    deriving (Show, Typeable)


instance Exception NoMoreDataException where
    toException = toException . IOProblem
    fromException x = do
        IOProblem  a <- fromException x
        cast a


-- | Represents a chain of IO exceptions that still has access to
--   the original excetption
data DerivedDataException = forall e . Exception e => DerivedDataException e
    deriving (Typeable)

instance Show DerivedDataException where
    show (DerivedDataException e ) = "DerivedDataException of " ++ show e


instance Exception DerivedDataException where
    toException = toException . IOProblem
    fromException x = do
        IOProblem a <- fromException x
        cast a


data TLSEncodingIssue = TLSEncodingIssue
    deriving (Show, Typeable)

instance Exception TLSEncodingIssue where
    toException = toException . IOProblem
    fromException x = do
        IOProblem  a <- fromException x
        cast a


data BadAddressException = BadAddressException String
    deriving (Show, Typeable)

instance Exception BadAddressException where
    toException = toException . IOProblem
    fromException x = do
        IOProblem a <- fromException x
        cast a


-- | Happens when we have to forward an exception from the gateway to the
--   top-level session handler, and it is bad enough that we can't return
--   a coherent answer 500 to the client (e.g., with chunked encoding
--   syntax errors)
data ForwardedGatewayException where
    ForwardedGatewayException :: forall e . Exception e => e -> ForwardedGatewayException
  deriving Typeable

instance Show ForwardedGatewayException where
    show (ForwardedGatewayException e ) = "ForwardedGatewayException of " ++ show e

-- instance Exception DerivedDataException where
--     toException = toException . IOProblem
--     fromException x = do
--         IOProblem a <- fromException x
--         cast a


-- | By definition, any problems with the gateway can be considered an I/O
--   problem, however, we have more generic mechanisms to trap I/O issues
--   and we are interested in reporting some parsing errors in a more
--   specific way.
instance Exception ForwardedGatewayException where
    toException e = SomeException e
    fromException x = do
        SomeException  a <- fromException x
        cast a


badAddressException :: Proxy BadAddressException
badAddressException = Proxy


noMoreDataException :: Proxy NoMoreDataException
noMoreDataException = Proxy

-- | This exception will be raised inside a `CoherentWorker` when the underlying
-- stream is cancelled (STREAM_RESET in HTTP\/2). Do any necessary cleanup
-- in a handler, or simply use the fact that the exception is asynchronously
-- delivered
-- to your CoherentWorker Haskell thread, giving you an opportunity to
-- interrupt any blocked operations.
data StreamCancelledException = StreamCancelledException
    deriving (Show, Typeable)

instance Exception StreamCancelledException


-- | Exception to denote that something failed with the SOCKS5 protocol
data SOCKS5ProtocolException = SOCKS5ProtocolException String
    deriving (Show, Typeable)


instance Exception SOCKS5ProtocolException


-- | Simple utility function that ignores an exception. Good to work
--   on threads when we know stuff. It takes as a first parameter a
--   proxy.
ignoreException :: Exception e => Proxy e -> a -> IO a -> IO a
ignoreException prx default_value comp =
  let
    predicate :: Proxy e ->  e -> Maybe ()
    predicate _prx _ = Just ()
    in catchJust (predicate prx ) comp (const $ return default_value)


-- | Simple utility function that reports exceptions
reportExceptions :: forall a . IO a -> IO a
reportExceptions comp =
  do
    ei <- try comp
    case (ei :: Either SomeException a) of
        Left e@(SomeException ee) -> do
            putStrLn $ "Bubbling exc " ++ displayException e ++ " (with type " ++ (show $ typeOf ee) ++ ")"
            throwIO e

        Right a -> do
            return a


keyedReportExceptions :: forall a . String -> IO a -> IO a
keyedReportExceptions key comp =
  do
    ei <- try comp
    case (ei :: Either SomeException a) of
        Left e@(SomeException ee) -> do
            current_call_stack <- currentCallStack
            putStrLn $ "Bubbling exc "
                ++ displayException e
                ++ " (with type "
                ++ (show $ typeOf ee)
                ++ ") at "
                ++ key
                ++ " (call stack?) "
                ++ show current_call_stack

            throwIO e

        Right a -> do
            return a


mKeyedReportExceptions ::
  forall m a .
  (
    CMC.MonadCatch m,
    MonadIO m
  ) =>
  String ->
  m a -> m a
mKeyedReportExceptions key comp =
  do
    ei <- CMC.try comp
    case (ei :: Either SomeException a) of
        Left e@(SomeException ee) -> do
            liftIO . putStrLn $
                "Bubbling exc " ++
                displayException e ++
                " (with type " ++
                (show $ typeOf ee) ++
                ") at " ++
                key
            CMC.throwM e

        Right a -> do
            return a


-- | Just report all unhandled and un-ignored exceptions
---  in forked threads
forkIOExc :: String -> IO () -> IO ThreadId
forkIOExc msg comp = forkIO $ keyedReportExceptions msg  comp


-- | Used to trace bubbling exceptions through an IO interface, without
--   stopping those exceptions
traceIOExc ::forall m a .
  (
    CMC.MonadCatch m,
    MonadIO m,
    HasCallStack
  )  => m a -> m a
traceIOExc op = do
    let
        key = prettyCallStack callStack
    mKeyedReportExceptions key op


-- resourceForkIO :: MonadBaseControl IO m => ResourceT m () -> ResourceT m ThreadId
resourceForkIOExc  ::
    (
      ReT.MonadBaseControl IO m,
      MonadIO m,
      CMC.MonadCatch m
    ) =>
    String  ->
    ReT.ResourceT m () ->
       ReT.ResourceT m ThreadId
resourceForkIOExc msg comp =
    ReT.resourceForkIO $ mKeyedReportExceptions msg comp

blockedIndefinitelyOnMVar :: Proxy BlockedIndefinitelyOnMVar
blockedIndefinitelyOnMVar = Proxy

blockedIndefinitelyOnSTM :: Proxy BlockedIndefinitelyOnSTM
blockedIndefinitelyOnSTM = Proxy

ioException :: Proxy IOException
ioException = Proxy
