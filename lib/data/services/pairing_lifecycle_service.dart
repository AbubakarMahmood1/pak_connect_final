import 'package:logging/logging.dart';
import '../../domain/models/identity_session_state.dart';
import 'package:pak_connect/domain/interfaces/i_identity_manager.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/models/spy_mode_info.dart';
import 'package:pak_connect/domain/services/pairing_crypto_service.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import '../../domain/services/ephemeral_key_manager.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/intro_hint_repository.dart';
import '../../data/repositories/user_preferences.dart';
import 'package:pak_connect/domain/values/id_types.dart';

/// Handles post-verification pairing lifecycle steps so the pairing flow
/// controller can stay lean and delegate identity/persistence updates.
class PairingLifecycleService {
  PairingLifecycleService({
    required Logger logger,
    required ContactRepository contactRepository,
    required IdentitySessionState identityState,
    required Map<String, String> conversationKeys,
    required Future<String> Function() myPersistentIdProvider,
    required Future<void> Function({
      required String ephemeralId,
      required String persistentKey,
      String? contactName,
    })
    triggerChatMigration,
    IIdentityManager? identityManager,
    ISecurityService? securityService,
    PairingCryptoService? pairingCryptoService,
  }) : _logger = logger,
       _contactRepository = contactRepository,
       _identityState = identityState,
       _getMyPersistentId = myPersistentIdProvider,
       _triggerChatMigration = triggerChatMigration,
       _identityManager = identityManager,
       _securityService = securityService,
       _pairingCrypto =
           pairingCryptoService ??
           PairingCryptoService(
             logger: logger,
             contactRepository: contactRepository,
             runtimeConversationSecrets: conversationKeys,
           );

  final Logger _logger;
  final ContactRepository _contactRepository;
  final IdentitySessionState _identityState;
  final Future<String> Function() _getMyPersistentId;
  final Future<void> Function({
    required String ephemeralId,
    required String persistentKey,
    String? contactName,
  })
  _triggerChatMigration;
  final IIdentityManager? _identityManager;
  final ISecurityService? _securityService;
  final PairingCryptoService _pairingCrypto;

  ISecurityService get _resolvedSecurityService =>
      _securityService ?? SecurityServiceLocator.resolveService();

  Future<void> ensureContactExistsAfterHandshake(
    String publicKey,
    String displayName, {
    String? ephemeralId,
  }) async {
    final userId = _toUserId(publicKey);
    if (userId == null) {
      _logger.warning(
        'Handshake contact key is empty; skipping contact create',
      );
      return;
    }

    final existingContact = await _contactRepository.getContactByUserId(userId);

    if (existingContact == null) {
      await _contactRepository.saveContactWithSecurity(
        publicKey,
        displayName,
        SecurityLevel.low,
        currentEphemeralId: ephemeralId,
      );
      _logger.info(
        '🔒 HANDSHAKE: Created contact with LOW security (Noise session): $displayName',
      );

      await _deleteIntroHintAfterConnection(displayName, publicKey);
    } else {
      if (existingContact.securityLevel.index < SecurityLevel.low.index) {
        await _contactRepository.updateContactSecurityLevel(
          userId.value,
          SecurityLevel.low,
        );
        _logger.info(
          '🔒 HANDSHAKE: Updated contact to LOW security (Noise session): $displayName',
        );
      }
      if (ephemeralId != null) {
        await _contactRepository.updateContactEphemeralId(
          userId.value,
          ephemeralId,
        );
        _logger.info(
          '🔒 HANDSHAKE: Updated ephemeral ID for contact: $displayName',
        );
      }
    }
  }

  Future<void> cacheSharedSecret({
    required String contactId,
    String? alternateSessionId,
    required String sharedSecret,
  }) async {
    final contactUserId = _toUserId(contactId);
    final alternateUserId = alternateSessionId != null
        ? _toUserId(alternateSessionId)
        : null;
    if (contactUserId == null) {
      _logger.warning('cacheSharedSecret called with empty contactId');
      return;
    }

    await _pairingCrypto.cacheSharedSecret(
      contactId: contactUserId.value,
      alternateSessionId: alternateUserId?.value,
      sharedSecret: sharedSecret,
    );
  }

  Future<void> upgradeContactToMediumSecurity({
    required String? theirEphemeralId,
    required String theirPersistentKey,
    String? displayName,
  }) async {
    if (theirEphemeralId == null) {
      _logger.warning('⚠️ Missing ephemeral ID for security upgrade');
      return;
    }

    final theirEphUserId = _toUserId(theirEphemeralId);
    if (theirEphUserId == null) {
      _logger.warning('⚠️ Cannot upgrade - empty ephemeral ID');
      return;
    }

    final contact = await _contactRepository.getContactByUserId(theirEphUserId);

    if (contact == null) {
      _logger.warning('⚠️ Cannot upgrade - contact not found');
      return;
    }

    await _contactRepository.saveContactWithSecurity(
      contact.publicKey,
      contact.displayName,
      SecurityLevel.medium,
      currentEphemeralId: contact.currentEphemeralId,
      persistentPublicKey: theirPersistentKey,
    );

    _logger.info('✅ Contact upgraded to MEDIUM');
    _logger.info('   publicKey (unchanged): ${contact.publicKey.shortId()}...');
    _logger.info(
      '   persistentPublicKey (now set): ${theirPersistentKey.shortId()}...',
    );

    _resolvedSecurityService.registerIdentityMapping(
      persistentPublicKey: theirPersistentKey,
      ephemeralID: theirEphemeralId,
    );
    _logger.info(
      '🔑 Registered Noise identity mapping: ${theirPersistentKey.shortId(8)}... → ${theirEphemeralId.shortId(8)}...',
    );

    await _triggerChatMigration(
      ephemeralId: contact.publicKey,
      persistentKey: theirPersistentKey,
      contactName: displayName,
    );
  }

  Future<void> handlePersistentKeyExchange({
    required String theirPersistentKey,
    String? displayName,
    void Function(SpyModeInfo info)? onSpyModeDetected,
  }) async {
    final theirEphemeralId = _identityState.theirEphemeralId;
    if (theirEphemeralId == null) {
      _logger.warning('❌ Cannot process persistent key - no ephemeral ID');
      return;
    }

    _identityState.setPersistentAssociation(
      persistentKey: theirPersistentKey,
      ephemeralId: theirEphemeralId,
    );
    _identityManager?.setTheirPersistentKey(
      theirPersistentKey,
      ephemeralId: theirEphemeralId,
    );
    _identityManager?.setCurrentSessionId(theirPersistentKey);

    _resolvedSecurityService.registerIdentityMapping(
      persistentPublicKey: theirPersistentKey,
      ephemeralID: theirEphemeralId,
    );
    _logger.info(
      '🔐 Persistent key identity mapping registered: ${_truncateId(theirEphemeralId)} ↔ ${_truncateId(theirPersistentKey)}',
    );

    await _contactRepository.saveContactWithSecurity(
      theirEphemeralId,
      displayName ?? 'User',
      SecurityLevel.low,
      currentEphemeralId: theirEphemeralId,
      persistentPublicKey: null,
    );

    final myPersistentKey = await _getMyPersistentId();
    final myEphId = EphemeralKeyManager.generateMyEphemeralKey();
    _logger.info('═══════════════════════════════════════════════════════════');
    _logger.info('🔑📊 HANDSHAKE COMPLETE: ${displayName ?? "Unknown"}');
    _logger.info(
      '🔑📊 My Keys:    Ephemeral=$myEphId | Persistent=${_truncateId(myPersistentKey)}',
    );
    _logger.info(
      '🔑📊 Their Keys: Ephemeral=$theirEphemeralId | Persistent=${_truncateId(theirPersistentKey)}',
    );
    _logger.info('🔑📊 Security:   LOW (Noise session only - not paired yet)');
    _logger.info(
      '🔑📊 Contact ID: $theirEphemeralId (ephemeral - will upgrade on pairing)',
    );
    _logger.info('═══════════════════════════════════════════════════════════');

    await _identityState.detectSpyMode(
      persistentKey: theirPersistentKey,
      getContactDisplayName: (pk) async {
        final contact = await _contactRepository.getContact(pk);
        return contact?.displayName;
      },
      hintsEnabledFetcher: () async {
        final userPrefs = UserPreferences();
        return userPrefs.getHintBroadcastEnabled();
      },
      onSpyModeDetected: onSpyModeDetected,
    );
  }

  Future<void> _deleteIntroHintAfterConnection(
    String displayName,
    String publicKey,
  ) async {
    try {
      final introHintRepo = IntroHintRepository();
      final scannedHints = await introHintRepo.getScannedHints();

      for (final hint in scannedHints.values) {
        if (hint.displayName == displayName) {
          await introHintRepo.removeScannedHint(hint.hintHex);
          _logger.info(
            '🗑️ PRIVACY: Deleted intro hint after connection: ${hint.hintHex} ($displayName)',
          );
          _logger.info(
            '   Reason: Intro hints are temporary - prevents identity linkage across sessions',
          );
          return;
        }
      }

      _logger.fine(
        'ℹ️ No intro hint found to delete for $displayName (may not be QR-based connection)',
      );
    } catch (e, stackTrace) {
      _logger.warning('⚠️ Failed to delete intro hint for $displayName: $e');
      _logger.fine(stackTrace);
    }
  }

  String _truncateId(String? id, {int maxLength = 16}) {
    if (id == null) return 'null';
    if (id.length <= maxLength) return id;
    return '${id.substring(0, maxLength)}...';
  }

  UserId? _toUserId(String publicKey) {
    if (publicKey.isEmpty) return null;
    return UserId(publicKey);
  }
}
