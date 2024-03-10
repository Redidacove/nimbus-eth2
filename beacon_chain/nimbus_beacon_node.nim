{.push raises: [].}

import
  std/[os, times],
  chronos,
  stew/[byteutils, io2],
  eth/p2p/discoveryv5/[enr, random2],
  ./networking/[network_metadata_downloads],
  ./spec/datatypes/[altair, bellatrix, phase0],
  ./spec/deposit_snapshots,
  ./validators/[keystore_management, beacon_validators],
  "."/[
    beacon_node,
    nimbus_binary_common]

from ./spec/datatypes/deneb import SignedBeaconBlock

from
  libp2p/protocols/pubsub/gossipsub
import
  validateParameters, init

proc loadChainDag(
    config: BeaconNodeConf,
    cfg: RuntimeConfig,
    db: BeaconChainDB,
    networkGenesisValidatorsRoot: Opt[Eth2Digest]): ChainDAGRef =
  var dag: ChainDAGRef

  let
    chainDagFlags =
      if config.strictVerification: {strictVerification}
      else: {}
  dag = ChainDAGRef.init(
    cfg, db, chainDagFlags, config.eraDir)

  if networkGenesisValidatorsRoot.isSome:
    let databaseGenesisValidatorsRoot =
      getStateField(dag.headState, genesis_validators_root)
    if networkGenesisValidatorsRoot.get != databaseGenesisValidatorsRoot:
      fatal "The specified --data-dir contains data for a different network",
            networkGenesisValidatorsRoot = networkGenesisValidatorsRoot.get,
            databaseGenesisValidatorsRoot,
            dataDir = config.dataDir
      quit 1

  dag

proc initFullNode(
    node: BeaconNode,
    rng: ref HmacDrbgContext,
    dag: ChainDAGRef,
    getBeaconTime: GetBeaconTimeFn) {.async.} =
  template config(): auto = node.config

  node.dag = dag
  node.router = new MessageRouter

  await node.addValidators()

proc init*(T: type BeaconNode,
           rng: ref HmacDrbgContext,
           config: BeaconNodeConf,
           metadata: Eth2NetworkMetadata): Future[BeaconNode]
          {.async.} =
  template cfg: auto = metadata.cfg
  template eth1Network: auto = metadata.eth1Network

  if metadata.genesis.kind == BakedIn:
    if config.genesisState.isSome:
      warn "The --genesis-state option has no effect on networks with built-in genesis state"

    if config.genesisStateUrl.isSome:
      warn "The --genesis-state-url option has no effect on networks with built-in genesis state"

  let
    db = BeaconChainDB.new(config.databaseDir, cfg, inMemory = false)

  let checkpointState = if config.finalizedCheckpointState.isSome:
    let checkpointStatePath = config.finalizedCheckpointState.get.string
    let tmp = try:
      newClone(readSszForkedHashedBeaconState(
        cfg, readAllBytes(checkpointStatePath).tryGet()))
    except SszError as err:
      fatal "Checkpoint state loading failed",
            err = formatMsg(err, checkpointStatePath)
      quit 1
    except CatchableError as err:
      fatal "Failed to read checkpoint state file", err = err.msg
      quit 1

    if not getStateField(tmp[], slot).is_epoch:
      fatal "--finalized-checkpoint-state must point to a state for an epoch slot",
        slot = getStateField(tmp[], slot)
      quit 1
    tmp
  else:
    nil

  if config.finalizedDepositTreeSnapshot.isSome:
    let
      depositTreeSnapshotPath = config.finalizedDepositTreeSnapshot.get.string
      depositTreeSnapshot = try:
        SSZ.loadFile(depositTreeSnapshotPath, DepositTreeSnapshot)
      except SszError as err:
        fatal "Deposit tree snapshot loading failed",
              err = formatMsg(err, depositTreeSnapshotPath)
        quit 1
      except CatchableError as err:
        fatal "Failed to read deposit tree snapshot file", err = err.msg
        quit 1
    db.putDepositTreeSnapshot(depositTreeSnapshot)

  var networkGenesisValidatorsRoot = metadata.bakedGenesisValidatorsRoot

  if not ChainDAGRef.isInitialized(db).isOk():
    let genesisState = if checkpointState != nil and getStateField(checkpointState[], slot) == 0:
      checkpointState
    else:
      let genesisBytes = block:
        if metadata.genesis.kind != BakedIn and config.genesisState.isSome:
          let res = io2.readAllBytes(config.genesisState.get.string)
          res.valueOr:
            error "Failed to read genesis state file", err = res.error.ioErrorMsg
            quit 1
        elif metadata.hasGenesis:
          try:
            await metadata.fetchGenesisBytes(config.genesisStateUrl)
          except CatchableError as err:
            error "Failed to obtain genesis state",
                  source = metadata.genesis.sourceDesc,
                  err = err.msg
            quit 1
        else:
          @[]

      if genesisBytes.len > 0:
        try:
          newClone readSszForkedHashedBeaconState(cfg, genesisBytes)
        except CatchableError as err:
          error "Invalid genesis state",
                size = genesisBytes.len,
                digest = eth2digest(genesisBytes),
                err = err.msg
          quit 1
      else:
        nil

    if genesisState == nil and checkpointState == nil:
      fatal "No database and no genesis snapshot found. Please supply a genesis.ssz " &
            "with the network configuration"
      quit 1

    if not genesisState.isNil and not checkpointState.isNil:
      if getStateField(genesisState[], genesis_validators_root) !=
          getStateField(checkpointState[], genesis_validators_root):
        fatal "Checkpoint state does not match genesis - check the --network parameter",
          rootFromGenesis = getStateField(
            genesisState[], genesis_validators_root),
          rootFromCheckpoint = getStateField(
            checkpointState[], genesis_validators_root)
        quit 1

    try:
      if not genesisState.isNil:
        ChainDAGRef.preInit(db, genesisState[])
        networkGenesisValidatorsRoot =
          Opt.some(getStateField(genesisState[], genesis_validators_root))

      if not checkpointState.isNil:
        if genesisState.isNil or
            getStateField(checkpointState[], slot) != GENESIS_SLOT:
          ChainDAGRef.preInit(db, checkpointState[])

      doAssert ChainDAGRef.isInitialized(db).isOk(), "preInit should have initialized db"
    except CatchableError as exc:
      error "Failed to initialize database", err = exc.msg
      quit 1
  else:
    if not checkpointState.isNil:
      fatal "A database already exists, cannot start from given checkpoint",
        dataDir = config.dataDir
      quit 1

  let
    dag = loadChainDag(
      config, cfg, db,
      networkGenesisValidatorsRoot)
    genesisTime = getStateField(dag.headState, genesis_time)
    beaconClock = BeaconClock.init(genesisTime).valueOr:
      fatal "Invalid genesis time in state", genesisTime
      quit 1

    getBeaconTime = beaconClock.getBeaconTimeFn()

  let elManager = default(ELManager)

  proc getValidatorAndIdx(pubkey: ValidatorPubKey): Opt[ValidatorAndIndex] =
    withState(dag.headState):
      getValidator(forkyState().data.validators.asSeq(), pubkey)

  func getCapellaForkVersion(): Opt[Version] =
    Opt.some(cfg.CAPELLA_FORK_VERSION)

  func getDenebForkEpoch(): Opt[Epoch] =
    Opt.some(cfg.DENEB_FORK_EPOCH)

  proc getForkForEpoch(epoch: Epoch): Opt[Fork] =
    Opt.some(dag.cfg.forkAtEpoch(epoch))

  proc getGenesisRoot(): Eth2Digest =
    getStateField(dag.headState, genesis_validators_root)

  let
    keystoreCache = KeystoreCacheRef.init()
    slashingProtectionDB =
      SlashingProtectionDB.init(
          getStateField(dag.headState, genesis_validators_root),
          config.validatorsDir(), "")
    validatorPool = newClone(ValidatorPool.init(
      slashingProtectionDB))

  let node = BeaconNode(
    nickname: "foobar",
    db: db,
    config: config,
    attachedValidators: validatorPool,
    elManager: elManager,
    keystoreCache: keystoreCache,
    beaconClock: beaconClock)

  await node.initFullNode(rng, dag, getBeaconTime)

  node

from ./spec/validator import get_beacon_proposer_indices

proc onSlotStart(node: BeaconNode, wallTime: BeaconTime,
                 lastSlot: Slot): Future[bool] {.async.} =
  let
    wallSlot = wallTime.slotOrZero
    expectedSlot = lastSlot + 1

  if wallSlot > 2:
    quit(0)

  await handleProposal(node, node.dag.head, wallSlot)
  quit 0

proc runOnSecondLoop(node: BeaconNode) {.async.} =
  const
    sleepTime = chronos.seconds(1)
  while true:
    let start = chronos.now(chronos.Moment)
    await chronos.sleepAsync(sleepTime)

proc start*(node: BeaconNode) {.raises: [CatchableError].} =
  echo "foo"
  node.elManager.start()
  let
    wallTime = node.beaconClock.now()

  asyncSpawn runSlotLoop(node, wallTime, onSlotStart)
  asyncSpawn runOnSecondLoop(node)

  while true:
    poll() # if poll fails, the network is broken
