{-# LANGUAGE TypeFamilies #-}

-- | Wallets, accounts and addresses management logic

module Pos.Wallet.Web.Methods.Logic
       ( getWallet
       , getWallets
       , getAccount
       , getAccounts

       , createWalletSafe
       , newAccount
       , newAccountIncludeUnready
       , newAddress

       , deleteWallet
       , deleteAccount

       , updateWallet
       , updateAccount
       , changeWalletPassphrase
       ) where

import           Universum

import qualified Data.HashMap.Strict        as HM
import           Data.List                  (findIndex)
import qualified Data.Set                   as S
import           Data.Time.Clock.POSIX      (getPOSIXTime)
import           Formatting                 (build, sformat, (%))
import           System.Wlog                (logDebug)

import           Pos.Aeson.ClientTypes      ()
import           Pos.Aeson.WalletBackup     ()
import           Pos.Core                   (Address, Coin, mkCoin, sumCoins,
                                             unsafeIntegerToCoin)
import           Pos.Crypto                 (PassPhrase, changeEncPassphrase,
                                             checkPassMatches, emptyPassphrase)
import           Pos.Txp                    (applyUtxoModToAddrCoinMap)
import           Pos.Util                   (maybeThrow)
import qualified Pos.Util.Modifier          as MM
import           Pos.Util.Servant           (encodeCType)
import           Pos.Wallet.KeyStorage      (addSecretKey, deleteSecretKey,
                                             getSecretKeysPlain)
import           Pos.Wallet.Web.Account     (AddrGenSeed, genUniqueAccountId,
                                             genUniqueAddress, getAddrIdx, getSKById)
import           Pos.Wallet.Web.ClientTypes (AccountId (..), CAccount (..),
                                             CAccountInit (..), CAccountMeta (..),
                                             CAddress (..), CId, CWAddressMeta (..),
                                             CWallet (..), CWalletMeta (..), Wal,
                                             addrMetaToAccount, encToCId, mkCCoin)
import           Pos.Wallet.Web.Error       (WalletError (..))
import           Pos.Wallet.Web.Mode        (MonadWalletWebMode, convertCIdTOAddr)
import           Pos.Wallet.Web.State       (AddressLookupMode (Existing),
                                             CustomAddressType (ChangeAddr, UsedAddr),
                                             addWAddress, createAccount, createWallet,
                                             getAccountIds, getAccountMeta,
                                             getWalletAddresses,
                                             getWalletMetaIncludeUnready, getWalletPassLU,
                                             isCustomAddress, removeAccount,
                                             removeHistoryCache, removeTxMetas,
                                             removeWallet, setAccountMeta, setWalletMeta,
                                             setWalletPassLU)
import           Pos.Wallet.Web.State       (WalletSnapshot)
import qualified Pos.Wallet.Web.State       as WS
import           Pos.Wallet.Web.Tracking    (CAccModifier (..), CachedCAccModifier,
                                             fixCachedAccModifierFor,
                                             fixingCachedAccModifier, sortedInsertions)
import           Pos.Wallet.Web.Util        (decodeCTypeOrFail, getAccountAddrsOrThrow,
                                             getWalletAccountIds)

----------------------------------------------------------------------------
-- Getters
----------------------------------------------------------------------------

getBalanceWithMod :: WalletSnapshot -> CachedCAccModifier -> Address -> Coin
getBalanceWithMod ws accMod addr =
    fromMaybe (mkCoin 0) .
    HM.lookup addr $
    flip applyUtxoModToAddrCoinMap balancesAndUtxo (camUtxo accMod)
  where
    balancesAndUtxo = WS.getWalletBalancesAndUtxo ws

getWAddressBalanceWithMod
    :: MonadWalletWebMode m
    => WalletSnapshot
    -> CachedCAccModifier
    -> CWAddressMeta
    -> m Coin
getWAddressBalanceWithMod ws accMod addr =
    getBalanceWithMod ws accMod
        <$> convertCIdTOAddr (cwamId addr)

-- BE CAREFUL: this function works for O(number of used and change addresses)
getWAddress
    :: MonadWalletWebMode m
    => WalletSnapshot
    -> CachedCAccModifier -> CWAddressMeta -> m CAddress
getWAddress ws cachedAccModifier cAddr = do
    let aId = cwamId cAddr
    balance <- getWAddressBalanceWithMod ws cachedAccModifier cAddr

    let getFlag customType accessMod =
            let checkDB = isCustomAddress ws customType (cwamId cAddr)
                checkMempool = elem aId . map (fst . fst) . toList $
                               MM.insertions $ accessMod cachedAccModifier
             in checkDB || checkMempool
        isUsed   = getFlag UsedAddr camUsed
        isChange = getFlag ChangeAddr camChange
    return $ CAddress aId (mkCCoin balance) isUsed isChange

getAccountMod
    :: MonadWalletWebMode m
    => WalletSnapshot
    -> CachedCAccModifier
    -> AccountId
    -> m CAccount
getAccountMod ws accMod accId = do
    dbAddrs    <- getAccountAddrsOrThrow ws Existing accId
    let allAddrIds = gatherAddresses (camAddresses accMod) dbAddrs
    logDebug "getAccountMod: gathering info about addresses.."
    allAddrs <- mapM (getWAddress ws accMod) allAddrIds
    logDebug "getAccountMod: info about addresses gathered"
    balance <- mkCCoin . unsafeIntegerToCoin . sumCoins <$>
               mapM (decodeCTypeOrFail . cadAmount) allAddrs
    meta <- maybeThrow noAccount (getAccountMeta ws accId)
    pure $ CAccount (encodeCType accId) meta allAddrs balance
  where
    noAccount =
        RequestError $ sformat ("No account with id "%build%" found") accId
    gatherAddresses addrModifier dbAddrs = do
        let memAddrs :: [CWAddressMeta]
            memAddrs = sortedInsertions addrModifier
            dbAddrsSet = S.fromList dbAddrs
            relatedMemAddrs = filter ((== accId) . addrMetaToAccount) memAddrs
            unknownMemAddrs = filter (`S.notMember` dbAddrsSet) relatedMemAddrs
        dbAddrs <> unknownMemAddrs

getAccount :: MonadWalletWebMode m => AccountId -> m CAccount
getAccount accId = do
    ws <- WS.getWalletSnapshot
    fixingCachedAccModifier ws (getAccountMod ws) accId

getAccountsIncludeUnready
    :: MonadWalletWebMode m
    => WalletSnapshot
    -> Bool -> Maybe (CId Wal) -> m [CAccount]
getAccountsIncludeUnready ws includeUnready mCAddr = do
    whenJust mCAddr $ \cAddr ->
      void $ maybeThrow (noWallet cAddr) $
        getWalletMetaIncludeUnready ws includeUnready cAddr
    let accIds = maybe (getAccountIds ws) (getWalletAccountIds ws) mCAddr
    let groupedAccIds = fmap reverse $ HM.fromListWith mappend $
                        accIds <&> \acc -> (aiWId acc, [acc])
    concatForM (HM.toList groupedAccIds) $ \(wid, walAccIds) ->
         fixCachedAccModifierFor ws wid $ \accMod ->
             mapM (getAccountMod ws accMod) walAccIds
  where
    noWallet cAddr = RequestError $
        -- TODO No WALLET with id ...
        -- dunno whether I can fix and not break compatible w/ daedalus
        sformat ("No account with id "%build%" found") cAddr

getAccounts
    :: MonadWalletWebMode m
    => Maybe (CId Wal) -> m [CAccount]
getAccounts mCAddr = do
    ws <- WS.getWalletSnapshot
    getAccountsIncludeUnready ws False mCAddr

getWalletIncludeUnready :: MonadWalletWebMode m
                        => WalletSnapshot -> Bool -> CId Wal -> m CWallet
getWalletIncludeUnready ws includeUnready cAddr = do
    meta       <- maybeThrow noWallet $ getWalletMetaIncludeUnready ws includeUnready cAddr
    accounts   <- getAccountsIncludeUnready ws includeUnready (Just cAddr)
    let accountsNum = length accounts
    balance    <- mkCCoin . unsafeIntegerToCoin . sumCoins <$>
                     mapM (decodeCTypeOrFail . caAmount) accounts
    hasPass    <- isNothing . checkPassMatches emptyPassphrase <$> getSKById cAddr
    passLU     <- maybeThrow noWallet (getWalletPassLU ws cAddr)
    pure $ CWallet cAddr meta accountsNum balance hasPass passLU
  where
    noWallet = RequestError $
        sformat ("No wallet with address "%build%" found") cAddr

getWallet :: MonadWalletWebMode m => CId Wal -> m CWallet
getWallet wid = do
    ws <- WS.getWalletSnapshot
    getWalletIncludeUnready ws False wid

getWallets :: MonadWalletWebMode m => m [CWallet]
getWallets = do
    ws <- WS.getWalletSnapshot
    mapM (getWalletIncludeUnready ws False) (getWalletAddresses ws)

----------------------------------------------------------------------------
-- Creators
----------------------------------------------------------------------------

newAddress
    :: MonadWalletWebMode m
    => AddrGenSeed
    -> PassPhrase
    -> AccountId
    -> m CAddress
newAddress addGenSeed passphrase accId = do
    ws <- WS.getWalletSnapshot

    -- check whether account exists
    let parentExists = WS.doesAccountExist ws accId
    unless parentExists $ throwM noAccount

    cAccAddr <- genUniqueAddress ws addGenSeed passphrase accId
    addWAddress cAccAddr

    -- Re-read DB after the update. TODO: make this atomic
    ws' <- WS.getWalletSnapshot
    fixCachedAccModifierFor ws' accId $ \accMod ->
      getWAddress ws' accMod cAccAddr
  where
    noAccount =
        RequestError $ sformat ("No account with id "%build%" found") accId

newAccountIncludeUnready
    :: MonadWalletWebMode m
    => Bool -> AddrGenSeed -> PassPhrase -> CAccountInit -> m CAccount
newAccountIncludeUnready includeUnready addGenSeed passphrase CAccountInit {..} = do
    ws <- WS.getWalletSnapshot

    -- check wallet exists
    _ <- getWalletIncludeUnready ws includeUnready caInitWId

    cAcc <- genUniqueAccountId ws addGenSeed caInitWId
    createAccount cAcc caInitMeta

    cAccAddr <- genUniqueAddress ws addGenSeed passphrase cAcc
    addWAddress cAccAddr

    -- Re-read DB after the update.
    ws' <- WS.getWalletSnapshot
    fixCachedAccModifierFor ws' caInitWId $ \accMod ->
        getAccountMod ws' accMod cAcc

newAccount
    :: MonadWalletWebMode m
    => AddrGenSeed -> PassPhrase -> CAccountInit -> m CAccount
newAccount = newAccountIncludeUnready False

createWalletSafe
    :: MonadWalletWebMode m
    => CId Wal -> CWalletMeta -> Bool -> m CWallet
createWalletSafe cid wsMeta isReady = do
    -- Disallow duplicate wallets (including unready wallets)
    ws <- WS.getWalletSnapshot
    let wSetExists = isJust $ getWalletMetaIncludeUnready ws True cid
    when wSetExists $
        throwM $ RequestError "Wallet with that mnemonics already exists"
    curTime <- liftIO getPOSIXTime
    createWallet cid wsMeta isReady curTime
    -- Return the newly created wallet irrespective of whether it's ready yet
    getWalletIncludeUnready ws True cid


----------------------------------------------------------------------------
-- Deleters
----------------------------------------------------------------------------

deleteWallet :: MonadWalletWebMode m => CId Wal -> m ()
deleteWallet wid = do
    accounts <- getAccounts (Just wid)
    mapM_ (deleteAccount <=< decodeCTypeOrFail . caId) accounts
    removeWallet wid
    removeTxMetas wid
    removeHistoryCache wid
    deleteSecretKey . fromIntegral =<< getAddrIdx wid

deleteAccount :: MonadWalletWebMode m => AccountId -> m ()
deleteAccount = removeAccount

----------------------------------------------------------------------------
-- Modifiers
----------------------------------------------------------------------------

updateWallet :: MonadWalletWebMode m => CId Wal -> CWalletMeta -> m CWallet
updateWallet wId wMeta = do
    setWalletMeta wId wMeta
    getWallet wId

updateAccount :: MonadWalletWebMode m => AccountId -> CAccountMeta -> m CAccount
updateAccount accId wMeta = do
    setAccountMeta accId wMeta
    getAccount accId

changeWalletPassphrase
    :: MonadWalletWebMode m
    => CId Wal -> PassPhrase -> PassPhrase -> m ()
changeWalletPassphrase wid oldPass newPass = do
    oldSK <- getSKById wid

    unless (isJust $ checkPassMatches newPass oldSK) $ do
        newSK <- maybeThrow badPass =<< changeEncPassphrase oldPass newPass oldSK
        deleteSK oldPass
        addSecretKey newSK
        setWalletPassLU wid =<< liftIO getPOSIXTime
  where
    badPass = RequestError "Invalid old passphrase given"
    deleteSK passphrase = do
        let nice k = encToCId k == wid && isJust (checkPassMatches passphrase k)
        midx <- findIndex nice <$> getSecretKeysPlain
        idx  <- RequestError "No key with such address and pass found"
                `maybeThrow` midx
        deleteSecretKey (fromIntegral idx)
