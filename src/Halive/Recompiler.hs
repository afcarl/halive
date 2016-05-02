{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}
module Halive.Recompiler where
import Halive.SubHalive
import Halive.FileListener

import Control.Concurrent.STM
import Control.Concurrent
import Control.Monad.Trans
import Control.Monad

data CompilationRequest = CompilationRequest
    { crFilePath         :: FilePath
    , crExpressionString :: String
    , crResultTChan      :: TChan CompilationResult
    , crFileContents     :: Maybe String -- This is intentionally lazy, since we want to evaluate the string on the SubHalive thread.
                                         -- (as it may be e.g. a TextSeq that needs conversion)
                                         -- In the future, we may want to pass GHC's StringBuffer type here instead, and construct those
                                         -- in a smarter way.
    }


type CompilationResult = Either [String] CompiledValue

startGHC :: MonadIO m => GHCSessionConfig -> m (TChan CompilationRequest)
startGHC ghcSessionConfig = liftIO $ do
    ghcChan <- newTChanIO

    -- Grab this thread's ID (need to run this on the main thread, of course)
    mainThreadID <- myThreadId
    
    initialFileLock <- liftIO newEmptyMVar

    _ <- forkIO . void . withGHCSession mainThreadID ghcSessionConfig $ do
        
        initialResult <- recompileExpressionInFile "Dummy.hs" Nothing "foo"

        liftIO $ putMVar initialFileLock ()
        forever $ do
            CompilationRequest{..} <- readTChanIO ghcChan
            liftIO . putStrLn $ "SubHalive recompiling: " ++ show (crFilePath, crExpressionString)
            
            result <- recompileExpressionInFile crFilePath crFileContents crExpressionString
            writeTChanIO crResultTChan result

    () <- liftIO $ takeMVar initialFileLock

    return ghcChan


data Recompiler = Recompiler 
    { recResultTChan :: TChan CompilationResult
    , recFileEventListener :: FileEventListener
    }

recompilerForExpression :: MonadIO m => (TChan CompilationRequest) -> FilePath -> String -> m Recompiler
recompilerForExpression ghcChan filePath expressionString = liftIO $ do
    resultTChan <- newTChanIO
    let compilationRequest = CompilationRequest 
            { crFilePath         = filePath
            , crExpressionString = expressionString 
            , crResultTChan      = resultTChan
            , crFileContents     = Nothing
            }


    -- Compile for the first time immediately
    writeTChanIO ghcChan compilationRequest
    
    -- Recompile on file event notifications
    fileEventListener <- eventListenerForFile filePath JustReportEvents
    _ <- forkIO . forever $ do
        _ <- readFileEvent fileEventListener
        writeTChanIO ghcChan compilationRequest

    return Recompiler { recResultTChan = resultTChan, recFileEventListener = fileEventListener }

