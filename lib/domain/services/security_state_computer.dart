import '../../core/models/security_state.dart';
import '../../data/services/ble_service.dart';
import '../../core/models/connection_info.dart';
import '../../data/repositories/contact_repository.dart';

class SecurityStateComputer {
  static Future<SecurityState> computeState({
    required bool isRepositoryMode,
    required ConnectionInfo? connectionInfo,
    required BLEService bleService,
    String? otherPublicKey,
  }) async {
    // Repository mode chats are always secure (offline)
    if (isRepositoryMode) {
      return SecurityState.verifiedContact(
        otherUserName: connectionInfo?.otherUserName ?? 'Unknown Contact',
        otherPublicKey: otherPublicKey ?? '',
      );
    }
    
    // No BLE connection
    if (connectionInfo == null || !connectionInfo.isConnected) {
      return SecurityState.disconnected();
    }
    
    // Connecting state
    if (!connectionInfo.isReady) {
      return SecurityState.connecting();
    }
    
    // Connected but no identity yet
    if (connectionInfo.otherUserName == null || connectionInfo.otherUserName!.isEmpty) {
      return SecurityState.exchangingIdentity();
    }
    
    // Have identity, check contact status
    final blePublicKey = bleService.otherDevicePersistentId;
    if (blePublicKey == null) {
      return SecurityState.exchangingIdentity();
    }
    
    final otherUserName = connectionInfo.otherUserName!;
    
    // Check mutual contact status - BOTH from repository for consistency
    final contact = await bleService.stateManager.contactRepository.getContact(blePublicKey);
    final weHaveThem = contact != null && contact.trustStatus == TrustStatus.verified;

    // For existing contacts, assume mutual relationship until proven otherwise
    final theyHaveUs = weHaveThem ? true : bleService.stateManager.theyHaveUsAsContact;

    print('DEBUG SecurityStateComputer:');
    print('  weHaveThem: $weHaveThem (contact: ${contact?.displayName})');
    print('  theyHaveUs: $theyHaveUs');
    print('  blePublicKey: ${blePublicKey.substring(0, 16)}...');
    
    // Both verified contacts - highest security
    if (weHaveThem && theyHaveUs) {
  print('  → VERIFIED CONTACT state');
  return SecurityState.verifiedContact(
    otherUserName: otherUserName,
    otherPublicKey: blePublicKey,
  );
}
    
    // Asymmetric contact relationship
    if (theyHaveUs && !weHaveThem) {
      return SecurityState.asymmetricContact(
        otherUserName: otherUserName,
        otherPublicKey: blePublicKey,
      );
    }
    
    // Check if paired (has conversation key)
    final hasPaired = bleService.stateManager.getConversationKey(blePublicKey) != null;
    
    if (hasPaired) {
      return SecurityState.paired(
        otherUserName: otherUserName,
        otherPublicKey: blePublicKey,
      );
    }
    
    // Connected but needs pairing
    return SecurityState.needsPairing(
      otherUserName: otherUserName,
      otherPublicKey: blePublicKey,
    );
  }
}