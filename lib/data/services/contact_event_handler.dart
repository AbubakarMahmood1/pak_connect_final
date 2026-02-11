import 'package:logging/logging.dart';
import '../../domain/models/protocol_message.dart';

/// Handles contact-related protocol events (request/accept/reject and crypto
/// verification) so BLEMessageHandler can delegate orchestration.
class ContactEventHandler {
  ContactEventHandler({Logger? logger})
    : _logger = logger ?? Logger('ContactEventHandler');

  final Logger _logger;

  Function(String, String)? onContactRequestReceived;
  Function(String, String)? onContactAcceptReceived;
  Function()? onContactRejectReceived;
  Function(String, String)? onCryptoVerificationReceived;
  Function(String, String, bool, Map<String, dynamic>?)?
  onCryptoVerificationResponseReceived;

  Future<String?> handleContactRequest(ProtocolMessage message) async {
    try {
      final requestPublicKey = message.contactRequestPublicKey;
      final requestDisplayName = message.contactRequestDisplayName;

      if (requestPublicKey != null && requestDisplayName != null) {
        _logger.info('📱 CONTACT REQUEST: Received from $requestDisplayName');
        onContactRequestReceived?.call(requestPublicKey, requestDisplayName);
      }
    } catch (e) {
      _logger.severe('Failed to handle contact request: $e');
    }
    return null;
  }

  Future<String?> handleContactAccept(ProtocolMessage message) async {
    try {
      final acceptPublicKey = message.contactAcceptPublicKey;
      final acceptDisplayName = message.contactAcceptDisplayName;

      if (acceptPublicKey != null && acceptDisplayName != null) {
        _logger.info('📱 CONTACT ACCEPT: Received from $acceptDisplayName');
        onContactAcceptReceived?.call(acceptPublicKey, acceptDisplayName);
      }
    } catch (e) {
      _logger.severe('Failed to handle contact accept: $e');
    }
    return null;
  }

  Future<String?> handleContactReject() async {
    try {
      _logger.info('📱 CONTACT REJECT: Received');
      onContactRejectReceived?.call();
    } catch (e) {
      _logger.severe('Failed to handle contact reject: $e');
    }
    return null;
  }

  Future<String?> handleCryptoVerification(ProtocolMessage message) async {
    try {
      final verificationId = message.payload['verificationId'] as String?;
      final contactKey = message.payload['contactKey'] as String?;

      if (verificationId != null && contactKey != null) {
        _logger.info('🔐 Crypto verification requested');
        onCryptoVerificationReceived?.call(verificationId, contactKey);
      }
    } catch (e) {
      _logger.severe('Failed to handle crypto verification: $e');
    }
    return null;
  }

  Future<String?> handleCryptoVerificationResponse(
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
        onCryptoVerificationResponseReceived?.call(
          verificationId,
          contactKey,
          isVerified,
          message.payload,
        );
      }
    } catch (e) {
      _logger.severe('Failed to handle crypto verification response: $e');
    }
    return null;
  }
}
