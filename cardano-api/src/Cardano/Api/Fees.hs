{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

-- | Fee calculation
--
module Cardano.Api.Fees (

    -- * Transaction fees
    transactionFee,
    estimateTransactionFee,
    evaluateTransactionFee,
    estimateTransactionKeyWitnessCount,

    -- * Script execution units
    evaluateTransactionExecutionUnits,
    ScriptExecutionError(..),
    TransactionValidityIntervalError(..),

    -- * Transaction balance
    evaluateTransactionBalance,

    -- * Automated transaction building
    makeTransactionBodyAutoBalance,
    BalancedTxBody(..),
    TxBodyErrorAutoBalance(..),

    -- * Minimum UTxO calculation
    calculateMinimumUTxO,
    MinimumUTxOError(..),
  ) where

import           Prelude

import qualified Data.Array as Array
import           Data.Bifunctor (bimap, first)
import qualified Data.ByteString as BS
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe (fromMaybe)
import           Data.Sequence.Strict (StrictSeq (..))
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as Text
import           GHC.Records (HasField (..))
import           Numeric.Natural

import           Control.Monad.Trans.Except
import qualified Data.Text.Prettyprint.Doc as PP
import qualified Data.Text.Prettyprint.Doc.Render.String as PP

import qualified Cardano.Binary as CBOR
import           Cardano.Slotting.EpochInfo (EpochInfo, hoistEpochInfo)

import qualified Cardano.Chain.Common as Byron

import qualified Cardano.Ledger.Alonzo.Rules.Utxo as Alonzo
import qualified Cardano.Ledger.Coin as Ledger
import qualified Cardano.Ledger.Core as Ledger
import qualified Cardano.Ledger.Crypto as Ledger
import qualified Cardano.Ledger.Era as Ledger.Era (Crypto)
import qualified Cardano.Ledger.Keys as Ledger
import qualified Shelley.Spec.Ledger.API as Ledger (CLI, DCert, TxIn, Wdrl)
import qualified Shelley.Spec.Ledger.API.Wallet as Ledger (evaluateTransactionBalance,
                   evaluateTransactionFee)

import           Shelley.Spec.Ledger.PParams (PParams' (..))

import qualified Cardano.Ledger.Mary.Value as Mary

import qualified Cardano.Ledger.Alonzo as Alonzo
import qualified Cardano.Ledger.Alonzo.Language as Alonzo
import           Cardano.Ledger.Alonzo.PParams (PParams' (..))
import qualified Cardano.Ledger.Alonzo.Scripts as Alonzo
import qualified Cardano.Ledger.Alonzo.Tools as Alonzo
import qualified Cardano.Ledger.Alonzo.TxWitness as Alonzo

import qualified Plutus.V1.Ledger.Api as Plutus

import qualified Ouroboros.Consensus.HardFork.History as Consensus

import           Cardano.Api.Address
import           Cardano.Api.Certificate
import           Cardano.Api.Eras
import           Cardano.Api.Error
import           Cardano.Api.Modes
import           Cardano.Api.NetworkId
import           Cardano.Api.ProtocolParameters
import           Cardano.Api.Query
import           Cardano.Api.Script
import           Cardano.Api.Tx
import           Cardano.Api.TxBody
import           Cardano.Api.Value

{- HLINT ignore "Redundant return" -}

-- ----------------------------------------------------------------------------
-- Transaction fees
--

-- | For a concrete fully-constructed transaction, determine the minimum fee
-- that it needs to pay.
--
-- This function is simple, but if you are doing input selection then you
-- probably want to consider estimateTransactionFee.
--
transactionFee :: forall era.
                  IsShelleyBasedEra era
               => Natural -- ^ The fixed tx fee
               -> Natural -- ^ The tx fee per byte
               -> Tx era
               -> Lovelace
transactionFee txFeeFixed txFeePerByte tx =
  let a = toInteger txFeePerByte
      b = toInteger txFeeFixed
  in case tx of
       ShelleyTx _ tx' -> let x = obtainHasField shelleyBasedEra $ getField @"txsize" tx'
                          in Lovelace (a * x + b)
       --TODO: This can be made to work for Byron txs too. Do that: fill in this case
       -- and remove the IsShelleyBasedEra constraint.
       ByronTx _ -> case shelleyBasedEra :: ShelleyBasedEra ByronEra of {}
 where
  obtainHasField
    :: ShelleyLedgerEra era ~ ledgerera
    => ShelleyBasedEra era
    -> ( HasField "txsize" (Ledger.Tx (ShelleyLedgerEra era)) Integer
        => a)
    -> a
  obtainHasField ShelleyBasedEraShelley f = f
  obtainHasField ShelleyBasedEraAllegra f = f
  obtainHasField ShelleyBasedEraMary    f = f
  obtainHasField ShelleyBasedEraAlonzo  f = f

{-# DEPRECATED transactionFee "Use 'evaluateTransactionFee' instead" #-}


--TODO: in the Byron case the per-byte is non-integral, would need different
-- parameters. e.g. a new data type for fee params, Byron vs Shelley

-- | This can estimate what the transaction fee will be, based on a starting
-- base transaction, plus the numbers of the additional components of the
-- transaction that may be added.
--
-- So for example with wallet coin selection, the base transaction should
-- contain all the things not subject to coin selection (such as script inputs,
-- metadata, withdrawals, certs etc)
--
estimateTransactionFee :: forall era.
                          IsShelleyBasedEra era
                       => NetworkId
                       -> Natural -- ^ The fixed tx fee
                       -> Natural -- ^ The tx fee per byte
                       -> Tx era
                       -> Int -- ^ The number of extra UTxO transaction inputs
                       -> Int -- ^ The number of extra transaction outputs
                       -> Int -- ^ The number of extra Shelley key witnesses
                       -> Int -- ^ The number of extra Byron key witnesses
                       -> Lovelace
estimateTransactionFee nw txFeeFixed txFeePerByte (ShelleyTx era tx) =
    let Lovelace baseFee = transactionFee txFeeFixed txFeePerByte (ShelleyTx era tx)
     in \nInputs nOutputs nShelleyKeyWitnesses nByronKeyWitnesses ->

        --TODO: this is fragile. Move something like this to the ledger and
        -- make it robust, based on the txsize calculation.
        let extraBytes :: Int
            extraBytes = nInputs               * sizeInput
                       + nOutputs              * sizeOutput
                       + nByronKeyWitnesses    * sizeByronKeyWitnesses
                       + nShelleyKeyWitnesses  * sizeShelleyKeyWitnesses

         in Lovelace (baseFee + toInteger txFeePerByte * toInteger extraBytes)
  where
    sizeInput               = smallArray + uint + hashObj
    sizeOutput              = smallArray + uint + address
    sizeByronKeyWitnesses   = smallArray + keyObj + sigObj + ccodeObj + attrsObj
    sizeShelleyKeyWitnesses = smallArray + keyObj + sigObj

    smallArray  = 1
    uint        = 5

    hashObj     = 2 + hashLen
    hashLen     = 32

    keyObj      = 2 + keyLen
    keyLen      = 32

    sigObj      = 2 + sigLen
    sigLen      = 64

    ccodeObj    = 2 + ccodeLen
    ccodeLen    = 32

    address     = 2 + addrHeader + 2 * addrHashLen
    addrHeader  = 1
    addrHashLen = 28

    attrsObj    = 2 + BS.length attributes
    attributes  = CBOR.serialize' $
                    Byron.mkAttributes Byron.AddrAttributes {
                      Byron.aaVKDerivationPath = Nothing,
                      Byron.aaNetworkMagic     = toByronNetworkMagic nw
                    }

--TODO: This can be made to work for Byron txs too. Do that: fill in this case
-- and remove the IsShelleyBasedEra constraint.
estimateTransactionFee _ _ _ (ByronTx _) =
    case shelleyBasedEra :: ShelleyBasedEra era of {}

--TODO: also deprecate estimateTransactionFee:
--{-# DEPRECATED estimateTransactionFee "Use 'evaluateTransactionFee' instead" #-}


-- | Compute the transaction fee for a proposed transaction, with the
-- assumption that there will be the given number of key witnesses (i.e.
-- signatures).
--
-- TODO: we need separate args for Shelley vs Byron key sigs
--
evaluateTransactionFee :: forall era.
                          IsShelleyBasedEra era
                       => ProtocolParameters
                       -> TxBody era
                       -> Word  -- ^ The number of Shelley key witnesses
                       -> Word  -- ^ The number of Byron key witnesses
                       -> Lovelace
evaluateTransactionFee _ _ _ byronwitcount | byronwitcount > 0 =
  error "evaluateTransactionFee: TODO support Byron key witnesses"

evaluateTransactionFee pparams txbody keywitcount _byronwitcount =
    case makeSignedTransaction [] txbody of
      ByronTx{} -> case shelleyBasedEra :: ShelleyBasedEra era of {}
      --TODO: we could actually support Byron here, it'd be different but simpler

      ShelleyTx era tx -> withLedgerConstraints era (evalShelleyBasedEra era tx)
  where
    evalShelleyBasedEra :: forall ledgerera.
                           ShelleyLedgerEra era ~ ledgerera
                        => Ledger.CLI ledgerera
                        => ShelleyBasedEra era
                        -> Ledger.Tx ledgerera
                        -> Lovelace
    evalShelleyBasedEra era tx =
      fromShelleyLovelace $
        Ledger.evaluateTransactionFee
          (toLedgerPParams era pparams)
          tx
          keywitcount

    -- Conjur up all the necessary class instances and evidence
    withLedgerConstraints
      :: ShelleyLedgerEra era ~ ledgerera
      => ShelleyBasedEra era
      -> (   Ledger.CLI ledgerera
          => a)
      -> a
    withLedgerConstraints ShelleyBasedEraShelley f = f
    withLedgerConstraints ShelleyBasedEraAllegra f = f
    withLedgerConstraints ShelleyBasedEraMary    f = f
    withLedgerConstraints ShelleyBasedEraAlonzo  f = f

-- | Give an approximate count of the number of key witnesses (i.e. signatures)
-- a transaction will need.
--
-- This is an estimate not a precise count in that it can over-estimate: it
-- makes conservative assumptions such as all inputs are from distinct
-- addresses, but in principle multiple inputs can use the same address and we
-- only need a witness per address.
--
-- Similarly there can be overlap between the regular and collateral inputs,
-- but we conservatively assume they are distinct.
--
-- TODO: it is worth us considering a more precise count that relies on the
-- UTxO to resolve which inputs are for distinct addresses, and also to count
-- the number of Shelley vs Byron style witnesses.
--
estimateTransactionKeyWitnessCount :: TxBodyContent BuildTx era -> Word
estimateTransactionKeyWitnessCount TxBodyContent {
                                     txIns,
                                     txInsCollateral,
                                     txExtraKeyWits,
                                     txWithdrawals,
                                     txCertificates,
                                     txUpdateProposal
                                   } =
  fromIntegral $
    length [ () | (_txin, BuildTxWith KeyWitness{}) <- txIns ]

  + case txInsCollateral of
      TxInsCollateral _ txins
        -> length txins
      _ -> 0

  + case txExtraKeyWits of
      TxExtraKeyWitnesses _ khs
        -> length khs
      _ -> 0

  + case txWithdrawals of
      TxWithdrawals _ withdrawals
        -> length [ () | (_, _, BuildTxWith KeyWitness{}) <- withdrawals ]
      _ -> 0

  + case txCertificates of
      TxCertificates _ _ (BuildTxWith witnesses)
        -> length [ () | KeyWitness{} <- Map.elems witnesses ]
      _ -> 0

  + case txUpdateProposal of
      TxUpdateProposal _ (UpdateProposal updatePerGenesisKey _)
        -> Map.size updatePerGenesisKey
      _ -> 0


-- ----------------------------------------------------------------------------
-- Script execution units
--

-- | The different possible reasons that executing a script can fail,
-- as reported by 'evaluateTransactionExecutionUnits'.
--
-- The first three of these are about failures before we even get to execute
-- the script, and two are the result of execution.
--
data ScriptExecutionError =

       -- | The script depends on a 'TxIn' that has not been provided in the
       -- given 'UTxO' subset. The given 'UTxO' must cover all the inputs
       -- the transaction references.
       ScriptErrorMissingTxIn TxIn

       -- | The 'TxIn' the script is spending does not have a 'ScriptDatum'.
       -- All inputs guarded by Plutus scripts need to have been created with
       -- a 'ScriptDatum'.
     | ScriptErrorTxInWithoutDatum TxIn

       -- | The 'ScriptDatum' provided does not match the one from the 'UTxO'.
       -- This means the wrong 'ScriptDatum' value has been provided.
       --
     | ScriptErrorWrongDatum (Hash ScriptData)

       -- | The script evaluation failed. This usually means it evaluated to an
       -- error value. This is not a case of running out of execution units
       -- (which is not possible for 'evaluateTransactionExecutionUnits' since
       -- the whole point of it is to discover how many execution units are
       -- needed).
       --
     | ScriptErrorEvaluationFailed Plutus.EvaluationError

       -- | The execution units overflowed a 64bit word. Congratulations if
       -- you encounter this error. With the current style of cost model this
       -- would need a script to run for over 7 months, which is somewhat more
       -- than the expected maximum of a few milliseconds.
       --
     | ScriptErrorExecutionUnitsOverflow

       -- | An attempt was made to spend a key witnessed tx input
       -- with a script witness.
     | ScriptErrorNotPlutusWitnessedTxIn ScriptWitnessIndex
  deriving Show

instance Error ScriptExecutionError where
  displayError (ScriptErrorMissingTxIn txin) =
      "The supplied UTxO is missing the txin " ++ Text.unpack (renderTxIn txin)

  displayError (ScriptErrorTxInWithoutDatum txin) =
      "The Plutus script witness for the txin does not have a script datum "
   ++ "(according to the UTxO). The txin in question is "
   ++ Text.unpack (renderTxIn txin)

  displayError (ScriptErrorWrongDatum dh) =
      "The Plutus script witness has the wrong datum (according to the UTxO). "
   ++ "The expected datum value has hash " ++ show dh

  displayError (ScriptErrorEvaluationFailed evalErr) =
      "The Plutus script evaluation failed: " ++ pp evalErr
    where
      pp :: PP.Pretty p => p -> String
      pp = PP.renderString
         . PP.layoutPretty PP.defaultLayoutOptions
         . PP.pretty

  displayError ScriptErrorExecutionUnitsOverflow =
      "The execution units required by this Plutus script overflows a 64bit "
   ++ "word. In a properly configured chain this should be practically "
   ++ "impossible. So this probably indicates a chain configuration problem, "
   ++ "perhaps with the values in the cost model."

  displayError (ScriptErrorNotPlutusWitnessedTxIn scriptWitness) =
      renderScriptWitnessIndex scriptWitness <> " is not a Plutus script \
      \witnessed tx input and cannot be spent using a Plutus script witness."

-- | The transaction validity interval is too far into the future.
--
-- Transactions with Plutus scripts need to have a validity interval that is
-- not so far in the future that we cannot reliably determine the UTC time
-- corresponding to the validity interval expressed in slot numbers.
--
-- This is because the Plutus scripts get given the transaction validity
-- interval in UTC time, so that they are not sensitive to slot lengths.
--
-- If either end of the validity interval is beyond the so called \"time
-- horizon\" then the consensus algorithm is not able to reliably determine
-- the relationship between slots and time. This is this situation in which
-- this error is reported. For the Cardano mainnet the time horizon is 36
-- hours beyond the current time. This effectively means we cannot submit
-- check or submit transactions that use Plutus scripts that have the end
-- of their validity interval more than 36 hours into the future.
--
newtype TransactionValidityIntervalError =
          TransactionValidityIntervalError Consensus.PastHorizonException
  deriving Show

instance Error TransactionValidityIntervalError where
  displayError (TransactionValidityIntervalError pastTimeHorizon) =
      "The transaction validity interval is too far in the future. "
   ++ "For this network it must not be more than "
   ++ show (timeHorizonSlots pastTimeHorizon)
   ++ "slots ahead of the current time slot. "
   ++ "(Transactions with Plutus scripts must have validity intervals that "
   ++ "are close enough in the future that we can reliably turn the slot "
   ++ "numbers into UTC wall clock times.)"
    where
      timeHorizonSlots :: Consensus.PastHorizonException -> Word
      timeHorizonSlots Consensus.PastHorizon{Consensus.pastHorizonSummary}
        | eraSummaries@(_:_) <- pastHorizonSummary
        , Consensus.StandardSafeZone slots <-
            (Consensus.eraSafeZone . Consensus.eraParams . last) eraSummaries
        = fromIntegral slots

        | otherwise
        = 0 -- This should be impossible.



-- | Compute the 'ExecutionUnits' needed for each script in the transaction.
--
-- This works by running all the scripts and counting how many execution units
-- are actually used.
--
evaluateTransactionExecutionUnits
  :: forall era mode.
     EraInMode era mode
  -> SystemStart
  -> EraHistory mode
  -> ProtocolParameters
  -> UTxO era
  -> TxBody era
  -> Either TransactionValidityIntervalError
            (Map ScriptWitnessIndex (Either ScriptExecutionError ExecutionUnits))
evaluateTransactionExecutionUnits _eraInMode systemstart history pparams utxo txbody =
    case makeSignedTransaction [] txbody of
      ByronTx {}                 -> evalPreAlonzo
      ShelleyTx era tx' ->
        case era of
          ShelleyBasedEraShelley -> evalPreAlonzo
          ShelleyBasedEraAllegra -> evalPreAlonzo
          ShelleyBasedEraMary    -> evalPreAlonzo
          ShelleyBasedEraAlonzo  -> evalAlonzo era tx'
  where
    -- Pre-Alonzo eras do not support languages with execution unit accounting.
    evalPreAlonzo :: Either TransactionValidityIntervalError
                            (Map ScriptWitnessIndex
                                 (Either ScriptExecutionError ExecutionUnits))
    evalPreAlonzo = Right Map.empty

    evalAlonzo :: forall ledgerera.
                  ShelleyLedgerEra era ~ ledgerera
               => ledgerera ~ Alonzo.AlonzoEra Ledger.StandardCrypto
               => LedgerEraConstraints ledgerera
               => ShelleyBasedEra era
               -> Ledger.Tx ledgerera
               -> Either TransactionValidityIntervalError
                         (Map ScriptWitnessIndex
                              (Either ScriptExecutionError ExecutionUnits))
    evalAlonzo era tx =
      case Alonzo.evaluateTransactionExecutionUnits
             (toLedgerPParams era pparams)
             tx
             (toLedgerUTxO era utxo)
             (toLedgerEpochInfo history)
             systemstart
             (toAlonzoCostModels (protocolParamCostModels pparams))
        of Left  err   -> Left err
           Right exmap -> Right (fromLedgerScriptExUnitsMap exmap)

    toLedgerEpochInfo :: EraHistory mode
                      -> EpochInfo (Either TransactionValidityIntervalError)
    toLedgerEpochInfo (EraHistory _ interpreter) =
        hoistEpochInfo (first TransactionValidityIntervalError . runExcept) $
          Consensus.interpreterToEpochInfo interpreter

    toAlonzoCostModels :: Map AnyPlutusScriptVersion CostModel
                       -> Array.Array Alonzo.Language Alonzo.CostModel
    toAlonzoCostModels costmodels =
      Array.array
        (minBound, maxBound)
        [ (toAlonzoLanguage lang, toAlonzoCostModel costmodel)
        | (lang, costmodel) <- Map.toList costmodels ]

    fromLedgerScriptExUnitsMap
      :: Map Alonzo.RdmrPtr (Either (Alonzo.ScriptFailure Ledger.StandardCrypto)
                                    Alonzo.ExUnits)
      -> Map ScriptWitnessIndex (Either ScriptExecutionError ExecutionUnits)
    fromLedgerScriptExUnitsMap exmap =
      Map.fromList
        [ (fromAlonzoRdmrPtr rdmrptr,
           bimap fromAlonzoScriptExecutionError fromAlonzoExUnits exunitsOrFailure)
        | (rdmrptr, exunitsOrFailure) <- Map.toList exmap ]

    fromAlonzoScriptExecutionError :: Alonzo.ScriptFailure Ledger.StandardCrypto
                                   -> ScriptExecutionError
    fromAlonzoScriptExecutionError failure =
      case failure of
        Alonzo.UnknownTxIn     txin -> ScriptErrorMissingTxIn txin'
                                         where txin' = fromShelleyTxIn txin
        Alonzo.InvalidTxIn     txin -> ScriptErrorTxInWithoutDatum txin'
                                         where txin' = fromShelleyTxIn txin
        Alonzo.MissingDatum      dh -> ScriptErrorWrongDatum (ScriptDataHash dh)
        Alonzo.ValidationFailed err -> ScriptErrorEvaluationFailed err
        Alonzo.IncompatibleBudget _ -> ScriptErrorExecutionUnitsOverflow

        -- This is only possible for spending scripts and occurs when
        -- we attempt to spend a key witnessed tx input with a Plutus
        -- script witness.
        Alonzo.RedeemerNotNeeded rdmrPtr ->
          ScriptErrorNotPlutusWitnessedTxIn $ fromAlonzoRdmrPtr rdmrPtr
        -- Some of the errors are impossible by construction, given the way we
        -- build transactions in the API:
        Alonzo.MissingScript rdmrPtr ->
          impossible ("MissingScript " ++ show (fromAlonzoRdmrPtr rdmrPtr))

    impossible detail = error $ "evaluateTransactionExecutionUnits: "
                             ++ "the impossible happened: " ++ detail


-- ----------------------------------------------------------------------------
-- Transaction balance
--

-- | Compute the total balance of the proposed transaction. Ultimately a valid
-- transaction must be fully balanced: that is have a total value of zero.
--
-- Finding the (non-zero) balance of partially constructed transaction is
-- useful for adjusting a transaction to be fully balanced.
--
evaluateTransactionBalance :: forall era.
                              IsShelleyBasedEra era
                           => ProtocolParameters
                           -> Set PoolId
                           -> UTxO era
                           -> TxBody era
                           -> TxOutValue era
evaluateTransactionBalance _ _ _ (ByronTxBody _) =
    case shelleyBasedEra :: ShelleyBasedEra era of {}
    --TODO: we could actually support Byron here, it'd be different but simpler

evaluateTransactionBalance pparams poolids utxo
                           (ShelleyTxBody era txbody _ _ _ _) =
    withLedgerConstraints era evalAdaOnly evalMultiAsset
  where
    isNewPool :: Ledger.KeyHash Ledger.StakePool Ledger.StandardCrypto -> Bool
    isNewPool kh = StakePoolKeyHash kh `Set.notMember` poolids

    evalMultiAsset :: forall ledgerera.
                      ShelleyLedgerEra era ~ ledgerera
                   => LedgerEraConstraints ledgerera
                   => LedgerMultiAssetConstraints ledgerera
                   => MultiAssetSupportedInEra era
                   -> TxOutValue era
    evalMultiAsset evidence =
      TxOutValue evidence . fromMaryValue $
         Ledger.evaluateTransactionBalance
           (toLedgerPParams era pparams)
           (toLedgerUTxO era utxo)
           isNewPool
           txbody

    evalAdaOnly :: forall ledgerera.
                   ShelleyLedgerEra era ~ ledgerera
                => LedgerEraConstraints ledgerera
                => LedgerAdaOnlyConstraints ledgerera
                => OnlyAdaSupportedInEra era
                -> TxOutValue era
    evalAdaOnly evidence =
     TxOutAdaOnly evidence . fromShelleyLovelace
       $ Ledger.evaluateTransactionBalance
           (toLedgerPParams era pparams)
           (toLedgerUTxO era utxo)
           isNewPool
           txbody

    -- Conjur up all the necessary class instances and evidence
    withLedgerConstraints
      :: ShelleyLedgerEra era ~ ledgerera
      => ShelleyBasedEra era
      -> (   LedgerEraConstraints ledgerera
          => LedgerAdaOnlyConstraints ledgerera
          => LedgerPParamsConstraints ledgerera
          => LedgerTxBodyConstraints ledgerera
          => OnlyAdaSupportedInEra era
          -> a)
      -> (   LedgerEraConstraints ledgerera
          => LedgerMultiAssetConstraints ledgerera
          => LedgerPParamsConstraints ledgerera
          => LedgerTxBodyConstraints ledgerera
          => MultiAssetSupportedInEra era
          -> a)
      -> a
    withLedgerConstraints ShelleyBasedEraShelley f _ = f AdaOnlyInShelleyEra
    withLedgerConstraints ShelleyBasedEraAllegra f _ = f AdaOnlyInAllegraEra
    withLedgerConstraints ShelleyBasedEraMary    _ f = f MultiAssetInMaryEra
    withLedgerConstraints ShelleyBasedEraAlonzo  _ f = f MultiAssetInAlonzoEra

type LedgerEraConstraints ledgerera =
       ( Ledger.Era.Crypto ledgerera ~ Ledger.StandardCrypto
       , Ledger.CLI ledgerera
       )

type LedgerAdaOnlyConstraints ledgerera =
         Ledger.Value ledgerera ~ Ledger.Coin

type LedgerMultiAssetConstraints ledgerera =
       ( Ledger.Value ledgerera ~ Mary.Value Ledger.StandardCrypto
       , HasField "mint" (Ledger.TxBody ledgerera) (Ledger.Value ledgerera)
       )

type LedgerPParamsConstraints ledgerera =
       ( HasField "_minfeeA"     (Ledger.PParams ledgerera) Natural
       , HasField "_minfeeB"     (Ledger.PParams ledgerera) Natural
       , HasField "_keyDeposit"  (Ledger.PParams ledgerera) Ledger.Coin
       , HasField "_poolDeposit" (Ledger.PParams ledgerera) Ledger.Coin
       )

type LedgerTxBodyConstraints ledgerera =
       ( HasField "certs" (Ledger.TxBody ledgerera)
                          (StrictSeq (Ledger.DCert Ledger.StandardCrypto))
       , HasField "inputs" (Ledger.TxBody ledgerera)
                           (Set (Ledger.TxIn Ledger.StandardCrypto))
       , HasField "wdrls" (Ledger.TxBody ledgerera) (Ledger.Wdrl Ledger.StandardCrypto)
       )


-- ----------------------------------------------------------------------------
-- Automated transaction building
--

-- | The possible errors that can arise from 'makeTransactionBodyAutoBalance'.
--
data TxBodyErrorAutoBalance =

       -- | The same errors that can arise from 'makeTransactionBody'.
       TxBodyError TxBodyError

       -- | One or more of the scripts fails to execute correctly.
     | TxBodyScriptExecutionError [(ScriptWitnessIndex, ScriptExecutionError)]

       -- | One or more of the scripts were expected to fail validation, but none did.
     | TxBodyScriptBadScriptValidity

       -- | The balance of the non-ada assets is not zero. The 'Value' here is
       -- that residual non-zero balance. The 'makeTransactionBodyAutoBalance'
       -- function only automatically balances ada, not other assets.
     | TxBodyErrorAssetBalanceWrong Value

       -- | There is not enough ada to cover both the outputs and the fees.
       -- The transaction should be changed to provide more input ada, or
       -- otherwise adjusted to need less (e.g. outputs, script etc).
       --
     | TxBodyErrorAdaBalanceNegative Lovelace

       -- | There is enough ada to cover both the outputs and the fees, but the
       -- resulting change is too small: it is under the minimum value for
       -- new UTxO entries. The transaction should be changed to provide more
       -- input ada.
       --
     | TxBodyErrorAdaBalanceTooSmall
         -- ^ Offending TxOut
         TxOutInAnyEra
         -- ^ Minimum UTxO
         Lovelace
         -- ^ Tx balance
         Lovelace

       -- | 'makeTransactionBodyAutoBalance' does not yet support the Byron era.
     | TxBodyErrorByronEraNotSupported

       -- | The 'ProtocolParameters' must provide the value for the min utxo
       -- parameter, for eras that use this parameter.
     | TxBodyErrorMissingParamMinUTxO

       -- | The 'ProtocolParameters' must provide the value for the cost per
       -- word parameter, for eras that use this parameter.
     | TxBodyErrorMissingParamCostPerWord

       -- | The transaction validity interval is too far into the future.
       -- See 'TransactionValidityIntervalError' for details.
     | TxBodyErrorValidityInterval TransactionValidityIntervalError

       -- | The minimum spendable UTxO threshold has not been met.
     | TxBodyErrorMinUTxONotMet
         -- ^ Offending TxOut
         TxOutInAnyEra
         -- ^ Minimum UTxO
         Lovelace
     | TxBodyErrorMinUTxOMissingPParams MinimumUTxOError
     | TxBodyErrorNonAdaAssetsUnbalanced Value
  deriving Show


instance Error TxBodyErrorAutoBalance where
  displayError (TxBodyError err) = displayError err

  displayError (TxBodyScriptExecutionError failures) =
      "The following scripts have execution failures:\n"
   ++ unlines [ "the script for " ++ renderScriptWitnessIndex index
                ++ " failed with: " ++ "\n" ++ displayError failure
              | (index, failure) <- failures ]

  displayError TxBodyScriptBadScriptValidity =
      "One or more of the scripts were expected to fail validation, but none did."

  displayError (TxBodyErrorAssetBalanceWrong _value) =
      "The transaction does not correctly balance in its non-ada assets. "
   ++ "The balance between inputs and outputs should sum to zero. "
   ++ "The actual balance is: "
   ++ "TODO: move the Value renderer and parser from the CLI into the API and use them here"
   -- TODO: do this ^^

  displayError (TxBodyErrorAdaBalanceNegative lovelace) =
      "The transaction does not balance in its use of ada. The net balance "
   ++ "of the transaction is negative: " ++ show lovelace ++ " lovelace. "
   ++ "The usual solution is to provide more inputs, or inputs with more ada."

  displayError (TxBodyErrorAdaBalanceTooSmall changeOutput minUTxO balance) =
      "The transaction does balance in its use of ada, however the net "
   ++ "balance does not meet the minimum UTxO threshold. \n"
   ++ "Balance: " ++ show balance ++ "\n"
   ++ "Offending output (change output): " ++ Text.unpack (prettyRenderTxOut changeOutput) ++ "\n"
   ++ "Minimum UTxO threshold: " ++ show minUTxO ++ "\n"
   ++ "The usual solution is to provide more inputs, or inputs with more ada to \
      \meet the minimum UTxO threshold"

  displayError TxBodyErrorByronEraNotSupported =
      "The Byron era is not yet supported by makeTransactionBodyAutoBalance"

  displayError TxBodyErrorMissingParamMinUTxO =
      "The minUTxOValue protocol parameter is required but missing"

  displayError TxBodyErrorMissingParamCostPerWord =
      "The utxoCostPerWord protocol parameter is required but missing"

  displayError (TxBodyErrorValidityInterval err) =
      displayError err

  displayError (TxBodyErrorMinUTxONotMet txout minUTxO) =
      "Minimum UTxO threshold not met for tx output: " <> Text.unpack (prettyRenderTxOut txout) <> "\n"
   <> "Minimum required UTxO: " <> show minUTxO

  displayError (TxBodyErrorNonAdaAssetsUnbalanced val) =
      "Non-Ada assets are unbalanced: " <> Text.unpack (renderValue val)

  displayError (TxBodyErrorMinUTxOMissingPParams err) = displayError err

handleExUnitsErrors ::
     ScriptValidity -- ^ Mark script as expected to pass or fail validation
  -> Map ScriptWitnessIndex ScriptExecutionError
  -> Map ScriptWitnessIndex ExecutionUnits
  -> Either TxBodyErrorAutoBalance (Map ScriptWitnessIndex ExecutionUnits)
handleExUnitsErrors ScriptValid failuresMap exUnitsMap =
    if null failures
      then Right exUnitsMap
      else Left (TxBodyScriptExecutionError failures)
  where failures :: [(ScriptWitnessIndex, ScriptExecutionError)]
        failures = Map.toList failuresMap
handleExUnitsErrors ScriptInvalid failuresMap exUnitsMap
  | null scriptFailures = Left TxBodyScriptBadScriptValidity
  | null nonScriptFailures = Right exUnitsMap
  | otherwise = Left (TxBodyScriptExecutionError nonScriptFailures)
  where nonScriptFailures :: [(ScriptWitnessIndex, ScriptExecutionError)]
        nonScriptFailures = filter (not . isScriptErrorEvaluationFailed) (Map.toList failuresMap)
        scriptFailures :: [(ScriptWitnessIndex, ScriptExecutionError)]
        scriptFailures = filter isScriptErrorEvaluationFailed (Map.toList failuresMap)
        isScriptErrorEvaluationFailed :: (ScriptWitnessIndex, ScriptExecutionError) -> Bool
        isScriptErrorEvaluationFailed (_, e) = case e of
            ScriptErrorEvaluationFailed _ -> True
            _ -> True

data BalancedTxBody era
  = BalancedTxBody
      (TxBody era)
      (TxOut era) -- ^ Transaction balance (change output)
      Lovelace    -- ^ Estimated transaction fee

-- | This is much like 'makeTransactionBody' but with greater automation to
-- calculate suitable values for several things.
--
-- In particular:
--
-- * It calculates the correct script 'ExecutionUnits' (ignoring the provided
--   values, which can thus be zero).
--
-- * It calculates the transaction fees, based on the script 'ExecutionUnits',
--   the current 'ProtocolParameters', and an estimate of the number of
--   key witnesses (i.e. signatures). There is an override for the number of
--   key witnesses.
--
-- * It accepts a change address, calculates the balance of the transaction
--   and puts the excess change into the change output.
--
-- * It also checks that the balance is positive and the change is above the
--   minimum threshold.
--
-- To do this it needs more information than 'makeTransactionBody', all of
-- which can be queried from a local node.
--
makeTransactionBodyAutoBalance
  :: forall era mode.
     IsShelleyBasedEra era
  => EraInMode era mode
  -> SystemStart
  -> EraHistory mode
  -> ProtocolParameters
  -> Set PoolId       -- ^ The set of registered stake pools
  -> UTxO era         -- ^ Just the transaction inputs, not the entire 'UTxO'.
  -> TxBodyContent BuildTx era
  -> AddressInEra era -- ^ Change address
  -> Maybe Word       -- ^ Override key witnesses
  -> Either TxBodyErrorAutoBalance (BalancedTxBody era)
makeTransactionBodyAutoBalance eraInMode systemstart history pparams
                            poolids utxo txbodycontent changeaddr mnkeys = do

    -- Our strategy is to:
    -- 1. evaluate all the scripts to get the exec units, update with ex units
    -- 2. figure out the overall min fees
    -- 3. update tx with fees
    -- 4. balance the transaction and update tx change output

    txbody0 <-
      first TxBodyError $ makeTransactionBody txbodycontent
        { txOuts =
              TxOut changeaddr (lovelaceToTxOutValue 0) TxOutDatumHashNone
            : txOuts txbodycontent
            --TODO: think about the size of the change output
            -- 1,2,4 or 8 bytes?
        }

    exUnitsMap <- first TxBodyErrorValidityInterval $
                    evaluateTransactionExecutionUnits
                      eraInMode
                      systemstart history
                      pparams
                      utxo
                      txbody0

    exUnitsMap' <-
      case Map.mapEither id exUnitsMap of
        (failures, exUnitsMap') ->
          handleExUnitsErrors
            (txScriptValidityToScriptValidity (txScriptValidity txbodycontent))
            failures
            exUnitsMap'

    let txbodycontent1 = substituteExecutionUnits exUnitsMap' txbodycontent

    explicitTxFees <- first (const TxBodyErrorByronEraNotSupported) $
                        txFeesExplicitInEra era'

    -- Make a txbody that we will use for calculating the fees. For the purpose
    -- of fees we just need to make a txbody of the right size in bytes. We do
    -- not need the right values for the fee or change output. We use
    -- "big enough" values for the change output and set so that the CBOR
    -- encoding size of the tx will be big enough to cover the size of the final
    -- output and fee. Yes this means this current code will only work for
    -- final fee of less than around 4000 ada (2^32-1 lovelace) and change output
    -- of less than around 18 trillion ada  (2^64-1 lovelace).
    txbody1 <- first TxBodyError $ -- TODO: impossible to fail now
               makeTransactionBody txbodycontent1 {
                 txFee  = TxFeeExplicit explicitTxFees $ Lovelace (2^(32 :: Integer) - 1),
                 txOuts = TxOut changeaddr
                                (lovelaceToTxOutValue $ Lovelace (2^(64 :: Integer)) - 1)
                                TxOutDatumHashNone
                        : txOuts txbodycontent
               }

    let nkeys = fromMaybe (estimateTransactionKeyWitnessCount txbodycontent1)
                          mnkeys
        fee   = evaluateTransactionFee pparams txbody1 nkeys 0 --TODO: byron keys

    -- Make a txbody for calculating the balance. For this the size of the tx
    -- does not matter, instead it's just the values of the fee and outputs.
    -- Here we do not want to start with any change output, since that's what
    -- we need to calculate.
    txbody2 <- first TxBodyError $ -- TODO: impossible to fail now
               makeTransactionBody txbodycontent1 {
                 txFee = TxFeeExplicit explicitTxFees fee
               }

    let balance = evaluateTransactionBalance pparams poolids utxo txbody2

    mapM_ (`checkMinUTxOValue` pparams) $ txOuts txbodycontent1

    -- check if the balance is positive or negative
    -- in one case we can produce change, in the other the inputs are insufficient
    case balance of
      TxOutAdaOnly _ _ -> balanceCheck balance
      TxOutValue _ v   ->
        case valueToLovelace v of
          Nothing -> Left $ TxBodyErrorNonAdaAssetsUnbalanced v
          Just _ -> balanceCheck balance

    --TODO: we could add the extra fee for the CBOR encoding of the change,
    -- now that we know the magnitude of the change: i.e. 1-8 bytes extra.

    -- The txbody with the final fee and change output. This should work
    -- provided that the fee and change are less than 2^32-1, and so will
    -- fit within the encoding size we picked above when calculating the fee.
    -- Yes this could be an over-estimate by a few bytes if the fee or change
    -- would fit within 2^16-1. That's a possible optimisation.
    txbody3 <-
      first TxBodyError $ -- TODO: impossible to fail now
        makeTransactionBody txbodycontent1 {
          txFee  = TxFeeExplicit explicitTxFees fee,
          txOuts = accountForNoChange
                     (TxOut changeaddr balance TxOutDatumHashNone)
                     (txOuts txbodycontent)
        }
    return (BalancedTxBody txbody3 (TxOut changeaddr balance TxOutDatumHashNone) fee)
 where
   era :: ShelleyBasedEra era
   era = shelleyBasedEra

   era' :: CardanoEra era
   era' = cardanoEra

   -- In the event of spending the exact amount of lovelace in
   -- the specified input(s), this function excludes the change
   -- output. Note that this does not save any fees because by default
   -- the fee calculation includes a change address for simplicity and
   -- we make no attempt to recalculate the tx fee without a change address.
   accountForNoChange :: TxOut era -> [TxOut era] -> [TxOut era]
   accountForNoChange change@(TxOut _ balance _) rest =
     case txOutValueToLovelace balance of
       Lovelace 0 -> rest
       _ -> change : rest

   balanceCheck :: TxOutValue era -> Either TxBodyErrorAutoBalance ()
   balanceCheck balance
    | txOutValueToLovelace balance == 0 = return ()
    | txOutValueToLovelace balance < 0 =
        Left . TxBodyErrorAdaBalanceNegative $ txOutValueToLovelace balance
    | otherwise =
        case checkMinUTxOValue (TxOut changeaddr balance TxOutDatumHashNone) pparams of
          Left (TxBodyErrorMinUTxONotMet txOutAny minUTxO) ->
            Left $ TxBodyErrorAdaBalanceTooSmall txOutAny minUTxO (txOutValueToLovelace balance)
          Left err -> Left err
          Right _ -> Right ()

   checkMinUTxOValue
     :: TxOut era
     -> ProtocolParameters
     -> Either TxBodyErrorAutoBalance ()
   checkMinUTxOValue txout@(TxOut _ v _) pparams' = do
     minUTxO  <- first TxBodyErrorMinUTxOMissingPParams
                   $ calculateMinimumUTxO era txout pparams'
     if txOutValueToLovelace v >= selectLovelace minUTxO
     then Right ()
     else Left $ TxBodyErrorMinUTxONotMet
                   (txOutInAnyEra txout)
                   (selectLovelace minUTxO)

substituteExecutionUnits :: Map ScriptWitnessIndex ExecutionUnits
                         -> TxBodyContent BuildTx era
                         -> TxBodyContent BuildTx era
substituteExecutionUnits exUnitsMap =
    mapTxScriptWitnesses f
  where
    f :: ScriptWitnessIndex
      -> ScriptWitness witctx era
      -> ScriptWitness witctx era
    f _   wit@SimpleScriptWitness{} = wit
    f idx wit@(PlutusScriptWitness langInEra version script datum redeemer _) =
      case Map.lookup idx exUnitsMap of
        Nothing      -> wit
        Just exunits -> PlutusScriptWitness langInEra version script
                                            datum redeemer exunits

calculateMinimumUTxO
  :: ShelleyBasedEra era
  -> TxOut era
  -> ProtocolParameters
  -> Either MinimumUTxOError Value
calculateMinimumUTxO era txout@(TxOut _ v _) pparams' =
  case era of
    ShelleyBasedEraShelley -> lovelaceToValue <$> getMinUTxOPreAlonzo pparams'
    ShelleyBasedEraAllegra -> calcMinUTxOAllegraMary
    ShelleyBasedEraMary -> calcMinUTxOAllegraMary
    ShelleyBasedEraAlonzo ->
      case protocolParamUTxOCostPerWord pparams' of
        Just (Lovelace costPerWord) -> do
          Right . lovelaceToValue
            $ Lovelace (Alonzo.utxoEntrySize (toShelleyTxOut era txout) * costPerWord)
        Nothing -> Left PParamsUTxOCostPerWordMissing
 where
   calcMinUTxOAllegraMary :: Either MinimumUTxOError Value
   calcMinUTxOAllegraMary = do
     let val = txOutValueToValue v
     minUTxO <- getMinUTxOPreAlonzo pparams'
     Right . lovelaceToValue $ calcMinimumDeposit val minUTxO

   getMinUTxOPreAlonzo
     :: ProtocolParameters -> Either MinimumUTxOError Lovelace
   getMinUTxOPreAlonzo =
     maybe (Left PParamsMinUTxOMissing) Right . protocolParamMinUTxOValue

data MinimumUTxOError =
    PParamsMinUTxOMissing
  | PParamsUTxOCostPerWordMissing
  deriving Show

instance Error MinimumUTxOError where
  displayError PParamsMinUTxOMissing =
    "\"minUtxoValue\" field not present in protocol parameters when \
    \trying to calculate minimum UTxO value."
  displayError PParamsUTxOCostPerWordMissing =
    "\"utxoCostPerWord\" field not present in protocol parameters when \
    \trying to calculate minimum UTxO value."
