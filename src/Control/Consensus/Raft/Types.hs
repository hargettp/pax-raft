{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE StandaloneDeriving #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Consensus.Raft.Types
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

module Control.Consensus.Raft.Types (
    Action(..),
    Command,
    Configuration(..),
        newConfiguration,
        clusterLeader,
        clusterMembers,
        clusterMembersOnly,
    RaftServer,
    RaftLog,
    RaftLogEntry(..),
    RaftState(..),
    Server(..),
    ServerId,
    ServerState(..),
    Term,
    Timeout
) where

-- local imports

-- external imports

import qualified Data.ByteString as B
import qualified Data.List as L
import Data.Log
import Data.Serialize
import Data.Typeable

import GHC.Generics

import Network.Endpoints

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

type Term = Int

type ServerId = Name

{-|
Type used for timeouts.  Mostly used for code clarity.
-}
type Timeout = Int

{- |
A configuration identifies all the members of a cluster and the nature of their participation 
in the cluster.
-}
data Configuration = Configuration {
          configurationLeader :: Maybe ServerId,
          configurationParticipants :: [ServerId],
          configurationObservers :: [ServerId]
          }
          | JointConfiguration {
          jointOldConfiguration :: Configuration,
          jointNewConfiguration :: Configuration
          } deriving (Generic,Show,Typeable,Eq)

instance Serialize Configuration

newConfiguration :: [ServerId] -> Configuration
newConfiguration participants = Configuration {
    configurationLeader = Nothing,
    configurationParticipants = participants,
    configurationObservers = []
}

clusterLeader :: Configuration -> Maybe ServerId
clusterLeader Configuration {configurationLeader = leaderId} = leaderId
clusterLeader (JointConfiguration _ configuration) = clusterLeader configuration

clusterMembers :: Configuration -> [ServerId]
clusterMembers (Configuration _ participants observers) = participants ++ observers
clusterMembers (JointConfiguration jointOld jointNew) = (clusterMembers jointOld) ++ (clusterMembers jointNew)

clusterMembersOnly :: Configuration -> [ServerId]
clusterMembersOnly cfg = case clusterLeader cfg of
    Just ldr -> L.delete ldr (clusterMembers cfg)
    Nothing -> clusterMembers cfg

class (LogIO l RaftLogEntry (ServerState v)) => RaftLog l v

type RaftServer l v = Server l RaftLogEntry (ServerState v)

data RaftState l v = (RaftLog l v) => RaftState {
    raftCurrentTerm :: Term,
    raftLastCandidate :: Maybe ServerId,
    raftServer :: RaftServer l v
}

data RaftLogEntry =  RaftLogEntry {
    entryTerm :: Term,
    entryAction :: Action
} deriving (Eq,Show,Generic)

instance Serialize RaftLogEntry

type Command = B.ByteString

data Action = Cfg Configuration | Cmd Command
    deriving (Eq,Show,Generic)

instance Serialize Action

data Server l e v = (LogIO l e v) => Server {
    serverId :: ServerId,
    serverLog :: l,
    serverState :: v
}

data ServerState v = (Eq v,Show v) => ServerState {
    serverConfiguration :: Configuration,
    serverData :: v
}

deriving instance Eq (ServerState v)
deriving instance Show (ServerState v)