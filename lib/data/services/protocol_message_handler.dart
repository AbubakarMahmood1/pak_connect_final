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
import 'package:pak_connect/core/security/peer_protocol_version_guard.dart';
import '../../domain/constants/special_recipients.dart';
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
  static const bool _defaultAllowLegacyV2Decrypt = bool.fromEnvironment(
    'PAKCONNECT_ALLOW_LEGACY_V2_DECRYPT',
    defaultValue: true,
  );
  static const bool _defaultRequireV2Signature = bool.fromEnvironment(
    'PAKCONNECT_REQUIRE_V2_SIGNATURE',
    defaultValue: false,
  );
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
  final bool _allowLegacyV2Decrypt;
  final bool _requireV2Signature;

  ProtocolMessageHandler({
    required ISecurityService securityService,
    ContactRepository? contactRepository,
    bool? allowLegacyV2Decrypt,
    bool? requireV2Signature,
  }) : _securityService = securityService,
       _contactRepository = contactRepository ?? ContactRepository(),
       _allowLegacyV2Decrypt =
           allowLegacyV2Decrypt ?? _defaultAllowLegacyV2Decrypt,
       _requireV2Signature = requireV2Signature ?? _defaultRequireV2Signature;

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

  /// Test hook for isolating protocol-floor behavior between test cases.
  static void clearPeerProtocolVersionFloorForTest() {
    PeerProtocolVersionGuard.clearForTest();
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
      final resolvedDecryptSenderId = await _resolveSenderKeyForDecrypt(
        declaredSenderId,
      );
      final resolvedSignatureSenderKey = await _resolveSenderKeyForSignature(
        declaredSenderId,
      );
      final decryptionPeerId = (resolvedDecryptSenderId?.isNotEmpty ?? false)
          ? resolvedDecryptSenderId!
          : fromNodeId;
      final versionPeerKey = _versionPeerKey(
        signatureSenderKey: resolvedSignatureSenderKey,
        declaredSenderId: declaredSenderId,
        transportSenderId: fromNodeId,
      );
      if (_shouldRejectLegacyDowngrade(
        messageVersion: message.version,
        peerKey: versionPeerKey,
        messageId: messageId,
      )) {
        return null;
      }

      // Check if message is for us
      final isForMe = await isMessageForMe(intendedRecipient);
      if (!isForMe) {
        _logger.fine('💬 Message not for us, ignoring');
        return null;
      }

      if (message.version >= 2 && !message.isEncrypted) {
        final isBroadcast = _isBroadcastV2TextMessage(
          recipientId: message.recipientId,
          intendedRecipient: intendedRecipient,
        );
        if (!isBroadcast) {
          _logger.severe(
            '🔒 v2 direct plaintext text message rejected: $messageId',
          );
          return null;
        }
        if (message.signature == null) {
          _logger.severe(
            '🔒 v2 plaintext broadcast missing signature: $messageId',
          );
          return null;
        }
      }

      // Decrypt if needed
      String decryptedContent = content;
      var isV2Authenticated = message.version < 2;
      if (message.isEncrypted && decryptionPeerId.isNotEmpty) {
        if (_shouldRequireV2Signature(
              messageVersion: message.version,
              peerKey: versionPeerKey,
            ) &&
            message.signature == null) {
          _logger.severe(
            '🔒 v2 encrypted message missing signature under strict/upgraded-peer policy: $messageId',
          );
          return null;
        }
        try {
          if (message.version >= 2) {
            final cryptoHeader = message.cryptoHeader;
            if (cryptoHeader == null) {
              _logger.severe(
                '🔒 v2 encrypted message missing crypto header: $messageId',
              );
              return null;
            }
            if (cryptoHeader.mode == CryptoMode.sealedV1) {
              final sealedSenderId =
                  message.senderId ??
                  (message.payload['originalSender'] as String?);
              final recipientForSealed = message.recipientId;
              if (sealedSenderId == null || sealedSenderId.isEmpty) {
                _logger.severe(
                  '🔒 v2 sealed message missing sender binding: $messageId',
                );
                return null;
              }
              if (recipientForSealed == null || recipientForSealed.isEmpty) {
                _logger.severe(
                  '🔒 v2 sealed message missing recipient binding: $messageId',
                );
                return null;
              }
              decryptedContent = await _securityService.decryptSealedMessage(
                encryptedMessage: content,
                cryptoHeader: cryptoHeader,
                messageId: messageId,
                senderId: sealedSenderId,
                recipientId: recipientForSealed,
              );
            } else {
              if (cryptoHeader.mode == CryptoMode.legacyGlobalV1) {
                _logger.warning(
                  '🔒 v2 legacy global decrypt mode is blocked by policy: '
                  '${cryptoHeader.mode.wireValue} '
                  '(messageId=${messageId.shortId(8)})',
                );
                return null;
              }
              if (_shouldRejectLegacyV2ModeForUpgradedPeer(
                peerKey: versionPeerKey,
                mode: cryptoHeader.mode,
                messageId: messageId,
              )) {
                return null;
              }
              if (!_allowLegacyV2Decrypt && _isLegacyMode(cryptoHeader.mode)) {
                _logger.warning(
                  '🔒 v2 legacy decrypt mode blocked by policy: ${cryptoHeader.mode.wireValue} '
                  '(messageId=${messageId.shortId(8)})',
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
            }
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
          final signatureKey = resolvedSignatureSenderKey ?? declaredSenderId;
          if (signatureKey.isEmpty) {
            _logger.severe(
              '❌ v2 trusted signature missing sender verification key for message $messageId',
            );
            return '[❌ UNTRUSTED MESSAGE - Missing sender identity]';
          }
          verifyingKey = signatureKey;
        }

        final signaturePayload = SigningManager.signaturePayloadForMessage(
          message,
          fallbackContent: decryptedContent,
        );
        final isValid = SigningManager.verifySignature(
          signaturePayload,
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
        if (message.version >= 2) {
          isV2Authenticated = true;
        }
      }

      _sendAck(messageId, fromNodeId);
      if (message.version < 2 || isV2Authenticated) {
        _trackPeerVersionFloor(
          peerKey: versionPeerKey,
          messageVersion: message.version,
          messageId: messageId,
        );
      } else {
        _logger.warning(
          '🔒 Skipping protocol-floor upgrade for unauthenticated '
          'v${message.version} message from ${versionPeerKey.shortId(8)}... '
          '(messageId=${messageId.shortId(8)})',
        );
      }
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

  String _versionPeerKey({
    required String? signatureSenderKey,
    required String? declaredSenderId,
    required String transportSenderId,
  }) {
    if (signatureSenderKey != null && signatureSenderKey.isNotEmpty) {
      return signatureSenderKey;
    }
    if (declaredSenderId != null && declaredSenderId.isNotEmpty) {
      return declaredSenderId;
    }
    return transportSenderId;
  }

  bool _shouldRejectLegacyDowngrade({
    required int messageVersion,
    required String peerKey,
    required String messageId,
  }) {
    final shouldReject = PeerProtocolVersionGuard.shouldRejectLegacyMessage(
      messageVersion: messageVersion,
      peerKey: peerKey,
    );
    if (!shouldReject) {
      return false;
    }
    final floor = PeerProtocolVersionGuard.floorForPeer(peerKey);
    _logger.warning(
      '🔒 Downgrade guard rejected v$messageVersion message from '
      '${peerKey.shortId(8)}... after observing v$floor capability '
      '(messageId=${messageId.shortId(8)})',
    );
    return true;
  }

  void _trackPeerVersionFloor({
    required String peerKey,
    required int messageVersion,
    required String messageId,
  }) {
    final result = PeerProtocolVersionGuard.trackObservedVersion(
      messageVersion: messageVersion,
      peerKey: peerKey,
    );
    if (result.upgraded) {
      _logger.fine(
        '🔒 Protocol floor upgraded for ${peerKey.shortId(8)}... '
        'to v${result.floor} via ${messageId.shortId(8)}',
      );
    }
    if (result.cacheCleared) {
      _logger.warning(
        '🔒 Protocol floor cache exceeded 4096 entries; clearing oldest state',
      );
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

  Future<String?> _resolveSenderKeyForDecrypt(String? candidateKey) async {
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
        'Decrypt sender resolution failed for ${candidateKey.shortId(8)}: $e',
      );
    }
    return candidateKey;
  }

  Future<String?> _resolveSenderKeyForSignature(String? candidateKey) async {
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
        if (persistentKey != null && persistentKey.isNotEmpty) {
          return persistentKey;
        }
        if (contact.publicKey.isNotEmpty) {
          return contact.publicKey;
        }
      }
    } catch (e) {
      _logger.fine(
        'Signature sender resolution failed for ${candidateKey.shortId(8)}: $e',
      );
    }
    return candidateKey;
  }

  bool _isLegacyMode(CryptoMode mode) {
    return mode == CryptoMode.legacyEcdhV1 ||
        mode == CryptoMode.legacyPairingV1 ||
        mode == CryptoMode.legacyGlobalV1;
  }

  bool _shouldRejectLegacyV2ModeForUpgradedPeer({
    required String peerKey,
    required CryptoMode mode,
    required String messageId,
  }) {
    if (!_isLegacyMode(mode) || peerKey.isEmpty) {
      return false;
    }

    final floor = PeerProtocolVersionGuard.floorForPeer(peerKey);
    if (floor < 2) {
      return false;
    }

    _logger.warning(
      '🔒 v2 legacy decrypt mode blocked for upgraded peer '
      '${peerKey.shortId(8)}... (floor=v$floor, mode=${mode.wireValue}, '
      'messageId=${messageId.shortId(8)})',
    );
    return true;
  }

  bool _shouldRequireV2Signature({
    required int messageVersion,
    required String peerKey,
  }) {
    if (messageVersion < 2) {
      return false;
    }
    if (_requireV2Signature) {
      return true;
    }
    if (!PeerProtocolVersionGuard.isEnabled || peerKey.isEmpty) {
      return false;
    }
    return PeerProtocolVersionGuard.floorForPeer(peerKey) >= 2;
  }

  bool _isBroadcastV2TextMessage({
    required String? recipientId,
    required String? intendedRecipient,
  }) {
    if (recipientId == SpecialRecipients.broadcast ||
        intendedRecipient == SpecialRecipients.broadcast) {
      return true;
    }
    return recipientId == null && intendedRecipient == null;
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
        // v2 never permits legacy global decrypt.
        return null;
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
