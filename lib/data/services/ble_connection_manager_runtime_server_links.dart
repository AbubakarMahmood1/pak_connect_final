part of 'ble_connection_manager.dart';

extension _BleConnectionManagerRuntimeServerLinks on BLEConnectionManager {
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

  Future<bool> _runtimeHandleCentralConnected(Central central) async {
    final address = central.uuid.toString();
    _trackPeerHintForAddress(address);
    final peerHint = _peerHintForAddress(address);
    final hasClientForPeer = hasClientLinkForPeer(address);
    final pendingClientForPeer = hasPendingClientForPeer(address);
    final hasServerForPeer = hasServerLinkForPeer(address);
    final hasHintCollision = hasAnyLinkForPeerHint(peerHint);

    if (hasServerForPeer ||
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
      return false;
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
      return false;
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
    return _serverConnections.containsKey(address);
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
}
