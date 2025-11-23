import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/security/signing_manager.dart';
import '../../core/utils/message_fragmenter.dart';
import '../../core/models/protocol_message.dart';
import '../../data/repositories/contact_repository.dart';
import 'ble_state_manager.dart';
import '../../core/services/security_manager.dart';
import '../../core/messaging/message_ack_tracker.dart';
import '../../core/messaging/message_chunk_sender.dart';
import '../../data/repositories/user_preferences.dart';
import '../../core/security/ephemeral_key_manager.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

/// Handles outbound message preparation and sending for BLEMessageHandler.
class OutboundMessageSender {
  OutboundMessageSender({
    required Logger logger,
    required MessageAckTracker ackTracker,
    required MessageChunkSender chunkSender,
    Future<void> Function({
      required CentralManager centralManager,
      required Peripheral peripheral,
      required GATTCharacteristic characteristic,
      required Uint8List value,
    })?
    centralWrite,
    Future<void> Function({
      required PeripheralManager peripheralManager,
      required Central central,
      required GATTCharacteristic characteristic,
      required Uint8List value,
      bool withoutResponse,
    })?
    peripheralWrite,
  }) : _logger = logger,
       _ackTracker = ackTracker,
       _chunkSender = chunkSender,
       _centralWrite = centralWrite,
       _peripheralWrite = peripheralWrite;

  final Logger _logger;
  final MessageAckTracker _ackTracker;
  final MessageChunkSender _chunkSender;
  final Future<void> Function({
    required CentralManager centralManager,
    required Peripheral peripheral,
    required GATTCharacteristic characteristic,
    required Uint8List value,
  })?
  _centralWrite;
  final Future<void> Function({
    required PeripheralManager peripheralManager,
    required Central central,
    required GATTCharacteristic characteristic,
    required Uint8List value,
    bool withoutResponse,
  })?
  _peripheralWrite;
  String? _currentNodeId;

  void setCurrentNodeId(String? nodeId) {
    _currentNodeId = nodeId;
  }

  Future<bool> sendCentralMessage({
    required CentralManager centralManager,
    required Peripheral connectedDevice,
    required GATTCharacteristic messageCharacteristic,
    required String message,
    required int mtuSize,
    String? messageId,
    String? contactPublicKey,
    String? recipientId,
    bool useEphemeralAddressing = false,
    String? originalIntendedRecipient,
    required ContactRepository contactRepository,
    required BLEStateManager stateManager,
    Function(bool)? onMessageOperationChanged,
  }) async {
    final msgId = messageId ?? DateTime.now().millisecondsSinceEpoch.toString();

    try {
      onMessageOperationChanged?.call(true);

      try {
        final pingData = Uint8List.fromList([0x00]);
        await centralManager.writeCharacteristic(
          connectedDevice,
          messageCharacteristic,
          value: pingData,
          type: GATTCharacteristicWriteType.withResponse,
        );
        _logger.info('Connection validation (ping) successful');
      } catch (e) {
        _logger.severe('Connection validation failed: $e');
        _logger.warning('🔥 Forcing disconnect to trigger reconnection...');
        try {
          await centralManager.disconnect(connectedDevice);
        } catch (disconnectError) {
          _logger.warning('Force disconnect failed: $disconnectError');
        }
        throw Exception('Connection unhealthy - forced disconnect');
      }

      final identities = await _resolveMessageIdentities(
        contactPublicKey: contactPublicKey,
        contactRepository: contactRepository,
        stateManager: stateManager,
      );

      final finalRecipientId = identities.intendedRecipient;
      final finalSenderIf = identities.originalSender;

      if (identities.isSpyMode) {
        _logger.info('🕵️ SPY MODE: Sending anonymously');
        _logger.info(
          '🕵️   Sender: ${finalSenderIf.shortId(8)}... (ephemeral)',
        );
        _logger.info(
          '🕵️   Recipient: ${finalRecipientId.shortId(8)}... (ephemeral)',
        );
      }

      String payload = message;
      String encryptionMethod = 'none';

      if (contactPublicKey != null && contactPublicKey.isNotEmpty) {
        try {
          payload = await SecurityManager.instance.encryptMessage(
            message,
            contactPublicKey,
            contactRepository,
          );
          encryptionMethod = await _getSimpleEncryptionMethod(
            contactPublicKey,
            contactRepository,
          );
          _logger.info(
            '🔒 MESSAGE: Encrypted with ${encryptionMethod.toUpperCase()} method',
          );
        } catch (e) {
          _logger.warning(
            '🔒 MESSAGE: Encryption failed, sending unencrypted: $e',
          );
          encryptionMethod = 'none';
        }
      } else {
        _logger.info('🔒 MESSAGE: No contact key, sending unencrypted');
      }

      SecurityLevel trustLevel;
      try {
        trustLevel = await SecurityManager.instance.getCurrentLevel(
          contactPublicKey ?? '',
          contactRepository,
        );
      } catch (e) {
        _logger.warning(
          '🔒 CENTRAL: Failed to get security level: $e, defaulting to LOW',
        );
        trustLevel = SecurityLevel.low;
      }

      final signingInfo = SigningManager.getSigningInfo(trustLevel);
      final signature = SigningManager.signMessage(message, trustLevel);

      final protocolMessage = ProtocolMessage.textMessage(
        messageId: msgId,
        content: payload,
        encrypted: encryptionMethod != 'none',
        recipientId: recipientId,
        useEphemeralAddressing: useEphemeralAddressing,
      );

      final legacyPayload = {
        ...protocolMessage.payload,
        'encryptionMethod': encryptionMethod,
        'intendedRecipient': originalIntendedRecipient ?? finalRecipientId,
        'originalSender': finalSenderIf,
      };

      final finalMessage = ProtocolMessage(
        type: protocolMessage.type,
        payload: legacyPayload,
        timestamp: protocolMessage.timestamp,
        signature: signature,
        useEphemeralSigning: signingInfo.useEphemeralSigning,
        ephemeralSigningKey: signingInfo.signingKey,
      );

      _logOutboundDiagnostics(
        msgId: msgId,
        recipientId: recipientId,
        useEphemeralAddressing: useEphemeralAddressing,
        contactPublicKey: contactPublicKey,
        currentNodeId: _currentNodeId,
        encryptionMethod: encryptionMethod,
        message: message,
      );

      final jsonBytes = finalMessage.toBytes();
      final chunks = MessageFragmenter.fragmentBytes(jsonBytes, mtuSize, msgId);
      _logger.info('Created ${chunks.length} chunks for message: $msgId');

      final ackCompleter = _ackTracker.track(
        msgId,
        onTimeout: (timedOutId) {
          _logger.warning('Message timeout: $timedOutId');
        },
      );

      await _chunkSender.sendChunks(
        messageId: msgId,
        fragments: chunks,
        sendChunk: (chunkData) async {
          if (_centralWrite != null) {
            await _centralWrite!(
              centralManager: centralManager,
              peripheral: connectedDevice,
              characteristic: messageCharacteristic,
              value: chunkData,
            );
          } else {
            await centralManager.writeCharacteristic(
              connectedDevice,
              messageCharacteristic,
              value: chunkData,
              type: GATTCharacteristicWriteType.withResponse,
            );
          }
        },
        onBeforeSend: (index, chunk) {
          final step = index + 1;
          print(
            '📨 SEND STEP 5.$step: Converting chunk $step/${chunks.length} to bytes',
          );
          print(
            '📨 SEND STEP 5.${step}a: Chunk format: ${chunk.messageId}|${chunk.chunkIndex}|${chunk.totalChunks}|${chunk.isBinary ? "1" : "0"}|[${chunk.content.length} chars]',
          );
          print(
            '📨 SEND STEP 5.${step}b: Chunk $step → ${chunk.toBytes().length} bytes',
          );
        },
        onAfterSend: (index, _) {
          final step = index + 1;
          print(
            '📨 SEND STEP 6.$step✅: Chunk $step written to BLE successfully',
          );
        },
      );

      _logger.info('All chunks sent for message: $msgId, waiting for ACK...');
      return await ackCompleter.future;
    } catch (e, stackTrace) {
      _logger.severe('Failed to send message: $e');
      _logger.severe('Stack trace: $stackTrace');
      rethrow;
    } finally {
      _ackTracker.cancel(msgId);
      Future.delayed(Duration(milliseconds: 500), () {
        onMessageOperationChanged?.call(false);
      });
    }
  }

  Future<bool> sendPeripheralMessage({
    required PeripheralManager peripheralManager,
    required Central connectedCentral,
    required GATTCharacteristic messageCharacteristic,
    required String message,
    required int mtuSize,
    String? messageId,
    String? contactPublicKey,
    String? recipientId,
    bool useEphemeralAddressing = false,
    String? originalIntendedRecipient,
    required ContactRepository contactRepository,
    required BLEStateManager stateManager,
  }) async {
    final msgId = messageId ?? DateTime.now().millisecondsSinceEpoch.toString();

    try {
      String payload = message;
      String encryptionMethod = 'none';

      if (contactPublicKey != null && contactPublicKey.isNotEmpty) {
        try {
          payload = await SecurityManager.instance.encryptMessage(
            message,
            contactPublicKey,
            contactRepository,
          );
          encryptionMethod = await _getSimpleEncryptionMethod(
            contactPublicKey,
            contactRepository,
          );
          _logger.info(
            '🔒 PERIPHERAL MESSAGE: Encrypted with ${encryptionMethod.toUpperCase()} method',
          );
        } catch (e) {
          _logger.warning(
            '🔒 PERIPHERAL MESSAGE: Encryption failed, sending unencrypted: $e',
          );
          encryptionMethod = 'none';
        }
      } else {
        _logger.info(
          '🔒 PERIPHERAL MESSAGE: No contact key, sending unencrypted',
        );
      }

      SecurityLevel trustLevel;
      try {
        trustLevel = await SecurityManager.instance.getCurrentLevel(
          contactPublicKey ?? '',
          contactRepository,
        );
      } catch (e) {
        _logger.warning(
          '🔒 PERIPHERAL: Failed to get security level: $e, defaulting to LOW',
        );
        trustLevel = SecurityLevel.low;
      }

      final signingInfo = SigningManager.getSigningInfo(trustLevel);
      final signature = SigningManager.signMessage(message, trustLevel);

      if (signingInfo.useEphemeralSigning && signingInfo.signingKey == null) {
        _logger.warning(
          '⚠️ PERIPHERAL: Ephemeral signing key not available - message will not be signed',
        );
      }

      final identities = await _resolveMessageIdentities(
        contactPublicKey: contactPublicKey,
        contactRepository: contactRepository,
        stateManager: stateManager,
      );

      final finalRecipientId = identities.intendedRecipient;
      final finalSenderIf = identities.originalSender;

      final protocolMessage = ProtocolMessage.textMessage(
        messageId: msgId,
        content: payload,
        encrypted: encryptionMethod != 'none',
        recipientId: recipientId,
        useEphemeralAddressing: useEphemeralAddressing,
      );

      final legacyPayload = {
        ...protocolMessage.payload,
        'encryptionMethod': encryptionMethod,
        'intendedRecipient': originalIntendedRecipient ?? finalRecipientId,
        'originalSender': finalSenderIf,
      };

      final finalMessage = ProtocolMessage(
        type: protocolMessage.type,
        payload: legacyPayload,
        timestamp: protocolMessage.timestamp,
        signature: signature,
        useEphemeralSigning: signingInfo.useEphemeralSigning,
        ephemeralSigningKey: signingInfo.signingKey,
      );

      _logger.info(
        '🔧 PERIPHERAL SEND DEBUG: Message ID: ${_safeTruncate(msgId, 16)}...',
      );
      _logger.info(
        '🔧 PERIPHERAL SEND DEBUG: Recipient ID: ${_safeTruncate(recipientId, 16, fallback: "NOT SPECIFIED")}...',
      );
      _logger.info(
        '🔧 PERIPHERAL SEND DEBUG: Addressing: ${useEphemeralAddressing ? "EPHEMERAL" : "PERSISTENT"}',
      );
      _logger.info(
        '🔧 PERIPHERAL SEND DEBUG: Intended recipient: ${_safeTruncate(contactPublicKey, 16, fallback: "NOT SPECIFIED")}...',
      );
      _logger.info(
        '🔧 PERIPHERAL SEND DEBUG: Current node ID: ${_safeTruncate(_currentNodeId, 16, fallback: "NOT SET")}...',
      );
      _logger.info(
        '🔧 PERIPHERAL SEND DEBUG: Encryption method: $encryptionMethod',
      );

      final jsonBytes = finalMessage.toBytes();
      final chunks = MessageFragmenter.fragmentBytes(jsonBytes, mtuSize, msgId);
      _logger.info(
        'Created ${chunks.length} chunks for peripheral message: $msgId',
      );

      await _chunkSender.sendChunks(
        messageId: msgId,
        fragments: chunks,
        sendChunk: (chunkData) async {
          if (_peripheralWrite != null) {
            await _peripheralWrite!(
              peripheralManager: peripheralManager,
              central: connectedCentral,
              characteristic: messageCharacteristic,
              value: chunkData,
              withoutResponse: true,
            );
          } else {
            await peripheralManager.notifyCharacteristic(
              connectedCentral,
              messageCharacteristic,
              value: chunkData,
            );
          }
        },
        onBeforeSend: (index, chunk) {
          final step = index + 1;
          _logger.info(
            'Sending peripheral chunk $step/${chunks.length} for message: $msgId',
          );
          _logger.fine(
            'Peripheral chunk $step size: ${chunk.toBytes().length} bytes',
          );
        },
      );

      _logger.info('All peripheral chunks sent for message: $msgId');
      return true;
    } catch (e, stackTrace) {
      _logger.severe('Failed to send peripheral message: $e');
      _logger.severe('Stack trace: $stackTrace');
      rethrow;
    }
  }

  void _logOutboundDiagnostics({
    required String msgId,
    required String? recipientId,
    required bool useEphemeralAddressing,
    required String? contactPublicKey,
    required String? currentNodeId,
    required String encryptionMethod,
    required String message,
  }) {
    print('🔧 SEND DEBUG: ===== MESSAGE SENDING ANALYSIS =====');
    print('🔧 SEND DIAGNOSTIC: Message ID length: ${msgId.length}');
    print(
      '🔧 SEND DIAGNOSTIC: Contact key length: ${contactPublicKey?.length ?? 0}',
    );
    print(
      '🔧 SEND DIAGNOSTIC: Current node length: ${currentNodeId?.length ?? 0}',
    );

    print('🔧 SEND DEBUG: Message ID: ${_safeTruncate(msgId, 16)}...');
    print(
      '🔧 SEND DEBUG: Recipient ID: ${_safeTruncate(recipientId, 16, fallback: "NOT SPECIFIED")}...',
    );
    print(
      '🔧 SEND DEBUG: Addressing: ${useEphemeralAddressing ? "EPHEMERAL" : "PERSISTENT"}',
    );
    print(
      '🔧 SEND DEBUG: Intended recipient: ${_safeTruncate(contactPublicKey, 16, fallback: "NOT SPECIFIED")}...',
    );
    print(
      '🔧 SEND DEBUG: Current node ID: ${_safeTruncate(currentNodeId, 16, fallback: "NOT SET")}...',
    );
    print('🔧 SEND DEBUG: Encryption method: $encryptionMethod');
    print('🔧 SEND DEBUG: Message content: "${_safeTruncate(message, 50)}..."');
    print('🔧 SEND DEBUG: ===== END SENDING ANALYSIS =====');
  }

  Future<String> _getSimpleEncryptionMethod(
    String? contactPublicKey,
    ContactRepository contactRepository,
  ) async {
    if (contactPublicKey == null || contactPublicKey.isEmpty) {
      return 'global';
    }

    final level = await SecurityManager.instance.getCurrentLevel(
      contactPublicKey,
      contactRepository,
    );

    switch (level) {
      case SecurityLevel.high:
        return 'ecdh';
      case SecurityLevel.medium:
        return 'pairing';
      case SecurityLevel.low:
        return 'global';
    }
  }

  Future<_MessageIdentities> _resolveMessageIdentities({
    required String? contactPublicKey,
    required ContactRepository contactRepository,
    required BLEStateManager stateManager,
  }) async {
    final _ = stateManager;
    final userPrefs = UserPreferences();
    final hintsEnabled = await userPrefs.getHintBroadcastEnabled();

    final myPersistentKey = await userPrefs.getPublicKey();
    final myEphemeralID = EphemeralKeyManager.generateMyEphemeralKey();

    final contact = contactPublicKey != null
        ? await contactRepository.getContact(contactPublicKey)
        : null;

    final noiseSessionExists =
        contact?.currentEphemeralId != null &&
        SecurityManager.instance.noiseService?.hasEstablishedSession(
              contact!.currentEphemeralId!,
            ) ==
            true;

    String originalSender;
    if (!hintsEnabled && noiseSessionExists) {
      originalSender = myEphemeralID;
    } else {
      originalSender = myPersistentKey;
    }

    String intendedRecipient;
    if (!hintsEnabled &&
        noiseSessionExists &&
        contact?.currentEphemeralId != null) {
      intendedRecipient = contact!.currentEphemeralId!;
    } else if (contact?.persistentPublicKey != null) {
      intendedRecipient = contact!.persistentPublicKey!;
    } else {
      intendedRecipient =
          contact?.publicKey ?? contactPublicKey ?? myEphemeralID;
    }

    return _MessageIdentities(
      originalSender: originalSender,
      intendedRecipient: intendedRecipient,
      isSpyMode: !hintsEnabled && noiseSessionExists,
    );
  }

  static String _safeTruncate(
    String? input,
    int maxLength, {
    String fallback = "NULL",
  }) {
    if (input == null || input.isEmpty) return fallback;
    if (input.length <= maxLength) return input;
    return input.substring(0, maxLength);
  }
}

class _MessageIdentities {
  final String originalSender;
  final String intendedRecipient;
  final bool isSpyMode;

  _MessageIdentities({
    required this.originalSender,
    required this.intendedRecipient,
    required this.isSpyMode,
  });
}
