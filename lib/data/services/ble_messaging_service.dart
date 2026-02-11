import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:flutter/services.dart';
import 'package:pak_connect/domain/interfaces/i_ble_messaging_service.dart';
import '../../domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import '../../domain/utils/message_fragmenter.dart';
import '../../domain/utils/binary_fragmenter.dart';
import 'package:pak_connect/domain/constants/binary_payload_types.dart';
import 'package:pak_connect/domain/interfaces/i_ble_message_handler_facade.dart';
import 'package:pak_connect/domain/interfaces/i_message_fragmentation_handler.dart';
import 'package:pak_connect/domain/messaging/media_transfer_store.dart';
import 'ble_connection_manager.dart';
import '../../domain/constants/ble_constants.dart';
import 'package:pak_connect/domain/interfaces/i_ble_state_manager_facade.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../../domain/services/device_deduplication_manager.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import 'package:pak_connect/domain/utils/chat_utils.dart';
import '../../domain/entities/message.dart';
import '../../domain/values/id_types.dart';

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
// Raised when a handshake control frame cannot be written to BLE.
// Allows the handshake coordinator to fail fast instead of timing out.
class HandshakeSendException implements Exception {
  final String message;
  HandshakeSendException(this.message);
  @override
  String toString() => 'HandshakeSendException: $message';
}

class BLEMessagingService implements IBLEMessagingService {
  final _logger = Logger('BLEMessagingService');

  // Dependencies (injected)
  final IBLEMessageHandlerFacade _messageHandler;
  final BLEConnectionManager _connectionManager;
  final IBLEStateManagerFacade _stateManager;
  final ContactRepository _contactRepository;
  final MessageRepository _messageRepository;
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
  // Keep in sync with DeviceDeduplicationManager._noHintValue
  static const String _noHintValue = 'NO_HINT';

  BLEMessagingService({
    required IBLEMessageHandlerFacade messageHandler,
    required BLEConnectionManager connectionManager,
    required IBLEStateManagerFacade stateManager,
    required ContactRepository contactRepository,
    MessageRepository? messageRepository,
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
       _messageRepository = messageRepository ?? MessageRepository(),
       _getCentralManager = getCentralManager,
       _getPeripheralManager = getPeripheralManager,
       _getConnectedCentral = getConnectedCentral,
       _getPeripheralMessageCharacteristic = getPeripheralMessageCharacteristic,
       _getPeripheralMtuReady = getPeripheralMtuReady,
       _getPeripheralNegotiatedMtu = getPeripheralNegotiatedMtu {
    // Relay messages from handler into internal listeners.
    _messageHandler.onRelayMessageReceived =
        (String originalMessageId, String content, String originalSender) {
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

    _messageHandler.onTextMessageReceived =
        (String content, String? messageId, String? senderNodeId) async {
          await _handleInboundTextMessage(
            content: content,
            messageId: messageId,
            senderNodeId: senderNodeId,
          );
        };
  }

  Future<String> _resolveSenderNodeId(
    String deviceId, {
    String? providedNodeId,
  }) async {
    bool isPlaceholder(String value) {
      if (value.isEmpty || value == _noHintValue) return true;
      final normalized = value.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
      return normalized.isNotEmpty && RegExp(r'^0+$').hasMatch(normalized);
    }

    if (providedNodeId != null && !isPlaceholder(providedNodeId)) {
      return providedNodeId;
    }

    final dedupDevice = DeviceDeduplicationManager.getDevice(deviceId);
    final contact = dedupDevice?.contactInfo?.contact;

    final sessionId = contact?.currentEphemeralId;
    if (sessionId != null && sessionId.isNotEmpty) {
      return sessionId;
    }

    final contactId = contact?.chatId;
    if (contactId != null && contactId.isNotEmpty) {
      return contactId;
    }

    final hint = dedupDevice?.ephemeralHint;
    if (hint != null && hint.isNotEmpty && hint != _noHintValue) {
      final contactFromHint = await _contactRepository.getContactByAnyId(hint);
      if (contactFromHint?.currentEphemeralId?.isNotEmpty == true) {
        return contactFromHint!.currentEphemeralId!;
      }
      if (contactFromHint != null) {
        return contactFromHint.chatId;
      }
      return hint;
    }

    // Fallback: use active peer session from state manager when device/hint
    // are placeholders (e.g., 0000... MAC).
    final theirEphemeral = _stateManager.theirEphemeralId;
    if (theirEphemeral != null && theirEphemeral.isNotEmpty) {
      return theirEphemeral;
    }
    final currentSession = _stateManager.currentSessionId;
    if (currentSession != null && currentSession.isNotEmpty) {
      return currentSession;
    }

    return deviceId;
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

    String? recipientId = _stateManager.getRecipientId();
    // If state is missing a recipient (race/tie), fall back to the queued/intended recipient.
    if ((recipientId == null || recipientId.isEmpty) &&
        originalIntendedRecipient != null &&
        originalIntendedRecipient.isNotEmpty) {
      recipientId = originalIntendedRecipient;
    }
    final idType = _stateManager.getIdType();

    if (recipientId != null && recipientId.isNotEmpty) {
      final truncatedId = recipientId.length > 16
          ? recipientId.substring(0, 16)
          : recipientId;
      _logger.info(
        '📤 STEP 7: Sending message using $idType ID: $truncatedId...',
      );
    } else {
      _logger.warning(
        '⚠️ No recipient ID available for central send; aborting',
      );
      return false;
    }

    return await _messageHandler.sendMessage(
      recipientKey: recipientId,
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
    String? recipientId = _stateManager.getRecipientId();
    if ((recipientId == null || recipientId.isEmpty) &&
        _stateManager.theirPersistentKey != null &&
        _stateManager.theirPersistentKey!.isNotEmpty) {
      recipientId = _stateManager.theirPersistentKey;
    }
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
    final hasCentralLink =
        _connectionManager.hasBleConnection &&
        _connectionManager.messageCharacteristic != null;
    final hasPeripheralLink =
        _stateManager.isPeripheralMode &&
        _getConnectedCentral() != null &&
        _getPeripheralMessageCharacteristic() != null;

    if (_connectionManager.isHandshakeInProgress ||
        _connectionManager.awaitingHandshake) {
      _logger.fine(
        '🔄 QUEUE SYNC: Skipping send while handshake is in progress',
      );
      return;
    }
    if (!hasCentralLink && !hasPeripheralLink) {
      _logger.fine('🔄 QUEUE SYNC: No active BLE link, skipping send');
      return;
    }

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
  /// Requires encryption - aborts if recipientId is missing or encryption fails.
  Future<void> _sendBinaryPayload({
    required Uint8List data,
    required int originalType,
    String? recipientId,
  }) async {
    // Encryption is required for all binary payloads
    if (recipientId == null || recipientId.isEmpty) {
      _logger.severe(
        '❌ SEND ABORTED: Cannot send binary payload without recipient ID (encryption required)',
      );
      throw Exception('Cannot send binary payload without recipient ID');
    }

    final payload = await SecurityServiceLocator.instance.encryptBinaryPayload(
      data,
      recipientId,
      _contactRepository,
    );

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
          // Decrement TTL byte before forwarding to enforce hop cap.
          final forwarded = Uint8List.fromList(data);
          if (forwarded.length > 10) {
            // TTL is after: magic(1) + fragmentId(8) + index/total(4) => offset 13
            const ttlOffset = 1 + 8 + 4;
            forwarded[ttlOffset] = (forwarded[ttlOffset] - 1) & 0xFF;
          }
          await _getCentralManager().writeCharacteristic(
            conn.peripheral,
            characteristic,
            value: forwarded,
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
          // Decrement TTL byte before forwarding to enforce hop cap.
          final forwarded = Uint8List.fromList(data);
          if (forwarded.length > 10) {
            const ttlOffset = 1 + 8 + 4;
            forwarded[ttlOffset] = (forwarded[ttlOffset] - 1) & 0xFF;
          }
          await _getPeripheralManager().notifyCharacteristic(
            connectedCentral,
            characteristic,
            value: forwarded,
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
  /// Requires an established encryption path; throws instead of sending
  /// plaintext when encryption cannot be applied.
  @override
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
  @override
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
            final central = _getConnectedCentral() as Central?;
            final characteristic =
                _getPeripheralMessageCharacteristic() as GATTCharacteristic?;
            if (central == null || characteristic == null) return false;
            BLEServerConnection? serverConn;
            try {
              serverConn = _connectionManager.serverConnections.firstWhere(
                (c) => c.address == central.uuid.toString(),
              );
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
            await Future.delayed(Duration(milliseconds: 50));
          }
          return peripheralNotifyReady();
        }

        // Bail out early if neither central nor peripheral link is usable.
        final hasCentralLink =
            _connectionManager.hasBleConnection &&
            _connectionManager.messageCharacteristic != null;
        final hasPeripheralLink =
            _stateManager.isPeripheralMode &&
            _getConnectedCentral() != null &&
            _getPeripheralMessageCharacteristic() != null;

        // For handshake control frames we must avoid stale handles. If we are in
        // peripheral mode and have a fresh inbound link, prefer that path even
        // if an old client connection still exists.
        Future<void> sendUnfragmented(Uint8List value) async {
          if (isHandshakeMessage && hasPeripheralLink) {
            final connectedCentral = _getConnectedCentral() as Central;
            final characteristic =
                _getPeripheralMessageCharacteristic() as GATTCharacteristic;
            await _getPeripheralManager().notifyCharacteristic(
              connectedCentral,
              characteristic,
              value: value,
            );
            return;
          }

          if (hasCentralLink) {
            await _getCentralManager().writeCharacteristic(
              _connectionManager.connectedDevice!,
              _connectionManager.messageCharacteristic!,
              value: value,
              type: GATTCharacteristicWriteType.withResponse,
            );
            return;
          }

          if (hasPeripheralLink) {
            final connectedCentral = _getConnectedCentral() as Central;
            final characteristic =
                _getPeripheralMessageCharacteristic() as GATTCharacteristic;
            await _getPeripheralManager().notifyCharacteristic(
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
              'No usable BLE link (central=$hasCentralLink, peripheral=$hasPeripheralLink, state=${_connectionManager.connectionState.name})';
          _logger.warning('⚠️ Protocol message send skipped: $msg');
          if (isHandshakeMessage) {
            _isProcessingWriteQueue = false;
            completer.completeError(HandshakeSendException(msg));
            return;
          }
          completer.complete();
          return;
        }

        if (isHandshakeMessage &&
            hasPeripheralLink &&
            !peripheralNotifyReady()) {
          _logger.fine(
            '⏳ Waiting for peripheral notify subscription before sending handshake...',
          );
          final ready = await waitForPeripheralNotifyReady();
          if (!ready) {
            final msg = 'Responder notify not enabled for handshake path';
            _logger.warning('⚠️ Handshake send blocked: $msg');
            _logger.warning(
              '⚠️ No inbound notify subscription detected within wait window; initiator may not be enabling notifications',
            );
            final reconnectAddress = _connectionManager.connectedDevice?.uuid
                .toString();
            if (reconnectAddress != null) {
              _logger.info(
                '🔁 Notify wait timed out — reconnecting client link $reconnectAddress',
              );
              unawaited(
                _connectionManager.disconnectClient(reconnectAddress).then((_) {
                  _connectionManager.triggerReconnection();
                }),
              );
            }
            _isProcessingWriteQueue = false;
            completer.completeError(HandshakeSendException(msg));
            return;
          }
        }

        // Convert protocol message to bytes (may be compressed binary)
        final messageBytes = message.toBytes();

        // Get MTU size with fallback to safe default
        final mtuSize =
            _connectionManager.mtuSize ?? BLEConstants.maxMessageLength;

        // Handshake fast-path: send control frames unfragmented when they fit MTU.
        if (isHandshakeMessage && messageBytes.length <= mtuSize) {
          _logger.fine(
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
            _connectionManager.mtuSize ?? BLEConstants.maxMessageLength;

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
            mtu: fragmentationMtu,
            originalType: BinaryPayloadType.protocolMessage,
            recipient: recipientId,
          );

          for (int i = 0; i < fragments.length; i++) {
            await sendUnfragmented(fragments[i]);
            if (i < fragments.length - 1) {
              await Future.delayed(Duration(milliseconds: 20));
            }
          }
        } else if (singleChunk != null) {
          // Single-chunk fast path to avoid binary envelope overhead.
          await sendUnfragmented(singleChunk.toBytes());
        }

        completer.complete();
      } catch (e, stack) {
        _logger.warning('⚠️ Protocol message send failed: $e');
        _logger.fine('Protocol send stacktrace: $stack');
        final isPlatformException =
            e is PlatformException &&
            (e.message?.contains('status: 133') == true ||
                e.message?.contains('IllegalArgumentException') == true);
        if (isPlatformException && isHandshakeMessage) {
          final msg =
              'Handshake write failed (platform status 133/IllegalArgument)';
          _logger.warning(
            '⚠️ Detected platform write failure (status 133 / IllegalArgument) — aborting queue and awaiting reconnection',
          );
          _isProcessingWriteQueue = false;
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
    _processWriteQueue();

    return completer.future;
  }

  Future<void> _processWriteQueue() async {
    if (_isProcessingWriteQueue || _writeQueue.isEmpty) return;

    _isProcessingWriteQueue = true;

    while (_writeQueue.isNotEmpty) {
      final write = _writeQueue.removeAt(0);
      final hasCentralLink =
          _connectionManager.hasBleConnection &&
          _connectionManager.messageCharacteristic != null;
      final hasPeripheralLink =
          _stateManager.isPeripheralMode &&
          _getConnectedCentral() != null &&
          _getPeripheralMessageCharacteristic() != null;
      if (!hasCentralLink && !hasPeripheralLink) {
        _logger.warning(
          '⚠️ Aborting write queue; BLE connection not ready '
          '(central=$hasCentralLink, peripheral=$hasPeripheralLink, '
          'state=${_connectionManager.connectionState.name})',
        );
        _isProcessingWriteQueue = false;
        return;
      }
      try {
        await write();
      } catch (e) {
        // Write failed; stop processing so caller can handle.
        _isProcessingWriteQueue = false;
        rethrow;
      }
      // Small delay between writes to prevent GATT overload
      await Future.delayed(Duration(milliseconds: 50));
    }

    _isProcessingWriteQueue = false;
  }

  // ============================================================================
  // MESSAGE RECEPTION & STREAM
  // ============================================================================

  @override
  Future<void> processIncomingPeripheralData(
    Uint8List data, {
    required String senderDeviceId,
    String? senderNodeId,
  }) async {
    try {
      final inferredNodeId = await _resolveSenderNodeId(
        senderDeviceId,
        providedNodeId: senderNodeId,
      );
      await _messageHandler.processReceivedData(
        data: data,
        fromDeviceId: senderDeviceId,
        fromNodeId: inferredNodeId,
      );
    } catch (e) {
      _logger.warning('⚠️ Failed to process inbound peripheral data: $e');
    }
  }

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

  Future<void> _handleInboundTextMessage({
    required String content,
    String? messageId,
    String? senderNodeId,
  }) async {
    try {
      final senderId = await _resolveStorageSenderId(senderNodeId);
      final chatId = ChatId(ChatUtils.generateChatId(senderId));
      final resolvedMessageId = (messageId != null && messageId.isNotEmpty)
          ? messageId
          : _generateFallbackMessageId(senderId, content);

      extractedMessageId = resolvedMessageId;

      final existing = await _messageRepository.getMessageById(
        MessageId(resolvedMessageId),
      );
      if (existing != null) {
        return;
      }

      final inbound = Message(
        id: MessageId(resolvedMessageId),
        chatId: chatId,
        content: content,
        timestamp: DateTime.now(),
        isFromMe: false,
        status: MessageStatus.delivered,
      );

      await _messageRepository.saveMessage(inbound);
      _emitReceivedMessage(content);

      final previewId = resolvedMessageId.length > 8
          ? resolvedMessageId.substring(0, 8)
          : resolvedMessageId;
      final previewChat = chatId.value.length > 8
          ? chatId.value.substring(0, 8)
          : chatId.value;
      _logger.info(
        '💾 Stored inbound message $previewId... in chat $previewChat...',
      );
    } catch (e) {
      _logger.warning('⚠️ Failed to persist inbound message: $e');
    }
  }

  Future<String> _resolveStorageSenderId(String? senderNodeId) async {
    final fallbackId =
        _stateManager.theirPersistentKey ?? _stateManager.currentSessionId;
    final candidate = senderNodeId?.isNotEmpty == true
        ? senderNodeId!
        : (fallbackId ?? 'unknown_sender');

    try {
      final contact = await _contactRepository.getContactByAnyId(candidate);
      if (contact != null) {
        if (contact.persistentPublicKey?.isNotEmpty == true) {
          return contact.persistentPublicKey!;
        }
        return contact.publicKey;
      }
    } catch (_) {
      // Fallback below
    }

    return candidate;
  }

  String _generateFallbackMessageId(String senderId, String content) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final payload = '$timestamp|$senderId|$content';
    final hash = sha256.convert(utf8.encode(payload)).toString();
    return 'rx_${hash.substring(0, 32)}';
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
