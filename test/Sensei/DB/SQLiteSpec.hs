{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Sensei.DB.SQLiteSpec where

import Control.Exception.Safe (throwIO)
import Control.Monad.Reader
import Data.Aeson(encode)
import Data.List (isInfixOf, isPrefixOf)
import Data.Text.Encoding(decodeUtf8)
import Data.ByteString.Lazy(toStrict)
import qualified Database.SQLite.Simple as SQLite
import Preface.Log
import Sensei.API
import Sensei.DB
import qualified Sensei.DB.File as File
import Sensei.DB.Log ()
import Sensei.DB.Model (canReadFlowsAndTracesWritten)
import Sensei.DB.SQLite (SQLiteDBError (..), runDB, withBackup)
import Sensei.TestHelper
import Sensei.Time hiding (getCurrentTime)
import System.Directory
import System.FilePath (takeDirectory, takeFileName)
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = describe "SQLite DB" $ do
  around withTempFile $
    describe "Backup files" $ do
      let isBackupFileFor file fp =
            file `isPrefixOf` takeFileName fp
              && ".bak." `isInfixOf` takeFileName fp

      it "backup file before running action" $ \tmp -> do
        writeFile tmp "Foo"

        withBackup tmp $ \file -> do
          writeFile file "Bar"

          let dir = takeDirectory file
          backups <- filter (isBackupFileFor tmp) <$> listDirectory dir

          backups `shouldNotBe` []
          readFile (head backups) `shouldReturn` "Foo"

      it "Delete backup file after action completes successfuly" $ \tmp -> do
        withBackup tmp $ \file -> do
          writeFile file "Bar"

        let dir = takeDirectory tmp

        files <- listDirectory dir
        filter (isBackupFileFor tmp) files `shouldBe` []

      it "Restore initial file from backup and delete backup after action throws SQLiteDBError" $ \tmp -> do
        writeFile tmp "Foo"

        withBackup
          tmp
          ( \file -> do
              writeFile file "Bar"

              void $ throwIO $ SQLiteDBError "select * from foo;" "some error"
          )
          `shouldThrow` \(_ :: SQLiteDBError) -> True

        let dir = takeDirectory tmp

        files <- listDirectory dir
        filter (isBackupFileFor tmp) files `shouldBe` []
        readFile tmp `shouldReturn` "Foo"

      it "Do not remove backup file after action throws IOException" $ \tmp -> do
        writeFile tmp "Foo"

        withBackup
          tmp
          ( \file -> do
              writeFile file "Bar"

              void $ throwIO $ userError "some error"
          )
          `shouldThrow` anyIOException

        let dir = takeDirectory tmp

        files <- listDirectory dir
        filter (isBackupFileFor tmp) files `shouldNotBe` []
        mapM_ removeFile (filter (isBackupFileFor tmp) files)
  around withTempFile $
    describe "Basic Operations" $ do
      it "matches DB model" $ \tempdb -> property $ canReadFlowsAndTracesWritten tempdb (runDB tempdb "." fakeLogger)

      it "gets IO-based current time when time is not set" $ \tempdb -> do
        res <- runDB tempdb "." fakeLogger $ do
          initLogStorage
          t1 <- getCurrentTime defaultProfile
          t2 <- getCurrentTime defaultProfile
          pure (t1, t2)

        uncurry (<) res `shouldBe` True

      it "throws SQLiteDBError when querying uninitialised DB" $ \tempdb -> do
        removePathForcibly tempdb

        runDB tempdb "." fakeLogger (getCurrentTime defaultProfile)
          `shouldThrow` \SQLiteDBError {} -> True

      it "logs all DB operations using given logger" $ \tempdb -> do
        let time1 = UTCTime (toEnum 50000) 0
        logger <- newLog "test"

        res <-
          runDB tempdb "." logger $
            runReaderT
              ( do
                  initLogStorage
                  setCurrentTime defaultProfile time1
                  getCurrentTime defaultProfile
              )
              logger

        res `shouldBe` time1

      it "gets latest current time when time is set explicitly" $ \tempdb -> do
        let time1 = UTCTime (toEnum 50000) 0
            time2 = UTCTime (toEnum 50000) 100

        res <- runDB tempdb "." fakeLogger $ do
          initLogStorage
          setCurrentTime defaultProfile time1
          setCurrentTime defaultProfile time2
          getCurrentTime defaultProfile

        res `shouldBe` time2

      it "indexes newly inserted note on the fly" $ \tempdb -> do
        let noteTime = UTCTime (toEnum 50000) 1000
            content = "foo bar baz cat"
            note1 = NoteFlow "arnaud" noteTime "some/dir" content
        res <- runDB tempdb "." fakeLogger $ do
          initLogStorage
          writeEvent (EventNote note1)
          searchNotes defaultProfile "foo"

        res `shouldBe` [(utcToLocalTime (userTimezone defaultProfile) noteTime, content)]

  around withTempFile $
    describe "Migrations" $ do
      it "populate user column from flow_data" $ \tmp -> do
        copyFile "test.sqlite" tmp

        runDB tmp "." fakeLogger initLogStorage

        res <- SQLite.withConnection tmp $ \cnx ->
          SQLite.query_ cnx "select user from event_log;"

        head res `shouldBe` ["arnaud" :: String]

      it "adds existing file-based user profile to DB with uid" $ \tmp ->
        withTempDir $ \ dir -> do
          File.writeProfileFile defaultProfile dir

          runDB tmp dir fakeLogger initLogStorage

          rows <- SQLite.withConnection tmp $ \cnx ->
            SQLite.query_ cnx "select id,user,profile from users;"

          rows `shouldBe` [(1 :: Int, "arnaud" :: String, decodeUtf8 $ toStrict $ encode defaultProfile)]
