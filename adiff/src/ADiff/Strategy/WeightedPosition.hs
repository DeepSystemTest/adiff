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

{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module ADiff.Strategy.WeightedPosition
  ( randomUniformStrategy
  , depthFirstStrategy
  , breadthFirstStrategy
  , randomUniformBatchStrategy
  ) where

import           ADiff.Prelude

import           Control.Monad
import           Data.Functor.Identity
import qualified Data.Vector                  as V
import           Language.C
import           ADiff.Data
import           ADiff.Instrumentation
import           ADiff.Strategy.Common
import           ADiff.Strategy.Common.Budget
import qualified ADiff.Strategy.Common.Raffle as Raffle

type Prioritization = ExprRead -> Double


-- | Every position has priority 1.0
randomUniformStrategy :: (IsStrategyEnv env) => RIO env ()
randomUniformStrategy = mkStrategy  (const 1.0)

randomUniformBatchStrategy :: (IsStrategyEnv env) => RIO env ()
randomUniformBatchStrategy = mkStrategy (const 1.0)

-- | Priority proportional to depth
depthFirstStrategy :: (IsStrategyEnv env) => RIO env ()
depthFirstStrategy = mkStrategy p
  where
    p r = fromIntegral $ astDepth (r ^. position)

-- | Priority anti-proportional to depth
breadthFirstStrategy :: (IsStrategyEnv env) => RIO env ()
breadthFirstStrategy = mkStrategy p
  where
    p r = 1.0 / fromIntegral (astDepth (r ^. position))


mkStrategy :: (IsStrategyEnv env) => Prioritization -> RIO env ()
mkStrategy prioritize = do
  tu              <- view translationUnit
  bdg             <- view initialBudget
  sm              <- view (diffParameters . searchMode)
  conjunctionSize <- view (diffParameters . batchSize)

  let (reads :: Raffle.Raffle ExprRead) = Raffle.fromList $ zipMap prioritize $ findAllReads sm tu
  let constantPool = findAllConstants tu

  unless (Raffle.countElements reads == 0) $
    void $ runBudgetT bdg $ forever $ do
      r <- Raffle.drawM reads
      let ty = getType $ r ^. expression
      let constantRaffle = let tmp = Raffle.fromList1 $ map Just $ lookupPool ty constantPool
                           in Raffle.insert (Nothing, max 1 $ Raffle.countTickets tmp) tmp
      constants <- replicateM conjunctionSize $ Raffle.drawM constantRaffle
      conjuncts <- forM constants $ \case
        Nothing -> mkRandomConstant ty
        Just c -> return c
      let compoundAssertion = assertUnequals (r ^. expression) conjuncts
      let tu' = insertAt (r ^. position) compoundAssertion tu
      (_,c) <- verifyB tu'
      when (isDisagreement c) $ void $
        binaryIntervalSearch (V.fromList conjuncts) $ \cs -> do
          let compoundAssertion = assertUnequals (r ^. expression) (V.toList cs)
          let tu' = insertAt (r ^. position) compoundAssertion tu
          (_,c) <- verifyB tu'
          return (isDisagreement c)
  where
    zipMap f l = zip l (map f l)



-- | finds the singleton for which the test fails.
-- | A test t should have the following property: t({x}) -> t({x} u X)
binaryIntervalSearch :: (Monad m) => Vector a -> (Vector a -> m Bool) -> m (Maybe a)
binaryIntervalSearch v test
  | null v = return Nothing
  | length v == 1 = return $ Just (V.head v)
  | otherwise = do
      let pivot = V.length v `div` 2
          (v1,v2) = V.splitAt pivot v
      left <- test v1
      if left
        then binaryIntervalSearch v1 test
        else do
          right <- test v2
          if right
            then binaryIntervalSearch v2 test
            else return Nothing

insertAt :: AstPosition -> CStatement SemPhase -> CTranslationUnit SemPhase -> CTranslationUnit SemPhase
insertAt p asrt tu = snd $ runIdentity $ runBrowserT (gotoPosition p >> insertBefore asrt) tu
