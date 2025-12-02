import 'package:logging/logging.dart';

import '../interfaces/i_contact_repository.dart';
import '../services/security_manager.dart';
import '../security/signing_manager.dart';
import '../models/protocol_message.dart';
import '../../domain/values/id_types.dart';

/// Handles routing, decryption, and signature verification for inbound text messages.
class InboundTextProcessor {
  InboundTextProcessor({
    required IContactRepository contactRepository,
    required Future<bool> Function(String? intendedRecipient) isMessageForMe,
    required String? Function() currentNodeIdProvider,
    Logger? logger,
  }) : _contactRepository = contactRepository,
       _isMessageForMe = isMessageForMe,
       _currentNodeIdProvider = currentNodeIdProvider,
       _logger = logger ?? Logger('InboundTextProcessor');

  final IContactRepository _contactRepository;
  final Future<bool> Function(String? intendedRecipient) _isMessageForMe;
  final String? Function() _currentNodeIdProvider;
  final Logger _logger;

  Future<String?> process({
    required ProtocolMessage protocolMessage,
    required String? senderPublicKey,
    String? Function(String)? onMessageIdFound,
  }) async {
    final currentNodeId = _currentNodeIdProvider();

    // Drop messages that originated from this node to prevent loops/echo
    if (senderPublicKey != null && senderPublicKey == currentNodeId) {
      _logger.fine('⏭️ ROUTING: Ignoring self-originated message');
      return null;
    }

    final messageId = protocolMessage.textMessageId!;
    final messageIdValue = MessageId(messageId);
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
        return null;
      }
    }

    String decryptedContent = content;

    if (protocolMessage.isEncrypted &&
        senderPublicKey != null &&
        senderPublicKey.isNotEmpty) {
      try {
        decryptedContent = await SecurityManager.instance.decryptMessage(
          content,
          senderPublicKey,
          _contactRepository,
        );
        _logger.info('🔒 MESSAGE: Decrypted successfully');
      } catch (e) {
        _logger.severe('🔒 MESSAGE: Decryption failed: $e');

        if (e.toString().contains('security resync requested')) {
          return '[🔄 Security resync in progress - message will be readable after reconnection]';
        } else {
          return '[❌ Could not decrypt message - please reconnect to resync security]';
        }
      }
    } else if (protocolMessage.isEncrypted) {
      _logger.warning('🔒 MESSAGE: Encrypted but no sender key available');
      return '[❌ Encrypted message but no sender identity]';
    }

    // Verify signature when present
    if (protocolMessage.signature != null) {
      String verifyingKey;

      if (protocolMessage.useEphemeralSigning) {
        if (protocolMessage.ephemeralSigningKey == null) {
          _logger.warning(
            '⚠️ Ephemeral message missing signing key - accepting unsigned',
          );
          return decryptedContent;
        }
        verifyingKey = protocolMessage.ephemeralSigningKey!;
      } else {
        if (senderPublicKey == null) {
          _logger.severe('❌ Trusted message but no sender identity');
          return '[❌ Missing sender identity]';
        }
        verifyingKey = senderPublicKey;
      }

      final isValid = SigningManager.verifySignature(
        decryptedContent,
        protocolMessage.signature!,
        verifyingKey,
        protocolMessage.useEphemeralSigning,
      );

      if (!isValid) {
        _logger.severe('❌ SIGNATURE VERIFICATION FAILED');
        return '[❌ UNTRUSTED MESSAGE - Signature Invalid]';
      }

      if (protocolMessage.useEphemeralSigning) {
        _logger.info('✅ Ephemeral signature verified');
      } else {
        _logger.info('✅ Real signature verified');
      }
    }

    return decryptedContent;
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

  String _safeTruncate(String? input, {int maxLength = 16, String? fallback}) {
    if (input == null || input.isEmpty) return fallback ?? 'NULL';
    if (input.length <= maxLength) return input;
    return input.substring(0, maxLength);
  }
}
