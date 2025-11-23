import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'dart:async';
import 'package:logging/logging.dart';

import '../../core/interfaces/i_ble_messaging_service.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../core/utils/message_fragmenter.dart';
import '../../core/interfaces/i_ble_message_handler_facade.dart';
import 'ble_connection_manager.dart';
import '../../core/constants/ble_constants.dart';
import '../../core/interfaces/i_ble_state_manager_facade.dart';
import '../../data/repositories/contact_repository.dart';
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
  late final StreamController<String> _messagesController;
  String? extractedMessageId;

  // Central/peripheral connection state (from facade)
  final Function() _getConnectedCentral;
  final Function() _getPeripheralMessageCharacteristic;
  final Function() _getPeripheralMtuReady;
  final Function() _getPeripheralNegotiatedMtu;

  // Write queue for serialization
  final List<Future<void> Function()> _writeQueue = [];
  bool _isProcessingWriteQueue = false;

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
    required StreamController<String> messagesController,
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
       _messagesController = messagesController,
       _getConnectedCentral = getConnectedCentral,
       _getPeripheralMessageCharacteristic = getPeripheralMessageCharacteristic,
       _getPeripheralMtuReady = getPeripheralMtuReady,
       _getPeripheralNegotiatedMtu = getPeripheralNegotiatedMtu;

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

        // Fragment the binary data (handles base64 encoding + MTU sizing)
        final chunks = MessageFragmenter.fragmentBytes(
          messageBytes,
          mtuSize,
          msgId,
        );

        _logger.fine(
          '📦 Protocol message fragmented into ${chunks.length} chunk(s)',
        );

        // Send each chunk with delay to prevent BLE congestion
        if (_connectionManager.hasBleConnection &&
            _connectionManager.messageCharacteristic != null) {
          for (int i = 0; i < chunks.length; i++) {
            await _getCentralManager().writeCharacteristic(
              _connectionManager.connectedDevice!,
              _connectionManager.messageCharacteristic!,
              value: chunks[i].toBytes(),
              type: GATTCharacteristicWriteType.withResponse,
            );

            // Small delay between chunks to prevent GATT congestion
            if (i < chunks.length - 1) {
              await Future.delayed(Duration(milliseconds: 20));
            }
          }
        } else if (_stateManager.isPeripheralMode &&
            _getConnectedCentral() != null &&
            _getPeripheralMessageCharacteristic() != null) {
          final connectedCentral = _getConnectedCentral() as Central;
          final characteristic =
              _getPeripheralMessageCharacteristic() as GATTCharacteristic;

          for (int i = 0; i < chunks.length; i++) {
            await _getPeripheralManager().notifyCharacteristic(
              connectedCentral,
              characteristic,
              value: chunks[i].toBytes(),
            );

            // Small delay between chunks to prevent GATT congestion
            if (i < chunks.length - 1) {
              await Future.delayed(Duration(milliseconds: 20));
            }
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
  Stream<String> get receivedMessagesStream => _messagesController.stream;

  @override
  String? get lastExtractedMessageId => extractedMessageId;

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
