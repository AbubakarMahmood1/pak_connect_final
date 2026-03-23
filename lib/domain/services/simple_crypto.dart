import '../interfaces/i_contact_repository.dart';
import 'contact_crypto_service.dart';
import 'conversation_crypto_service.dart';
import 'signing_crypto_service.dart';

/// Transitional active-crypto facade kept for tests and compatibility helpers.
///
/// Runtime production code should depend on the narrower services directly
/// instead of extending this facade.
class SimpleCrypto {
  /// Kept as a no-op so older tests can continue to call setup hooks safely.
  static void initialize() {}

  /// Deprecated wrapper telemetry always stays at zero because the legacy
  /// wrapper/decrypt lane has been removed.
  static Map<String, int> getDeprecatedWrapperUsageCounts() => const {
    'encrypt': 0,
    'decrypt': 0,
    'total': 0,
  };

  static void resetDeprecatedWrapperUsageCounts() {}

  static bool get isInitialized => false;

  static void clear() {
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
