{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Pos.Ssc.Class.Helpers
       (
         SscHelpersClass (..)
       ) where

import           Data.Tagged         (Tagged)
import           Universum

import           Pos.Ssc.Class.Types (Ssc (..))
import           Pos.Types.Core      (EpochIndex)
import           Pos.Types.Types     (MainBlockHeader)

class Ssc ssc => SscHelpersClass ssc where
    sscVerifyPayload ::
        Tagged ssc ( Either EpochIndex (MainBlockHeader ssc) ->
                     SscPayload ssc ->
                     Either (SscVerifyError ssc) ())
