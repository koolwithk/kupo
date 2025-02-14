-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE PatternSynonyms #-}

module Test.Kupo.Data.CardanoSpec
    ( spec
    ) where

import Kupo.Prelude

import Kupo.Data.Cardano
    ( Blake2b_224
    , pattern GenesisPoint
    , datumHashFromText
    , datumHashToText
    , digest
    , hashScript
    , headerHashFromText
    , pointFromText
    , scriptFromBytes
    , scriptHashFromBytes
    , scriptHashFromText
    , scriptHashToBytes
    , scriptHashToText
    , scriptToBytes
    , slotNoFromText
    , slotNoToText
    , unsafeScriptHashFromBytes
    )
import Test.Hspec
    ( Spec, context, parallel, shouldBe, specify )
import Test.Hspec.QuickCheck
    ( prop )
import Test.Kupo.Data.Generators
    ( genDatumHash, genScript, genScriptHash, genSlotNo )
import Test.QuickCheck
    ( Gen, arbitrary, forAll, property, vectorOf, (===) )

import qualified Data.ByteString as BS

spec :: Spec
spec = parallel $ do
    context "pointFromText" $ do
        specify "origin" $ do
            pointFromText "origin" `shouldBe` Just GenesisPoint

        prop "{slotNo}.{blockHeaderHash}" $
            forAll genSlotNo $ \s ->
                forAll (genBytes 32) $ \bytes ->
                    let txt = slotNoToText s <> "." <> encodeBase16 bytes
                     in case pointFromText txt of
                            Just{}  -> property True
                            Nothing -> property False

    context "SlotNo" $ do
        prop "forall (s :: SlotNo). slotNoFromText (slotNoToText s) === Just{}" $
            forAll genSlotNo $ \s ->
                slotNoFromText (slotNoToText s) === Just s

    context "DatumHash" $ do
        prop "forall (x :: DatumHash). datumHashFromText (datumHashToText x) === x" $
            forAll genDatumHash $ \x ->
                datumHashFromText (datumHashToText x) === Just x

    context "Script" $ do
        prop "forall (x :: Script). scriptFromBytes (scriptToBytes x) === x" $
            forAll genScript $ \x ->
                scriptFromBytes (scriptToBytes x) === Just x
        prop "forall (x :: Script). digest @Blake2b_224 x === hashScript x" $
            forAll genScript $ \x ->
                unsafeScriptHashFromBytes (digest (Proxy @Blake2b_224) (scriptToBytes x))
                    === hashScript x

    context "ScriptHash" $ do
        prop "forall (x :: ScriptHash). scriptHashFromBytes (scriptHashToBytes x) === x" $
            forAll genScriptHash $ \x ->
                scriptHashFromBytes (scriptHashToBytes x) === Just x
        prop "forall (x :: ScriptHash). scriptFromText (scriptToText x) === x" $
            forAll genScriptHash $ \x ->
                scriptHashFromText (scriptHashToText x) === Just x

    context "headerHashFromText" $ do
        prop "forall (bs :: ByteString). bs .size 32 => headerHashFromText (base16 bs) === Just{}" $
            forAll (genBytes 32) $ \bytes ->
                case headerHashFromText (encodeBase16 bytes) of
                    Just{}  -> property True
                    Nothing -> property False

--
-- Generators
--

genBytes :: Int -> Gen ByteString
genBytes n =
    BS.pack <$> vectorOf n arbitrary
