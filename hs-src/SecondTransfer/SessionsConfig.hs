{-# LANGUAGE FlexibleContexts, Rank2Types, TemplateHaskell, OverloadedStrings #-}
module SecondTransfer.SessionsConfig(
    sessionId
    ,defaultSessionsConfig
    ,makeSessionsContext
    ,sessionsConfig 
    ,sessionsCallbacks
    ,reportErrorCallback
    ,nextSessionId

    ,SessionComponent(..)
    ,SessionsContext(..)
    ,SessionCoordinates(..)
    ,SessionsCallbacks(..)
    ,SessionsConfig(..)
    ,ErrorCallback
    ) where 


import Control.Exception(SomeException)
import Control.Lens(makeLenses, Lens')
import Control.Concurrent.MVar(MVar, newMVar)


-- | Information used to identify a particular session. 
newtype SessionCoordinates = SessionCoordinates  Int
    deriving Show

instance Eq SessionCoordinates where 
    (SessionCoordinates a) == (SessionCoordinates b) =  a == b

-- | Get/set a numeric Id from a `SessionCoordinates`. For example, to 
--   get the session id with this, import `Control.Lens.(^.)` and then do 
--
-- @
--      session_id = session_coordinates ^. sessionId
-- @
-- 
sessionId :: Functor f => (Int -> f Int) -> SessionCoordinates -> f SessionCoordinates
sessionId f (SessionCoordinates session_id) = 
    fmap (\ s' -> (SessionCoordinates s')) (f session_id)



-- | Components at an individual session. Used to report
--   where in the session an error was produced. This interface is likely 
--   to change in the future, as we add more metadata to exceptions
data SessionComponent = 
    SessionInputThread_HTTP2SessionComponent 
    |SessionHeadersOutputThread_HTTP2SessionComponent
    |SessionDataOutputThread_HTTP2SessionComponent
    |Framer_HTTP2SessionComponent
    deriving Show


-- | Used by this session engine to report an error at some component, in a particular
--   session. 
type ErrorCallback = (SessionComponent, SessionCoordinates, SomeException) -> IO ()

-- | Callbacks that you can provide your sessions to notify you 
--   of interesting things happening in the server. 
data SessionsCallbacks = SessionsCallbacks {
    -- Callback used to report errors during this session
    _reportErrorCallback :: Maybe ErrorCallback
}

makeLenses ''SessionsCallbacks


-- | Configuration information you can provide to the session maker.
data SessionsConfig = SessionsConfig {
    -- | Session callbacks
    _sessionsCallbacks :: SessionsCallbacks
}

-- makeLenses ''SessionsConfig

-- | Lens to access sessionsCallbacks in the `SessionsConfig` object.
sessionsCallbacks :: Lens' SessionsConfig SessionsCallbacks
sessionsCallbacks  f (
    SessionsConfig {
        _sessionsCallbacks= s 
    }) = fmap (\ s' -> SessionsConfig {_sessionsCallbacks = s'}) (f s)


-- | Contains information that applies to all 
--   sessions created in the program. Use the lenses 
--   interface to access members of this struct. 
-- 
data SessionsContext = SessionsContext {
     _sessionsConfig  :: SessionsConfig
    ,_nextSessionId   :: MVar Int
    }


makeLenses ''SessionsContext


-- | Creates a default sessions context. Modify as needed using 
--   the lenses interfaces
defaultSessionsConfig :: SessionsConfig
defaultSessionsConfig = SessionsConfig {
    _sessionsCallbacks = SessionsCallbacks {
            _reportErrorCallback = Nothing
        }
    }


-- Adds runtime data to a context, and let it work.... 
makeSessionsContext :: SessionsConfig -> IO SessionsContext
makeSessionsContext sessions_config = do 
    next_session_id_mvar <- newMVar 1 
    return $ SessionsContext {
        _sessionsConfig = sessions_config,
        _nextSessionId = next_session_id_mvar
        }