-----------------------------------------------------------------------------
-- |
-- Module      :  TestRaft
-- Copyright   :  (c) Phil Hargett 2014
-- License     :  MIT (see LICENSE file)
-- 
-- Maintainer  :  phil@haphazardhouse.net
-- Stability   :  experimental
-- Portability :  non-portable (requires STM)
--
-- (..... module description .....)
--
-----------------------------------------------------------------------------

module TestRaft (
    tests,
    troubleshoot
) where

-- local imports

import Control.Consensus.Raft
import Control.Consensus.Raft.Actions
import Control.Consensus.Raft.Log
import Control.Consensus.Raft.Members
import Control.Consensus.Raft.Protocol

import IntServer

-- external imports

import Prelude hiding (log)

import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception

import qualified Data.Map as M
import Data.Serialize

import Network.Endpoints
import Network.RPC
import Network.Transport.Memory

import System.Log.Logger

import Test.Framework
import Test.HUnit
import Test.Framework.Providers.HUnit

import Text.Printf

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

_log :: String
_log = "test.raft"

tests :: [Test.Framework.Test]
tests = [
    testCase "3cluster" test3Cluster,
    testCase "3cluster-1nonparticipant" test3Cluster1NonParticipant,
    testCase "3cluster-add1" test3ClusterAdd1,
    testCase "3cluster-stability" test3ClusterStability,
    testCase "3cluster-1nonparticipant-stability" test3Cluster1NonParticipantStability,
    testCase "5cluster" test5Cluster,
    testCase "5cluster-stability" test5ClusterStability,
    testCase "client" testClient,
    testCase "consistency" testConsistency,
    testCase "2consistency" test2Consistency,
    testCase "3consistency" test3Consistency,
    testCase "10consistency" test10Consistency,
    testCase "5cluster-10consistency" test5Cluster10Consistency,
    testCase "7cluster-10consistency" test7Cluster10Consistency,
    testCase "performAction" testPerformAction,
    testCase "goPerformAction" testGoPerformAction,
    testCase "clientPerformAction" testClientPerformAction,
    testCase "withClientPerformAction" testWithClientPerformAction
    ]

troubleshoot :: IO () -> IO ()
troubleshoot fn = do
    finally (do
        updateGlobalLogger rootLoggerName (setLevel INFO)
        fn) (updateGlobalLogger rootLoggerName (setLevel WARNING))

test3Cluster :: Assertion
test3Cluster = do
    transport <- newMemoryTransport
    let cfg = newTestConfiguration ["server1","server2","server3"]
    with3Servers  transport cfg $ \vRafts -> do
        leader <- waitForLeader 5 (1 :: Integer) vRafts
        leaders <- allLeaders vRafts
        infoM _log $ "Leaders are " ++ (show leaders)
        _ <- checkForConsistency (1 :: Integer) leader vRafts
        return ()

test3Cluster1NonParticipant :: Assertion
test3Cluster1NonParticipant = do
    transport <- newMemoryTransport
    let cfg = newTestConfiguration ["server1","server2","server3"]
    with3Servers1NonParticipant transport cfg "server4" $ \vRafts -> do
        let mRafts = take 3 vRafts
        leader <- waitForLeader 5 (1 :: Integer) mRafts
        leaders <- allLeaders mRafts
        infoM _log $ "Leaders are " ++ (show leaders)
        _ <- checkForConsistency (1 :: Integer) leader mRafts
        return ()

test3ClusterAdd1 :: Assertion
test3ClusterAdd1 = do
    transport <- newMemoryTransport
    let cfg = newTestConfiguration ["server1","server2","server3"]
    with3Servers1NonParticipant transport cfg "server4" $ \vRafts -> do
        let mRafts = take 3 vRafts
        leader <- waitForLeader 5 (1 :: Integer) mRafts
        leaders <- allLeaders mRafts
        infoM _log $ "Leaders are " ++ (show leaders)
        _ <- checkForConsistency (1 :: Integer) leader mRafts
        withClient transport "client1" cfg $ \client -> do
            RaftTime _ clientIndex <- performAction client $ AddParticipants ["server4"]
            assertBool (printf "Client index should be 0: %v" (show clientIndex)) $ clientIndex == 0
            _ <- waitForLeader 5 (2 :: Integer) vRafts
            newLeaders <- allLeaders vRafts
            infoM _log $ printf "New leaders are %v" (show newLeaders)
            newLastCommitted <- allLastCommitted vRafts
            infoM _log $ printf "Last committed indexes are %v" (show newLastCommitted)
            _ <- checkForConsistency (1 :: Integer) leader vRafts
            return ()

test3ClusterStability :: Assertion
test3ClusterStability = do
    transport <- newMemoryTransport
    let cfg = newTestConfiguration ["server1","server2","server3"]
    with3Servers  transport cfg $ \vRafts -> do
        firstLeader <- waitForLeader 5 (1 :: Integer) vRafts
        _ <- checkForConsistency (1 :: Integer) firstLeader vRafts
        pause >> pause
        _ <- checkForConsistency (2 :: Integer) firstLeader vRafts
        return ()

test3Cluster1NonParticipantStability :: Assertion
test3Cluster1NonParticipantStability = do
    transport <- newMemoryTransport
    let cfg = newTestConfiguration ["server1","server2","server3"]
    with3Servers1NonParticipant  transport cfg "server4" $ \vRafts -> do
        let mRafts = take 3 vRafts
        firstLeader <- waitForLeader 5 (1 :: Integer) mRafts
        _ <- checkForConsistency (1 :: Integer) firstLeader mRafts
        pause >> pause
        _ <- checkForConsistency (2 :: Integer) firstLeader mRafts
        return ()

test5Cluster :: Assertion
test5Cluster = do
    transport <- newMemoryTransport
    let cfg = newTestConfiguration ["server1","server2","server3","server4","server5"]
    with5Servers  transport cfg $ \vRafts -> do
        firstLeader <- waitForLeader 5 (1 :: Integer) vRafts
        _ <- checkForConsistency (1 :: Integer) firstLeader vRafts
        return ()

test5ClusterStability :: Assertion
test5ClusterStability = do
    transport <- newMemoryTransport
    let cfg = newTestConfiguration ["server1","server2","server3","server4","server5"]
    with5Servers  transport cfg $ \vRafts -> do
        firstLeader <- waitForLeader 5 (1 :: Integer) vRafts
        _ <- checkForConsistency (1 :: Integer) firstLeader vRafts
        pause >> pause >> pause
        _ <- checkForConsistency (2 :: Integer) firstLeader vRafts
        return ()

testClient :: Assertion
testClient = do
    transport <- newMemoryTransport
    let cfg = newTestConfiguration ["server1","server2","server3"]
    with3Servers  transport cfg $ \vRafts -> do
        pause
        errOrResult <- race (do 
                _ <- waitForLeader 5 (1 :: Integer) vRafts
                threadDelay $ 30 * 1000 * 1000
                return ())
            (withClient transport "client1" cfg $ \client -> do
                                _ <- waitForLeader 5 (1 :: Integer) vRafts
                                performAction client $ Cmd $ encode $ Add 1)
        case errOrResult of
            Right clientResult -> do
                let RaftTime _ clientIndex = clientResult
                assertBool "Client index should be 0" $ clientIndex == 0
            Left _ -> do
                assertBool "Performing action failed" False

testConsistency :: Assertion
testConsistency = do
    transport <- newMemoryTransport
    let cfg = newTestConfiguration ["server1","server2","server3"]
    with3Servers  transport cfg $ \vRafts -> do
        pause
        errOrResult <- race (do 
                _ <- waitForLeader 5 (1 :: Integer) vRafts
                threadDelay $ 30 * 1000 * 1000
                return ())
            (withClient transport "client1" cfg $ \client -> do
                                _ <- waitForLeader 5 (1 :: Integer) vRafts
                                RaftTime _ clientIndex <- performAction client $ Cmd $ encode $ Add 1
                                assertBool (printf "Client index should be 0: %v" (show clientIndex)) $ clientIndex == 0
                                -- pause -- have to wait for synchronization to occur
                                threadDelay $ 2 * 1000 * 1000
                                states <- allStates vRafts
                                assertBool "" $ all (== (IntState 1)) states
                                checkForConsistency_ vRafts)
        case errOrResult of
            Right _ -> assertBool "" True
            Left _ -> assertBool "Performing action failed" False

test2Consistency :: Assertion
test2Consistency = do
    transport <- newMemoryTransport
    let cfg = newTestConfiguration ["server1","server2","server3"]
    with3Servers  transport cfg $ \vRafts -> do
        pause
        errOrResult <- race (do 
                _ <- waitForLeader 5 (1 :: Integer) vRafts
                threadDelay $ 30 * 1000 * 1000
                return ())
            (withClient transport "client1" cfg $ \client -> do
                                _ <- waitForLeader 5 (1 :: Integer) vRafts
                                _ <- performAction client $ Cmd $ encode $ Add 3
                                RaftTime _ clientIndex <- performAction client $ Cmd $ encode $ Multiply 5
                                assertBool  (printf "Client index should be 1: %v" (show clientIndex)) $ clientIndex == 1
                                -- pause -- have to wait for synchronization to occur
                                threadDelay $ 2 * 1000 * 1000
                                states <- allStates vRafts
                                assertBool "" $ all (== (IntState 15)) states
                                checkForConsistency_ vRafts)
        case errOrResult of
            Right _ -> assertBool "" True
            Left _ -> assertBool "Performing action failed" False

test3Consistency :: Assertion
test3Consistency = do
    transport <- newMemoryTransport
    let cfg = newTestConfiguration ["server1","server2","server3"]
    with3Servers  transport cfg $ \vRafts -> do
        pause
        errOrResult <- race (do 
                _ <- waitForLeader 5 (1 :: Integer) vRafts
                threadDelay $ 30 * 1000 * 1000
                return ())
            (withClient transport "client1" cfg $ \client -> do
                                _ <- waitForLeader 5 (1 :: Integer) vRafts
                                _ <- performAction client $ Cmd $ encode $ Add 3
                                _ <- performAction client $ Cmd $ encode $ Multiply 5
                                RaftTime _ clientIndex <- performAction client $ Cmd $ encode $ Subtract 2
                                assertBool  (printf "Client index should be 2: %v" (show clientIndex)) $ clientIndex == 2
                                -- pause -- have to wait for synchronization to occur
                                threadDelay $ 2 * 1000 * 1000
                                states <- allStates vRafts
                                assertBool "" $ all (== (IntState 13)) states
                                checkForConsistency_ vRafts)
        case errOrResult of
            Right _ -> assertBool "" True
            Left _ -> assertBool "Performing action failed" False

test10Consistency :: Assertion
test10Consistency = do
    transport <- newMemoryTransport
    let cfg = newTestConfiguration ["server1","server2","server3"]
    with3Servers  transport cfg $ \vRafts -> do
        pause
        errOrResult <- race (do 
                _ <- waitForLeader 5 (1 :: Integer) vRafts
                threadDelay $ 30 * 1000 * 1000
                return ())
            (withClient transport "client1" cfg $ \client -> do
                                _ <- waitForLeader 5 (1 :: Integer) vRafts
                                _ <- performAction client $ Cmd $ encode $ Add 3
                                _ <- performAction client $ Cmd $ encode $ Multiply 5
                                _ <- performAction client $ Cmd $ encode $ Subtract 2
                                _ <- performAction client $ Cmd $ encode $ Add 3
                                _ <- performAction client $ Cmd $ encode $ Multiply 5
                                _ <- performAction client $ Cmd $ encode $ Subtract 2
                                _ <- performAction client $ Cmd $ encode $ Add 3
                                _ <- performAction client $ Cmd $ encode $ Multiply 5
                                _ <- performAction client $ Cmd $ encode $ Subtract 2
                                RaftTime _ clientIndex <- performAction client $ Cmd $ encode $ Add 3
                                assertBool  (printf "Client index should be 9: %v" (show clientIndex)) $ clientIndex == 9
                                -- pause -- have to wait for synchronization to occur
                                threadDelay $ 2 * 1000 * 1000
                                states <- allStates vRafts
                                assertBool "" $ all (== (IntState 406)) states
                                checkForConsistency_ vRafts)
        case errOrResult of
            Right _ -> assertBool "" True
            Left _ -> assertBool "Performing action failed" False

test5Cluster10Consistency :: Assertion
test5Cluster10Consistency = do
    transport <- newMemoryTransport
    let cfg = newTestConfiguration ["server1","server2","server3","server4","server5"]
    with5Servers  transport cfg $ \vRafts -> do
        pause
        errOrResult <- race (do 
                _ <- waitForLeader 5 (1 :: Integer) vRafts
                threadDelay $ 30 * 1000 * 1000
                return ())
            (withClient transport "client1" cfg $ \client -> do
                                _ <- waitForLeader 5 (1 :: Integer) vRafts
                                _ <- performAction client $ Cmd $ encode $ Add 3
                                _ <- performAction client $ Cmd $ encode $ Multiply 5
                                _ <- performAction client $ Cmd $ encode $ Subtract 2
                                _ <- performAction client $ Cmd $ encode $ Add 3
                                _ <- performAction client $ Cmd $ encode $ Multiply 5
                                _ <- performAction client $ Cmd $ encode $ Subtract 2
                                _ <- performAction client $ Cmd $ encode $ Add 3
                                _ <- performAction client $ Cmd $ encode $ Multiply 5
                                _ <- performAction client $ Cmd $ encode $ Subtract 2
                                RaftTime _ clientIndex <- performAction client $ Cmd $ encode $ Add 3
                                assertBool  (printf "Client index should be 9: %v" (show clientIndex)) $ clientIndex == 9
                                -- pause -- have to wait for synchronization to occur
                                threadDelay $ 2 * 1000 * 1000
                                states <- allStates vRafts
                                assertBool "" $ all (== (IntState 406)) states
                                checkForConsistency_ vRafts)
        case errOrResult of
            Right _ -> assertBool "" True
            Left _ -> assertBool "Performing action failed" False

test7Cluster10Consistency :: Assertion
test7Cluster10Consistency = do
    transport <- newMemoryTransport
    let cfg = newTestConfiguration ["server1","server2","server3","server4","server5","server6","server7"]
    with7Servers  transport cfg $ \vRafts -> do
        pause
        errOrResult <- race (do 
                _ <- waitForLeader 10 (1 :: Integer) vRafts
                threadDelay $ 30 * 1000 * 1000
                return ())
            (withClient transport "client1" cfg $ \client -> do
                                _ <- waitForLeader 10 (1 :: Integer) vRafts
                                _ <- performAction client $ Cmd $ encode $ Add 3
                                _ <- performAction client $ Cmd $ encode $ Multiply 5
                                _ <- performAction client $ Cmd $ encode $ Subtract 2
                                _ <- performAction client $ Cmd $ encode $ Add 3
                                _ <- performAction client $ Cmd $ encode $ Multiply 5
                                _ <- performAction client $ Cmd $ encode $ Subtract 2
                                _ <- performAction client $ Cmd $ encode $ Add 3
                                _ <- performAction client $ Cmd $ encode $ Multiply 5
                                _ <- performAction client $ Cmd $ encode $ Subtract 2
                                RaftTime _ clientIndex <- performAction client $ Cmd $ encode $ Add 3
                                assertBool  (printf "Client index should be 9: %v" (show clientIndex)) $ clientIndex == 9
                                -- pause -- have to wait for synchronization to occur
                                threadDelay $ 2 * 1000 * 1000
                                states <- allStates vRafts
                                assertBool "" $ all (== (IntState 406)) states
                                checkForConsistency_ vRafts)
        case errOrResult of
            Right _ -> assertBool "" True
            Left _ -> assertBool "Performing action failed" False

testPerformAction :: Assertion
testPerformAction = do
    let client = "client1"
        server = "server1"
    transport <- newMemoryTransport
    _ <- async $ do
        endpoint <- newEndpoint [transport]
        bindEndpoint_ endpoint server
        onPerformAction endpoint server $ \_ reply -> do
            reply MemberResult {
                memberActionSuccess = True,
                memberLeader = Nothing,
                memberCurrentTerm = 0,
                memberLastAppended = RaftTime 0 0,
                memberLastCommitted = RaftTime 0 0
                }
    endpoint <- newEndpoint [transport]
    bindEndpoint_ endpoint client
    let cs = newCallSite endpoint client
        action = Cmd $ encode $ Add 1
        outs = defaultTimeouts
    Just msg <- callWithTimeout cs server "performAction" (timeoutRpc outs) $ encode action
    let Right result = decode msg
    assertBool "Result should be true" $ memberActionSuccess result

testGoPerformAction :: Assertion
testGoPerformAction = do
    let client = "client1"
        server = "server1"
    transport <- newMemoryTransport
    _ <- async $ do
        endpoint <- newEndpoint [transport]
        bindEndpoint_ endpoint server
        onPerformAction endpoint server $ \_ reply -> do
            infoM _log $ "Returning result"
            reply MemberResult {
                memberActionSuccess = True,
                memberLeader = Nothing,
                memberCurrentTerm = 0,
                memberLastAppended = RaftTime 0 0,
                memberLastCommitted = RaftTime 0 0
                }
    -- we have to wait a bit for server to start
    pause
    endpoint <- newEndpoint [transport]
    bindEndpoint_ endpoint client
    let cs = newCallSite endpoint client
        action = Cmd $ encode $ Add 1
        cfg = (newTestConfiguration [server]) {configurationLeader = Just server}
    response <- goPerformAction cs cfg server action
    case response of
        Just result -> assertBool "Result should be true" $ memberActionSuccess result
        Nothing -> assertBool "No response" False

testClientPerformAction :: Assertion
testClientPerformAction = do
    let client = "client1"
        server = "server1"
        cfg = newTestConfiguration [server]
    transport <- newMemoryTransport
    _ <- async $ do
        endpoint <- newEndpoint [transport]
        bindEndpoint_ endpoint server
        onPerformAction endpoint server $ \_ reply -> do
            reply MemberResult {
                memberActionSuccess = True,
                memberLeader = Nothing,
                memberCurrentTerm = 1,
                memberLastAppended = RaftTime 1 1,
                memberLastCommitted = RaftTime 1 1
                }
    endpoint <- newEndpoint [transport]
    bindEndpoint_ endpoint client
    let raftClient = newClient endpoint client cfg
    let action = Cmd $ encode $ Add 1
    result <- performAction raftClient action
    assertBool "Result should be true" $ result == RaftTime 1 1

testWithClientPerformAction :: Assertion
testWithClientPerformAction = do
    let client = "client1"
        server = "server1"
        cfg = newTestConfiguration [server]
    transport <- newMemoryTransport
    _ <- async $ do
        endpoint <- newEndpoint [transport]
        bindEndpoint_ endpoint server
        onPerformAction endpoint server $ \_ reply -> do
            reply MemberResult {
                memberActionSuccess = True,
                memberLeader = Nothing,
                memberCurrentTerm = 1,
                memberLastAppended = RaftTime 1 1,
                memberLastCommitted = RaftTime 1 1
                }
    endpoint <- newEndpoint [transport]
    bindEndpoint_ endpoint client
    let action = Cmd $ encode $ Add 1
    result <- withClient transport client cfg $ \raftClient -> do
        pause
        performAction raftClient action
    assertBool "Result should be true" $ result == RaftTime 1 1

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

checkForConsistency_ :: [Raft IntLog IntState] -> IO (Maybe Name)
checkForConsistency_ rafts = checkForConsistency 1 Nothing rafts

checkForConsistency :: Integer -> Maybe Name -> [Raft IntLog IntState] -> IO (Maybe Name)
checkForConsistency run possibleLeader vRafts = do
    rafts <- mapM (\vRaft -> atomically $ readTVar $ raftContext vRaft) vRafts
    let leaders = map (clusterLeader . raftStateConfiguration . raftState) rafts
        results = map (raftStateData . raftState) rafts
        indexes = map (lastCommitted . raftLog) rafts
    assertBool (printf "%d: Most results should be equal" (show run)) $ hasCommon results
    assertBool (printf "%d: Most log indexes should be equal" (show run)) $ hasCommon indexes
    assertBool (printf "%d: Most members should have same leader: %s" (show run) (show leaders)) $ hasCommon leaders
    assertBool (printf "%d: There must be a leader %s" (show run) (show leaders)) $ all (/= Nothing) leaders
    let leader = (leaders !! 0)
    case possibleLeader of
        Just _ -> if all (== possibleLeader) leaders
                            then return leader
                            else return Nothing
        Nothing -> if all (== leader) leaders
                        then return leader
                        else return Nothing

waitForLeader :: Integer -> Integer -> [Raft IntLog IntState] -> IO (Maybe Name)
waitForLeader maxCount attempt vRafts = do
    leaders <- allLeaders vRafts
    let leader = leaders !! 0
    if maxCount <= 0
        then do
            assertBool ("No leader found after " ++ (show (attempt - 1)) ++ " rounds: " ++ (show leaders)) False
            return Nothing
        else do
            pause
            if (leader /= Nothing) && (all (== leader) leaders)
                then do
                    let msg = "After " ++ (show attempt) ++ " rounds, the leader is " ++ (show leader)
                    if attempt > 3
                        then warningM _log msg
                        else infoM _log msg
                    return leader
                else
                    waitForLeader (maxCount - 1) (attempt + 1) vRafts

allLeaders :: [Raft IntLog IntState] -> IO [Maybe Name]
allLeaders vRafts = do
    rafts <- mapM (\vRaft -> atomically $ readTVar $ raftContext vRaft) vRafts
    let leaders = map (clusterLeader . raftStateConfiguration . raftState) rafts
    return leaders

allStates :: [Raft IntLog IntState] -> IO [IntState]
allStates vRafts = do
    rafts <- mapM (\vRaft -> atomically $ readTVar $ raftContext vRaft) vRafts
    let states = map (raftStateData . raftState) rafts
    return states

allLastCommitted :: [Raft IntLog IntState] -> IO [Index]
allLastCommitted vRafts = do
    rafts <- mapM (\vRaft -> atomically $ readTVar $ raftContext vRaft) vRafts
    let committed = map (lastCommitted . raftLog) rafts
    return committed

withClient :: Transport -> Name -> Configuration -> (Client -> IO a) -> IO a
withClient transport name cfg fn = do
    endpoint <- newEndpoint [transport]
    bindEndpoint_ endpoint name
    let client = newClient endpoint name cfg
    fn client

hasCommon :: (Eq a,Ord a) => [a] -> Bool
hasCommon values = let (_,count) = common values
                       majority = 1 + ((length values ) `quot` 2)
                      in count >= majority 

common :: (Eq a,Ord a) => [a] -> (a,Int)
common values = classify values M.empty
    where
        classify [] classified = mostCommon $ M.toList classified
        classify (value:rest) classified  = classify rest (tally value classified)
        mostCommon [] = error "No common values!"
        mostCommon (pair:[]) = pair
        mostCommon (pair:rest) = let (value,count) = pair
                                     (highestValue,highestCount) = mostCommon rest
                                    in if count > highestCount 
                                        then (value,count)
                                        else (highestValue,highestCount)
        tally value classified = case M.lookup value classified of
            Just count -> M.insert value (count + 1) classified
            Nothing -> M.insert value 1 classified

newTestConfiguration :: [Name] -> Configuration
newTestConfiguration members = (mkConfiguration members) {configurationTimeouts = testTimeouts}

pause :: IO ()
pause = threadDelay serverTimeout

testTimeouts :: Timeouts
testTimeouts = timeouts (25 * 1000)

-- We need this to be high enough that members
-- can complete their election processing (that's the longest timeout we have)
-- before the test itself completes--otherwise we occasionally get spurious
-- failures, as a member is still electing when the test ends, resulting
-- in test failures, because not all members have agreed on the same leader
serverTimeout :: Timeout
serverTimeout = 2 * (snd $ timeoutElectionRange testTimeouts)

{-|
Utility for running a server only for a defined period of time
-}
withServer :: Transport -> Configuration -> Name -> (IntRaft -> IO ()) -> IO ()
withServer transport cfg name fn = do
    endpoint <- newEndpoint [transport]
    bindEndpoint_ endpoint name
    initialLog <- mkIntLog
    let initialState = mkRaftState (IntState 0) cfg name
    finally (withConsensus endpoint name initialLog initialState fn)
        (unbindEndpoint_ endpoint name)

with3Servers :: Transport -> Configuration -> ([IntRaft] -> IO ()) -> IO ()
with3Servers transport cfg fn = 
    let names = clusterMembers cfg
    in withServer transport cfg (names !! 0) $ \vRaft1 ->
        withServer transport cfg (names !! 1) $ \vRaft2 ->
        withServer transport cfg (names !! 2) $ \vRaft3 -> fn $ [vRaft1,vRaft2,vRaft3]

with3Servers1NonParticipant :: Transport -> Configuration -> Name -> ([IntRaft] -> IO ()) -> IO ()
with3Servers1NonParticipant transport cfg name fn = 
    let names = clusterMembers cfg
    in withServer transport cfg (names !! 0) $ \vRaft1 ->
        withServer transport cfg (names !! 1) $ \vRaft2 ->
        withServer transport cfg (names !! 2) $ \vRaft3 -> 
        withServer transport cfg name $ \vRaft4 -> fn $ [vRaft1, vRaft2, vRaft3, vRaft4]

with5Servers :: Transport -> Configuration -> ([IntRaft] -> IO ()) -> IO ()
with5Servers transport cfg fn = 
    let names = clusterMembers cfg
    in withServer transport cfg (names !! 0) $ \vRaft1 ->
        withServer transport cfg (names !! 1) $ \vRaft2 ->
        withServer transport cfg (names !! 2) $ \vRaft3 ->
        withServer transport cfg (names !! 3) $ \vRaft4 ->
        withServer transport cfg (names !! 4) $ \vRaft5 -> fn $ [vRaft1] ++ [vRaft2] ++ [vRaft3] ++ [vRaft4] ++ [vRaft5]

with7Servers :: Transport -> Configuration -> ([IntRaft] -> IO ()) -> IO ()
with7Servers transport cfg fn = 
    let names = clusterMembers cfg
    in withServer transport cfg (names !! 0) $ \vRaft1 ->
        withServer transport cfg (names !! 1) $ \vRaft2 ->
        withServer transport cfg (names !! 2) $ \vRaft3 ->
        withServer transport cfg (names !! 3) $ \vRaft4 ->
        withServer transport cfg (names !! 4) $ \vRaft5 ->
        withServer transport cfg (names !! 5) $ \vRaft6 ->
        withServer transport cfg (names !! 6) $ \vRaft7 -> fn $ [vRaft1] ++ [vRaft2] ++ [vRaft3] ++ [vRaft4] ++ [vRaft5] ++ [vRaft6] ++ [vRaft7]
