{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
--
-- Copyright (c) 2009-2012   Stefan Wehr - http://www.stefanwehr.de
--
-- This library is free software; you can redistribute it and/or
-- modify it under the terms of the GNU Lesser General Public
-- License as published by the Free Software Foundation; either
-- version 2.1 of the License, or (at your option) any later version.
--
-- This library is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
-- Lesser General Public License for more details.
--
-- You should have received a copy of the GNU Lesser General Public
-- License along with this library; if not, write to the Free Software
-- Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307, USA
--

{- |

This module defines function for running a set of tests. Furthermore,
it provides functionality for organzing tests into a hierarchical
structure. This functionality is mainly used internally in the code
generated by the @hftpp@ pre-processor.
-}

module Test.Framework.TestManager (

  -- * Re-exports
  module Test.Framework.TestTypes,

  -- * Running tests
  htfMain, htfMainWithArgs, runTest, runTest', runTestWithArgs, runTestWithArgs',
  runTestWithOptions, runTestWithOptions', runTestWithConfig, runTestWithConfig',

  -- * Organzing tests
  TestableHTF,

  makeQuickCheckTest, makeUnitTest, makeBlackBoxTest, makeTestSuite,
  makeAnonTestSuite,
  addToTestSuite, testSuiteAsTest,

  flattenTest
) where

import Control.Monad.RWS
import System.Exit (ExitCode(..), exitWith)
import System.Environment (getArgs)
import qualified Control.Exception as Exc
import Data.Maybe
import Data.Time
import qualified Data.List as List
import qualified Data.ByteString as BS
import Data.IORef
import Control.Concurrent

import System.IO

import Test.Framework.Utils
import Test.Framework.TestInterface
import Test.Framework.TestTypes
import Test.Framework.CmdlineOptions
import Test.Framework.TestReporter
import Test.Framework.Location
import Test.Framework.Colors
import Test.Framework.ThreadPool
import Test.Framework.History

-- | Construct a test where the given 'Assertion' checks a quick check property.
-- Mainly used internally by the htfpp preprocessor.
makeQuickCheckTest :: TestID -> Location -> Assertion -> Test
makeQuickCheckTest id loc ass = BaseTest QuickCheckTest id (Just loc) defaultTestOptions ass

-- | Construct a unit test from the given 'IO' action.
-- Mainly used internally by the htfpp preprocessor.
makeUnitTest :: AssertionWithTestOptions a => TestID -> Location -> a -> Test
makeUnitTest id loc ass =
    BaseTest UnitTest id (Just loc) (testOptions ass) (assertion ass)

-- | Construct a black box test from the given 'Assertion'.
-- Mainly used internally.
makeBlackBoxTest :: TestID -> Assertion -> Test
makeBlackBoxTest id ass = BaseTest BlackBoxTest id Nothing defaultTestOptions ass

-- | Create a named 'TestSuite' from a list of 'Test' values.
makeTestSuite :: TestID -> [Test] -> TestSuite
makeTestSuite = TestSuite

-- | Create an unnamed 'TestSuite' from a list of 'Test' values.
makeAnonTestSuite :: [Test] -> TestSuite
makeAnonTestSuite = AnonTestSuite

-- | Turn a 'TestSuite' into a proper 'Test'.
testSuiteAsTest :: TestSuite -> Test
testSuiteAsTest = CompoundTest

-- | Extend a 'TestSuite' with a list of 'Test' values
addToTestSuite :: TestSuite -> [Test] -> TestSuite
addToTestSuite (TestSuite id ts) ts' = TestSuite id (ts ++ ts')
addToTestSuite (AnonTestSuite ts) ts' = AnonTestSuite (ts ++ ts')

-- | A type class for things that can be run as tests.
-- Mainly used internally.
class TestableHTF t where
    flatten :: t -> [FlatTest]

instance TestableHTF Test where
    flatten = flattenTest

instance TestableHTF TestSuite where
    flatten = flattenTestSuite

instance TestableHTF t => TestableHTF [t] where
    flatten = concatMap flatten

instance TestableHTF (IO a) where
    flatten action = flatten (makeUnitTest "unnamed test" unknownLocation action)

flattenTest :: Test -> [FlatTest]
flattenTest (BaseTest sort id mloc opts x) =
    [FlatTest sort (TestPathBase id) mloc (WithTestOptions opts x)]
flattenTest (CompoundTest ts) =
    flattenTestSuite ts

flattenTestSuite :: TestSuite -> [FlatTest]
flattenTestSuite (TestSuite id ts) =
    let fts = concatMap flattenTest ts
    in map (\ft -> ft { ft_path = TestPathCompound (Just id) (ft_path ft) }) fts
flattenTestSuite (AnonTestSuite ts) =
    let fts = concatMap flattenTest ts
    in map (\ft -> ft { ft_path = TestPathCompound Nothing (ft_path ft) }) fts

maxRunTime :: TestConfig -> FlatTest -> Maybe Milliseconds
maxRunTime tc ft =
    let mt1 = tc_maxSingleTestTime tc
        mt2 =
            case tc_prevFactor tc of
              Nothing -> Nothing
              Just d ->
                  case max (fmap htr_timeMs (findHistoricSuccessfulTestResult (historyKey ft) (tc_history tc)))
                           (fmap htr_timeMs (findHistoricTestResult (historyKey ft) (tc_history tc)))
                  of
                    Nothing -> Nothing
                    Just t -> Just $ ceiling (fromInteger (toInteger t) * d)
    in case (mt1, mt2) of
         (Just t1, Just t2) -> Just (min t1 t2)
         (_, Nothing) -> mt1
         (Nothing, _) -> mt2

-- | HTF uses this function to execute the given assertion as a HTF test.
performTestHTF :: Assertion -> IO FullTestResult
performTestHTF action =
    do action
       return (mkFullTestResult Pass Nothing)
     `Exc.catches`
      [Exc.Handler (\(HTFFailure res) -> return res)
      ,Exc.Handler handleUnexpectedException]
    where
      handleUnexpectedException exc =
          case Exc.fromException exc of
            Just (async :: Exc.AsyncException) ->
                case async of
                  Exc.StackOverflow -> exceptionAsError exc
                  _ -> Exc.throwIO exc
            _ -> exceptionAsError exc
      exceptionAsError exc =
          return (mkFullTestResult Error (Just $ show (exc :: Exc.SomeException)))

data TimeoutResult a
    = TimeoutResultOk a
    | TimeoutResultException Exc.SomeException
    | TimeoutResultTimeout

timeout :: Int -> IO a -> IO (Maybe a)
timeout microSecs action
    | microSecs < 0 = fmap Just action
    | microSecs == 0 = return Nothing
    | otherwise =
        do resultChan <- newChan
           finishedVar <- newIORef False
           workerTid <- forkIO (wrappedAction resultChan finishedVar)
           _ <- forkIO (threadDelay microSecs >> writeChan resultChan TimeoutResultTimeout)
           res <- readChan resultChan
           case res of
             TimeoutResultTimeout ->
                 do atomicModifyIORef finishedVar (\_ -> (True, ()))
                    killThread workerTid
                    return Nothing
             TimeoutResultOk x ->
                 return (Just x)
             TimeoutResultException exc ->
                 Exc.throwIO exc
    where
      wrappedAction resultChan finishedVar =
          Exc.mask $ \restore ->
                   (do x <- restore action
                       writeChan resultChan (TimeoutResultOk x))
                   `Exc.catch`
                   (\(exc::Exc.SomeException) ->
                        do b <- shouldReraiseException exc finishedVar
                           if b then Exc.throwIO exc else writeChan resultChan (TimeoutResultException exc))
      shouldReraiseException exc finishedVar =
          case Exc.fromException exc of
            Just (async :: Exc.AsyncException) ->
                case async of
                  Exc.ThreadKilled -> atomicModifyIORef finishedVar (\old -> (old, old))
                  _ -> return False
            _ -> return False

data PrimTestResult
    = PrimTestResultNoTimeout FullTestResult
    | PrimTestResultTimeout

mkFlatTestRunner :: TestConfig -> FlatTest -> ThreadPoolEntry TR () (PrimTestResult, Milliseconds)
mkFlatTestRunner tc ft = (pre, action, post)
    where
      pre = reportTestStart ft
      action _ =
          let run = performTestHTF (wto_payload (ft_payload ft))
          in case maxRunTime tc ft of
               Nothing ->
                   do (res, time) <- measure run
                      return (PrimTestResultNoTimeout res, time)
               Just maxMs ->
                    do mx <- timeout (1000 * maxMs) $ measure run
                       case mx of
                         Nothing -> return (PrimTestResultTimeout, maxMs)
                         Just (res, time) ->
                             return (PrimTestResultNoTimeout res, time)
      post excOrResult =
          let (testResult, time) =
                 case excOrResult of
                   Left exc ->
                       (FullTestResult
                        { ftr_location = Nothing
                        , ftr_callingLocations = []
                        , ftr_message = Just $ noColor ("Running test unexpectedly failed: " ++ show exc)
                        , ftr_result = Just Error
                        }
                       ,(-1))
                   Right (res, time) ->
                       case res of
                         PrimTestResultTimeout ->
                             (FullTestResult
                              { ftr_location = Nothing
                              , ftr_callingLocations = []
                              , ftr_message = Just $ colorize warningColor "timeout"
                              , ftr_result = Nothing
                              }
                             ,time)
                         PrimTestResultNoTimeout res ->
                             let res' =
                                     if isNothing (ftr_message res) && isNothing (ftr_result res)
                                     then res { ftr_message = Just (colorize warningColor "timeout") }
                                     else res
                             in (res', time)
              (sumRes, isTimeout) =
                  case ftr_result testResult of
                    Just x -> (x, False)
                    Nothing -> (if tc_timeoutIsSuccess tc then Pass else Error, True)
              rr = FlatTest

                     { ft_sort = ft_sort ft
                     , ft_path = ft_path ft
                     , ft_location = ft_location ft
                     , ft_payload = RunResult sumRes (ftr_location testResult)
                                              (ftr_callingLocations testResult)
                                              (fromMaybe emptyColorString (ftr_message testResult))
                                              time isTimeout
                     }
          in do modify (\s -> s { ts_results = rr : ts_results s })
                reportTestResult rr
                return (stopFlag sumRes)
      stopFlag result =
          if not (tc_failFast tc)
          then DoNotStop
          else case result of
                 Pass -> DoNotStop
                 Pending -> DoNotStop
                 Fail -> DoStop
                 Error -> DoStop

runAllFlatTests :: TestConfig -> [FlatTest] -> TR ()
runAllFlatTests tc tests' =
    do reportGlobalStart tests
       tc <- ask
       case tc_threads tc of
         Nothing ->
             let entries = map (mkFlatTestRunner tc) tests
             in tp_run sequentialThreadPool entries
         Just i ->
             let (ptests, stests) = List.partition (\t -> to_parallel (wto_options (ft_payload t))) tests
                 pentries' = map (mkFlatTestRunner tc) ptests
                 sentries = map (mkFlatTestRunner tc) stests
             in do tp <- parallelThreadPool i
                   pentries <- if tc_shuffle tc
                               then liftIO (shuffleIO pentries')
                               else return pentries'
                   tp_run tp pentries
                   tp_run sequentialThreadPool sentries
    where
      tests = sortTests tests'
      sortTests ts =
          if not (tc_sortByPrevTime tc)
          then ts
          else map snd $ List.sortBy compareTests (map (\t -> (historyKey t, t)) ts)
      compareTests (t1, _) (t2, _) =
          case (max (fmap htr_timeMs (findHistoricSuccessfulTestResult t1 (tc_history tc)))
                    (fmap htr_timeMs (findHistoricTestResult t1 (tc_history tc)))
               ,max (fmap htr_timeMs (findHistoricSuccessfulTestResult t2 (tc_history tc)))
                    (fmap htr_timeMs (findHistoricTestResult t2 (tc_history tc))))
          of
            (Just t1, Just t2) -> compare t1 t2
            (Just _, Nothing) -> GT
            (Nothing, Just _) -> LT
            (Nothing, Nothing) -> EQ

-- | Run something testable using the 'Test.Framework.TestConfig.defaultCmdlineOptions'.
runTest :: TestableHTF t => t              -- ^ Testable thing
                         -> IO ExitCode    -- ^ See 'runTestWithOptions' for a specification of the 'ExitCode' result
runTest = runTestWithOptions defaultCmdlineOptions

-- | Run something testable using the 'Test.Framework.TestConfig.defaultCmdlineOptions'.
runTest' :: TestableHTF t => t              -- ^ Testable thing
                         -> IO (IO (), ExitCode)    -- ^ 'IO' action for printing the overall test results, and exit code for the test run. See 'runTestWithOptions' for a specification of the 'ExitCode' result
runTest' = runTestWithOptions' defaultCmdlineOptions

-- | Run something testable, parse the 'CmdlineOptions' from the given commandline arguments.
-- Does not print the overall test results but returns an 'IO' action for doing so.
runTestWithArgs :: TestableHTF t => [String]        -- ^ Commandline arguments
                                 -> t               -- ^ Testable thing
                                 -> IO ExitCode     -- ^ See 'runTestWithConfig' for a specification of the 'ExitCode' result.
runTestWithArgs args t =
    do (printSummary, ecode) <- runTestWithArgs' args t
       printSummary
       return ecode


-- | Run something testable, parse the 'CmdlineOptions' from the given commandline arguments.
runTestWithArgs' :: TestableHTF t => [String]        -- ^ Commandline arguments
                                 -> t               -- ^ Testable thing
                                 -> IO (IO (), ExitCode)  -- ^ 'IO' action for printing the overall test results, and exit code for the test run. See 'runTestWithConfig' for a specification of the 'ExitCode' result.
runTestWithArgs' args t =
    case parseTestArgs args of
      Left err ->
          do hPutStrLn stderr err
             return $ (return (), ExitFailure 1)
      Right opts ->
          runTestWithOptions' opts t

-- | Runs something testable with the given 'CmdlineOptions'.
-- See 'runTestWithConfig' for a specification of the 'ExitCode' result.
runTestWithOptions :: TestableHTF t => CmdlineOptions -> t -> IO ExitCode
runTestWithOptions opts t =
    do (printSummary, ecode) <- runTestWithOptions' opts t
       printSummary
       return ecode

-- | Runs something testable with the given 'CmdlineOptions'. Does not
-- print the overall test results but returns an 'IO' action for doing so.
-- See 'runTestWithConfig' for a specification of the 'ExitCode' result.
runTestWithOptions' :: TestableHTF t => CmdlineOptions -> t -> IO (IO (), ExitCode)
runTestWithOptions' opts t =
    if opts_help opts
       then do hPutStrLn stderr helpString
               return $ (return (), ExitFailure 1)
       else do tc <- testConfigFromCmdlineOptions opts
               (printSummary, ecode) <-
                   (if opts_listTests opts
                      then let fts = filter (opts_filter opts) (flatten t)
                           in return (runRWST (reportAllTests fts) tc initTestState >> return (), ExitSuccess)
                      else do (printSummary, ecode, history) <- runTestWithConfig' tc t
                              storeHistory (tc_historyFile tc) history
                              return (printSummary, ecode))
               return (printSummary `Exc.finally` cleanup tc, ecode)
    where
      cleanup tc =
          case tc_output tc of
            TestOutputHandle h True -> hClose h
            _ -> return ()
      storeHistory file history =
          BS.writeFile file (serializeTestHistory history)

-- | Runs something testable with the given 'TestConfig'.
-- The result is 'ExitSuccess' if all tests were executed successfully,
-- 'ExitFailure' otherwise. In the latter case, an error code of @1@ indicates
-- that failures but no errors occurred, otherwise the error code @2@ is used.
--
-- A test is /successful/ if the test terminates and no assertion fails.
-- A test is said to /fail/ if an assertion fails but no other error occur.
runTestWithConfig :: TestableHTF t => TestConfig -> t -> IO (ExitCode, TestHistory)
runTestWithConfig tc t =
    do (printSummary, ecode, history) <- runTestWithConfig' tc t
       printSummary
       return (ecode, history)

-- | Runs something testable with the given 'TestConfig'. Does not
-- print the overall test results but returns an 'IO' action for doing so.
-- See 'runTestWithConfig' for a specification of the 'ExitCode' result.
runTestWithConfig' :: TestableHTF t => TestConfig -> t -> IO (IO (), ExitCode, TestHistory)
runTestWithConfig' tc t =
     do let allTests = flatten t
            activeTests = filter (tc_filter tc) allTests
            filteredTests = filter (not . tc_filter tc) allTests
        startTime <- getCurrentTime
        ((_, s, _), time) <-
            measure $
            runRWST (runAllFlatTests tc activeTests) tc initTestState
        let results = reverse (ts_results s)
            passed = filter (\ft -> (rr_result . ft_payload) ft == Pass) results
            pending = filter (\ft -> (rr_result . ft_payload) ft == Pending) results
            failed = filter (\ft -> (rr_result . ft_payload) ft == Fail) results
            error = filter (\ft -> (rr_result . ft_payload) ft == Error) results
            timedOut = filter (\ft -> (rr_timeout . ft_payload) ft) results
            arg = ReportGlobalResultsArg
                  { rgra_timeMs = time
                  , rgra_passed = passed
                  , rgra_pending = pending
                  , rgra_failed = failed
                  , rgra_errors = error
                  , rgra_timedOut = timedOut
                  , rgra_filtered = filteredTests
    }
        let printSummary =
                runRWST (reportGlobalResults arg) tc (TestState [] (ts_index s)) -- keep index from run
            !newHistory = updateHistory startTime results (tc_history tc)
        return (printSummary >> return (),
                case () of
                   _| length failed == 0 && length error == 0 -> ExitSuccess
                    | length error == 0 -> ExitFailure 1
                    | otherwise -> ExitFailure 2
               ,newHistory)
    where
      updateHistory :: UTCTime -> [FlatTestResult] -> TestHistory -> TestHistory
      updateHistory time results history =
          let runHistory = mkTestRunHistory time (map (\res -> HistoricTestResult {
                                                                 htr_testId = historyKey res
                                                               , htr_result = rr_result (ft_payload res)
                                                               , htr_timedOut = rr_timeout (ft_payload res)
                                                               , htr_timeMs = rr_wallTimeMs (ft_payload res)
                                                               })
                                                      results)
          in updateTestHistory runHistory history

-- | Runs something testable by parsing the commandline arguments as test options
-- (using 'parseTestArgs'). Exits with the exit code returned by 'runTestWithArgs'.
-- This function is the main entry point for running tests.
htfMain :: TestableHTF t => t -> IO ()
htfMain tests =
    do args <- getArgs
       htfMainWithArgs args tests

-- | Runs something testable by parsing the commandline arguments as test options
-- (using 'parseTestArgs'). Exits with the exit code returned by 'runTestWithArgs'.
htfMainWithArgs :: TestableHTF t => [String] -> t -> IO ()
htfMainWithArgs args tests =
    do ecode <- runTestWithArgs args tests
       exitWith ecode
