{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Consensus.Raft.State
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

module Control.Consensus.Raft.Log (
    -- * Raft state
    Raft(..),
    mkRaft,
    raftCurrentTerm,
    raftName,
    RaftContext(..),
    RaftLog(..),
    RaftLogEntry(..),
    RaftState(..),
    mkRaftState,
    setRaftTerm,
    setRaftLeader,
    isRaftLeader,
    setRaftLastCandidate,
    setRaftConfiguration,
    setRaftConfigurationIndex,
    raftConfiguration,
    raftMembers,
    raftSafeAppendedTerm,
    setRaftMembers,
    setRaftLog,
    setRaftState,

    module Control.Consensus.Raft.Actions,
    module Control.Consensus.Raft.Types,
    module Data.Log

) where

-- local imports

import Data.Log
import Control.Consensus.Raft.Actions
import Control.Consensus.Raft.Members
import Control.Consensus.Raft.Types

-- external imports

import Control.Concurrent.STM

import qualified Data.Map as M
import Data.Serialize

import Network.Endpoints

import System.Log.Logger

import Text.Printf

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

_log :: String
_log = "raft.consensus"

{-|
Encapsulates the state necessary for the Raft algorithm, depending
on a 'RaftServer' for customizing the use of the algorithm to a 
specific application.
-}
data RaftContext l e v = (RaftLog l e v) => RaftContext {
    raftEndpoint :: Endpoint,
    raftLog :: l,
    raftState :: RaftState v
}

data Raft l e v = (RaftLog l e v,Serialize v) => Raft {raftContext :: TVar (RaftContext l e v)}

mkRaft :: (RaftLog l e v) => Endpoint -> l -> RaftState v -> STM (Raft l e v)
mkRaft endpoint initialLog initialState = do
    ctx <- newTVar $ RaftContext {
        raftEndpoint = endpoint,
        raftLog = initialLog,
        raftState = initialState
    }
    return $ Raft ctx

{-|
A minimal 'Log' sufficient for a 'Server' to particpate in the Raft algorithm'.
-}
class (Serialize e,Serialize v,Log l IO (RaftLogEntry e) (RaftState v)) => RaftLog l e v where
    lastAppendedTime :: l -> RaftTime
    lastCommittedTime :: l -> RaftTime


data RaftState v = (Serialize v) => RaftState {
    raftStateCurrentTerm :: Term,
    raftStateLastCandidate :: Maybe Name,
    raftStateName :: Name,
    raftStateConfigurationIndex :: Maybe Index,
    raftStateConfiguration :: RaftConfiguration,
    raftStateMembers :: Members,
    raftStateData :: v
}

deriving instance (Eq v) => Eq (RaftState v)
deriving instance (Show v) => Show (RaftState v)

mkRaftState :: (Serialize v) => v -> RaftConfiguration -> Name -> RaftState v
mkRaftState initialData cfg name = RaftState {
    raftStateCurrentTerm = 0,
    raftStateLastCandidate = Nothing,
    raftStateName = name,
    raftStateConfigurationIndex = Nothing,
    raftStateConfiguration = cfg,
    raftStateMembers = mkMembers cfg initialRaftTime,
    raftStateData = initialData
}

data RaftLogEntry e = (Serialize e) => RaftLogEntry {
    entryTerm :: Term,
    entryAction :: RaftAction e
}

deriving instance (Eq e) => Eq (RaftLogEntry e)
deriving instance (Show e) => Show (RaftLogEntry e)

instance (Serialize e) => Serialize (RaftLogEntry e) where
    get = do
        term <- get
        action <- get
        return $ RaftLogEntry term action
    put (RaftLogEntry term action) = do
        put term
        put action

instance (Serialize e,State v IO e) => State (RaftState v) IO (RaftLogEntry e) where
    canApplyEntry oldRaftState entry = do
        let members = raftStateMembers oldRaftState
            cfg = raftStateConfiguration oldRaftState
            term = membersSafeAppendedTerm members $ clusterConfiguration cfg
            currentTerm = raftStateCurrentTerm oldRaftState
            leader = (Just $ raftStateName oldRaftState) == (clusterLeader $ clusterConfiguration cfg)
        infoM _log $ printf "%v: Safe term for members %v is %v" currentTerm (show $ M.map (logTerm . memberLogLastAppended) members) term
        if leader
                then if term /= raftStateCurrentTerm oldRaftState
                    then return False
                    else canApply $ entryAction entry
                else canApply $ entryAction entry
        where
            canApply (Cmd cmd) = do
                let oldData = raftStateData oldRaftState
                canApplyEntry oldData cmd
            -- TODO check configuration cases
            canApply _ = return True

    applyEntry oldRaftState entry = applyAction $ entryAction entry
        where
            applyAction (Cmd cmd) = do
                let oldData = raftStateData oldRaftState
                newData <- applyEntry oldData cmd
                return $ oldRaftState {raftStateData = newData}
            applyAction action = do
                let cfg = applyConfigurationAction (clusterConfiguration $ raftStateConfiguration oldRaftState) action
                infoM _log $ printf "New configuration is %v" (show cfg)
                return $ oldRaftState {
                    raftStateConfiguration = (raftStateConfiguration oldRaftState) {
                        clusterConfiguration = cfg
                    }
                }

raftCurrentTerm :: (RaftLog l e v) => RaftContext l e v -> Term
raftCurrentTerm raft = raftStateCurrentTerm $ raftState raft

raftName :: (RaftLog l e v) => RaftContext l e v -> Name
raftName raft = raftStateName $ raftState raft

{-|
Update the current term in a new 'RaftContext'
-}
setRaftTerm :: Term -> RaftContext l e v -> RaftContext l e v
setRaftTerm term raft = raft {
        raftState = (raftState raft) {
            raftStateCurrentTerm = term
            }
        }

{-|
Update the current term in a new 'RaftContext'
-}
setRaftMembers :: Members -> RaftContext l e v -> RaftContext l e v
setRaftMembers members raft = raft {
        raftState = (raftState raft) {
            raftStateMembers = members
            }
        }

raftMembers :: (RaftLog l e v) => RaftContext l e v -> Members
raftMembers raft = raftStateMembers $ raftState raft

raftSafeAppendedTerm :: (RaftLog l e v) => RaftContext l e v -> Term
raftSafeAppendedTerm raft = 
    let members = raftMembers raft
        cfg = raftConfiguration raft
        in membersSafeAppendedTerm members cfg

{-|
Update the last candidate in a new 'RaftContext'
-}
setRaftLastCandidate :: Maybe Name -> RaftContext l e v -> RaftContext l e v
setRaftLastCandidate candidate raft = raft {
                    raftState = (raftState raft) {
                        raftStateLastCandidate = candidate
                        }
                    }

{-|
Update the 'RaftState' in a new 'RaftContext' to specify a new leader
-}
setRaftLeader :: Maybe Name -> RaftContext l e v -> RaftContext l e v
setRaftLeader leader raft = 
    let cfg = clusterConfiguration $ raftStateConfiguration $ raftState raft
        in case cfg of
            Configuration _ _ _ -> raft {
                    raftState = (raftState raft) {
                        raftStateConfiguration = (raftStateConfiguration $ raftState raft) {
                            clusterConfiguration = cfg {
                            configurationLeader = leader
                        }}}
                }
            JointConfiguration _ jointNew -> raft {
                    raftState = (raftState raft) {
                        raftStateConfiguration = (raftStateConfiguration $ raftState raft) {
                            clusterConfiguration = jointNew {
                            configurationLeader = leader
                        }}}
                }

isRaftLeader :: (RaftLog l e v) => RaftContext l e v -> Bool
isRaftLeader raft = (Just $ raftName raft) == (clusterLeader $ raftConfiguration raft)

setRaftLog :: (RaftLog l e v) => l -> RaftContext l e v -> RaftContext l e v
setRaftLog rlog raft = raft {
        raftLog = rlog
        }

setRaftConfiguration :: (RaftLog l e v) => Configuration -> RaftContext l e v -> RaftContext l e v
setRaftConfiguration cfg raft =
    let newState = (raftState raft) {
        raftStateConfiguration = (raftStateConfiguration $ raftState raft) {
                            clusterConfiguration = cfg
        }}
        in setRaftState newState raft

raftConfiguration :: (RaftLog l e v) => RaftContext l e v -> Configuration 
raftConfiguration raft = clusterConfiguration $ raftStateConfiguration $ raftState raft

setRaftConfigurationIndex :: (RaftLog l e v) => Maybe Index -> RaftContext l e v -> RaftContext l e v
setRaftConfigurationIndex index raft =
    let newState = (raftState raft) {
        raftStateConfigurationIndex = index
        }
        in setRaftState newState raft

setRaftState :: (RaftLog l e v) => RaftState v -> RaftContext l e v -> RaftContext l e v
setRaftState state raft = raft {
        raftState = state
        }
