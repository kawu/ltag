{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE UndecidableInstances #-}


{-
 - Early parser for TAGs.  Fourth preliminary version :-).
 -}


module NLP.LTAG.Early4 where


import           Control.Applicative        ((<$>), (*>))
import           Control.Monad              (guard, void)
import qualified Control.Monad.RWS.Strict   as RWS
import qualified Control.Monad.State.Strict as ST
import           Control.Monad.Trans.Class  (lift)
import           Control.Monad.Trans.Maybe  (MaybeT (..))

import           Data.List                  (intercalate)
import qualified Data.Map.Strict            as M
import           Data.Maybe     ( isJust, isNothing
                                , listToMaybe, maybeToList)
import qualified Data.Set                   as S
import qualified Data.PSQueue               as Q
import           Data.PSQueue (Binding(..))

import qualified Pipes                      as P

import qualified NLP.LTAG.Tree              as G


--------------------------------------------------
-- CUSTOM SHOW
--------------------------------------------------


class Show a => View a where
    view :: a -> String

instance View String where
    view x = x

instance View Int where
    view = show


--------------------------------------------------
-- VIEW + ORD
--------------------------------------------------


class (View a, Ord a) => VOrd a where

instance (View a, Ord a) => VOrd a where


--------------------------------------------------
-- CORE TYPES
--------------------------------------------------


-- | Position in the sentence.
type Pos = Int


----------------------
-- Initial Trees
----------------------


-- Each initial tree is factorized into a collection of flat CF
-- rules.  In order to make sure that this collection of rules
-- can be only used to recognize this particular tree, each
-- non-terminal is paired with an additional identifier.
--
-- Within the context of substitution, both the non-terminal and
-- the identifier have to agree.  In case of adjunction, only the
-- non-terminals have to be equal.


-- | Additional identifier.
type ID = Int


-- | Symbol: a (non-terminal, maybe identifier) pair.
type Sym n = (n, Maybe ID)


-- | Show the symbol.
viewSym :: View n => Sym n -> String
viewSym (x, Just i) = "(" ++ view x ++ ", " ++ show i ++ ")"
viewSym (x, Nothing) = "(" ++ view x ++ ", _)"


-- | Label: a symbol, a terminal or a generalized foot node.
-- Generalized in the sense that it can represent not only a foot
-- note of an auxiliary tree, but also a non-terminal on the path
-- from the root to the real foot note of an auxiliary tree.
data Lab n t
    = NonT (Sym n)
    | Term t
    | Foot (Sym n)
    deriving (Show, Eq, Ord)


-- | Show the label.
viewLab :: (View n, View t) => Lab n t -> String
viewLab (NonT s) = "N" ++ viewSym s
viewLab (Term t) = "T(" ++ view t ++ ")"
viewLab (Foot s) = "F" ++ viewSym s


-- | A rule for initial tree.
data Rule n t = Rule {
    -- | The head of the rule
      headI :: Sym n
    -- | The body of the rule
    , body  :: [Lab n t]
    } deriving (Show, Eq, Ord)


--------------------------
-- Rule generation monad
--------------------------


-- | Identifier generation monad.
type RM n t a = RWS.RWS () [Rule n t] Int a


-- | Pull the next identifier.
nextID :: RM n t ID
nextID = RWS.state $ \i -> (i, i + 1)


-- | Save the rule in the writer component of the monad.
keepRule :: Rule n t -> RM n t ()
keepRule = RWS.tell . (:[])


-- | Evaluate the RM monad.
runRM :: RM n t a -> (a, [Rule n t])
runRM rm = RWS.evalRWS rm () 0


-----------------------------------------
-- Tree Factorization
-----------------------------------------


-- | Take an initial tree and factorize it into a list of rules.
treeRules
    :: Bool         -- ^ Is it a top level tree?  `True' for
                    -- an entire initial tree, `False' otherwise.
    -> G.Tree n t   -- ^ The tree itself
    -> RM n t (Lab n t)
treeRules isTop G.INode{..} = case subTrees of
    [] -> do
        let x = (labelI, Nothing)
        -- keepRule $ Rule x []
        return $ NonT x
    _  -> do
        x <- if isTop
            then return (labelI, Nothing)
            else (labelI,) . Just <$> nextID
        xs <- mapM (treeRules False) subTrees
        keepRule $ Rule x xs
        return $ NonT x
treeRules _ G.FNode{..} = return $ Term labelF


-----------------------------------------
-- Auxiliary Tree Factorization
-----------------------------------------


-- | Convert an auxiliary tree to a lower-level auxiliary
-- representation and a list of corresponding rules which
-- represent the "substitution" trees on the left and on the
-- right of the spine.
auxRules :: Bool -> G.AuxTree n t -> RM n t (Lab n t)
-- auxRules :: Bool -> G.AuxTree n t -> RM n t (Maybe (Sym n))
auxRules b G.AuxTree{..} =
    doit b auxTree auxFoot
  where
    -- doit _ G.INode{..} [] = return Nothing
    doit _ G.INode{..} [] = return $ Foot (labelI, Nothing)
    doit isTop G.INode{..} (k:ks) = do
        let (ls, bt, rs) = split k subTrees
        x <- if isTop
            then return (labelI, Nothing)
            else (labelI,) . Just <$> nextID
        ls' <- mapM (treeRules False) ls
        bt' <- doit False bt ks
        rs' <- mapM (treeRules False) rs
--         keepAux $ Aux x ls' bt' rs'
--         return $ Just x
        keepRule $ Rule x $ ls' ++ (bt' : rs')
        return $ Foot x
    doit _ _ _ = error "auxRules: incorrect path"
    split =
        doit []
      where
        doit acc 0 (x:xs) = (reverse acc, x, xs)
        doit acc k (x:xs) = doit (x:acc) (k-1) xs
        doit acc _ [] = error "auxRules.split: index to high"


--------------------------------------------------
-- CHART STATE ...
--
-- ... and chart extending operations
--------------------------------------------------


-- | Parsing state: processed initial rule elements and the elements
-- yet to process.
data State n t = State {
    -- | The head of the rule represented by the state.
      root  :: Sym n
    -- | The list of processed elements of the rule, stored in an
    -- inverse order.
    , left  :: [Lab n t]
    -- | The list of elements yet to process.
    , right :: [Lab n t]
    -- | The starting position.
    , beg   :: Pos
    -- | The ending position (or rather the position of the dot).
    , end   :: Pos
    -- | Coordinates of the gap (if applies)
    , gap   :: Maybe (Pos, Pos)
    } deriving (Show, Eq, Ord)


-- | Is it a completed (fully-parsed) state?
completed :: State n t -> Bool
completed = null . right


-- | Does it represent a regular rule?
regular :: State n t -> Bool
regular = isNothing . gap


-- | Does it represent a regular rule?
auxiliary :: State n t -> Bool
auxiliary = isJust . gap


-- | Is it top-level?  All top-level states (regular or
-- auxiliary) have an underspecified ID in the root symbol.
topLevel :: State n t -> Bool
topLevel = isNothing . snd . root


-- | Is it subsidiary (i.e. not top) level?
subLevel :: State n t -> Bool
subLevel = isJust . snd . root


-- | Deconstruct the right part of the state (i.e. labels yet to
-- process) within the MaybeT monad.
expects :: Monad m => State n t -> MaybeT m (Lab n t, [Lab n t])
expects = maybeT . expects'


-- | Deconstruct the right part of the state (i.e. labels yet to
-- process) within the MaybeT monad.
expects' :: State n t -> Maybe (Lab n t, [Lab n t])
expects' = decoList . right


-- | Print the state.
printState :: (View n, View t) => State n t -> IO ()
printState State{..} = do
    putStr $ viewSym root
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


-- | Priority type.
type Prio = Int


-- | Priority of a state.  Crucial for the algorithm -- states have
-- to be removed from the queue in a specific order.
prio :: State n t -> Prio
prio p = end p


--------------------------------------------------
-- Earley monad
--------------------------------------------------


-- | The state of the earley monad.
data EarSt n t = EarSt {
    -- | Rules which expect a specific label and which end on a
    -- specific position.
      doneExpEnd :: M.Map (Lab n t, Pos) (S.Set (State n t))
    -- | Rules providing a specific non-terminal in the root
    -- and spanning over a given range.
    , doneProSpan :: M.Map (n, Pos, Pos) (S.Set (State n t))
    -- | The set of states waiting on the queue to be processed.
    -- Invariant: the intersection of `done' and `waiting' states
    -- is empty.
    -- , waiting    :: S.Set (State n t) }
    , waiting    :: Q.PSQ (State n t) Prio }
    deriving (Show)


-- | Make an initial `EarSt` from a set of states.
mkEarSt :: (Ord n, Ord t) => S.Set (State n t) -> (EarSt n t)
mkEarSt s = EarSt
    { doneExpEnd = M.empty
    , doneProSpan = M.empty
    , waiting = Q.fromList
        [ p :-> prio p
        | p <- S.toList s ] }


-- | Earley parser monad.  Contains the input sentence (reader)
-- and the state of the computation `EarSt'.
type Earley n t = RWS.RWST [t] () (EarSt n t) IO


-- | Read word from the given position of the input.
readInput :: Pos -> MaybeT (Earley n t) t
readInput i = do
    -- ask for the input
    xs <- RWS.ask
    -- just a safe way to retrieve the i-th element
    maybeT $ listToMaybe $ drop i xs


-- | Retrieve the set of "done" states.
--  :: Earley n t (S.Set (State n t))
--  = done <$> RWS.get


-- | Add the state to the waiting queue.  Check first if it is
-- not already in the set of processed (`done') states.
pushState :: (Ord t, Ord n) => State n t -> Earley n t ()
pushState p = RWS.state $ \s ->
    let waiting' = if isProcessed p s
            then waiting s
            else Q.insert p (prio p) (waiting s)
    in  ((), s {waiting = waiting'})


-- | Remove a state from the queue.  In future, the queue
-- will be probably replaced by a priority queue which will allow
-- to order the computations in some smarter way.
popState :: (Ord t, Ord n) => Earley n t (Maybe (State n t))
popState = RWS.state $ \st -> case Q.minView (waiting st) of
    Nothing -> (Nothing, st)
    Just (x :-> _, s) -> (Just x, st {waiting = s})


-- | Add the state to the set of processed (`done') states.
saveState :: (Ord t, Ord n) => State n t -> Earley n t ()
saveState p = RWS.state $ \s -> ((), doit s)
  where
    doit st@EarSt{..} = st
      { doneExpEnd = case expects' p of
          Just (x, _) -> M.insertWith S.union (x, end p)
                              (S.singleton p) doneExpEnd
          Nothing -> doneExpEnd
      , doneProSpan = if completed p
          then M.insertWith S.union (fst $ root p, beg p, end p)
               (S.singleton p) doneProSpan
          else doneProSpan }


-- | Check if the state is not already processed (i.e. in one of the
-- done-related maps).
isProcessed :: (Ord n, Ord t) => State n t -> EarSt n t -> Bool
isProcessed p EarSt{..} = S.member p $ case expects' p of
    Just (x, _) -> M.findWithDefault S.empty
        (x, end p) doneExpEnd
    Nothing -> M.findWithDefault S.empty
        (fst $ root p, beg p, end p) doneProSpan


-- | Return all completed states which:
-- * expect a given label,
-- * end on the given position.
expectEnd
    :: (Ord n, Ord t) => Lab n t -> Pos
    -> P.ListT (Earley n t) (State n t)
expectEnd x i = do
  EarSt{..} <- lift RWS.get
  listValues (x, i) doneExpEnd


-- | Return all completed states with:
-- * the given root non-terminal value
-- * the given span
rootSpan
    :: Ord n => n -> (Pos, Pos)
    -> P.ListT (Earley n t) (State n t)
rootSpan x (i, j) = do
  EarSt{..} <- lift RWS.get
  listValues (x, i, j) doneProSpan


-- | A utility function.
listValues :: (Monad m, Ord a) => a -> M.Map a (S.Set b) -> P.ListT m b
listValues x m = each $ case M.lookup x m of
    Nothing -> []
    Just s -> S.toList s


-- | Perform the earley-style computation given the grammar and
-- the input sentence.
earley
    :: (VOrd t, VOrd n)
    => S.Set (Rule n t) -- ^ The grammar (set of rules)
    -> [t]              -- ^ Input sentence
    -- -> IO (S.Set (State n t))
    -> IO ()
earley gram xs =
    -- done . fst <$> RWS.execRWST loop xs st0
    void $ RWS.execRWST loop xs st0
  where
    -- we put in the initial state all the states with the dot on
    -- the left of the body of the rule (-> left = []) on all
    -- positions of the input sentence.
    st0 = mkEarSt $ S.fromList
        [ State
            { root = headI
            , left = []
            , right = body
            , beg = i, end = i
            , gap = Nothing }
        | Rule{..} <- S.toList gram
        , i <- [0 .. length xs - 1] ]
    -- the computetion is performed as long as the waiting queue
    -- is non-empty.
    loop = popState >>= \mp -> case mp of
        Nothing -> return ()
        Just p -> step p >> loop


-- | Step of the algorithm loop.  `p' is the state popped up from
-- the queue.
step :: (VOrd t, VOrd n) => State n t -> Earley n t ()
step p = do
    sequence $ map ($p)
      [ tryScan, trySubst
      , tryAdjoinInit
      , tryAdjoinCont
      , tryAdjoinTerm ]
    saveState p


-- | Try to perform SCAN on the given state.
tryScan :: (VOrd t, VOrd n) => State n t -> Earley n t ()
tryScan p = void $ runMaybeT $ do
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
    lift $ pushState p'


-- | Try to use the state (only if fully parsed) to complement
-- (=> substitution) other rules.
trySubst
    :: (VOrd t, VOrd n)
    => State n t
    -> Earley n t ()
trySubst p = void $ P.runListT $ do
    -- make sure that `p' is a fully-parsed regular rule
    guard $ completed p && regular p
    -- find rules which end where `p' begins and which
    -- expect the non-terminal provided by `p' (ID included)
    q <- expectEnd (NonT $ root p) (beg p)
    -- construct the resultant state
    let q' = q
            { end = end p
            , left = NonT (root p) : left q
            , right = tail (right q) }
    -- print logging information
    lift . lift $ do
        putStr "[U]  " >> printState p
        putStr "  +  " >> printState q
        putStr "  :  " >> printState q'
    -- push the resulting state into the waiting queue
    lift $ pushState q'


-- | `tryAdjoinInit p q':
-- * `p' is a completed state (regular or auxiliary)
-- * `q' not completed and expects a *real* foot
tryAdjoinInit
    :: (VOrd n, VOrd t)
    => State n t
    -> Earley n t ()
tryAdjoinInit p = void $ P.runListT $ do
    -- make sure that `p' is fully-parsed
    guard $ completed p
    -- find all rules which expect a real foot (with ID == Nothing)
    -- and which end where `p' begins.
    let u = fst (root p)
    q <- expectEnd (Foot (u, Nothing)) (beg p)  
    -- construct the resultant state
    let q' = q
            { gap = Just (beg p, end p)
            , end = end p
            , left = Foot (u, Nothing) : left q
            , right = tail (right q) }
    -- print logging information
    lift . lift $ do
        putStr "[A]  " >> printState p
        putStr "  +  " >> printState q
        putStr "  :  " >> printState q'
    -- push the resulting state into the waiting queue
    lift $ pushState q'


-- | `tryAdjoinCont p q':
-- * `p' is a completed, auxiliary state
-- * `q' not completed and expects a *dummy* foot
tryAdjoinCont
    :: (VOrd n, VOrd t)
    => State n t
    -> Earley n t ()
tryAdjoinCont p = void $ P.runListT $ do
    -- make sure that `p' is a completed, sub-level auxiliary rule
    guard $ completed p && subLevel p && auxiliary p
    -- find all rules which expect a foot provided by `p'
    -- and which end where `p' begins.
    q <- expectEnd (Foot $ root p) (beg p)
    -- construct the resulting state; the span of the gap of the
    -- inner state `p' is copied to the outer state based on `q'
    let q' = q
            { gap = gap p, end = end p
            , left = Foot (root p) : left q
            , right = tail (right q) }
    -- logging info
    lift . lift $ do
        putStr "[B]  " >> printState p
        putStr "  +  " >> printState q
        putStr "  :  " >> printState q'
    -- push the resulting state into the waiting queue
    lift $ pushState q'


-- | Adjoin a fully-parsed auxiliary state to a partially parsed
-- tree represented by a fully parsed rule/state.
tryAdjoinTerm
    :: (VOrd t, VOrd n)
    => State n t
    -> Earley n t ()
tryAdjoinTerm p = void $ P.runListT $ do
    -- make sure that `p' is a completed, top-level state ...
    guard $ completed p && topLevel p
    -- ... and that it is an auxiliary state
    (gapBeg, gapEnd) <- each $ maybeToList $ gap p
    -- take all completed rules with a given span
    -- and a given root non-terminal (IDs irrelevant)
    q <- rootSpan (fst $ root p) (gapBeg, gapEnd)
    -- make sure that `q' is completed as well and that it is
    -- either a regular rule or an intermediate auxiliary rule
    -- ((<=) used as an implication here!)
    guard $ completed q && auxiliary q <= subLevel q
    let q' = q
            { beg = beg p
            , end = end p }
    lift . lift $ do
        putStr "[C]  " >> printState p
        putStr "  +  " >> printState q
        putStr "  :  " >> printState q'
    lift $ pushState q'


--------------------------------------------------
-- UTILS
--------------------------------------------------


-- | Deconstruct list.  Utility function.
decoList :: [a] -> Maybe (a, [a])
decoList [] = Nothing
decoList (y:ys) = Just (y, ys)


-- | MaybeT transformer.
maybeT :: Monad m => Maybe a -> MaybeT m a
maybeT = MaybeT . return


-- | ListT from a list.
each :: Monad m => [a] -> P.ListT m a
each = P.Select . P.each
