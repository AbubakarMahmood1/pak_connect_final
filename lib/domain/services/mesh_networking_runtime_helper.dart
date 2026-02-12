part of 'mesh_networking_service.dart';

class _MeshNetworkingRuntimeHelper {
  _MeshNetworkingRuntimeHelper(this._owner);

  final MeshNetworkingService _owner;

  Future<void> initialize({String? nodeId}) async {
    if (_owner._isInitialized) {
      MeshNetworkingService._logger.warning(
        'Mesh networking service already initialized',
      );
      return;
    }

    try {
      MeshNetworkingService._logger.info(
        'Initializing mesh networking service...',
      );

      _owner._currentNodeId = nodeId ?? await _owner._getNodeIdWithFallback();
      final truncatedNodeId = _owner._currentNodeId!.length > 16
          ? _owner._currentNodeId!.shortId()
          : _owner._currentNodeId!;
      MeshNetworkingService._logger.info('Node ID: $truncatedNodeId...');

      await _owner._initializeCoreComponents();
      await _owner._loadPendingBinarySends();
      unawaited(
        _owner._mediaStore.cleanupStaleTransfers().then((removed) {
          if (removed > 0) {
            MeshNetworkingService._logger.fine(
              '🧹 Cleaned $removed stale binary payload(s) from disk',
            );
          }
        }),
      );

      await _owner._setupBLEIntegrationWithFallback();

      _owner._isInitialized = true;
      _owner._broadcastMeshStatus();
      MeshNetworkingService._logger.info(
        '✅ Mesh networking service initialized successfully',
      );
    } catch (e) {
      MeshNetworkingService._logger.severe(
        '❌ Failed to initialize mesh networking service: $e',
      );
      _owner._broadcastFallbackStatus();
      rethrow;
    }
  }

  Future<void> initializeCoreComponents() async {
    MeshNetworkingService._logger.info(
      '🔗 Using shared message queue provider for mesh networking',
    );

    if (!_owner._sharedQueueProvider.isInitialized) {
      if (_owner._sharedQueueProvider.isInitializing) {
        MeshNetworkingService._logger.info(
          'Shared queue host initialization in progress; reusing queue without re-entry',
        );
      } else {
        MeshNetworkingService._logger.warning(
          'Shared queue host not initialized, initializing now...',
        );
        await _owner._sharedQueueProvider.initialize();
      }
    }

    final sharedQueue = _owner._sharedQueueProvider.messageQueue;
    MeshNetworkingService._logger.info(
      '✅ Connected to shared message queue with ${sharedQueue.getStatistics().pendingMessages} pending messages',
    );

    await _owner._queueCoordinator.initialize(
      nodeId: _owner._currentNodeId!,
      messageQueue: sharedQueue,
      onStatusChanged: _owner._broadcastMeshStatus,
    );

    _owner._gossipSyncManager =
        GossipSyncManager(
            myNodeId: _owner._currentNodeId!,
            messageQueue: sharedQueue,
          )
          ..onSendSyncToPeer = (peerId, syncMessage) {
            MeshNetworkingService._logger.fine(
              '📡 Gossip: sending sync to ${peerId.shortId(8)}... (${syncMessage.messageIds.length} ids)',
            );
            unawaited(_owner._bleService.sendQueueSyncMessage(syncMessage));
          }
          ..onDirectAnnouncement = (peerId) {
            _owner._scheduleInitialSyncForPeer(
              peerId,
              delay: const Duration(seconds: 1),
            );
          }
          ..onSendSyncRequest = (syncMessage) {
            final peers = _owner._bleService.activeConnectionDeviceIds;
            if (peers.isEmpty) {
              MeshNetworkingService._logger.fine(
                '📡 Gossip: no peers to broadcast sync request',
              );
              return;
            }
            for (final peer in peers) {
              MeshNetworkingService._logger.fine(
                '📡 Gossip: broadcasting sync request to ${peer.shortId(8)}...',
              );
              unawaited(_owner._bleService.sendQueueSyncMessage(syncMessage));
            }
          };

    _owner._spamPrevention = SpamPreventionManager();
    await _owner._spamPrevention!.initialize();

    await _owner._relayCoordinator.initialize(
      nodeId: _owner._currentNodeId!,
      messageQueue: sharedQueue,
      spamPrevention: _owner._spamPrevention!,
    );

    if (_owner._gossipSyncManager != null) {
      await _owner._gossipSyncManager!.start();
    }

    MeshNetworkingService._logger.info(
      'Core mesh components initialized with dumb flood relay',
    );
  }

  Future<void> setupBleIntegration() async {
    if (_owner._integrationCancelled) {
      throw StateError('BLE integration cancelled');
    }

    await _owner._messageHandler.initializeRelaySystem(
      currentNodeId: _owner._currentNodeId!,
      onRelayDecisionMade: _owner._handleRelayDecision,
      onRelayStatsUpdated: _owner._handleRelayStatsUpdated,
    );

    if (_owner._integrationCancelled) {
      MeshNetworkingService._logger.info(
        'BLE integration cancelled mid-initialize; aborting setup',
      );
      return;
    }

    _owner._messageHandler.onRelayDecisionMade = _owner._handleRelayDecision;
    _owner._messageHandler.onRelayStatsUpdated =
        _owner._handleRelayStatsUpdated;

    _owner._queueCoordinator.enableQueueSyncHandling();
    _owner._queueCoordinator.startConnectionMonitoring();

    _owner._connectionSub ??= _owner._bleService.connectionInfo.listen(
      _owner._handleConnectionUpdateForGossip,
      onError: (e) =>
          MeshNetworkingService._logger.fine('Connection stream error: $e'),
    );

    _owner._identitySub ??= _owner._bleService.identityRevealed.listen(
      _owner._handleIdentityRevealedForGossip,
      onError: (e) =>
          MeshNetworkingService._logger.fine('Identity stream error: $e'),
    );

    _owner._binarySub ??= _owner._bleService.receivedBinaryStream.listen(
      _owner._handleBinaryPayload,
      onError: (e) =>
          MeshNetworkingService._logger.fine('Binary stream error: $e'),
    );

    MeshNetworkingService._logger.info('BLE integration set up');
  }

  void handleConnectionUpdateForGossip(ConnectionInfo info) {
    if (!info.isReady) return;
    final peerId = _owner._bleService.currentSessionId;
    if (peerId == null || peerId.isEmpty) return;
    _owner._scheduleInitialSyncForPeer(
      peerId,
      delay: const Duration(seconds: 1),
    );
    unawaited(_owner._flushPendingBinarySends());
  }

  void handleIdentityRevealedForGossip(String peerId) {
    _owner._scheduleInitialSyncForPeer(
      peerId,
      delay: const Duration(seconds: 1),
    );
  }

  void scheduleInitialSyncForPeer(
    String peerId, {
    Duration delay = const Duration(seconds: 1),
  }) {
    if (peerId.isEmpty) return;
    if (_owner._initialSyncPeers.contains(peerId)) return;
    _owner._initialSyncPeers.add(peerId);
    MeshNetworkingService._logger.fine(
      '📡 Scheduling initial gossip sync to ${peerId.shortId(8)}...',
    );

    final manager = _owner._gossipSyncManager;
    if (manager != null) {
      unawaited(manager.scheduleInitialSyncToPeer(peerId, delay: delay));
    }
  }

  Future<String> getNodeIdWithFallback() async {
    try {
      final ephemeralId = await Future.any([
        _owner._bleService.getMyEphemeralId(),
        Future.delayed(
          const Duration(seconds: 5),
          () => throw TimeoutException(
            'BLE service timeout',
            Duration(seconds: 5),
          ),
        ),
      ]);

      if (ephemeralId.isNotEmpty) {
        MeshNetworkingService._logger.info(
          '✅ Successfully obtained EPHEMERAL node ID from BLE service (session-specific)',
        );
        MeshNetworkingService._logger.info(
          '🔐 Privacy: Using ephemeral key for mesh routing (NOT persistent identity)',
        );
        return ephemeralId;
      }

      throw Exception('BLE service returned null/empty ephemeral ID');
    } catch (e) {
      MeshNetworkingService._logger.warning(
        '⚠️ BLE service unavailable for ephemeral ID (${e.toString()}), generating fallback',
      );
      final fallbackId = _owner._generateFallbackNodeId();
      MeshNetworkingService._logger.info(
        '🔄 Using fallback ephemeral node ID: ${fallbackId.length > 16 ? '${fallbackId.shortId()}...' : fallbackId}',
      );
      return fallbackId;
    }
  }

  String generateFallbackNodeId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = DateTime.now().microsecond;
    return 'fallback_${timestamp}_$random';
  }

  Future<void> waitForBluetoothReady({
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (_owner._bleService.isBluetoothReady) return;

    final completer = Completer<void>();
    late StreamSubscription<BluetoothStateInfo> sub;
    sub = _owner._bleService.bluetoothStateStream.listen((info) {
      if (info.isReady || info.state == BluetoothLowEnergyState.poweredOn) {
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    }, onError: (_) {});

    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      MeshNetworkingService._logger.warning(
        '⚠️ Bluetooth not ready within ${timeout.inSeconds}s; proceeding with fallback',
      );
      rethrow;
    } finally {
      await sub.cancel();
    }
  }

  Future<void> setupBleIntegrationWithFallback() async {
    try {
      await _owner._waitForBluetoothReady();

      _owner._integrationCancelled = false;
      await _owner._setupBLEIntegration().timeout(
        const Duration(seconds: 25),
        onTimeout: () {
          _owner._integrationCancelled = true;
          throw TimeoutException(
            'BLE integration timeout',
            Duration(seconds: 25),
          );
        },
      );
      MeshNetworkingService._logger.info(
        '✅ BLE integration set up successfully',
      );
    } catch (e) {
      MeshNetworkingService._logger.warning(
        '⚠️ BLE integration failed (${e.toString()}), continuing without BLE integration',
      );
      _owner._setupMinimalBLEIntegration();
    }
  }

  void setupMinimalBleIntegration() {
    try {
      _owner._queueCoordinator.startConnectionMonitoring();
      MeshNetworkingService._logger.info(
        '📱 Minimal BLE integration active (connection monitoring only)',
      );
    } catch (e) {
      MeshNetworkingService._logger.warning(
        'Even minimal BLE integration failed: $e',
      );
    }
  }

  void broadcastFallbackStatus() {
    _owner._healthMonitor.broadcastFallbackStatus(
      currentNodeId: _owner._currentNodeId,
    );
  }

  void broadcastMeshStatus() {
    _owner._healthMonitor.broadcastMeshStatus(
      isInitialized: _owner._isInitialized,
      currentNodeId: _owner._currentNodeId,
      isConnected: _owner._bleService.isConnected,
      statistics: _owner.getNetworkStatistics(),
      queueMessages: _owner._queueCoordinator.getActiveQueueMessages(),
    );
  }

  void dispose() {
    _owner._relayCoordinator.dispose();
    unawaited(_owner._queueCoordinator.dispose());
    _owner._spamPrevention?.dispose();
    _owner._spamPrevention = null;
    _owner._gossipSyncManager?.stop();
    _owner._connectionSub?.cancel();
    _owner._connectionSub = null;
    _owner._identitySub?.cancel();
    _owner._identitySub = null;
    _owner._binarySub?.cancel();
    _owner._binarySub = null;
    _owner._binaryController.close();
    _owner._healthMonitor.dispose();

    MeshNetworkingService._logger.info('Mesh networking service disposed');
  }
}
