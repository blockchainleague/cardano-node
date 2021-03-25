{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

{-# OPTIONS_GHC -Wno-unused-imports  #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.TraceDispatcher.ChainDBTracer
  ( docChainDBTraceEvent
  ) where


import           Data.Aeson (Value (String), toJSON, (.=))
import qualified Data.Aeson as A
import           Data.HashMap.Strict (insertWith)
import qualified Data.Text as Text
import           NoThunks.Class (NoThunks)
import qualified Data.List.NonEmpty as NE

import           Cardano.Logging
import           Cardano.Prelude hiding (Show, show)
import           Text.Show
import           Cardano.Slotting.Slot (EpochNo(..))
import           Cardano.TraceDispatcher.OrphanInstances.Consensus ()
import           Cardano.TraceDispatcher.OrphanInstances.Network ()
import           Cardano.TraceDispatcher.Render (condenseT,
                     renderHeaderHashForDetails, renderPoint,
                     renderPointAsPhrase, renderPointForDetails,
                     renderRealPoint, renderRealPointAsPhrase, showT)

import           Ouroboros.Consensus.Block (BlockNo (BlockNo), ConvertRawHash,
                     HasHeader, Header, HeaderHash, Point, RealPoint,
                     SlotNo (unSlotNo), StandardHash, headerPoint, pointSlot,
                     realPointHash, realPointSlot, ChainHash(..), GetHeader(..),
                     GetPrevHash(..), getBlockHeaderFields)
import           Ouroboros.Consensus.Block.RealPoint
import           Ouroboros.Consensus.Byron.Ledger.Block (ByronBlock,
                     ByronHash (..))
import qualified Ouroboros.Consensus.Cardano as PBFT
import           Ouroboros.Consensus.HeaderValidation
import           Ouroboros.Consensus.Ledger.Extended (ExtValidationError (..))
import           Ouroboros.Consensus.Ledger.Inspect (InspectLedger,
                     LedgerEvent (..), LedgerUpdate, LedgerWarning)
import           Ouroboros.Consensus.Ledger.SupportsProtocol
                     (LedgerSupportsProtocol)
import qualified Ouroboros.Consensus.Storage.ChainDB as ChainDB
import qualified Ouroboros.Consensus.Storage.LedgerDB.OnDisk as LedgerDB
import qualified Ouroboros.Network.AnchoredFragment as AF
import           Ouroboros.Network.Block (HeaderFields(..))
import           Ouroboros.Consensus.Fragment.Diff(ChainDiff(..))
import qualified Ouroboros.Network.AnchoredSeq as AS
import           Ouroboros.Consensus.Util.Condense (Condense(..))

addedHdrsNewChain :: HasHeader (Header blk)
  => AF.AnchoredFragment (Header blk)
  -> AF.AnchoredFragment (Header blk)
  -> [Header blk]
addedHdrsNewChain fro to_ =
 case AF.intersect fro to_ of
   Just (_, _, _, s2 :: AF.AnchoredFragment (Header blk)) ->
     AF.toOldestFirst s2
   Nothing -> [] -- No sense to do validation here.

kindContext :: Text -> A.Object -> A.Object
kindContext toAdd = insertWith f "kind" (String toAdd)
  where
    f (String new) (String old) = String (new <> "." <> old)
    f (String new) _            = String new
    f _ o                       = o

--------------------
-- Documentation types

newtype TestHash = UnsafeTestHash {
      unTestHash :: NonEmpty Word64
    }
  deriving stock    (Generic)
  deriving newtype  (Eq, Ord)
  deriving anyclass (NoThunks)

pattern TestHash :: NonEmpty Word64 -> TestHash
pattern TestHash path <- UnsafeTestHash path where
  TestHash path = UnsafeTestHash (force path)

testHashFromList :: [Word64] -> TestHash
testHashFromList = TestHash . NE.fromList . reverse

instance Show TestHash where
  show (UnsafeTestHash h) = "(testHashFromList " <> show (reverse (NE.toList h)) <> ")"

instance Condense TestHash where
  condense = condense . reverse . NE.toList . unTestHash

data TestBlock = TestBlock {
      tbHash  :: TestHash
    , tbSlot  :: SlotNo
      -- ^ We store a separate 'Block.SlotNo', as slots can have gaps between
      -- them, unlike block numbers.
      --
      -- Note that when generating a 'TestBlock', you must make sure that
      -- blocks with the same 'TestHash' have the same slot number.
    , tbValid :: Bool
      -- ^ Note that when generating a 'TestBlock', you must make sure that
      -- blocks with the same 'TestHash' have the same value for 'tbValid'.
    }
  deriving stock    (Show, Eq, Ord, Generic)
  deriving anyclass (NoThunks)

newtype instance Header TestBlock = TestHeader { testHeader :: TestBlock }
  deriving stock   (Eq, Show)
  deriving newtype (NoThunks)

instance GetHeader TestBlock where
  getHeader = TestHeader
  blockMatchesHeader (TestHeader blk') blk = blk == blk'
  headerIsEBB = const Nothing

type instance HeaderHash TestBlock = TestHash

instance HasHeader TestBlock where
  getHeaderFields = getBlockHeaderFields

instance HasHeader (Header TestBlock) where
  getHeaderFields (TestHeader TestBlock{..}) = HeaderFields {
        headerFieldHash    = tbHash
      , headerFieldSlot    = tbSlot
      , headerFieldBlockNo = fromIntegral . NE.length . unTestHash $ tbHash
      }

instance GetPrevHash TestBlock where
  headerPrevHash (TestHeader b) =
      case NE.nonEmpty . NE.tail . unTestHash . tbHash $ b of
        Nothing       -> GenesisHash
        Just prevHash -> BlockHash (TestHash prevHash)

instance StandardHash TestBlock

docValidationError :: ChainDB.InvalidBlockReason TestBlock
docValidationError = ChainDB.ValidationError
  (ExtValidationErrorHeader (HeaderEnvelopeError (UnexpectedSlotNo 1 2)))

docHeaderFields :: HeaderFields TestBlock
docHeaderFields = HeaderFields 1 1 docTestHash

docAF :: AF.AnchoredFragment (HeaderFields TestBlock)
docAF = AS.Empty (AS.asAnchor docHeaderFields)

docAFH :: AF.AnchoredFragment (Header TestBlock)
docAFH =  AS.Empty (AS.asAnchor (TestHeader docTestBlock))

docHeaderDiff :: ChainDiff (HeaderFields TestBlock)
docHeaderDiff = ChainDiff 1 docAF

docTestHash :: TestHash
docTestHash = testHashFromList [1]

docTestBlock :: TestBlock
docTestBlock = TestBlock docTestHash 1 True

docNTI :: ChainDB.NewTipInfo TestBlock
docNTI = ChainDB.NewTipInfo (RealPoint 1 docTestHash) (EpochNo 1) 1 (RealPoint 1 docTestHash)

--
--     -- | The new block fits onto the current chain (first
--     -- fragment) and we have successfully used it to extend our (new) current
--     -- chain (second fragment).
--   | AddedToCurrentChain
--       [LedgerEvent blk]
--       (NewTipInfo blk)
--       (AnchoredFragment (Header blk))
--       (AnchoredFragment (Header blk))
--
--     -- | The new block fits onto some fork and we have switched to that fork
--     -- (second fragment), as it is preferable to our (previous) current chain
--     -- (first fragment).
--   | SwitchedToAFork
--       [LedgerEvent blk]
--       (NewTipInfo blk)
--       (AnchoredFragment (Header blk))
--       (AnchoredFragment (Header blk))
--
--     -- | An event traced during validating performed while adding a block.
--   | AddBlockValidation (TraceValidationEvent blk)
--
--     -- | Run chain selection for a block that was previously from the future.
--     -- This is done for all blocks from the future each time a new block is
--     -- added.
--   | ChainSelectionForFutureBlock (RealPoint blk)
--   deriving (Generic)
--



docChainDBTraceEvent :: Documented (ChainDB.TraceEvent TestBlock)
docChainDBTraceEvent = Documented [
    DocMsg
      (ChainDB.TraceAddBlockEvent
        (ChainDB.IgnoreBlockOlderThanK
          (RealPoint 1 docTestHash)))
      "IgnoreBlockOlderThanK"
      "A block with a 'BlockNo' more than @k@ back than the current tip\
      \ was ignored."
  , DocMsg
      (ChainDB.TraceAddBlockEvent
        (ChainDB.IgnoreBlockAlreadyInVolatileDB
          (RealPoint 1 docTestHash)))
      "IgnoreBlockAlreadyInVolatileDB"
      "A block that is already in the Volatile DB was ignored."
  , DocMsg
      (ChainDB.TraceAddBlockEvent
        (ChainDB.IgnoreInvalidBlock
          (RealPoint 1 docTestHash) docValidationError))
      "IgnoreBlockAlreadyInVolatileDB"
      "A block that is already in the Volatile DB was ignored."
  , DocMsg
      (ChainDB.TraceAddBlockEvent
        (ChainDB.AddedBlockToQueue
          (RealPoint 1 docTestHash) 1))
      "AddedBlockToQueue"
      "The block was added to the queue and will be added to the ChainDB by\
      \ the background thread. The size of the queue is included.."
  , DocMsg
      (ChainDB.TraceAddBlockEvent
        (ChainDB.BlockInTheFuture
          (RealPoint 1 docTestHash) 1))
      "BlockInTheFuture"
      "The block is from the future, i.e., its slot number is greater than\
      \ the current slot (the second argument)."
  , DocMsg
      (ChainDB.TraceAddBlockEvent
        (ChainDB.AddedBlockToVolatileDB
          (RealPoint 1 docTestHash) 1 ChainDB.IsEBB))
      "AddedBlockToVolatileDB"
      "A block was added to the Volatile DB"
  , DocMsg
      (ChainDB.TraceAddBlockEvent
        (ChainDB.TryAddToCurrentChain
          (RealPoint 1 docTestHash)))
      "TryAddToCurrentChain"
      "The block fits onto the current chain, we'll try to use it to extend\
      \ our chain."
  , DocMsg
      (ChainDB.TraceAddBlockEvent
        (ChainDB.TrySwitchToAFork
          (RealPoint 1 docTestHash) docHeaderDiff))
      "TrySwitchToAFork"
      "The block fits onto some fork, we'll try to switch to that fork (if\
      \ it is preferable to our chain)"
  , DocMsg
      (ChainDB.TraceAddBlockEvent
        (ChainDB.StoreButDontChange
          (RealPoint 1 docTestHash)))
      "StoreButDontChange"
      "The block fits onto some fork, we'll try to switch to that fork (if\
      \ it is preferable to our chain)."
  , DocMsg
      (ChainDB.TraceAddBlockEvent
        (ChainDB.AddedToCurrentChain [] docNTI docAFH docAFH))
      "AddedToCurrentChain"
      "The new block fits onto the current chain (first\
      \fragment) and we have successfully used it to extend our (new) current\
      \chain (second fragment)."
  ]

instance (  LogFormatting (Header blk)
          , LogFormatting (LedgerEvent blk)
          , LogFormatting (RealPoint blk)
          , ConvertRawHash blk
          , ConvertRawHash (Header blk)
          , HasHeader (Header blk)
          , LedgerSupportsProtocol blk
          , InspectLedger blk
          ) => LogFormatting (ChainDB.TraceEvent blk) where
  forHuman (ChainDB.TraceAddBlockEvent v) = forHuman v
  -- -- forHuman (TraceReaderEvent v) = forHuman v
  -- forHuman (TraceCopyToImmutableDBEvent v) = forHuman v
  -- forHuman (TraceGCEvent v) = forHuman v
  -- forHuman (TraceInitChainSelEvent v) = forHuman v
  -- forHuman (TraceOpenEvent v) = forHuman v
  -- forHuman (TraceIteratorEvent v) = forHuman v
  -- forHuman (TraceLedgerEvent v) = forHuman v
  -- forHuman (TraceLedgerReplayEvent v) = forHuman v
  -- forHuman (TraceImmutableDBEvent v) = forHuman v
  -- forHuman (TraceVolatileDBEvent v) = forHuman v
  forHuman _                              = ""

  forMachine details (ChainDB.TraceAddBlockEvent v) =
     kindContext "AddBlockEvent" $ forMachine details v
  -- -- forMachine details (TraceReaderEvent v) = forMachine details v
  -- forMachine details (TraceCopyToImmutableDBEvent v) = forMachine details v
  -- forMachine details (TraceGCEvent v) = forMachine details v
  -- forMachine details (TraceInitChainSelEvent v) = forMachine details v
  -- forMachine details (TraceOpenEvent v) = forMachine details v
  -- forMachine details (TraceIteratorEvent v) = forMachine details v
  -- forMachine details (TraceLedgerEvent v) = forMachine details v
  -- forMachine details (TraceLedgerReplayEvent v) = forMachine details v
  -- forMachine details (TraceImmutableDBEvent v) = forMachine details v
  -- forMachine details (TraceVolatileDBEvent v) = forMachine details v
  forMachine _details _ = mempty

  asMetrics (ChainDB.TraceAddBlockEvent v) = asMetrics v
  -- -- asMetrics (TraceReaderEvent v) = asMetrics v
  -- asMetrics (TraceCopyToImmutableDBEvent v) = asMetrics v
  -- asMetrics (TraceGCEvent v) = asMetrics v
  -- asMetrics (TraceInitChainSelEvent v) = asMetrics v
  -- asMetrics (TraceOpenEvent v) = asMetrics v
  -- asMetrics (TraceIteratorEvent v) = asMetrics v
  -- asMetrics (TraceLedgerEvent v) = asMetrics v
  -- asMetrics (TraceLedgerReplayEvent v) = asMetrics v
  -- asMetrics (TraceImmutableDBEvent v) = asMetrics v
  -- asMetrics (TraceVolatileDBEvent v) = asMetrics v
  asMetrics _                              = []


instance ( LogFormatting (Header blk)
         , LogFormatting (LedgerEvent blk)
         , LogFormatting (RealPoint blk)
         , ConvertRawHash blk
         , ConvertRawHash (Header blk)
         , HasHeader (Header blk)
         , LedgerSupportsProtocol blk
         , InspectLedger blk
         ) => LogFormatting (ChainDB.TraceAddBlockEvent blk) where
  forHuman (ChainDB.IgnoreBlockOlderThanK pt) =
    "Ignoring block older than K: " <> renderRealPointAsPhrase pt
  forHuman (ChainDB.IgnoreBlockAlreadyInVolatileDB pt) =
      "Ignoring block already in DB: " <> renderRealPointAsPhrase pt
  forHuman (ChainDB.IgnoreInvalidBlock pt _reason) =
      "Ignoring previously seen invalid block: " <> renderRealPointAsPhrase pt
  forHuman (ChainDB.AddedBlockToQueue pt sz) =
      "Block added to queue: " <> renderRealPointAsPhrase pt <> " queue size " <> condenseT sz
  forHuman (ChainDB.BlockInTheFuture pt slot) =
      "Ignoring block from future: " <> renderRealPointAsPhrase pt <> ", slot " <> condenseT slot
  forHuman (ChainDB.StoreButDontChange pt) =
      "Ignoring block: " <> renderRealPointAsPhrase pt
  forHuman (ChainDB.TryAddToCurrentChain pt) =
      "Block fits onto the current chain: " <> renderRealPointAsPhrase pt
  forHuman (ChainDB.TrySwitchToAFork pt _) =
      "Block fits onto some fork: " <> renderRealPointAsPhrase pt
  forHuman (ChainDB.AddedToCurrentChain es _ _ c) =
      "Chain extended, new tip: " <> renderPointAsPhrase (AF.headPoint c) <>
        Text.concat [ "\nEvent: " <> showT e | e <- es ]
  forHuman (ChainDB.SwitchedToAFork es _ _ c) =
      "Switched to a fork, new tip: " <> renderPointAsPhrase (AF.headPoint c) <>
        Text.concat [ "\nEvent: " <> showT e | e <- es ]
  forHuman (ChainDB.AddBlockValidation ev') = forHuman ev'
  forHuman (ChainDB.AddedBlockToVolatileDB pt _ _) =
      "Chain added block " <> renderRealPointAsPhrase pt
  forHuman (ChainDB.ChainSelectionForFutureBlock pt) =
      "Chain selection run for block previously from future: " <> renderRealPointAsPhrase pt

  forMachine dtal (ChainDB.IgnoreBlockOlderThanK pt) =
      mkObject [ "kind" .= String "IgnoreBlockOlderThanK"
               , "block" .= forMachine dtal pt ]
  forMachine dtal (ChainDB.IgnoreBlockAlreadyInVolatileDB pt) =
      mkObject [ "kind" .= String "IgnoreBlockAlreadyInVolatileDB"
               , "block" .= forMachine dtal pt ]
  forMachine dtal (ChainDB.IgnoreInvalidBlock pt reason) =
      mkObject [ "kind" .= String "IgnoreInvalidBlock"
               , "block" .= forMachine dtal pt
               , "reason" .= showT reason ]
  forMachine dtal (ChainDB.AddedBlockToQueue pt sz) =
      mkObject [ "kind" .= String "AddedBlockToQueue"
               , "block" .= forMachine dtal pt
               , "queueSize" .= toJSON sz ]
  forMachine dtal (ChainDB.BlockInTheFuture pt slot) =
      mkObject [ "kind" .= String "BlockInTheFuture"
               , "block" .= forMachine dtal pt
               , "slot" .= forMachine dtal slot ]
  forMachine dtal (ChainDB.StoreButDontChange pt) =
      mkObject [ "kind" .= String "StoreButDontChange"
               , "block" .= forMachine dtal pt ]
  forMachine dtal (ChainDB.TryAddToCurrentChain pt) =
      mkObject [ "kind" .= String "TryAddToCurrentChain"
               , "block" .= forMachine dtal pt ]
  forMachine dtal (ChainDB.TrySwitchToAFork pt _) =
      mkObject [ "kind" .= String "TraceAddBlockEvent.TrySwitchToAFork"
               , "block" .= forMachine dtal pt ]
  forMachine dtal (ChainDB.AddedToCurrentChain events _ base extended) =
      mkObject $
               [ "kind" .=  String "AddedToCurrentChain"
               , "newtip" .= renderPointForDetails dtal (AF.headPoint extended)
               ]
            ++ [ "headers" .= toJSON (forMachine dtal `map` addedHdrsNewChain base extended)
               | dtal == DDetailed ]
            ++ [ "events" .= toJSON (map (forMachine dtal) events)
               | not (null events) ]
  forMachine dtal (ChainDB.SwitchedToAFork events _ old new) =
      mkObject $
               [ "kind" .= String "TraceAddBlockEvent.SwitchedToAFork"
               , "newtip" .= renderPointForDetails dtal (AF.headPoint new)
               ]
            ++ [ "headers" .= toJSON (forMachine dtal `map` addedHdrsNewChain old new)
               | dtal == DDetailed ]
            ++ [ "events" .= toJSON (map (forMachine dtal) events)
               | not (null events) ]
  forMachine dtal (ChainDB.AddBlockValidation ev') =
    kindContext "AddBlockEvent" $ forMachine dtal ev'
  forMachine dtal (ChainDB.AddedBlockToVolatileDB pt (BlockNo bn) _) =
      mkObject [ "kind" .= String "AddedBlockToVolatileDB"
               , "block" .= forMachine dtal pt
               , "blockNo" .= showT bn ]
  forMachine dtal (ChainDB.ChainSelectionForFutureBlock pt) =
      mkObject [ "kind" .= String "TChainSelectionForFutureBlock"
               , "block" .= forMachine dtal pt ]


  -- data TraceEvent blk
  --   = TraceAddBlockEvent          (TraceAddBlockEvent           blk)
  --   | TraceReaderEvent            (TraceReaderEvent             blk)
  --   | TraceCopyToImmutableDBEvent (TraceCopyToImmutableDBEvent  blk)
  --   | TraceGCEvent                (TraceGCEvent                 blk)
  --   | TraceInitChainSelEvent      (TraceInitChainSelEvent       blk)
  --   | TraceOpenEvent              (TraceOpenEvent               blk)
  --   | TraceIteratorEvent          (TraceIteratorEvent           blk)
  --   | TraceLedgerEvent            (LgrDB.TraceEvent             blk)
  --   | TraceLedgerReplayEvent      (LgrDB.TraceLedgerReplayEvent blk)
  --   | TraceImmutableDBEvent       (ImmutableDB.TraceEvent       blk)
  --   | TraceVolatileDBEvent        (VolatileDB.TraceEvent        blk)
  --   deriving (Generic)







  --
  --   -- | The block is from the future, i.e., its slot number is greater than
  --   -- the current slot (the second argument).
  -- | BlockInTheFuture (RealPoint blk) SlotNo
  --
  --   -- | A block was added to the Volatile DB
  -- | AddedBlockToVolatileDB (RealPoint blk) BlockNo IsEBB
  --
  --   -- | The block fits onto the current chain, we'll try to use it to extend
  --   -- our chain.
  -- | TryAddToCurrentChain (RealPoint blk)
  --
  --   -- | The block fits onto some fork, we'll try to switch to that fork (if
  --   -- it is preferable to our chain).
  -- | TrySwitchToAFork (RealPoint blk) (ChainDiff (HeaderFields blk))
  --
  --   -- | The block doesn't fit onto any other block, so we store it and ignore
  --   -- it.
  -- | StoreButDontChange (RealPoint blk)
  --
  --   -- | The new block fits onto the current chain (first
  --   -- fragment) and we have successfully used it to extend our (new) current
  --   -- chain (second fragment).
  -- | AddedToCurrentChain
  --     [LedgerEvent blk]
  --     (NewTipInfo blk)
  --     (AnchoredFragment (Header blk))
  --     (AnchoredFragment (Header blk))
  --
  --   -- | The new block fits onto some fork and we have switched to that fork
  --   -- (second fragment), as it is preferable to our (previous) current chain
  --   -- (first fragment).
  -- | SwitchedToAFork
  --     [LedgerEvent blk]
  --     (NewTipInfo blk)
  --     (AnchoredFragment (Header blk))
  --     (AnchoredFragment (Header blk))
  --
  --   -- | An event traced during validating performed while adding a block.
  -- | AddBlockValidation (TraceValidationEvent blk)
  --
  --   -- | Run chain selection for a block that was previously from the future.
  --   -- This is done for all blocks from the future each time a new block is
  --   -- added.
  -- | ChainSelectionForFutureBlock (RealPoint blk)

instance ( HasHeader (Header blk)
         , LedgerSupportsProtocol blk
         , ConvertRawHash (Header blk)
         , ConvertRawHash blk
         , LogFormatting (RealPoint blk))
         => LogFormatting (ChainDB.TraceValidationEvent blk) where
  forMachine dtal  (ChainDB.InvalidBlock err pt) =
          mkObject [ "kind" .= String "InvalidBlock"
                   , "block" .= forMachine dtal pt
                   , "error" .= showT err ]
  forMachine dtal  (ChainDB.InvalidCandidate c) =
          mkObject [ "kind" .= String "InvalidCandidate"
                   , "block" .= renderPointForDetails dtal (AF.headPoint c) ]
  forMachine dtal  (ChainDB.ValidCandidate c) =
          mkObject [ "kind" .= String "ValidCandidate"
                   , "block" .= renderPointForDetails dtal (AF.headPoint c) ]
  forMachine dtal  (ChainDB.CandidateContainsFutureBlocks c hdrs) =
          mkObject [ "kind" .= String "CandidateContainsFutureBlocks"
                   , "block"   .= renderPointForDetails dtal (AF.headPoint c)
                   , "headers" .= map (renderPointForDetails dtal . headerPoint) hdrs ]
  forMachine dtal  (ChainDB.CandidateContainsFutureBlocksExceedingClockSkew c hdrs) =
          mkObject [ "kind" .= String "CandidateContainsFutureBlocksExceedingClockSkew"
                   , "block"   .= renderPointForDetails dtal (AF.headPoint c)
                   , "headers" .= map (renderPointForDetails dtal . headerPoint) hdrs ]

  forHuman (ChainDB.InvalidBlock err pt) =
      "Invalid block " <> renderRealPointAsPhrase pt <> ": " <> showT err
  forHuman (ChainDB.InvalidCandidate c) =
      "Invalid candidate " <> renderPointAsPhrase (AF.headPoint c)
  forHuman (ChainDB.ValidCandidate c) =
      "Valid candidate " <> renderPointAsPhrase (AF.headPoint c)
  forHuman (ChainDB.CandidateContainsFutureBlocks c hdrs) =
      "Candidate contains blocks from near future:  " <>
        renderPointAsPhrase (AF.headPoint c) <> ", slots " <>
        Text.intercalate ", " (map (renderPoint . headerPoint) hdrs)
  forHuman (ChainDB.CandidateContainsFutureBlocksExceedingClockSkew c hdrs) =
      "Candidate contains blocks from future exceeding clock skew limit: " <>
        renderPointAsPhrase (AF.headPoint c) <> ", slots " <>
        Text.intercalate ", " (map (renderPoint . headerPoint) hdrs)

instance ConvertRawHash blk
          => LogFormatting (LedgerDB.TraceReplayEvent blk (Point blk)) where
  forHuman (LedgerDB.ReplayFromGenesis _replayTo) =
      "Replaying ledger from genesis"
  forHuman (LedgerDB.ReplayFromSnapshot snap tip' _replayTo) =
      "Replaying ledger from snapshot " <> showT snap <> " at " <>
        renderRealPointAsPhrase tip'
  forHuman (LedgerDB.ReplayedBlock pt _ledgerEvents replayTo) =
      "Replayed block: slot " <> showT (realPointSlot pt) <> " of " <> showT (pointSlot replayTo)

instance ( StandardHash blk
         , ConvertRawHash blk)
         => LogFormatting (LedgerDB.TraceEvent blk) where
  forHuman (LedgerDB.TookSnapshot snap pt) =
      "Took ledger snapshot " <> showT snap <>
        " at " <> renderRealPointAsPhrase pt
  forHuman (LedgerDB.DeletedSnapshot snap) =
      "Deleted old snapshot " <> showT snap
  forHuman (LedgerDB.InvalidSnapshot snap failure) =
      "Invalid snapshot " <> showT snap <> showT failure

instance ConvertRawHash blk
          => LogFormatting (ChainDB.TraceCopyToImmutableDBEvent blk) where
  forHuman (ChainDB.CopiedBlockToImmutableDB pt) =
      "Copied block " <> renderPointAsPhrase pt <> " to the ImmutableDB"
  forHuman  ChainDB.NoBlocksToCopyToImmutableDB  =
      "There are no blocks to copy to the ImmutableDB"

instance LogFormatting (ChainDB.TraceGCEvent blk) where
  forHuman (ChainDB.PerformedGC slot) =
      "Performed a garbage collection for " <> condenseT slot
  forHuman (ChainDB.ScheduledGC slot _difft) =
      "Scheduled a garbage collection for " <> condenseT slot

instance ConvertRawHash blk
          => LogFormatting (ChainDB.TraceOpenEvent blk) where
  forHuman (ChainDB.OpenedDB immTip tip') =
          "Opened db with immutable tip at " <> renderPointAsPhrase immTip <>
          " and tip " <> renderPointAsPhrase tip'
  forHuman (ChainDB.ClosedDB immTip tip') =
          "Closed db with immutable tip at " <> renderPointAsPhrase immTip <>
          " and tip " <> renderPointAsPhrase tip'
  forHuman (ChainDB.OpenedImmutableDB immTip chunk) =
          "Opened imm db with immutable tip at " <> renderPointAsPhrase immTip <>
          " and chunk " <> showT chunk
  forHuman ChainDB.OpenedVolatileDB = "Opened vol db"
  forHuman ChainDB.OpenedLgrDB = "Opened lgr db"


      --   ChainDB.NewFollower ->  "New follower was created"
      --   ChainDB.FollowerNoLongerInMem _ ->  "FollowerNoLongerInMem"
      --   ChainDB.FollowerSwitchToMem _ _ ->  "FollowerSwitchToMem"
      --   ChainDB.FollowerNewImmIterator _ _ ->  "FollowerNewImmIterator"

      --   ChainDB.InitChainSelValidation _ ->  "InitChainSelValidation"

instance  ( StandardHash blk
          , ConvertRawHash blk
          ) => LogFormatting (ChainDB.TraceIteratorEvent blk) where
  forHuman (ChainDB.UnknownRangeRequested ev') = forHuman ev'
  forHuman (ChainDB.BlockMissingFromVolatileDB realPt) =
      "This block is no longer in the VolatileDB because it has been garbage\
         \ collected. It might now be in the ImmutableDB if it was part of the\
         \ current chain. Block: " <> renderRealPoint realPt
  forHuman (ChainDB.StreamFromImmutableDB sFrom sTo) =
      "Stream only from the ImmutableDB. StreamFrom:" <> showT sFrom <>
        " StreamTo: " <> showT sTo
  forHuman (ChainDB.StreamFromBoth sFrom sTo pts) =
      "Stream from both the VolatileDB and the ImmutableDB."
        <> " StreamFrom: " <> showT sFrom <> " StreamTo: " <> showT sTo
        <> " Points: " <> showT (map renderRealPoint pts)
  forHuman (ChainDB.StreamFromVolatileDB sFrom sTo pts) =
      "Stream only from the VolatileDB."
        <> " StreamFrom: " <> showT sFrom <> " StreamTo: " <> showT sTo
        <> " Points: " <> showT (map renderRealPoint pts)
  forHuman (ChainDB.BlockWasCopiedToImmutableDB pt) =
      "This block has been garbage collected from the VolatileDB is now\
        \ found and streamed from the ImmutableDB. Block: " <> renderRealPoint pt
  forHuman (ChainDB.BlockGCedFromVolatileDB pt) =
      "This block no longer in the VolatileDB and isn't in the ImmutableDB\
        \ either; it wasn't part of the current chain. Block: " <> renderRealPoint pt
  forHuman ChainDB.SwitchBackToVolatileDB = "SwitchBackToVolatileDB"

instance  ( StandardHash blk
          , ConvertRawHash blk
          ) => LogFormatting (ChainDB.UnknownRange blk) where
  forHuman (ChainDB.MissingBlock realPt) =
      "The block at the given point was not found in the ChainDB."
        <> renderRealPoint realPt
  forHuman (ChainDB.ForkTooOld streamFrom) =
      "The requested range forks off too far in the past"
        <> showT streamFrom

instance (Show (PBFT.PBftVerKeyHash c))
      => LogFormatting (PBFT.PBftValidationErr c) where
  forMachine _dtal (PBFT.PBftInvalidSignature text) =
    mkObject
      [ "kind" .= String "PBftInvalidSignature"
      , "error" .= String text
      ]
  forMachine _dtal (PBFT.PBftNotGenesisDelegate vkhash _ledgerView) =
    mkObject
      [ "kind" .= String "PBftNotGenesisDelegate"
      , "vk" .= String (Text.pack $ show vkhash)
      ]
  forMachine _dtal (PBFT.PBftExceededSignThreshold vkhash numForged) =
    mkObject
      [ "kind" .= String "PBftExceededSignThreshold"
      , "vk" .= String (Text.pack $ show vkhash)
      , "numForged" .= String (Text.pack (show numForged))
      ]
  forMachine _dtal PBFT.PBftInvalidSlot =
    mkObject
      [ "kind" .= String "PBftInvalidSlot"
      ]

instance (Show (PBFT.PBftVerKeyHash c))
      => LogFormatting (PBFT.PBftCannotForge c) where
  forMachine _dtal (PBFT.PBftCannotForgeInvalidDelegation vkhash) =
    mkObject
      [ "kind" .= String "PBftCannotForgeInvalidDelegation"
      , "vk" .= String (Text.pack $ show vkhash)
      ]
  forMachine _dtal (PBFT.PBftCannotForgeThresholdExceeded numForged) =
    mkObject
      [ "kind" .= String "PBftCannotForgeThresholdExceeded"
      , "numForged" .= numForged
      ]