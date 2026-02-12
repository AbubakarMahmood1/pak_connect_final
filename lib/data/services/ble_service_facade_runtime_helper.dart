part of 'ble_service_facade.dart';

class _BleServiceFacadeRuntimeHelper {
  _BleServiceFacadeRuntimeHelper(this._owner);

  final BLEServiceFacade _owner;

  Future<void> initializeFacade() async {
    _owner._logger.info(
      '🏗️ Initializing BLEServiceFacade (lazy initialization)...',
    );
    try {
      await _owner._platformHost.ensureEphemeralKeysInitialized();
      await _owner._stateManager.initialize();
      await _owner._initializeNodeIdentity();
      await _owner._bluetoothStateMonitor.initialize(
        onBluetoothReady: () => unawaited(_owner._onBluetoothBecameReady()),
        onBluetoothUnavailable: () =>
            unawaited(_owner._onBluetoothBecameUnavailable()),
        onInitializationRetry: () =>
            unawaited(_owner._onBluetoothInitializationRetry()),
      );
      _owner._ensureConnectionServicePrepared();
      await _owner._ensureDiscoveryInitialized();
    } catch (e, stack) {
      _owner._logger.severe(
        '❌ Failed to initialize BLEServiceFacade',
        e,
        stack,
      );
      if (!_owner._initializationCompleter.isCompleted) {
        _owner._initializationCompleter.completeError(e, stack);
      }
      rethrow;
    }
    _owner._logger.info('✅ BLEServiceFacade ready');
    if (!_owner._initializationCompleter.isCompleted) {
      _owner._initializationCompleter.complete();
    }
  }

  Future<void> disposeFacade() async {
    _owner._logger.info('🧹 Disposing BLEServiceFacade...');

    try {
      if (_owner._discoveryService != null) {
        await _owner._discoveryService!.dispose().catchError((_) {});
      }
      if (_owner._connectionService != null) {
        _owner._connectionService!.stopConnectionMonitoring();
        await _owner._connectionService!.disconnect().catchError((_) {});
        _owner._connectionService!.disposeConnection();
      }
      if (_owner._handshakeService != null) {
        _owner._handshakeService!.disposeHandshakeCoordinator();
      }
      _owner._messageHandlerFacade.dispose();
      _owner._messageHandler.dispose();
      _owner._logger.info('✅ BLEServiceFacade disposed');
    } catch (e, stack) {
      _owner._logger.severe('❌ Disposal error', e, stack);
    } finally {
      _owner._eventBus.clear();
      await _owner._connectionInfoSubscription?.cancel();
      _owner._connectionInfoSubscription = null;
      await _owner._lifecycleCoordinator.dispose();
    }
  }

  Future<String> getMyPublicKey() async {
    _owner._logger.fine('Getting public key from BLEStateManager...');
    try {
      return await _owner._stateManager.getMyPersistentId();
    } catch (e, stack) {
      _owner._logger.warning('Failed to read persistent key', e, stack);
      return '';
    }
  }

  Future<String> getMyEphemeralId() async {
    String? ephemeralId;
    try {
      ephemeralId = _owner._stateManager.myEphemeralId;
    } on StateError catch (e, stack) {
      _owner._logger.warning(
        'EphemeralKeyManager not initialized via BLEStateManager',
        e,
        stack,
      );
      await _owner._platformHost.ensureEphemeralKeysInitialized();
      try {
        ephemeralId = _owner._stateManager.myEphemeralId;
      } catch (_) {
        // fallback below
      }
    }
    if (ephemeralId != null && ephemeralId.isNotEmpty) {
      return ephemeralId;
    }
    try {
      _owner._logger.fine(
        'State manager missing ephemeral ID - querying platform',
      );
      return _owner._platformHost.getCurrentEphemeralId();
    } catch (e, stack) {
      _owner._logger.warning('Ephemeral key provider not available', e, stack);
      return '';
    }
  }

  Future<void> setMyUserName(String name) async {
    _owner._logger.fine('Setting username to: $name');
    await _owner._stateManager.setMyUserName(name);
  }

  void registerQueueSyncHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  ) {
    _owner._logger.info(
      '📡 Registering queue sync handler for mesh networking',
    );
    _owner._queueSyncHandler = handler;
    _owner._messageHandlerFacade.onQueueSyncReceived = (message, fromNodeId) {
      final registeredHandler = _owner._queueSyncHandler;
      if (registeredHandler != null) {
        unawaited(registeredHandler(message, fromNodeId));
      }
    };
    _owner._getMessagingService().registerQueueSyncMessageHandler(handler);
  }

  Stream<List<Peripheral>> get discoveredDevicesStream =>
      Stream<List<Peripheral>>.multi((controller) {
        controller.add(_owner._connectionManager.activeConnections);

        final subscription = _owner
            ._getDiscoveryService()
            .discoveredDevices
            .listen(
              (devices) {
                controller.add(devices);
              },
              onError: (error, stackTrace) {
                controller.addError(error, stackTrace);
              },
            );

        controller.onCancel = () {
          subscription.cancel();
        };
      }, isBroadcast: true);

  void emitSpyModeDetected(SpyModeInfo info) {
    notifySpyModeDetected(info);
    if (_owner._handshakeService != null && !_owner._forwardingSpyModeEvent) {
      _owner._forwardingSpyModeEvent = true;
      try {
        _owner._handshakeService!.emitSpyModeDetected(info);
      } finally {
        _owner._forwardingSpyModeEvent = false;
      }
    }
  }

  void notifySpyModeDetected(SpyModeInfo info) {
    _owner._stateManager.onSpyModeDetected?.call(info);
    _owner._eventBus.emitSpyMode(info);
  }

  void emitIdentityRevealed(String contactId) {
    notifyIdentityRevealed(contactId);
    if (_owner._handshakeService != null && !_owner._forwardingIdentityEvent) {
      _owner._forwardingIdentityEvent = true;
      try {
        _owner._handshakeService!.emitIdentityRevealed(contactId);
      } finally {
        _owner._forwardingIdentityEvent = false;
      }
    }
  }

  void notifyIdentityRevealed(String contactId) {
    _owner._stateManager.onIdentityRevealed?.call(contactId);
    _owner._eventBus.emitIdentityRevealed(contactId);
  }

  void ensureConnectionServicePrepared() {
    _owner._lifecycleCoordinator.ensureConnectionServicePrepared();
  }

  Future<void> ensureDiscoveryInitialized() async {
    await _owner._lifecycleCoordinator.ensureDiscoveryInitialized();
  }

  void updateConnectionInfo({
    bool? isConnected,
    bool? isReady,
    String? otherUserName,
    String? statusMessage,
    bool? isScanning,
    bool? isAdvertising,
    bool? isReconnecting,
  }) {
    _owner._currentConnectionInfo = _owner._currentConnectionInfo.copyWith(
      isConnected: isConnected,
      isReady: isReady,
      otherUserName: otherUserName,
      statusMessage: statusMessage,
      isScanning: isScanning,
      isAdvertising: isAdvertising,
      isReconnecting: isReconnecting,
    );
    _owner._eventBus.emitConnectionInfo(_owner._currentConnectionInfo);
  }

  Future<void> initializeNodeIdentity() async {
    try {
      final prefs = UserPreferences();
      final persistent = await prefs.getPublicKey();
      final sessionId = EphemeralKeyManager.currentSessionKey;
      final nodeId = (sessionId != null && sessionId.isNotEmpty)
          ? sessionId
          : (persistent.isNotEmpty ? persistent : null);

      if (nodeId != null) {
        _owner._messageHandler.setCurrentNodeId(nodeId);
        _owner._messageHandlerFacade.setCurrentNodeId(nodeId);
        _owner._logger.fine(
          '🔧 Node identity set for messaging: ${nodeId.shortId(8)}',
        );
      } else {
        _owner._logger.warning(
          '⚠️ Unable to set node identity (no session or persistent key)',
        );
      }
    } catch (e) {
      _owner._logger.warning('⚠️ Failed to initialize node identity: $e');
    }
  }

  Future<void> onBluetoothBecameReady() async {
    _owner._logger.info('🔵 Bluetooth ready - facade notified');
    final advertisingService = _owner._getAdvertisingService();
    try {
      await _owner._connectionManager.startMeshNetworking(
        onStartAdvertising: () => advertisingService.startAsPeripheral(),
      );
      updateConnectionInfo(
        statusMessage: 'Bluetooth ready for dual-role operation',
        isAdvertising: advertisingService.isAdvertising,
      );
    } catch (e, stack) {
      _owner._logger.warning(
        '⚠️ Failed to start mesh networking after Bluetooth ready: $e',
        e,
        stack,
      );
      updateConnectionInfo(
        statusMessage: 'Bluetooth ready (advertising unavailable)',
        isAdvertising: advertisingService.isAdvertising,
      );
    }
  }

  Future<void> onBluetoothBecameUnavailable() async {
    _owner._logger.warning('🔵 Bluetooth unavailable - facade notified');
    updateConnectionInfo(
      isConnected: false,
      isReady: false,
      statusMessage: 'Bluetooth unavailable',
      isScanning: false,
      isAdvertising: false,
    );
  }

  Future<void> onBluetoothInitializationRetry() async {
    _owner._logger.info('🔄 Retrying Bluetooth initialization...');
  }

  void handleIdentityExchangeSent(String publicKey, String displayName) {
    final truncatedKey = publicKey.length > 16
        ? '${publicKey.substring(0, 8)}...'
        : publicKey;
    _owner._logger.fine(
      '🪪 Identity exchange sent (pubKey: $truncatedKey, displayName: $displayName)',
    );
  }

  Future<void> sendHandshakeProtocolMessage(ProtocolMessage message) =>
      _owner._getMessagingService().sendHandshakeMessage(message);

  Future<void> processPendingHandshakeMessages() async {
    if (_owner._handshakeMessageBuffer.isNotEmpty) {
      _owner._logger.fine(
        '📦 Flushing ${_owner._handshakeMessageBuffer.length} buffered handshake message(s)',
      );
      _owner._handshakeMessageBuffer.clear();
    }
  }

  Future<void> startGossipSync() async {
    // Placeholder hook for full gossip sync integration once wired
    _owner._logger.finer('🕸️ Gossip sync start hook invoked');
  }

  Future<void> handleHandshakeComplete({
    required String ephemeralId,
    required String displayName,
    required String? noiseKey,
  }) async {
    final truncatedId = ephemeralId.length > 8
        ? '${ephemeralId.substring(0, 8)}...'
        : ephemeralId;
    _owner._logger.info(
      '🤝 Handshake complete with $displayName ($truncatedId)',
    );
    _owner._stateManager.setOtherUserName(displayName);
    _owner._stateManager.setTheirEphemeralId(ephemeralId, displayName);
    // Persist or create contact record using the session ephemeral as the
    // immutable key for LOW security contacts. This prevents later sends from
    // resolving to an empty/“NOT SPECIFIED” recipient.
    try {
      final existingContact = await _owner._contactRepository.getContact(
        ephemeralId,
      );
      if (existingContact == null) {
        await _owner._contactRepository.saveContactWithSecurity(
          ephemeralId,
          displayName,
          SecurityLevel.low,
          currentEphemeralId: ephemeralId,
        );
        _owner._logger.info(
          '🔒 HANDSHAKE: Created LOW-security contact for $displayName ($truncatedId)',
        );
      } else {
        if (existingContact.currentEphemeralId != ephemeralId) {
          await _owner._contactRepository.updateContactEphemeralId(
            existingContact.publicKey,
            ephemeralId,
          );
        }
        if (existingContact.persistentPublicKey != null &&
            existingContact.persistentPublicKey!.isNotEmpty) {
          SecurityServiceLocator.instance.registerIdentityMapping(
            persistentPublicKey: existingContact.persistentPublicKey!,
            ephemeralID: ephemeralId,
          );
        }
      }
    } catch (e) {
      _owner._logger.warning(
        '⚠️ Failed to persist contact after handshake: $e',
      );
    }
    // Allow health checks now that handshake is done.
    _owner._connectionManager.markHandshakeComplete();
    // Refresh our node identity in case session keys rotated during handshake.
    await initializeNodeIdentity();
    updateConnectionInfo(
      isConnected: true,
      isReady: true,
      otherUserName: displayName,
      statusMessage: 'Ready to chat',
    );
    await processPendingHandshakeMessages();
    await startGossipSync();
  }

  void handleSpyModeDetected(SpyModeInfo info) {
    _owner._logger.warning('🕵️ Spy mode detected with ${info.contactName}');
    if (_owner._forwardingSpyModeEvent) {
      return;
    }
    _owner._notifySpyModeDetected(info);
  }

  void handleIdentityRevealed(String contactId) {
    _owner._logger.info('🪪 Identity revealed to contact: $contactId');
    if (_owner._forwardingIdentityEvent) {
      return;
    }
    _owner._notifyIdentityRevealed(contactId);
  }
}
