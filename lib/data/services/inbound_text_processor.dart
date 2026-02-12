import 'package:logging/logging.dart';

import '../../domain/interfaces/i_contact_repository.dart';
import '../../domain/interfaces/i_security_service.dart';
import '../../domain/models/crypto_header.dart';
import '../../domain/models/encryption_method.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import '../../domain/services/signing_manager.dart';
import '../../domain/models/protocol_message.dart';

class InboundTextResult {
  const InboundTextResult({
    required this.content,
    required this.shouldAck,
    this.resolvedSenderKey,
  });

  final String? content;
  final bool shouldAck;
  final String? resolvedSenderKey;
}

/// Handles routing, decryption, and signature verification for inbound text messages.
class InboundTextProcessor {
  InboundTextProcessor({
    required IContactRepository contactRepository,
    required Future<bool> Function(String? intendedRecipient) isMessageForMe,
    required String? Function() currentNodeIdProvider,
    ISecurityService? securityService,
    Logger? logger,
  }) : _contactRepository = contactRepository,
       _isMessageForMe = isMessageForMe,
       _currentNodeIdProvider = currentNodeIdProvider,
       _securityService =
           securityService ?? SecurityServiceLocator.resolveService(),
       _logger = logger ?? Logger('InboundTextProcessor');

  final IContactRepository _contactRepository;
  final Future<bool> Function(String? intendedRecipient) _isMessageForMe;
  final String? Function() _currentNodeIdProvider;
  final ISecurityService _securityService;
  final Logger _logger;
  static const bool _allowLegacyV1DecryptFallback = true;

  Future<InboundTextResult> process({
    required ProtocolMessage protocolMessage,
    required String? senderPublicKey,
    String? Function(String)? onMessageIdFound,
  }) async {
    final currentNodeId = _currentNodeIdProvider();

    // Drop messages that originated from this node to prevent loops/echo
    if (senderPublicKey != null && senderPublicKey == currentNodeId) {
      _logger.fine('⏭️ ROUTING: Ignoring self-originated message');
      return const InboundTextResult(content: null, shouldAck: false);
    }

    final messageId = protocolMessage.textMessageId!;
    final content = protocolMessage.textContent!;
    final intendedRecipient =
        protocolMessage.payload['intendedRecipient'] as String?;

    _logRoutingDiagnostics(
      messageId: messageId,
      senderPublicKey: senderPublicKey,
      intendedRecipient: intendedRecipient,
    );

    onMessageIdFound?.call(messageId);

    // Privacy-aware routing: drop messages not addressed to us
    if (intendedRecipient != null) {
      final isForMe = await _isMessageForMe(intendedRecipient);
      if (!isForMe) {
        _logger.fine(
          '🔧 ROUTING: Discarding message not addressed to us (${_safeTruncate(intendedRecipient)})',
        );
        return const InboundTextResult(content: null, shouldAck: false);
      }
    }

    String decryptedContent = content;
    final originalSender = protocolMessage.payload['originalSender'] as String?;
    final declaredSenderId = protocolMessage.senderId ?? originalSender;
    final resolvedSender = await _resolveSenderKey(senderPublicKey);
    final resolvedOriginalSender = await _resolveSenderKey(originalSender);
    final resolvedDeclaredSender = await _resolveSenderKey(declaredSenderId);

    final decryptKey = resolvedDeclaredSender?.isNotEmpty == true
        ? resolvedDeclaredSender
        : (resolvedSender?.isNotEmpty == true
              ? resolvedSender
              : resolvedOriginalSender);
    String? decryptKeyUsed = decryptKey;

    if (protocolMessage.isEncrypted) {
      final cryptoHeader =
          protocolMessage.version >= 2 ? protocolMessage.cryptoHeader : null;
      final isSealedV2 = cryptoHeader?.mode == CryptoMode.sealedV1;

      if (decryptKey == null && !isSealedV2) {
        _logger.warning('🔒 MESSAGE: Encrypted but no sender key available');
        return const InboundTextResult(
          content: '[❌ Encrypted message but no sender identity]',
          shouldAck: false,
        );
      }

      try {
        if (protocolMessage.version >= 2) {
          if (cryptoHeader == null) {
            _logger.severe(
              '🔒 v2 encrypted message missing crypto header: $messageId',
            );
            return const InboundTextResult(content: null, shouldAck: false);
          }
          if (cryptoHeader.mode == CryptoMode.sealedV1) {
            final sealedSenderId = declaredSenderId ?? senderPublicKey;
            final sealedRecipientId = protocolMessage.recipientId;
            if (sealedSenderId == null ||
                sealedSenderId.isEmpty ||
                sealedRecipientId == null ||
                sealedRecipientId.isEmpty) {
              _logger.severe(
                '🔒 v2 sealed message missing sender/recipient binding: $messageId',
              );
              return const InboundTextResult(content: null, shouldAck: false);
            }
            decryptedContent = await _securityService.decryptSealedMessage(
              encryptedMessage: content,
              cryptoHeader: cryptoHeader,
              messageId: messageId,
              senderId: sealedSenderId,
              recipientId: sealedRecipientId,
            );
            _logger.info(
              '🔒 MESSAGE: Decrypted successfully (mode=${cryptoHeader.mode.wireValue})',
            );
          } else {
            final encryptionType = _encryptionTypeForMode(cryptoHeader.mode);
            if (encryptionType == null) {
              _logger.severe(
                '🔒 v2 encrypted message has unsupported crypto mode: ${cryptoHeader.mode.wireValue}',
              );
              return const InboundTextResult(content: null, shouldAck: false);
            }
            decryptedContent = await _securityService.decryptMessageByType(
              content,
              decryptKey!,
              _contactRepository,
              encryptionType,
            );
            _logger.info(
              '🔒 MESSAGE: Decrypted successfully (mode=${cryptoHeader.mode.wireValue})',
            );
          }
        } else {
          if (!_allowLegacyV1DecryptFallback) {
            _logger.warning(
              '🔒 Legacy v1 decrypt fallback disabled. Rejecting message: $messageId',
            );
            return const InboundTextResult(content: null, shouldAck: false);
          }
          decryptedContent = await _securityService.decryptMessage(
            content,
            decryptKey!,
            _contactRepository,
          );
          _logger.info('🔒 MESSAGE: Decrypted successfully');
        }
      } catch (e) {
        final errorText = e.toString();
        final truncatedKey = _safeTruncate(decryptKey);
        _logger.warning('🔒 MESSAGE: Decryption failed with $truncatedKey: $e');

        if (protocolMessage.version >= 2) {
          return InboundTextResult(
            content:
                '[❌ Could not decrypt v2 message - verify crypto mode/session state]',
            shouldAck: false,
            resolvedSenderKey: decryptKey,
          );
        }

        if (errorText.contains('No session found') ||
            errorText.contains('Session not established')) {
          _logger.warning(
            '🔒 MESSAGE: Missing Noise session for $truncatedKey - requesting resync and skipping ACK',
          );
          return InboundTextResult(
            content: null,
            shouldAck: false,
            resolvedSenderKey: decryptKey,
          );
        }

        // Fallback: try originalSender if different from the first key
        if (originalSender != null &&
            originalSender.isNotEmpty &&
            originalSender != decryptKey) {
          try {
            decryptedContent = await _securityService.decryptMessage(
              content,
              originalSender,
              _contactRepository,
            );
            decryptKeyUsed = originalSender;
            _logger.info(
              '🔒 MESSAGE: Decrypted successfully using originalSender fallback',
            );
          } catch (fallbackError) {
            _logger.severe(
              '🔒 MESSAGE: Fallback decryption failed: $fallbackError',
            );
            if (fallbackError.toString().contains(
              'security resync requested',
            )) {
              return InboundTextResult(
                content:
                    '[🔄 Security resync in progress - message will be readable after reconnection]',
                shouldAck: false,
                resolvedSenderKey: originalSender,
              );
            }
            return InboundTextResult(
              content:
                  '[❌ Could not decrypt message - please reconnect to resync security]',
              shouldAck: false,
              resolvedSenderKey: originalSender,
            );
          }
        } else {
          if (e.toString().contains('security resync requested')) {
            return InboundTextResult(
              content:
                  '[🔄 Security resync in progress - message will be readable after reconnection]',
              shouldAck: false,
              resolvedSenderKey: decryptKey,
            );
          }
          return InboundTextResult(
            content:
                '[❌ Could not decrypt message - please reconnect to resync security]',
            shouldAck: false,
            resolvedSenderKey: decryptKey,
          );
        }
      }
    }

    // Verify signature when present
    if (protocolMessage.signature != null) {
      String verifyingKey;

      if (protocolMessage.useEphemeralSigning) {
        if (protocolMessage.ephemeralSigningKey == null) {
          if (protocolMessage.version >= 2) {
            _logger.severe(
              '❌ v2 ephemeral signature missing signing key for message $messageId',
            );
            return const InboundTextResult(
              content: '[❌ UNTRUSTED MESSAGE - Missing ephemeral signing key]',
              shouldAck: false,
            );
          }
          _logger.warning(
            '⚠️ Ephemeral message missing signing key - accepting unsigned (legacy v1)',
          );
          return InboundTextResult(
            content: decryptedContent,
            shouldAck: true,
            resolvedSenderKey:
                decryptKeyUsed ??
                resolvedDeclaredSender ??
                resolvedSender ??
                resolvedOriginalSender,
          );
        }
        verifyingKey = protocolMessage.ephemeralSigningKey!;
      } else {
        final resolvedForSignature =
            resolvedDeclaredSender ??
            resolvedSender ??
            senderPublicKey ??
            resolvedOriginalSender;
        if (resolvedForSignature == null) {
          _logger.severe('❌ Trusted message but no sender identity');
          return const InboundTextResult(
            content: '[❌ Missing sender identity]',
            shouldAck: false,
          );
        }
        verifyingKey = resolvedForSignature;
      }

      final isValid = SigningManager.verifySignature(
        decryptedContent,
        protocolMessage.signature!,
        verifyingKey,
        protocolMessage.useEphemeralSigning,
      );

      if (!isValid) {
        _logger.severe('❌ SIGNATURE VERIFICATION FAILED');
        return const InboundTextResult(
          content: '[❌ UNTRUSTED MESSAGE - Signature Invalid]',
          shouldAck: false,
        );
      }

      if (protocolMessage.useEphemeralSigning) {
        _logger.info('✅ Ephemeral signature verified');
      } else {
        _logger.info('✅ Real signature verified');
      }
    }

    return InboundTextResult(
      content: decryptedContent,
      shouldAck: true,
      resolvedSenderKey:
          decryptKeyUsed ??
          resolvedDeclaredSender ??
          resolvedSender ??
          resolvedOriginalSender ??
          senderPublicKey ??
          declaredSenderId ??
          originalSender,
    );
  }

  void _logRoutingDiagnostics({
    required String messageId,
    required String? senderPublicKey,
    required String? intendedRecipient,
  }) {
    final currentNodeId = _currentNodeIdProvider();

    _logger.fine('🔧 ROUTING DEBUG: ===== MESSAGE ROUTING ANALYSIS =====');
    _logger.fine('Message ID: ${_safeTruncate(messageId)}');
    _logger.fine('Sender key: ${_safeTruncate(senderPublicKey)}');
    _logger.fine('Intended recipient: ${_safeTruncate(intendedRecipient)}');
    _logger.fine('Current node: ${_safeTruncate(currentNodeId)}');
    _logger.fine('===============================================');
  }

  Future<String?> _resolveSenderKey(String? candidateKey) async {
    if (candidateKey == null || candidateKey.isEmpty) return candidateKey;
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
        'Sender resolution failed for ${_safeTruncate(candidateKey)}: $e',
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

  String _safeTruncate(String? input, {int maxLength = 16, String? fallback}) {
    if (input == null || input.isEmpty) return fallback ?? 'NULL';
    if (input.length <= maxLength) return input;
    return input.substring(0, maxLength);
  }
}
