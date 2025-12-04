import 'dart:async';
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../../core/interfaces/i_ble_messaging_service.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../core/utils/message_fragmenter.dart';
import '../../core/utils/binary_fragmenter.dart';
import '../../core/constants/binary_payload_types.dart';
import '../../core/interfaces/i_ble_message_handler_facade.dart';
import '../../core/interfaces/i_message_fragmentation_handler.dart';
import '../../core/messaging/media_transfer_store.dart';
import 'ble_connection_manager.dart';
import '../../core/constants/ble_constants.dart';
import '../../core/interfaces/i_ble_state_manager_facade.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import '../../core/services/security_manager.dart';
import 'ble_state_manager_facade.dart';
import 'ble_state_manager.dart';

// Type aliases for better clarity
typedef CentralManagerType = CentralManager;
typedef PeripheralManagerType = PeripheralManager;

/// Manages BLE message transmission and reception.
///
/// Phase 2A Migration: Extracted from BLEService
///
/// Responsibility: Handle all messaging-related operations
/// - Chat message encryption and sending (central & peripheral modes)
/// - Protocol message fragmentation and write queue serialization
/// - Message decryption and event emission
/// - Identity exchange protocol messages
class BLEMessagingService implements IBLEMessagingService {
  final _logger = Logger('BLEMessagingService');

  // Dependencies (injected)
  final IBLEMessageHandlerFacade _messageHandler;
  final BLEConnectionManager _connectionManager;
  final IBLEStateManagerFacade _stateManager;
  final ContactRepository _contactRepository;
  final CentralManager Function() _getCentralManager;
  final PeripheralManager Function() _getPeripheralManager;

  // State (provided by facade)
  final Set<void Function(String)> _messageListeners = {};
  final Set<void Function(BinaryPayload)> _binaryListeners = {};
  final MediaTransferStore _mediaStore = MediaTransferStore();
  String? extractedMessageId;

  // Central/peripheral connection state (from facade)
  final Function() _getConnectedCentral;
  final Function() _getPeripheralMessageCharacteristic;
  final Function() _getPeripheralMtuReady;
  final Function() _getPeripheralNegotiatedMtu;

  // Write queue for serialization
  final List<Future<void> Function()> _writeQueue = [];
  bool _isProcessingWriteQueue = false;
  final Map<String, String> _nodeIdToAddress = {};

  // Queue sync message handler (set by MeshNetworkingService)
  Future<bool> Function(QueueSyncMessage message, String fromNodeId)?
  _queueSyncMessageHandler;

  // Callbacks for facade coordination
  final Function(bool)? onMessageOperationChanged;

  BLEMessagingService({
    required IBLEMessageHandlerFacade messageHandler,
    required BLEConnectionManager connectionManager,
    required IBLEStateManagerFacade stateManager,
    required ContactRepository contactRepository,
    required CentralManager Function() getCentralManager,
    required PeripheralManager Function() getPeripheralManager,
    required Function() getConnectedCentral,
    required Function() getPeripheralMessageCharacteristic,
    required Function() getPeripheralMtuReady,
    required Function() getPeripheralNegotiatedMtu,
    this.onMessageOperationChanged,
  }) : _messageHandler = messageHandler,
       _connectionManager = connectionManager,
       _stateManager = stateManager,
       _contactRepository = contactRepository,
       _getCentralManager = getCentralManager,
       _getPeripheralManager = getPeripheralManager,
       _getConnectedCentral = getConnectedCentral,
       _getPeripheralMessageCharacteristic = getPeripheralMessageCharacteristic,
       _getPeripheralMtuReady = getPeripheralMtuReady,
       _getPeripheralNegotiatedMtu = getPeripheralNegotiatedMtu {
    // Relay messages from handler into internal listeners.
    _messageHandler.onRelayMessageReceived =
        (String _, String content, String __) {
          _emitReceivedMessage(content);
        };

    // Forward binary fragments hop-by-hop; reassembly happens only at recipient.
    _messageHandler.onForwardBinaryFragment =
        (
          Uint8List data,
          String fragmentId,
          int index,
          String fromDeviceId,
          String fromNodeId,
        ) {
          _forwardBinaryFragment(
            data: data,
            fragmentId: fragmentId,
            fragmentIndex: index,
            fromDeviceId: fromDeviceId,
            fromNodeId: fromNodeId,
          );
        };

    _messageHandler.onBinaryPayloadReceived =
        (
          Uint8List data,
          int originalType,
          String fragmentId,
          int ttl,
          String? recipient,
          String? senderNodeId,
        ) {
          _emitReceivedBinaryPayload(
            BinaryPayload(
              data: data,
              originalType: originalType,
              fragmentId: fragmentId,
              ttl: ttl,
              recipient: recipient,
              senderNodeId: senderNodeId,
            ),
          );
        };
  }

  // ============================================================================
  // MESSAGE SENDING (CENTRAL ROLE)
  // ============================================================================
  @override
  Future<bool> sendMessage(
    String message, {
    String? messageId,
    String? originalIntendedRecipient,
  }) async {
    if (!_connectionManager.hasBleConnection ||
        _connectionManager.messageCharacteristic == null) {
      throw Exception('Not connected to any device');
    }

    final recipientId = _stateManager.getRecipientId();
    final isPaired = _stateManager.isPaired;
    final idType = _stateManager.getIdType();

    if (recipientId != null) {
      final truncatedId = recipientId.length > 16
          ? recipientId.substring(0, 16)
          : recipientId;
      _logger.info(
        '📤 STEP 7: Sending message using $idType ID: $truncatedId...',
      );
    }

    return await _messageHandler.sendMessage(
      recipientKey: recipientId ?? '',
      content: message,
      timeout: Duration(seconds: 5),
      messageId: messageId,
      originalIntendedRecipient: originalIntendedRecipient,
    );
  }

  @override
  Future<bool> sendPeripheralMessage(
    String message, {
    String? messageId,
  }) async {
    if (!_stateManager.isPeripheralMode) {
      throw Exception('Not in peripheral mode');
    }

    // For peripheral mode, we need to find the connected central and characteristic
    final connectedCentral = _getConnectedCentral() as Central?;
    final messageCharacteristic =
        _getPeripheralMessageCharacteristic() as GATTCharacteristic?;

    if (connectedCentral == null || messageCharacteristic == null) {
      throw Exception('No central connected or characteristic not found');
    }

    // 🔧 FIX: Wait for MTU negotiation before sending
    final peripheralMtuReady = _getPeripheralMtuReady() as bool;
    final peripheralNegotiatedMtu = _getPeripheralNegotiatedMtu() as int?;

    if (!peripheralMtuReady && peripheralNegotiatedMtu == null) {
      _logger.info('⏳ Waiting for MTU negotiation (up to 2 seconds)...');
      // Check every 50ms for faster response (40 iterations = 2 seconds max)
      for (int i = 0; i < 40; i++) {
        if (_getPeripheralMtuReady() as bool ||
            _getPeripheralNegotiatedMtu() != null) {
          _logger.info('✅ MTU ready after ${i * 50}ms wait');
          break; // Exit immediately when ready
        }
        await Future.delayed(Duration(milliseconds: 50));
      }

      if (!(_getPeripheralMtuReady() as bool) &&
          _getPeripheralNegotiatedMtu() == null) {
        _logger.warning(
          '⚠️ MTU negotiation timeout - proceeding with default 20 bytes',
        );
      }
    }

    // Use the negotiated MTU from central connection
    int mtuSize = (_getPeripheralNegotiatedMtu() as int?) ?? 20;
    _logger.info('📡 Peripheral sending with MTU: $mtuSize bytes');

    // STEP 7: Get appropriate recipient ID (ephemeral or persistent)
    final recipientId = _stateManager.getRecipientId();
    final isPaired = _stateManager.isPaired;
    final idType = _stateManager.getIdType();

    if (recipientId != null) {
      final truncatedId = recipientId.length > 16
          ? recipientId.substring(0, 16)
          : recipientId;
      _logger.info(
        '📤 STEP 7 (Peripheral): Sending message using $idType ID: $truncatedId...',
      );
    }

    return await _messageHandler.sendPeripheralMessage(
      senderKey: recipientId ?? '',
      content: message,
      messageId: messageId,
    );
  }

  @override
  Future<void> sendQueueSyncMessage(QueueSyncMessage queueMessage) async {
    final protocolMessage = ProtocolMessage.queueSync(
      queueMessage: queueMessage,
    );
    await _sendProtocolMessage(protocolMessage);
  }

  // ============================================================================
  // IDENTITY EXCHANGE (PROTOCOL LEVEL)
  // ============================================================================

  @override
  Future<void> sendIdentityExchange() async {
    if (!_connectionManager.hasBleConnection ||
        _connectionManager.messageCharacteristic == null) {
      throw Exception('Cannot send identity exchange - not properly connected');
    }

    try {
      // CRITICAL: Ensure username is loaded before sending
      if (_stateManager.myUserName == null ||
          _stateManager.myUserName!.isEmpty) {
        _logger.info('Loading username before identity exchange...');
        await _stateManager.loadUserName();
      }

      if (_stateManager.myUserName == null ||
          _stateManager.myUserName!.isEmpty) {
        _logger.info('Loading username before identity exchange...');
        await _stateManager.loadUserName();
      }

      final myPublicKey = await _stateManager.getMyPersistentId();
      final displayName = _stateManager.myUserName ?? 'User';

      _logger.info('Sending identity exchange:');
      _logger.info(
        '  Public key: ${myPublicKey.length > 16 ? '${myPublicKey.substring(0, 16)}...' : myPublicKey}',
      );
      _logger.info('  Display name: $displayName');

      final protocolMessage = ProtocolMessage.identity(
        publicKey: myPublicKey,
        displayName: displayName,
      );

      await _getCentralManager().writeCharacteristic(
        _connectionManager.connectedDevice!,
        _connectionManager.messageCharacteristic!,
        value: protocolMessage.toBytes(),
        type: GATTCharacteristicWriteType.withResponse,
      );

      _logger.info(
        'Public key identity sent successfully with name: $displayName',
      );
    } catch (e) {
      _logger.severe('❌ Failed to send identity exchange: $e');
      rethrow;
    }
  }

  @override
  Future<void> sendPeripheralIdentityExchange() async {
    final connectedCentral = _getConnectedCentral() as Central?;
    final messageCharacteristic =
        _getPeripheralMessageCharacteristic() as GATTCharacteristic?;

    if (!_stateManager.isPeripheralMode ||
        connectedCentral == null ||
        messageCharacteristic == null) {
      _logger.warning(
        'Cannot send peripheral identity - not in peripheral mode or no central connected',
      );
      return;
    }

    try {
      // CRITICAL: Ensure username is loaded before sending
      if (_stateManager.myUserName == null ||
          _stateManager.myUserName!.isEmpty) {
        await _stateManager.loadUserName();
      }

      final myPublicKey = await _stateManager.getMyPersistentId();
      final displayName = _stateManager.myUserName ?? 'User';

      _logger.info('Sending peripheral identity re-exchange:');
      _logger.info(
        '  Public key: ${myPublicKey.length > 16 ? '${myPublicKey.substring(0, 16)}...' : myPublicKey}',
      );
      _logger.info('  Display name: $displayName');

      final protocolMessage = ProtocolMessage.identity(
        publicKey: myPublicKey,
        displayName: displayName,
      );

      await _getPeripheralManager().notifyCharacteristic(
        connectedCentral,
        messageCharacteristic,
        value: protocolMessage.toBytes(),
      );

      _logger.info('✅ Peripheral identity re-exchange sent successfully');
    } catch (e) {
      _logger.severe('❌ Peripheral identity re-exchange failed: $e');
      rethrow;
    }
  }

  @override
  Future<void> sendHandshakeMessage(ProtocolMessage message) async {
    try {
      // Use the existing queued write system to prevent concurrent writes
      await _sendProtocolMessage(message);
      _logger.fine('✅ Sent handshake message: ${message.type}');
    } catch (e) {
      _logger.severe('❌ Failed to send handshake message ${message.type}: $e');
      // Rethrow so handshake coordinator knows it failed
      rethrow;
    }
  }

  // ============================================================================
  // IDENTITY MANAGEMENT (USER-LEVEL)
  // ============================================================================

  @override
  Future<void> requestIdentityExchange() async {
    if (!_connectionManager.hasBleConnection ||
        _connectionManager.messageCharacteristic == null) {
      _logger.warning('Cannot request identity - not connected');
      return;
    }

    _logger.info('Manually requesting identity exchange');
    await sendIdentityExchange();
  }

  @override
  Future<void> triggerIdentityReExchange() async {
    _logger.info(
      '🔄 USERNAME PROPAGATION: Triggering identity re-exchange for updated username',
    );

    try {
      // Force reload username from storage to ensure we have the latest
      await _stateManager.loadUserName();

      // Re-send identity with updated username
      if (_stateManager.isPeripheralMode) {
        await sendPeripheralIdentityExchange();
      } else {
        await sendIdentityExchange();
      }

      _logger.info(
        '✅ USERNAME PROPAGATION: Identity re-exchange completed successfully',
      );
    } catch (e) {
      _logger.warning(
        '❌ USERNAME PROPAGATION: Identity re-exchange failed: $e',
      );
    }
  }

  // ============================================================================
  // PROTOCOL MESSAGE SENDING (INTERNAL)
  // ============================================================================

  /// Fragments and enqueues a binary payload for BLE transport.
  /// Attempts Noise encryption when a session is available; otherwise sends plaintext.
  Future<void> _sendBinaryPayload({
    required Uint8List data,
    required int originalType,
    String? recipientId,
  }) async {
    var payload = data;
    if (recipientId != null && recipientId.isNotEmpty) {
      try {
        payload = await SecurityManager.instance.encryptBinaryPayload(
          data,
          recipientId,
          _contactRepository,
        );
      } catch (e) {
        _logger.warning('⚠️ Binary payload encryption failed: $e');
      }
    }

    final mtuSize = _connectionManager.mtuSize ?? BLEConstants.maxMessageLength;
    final fragments = BinaryFragmenter.fragment(
      data: payload,
      mtu: mtuSize,
      originalType: originalType,
      recipient: recipientId,
    );

    final completer = Completer<void>();

    _writeQueue.add(() async {
      try {
        if (_connectionManager.hasBleConnection &&
            _connectionManager.messageCharacteristic != null) {
          final device = _connectionManager.connectedDevice!;
          final characteristic = _connectionManager.messageCharacteristic!;
          for (var i = 0; i < fragments.length; i++) {
            await _getCentralManager().writeCharacteristic(
              device,
              characteristic,
              value: fragments[i],
              type: GATTCharacteristicWriteType.withResponse,
            );
            if (i < fragments.length - 1) {
              await Future.delayed(Duration(milliseconds: 20));
            }
          }
        } else if (_stateManager.isPeripheralMode &&
            _getConnectedCentral() != null &&
            _getPeripheralMessageCharacteristic() != null) {
          final connectedCentral = _getConnectedCentral() as Central;
          final characteristic =
              _getPeripheralMessageCharacteristic() as GATTCharacteristic;
          for (var i = 0; i < fragments.length; i++) {
            await _getPeripheralManager().notifyCharacteristic(
              connectedCentral,
              characteristic,
              value: fragments[i],
            );
            if (i < fragments.length - 1) {
              await Future.delayed(Duration(milliseconds: 20));
            }
          }
        } else {
          throw Exception('No BLE link available to send binary payload');
        }

        completer.complete();
      } catch (e) {
        _logger.warning('⚠️ Binary payload send failed: $e');
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      }
    });

    _processWriteQueue();

    return completer.future;
  }

  void _forwardBinaryFragment({
    required Uint8List data,
    required String fragmentId,
    required int fragmentIndex,
    required String fromDeviceId,
    required String fromNodeId,
  }) {
    ForwardReassembledPayload? reassembled;

    if (fromNodeId.isNotEmpty) {
      _nodeIdToAddress[fromNodeId] = fromDeviceId;
    }
    _writeQueue.add(() async {
      // Forward over any active client connection
      final clientConns = _connectionManager.clientConnections;
      for (final conn in clientConns) {
        if (_shouldSkipForward(
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
          reassembled ??= _messageHandler.takeForwardReassembledPayload(
            fragmentId,
          );
          if (reassembled == null) {
            _logger.fine(
              '⚠️ Forward (client) dropped: fragment ${data.length}B exceeds MTU $mtuBudget and no reassembled payload (${conn.address})',
            );
            continue;
          }
          final ttlOut = (reassembled!.ttl - 1).clamp(0, 255);
          if (ttlOut <= 0) {
            _logger.fine(
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
              await _getCentralManager().writeCharacteristic(
                conn.peripheral,
                characteristic,
                value: frags[i],
                type: GATTCharacteristicWriteType.withResponse,
              );
              if (i < frags.length - 1) {
                await Future.delayed(Duration(milliseconds: 10));
              }
            }
          } catch (e) {
            _logger.fine('⚠️ Forward (client) re-fragmented send failed: $e');
          }
          continue;
        }
        try {
          await _getCentralManager().writeCharacteristic(
            conn.peripheral,
            characteristic,
            value: data,
            type: GATTCharacteristicWriteType.withResponse,
          );
          await Future.delayed(Duration(milliseconds: 10));
        } catch (e) {
          _logger.fine('⚠️ Forward (client) failed: $e');
        }
      }

      // Forward over peripheral side if connected
      if (_stateManager.isPeripheralMode &&
          _getConnectedCentral() != null &&
          _getPeripheralMessageCharacteristic() != null) {
        try {
          final connectedCentral = _getConnectedCentral() as Central;
          final characteristic =
              _getPeripheralMessageCharacteristic() as GATTCharacteristic;
          final negotiatedMtu = (_getPeripheralNegotiatedMtu() as int?) ?? 20;
          final mtuBudget = negotiatedMtu.clamp(20, 517);
          if (data.length > mtuBudget) {
            reassembled ??= _messageHandler.takeForwardReassembledPayload(
              fragmentId,
            );
            if (reassembled == null) {
              _logger.fine(
                '⚠️ Forward (peripheral) dropped: fragment ${data.length}B exceeds MTU $mtuBudget and no reassembled payload (${connectedCentral.uuid})',
              );
              return;
            }
            final ttlOut = (reassembled!.ttl - 1).clamp(0, 255);
            if (ttlOut <= 0) {
              _logger.fine(
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
                await _getPeripheralManager().notifyCharacteristic(
                  connectedCentral,
                  characteristic,
                  value: frags[i],
                );
                if (i < frags.length - 1) {
                  await Future.delayed(Duration(milliseconds: 10));
                }
              }
            } catch (e) {
              _logger.fine(
                '⚠️ Forward (peripheral) re-fragmented send failed: $e',
              );
            }
            return;
          }
          if (_shouldSkipForward(
            toAddress: connectedCentral.uuid.toString(),
            fromPeerAddress: fromDeviceId,
            fromPeerId: fromNodeId,
          )) {
            return;
          }
          await _getPeripheralManager().notifyCharacteristic(
            connectedCentral,
            characteristic,
            value: data,
          );
          await Future.delayed(Duration(milliseconds: 10));
        } catch (e) {
          _logger.fine('⚠️ Forward (peripheral) failed: $e');
        }
      }
    });
    _processWriteQueue();
  }

  bool _shouldSkipForward({
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
    final mappedAddress = _nodeIdToAddress[fromPeerId];
    if (mappedAddress != null && mappedAddress == toAddress) return true;
    return false;
  }

  /// Public helper for sending binary/media payloads over BLE.
  ///
  /// Returns [transferId] so the origin can retry with fresh fragmentation.
  /// Attempts to encrypt via Noise session before fragmenting; falls back to
  /// plaintext if no session is available.
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType = BinaryPayloadType.media,
    Map<String, dynamic>? metadata,
    bool persistOnly = false,
  }) async {
    final record = await _mediaStore.persist(
      data: data,
      metadata: {
        'recipientId': recipientId,
        'originalType': originalType,
        if (metadata != null) ...metadata,
      },
    );
    unawaited(_mediaStore.cleanupStaleTransfers());
    if (persistOnly) {
      return record.transferId;
    }
    await _sendBinaryPayload(
      data: record.bytes ?? data,
      originalType: originalType,
      recipientId: recipientId,
    );
    return record.transferId;
  }

  /// Retry a previously persisted binary payload using the latest MTU.
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  }) async {
    final record = await _mediaStore.load(transferId);
    if (record == null || record.bytes == null) {
      _logger.warning(
        '⚠️ Retry skipped - no stored payload for transferId=$transferId',
      );
      return false;
    }
    final targetRecipient =
        recipientId ?? record.metadata['recipientId'] as String?;
    if (targetRecipient == null || targetRecipient.isEmpty) {
      _logger.warning(
        '⚠️ Retry skipped - missing recipient for transferId=$transferId',
      );
      return false;
    }
    final type =
        originalType ??
        record.metadata['originalType'] as int? ??
        BinaryPayloadType.media;
    await _sendBinaryPayload(
      data: record.bytes!,
      originalType: type,
      recipientId: targetRecipient,
    );
    return true;
  }

  Future<void> _sendProtocolMessage(ProtocolMessage message) async {
    // 🔧 CRITICAL FIX: Protocol messages must be fragmented like user messages
    // ProtocolMessage.toBytes() returns binary data (compressed or uncompressed)
    // This CANNOT be sent directly to BLE - it must be:
    // 1. Fragmented into MTU-sized chunks
    // 2. Base64-encoded for text transmission
    // 3. Sent with proper headers for reassembly

    // Add write to queue to serialize operations
    final completer = Completer<void>();

    _writeQueue.add(() async {
      try {
        // Convert protocol message to bytes (may be compressed binary)
        final messageBytes = message.toBytes();

        // Generate unique message ID for fragmentation
        final msgId =
            'proto_${message.type.name}_${DateTime.now().millisecondsSinceEpoch}';

        // Get MTU size with fallback to safe default
        final mtuSize =
            _connectionManager.mtuSize ?? BLEConstants.maxMessageLength;

        List<MessageChunk>? chunks;
        MessageChunk? singleChunk;
        var useBinaryEnvelope = false;
        try {
          chunks = MessageFragmenter.fragmentBytes(
            messageBytes,
            mtuSize,
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
          _logger.fine(
            '⚠️ Protocol chunk fragmentation failed (fallback to binary envelope): $e',
          );
          useBinaryEnvelope = true;
        }

        _logger.fine(
          '📦 Protocol message ${useBinaryEnvelope ? "using binary envelope" : "single-chunk fast path"}',
        );

        if (useBinaryEnvelope) {
          final recipientId = _stateManager.getRecipientId();
          final fragments = BinaryFragmenter.fragment(
            data: messageBytes,
            mtu: mtuSize,
            originalType: BinaryPayloadType.protocolMessage,
            recipient: recipientId,
          );

          if (_connectionManager.hasBleConnection &&
              _connectionManager.messageCharacteristic != null) {
            for (int i = 0; i < fragments.length; i++) {
              await _getCentralManager().writeCharacteristic(
                _connectionManager.connectedDevice!,
                _connectionManager.messageCharacteristic!,
                value: fragments[i],
                type: GATTCharacteristicWriteType.withResponse,
              );

              if (i < fragments.length - 1) {
                await Future.delayed(Duration(milliseconds: 20));
              }
            }
          } else if (_stateManager.isPeripheralMode &&
              _getConnectedCentral() != null &&
              _getPeripheralMessageCharacteristic() != null) {
            final connectedCentral = _getConnectedCentral() as Central;
            final characteristic =
                _getPeripheralMessageCharacteristic() as GATTCharacteristic;

            for (int i = 0; i < fragments.length; i++) {
              await _getPeripheralManager().notifyCharacteristic(
                connectedCentral,
                characteristic,
                value: fragments[i],
              );

              if (i < fragments.length - 1) {
                await Future.delayed(Duration(milliseconds: 20));
              }
            }
          }
        } else if (singleChunk != null) {
          // Single-chunk fast path to avoid binary envelope overhead.
          if (_connectionManager.hasBleConnection &&
              _connectionManager.messageCharacteristic != null) {
            await _getCentralManager().writeCharacteristic(
              _connectionManager.connectedDevice!,
              _connectionManager.messageCharacteristic!,
              value: singleChunk.toBytes(),
              type: GATTCharacteristicWriteType.withResponse,
            );
          } else if (_stateManager.isPeripheralMode &&
              _getConnectedCentral() != null &&
              _getPeripheralMessageCharacteristic() != null) {
            final connectedCentral = _getConnectedCentral() as Central;
            final characteristic =
                _getPeripheralMessageCharacteristic() as GATTCharacteristic;

            await _getPeripheralManager().notifyCharacteristic(
              connectedCentral,
              characteristic,
              value: singleChunk.toBytes(),
            );
          }
        }

        completer.complete();
      } catch (e) {
        _logger.warning('⚠️ Protocol message send failed: $e');
        completer.completeError(e);
      }
    });

    // Process queue
    _processWriteQueue();

    return completer.future;
  }

  Future<void> _processWriteQueue() async {
    if (_isProcessingWriteQueue || _writeQueue.isEmpty) return;

    _isProcessingWriteQueue = true;

    while (_writeQueue.isNotEmpty) {
      final write = _writeQueue.removeAt(0);
      await write();
      // Small delay between writes to prevent GATT overload
      await Future.delayed(Duration(milliseconds: 50));
    }

    _isProcessingWriteQueue = false;
  }

  // ============================================================================
  // MESSAGE RECEPTION & STREAM
  // ============================================================================

  @override
  Stream<String> get receivedMessagesStream =>
      Stream<String>.multi((controller) {
        void listener(String message) {
          controller.add(message);
        }

        _messageListeners.add(listener);
        controller
          ..onListen = () {
            // No-op: listeners are fed via _messageListeners bridge
          }
          ..onCancel = () {
            _messageListeners.remove(listener);
          };
      }).asBroadcastStream();

  @override
  Stream<BinaryPayload> get receivedBinaryStream =>
      Stream<BinaryPayload>.multi((controller) {
        void listener(BinaryPayload payload) {
          controller.add(payload);
        }

        _binaryListeners.add(listener);
        controller.onCancel = () {
          _binaryListeners.remove(listener);
        };
      }).asBroadcastStream();

  @override
  String? get lastExtractedMessageId => extractedMessageId;

  @visibleForTesting
  void debugEmitReceivedMessage(String message) =>
      _emitReceivedMessage(message);

  void _emitReceivedMessage(String message) {
    for (final listener in List.of(_messageListeners)) {
      try {
        listener(message);
      } catch (e, stackTrace) {
        _logger.warning('Error notifying message listener: $e', e, stackTrace);
      }
    }
  }

  void _emitReceivedBinaryPayload(BinaryPayload payload) {
    for (final listener in List.of(_binaryListeners)) {
      try {
        listener(payload);
      } catch (e, stackTrace) {
        _logger.warning(
          'Error notifying binary payload listener: $e',
          e,
          stackTrace,
        );
      }
    }
  }

  // ============================================================================
  // MESH RELAY INTEGRATION
  // ============================================================================

  @override
  void registerQueueSyncMessageHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  ) {
    _queueSyncMessageHandler = handler;
    _logger.info('✅ Registered queue sync message handler');
  }

  // Callback for facade to invoke handler
  Future<bool> invokeQueueSyncHandler(
    QueueSyncMessage message,
    String fromNodeId,
  ) async {
    if (_queueSyncMessageHandler != null) {
      return await _queueSyncMessageHandler!(message, fromNodeId);
    }
    return false;
  }
}
