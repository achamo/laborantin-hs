{-# LANGUAGE OverloadedStrings #-}

module Laborantin.Implementation (
        EnvIO, runEnvIO
    , defaultBackend
    , defaultResult
    , defaultLog
    , liftIO
) where

import Control.Monad.IO.Class (liftIO)
import qualified Data.Map as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Lazy.Char8 as C
import Laborantin.Types
import Laborantin.Query
import Data.Aeson (decode,encode,FromJSON,parseJSON,(.:),ToJSON,toJSON,(.=),object)
import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A
import Control.Monad.State
import Control.Monad.Error
import Control.Applicative ((<$>),(<*>))
import Data.List
import Data.Maybe
import Data.UUID
import System.Directory
import System.Random
import System.IO.Error
import System.Log.Logger
import System.Log.Handler (close)
import System.Log.Handler.Simple
import System.Log.Handler.Log4jXML
import Data.Time (UTCTime, getCurrentTime)

-- | Default monad for 'defaultBackend'.
--   EnvIO carries a 'DynEnv' in a state and allows you to perform IO actions.
type EnvIO = IO

-- | Execute an EnvIO action in IO.
runEnvIO :: IO a -> IO a
runEnvIO = id

instance ToJSON ParameterValue where
    toJSON (StringParam str) = object ["type" .= ("string"::Text), "val" .= str]
    toJSON (NumberParam n)   = object ["type" .= ("num"::T.Text), "val" .= n]
    toJSON (Array xs)        = toJSON xs
    toJSON (Range _ _ _)     = error "should not have to encode ranges but concrete values instead"

instance ToJSON ExecutionStatus where
    toJSON = toJSON . show

instance ToJSON (Execution a) where
    toJSON (Exec sc params path status es tsts) = object [ "scenario-name" .= sName sc
                                                    , "params" .= params
                                                    , "path" .= path
                                                    , "status" .= status
                                                    , "ancestors" .= ancestors
                                                    , "timestamps" .= tsts
                                                    ] 
                                             where ancestors = map f es
                                                   f x = toJSON (ePath x, sName $ eScenario x)

instance FromJSON ParameterValue where
    parseJSON (A.Object v) = (v .: "type") >>= match
        where match :: T.Text -> A.Parser ParameterValue
              match "string" = StringParam <$> v .: "val"
              match "num"    = NumberParam <$> v .: "val"
              match "range"  = error "should not have to read ranges"
              match _        = mzero
    
    parseJSON _ = mzero

instance FromJSON ExecutionStatus where
    parseJSON (A.String txt) = return $ read $ T.unpack txt
    parseJSON _ = mzero

instance FromJSON StoredExecution where
    parseJSON (A.Object v) = Stored <$>
                               v .: "params" <*>
                               v .: "path" <*>
                               v .: "status" <*>
                               v .: "ancestors" <*>
                               v .: "timestamps"
    parseJSON _          = mzero

-- | Default backend for the 'EnvIO' monad.  This backend uses the filesystem
-- as storage and UUIDs for scenario instances (supposes that UUID collision
-- cannot happen).
--
-- Parameters, logfiles, and result data all are stored in a unique directory named
-- ./<scenario-name>/<uuid>
-- 
-- Results are individual files in this directory. There is no namespacing
-- hence avoid the following names: 'execution.json', 'execution-log.txt', and
-- 'execution-log.xml'. These three files are the scenario execution metadata
-- and logs.
--
defaultBackend :: Backend EnvIO
defaultBackend = Backend "default EnvIO backend" prepare finalize setup run teardown analyze recover result load log rm
  where prepare :: ScenarioDescription EnvIO -> ParameterSet -> EnvIO (Execution EnvIO,Finalizer EnvIO)
        prepare = prepareNewScenario
        finalize  exec finalizer = do
                            finalizer exec
                            now <- liftIO $ getCurrentTime
                            let exec' = updateCompletionTime exec now
                            bPrintT $ "execution finished\n"
                            liftIO $ BSL.writeFile (rundir ++ "/execution.json") (encode exec')
                            where rundir = ePath exec
        setup             = callHooks "setup" . eScenario
        run               = callHooks "run" . eScenario
        teardown          = callHooks "teardown" . eScenario
        analyze exec      = callHooks "analyze" (eScenario exec)
        recover err exec  = unAction (doRecover err)
                            where doRecover = fromMaybe (\_ -> Action $ return ()) (sRecoveryAction $ eScenario exec) 
        result exec       = return . defaultResult exec
        log exec          = return $ defaultLog exec
        rm exec           = liftIO $ removeDirectoryRecursive $ ePath exec

        callHooks key sc  = maybe (error $ "no such hook: " ++ T.unpack key) unAction (M.lookup key $ sHooks sc)

        load               = loadExisting

updateCompletionTime :: Execution m -> UTCTime -> Execution m
updateCompletionTime exec t1 = exec {eTimeStamps = (t0,t1)}  
    where t0 = fst $ eTimeStamps exec

advertise :: Execution m -> Text
advertise exec = T.pack $ unlines [ "scenario: " ++ (show . sName . eScenario) exec
                         , "         rundir: " ++ ePath exec
                         , "         json-params: " ++ (C.unpack . encode . eParamSet) exec
                         ]

bPrint :: (MonadIO m, Show a) => a -> m ()
bPrint = liftIO . putStrLn . ("backend> " ++) . show

bPrintT :: (MonadIO m) => Text -> m ()
bPrintT = liftIO . T.putStrLn . (T.append "backend> ")

prepareNewScenario :: ScenarioDescription EnvIO -> ParameterSet -> EnvIO (Execution EnvIO,Finalizer EnvIO)
prepareNewScenario  sc params = do
    bPrint $ T.append "preparing " (sName sc)
    (now,uuid) <- liftIO $ do
                now <- getCurrentTime
                id <- randomIO :: IO UUID
                return (now,id)
    let rundir = intercalate "/" [T.unpack (sName sc), show uuid]
    let newExec = Exec sc params rundir Running [] (now,now)
    bPrint "resolving dependencies"
    exec <- resolveDependencies newExec
    bPrintT $ advertise exec
    handles <- liftIO $ do
        createDirectoryIfMissing True rundir
        BSL.writeFile (rundir ++ "/execution.json") (encode exec)
        updateGlobalLogger (loggerName exec) (setLevel DEBUG)
        h1 <- fileHandler (rundir ++ "/execution-log.txt") DEBUG
        h2 <- log4jFileHandler (rundir ++ "/execution-log.xml") DEBUG
        forM_ [h1,h2] (updateGlobalLogger (loggerName exec) . addHandler)
        return [h1,h2]
    return (exec, \_ -> liftIO $ forM_ handles close)

resolveDependencies :: Execution EnvIO -> EnvIO (Execution EnvIO)
resolveDependencies exec = do
    pending <- getPendingDeps exec deps 
    resolveDependencies' exec [] pending
    where deps = sDeps $ eScenario exec

resolveDependencies' :: Execution EnvIO -> [Dependency EnvIO] -> [Dependency EnvIO] -> EnvIO (Execution EnvIO)
resolveDependencies' exec [] []                = return exec
resolveDependencies' exec failed []            = error "cannot solve dependencies"
resolveDependencies' exec failed (dep:pending) = do
    bPrint $ "trying to solve " ++ (T.unpack $ dName dep)
    exec2 <- dSolve dep (exec, defaultBackend)
    success <- dCheck dep exec2 
    case success of
        True -> do
            bPrint $ "successfully solved " ++ (T.unpack $ dName dep)
            resolveDependencies' exec2 [] (pending ++ failed)
        False -> do
            bPrint $ "failed to solve " ++ (T.unpack $ dName dep)
            resolveDependencies' exec2 failed pending

-- | Evaluates and returns, for an execution, the list of failing dependencies 
--
getPendingDeps :: (Functor m, Monad m, MonadIO m) => Execution m -> [Dependency m] -> m [Dependency m]
getPendingDeps exec deps = keepFailedChecks <$> mapM checkDep deps
    where keepFailedChecks = map fst . filter (not . snd). zip deps 
          checkDep dep = do
            bPrintT $ T.append "checking " (dName dep)
            dCheck dep exec 

loadExisting :: [ScenarioDescription EnvIO] -> TExpr Bool -> EnvIO [Execution EnvIO]
loadExisting scs qexpr = do
    concat <$> mapM f scs
    where f :: ScenarioDescription EnvIO -> EnvIO [Execution EnvIO]
          f sc = do
            paths <- map ((name ++ "/") ++) . filter notDot <$> liftIO (getDirectoryContents' name)
            allExecs <- mapM (loadOne sc scs) paths
            return $ filter (matchTExpr qexpr) allExecs
            where notDot dirname = take 1 dirname /= "."
                  name = T.unpack $ sName sc

                  getDirectoryContents' dir = catchIOError (getDirectoryContents dir)
                                                           (\e -> if isDoesNotExistError e then return [] else ioError e)

loadOne :: ScenarioDescription EnvIO -> [ScenarioDescription EnvIO] -> FilePath -> EnvIO (Execution EnvIO)
loadOne sc scs path = do
  stored <- decode <$> liftIO (BSL.readFile (path ++ "/execution.json"))
  maybe (error $ "decoding: " ++ path) forStored stored
  where forStored (Stored params path status pairs tsts) = do
            ancestors <- loadAncestors scs pairs
            return $ Exec sc params path status ancestors tsts

loadAncestors :: [ScenarioDescription EnvIO] -> [(FilePath,Text)] -> EnvIO [Execution EnvIO]
loadAncestors scs pairs = catMaybes <$> mapM loadFromPathAndName pairs
    where loadFromPathAndName :: (FilePath,Text) -> EnvIO (Maybe (Execution EnvIO))
          loadFromPathAndName (path, name) = do
            let sc = find ((== name) . sName) scs
            maybe (return Nothing) (\x -> Just <$> loadOne x scs path) sc

-- | Default result handler for the 'EnvIO' monad (see 'defaultBackend').
defaultResult :: Execution m -> FilePath -> Result EnvIO
defaultResult exec basename = Result path read append write
  where read        = liftIO $ T.readFile path
        append dat  = liftIO $ T.appendFile path dat
        write dat   = liftIO $ T.writeFile path dat
        path        = intercalate "/" [ePath exec, basename]

-- | Default logger for the 'EnvIO' monad (see 'defaultBackend').
defaultLog :: Execution m -> LogHandler EnvIO
defaultLog exec = LogHandler logF
    where logF txt = liftIO $ debugM (loggerName exec) (T.unpack txt)
          path = ePath exec ++ "/execution.log"

loggerName :: Execution m -> String
loggerName exec = "laborantin:" ++ ePath exec
