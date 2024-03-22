import
  std/os,
  chronos,
  ../spec/forks,
  ".."/conf,
  "."/[
    slashing_protection]

import ../spec/[datatypes/base, crypto]
type
  ValidatorKind {.pure.} = enum
    Local, Remote
  AttachedValidator = ref object
    case kind*: ValidatorKind
    of ValidatorKind.Local:
      discard
    of ValidatorKind.Remote:
      discard
    index: Opt[ValidatorIndex]
    validator: Opt[Validator]
  SignatureResult = Result[ValidatorSig, string]
func shortLog*(v: AttachedValidator): string =
  case v.kind
  of ValidatorKind.Local:
    ""
  of ValidatorKind.Remote:
    ""
proc getBlockSignature(): Future[SignatureResult]
                       {.async: (raises: [CancelledError]).} =
  SignatureResult.ok(default(ValidatorSig))

type
  # https://github.com/ethereum/consensus-specs/blob/v1.4.0/specs/deneb/validator.md#blobsbundle
  KzgProofs = List[int, Limit MAX_BLOB_COMMITMENTS_PER_BLOCK]
  Blobs = List[int, Limit MAX_BLOB_COMMITMENTS_PER_BLOCK]
  BlobRoots = List[Eth2Digest, Limit MAX_BLOB_COMMITMENTS_PER_BLOCK]

  BlobsBundle = object
    proofs*: KzgProofs
    blobs*: Blobs

  EngineBid = tuple[
    blockValue: Wei,
    blobsBundleOpt: Opt[BlobsBundle]]

  BuilderBid[SBBB] = tuple[
    blindedBlckPart: SBBB, blockValue: UInt256]

  ForkedBlockResult =
    Result[EngineBid, string]
  BlindedBlockResult[SBBB] =
    Result[BuilderBid[SBBB], string]

  Bids[SBBB] = object
    engineBid: Opt[EngineBid]
    builderBid: Opt[BuilderBid[SBBB]]

import ".."/consensus_object_pools/block_dag
let pk = ValidatorPubKey.fromHex("891c64850444b66331ef7888c907b4af71ab6b2c883affe2cebd15d6c3644ac7ce6af96334192efdf95a64bab8ea425a")[]
proc getValidatorForDuties(
    idx: ValidatorIndex, slot: Slot,
    slashingSafe = false): Opt[AttachedValidator] =
  ok AttachedValidator(
    kind: ValidatorKind.Local,
    index: Opt.some 0.ValidatorIndex,
    validator: Opt.some Validator(pubkey: ValidatorPubKey.fromHex("891c64850444b66331ef7888c907b4af71ab6b2c883affe2cebd15d6c3644ac7ce6af96334192efdf95a64bab8ea425a")[]))

from ".."/spec/datatypes/capella import shortLog
from ".."/spec/datatypes/phase0 import BeaconBlock, shortLog
proc makeBeaconBlock(): Result[phase0.BeaconBlock, cstring] = ok(default(phase0.BeaconBlock))

proc getProposalState(
    head: BlockRef, slot: Slot, cache: var StateCache):
    Result[ref ForkedHashedBeaconState, cstring] =
  let state = assignClone(default(ForkedHashedBeaconState))
  ok state

proc makeBeaconBlockForHeadAndSlot(
    PayloadType: type ForkyExecutionPayloadForSigning,
    validator_index: ValidatorIndex, graffiti: GraffitiBytes, head: BlockRef,
    slot: Slot,
    execution_payload: Opt[PayloadType]):
    Future[ForkedBlockResult] {.async: (raises: [CancelledError]).} =
  var cache = StateCache()

  let maybeState = getProposalState(head, slot, cache)
  let consensusFork = ConsensusFork.Bellatrix
  if maybeState.isErr:
    return err($maybeState.error)

  let
    payloadFut =
      if execution_payload.isSome:
        withConsensusFork(consensusFork):
          discard
        let fut = Future[Opt[PayloadType]].Raising([CancelledError]).init(
          "given-payload")
        fut.complete(Opt.some(default(PayloadType)))
        fut
      elif slot.epoch < 0:
        let fut = Future[Opt[PayloadType]].Raising([CancelledError]).init(
          "empty-payload")
        fut.complete(Opt.some(default(PayloadType)))
        fut
      else:
        let fut = Future[Opt[PayloadType]].Raising([CancelledError]).init(
          "empty-payload")
        fut.complete(Opt.some(default(PayloadType)))
        fut

  if false:
    return err("Eth1 deposits not available")

  let
    payloadRes = await payloadFut
    payload = payloadRes.valueOr:
      return err("Unable to get execution payload")

  let blck = makeBeaconBlock().mapErr do (error: cstring) -> string:
    $error

  var blobsBundleOpt = Opt.none(BlobsBundle)
  return if blck.isOk:
    ok((payload.blockValue, blobsBundleOpt))
  else:
    err(blck.error)

proc makeBeaconBlockForHeadAndSlot(
    PayloadType: type ForkyExecutionPayloadForSigning,
    validator_index: ValidatorIndex, graffiti: GraffitiBytes, head: BlockRef,
    slot: Slot):
    Future[ForkedBlockResult] =
  return makeBeaconBlockForHeadAndSlot(
    PayloadType, validator_index, graffiti, head, slot,
    execution_payload = Opt.none(PayloadType))

proc blindedBlockCheckSlashingAndSign[
    T: int](
    slot: Slot, validator: AttachedValidator,
    validator_index: ValidatorIndex, nonsignedBlindedBlock: T):
    Future[Result[T, string]] {.async: (raises: [CancelledError]).} =
  return err "foo"

proc getUnsignedBlindedBeaconBlock[
    T: int](
    slot: Slot,
    validator_index: ValidatorIndex, forkedBlock: ForkedBeaconBlock,
    executionPayloadHeader: capella.ExecutionPayloadHeader):
    Result[T, string] =
  var fork = ConsensusFork.Altair
  withConsensusFork(fork):
    return err("")

proc getBlindedBlockParts[
    EPH: capella.ExecutionPayloadHeader](
    head: BlockRef,
    pubkey: ValidatorPubKey, slot: Slot,
    validator_index: ValidatorIndex, graffiti: GraffitiBytes):
    Future[Result[(EPH, UInt256, ForkedBeaconBlock), string]]
    {.async: (raises: [CancelledError]).} =
  return err("")

proc getBuilderBid[
    SBBB: int](
    head: BlockRef,
    validator_pubkey: ValidatorPubKey, slot: Slot,
    validator_index: ValidatorIndex):
    Future[BlindedBlockResult[SBBB]] {.async: (raises: [CancelledError]).} =
  when SBBB is int:
    type EPH = capella.ExecutionPayloadHeader
  else:
    static: doAssert false

  let blindedBlockParts = await getBlindedBlockParts[EPH](
    node, head, validator_pubkey, slot,
    validator_index, default(GraffitiBytes))
  if blindedBlockParts.isErr:
    return err blindedBlockParts.error()

  let (executionPayloadHeader, bidValue, forkedBlck) = blindedBlockParts.get

  let unsignedBlindedBlock = getUnsignedBlindedBeaconBlock[SBBB](
    slot, validator_index, forkedBlck, executionPayloadHeader)

  if unsignedBlindedBlock.isErr:
    return err unsignedBlindedBlock.error()

  return ok (unsignedBlindedBlock.get, bidValue)

proc proposeBlockMEV(
    blindedBlock: int |
                  int):
    Future[Result[BlockRef, string]] {.async: (raises: [CancelledError]).} =
  err "foo"

proc collectBids(
    SBBB: typedesc, EPS: typedesc,
    validator_pubkey: ValidatorPubKey,
    validator_index: ValidatorIndex, graffitiBytes: GraffitiBytes,
    head: BlockRef, slot: Slot): Future[Bids[SBBB]] {.async: (raises: [CancelledError]).} =
  let usePayloadBuilder = false

  let
    payloadBuilderBidFut =
      if usePayloadBuilder:
        when false:
          getBuilderBid[SBBB](node, head,
                              validator_pubkey, slot, validator_index)
        else:
          let fut = newFuture[BlindedBlockResult[SBBB]]("builder-bid")
          fut.complete(BlindedBlockResult[SBBB].err(
            "Bellatrix Builder API unsupported"))
          fut
      else:
        let fut = newFuture[BlindedBlockResult[SBBB]]("builder-bid")
        fut.complete(BlindedBlockResult[SBBB].err(
          "either payload builder disabled or liveness failsafe active"))
        fut
    engineBlockFut = makeBeaconBlockForHeadAndSlot(
      EPS, validator_index, graffitiBytes, head, slot)

  await allFutures(payloadBuilderBidFut, engineBlockFut)
  doAssert payloadBuilderBidFut.finished and engineBlockFut.finished

  let builderBid =
    if payloadBuilderBidFut.completed:
      if payloadBuilderBidFut.value().isOk:
        Opt.some(payloadBuilderBidFut.value().value())
      elif usePayloadBuilder:
        echo "Payload builder error"
        Opt.none(BuilderBid[SBBB])
      else:
        # Effectively the same case, but without the log message
        Opt.none(BuilderBid[SBBB])
    else:
      echo "Payload builder bid request failed"
      Opt.none(BuilderBid[SBBB])

  let engineBid =
    if engineBlockFut.completed:
      if engineBlockFut.value.isOk:
        Opt.some(engineBlockFut.value().value())
      else:
        echo "Engine block building error"
        Opt.none(EngineBid)
    else:
      echo "Engine block building failed"
      Opt.none(EngineBid)

  Bids[SBBB](
    engineBid: engineBid,
    builderBid: builderBid)

func builderBetterBid(
    localBlockValueBoost: uint8, builderValue: UInt256, engineValue: Wei): bool =
  const scalingBits = 10
  static: doAssert 1 shl scalingBits >
    high(typeof(localBlockValueBoost)).uint16 + 100
  let
    scaledBuilderValue = (builderValue shr scalingBits) * 100
    scaledEngineValue = engineValue shr scalingBits
  scaledBuilderValue >
    scaledEngineValue * (localBlockValueBoost.uint16 + 100).u256

from ".."/spec/datatypes/bellatrix import shortLog
import chronicles
import "."/message_router
type BlobSidecar = int
proc proposeBlockAux(
    SBBB: typedesc, EPS: typedesc,
    validator: AttachedValidator, validator_pubkey: ValidatorPubKey, validator_index: ValidatorIndex,
    head: BlockRef, slot: Slot, fork: Fork): Future[BlockRef] {.async: (raises: [CancelledError]).} =
  let
    collectedBids = await collectBids(
      SBBB, EPS, validator_pubkey, validator_index,
      default(GraffitiBytes), head, slot)

    useBuilderBlock =
      if collectedBids.builderBid.isSome():
        collectedBids.engineBid.isNone() or builderBetterBid(
          0,
          collectedBids.builderBid.value().blockValue,
          collectedBids.engineBid.value().blockValue)
      else:
        if not collectedBids.engineBid.isSome():
          return head   # errors logged in router
        false

  if useBuilderBlock:
    let
      blindedBlock = (await blindedBlockCheckSlashingAndSign(
        slot, validator, validator_index,
        collectedBids.builderBid.value().blindedBlckPart)).valueOr:
          return head
      maybeUnblindedBlock = await proposeBlockMEV(
        blindedBlock)

    return maybeUnblindedBlock.valueOr:
      warn "Blinded block proposal incomplete",
       foo = maybeUnblindedBlock.error
      return head

  let engineBid_blck = default(ForkedBeaconBlock)
  let engineBid = collectedBids.engineBid.value()

  withBlck(engineBid_blck):
    let
      blockRoot = default(Eth2Digest)
      signingRoot = default(Eth2Digest)

      notSlashable = registerBlock(validator_index, validator_pubkey, slot, signingRoot)

    if notSlashable.isErr:
      warn "Slashing protection activated for block proposal",
        blockRoot = shortLog(blockRoot),
        blck = shortLog(default(phase0.BeaconBlock)),
        signingRoot = shortLog(signingRoot),
        existingProposal = notSlashable.error
      return head

    let
      signature =
        block:
          let res = await getBlockSignature()
          if res.isErr():
            return head
          res.get()
      signedBlock = consensusFork.SignedBeaconBlock(
        signature: signature, root: blockRoot)
      blobsOpt =
        when consensusFork >= ConsensusFork.Deneb:
          Opt.some(default(seq[BlobSidecar]))
        else:
          Opt.none(seq[BlobSidecar])

    # - macOS 14.2.1 (23C71)
    # - Xcode 15.1 (15C65)
    let
      newBlockRef = (
        await routeSignedBeaconBlock(signedBlock, blobsOpt)
      ).valueOr:
        return head # Errors logged in router

    if newBlockRef.isNone():
      return head # Validation errors logged in router

    echo "foo 1"
    notice "Block proposed",
      blockRoot = shortLog(blockRoot)

    echo "foo 2"

    return newBlockRef.get()

proc proposeBlock*(head: BlockRef,
                   slot: Slot) {.async: (raises: [CancelledError]).} =
  let
    validator_pubkey = pk
    validator_index = 0.ValidatorIndex
    validator = getValidatorForDuties(validator_index, slot).valueOr:
      return

  let
    fork = default(Fork)
    genesis_validators_root = default(Eth2Digest)
    cf = ConsensusFork.Bellatrix

  discard withConsensusFork(cf):
    when consensusFork >= ConsensusFork.Capella:
      default(BlockRef)
    else:
      await proposeBlockAux(
        int, bellatrix.ExecutionPayloadForSigning, validator, validator_pubkey, validator_index, head, slot, fork)
