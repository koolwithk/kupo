--  This Source Code Form is subject to the terms of the Mozilla Public
--  License, v. 2.0. If a copy of the MPL was not distributed with this
--  file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kupo.Control.MonadDatabase
    ( -- * Database DSL
      MonadDatabase (..)
    , Database (..)
    , LongestRollback (..)
    ) where

import Kupo.Prelude

import Control.Exception
    ( throwIO )
import Data.FileEmbed
    ( embedFile )
import Database.SQLite.Simple
    ( Connection
    , Only (..)
    , Query (..)
    , SQLData (..)
    , ToRow (..)
    , execute
    , execute_
    , fold_
    , nextRow
    , withConnection
    , withStatement
    , withTransaction
    )
import GHC.TypeLits
    ( KnownSymbol, symbolVal )

import qualified Data.Text as T


class (Monad m, Monad (DBTransaction m)) => MonadDatabase (m :: Type -> Type) where
    type DBTransaction m :: (Type -> Type)
    withDatabase
        :: LongestRollback
        -> FilePath
        -> (Database m -> m a)
        -> m a

newtype LongestRollback = LongestRollback
    { getLongestRollback :: Word64
    } deriving newtype (Integral, Real, Num, Enum, Ord, Eq)

data Database (m :: Type -> Type) = Database
    { insertInputs
        :: [ ( ByteString       -- output_reference
             , ByteString       -- address
             , ByteString       -- value
             , Maybe ByteString -- datum_hash
             , Word64           -- slot_no
             )
           ]
        -> DBTransaction m ()

    , insertAddresses
        :: [ ( ByteString       -- payment
             , Maybe ByteString -- delegation
             )
           ]
        -> DBTransaction m ()

    , insertCheckpoint
        :: ByteString -- header_hash
        -> Word64     -- slot_no
        -> DBTransaction m ()

    , listCheckpointsDesc
        :: forall checkpoint. ()
        => (ByteString -> Word64 -> checkpoint)
        -> DBTransaction m [checkpoint]

    , runTransaction
        :: forall a. ()
        => DBTransaction m a
        -> m a
    }

--
-- IO
--

newtype WrappedIO a = WrappedIO { runIO :: IO a }
    deriving newtype (Functor, Applicative, Monad)

instance MonadDatabase IO where
    type DBTransaction IO = WrappedIO
    withDatabase k filePath action =
        withConnection filePath $ \conn -> do
            databaseVersion conn >>= runMigrations conn
            action (mkDatabase k conn)

mkDatabase :: LongestRollback -> Connection -> Database IO
mkDatabase (toInteger -> longestRollback) conn = Database
    { insertInputs = WrappedIO . mapM_
        (\(outputReference, address, value, datumHash, fromIntegral -> slotNo) ->
            insertRow @"inputs" conn
                [ SQLBlob outputReference
                , SQLBlob address
                , SQLBlob value
                , maybe SQLNull SQLBlob datumHash
                , SQLInteger slotNo
                ]
        )

    , insertAddresses = WrappedIO . mapM_
        (\(payment, delegation) ->
            insertRow @"addresses" conn
                [ SQLBlob payment
                , maybe SQLNull SQLBlob delegation
                ]
        )

    , insertCheckpoint = \headerHash (toInteger -> slotNo) -> WrappedIO $ do
        insertRow @"checkpoints" conn
            [ SQLBlob headerHash
            , SQLInteger (fromIntegral slotNo)
            ]
        execute conn "DELETE FROM checkpoints WHERE slot_no < ?"
            [ SQLInteger (fromIntegral (slotNo - longestRollback))
            ]

    , listCheckpointsDesc = \mk -> WrappedIO $ do
        -- NOTE: fetching in *ASC*ending order because the list construction
        -- reverses it,
        fold_ conn "SELECT * FROM checkpoints ORDER BY slot_no ASC" []
            $ \xs (headerHash, slotNo) -> pure ((mk headerHash slotNo) : xs)

    , runTransaction =
        withTransaction conn . runIO
    }

insertRow
    :: forall tableName.
        ( KnownSymbol tableName
        )
    => Connection
    -> [SQLData]
    -> IO ()
insertRow conn r =
    let
        tableName = fromString (symbolVal (Proxy @tableName))
        values = mkPreparedStatement (length (toRow r))
        qry = "INSERT OR IGNORE INTO " <> tableName <> " VALUES " <> values
     in
        execute conn qry r

--
-- Helpers
--

mkPreparedStatement :: Int -> Query
mkPreparedStatement n =
    Query ("(" <> T.intercalate "," (replicate n "?") <> ")")

--
-- Migrations
--

type MigrationRevision = Int
type Migration = [Query]

databaseVersion :: Connection -> IO MigrationRevision
databaseVersion conn =
    withStatement conn "PRAGMA user_version" $ \stmt -> do
        nextRow stmt >>= \case
            Just (Only version) ->
                pure version
            _ ->
                throwIO UnexpectedUserVersion

runMigrations :: Connection -> MigrationRevision -> IO ()
runMigrations conn currentVersion = do
    let missingMigrations = drop currentVersion migrations
    if null missingMigrations then
        putStrLn $ "No migration to run; version=" <> show currentVersion
    else do
        putStrLn $ "Running " <> show (length missingMigrations) <> " migration(s) from version=" <> show currentVersion
        void $ withTransaction conn $
            traverse (traverse (execute_ conn)) missingMigrations

migrations :: [Migration]
migrations =
    [ mkMigration (decodeUtf8 m)
    | m <-
        [ $(embedFile "db/001.sql")
        ]
    ]
  where
    mkMigration :: Text -> [Query]
    mkMigration =
        fmap Query . filter (not . T.null . T.strip) . T.splitOn ";"

--
-- Exceptions
--

-- | Somehow, a 'PRAGMA user_version' didn't yield a number but, either nothing
-- or something else?
data UnexpectedUserVersionException
    = UnexpectedUserVersion
    deriving Show
instance Exception UnexpectedUserVersionException
