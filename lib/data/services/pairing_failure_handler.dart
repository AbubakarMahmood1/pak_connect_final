import 'dart:async';
import 'package:logging/logging.dart';
import '../../domain/models/identity_session_state.dart';
import 'package:pak_connect/domain/models/pairing_state.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import '../../domain/services/simple_crypto.dart';
import '../../data/repositories/contact_repository.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import 'pairing_service.dart';

/// Handles cleanup and state resets when pairing verification fails.
class PairingFailureHandler {
  PairingFailureHandler({
    required Logger logger,
    required ContactRepository contactRepository,
    required Map<String, String> conversationKeys,
  }) : _logger = logger,
       _contactRepository = contactRepository,
       _conversationKeys = conversationKeys;

  final Logger _logger;
  final ContactRepository _contactRepository;
  final Map<String, String> _conversationKeys;

  Future<void> handleVerificationFailure({
    required PairingInfo? previousPairing,
    required String? currentSessionId,
    required String? theirPersistentKey,
    required void Function(PairingInfo?) setPairingState,
    required void Function(String?) setTheirPersistentKey,
    required void Function()? onPairingCancelled,
    required IdentitySessionState identityState,
    required PairingService pairingService,
    String? reason,
  }) async {
    final contactId = currentSessionId ?? theirPersistentKey;
    final idsToClear = <String>{};
    if (contactId != null) idsToClear.add(contactId);
    if (theirPersistentKey != null) idsToClear.add(theirPersistentKey);
    if (currentSessionId != null) idsToClear.add(currentSessionId);

    pairingService.clearPairing();
    if (previousPairing != null) {
      setPairingState(
        PairingInfo(
          myCode: previousPairing.myCode,
          theirCode: previousPairing.theirCode,
          state: PairingState.failed,
          sharedSecret: null,
          theirEphemeralId: previousPairing.theirEphemeralId,
          theirDisplayName: previousPairing.theirDisplayName,
        ),
      );
    }

    onPairingCancelled?.call();

    for (final id in idsToClear) {
      _conversationKeys.remove(id);
      SimpleCrypto.clearConversationKey(id);
      await _contactRepository.clearCachedSecrets(id);
    }

    if (theirPersistentKey != null) {
      try {
        SecurityServiceLocator.instance.unregisterIdentityMapping(
          theirPersistentKey,
        );
      } catch (e) {
        _logger.fine(
          'Skipping identity mapping unregister for '
          '${theirPersistentKey.shortId()}...: $e',
        );
      }
      setTheirPersistentKey(null);
    }
    identityState.theirPersistentKey = null;

    if (contactId != null) {
      final contact = await _contactRepository.getContactByAnyId(contactId);
      if (contact != null && contact.securityLevel != SecurityLevel.low) {
        await _contactRepository.saveContactWithSecurity(
          contact.publicKey,
          contact.displayName,
          SecurityLevel.low,
          currentEphemeralId: contact.currentEphemeralId ?? contact.publicKey,
          persistentPublicKey: null,
        );
        _logger.info(
          '🔒 Reverted contact ${contact.publicKey.shortId()}... to LOW after verification failure${reason != null ? " ($reason)" : ""}',
        );
      }
    }

    onPairingCancelled?.call();
  }
}
