part of 'ble_connection_manager.dart';

extension _BleConnectionManagerRuntimeClientLinks on BLEConnectionManager {
  Future<void> _runtimeConnectToDevice(
    Peripheral device, {
    int? rssi,
    int? schedulerAttemptId,
  }) async {
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
      final retryBackoffRemaining = _connectionTracker.retryBackoffRemaining(
        address,
      );
      final retryBackoffNextAllowed = _connectionTracker.nextAllowedAttemptAt(
        address,
      );
      final disconnectCooldownRemaining = _connectionTracker
          .disconnectCooldownRemaining(address);
      final disconnectCooldownUntil = _connectionTracker
          .disconnectCooldownUntil(address);
      final attemptsInWindow = _connectionTracker.pendingAttemptCount(address);
      final blockingReason =
          disconnectCooldownRemaining != null &&
              disconnectCooldownRemaining > Duration.zero
          ? 'post-disconnect-cooldown'
          : 'attempt-backoff';
      _logger.fine(
        '⏳ Backing off reconnect to ${_formatAddress(address)} '
        '(reason=$blockingReason, '
        'retryRemaining=${retryBackoffRemaining?.inMilliseconds ?? 0}ms, '
        'attempts=$attemptsInWindow, '
        'retryNextAllowed=${retryBackoffNextAllowed?.toIso8601String() ?? "n/a"}, '
        'disconnectRemaining=${disconnectCooldownRemaining?.inMilliseconds ?? 0}ms, '
        'disconnectUntil=${disconnectCooldownUntil?.toIso8601String() ?? "n/a"})',
      );
      return;
    }
    if (_pendingClientConnections.contains(address)) {
      _logger.fine(
        '↻ Already connecting to ${_formatAddress(address)} - ignoring duplicate request',
      );
      return;
    }
    // Only count real attempts: marking before the duplicate check inflated
    // backoff state for requests that never dialed.
    _connectionTracker.markAttempt(address);
    final attemptId = _beginClientAttempt(address);

    try {
      Future<bool> ensureCurrentAttempt(
        String stage, {
        bool disconnectIfStale = false,
      }) async {
        if (_isClientAttemptCurrent(address, attemptId)) {
          return true;
        }
        _logger.fine(
          'Ignoring stale client attempt#$attemptId for '
          '${_formatAddress(address)} during $stage',
        );
        if (disconnectIfStale) {
          try {
            await centralManager.disconnect(device);
          } catch (_) {
            // Best-effort stale cleanup.
          }
        }
        return false;
      }

      _pendingClientConnections.add(address);
      if (!await ensureCurrentAttempt('preflight')) return;

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
      if (!await ensureCurrentAttempt('post-connect-delay')) return;

      await _gattController.connectWithRetry(
        device: device,
        formattedAddress: _formatAddress(address),
      );
      if (!await ensureCurrentAttempt(
        'post-gatt-connect',
        disconnectIfStale: true,
      )) {
        return;
      }

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
          if (!await ensureCurrentAttempt('post-collision-cleanup')) return;
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
      if (!await ensureCurrentAttempt(
        'post-mtu-detect',
        disconnectIfStale: true,
      )) {
        return;
      }
      final mtuConnection = _clientConnections[address];
      if (mtuConnection != null) {
        _clientConnections[address] = mtuConnection.copyWith(mtu: mtu);
      }
      onMtuDetected?.call(mtu);
      onClientMtuReady?.call(address, mtu, schedulerAttemptId);

      final messageChar = await _gattController.discoverMessageCharacteristic(
        device: device,
        formattedAddress: _formatAddress(address),
      );
      if (!await ensureCurrentAttempt(
        'post-characteristic-discovery',
        disconnectIfStale: true,
      )) {
        return;
      }

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
          onClientNotifySubscribed?.call(address, schedulerAttemptId);
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
      if (!await ensureCurrentAttempt('post-notification-setup')) return;

      _logger.info('🔐 BLE Connected - starting protocol setup');
      _updateConnectionState(ChatConnectionState.connecting);

      _logger.info('🔑 Triggering identity exchange');
      onConnectionComplete?.call(address, schedulerAttemptId);

      _isReconnection = false;
    } catch (e) {
      _logger.severe('❌ Connection failed: $e');
      _isReconnection = false;

      if (_isClientAttemptCurrent(address, attemptId)) {
        _clientConnections.remove(address);
        _connectionTracker.removeConnection(address);
        clearConnectionState(
          keepMonitoring:
              _healthMonitor.isMonitoring || _serverConnections.isNotEmpty,
        );
      } else {
        _logger.fine(
          'Skipping stale failure cleanup for client attempt#$attemptId '
          '(${_formatAddress(address)})',
        );
      }
      rethrow;
    } finally {
      if (_isClientAttemptCurrent(address, attemptId)) {
        _pendingClientConnections.remove(address);
        _endClientAttempt(address, attemptId);
        if (_connectionTracker.isConnected(address)) {
          _connectionTracker.clearAttempt(address);
        } else {
          _clearPeerHintIfUnused(address);
        }
      } else {
        _logger.fine(
          'Skipping stale finalizer for client attempt#$attemptId '
          '(${_formatAddress(address)})',
        );
      }
    }
  }

  Future<Peripheral?> _runtimeScanForSpecificDevice({
    Duration timeout = const Duration(seconds: 10),
    String? expectedPeripheralUuid,
  }) async {
    if (centralManager.state != BluetoothLowEnergyState.poweredOn) {
      return null;
    }

    _logger.info(
      expectedPeripheralUuid == null
          ? '🔍 Scanning for service-advertising devices only'
          : '🔍 Scanning for reconnect target $expectedPeripheralUuid',
    );

    final completer = Completer<Peripheral?>();
    StreamSubscription? discoverySubscription;
    Timer? timeoutTimer;
    final deadline = DateTime.now().add(timeout);

    Duration remainingTime() {
      final remaining = deadline.difference(DateTime.now());
      return remaining.isNegative ? Duration.zero : remaining;
    }

    Future<void> runBoundedCleanup(
      Future<void> Function() operation,
      String label,
    ) async {
      final remaining = remainingTime();
      final budget = remaining > const Duration(seconds: 1)
          ? const Duration(seconds: 1)
          : (remaining == Duration.zero
                ? const Duration(milliseconds: 1)
                : remaining);
      try {
        await operation().timeout(budget);
      } catch (error) {
        _logger.warning('Reconnect scan $label cleanup failed: $error');
      }
    }

    try {
      discoverySubscription = centralManager.discovered.listen((event) {
        final discoveredUuid = event.peripheral.uuid.toString();
        if (expectedPeripheralUuid != null &&
            discoveredUuid.toLowerCase() !=
                expectedPeripheralUuid.toLowerCase()) {
          _logger.fine(
            'Ignoring nonmatching reconnect advertiser: $discoveredUuid',
          );
          return;
        }
        _logger.info('✅ Found device advertising our service: $discoveredUuid');
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

      if (expectedPeripheralUuid == null) {
        final remaining = remainingTime();
        final delay = remaining > const Duration(milliseconds: 500)
            ? const Duration(milliseconds: 500)
            : remaining;
        await Future<void>.delayed(delay);
      }

      if (!completer.isCompleted) {
        final startBudget = remainingTime();
        if (startBudget == Duration.zero) {
          completer.complete(null);
        } else {
          await centralManager
              .startDiscovery(serviceUUIDs: [BLEConstants.serviceUUID])
              .timeout(
                startBudget,
                onTimeout: () {
                  if (!completer.isCompleted) {
                    completer.complete(null);
                  }
                },
              );
        }
      }

      return await completer.future;
    } finally {
      timeoutTimer?.cancel();
      await runBoundedCleanup(
        () => centralManager.stopDiscovery(),
        'stop-discovery',
      );
      final subscription = discoverySubscription;
      if (subscription != null) {
        await runBoundedCleanup(subscription.cancel, 'subscription');
      }
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
}
