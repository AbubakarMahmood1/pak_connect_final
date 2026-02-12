import 'package:logging/logging.dart';

import '../../domain/interfaces/i_contact_repository.dart';
import '../../domain/interfaces/i_security_service.dart';
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
    final resolvedSender = await _resolveSenderKey(senderPublicKey);
    final resolvedOriginalSender = await _resolveSenderKey(originalSender);

    final decryptKey = resolvedSender?.isNotEmpty == true
        ? resolvedSender
        : resolvedOriginalSender;
    String? decryptKeyUsed = decryptKey;

    if (protocolMessage.isEncrypted) {
      if (decryptKey == null) {
        _logger.warning('🔒 MESSAGE: Encrypted but no sender key available');
        return const InboundTextResult(
          content: '[❌ Encrypted message but no sender identity]',
          shouldAck: false,
        );
      }

      try {
        decryptedContent = await _securityService.decryptMessage(
          content,
          decryptKey,
          _contactRepository,
        );
        _logger.info('🔒 MESSAGE: Decrypted successfully');
      } catch (e) {
        final errorText = e.toString();
        final truncatedKey = _safeTruncate(decryptKey);
        _logger.warning('🔒 MESSAGE: Decryption failed with $truncatedKey: $e');

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
          _logger.warning(
            '⚠️ Ephemeral message missing signing key - accepting unsigned',
          );
          return InboundTextResult(
            content: decryptedContent,
            shouldAck: true,
            resolvedSenderKey:
                decryptKeyUsed ?? resolvedSender ?? resolvedOriginalSender,
          );
        }
        verifyingKey = protocolMessage.ephemeralSigningKey!;
      } else {
        final resolvedForSignature =
            resolvedSender ?? senderPublicKey ?? resolvedOriginalSender;
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
          resolvedSender ??
          resolvedOriginalSender ??
          senderPublicKey ??
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

  String _safeTruncate(String? input, {int maxLength = 16, String? fallback}) {
    if (input == null || input.isEmpty) return fallback ?? 'NULL';
    if (input.length <= maxLength) return input;
    return input.substring(0, maxLength);
  }
}
