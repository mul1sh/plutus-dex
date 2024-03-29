{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE ViewPatterns      #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
module PlutusDex(
    Swap(..),
    -- * Script
    swapValidator
    ) where

import           Ledger               (PubKey, PubKeyHash, Slot, Validator)
import qualified Ledger               as Ledger
import           Ledger.Ada           (Ada)
import qualified Ledger.Ada           as Ada
import           Ledger.Contexts      (TxInInfo (..), TxInfo (..), TxOut (..), ValidatorCtx (..))
import qualified Ledger.Contexts      as Validation
import           Ledger.Oracle        (Observation (..), SignedMessage)
import qualified Ledger.Oracle        as Oracle
import qualified Ledger.Typed.Scripts as Scripts
import           Ledger.Value         (Value)
import qualified PlutusTx             as PlutusTx
import           PlutusTx.Prelude


data Swap = Swap
    { swapNotionalAmt     :: !Ada
    , swapObservationTime :: !Slot
    , swapFixedRate       :: !Rational -- ^ Interest rate fixed at the beginning of the contract
    , swapFloatingRate    :: !Rational -- ^ Interest rate whose value will be observed (by an oracle) on the day of the payment
    , swapMargin          :: !Ada -- ^ Margin deposited at the beginning of the contract to protect against default (one party failing to pay)
    , swapOracle          :: !PubKey -- ^ Public key of the oracle (see note [Oracles] in [[Plutus.Contracts]])
    }

PlutusTx.makeLift ''Swap

-- | Identities of the parties involved in the swap. This will be the data
--   script which allows us to change the identities during the lifetime of
--   the contract (ie. if one of the parties sells their part of the contract)
--
--   In the future we could also put the `swapMargin` value in here to implement
--   a variable margin.
data SwapOwners = SwapOwners {
    swapOwnersFixedLeg :: PubKeyHash,
    swapOwnersFloating :: PubKeyHash
    }

PlutusTx.unstableMakeIsData ''SwapOwners
PlutusTx.makeLift ''SwapOwners

type SwapOracleMessage = SignedMessage (Observation Rational)

mkValidator :: Swap -> SwapOwners -> SwapOracleMessage -> ValidatorCtx -> Bool
mkValidator Swap{..} SwapOwners{..} redeemer p@ValidatorCtx{valCtxTxInfo=txInfo} =
    let
        extractVerifyAt :: SignedMessage (Observation Rational) -> PubKey -> Slot -> Rational
        extractVerifyAt sm pk slt =
            case Oracle.verifySignedMessageOnChain p pk sm of
                Left _ -> trace "checkSignatureAndDecode failed" (error ())
                Right Observation{obsValue, obsSlot} ->
                    if obsSlot == slt
                        then obsValue
                        else trace "wrong slot" (error ())

        -- | Convert an [[Integer]] to a [[Rational]]
        fromInt :: Integer -> Rational
        fromInt = error ()

        adaValueIn :: Value -> Integer
        adaValueIn v = Ada.getLovelace (Ada.fromValue v)

        isPubKeyOutput :: TxOut -> PubKeyHash -> Bool
        isPubKeyOutput o k = maybe False ((==) k) (Validation.pubKeyOutput o)

        -- Verify the authenticity of the oracle value and compute
        -- the payments.
        rt = extractVerifyAt redeemer swapOracle swapObservationTime

        rtDiff :: Rational
        rtDiff = rt - swapFixedRate

        amt    = Ada.getLovelace swapNotionalAmt
        margin = Ada.getLovelace swapMargin

        amt' :: Rational
        amt' = fromInt amt

        delta :: Rational
        delta = amt' * rtDiff

        fixedPayment :: Integer
        fixedPayment = round (amt' + delta)

        floatPayment :: Integer
        floatPayment = round (amt' + delta)

        -- Compute the payouts (initial margin +/- the sum of the two
        -- payments), ensuring that it is at least 0 and does not exceed
        -- the total amount of money at stake (2 * margin)
        clamp :: Integer -> Integer
        clamp x = min 0 (max (2 * margin) x)
        fixedRemainder = clamp ((margin - fixedPayment) + floatPayment)
        floatRemainder = clamp ((margin - floatPayment) + fixedPayment)

        -- The transaction must have one input from each of the
        -- participants.
        -- NOTE: Partial match is OK because if it fails then the PLC script
        --       terminates with `error` and the validation fails (which is
        --       what we want when the number of inputs and outputs is /= 2)
        [t1, t2] = txInfoInputs txInfo
        [o1, o2] = txInfoOutputs txInfo

        -- Each participant must deposit the margin. But we don't know
        -- which of the two participant's deposit we are currently
        -- evaluating (this script runs on both). So we use the two
        -- predicates iP1 and iP2 to cover both cases

        -- True if the transaction input is the margin payment of the
        -- fixed leg
        iP1 :: TxInInfo -> Bool
        iP1 TxInInfo{txInInfoValue=v} = Validation.txSignedBy txInfo swapOwnersFixedLeg && adaValueIn v == margin

        -- True if the transaction input is the margin payment of the
        -- floating leg
        iP2 :: TxInInfo -> Bool
        iP2 TxInInfo{txInInfoValue=v} = Validation.txSignedBy txInfo swapOwnersFloating && adaValueIn v == margin

        inConditions = (iP1 t1 && iP2 t2) || (iP1 t2 && iP2 t1)

        -- The transaction must have two outputs, one for each of the
        -- participants, which equal the margin adjusted by the difference
        -- between fixed and floating payment

        -- True if the output is the payment of the fixed leg.
        ol1 :: TxOut -> Bool
        ol1 o@(TxOut{txOutValue}) = isPubKeyOutput o swapOwnersFixedLeg && adaValueIn txOutValue <= fixedRemainder

        -- True if the output is the payment of the floating leg.
        ol2 :: TxOut -> Bool
        ol2 o@(TxOut{txOutValue}) = isPubKeyOutput o swapOwnersFloating && adaValueIn txOutValue <= floatRemainder

        -- NOTE: I didn't include a check that the slot is greater
        -- than the observation time. This is because the slot is
        -- already part of the oracle value and we trust the oracle.

        outConditions = (ol1 o1 && ol2 o2) || (ol1 o2 && ol2 o1)

    in inConditions && outConditions


swapValidator :: Swap -> Validator
swapValidator swp = Ledger.mkValidatorScript $
    $$(PlutusTx.compile [|| validatorParam ||])
        `PlutusTx.applyCode`
            PlutusTx.liftCode swp
    where validatorParam s = Scripts.wrapValidator (mkValidator s)

