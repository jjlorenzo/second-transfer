{-# LANGUAGE TemplateHaskell, OverloadedStrings, GeneralizedNewtypeDeriving  #-}
module SecondTransfer.Socks5.Session (
                 tlsSOCKS5Serve'
               , ConnectOrForward                                  (..)
               , Socks5ServerState
               , initSocks5ServerState
               , targetAddress_S5
               , socket_S5
     ) where


import           Control.Concurrent
import qualified Control.Exception                                  as E
import           Control.Lens                                       ( makeLenses, (^.), set)

import qualified Data.ByteString                                    as B
import qualified Data.ByteString.Lazy                               as LB
import           Data.ByteString.Char8                              ( unpack,  pack)
import qualified Data.Attoparsec.ByteString                         as P
import qualified Data.Binary                                        as U
import qualified Data.Binary.Put                                    as U
import           Data.Word                                          (Word16)
import           Data.Int                                           (Int64)

import qualified Network.Socket                                     as NS

import           SecondTransfer.Exception                           (
                                                                     SOCKS5ProtocolException (..),
                                                                     NoMoreDataException,
                                                                     forkIOExc )

import           SecondTransfer.Socks5.Types
import           SecondTransfer.Socks5.Parsers
import           SecondTransfer.Socks5.Serializers

import           SecondTransfer.IOCallbacks.Types
import           SecondTransfer.IOCallbacks.SocketServer
import           SecondTransfer.IOCallbacks.Coupling                (couple)
import           SecondTransfer.IOCallbacks.WrapSocket              (
                                                                     HasSocketPeer(..),
                                                                     AcceptErrorCondition
                                                                     )

-- For debugging purposes
--import           SecondTransfer.IOCallbacks.Botcher


data Socks5ServerState = Socks5ServerState {
    _nextConnection_S5S       :: !Int64
    }
makeLenses ''Socks5ServerState

initSocks5ServerState :: Socks5ServerState
initSocks5ServerState = Socks5ServerState 0

data ConnectOrForward =
    Connect_COF B.ByteString IOCallbacks IndicatedAddress
  | Forward_COF B.ByteString Word16
  | Drop_COF B.ByteString


tryRead :: IOCallbacks ->  String  ->  B.ByteString  -> P.Parser a -> IO (a,B.ByteString)
tryRead iocallbacks what_doing leftovers p = do
    let
        react (P.Done i r) = return  (r, i)
        react (P.Fail i contexts msg) =
            E.throwIO $ SOCKS5ProtocolException
                 ("/" ++
                  what_doing ++
                  "/" ++
                  "parseFailed: Left #" ++
                 show (B.length i) ++
                 " bytes to parse ( " ++
                 show (B.unpack i) ++
                 ") " ++ " contexts: " ++
                 (show contexts) ++
                 " message: " ++
                 msg
                )
        react (P.Partial f)  =
            go f

        go  f = do
            fragment <- (iocallbacks ^. bestEffortPullAction_IOC) True
            --
            react (f $ LB.toStrict fragment)

    react $ P.parse p leftovers


pushDatum :: IOCallbacks -> (a -> U.Put) -> a -> IO ()
pushDatum iocallbacks putthing x = do
    let
        datum = U.runPut (putthing x)
    (iocallbacks ^. pushAction_IOC) datum


-- | Forwards a set of IOCallbacks (actually, it is exactly the same passed in) after the
--   SOCKS5 negotiation, if the negotiation succeeds and the indicated "host" is approved
--   by the first parameter. Quite simple.
negotiateSocksAndForward ::  (B.ByteString -> Bool) -> IOCallbacks -> IO ConnectOrForward
negotiateSocksAndForward approver socks_here =
  do
    let
        tr = tryRead socks_here
        ps = pushDatum socks_here
    -- Start by reading the standard socks5 header
    ei <- E.try $ do
        (_auth, next1) <- tr "client-auth-methods"  ""  parseClientAuthMethods_Packet
        -- I will ignore the auth methods for now
        let
            server_selects = ServerSelectsMethod_Packet ProtocolVersion 0 -- No auth
        ps putServerSelectsMethod_Packet server_selects
        (req_packet, _next2) <- tr "client-request"  next1 parseClientRequest_Packet
        case req_packet ^. cmd_SP3 of

            Connect_S5PC  -> do
                -- Can accept a connect, to what?
                let
                    address = req_packet ^. address_SP3
                    port = req_packet ^. port_SP3
                    named_host = case address of
                        DomainName_IA name -> name
                        _  -> E.throw . SOCKS5ProtocolException $ "UnsupportedAddress " ++ show address
                if  approver named_host && port == 443 then
                    do
                        -- First I need to answer to the client that we are happy and ready
                        let
                            server_reply = ServerReply_Packet {
                                _version_SP4    = ProtocolVersion
                              , _replyField_SP4 = Succeeded_S5RF
                              , _reservedField_SP4 = 0
                              , _address_SP4 = IPv4_IA 0x7f000001
                              , _port_SP4 = 10001
                                }
                        ps putServerReply_Packet server_reply
                        -- Now that I have the attendant, let's just activate it ...

                        -- CORRECT WAY:
                        return $ Connect_COF named_host socks_here address

                    else do
                        -- Logging? We need to get that real right.
                        return $ Drop_COF named_host


            -- Other commands not handled for now
            _             -> do
                return $ Drop_COF "<socks5-unimplemented-command>"

    case ei of
        Left (SOCKS5ProtocolException msg) -> return $ Drop_COF (pack msg)
        Right result -> return result


-- | Forwards a set of IOCallbacks (actually, it is exactly the same passed in) after the
--   SOCKS5 negotiation, if the negotiation succeeds and the indicated "host" is approved
--   by the first parameter. If the approver returns false, this function will try to
--   actually connect to the host and let the software act as a true proxy.
negotiateSocksForwardOrConnect ::  (B.ByteString -> Bool) -> IOCallbacks -> IO ConnectOrForward
negotiateSocksForwardOrConnect approver socks_here =
  do
    let
        tr = tryRead socks_here
        ps = pushDatum socks_here
    -- Start by reading the standard socks5 header
    ei <- E.try $ do
        (_auth, next1) <- tr "client-auth-methods" ""  parseClientAuthMethods_Packet
        -- I will ignore the auth methods for now
        let
            server_selects = ServerSelectsMethod_Packet ProtocolVersion 0 -- No auth
        ps putServerSelectsMethod_Packet server_selects
        (req_packet, _next2) <- tr "client-request" next1 parseClientRequest_Packet
        let
            target_port_number = req_packet ^. port_SP3
        case req_packet ^. cmd_SP3 of

            Connect_S5PC  -> do
                -- Can accept a connect, to what?
                let
                    address = req_packet ^. address_SP3

                    externalConnectProcessing  =
                      do
                        maybe_forwarding_callbacks <- connectOnBehalfOfClient address target_port_number
                        case maybe_forwarding_callbacks of
                            Just (_indicated_address, io_callbacks) -> do
                                let
                                    server_reply =  ServerReply_Packet {
                                        _version_SP4    = ProtocolVersion
                                      , _replyField_SP4 = Succeeded_S5RF
                                      , _reservedField_SP4 = 0
                                      , _address_SP4 = IPv4_IA 0x7f000001
                                         -- Wrong port, but...
                                      , _port_SP4 = 10001
                                        }
                                E.catch
                                    (do
                                        ps putServerReply_Packet server_reply
                                        -- Now couple the two streams ...
                                        _ <- couple socks_here io_callbacks
                                        return $ Forward_COF (pack . show $ address) (fromIntegral target_port_number)
                                    )
                                    (
                                      (\ _e ->
                                          return . Drop_COF . pack $
                                               "Connection truncated by forwarding target " ++ show address
                                          ) :: NoMoreDataException -> IO ConnectOrForward
                                    )

                            _ ->
                                return $ Drop_COF (pack . show $ address)


                -- /let
                case address of
                    DomainName_IA named_host
                      | target_port_number == 443 ->
                            if  approver named_host
                              then do
                                -- First I need to answer to the client that we are happy and ready
                                let
                                    server_reply = ServerReply_Packet {
                                        _version_SP4    = ProtocolVersion
                                      , _replyField_SP4 = Succeeded_S5RF
                                      , _reservedField_SP4 = 0
                                      , _address_SP4 = IPv4_IA 0x7f000001
                                      , _port_SP4 = 10001
                                        }
                                ps putServerReply_Packet server_reply
                                -- Now that I have the attendant, let's just activate it ...
                                return $ Connect_COF named_host socks_here address
                              else do
                                -- Forward to an external host
                                externalConnectProcessing
                      | otherwise ->
                            if not (approver named_host)
                              then
                                externalConnectProcessing
                              else
                                return . Drop_COF . pack$
                                    "Connections to port other than 443 are rejected by SOCKS5"

                    IPv4_IA _ -> do
                        -- TODO: Some address sanitization
                        externalConnectProcessing

                    IPv6_IA _ ->
                        error "IPv6NotHandledYet"

            -- Other commands not handled for now
            _             -> do
                --putStrLn "SOCKS5 HAS NEGLECTED TO REJECT A CONNECTION"
                return $ Drop_COF "<socks5-unimplemented>"

    case ei of
        Left (SOCKS5ProtocolException msg) -> return . Drop_COF  . pack $ msg
        Right result -> return result


connectOnBehalfOfClient :: IndicatedAddress -> Word16 -> IO (Maybe (IndicatedAddress , IOCallbacks))
connectOnBehalfOfClient address port_number =
  do
    maybe_sock_addr <- case address of
        IPv4_IA addr ->
            return . Just $  NS.SockAddrInet (fromIntegral port_number) addr

        DomainName_IA dn -> do
            -- Let's try to connect on behalf of the client...
            let
                hints = NS.defaultHints {
                    NS.addrFlags = [NS.AI_ADDRCONFIG]
                  }
            addrs <- E.catch
               ( NS.getAddrInfo (Just hints) (Just . unpack $ dn) Nothing )
               ((\_ -> return [])::E.IOException -> IO [NS.AddrInfo])
            case addrs of
                ( first : _) -> do
                    return . Just $ NS.addrAddress first
                _ ->
                    return Nothing

        -- TODO: Implement other address formats
        _ -> return Nothing

    case maybe_sock_addr of
        Just _sock_addr@(NS.SockAddrInet _ ha) -> do
            E.catches
                (do
                    client_socket <-  NS.socket NS.AF_INET NS.Stream NS.defaultProtocol
                    let
                        translated_address =  (NS.SockAddrInet (fromIntegral port_number) ha)
                    NS.connect client_socket translated_address
                    _is_connected <- NS.isConnected client_socket
                    _peer_name <- NS.getPeerName client_socket
                    socket_io_callbacks <- socketIOCallbacks client_socket
                    io_callbacks <- handshake socket_io_callbacks
                    return . Just $ (toSocks5Addr translated_address , io_callbacks)
                )
                [
                  E.Handler
                      (
                          (\_ -> do
                              return Nothing
                          )::E.IOException -> IO (Maybe (IndicatedAddress , IOCallbacks))
                      ),
                  E.Handler
                      (
                          (\_ -> do
                              return Nothing
                          )::NoMoreDataException -> IO (Maybe (IndicatedAddress , IOCallbacks))
                      )
                ]

        _ -> do
            -- Temporary message
            -- putStrLn "SOCKS5 could not be forwarded/address not resolved, or resolved to strange format"
            return Nothing


toSocks5Addr:: NS.SockAddr -> IndicatedAddress
toSocks5Addr (NS.SockAddrInet _ ha) = IPv4_IA ha
toSocks5Addr _                      = error "toSocks5Addr not fully implemented"


-- | Simple alias to SocketIOCallbacks where we expect
--   encrypted contents over a SOCKS5 Socket
data TLSServerSOCKS5Callbacks = TLSServerSOCKS5Callbacks {
    _socket_S5 :: SocketIOCallbacks,
    _targetAddress_S5 :: IndicatedAddress
    }


makeLenses ''TLSServerSOCKS5Callbacks

-- type TLSServerSOCKS5AcceptResult = Either AcceptErrorCondition TLSServerSOCKS5Callbacks

instance IOChannels TLSServerSOCKS5Callbacks where
    handshake s = handshake (s ^. socket_S5)


instance TLSEncryptedIO TLSServerSOCKS5Callbacks
instance TLSServerIO TLSServerSOCKS5Callbacks
instance HasSocketPeer TLSServerSOCKS5Callbacks where
    getSocketPeerAddress s = getSocketPeerAddress (s ^. socket_S5)



-- | tlsSOCKS5Serve approver listening_socket onsocks5_action
-- The approver should return True for host names that are served by this software (otherwise the connection will be closed, just for now,
-- in the close future we will implement a way to forward requests to external Internet hosts.)
-- Pass a bound and listening TCP socket where you expect a SOCKS5 exchange to have to tke place.
-- And pass an action that can do something with the callbacks. The passed-in action is expected to fork a thread and return
-- inmediately.
tlsSOCKS5Serve' ::
    MVar Socks5ServerState
 -> Socks5ConnectionCallbacks
 -> (B.ByteString -> Bool)
 -> Bool
 -> NS.Socket
 -> ( Either AcceptErrorCondition TLSServerSOCKS5Callbacks -> IO () )
 -> IO ()
tlsSOCKS5Serve' s5s_mvar socks5_callbacks approver forward_connections listen_socket onsocks5_action =
     tcpServe listen_socket service_is_closing socks_action
  where
     service_is_closing = case socks5_callbacks ^. serviceIsClosing_S5CC of
         Nothing -> return False
         Just clbk -> clbk

     socks_action either_condition_active_socket = do
         _ <- forkIOExc "tlsSOCKS5Serve/negotiation" $
             case either_condition_active_socket of
                 Left condition ->
                     process_condition condition

                 Right cc ->
                     process_connection cc
         return ()

     process_condition accept_condition = do
         case (socks5_callbacks ^. logEvents_S5CC) of
             Nothing -> return ()
             Just lgfn -> lgfn $ AcceptCondition_S5Ev accept_condition
         onsocks5_action $ Left accept_condition

     process_connection active_socket = do
         conn_id <- modifyMVar s5s_mvar $ \ s5s -> do
             let
                 conn_id = s5s ^. nextConnection_S5S
                 new_s5s  = set nextConnection_S5S (conn_id + 1) s5s
             return $ new_s5s `seq` (new_s5s, conn_id)
         let
             log_events_maybe = socks5_callbacks ^. logEvents_S5CC
             log_event :: Socks5ConnectEvent -> IO ()
             log_event ev = case log_events_maybe of
                 Nothing -> return ()
                 Just c -> c ev
             wconn_id = S5ConnectionId conn_id
         either_peer_address <- E.try (NS.getPeerName active_socket)
         case either_peer_address :: Either E.IOException NS.SockAddr of
             Left _e -> return ()
             Right peer_address -> do
                 log_event $ Established_S5Ev peer_address wconn_id

                 socket_io_callbacks <- socketIOCallbacks active_socket

                 io_callbacks <- handshake socket_io_callbacks
                 E.catch
                   (do
                     maybe_negotiated_io <-
                       if forward_connections
                           then negotiateSocksForwardOrConnect approver io_callbacks
                           else negotiateSocksAndForward       approver io_callbacks
                     case maybe_negotiated_io of
                         Connect_COF fate _negotiated_io address -> do
                             let
                                 tls_server_socks5_callbacks = TLSServerSOCKS5Callbacks {
                                     _socket_S5 = socket_io_callbacks,
                                     _targetAddress_S5 = address
                                     }
                             log_event $ HandlingHere_S5Ev fate wconn_id
                             onsocks5_action . Right $ tls_server_socks5_callbacks
                         Drop_COF fate -> do
                             log_event $ Dropped_S5Ev fate wconn_id
                             (io_callbacks ^. closeAction_IOC)
                             return ()
                         Forward_COF fate port -> do
                             -- TODO: More data needs to come here
                             -- Do not close
                             log_event $ ToExternal_S5Ev fate port wconn_id
                             return ()
                   )
                   (( \ _e -> do
                       log_event $ Dropped_S5Ev "Peer errored" wconn_id
                       (io_callbacks ^. closeAction_IOC)
                   ):: NoMoreDataException -> IO () )
         return ()
