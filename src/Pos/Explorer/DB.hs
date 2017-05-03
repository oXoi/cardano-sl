-- | Module containing explorer-specific logic and data

module Pos.Explorer.DB
       ( ExplorerOp (..)
       , getTxExtra
       , getAddrHistory
       , getAddrBalance
       , prepareExplorerDB
       ) where

import qualified Database.RocksDB      as Rocks
import           Universum

import qualified Data.HashMap.Strict   as HM
import qualified Data.Map.Strict       as M

import           Pos.Binary.Class      (encodeStrict)
import           Pos.Context.Class     (WithNodeContext)
import           Pos.Context.Functions (genesisUtxoM)
import           Pos.Core              (unsafeAddCoin)
import           Pos.Core.Types        (Address, Coin)
import           Pos.DB.Class          (MonadDB, getUtxoDB)
import           Pos.DB.Functions      (RocksBatchOp (..), rocksGetBytes)
import           Pos.DB.GState.Common  (gsGetBi, gsPutBi, writeBatchGState)
import           Pos.Explorer.Core     (AddrHistory, TxExtra (..))
import           Pos.Txp.Core          (TxId, TxOutAux (..), _TxOut)
import           Pos.Txp.Toil          (Utxo)
import           Pos.Util.Chrono       (NewestFirst (..))

----------------------------------------------------------------------------
-- Getters
----------------------------------------------------------------------------

getTxExtra :: MonadDB m => TxId -> m (Maybe TxExtra)
getTxExtra = gsGetBi . txExtraPrefix

getAddrHistory :: MonadDB m => Address -> m AddrHistory
getAddrHistory = fmap (NewestFirst . concat . maybeToList) .
                 gsGetBi . addrHistoryPrefix

getAddrBalance :: MonadDB m => Address -> m (Maybe Coin)
getAddrBalance = gsGetBi . addrBalancePrefix

----------------------------------------------------------------------------
-- Initialization
----------------------------------------------------------------------------

prepareExplorerDB :: (WithNodeContext ssc m, MonadDB m) => m ()
prepareExplorerDB =
    unlessM areBalancesInitialized $ do
        genesisUtxo <- genesisUtxoM
        putGenesisBalances genesisUtxo
        putInitFlag

balancesInitFlag :: ByteString
balancesInitFlag = "e/init/"

areBalancesInitialized :: MonadDB m => m Bool
areBalancesInitialized = isJust <$> (getUtxoDB >>= rocksGetBytes balancesInitFlag)

putInitFlag :: MonadDB m => m ()
putInitFlag = gsPutBi balancesInitFlag True

putGenesisBalances :: MonadDB m => Utxo -> m ()
putGenesisBalances genesisUtxo = do
    let txOuts = map (view _TxOut . toaOut . snd) . M.toList $ genesisUtxo
    writeBatchGState $
        map (uncurry PutAddrBalance) $ combineWith unsafeAddCoin txOuts
  where
    combineWith :: (Eq a, Hashable a) => (b -> b -> b) -> [(a, b)] -> [(a, b)]
    combineWith func = HM.toList . HM.fromListWith func

----------------------------------------------------------------------------
-- Batch operations
----------------------------------------------------------------------------

data ExplorerOp
    = AddTxExtra !TxId !TxExtra
    | DelTxExtra !TxId
    | UpdateAddrHistory !Address !AddrHistory
    | PutAddrBalance !Address !Coin
    | DelAddrBalance !Address

instance RocksBatchOp ExplorerOp where
    toBatchOp (AddTxExtra id extra) =
        [Rocks.Put (txExtraPrefix id) (encodeStrict extra)]
    toBatchOp (DelTxExtra id) =
        [Rocks.Del $ txExtraPrefix id]
    toBatchOp (UpdateAddrHistory addr txs) =
        [Rocks.Put (addrHistoryPrefix addr) (encodeStrict txs)]
    toBatchOp (PutAddrBalance addr coin) =
        [Rocks.Put (addrBalancePrefix addr) (encodeStrict coin)]
    toBatchOp (DelAddrBalance addr) =
        [Rocks.Del $ addrBalancePrefix addr]

----------------------------------------------------------------------------
-- Keys
----------------------------------------------------------------------------

txExtraPrefix :: TxId -> ByteString
txExtraPrefix h = "e/tx/" <> encodeStrict h

addrHistoryPrefix :: Address -> ByteString
addrHistoryPrefix addr = "e/ah/" <> encodeStrict addr

addrBalancePrefix :: Address -> ByteString
addrBalancePrefix addr = "e/ab/" <> encodeStrict addr
