import 'dart:async';
import 'dart:typed_data';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import '../../core/interfaces/i_protocol_message_handler.dart';
import '../../core/interfaces/i_identity_manager.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../core/models/protocol_message.dart';
import '../../core/security/ephemeral_key_manager.dart';
import '../../core/security/signing_manager.dart';
import '../../core/services/security_manager.dart';
import '../../core/messaging/queue_sync_manager.dart';
import '../../data/repositories/contact_repository.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

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
  final _logger = Logger('ProtocolMessageHandler');
  final ContactRepository _contactRepository = ContactRepository();

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

  String? _currentNodeId;
  String _encryptionMethod = 'none';

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
    required ProtocolMessage message,
    required String fromDeviceId,
    required String fromNodeId,
  }) async {
    try {
      return await _processProtocolMessage(message, fromNodeId);
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
  }) async {
    try {
      final protocolMessage = ProtocolMessage.fromBytes(
        Uint8List.fromList(content.codeUnits),
      );
      return await _processProtocolMessage(protocolMessage, fromNodeId);
    } catch (e) {
      _logger.severe('Failed to process complete protocol message: $e');
      return null;
    }
  }

  /// Handles direct protocol messages (not relayed)
  @override
  Future<String?> handleDirectProtocolMessage({
    required ProtocolMessage message,
    required String fromDeviceId,
  }) async {
    try {
      return await _processProtocolMessage(message, fromDeviceId);
    } catch (e) {
      _logger.severe('Failed to handle direct protocol message: $e');
      return null;
    }
  }

  /// Main protocol message processing dispatcher
  Future<String?> _processProtocolMessage(
    ProtocolMessage message,
    String fromNodeId,
  ) async {
    switch (message.type) {
      case ProtocolMessageType.textMessage:
        return await _handleTextMessage(message, fromNodeId);

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
        return await _handleQueueSync(message, fromNodeId);

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
    ProtocolMessage message,
    String fromNodeId,
  ) async {
    try {
      final messageId = message.textMessageId!;
      final content = message.textContent!;
      final intendedRecipient = message.payload['intendedRecipient'] as String?;

      // Check if message is for us
      final isForMe = await isMessageForMe(intendedRecipient);
      if (!isForMe) {
        _logger.fine('💬 Message not for us, ignoring');
        return null;
      }

      // Decrypt if needed
      String decryptedContent = content;
      if (message.isEncrypted && fromNodeId.isNotEmpty) {
        try {
          decryptedContent = await SecurityManager.instance.decryptMessage(
            content,
            fromNodeId,
            _contactRepository,
          );
          _logger.fine('🔒 Message decrypted successfully');
        } catch (e) {
          _logger.severe('🔒 Decryption failed: $e');
          return '[❌ Could not decrypt message - please reconnect]';
        }
      }

      // Verify signature
      if (message.signature != null) {
        final verifyingKey = message.useEphemeralSigning
            ? message.ephemeralSigningKey ?? fromNodeId
            : fromNodeId;

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

      return decryptedContent;
    } catch (e) {
      _logger.severe('Failed to handle text message: $e');
      return null;
    }
  }

  /// Handles incoming contact request
  Future<String?> _handleContactRequest(ProtocolMessage message) async {
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
  Future<String?> _handleContactAccept(ProtocolMessage message) async {
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
  Future<String?> _handleCryptoVerification(ProtocolMessage message) async {
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
    ProtocolMessage message,
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
    ProtocolMessage message,
    String fromNodeId,
  ) async {
    try {
      final queueMessage = message.queueSyncMessage;
      if (queueMessage != null) {
        _onQueueSyncReceived?.call(queueMessage, fromNodeId);
        _logger.info('📦 Queue sync received');
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
  Future<String?> _handleFriendReveal(ProtocolMessage message) async {
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

    if (GetIt.instance.isRegistered<IIdentityManager>()) {
      final identity = GetIt.instance<IIdentityManager>();
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
}
