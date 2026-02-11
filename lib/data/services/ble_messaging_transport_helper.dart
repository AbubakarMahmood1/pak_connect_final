part of 'ble_messaging_service.dart';

class _BleMessagingTransportHelper {
  _BleMessagingTransportHelper(this._owner);

  final BLEMessagingService _owner;

  Future<void> sendBinaryPayload({
    required Uint8List data,
    required int originalType,
    String? recipientId,
  }) async {
    // Encryption is required for all binary payloads
    if (recipientId == null || recipientId.isEmpty) {
      _owner._logger.severe(
        '❌ SEND ABORTED: Cannot send binary payload without recipient ID (encryption required)',
      );
      throw Exception('Cannot send binary payload without recipient ID');
    }

    final payload = await SecurityServiceLocator.instance.encryptBinaryPayload(
      data,
      recipientId,
      _owner._contactRepository,
    );

    final mtuSize =
        _owner._connectionManager.mtuSize ?? BLEConstants.maxMessageLength;
    final fragments = BinaryFragmenter.fragment(
      data: payload,
      mtu: mtuSize,
      originalType: originalType,
      recipient: recipientId,
    );

    final completer = Completer<void>();

    _owner._writeQueue.add(() async {
      try {
        if (_owner._connectionManager.hasBleConnection &&
            _owner._connectionManager.messageCharacteristic != null) {
          final device = _owner._connectionManager.connectedDevice!;
          final characteristic =
              _owner._connectionManager.messageCharacteristic!;
          for (var i = 0; i < fragments.length; i++) {
            await _owner._getCentralManager().writeCharacteristic(
              device,
              characteristic,
              value: fragments[i],
              type: GATTCharacteristicWriteType.withResponse,
            );
            if (i < fragments.length - 1) {
              await Future.delayed(const Duration(milliseconds: 20));
            }
          }
        } else if (_owner._stateManager.isPeripheralMode &&
            _owner._getConnectedCentral() != null &&
            _owner._getPeripheralMessageCharacteristic() != null) {
          final connectedCentral = _owner._getConnectedCentral() as Central;
          final characteristic =
              _owner._getPeripheralMessageCharacteristic()
                  as GATTCharacteristic;
          for (var i = 0; i < fragments.length; i++) {
            await _owner._getPeripheralManager().notifyCharacteristic(
              connectedCentral,
              characteristic,
              value: fragments[i],
            );
            if (i < fragments.length - 1) {
              await Future.delayed(const Duration(milliseconds: 20));
            }
          }
        } else {
          throw Exception('No BLE link available to send binary payload');
        }

        completer.complete();
      } catch (e) {
        _owner._logger.warning('⚠️ Binary payload send failed: $e');
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      }
    });

    unawaited(processWriteQueue());

    return completer.future;
  }

  void forwardBinaryFragment({
    required Uint8List data,
    required String fragmentId,
    required int fragmentIndex,
    required String fromDeviceId,
    required String fromNodeId,
  }) {
    ForwardReassembledPayload? reassembled;

    if (fromNodeId.isNotEmpty) {
      _owner._nodeIdToAddress[fromNodeId] = fromDeviceId;
    }
    _owner._writeQueue.add(() async {
      // Forward over any active client connection
      final clientConns = _owner._connectionManager.clientConnections;
      for (final conn in clientConns) {
        if (shouldSkipForward(
          toAddress: conn.address,
          fromPeerAddress: fromDeviceId,
          fromPeerId: fromNodeId,
        )) {
          continue;
        }
        final characteristic = conn.messageCharacteristic;
        if (characteristic == null) continue;
        final mtuBudget = (conn.mtu ?? BLEConstants.maxMessageLength).clamp(
          20,
          517,
        );
        if (data.length > mtuBudget) {
          reassembled ??= _owner._messageHandler.takeForwardReassembledPayload(
            fragmentId,
          );
          if (reassembled == null) {
            _owner._logger.fine(
              '⚠️ Forward (client) dropped: fragment ${data.length}B exceeds MTU $mtuBudget and no reassembled payload (${conn.address})',
            );
            continue;
          }
          final ttlOut = (reassembled!.ttl - 1).clamp(0, 255);
          if (ttlOut <= 0) {
            _owner._logger.fine(
              '⚠️ Forward (client) dropped: TTL exhausted for $fragmentId on ${conn.address}',
            );
            continue;
          }
          final frags = BinaryFragmenter.fragment(
            data: reassembled!.bytes,
            mtu: mtuBudget,
            originalType: reassembled!.originalType,
            recipient: reassembled!.recipient,
            ttl: ttlOut,
          );
          try {
            for (var i = 0; i < frags.length; i++) {
              await _owner._getCentralManager().writeCharacteristic(
                conn.peripheral,
                characteristic,
                value: frags[i],
                type: GATTCharacteristicWriteType.withResponse,
              );
              if (i < frags.length - 1) {
                await Future.delayed(const Duration(milliseconds: 10));
              }
            }
          } catch (e) {
            _owner._logger.fine(
              '⚠️ Forward (client) re-fragmented send failed: $e',
            );
          }
          continue;
        }
        try {
          // Decrement TTL byte before forwarding to enforce hop cap.
          final forwarded = Uint8List.fromList(data);
          if (forwarded.length > 10) {
            // TTL is after: magic(1) + fragmentId(8) + index/total(4) => offset 13
            const ttlOffset = 1 + 8 + 4;
            forwarded[ttlOffset] = (forwarded[ttlOffset] - 1) & 0xFF;
          }
          await _owner._getCentralManager().writeCharacteristic(
            conn.peripheral,
            characteristic,
            value: forwarded,
            type: GATTCharacteristicWriteType.withResponse,
          );
          await Future.delayed(const Duration(milliseconds: 10));
        } catch (e) {
          _owner._logger.fine('⚠️ Forward (client) failed: $e');
        }
      }

      // Forward over peripheral side if connected
      if (_owner._stateManager.isPeripheralMode &&
          _owner._getConnectedCentral() != null &&
          _owner._getPeripheralMessageCharacteristic() != null) {
        try {
          final connectedCentral = _owner._getConnectedCentral() as Central;
          final characteristic =
              _owner._getPeripheralMessageCharacteristic()
                  as GATTCharacteristic;
          final negotiatedMtu =
              (_owner._getPeripheralNegotiatedMtu() as int?) ?? 20;
          final mtuBudget = negotiatedMtu.clamp(20, 517);
          if (data.length > mtuBudget) {
            reassembled ??= _owner._messageHandler
                .takeForwardReassembledPayload(fragmentId);
            if (reassembled == null) {
              _owner._logger.fine(
                '⚠️ Forward (peripheral) dropped: fragment ${data.length}B exceeds MTU $mtuBudget and no reassembled payload (${connectedCentral.uuid})',
              );
              return;
            }
            final ttlOut = (reassembled!.ttl - 1).clamp(0, 255);
            if (ttlOut <= 0) {
              _owner._logger.fine(
                '⚠️ Forward (peripheral) dropped: TTL exhausted for $fragmentId on ${connectedCentral.uuid}',
              );
              return;
            }
            final frags = BinaryFragmenter.fragment(
              data: reassembled!.bytes,
              mtu: mtuBudget,
              originalType: reassembled!.originalType,
              recipient: reassembled!.recipient,
              ttl: ttlOut,
            );
            try {
              for (var i = 0; i < frags.length; i++) {
                await _owner._getPeripheralManager().notifyCharacteristic(
                  connectedCentral,
                  characteristic,
                  value: frags[i],
                );
                if (i < frags.length - 1) {
                  await Future.delayed(const Duration(milliseconds: 10));
                }
              }
            } catch (e) {
              _owner._logger.fine(
                '⚠️ Forward (peripheral) re-fragmented send failed: $e',
              );
            }
            return;
          }
          if (shouldSkipForward(
            toAddress: connectedCentral.uuid.toString(),
            fromPeerAddress: fromDeviceId,
            fromPeerId: fromNodeId,
          )) {
            return;
          }
          // Decrement TTL byte before forwarding to enforce hop cap.
          final forwarded = Uint8List.fromList(data);
          if (forwarded.length > 10) {
            const ttlOffset = 1 + 8 + 4;
            forwarded[ttlOffset] = (forwarded[ttlOffset] - 1) & 0xFF;
          }
          await _owner._getPeripheralManager().notifyCharacteristic(
            connectedCentral,
            characteristic,
            value: forwarded,
          );
          await Future.delayed(const Duration(milliseconds: 10));
        } catch (e) {
          _owner._logger.fine('⚠️ Forward (peripheral) failed: $e');
        }
      }
    });
    unawaited(processWriteQueue());
  }

  bool shouldSkipForward({
    required String toAddress,
    required String fromPeerAddress,
    required String fromPeerId,
  }) {
    if (toAddress == fromPeerAddress) return true;
    final dedup = DeviceDeduplicationManager.getDevice(toAddress);
    final peerId = dedup?.contactInfo?.publicKey ?? dedup?.ephemeralHint;
    if (peerId != null && peerId == fromPeerAddress) return true;
    if (peerId != null && peerId == fromPeerId) return true;
    if (fromPeerId.isNotEmpty && dedup?.ephemeralHint == fromPeerId) {
      return true;
    }
    final mappedAddress = _owner._nodeIdToAddress[fromPeerId];
    if (mappedAddress != null && mappedAddress == toAddress) return true;
    return false;
  }

  Future<void> sendProtocolMessage(ProtocolMessage message) async {
    // 🔧 CRITICAL FIX: Protocol messages must be fragmented like user messages
    // ProtocolMessage.toBytes() returns binary data (compressed or uncompressed)
    // This CANNOT be sent directly to BLE - it must be:
    // 1. Fragmented into MTU-sized chunks
    // 2. Base64-encoded for text transmission
    // 3. Sent with proper headers for reassembly

    // Add write to queue to serialize operations
    final completer = Completer<void>();

    _owner._writeQueue.add(() async {
      final isHandshakeMessage =
          message.type == ProtocolMessageType.connectionReady ||
          message.type == ProtocolMessageType.identity ||
          message.type == ProtocolMessageType.noiseHandshake1 ||
          message.type == ProtocolMessageType.noiseHandshake2 ||
          message.type == ProtocolMessageType.noiseHandshake3 ||
          message.type == ProtocolMessageType.noiseHandshakeRejected ||
          message.type == ProtocolMessageType.contactStatus;

      try {
        bool peripheralNotifyReady() {
          try {
            final central = _owner._getConnectedCentral() as Central?;
            final characteristic =
                _owner._getPeripheralMessageCharacteristic()
                    as GATTCharacteristic?;
            if (central == null || characteristic == null) return false;
            BLEServerConnection? serverConn;
            try {
              serverConn = _owner._connectionManager.serverConnections
                  .firstWhere((c) => c.address == central.uuid.toString());
            } catch (_) {}
            final subscribed = serverConn?.subscribedCharacteristic;
            if (subscribed == null) return false;
            return subscribed.uuid == characteristic.uuid;
          } catch (_) {
            return false;
          }
        }

        Future<bool> waitForPeripheralNotifyReady({
          Duration timeout = const Duration(milliseconds: 1200),
        }) async {
          final deadline = DateTime.now().add(timeout);
          while (DateTime.now().isBefore(deadline)) {
            if (peripheralNotifyReady()) return true;
            await Future.delayed(const Duration(milliseconds: 50));
          }
          return peripheralNotifyReady();
        }

        // Bail out early if neither central nor peripheral link is usable.
        final hasCentralLink =
            _owner._connectionManager.hasBleConnection &&
            _owner._connectionManager.messageCharacteristic != null;
        final hasPeripheralLink =
            _owner._stateManager.isPeripheralMode &&
            _owner._getConnectedCentral() != null &&
            _owner._getPeripheralMessageCharacteristic() != null;

        // For handshake control frames we must avoid stale handles. If we are in
        // peripheral mode and have a fresh inbound link, prefer that path even
        // if an old client connection still exists.
        Future<void> sendUnfragmented(Uint8List value) async {
          if (isHandshakeMessage && hasPeripheralLink) {
            final connectedCentral = _owner._getConnectedCentral() as Central;
            final characteristic =
                _owner._getPeripheralMessageCharacteristic()
                    as GATTCharacteristic;
            await _owner._getPeripheralManager().notifyCharacteristic(
              connectedCentral,
              characteristic,
              value: value,
            );
            return;
          }

          if (hasCentralLink) {
            await _owner._getCentralManager().writeCharacteristic(
              _owner._connectionManager.connectedDevice!,
              _owner._connectionManager.messageCharacteristic!,
              value: value,
              type: GATTCharacteristicWriteType.withResponse,
            );
            return;
          }

          if (hasPeripheralLink) {
            final connectedCentral = _owner._getConnectedCentral() as Central;
            final characteristic =
                _owner._getPeripheralMessageCharacteristic()
                    as GATTCharacteristic;
            await _owner._getPeripheralManager().notifyCharacteristic(
              connectedCentral,
              characteristic,
              value: value,
            );
            return;
          }

          throw Exception('No BLE link available to send payload');
        }

        if (!hasCentralLink && !hasPeripheralLink) {
          final msg =
              'No usable BLE link (central=$hasCentralLink, peripheral=$hasPeripheralLink, state=${_owner._connectionManager.connectionState.name})';
          _owner._logger.warning('⚠️ Protocol message send skipped: $msg');
          if (isHandshakeMessage) {
            _owner._isProcessingWriteQueue = false;
            completer.completeError(HandshakeSendException(msg));
            return;
          }
          completer.complete();
          return;
        }

        if (isHandshakeMessage &&
            hasPeripheralLink &&
            !peripheralNotifyReady()) {
          _owner._logger.fine(
            '⏳ Waiting for peripheral notify subscription before sending handshake...',
          );
          final ready = await waitForPeripheralNotifyReady();
          if (!ready) {
            final msg = 'Responder notify not enabled for handshake path';
            _owner._logger.warning('⚠️ Handshake send blocked: $msg');
            _owner._logger.warning(
              '⚠️ No inbound notify subscription detected within wait window; initiator may not be enabling notifications',
            );
            final reconnectAddress = _owner
                ._connectionManager
                .connectedDevice
                ?.uuid
                .toString();
            if (reconnectAddress != null) {
              _owner._logger.info(
                '🔁 Notify wait timed out — reconnecting client link $reconnectAddress',
              );
              unawaited(
                _owner._connectionManager
                    .disconnectClient(reconnectAddress)
                    .then((_) {
                      _owner._connectionManager.triggerReconnection();
                    }),
              );
            }
            _owner._isProcessingWriteQueue = false;
            completer.completeError(HandshakeSendException(msg));
            return;
          }
        }

        // Convert protocol message to bytes (may be compressed binary)
        final messageBytes = message.toBytes();

        // Get MTU size with fallback to safe default
        final mtuSize =
            _owner._connectionManager.mtuSize ?? BLEConstants.maxMessageLength;

        // Handshake fast-path: send control frames unfragmented when they fit MTU.
        if (isHandshakeMessage && messageBytes.length <= mtuSize) {
          _owner._logger.fine(
            '🤝 Handshake fast path (${message.type}) - sending unfragmented '
            '(${messageBytes.length} bytes <= MTU $mtuSize)',
          );

          await sendUnfragmented(messageBytes);

          completer.complete();
          return;
        }

        // Generate unique message ID for fragmentation
        final msgId =
            'proto_${message.type.name}_${DateTime.now().millisecondsSinceEpoch}';

        // Get MTU size with fallback to safe default (re-read after potential MTU change)
        final fragmentationMtu =
            _owner._connectionManager.mtuSize ?? BLEConstants.maxMessageLength;

        List<MessageChunk>? chunks;
        MessageChunk? singleChunk;
        var useBinaryEnvelope = false;
        try {
          chunks = MessageFragmenter.fragmentBytes(
            messageBytes,
            fragmentationMtu,
            msgId,
          );
          if (chunks.isEmpty) {
            useBinaryEnvelope = true;
          } else if (chunks.length == 1) {
            singleChunk = chunks.first;
          } else {
            useBinaryEnvelope = true;
          }
        } catch (e) {
          _owner._logger.fine(
            '⚠️ Protocol chunk fragmentation failed (fallback to binary envelope): $e',
          );
          useBinaryEnvelope = true;
        }

        _owner._logger.fine(
          '📦 Protocol message ${useBinaryEnvelope ? "using binary envelope" : "single-chunk fast path"}',
        );

        if (useBinaryEnvelope) {
          final recipientId = _owner._stateManager.getRecipientId();
          final fragments = BinaryFragmenter.fragment(
            data: messageBytes,
            mtu: fragmentationMtu,
            originalType: BinaryPayloadType.protocolMessage,
            recipient: recipientId,
          );

          for (int i = 0; i < fragments.length; i++) {
            await sendUnfragmented(fragments[i]);
            if (i < fragments.length - 1) {
              await Future.delayed(const Duration(milliseconds: 20));
            }
          }
        } else if (singleChunk != null) {
          // Single-chunk fast path to avoid binary envelope overhead.
          await sendUnfragmented(singleChunk.toBytes());
        }

        completer.complete();
      } catch (e, stack) {
        _owner._logger.warning('⚠️ Protocol message send failed: $e');
        _owner._logger.fine('Protocol send stacktrace: $stack');
        final isPlatformException =
            e is PlatformException &&
            (e.message?.contains('status: 133') == true ||
                e.message?.contains('IllegalArgumentException') == true);
        if (isPlatformException && isHandshakeMessage) {
          final msg =
              'Handshake write failed (platform status 133/IllegalArgument)';
          _owner._logger.warning(
            '⚠️ Detected platform write failure (status 133 / IllegalArgument) — aborting queue and awaiting reconnection',
          );
          _owner._isProcessingWriteQueue = false;
          completer.completeError(HandshakeSendException(msg));
          return;
        }
        // Guard against crashing the app when a platform write races with a
        // disconnect; treat it as a transient failure and let the connection
        // manager recover.
        completer.completeError(e);
      }
    });

    // Process queue
    unawaited(processWriteQueue());

    return completer.future;
  }

  Future<void> processWriteQueue() async {
    if (_owner._isProcessingWriteQueue || _owner._writeQueue.isEmpty) return;

    _owner._isProcessingWriteQueue = true;

    while (_owner._writeQueue.isNotEmpty) {
      final write = _owner._writeQueue.removeAt(0);
      final hasCentralLink =
          _owner._connectionManager.hasBleConnection &&
          _owner._connectionManager.messageCharacteristic != null;
      final hasPeripheralLink =
          _owner._stateManager.isPeripheralMode &&
          _owner._getConnectedCentral() != null &&
          _owner._getPeripheralMessageCharacteristic() != null;
      if (!hasCentralLink && !hasPeripheralLink) {
        _owner._logger.warning(
          '⚠️ Aborting write queue; BLE connection not ready '
          '(central=$hasCentralLink, peripheral=$hasPeripheralLink, '
          'state=${_owner._connectionManager.connectionState.name})',
        );
        _owner._isProcessingWriteQueue = false;
        return;
      }
      try {
        await write();
      } catch (e) {
        // Write failed; stop processing so caller can handle.
        _owner._isProcessingWriteQueue = false;
        rethrow;
      }
      // Small delay between writes to prevent GATT overload
      await Future.delayed(const Duration(milliseconds: 50));
    }

    _owner._isProcessingWriteQueue = false;
  }
}
