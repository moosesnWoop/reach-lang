module Reach.Optimize (optimize_, optimize, Optimize) where

import Control.Monad.Reader
import Data.IORef
import qualified Data.Set as S
import qualified Data.Map.Strict as M
import Data.Maybe
import Reach.AST.Base
import Reach.AST.DLBase
import Reach.AST.LL
import Reach.AST.PL
import Reach.Counter
import Reach.Sanitize
import Reach.UnrollLoops
import Reach.Util
import Safe (atMay)

type App = ReaderT Env IO
type ConstApp = ReaderT ConstEnv IO

type AppT a = a -> App a
type ConstT a = a -> ConstApp ()

class Optimize a where
  opt :: AppT a
  gcs :: ConstT a

data Focus
  = F_Ctor
  | F_All
  | F_One SLPart
  | F_Consensus
  deriving (Eq, Ord, Show)

data CommonEnv = CommonEnv
  { ceReplaced :: M.Map DLVar (DLVar, Maybe DLArg)
  , cePrev :: M.Map DLExpr DLVar
  , ceNots :: M.Map DLVar DLArg
  , ceKnownVariants :: M.Map DLVar (SLVar, DLArg)
  , ceKnownLargeArgs :: M.Map DLVar DLLargeArg
  }

instance Show CommonEnv where
  show (CommonEnv {..}) = show ceNots

instance Semigroup CommonEnv where
  x <> y =
    CommonEnv
      { ceReplaced = g ceReplaced
      , cePrev = g cePrev
      , ceNots = g ceNots
      , ceKnownVariants = g ceKnownVariants
      , ceKnownLargeArgs = g ceKnownLargeArgs
      }
    where
      g f = f x <> f y

instance Monoid CommonEnv where
  mempty = CommonEnv mempty mempty mempty mempty mempty

data Env = Env
  { eFocus :: Focus
  , eParts :: [SLPart]
  , eEnvsR :: IORef (M.Map Focus CommonEnv)
  , eCounter :: Counter
  , eConst :: S.Set DLVar
  }

data ConstEnv = ConstEnv
  { eConstR :: IORef (M.Map DLVar Integer)
  }

focus :: Focus -> App a -> App a
focus f = local (\e -> e {eFocus = f})

focus_ctor :: App a -> App a
focus_ctor = focus F_Ctor

focus_all :: App a -> App a
focus_all = focus F_All

focus_one :: SLPart -> App a -> App a
focus_one = focus . F_One

focus_con :: App a -> App a
focus_con = focus F_Consensus

optConst :: DLVar -> App Bool
optConst v = S.member v <$> asks eConst

newScope :: App x -> App x
newScope m = do
  Env {..} <- ask
  eEnvsR' <- liftIO $ dupeIORef eEnvsR
  local (\e -> e {eEnvsR = eEnvsR'}) m

lookupCommon :: Ord a => (CommonEnv -> M.Map a b) -> a -> App (Maybe b)
lookupCommon dict obj = do
  Env {..} <- ask
  eEnvs <- liftIO $ readIORef eEnvsR
  return $ do
    cenv <- M.lookup eFocus eEnvs
    M.lookup obj (dict cenv)

rewrittenp :: DLVar -> App (Maybe (DLVar, Maybe DLArg))
rewrittenp = lookupCommon ceReplaced

repeated :: DLExpr -> App (Maybe DLVar)
repeated = \case
  DLE_Arg _ (DLA_Var dv') -> return $ Just dv'
  e -> lookupCommon cePrev e

optNotHuh :: DLArg -> App (Maybe DLArg)
optNotHuh = \case
  DLA_Var v -> lookupCommon ceNots v
  _ -> return $ Nothing

recordNotHuh :: DLLetVar -> DLArg -> App ()
recordNotHuh = \case
  DLV_Eff -> const $ return ()
  DLV_Let _ v -> \a -> do
    updateLookup
      (\cenv ->
         cenv
           { ceNots = M.insert v a $ ceNots cenv
           })

optKnownVariant :: DLVar -> App (Maybe (SLVar, DLArg))
optKnownVariant = lookupCommon ceKnownVariants

recordKnownVariant :: DLVar -> SLVar -> DLArg -> App ()
recordKnownVariant dv k va =
  updateLookup (\e -> e { ceKnownVariants = M.insert dv (k, va) $ ceKnownVariants e })

optKnownLargeArg :: DLVar -> App (Maybe DLLargeArg)
optKnownLargeArg = lookupCommon ceKnownLargeArgs

recordKnownLargeArg :: DLVar -> DLLargeArg -> App ()
recordKnownLargeArg dv v =
  updateLookup (\e -> e { ceKnownLargeArgs = M.insert dv v $ ceKnownLargeArgs e })

remember_ :: Bool -> DLVar -> DLExpr -> App ()
remember_ always v e =
  updateLookup (\cenv -> cenv {cePrev = up $ cePrev cenv})
  where
    up prev =
      case always || not (M.member e prev) of
        True -> M.insert e v prev
        False -> prev

remember :: DLVar -> DLExpr -> App ()
remember = remember_ True

mremember :: DLVar -> DLExpr -> App ()
mremember = remember_ False

rewrite :: DLVar -> (DLVar, Maybe DLArg) -> App ()
rewrite v r = do
  updateLookup (\cenv -> cenv {ceReplaced = M.insert v r (ceReplaced cenv)})

updateLookup :: (CommonEnv -> CommonEnv) -> App ()
updateLookup up = do
  Env {..} <- ask
  let writeHuh f =
        case eFocus of
          F_Ctor ->
            case f of
              F_Ctor -> True
              F_All -> True -- False
              F_Consensus -> True -- False
              F_One _ -> True
          F_All -> True
          F_Consensus -> True
          F_One _ -> f == eFocus
  let update1 (f, cenv) = (f, (if writeHuh f then up else id) cenv)
  let update = M.fromList . (map update1) . M.toList
  liftIO $ modifyIORef eEnvsR update

mkEnv0 :: Counter -> S.Set DLVar -> [SLPart] -> IO Env
mkEnv0 eCounter eConst eParts = do
  let eFocus = F_Ctor
  let eEnvs =
        M.fromList $
          map (\x -> (x, mempty)) $ F_Ctor : F_All : F_Consensus : map F_One eParts
  eEnvsR <- liftIO $ newIORef eEnvs
  return $ Env {..}

opt_v2p :: DLVar -> App (DLVar, DLArg)
opt_v2p v = do
  r <- rewrittenp v
  let both v' = return $ (v', DLA_Var v')
  case r of
    Nothing -> both v
    Just (v', Nothing) -> both v'
    Just (v', Just a') -> return $ (v', a')

opt_v2v :: DLVar -> App DLVar
opt_v2v v = fst <$> opt_v2p v

opt_v2a :: DLVar -> App DLArg
opt_v2a v = snd <$> opt_v2p v

instance (Traversable t, Optimize a) => Optimize (t a) where
  opt = traverse opt
  gcs = mapM_ gcs

instance {-# OVERLAPS #-} (Optimize a, Optimize b) => Optimize (a, b) where
  opt (x, y) = (,) <$> opt x <*> opt y
  gcs (x, y) = gcs x >> gcs y

instance {-# OVERLAPS #-} (Optimize a, Optimize b) => Optimize (Either a b) where
  opt = \case
    Left x -> Left <$> opt x
    Right x -> Right <$> opt x
  gcs = \case
    Left x -> gcs x
    Right x -> gcs x

instance Optimize IType where
  opt = return
  gcs _ = return ()

instance Optimize DLVar where
  opt = opt_v2v
  gcs _ = return ()

instance Optimize Bool where
  opt = return
  gcs _ = return ()

instance Optimize DLArg where
  opt = \case
    DLA_Var v -> opt_v2a v
    DLA_Constant c -> return $ DLA_Constant c
    DLA_Literal c -> return $ DLA_Literal c
    DLA_Interact p m t -> return $ DLA_Interact p m t
  gcs _ = return ()

instance Optimize DLLargeArg where
  opt = \case
    DLLA_Array t as -> DLLA_Array t <$> opt as
    DLLA_Tuple as -> DLLA_Tuple <$> opt as
    DLLA_Obj m -> DLLA_Obj <$> opt m
    DLLA_Data t vn vv -> DLLA_Data t vn <$> opt vv
    DLLA_Struct kvs -> DLLA_Struct <$> mapM go kvs
    DLLA_Bytes b -> return $ DLLA_Bytes b
    where
      go (k, v) = (,) k <$> opt v
  gcs _ = return ()

instance Optimize DLTokenNew where
  opt (DLTokenNew {..}) = DLTokenNew
    <$> opt dtn_name
    <*> opt dtn_sym
    <*> opt dtn_url
    <*> opt dtn_metadata
    <*> opt dtn_supply
    <*> opt dtn_decimals
  gcs _ = return ()

instance Optimize DLWithBill where
  opt (DLWithBill y z) =
    DLWithBill <$> opt y <*> opt z
  gcs _ = return ()

unsafeAt :: [a] -> Int -> a
unsafeAt l i =
  case atMay l i of
    Nothing -> impossible "unsafeMay"
    Just x -> x

instance Optimize DLExpr where
  opt = \case
    DLE_Arg at a -> DLE_Arg at <$> opt a
    DLE_LArg at a -> DLE_LArg at <$> opt a
    DLE_Impossible at tag lab ->
      return $ DLE_Impossible at tag lab
    DLE_VerifyMuldiv at f cl args err ->
      opt (DLE_PrimOp at MUL_DIV args) >>= \case
        DLE_PrimOp _ _ args' -> return $ DLE_VerifyMuldiv at f cl args' err
        ow -> return ow
    DLE_PrimOp at p as -> do
      as' <- opt as
      let meh = return $ DLE_PrimOp at p as'
      let zero = DLA_Literal $ DLL_Int at 0
      case (p, as') of
        (ADD, [(DLA_Literal (DLL_Int _ 0)), rhs]) ->
          return $ DLE_Arg at rhs
        (ADD, [lhs, (DLA_Literal (DLL_Int _ 0))]) ->
          return $ DLE_Arg at lhs
        (SUB, [lhs, (DLA_Literal (DLL_Int _ 0))]) ->
          return $ DLE_Arg at lhs
        (MUL, [(DLA_Literal (DLL_Int _ 1)), rhs]) ->
          return $ DLE_Arg at rhs
        (MUL, [lhs, (DLA_Literal (DLL_Int _ 1))]) ->
          return $ DLE_Arg at lhs
        (MUL, [(DLA_Literal (DLL_Int _ 0)), _]) ->
          return $ DLE_Arg at zero
        (MUL, [_, (DLA_Literal (DLL_Int _ 0))]) ->
          return $ DLE_Arg at zero
        (DIV, [lhs, (DLA_Literal (DLL_Int _ 1))]) ->
          return $ DLE_Arg at lhs
        (MUL_DIV, [l, r, d])
          | l == d -> return $ DLE_Arg at r
          | r == d -> return $ DLE_Arg at l
        (MUL_DIV, [l, r, DLA_Literal (DLL_Int _ 1)]) ->
            opt $ DLE_PrimOp at MUL [l, r]
        (MUL_DIV, [DLA_Literal (DLL_Int _ 1), r, d]) ->
            opt $ DLE_PrimOp at DIV [r, d]
        (MUL_DIV, [l, DLA_Literal (DLL_Int _ 1), d]) ->
            opt $ DLE_PrimOp at DIV [l, d]
        (MUL_DIV, [DLA_Literal (DLL_Int _ 0), _, _]) ->
          return $ DLE_Arg at zero
        (MUL_DIV, [_, DLA_Literal (DLL_Int _ 0), _, _]) ->
          return $ DLE_Arg at zero
        (IF_THEN_ELSE, [c, (DLA_Literal (DLL_Bool True)), (DLA_Literal (DLL_Bool False))]) ->
          return $ DLE_Arg at $ c
        (IF_THEN_ELSE, [(DLA_Literal (DLL_Bool c)), t, f]) ->
          return $ DLE_Arg at $ if c then t else f
        (IF_THEN_ELSE, [c, t, f]) ->
          optNotHuh c >>= \case
            Nothing -> meh
            Just c' ->
              return $ DLE_PrimOp at IF_THEN_ELSE [c', f, t]
        _ -> meh
    DLE_ArrayRef at a i -> DLE_ArrayRef at <$> opt a <*> opt i
    DLE_ArraySet at a i v -> DLE_ArraySet at <$> opt a <*> opt i <*> opt v
    DLE_ArrayConcat at x0 y0 -> DLE_ArrayConcat at <$> opt x0 <*> opt y0
    DLE_ArrayZip at x0 y0 -> DLE_ArrayZip at <$> opt x0 <*> opt y0
    DLE_TupleRef at t i -> do
      t' <- opt t
      let meh = return $ DLE_TupleRef at t' i
      case t' of
        DLA_Var tv ->
          optKnownLargeArg tv >>= \case
            Just (DLLA_Tuple as) ->
              return $ DLE_Arg at $ unsafeAt as $ fromIntegral i
            _ -> meh
        _ -> meh
    DLE_ObjectRef at o k -> DLE_ObjectRef at <$> opt o <*> pure k
    DLE_Interact at fs p m t as -> DLE_Interact at fs p m t <$> opt as
    DLE_Digest at as -> DLE_Digest at <$> opt as
    DLE_Claim at fs t a m -> do
      a' <- opt a
      case a' of
        DLA_Literal (DLL_Bool True) -> nop at
        _ ->
          return $ DLE_Claim at fs t a' m
    DLE_Transfer at t a m -> do
      a' <- opt a
      case a' of
        DLA_Literal (DLL_Int _ 0) -> nop at
        _ ->
          DLE_Transfer at <$> opt t <*> pure a' <*> opt m
    DLE_TokenInit at t -> DLE_TokenInit at <$> opt t
    DLE_CheckPay at fs a m -> DLE_CheckPay at fs <$> opt a <*> opt m
    DLE_Wait at a -> DLE_Wait at <$> opt a
    DLE_PartSet at who a -> DLE_PartSet at who <$> opt a
    DLE_MapRef at mv fa -> DLE_MapRef at mv <$> opt fa
    DLE_MapSet at mv fa na -> DLE_MapSet at mv <$> opt fa <*> opt na
    DLE_Remote at fs av m amta as wbill -> DLE_Remote at fs <$> opt av <*> pure m <*> opt amta <*> opt as <*> opt wbill
    DLE_TokenNew at tns -> DLE_TokenNew at <$> opt tns
    DLE_TokenBurn at tok amt -> DLE_TokenBurn at <$> opt tok <*> opt amt
    DLE_TokenDestroy at tok -> DLE_TokenDestroy at <$> opt tok
    DLE_TimeOrder at tos -> DLE_TimeOrder at <$> opt tos
    DLE_GetContract at -> return $ DLE_GetContract at
    DLE_GetAddress at -> return $ DLE_GetAddress at
    DLE_EmitLog at k a -> DLE_EmitLog at k <$> opt a
    DLE_setApiDetails s p ts mc f -> return $ DLE_setApiDetails s p ts mc f
    DLE_GetUntrackedFunds at mt tb -> DLE_GetUntrackedFunds at <$> opt mt <*> opt tb
    where
      nop at = return $ DLE_Arg at $ DLA_Literal $ DLL_Null
  gcs _ = return ()

instance Optimize DLAssignment where
  opt (DLAssignment m) = DLAssignment <$> opt m
  gcs _ = return ()

class Extract a where
  extract :: a -> Maybe DLVar

instance Extract (Maybe DLVar) where
  extract = id

optIf :: (Eq k, Sanitize k, Optimize k) => (k -> r) -> (SrcLoc -> DLArg -> k -> k -> r) -> SrcLoc -> DLArg -> k -> k -> App r
optIf mkDo mkIf at c t f =
  opt c >>= \case
    DLA_Literal (DLL_Bool True) -> mkDo <$> opt t
    DLA_Literal (DLL_Bool False) -> mkDo <$> opt f
    c' -> do
      -- XXX We could see if c' is something like `DLVar x == DLArg y` and add x -> y to the optimization environment
      t' <- newScope $ opt t
      f' <- newScope $ opt f
      case sani t' == sani f' of
        True -> return $ mkDo t'
        False ->
          optNotHuh c' >>= \case
            Just c'' ->
              return $ mkIf at c'' f' t'
            Nothing ->
              return $ mkIf at c' t' f'

gcsSwitch :: Optimize k => ConstT (SwitchCases k)
gcsSwitch = mapM_ (\(_, _, n) -> gcs n)

optSwitch :: Optimize k => (k -> r) -> (DLStmt -> k -> k) -> (SrcLoc -> DLVar -> SwitchCases k -> r) -> SrcLoc -> DLVar -> SwitchCases k -> App r
optSwitch mkDo mkLet mkSwitch at ov csm = do
  ov' <- opt ov
  optKnownVariant ov' >>= \case
    Just (var, var_val) -> do
      let (var_var, _, var_k) = (M.!) csm var
      let var_k' = mkLet (DL_Let at (DLV_Let DVC_Many var_var) (DLE_Arg at var_val)) var_k
      newScope $ mkDo <$> opt var_k'
    Nothing -> do
      let cm1 k (v_v, vnu, n) = (,,) v_v vnu <$> (newScope $ recordKnownVariant ov' k (DLA_Var v_v) >> opt n)
      mkSwitch at ov' <$> mapWithKeyM cm1 csm

optWhile :: Optimize a => (DLAssignment -> DLBlock -> a -> a -> a) -> DLAssignment -> DLBlock -> a -> a -> App a
optWhile mk asn cond body k = do
  asn' <- opt asn
  cond'@(DLBlock _ _ _ ca) <- newScope $ opt cond
  let mca b m = case ca of
                  DLA_Var dv -> do
                    rewrite dv (dv, Just (DLA_Literal $ DLL_Bool b))
                    optNotHuh ca >>= \case
                      Just (DLA_Var dv') -> do
                        rewrite dv' (dv', Just (DLA_Literal $ DLL_Bool $ not b))
                      _ -> return ()
                    m
                  _ -> m
  body' <- newScope $ mca True $ opt body
  k' <- newScope $ mca False $ opt k
  return $ mk asn' cond' body' k'

optLet :: SrcLoc -> DLLetVar -> DLExpr -> App DLStmt
optLet at x e = do
  e' <- opt e
  let meh = return $ DL_Let at x e'
  case (extract x, isPure e && canDupe e) of
    (Just dv, True) ->
      case e' of
        DLE_LArg _ a' | canDupe a' -> do
          recordKnownLargeArg dv a'
          meh
        DLE_Arg _ a' | canDupe a' -> do
          rewrite dv (dv, Just a')
          mremember dv (sani e')
          meh
        _ -> do
          let e'' = sani e'
          common <- repeated e''
          case common of
            Just rt -> do
              rewrite dv (rt, Nothing)
              return $ DL_Nop at
            Nothing -> do
              remember dv e''
              case e' of
                DLE_PrimOp _ IF_THEN_ELSE [c, DLA_Literal (DLL_Bool False), DLA_Literal (DLL_Bool True)] -> do
                  recordNotHuh x c
                _ ->
                  return ()
              meh
    _ -> meh

instance Optimize DLStmt where
  opt = \case
    DL_Nop at -> return $ DL_Nop at
    DL_Let at x e -> optLet at x e
    DL_Var at v ->
      optConst v >>= \case
        True -> return $ DL_Nop at
        False -> return $ DL_Var at v
    DL_Set at v a ->
      optConst v >>= \case
        False -> DL_Set at v <$> opt a
        True -> optLet at (DLV_Let DVC_Many v) (DLE_Arg at a)
    DL_LocalIf at c t f ->
      optIf (DL_LocalDo at) DL_LocalIf at c t f
    DL_LocalSwitch at ov csm ->
      optSwitch (DL_LocalDo at) DT_Com DL_LocalSwitch at ov csm
    s@(DL_ArrayMap at ans x a f) -> maybeUnroll s x $
      DL_ArrayMap at ans <$> opt x <*> (pure a) <*> opt f
    s@(DL_ArrayReduce at ans x z b a f) -> maybeUnroll s x $ do
      DL_ArrayReduce at ans <$> opt x <*> opt z <*> (pure b) <*> (pure a) <*> opt f
    DL_MapReduce at mri ans x z b a f -> do
      DL_MapReduce at mri ans x <$> opt z <*> (pure b) <*> (pure a) <*> opt f
    DL_Only at ep l -> do
      let w = case ep of
            Left p -> focus_one p
            Right _ -> id
      l' <- w $ opt l
      case l' of
        DT_Return _ -> return $ DL_Nop at
        _ -> return $ DL_Only at ep l'
    DL_LocalDo at t ->
      opt t >>= \case
        DT_Return _ -> return $ DL_Nop at
        t' -> return $ DL_LocalDo at t'
    where
      maybeUnroll :: DLStmt -> DLArg -> App DLStmt -> App DLStmt
      maybeUnroll s x def =
        case argTypeOf x of
          T_Array _ n ->
            case n <= 1 of
              True -> do
                c <- asks eCounter
                let at = srclocOf s
                let t = DL_LocalDo at $ DT_Com s $ DT_Return at
                UnrollWrapper _ t' <- liftIO $ unrollLoops $ UnrollWrapper c t
                return t'
              _ -> def
          _ -> def
  gcs = \case
    DL_Nop {} -> return ()
    DL_Let {} -> return ()
    DL_Var {} -> return ()
    DL_Set _ v _ -> do
      cr <- asks eConstR
      let f = Just . (+) 1 . fromMaybe 0
      liftIO $ modifyIORef cr $ M.alter f v
    DL_LocalIf _ _ t f -> gcs t >> gcs f
    DL_LocalSwitch _ _ csm -> gcsSwitch csm
    DL_ArrayMap _ _ _ _ f -> gcs f
    DL_ArrayReduce _ _ _ _ _ _ f -> gcs f
    DL_MapReduce _ _ _ _ _ _ _ f -> gcs f
    DL_Only _ _ l -> gcs l
    DL_LocalDo _ t -> gcs t

instance Optimize DLTail where
  opt = \case
    DT_Return at -> return $ DT_Return at
    DT_Com m k -> mkCom DT_Com <$> opt m <*> opt k
  gcs = \case
    DT_Return _ -> return ()
    DT_Com m k -> gcs m >> gcs k

instance Optimize DLBlock where
  opt (DLBlock at fs b a) =
    -- newScope $
    DLBlock at fs <$> opt b <*> opt a
  gcs (DLBlock _ _ b _) = gcs b

instance {-# OVERLAPPING #-} Optimize a => Optimize (DLinExportBlock a) where
  opt (DLinExportBlock at vs b) =
    newScope $ DLinExportBlock at vs <$> opt b
  gcs (DLinExportBlock _ _ b) = gcs b

instance Optimize LLConsensus where
  opt = \case
    LLC_Com m k -> mkCom LLC_Com <$> opt m <*> opt k
    LLC_If at c t f ->
      optIf id LLC_If at c t f
    LLC_Switch at ov csm ->
      optSwitch id LLC_Com LLC_Switch at ov csm
    LLC_While at asn inv cond body k -> do
      inv' <- newScope $ opt inv
      optWhile (\asn' cond' body' k' -> LLC_While at asn' inv' cond' body' k') asn cond body k
    LLC_Continue at asn ->
      LLC_Continue at <$> opt asn
    LLC_FromConsensus at1 at2 s ->
      LLC_FromConsensus at1 at2 <$> (focus_all $ opt s)
    LLC_ViewIs at vn vk a k ->
      LLC_ViewIs at vn vk <$> opt a <*> opt k
  gcs = \case
    LLC_Com m k -> gcs m >> gcs k
    LLC_If _ _ t f -> gcs t >> gcs f
    LLC_Switch _ _ csm -> gcsSwitch csm
    LLC_While _ _ _ cond body k -> gcs cond >> gcs body >> gcs k
    LLC_Continue {} -> return ()
    LLC_FromConsensus _ _ s -> gcs s
    LLC_ViewIs _ _ _ _ k -> gcs k

_opt_dbg :: Show a => App a -> App a
_opt_dbg m = do
  e <- ask
  let f = eFocus e
  liftIO $ putStrLn $ show $ f
  fm <- liftIO $ readIORef $ eEnvsR e
  let mce = M.lookup f fm
  let ced = fmap ceReplaced mce
  liftIO $ putStrLn $ show $ ced
  x <- m
  liftIO $ putStrLn $ "got " <> show x
  return x

opt_mtime :: (Optimize a, Optimize b) => AppT (Maybe (a, b))
opt_mtime = \case
  Nothing -> pure $ Nothing
  Just (d, s) -> Just <$> (pure (,) <*> (focus_con $ opt d) <*> (newScope $ opt s))

gcs_mtime :: (Optimize b) => ConstT (Maybe (a, b))
gcs_mtime = \case
  Nothing -> return ()
  Just (_, s) -> gcs s

instance Optimize DLPayAmt where
  opt (DLPayAmt {..}) = DLPayAmt <$> opt pa_net <*> opt pa_ks
  gcs _ = return ()

opt_send :: AppT (SLPart, DLSend)
opt_send (p, DLSend isClass args amta whena) =
  focus_one p $
    (,) p <$> (DLSend isClass <$> opt args <*> opt amta <*> opt whena)

instance Optimize LLStep where
  opt = \case
    LLS_Com m k -> mkCom LLS_Com <$> opt m <*> opt k
    LLS_Stop at -> pure $ LLS_Stop at
    LLS_ToConsensus at lct send recv mtime ->
      LLS_ToConsensus at <$> opt lct <*> send' <*> recv' <*> mtime'
      where
        send' = M.fromList <$> mapM opt_send (M.toList send)
        k' = newScope $ focus_con $ opt $ dr_k recv
        recv' = (\k -> recv {dr_k = k}) <$> k'
        mtime' = opt_mtime mtime
  gcs = \case
    LLS_Com m k -> gcs m >> gcs k
    LLS_Stop _ -> return ()
    LLS_ToConsensus _ _ _ recv mtime -> gcs (dr_k recv) >> gcs_mtime mtime

instance Optimize DLInit where
  opt (DLInit {..}) = do
    return $
      DLInit
        { dli_maps = dli_maps
        }
  gcs _ = return ()

instance Optimize LLProg where
  opt (LLProg at opts ps dli dex dvs das devts s) = do
    let SLParts {..} = ps
    let psl = M.keys sps_ies
    cs <- asks eConst
    env0 <- liftIO $ mkEnv0 (getCounter opts) cs psl
    local (const env0) $
      focus_ctor $
        LLProg at opts ps <$> opt dli <*> opt dex <*> pure dvs <*> pure das <*> pure devts <*> opt s
  gcs (LLProg _ _ _ _ _ _ _ _ s) = gcs s

-- This is a bit of a hack...

instance Extract DLLetVar where
  extract = \case
    DLV_Eff -> Nothing
    DLV_Let _ v -> Just v

opt_svs :: AppT [(DLVar, DLArg)]
opt_svs = mapM $ \(v, a) -> (\x -> (v, x)) <$> opt a

instance Optimize FromInfo where
  opt = \case
    FI_Continue svs -> FI_Continue <$> opt_svs svs
    FI_Halt toks -> FI_Halt <$> opt toks
  gcs _ = return ()

instance {-# OVERLAPPING #-} (Optimize a, Optimize b, Optimize c, Optimize d, Optimize e) => Optimize (a, b, c, d, e) where
  opt (a, b, c, d, e) = (,,,,) <$> opt a <*> opt b <*> opt c <*> opt d <*> opt e
  gcs (a, b, c, d, e) = gcs a >> gcs b >> gcs c >> gcs d >> gcs e

instance Optimize ETail where
  opt = \case
    ET_Com m k -> mkCom ET_Com <$> opt m <*> opt k
    ET_Stop at -> return $ ET_Stop at
    ET_If at c t f ->
      optIf id ET_If at c t f
    ET_Switch at ov csm ->
      optSwitch id ET_Com ET_Switch at ov csm
    ET_FromConsensus at vi fi k ->
      ET_FromConsensus at vi fi <$> opt k
    ET_ToConsensus {..} -> do
      ET_ToConsensus et_tc_at et_tc_from et_tc_prev <$> opt et_tc_lct <*> pure et_tc_which <*> opt et_tc_from_me <*> pure et_tc_from_msg <*> pure et_tc_from_out <*> pure et_tc_from_timev <*> pure et_tc_from_secsv <*> pure et_tc_from_didSendv <*> opt_mtime et_tc_from_mtime <*> opt et_tc_cons
    ET_While at asn cond body k -> optWhile (ET_While at) asn cond body k
    ET_Continue at asn -> ET_Continue at <$> opt asn
  gcs = \case
    ET_Com m k -> gcs m >> gcs k
    ET_Stop _ -> return ()
    ET_If _ _ t f -> gcs t >> gcs f
    ET_Switch _ _ csm -> gcsSwitch csm
    ET_FromConsensus _ _ _ k -> gcs k
    ET_ToConsensus {..} -> gcs et_tc_cons >> gcs_mtime et_tc_from_mtime
    ET_While _ _ cond body k -> gcs cond >> gcs body >> gcs k
    ET_Continue {} -> return ()

instance Optimize CTail where
  opt = \case
    CT_Com m k -> mkCom CT_Com <$> opt m <*> opt k
    CT_If at c t f ->
      optIf id CT_If at c t f
    CT_Switch at ov csm ->
      optSwitch id CT_Com CT_Switch at ov csm
    CT_From at w fi ->
      CT_From at w <$> opt fi
    CT_Jump at which vs asn ->
      CT_Jump at which <$> opt vs <*> opt asn
  gcs = \case
    CT_Com m k -> gcs m >> gcs k
    CT_If _ _ t f -> gcs t >> gcs f
    CT_Switch _ _ csm -> gcsSwitch csm
    CT_From {} -> return ()
    CT_Jump {} -> return ()

instance Optimize CHandler where
  opt = \case
    C_Handler {..} -> do
      C_Handler ch_at ch_int ch_from ch_last ch_svs ch_msg ch_timev ch_secsv <$> opt ch_body
    C_Loop {..} -> do
      C_Loop cl_at cl_svs cl_vars <$> opt cl_body
  gcs = \case
    C_Handler {..} -> gcs ch_body
    C_Loop {..} -> gcs cl_body

instance Optimize ViewInfo where
  opt (ViewInfo vs vi) = ViewInfo vs <$> (newScope $ opt vi)
  gcs _ = return ()

instance Optimize CPProg where
  opt (CPProg at vi ai devts (CHandlers hs)) =
    CPProg at <$> (newScope $ opt vi) <*> pure ai <*> pure devts <*> (CHandlers <$> mapM (newScope . opt) hs)
  gcs (CPProg _ _ _ _ (CHandlers hs)) = gcs hs

instance Optimize EPProg where
  opt (EPProg at x ie et) = newScope $ EPProg at x ie <$> opt et
  gcs (EPProg _ _ _ et) = gcs et

instance Optimize EPPs where
  opt (EPPs {..}) = EPPs epps_apis <$> opt epps_m
  gcs (EPPs {..}) = gcs epps_m

instance Optimize PLProg where
  opt (PLProg at plo dli dex epps cp) =
    PLProg at plo dli <$> opt dex <*> opt epps <*> opt cp
  gcs (PLProg _ _ _ _ epps cp) = gcs epps >> gcs cp

optimize_ :: (Optimize a) => Counter -> a -> IO a
optimize_ c t = do
  eConstR <- newIORef $ mempty
  flip runReaderT (ConstEnv {..}) $ gcs t
  cs <- readIORef eConstR
  let csvs = M.keysSet $ M.filter (\x -> x < 2) cs
  env0 <- mkEnv0 c csvs []
  flip runReaderT env0 $
    opt t

optimize :: (HasCounter a, Optimize a) => a -> IO a
optimize t = optimize_ (getCounter t) t