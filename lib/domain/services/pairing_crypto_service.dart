import 'package:logging/logging.dart';

import '../interfaces/i_contact_repository.dart';
import 'conversation_crypto_service.dart';
import 'signing_crypto_service.dart';

/// Owns pairing/shared-secret lifecycle work so higher-level flows do not
/// reach directly into lower-level crypto primitives.
class PairingCryptoService {
  PairingCryptoService({
    required Logger logger,
    required IContactRepository contactRepository,
    Map<String, String>? runtimeConversationSecrets,
  }) : _logger = logger,
       _contactRepository = contactRepository,
       _runtimeConversationSecrets = runtimeConversationSecrets;

  final Logger _logger;
  final IContactRepository _contactRepository;
  final Map<String, String>? _runtimeConversationSecrets;

  bool hasConversationKey(String contactId) {
    if (contactId.isEmpty) {
      return false;
    }
    return ConversationCryptoService.hasConversationKey(contactId);
  }

  String? runtimeSecretFor(String contactId) {
    if (contactId.isEmpty) {
      return null;
    }
    return _runtimeConversationSecrets?[contactId];
  }

  void initializeConversation(String contactId, String sharedSecret) {
    if (contactId.isEmpty || sharedSecret.isEmpty) {
      _logger.warning(
        'Skipping pairing conversation initialization for empty contact/secret',
      );
      return;
    }

    ConversationCryptoService.initializeConversation(contactId, sharedSecret);
    _runtimeConversationSecrets?[contactId] = sharedSecret;
  }

  bool restoreConversationFromRuntimeSecret(String contactId) {
    final runtimeSecret = runtimeSecretFor(contactId);
    if (runtimeSecret == null || runtimeSecret.isEmpty) {
      return false;
    }

    ConversationCryptoService.initializeConversation(contactId, runtimeSecret);
    return true;
  }

  Future<bool> initializePairingConversationFromCachedSecret({
    required String contactId,
    required Future<String> Function() myPersistentIdProvider,
  }) async {
    if (contactId.isEmpty) {
      _logger.warning(
        'initializePairingConversationFromCachedSecret called with empty contactId',
      );
      return false;
    }

    if (hasConversationKey(contactId)) {
      return true;
    }

    final cachedSecret = await _contactRepository.getCachedSharedSecret(
      contactId,
    );
    if (cachedSecret == null || cachedSecret.isEmpty) {
      return false;
    }

    final myPersistentId = await myPersistentIdProvider();
    final conversationSeed = cachedSecret + myPersistentId + contactId;
    initializeConversation(contactId, conversationSeed);
    return true;
  }

  Future<bool> restoreConversationFromCachedSecret(String contactId) async {
    if (contactId.isEmpty) {
      _logger.warning(
        'restoreConversationFromCachedSecret called with empty contactId',
      );
      return false;
    }

    final cachedSecret = await _contactRepository.getCachedSharedSecret(
      contactId,
    );
    if (cachedSecret == null || cachedSecret.isEmpty) {
      return false;
    }

    _runtimeConversationSecrets?[contactId] = cachedSecret;
    await ConversationCryptoService.restoreConversationKey(
      contactId,
      cachedSecret,
    );
    return true;
  }

  Future<void> cacheSharedSecret({
    required String contactId,
    String? alternateSessionId,
    required String sharedSecret,
  }) async {
    final ids = _normalizedIds(contactId, alternateSessionId);
    if (ids.isEmpty) {
      _logger.warning('cacheSharedSecret called without any valid contact IDs');
      return;
    }
    if (sharedSecret.isEmpty) {
      _logger.warning('cacheSharedSecret called with empty shared secret');
      return;
    }

    for (final id in ids) {
      _runtimeConversationSecrets?[id] = sharedSecret;
      await _contactRepository.cacheSharedSecret(id, sharedSecret);
      ConversationCryptoService.initializeConversation(id, sharedSecret);
    }
  }

  Future<String?> computeAndCacheSharedSecret(
    String contactId, {
    String? alternateSessionId,
  }) async {
    if (contactId.isEmpty) {
      _logger.warning(
        'computeAndCacheSharedSecret called with empty contactId',
      );
      return null;
    }

    final sharedSecret = SigningCryptoService.computeSharedSecret(contactId);
    if (sharedSecret == null || sharedSecret.isEmpty) {
      return null;
    }

    await cacheSharedSecret(
      contactId: contactId,
      alternateSessionId: alternateSessionId,
      sharedSecret: sharedSecret,
    );
    return sharedSecret;
  }

  void clearConversationKey(String contactId) {
    if (contactId.isEmpty) {
      return;
    }

    _runtimeConversationSecrets?.remove(contactId);
    ConversationCryptoService.clearConversationKey(contactId);
  }

  Future<void> clearConversationState(
    Iterable<String> contactIds, {
    bool clearCachedSecrets = true,
  }) async {
    for (final id in _normalizedIdsFromIterable(contactIds)) {
      clearConversationKey(id);
      if (clearCachedSecrets) {
        await _contactRepository.clearCachedSecrets(id);
      }
    }
  }

  List<String> _normalizedIds(String contactId, String? alternateSessionId) {
    return _normalizedIdsFromIterable(<String?>[contactId, alternateSessionId]);
  }

  List<String> _normalizedIdsFromIterable(Iterable<String?> ids) {
    final normalized = <String>[];
    final seen = <String>{};

    for (final rawId in ids) {
      final id = rawId?.trim();
      if (id == null || id.isEmpty || !seen.add(id)) {
        continue;
      }
      normalized.add(id);
    }

    return normalized;
  }
}
