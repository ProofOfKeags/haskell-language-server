{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# OPTIONS_GHC -fno-warn-orphans       #-}

module Ide.Plugin.Tactic.Types
  ( module Ide.Plugin.Tactic.Types
  , module Ide.Plugin.Tactic.Debug
  , OccName
  , Name
  , Type
  , TyVar
  , Span
  , Range
  ) where

import Control.Lens hiding (Context)
import Data.Generics.Product (field)
import Control.Monad.Reader
import Data.Function
import Data.Map (Map)
import Data.Set (Set)
import Development.IDE.GHC.Compat
import Development.IDE.Types.Location
import GHC.Generics
import Ide.Plugin.Tactic.Debug
import OccName
import Refinery.Tactic
import Type


------------------------------------------------------------------------------
-- | A wrapper around 'Type' which supports equality and ordering.
newtype CType = CType { unCType :: Type }

instance Eq CType where
  (==) = eqType `on` unCType

instance Ord CType where
  compare = nonDetCmpType `on` unCType

instance Show CType where
  show  = unsafeRender . unCType

instance Show OccName where
  show  = unsafeRender

instance Show Var where
  show  = unsafeRender

instance Show TCvSubst where
  show  = unsafeRender

instance Show (LHsExpr GhcPs) where
  show  = unsafeRender


------------------------------------------------------------------------------
data TacticState = TacticState
    { ts_skolems   :: !([TyVar])
    , ts_unifier   :: !(TCvSubst)
    , ts_used_vals :: !(Set OccName)
    , ts_intro_vals :: !(Set OccName)
    , ts_recursion_stack :: ![Bool]
    } deriving stock (Show, Generic)


defaultTacticState :: TacticState
defaultTacticState =
  TacticState mempty emptyTCvSubst mempty mempty mempty


withRecursionStack
  :: ([Bool] -> [Bool]) -> TacticState -> TacticState
withRecursionStack f =
  field @"ts_recursion_stack" %~ f


withUsedVals :: (Set OccName -> Set OccName) -> TacticState -> TacticState
withUsedVals f =
  field @"ts_used_vals" %~ f


withIntroducedVals :: (Set OccName -> Set OccName) -> TacticState -> TacticState
withIntroducedVals f =
  field @"ts_intro_vals" %~ f



------------------------------------------------------------------------------
-- | The current bindings and goal for a hole to be filled by refinery.
data Judgement' a = Judgement
  { _jHypothesis :: !(Map OccName a)
  , _jDestructed :: !(Set OccName)
    -- ^ These should align with keys of _jHypothesis
  , _jPatternVals :: !(Set OccName)
    -- ^ These should align with keys of _jHypothesis
  , _jBlacklistDestruct :: !(Bool)
  , _jWhitelistSplit :: !(Bool)
  , _jPositionMaps :: !(Map OccName [[OccName]])
  , _jAncestry     :: !(Map OccName (Set OccName))
  , _jIsTopHole    :: !Bool
  , _jGoal         :: !(a)
  }
  deriving stock (Eq, Ord, Generic, Functor, Show)

type Judgement = Judgement' CType


newtype ExtractM a = ExtractM { unExtractM :: Reader Context a }
    deriving (Functor, Applicative, Monad, MonadReader Context)

------------------------------------------------------------------------------
-- | Orphan instance for producing holes when attempting to solve tactics.
instance MonadExtract (LHsExpr GhcPs) ExtractM where
  hole = pure $ noLoc $ HsVar noExtField $ noLoc $ Unqual $ mkVarOcc "_"


------------------------------------------------------------------------------
-- | Reasons a tactic might fail.
data TacticError
  = UndefinedHypothesis OccName
  | GoalMismatch String CType
  | UnsolvedSubgoals [Judgement]
  | UnificationError CType CType
  | NoProgress
  | NoApplicableTactic
  | AlreadyDestructed OccName
  | IncorrectDataCon DataCon
  | RecursionOnWrongParam OccName Int OccName
  | UnhelpfulDestruct OccName
  | UnhelpfulSplit OccName
  deriving stock (Eq)

instance Show TacticError where
    show (UndefinedHypothesis name) =
      occNameString name <> " is not available in the hypothesis."
    show (GoalMismatch tac (CType typ)) =
      mconcat
        [ "The tactic "
        , tac
        , " doesn't apply to goal type "
        , unsafeRender typ
        ]
    show (UnsolvedSubgoals _) =
      "There were unsolved subgoals"
    show (UnificationError (CType t1) (CType t2)) =
        mconcat
          [ "Could not unify "
          , unsafeRender t1
          , " and "
          , unsafeRender t2
          ]
    show NoProgress =
      "Unable to make progress"
    show NoApplicableTactic =
      "No tactic could be applied"
    show (AlreadyDestructed name) =
      "Already destructed " <> unsafeRender name
    show (IncorrectDataCon dcon) =
      "Data con doesn't align with goal type (" <> unsafeRender dcon <> ")"
    show (RecursionOnWrongParam call p arg) =
      "Recursion on wrong param (" <> show call <> ") on arg"
        <> show p <> ": " <> show arg
    show (UnhelpfulDestruct n) =
      "Destructing patval " <> show n <> " leads to no new types"
    show (UnhelpfulSplit n) =
      "Splitting constructor " <> show n <> " leads to no new goals"


------------------------------------------------------------------------------
type TacticsM  = TacticT Judgement (LHsExpr GhcPs) TacticError TacticState ExtractM
type RuleM     = RuleT Judgement (LHsExpr GhcPs) TacticError TacticState ExtractM
type Rule      = RuleM (LHsExpr GhcPs)


------------------------------------------------------------------------------
-- | The Reader context of tactics and rules
data Context = Context
  { ctxDefiningFuncs :: [(OccName, CType)]
    -- ^ The functions currently being defined
  , ctxModuleFuncs :: [(OccName, CType)]
    -- ^ Everything defined in the current module
  }
  deriving stock (Eq, Ord)

