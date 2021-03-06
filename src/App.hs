{-# LANGUAGE FlexibleContexts #-}
module App (app, sqlError, isSqlError) where

import Control.Monad (join)
import Control.Arrow ((***), second)
import Control.Applicative

import Data.Text hiding (map)
import Data.Maybe (fromMaybe, mapMaybe)
import Text.Regex.TDFA ((=~))
import Data.Ord (comparing)
import Data.Ranged.Ranges (emptyRange)
import qualified Data.HashMap.Strict as M
import Data.String.Conversions (cs)
import Data.CaseInsensitive (original)
import Data.List (sortBy)
import Data.Functor.Identity
import qualified Data.Set as S
import qualified Data.ByteString.Lazy as BL
import qualified Blaze.ByteString.Builder as BB
import qualified Data.Csv as CSV

import Network.HTTP.Types.Status
import Network.HTTP.Types.Header
import Network.HTTP.Types.URI (parseSimpleQuery)
import Network.HTTP.Base (urlEncodeVars)
import Network.Wai
import Network.Wai.Internal (Response(..))

import Data.Aeson
import Data.Monoid
import qualified Data.Vector as V
import qualified Hasql as H
import qualified Hasql.Backend as B
import qualified Hasql.Postgres as P

import Auth
import PgQuery
import RangeQuery
import PgStructure

app :: Text -> BL.ByteString -> Request -> H.Tx P.Postgres s Response
app v1schema reqBody req =
  case (path, verb) of
    ([], _) -> do
      body <- encode <$> tables (cs schema)
      return $ responseLBS status200 [jsonH] $ cs body

    ([table], "OPTIONS") -> do
      let t = QualifiedTable schema (cs table)
      cols <- columns t
      pkey <- map cs <$> primaryKeyColumns t
      return $ responseLBS status200 [jsonH, allOrigins]
        $ encode (TableOptions cols pkey)

    ([table], "GET") ->
      if range == Just emptyRange
      then return $ responseLBS status416 [] "HTTP Range error"
      else do
        let qt = QualifiedTable schema (cs table)
        let select = B.Stmt "select " V.empty True <>
                  parentheticT (
                    whereT qq $ countRows qt
                  ) <> commaq <> (
                  asJsonWithCount
                  . limitT range
                  . orderT (orderParse qq)
                  . whereT qq
                  $ selectStar qt
                )
        row <- H.maybeEx select
        let (tableTotal, queryTotal, body) =
              fromMaybe (0, 0, Just "" :: Maybe Text) row
            from = fromMaybe 0 $ rangeOffset <$> range
            to = from+queryTotal-1
            contentRange = contentRangeH from to tableTotal
            status = rangeStatus from to tableTotal
            canonical = urlEncodeVars
                          . sortBy (comparing fst)
                          . map (join (***) cs)
                          . parseSimpleQuery
                          $ rawQueryString req
        return $ responseLBS status
          [jsonH, contentRange,
            ("Content-Location",
             "/" <> cs table <>
                if Prelude.null canonical then "" else "?" <> cs canonical
            )
          ] (cs $ fromMaybe "[]" body)

    (["postgrest", "users"], "POST") -> do
      let user = decode reqBody :: Maybe AuthUser

      case user of
        Nothing -> return $ responseLBS status400 [jsonH] $
          encode . object $ [("message", String "Failed to parse user.")]
        Just u -> do
          _ <- addUser (cs $ userId u)
            (cs $ userPass u) (cs $ userRole u)
          return $ responseLBS status201
            [ jsonH
            , (hLocation, "/postgrest/users?id=eq." <> cs (userId u))
            ] ""

    ([table], "POST") -> do
      let qt = QualifiedTable schema (cs table)
          echoRequested = lookup "Prefer" hdrs == Just "return=representation"
          parsed :: Either String (V.Vector Text, V.Vector (V.Vector Value))
          parsed = if lookup "Content-Type" hdrs == Just "text/csv"
                    then do
                      rows <- CSV.decode CSV.NoHeader reqBody
                      if V.null rows then Left "CSV requires header"
                        else Right (V.head rows, (V.map $ V.map $ parseCsvCell . cs) (V.tail rows))
                    else eitherDecode reqBody >>= \val ->
                      case val of
                        Object obj -> Right .  second V.singleton .  V.unzip .  V.fromList $
                          M.toList obj
                        _ -> Left "Expecting single JSON object or CSV rows"
      case parsed of
        Left err -> return $ responseLBS status400 [] $
          encode . object $ [("message", String $ "Failed to parse JSON payload. " <> cs err)]
        Right toBeInserted -> do
          rows :: [Identity Text] <- H.listEx $ uncurry (insertInto qt) toBeInserted
          let inserted :: [Object] = mapMaybe (decode . cs . runIdentity) rows
          primaryKeys <- primaryKeyColumns qt
          let responses = flip map inserted $ \obj -> do
                let primaries =
                      if Prelude.null primaryKeys
                        then obj
                        else M.filterWithKey (const . (`elem` primaryKeys)) obj
                let params = urlEncodeVars
                      $ map (\t -> (cs $ fst t, cs (paramFilter $ snd t)))
                      $ sortBy (comparing fst) $ M.toList primaries
                responseLBS status201
                  [ jsonH
                  , (hLocation, "/" <> cs table <> "?" <> cs params)
                  ] $ if echoRequested then encode obj else ""
          return $ multipart status201 responses

    ([table], "PUT") ->
      handleJsonObj reqBody $ \obj -> do
        let qt = QualifiedTable schema (cs table)
        primaryKeys <- primaryKeyColumns qt
        let specifiedKeys = map (cs . fst) qq
        if S.fromList primaryKeys /= S.fromList specifiedKeys
          then return $ responseLBS status405 []
               "You must speficy all and only primary keys as params"
          else do
            tableCols <- map (cs . colName) <$> columns qt
            let cols = map cs $ M.keys obj
            if S.fromList tableCols == S.fromList cols
              then do
                let vals = M.elems obj
                H.unitEx $ iffNotT
                        (whereT qq $ update qt cols vals)
                        (insertSelect qt cols vals)
                return $ responseLBS status204 [ jsonH ] ""

              else return $ if Prelude.null tableCols
                then responseLBS status404 [] ""
                else responseLBS status400 []
                   "You must specify all columns in PUT request"

    ([table], "PATCH") ->
      handleJsonObj reqBody $ \obj -> do
        let qt = QualifiedTable schema (cs table)
        H.unitEx
          $ whereT qq
          $ update qt (map cs $ M.keys obj) (M.elems obj)
        return $ responseLBS status204 [ jsonH ] ""

    ([table], "DELETE") -> do
      let qt = QualifiedTable schema (cs table)
      let del = countT
            . returningStarT
            . whereT qq
            $ deleteFrom qt
      row <- H.maybeEx del
      let (Identity deletedCount) = fromMaybe (Identity 0 :: Identity Int) row
      return $ if deletedCount == 0
         then responseLBS status404 [] ""
         else responseLBS status204 [("Content-Range", "*/"<> cs (show deletedCount))] ""

    (_, _) ->
      return $ responseLBS status404 [] ""

  where
    path   = pathInfo req
    verb   = requestMethod req
    qq     = queryString req
    hdrs   = requestHeaders req
    schema = requestedSchema v1schema hdrs
    range  = rangeRequested hdrs
    allOrigins = ("Access-Control-Allow-Origin", "*") :: Header

sqlError :: t
sqlError = undefined

isSqlError :: t
isSqlError = undefined

rangeStatus :: Int -> Int -> Int -> Status
rangeStatus from to total
  | from > total            = status416
  | (1 + to - from) < total = status206
  | otherwise               = status200

contentRangeH :: Int -> Int -> Int -> Header
contentRangeH from to total =
  ("Content-Range",
    if total == 0 || from > total
    then "*/" <> cs (show total)
    else cs (show from)  <> "-"
       <> cs (show to)    <> "/"
       <> cs (show total)
  )

requestedSchema :: Text -> RequestHeaders -> Text
requestedSchema v1schema hdrs =
  case verStr of
       Just [[_, ver]] -> if ver == "1" then v1schema else ver
       _ -> v1schema

  where verRegex = "version[ ]*=[ ]*([0-9]+)" :: String
        accept = cs <$> lookup hAccept hdrs :: Maybe Text
        verStr = (=~ verRegex) <$> accept :: Maybe [[Text]]

jsonH :: Header
jsonH = (hContentType, "application/json")

handleJsonObj :: BL.ByteString -> (Object -> H.Tx P.Postgres s Response)
              -> H.Tx P.Postgres s Response
handleJsonObj reqBody handler = do
  let p = eitherDecode reqBody
  case p of
    Left err ->
      return $ responseLBS status400 [jsonH] jErr
      where
        jErr = encode . object $
          [("message", String $ "Failed to parse JSON payload. " <> cs err)]
    Right (Object o) -> handler o
    Right _ ->
      return $ responseLBS status400 [jsonH] jErr
      where
        jErr = encode . object $
          [("message", String "Expecting a JSON object")]

parseCsvCell :: BL.ByteString -> Value
parseCsvCell s = if s == "NULL" then Null else String $ cs s

multipart :: Status -> [Response] -> Response
multipart _ [] = responseLBS status204 [] ""
multipart _ [r] = r
multipart s rs =
  responseLBS s [(hContentType, "multipart/mixed; boundary=\"postgrest_boundary\"")] $
    BL.intercalate "\n--postgrest_boundary\n" (map renderResponseBody rs)

  where
    renderHeader :: Header -> BL.ByteString
    renderHeader (k, v) = cs (original k) <> ": " <> cs v

    renderResponseBody :: Response -> BL.ByteString
    renderResponseBody (ResponseBuilder _ headers b) =
      BL.intercalate "\n" (map renderHeader headers)
        <> "\n\n" <> BB.toLazyByteString b
    renderResponseBody _ = error
      "Unable to create multipart response from non-ResponseBuilder"

data TableOptions = TableOptions {
  tblOptcolumns :: [Column]
, tblOptpkey :: [Text]
}

instance ToJSON TableOptions where
  toJSON t = object [
      "columns" .= tblOptcolumns t
    , "pkey"   .= tblOptpkey t ]
