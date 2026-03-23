import '../interfaces/i_contact_repository.dart';
import 'contact_crypto_service.dart';
import 'conversation_crypto_service.dart';
import 'legacy_crypto_migration_policy.dart';
import 'signing_crypto_service.dart';

/// Transitional facade kept for compatibility while call sites migrate to the
/// dedicated crypto services.
///
/// New runtime code should depend on the narrower services directly instead of
/// extending this facade.
class SimpleCrypto {
  /// Initializes the migration-only legacy compatibility decryptor.
  static void initialize() {
    LegacyCryptoMigrationPolicy.initializeCompatibilityLayer();
  }

  static Map<String, int> getDeprecatedWrapperUsageCounts() =>
      LegacyCryptoMigrationPolicy.getDeprecatedWrapperUsageCounts();

  static void resetDeprecatedWrapperUsageCounts() =>
      LegacyCryptoMigrationPolicy.resetDeprecatedWrapperUsageCounts();

  /// Compatibility helper for legacy test fixtures and migration reads only.
  static String encodeLegacyPlaintext(String plaintext) {
    return LegacyCryptoMigrationPolicy.encodeLegacyPlaintext(plaintext);
  }

  /// Compatibility helper for legacy inbound payload migration only.
  static String decryptLegacyCompatible(String encryptedBase64) {
    return LegacyCryptoMigrationPolicy.decryptLegacyCompatible(encryptedBase64);
  }

  @Deprecated(
    'Use proper encryption methods (Noise, ECDH, or Pairing). '
    'This method does NOT provide real security.',
  )
  static String encrypt(String plaintext) {
    return LegacyCryptoMigrationPolicy.encryptDeprecatedWrapper(plaintext);
  }

  @Deprecated('Use proper decryption methods (Noise, ECDH, or Pairing)')
  static String decrypt(String encryptedBase64) {
    return LegacyCryptoMigrationPolicy.decryptDeprecatedWrapper(
      encryptedBase64,
    );
  }

  static bool get isInitialized =>
      LegacyCryptoMigrationPolicy.isCompatibilityLayerInitialized;

  static void clear() {
    LegacyCryptoMigrationPolicy.clearCompatibilityState();
    SigningCryptoService.clear();
  }

  static void initializeConversation(String publicKey, String sharedSecret) {
    ConversationCryptoService.initializeConversation(publicKey, sharedSecret);
  }

  static String encryptForConversation(String plaintext, String publicKey) {
    return ConversationCryptoService.encryptForConversation(
      plaintext,
      publicKey,
    );
  }

  static String decryptFromConversation(
    String encryptedBase64,
    String publicKey,
  ) {
    return ConversationCryptoService.decryptFromConversation(
      encryptedBase64,
      publicKey,
    );
  }

  static bool hasConversationKey(String publicKey) {
    return ConversationCryptoService.hasConversationKey(publicKey);
  }

  static void initializeSigning(String privateKeyHex, String publicKeyHex) {
    SigningCryptoService.initializeSigning(privateKeyHex, publicKeyHex);
  }

  static String? signMessage(String content) {
    return SigningCryptoService.signMessage(content);
  }

  static bool verifySignature(
    String content,
    String signatureHex,
    String senderPublicKeyHex,
  ) {
    return SigningCryptoService.verifySignature(
      content,
      signatureHex,
      senderPublicKeyHex,
    );
  }

  static bool get isSigningReady => SigningCryptoService.isSigningReady;

  static String? computeSharedSecret(String theirPublicKeyHex) {
    return SigningCryptoService.computeSharedSecret(theirPublicKeyHex);
  }

  static Future<String?> encryptForContact(
    String plaintext,
    String contactPublicKey,
    IContactRepository contactRepo,
  ) => ContactCryptoService.encryptForContact(
    plaintext,
    contactPublicKey,
    contactRepo,
  );

  static Future<String?> decryptFromContact(
    String encryptedBase64,
    String contactPublicKey,
    IContactRepository contactRepo,
  ) => ContactCryptoService.decryptFromContact(
    encryptedBase64,
    contactPublicKey,
    contactRepo,
  );

  static void clearConversationKey(String publicKey) {
    ConversationCryptoService.clearConversationKey(publicKey);
  }

  static void clearAllConversationKeys() {
    ConversationCryptoService.clearAllConversationKeys();
  }

  static Future<String?> getCachedOrComputeSharedSecret(
    String contactPublicKey,
    IContactRepository contactRepo,
  ) => ContactCryptoService.getCachedOrComputeSharedSecret(
    contactPublicKey,
    contactRepo,
  );

  /// Ensure conversation key synchronization to prevent race conditions
  static Future<void> ensureConversationKeySync(
    String publicKey,
    IContactRepository repo,
  ) => ContactCryptoService.ensureConversationKeySync(publicKey, repo);

  static Future<void> restoreConversationKey(
    String publicKey,
    String cachedSecret,
  ) =>
      ConversationCryptoService.restoreConversationKey(publicKey, cachedSecret);
}
