{-# LANGUAGE ExistentialQuantification, FlexibleInstances, IncoherentInstances,
             OverloadedStrings #-}
-- Module:      Text.Hastache
-- Copyright:   Sergey S Lymar (c) 2011 
-- License:     BSD3
-- Maintainer:  Sergey S Lymar <sergey.lymar@gmail.com>
-- Stability:   experimental
-- Portability: portable
--
-- Haskell implementation of Mustache templates

{- | Haskell implementation of Mustache templates

See homepage for examples of usage: <http://github.com/lymar/hastache>

Simplest example:

@
import Text.Hastache 
import Text.Hastache.Context 
import qualified Data.ByteString.Lazy as LZ 

main = do 
    res <- hastacheStr defaultConfig (encodeStr template)  
        (mkStrContext context) 
    LZ.putStrLn res 
    where 
    template = \"Hello, {{name}}!\\n\\nYou have {{unread}} unread messages.\" 
    context \"name\" = MuVariable \"Haskell\"
    context \"unread\" = MuVariable (100 :: Int)
@

Result:

@
Hello, Haskell!

You have 100 unread messages.
@

Using Generics:

@
import Text.Hastache 
import Text.Hastache.Context 
import qualified Data.ByteString.Lazy as LZ 
import Data.Data 
import Data.Generics 
 
data Info = Info { 
    name    :: String, 
    unread  :: Int 
    } deriving (Data, Typeable)

main = do 
    res <- hastacheStr defaultConfig (encodeStr template) 
        (mkGenericContext inf) 
    LZ.putStrLn res 
    where 
    template = \"Hello, {{name}}!\\n\\nYou have {{unread}} unread messages.\"
    inf = Info \"Haskell\" 100
@

-}
module Text.Hastache (
      hastacheStr
    , hastacheFile
    , hastacheStrBuilder
    , hastacheFileBuilder
    , MuContext
    , MuType(..)
    , MuConfig(..)
    , MuVar(..)
    , htmlEscape
    , emptyEscape
    , defaultConfig
    , encodeStr
    , encodeStrLBS
    , decodeStr
    , decodeStrLBS
    ) where 

import Control.Monad (guard, when)
import Control.Monad.Reader (ask, runReaderT, MonadReader, ReaderT)
import Control.Monad.Trans (lift, liftIO, MonadIO)
import Data.AEq (AEq,(~==))
import Data.ByteString hiding (map, foldl1)
import Data.ByteString.Char8 (readInt)
import Data.Char (ord)
import Data.Int
import Data.IORef
import Data.Maybe (isJust)
import Data.Monoid (mappend, mempty)
import Data.Word
import Prelude hiding (putStrLn, readFile, length, drop, tail, dropWhile, elem,
    head, last, reverse, take, span, null)
import System.Directory (doesFileExist)
import System.FilePath (combine)

import qualified Blaze.ByteString.Builder as BSB
import qualified Codec.Binary.UTF8.String as SU
import qualified Data.ByteString.Lazy as LZ
import qualified Data.List as List
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.Lazy as LText
import qualified Data.Text.Lazy.Encoding as LTextEncoding
import qualified Prelude

(~>) :: a -> (a -> b) -> b
x ~> f = f x
infixl 9 ~>

-- | Data for Hastache variable
type MuContext m = 
    ByteString  -- ^ Variable name
    -> MuType m -- ^ Value

class Show a => MuVar a where
    -- | Convert to Lazy ByteString
    toLByteString   :: a -> LZ.ByteString 
    -- | Is empty variable (empty string, zero number etc.)
    isEmpty         :: a -> Bool 
    isEmpty _ = False
        
instance MuVar ByteString where
    toLByteString = toLBS
    isEmpty a = length a == 0
    
instance MuVar LZ.ByteString where
    toLByteString = id
    isEmpty a = LZ.length a == 0

withShowToLBS :: Show a => a -> LZ.ByteString
withShowToLBS a = show a ~> encodeStr ~> toLBS

numEmpty :: (Num a,AEq a) => a -> Bool
numEmpty a = a ~== 0

instance MuVar Integer where {toLByteString = withShowToLBS; isEmpty = numEmpty}
instance MuVar Int     where {toLByteString = withShowToLBS; isEmpty = numEmpty}
instance MuVar Float   where {toLByteString = withShowToLBS; isEmpty = numEmpty}
instance MuVar Double  where {toLByteString = withShowToLBS; isEmpty = numEmpty}
instance MuVar Int8    where {toLByteString = withShowToLBS; isEmpty = numEmpty}
instance MuVar Int16   where {toLByteString = withShowToLBS; isEmpty = numEmpty}
instance MuVar Int32   where {toLByteString = withShowToLBS; isEmpty = numEmpty}
instance MuVar Int64   where {toLByteString = withShowToLBS; isEmpty = numEmpty}
instance MuVar Word    where {toLByteString = withShowToLBS; isEmpty = numEmpty}
instance MuVar Word8   where {toLByteString = withShowToLBS; isEmpty = numEmpty}
instance MuVar Word16  where {toLByteString = withShowToLBS; isEmpty = numEmpty}
instance MuVar Word32  where {toLByteString = withShowToLBS; isEmpty = numEmpty}
instance MuVar Word64  where {toLByteString = withShowToLBS; isEmpty = numEmpty}

instance MuVar Text.Text where 
    toLByteString t = TextEncoding.encodeUtf8 t ~> toLBS
    isEmpty a = Text.length a == 0

instance MuVar LText.Text where 
    toLByteString t = LTextEncoding.encodeUtf8 t
    isEmpty a = LText.length a == 0
    
instance MuVar Char where
    toLByteString a = (a : "") ~> encodeStr ~> toLBS

instance MuVar a => MuVar [a] where
    toLByteString a = toLByteString '[' <+> cnvLst <+> toLByteString ']'
        where
        cnvLst = map toLByteString a ~> 
                LZ.intercalate (toLByteString ',')
        (<+>) = LZ.append

instance MuVar [Char] where
    toLByteString k = k ~> encodeStr ~> toLBS
    isEmpty a = Prelude.length a == 0

data MuType m = 
    forall a. MuVar a => MuVariable a                   |
    MuList [MuContext m]                                |
    MuBool Bool                                         |
    forall a. MuVar a => MuLambda (ByteString -> a)     |
    forall a. MuVar a => MuLambdaM (ByteString -> m a)  |
    MuNothing

instance Show (MuType m) where
    show (MuVariable a) = "MuVariable " ++ show a
    show (MuList _) = "MuList [..]"
    show (MuBool v) = "MuBool " ++ show v
    show (MuLambda _) = "MuLambda <..>"
    show (MuLambdaM _) = "MuLambdaM <..>"
    show MuNothing = "MuNothing"

data MuConfig = MuConfig {
    muEscapeFunc        :: LZ.ByteString -> LZ.ByteString, 
        -- ^ Escape function ('htmlEscape', 'emptyEscape' etc.)
    muTemplateFileDir   :: Maybe FilePath,
        -- ^ Directory for search partial templates ({{> templateName}})
    muTemplateFileExt   :: Maybe String
        -- ^ Partial template files extension
    }

-- | Convert String to UTF-8 Bytestring
encodeStr :: String -> ByteString
encodeStr = pack . SU.encode

-- | Convert String to UTF-8 Lazy Bytestring
encodeStrLBS :: String -> LZ.ByteString
encodeStrLBS = LZ.pack . SU.encode

-- | Convert UTF-8 Bytestring to String
decodeStr :: ByteString -> String
decodeStr = SU.decode . unpack

-- | Convert UTF-8 Lazy Bytestring to String
decodeStrLBS :: LZ.ByteString -> String
decodeStrLBS = SU.decode . LZ.unpack

ord8 :: Char -> Word8
ord8 = fromIntegral . ord

isMuNothing MuNothing = True
isMuNothing _ = False

-- | Escape HTML symbols
htmlEscape :: LZ.ByteString -> LZ.ByteString
htmlEscape str = LZ.unpack str ~> proc ~> LZ.pack
    where
    proc :: [Word8] -> [Word8]
    proc (h:t)
        | h == ord8 '&' = stp "&amp;" t
        | h == ord8 '\\'= stp "&#92;" t
        | h == ord8 '"' = stp "&quot;" t
        | h == ord8 '\''= stp "&#39;" t
        | h == ord8 '<' = stp "&lt;" t
        | h == ord8 '>' = stp "&gt;" t
        | otherwise     = h : proc t
    proc [] = []
    stp a t = map ord8 a ++ proc t

-- | No escape
emptyEscape :: LZ.ByteString -> LZ.ByteString
emptyEscape = id

{- | Default config: HTML escape function, current directory as 
     template directory, template file extension not specified -}
defaultConfig :: MuConfig 
defaultConfig = MuConfig { 
    muEscapeFunc = htmlEscape,
    muTemplateFileDir = Nothing,
    muTemplateFileExt = Nothing
    } 

defOTag = "{{" :: ByteString
defCTag = "}}" :: ByteString
unquoteCTag = "}}}" :: ByteString

findBlock :: 
       ByteString 
    -> ByteString 
    -> ByteString
    -> Maybe (ByteString, Word8, ByteString, ByteString)
findBlock str otag ctag = do
    guard (length fnd > length otag)
    Just (pre, symb, inTag, afterClose)
    where
    (pre, fnd) = breakSubstring otag str
    symb = index fnd (length otag)
    (inTag, afterClose)
        -- test for unescape ( {{{some}}} )
        | symb == ord8 '{' && ctag == defCTag = 
            breakSubstring unquoteCTag fnd ~> \(a,b) -> 
            (drop (length otag) a, drop 3 b)
        | otherwise = breakSubstring ctag fnd ~> \(a,b) -> 
            (drop (length otag) a, drop (length ctag) b)

toLBS :: ByteString -> LZ.ByteString
toLBS v = LZ.fromChunks [v]


readVar :: MonadIO m => [MuContext m] -> ByteString -> LZ.ByteString
readVar [] _ = LZ.empty
readVar (context:parentCtx) name =
    case context name of
        MuVariable a -> toLByteString a
        MuBool a -> show a ~> encodeStr ~> toLBS
        MuNothing -> case tryFindArrayItem context name of
            Just (nctx,nn) -> readVar [nctx] nn
            _ -> readVar parentCtx name
        _ -> LZ.empty

tryFindArrayItem :: MonadIO m => 
       MuContext m
    -> ByteString 
    -> Maybe (MuContext m, ByteString)
tryFindArrayItem context name = do
    guard $ length idx > 1
    (idx,nxt) <- readInt $ tail idx
    guard $ idx >= 0
    guard $ (null nxt) || ((head nxt) == (ord8 '.'))
    case context nm of
        MuList l -> do
            guard $ idx < (List.length l)
            let ncxt = l !! idx
            if null nxt 
                then Just (ncxt, dotStr) -- {{some.0}}
                else Just (ncxt, tail nxt) -- {{some.0.field}}
        _ -> Nothing
    where
    (nm,idx) = breakSubstring dotStr name
    dotStr = "."

findCloseSection :: 
       ByteString 
    -> ByteString 
    -> ByteString 
    -> ByteString
    -> Maybe (ByteString, ByteString)
findCloseSection str name otag ctag = do
    guard (length after > 0)
    Just (before, drop (length close) after)
    where
    close = foldl1 append [otag, "/", name, ctag]
    (before, after) = breakSubstring close str

trimCharsTest :: Word8 -> Bool
trimCharsTest = (`elem` " \t")

trimAll :: ByteString -> ByteString
trimAll str = span trimCharsTest str ~> snd ~> spanEnd trimCharsTest ~> fst

addRes :: MonadIO m => LZ.ByteString -> ReaderT (IORef BSB.Builder) m ()
addRes str = do
    rf <- ask
    b <- readIORef rf ~> liftIO
    let l = mappend b (BSB.fromLazyByteString str)
    writeIORef rf l ~> liftIO
    return ()

addResBS :: MonadIO m => ByteString -> ReaderT (IORef BSB.Builder) m ()
addResBS str = toLBS str ~> addRes

addResLZ :: MonadIO m => LZ.ByteString -> ReaderT (IORef BSB.Builder) m ()
addResLZ = addRes

processBlock :: MonadIO m => 
       ByteString 
    -> [MuContext m] 
    -> ByteString 
    -> ByteString 
    -> MuConfig 
    -> ReaderT (IORef BSB.Builder) m ()
processBlock str contexts otag ctag conf = 
    case findBlock str otag ctag of
        Just (pre, symb, inTag, afterClose) -> do
            addResBS pre
            renderBlock contexts symb inTag afterClose otag ctag conf
        Nothing -> do
            addResBS str
            return ()

renderBlock :: MonadIO m =>
       [MuContext m] 
    -> Word8 
    -> ByteString 
    -> ByteString 
    -> ByteString
    -> ByteString 
    -> MuConfig 
    -> ReaderT (IORef BSB.Builder) m ()
renderBlock contexts symb inTag afterClose otag ctag conf
    -- comment
    | symb == ord8 '!' = next afterClose
    -- unescape variable
    | symb == ord8 '&' || (symb == ord8 '{' && otag == defOTag) = do
        readVar contexts (tail inTag ~> trimAll) ~> addResLZ
        next afterClose
    -- section, inverted section
    | symb == ord8 '#' || symb == ord8 '^' = 
        case findCloseSection afterClose (tail inTag) otag ctag of
            Nothing -> next afterClose
            Just (sectionContent', afterSection') -> 
                let 
                    dropNL str = 
                        if length str > 0 && head str == ord8 '\n' 
                           then tail str
                           else str
                    sectionContent = dropNL sectionContent'
                    afterSection = 
                        if ord8 '\n' `elem` sectionContent
                            then dropNL afterSection'
                            else afterSection'
                    tlInTag = tail inTag
                    readContext' = map ($ tlInTag) contexts 
                        ~> List.find (not . isMuNothing)
                    readContextWithIdx = do
                        Just (ctx,name) <- map (
                            \c -> tryFindArrayItem c tlInTag) 
                            contexts ~> List.find isJust
                        Just $ ctx name
                    readContext = case readContext' of
                        Just a -> Just a
                        Nothing -> readContextWithIdx
                    processAndNext = do 
                        processBlock sectionContent contexts otag ctag conf
                        next afterSection
                in 
                if symb == ord8 '#'
                    then case readContext of -- section
                        Just (MuList []) -> next afterSection
                        Just (MuList b) -> do
                            mapM_ (\c -> processBlock sectionContent
                                (c:contexts) otag ctag conf) b
                            next afterSection
                        Just (MuVariable a) -> if isEmpty a 
                            then next afterSection
                            else processAndNext
                        Just (MuBool True) -> processAndNext
                        Just (MuLambda func) -> do
                            func sectionContent ~> toLByteString ~> addResLZ
                            next afterSection
                        Just (MuLambdaM func) -> do
                            res <- lift (func sectionContent)
                            toLByteString res ~> addResLZ
                            next afterSection
                        _ -> next afterSection
                    else case readContext of -- inverted section
                        Just (MuList []) -> processAndNext
                        Just (MuBool False) -> processAndNext
                        Just (MuVariable a) -> if isEmpty a 
                            then processAndNext
                            else next afterSection
                        Nothing -> processAndNext
                        _ -> next afterSection
    -- set delimiter
    | symb == ord8 '=' = 
        let
            lenInTag = length inTag
            delimitersCommand = take (lenInTag - 1) inTag ~> drop 1
            getDelimiter = do
                guard $ lenInTag > 4
                guard $ index inTag (lenInTag - 1) == ord8 '='
                [newOTag,newCTag] <- Just $ split (ord8 ' ') delimitersCommand
                Just (newOTag, newCTag)
        in case getDelimiter of
                Nothing -> next afterClose
                Just (newOTag, newCTag) -> 
                    processBlock (trim' afterClose) contexts
                        newOTag newCTag conf
    -- partials
    | symb == ord8 '>' =
        let 
            fileName' = tail inTag ~> trimAll
            fileName'' = case muTemplateFileExt conf of
                Nothing -> fileName'
                Just ext -> fileName' `append` encodeStr ext
            fileName = decodeStr fileName''
            fullFileName = case muTemplateFileDir conf of
                Nothing -> fileName
                Just path -> combine path fileName
        in do
            fe <- liftIO $ doesFileExist fullFileName
            when fe $ do
                cnt <- liftIO $ readFile fullFileName
                next cnt
            next (trim' afterClose)
    -- variable
    | otherwise = do
        readVar contexts (trimAll inTag) ~> muEscapeFunc conf ~> addResLZ
        next afterClose
    where
    next t = processBlock t contexts otag ctag conf
    trim' content = 
        dropWhile trimCharsTest content
        ~> \t -> if length t > 0 && head t == ord8 '\n'
            then tail t else content
    processSection = undefined

-- | Render Hastache template from ByteString
hastacheStr :: (MonadIO m) => 
       MuConfig         -- ^ Configuration
    -> ByteString       -- ^ Template
    -> MuContext m      -- ^ Context
    -> m LZ.ByteString
hastacheStr conf str context = 
    hastacheStrBuilder conf str context >>= return . BSB.toLazyByteString

-- | Render Hastache template from file
hastacheFile :: (MonadIO m) => 
       MuConfig         -- ^ Configuration
    -> FilePath         -- ^ Template file name
    -> MuContext m      -- ^ Context
    -> m LZ.ByteString
hastacheFile conf file_name context = 
    hastacheFileBuilder conf file_name context >>= return . BSB.toLazyByteString

-- | Render Hastache template from ByteString
hastacheStrBuilder :: (MonadIO m) => 
       MuConfig         -- ^ Configuration
    -> ByteString       -- ^ Template
    -> MuContext m      -- ^ Context
    -> m BSB.Builder
hastacheStrBuilder conf str context = do
    rf <- newIORef mempty ~> liftIO
    runReaderT (processBlock str [context] defOTag defCTag conf) rf
    readIORef rf ~> liftIO

-- | Render Hastache template from file
hastacheFileBuilder :: (MonadIO m) => 
       MuConfig         -- ^ Configuration
    -> FilePath         -- ^ Template file name
    -> MuContext m      -- ^ Context
    -> m BSB.Builder
hastacheFileBuilder conf file_name context = do
    str <- readFile file_name ~> liftIO
    hastacheStrBuilder conf str context

