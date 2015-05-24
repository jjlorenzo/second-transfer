{-# LANGUAGE DeriveDataTypeable, ExistentialQuantification #-}
{-|
Module      : SecondTransfer.Exception
-}
module SecondTransfer.Exception (
    -- * Exceptions thrown by the HTTP/2 sessions
    HTTP2SessionException (..)
    ,FramerException (..)
    ,BadPrefaceException (..)
    ,HTTP11Exception (..)
    ,HTTP11SyntaxException (..)
    ,ContentLengthMissingException (..)

    -- * Exceptions related to the IO layer
    ,IOProblem(..)
    ,GenericIOProblem(..)
    ,StreamCancelledException(..)

    -- * Internal exceptions
    ,HTTP2ProtocolException(..)
    ) where 

import           Control.Exception
import           Data.Typeable



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
--   raised when handling HTTP/2 sessions also
data HTTP11Exception = forall e . Exception e => HTTP11Exception e
    deriving Typeable

instance Show HTTP11Exception where
    show (HTTP11Exception e) = show e

instance  Exception HTTP11Exception 

convertHTTP11ExceptionToException :: Exception e => e -> SomeException
convertHTTP11ExceptionToException = toException . HTTP11Exception

getHTTP11ExceptionFromException :: Exception e => SomeException -> Maybe e
getHTTP11ExceptionFromException x = do
    HTTP2SessionException a <- fromException x
    cast a

-- | Thrown with HTTP/1.1 over HTTP/1.1 sessions when the response body
--   or the request body doesn't include a Content-Length header field,
--   even if it should have included it 
data ContentLengthMissingException = ContentLengthMissingException 
    deriving (Typeable, Show)

instance Exception ContentLengthMissingException where 
    toException = convertHTTP11ExceptionToException
    fromException = getHTTP11ExceptionFromException


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


-- | This exception will be raised inside a `CoherentWorker` when the underlying 
-- stream is cancelled (STREAM_RESET in HTTP\/2). Do any necessary cleanup
-- in a handler, or simply use the fact that the exception is asynchronously
-- delivered 
-- to your CoherentWorker Haskell thread, giving you an opportunity to 
-- interrupt any blocked operations.
data StreamCancelledException = StreamCancelledException
    deriving (Show, Typeable)

instance Exception StreamCancelledException