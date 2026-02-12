import 'dart:async';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/interfaces/i_protocol_message_handler.dart';
import 'package:pak_connect/domain/interfaces/i_identity_manager.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/crypto_header.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/protocol_message.dart'
    as domain_models;
import 'package:pak_connect/domain/models/protocol_message_type.dart';
import '../../domain/services/ephemeral_key_manager.dart';
import '../../domain/services/signing_manager.dart';
import '../../data/repositories/contact_repository.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';

/// Handles protocol message parsing and dispatching
///
/// Responsibilities:
/// - Parsing protocol messages (contact requests, verifications, queue sync, etc.)
/// - Message type dispatch to appropriate handlers
/// - Message decryption and signature verification
/// - Identity resolution (sender and recipient identification)
/// - Contact request/accept/reject lifecycle
/// - Crypto verification request/response handling
class ProtocolMessageHandler implements IProtocolMessageHandler {
  static IIdentityManager? Function()? _identityManagerResolver;

  static void configureIdentityManagerResolver(
    IIdentityManager? Function() resolver,
  ) {
    _identityManagerResolver = resolver;
  }

  static void clearIdentityManagerResolver() {
    _identityManagerResolver = null;
  }

  final _logger = Logger('ProtocolMessageHandler');
  final ContactRepository _contactRepository;
  final ISecurityService _securityService;

  ProtocolMessageHandler({
    required ISecurityService securityService,
    ContactRepository? contactRepository,
  }) : _securityService = securityService,
       _contactRepository = contactRepository ?? ContactRepository();

  // Callbacks
  Function(String, String)? _onContactRequestReceived;
  Function(String, String)? _onContactAcceptReceived;
  Function()? _onContactRejectReceived;
  Function(String, String)? _onCryptoVerificationReceived;
  Function(String, String, bool, Map<String, dynamic>?)?
  _onCryptoVerificationResponseReceived;
  Function(String)? _onIdentityRevealed;

  // Queue sync callbacks (registered by relay coordinator)
  Function(QueueSyncMessage, String)? _onQueueSyncReceived;
  Function(domain_models.ProtocolMessage message)? _onSendAckMessage;
  Future<void> Function(
    String content,
    String? messageId,
    String? senderNodeId,
  )?
  _onTextMessageReceived;

  String? _currentNodeId;
  String _encryptionMethod = 'none';
  static const bool _allowLegacyV1DecryptFallback = true;

  /// Sets current node ID for routing and identity checks
  void setCurrentNodeId(String nodeId) {
    _currentNodeId = nodeId;
    final previewLength = nodeId.length >= 8 ? 8 : nodeId.length;
    final preview = nodeId.substring(0, previewLength);
    _logger.fine('📍 Current node ID set: $preview...');
  }

  /// Processes a received protocol message
  @override
  Future<String?> processProtocolMessage({
    required domain_models.ProtocolMessage message,
    required String fromDeviceId,
    required String fromNodeId,
    String? transportMessageId,
  }) async {
    try {
      return await _processProtocolMessage(
        message,
        fromNodeId,
        transportMessageId,
      );
    } catch (e) {
      _logger.severe('Failed to process protocol message: $e');
      return null;
    }
  }

  /// Processes a complete protocol message (after reassembly)
  @override
  Future<String?> processCompleteProtocolMessage({
    required String content,
    required String fromDeviceId,
    required String fromNodeId,
    required Map<String, dynamic>? messageData,
    String? transportMessageId,
  }) async {
    try {
      final protocolMessage = domain_models.ProtocolMessage.fromBytes(
        Uint8List.fromList(content.codeUnits),
      );
      return await _processProtocolMessage(
        protocolMessage,
        fromNodeId,
        transportMessageId,
      );
    } catch (e) {
      _logger.severe('Failed to process complete protocol message: $e');
      return null;
    }
  }

  /// Handles direct protocol messages (not relayed)
  @override
  Future<String?> handleDirectProtocolMessage({
    required domain_models.ProtocolMessage message,
    required String fromDeviceId,
    String? transportMessageId,
  }) async {
    try {
      return await _processProtocolMessage(
        message,
        fromDeviceId,
        transportMessageId,
      );
    } catch (e) {
      _logger.severe('Failed to handle direct protocol message: $e');
      return null;
    }
  }

  /// Main protocol message processing dispatcher
  Future<String?> _processProtocolMessage(
    domain_models.ProtocolMessage message,
    String fromNodeId,
    String? transportMessageId,
  ) async {
    switch (message.type) {
      case ProtocolMessageType.textMessage:
        return await _handleTextMessage(
          message,
          fromNodeId,
          transportMessageId,
        );

      case ProtocolMessageType.ack:
        // ACKs are handled by fragmentation handler
        return null;

      case ProtocolMessageType.contactRequest:
        return await _handleContactRequest(message);

      case ProtocolMessageType.contactAccept:
        return await _handleContactAccept(message);

      case ProtocolMessageType.contactReject:
        return await _handleContactReject();

      case ProtocolMessageType.cryptoVerification:
        return await _handleCryptoVerification(message);

      case ProtocolMessageType.cryptoVerificationResponse:
        return await _handleCryptoVerificationResponse(message);

      case ProtocolMessageType.queueSync:
        return await _handleQueueSync(message, fromNodeId, transportMessageId);

      case ProtocolMessageType.friendReveal:
        return await _handleFriendReveal(message);

      case ProtocolMessageType.ping:
        _logger.fine('📍 Received protocol ping');
        return null;

      case ProtocolMessageType.relayAck:
        // Handled by relay coordinator
        return null;

      default:
        _logger.warning('Unknown protocol message type: ${message.type}');
        return null;
    }
  }

  /// Handles text message reception with decryption and signature verification
  Future<String?> _handleTextMessage(
    domain_models.ProtocolMessage message,
    String fromNodeId,
    String? transportMessageId,
  ) async {
    try {
      final messageId = message.textMessageId!;
      final content = message.textContent!;
      final intendedRecipient = message.payload['intendedRecipient'] as String?;
      final declaredSenderId =
          message.senderId ??
          (message.payload['originalSender'] as String?) ??
          fromNodeId;
      final resolvedSenderId = await _resolveSenderKey(declaredSenderId);
      final decryptionPeerId = (resolvedSenderId?.isNotEmpty ?? false)
          ? resolvedSenderId!
          : fromNodeId;

      // Check if message is for us
      final isForMe = await isMessageForMe(intendedRecipient);
      if (!isForMe) {
        _logger.fine('💬 Message not for us, ignoring');
        return null;
      }

      // Decrypt if needed
      String decryptedContent = content;
      if (message.isEncrypted && decryptionPeerId.isNotEmpty) {
        try {
          if (message.version >= 2) {
            final cryptoHeader = message.cryptoHeader;
            if (cryptoHeader == null) {
              _logger.severe(
                '🔒 v2 encrypted message missing crypto header: $messageId',
              );
              return null;
            }
            final encryptionType = _encryptionTypeForMode(cryptoHeader.mode);
            if (encryptionType == null) {
              _logger.severe(
                '🔒 v2 encrypted message has unsupported crypto mode: ${cryptoHeader.mode.wireValue}',
              );
              return null;
            }
            decryptedContent = await _securityService.decryptMessageByType(
              content,
              decryptionPeerId,
              _contactRepository,
              encryptionType,
            );
          } else {
            if (!_allowLegacyV1DecryptFallback) {
              _logger.warning(
                '🔒 Legacy v1 decrypt fallback disabled. Rejecting message: $messageId',
              );
              return null;
            }
            decryptedContent = await _securityService.decryptMessage(
              content,
              decryptionPeerId,
              _contactRepository,
            );
          }
          _logger.fine('🔒 Message decrypted successfully');
        } catch (e) {
          _logger.warning(
            '🔒 Decryption failed for ${decryptionPeerId.shortId(8)} (v${message.version}): $e',
          );
          return null;
        }
      }

      // Verify signature
      if (message.signature != null) {
        String verifyingKey;
        if (message.useEphemeralSigning) {
          if (message.ephemeralSigningKey == null ||
              message.ephemeralSigningKey!.isEmpty) {
            if (message.version >= 2) {
              _logger.severe(
                '❌ v2 ephemeral signature missing signing key for message $messageId',
              );
              return '[❌ UNTRUSTED MESSAGE - Missing ephemeral signing key]';
            }
            verifyingKey = decryptionPeerId;
          } else {
            verifyingKey = message.ephemeralSigningKey!;
          }
        } else {
          verifyingKey = decryptionPeerId;
        }

        final isValid = SigningManager.verifySignature(
          decryptedContent,
          message.signature!,
          verifyingKey,
          message.useEphemeralSigning,
        );

        if (!isValid) {
          _logger.severe('❌ Signature verification failed');
          return '[❌ UNTRUSTED MESSAGE - Invalid signature]';
        }

        _logger.fine(
          '✅ Signature verified (${message.useEphemeralSigning ? "ephemeral" : "real"})',
        );
      }

      _sendAck(messageId, fromNodeId);
      final textCallback = _onTextMessageReceived;
      if (textCallback != null) {
        try {
          await textCallback(
            decryptedContent,
            messageId,
            decryptionPeerId.isNotEmpty ? decryptionPeerId : null,
          );
        } catch (e, stack) {
          _logger.warning('⚠️ Inbound text callback failed: $e', e, stack);
        }
      }
      return decryptedContent;
    } catch (e) {
      _logger.severe('Failed to handle text message: $e');
      return null;
    }
  }

  /// Handles incoming contact request
  Future<String?> _handleContactRequest(
    domain_models.ProtocolMessage message,
  ) async {
    try {
      final publicKey = message.contactRequestPublicKey;
      final displayName = message.contactRequestDisplayName;

      if (publicKey != null && displayName != null) {
        _logger.info('📱 Contact request received from $displayName');
        _onContactRequestReceived?.call(publicKey, displayName);
      }
      return null;
    } catch (e) {
      _logger.severe('Failed to handle contact request: $e');
      return null;
    }
  }

  /// Handles incoming contact accept
  Future<String?> _handleContactAccept(
    domain_models.ProtocolMessage message,
  ) async {
    try {
      final publicKey = message.contactAcceptPublicKey;
      final displayName = message.contactAcceptDisplayName;

      if (publicKey != null && displayName != null) {
        _logger.info('✅ Contact accept received from $displayName');
        _onContactAcceptReceived?.call(publicKey, displayName);
      }
      return null;
    } catch (e) {
      _logger.severe('Failed to handle contact accept: $e');
      return null;
    }
  }

  /// Handles incoming contact reject
  Future<String?> _handleContactReject() async {
    try {
      _logger.info('❌ Contact reject received');
      _onContactRejectReceived?.call();
      return null;
    } catch (e) {
      _logger.severe('Failed to handle contact reject: $e');
      return null;
    }
  }

  /// Handles crypto verification request
  Future<String?> _handleCryptoVerification(
    domain_models.ProtocolMessage message,
  ) async {
    try {
      final verificationId = message.payload['verificationId'] as String?;
      final contactKey = message.payload['contactKey'] as String?;

      if (verificationId != null && contactKey != null) {
        _logger.info('🔐 Crypto verification requested');
        _onCryptoVerificationReceived?.call(verificationId, contactKey);
      }
      return null;
    } catch (e) {
      _logger.severe('Failed to handle crypto verification: $e');
      return null;
    }
  }

  /// Handles crypto verification response
  Future<String?> _handleCryptoVerificationResponse(
    domain_models.ProtocolMessage message,
  ) async {
    try {
      final verificationId = message.payload['verificationId'] as String?;
      final contactKey = message.payload['contactKey'] as String?;
      final isVerified = (message.payload['isVerified'] as bool?) ?? false;

      if (verificationId != null && contactKey != null) {
        _logger.info(
          '🔐 Crypto verification response: ${isVerified ? "verified ✅" : "not verified ❌"}',
        );
        _onCryptoVerificationResponseReceived?.call(
          verificationId,
          contactKey,
          isVerified,
          message.payload,
        );
      }
      return null;
    } catch (e) {
      _logger.severe('Failed to handle crypto verification response: $e');
      return null;
    }
  }

  /// Handles queue sync message
  Future<String?> _handleQueueSync(
    domain_models.ProtocolMessage message,
    String fromNodeId,
    String? transportMessageId,
  ) async {
    try {
      final queueMessage = message.queueSyncMessage;
      if (queueMessage != null) {
        _onQueueSyncReceived?.call(queueMessage, fromNodeId);
        _logger.info('📦 Queue sync received');
        _sendAck(transportMessageId ?? queueMessage.queueHash, fromNodeId);
      } else {
        _logger.warning('⚠️ Queue sync payload missing expected fields');
      }
      return null;
    } catch (e) {
      _logger.severe('Failed to handle queue sync: $e');
      return null;
    }
  }

  /// Handles friend reveal (spy mode identity disclosure)
  Future<String?> _handleFriendReveal(
    domain_models.ProtocolMessage message,
  ) async {
    try {
      final contactName =
          message.payload['contactName'] as String? ??
          message.payload['myPersistentKey'] as String?;
      if (contactName != null) {
        _logger.warning('👁️ Friend reveal: $contactName');
        _onIdentityRevealed?.call(contactName);
      }
      return null;
    } catch (e) {
      _logger.severe('Failed to handle friend reveal: $e');
      return null;
    }
  }

  /// Checks if message is intended for this device
  @override
  Future<bool> isMessageForMe(String? intendedRecipient) async {
    if (intendedRecipient == null || intendedRecipient.isEmpty) {
      // Broadcast message
      return true;
    }

    if (_currentNodeId != null && intendedRecipient == _currentNodeId) {
      _logger.fine('💬 Message addressed to current nodeId');
      return true;
    }

    String? myPersistentId;
    String? sessionEphemeralId;
    String? signingEphemeralId;

    final identity = _resolveIdentityManager();
    if (identity != null) {
      myPersistentId = identity.myPersistentId ?? identity.getMyPersistentId();
      try {
        sessionEphemeralId = identity.myEphemeralId;
      } catch (_) {
        // Ephemeral manager may not be initialized yet; fall back below.
      }
    }

    sessionEphemeralId ??= EphemeralKeyManager.currentSessionKey;
    signingEphemeralId = EphemeralKeyManager.ephemeralSigningPublicKey;

    if (myPersistentId != null && intendedRecipient == myPersistentId) {
      _logger.fine('💬 Message addressed to our persistent key');
      return true;
    }

    if (sessionEphemeralId != null && intendedRecipient == sessionEphemeralId) {
      _logger.fine('💬 Message addressed to our session ephemeral key');
      return true;
    }

    if (signingEphemeralId != null && intendedRecipient == signingEphemeralId) {
      _logger.fine('💬 Message addressed to our ephemeral signing key');
      return true;
    }

    final truncatedRecipient = intendedRecipient.shortId(8);
    final truncatedNodeId = _currentNodeId?.shortId(8) ?? 'null';
    _logger.fine(
      '💬 Message not for us (recipient: $truncatedRecipient, node: $truncatedNodeId, session: ${sessionEphemeralId?.shortId(8) ?? "null"})',
    );
    return false;
  }

  IIdentityManager? _resolveIdentityManager() {
    final resolver = _identityManagerResolver;
    if (resolver == null) {
      return null;
    }
    try {
      return resolver();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolveSenderKey(String? candidateKey) async {
    if (candidateKey == null || candidateKey.isEmpty) {
      return candidateKey;
    }
    try {
      final contact = await _contactRepository.getContactByAnyId(candidateKey);
      if (contact != null) {
        final sessionId = contact.currentEphemeralId;
        final persistentKey = contact.persistentPublicKey;
        if (persistentKey != null &&
            persistentKey.isNotEmpty &&
            sessionId != null &&
            sessionId.isNotEmpty) {
          _securityService.registerIdentityMapping(
            persistentPublicKey: persistentKey,
            ephemeralID: sessionId,
          );
        }
        if (sessionId != null && sessionId.isNotEmpty) {
          return sessionId;
        }
        if (persistentKey != null && persistentKey.isNotEmpty) {
          return persistentKey;
        }
        return contact.publicKey;
      }
    } catch (e) {
      _logger.fine(
        'Sender resolution failed for ${candidateKey.shortId(8)}: $e',
      );
    }
    return candidateKey;
  }

  EncryptionType? _encryptionTypeForMode(CryptoMode mode) {
    switch (mode) {
      case CryptoMode.noiseV1:
        return EncryptionType.noise;
      case CryptoMode.legacyEcdhV1:
        return EncryptionType.ecdh;
      case CryptoMode.legacyPairingV1:
        return EncryptionType.pairing;
      case CryptoMode.legacyGlobalV1:
        return EncryptionType.global;
      case CryptoMode.none:
      case CryptoMode.sealedV1:
        return null;
    }
  }

  /// Resolves message sender and recipient identities
  @override
  Future<Map<String, dynamic>> resolveMessageIdentities({
    required String? encryptionSenderKey,
    required String? meshSenderKey,
    required String? intendedRecipient,
  }) async {
    return {
      'originalSender': encryptionSenderKey ?? meshSenderKey,
      'intendedRecipient': intendedRecipient,
      'isSpyMode': encryptionSenderKey != meshSenderKey,
    };
  }

  /// Gets current encryption method
  @override
  String getEncryptionMethod() => _encryptionMethod;

  /// Sets encryption method
  @override
  void setEncryptionMethod(String method) {
    _encryptionMethod = method;
  }

  /// Gets message encryption method
  @override
  Future<String> getMessageEncryptionMethod({
    required String senderKey,
    required String recipientKey,
  }) async {
    // This would check contact security level and return appropriate method
    // For now, return 'none' as placeholder
    return 'none';
  }

  /// Handles QR code introduction claim
  @override
  Future<void> handleQRIntroductionClaim({
    required String claimJson,
    required String fromDeviceId,
  }) async {
    _logger.fine('📱 QR introduction claim received from $fromDeviceId');
  }

  /// Checks QR introduction match
  @override
  Future<bool> checkQRIntroductionMatch({
    required String receivedHash,
    required String expectedHash,
  }) async {
    return receivedHash == expectedHash;
  }

  // ==================== CALLBACK REGISTRATION ====================

  @override
  void onContactRequestReceived(
    Function(String contactKey, String displayName) callback,
  ) {
    _onContactRequestReceived = callback;
  }

  @override
  void onContactAcceptReceived(
    Function(String contactKey, String displayName) callback,
  ) {
    _onContactAcceptReceived = callback;
  }

  @override
  void onContactRejectReceived(Function() callback) {
    _onContactRejectReceived = callback;
  }

  @override
  void onCryptoVerificationReceived(
    Function(String verificationId, String contactKey) callback,
  ) {
    _onCryptoVerificationReceived = callback;
  }

  @override
  void onCryptoVerificationResponseReceived(
    Function(
      String verificationId,
      String contactKey,
      bool isVerified,
      Map<String, dynamic>? data,
    )
    callback,
  ) {
    _onCryptoVerificationResponseReceived = callback;
  }

  @override
  void onIdentityRevealed(Function(String contactName) callback) {
    _onIdentityRevealed = callback;
  }

  @override
  void onSendAckMessage(
    Function(domain_models.ProtocolMessage message) callback,
  ) {
    _onSendAckMessage = callback;
  }

  void onTextMessageReceived(
    Future<void> Function(
      String content,
      String? messageId,
      String? senderNodeId,
    )
    callback,
  ) {
    _onTextMessageReceived = callback;
  }

  void _sendAck(String? messageId, String fromNodeId) {
    if (messageId == null || messageId.isEmpty) return;
    if (_onSendAckMessage == null) return;

    try {
      final ackMessage = domain_models.ProtocolMessage.ack(
        originalMessageId: messageId,
      );
      _onSendAckMessage!.call(ackMessage);
      _logger.info(
        '📨 ACK sent for ${messageId.shortId(8)} to ${fromNodeId.shortId(8)}',
      );
    } catch (e) {
      _logger.warning('⚠️ Failed to send ACK for ${messageId.shortId(8)}: $e');
    }
  }
}
