{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE EmptyDataDecls #-}

{- |
Module      : Verifier.SAW.Simulator.SBV
Copyright   : Galois, Inc. 2012-2015
License     : BSD3
Maintainer  : huffman@galois.com
Stability   : experimental
Portability : non-portable (language extensions)
-}
module Verifier.SAW.Simulator.SBV
  ( sbvSolve
  , sbvSolveBasic
  , SValue
  , Labeler(..)
  , sbvCodeGen_definition
  , sbvCodeGen
  , toWord
  , toBool
  , module Verifier.SAW.Simulator.SBV.SWord
  ) where

import Data.SBV.Dynamic

import Verifier.SAW.Simulator.SBV.SWord

import Control.Lens ((<&>))
import qualified Control.Arrow as A

import Data.Bits
import Data.IORef
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Vector (Vector)
import qualified Data.Vector as V

import Data.Traversable as T
#if !MIN_VERSION_base(4,8,0)
import Control.Applicative
#endif
import Control.Monad.IO.Class
import Control.Monad.State as ST

import qualified Verifier.SAW.Recognizer as R
import qualified Verifier.SAW.Simulator as Sim
import qualified Verifier.SAW.Simulator.Prims as Prims
import Verifier.SAW.SharedTerm
import Verifier.SAW.Simulator.Value
import Verifier.SAW.TypedAST (FieldName, Module, identName)
import Verifier.SAW.FiniteValue (FirstOrderType(..), asFirstOrderType)

data SBV

type instance EvalM SBV = IO
type instance VBool SBV = SBool
type instance VWord SBV = SWord
type instance VInt  SBV = SInteger
type instance Extra SBV = SbvExtra

type SValue = Value SBV
--type SThunk = Thunk SBV

data SbvExtra =
  SStream (Integer -> IO SValue) (IORef (Map Integer SValue))

instance Show SbvExtra where
  show (SStream _ _) = "<SStream>"

pure1 :: Applicative f => (a -> b) -> a -> f b
pure1 f x = pure (f x)

pure2 :: Applicative f => (a -> b -> c) -> a -> b -> f c
pure2 f x y = pure (f x y)

pure3 :: Applicative f => (a -> b -> c -> d) -> a -> b -> c -> f d
pure3 f x y z = pure (f x y z)

prims :: Prims.BasePrims SBV
prims =
  Prims.BasePrims
  { Prims.bpAsBool  = svAsBool
  , Prims.bpUnpack  = svUnpack
  , Prims.bpPack    = pure1 symFromBits
  , Prims.bpBvAt    = pure2 svAt
  , Prims.bpBvLit   = pure2 literalSWord
  , Prims.bpBvSize  = intSizeOf
  , Prims.bpBvJoin  = pure2 svJoin
  , Prims.bpBvSlice = pure3 svSlice
    -- Conditionals
  , Prims.bpMuxBool  = pure3 svIte
  , Prims.bpMuxWord  = pure3 svIte
  , Prims.bpMuxInt   = pure3 svIte
  , Prims.bpMuxExtra = pure3 extraFn
    -- Booleans
  , Prims.bpTrue   = svTrue
  , Prims.bpFalse  = svFalse
  , Prims.bpNot    = pure1 svNot
  , Prims.bpAnd    = pure2 svAnd
  , Prims.bpOr     = pure2 svOr
  , Prims.bpXor    = pure2 svXOr
  , Prims.bpBoolEq = pure2 svEqual
    -- Bitvector logical
  , Prims.bpBvNot  = pure1 svNot
  , Prims.bpBvAnd  = pure2 svAnd
  , Prims.bpBvOr   = pure2 svOr
  , Prims.bpBvXor  = pure2 svXOr
    -- Bitvector arithmetic
  , Prims.bpBvNeg  = pure1 svUNeg
  , Prims.bpBvAdd  = pure2 svPlus
  , Prims.bpBvSub  = pure2 svMinus
  , Prims.bpBvMul  = pure2 svTimes
  , Prims.bpBvUDiv = pure2 svQuot
  , Prims.bpBvURem = pure2 svRem
  , Prims.bpBvSDiv = \x y -> pure (svUnsign (svQuot (svSign x) (svSign y)))
  , Prims.bpBvSRem = \x y -> pure (svUnsign (svRem (svSign x) (svSign y)))
  , Prims.bpBvLg2  = pure1 sLg2
    -- Bitvector comparisons
  , Prims.bpBvEq   = pure2 svEqual
  , Prims.bpBvsle  = \x y -> pure (svLessEq (svSign x) (svSign y))
  , Prims.bpBvslt  = \x y -> pure (svLessThan (svSign x) (svSign y))
  , Prims.bpBvule  = pure2 svLessEq
  , Prims.bpBvult  = pure2 svLessThan
  , Prims.bpBvsge  = \x y -> pure (svGreaterEq (svSign x) (svSign y))
  , Prims.bpBvsgt  = \x y -> pure (svGreaterThan (svSign x) (svSign y))
  , Prims.bpBvuge  = pure2 svGreaterEq
  , Prims.bpBvugt  = pure2 svGreaterThan
    -- Bitvector shift/rotate
  , Prims.bpBvRolInt = pure2 svRol'
  , Prims.bpBvRorInt = pure2 svRor'
  , Prims.bpBvShlInt = pure3 svShl'
  , Prims.bpBvShrInt = pure3 svShr'
  , Prims.bpBvRol    = pure2 svRotateLeft
  , Prims.bpBvRor    = pure2 svRotateRight
  , Prims.bpBvShl    = pure3 svShiftL
  , Prims.bpBvShr    = pure3 svShiftR
    -- Integer operations
  , Prims.bpIntAdd = pure2 svPlus
  , Prims.bpIntSub = pure2 svMinus
  , Prims.bpIntMul = pure2 svTimes
  , Prims.bpIntDiv = pure2 svQuot
  , Prims.bpIntMod = pure2 svRem
  , Prims.bpIntNeg = pure1 svUNeg
  , Prims.bpIntEq  = pure2 svEqual
  , Prims.bpIntLe  = pure2 svLessEq
  , Prims.bpIntLt  = pure2 svLessThan
  , Prims.bpIntMin = undefined --pure2 min
  , Prims.bpIntMax = undefined --pure2 max
  }

constMap :: Map Ident SValue
constMap =
  Map.union (Prims.constMap prims) $
  Map.fromList
  [
  -- Shifts
    ("Prelude.bvShl" , bvShLOp)
  , ("Prelude.bvShr" , bvShROp)
  , ("Prelude.bvSShr", bvSShROp)
  -- Integers
  --XXX , ("Prelude.intToNat", Prims.intToNatOp)
  , ("Prelude.natToInt", natToIntOp)
  , ("Prelude.intToBv" , intToBvOp)
  , ("Prelude.bvToInt" , bvToIntOp)
  , ("Prelude.sbvToInt", sbvToIntOp)
  -- Streams
  , ("Prelude.MkStream", mkStreamOp)
  , ("Prelude.streamGet", streamGetOp)
  , ("Prelude.bvStreamGet", bvStreamGetOp)
  ]

------------------------------------------------------------
-- Coercion functions
--

bitVector :: Int -> Integer -> SWord
bitVector w i = literalSWord w i

symFromBits :: Vector SBool -> SWord
symFromBits v = V.foldl svJoin (bitVector 0 0) (V.map svToWord1 v)

toMaybeBool :: SValue -> Maybe SBool
toMaybeBool (VBool b) = Just b
toMaybeBool _  = Nothing

toBool :: SValue -> SBool
toBool (VBool b) = b
toBool sv = error $ unwords ["toBool failed:", show sv]

toWord :: SValue -> IO SWord
toWord (VWord w) = return w
toWord (VVector vv) = symFromBits <$> traverse (fmap toBool . force) vv
toWord x = fail $ unwords ["Verifier.SAW.Simulator.SBV.toWord", show x]

toMaybeWord :: SValue -> IO (Maybe SWord)
toMaybeWord (VWord w) = return (Just w)
toMaybeWord (VVector vv) = ((symFromBits <$>) . T.sequence) <$> traverse (fmap toMaybeBool . force) vv
toMaybeWord _ = return Nothing

-- | Flatten an SValue to a sequence of components, each of which is
-- either a symbolic word or a symbolic boolean. If the SValue
-- contains any values built from data constructors, then return them
-- encoded as a String.
flattenSValue :: SValue -> IO ([SVal], String)
flattenSValue v = do
  mw <- toMaybeWord v
  case mw of
    Just w -> return ([w], "")
    Nothing ->
      case v of
        VUnit                     -> return ([], "")
        VPair x y                 -> do (xs, sx) <- flattenSValue =<< force x
                                        (ys, sy) <- flattenSValue =<< force y
                                        return (xs ++ ys, sx ++ sy)
        VEmpty                    -> return ([], "")
        VField _ x y              -> do (xs, sx) <- flattenSValue =<< force x
                                        (ys, sy) <- flattenSValue y
                                        return (xs ++ ys, sx ++ sy)
        VVector (V.toList -> ts)  -> do (xss, ss) <- unzip <$> traverse (force >=> flattenSValue) ts
                                        return (concat xss, concat ss)
        VBool sb                  -> return ([sb], "")
        VWord sw                  -> return (if intSizeOf sw > 0 then [sw] else [], "")
        VCtorApp i (V.toList->ts) -> do (xss, ss) <- unzip <$> traverse (force >=> flattenSValue) ts
                                        return (concat xss, "_" ++ identName i ++ concat ss)
        VNat n                    -> return ([], "_" ++ show n)
        _ -> fail $ "Could not create sbv argument for " ++ show v

vWord :: SWord -> SValue
vWord lv = VWord lv

vBool :: SBool -> SValue
vBool l = VBool l

vInteger :: SInteger -> SValue
vInteger x = VInt x

------------------------------------------------------------
-- Function constructors

wordFun :: (SWord -> IO SValue) -> SValue
wordFun f = strictFun (\x -> toWord x >>= f)

------------------------------------------------------------
-- Indexing operations

-- | Lifts a strict mux operation to a lazy mux
lazyMux :: (SBool -> a -> a -> IO a) -> (SBool -> IO a -> IO a -> IO a)
lazyMux muxFn c tm fm =
  case svAsBool c of
    Just True  -> tm
    Just False -> fm
    Nothing    -> do
      t <- tm
      f <- fm
      muxFn c t f

-- selectV merger maxValue valueFn index returns valueFn v when index has value v
-- if index is greater than maxValue, it returns valueFn maxValue. Use the ite op from merger.
selectV :: (Ord a, Num a, Bits a) => (SBool -> b -> b -> b) -> a -> (a -> b) -> SWord -> b
selectV merger maxValue valueFn vx =
  case svAsInteger vx of
    Just i  -> valueFn (fromIntegral i)
    Nothing -> impl (intSizeOf vx) 0
  where
    impl _ x | x > maxValue || x < 0 = valueFn maxValue
    impl 0 y = valueFn y
    impl i y = merger (svTestBit vx j) (impl j (y `setBit` j)) (impl j y) where j = i - 1

-- Big-endian version of svTestBit
svAt :: SWord -> Int -> SBool
svAt x i = svTestBit x (intSizeOf x - 1 - i)

svUnpack :: SWord -> IO (Vector SBool)
svUnpack x = return (V.generate (intSizeOf x) (svAt x))

asWordList :: [SValue] -> Maybe [SWord]
asWordList = go id
 where
  go f [] = Just (f [])
  go f (VWord x : xs) = go (f . (x:)) xs
  go _ _ = Nothing

svSlice :: Int -> Int -> SWord -> SWord
svSlice i j x = svExtract (w - i - 1) (w - i - j) x
  where w = intSizeOf x

----------------------------------------
-- Shift operations

-- | op :: (n :: Nat) -> bitvector n -> Nat -> bitvector n
bvShiftOp :: (SWord -> SWord -> SWord) -> (SWord -> Int -> SWord) -> SValue
bvShiftOp bvOp natOp =
  constFun $
  wordFun $ \x -> return $
  strictFun $ \y ->
    case y of
      VNat i   -> return (vWord (natOp x j))
        where j = fromInteger (i `min` toInteger (intSizeOf x))
      VToNat v -> fmap (vWord . bvOp x) (toWord v)
      _        -> error $ unwords ["Verifier.SAW.Simulator.SBV.bvShiftOp", show y]

-- bvShl :: (w :: Nat) -> bitvector w -> Nat -> bitvector w;
bvShLOp :: SValue
bvShLOp = bvShiftOp svShiftLeft svShl

-- bvShR :: (w :: Nat) -> bitvector w -> Nat -> bitvector w;
bvShROp :: SValue
bvShROp = bvShiftOp svShiftRight svShr

-- bvSShR :: (w :: Nat) -> bitvector w -> Nat -> bitvector w;
bvSShROp :: SValue
bvSShROp = bvShiftOp bvOp natOp
  where
    bvOp w x = svUnsign (svShiftRight (svSign w) x)
    natOp w i = svUnsign (svShr (svSign w) i)

-----------------------------------------
-- Integer/bitvector conversions

-- primitive natToInt :: Nat -> Integer;
natToIntOp :: SValue
natToIntOp =
  Prims.natFun' "natToInt" $ \n -> return $
    VInt (literalSInteger (toInteger n))

-- primitive bvToInt :: (n::Nat) -> bitvector n -> Integer;
bvToIntOp :: SValue
bvToIntOp = constFun $ wordFun $ \v ->
   case svAsInteger v of
      Just i -> return $ VInt (literalSInteger i)
      Nothing -> return $ VInt (svFromIntegral KUnbounded v)

-- primitive sbvToInt :: (n::Nat) -> bitvector n -> Integer;
sbvToIntOp :: SValue
sbvToIntOp = constFun $ wordFun $ \v ->
   case svAsInteger (svSign v) of
      Just i -> return $ VInt (literalSInteger i)
      Nothing -> return $ VInt (svFromIntegral KUnbounded (svSign v))

-- primitive intToBv :: (n::Nat) -> Integer -> bitvector n;
intToBvOp :: SValue
intToBvOp =
  Prims.natFun' "intToBv n" $ \n -> return $
  Prims.intFun "intToBv x" $ \x ->
    case svAsInteger x of
      Just i -> return $ VWord $ literalSWord (fromIntegral n) i
      Nothing -> return $ VWord $ svFromIntegral (KBounded False (fromIntegral n)) x

------------------------------------------------------------
-- Rotations and shifts

svRol' :: SWord -> Integer -> SWord
svRol' x i = svRol x (fromInteger (i `mod` toInteger (intSizeOf x)))

svRor' :: SWord -> Integer -> SWord
svRor' x i = svRor x (fromInteger (i `mod` toInteger (intSizeOf x)))

svShl' :: SBool -> SWord -> Integer -> SWord
svShl' b x i = svIte b (svNot (svShl (svNot x) j)) (svShl x j)
  where j = fromInteger (i `min` toInteger (intSizeOf x))

svShr' :: SBool -> SWord -> Integer -> SWord
svShr' b x i = svIte b (svNot (svShr (svNot x) j)) (svShr x j)
  where j = fromInteger (i `min` toInteger (intSizeOf x))

svShiftL :: SBool -> SWord -> SWord -> SWord
svShiftL b x i = svIte b (svNot (svShiftLeft (svNot x) i)) (svShiftLeft x i)

svShiftR :: SBool -> SWord -> SWord -> SWord
svShiftR b x i = svIte b (svNot (svShiftRight (svNot x) i)) (svShiftRight x i)

------------------------------------------------------------
-- Stream operations

-- MkStream :: (a :: sort 0) -> (Nat -> a) -> Stream a;
mkStreamOp :: SValue
mkStreamOp =
  constFun $
  strictFun $ \f -> do
    r <- newIORef Map.empty
    return $ VExtra (SStream (\n -> apply f (ready (VNat n))) r)

-- streamGet :: (a :: sort 0) -> Stream a -> Nat -> a;
streamGetOp :: SValue
streamGetOp =
  constFun $
  strictFun $ \xs -> return $
  Prims.natFun'' "streamGetOp" $ \n -> lookupSStream xs (toInteger n)

-- bvStreamGet :: (a :: sort 0) -> (w :: Nat) -> Stream a -> bitvector w -> a;
bvStreamGetOp :: SValue
bvStreamGetOp =
  constFun $
  constFun $
  strictFun $ \xs -> return $
  wordFun $ \ilv ->
  selectV (lazyMux muxBVal) ((2 ^ intSizeOf ilv) - 1) (lookupSStream xs) ilv

lookupSStream :: SValue -> Integer -> IO SValue
lookupSStream (VExtra (SStream f r)) n = do
   m <- readIORef r
   case Map.lookup n m of
     Just v  -> return v
     Nothing -> do v <- f n
                   writeIORef r (Map.insert n v m)
                   return v
lookupSStream _ _ = fail "expected Stream"

------------------------------------------------------------
-- Misc operations

-- | Ceiling (log_2 x)
sLg2 :: SWord -> SWord
sLg2 x = go 0
  where
    lit n = literalSWord (intSizeOf x) n
    go i | i < intSizeOf x = svIte (svLessEq x (lit (2^i))) (lit (toInteger i)) (go (i + 1))
         | otherwise       = lit (toInteger i)

------------------------------------------------------------
-- Ite ops

muxBVal :: SBool -> SValue -> SValue -> IO SValue
muxBVal = Prims.muxValue prims

extraFn :: SBool -> SbvExtra -> SbvExtra -> SbvExtra
extraFn _ _ _ = error "iteOp: malformed arguments (extraFn)"

------------------------------------------------------------
-- External interface

-- | Abstract constants with names in the list 'unints' are kept as
-- uninterpreted constants; all others are unfolded.
sbvSolveBasic :: Module -> Map Ident SValue -> [String] -> Term -> IO SValue
sbvSolveBasic m addlPrims unints t = do
  let unintSet = Set.fromList unints
  let uninterpreted nm ty
        | Set.member nm unintSet = Just $ parseUninterpreted [] nm ty
        | otherwise              = Nothing
  cfg <- Sim.evalGlobal m (Map.union constMap addlPrims)
         (const (parseUninterpreted []))
         uninterpreted
  Sim.evalSharedTerm cfg t

parseUninterpreted :: [SVal] -> String -> SValue -> IO SValue
parseUninterpreted cws nm ty =
  case ty of
    (VPiType _ f)
      -> return $
         strictFun $ \x -> do
           (cws', suffix) <- flattenSValue x
           t2 <- f (ready x)
           parseUninterpreted (cws ++ cws') (nm ++ suffix) t2

    (VDataType "Prelude.Bool" [])
      -> return $ vBool $ mkUninterpreted KBool cws nm

    VIntType
      -> return $ vInteger $ mkUninterpreted KUnbounded cws nm

    (VVecType (VNat n) (VDataType "Prelude.Bool" []))
      -> return $ vWord $ mkUninterpreted (KBounded False (fromIntegral n)) cws nm

    (VVecType (VNat n) ety)
      -> do xs <- sequence $
                  [ parseUninterpreted cws (nm ++ "@" ++ show i) ety
                  | i <- [0 .. n-1] ]
            return (VVector (V.fromList (map ready xs)))

    VUnitType
      -> return VUnit

    (VPairType ty1 ty2)
      -> do x1 <- parseUninterpreted cws (nm ++ ".L") ty1
            x2 <- parseUninterpreted cws (nm ++ ".R") ty2
            return (VPair (ready x1) (ready x2))

    VEmptyType
      -> return VEmpty

    (VFieldType f ty1 ty2)
      -> do x1 <- parseUninterpreted cws (nm ++ ".L") ty1
            x2 <- parseUninterpreted cws (nm ++ ".R") ty2
            return (VField f (ready x1) x2)

    _ -> fail $ "could not create uninterpreted type for " ++ show ty

mkUninterpreted :: Kind -> [SVal] -> String -> SVal
mkUninterpreted k args nm = svUninterpreted k nm' Nothing args
  where nm' = "|" ++ nm ++ "|" -- enclose name to allow primes and other non-alphanum chars

asPredType :: SharedContext -> Term -> IO [Term]
asPredType sc t = do
  t' <- scWhnf sc t
  case t' of
    (R.asPi -> Just (_, t1, t2)) -> (t1 :) <$> asPredType sc t2
    (R.asBoolType -> Just ())    -> return []
    _                            -> fail $ "non-boolean result type: " ++ scPrettyTerm defaultPPOpts t'

sbvSolve :: SharedContext
         -> Map Ident SValue
         -> [String]
         -> Term
         -> IO ([Labeler], Symbolic SBool)
sbvSolve sc addlPrims unints t = do
  ty <- scTypeOf sc t
  argTs <- asPredType sc ty
  shapes <- traverse (asFirstOrderType sc) argTs
  bval <- sbvSolveBasic (scModule sc) addlPrims unints t
  (labels, vars) <- flip evalStateT 0 $ unzip <$> traverse newVars shapes
  let prd = do
              bval' <- traverse (fmap ready) vars >>= (liftIO . applyAll bval)
              case bval' of
                VBool b -> return b
                _ -> fail $ "sbvSolve: non-boolean result type. " ++ show bval'
  return (labels, prd)

data Labeler
   = BoolLabel String
   | IntegerLabel String
   | WordLabel String
   | VecLabel (Vector Labeler)
   | TupleLabel (Vector Labeler)
   | RecLabel (Map FieldName Labeler)
     deriving (Show)

nextId :: StateT Int IO String
nextId = ST.get >>= (\s-> modify (+1) >> return ("x" ++ show s))

--unzipMap :: Map k (a, b) -> (Map k a, Map k b)
--unzipMap m = (fmap fst m, fmap snd m)

myfun ::(Map String (Labeler, Symbolic SValue)) -> (Map String Labeler, Map String (Symbolic SValue))
myfun = fmap fst A.&&& fmap snd

newVars :: FirstOrderType -> StateT Int IO (Labeler, Symbolic SValue)
newVars FOTBit = nextId <&> \s-> (BoolLabel s, vBool <$> existsSBool s)
newVars FOTInt = nextId <&> \s-> (IntegerLabel s, vInteger <$> existsSInteger s)
newVars (FOTVec n FOTBit) =
  if n == 0
    then nextId <&> \s-> (WordLabel s, return (vWord (literalSWord 0 0)))
    else nextId <&> \s-> (WordLabel s, vWord <$> existsSWord s (fromIntegral n))
newVars (FOTVec n tp) = do
  (labels, vals) <- V.unzip <$> V.replicateM (fromIntegral n) (newVars tp)
  return (VecLabel labels, VVector <$> traverse (fmap ready) vals)
newVars (FOTTuple ts) = do
  (labels, vals) <- V.unzip <$> traverse newVars (V.fromList ts)
  return (TupleLabel labels, vTuple <$> traverse (fmap ready) (V.toList vals))
newVars (FOTRec tm) = do
  (labels, vals) <- myfun <$> (traverse newVars tm :: StateT Int IO (Map String (Labeler, Symbolic SValue)))
  return (RecLabel labels, vRecord <$> traverse (fmap ready) (vals :: (Map String (Symbolic SValue))))

------------------------------------------------------------
-- Code Generation

newCodeGenVars :: (Nat -> Bool) -> FirstOrderType -> StateT Int IO (SBVCodeGen SValue)
newCodeGenVars _checkSz FOTBit = nextId <&> \s -> (vBool <$> svCgInput KBool s)
newCodeGenVars _checkSz FOTInt = nextId <&> \s -> (vInteger <$> svCgInput KUnbounded s)
newCodeGenVars checkSz (FOTVec n FOTBit)
  | n == 0    = nextId <&> \_ -> return (vWord (literalSWord 0 0))
  | checkSz n = nextId <&> \s -> vWord <$> cgInputSWord s (fromIntegral n)
  | otherwise = nextId <&> \s -> fail $ "Invalid codegen bit width for input variable \'" ++ s ++ "\': " ++ show n
newCodeGenVars checkSz (FOTVec n (FOTVec m FOTBit))
  | m == 0    = nextId <&> \_ -> return (VVector $ V.fromList $ replicate (fromIntegral n) (ready $ vWord (literalSWord 0 0)))
  | checkSz m = do
      let k = KBounded False (fromIntegral m)
      vals <- nextId <&> \s -> svCgInputArr k (fromIntegral n) s
      return (VVector . V.fromList . fmap (ready . vWord) <$> vals)
  | otherwise = nextId <&> \s -> fail $ "Invalid codegen bit width for input variable array \'" ++ s ++ "\': " ++ show n
newCodeGenVars checkSz (FOTVec n tp) = do
  vals <- V.replicateM (fromIntegral n) (newCodeGenVars checkSz tp)
  return (VVector <$> traverse (fmap ready) vals)
newCodeGenVars checkSz (FOTTuple ts) = do
  vals <- traverse (newCodeGenVars checkSz) ts
  return (vTuple <$> traverse (fmap ready) vals)
newCodeGenVars checkSz (FOTRec tm) = do
  vals <- traverse (newCodeGenVars checkSz) tm
  return (vRecord <$> traverse (fmap ready) vals)

cgInputSWord :: String -> Int -> SBVCodeGen SWord
cgInputSWord s n = svCgInput (KBounded False n) s

argTypes :: SharedContext -> Term -> IO ([Term], Term)
argTypes sc t = do
  t' <- scWhnf sc t
  case t' of
    (R.asPi -> Just (_, t1, t2)) -> do
       (ts,res) <- argTypes sc t2
       return (t1:ts, res)
    _ -> return ([], t')

sbvCodeGen_definition
  :: SharedContext
  -> Map Ident SValue
  -> [String]
  -> Term
  -> (Nat -> Bool) -- ^ Allowed word sizes
  -> IO (SBVCodeGen (), [FirstOrderType], FirstOrderType)
sbvCodeGen_definition sc addlPrims unints t checkSz = do
  ty <- scTypeOf sc t
  (argTs,resTy) <- argTypes sc ty
  shapes <- traverse (asFirstOrderType sc) argTs
  resultShape <- asFirstOrderType sc resTy
  bval <- sbvSolveBasic (scModule sc) addlPrims unints t
  vars <- evalStateT (traverse (newCodeGenVars checkSz) shapes) 0
  let codegen = do
        args <- traverse (fmap ready) vars
        bval' <- liftIO (applyAll bval args)
        sbvSetResult checkSz resultShape bval'
  return (codegen, shapes, resultShape)


sbvSetResult :: (Nat -> Bool)
             -> FirstOrderType
             -> SValue
             -> SBVCodeGen ()
sbvSetResult _checkSz FOTBit (VBool b) = do
   svCgReturn b
sbvSetResult checkSz (FOTVec n FOTBit) v
   | n == 0    = return ()
   | checkSz n = do
      w <- liftIO $ toWord v
      svCgReturn w
   | otherwise =
      fail $ "Invalid word size in result: " ++ show n
sbvSetResult checkSz ft v = do
   void $ sbvSetOutput checkSz ft v 0


sbvSetOutput :: (Nat -> Bool)
             -> FirstOrderType
             -> SValue
             -> Int
             -> SBVCodeGen Int
sbvSetOutput _checkSz FOTBit (VBool b) i = do
   svCgOutput ("out_"++show i) b
   return $! i+1
sbvSetOutput checkSz (FOTVec n FOTBit) v i
   | n == 0    = return i
   | checkSz n = do
       w <- liftIO $ toWord v
       svCgOutput ("out_"++show i) w
       return $! i+1
   | otherwise =
       fail $ "Invalid word size in output " ++ show i ++ ": " ++ show n

sbvSetOutput checkSz (FOTVec n t) (VVector xv) i = do
   xs <- liftIO $ traverse force $ V.toList xv
   unless (toInteger n == toInteger (length xs)) $
     fail "sbvCodeGen: vector length mismatch when setting output values"
   case asWordList xs of
     Just ws -> do svCgOutputArr ("out_"++show i) ws
                   return $! i+1
     Nothing -> foldM (\i' x -> sbvSetOutput checkSz t x i') i xs
sbvSetOutput _checkSz (FOTTuple []) VUnit i =
   return i
sbvSetOutput checkSz (FOTTuple (t:ts)) (VPair l r) i = do
   l' <- liftIO $ force l
   r' <- liftIO $ force r
   sbvSetOutput checkSz t l' i >>= sbvSetOutput checkSz (FOTTuple ts) r'

sbvSetOutput _checkSz (FOTRec fs) VUnit i | Map.null fs = do
   return i
sbvSetOutput checkSz (FOTRec fs) (VField fn x rec) i = do
   x' <- liftIO $ force x
   case Map.lookup fn fs of
     Just t -> do
       let fs' = Map.delete fn fs
       sbvSetOutput checkSz t x' i >>= sbvSetOutput checkSz (FOTRec fs') rec
     Nothing -> fail "sbvCodeGen: type mismatch when setting record output value"
sbvSetOutput _checkSz _ft _v _i = do
   fail "sbvCode gen: type mismatch when setting output values"


sbvCodeGen :: SharedContext
           -> Map Ident SValue
           -> [String]
           -> Maybe FilePath
           -> String
           -> Term
           -> IO ()
sbvCodeGen sc addlPrims unints path fname t = do
  -- The SBV C code generator expects only these word sizes
  let checkSz n = n `elem` [8,16,32,64]

  (codegen,_,_) <- sbvCodeGen_definition sc addlPrims unints t checkSz
  compileToC path fname codegen
