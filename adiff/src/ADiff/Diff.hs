-- MIT License
--
-- Copyright (c) 2018 Christian Klinger
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

-- | Main entry point. Implements all the commands that are called from Main
module ADiff.Diff where

import           ADiff.Prelude

import           Control.Monad.Random
import           Data.List                   (sortBy)
import qualified Data.List                   as L
import qualified Data.Map                    as Map
import           Data.Ord                    (comparing)
import qualified Data.Text.IO                as T
import qualified Data.Text.Lazy              as LT
import qualified Docker.Client               as Docker
import           Language.C
import           System.Directory
import           System.Exit
import           System.IO
import           Text.PrettyPrint            (render)

import           ADiff.ArithmeticExpressions (evalExpr)
import           ADiff.Data
import           ADiff.Execute
import           ADiff.Instrumentation
import           ADiff.Strategy
import           ADiff.Util.ResourcePool
import           ADiff.Verifier



cmdDiff :: HasMainEnv a => Maybe Int -> DiffParameters -> RIO a ()
cmdDiff seed params = do
  logInfo "starting diff"

  s <- case seed of
    Just s  -> return s
    Nothing -> getRandomR (1,10000)
  logInfo $ "seed for random generator: " <> display s
  liftIO $ setStdGen $ mkStdGen s


  mAst <- openCFile (params ^. inputFile)
  case mAst of
    Nothing -> liftIO exitFailure
    Just ast -> do
      let ast' = preprocess ast
      stratEnv <- mkStrategyEnv ast' params
      runRIO stratEnv $ executeStrategy $ params ^. strategy


-- | parses the file, runs the semantic analysis (type checking), and pretty-prints the resulting semantic AST.
-- Use this to test the modified language-c-extensible library.
cmdParseTest :: HasLogFunc env => FilePath -> RIO env ()
cmdParseTest fn = openCFile fn >>= \case
  Nothing -> liftIO exitFailure
  Just ast -> liftIO $ putStrLn $ render $ pretty ast


cmdMarkReads :: HasLogFunc env => SearchMode -> FilePath -> RIO env ()
cmdMarkReads mode fn = do
  logDebug $ "mode is " <> display (tshow mode)
  (Just ast) <- openCFile fn
  let ast' = markAllReads mode ast
  liftIO . putStrLn . render . pretty $ ast'

cmdVersions :: RIO a ()
cmdVersions = liftIO $ forM_ (sortBy (comparing (^. name)) allVerifiers) $ \verifier -> do
    T.putStr $ verifier ^. name
    putStr ": "
    sv <- try (verifier ^. version) >>= \case
      Left (_ :: IOException) -> return "unknown (error)"
      Right Nothing -> return "unknown"
      Right (Just v) -> return v
    putStrLn sv

cmdRunVerifiers :: (HasLogFunc env) => DiffParameters -> RIO env ()
cmdRunVerifiers dp = do
  source <- readFileUtf8 (dp ^. inputFile)
  pool <- newResourcePool (dp ^. verifierResources)
  logInfo $ "resources are : " <> displayList (map tshow $ dp ^. verifierResources)
  logInfo $ "created pool with " <> display (length $ dp ^. verifierResources) <> " verifier resources"
  runs <- withResourcePool pool $ flip map (dp ^. verifiers) $ \(vn, flags, newName) r -> do
    result <- executeVerifierInDocker r vn flags source
    let name = fromMaybe vn newName
    printD $ display name <> ":\t " <> display (tshow $ result ^. verdict)
  return ()

mkStrategyEnv :: (HasMainEnv env) => CTranslationUnit SemPhase -> DiffParameters -> RIO env StrategyEnv
mkStrategyEnv tu dp = do
  lg <- view logFuncL
  db <- view databaseL
  let searchMode_ =  dp ^. searchMode
      budgetSpecification_ = dp ^. budgetSpecification
  -- interpret the budget specification
  let reads     = findAllReads searchMode_ tu
      positions = L.nub [r ^. position | r <- reads]
      exprEnv = Map.fromList [ ("reads", fromIntegral $ length reads)
                             , ("positions", fromIntegral $ length positions)
                             ]
  case evalExpr exprEnv (dp ^. budgetSpecification) of
    Left err -> error err
    Right bdg -> do
      logDebug $ "evaluated Doll expression '" <> display (dp ^. budgetSpecification) <> "' to " <> display (tshow bdg)
      return $ StrategyEnv  lg tu dp db (round bdg)
