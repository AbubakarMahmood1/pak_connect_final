part of 'ble_connection_manager.dart';

extension _BleConnectionManagerRuntimeCollisionPolicy on BLEConnectionManager {
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
      final localSummary = _summarizeCollisionToken(localToken);
      final remoteSummary = _summarizeCollisionToken(remoteToken);

      _logger.info(
        '⚖️ Collision tie-break token compare for ${_formatAddress(address)} '
        '(local=$localSummary, remote=$remoteSummary, '
        'comparison=$comparison, preferInbound=$preferInbound, '
        'inboundViable=$inboundViable)',
      );

      if (preferInbound && serverConn != null) {
        _logger.info(
          '⚖️ Collision tie-breaker: inbound preferred by token comparison',
        );
        if (!inboundViable) {
          _logger.info(
            '⚠️ Inbound not viable after wait for ${_formatAddress(address)} — keeping outbound link to preserve symmetry',
          );
          _logger.fine(
            '⏳ Inbound-preferred tie-break fallback keeps outbound link '
            '(suggested reconnect cooldown=${BleConnectionTracker.retryDelay.inSeconds}s)',
          );
          return false;
        }
        _logger.info(
          '⚖️ Collision tie-breaker: inbound viable and token-preferred — yielding to inbound',
        );
        return true;
      }

      _logger.info(
        '⚖️ Collision tie-breaker: keeping client link '
        '(local=$localSummary, remote=$remoteSummary)',
      );
      return false;
    } catch (e) {
      _logger.warning(
        '⚖️ Collision tie-breaker failed ($address): $e — keeping client link',
      );
      return false;
    }
  }

  String _summarizeCollisionToken(String token) =>
      token.length <= 12 ? token : '${token.substring(0, 8)}...';
}
