// ignore_for_file: avoid_print

import '../../core/models/security_state.dart';
import '../../data/services/ble_service.dart';
import '../../core/models/connection_info.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/services/security_manager.dart';

class SecurityStateComputer {
  
  /// Main entry point - computes complete security state for any context
  static Future<SecurityState> computeState({
    required bool isRepositoryMode,
    required ConnectionInfo? connectionInfo,
    required BLEService bleService,
    String? otherPublicKey,
  }) async {
    print('🐛 DEBUG: SecurityStateComputer.computeState called');
  print('🐛 DEBUG: - isRepositoryMode: $isRepositoryMode');
  print('🐛 DEBUG: - connectionInfo: ${connectionInfo?.isConnected}/${connectionInfo?.isReady}');
  print('🐛 DEBUG: - otherPublicKey: $otherPublicKey');
  
    if (isRepositoryMode) {
    final result = await _computeRepositoryModeState(otherPublicKey, bleService);
    print('🐛 DEBUG: Repository mode result: ${result.status.name}');
    return result;
  }
  
  final result = await _computeLiveConnectionState(connectionInfo, bleService);
  print('🐛 DEBUG: Live connection result: ${result.status.name}');
  return result;
  }
  
  /// Repository mode: Offline chats with stored contacts
  static Future<SecurityState> _computeRepositoryModeState(
  String? otherPublicKey, 
  BLEService bleService
) async {
  if (otherPublicKey == null) {
    return SecurityState.disconnected();
  }
  
  // Extract actual public key (remove 'repo_' prefix if present)
  final actualKey = otherPublicKey.startsWith('repo_') 
      ? otherPublicKey.substring(5) 
      : otherPublicKey;
  
  print('🔧 REPO DEBUG: Processing key: ${actualKey.length > 16 ? '${actualKey.substring(0, 16)}...' : actualKey}');
  
  final contactRepo = bleService.stateManager.contactRepository;
  final contact = await contactRepo.getContact(actualKey);
  
  print('🔧 REPO DEBUG: Contact found: ${contact != null}');
  print('🔧 REPO DEBUG: Contact trust status: ${contact?.trustStatus.name}');
  print('🔧 REPO DEBUG: Contact security level: ${contact?.securityLevel.name}');
  
  if (contact == null) {
    return SecurityState.needsPairing(
      otherUserName: 'Unknown Contact',
      otherPublicKey: actualKey,
    );
  }
  
  // Check if this is a verified contact (highest security)
  if (contact.trustStatus == TrustStatus.verified) {
    print('🔧 REPO DEBUG: → VERIFIED CONTACT');
    return SecurityState.verifiedContact(
      otherUserName: contact.displayName,
      otherPublicKey: actualKey,
    );
  }
  
  // Fall back to security level mapping
  return _mapSecurityLevelToState(
    contact.securityLevel, 
    contact.displayName, 
    actualKey
  );
}
  
  /// Live connection mode: Real-time BLE connections
  static Future<SecurityState> _computeLiveConnectionState(
    ConnectionInfo? connectionInfo,
    BLEService bleService
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
    final otherPublicKey = bleService.stateManager.otherDevicePersistentId;
    if (otherPublicKey == null) {
      return SecurityState.exchangingIdentity();
    }
    
    final contactRepo = bleService.stateManager.contactRepository;
    
    // Check bilateral contact relationship
    final contact = await contactRepo.getContact(otherPublicKey);
    final weHaveThem = contact != null && contact.trustStatus == TrustStatus.verified;
    final theyHaveUs = bleService.stateManager.theyHaveUsAsContact;
    
    return await _computeBilateralSecurityState(
      weHaveThem: weHaveThem,
      theyHaveUs: theyHaveUs,
      otherUserName: connectionInfo.otherUserName!,
      otherPublicKey: otherPublicKey,
      contactRepo: contactRepo,
    );
  }
  
  /// Compute security state based on bilateral contact relationship
  static Future<SecurityState> _computeBilateralSecurityState({
  required bool weHaveThem,
  required bool theyHaveUs,
  required String otherUserName,
  required String otherPublicKey,
  required ContactRepository contactRepo,
}) async {
  
  print('🔧 DEBUG: _computeBilateralSecurityState');
  print('🔧 DEBUG: - weHaveThem: $weHaveThem');
  print('🔧 DEBUG: - theyHaveUs: $theyHaveUs');
  
  // Get the actual stored security level for accurate state
  final storedSecurityLevel = await contactRepo.getContactSecurityLevel(otherPublicKey);
  print('🔧 DEBUG: - storedSecurityLevel: ${storedSecurityLevel.name}');
  
  // VERIFIED CONTACT: Both have each other AND we have high security
  if (weHaveThem && theyHaveUs && storedSecurityLevel == SecurityLevel.high) {
    print('🔧 DEBUG: → VERIFIED CONTACT');
    return SecurityState.verifiedContact(
      otherUserName: otherUserName,
      otherPublicKey: otherPublicKey,
    );
  }
  
  // ASYMMETRIC: They have us but we don't have them
  if (!weHaveThem && theyHaveUs) {
    print('🔧 DEBUG: → ASYMMETRIC CONTACT');
    return SecurityState.asymmetricContact(
      otherUserName: otherUserName,
      otherPublicKey: otherPublicKey,
    );
  }
  
  // PAIRED: We have medium security (pairing completed)
  if (storedSecurityLevel == SecurityLevel.medium) {
    print('🔧 DEBUG: → PAIRED');
    return SecurityState.paired(
      otherUserName: otherUserName,
      otherPublicKey: otherPublicKey,
    );
  }
  
  // DEFAULT: Basic/low security
  print('🔧 DEBUG: → NEEDS PAIRING');
  return SecurityState.needsPairing(
    otherUserName: otherUserName,
    otherPublicKey: otherPublicKey,
  );
}
  
  /// Map stored security level to UI state (for repository mode)
static SecurityState _mapSecurityLevelToState(
    SecurityLevel level, 
    String userName, 
    String publicKey
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