part of 'ble_connection_manager.dart';

extension _BleConnectionManagerRuntime on BLEConnectionManager {
  Future<void> _runtimeRemoveServerConnection(
    String address, {
    String reasonLog = 'client wins',
  }) async {
    final server = _serverConnections.remove(address);
    _peerHintsByAddress.remove(address);
    _blockedResponderHandshakes.remove(address);
    if (server != null) {
      try {
        await peripheralManager.disconnect(server.central);
        _logger.info('🔌 Force disconnected inbound central: $address');
      } catch (e) {
        _logger.warning(
          '⚠️ Failed to force disconnect central (might be unsupported): $e — retrying once',
        );
        try {
          await Future.delayed(const Duration(milliseconds: 200));
          await peripheralManager.disconnect(server.central);
          _logger.info('🔌 Retry disconnect succeeded for inbound $address');
        } catch (secondError) {
          _logger.warning(
            '⚠️ Second disconnect attempt failed for inbound $address: $secondError',
          );
        }
      }

      _logger.info('🧹 Removed inbound server connection ($reasonLog)');
    }

    _connectionTracker.removeConnection(address);

    _serverConnectionsController.add(serverConnections);
    _healthMonitor.setAwaitingHandshake(false);
    _updateAdvertisingState();
  }

  Future<void> _runtimeCompleteDeferredServerTeardown(
    String address, {
    required String reason,
  }) async {
    _blockedResponderHandshakes.remove(address);
    _deferredServerTeardown.remove(address);
    _deferredServerTeardownTimers.remove(address)?.cancel();
    await _removeServerConnection(address, reasonLog: reason);

    // Tracker should reflect the surviving client link so reconnect suppression stays active.
    _connectionTracker.removeConnection(
      address,
    ); // remove stale server-side entry
    final clientKey = _matchClientAddressByPeer(address);
    if (clientKey != null) {
      final client = _clientConnections[clientKey];
      _connectionTracker.addConnection(
        address: clientKey,
        isClient: true,
        rssi: client?.rssi,
      );
    }
  }

  void _runtimeScheduleDeferredServerTeardownCheck(String address) {
    _deferredServerTeardownTimers[address]?.cancel();
    // Short window: allow notify subscription or handshake kick-off to arrive.
    _deferredServerTeardownTimers[address] = Timer(
      const Duration(milliseconds: 1500),
      () async {
        if (!_deferredServerTeardown.contains(address)) return;

        final serverConn = _serverConnections[address];
        final hasSubscription = serverConn?.subscribedCharacteristic != null;
        if (hasSubscription || _healthMonitor.isHandshakeInProgress) {
          await _completeDeferredServerTeardown(
            address,
            reason: hasSubscription
                ? 'notify subscription observed'
                : 'handshake started during deferral',
          );
          return;
        }

        _logger.warning(
          '⚠️ Inbound link never became viable for ${_formatAddress(address)} — closing deferred server side',
        );

        await _completeDeferredServerTeardown(
          address,
          reason: 'non-viable inbound after deferral',
        );
      },
    );
  }

  Future<void> _runtimeStartMeshNetworking({
    Future<void> Function()? onStartAdvertising,
  }) async {
    _logger.info(
      '🚀 Starting mesh networking (simultaneous central + peripheral)',
    );

    try {
      // Start advertising FIRST (like BitChat)
      // ✅ NEW: Use callback to BLEService.startAsPeripheral() → AdvertisingManager
      if (onStartAdvertising != null) {
        _logger.info(
          '📡 Calling advertising callback (BLEService.startAsPeripheral)...',
        );
        await onStartAdvertising();
        _isAdvertising = true; // Assume success if no exception
        _logger.info(
          '✅ Peripheral role active (advertising via AdvertisingManager)',
        );
      } else {
        _logger.severe(
          '❌ No advertising callback provided - advertising will NOT start!',
        );
        throw Exception(
          'startMeshNetworking requires onStartAdvertising callback',
        );
      }

      // Central role is always ready (discovery initiated by BurstScanController)
      _logger.info('✅ Central role active (ready to scan)');
      _shouldBeAdvertising = true;

      _logger.info('🎉 Mesh networking started successfully');
      _logger.info('📊 Connection limits: $_limitConfig');
    } catch (e) {
      _logger.severe('❌ Failed to start mesh networking: $e');
      rethrow;
    }
  }

  Future<void> _runtimeStopMeshNetworking() async {
    _logger.info('🛑 Stopping mesh networking');

    _shouldBeAdvertising = false;

    try {
      await _stopAdvertising();
      _logger.info('✅ Mesh networking stopped');
    } catch (e) {
      _logger.warning('⚠️ Error stopping mesh networking: $e');
    }
  }

  Future<void> _runtimeUpdateAdvertisingState() async {
    try {
      final shouldAdvertise = _shouldBeAdvertising && canAcceptServerConnection;

      if (shouldAdvertise && !_isAdvertising) {
        // ⚠️ CANNOT start advertising here - requires BLEService callback
        // Advertising is managed by AdvertisingManager in BLEService
        _logger.info(
          '📡 Should start advertising (server connections: $serverConnectionCount/${_limitConfig.maxServerConnections})',
        );
        _logger.info(
          '⚠️ Advertising start requires BLEService.startAsPeripheral() - skipping',
        );
      } else if (!shouldAdvertise && _isAdvertising) {
        // Stop advertising (at limit or user requested stop)
        final reason = !_shouldBeAdvertising
            ? 'user requested'
            : 'reached limit: $serverConnectionCount/${_limitConfig.maxServerConnections}';
        _logger.info('🛑 Stopping advertising ($reason)');
        await _stopAdvertising();
      }
    } catch (e) {
      _logger.warning('⚠️ Advertising state update failed: $e');
    }
  }

  Future<void> _runtimeResolveInboundCollision(String address) async {
    _collisionResolutionsInFlight.add(address);
    final clientAddress = _matchClientAddressByPeer(address);
    try {
      final yieldToInbound = await _shouldYieldToInboundLink(address);

      if (yieldToInbound) {
        _logger.info(
          '⚖️ Collision: Yielding to inbound server link. Disconnecting client.',
        );
        final clientKey = clientAddress ?? address;
        final client = _clientConnections[clientKey];
        if (client != null) {
          try {
            await centralManager.disconnect(client.peripheral);
          } catch (e) {
            _logger.warning('⚠️ Failed to disconnect stale client link: $e');
          }
          _clientConnections.remove(clientKey);
        }
        if (_serverConnections.containsKey(address)) {
          _connectionTracker.addConnection(
            address: address,
            isClient: false,
            rssi: null,
          );
          _connectionTracker.removeConnection(clientKey);
        } else {
          _connectionTracker.removeConnection(clientKey);
          _connectionTracker.removeConnection(address);
        }
      } else {
        _logger.info(
          '⚖️ Collision: Keeping client link. Closing inbound server side.',
        );
        _logger.fine(
          '⏸️ Deferring inbound teardown for ${_formatAddress(address)} until notify/handshake start',
        );
        _deferredServerTeardown.add(address);
        _scheduleDeferredServerTeardownCheck(address);
        _pendingClientConnections.remove(address);
        if (clientAddress != null) {
          _pendingClientConnections.remove(clientAddress);
        }
        _connectionTracker.clearAttempt(address);

        final trackedClientKey = clientAddress ?? address;
        final client = _clientConnections[trackedClientKey];
        if (client != null) {
          _connectionTracker.addConnection(
            address: trackedClientKey,
            isClient: true,
            rssi: client.rssi,
          );
        } else {
          _connectionTracker.removeConnection(trackedClientKey);
        }
        _healthMonitor.setAwaitingHandshake(false);
        _serverConnectionsController.add(serverConnections);
        _updateAdvertisingState();
      }
    } catch (e) {
      _logger.warning('⚠️ Collision resolution failed: $e');
    } finally {
      _collisionResolutionsInFlight.remove(address);
    }
  }

  Future<void> _runtimeStopAdvertising() async {
    if (!_isAdvertising) {
      _logger.fine('🛑 Not advertising, skipping');
      return;
    }

    try {
      await peripheralManager.stopAdvertising();
      _isAdvertising = false;
      _logger.info('✅ Advertising stopped');
    } catch (e) {
      _logger.warning('⚠️ Failed to stop advertising: $e');
    }
  }

  Future<void> _runtimeHandleCentralConnected(Central central) async {
    final address = central.uuid.toString();
    _trackPeerHintForAddress(address);
    final peerHint = _peerHintForAddress(address);
    final hasClientForPeer = hasClientLinkForPeer(address);
    final pendingClientForPeer = hasPendingClientForPeer(address);
    final hasServerForPeer = hasServerLinkForPeer(address);
    final hasHintCollision = hasAnyLinkForPeerHint(peerHint);

    if (connectionState == ChatConnectionState.ready ||
        hasServerForPeer ||
        hasClientForPeer ||
        pendingClientForPeer ||
        hasHintCollision) {
      if (hasHintCollision || pendingClientForPeer) {
        _cancelPendingClientForPeer(
          address,
          reason: 'inbound duplicate detected',
        );
      }
      _logger.info(
        '🚫 Hard rejecting inbound from ${_formatAddress(address)}: '
        'Already ${connectionState == ChatConnectionState.ready ? "READY" : "CLIENT_LINK_ACTIVE/PENDING"} '
        '(hintMatch=$hasHintCollision)',
      );
      try {
        _blockedResponderHandshakes.add(address);
        await peripheralManager.disconnect(central);
        _ensureTrackerForClientPeer(address);
        _notifyInboundRejected(address);
      } catch (e) {
        _logger.warning(
          '⚠️ Failed to reject duplicate inbound for ${_formatAddress(address)}: $e',
        );
      }
      return;
    }

    if (_serverConnections.containsKey(address)) {
      _logger.warning(
        '⚠️ Central already connected: ${_formatAddress(address)} — rejecting duplicate inbound',
      );
      try {
        await peripheralManager.disconnect(central);
      } catch (e) {
        _logger.warning(
          '⚠️ Failed to disconnect duplicate inbound central: $e',
        );
      }
      return;
    }

    final collisionWithClient = _clientConnections.containsKey(address);

    _logger.info(
      '📥 Central connected: ${_formatAddress(address)} (server connections: ${serverConnectionCount + 1}/${_limitConfig.maxServerConnections})',
    );
    _healthMonitor.setAwaitingHandshake(true);

    final connection = BLEServerConnection(
      address: address,
      central: central,
      connectedAt: DateTime.now(),
    );

    _serverConnections[address] = connection;
    _connectionTracker.addConnection(
      address: address,
      isClient: false,
      rssi: null,
    );
    _logger.info(
      '📊 Total connections: $totalConnectionCount (client: $clientConnectionCount, server: $serverConnectionCount)',
    );

    _serverConnectionsController.add(serverConnections);
    _updateAdvertisingState();

    if (collisionWithClient) {
      _logger.info(
        '🔀 Collision detected with ${_formatAddress(address)} - resolving after server registration',
      );
      await _resolveInboundCollision(address);
      _serverConnectionsController.add(serverConnections);
    }
  }

  void _runtimeHandleCentralDisconnected(Central central) {
    final address = central.uuid.toString();
    _peerHintsByAddress.remove(address);
    _blockedResponderHandshakes.remove(address);

    final connection = _serverConnections.remove(address);
    if (connection != null) {
      _deferredServerTeardown.remove(address);
      _deferredServerTeardownTimers.remove(address)?.cancel();
      final duration = connection.connectedDuration;
      _logger.info(
        '📤 Central disconnected: ${_formatAddress(address)} (connected for: ${duration.inSeconds}s, server connections: $serverConnectionCount/${_limitConfig.maxServerConnections})',
      );
      _connectionTracker.removeConnection(address);

      onCentralDisconnected?.call(address);
      if (_serverConnections.isEmpty) {
        _healthMonitor.setAwaitingHandshake(false);
        onCharacteristicFound?.call(null);
        onMtuDetected?.call(null);
      }
    } else {
      _logger.warning(
        '⚠️ Unknown central disconnected: ${_formatAddress(address)}',
      );
    }

    _logger.info(
      '📊 Total connections: $totalConnectionCount (client: $clientConnectionCount, server: $serverConnectionCount)',
    );

    _serverConnectionsController.add(serverConnections);
    _updateAdvertisingState();
  }

  void _runtimeHandleCharacteristicSubscribed(
    Central central,
    GATTCharacteristic characteristic,
  ) {
    final address = central.uuid.toString();
    final peerHint = _peerHintForAddress(address);
    final hasHintCollision = hasAnyLinkForPeerHint(peerHint);

    final connection = _serverConnections[address];
    if (connection != null) {
      if (hasHintCollision &&
          (connectionState == ChatConnectionState.ready ||
              hasClientLinkForPeer(address) ||
              hasPendingClientForPeer(address))) {
        _logger.warning(
          '🚫 Duplicate inbound notify from ${_formatAddress(address)} (hint match) '
          'while client/ready link exists — dropping before subscription handling',
        );
        _cancelPendingClientForPeer(
          address,
          reason: 'duplicate inbound notify',
        );
        _blockedResponderHandshakes.add(address);
        unawaited(
          _completeDeferredServerTeardown(
            address,
            reason: 'duplicate inbound notify (hint match)',
          ),
        );
        _notifyInboundRejected(address);
        return;
      }

      if (_connectionTracker.isConnected(address) &&
          _clientConnections.containsKey(address) &&
          connectionState == ChatConnectionState.ready) {
        _logger.warning(
          '⚠️ Late inbound notify from ${_formatAddress(address)} after client link is ready — disconnecting duplicate inbound',
        );
        _blockedResponderHandshakes.add(address);
        unawaited(
          _completeDeferredServerTeardown(
            address,
            reason: 'late inbound after client ready',
          ),
        );
        _notifyInboundRejected(address);
        return;
      }

      _serverConnections[address] = connection.copyWith(
        subscribedCharacteristic: characteristic,
      );
      _logger.info(
        '📝 Central subscribed to notifications: ${_formatAddress(address)}',
      );
      if (_deferredServerTeardown.contains(address)) {
        _logger.fine(
          '⏸️ Deferred inbound teardown resolved by notify for ${_formatAddress(address)}',
        );
        unawaited(
          _completeDeferredServerTeardown(
            address,
            reason: 'notify subscription arrived',
          ),
        );
      }
    } else {
      _logger.warning(
        '⚠️ Subscription from unknown central: ${_formatAddress(address)}',
      );
    }
  }

  void _runtimeUpdateServerMtu(String address, int mtu) {
    final connection = _serverConnections[address];
    if (connection != null) {
      _serverConnections[address] = connection.copyWith(mtu: mtu);
      _logger.fine(
        '📏 Updated server MTU for ${_formatAddress(address)}: $mtu bytes',
      );
      if (_deferredServerTeardown.contains(address)) {
        _logger.fine(
          '⏸️ Deferred inbound teardown resolved by MTU negotiation for ${_formatAddress(address)}',
        );
        unawaited(
          _completeDeferredServerTeardown(
            address,
            reason: 'mtu observed during deferral',
          ),
        );
      }
    }
  }

  Future<bool> _runtimeShouldYieldToInboundLink(String address) async {
    if (_pendingClientConnections.contains(address)) {
      _logger.fine(
        '⏭️ Skipping inbound viability wait for ${_formatAddress(address)} because outbound dial is pending (favoring client link)',
      );
      return false;
    }

    if (_deferredServerTeardown.contains(address)) {
      _logger.fine(
        '⏭️ Skipping inbound viability wait for ${_formatAddress(address)} because deferral is active (keeping client link)',
      );
      return false;
    }

    bool inboundViable(BLEServerConnection? conn) {
      if (conn == null) return false;
      final hasSubscription = conn.subscribedCharacteristic != null;
      final hasMtu = conn.mtu != null && conn.mtu! > 0;
      return hasSubscription || hasMtu;
    }

    Future<bool> waitForInboundViable(Duration timeout) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        final conn = _serverConnections[address];
        if (inboundViable(conn)) return true;
        await Future.delayed(Duration(milliseconds: 50));
      }
      return inboundViable(_serverConnections[address]);
    }

    try {
      final now = DateTime.now();
      final initialServerConn = _serverConnections[address];
      _logger.fine(
        '⏱️ Collision check @${now.toIso8601String()} for ${_formatAddress(address)} '
        '(pendingClient=${_pendingClientConnections.contains(address)}, '
        'handshakeInProgress=${_healthMonitor.isHandshakeInProgress}, '
        'awaitingHandshake=${_healthMonitor.awaitingHandshake})',
      );
      final serverConn = _serverConnections[address];
      final inboundWaitDuration = const Duration(milliseconds: 2500);
      final inboundViable = await waitForInboundViable(inboundWaitDuration);
      _logger.fine(
        '📡 Inbound viability after $inboundWaitDuration '
        '(hadEntry=${initialServerConn != null}) -> $inboundViable',
      );

      if (inboundViable && serverConn != null) {
        _logger.info(
          '⚖️ Collision tie-breaker: inbound link is viable (subscribed/MTU) — yielding to inbound',
        );
        return true;
      }

      final remoteDevice = DeviceDeduplicationManager.getDevice(address);
      final remoteHint = remoteDevice?.ephemeralHint;
      final localHint = _localHintProvider != null
          ? await _localHintProvider!.call()
          : null;

      final localToken = (localHint != null && localHint.isNotEmpty)
          ? localHint
          : EphemeralKeyManager.generateMyEphemeralKey();
      final remoteToken =
          (remoteHint != null &&
              remoteHint.isNotEmpty &&
              remoteHint != DeviceDeduplicationManager.noHintValue)
          ? remoteHint
          : address;
      final comparison = localToken.compareTo(remoteToken);
      final preferInbound = comparison > 0;

      if (preferInbound && serverConn != null) {
        _logger.info(
          '⚖️ Collision tie-breaker: tokens local=$localToken remote=$remoteToken — inbound preferred by token',
        );
        if (!inboundViable) {
          _logger.info(
            '⚠️ Inbound not viable after wait for ${_formatAddress(address)} — keeping outbound link to preserve symmetry',
          );
          return false;
        }
        _logger.info(
          '⚖️ Collision tie-breaker: inbound viable and token-preferred — yielding to inbound',
        );
        return true;
      }

      _logger.info(
        '⚖️ Collision tie-breaker: tokens local=$localToken remote=$remoteToken — keeping client link',
      );
      return false;
    } catch (e) {
      _logger.warning(
        '⚖️ Collision tie-breaker failed ($address): $e — keeping client link',
      );
      return false;
    }
  }

  Future<void> _runtimeHandlePowerModeChange(PowerMode newMode) async {
    _logger.info('⚡ Power mode changed to: ${newMode.name}');

    final oldConfig = _limitConfig;
    final oldRssiThreshold = _rssiThreshold;

    _limitConfig = ConnectionLimitConfig.forPowerMode(newMode);
    _rssiThreshold = _limitEnforcer.rssiThresholdForPowerMode(newMode);

    _logger.info('🎯 Connection limits updated: $oldConfig → $_limitConfig');
    _logger.info(
      '📡 RSSI threshold updated: $oldRssiThreshold dBm → $_rssiThreshold dBm',
    );

    await _limitEnforcer.enforceConnectionLimits(
      limitConfig: _limitConfig,
      clientConnections: _clientConnections,
      serverConnections: _serverConnections,
      centralManager: centralManager,
      updateAdvertisingState: _updateAdvertisingState,
      formatAddress: _formatAddress,
    );

    await _updateAdvertisingState();
  }

  void _runtimeHandleBluetoothStateChange(BluetoothLowEnergyState state) {
    _reconnectPolicy.handleBluetoothStateChange(
      state: state,
      hasBleConnection: hasBleConnection,
      connectedDevice: _connectedDevice,
      lastConnectedDevice: _lastConnectedDevice,
      setLastConnectedDevice: (device) => _lastConnectedDevice = device,
      setReconnectionFlag: (value) => _isReconnection = value,
      startConnectionMonitoring: startConnectionMonitoring,
      stopConnectionMonitoring: stopConnectionMonitoring,
      clearConnectionState: ({bool keepMonitoring = false}) =>
          clearConnectionState(keepMonitoring: keepMonitoring),
    );
  }

  Future<void> _runtimeConnectToDevice(Peripheral device, {int? rssi}) async {
    final address = device.uuid.toString();
    _trackPeerHintForAddress(address);

    if (_connectionTracker.isConnected(address)) {
      _logger.fine(
        '↔️ Unified tracker: already connected to ${_formatAddress(address)} — skipping outbound connect',
      );
      return;
    }
    if (_clientConnections.containsKey(address) ||
        _serverConnections.containsKey(address)) {
      _logger.fine(
        '↔️ Existing link (client/server) to ${_formatAddress(address)} — skipping outbound connect',
      );
      return;
    }

    if (!_connectionTracker.canAttempt(address)) {
      _logger.fine(
        '⏳ Backing off reconnect to ${_formatAddress(address)} (pending attempt window)',
      );
      return;
    }
    _connectionTracker.markAttempt(address);

    if (_pendingClientConnections.contains(address)) {
      _logger.fine(
        '↻ Already connecting to ${_formatAddress(address)} - ignoring duplicate request',
      );
      return;
    }

    try {
      _pendingClientConnections.add(address);

      if (_serverConnections.containsKey(address)) {
        _logger.info(
          '↔️ Single-link: inbound link already active for ${_formatAddress(address)} — skipping outbound connect',
        );
        return;
      }

      if (rssi != null && rssi < _rssiThreshold) {
        _logger.info(
          '📡 Skipping weak device: RSSI $rssi dBm < threshold $_rssiThreshold dBm '
          '(${_formatAddress(address)})',
        );
        return;
      }

      if (rssi != null) {
        _logger.fine(
          '📡 Device RSSI: $rssi dBm (threshold: $_rssiThreshold dBm)',
        );
      }

      if (!canAcceptClientConnection) {
        _logger.warning(
          '⚠️ Cannot accept client connection (limit: ${_limitConfig.maxClientConnections}, current: $clientConnectionCount, total: $totalConnectionCount)',
        );
        throw ConnectionLimitException(
          'Client connection limit reached',
          currentCount: clientConnectionCount,
          maxCount: _limitConfig.maxClientConnections,
        );
      }

      _logger.info(
        '🔌 Connecting to ${_formatAddress(address)} @${DateTime.now().toIso8601String()}...',
      );
      await Future.delayed(Duration(milliseconds: 500));

      await _gattController.connectWithRetry(
        device: device,
        formattedAddress: _formatAddress(address),
      );

      if (_serverConnections.containsKey(address)) {
        final yieldToInbound = await _shouldYieldToInboundLink(address);
        if (yieldToInbound) {
          _logger.info(
            '↔️ Collision policy yielded to inbound link for ${_formatAddress(address)} — abandoning client link',
          );
          try {
            await centralManager.disconnect(device);
          } catch (e) {
            _logger.warning('⚠️ Failed to disconnect yielded client link: $e');
          }
          _connectionTracker.clearAttempt(address);
          return;
        } else {
          _logger.info(
            '↔️ Collision policy prefers our client link for ${_formatAddress(address)} — keeping outbound connection',
          );
          await _completeDeferredServerTeardown(
            address,
            reason: 'collision cleanup after outbound connect',
          );
        }
      }

      var connection = BLEClientConnection(
        address: address,
        peripheral: device,
        connectedAt: DateTime.now(),
      );

      _clientConnections[address] = connection;
      _lastConnectedDevice = device;
      _connectionTracker.addConnection(
        address: address,
        isClient: true,
        rssi: rssi,
      );

      _logger.info(
        '✅ Connected to ${_formatAddress(address)} @${DateTime.now().toIso8601String()} (client connections: $clientConnectionCount/${_limitConfig.maxClientConnections})',
      );
      _logger.info(
        '📊 Total connections: $totalConnectionCount (client: $clientConnectionCount, server: $serverConnectionCount)',
      );

      onConnectionChanged?.call(device);

      final mtu = await _gattController.detectOptimalMtu(
        device: device,
        formattedAddress: _formatAddress(address),
      );
      final mtuConnection = _clientConnections[address];
      if (mtuConnection != null) {
        _clientConnections[address] = mtuConnection.copyWith(mtu: mtu);
      }
      onMtuDetected?.call(mtu);

      final messageChar = await _gattController.discoverMessageCharacteristic(
        device: device,
        formattedAddress: _formatAddress(address),
      );

      connection = _clientConnections[address]!.copyWith(
        messageCharacteristic: messageChar,
      );
      _clientConnections[address] = connection;

      onCharacteristicFound?.call(messageChar);

      if (messageChar.properties.contains(GATTCharacteristicProperty.notify)) {
        try {
          await _gattController.enableNotifications(
            device: device,
            characteristic: messageChar,
            formattedAddress: _formatAddress(address),
          );
        } catch (e) {
          final hasInbound =
              _serverConnections.containsKey(address) ||
              _deferredServerTeardown.contains(address);
          _logger.severe('CRITICAL: Failed to enable notifications: $e');
          if (hasInbound) {
            _logger.warning(
              '⏸️ Notify setup failed but inbound/deferral exists for ${_formatAddress(address)} — deferring to responder link instead of redialing',
            );
            _clientConnections.remove(address);
            _connectionTracker.removeConnection(address);
            try {
              await centralManager.disconnect(device);
            } catch (disconnectError) {
              _logger.warning(
                '⚠️ Failed to disconnect client after notify failure: $disconnectError',
              );
            }
            return;
          }
          throw Exception('Cannot enable notifications - connection unusable');
        }
      }

      _logger.info('🔐 BLE Connected - starting protocol setup');
      _updateConnectionState(ChatConnectionState.connecting);

      _logger.info('🔑 Triggering identity exchange');
      onConnectionComplete?.call();

      _isReconnection = false;
    } catch (e) {
      _logger.severe('❌ Connection failed: $e');
      _isReconnection = false;

      _clientConnections.remove(address);
      _connectionTracker.removeConnection(address);

      clearConnectionState(keepMonitoring: _serverConnections.isNotEmpty);
      rethrow;
    } finally {
      _pendingClientConnections.remove(address);
      if (_connectionTracker.isConnected(address)) {
        _connectionTracker.clearAttempt(address);
      } else {
        _clearPeerHintIfUnused(address);
      }
    }
  }

  Future<Peripheral?> _runtimeScanForSpecificDevice({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (centralManager.state != BluetoothLowEnergyState.poweredOn) {
      return null;
    }

    _logger.info('🔍 Scanning for service-advertising devices only');

    final completer = Completer<Peripheral?>();
    StreamSubscription? discoverySubscription;
    Timer? timeoutTimer;

    try {
      discoverySubscription = centralManager.discovered.listen((event) {
        _logger.info(
          '✅ Found device advertising our service: ${event.peripheral.uuid}',
        );
        if (!completer.isCompleted) {
          completer.complete(event.peripheral);
        }
      });

      timeoutTimer = Timer(timeout, () {
        if (!completer.isCompleted) {
          _logger.info('⏰ Service scan timeout');
          completer.complete(null);
        }
      });

      await Future.delayed(Duration(milliseconds: 500));

      await centralManager.startDiscovery(
        serviceUUIDs: [BLEConstants.serviceUUID],
      );

      return await completer.future;
    } finally {
      await centralManager.stopDiscovery();
      discoverySubscription?.cancel();
      timeoutTimer?.cancel();
    }
  }

  Future<void> _runtimeDisconnectAll() async {
    _logger.info('🔌 Disconnecting all connections');

    stopConnectionMonitoring();

    for (final conn in _clientConnections.values.toList()) {
      try {
        _logger.info(
          '🔌 Disconnecting client: ${_formatAddress(conn.address)}',
        );
        await centralManager.disconnect(conn.peripheral);
      } catch (e) {
        _logger.warning(
          '⚠️ Failed to disconnect ${_formatAddress(conn.address)}: $e',
        );
      }
    }

    await _stopAdvertising();
    clearConnectionState();
  }

  Future<void> _runtimeDisconnectClient(String address) async {
    final connection = _clientConnections[address];
    if (connection == null) {
      _logger.warning(
        '⚠️ Cannot disconnect: client not found ${_formatAddress(address)}',
      );
      return;
    }

    try {
      _logger.info('🔌 Disconnecting client: ${_formatAddress(address)}');
      await centralManager.disconnect(connection.peripheral);
      _clientConnections.remove(address);
      _connectionTracker.removeConnection(address);
      _peerHintsByAddress.remove(address);
      _logger.info('✅ Client disconnected: ${_formatAddress(address)}');
    } catch (e) {
      _logger.warning('⚠️ Failed to disconnect ${_formatAddress(address)}: $e');
      _clientConnections.remove(address);
      _connectionTracker.removeConnection(address);
      _peerHintsByAddress.remove(address);
    }
  }

  Future<void> _runtimeDisconnect() async {
    if (_clientConnections.isEmpty) {
      _logger.info('🔌 No connections to disconnect');
      clearConnectionState();
      return;
    }

    final firstConnection = _clientConnections.values.first;
    await disconnectClient(firstConnection.address);
  }

  void _runtimeTriggerReconnection() {
    if (!_healthMonitor.isMonitoring) {
      startConnectionMonitoring();
    } else {
      _healthMonitor.triggerImmediateReconnection();
    }
    _logger.info('Triggering immediate reconnection...');
  }

  void _runtimeClearConnectionState({
    bool keepMonitoring = false,
    String? contactId,
  }) {
    _logger.info('🧹 Clearing connection state');

    for (final timer in _deferredServerTeardownTimers.values) {
      timer.cancel();
    }
    _deferredServerTeardownTimers.clear();
    _deferredServerTeardown.clear();

    onCharacteristicFound?.call(null);
    onMtuDetected?.call(null);
    _healthMonitor.resetHandshakeFlags();

    if (contactId != null) {
      _cleanupEphemeralContactIfOrphaned(contactId);
    } else {
      for (final conn in _clientConnections.values) {
        _cleanupEphemeralContactIfOrphaned(conn.address);
      }
    }

    _clientConnections.clear();
    if (!keepMonitoring) {
      _serverConnections.clear();
      _connectionTracker.clear();
    } else {
      _connectionTracker.clear();
      for (final entry in _serverConnections.entries) {
        _connectionTracker.addConnection(address: entry.key, isClient: false);
      }
    }
    _peerHintsByAddress.clear();
    _blockedResponderHandshakes.clear();
    _noHintInboundDebounceUntil = null;
    _lastConnectedDevice = null;

    _isReconnection = false;

    _logger.info('📊 Connections cleared (client: 0, server: 0)');
    _updateConnectionState(ChatConnectionState.disconnected);

    if (!keepMonitoring) {
      stopConnectionMonitoring();
    }

    onConnectionChanged?.call(null);
  }

  void _runtimeCleanupEphemeralContactIfOrphaned(String contactId) async {
    await EphemeralContactCleaner.cleanup(
      contactId: contactId,
      logger: _logger,
    );
  }

  bool _runtimeHasViableRelayConnection() {
    try {
      if (!hasConnection || _connectedDevice == null) {
        return false;
      }

      if (_clientConnections.isNotEmpty &&
          (_healthMonitor.isHandshakeInProgress ||
              _healthMonitor.awaitingHandshake)) {
        _logger.fine(
          '⏸️ Treating client link as viable while handshake is in flight to avoid reconnection churn',
        );
        return true;
      }

      if (_messageCharacteristic == null) {
        return false;
      }

      if (!_isReady) {
        return false;
      }

      _logger.info(
        '🔄 Viable relay connection detected: ${_connectedDevice?.uuid}',
      );
      return true;
    } catch (e) {
      _logger.warning('Error checking relay viability: $e');
      return false;
    }
  }

  void _runtimeDispose() {
    stopConnectionMonitoring();
    _serverConnectionsController.close();
  }
}
