{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Sensei.WrapperSpec where

import Data.Functor
import qualified Data.Map as Map
import Preface.Codec
import Sensei.API
import Sensei.Client hiding (send)
import Sensei.TestHelper
import Sensei.WaiTestHelper
import Sensei.Wrapper
import System.Exit
import Test.Hspec

io :: WrapperIO (WaiSession (Encoded Hex))
io = WrapperIO{..}
  where
    runProcess _ _ = pure ExitSuccess
    currentTime = pure $ UTCTime (toEnum 50000) 0
    send = runRequest
    fileExists = const $ pure True

spec :: Spec
spec =
    withApp app $
        describe "Program wrapper" $ do
            it "records execution trace of wrapped program and returns program's exit code" $ do
                res <- wrapProg io "arnaud" "git" ["status"] "somedir"
                res `isExpectedToBe` ExitSuccess

            it "selects program to run from User Profile" $ do
                void $ send io $ setUserProfileC "arnaud" defaultProfile{userName = "arnaud", userCommands = Just $ Map.fromList [("foo", "/usr/bin/foo")]}
                res <- tryWrapProg io "arnaud" "foo" [] "somedir"
                res `isExpectedToBe` Right ExitSuccess

            it "return error when called with a non-mapped alias" $ do
                void $ send io $ setUserProfileC "arnaud" defaultProfile{userName = "arnaud", userCommands = Just $ Map.fromList [("foo", "/usr/bin/foo")]}
                res <- tryWrapProg io "arnaud" "bar" [] "somedir"
                res `isExpectedToBe` Left (UnMappedAlias "bar")

            it "return error when called with a mapped alias given executable does not exist" $ do
                let ioWithoutProg = io{fileExists = const $ pure False}
                void $ send io $ setUserProfileC "arnaud" defaultProfile{userName = "arnaud", userCommands = Just $ Map.fromList [("foo", "qwerty123123")]}
                res <- tryWrapProg ioWithoutProg "arnaud" "foo" [] "somedir"
                res `isExpectedToBe` Left (NonExistentAlias "foo" "qwerty123123")
