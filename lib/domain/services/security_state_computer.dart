import 'package:logging/logging.dart';

import '../entities/contact.dart';
import '../interfaces/i_connection_service.dart';
import '../interfaces/i_contact_repository.dart';
import '../models/connection_info.dart';
import '../models/security_level.dart';
import '../models/security_state.dart';
import '../utils/string_extensions.dart';

class SecurityStateComputer {
  static final _logger = Logger('SecurityStateComputer');

  /// Main entry point - computes complete security state for any context
  static Future<SecurityState> computeState({
    required bool isRepositoryMode,
    required ConnectionInfo? connectionInfo,
    required IConnectionService connectionService,
    required IContactRepository contactRepository,
    required bool theyHaveUsAsContact,
    String? otherPublicKey,
  }) async {
    _logger.fine('🐛 DEBUG: SecurityStateComputer.computeState called');
    _logger.fine('🐛 DEBUG: - isRepositoryMode: $isRepositoryMode');
    _logger.fine(
      '🐛 DEBUG: - connectionInfo: ${connectionInfo?.isConnected}/${connectionInfo?.isReady}',
    );
    _logger.fine('🐛 DEBUG: - otherPublicKey: $otherPublicKey');

    if (isRepositoryMode) {
      final result = await _computeRepositoryModeState(
        otherPublicKey,
        contactRepository,
      );
      _logger.fine('🐛 DEBUG: Repository mode result: ${result.status.name}');
      return result;
    }

    final result = await _computeLiveConnectionState(
      connectionInfo,
      connectionService,
      contactRepository,
      theyHaveUsAsContact,
    );
    _logger.fine('🐛 DEBUG: Live connection result: ${result.status.name}');
    return result;
  }

  /// Repository mode: Offline chats with stored contacts
  static Future<SecurityState> _computeRepositoryModeState(
    String? otherPublicKey,
    IContactRepository contactRepository,
  ) async {
    if (otherPublicKey == null) {
      return SecurityState.disconnected();
    }

    // Extract actual public key (remove 'repo_' prefix if present)
    final actualKey = otherPublicKey.startsWith('repo_')
        ? otherPublicKey.substring(5)
        : otherPublicKey;

    _logger.fine(
      '🔧 REPO DEBUG: Processing key: ${actualKey.length > 16 ? '${actualKey.shortId()}...' : actualKey}',
    );

    // 🔧 FIX: Use comprehensive lookup to handle publicKey, persistentPublicKey, AND currentEphemeralId
    // This fixes "Contact exists: false" bug when looking up by persistent or ephemeral IDs
    final contact = await contactRepository.getContactByAnyId(actualKey);

    _logger.fine('🔧 REPO DEBUG: Contact found: ${contact != null}');
    _logger.fine(
      '🔧 REPO DEBUG: Contact trust status: ${contact?.trustStatus.name}',
    );
    _logger.fine(
      '🔧 REPO DEBUG: Contact security level: ${contact?.securityLevel.name}',
    );

    if (contact == null) {
      return SecurityState.needsPairing(
        otherUserName: 'Unknown Contact',
        otherPublicKey: actualKey,
      );
    }

    // Check if this is a verified contact (highest security)
    if (contact.trustStatus == TrustStatus.verified) {
      _logger.fine('🔧 REPO DEBUG: → VERIFIED CONTACT');
      return SecurityState.verifiedContact(
        otherUserName: contact.displayName,
        otherPublicKey: actualKey,
      );
    }

    // Fall back to security level mapping
    return _mapSecurityLevelToState(
      contact.securityLevel,
      contact.displayName,
      actualKey,
    );
  }

  /// Live connection mode: Real-time BLE connections
  static Future<SecurityState> _computeLiveConnectionState(
    ConnectionInfo? connectionInfo,
    IConnectionService connectionService,
    IContactRepository contactRepository,
    bool theyHaveUsAsContact,
  ) async {
    // No connection at all
    if (connectionInfo == null || !connectionInfo.isConnected) {
      return SecurityState.disconnected();
    }

    // Connected but still establishing identity
    if (!connectionInfo.isReady ||
        connectionInfo.otherUserName == null ||
        connectionInfo.otherUserName!.isEmpty) {
      return SecurityState.connecting();
    }

    // Have identity - now check security level
    final otherPublicKey = connectionService.currentSessionId;
    if (otherPublicKey == null) {
      return SecurityState.exchangingIdentity();
    }

    // Check bilateral contact relationship
    // 🔧 FIX: Use comprehensive lookup to handle any identifier type
    final contact = await contactRepository.getContactByAnyId(otherPublicKey);
    final weHaveThem =
        contact != null && contact.trustStatus == TrustStatus.verified;

    return _computeBilateralSecurityState(
      weHaveThem: weHaveThem,
      theyHaveUs: theyHaveUsAsContact,
      otherUserName: connectionInfo.otherUserName!,
      otherPublicKey: otherPublicKey,
      contactRepo: contactRepository,
    );
  }

  /// Compute security state based on bilateral contact relationship
  static Future<SecurityState> _computeBilateralSecurityState({
    required bool weHaveThem,
    required bool theyHaveUs,
    required String otherUserName,
    required String otherPublicKey,
    required IContactRepository contactRepo,
  }) async {
    _logger.fine('🔧 DEBUG: _computeBilateralSecurityState');
    _logger.fine('🔧 DEBUG: - weHaveThem: $weHaveThem');
    _logger.fine('🔧 DEBUG: - theyHaveUs: $theyHaveUs');

    // Get the actual stored security level for accurate state
    final storedSecurityLevel = await contactRepo.getContactSecurityLevel(
      otherPublicKey,
    );
    _logger.fine(
      '🔧 DEBUG: - storedSecurityLevel: ${storedSecurityLevel.name}',
    );

    // VERIFIED CONTACT: Both have each other AND we have high security
    if (weHaveThem && theyHaveUs && storedSecurityLevel == SecurityLevel.high) {
      _logger.fine('🔧 DEBUG: → VERIFIED CONTACT');
      return SecurityState.verifiedContact(
        otherUserName: otherUserName,
        otherPublicKey: otherPublicKey,
      );
    }

    // ASYMMETRIC: They have us but we don't have them
    if (!weHaveThem && theyHaveUs) {
      _logger.fine('🔧 DEBUG: → ASYMMETRIC CONTACT');
      return SecurityState.asymmetricContact(
        otherUserName: otherUserName,
        otherPublicKey: otherPublicKey,
      );
    }

    // PAIRED: We have medium security (pairing completed)
    if (storedSecurityLevel == SecurityLevel.medium) {
      _logger.fine('🔧 DEBUG: → PAIRED');
      return SecurityState.paired(
        otherUserName: otherUserName,
        otherPublicKey: otherPublicKey,
      );
    }

    // DEFAULT: Basic/low security
    _logger.fine('🔧 DEBUG: → NEEDS PAIRING');
    return SecurityState.needsPairing(
      otherUserName: otherUserName,
      otherPublicKey: otherPublicKey,
    );
  }

  /// Map stored security level to UI state (for repository mode)
  static SecurityState _mapSecurityLevelToState(
    SecurityLevel level,
    String userName,
    String publicKey,
  ) {
    switch (level) {
      case SecurityLevel.low:
        return SecurityState.needsPairing(
          otherUserName: userName,
          otherPublicKey: publicKey,
        );

      case SecurityLevel.medium:
        return SecurityState.paired(
          otherUserName: userName,
          otherPublicKey: publicKey,
        );

      case SecurityLevel.high:
        return SecurityState.verifiedContact(
          otherUserName: userName,
          otherPublicKey: publicKey,
        );
    }
  }

  /// Helper: Check if user can send messages based on security state
  static bool canSendMessages(SecurityState state) {
    return state.canSendMessages;
  }

  /// Helper: Get appropriate action for current security state
  static String? getRecommendedAction(SecurityState state) {
    switch (state.status) {
      case SecurityStatus.needsPairing:
        return 'Tap 🔒 to secure chat';
      case SecurityStatus.paired:
        return 'Tap + to add contact for ECDH encryption';
      case SecurityStatus.asymmetricContact:
        return 'Add them to enable ECDH encryption';
      case SecurityStatus.verifiedContact:
        return null; // No action needed
      default:
        return 'Connect to start chatting';
    }
  }

  /// Helper: Get encryption method description
  static String getEncryptionDescription(SecurityState state) {
    switch (state.status) {
      case SecurityStatus.verifiedContact:
        return 'ECDH + Signature Verification';
      case SecurityStatus.paired:
        return 'Paired + Global Encryption';
      case SecurityStatus.asymmetricContact:
        return 'Pairing Key + Global Encryption';
      case SecurityStatus.needsPairing:
        return 'Global Encryption Only';
      default:
        return 'No Encryption';
    }
  }
}
