{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -Wno-orphans #-}

import Prelude hiding (id, (.), filter)

import Control.Category
import Control.Lens
import Control.Monad.IO.Class
import Control.Monad.Fix
import Data.Align
import Data.Proxy
import Data.Map (Map)
import Data.Map.Monoidal (MonoidalMap(..))
import Data.Semigroup (First(..), Max(..))
import Data.Dependent.Map (DMap)
import Data.Text (Text)
import Reflex
import Reflex.Dom.Core
import qualified Data.Map as Map
import qualified Data.Map.Merge.Strict as Map

import Data.Vessel
import Data.Vessel.ViewMorphism
import Data.Vessel.Vessel
import Data.Vessel.Map
import Data.Vessel.Identity

import Data.GADT.Compare.TH
import Data.GADT.Show.TH
import Data.Constraint.Extras.TH


-- suppose a simple app; something like a blog...


type PostId = Int
type Post = Text

-- a "query" type, which captures the kinds of queries we can have...
data Qsimple g = Qsimple
  { _q_posts :: GrpMap PostId g -- ^ a map from post ID's to refcounts, represents querying for that post
  , _q_latestPostId :: GrpMap () g -- ^ morally a "bool"; for if the maxPost Id is being requested.
  } deriving (Eq, Ord, Show, Read)

-- and the corresponding result type.  Note that we have the same set of fields occur in both.
data Rsimple = Rsimple
  { _r_posts :: MonoidalMap PostId (First (Maybe Post)) -- ^ posts
  , _r_latestPostId :: MonoidalMap () (Max (Maybe PostId)) -- ^ the max post id;
  } deriving (Eq, Ord, Show, Read)


-- Now we end up needing to produce some boilerplate instances for our queries;
-- QueryT (the only "real" instance for MonadQuery) requires that the query
-- type be a Group.  it does this for essentially performance reasons.  if 100
-- widgets have queries, and one of them "goes away", then we can either add
-- the remaining 99 queries Or subtract the removed query from the total for
-- all 100 we already have.  the latter is almost always quicker.
instance (Eq g, Monoid g) => Semigroup (Qsimple g) where Qsimple x y <> Qsimple x' y' = Qsimple (x <> x') (y <> y')
instance (Eq g, Monoid g) => Monoid (Qsimple g) where mempty = Qsimple mempty mempty
instance (Eq g, Group g) => Group (Qsimple g) where negateG (Qsimple x y) = Qsimple (negateG x) (negateG y)
instance (Eq g, Monoid g, Additive g) => Additive (Qsimple g)
instance GrpFunctor Qsimple where mapG f (Qsimple x y) = Qsimple (mapG f x) (mapG f y)

-- MonadQuery Also requires that QueryResult be a monoid;  this reflects the
-- idea that the result can be updated as new data is sent to the frontend;
-- with "updates" being appended to the left.
-- That's the reason for the First and Max values above.
--
-- Those are also the reason for the Maybe wrappers in both cases,  it's
-- neccessary to distinguish the two states of "the data is absent because it
-- doesn't exist in the backend" from "the data is absent because you haven't
-- recieved it yet".
instance Semigroup Rsimple where Rsimple posts maxId <> Rsimple posts' maxId' = Rsimple (posts <> posts') (maxId <> maxId')
instance Monoid Rsimple where { mempty = Rsimple mempty mempty }

-- we associate the two types, query and response, with Query;  which is also
-- essentially boilerplate code.  the single method for Query; crop, should
-- restrict the query result to only that which matches the query.
-- Crop has two essential duities.  It's used in query handlers  that call runQueryT to
instance Query (Qsimple g) where
  type QueryResult (Qsimple g) = Rsimple
  crop (Qsimple postsQ maxIdQ) (Rsimple postsR maxIdR) = Rsimple (cropMap postsQ postsR) (cropMap maxIdQ maxIdR)
    where cropMap q r = MonoidalMap $ Map.intersection (getMonoidalMap r) (unGrpMap q)

-- We now can write code that "queries" for posts.  Note that the distinction
-- between "not yet loaded"  and "doesnt exist at all" is reflected in two
-- different Maybe's.  resist the urge to "join" the two together.  That's a
-- sure recipe for annoying glitches which flashes "deleted" right before
-- showing the user their data.
--
-- Once again we see some amount of boilerplate; we construct the query by
-- building up from the given  field; and then need to tear down the query
-- result by examining the corresponding field;
watchPost :: (MonadQuery t (Qsimple SelectedCount) m, Reflex t, Monad m)
  => Dynamic t PostId -> m (Dynamic t (Maybe (Maybe Post)))
watchPost postIds = do
  queryResult <- queryDyn $ ffor postIds $ \postId -> mempty { _q_posts = GrpMap (Map.singleton postId 1) }
  return $ ffor2 postIds queryResult $ \postId r -> getFirst <$> view (at postId) (_r_posts r)

watchLatestPostId :: (MonadQuery t (Qsimple SelectedCount) m, Reflex t, Monad m)
  => m (Dynamic t (Maybe (Maybe PostId)))
watchLatestPostId = do
  queryResult <- queryDyn $ constDyn $  mempty { _q_latestPostId = GrpMap (Map.singleton () 1) }
  return $ ffor queryResult $ \r -> getMax <$> view (at ()) (_r_latestPostId r)

displayLatestPost :: (MonadHold t m, MonadFix m, MonadQuery t (Qsimple SelectedCount) m, Reflex t, DomBuilder t m, PostBuild t m)
  => m ()
displayLatestPost = do
  mdmId <- maybeDyn =<< watchLatestPostId
  dyn_ $ ffor mdmId $ \case
    Nothing -> text "Loading ..."
    Just dmId -> do
      mdId <- maybeDyn dmId
      dyn_ $ ffor mdId $ \case
        Nothing -> text "No posts found"
        Just dId -> displayPost dId

displayPost
  :: (DomBuilder t m, MonadQuery t (Qsimple SelectedCount) m, PostBuild t m, MonadHold t m, MonadFix m)
  => Dynamic t PostId -> m ()
displayPost postId = do
  mdmPost <- maybeDyn =<< watchPost postId
  dyn_ $ ffor mdmPost $ \case
    Nothing -> text "Loading post ..."
    Just dmPost -> do
      mdPost <- maybeDyn dmPost
      dyn_ $ ffor mdPost $ \case
        Nothing -> text "Post Not Found"
        Just dPost -> dynText dPost

-- we can try to improve the situation in essentially all of these cases above
-- by factoring out the common parts using something resembling the HKD
-- Pattern;  when we need to associate a group with each query; we can use
-- `Const g`; and for the result which demands only the result data for that
-- key, we can use Identity
-- A downside is that the boilerplate instances, even the ones that be normally be derived.
data Qhkd (f :: * -> *) = Qhkd
  { _qhkd_posts :: MonoidalMap PostId (f (First (Maybe Post))) -- ^ posts
  , _qhkd_latestPostId :: MonoidalMap () (f (Max (Maybe PostId))) -- ^ the max post id;
  }

type Qhkd_query g = Qhkd (Const g)
type Qhkd_response = Qhkd Identity

-- We can instead observe the pattern that "most" of the shape of a record of
-- queries/responses can be  decomposed into products of maps.  another way of expressing the same concept is with a DMap.
-- with this approach;
data Qtag (a :: *) where
  Qtag_Posts        :: PostId -> Qtag (First (Maybe Post))
  Qtag_LatestPostId :: Qtag (Max (Maybe PostId))

type Qtag_query g = DMap Qtag (Const g)
type Qtag_response = DMap Qtag Identity

-- Vessel takes this idea a bit further; where the above approach uses
-- parameters as values, vessel makes it "recursive";  the GADTs used have
-- "functor" parameters, and most the applied types are also functor parametric.

data Qvessel (v :: (* -> *) -> *) where
  Posts        :: Qvessel (MapV PostId (First (Maybe Post)))
  LatestPostId :: Qvessel (IdentityV (Max (Maybe PostId)))


-- using this sort of construction allows us to eliminate nearly all of the
-- boilerplate; there's a small amount of TH to derive GCompare and all of the
-- remaining instances follow from the view types in vessel
viewPost :: (MonadQuery t (Vessel Qvessel (Const SelectedCount)) m, Reflex t, Monad m)
  => Dynamic t PostId -> m (Dynamic t (Maybe (Maybe Post)))
viewPost postIds = (fmap.fmap.fmap) (getFirst . runIdentity) $ queryViewMorphism 1 $ ffor postIds $ \pid -> vessel Posts . mapVMorphism pid

viewLatestPostId :: (MonadQuery t (Vessel Qvessel (Const SelectedCount)) m, Reflex t, Monad m)
  => m (Dynamic t (Maybe (Maybe PostId)))
viewLatestPostId = (fmap.fmap.fmap) (getMax . runIdentity) $ queryViewMorphism 1 $ constDyn $ vessel LatestPostId . identityV



-- Feel free to ignore everything below this line; this is just to force me to
-- get other types "right"
---------------------------------
positive :: forall x. (Monoid x, Ord x) => x -> SelectedCount
positive x
  | x > mempty = 1
  | otherwise = 0


dischargeMonadQuery :: forall v t m a.
  ( Additive (v SelectedCount), Group (v SelectedCount), PerformEvent t m, GrpFunctor v, Eq (v SelectedCount)
  , Monoid (QueryResult (v SelectedCount)), PostBuild t m, MonadHold t m, MonadFix m
  , Query (v SelectedCount)
  , DomBuilder t m
  )
  => (v SelectedCount -> Performable m (QueryResult (v SelectedCount)))
  -> (forall m'. (PostBuild t m', MonadHold t m', DomBuilder t m', MonadFix m', MonadQuery t (v SelectedCount) m') => m' a)
  -> m a
dischargeMonadQuery getQueryResult widget = mdo

  ( result
    , iVS :: Incremental t (AdditivePatch (v SelectedCount))
    ) <- runQueryT widget v_t
  let
    vs_t :: Dynamic t (v SelectedCount) = incrementalToDynamic iVS
    dvs :: Event t (v SelectedCount) = attach (current vs_t) (updated vs_t) <&> \(vs_n, vs_n1) -> mapG positive $ mapG positive vs_n ~~ mapG positive vs_n1

  pb <- getPostBuild
  let vs_0 = tag (current vs_t) pb

  v_t <- foldDyn (<>) mempty v_n1

  v_n1 :: Event t (QueryResult (v SelectedCount))
    <- performEvent $ salign vs_0 dvs <&> \dvs' -> if dvs' /= mempty then return mempty else getQueryResult dvs'

  return result



readShowLatestPost :: (MonadIO (Performable m), PerformEvent t m, PostBuild t m, DomBuilder t m, MonadHold t m, MonadFix m) => m ()
readShowLatestPost = dischargeMonadQuery promtForIt displayLatestPost
  where
    promtForIt q = liftIO $ do
      print q
      readLn

-- annoying stuff that needs to exist but doesn't.
newtype GrpMap k v = GrpMap { unGrpMap :: Map k v } deriving (Eq, Ord, Show, Read)
type role GrpMap nominal nominal

liftNonZero :: (Monoid a, Eq a) => (a -> a -> a) -> a -> a -> Maybe a
liftNonZero f x y = if (xy /= mempty)
  then Just x
  else Nothing
  where xy = f x y

instance (Monoid g, Eq g, Ord k) => Semigroup (GrpMap k g) where
  GrpMap xs <> GrpMap ys = GrpMap $ Map.merge id id (Map.zipWithMaybeMatched $ const $ liftNonZero (<>)) xs ys

instance (Monoid g, Eq g, Ord k) => Monoid (GrpMap k g) where
  mempty = GrpMap Map.empty
  mappend = (<>)

instance (Group g, Eq g, Ord k) => Group (GrpMap k g) where
  negateG (GrpMap xs) = GrpMap $ fmap negateG xs
  GrpMap xs ~~ GrpMap ys = GrpMap $ Map.merge id (Map.mapMissing $ const $ negateG) (Map.zipWithMaybeMatched $ const $ liftNonZero (~~)) xs ys

instance Group g => Group (r -> g) where negateG = fmap negateG
instance Group g => Group (Identity g) where negateG = fmap negateG
instance Group (Proxy x) where negateG _ = Proxy

instance Group () where negateG _ = ()
instance (Group a, Group b) => Group (a, b) where negateG (x, y) = (negateG x, negateG y)

class (forall g. (Eq g, Group g) => Group (f g)) => GrpFunctor f where
  mapG :: (Eq b, Group b) => (a -> b) -> f a -> f b

-- distributive functors can still be groups.
instance GrpFunctor ((->) r) where mapG = fmap
instance GrpFunctor Proxy where mapG = fmap
instance GrpFunctor Identity where mapG = fmap

instance Group h => GrpFunctor (Const h) where mapG = fmap

instance Ord k => GrpFunctor (GrpMap k) where
  mapG f (GrpMap xs) = GrpMap $ Map.mapMaybe (\x ->
    let fx = f x
    in if fx /= mempty
    then Just fx
    else Nothing) xs



deriveArgDict ''Qvessel
-- deriveJSONGADT ''Qvessel
deriveGEq ''Qvessel
deriveGCompare ''Qvessel
deriveGShow ''Qvessel
