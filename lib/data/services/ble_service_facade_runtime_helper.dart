part of 'ble_service_facade.dart';

class _BleServiceFacadeRuntimeHelper {
  _BleServiceFacadeRuntimeHelper(this._owner);

  final BLEServiceFacade _owner;

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
