-----------------------------------------------------------------------------
-- |
-- Module      :  TestLog
-- Copyright   :  (c) Phil Hargett 2014
-- License     :  MIT (see LICENSE file)
-- 
-- Maintainer  :  phil@haphazardhouse.net
-- Stability   :  experimental
-- Portability :  non-portable (requires STM)
--
-- Unit tests for basic 'Log' typeclass.
--
-----------------------------------------------------------------------------

module TestLog (
    tests
) where

-- local imports

import NumberServer

-- external imports

import Data.Log

import Prelude hiding (log)

import Test.Framework
import Test.HUnit
import Test.Framework.Providers.HUnit

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

tests :: [Test.Framework.Test]
tests = [
    testCase "new-log" testNewLog,
    testCase "empty-log" testEmptyLog,
    testCase "single-action" testSingleAction,
    testCase "double-action" testDoubleAction
    ]

testNewLog :: Assertion
testNewLog = do
    _ <- newLog :: IO NumberLog
    return ()

testEmptyLog :: Assertion
testEmptyLog = do
    log <- newLog :: IO NumberLog
    let val = 0 :: Int
    (_,chg) <- commitEntries log 0 val
    assertEqual "Empty log should leave value unchanged" val chg

testSingleAction :: Assertion
testSingleAction = do
    log <- newLog :: IO NumberLog
    log1 <- appendEntries log 0 [NumberLogEntry (+ 2)]
    let val = 1 :: Int
    entries <- fetchEntries log1 0 1
    let lastIndex = lastAppended log1
    assertEqual "Log index should be 0" 0 lastIndex
    assertBool "Log should not be empty" (not $ null entries)
    (log2,chg) <- commitEntries log1 0 val
    assertEqual "Committing simple log did not match expected value" 3 chg
    let committedIndex = lastCommitted log2
    assertEqual "Committed index sould be equal to lastIndex" lastIndex committedIndex

testDoubleAction :: Assertion
testDoubleAction = do
    log <- newLog :: IO NumberLog
    log1 <- appendEntries log 0 [NumberLogEntry (+ 2),NumberLogEntry ( * 5)]
    let val = 1
    entries <- fetchEntries log1 0 2
    assertBool "Log should not be empty" (not $ null entries)
    assertEqual "Length incorrect" 2 (length entries)
    let lastIndex = lastAppended log1
    assertEqual "Appended index incorrect" 1 lastIndex
    (log2,chg) <- commitEntries log1 1 val
    assertEqual "Committing simple log did not match expected value" 15 chg
    let committedIndex = lastCommitted log2
    assertEqual "Committed index sould be equal to lastIndex" lastIndex committedIndex
