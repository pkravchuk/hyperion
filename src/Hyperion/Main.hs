{-# LANGUAGE ApplicativeDo       #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Hyperion.Main where

import           Control.Concurrent        (forkIO, killThread)
import           Control.Concurrent.MVar   (newMVar, readMVar)
import           Control.Monad             (unless)
import           Data.Maybe                (isJust)
import           Hyperion.Cluster          (Cluster, ClusterEnv (..),
                                            ProgramInfo (..), runCluster,
                                            runDBWithProgramInfo)
import           Hyperion.Command          (Worker (..), workerOpts)
import           Hyperion.Config           (HyperionConfig (..), newClusterEnv)
import qualified Hyperion.Database         as DB
import           Hyperion.HoldServer       (runHoldServer)
import qualified Hyperion.Log              as Log
import           Hyperion.Remote           (addressToNodeId,
                                            runProcessLocallyDefault, worker)
import           Options.Applicative
import           System.Console.Concurrent (withConcurrentOutput)
import           System.Directory          (removeFile)
import           System.Environment        (getEnvironment)
import           System.FilePath.Posix     ((</>))
import           System.Posix.Process      (getProcessID)

-- | The type for command-line options to 'hyperionMain'. Here @a@ is the type for program-specific options.
-- In practice we want @a@ to be an instance of 'Show'
data HyperionOpts a = 
    HyperionMaster a      -- ^ Constructor for the case of a master process, holds program-specific options
  | HyperionWorker Worker -- ^ Constructor for the case of a worker process, holds 'Worker' which is parsed
                          -- by 'workerOpts'


-- | Main command-line option parser for 'hyperionMain'. 
-- Returns a 'Parser' that supports commands "worker" and "master",
-- and uses 'workerOpts' or the supplied parser, respectively, to parse the remaining options
hyperionOpts 
  :: Parser a -- ^ 'Parser' for program-specific options
  -> Parser (HyperionOpts a)
hyperionOpts programOpts = subparser $ mconcat
  [ command "worker" $
    info (helper <*> (HyperionWorker <$> workerOpts)) $
    progDesc "Run a worker process. Usually this is run automatically."
  , command "master" $
    info (helper <*> (HyperionMaster <$> programOpts)) $
    progDesc "Run a master process"
  ]

-- | Same as 'hyperionOpts' but with added @--help@ option and wrapped into 'ParserInfo' (by adding program description).
-- This now can be used in 'execParser' from "Options.Applicative".
opts :: Parser a -> ParserInfo (HyperionOpts a)
opts programOpts = info (helper <*> hyperionOpts programOpts) fullDesc

-- | 'hyperionMain' produces an @'IO' ()@ action that runs @hyperion@ and can be
-- assigned to @main@. It performs the following actions
--
--  1. If command-line arguments start with command @master@ then 
--
--      - Uses the supplied parser to parse the remaining options into type @a@
--      - Uses the supplied function to extract 'HyperionConfig' from @a@
--      - The data in 'HyperionConfig' is then used for all following actions
--      - Starts a log in 'stderr', and then redirects it to a file
--      - Starts a hold server from "Hyperion.HoldServer"
--      - Uses 'DB.setupKeyValTable' to setup a "Hyperion.Database.KeyValMap" in the program database
--      - Runs the supplied @'Cluster' ()@ action
--      - TODO : comment the stuff with copying/removing executables
--
--  2. If command-line arguments start with command @worker@ then 
--
--      - TODO
hyperionMain
  :: Show a
  => Parser a
  -> (a -> HyperionConfig)
  -> (a -> Cluster ())
  -> IO ()
hyperionMain programOpts mkHyperionConfig clusterProgram = withConcurrentOutput $
  execParser (opts programOpts) >>= \case
  HyperionWorker Worker{..} -> do
    Log.redirectToFile workerLogFile
    Log.info "Starting service" workerService
    Log.info "Environment" =<< getEnvironment
    runProcessLocallyDefault
      (worker (addressToNodeId workerMasterAddress) workerService)
  HyperionMaster args -> do
    let hyperionConfig = mkHyperionConfig args
    (clusterEnv@ClusterEnv{..}, hyperionExecutable, holdMap) <- newClusterEnv hyperionConfig
    let progId = programId clusterProgramInfo
        masterLogFile = programLogDir clusterProgramInfo </> "master.log"
    pid <- getProcessID
    -- Initially try to start hold server on this port. If connection
    -- fails, the port number will be incremented until it succeeds.
    portVar <- newMVar 11132
    -- Need to run the hold server first to fill portVar with the
    -- right value. Capture the threadId so it can be killed later.
    -- TODO: currently, there is a race condition on portVar with holdServerThread
    holdServerThread <- forkIO $ runHoldServer holdMap portVar
    let logMasterInfo = do
          Log.info "Program id" progId
          Log.info "Process id" pid
          Log.info "Program arguments" args
          Log.info "Using database" (programDatabase clusterProgramInfo)
          port <- readMVar portVar
          Log.info "Running hold server on port" port
    logMasterInfo
    Log.info "Logging to" masterLogFile
    Log.flush
    Log.redirectToFile masterLogFile
    logMasterInfo
    runDBWithProgramInfo clusterProgramInfo DB.setupKeyValTable
    runCluster clusterEnv (clusterProgram args)
    unless (isJust (hyperionCommand hyperionConfig)) $ removeFile hyperionExecutable
    killThread holdServerThread
    Log.info "Finished" progId

