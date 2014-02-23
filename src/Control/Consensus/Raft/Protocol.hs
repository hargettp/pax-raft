{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Consensus.Raft.Protocol
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

module Control.Consensus.Raft.Protocol (

    -- * Basic message types
    AppendEntries(..),

    RequestVote(..),

    MemberResult(..),
    createResult,

    -- * Client call
    goPerformAction,

    -- * Leader calls
    goAppendEntries,
    goRequestVote,
    onPerformAction,

    -- * Member handlers
    onAppendEntries,
    onRequestVote,

    -- * Timeouts
    electionTimeout,
    heartbeatTimeout,
    pulseTimeout,
    rpcTimeout

) where

-- local imports

import Control.Consensus.Raft.Types
import Data.Log

-- external imports

import qualified Data.Map as M
import Data.Serialize

import GHC.Generics

import Network.Endpoints
import Network.RPC

import qualified System.Random as R

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

data AppendEntries =  AppendEntries {
    aeLeader :: ServerId,
    aeLeaderTerm :: Term,
    aePreviousIndex :: Index,
    aePreviousTerm :: Term,
    aeCommittedIndex :: Index,
    aeEntries :: [RaftLogEntry]
} deriving (Eq,Show,Generic)

instance Serialize AppendEntries

data RequestVote = RequestVote {
        rvCandidate :: ServerId,
        rvCandidateTerm :: Term,
        rvCandidateLastEntryIndex :: Index,
        rvCandidateLastEntryTerm :: Term
} deriving (Eq,Show,Generic)

instance Serialize RequestVote

data MemberResult = MemberResult {
    memberActionSuccess :: Bool,
    memberLeader :: Maybe ServerId,
    memberCurrentTerm :: Term,
    memberLastAppended :: Index,
    memberLastCommitted :: Index
} deriving (Eq,Show,Generic)

instance Serialize MemberResult

createResult :: (RaftLog l v) => Bool -> RaftState l v -> MemberResult
createResult success raft = MemberResult {
    memberActionSuccess = success,
    memberLeader = clusterLeader $ serverConfiguration $ serverState $ raftServer raft,
    memberCurrentTerm = raftCurrentTerm raft,
    memberLastAppended = lastAppended $ serverLog $ raftServer raft,
    memberLastCommitted = lastCommitted $ serverLog $ raftServer raft
}

methodAppendEntries :: String
methodAppendEntries = "appendEntries"

goAppendEntries :: CallSite
            -> Name                     -- ^^ Member that is target of the call
            -> ServerId                 -- ^^ Leader
            -> Term                     -- ^^ Leader's current term
            -> Index                    -- ^^ Log index of entry just prior to the entries being appended
            -> Term                     -- ^^ Term of entry just priot to the entries being appended
            -> Index                    -- ^^ Last index up to which all entries are committed on leader
            -> [RaftLogEntry]    -- ^^ Entries to append
            -> IO (Maybe MemberResult)
goAppendEntries cs member leader term prevLogIndex prevTerm commitIndex entries = do
    response <- callWithTimeout cs member methodAppendEntries rpcTimeout
        $ encode $ AppendEntries leader term prevLogIndex prevTerm commitIndex entries
    case response of
        Just bytes -> let Right results = decode bytes
                      in return $ Just results
        _ -> return Nothing

methodRequestVote :: String
methodRequestVote = "requestVote"

goRequestVote :: CallSite -> [Name]
                -> Term     -- ^^ Candidate's term
                -> ServerId -- ^^ Candidate's id
                -> Index    -- ^^ Index of candidate's last entry
                -> Term     -- ^^ Term of candidate's last entry
                -> IO (M.Map Name (Maybe MemberResult))
goRequestVote cs members term candidate lastIndex lastTerm = do
    results <- gcallWithTimeout cs members methodRequestVote rpcTimeout
        $ encode $ RequestVote candidate term lastIndex lastTerm
    return $ mapResults results
    where
        mapResults results = M.map (\msg ->
            case msg of
                Just bytes -> let Right result = decode bytes in Just result
                _ -> Nothing) results

methodPerformAction :: String
methodPerformAction = "performAction"

goPerformAction :: CallSite
                    -> ServerId
                    -> Action
                    -> IO (Either (Maybe ServerId) Index)
goPerformAction cs member cmd = do
    index <- call cs member methodPerformAction $ encode cmd
    return index

{-|
Wait for an 'AppendEntries' RPC to arrive, until 'rpcTimeout' expires. If one arrives,
process it, and return @True@.  If none arrives before the timeout, then return @False@.
-}
onAppendEntries :: Endpoint -> ServerId -> (AppendEntries -> IO MemberResult) -> IO (Index,Bool)
onAppendEntries endpoint server fn = do
    msg <- hearTimeout endpoint server methodAppendEntries heartbeatTimeout
    case msg of
        Just (bytes,reply) -> do
            let Right req = decode bytes
            result <- fn req
            reply $ encode result
            return (aeCommittedIndex req,True)
        Nothing -> return (0,False)

{-|
Wait for an 'RequestVote' RPC to arrive, and process it when it arrives.
-}
onRequestVote :: Endpoint -> ServerId -> (RequestVote -> IO MemberResult) -> IO ()
onRequestVote endpoint server fn = do
    (bytes,reply) <- hear endpoint server methodRequestVote
    let Right req = decode bytes
    result <- fn req
    reply $ encode result
    return ()

{-|
Wait for a request from a client to perform an action, and process it when it arrives.
-}
onPerformAction :: Endpoint -> ServerId -> (Action -> IO MemberResult) -> IO ()
onPerformAction endpoint leader fn = do
    (bytes,reply) <- hear endpoint leader methodPerformAction
    let Right cmd = decode bytes
    response <- fn cmd
    reply $ encode response
    return ()

--------------------------------------------------------------------------------
-- Timeouts
--------------------------------------------------------------------------------

{-|
Expected delay (in microseconds) for group rpc's to complete
-}
rpcTimeout :: Timeout
rpcTimeout = (50 * 1000)

{-|
Expected delay (in microseconds) between heartbeats
-}
heartbeatTimeout :: Timeout
heartbeatTimeout = (4 * rpcTimeout)

{-|
Maximum delay leader waits for a new message to process before
preparing heartbeat
-}
pulseTimeout :: Timeout
pulseTimeout = (3 * rpcTimeout)

{-|
Range for choosing an election timeout
-}
electionTimeoutRange :: (Timeout,Timeout)
electionTimeoutRange = (2 * heartbeatTimeout, 4 * heartbeatTimeout)

{-|
Return a new election timeout
-}
electionTimeout :: IO Timeout
electionTimeout = R.randomRIO electionTimeoutRange