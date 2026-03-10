import 'dart:convert';
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../domain/services/signing_manager.dart';
import '../../domain/utils/message_fragmenter.dart';
import '../../domain/models/protocol_message.dart';
import '../../domain/models/crypto_header.dart';
import '../../domain/models/encryption_method.dart';
import '../../domain/interfaces/i_security_service.dart';
import '../../data/repositories/contact_repository.dart';
import 'ble_state_manager.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import 'package:pak_connect/domain/messaging/message_ack_tracker.dart';
import '../../domain/messaging/message_chunk_sender.dart';
import '../../data/repositories/user_preferences.dart';
import '../../domain/services/ephemeral_key_manager.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import '../../domain/utils/binary_fragmenter.dart';
import 'package:pak_connect/domain/constants/binary_payload_types.dart';
import '../../domain/models/security_level.dart';
import '../../domain/values/id_types.dart';
import '../../core/security/sealed/sealed_encryption_service.dart';
import '../../core/security/peer_protocol_version_guard.dart';

/// Handles outbound message preparation and sending for BLEMessageHandler.
class OutboundMessageSender {
  /// Legacy v2 send is disabled by default for security hardening.
  /// Override at build time with -DPAKCONNECT_ALLOW_LEGACY_V2_SEND=true
  /// for backward compatibility during migration.
  static const bool _defaultAllowLegacyV2Send = bool.fromEnvironment(
    'PAKCONNECT_ALLOW_LEGACY_V2_SEND',
    defaultValue: false,
  );
  static const bool _defaultEnableSealedV1Send = bool.fromEnvironment(
    'PAKCONNECT_ENABLE_SEALED_V1_SEND',
    defaultValue: false,
  );

  OutboundMessageSender({
    required Logger logger,
    required MessageAckTracker ackTracker,
    required MessageChunkSender chunkSender,
    ISecurityService? securityService,
    SealedEncryptionService? sealedEncryptionService,
    bool? allowLegacyV2Send,
    bool? enableSealedV1Send,
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
       _securityService =
           securityService ?? SecurityServiceLocator.resolveService(),
       _sealedEncryptionService =
           sealedEncryptionService ?? SealedEncryptionService(),
       _allowLegacyV2Send = allowLegacyV2Send ?? _defaultAllowLegacyV2Send,
       _enableSealedV1Send = enableSealedV1Send ?? _defaultEnableSealedV1Send,
       _centralWrite = centralWrite,
       _peripheralWrite = peripheralWrite;

  final Logger _logger;
  final MessageAckTracker _ackTracker;
  final MessageChunkSender _chunkSender;
  final ISecurityService _securityService;
  final SealedEncryptionService _sealedEncryptionService;
  final bool _allowLegacyV2Send;
  final bool _enableSealedV1Send;
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

  String? get _safeNodeId =>
      _currentNodeId ?? EphemeralKeyManager.currentSessionKey;

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
    void Function(String messageId, bool success)? onMessageSent,
    void Function(MessageId messageId, bool success)? onMessageSentIds,
  }) async {
    final msgId = messageId ?? DateTime.now().millisecondsSinceEpoch.toString();

    try {
      onMessageOperationChanged?.call(true);
      // Skip extra ping writes; they have been causing GATT 133 on some stacks.

      final contactKey = (contactPublicKey?.isNotEmpty ?? false)
          ? contactPublicKey
          : recipientId;
      final identities = await _resolveMessageIdentities(
        contactPublicKey: contactKey,
        contactRepository: contactRepository,
        stateManager: stateManager,
      );

      final finalRecipientId = identities.intendedRecipient;
      final finalSenderIf = identities.originalSender;
      final encryptionKey = (contactPublicKey?.isNotEmpty ?? false)
          ? contactPublicKey!
          : finalRecipientId;

      if (finalRecipientId.isEmpty) {
        _logger.severe(
          '❌ SEND ABORTED: Intended recipient is empty; cannot send message $msgId',
        );
        throw Exception('Intended recipient not set');
      }

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
      EncryptionMethod? encryptionDecision;
      CryptoHeader? explicitCryptoHeader;

      if (encryptionKey.isNotEmpty) {
        encryptionDecision = await _securityService.getEncryptionMethod(
          encryptionKey,
          contactRepository,
        );
        payload = await _securityService.encryptMessageByType(
          message,
          encryptionKey,
          contactRepository,
          encryptionDecision.type,
        );
        encryptionMethod = _wireMethodForType(encryptionDecision.type);
        _logger.info(
          '🔒 MESSAGE: Encrypted with ${encryptionMethod.toUpperCase()} method',
        );
      } else {
        _logger.severe(
          '❌ SEND ABORTED: No encryption key available for message $msgId',
        );
        throw Exception('Cannot send message without encryption key');
      }

      final upgradedPeerObserved = _hasUpgradedPeerProtocolFloor(
        recipientId: finalRecipientId,
        contactLookupKey: encryptionKey,
      );
      final shouldAttemptSealedFallback =
          _isLegacyEncryptionType(encryptionDecision.type) &&
          (_enableSealedV1Send ||
              upgradedPeerObserved ||
              !_allowLegacyV2Send);

      if (shouldAttemptSealedFallback) {
        final sealedResult = await _tryEncryptWithSealedV1(
          plaintext: message,
          messageId: msgId,
          senderId: finalSenderIf,
          recipientId: finalRecipientId,
          contactLookupKey: encryptionKey,
          contactRepository: contactRepository,
        );
        if (sealedResult != null) {
          payload = sealedResult.payloadBase64;
          encryptionMethod = 'sealed';
          explicitCryptoHeader = sealedResult.header;
          _logger.info(
            '🔒 MESSAGE: Switched to SEALED_V1 offline lane (${_safeTruncate(msgId, 16)})',
          );
        }
      }

      SecurityLevel trustLevel;
      try {
        trustLevel = await _securityService.getCurrentLevel(
          encryptionKey,
          contactRepository,
        );
      } catch (e) {
        _logger.warning(
          '🔒 CENTRAL: Failed to get security level: $e, defaulting to LOW',
        );
        trustLevel = SecurityLevel.low;
      }

      final signingInfo = SigningManager.getSigningInfo(trustLevel);

      final protocolMessage = ProtocolMessage.textMessage(
        messageId: msgId,
        content: payload,
        encrypted: encryptionMethod != 'none',
        recipientId: finalRecipientId,
        useEphemeralAddressing: useEphemeralAddressing,
      );

      final intendedRecipientPayload =
          originalIntendedRecipient ?? finalRecipientId;
      final allowLegacyV2ForMessage = _allowLegacyV2ForMessage(
        recipientId: finalRecipientId,
        contactLookupKey: encryptionKey,
        transportSide: 'central',
        messageId: msgId,
      );
      final cryptoHeader =
          explicitCryptoHeader ??
          _buildCryptoHeader(
            encryptionMethod: encryptionMethod,
            sessionId: encryptionMethod == 'noise'
                ? (encryptionDecision.publicKey ?? encryptionKey)
                : null,
            messageId: msgId,
            transportSide: 'central',
            allowLegacyV2ForMessage: allowLegacyV2ForMessage,
          );

      final legacyPayload = {
        ...protocolMessage.payload,
        'encryptionMethod': encryptionMethod,
        'intendedRecipient': intendedRecipientPayload,
        'originalSender': finalSenderIf,
        'senderId': finalSenderIf,
        if (cryptoHeader != null) 'crypto': cryptoHeader.toJson(),
      };

      final unsignedMessage = ProtocolMessage(
        type: protocolMessage.type,
        version: 2,
        payload: legacyPayload,
        timestamp: protocolMessage.timestamp,
        useEphemeralSigning: signingInfo.useEphemeralSigning,
        ephemeralSigningKey: signingInfo.signingKey,
      );
      final signaturePayload = SigningManager.signaturePayloadForMessage(
        unsignedMessage,
        fallbackContent: message,
      );
      final signature = SigningManager.signMessage(
        signaturePayload,
        trustLevel,
      );
      final finalMessage = ProtocolMessage(
        type: unsignedMessage.type,
        version: unsignedMessage.version,
        payload: unsignedMessage.payload,
        timestamp: unsignedMessage.timestamp,
        signature: signature,
        useEphemeralSigning: unsignedMessage.useEphemeralSigning,
        ephemeralSigningKey: unsignedMessage.ephemeralSigningKey,
      );

      _logOutboundDiagnostics(
        msgId: msgId,
        recipientId: finalRecipientId,
        useEphemeralAddressing: useEphemeralAddressing,
        contactPublicKey: contactKey,
        currentNodeId: _currentNodeId,
        encryptionMethod: encryptionMethod,
        message: message,
      );

      final jsonBytes = finalMessage.toBytes();
      List<MessageChunk>? chunks;
      MessageChunk? singleChunk;
      var useBinaryEnvelope = false;
      try {
        chunks = MessageFragmenter.fragmentBytes(jsonBytes, mtuSize, msgId);
        if (chunks.isEmpty) {
          useBinaryEnvelope = true;
        } else if (chunks.length == 1) {
          singleChunk = chunks.first;
        } else {
          useBinaryEnvelope = true;
        }
      } catch (e) {
        _logger.fine(
          '⚠️ Chunk fragmentation failed (fallback to binary envelope): $e',
        );
        useBinaryEnvelope = true;
      }
      _logger.info(
        '${useBinaryEnvelope ? "Using binary envelope" : "Single-chunk fast path"} for message: $msgId',
      );

      final ackCompleter = _ackTracker.track(
        msgId,
        onTimeout: (timedOutId) {
          _logger.warning('Message timeout: $timedOutId');
        },
      );

      if (useBinaryEnvelope) {
        await sendBinaryPayload(
          data: jsonBytes,
          mtuSize: mtuSize,
          originalType: BinaryPayloadType.protocolMessage,
          recipientId: finalRecipientId,
          sendChunk: (chunkData) async {
            if (_centralWrite != null) {
              await _centralWrite(
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
        );
      } else if (singleChunk != null) {
        await _chunkSender.sendChunks(
          messageId: msgId,
          fragments: [singleChunk],
          sendChunk: (chunkData) async {
            if (_centralWrite != null) {
              await _centralWrite(
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
            _logger.fine('📨 SEND STEP 5.1: Converting chunk 1/1 to bytes');
            _logger.fine(
              '📨 SEND STEP 5.1a: Chunk format: ${chunk.messageId}|${chunk.chunkIndex}|${chunk.totalChunks}|${chunk.isBinary ? "1" : "0"}|[${chunk.content.length} chars]',
            );
            _logger.fine(
              '📨 SEND STEP 5.1b: Chunk 1 → ${chunk.toBytes().length} bytes',
            );
          },
          onAfterSend: (index, _) {
            _logger.fine(
              '📨 SEND STEP 6.1✅: Chunk written to BLE successfully',
            );
          },
        );
      }

      _logger.info(
        'Message send dispatched for $msgId (${useBinaryEnvelope ? "binary envelope" : "chunk path"}), waiting for ACK...',
      );
      final success = await ackCompleter.future;
      onMessageSent?.call(msgId, success);
      onMessageSentIds?.call(MessageId(msgId), success);
      return success;
    } catch (e, stackTrace) {
      _logger.severe('Failed to send message: $e');
      _logger.severe('Stack trace: $stackTrace');
      onMessageSent?.call(msgId, false);
      onMessageSentIds?.call(MessageId(msgId), false);
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
    void Function(String messageId, bool success)? onMessageSent,
    void Function(MessageId messageId, bool success)? onMessageSentIds,
  }) async {
    final msgId = messageId ?? DateTime.now().millisecondsSinceEpoch.toString();

    try {
      final contactKey = (contactPublicKey?.isNotEmpty ?? false)
          ? contactPublicKey
          : recipientId;
      final identities = await _resolveMessageIdentities(
        contactPublicKey: contactKey,
        contactRepository: contactRepository,
        stateManager: stateManager,
      );

      final finalRecipientId = identities.intendedRecipient;
      final finalSenderIf = identities.originalSender;
      final encryptionKey = (contactPublicKey?.isNotEmpty ?? false)
          ? contactPublicKey!
          : finalRecipientId;

      if (finalRecipientId.isEmpty) {
        _logger.severe(
          '❌ PERIPHERAL SEND ABORTED: Intended recipient is empty; cannot send message $msgId',
        );
        throw Exception('Intended recipient not set');
      }

      String payload = message;
      String encryptionMethod = 'none';
      EncryptionMethod? encryptionDecision;
      CryptoHeader? explicitCryptoHeader;

      if (encryptionKey.isNotEmpty) {
        encryptionDecision = await _securityService.getEncryptionMethod(
          encryptionKey,
          contactRepository,
        );
        payload = await _securityService.encryptMessageByType(
          message,
          encryptionKey,
          contactRepository,
          encryptionDecision.type,
        );
        encryptionMethod = _wireMethodForType(encryptionDecision.type);
        _logger.info(
          '🔒 PERIPHERAL MESSAGE: Encrypted with ${encryptionMethod.toUpperCase()} method',
        );
      } else {
        _logger.severe(
          '❌ PERIPHERAL SEND ABORTED: No encryption key available for message $msgId',
        );
        throw Exception('Cannot send message without encryption key');
      }

      final upgradedPeerObserved = _hasUpgradedPeerProtocolFloor(
        recipientId: finalRecipientId,
        contactLookupKey: encryptionKey,
      );
      final shouldAttemptSealedFallback =
          _isLegacyEncryptionType(encryptionDecision.type) &&
          (_enableSealedV1Send ||
              upgradedPeerObserved ||
              !_allowLegacyV2Send);

      if (shouldAttemptSealedFallback) {
        final sealedResult = await _tryEncryptWithSealedV1(
          plaintext: message,
          messageId: msgId,
          senderId: finalSenderIf,
          recipientId: finalRecipientId,
          contactLookupKey: encryptionKey,
          contactRepository: contactRepository,
        );
        if (sealedResult != null) {
          payload = sealedResult.payloadBase64;
          encryptionMethod = 'sealed';
          explicitCryptoHeader = sealedResult.header;
          _logger.info(
            '🔒 PERIPHERAL MESSAGE: Switched to SEALED_V1 offline lane (${_safeTruncate(msgId, 16)})',
          );
        }
      }

      SecurityLevel trustLevel;
      try {
        trustLevel = await _securityService.getCurrentLevel(
          encryptionKey,
          contactRepository,
        );
      } catch (e) {
        _logger.warning(
          '🔒 PERIPHERAL: Failed to get security level: $e, defaulting to LOW',
        );
        trustLevel = SecurityLevel.low;
      }

      final signingInfo = SigningManager.getSigningInfo(trustLevel);

      if (signingInfo.useEphemeralSigning && signingInfo.signingKey == null) {
        _logger.warning(
          '⚠️ PERIPHERAL: Ephemeral signing key not available - message will not be signed',
        );
      }

      final protocolMessage = ProtocolMessage.textMessage(
        messageId: msgId,
        content: payload,
        encrypted: encryptionMethod != 'none',
        recipientId: finalRecipientId,
        useEphemeralAddressing: useEphemeralAddressing,
      );

      final intendedRecipientPayload =
          originalIntendedRecipient ?? finalRecipientId;
      final allowLegacyV2ForMessage = _allowLegacyV2ForMessage(
        recipientId: finalRecipientId,
        contactLookupKey: encryptionKey,
        transportSide: 'peripheral',
        messageId: msgId,
      );
      final cryptoHeader =
          explicitCryptoHeader ??
          _buildCryptoHeader(
            encryptionMethod: encryptionMethod,
            sessionId: encryptionMethod == 'noise'
                ? (encryptionDecision.publicKey ?? encryptionKey)
                : null,
            messageId: msgId,
            transportSide: 'peripheral',
            allowLegacyV2ForMessage: allowLegacyV2ForMessage,
          );

      final legacyPayload = {
        ...protocolMessage.payload,
        'encryptionMethod': encryptionMethod,
        'intendedRecipient': intendedRecipientPayload,
        'originalSender': finalSenderIf,
        'senderId': finalSenderIf,
        if (cryptoHeader != null) 'crypto': cryptoHeader.toJson(),
      };

      final unsignedMessage = ProtocolMessage(
        type: protocolMessage.type,
        version: 2,
        payload: legacyPayload,
        timestamp: protocolMessage.timestamp,
        useEphemeralSigning: signingInfo.useEphemeralSigning,
        ephemeralSigningKey: signingInfo.signingKey,
      );
      final signaturePayload = SigningManager.signaturePayloadForMessage(
        unsignedMessage,
        fallbackContent: message,
      );
      final signature = SigningManager.signMessage(
        signaturePayload,
        trustLevel,
      );
      final finalMessage = ProtocolMessage(
        type: unsignedMessage.type,
        version: unsignedMessage.version,
        payload: unsignedMessage.payload,
        timestamp: unsignedMessage.timestamp,
        signature: signature,
        useEphemeralSigning: unsignedMessage.useEphemeralSigning,
        ephemeralSigningKey: unsignedMessage.ephemeralSigningKey,
      );

      _logger.info(
        '🔧 PERIPHERAL SEND DEBUG: Message ID: ${_safeTruncate(msgId, 16)}...',
      );
      _logger.info(
        '🔧 PERIPHERAL SEND DEBUG: Recipient ID: ${_safeTruncate(finalRecipientId, 16, fallback: "NOT SPECIFIED")}...',
      );
      _logger.info(
        '🔧 PERIPHERAL SEND DEBUG: Addressing: ${useEphemeralAddressing ? "EPHEMERAL" : "PERSISTENT"}',
      );
      _logger.info(
        '🔧 PERIPHERAL SEND DEBUG: Intended recipient: ${_safeTruncate(contactKey, 16, fallback: "NOT SPECIFIED")}...',
      );
      _logger.info(
        '🔧 PERIPHERAL SEND DEBUG: Current node ID: ${_safeTruncate(_currentNodeId, 16, fallback: "NOT SET")}...',
      );
      _logger.info(
        '🔧 PERIPHERAL SEND DEBUG: Encryption method: $encryptionMethod',
      );

      final jsonBytes = finalMessage.toBytes();
      List<MessageChunk>? chunks;
      MessageChunk? singleChunk;
      var useBinaryEnvelope = false;
      try {
        chunks = MessageFragmenter.fragmentBytes(jsonBytes, mtuSize, msgId);
        if (chunks.isEmpty) {
          useBinaryEnvelope = true;
        } else if (chunks.length == 1) {
          singleChunk = chunks.first;
        } else {
          useBinaryEnvelope = true;
        }
      } catch (e) {
        _logger.fine(
          '⚠️ Peripheral chunk fragmentation failed (fallback to binary envelope): $e',
        );
        useBinaryEnvelope = true;
      }
      _logger.info(
        '${useBinaryEnvelope ? "Using binary envelope" : "Single-chunk fast path"} for peripheral message: $msgId',
      );

      if (useBinaryEnvelope) {
        await sendBinaryPayload(
          data: jsonBytes,
          mtuSize: mtuSize,
          originalType: BinaryPayloadType.protocolMessage,
          recipientId: finalRecipientId,
          sendChunk: (chunkData) async {
            if (_peripheralWrite != null) {
              await _peripheralWrite(
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
        );
      } else if (singleChunk != null) {
        await _chunkSender.sendChunks(
          messageId: msgId,
          fragments: [singleChunk],
          sendChunk: (chunkData) async {
            if (_peripheralWrite != null) {
              await _peripheralWrite(
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
            _logger.info('Sending peripheral chunk 1/1 for message: $msgId');
            _logger.fine(
              'Peripheral chunk size: ${chunk.toBytes().length} bytes',
            );
          },
        );
      }

      _logger.info(
        'Peripheral message dispatched for $msgId (${useBinaryEnvelope ? "binary envelope" : "chunk path"})',
      );
      onMessageSent?.call(msgId, true);
      onMessageSentIds?.call(MessageId(msgId), true);
      return true;
    } catch (e, stackTrace) {
      _logger.severe('Failed to send peripheral message: $e');
      _logger.severe('Stack trace: $stackTrace');
      onMessageSent?.call(msgId, false);
      onMessageSentIds?.call(MessageId(msgId), false);
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
    _logger.fine('🔧 SEND DEBUG: ===== MESSAGE SENDING ANALYSIS =====');
    _logger.fine('🔧 SEND DIAGNOSTIC: Message ID length: ${msgId.length}');
    _logger.fine(
      '🔧 SEND DIAGNOSTIC: Contact key length: ${contactPublicKey?.length ?? 0}',
    );
    _logger.fine(
      '🔧 SEND DIAGNOSTIC: Current node length: ${currentNodeId?.length ?? 0}',
    );

    _logger.fine('🔧 SEND DEBUG: Message ID: ${_safeTruncate(msgId, 16)}...');
    _logger.fine(
      '🔧 SEND DEBUG: Recipient ID: ${_safeTruncate(recipientId, 16, fallback: "NOT SPECIFIED")}...',
    );
    _logger.fine(
      '🔧 SEND DEBUG: Addressing: ${useEphemeralAddressing ? "EPHEMERAL" : "PERSISTENT"}',
    );
    _logger.fine(
      '🔧 SEND DEBUG: Intended recipient: ${_safeTruncate(contactPublicKey, 16, fallback: "NOT SPECIFIED")}...',
    );
    _logger.fine(
      '🔧 SEND DEBUG: Current node ID: ${_safeTruncate(currentNodeId, 16, fallback: "NOT SET")}...',
    );
    _logger.fine('🔧 SEND DEBUG: Encryption method: $encryptionMethod');
    _logger.fine(
      '🔧 SEND DEBUG: Message content: "${_safeTruncate(message, 50)}..."',
    );
    _logger.fine('🔧 SEND DEBUG: ===== END SENDING ANALYSIS =====');
  }

  String _wireMethodForType(EncryptionType type) {
    switch (type) {
      case EncryptionType.noise:
        return 'noise';
      case EncryptionType.ecdh:
        return 'ecdh';
      case EncryptionType.pairing:
        return 'pairing';
      case EncryptionType.global:
        return 'global';
    }
  }

  bool _isLegacyEncryptionType(EncryptionType type) {
    return type == EncryptionType.ecdh ||
        type == EncryptionType.pairing ||
        type == EncryptionType.global;
  }

  Future<_SealedPayload?> _tryEncryptWithSealedV1({
    required String plaintext,
    required String messageId,
    required String senderId,
    required String recipientId,
    required String contactLookupKey,
    required ContactRepository contactRepository,
  }) async {
    if (senderId.isEmpty || recipientId.isEmpty || contactLookupKey.isEmpty) {
      return null;
    }

    final contact = await contactRepository.getContactByAnyId(contactLookupKey);
    final recipientNoisePublicKey = contact?.noisePublicKey;
    if (recipientNoisePublicKey == null || recipientNoisePublicKey.isEmpty) {
      _logger.fine(
        '🔒 SEALED_V1 unavailable: no recipient noise key for ${_safeTruncate(contactLookupKey, 12)}',
      );
      return null;
    }

    Uint8List recipientStaticKeyBytes;
    try {
      recipientStaticKeyBytes = Uint8List.fromList(
        base64.decode(recipientNoisePublicKey),
      );
    } catch (error) {
      _logger.warning(
        '🔒 SEALED_V1 unavailable: invalid recipient noise key encoding for ${_safeTruncate(contactLookupKey, 12)}: $error',
      );
      return null;
    }

    if (recipientStaticKeyBytes.length != 32) {
      _logger.warning(
        '🔒 SEALED_V1 unavailable: recipient noise key has invalid length (${recipientStaticKeyBytes.length}) for ${_safeTruncate(contactLookupKey, 12)}',
      );
      return null;
    }

    try {
      final aad = _buildSealedV1Aad(
        messageId: messageId,
        senderId: senderId,
        recipientId: recipientId,
      );
      final sealed = await _sealedEncryptionService.encrypt(
        plaintext: Uint8List.fromList(utf8.encode(plaintext)),
        recipientPublicKey: recipientStaticKeyBytes,
        aad: aad,
      );

      return _SealedPayload(
        payloadBase64: base64.encode(sealed.ciphertext),
        header: CryptoHeader(
          mode: CryptoMode.sealedV1,
          modeVersion: 1,
          keyId: sealed.keyId,
          ephemeralPublicKey: base64.encode(sealed.ephemeralPublicKey),
          nonce: base64.encode(sealed.nonce),
        ),
      );
    } catch (error) {
      _logger.warning(
        '🔒 SEALED_V1 encryption failed for ${_safeTruncate(contactLookupKey, 12)}: $error',
      );
      return null;
    }
  }

  Uint8List _buildSealedV1Aad({
    required String messageId,
    required String senderId,
    required String recipientId,
  }) {
    final context = 'v2|$messageId|$senderId|$recipientId|sealed_v1';
    return Uint8List.fromList(utf8.encode(context));
  }

  CryptoHeader? _buildCryptoHeader({
    required String encryptionMethod,
    required String? sessionId,
    required String messageId,
    required String transportSide,
    required bool allowLegacyV2ForMessage,
  }) {
    final mode = _mapEncryptionMethodToMode(encryptionMethod);
    if (mode == null) {
      return null;
    }
    if (_isLegacyMode(mode)) {
      if (!allowLegacyV2ForMessage) {
        throw StateError(
          'Legacy v2 send mode blocked by policy: $encryptionMethod '
          '(messageId=$messageId). Enable PAKCONNECT_ALLOW_LEGACY_V2_SEND=true '
          'temporarily during migration.',
        );
      }
      _logger.warning(
        '🔒 POLICY: Emitting legacy v2 mode ${mode.wireValue} for '
        '$transportSide message ${_safeTruncate(messageId, 16)} '
        '(compatibility mode enabled)',
      );
    }
    return CryptoHeader(mode: mode, modeVersion: 1, sessionId: sessionId);
  }

  bool _allowLegacyV2ForMessage({
    required String recipientId,
    required String contactLookupKey,
    required String transportSide,
    required String messageId,
  }) {
    if (!_allowLegacyV2Send) {
      return false;
    }
    if (!PeerProtocolVersionGuard.isEnabled) {
      return true;
    }

    final peerCandidates = <String>{recipientId, contactLookupKey}
      ..removeWhere((candidate) => candidate.isEmpty);
    for (final candidate in peerCandidates) {
      final floor = PeerProtocolVersionGuard.floorForPeer(candidate);
      if (floor >= 2) {
        _logger.warning(
          '🔒 POLICY: Blocking legacy v2 mode for upgraded peer '
          '${_safeTruncate(candidate, 12)} on $transportSide send '
          '(messageId=${_safeTruncate(messageId, 16)}, floor=v$floor)',
        );
        return false;
      }
    }
    return true;
  }

  bool _hasUpgradedPeerProtocolFloor({
    required String recipientId,
    required String contactLookupKey,
  }) {
    if (!PeerProtocolVersionGuard.isEnabled) {
      return false;
    }
    final peerCandidates = <String>{recipientId, contactLookupKey}
      ..removeWhere((candidate) => candidate.isEmpty);
    for (final candidate in peerCandidates) {
      if (PeerProtocolVersionGuard.floorForPeer(candidate) >= 2) {
        return true;
      }
    }
    return false;
  }

  bool _isLegacyMode(CryptoMode mode) {
    return mode == CryptoMode.legacyEcdhV1 ||
        mode == CryptoMode.legacyPairingV1 ||
        mode == CryptoMode.legacyGlobalV1;
  }

  CryptoMode? _mapEncryptionMethodToMode(String encryptionMethod) {
    switch (encryptionMethod) {
      case 'noise':
        return CryptoMode.noiseV1;
      case 'sealed':
        return CryptoMode.sealedV1;
      case 'ecdh':
        return CryptoMode.legacyEcdhV1;
      case 'pairing':
        return CryptoMode.legacyPairingV1;
      case 'global':
        return CryptoMode.legacyGlobalV1;
      case 'none':
        return CryptoMode.none;
      default:
        return null;
    }
  }

  Future<_MessageIdentities> _resolveMessageIdentities({
    required String? contactPublicKey,
    required ContactRepository contactRepository,
    required BLEStateManager stateManager,
  }) async {
    final normalizedContactKey = _normalizeContactKey(contactPublicKey);
    final userPrefs = UserPreferences();
    final hintsEnabled = await userPrefs.getHintBroadcastEnabled();

    final myPersistentKey = await userPrefs.getPublicKey();
    final mySessionEphemeral =
        EphemeralKeyManager.currentSessionKey ??
        EphemeralKeyManager.generateMyEphemeralKey();

    final contact = normalizedContactKey != null
        ? await contactRepository.getContact(normalizedContactKey)
        : null;

    final noiseSessionExists =
        contact?.currentEphemeralId != null &&
        _securityService.hasEstablishedNoiseSession(
          contact!.currentEphemeralId!,
        );

    // Security-aware identity selection:
    // - Medium/High: use persistent keys when available
    // - Low (or no persistent): use session ephemeral keys
    SecurityLevel securityLevel = SecurityLevel.low;
    try {
      securityLevel = await _securityService.getCurrentLevel(
        normalizedContactKey ?? '',
        contactRepository,
      );
    } catch (_) {
      // Default to low if lookup fails
      securityLevel = SecurityLevel.low;
    }

    // Spy mode forces ephemeral IDs to prevent long-term tracking
    final isSpyMode = !hintsEnabled && noiseSessionExists;

    final prefersPersistent =
        !isSpyMode &&
        (securityLevel == SecurityLevel.high ||
            securityLevel == SecurityLevel.medium) &&
        (contact?.persistentPublicKey?.isNotEmpty ?? false);

    final originalSender = prefersPersistent
        ? myPersistentKey
        : (mySessionEphemeral.isNotEmpty
              ? mySessionEphemeral
              : myPersistentKey);

    // Recipient resolution order with security level awareness:
    // Medium/High: persistent (if present), else session ephemeral.
    // Low: session ephemeral first, then fallbacks.
    String intendedRecipient = '';

    if (prefersPersistent) {
      intendedRecipient = contact?.persistentPublicKey?.isNotEmpty == true
          ? contact!.persistentPublicKey!
          : '';
    }

    if (intendedRecipient.isEmpty &&
        (contact?.currentEphemeralId?.isNotEmpty ?? false)) {
      intendedRecipient = contact!.currentEphemeralId!;
    }

    if (intendedRecipient.isEmpty && (contact?.publicKey.isNotEmpty ?? false)) {
      intendedRecipient = contact!.publicKey;
    }

    if (intendedRecipient.isEmpty &&
        normalizedContactKey != null &&
        normalizedContactKey.isNotEmpty) {
      intendedRecipient = normalizedContactKey;
    }

    // Fallback: if we still have nothing, use our current session as a last
    // resort, but abort later if that would address the message to ourselves.
    if (intendedRecipient.isEmpty && _safeNodeId != null) {
      intendedRecipient = _safeNodeId!;
    }

    // Prevent misaddressing to ourselves (observed as “NOT SPECIFIED”/self
    // sends). If the resolved recipient matches our node ID, clear it so the
    // caller can abort instead of silently looping.
    if (intendedRecipient.isEmpty ||
        (_safeNodeId != null && intendedRecipient == _safeNodeId)) {
      _logger.severe(
        '❌ Recipient resolution failed (resolved to self or empty) for contact ${contactPublicKey?.shortId(8) ?? "UNKNOWN"}',
      );
      intendedRecipient = '';
    }

    return _MessageIdentities(
      originalSender: originalSender,
      intendedRecipient: intendedRecipient,
      isSpyMode: isSpyMode,
    );
  }

  String? _normalizeContactKey(String? contactKey) {
    if (contactKey == null || contactKey.isEmpty) return contactKey;
    if (contactKey.startsWith('repo_') && contactKey.length > 5) {
      return contactKey.substring(5);
    }
    return contactKey;
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

  /// Send raw binary payload using binary fragment envelopes.
  ///
  /// - [originalType] should map to your FILE/media message type.
  /// - [recipientId] optional; if null/empty treated as broadcast/unknown.
  /// - Respects negotiated [mtuSize]; throws if MTU cannot fit header + data.
  Future<void> sendBinaryPayload({
    required Uint8List data,
    required int mtuSize,
    required int originalType,
    String? recipientId,
    required Future<void> Function(Uint8List data) sendChunk,
  }) async {
    final frags = BinaryFragmenter.fragment(
      data: data,
      mtu: mtuSize,
      originalType: originalType,
      recipient: recipientId,
    );
    for (var i = 0; i < frags.length; i++) {
      _logger.fine(
        '📤 Sending binary fragment ${i + 1}/${frags.length} (${frags[i].length} bytes)',
      );
      await sendChunk(frags[i]);
      if (i < frags.length - 1) {
        await Future.delayed(Duration(milliseconds: 20));
      }
    }
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

class _SealedPayload {
  final String payloadBase64;
  final CryptoHeader header;

  _SealedPayload({required this.payloadBase64, required this.header});
}
