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
import '../../core/utils/binary_fragmenter.dart';
import '../../core/constants/binary_payload_types.dart';
import '../../domain/values/id_types.dart';

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

      if (encryptionKey.isNotEmpty) {
        try {
          payload = await SecurityManager.instance.encryptMessage(
            message,
            encryptionKey,
            contactRepository,
          );
          encryptionMethod = await _getSimpleEncryptionMethod(
            encryptionKey,
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
        _logger.info(
          '🔒 MESSAGE: No encryption key resolved, sending unencrypted',
        );
      }

      SecurityLevel trustLevel;
      try {
        trustLevel = await SecurityManager.instance.getCurrentLevel(
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
      final signature = SigningManager.signMessage(message, trustLevel);

      final protocolMessage = ProtocolMessage.textMessage(
        messageId: msgId,
        content: payload,
        encrypted: encryptionMethod != 'none',
        recipientId: finalRecipientId,
        useEphemeralAddressing: useEphemeralAddressing,
      );

      final intendedRecipientPayload =
          originalIntendedRecipient ?? finalRecipientId;

      final legacyPayload = {
        ...protocolMessage.payload,
        'encryptionMethod': encryptionMethod,
        'intendedRecipient': intendedRecipientPayload,
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
        );
      } else if (singleChunk != null) {
        await _chunkSender.sendChunks(
          messageId: msgId,
          fragments: [singleChunk],
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
            print('📨 SEND STEP 5.1: Converting chunk 1/1 to bytes');
            print(
              '📨 SEND STEP 5.1a: Chunk format: ${chunk.messageId}|${chunk.chunkIndex}|${chunk.totalChunks}|${chunk.isBinary ? "1" : "0"}|[${chunk.content.length} chars]',
            );
            print(
              '📨 SEND STEP 5.1b: Chunk 1 → ${chunk.toBytes().length} bytes',
            );
          },
          onAfterSend: (index, _) {
            print('📨 SEND STEP 6.1✅: Chunk written to BLE successfully');
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

      if (encryptionKey.isNotEmpty) {
        try {
          payload = await SecurityManager.instance.encryptMessage(
            message,
            encryptionKey,
            contactRepository,
          );
          encryptionMethod = await _getSimpleEncryptionMethod(
            encryptionKey,
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
          '🔒 PERIPHERAL MESSAGE: No encryption key resolved, sending unencrypted',
        );
      }

      SecurityLevel trustLevel;
      try {
        trustLevel = await SecurityManager.instance.getCurrentLevel(
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
      final signature = SigningManager.signMessage(message, trustLevel);

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

      final legacyPayload = {
        ...protocolMessage.payload,
        'encryptionMethod': encryptionMethod,
        'intendedRecipient': intendedRecipientPayload,
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
        );
      } else if (singleChunk != null) {
        await _chunkSender.sendChunks(
          messageId: msgId,
          fragments: [singleChunk],
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

    final contact = await contactRepository.getContactByAnyId(contactPublicKey);
    final sessionLookupKey = contact?.sessionIdForNoise ?? contactPublicKey;
    final hasNoise =
        SecurityManager.instance.noiseService?.hasEstablishedSession(
          sessionLookupKey,
        ) ==
        true;
    if (hasNoise) {
      return 'noise';
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
        SecurityManager.instance.noiseService?.hasEstablishedSession(
              contact!.currentEphemeralId!,
            ) ==
            true;

    // Security-aware identity selection:
    // - Medium/High: use persistent keys when available
    // - Low (or no persistent): use session ephemeral keys
    SecurityLevel securityLevel = SecurityLevel.low;
    try {
      securityLevel = await SecurityManager.instance.getCurrentLevel(
        normalizedContactKey ?? '',
        contactRepository,
      );
    } catch (_) {
      // Default to low if lookup fails
      securityLevel = SecurityLevel.low;
    }

    final prefersPersistent =
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
      isSpyMode: !hintsEnabled && noiseSessionExists,
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
