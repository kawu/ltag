-- {-# LANGUAGE FlexibleInstances    #-}
-- {-# LANGUAGE TupleSections        #-}
-- {-# LANGUAGE UndecidableInstances #-}
-- {-# LANGUAGE DeriveFunctor #-}
-- {-# LANGUAGE DeriveFoldable #-}
-- {-# LANGUAGE DeriveTraversable #-}
-- {-# LANGUAGE NoMonomorphismRestriction #-}

{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE GADTs #-}


{-
 - Early parser for TAGs.  Fifth preliminary version :-).
 -}


module NLP.LTAG.Earley5 where


import           Control.Applicative        ((<*>), (<$>))
import           Control.Arrow              (second)
import           Control.Monad              (guard, void, forever)
import qualified Control.Monad.State.Strict as E
import           Control.Monad.Trans.Class  (lift)
import           Control.Monad.Trans.Maybe  (MaybeT (..))
import qualified Control.Monad.RWS.Strict   as RWS
import           Control.Monad.Identity     (Identity(..))

import           Data.Function              (on)
import           Data.Monoid                (mappend, mconcat)
import           Data.List                  (intercalate)
-- import           Data.Foldable (Foldable)
-- import           Data.Traversable (Traversable)
import           Data.Maybe     ( isJust, isNothing
                                , listToMaybe, maybeToList)
import qualified Data.Map.Strict            as M
import qualified Data.Set                   as S
import qualified Data.PSQueue               as Q
import           Data.PSQueue (Binding(..))
import qualified Data.Partition             as Part
import qualified Pipes                      as P
-- import qualified Pipes.Prelude              as P

import qualified NLP.FeatureStructure.Tree as FT
import qualified NLP.FeatureStructure.Graph as FG
import qualified NLP.FeatureStructure.Join as J
import qualified NLP.FeatureStructure.Unify as U
-- import qualified NLP.FeatureStructure.Reid2 as Reid

import           NLP.LTAG.Core
import qualified NLP.LTAG.Rule as R


--------------------------
-- Internal rule
--------------------------


-- | A feature graph identifier, i.e. an identifier used to refer
-- to individual nodes in a FS.
type ID = FT.ID


-- -- | Symbol: a (non-terminal, maybe identifier) pair addorned with
-- -- a feature structure. 
-- data Sym n = Sym
--     { nonTerm :: n
--     , ide     :: Maybe SymID
--     , fgID    :: FID }
--     deriving (Show, Eq, Ord)
-- 
-- 
-- -- | A simplified symbol without FID.
-- type SSym n = (n, Maybe SymID)
-- 
-- 
-- -- | Simplify symbol.
-- simpSym :: Sym n -> SSym n
-- simpSym Sym{..} = (nonTerm, ide)
-- 
-- 
-- -- | Show the symbol.
-- viewSym :: View n => Sym n -> String
-- viewSym (Sym x (Just i) _) = "(" ++ view x ++ ", " ++ show i ++ ")"
-- viewSym (Sym x Nothing _) = "(" ++ view x ++ ", _)"


-- -- | Label: a symbol, a terminal or a generalized foot node.
-- -- Generalized in the sense that it can represent not only a foot
-- -- note of an auxiliary tree, but also a non-terminal on the path
-- -- from the root to the real foot note of an auxiliary tree.
-- data Lab n t
--     = NonT (Sym n)
--     | Term t
--     | Foot (Sym n)
--     deriving (Show, Eq, Ord)


-- | Label represent one of the following:
-- * A non-terminal
-- * A terminal
-- * A root of an auxiliary tree
-- * A foot node of an auxiliary tree
-- * A vertebra of the spine of the auxiliary tree
--
-- It has neither Eq nor Ord instances, because the comparison of
-- feature graph identifiers without context doesn't make much
-- sense.
data Lab n t i
    = NonT
        { nonTerm   :: n
        , labID     :: Maybe SymID
        , topID     :: i
        , botID     :: i }
    | Term t
    | AuxRoot
        { nonTerm   :: n
        , topID     :: i
        , botID     :: i
        , footTopID :: i
        , footBotID :: i }
    | AuxFoot
        { nonTerm   :: n }
    | AuxVert
        { nonTerm   :: n
        , symID     :: SymID
        , topID     :: i
        , botID     :: i }
    deriving (Show)


-- | Map IDs given a mapping function.
mapID :: (i -> j) -> Lab n t i -> Lab n t j
mapID f lab = case lab of
    NonT{..} -> NonT
        { nonTerm = nonTerm
        , labID = labID
        , topID = f topID
        , botID = f botID }
    Term x -> Term x
    AuxRoot{..} -> AuxRoot
        { nonTerm = nonTerm
        , topID = f topID
        , botID = f botID
        , footTopID = f footTopID
        , footBotID = f footBotID }
    AuxFoot x -> AuxFoot x
    AuxVert{..} -> AuxVert
        { nonTerm = nonTerm
        , symID = symID
        , topID = f topID
        , botID = f botID }


-- | Label equality within the context of corresponding
-- feature graphs.
--
-- TODO: Reimplement based on `labEq'`
labEq
    :: forall n t i j f a
     -- We have to use scoped type variables in order to be able
     -- to refer to them from the internal functions.  The usage
     -- of the internal `nodeEq` is most likely responsible for
     -- this. 
     . (Eq n, Eq t, Ord i, Ord j, Eq f, Eq a)
    => Lab n t i        -- ^ First label `x`
    -> FG.Graph i f a   -- ^ Graph corresponding to `x`
    -> Lab n t j        -- ^ Second label `y`
    -> FG.Graph j f a   -- ^ Graph corresponding to `y`
    -> Bool
labEq p g q h =
    eq p q
  where
    eq x@NonT{} y@NonT{}
        =  eqOn nonTerm x y
        && eqOn labID x y
        && nodeEqOn topID x y
        && nodeEqOn botID x y
    eq (Term x) (Term y)
        =  x == y 
    eq x@AuxRoot{} y@AuxRoot{}
        =  eqOn nonTerm x y
        && nodeEqOn topID x y
        && nodeEqOn botID x y
        && nodeEqOn footTopID x y
        && nodeEqOn footBotID x y
    eq (AuxFoot x) (AuxFoot y)
        =  x == y
    eq x@AuxVert{} y@AuxVert{}
        =  eqOn nonTerm x y
        && eqOn symID x y
        && nodeEqOn topID x y
        && nodeEqOn botID x y
    eq _ _ = False
    -- if we don't write `forall k.` then compiler tries to match
    -- it with both `i` and `j` at the same time.
    eqOn :: Eq z => (forall k . Lab n t k -> z)
         -> Lab n t i -> Lab n t j -> Bool
    eqOn f x y = f x == f y
    nodeEqOn :: (forall k . Lab n t k -> k)
        -> Lab n t i -> Lab n t j -> Bool
    nodeEqOn f x y = nodeEq (f x) (f y)
    -- assumption: the first index belongs to the first
    -- graph, the second to the second graph.
    nodeEq i j = FG.equal g i h j


-- | Label equality within the context of corresponding feature
-- graphs.  Concerning the `SymID` values, it is only checked if
-- either both are `Nothing` or both are `Just`.
labEq'
    :: forall n t i j f a
     -- We have to use scoped type variables in order to be able
     -- to refer to them from the internal functions.  The usage
     -- of the internal `nodeEq` is most likely responsible for
     -- this. 
     . (Eq n, Eq t, Ord i, Ord j, Eq f, Eq a)
    => Lab n t i        -- ^ First label `x`
    -> FG.Graph i f a   -- ^ Graph corresponding to `x`
    -> Lab n t j        -- ^ Second label `y`
    -> FG.Graph j f a   -- ^ Graph corresponding to `y`
    -> Bool
labEq' p g q h =
    eq p q
  where
    eq x@NonT{} y@NonT{}
        =  eqOn nonTerm x y
        && eqOn (isJust . labID) x y
        && nodeEqOn topID x y
        && nodeEqOn botID x y
    eq (Term x) (Term y)
        =  x == y 
    eq x@AuxRoot{} y@AuxRoot{}
        =  eqOn nonTerm x y
        && nodeEqOn topID x y
        && nodeEqOn botID x y
        && nodeEqOn footTopID x y
        && nodeEqOn footBotID x y
    eq (AuxFoot x) (AuxFoot y)
        =  x == y
    eq x@AuxVert{} y@AuxVert{}
        =  eqOn nonTerm x y
        -- && eqOn symID x y
        && nodeEqOn topID x y
        && nodeEqOn botID x y
    eq _ _ = False
    -- if we don't write `forall k.` then compiler tries to match
    -- it with both `i` and `j` at the same time.
    eqOn :: Eq z => (forall k . Lab n t k -> z)
         -> Lab n t i -> Lab n t j -> Bool
    eqOn f x y = f x == f y
    nodeEqOn :: (forall k . Lab n t k -> k)
        -> Lab n t i -> Lab n t j -> Bool
    nodeEqOn f x y = nodeEq (f x) (f y)
    -- assumption: the first index belongs to the first
    -- graph, the second to the second graph.
    nodeEq i j = FG.equal g i h j


-- | Label comparison within the context of corresponding
-- feature graphs.
labCmp
    :: forall n t i j f a
     . (Ord n, Ord t, Ord i, Ord j, Ord f, Ord a)
    => Lab n t i      -- ^ First label `x`
    -> FG.Graph i f a -- ^ Graph corresponding to `x`
    -> Lab n t j      -- ^ Second label `y`
    -> FG.Graph j f a -- ^ Graph corresponding to `y`
    -> Ordering
labCmp p g q h =
    cmp p q
  where
    cmp x@NonT{} y@NonT{} =
        cmpOn nonTerm x y       `mappend`
        cmpOn labID x y         `mappend`
        nodeCmpOn topID x y `mappend`
        nodeCmpOn botID x y
    cmp (Term x) (Term y) =
        compare x y
    cmp x@AuxRoot{} y@AuxRoot{} =
        cmpOn nonTerm x y       `mappend`
        nodeCmpOn topID x y `mappend`
        nodeCmpOn botID x y `mappend`
        nodeCmpOn footTopID x y `mappend`
        nodeCmpOn footBotID x y
    cmp (AuxFoot x) (AuxFoot y) =
        compare x y
    cmp x@AuxVert{} y@AuxVert{} =
        cmpOn nonTerm x y       `mappend`
        cmpOn symID x y         `mappend`
        nodeCmpOn topID x y `mappend`
        nodeCmpOn botID x y
    cmp x y = cmpOn conID x y
    cmpOn :: Ord z => (forall k . Lab n t k -> z)
          -> Lab n t i -> Lab n t j -> Ordering
    cmpOn f x y = compare (f x) (f y)
    nodeCmpOn :: (forall k . Lab n t k -> k)
              -> Lab n t i -> Lab n t j -> Ordering
    nodeCmpOn f x y = nodeCmp (f x) (f y)
    -- assumption: the first index belongs to the first
    -- graph, the second to the second graph.
    nodeCmp i j = FG.compare' g i h j
    -- data constructur identifier
    conID x = case x of
        NonT{}      -> 1 :: Int
        Term _      -> 2
        AuxRoot{}   -> 3
        AuxFoot{}   -> 4
        AuxVert{}   -> 5


-- | Label comparison within the context of corresponding
-- feature graphs.  Concerning the `SymID` values, it is only
-- checked if either both are `Nothing` or both are `Just`.
labCmp'
    :: forall n t i j f a
     . (Ord n, Ord t, Ord i, Ord j, Ord f, Ord a)
    => Lab n t i      -- ^ First label `x`
    -> FG.Graph i f a -- ^ Graph corresponding to `x`
    -> Lab n t j      -- ^ Second label `y`
    -> FG.Graph j f a -- ^ Graph corresponding to `y`
    -> Ordering
labCmp' p g q h =
    cmp p q
  where
    cmp x@NonT{} y@NonT{} =
        cmpOn nonTerm x y       `mappend`
        cmpOn (isJust . labID) x y        `mappend`
        nodeCmpOn topID x y     `mappend`
        nodeCmpOn botID x y
    cmp (Term x) (Term y) =
        compare x y
    cmp x@AuxRoot{} y@AuxRoot{} =
        cmpOn nonTerm x y       `mappend`
        nodeCmpOn topID x y `mappend`
        nodeCmpOn botID x y `mappend`
        nodeCmpOn footTopID x y `mappend`
        nodeCmpOn footBotID x y
    cmp (AuxFoot x) (AuxFoot y) =
        compare x y
    cmp x@AuxVert{} y@AuxVert{} =
        cmpOn nonTerm x y       `mappend`
        -- cmpOn symID x y         `mappend`
        nodeCmpOn topID x y `mappend`
        nodeCmpOn botID x y
    cmp x y = cmpOn conID x y
    cmpOn :: Ord z => (forall k . Lab n t k -> z)
          -> Lab n t i -> Lab n t j -> Ordering
    cmpOn f x y = compare (f x) (f y)
    nodeCmpOn :: (forall k . Lab n t k -> k)
              -> Lab n t i -> Lab n t j -> Ordering
    nodeCmpOn f x y = nodeCmp (f x) (f y)
    -- assumption: the first index belongs to the first
    -- graph, the second to the second graph.
    nodeCmp i j = FG.compare' g i h j
    -- data constructur identifier
    conID x = case x of
        NonT{}      -> 1 :: Int
        Term _      -> 2
        AuxRoot{}   -> 3
        AuxFoot{}   -> 4
        AuxVert{}   -> 5


-- | A simplified label which does not contain any information
-- about FSs.  In contrast to `Lab n t`, it provides Eq and Ord
-- instances.  TODO: note that we lose the distinction between
-- `AuxRoot` and `AuxFoot` here.
data SLab n t
    = SNonT (n, Maybe SymID)
    | STerm t
    | SAux (n, Maybe SymID)
    deriving (Show, Eq, Ord)


-- | Simplify label.
simpLab :: Lab n t i -> SLab n t
simpLab NonT{..} = SNonT (nonTerm, labID)
simpLab (Term t) = STerm t
simpLab AuxRoot{..} = SAux (nonTerm, Nothing)
simpLab AuxFoot{..} = SAux (nonTerm, Nothing)
simpLab AuxVert{..} = SAux (nonTerm, Just symID)


-- | Show the label.
viewLab :: (View n, View t) => Lab n t i -> String
viewLab NonT{..} = "N" ++ viewSym (nonTerm, labID)
viewLab (Term t) = "T(" ++ view t ++ ")"
viewLab AuxRoot{..} = "A" ++ viewSym (nonTerm, Nothing)
viewLab AuxVert{..} = "V" ++ viewSym (nonTerm, Just symID)
viewLab AuxFoot{..} = "F" ++ viewSym (nonTerm, Nothing)


-- | View part of the label.  Utility function.
viewSym :: View n => (n, Maybe SymID) -> String
viewSym (x, Just i) = "(" ++ view x ++ ", " ++ show i ++ ")"
viewSym (x, Nothing) = "(" ++ view x ++ ", _)"


-- | Show full info about the label.
viewLabFS
    :: (Ord i, View n, View t, View i, View f, View a)
    => Lab n t i
    -> FG.Graph i f a
    -> String
viewLabFS lab gr = case lab of
    NonT{..} -> "N(" ++ view nonTerm
        ++ ( case labID of
                Nothing -> ""
                Just i  -> ", " ++ view i ) ++ ")"
        ++ "[t=" ++ FG.showFlat gr topID
        ++ ",b=" ++ FG.showFlat gr botID ++ "]"
    Term t -> "T(" ++ view t ++ ")"
    AuxRoot{..} -> "A(" ++ view nonTerm ++ ")"
        ++ "[t=" ++ FG.showFlat gr topID
        ++ ",b=" ++ FG.showFlat gr botID
        ++ ",ft=" ++ FG.showFlat gr footTopID
        ++ ",fb=" ++ FG.showFlat gr footBotID ++ "]"
    AuxFoot x -> "F(" ++ view x ++ ")"
    AuxVert{..} -> "V(" ++ view nonTerm ++ ", " ++ view symID ++ ")"
        ++ "[t=" ++ FG.showFlat gr topID
        ++ ",b=" ++ FG.showFlat gr botID ++ "]"


-- | A rule for an elementary tree.
data Rule n t i f a = Rule {
    -- | The head of the rule.  TODO: Should never be a foot or a
    -- terminal <- can we enforce this constraint?
      headR :: Lab n t i
    -- | The body of the rule
    , bodyR :: [Lab n t i]
    -- | The underlying feature graph.
    , graphR :: FG.Graph i f a
    } deriving (Show)


--------------------------------------------------
-- Substructure Sharing
--------------------------------------------------


-- | Duplication-removal state serves to share common
-- substructures.
--
-- The idea is to remove redundant rules equivalent to other
-- rules already present in the set of processed rules
-- `rulDepo`(sit).
--
-- Note that rules have to be processed in an appropriate order
-- so that lower-level rules are processed before the
-- higher-level rules from which they are referenced.
data DupS n t i f a = DupS {
    -- | A disjoint set for `SymID`s
      symDisj   :: Part.Partition SymID
    -- | Rules already saved
    , rulDepo   :: S.Set (Rule n t i f a)
    } 


-- Let us take a rule and let us assume that all identifiers it
-- contains point to rules which have already been processed (for
-- this assumption to be valid we just need to order the set of
-- rules properly).  So we have a rule `r`, a set of processed
-- rules `rs` and a clustering (disjoint-set) over `SymID`s
-- present in `rs`.
--
-- Now we want to process `r` and, in particular, check if it is
-- not already in `rs` and update its `SymID`s.
--
-- First we translate the body w.r.t. the existing clustering of
-- `SymID`s (thanks to our assumption, these `SymID`s are already
-- known and processed).  The `SymID` in the root of the rule (if
-- present) is the new one and it should not yet have been mentioned
-- in `rs`.  Even when `SymID` is not present in the root, we can
-- still try to check if `r` is not present in `rs` -- after all, there
-- may be some duplicates in the input grammar.
--
-- Case 1: we have a rule with a `SymID` in the root.  We want to
-- check if there is already a rule in `rs` which:
-- * Has identical body (remember that we have already
--   transformed `SymID`s of the body of the rule in question)
-- * Has the same non-terminal in the root and some `SymID`
--
-- Case 2: the same as case 1 with the difference that we look
-- for the rules which have an empty `SymID` in the root.
--
-- For this to work we just need a specific comparison function
-- which works as specified in the two cases desribed above
-- (i.e. either there are some `SymID`s in the roots, or there
-- are no `SymID`s in both roots.) 
--
-- Once we have this comparison, we simply process the set of
-- rules incrementally.


-- | Duplication-removal transformer.
type DupT n t i f a m = E.StateT (DupS n t i f a) m


-- | Duplication-removal monad.
type DupM n t i f a = DupT n t i f a Identity


-- | Run the transformer.
runDupT
    :: (Functor m, Monad m)
    => DupT n t i f a m b
    -> m (b, S.Set (Rule n t i f a))
runDupT = fmap (second rulDepo) . flip E.runStateT
    (DupS Part.empty S.empty)


-- | Update the body of the rule by replacing old `SymID`s with
-- their representatives.
updateBody
    :: Rule n t i f a
    -> DupM n t i f a (Rule n t i f a)
updateBody r = do
    d <- E.gets symDisj
    let body' = map (updLab d) (bodyR r)
    return $ r { bodyR = body' }
  where
    updLab d x@NonT{..}     = x { labID = updSym d <$> labID }
    updLab d x@AuxVert{..}  = x { symID = updSym d symID }
    updLab _ x              = x
    updSym                  = Part.rep


-- | Find a rule if already present.
findRule 
    :: (Ord n, Ord t, Ord i, Ord f, Ord a)
    => Rule n t i f a
    -> DupM n t i f a (Maybe (Rule n t i f a))
findRule x = do
    s <- E.gets rulDepo
    return $ lookupSet x s


-- | Join two `SymID`s.
joinSym :: SymID -> SymID -> DupM n t i f a ()
joinSym x y = E.modify $ \s@DupS{..} -> s
    { symDisj = Part.joinElems x y symDisj }
    


-- | Save the rule in the underlying deposit. 
keepRule
    :: (Ord n, Ord t, Ord i, Ord f, Ord a)
    => Rule n t i f a
    -> DupM n t i f a ()
keepRule r = E.modify $ \s@DupS{..} -> s
    { rulDepo = S.insert r rulDepo }


-- | Retrieve the symbol of the head of the rule.
headSym :: Rule n t i f a -> Maybe SymID
headSym r = case headR r of
    NonT{..}    -> labID
    AuxVert{..} -> Just symID
    _           -> Nothing


-- | Removing duplicates updating `SymID`s at the same time.
-- WARNING: The pipe assumes that `SymID`s to which the present
-- rule refers have already been processed -- in other words,
-- that rule on which the present rule depends have been
-- processed earlier.
rmDups
    :: (Ord n, Ord t, Ord i, Ord f, Ord a)
    => P.Pipe
        (Rule n t i f a)    -- Input
        (Rule n t i f a)    -- Output 
        (DupM n t i f a)    -- Underlying state
        ()                  -- No result
rmDups = forever $ do
    r <- P.await >>= lift . updateBody
    lift (findRule r) >>= \mr -> case mr of
        Nothing -> do
            lift $ keepRule r
            P.yield r
        Just r' -> case (headSym r, headSym r') of
            (Just x, Just y)    -> lift $ joinSym x y
            _                   -> return ()
--         Just r' -> void $ runMaybeT $ joinSym
--             <$> headSymT r
--             <*> headSymT r'
    -- where headSymT = maybeT . headSym


instance (Eq n, Eq t, Ord i, Eq f, Eq a) => Eq (Rule n t i f a) where
    r == s = (hdEq `on` headR) r s
        && ((==) `on` length.bodyR) r s
        && and [eq x y | (x, y) <- zip (bodyR r) (bodyR s)]
      where
        eq x y   = labEq  x (graphR r) y (graphR s)
        hdEq x y = labEq' x (graphR r) y (graphR s)


instance (Ord n, Ord t, Ord i, Ord f, Ord a) => Ord (Rule n t i f a) where
    r `compare` s = (hdCmp `on` headR) r s    `mappend`
        (compare `on` length.bodyR) r s     `mappend`
        mconcat [cmp x y | (x, y) <- zip (bodyR r) (bodyR s)]
      where
        cmp x y   = labCmp  x (graphR r) y (graphR s)
        hdCmp x y = labCmp' x (graphR r) y (graphR s)


-- | Compile a regular rule to an internal rule.
compile
    :: (View n, View t, Ord i, Ord f, Ord a)
    => R.Rule n t i f a -> Rule n t ID f a
compile R.Rule{..} = unJust $ do
    ((x, xs), J.Res{..}) <- FT.runCon $ (,)
        <$> conLab headR
        <*> mapM conLab bodyR
    return $ Rule
        (mapID convID x)
        (map (mapID convID) xs)
        resGraph
  where
    conLab R.NonT{..} = NonT nonTerm labID
        <$> FT.fromFN rootTopFS
        <*> FT.fromFN rootBotFS
    conLab (R.Term x) = return $ Term x
    conLab R.AuxRoot{..} = AuxRoot nonTerm
        <$> FT.fromFN rootTopFS
        <*> FT.fromFN rootBotFS
        <*> FT.fromFN footTopFS
        <*> FT.fromFN footBotFS
    conLab (R.AuxFoot x) = return $ AuxFoot x
    conLab R.AuxVert{..} = AuxVert nonTerm symID
        <$> FT.fromFN rootTopFS
        <*> FT.fromFN rootBotFS


-- | Print the state.
printRuleFS
    :: ( Ord i, View n, View t
       , View i, View f, View a )
    => Rule n t i f a -> IO ()
printRuleFS Rule{..} = do
    putStr $ viewl headR
    putStr " -> "
    putStr $ intercalate " " $ map viewl bodyR
  where
    viewl x = viewLabFS x graphR




--------------------------------------------------
-- CHART STATE ...
--
-- ... and chart extending operations
--------------------------------------------------


-- | Parsing state: processed initial rule elements and the elements
-- yet to process.
data State n t i f a = State {
    -- | The head of the rule represented by the state.
    -- TODO: Not a terminal nor a foot.
      root  :: Lab n t i
    -- | The list of processed elements of the rule, stored in an
    -- inverse order.
    , left  :: [Lab n t i]
    -- | The list of elements yet to process.
    , right :: [Lab n t i]
    -- | The starting position.
    , beg   :: Pos
    -- | The ending position (or rather the position of the dot).
    , end   :: Pos
    -- | Coordinates of the gap (if applies)
    , gap   :: Maybe (Pos, Pos)
    -- | The underlying feature graph.
    , graph :: FG.Graph i f a
    } deriving (Show)


-- | Equality of states.
statEq
    :: forall n t i j f a
     . (Eq n, Eq t, Ord i, Ord j, Eq f, Eq a)
    => State n t i f a
    -> State n t j f a
    -> Bool
statEq r s
     = eqOn beg r s
    && eqOn end r s
    && eqOn gap r s
    && leq (root r) (root s)
    && eqOn (length.left) r s
    && eqOn (length.right) r s
    && and [leq x y | (x, y) <- zip (left r) (left s)]
    && and [leq x y | (x, y) <- zip (right r) (right s)]
  where
    leq x y = labEq x (graph r) y (graph s)
    eqOn :: Eq z => (forall k . State n t k f a -> z)
         -> State n t i f a -> State n t j f a -> Bool
    eqOn f x y = f x == f y


instance (Eq n, Eq t, Ord i, Eq f, Eq a) => Eq (State n t i f a) where
    (==) = statEq


-- | Equality of states.
statCmp
    :: forall n t i j f a
     . (Ord n, Ord t, Ord i, Ord j, Ord f, Ord a)
    => State n t i f a
    -> State n t j f a
    -> Ordering
statCmp r s = cmpOn beg r s
    `mappend` cmpOn end r s
    `mappend` cmpOn gap r s
    `mappend` lcmp (root r) (root s)
    `mappend` cmpOn (length.left) r s
    `mappend` cmpOn (length.right) r s
    `mappend` mconcat [lcmp x y | (x, y) <- zip (left r) (left s)]
    `mappend` mconcat [lcmp x y | (x, y) <- zip (right r) (right s)]
  where
    lcmp x y = labCmp x (graph r) y (graph s)
    cmpOn :: Ord z => (forall k . State n t k f a -> z)
         -> State n t i f a -> State n t j f a -> Ordering
    cmpOn f x y = compare (f x) (f y)


instance (Ord n, Ord t, Ord i, Ord f, Ord a) => Ord (State n t i f a) where
    compare = statCmp


-- | Is it a completed (fully-parsed) state?
completed :: State n t i f a -> Bool
completed = null . right


-- | Does it represent a regular rule?
regular :: State n t i f a -> Bool
regular = isNothing . gap


-- | Does it represent an auxiliary rule?
auxiliary :: State n t i f a -> Bool
auxiliary = isJust . gap


-- | Is it top-level?  All top-level states (regular or
-- auxiliary) have an underspecified ID in the root symbol.
topLevel :: State n t i f a -> Bool
-- topLevel = isNothing . ide . root
topLevel = not . subLevel


-- | Is it subsidiary (i.e. not top) level?
subLevel :: State n t i f a -> Bool
-- subLevel = isJust . ide . root
subLevel x = case root x of
    NonT{..}  -> isJust labID
    AuxVert{} -> True
    Term _    -> True
    _         -> False
    

-- | Deconstruct the right part of the state (i.e. labels yet to
-- process) within the MaybeT monad.
expects
    :: Monad m
    => State n t i f a
    -> MaybeT m (Lab n t i, [Lab n t i])
expects = maybeT . expects'


-- | Deconstruct the right part of the state (i.e. labels yet to
-- process). 
expects'
    :: State n t i f a
    -> Maybe (Lab n t i, [Lab n t i])
expects' = decoList . right


-- | Print the state.
printStateRaw :: (View n, View i, View t) => State n t i f a -> IO ()
printStateRaw State{..} = do
    putStr $ viewLab root
    putStr " -> "
    putStr $ intercalate " " $
        map viewLab (reverse left) ++ ["*"] ++ map viewLab right
    putStr " <"
    putStr $ show beg
    putStr ", "
    case gap of
        Nothing -> return ()
        Just (p, q) -> do
            putStr $ show p
            putStr ", "
            putStr $ show q
            putStr ", "
    putStr $ show end
    putStrLn ">"


-- | Print the state.
printStateFS
    :: ( Ord i, View n, View t
       , View i, View f, View a )
    => State n t i f a -> IO ()
printStateFS State{..} = do
    putStr $ viewl root
    putStr " -> "
    putStr $ intercalate " " $
        map viewl (reverse left) ++ ["*"] ++ map viewl right
    putStr " <"
    putStr $ show beg
    putStr ", "
    case gap of
        Nothing -> return ()
        Just (p, q) -> do
            putStr $ show p
            putStr ", "
            putStr $ show q
            putStr ", "
    putStr $ show end
    putStrLn ">"
  where
    viewl x = viewLabFS x graph


-- | Print the state.
printState
    :: ( Ord i, View n, View t
       , View i, View f, View a )
    => State n t i f a -> IO ()
printState = printStateFS


-- | Priority type.
type Prio = Int


-- | Priority of a state.  Crucial for the algorithm -- states have
-- to be removed from the queue in a specific order.
prio :: State n t i f a -> Prio
prio p = end p


--------------------------------------------------
-- StateE
--------------------------------------------------


-- | A state existentially quantified over the ID type.
data StateE n t f a where
    StateE :: VOrd i => State n t i f a -> StateE n t f a


instance (Eq n, Eq t, Eq f, Eq a) => Eq (StateE n t f a) where
    StateE r == StateE s = statEq r s


instance (Ord n, Ord t, Ord f, Ord a) => Ord (StateE n t f a) where
    StateE r `compare` StateE s = statCmp r s


-- | Priority of a StateE.
prioE :: StateE n t f a -> Prio
prioE (StateE s) = prio s


--------------------------------------------------
-- Earley monad
--------------------------------------------------


-- | The state of the earley monad.
data EarSt n t f a = EarSt {
    -- | Rules which expect a specific label and which end on a
    -- specific position.
      doneExpEnd :: M.Map (SLab n t, Pos) (S.Set (StateE n t f a))
    -- | Rules providing a specific non-terminal in the root
    -- and spanning over a given range.
    , doneProSpan :: M.Map (n, Pos, Pos) (S.Set (StateE n t f a))
    -- | The set of states waiting on the queue to be processed.
    -- Invariant: the intersection of `done' and `waiting' states
    -- is empty.
    , waiting    :: Q.PSQ (StateE n t f a) Prio }


-- | Make an initial `EarSt` from a set of states.
mkEarSt
    :: (Ord n, Ord t, Ord a, Ord f)
    => S.Set (StateE n t f a)
    -> (EarSt n t f a)
mkEarSt s = EarSt
    { doneExpEnd = M.empty
    , doneProSpan = M.empty
    , waiting = Q.fromList
        [ p :-> prioE p
        | p <- S.toList s ] }


-- | Earley parser monad.  Contains the input sentence (reader)
-- and the state of the computation `EarSt'.
type Earley n t f a = RWS.RWST [t] () (EarSt n t f a) IO


-- | Read word from the given position of the input.
readInput :: Pos -> MaybeT (Earley n t f a) t
readInput i = do
    -- ask for the input
    xs <- RWS.ask
    -- just a safe way to retrieve the i-th element
    maybeT $ listToMaybe $ drop i xs


-- | Check if the state is not already processed (i.e. in one of the
-- done-related maps).
isProcessed
    :: (Ord n, Ord t, Ord a, Ord f)
    => StateE n t f a
    -> EarSt n t f a
    -> Bool
isProcessed pE EarSt{..} =
    S.member pE $ chooseSet pE
  where
    chooseSet (StateE p) = case expects' p of
        Just (x, _) -> M.findWithDefault S.empty
            (simpLab x, end p) doneExpEnd
        Nothing -> M.findWithDefault S.empty
            (nonTerm $ root p, beg p, end p) doneProSpan


-- | Add the state to the waiting queue.  Check first if it is
-- not already in the set of processed (`done') states.
pushState
    :: (Ord t, Ord n, Ord a, Ord f)
    => StateE n t f a
    -> Earley n t f a ()
pushState p = RWS.state $ \s ->
    let waiting' = if isProcessed p s
            then waiting s
            else Q.insert p (prioE p) (waiting s)
    in  ((), s {waiting = waiting'})


-- | Remove a state from the queue.  In future, the queue
-- will be probably replaced by a priority queue which will allow
-- to order the computations in some smarter way.
popState
    :: (Ord t, Ord n, Ord a, Ord f)
    => Earley n t f a (Maybe (StateE n t f a))
popState = RWS.state $ \st -> case Q.minView (waiting st) of
    Nothing -> (Nothing, st)
    Just (x :-> _, s) -> (Just x, st {waiting = s})


-- | Add the state to the set of processed (`done') states.
saveState
    :: (Ord t, Ord n, Ord a, Ord f)
    => StateE n t f a
    -> Earley n t f a ()
saveState pE =
    RWS.state $ \s -> ((), doit pE s)
  where
    doit (StateE p) st@EarSt{..} = st
      { doneExpEnd = case expects' p of
          Just (x, _) -> M.insertWith S.union (simpLab x, end p)
                              (S.singleton pE) doneExpEnd
          Nothing -> doneExpEnd
      , doneProSpan = if completed p
          then M.insertWith S.union (nonTerm $ root p, beg p, end p)
               (S.singleton pE) doneProSpan
          else doneProSpan }


-- | Return all completed states which:
-- * expect a given label,
-- * end on the given position.
expectEnd
    :: (Ord n, Ord t) => SLab n t -> Pos
    -> P.ListT (Earley n t f a) (StateE n t f a)
expectEnd x i = do
  EarSt{..} <- lift RWS.get
  listValues (x, i) doneExpEnd


-- | Return all completed states with:
-- * the given root non-terminal value
-- * the given span
rootSpan
    :: Ord n => n -> (Pos, Pos)
    -> P.ListT (Earley n t f a) (StateE n t f a)
rootSpan x (i, j) = do
  EarSt{..} <- lift RWS.get
  listValues (x, i, j) doneProSpan


-- | A utility function.
listValues
    :: (Monad m, Ord a)
    => a -> M.Map a (S.Set b)
    -> P.ListT m b
listValues x m = each $ case M.lookup x m of
    Nothing -> []
    Just s -> S.toList s


--------------------------------------------------
-- SCAN
--------------------------------------------------


-- | Try to perform SCAN on the given state.
tryScan
    :: (VOrd t, VOrd n, VOrd a, VOrd f)
    => StateE n t f a
    -> Earley n t f a ()
tryScan (StateE p) = void $ runMaybeT $ do
    -- check that the state expects a terminal on the right
    (Term t, right') <- expects p
    -- read the word immediately following the ending position of
    -- the state
    c <- readInput $ end p
    -- make sure that what the rule expects is consistent with
    -- the input
    guard $ c == t
    -- construct the resultant state
    let p' = p
            { end = end p + 1
            , left = Term t : left p
            , right = right' }
    -- print logging information
    lift . lift $ do
        putStr "[S]  " >> printState p
        putStr "  :  " >> printState p'
    -- push the resulting state into the waiting queue
    lift $ pushState $ StateE p'


--------------------------------------------------
-- SUBST
--------------------------------------------------


-- | Try to use the state (only if fully parsed) to complement
-- (=> substitution) other rules.
trySubst
    :: (VOrd t, VOrd n, VOrd a, VOrd f)
    => StateE n t f a
    -> Earley n t f a ()
trySubst (StateE p) = void $ P.runListT $ do
    -- make sure that `p' is a fully-parsed regular rule
    guard $ completed p && regular p
    -- find rules which end where `p' begins and which
    -- expect the non-terminal provided by `p' (ID included)
    StateE q <- expectEnd (simpLab $ root p) (beg p)
    (r@NonT{}, _) <- some $ expects' q
    -- unify the corresponding feature structures
    -- TODO: We assume here that graph IDs are disjoint.
    J.Res{..} <- some $ U.unify (graph p) (graph q)
            [ (topID $ root p, topID r)
            -- in practice, `botID r` should be empty, but
            -- it seems that we don't lose anything by taking
            -- the other possibility into account.
            -- BUT :=> In our case, `botID r` can very well be
            -- non-empty.  The reason is that trees are broken
            -- down into flat rules and therefore intermediary
            -- nodes are split.
            , (botID $ root p, botID r) ]
    -- construct the resultant state
    -- Q: Why are we using `Right` here?
    let conv = mapID $ convID . Right
        q' = q
            { end = end p
            , root  = conv $ root q
            , left  = map conv $ r : left q
            , right = map conv $ tail $ right q
            , graph = resGraph }
    -- print logging information
    lift . lift $ do
        putStr "[U]  " >> printState p
        putStr "  +  " >> printState q
        putStr "  :  " >> printState q'
    -- push the resulting state into the waiting queue
    lift $ pushState $ StateE q'


--------------------------------------------------
-- ADJOIN
--------------------------------------------------


-- | `tryAdjoinInit p q':
-- * `p' is a completed state (regular or auxiliary)
-- * `q' not completed and expects a *real* foot
--
-- No FS unification is taking place here, it is performed at the
-- level of `tryAdjoinTerm(inate)`.
--
tryAdjoinInit
    :: (VOrd n, VOrd t, VOrd a, VOrd f)
    => StateE n t f a
    -> Earley n t f a ()
tryAdjoinInit (StateE p) = void $ P.runListT $ do
    -- make sure that `p' is fully-matched and that it is either
    -- a regular rule or an intermediate auxiliary rule ((<=)
    -- used as an implication here!); look at `tryAdjoinTerm`
    -- for motivations.
    guard $ completed p && auxiliary p <= subLevel p
    -- before: guard $ completed p
    -- find all rules which expect a real foot (with ID == Nothing)
    -- and which end where `p' begins.
    let u = nonTerm (root p)
    StateE q <- expectEnd (SAux (u, Nothing)) (beg p)
    -- NOTE: While `SAux (u, Nothing)` can, in theory, represent an
    -- auxiliary root as well as a foot, in this context (i.e. as an
    -- argument to `expectEnd`) it can only be interpreted as a foot.
    (r@AuxFoot{}, _) <- some $ expects' q
    -- construct the resultant state
    let q' = q
            { gap = Just (beg p, end p)
            , end = end p
            , left = r : left q
            , right = tail (right q) }
    -- print logging information
    lift . lift $ do
        putStr "[A]  " >> printState p
        putStr "  +  " >> printState q
        putStr "  :  " >> printState q'
    -- push the resulting state into the waiting queue
    lift $ pushState $ StateE q'


-- | `tryAdjoinCont p q':
-- * `p' is a completed, auxiliary state
-- * `q' not completed and expects a *dummy* foot
tryAdjoinCont
    :: (VOrd n, VOrd t, VOrd f, VOrd a)
    => StateE n t f a
    -> Earley n t f a ()
tryAdjoinCont (StateE p) = void $ P.runListT $ do
    -- make sure that `p' is a completed, sub-level auxiliary rule
    guard $ completed p && subLevel p && auxiliary p
    -- find all rules which expect a foot provided by `p'
    -- and which end where `p' begins.
    StateE q <- expectEnd (simpLab $ root p) (beg p)
    (r@AuxVert{}, _) <- some $ expects' q
    -- unify the feature structures corresponding to the 'p's
    -- root and 'q's foot.  TODO: We assume here that graph IDs
    -- are disjoint.
    J.Res{..} <- some $ U.unify (graph p) (graph q)
            [ (topID $ root p, topID r)
            , (botID $ root p, botID r) ]
    -- construct the resulting state; the span of the gap of the
    -- inner state `p' is copied to the outer state based on `q'
    let conv = mapID $ convID . Right
        q' = q
            { gap = gap p, end = end p
            , root  = conv $ root q 
            , left  = map conv $ r : left q
            , right = map conv $ tail $ right q
            -- , left = r : left q
            -- , right = tail (right q)
            , graph = resGraph }
    -- logging info
    lift . lift $ do
        putStr "[B]  " >> printState p
        putStr "  +  " >> printState q
        putStr "  :  " >> printState q'
    -- push the resulting state into the waiting queue
    lift $ pushState $ StateE q'


-- | Adjoin a fully-parsed auxiliary state `p` to a partially parsed
-- tree represented by a fully parsed rule/state `q`.
tryAdjoinTerm
    :: (VOrd t, VOrd n, VOrd a, VOrd f)
    => StateE n t f a
    -> Earley n t f a ()
tryAdjoinTerm (StateE p) = void $ P.runListT $ do
    -- make sure that `p' is a completed, top-level state ...
    guard $ completed p && topLevel p
    -- ... and that it is an auxiliary state (by definition only
    -- auxiliary states have gaps)
    (gapBeg, gapEnd) <- each $ maybeToList $ gap p
    -- it is top-level, so we can also make sure that the
    -- root is an AuxRoot.
    pRoot@AuxRoot{} <- some $ Just $ root p
    -- take all completed rules with a given span
    -- and a given root non-terminal (IDs irrelevant)
    StateE q <- rootSpan (nonTerm $ root p) (gapBeg, gapEnd)
    -- make sure that `q' is completed as well and that it is either
    -- a regular (perhaps intermediate) rule or an intermediate
    -- auxiliary rule (note that (<=) is used as an implication
    -- here and can be read as `implies`).
    -- NOTE: root auxiliary rules are of no interest to us but they
    -- are all the same taken into account in an indirect manner.
    -- We can assume here that such rules are already adjoined thus
    -- creating either regular or intermediate auxiliary.
    -- NOTE: similar reasoning can be used to explain why foot
    -- auxiliary rules are likewise ignored.
    -- Q: don't get this second remark -- how could a foot node
    -- be a root of a state/rule `q`?  What `foot auxiliary rules`
    -- could actually mean?
    guard $ completed q && auxiliary q <= subLevel q
    -- TODO: it seems that some of the constraints given above
    -- follow from the code below:
    qRoot <- some $ case root q of
        x@NonT{}    -> Just x
        x@AuxVert{} -> Just x
        _           -> Nothing
    J.Res{..} <- some $ U.unify (graph p) (graph q)
            [ (topID pRoot,     topID qRoot)
            , (footBotID pRoot, botID qRoot) ]
    let convR = mapID $ convID . Right
        convL = convID . Left
    newRoot <- some $ case qRoot of
        NonT{} -> Just $ NonT
            { nonTerm = nonTerm qRoot
            , labID = labID qRoot
            , topID = convL $ topID pRoot
            , botID = convL $ botID pRoot }
        AuxVert{} -> Just $ AuxVert
            { nonTerm = nonTerm qRoot
            , symID = symID qRoot
            , topID = convL $ topID pRoot
            , botID = convL $ botID pRoot }
        _           -> Nothing
    let q' = q
            { root = newRoot 
            , left  = map convR $ left q
            , right = map convR $ right q
            , beg = beg p
            , end = end p
            , graph = resGraph }
    lift . lift $ do
        putStr "[C]  " >> printState p
        putStr "  +  " >> printState q
        putStr "  :  " >> printState q'
    lift $ pushState $ StateE q'


--------------------------------------------------
-- EARLEY
--------------------------------------------------


-- | Perform the earley-style computation given the grammar and
-- the input sentence.
earley
    :: (VOrd t, VOrd n, VOrd f, VOrd a)
    => S.Set (Rule n t ID f a) -- ^ The grammar (set of rules)
    -> [t]                     -- ^ Input sentence
    -> IO (S.Set (StateE n t f a))
    -- -> IO ()
earley gram xs =
    agregate . doneProSpan . fst <$> RWS.execRWST loop xs st0
    -- void $ RWS.execRWST loop xs st0
  where
    -- Agregate the results from the `doneProSpan` part of the
    -- result.
    agregate = S.unions . M.elems
    -- we put in the initial state all the states with the dot on
    -- the left of the body of the rule (-> left = []) on all
    -- positions of the input sentence.
    st0 = mkEarSt $ S.fromList -- $ Reid.runReid $ mapM reidState
        [ StateE $ State
            { root  = headR
            , left  = []
            , right = bodyR
            , beg   = i
            , end   = i
            , gap   = Nothing
            , graph = graphR }
        | Rule{..} <- S.toList gram
        , i <- [0 .. length xs - 1] ]
    -- the computation is performed as long as the waiting queue
    -- is non-empty.
    loop = popState >>= \mp -> case mp of
        Nothing -> return ()
        Just p -> do
            -- lift $ case p of
            --     (StateE q) -> putStr "POPED: " >> printState q
            step p >> loop


-- | Step of the algorithm loop.  `p' is the state popped up from
-- the queue.
step
    :: (VOrd t, VOrd n, VOrd f, VOrd a)
    => StateE n t f a
    -> Earley n t f a ()
step p = do
    sequence_ $ map ($p)
      [ tryScan, trySubst
      , tryAdjoinInit
      , tryAdjoinCont
      , tryAdjoinTerm ]
    saveState p


--------------------------------------------------
-- Utility
--------------------------------------------------


-- | Retrieve the Just value.  Error otherwise.
unJust :: Maybe a -> a
unJust (Just x) = x
unJust Nothing = error "unJust: got Nothing!" 


-- | Deconstruct list.  Utility function.  Similar to `unCons`.
decoList :: [a] -> Maybe (a, [a])
decoList [] = Nothing
decoList (y:ys) = Just (y, ys)


-- | MaybeT transformer.
maybeT :: Monad m => Maybe a -> MaybeT m a
maybeT = MaybeT . return


-- | ListT from a list.
each :: Monad m => [a] -> P.ListT m a
each = P.Select . P.each


-- | ListT from a maybe.
some :: Monad m => Maybe a -> P.ListT m a
some = each . maybeToList


-- | Lookup an element in a set.
lookupSet :: Ord a => a -> S.Set a -> Maybe a
lookupSet x s = do    
    y <- S.lookupLE x s
    guard $ x == y
    return y
