{-# LANGUAGE OverloadedStrings, Rank2Types, GeneralizedNewtypeDeriving, DeriveGeneric  #-}
{-|

Utilities for working with headers.

-}
module SecondTransfer.Utils.HTTPHeaders (
    -- * Simple manipulation
    --
    -- | These transformations are simple enough that don't require
    --   going away from the list representation (see type `Headers`)
    lowercaseHeaders
    ,headersAreLowercase
    ,headersAreLowercaseAtHeaderEditor
    ,fetchHeader
    -- * Transformations based on maps
    --
    -- | Many operations benefit
    --   from transforming the list to a map with custom sorting and
    --   doing a set of operations on that representation.
    --
    ,HeaderEditor
    ,Headers
    -- ** Introducing and removing the `HeaderEditor`
    ,fromList
    ,toList
    -- ** Access to a particular header
    ,headerLens
    ,replaceHeaderValue
    -- ** HTTP utilities
    ,replaceHostByAuthority
    ,introduceDateHeader
    ,headerIsPseudo
    ) where

import qualified Control.Lens                           as L
import           Control.Lens                           ( (^.) )
import           GHC.Generics                           (Generic)

import qualified Data.ByteString                        as B
import           Data.ByteString.Char8                  (pack)
import           Data.Char                              (isUpper)
import           Data.List                              (find)
import           Data.Text                              (toLower)
import qualified Data.Text                              as T
import           Data.Text.Encoding                     (decodeUtf8, encodeUtf8)
import qualified Data.Map.Strict                        as Ms
import           Data.Word                              (Word8)


import           Data.Time.Format                       (formatTime, defaultTimeLocale)
import           Data.Time.Clock                        (getCurrentTime)


import           SecondTransfer.MainLoop.CoherentWorker (Headers, HeaderName, HeaderValue, Header)

-- Why having a headers library? The one at Network.HTTP.Headers works
-- with Strings and is not very friendly to custom headers.
-- This is a very basic, lightweight normalizer.

-- | HTTP headers are case-insensitive, so we can use lowercase versions
-- everywhere
lowercaseHeaders :: Headers -> Headers
lowercaseHeaders = map (\(h,v) -> (lower h, v))

lower :: B.ByteString -> B.ByteString
lower = encodeUtf8 . toLower . decodeUtf8

-- | Checks that headers are lowercase
headersAreLowercase :: Headers -> Bool
headersAreLowercase headers =
    foldl
        (\ prev (hn, _) -> (flip (&&)) (aTitleIsLowercase  hn) $! prev)
        True
        headers

headersAreLowercaseAtHeaderEditor :: HeaderEditor -> Bool
headersAreLowercaseAtHeaderEditor header_editor =
    Ms.foldlWithKey'
        (\ prev hn _ -> (flip (&&)) (aTitleIsLowercase . toFlatBs $ hn) $! prev)
        True
        (innerMap header_editor)

aTitleIsLowercase :: B.ByteString -> Bool
aTitleIsLowercase a_title = not . T.any isUpper . decodeUtf8 $ a_title


-- | Looks for a given header
fetchHeader :: Headers -> B.ByteString -> Maybe B.ByteString
fetchHeader headers header_name =
    snd
      <$>
    find ( \ x -> fst x == header_name ) headers


data HeaderPriority =
   Pseudo_Hep
 | Important_Hep
 | Normal_HeP
   deriving (Eq, Ord, Show, Generic)


headerIsPseudo :: HeaderName -> Bool
headerIsPseudo h  | B.length h == 0 = False --- Actually....
                  | B.head h == colon = True
                  | otherwise = False

headerIsImportant :: HeaderName -> Bool
headerIsImportant hn | hn == "host"  = True
                     | hn == "date"  = True
                     | hn == "content-length" = True
                     | hn == "content-type" = True
                     | hn == "cache-control" = True
                     | otherwise = False

headerPriority :: HeaderName -> HeaderPriority
headerPriority hn | headerIsPseudo hn = Pseudo_Hep
                  | headerIsImportant hn = Important_Hep
                  | otherwise = Normal_HeP


-- This is  a "flattish" representation of a header using lexical
-- ordering. HeaderName gives HeaderPriority, but we cache it here
-- nonetheless. The last number is used to hold the order.
newtype Autosorted = Autosorted (HeaderPriority, HeaderName, Int)
  deriving (Eq, Ord, Show, Generic)

toFlatBs :: Autosorted -> B.ByteString
toFlatBs (Autosorted (_priority, header_name, _same_order) ) = header_name


colon :: Word8
colon = fromIntegral . fromEnum $ ':'


-- | Abstract data-type. Use `fromList` to get one of these from `Headers`.
-- The underlying representation admits better asymptotics.
newtype HeaderEditor = HeaderEditor { innerMap :: Ms.Map Autosorted B.ByteString }

-- This is a pretty uninteresting instance
instance Monoid HeaderEditor where
    mempty = HeaderEditor mempty
    mappend (HeaderEditor x) (HeaderEditor y) = HeaderEditor (x `combineMaps` y)

-- | Expands a header value with zeros into something else
splitByZeros :: B.ByteString -> [B.ByteString]
splitByZeros = B.split 0

-- | Transforms a header value so that characters outside the valid ascii range
--   are replaced by nothings
sanitizeHeaderValue :: HeaderValue -> HeaderValue
sanitizeHeaderValue hv = B.filter (\x -> x >= 32 && x <= 126) hv

headerToMany :: Int -> Header -> [(Autosorted, HeaderValue)]
headerToMany base (header_name, header_value) =
  zip
      (map
        Autosorted
        (zip3
         (repeat (headerPriority header_name))
         (repeat (lower header_name))
         (iterate (+ 1) base)
        )
       )
       (map sanitizeHeaderValue $ splitByZeros header_value)

-- Uses a new base to change the number components in the Autosorted tuple ,
-- provided that they are already sorted.
rebase :: Int -> [(Autosorted, HeaderValue)] -> [(Autosorted, HeaderValue)]
rebase _base [] = []
rebase base ((Autosorted (hp, hn,_),hv ): rest) = (Autosorted (hp, hn, base), hv) : ( rebase (base+1) rest )

headerIsSingleton :: HeaderName -> Bool
headerIsSingleton hn | hn == "date"  = True
                     | hn == "content-length" = True
                     | hn == "content-type" = True
                     | hn == "expires" = True
                     | hn == "last-modified" = True
                     | hn == "content-encoding" = True
                     | hn == "server" = True
                     | otherwise = False


removeDuplicateHeaders :: [(Autosorted,HeaderValue)] -> [(Autosorted, HeaderValue)]
removeDuplicateHeaders [] = []
removeDuplicateHeaders (a:[]) = [a]
removeDuplicateHeaders ( (Autosorted (hp1, hn1,n1),hv1):(Autosorted (hp2, hn2,n2), hv2):rest )
      | hn1 == hn2 && headerIsSingleton hn1
          = removeDuplicateHeaders ( (Autosorted (hp2, hn2,n2), hv2):rest )
      | otherwise =  (Autosorted (hp1, hn1,n1), hv1) : removeDuplicateHeaders  ( (Autosorted(hp2, hn2,n2), hv2):rest )


combineMaps :: Ms.Map Autosorted B.ByteString -> Ms.Map Autosorted B.ByteString -> Ms.Map Autosorted B.ByteString
combineMaps mp1 mp2 =
  let
    at2 :: [(Autosorted, HeaderValue)]
    at2 = Ms.toList mp2

    n1 = Ms.size mp1
    at2' = rebase (n1+1) at2

    mp3 = mp1 `mappend` (Ms.fromList at2')
    at3 = Ms.toList mp3
    at4 = removeDuplicateHeaders at3
    at5 = rebase 0 at4
  in Ms.fromList at5


-- | /O(n*log n)/ Builds the editor from a list.
fromList :: Headers -> HeaderEditor
fromList headers =
  let
    at1go :: Int -> Headers ->  [[(Autosorted, HeaderValue)]]
    at1go _base []  = []
    at1go base (h:rest) = let
      g = headerToMany base h
      in g : at1go (base + length g ) rest

    at1 ::  [[(Autosorted, HeaderValue)]]
    at1 = at1go 0 headers

    mp1 :: Ms.Map Autosorted HeaderValue
    mp1 = Ms.fromList . concat $ at1

    at2 = Ms.toList mp1
    at3 = removeDuplicateHeaders at2
    at4 = rebase 0 at3
    mp2 = Ms.fromList at4
  in HeaderEditor mp2


-- | /O(n)/ Takes the HeaderEditor back to Headers. Notice that these headers
--          are good for both HTTP/1.1 and HTTP/2, as combined headers won't
--          be merged. It will even work for Cookie headers.
toList :: HeaderEditor -> Headers
toList (HeaderEditor m) = [ (toFlatBs x, v) | (x,v) <- Ms.toList m ]


-- | replaceHeaderValue headers header_name maybe_header_value looks for
--   header_name. If header_name is found and maybe_header_value is nothing, it
--   returns a new headers list with the header deleted. If header_name is found
--   and header_value is Just new_value, it returns a new list with the header
--   containing the new value. If header_name is not in headers and maybe_header_value
--   is Nothing, it returns the original headers list. If header_name is not in headers
--   and maybe_header_value is Just new_value, it returns a new list where the last element
--   is (header_name, new_value)
replaceHeaderValue :: HeaderEditor -> HeaderName -> Maybe HeaderValue -> HeaderEditor
replaceHeaderValue (HeaderEditor m) header_name maybe_header_value =
  let
    lst = Ms.toList m

    rpl (e1@(Autosorted (_hp, hn,_n), _hv):rest) | hn == header_name , Just new_value <- maybe_header_value =
                                                 (Autosorted (_hp, hn, _n), new_value): rest
                                             | hn == header_name, Nothing <- maybe_header_value =
                                                 rest
                                             | otherwise = e1:rest
    rpl [] = []

    at1 = rpl lst
    at2 = rebase 0 at1
  in HeaderEditor . Ms.fromList $ at2



-- | headerLens header_name represents a lens into the headers,
--   and you can use it then to add, alter and() remove headers.
--   It uses the same semantics than `replaceHeaderValue`
headerLens :: B.ByteString -> L.Lens' HeaderEditor (Maybe B.ByteString)
headerLens name =
  let
    --
    at1f he = Ms.toList . innerMap $ he
    findthingy ( (Autosorted (_hp, hn, _n), hv):rest )
        | hn == name = Just hv
        | otherwise = findthingy rest
    findthingy [] = Nothing

    --
    result = L.lens
        (findthingy . at1f )
        (\he mhv -> replaceHeaderValue he name mhv)
  in result


-- | Replaces a \"host\" HTTP\/1.1 header by an ":authority" HTTP\/2
-- header.
-- The list is expected to be already in lowercase, so nothing will happen if there
-- the header name portion is \"Host\" instead of \"host\".
--
-- Notice that having a "Host" header in an HTTP\/2 message is perfectly valid in certain
-- circumstances, check <https://http2.github.io/http2-spec/#rfc.section.8.1.2.3 Section 8.1.2.3>
-- of the spec for details.
replaceHostByAuthority :: HeaderEditor -> HeaderEditor
replaceHostByAuthority  headers =
  let
    host_lens :: L.Lens' HeaderEditor (Maybe B.ByteString)
    host_lens = headerLens "host"
    authority_lens = headerLens ":authority"
    maybe_host_header = headers ^. host_lens
    no_hosts = L.set host_lens Nothing headers
  in
    case maybe_host_header of
        Nothing -> headers
        Just host -> L.set authority_lens (Just host) no_hosts


-- | Given a header editor, introduces a "Date" header. This function has
-- a side-effect: to get the current time
introduceDateHeader :: HeaderEditor -> IO HeaderEditor
introduceDateHeader header_editor = do
    current_time <- getCurrentTime
    let
        date_header_lens = headerLens "date"
        formatted_date = Just . pack $
            formatTime defaultTimeLocale "%a, %d %b %Y %H:%M:%S %Z" current_time
        new_editor = L.set date_header_lens formatted_date header_editor
    return new_editor
