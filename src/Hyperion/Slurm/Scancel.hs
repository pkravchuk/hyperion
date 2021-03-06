module Hyperion.Slurm.Scancel where

import           Control.Monad          (void)
import           Control.Monad.IO.Class (liftIO)
import qualified Data.Text              as T
import           Hyperion.Slurm.JobId   (JobId (..))
import           System.Process         (createProcess, proc)

scancel :: JobId -> IO ()
scancel j = void $ liftIO $ createProcess $ proc "scancel" [arg]
  where
    arg = case j of
      JobById jobId     -> T.unpack jobId
      JobByName jobName -> "--name=" ++ T.unpack jobName
