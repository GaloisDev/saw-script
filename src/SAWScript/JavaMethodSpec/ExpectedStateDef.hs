{- |
Module           : $Header$
Description      :
License          : Free for non-commercial use. See LICENSE.
Stability        : provisional
Point-of-contact : atomb
-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ViewPatterns #-}
module SAWScript.JavaMethodSpec.ExpectedStateDef
  ( ExpectedStateDef(..)
  , esdRefName
  , initializeVerification
    -- * Ut
  ) where

import Control.Lens
import Control.Monad
import Control.Monad.State.Strict
import Data.Int
import qualified Data.JVM.Symbolic.AST as JSS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe
import qualified Text.PrettyPrint.HughesPJ as PP

import Language.JVM.Common (ppFldId)

import qualified Verifier.Java.Codebase as JSS
import qualified Verifier.Java.Common as JSS
import qualified Verifier.Java.Simulator as JSS

import qualified SAWScript.CongruenceClosure as CC
import qualified SAWScript.JavaExpr as TC
import SAWScript.JavaMethodSpec.Evaluator

import SAWScript.JavaMethodSpecIR
import SAWScript.Utils
  ( SAWCtx
  , basic_ss
  , ftext
  , throwIOExecException
  )

import Verifier.SAW.Prelude
import Verifier.SAW.Recognizer
import Verifier.SAW.Rewriter
import Verifier.SAW.SharedTerm

import Verifier.SAW.Cryptol (scCryptolEq)

-- ExpectedStateDef {{{1

-- | Describes expected result of computation.
data ExpectedStateDef = ESD {
         -- | Location that we started from.
         esdStartLoc :: JSS.Breakpoint
         -- | Initial path state (used for evaluating expressions in
         -- verification).
       , esdInitialPathState :: SpecPathState

       , esdJavaExprs :: !(Map String TC.JavaExpr)
         -- | Stores initial assignments.
       , esdInitialAssignments :: !([(TC.JavaExpr, SharedTerm SAWCtx)])
         -- | Map from references back to Java expressions denoting them.
       , esdRefExprMap :: !(Map JSS.Ref [TC.JavaExpr])
         -- | Expected return value or Nothing if method returns void.
       , esdReturnValue :: !(Maybe SpecJavaValue)
         -- | Maps instance fields to expected value, or Nothing if value may
         -- be arbitrary.
       , esdInstanceFields :: !(Map (JSS.Ref, JSS.FieldId) (Maybe SpecJavaValue))
         -- | Maps static fields to expected value, or Nothing if value may
         -- be arbitrary.
       , esdStaticFields :: !(Map JSS.FieldId (Maybe SpecJavaValue))
         -- | Maps reference to expected node, or Nothing if value may be arbitrary.
       , esdArrays :: !(Map JSS.Ref (Maybe (Int32, SharedTerm SAWCtx)))
       }

-- | Return the name of a reference from the expected state def.
esdRefName :: JSS.Ref -> ExpectedStateDef -> String
esdRefName JSS.NullRef _ = "null"
esdRefName ref esd =
  case Map.lookup ref (esdRefExprMap esd) of
    Just cl -> ppJavaExprEquivClass cl
    Nothing -> "fresh allocation"

-- Initial state generation {{{1

-- | State for running the behavior specifications in a method override.
data ESGState = ESGState {
         esContext :: SharedContext SAWCtx
       , esMethod :: JSS.Method
       , esJavaExprs :: Map String TC.JavaExpr
       , esExprRefMap :: Map TC.JavaExpr JSS.Ref
       , esInitialAssignments :: [(TC.JavaExpr, SharedTerm SAWCtx)]
       , esInitialPathState :: SpecPathState
       , esReturnValue :: Maybe SpecJavaValue
       , esInstanceFields :: Map (JSS.Ref, JSS.FieldId) (Maybe SpecJavaValue)
       , esStaticFields :: Map JSS.FieldId (Maybe SpecJavaValue)
       , esArrays :: Map JSS.Ref (Maybe (Int32, SharedTerm SAWCtx))
       , esErrors :: [String]
       }

-- | Monad used to execute statements in a behavior specification for a method
-- override.
type ExpectedStateGenerator = StateT ESGState IO

esEval :: (EvalContext -> ExprEvaluator b) -> ExpectedStateGenerator b
esEval fn = do
  sc <- gets esContext
  m <- gets esJavaExprs
  initPS <- gets esInitialPathState
  let ec = evalContextFromPathState sc m initPS
  res <- runEval (fn ec)
  case res of
    Left _expr -> error "internal: esEval failed to evaluate expression"
    Right v   -> return v

esError :: String -> ExpectedStateGenerator ()
esError err = modify $ \es -> es { esErrors = err : esErrors es }

esGetInitialPathState :: ExpectedStateGenerator SpecPathState
esGetInitialPathState = gets esInitialPathState

esPutInitialPathState :: SpecPathState -> ExpectedStateGenerator ()
esPutInitialPathState ps = modify $ \es -> es { esInitialPathState = ps }

esModifyInitialPathState :: (SpecPathState -> SpecPathState)
                         -> ExpectedStateGenerator ()
esModifyInitialPathState fn =
  modify $ \es -> es { esInitialPathState = fn (esInitialPathState es) }

esModifyInitialPathStateIO :: (SpecPathState -> IO SpecPathState)
                         -> ExpectedStateGenerator ()
esModifyInitialPathStateIO fn =
  do s0 <- esGetInitialPathState
     esPutInitialPathState =<< liftIO (fn s0)

esAddEqAssertion :: SharedContext SAWCtx -> String -> SharedTerm SAWCtx -> SharedTerm SAWCtx
                 -> ExpectedStateGenerator ()
esAddEqAssertion sc _nm x y =
  do prop <- liftIO (scEq sc x y)
     esModifyInitialPathStateIO (addAssertion sc prop)

-- | Assert that two terms are equal.
esAssertEq :: String -> SpecJavaValue -> SpecJavaValue
           -> ExpectedStateGenerator ()
esAssertEq nm (JSS.RValue x) (JSS.RValue y) = do
  when (x /= y) $
    esError $ "internal: Asserted different references for " ++ nm ++ " are equal."
esAssertEq nm (JSS.IValue x) (JSS.IValue y) = do
  sc <- gets esContext
  esAddEqAssertion sc nm x y
esAssertEq nm (JSS.LValue x) (JSS.LValue y) = do
  sc <- gets esContext
  esAddEqAssertion sc nm x y
esAssertEq _ _ _ = esError "internal: esAssertEq given illegal arguments."

-- | Set value in initial state.
esSetJavaValue :: TC.JavaExpr -> SpecJavaValue -> ExpectedStateGenerator ()
esSetJavaValue e@(CC.Term exprF) v = do
  -- liftIO $ putStrLn $ "Setting Java value for " ++ show e
  case exprF of
    -- TODO: the following is ugly, and doesn't make good use of lenses
    TC.Local _ idx _ -> do
      ps <- esGetInitialPathState
      let ls = case JSS.currentCallFrame ps of
                 Just cf -> cf ^. JSS.cfLocals
                 Nothing -> Map.empty
          ps' = (JSS.pathStack %~ updateLocals) ps
          updateLocals (f:r) = (JSS.cfLocals %~ Map.insert idx v) f : r
          updateLocals [] =
            error "internal: esSetJavaValue of local with empty call stack"
      -- liftIO $ putStrLn $ "Local " ++ show idx ++ " with stack " ++ show ls
      case Map.lookup idx ls of
        Just oldValue -> esAssertEq (TC.ppJavaExpr e) oldValue v
        Nothing -> esPutInitialPathState ps'
    -- TODO: the following is ugly, and doesn't make good use of lenses
    TC.InstanceField refExpr f -> do
      -- Lookup refrence associated to refExpr
      Just ref <- Map.lookup refExpr <$> gets esExprRefMap
      ps <- esGetInitialPathState
      case Map.lookup (ref,f) (ps ^. JSS.pathMemory . JSS.memInstanceFields) of
        Just oldValue -> esAssertEq (TC.ppJavaExpr e) oldValue v
        Nothing -> esPutInitialPathState $
          (JSS.pathMemory . JSS.memInstanceFields %~ Map.insert (ref,f) v) ps
    TC.StaticField f -> do
      ps <- esGetInitialPathState
      case Map.lookup f (ps ^. JSS.pathMemory . JSS.memStaticFields) of
        Just oldValue -> esAssertEq (TC.ppJavaExpr e) oldValue v
        Nothing -> esPutInitialPathState $
          (JSS.pathMemory . JSS.memStaticFields %~ Map.insert f v) ps

esResolveLogicExprs :: TC.JavaExpr -> SharedTerm SAWCtx -> [TC.LogicExpr]
                    -> ExpectedStateGenerator (SharedTerm SAWCtx)
esResolveLogicExprs e tp [] = do
  sc <- gets esContext
  -- Create input variable.
  -- liftIO $ putStrLn $ "Creating global of type: " ++ show tp
  -- TODO: look e up in map, instead
  liftIO $ scFreshGlobal sc (TC.ppJavaExpr e) tp
esResolveLogicExprs _ _ (hrhs:rrhs) = do
  sc <- gets esContext
  -- liftIO $ putStrLn $ "Evaluating " ++ show hrhs
  t <- esEval $ evalLogicExpr hrhs
  -- Add assumptions for other equivalent expressions.
  forM_ rrhs $ \rhsExpr -> do
    rhs <- esEval $ evalLogicExpr rhsExpr
    esModifyInitialPathStateIO $ \s0 -> do prop <- scCryptolEq sc t rhs
                                           addAssumption sc prop s0
  -- Return value.
  return t

esSetLogicValues :: SharedContext SAWCtx -> [TC.JavaExpr] -> SharedTerm SAWCtx
                 -> [TC.LogicExpr]
                 -> ExpectedStateGenerator ()
esSetLogicValues _ [] _ _ = esError "empty class passed to esSetLogicValues"
esSetLogicValues sc cl@(rep:_) tp lrhs = do
  -- liftIO $ putStrLn $ "Setting logic values for: " ++ show cl
  -- Get value of rhs.
  value <- esResolveLogicExprs rep tp lrhs
  -- Update Initial assignments.
  modify $ \es -> es { esInitialAssignments =
                         map (\e -> (e,value)) cl ++  esInitialAssignments es }
  ty <- liftIO $ scTypeOf sc value
  -- Update value.
  case ty of
    (isVecType (const (return ())) -> Just (n :*: _)) -> do
       refs <- forM cl $ \expr -> do
                 JSS.RValue ref <- esEval $ evalJavaExpr expr
                 return ref
       forM_ refs $
         \r -> esModifyInitialPathState (setArrayValue r (fromIntegral n) value)
    (asBitvectorType -> Just 32) ->
       mapM_ (flip esSetJavaValue (JSS.IValue value)) cl
    (asBitvectorType -> Just 64) ->
       mapM_ (flip esSetJavaValue (JSS.LValue value)) cl
    _ -> esError "internal: initializing Java values given bad rhs."

esStep :: BehaviorCommand -> ExpectedStateGenerator ()
esStep (AssertPred _ expr) = do
  sc <- gets esContext
  v <- esEval $ evalLogicExpr expr
  esModifyInitialPathStateIO $ addAssumption sc v
esStep (AssumePred expr) = do
  sc <- gets esContext
  v <- esEval $ evalLogicExpr expr
  esModifyInitialPathStateIO $ addAssumption sc v
esStep (ReturnValue expr) = do
  v <- esEval $ evalMixedExpr expr
  modify $ \es -> es { esReturnValue = Just v }
esStep (EnsureInstanceField _pos refExpr f rhsExpr) = do
  -- Evaluate expressions.
  ref <- esEval $ evalJavaRefExpr refExpr
  value <- esEval $ evalMixedExpr rhsExpr
  -- Get dag engine
  sc <- gets esContext
  -- Check that instance field is already defined, if so add an equality check for that.
  ifMap <- gets esInstanceFields
  case (Map.lookup (ref, f) ifMap, value) of
    (Nothing, _) -> return ()
    (Just Nothing, _) -> return ()
    (Just (Just (JSS.RValue prev)), JSS.RValue new)
      | prev == new -> return ()
    (Just (Just (JSS.IValue prev)), JSS.IValue new) ->
       esAddEqAssertion sc (show refExpr) prev new
    (Just (Just (JSS.LValue prev)), JSS.LValue new) ->
       esAddEqAssertion sc (show refExpr) prev new
    -- TODO: See if we can give better error message here.
    -- Perhaps this just ends up meaning that we need to verify the assumptions in this
    -- behavior are inconsistent.
    _ -> esError "internal: Incompatible values assigned to instance field."
  -- Define instance field post condition.
  modify $ \es ->
    es { esInstanceFields = Map.insert (ref,f) (Just value) (esInstanceFields es) }
esStep (EnsureStaticField _pos f rhsExpr) = do
  value <- esEval $ evalMixedExpr rhsExpr
  -- Get dag engine
  sc <- gets esContext
  -- Check that instance field is already defined, if so add an equality check for that.
  sfMap <- gets esStaticFields
  case (Map.lookup f sfMap, value) of
    (Nothing, _) -> return ()
    (Just Nothing, _) -> return ()
    (Just (Just (JSS.RValue prev)), JSS.RValue new)
      | prev == new -> return ()
    (Just (Just (JSS.IValue prev)), JSS.IValue new) ->
       esAddEqAssertion sc (ppFldId f) prev new
    (Just (Just (JSS.LValue prev)), JSS.LValue new) ->
       esAddEqAssertion sc (ppFldId f) prev new
    -- TODO: See if we can give better error message here.
    -- Perhaps this just ends up meaning that we need to verify the assumptions in this
    -- behavior are inconsistent.
    _ -> esError "internal: Incompatible values assigned to static field."
  modify $ \es ->
    es { esStaticFields = Map.insert f (Just value) (esStaticFields es) }
esStep (ModifyInstanceField refExpr f) = do
  -- Evaluate expressions.
  ref <- esEval $ evalJavaRefExpr refExpr
  es <- get
  -- Add postcondition if value has not been assigned.
  when (Map.notMember (ref, f) (esInstanceFields es)) $ do
    put es { esInstanceFields = Map.insert (ref,f) Nothing (esInstanceFields es) }
esStep (ModifyStaticField f) = do
  es <- get
  -- Add postcondition if value has not been assigned.
  when (Map.notMember f (esStaticFields es)) $ do
    put es { esStaticFields = Map.insert f Nothing (esStaticFields es) }
esStep (EnsureArray _pos lhsExpr rhsExpr) = do
  -- Evaluate expressions.
  ref    <- esEval $ evalJavaRefExpr lhsExpr
  value  <- esEval $ evalMixedExprAsLogic rhsExpr
  -- Get dag engine
  sc <- gets esContext
  ss <- liftIO $ basic_ss sc
  ty <- liftIO $ scTypeOf sc value >>= rewriteSharedTerm sc ss
  case ty of
    (isVecType (const (return ())) -> Just (w :*: _)) -> do
      let l = fromIntegral w
      -- Check if array has already been assigned value.
      aMap <- gets esArrays
      case Map.lookup ref aMap of
        Just (Just (oldLen, prev))
          | l /= fromIntegral oldLen -> esError "internal: array changed size."
          | otherwise -> esAddEqAssertion sc (show lhsExpr) prev value
        _ -> return ()
      -- Define instance field post condition.
      modify $ \es -> es { esArrays = Map.insert ref (Just (l, value)) (esArrays es) }
    _ -> esError "internal: right hand side of array ensure clause has non-array type."
esStep (ModifyArray refExpr _) = do
  ref <- esEval $ evalJavaRefExpr refExpr
  es <- get
  -- Add postcondition if value has not been assigned.
  when (Map.notMember ref (esArrays es)) $ do
    put es { esArrays = Map.insert ref Nothing (esArrays es) }

-----------------------------------------------------------------------------
-- initializeVerification

initializeVerification :: JSS.MonadSim (SharedContext SAWCtx) m =>
                          SharedContext SAWCtx
                       -> JavaMethodSpecIR
                       -> BehaviorSpec
                       -> RefEquivConfiguration
                       -> JSS.Simulator (SharedContext SAWCtx) m ExpectedStateDef
initializeVerification sc ir bs refConfig = do
  exprRefs <- mapM (JSS.genRef . TC.jssTypeOfActual . snd) refConfig
  let refAssignments = (map fst refConfig `zip` exprRefs)
      m = specJavaExprNames ir
      --key = JSS.methodKey (specMethod ir)
      pushFrame cs = fromMaybe (error "internal: failed to push call frame") mcs'
        where
          mcs' = JSS.pushCallFrame (JSS.className (specMethodClass ir))
                                   (specMethod ir)
                                   JSS.entryBlock -- FIXME: not the right block
                                   Map.empty
                                   cs
  -- liftIO $ print refAssignments
  JSS.modifyCSM_ (return . pushFrame)
  let updateInitializedClasses mem =
        foldr (flip JSS.setInitializationStatus JSS.Initialized)
              mem
              (specInitializedClasses ir)
  JSS.modifyPathM_ (PP.text "initializeVerification") $
    return . (JSS.pathMemory %~ updateInitializedClasses)
  -- TODO: add breakpoints once local specs exist
  --forM_ (Map.keys (specBehaviors ir)) $ JSS.addBreakpoint clName key
  -- TODO: set starting PC
  initPS <- JSS.getPath (PP.text "initializeVerification")
  let initESG = ESGState { esContext = sc
                         , esMethod = specMethod ir
                         , esJavaExprs = m
                         , esExprRefMap = Map.fromList
                             [ (e, r) | (cl,r) <- refAssignments, e <- cl ]
                         , esInitialAssignments = []
                         , esInitialPathState = initPS
                         , esReturnValue = Nothing
                         , esInstanceFields = Map.empty
                         , esStaticFields = Map.empty
                         , esArrays = Map.empty
                         , esErrors = []
                         }
  -- liftIO $ putStrLn "Starting to initialize state."
  es <- liftIO $ flip execStateT initESG $ do
          -- Set references
          -- liftIO $ putStrLn "Setting references."
          forM_ refAssignments $ \(cl,r) ->
            forM_ cl $ \e -> esSetJavaValue e (JSS.RValue r)
          -- Set initial logic values.
          -- liftIO $ putStrLn "Setting logic values."
          lcs <- liftIO $ bsLogicClasses sc m bs refConfig
          case lcs of
            Nothing ->
              let msg = "Unresolvable cyclic dependencies between assumptions."
               in throwIOExecException (specPos ir) (ftext msg) ""
            Just assignments -> mapM_ (\(l,t,r) -> esSetLogicValues sc l t r) assignments
          -- Process commands
          -- liftIO $ putStrLn "Running commands."
          mapM esStep (bsCommands bs)
  let ps = esInitialPathState es
      errs = esErrors es
      indent2 = (' ' :) . (' ' :)
  unless (null errs) $ fail . unlines $
    "Errors while initializing verification:" : map indent2 errs
  JSS.modifyPathM_ (PP.text "initializeVerification") (\_ -> return ps)
  return ESD { esdStartLoc = bsLoc bs
             , esdInitialPathState = esInitialPathState es
             , esdInitialAssignments = reverse (esInitialAssignments es)
             , esdJavaExprs = m
             , esdRefExprMap =
                  Map.fromList [ (r, cl) | (cl,r) <- refAssignments ]
             , esdReturnValue = esReturnValue es
               -- Create esdArrays map while providing entry for unspecified
               -- expressions.
             , esdInstanceFields =
                 Map.union (esInstanceFields es)
                           (Map.map Just (ps ^. JSS.pathMemory . JSS.memInstanceFields))
             , esdStaticFields =
                 Map.union (esStaticFields es)
                           (Map.map Just (ps ^. JSS.pathMemory . JSS.memStaticFields))
               -- Create esdArrays map while providing entry for unspecified
               -- expressions.
             , esdArrays =
                 Map.union (esArrays es)
                           (Map.map Just (ps ^. JSS.pathMemory . JSS.memScalarArrays))
             }