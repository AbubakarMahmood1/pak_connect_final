import 'legacy_payload_compat_service.dart';

/// Central policy seam for the remaining legacy/global compatibility lane.
///
/// This class exists so the migration kill switch and the last remaining
/// compatibility operations are defined in one place instead of leaking across
/// unrelated runtime services.
class LegacyCryptoMigrationPolicy {
  static const bool allowCompatibilityDecrypt = bool.fromEnvironment(
    'PAKCONNECT_ALLOW_LEGACY_COMPAT_DECRYPT',
    defaultValue: true,
  );

  /// Removal criteria for deleting the compatibility lane entirely.
  static const List<String> removalCriteria = <String>[
    'No supported peers require legacy/global payload decrypt compatibility.',
    'Strict validation passes with PAKCONNECT_ALLOW_LEGACY_COMPAT_DECRYPT=false.',
    'No production runtime code depends on SimpleCrypto or legacy decrypt helpers outside this policy seam.',
  ];

  static void initializeCompatibilityLayer() {
    LegacyPayloadCompatService.initialize();
  }

  static bool get isCompatibilityLayerInitialized =>
      LegacyPayloadCompatService.isInitialized;

  static Map<String, int> getDeprecatedWrapperUsageCounts() =>
      LegacyPayloadCompatService.getDeprecatedWrapperUsageCounts();

  static void resetDeprecatedWrapperUsageCounts() =>
      LegacyPayloadCompatService.resetDeprecatedWrapperUsageCounts();

  static String encodeLegacyPlaintext(String plaintext) {
    return LegacyPayloadCompatService.encodeLegacyPlaintext(plaintext);
  }

  static String decryptLegacyCompatible(String encryptedBase64) {
    if (!allowCompatibilityDecrypt) {
      throw Exception('Legacy compatibility decrypt disabled by policy');
    }
    return LegacyPayloadCompatService.decryptLegacyCompatible(encryptedBase64);
  }

  static String encryptDeprecatedWrapper(String plaintext) {
    return LegacyPayloadCompatService.encrypt(plaintext);
  }

  static String decryptDeprecatedWrapper(String encryptedBase64) {
    if (!allowCompatibilityDecrypt) {
      throw Exception('Legacy compatibility decrypt disabled by policy');
    }
    return LegacyPayloadCompatService.decrypt(encryptedBase64);
  }

  static void clearCompatibilityState() {
    LegacyPayloadCompatService.clear();
  }
}
