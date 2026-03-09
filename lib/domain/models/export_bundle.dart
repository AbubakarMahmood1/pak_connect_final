// Export bundle data model
// Represents the encrypted export package structure

import 'dart:typed_data';

/// Type of data to export
enum ExportType {
  full, // Everything: contacts, messages, chats, preferences
  contactsOnly, // Only contacts table
  messagesOnly, // Messages + chats (messages need chat context)
}

/// Represents an encrypted export bundle.
///
/// **v2.0.0** bundles are self-contained: the database bytes are encrypted and
/// embedded in [encryptedDatabase], integrity is protected by HMAC-SHA256
/// ([hmac]), and [databasePath] is unused.
///
/// **v1.0.0** (legacy) bundles reference an external DB file via
/// [databasePath] and use an unkeyed SHA-256 [checksum].
class ExportBundle {
  // Bundle metadata
  final String version;
  final DateTime timestamp;
  final String deviceId;
  final String username;
  final ExportType exportType;

  // Encrypted payloads (base64 encoded)
  final String encryptedMetadata;
  final String encryptedKeys;
  final String encryptedPreferences;

  /// v2: AES-256-GCM encrypted database bytes (base64). Null for v1 bundles.
  final String? encryptedDatabase;

  /// v1 only: path to external database file. Empty string for v2 bundles.
  final String databasePath;

  // Encryption metadata
  final Uint8List salt;

  /// v2: HMAC-SHA256 keyed with the derived encryption key. Null for v1.
  final String? hmac;

  /// v1 only: unkeyed SHA-256 checksum. Null for v2 bundles.
  final String? checksum;

  const ExportBundle({
    required this.version,
    required this.timestamp,
    required this.deviceId,
    required this.username,
    this.exportType = ExportType.full,
    required this.encryptedMetadata,
    required this.encryptedKeys,
    required this.encryptedPreferences,
    this.encryptedDatabase,
    this.databasePath = '',
    required this.salt,
    this.hmac,
    this.checksum,
  });

  /// Whether this is a v2+ self-contained bundle.
  bool get isSelfContained => encryptedDatabase != null && encryptedDatabase!.isNotEmpty;

  /// Whether this is a legacy v1 bundle with an external DB path.
  bool get isLegacy => !isSelfContained;

  /// Convert to JSON for serialization
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'version': version,
      'timestamp': timestamp.toIso8601String(),
      'device_id': deviceId,
      'username': username,
      'export_type': exportType.name,
      'encrypted_metadata': encryptedMetadata,
      'encrypted_keys': encryptedKeys,
      'encrypted_preferences': encryptedPreferences,
      'salt': salt.toList(),
    };

    if (isSelfContained) {
      json['encrypted_database'] = encryptedDatabase;
      json['hmac'] = hmac;
    } else {
      json['database_path'] = databasePath;
      json['checksum'] = checksum;
    }

    return json;
  }

  /// Create from JSON (supports both v1 and v2 formats)
  factory ExportBundle.fromJson(Map<String, dynamic> json) {
    return ExportBundle(
      version: json['version'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      deviceId: json['device_id'] as String,
      username: json['username'] as String,
      exportType: ExportType.values.firstWhere(
        (e) => e.name == (json['export_type'] ?? 'full'),
        orElse: () => ExportType.full,
      ),
      encryptedMetadata: json['encrypted_metadata'] as String,
      encryptedKeys: json['encrypted_keys'] as String,
      encryptedPreferences: json['encrypted_preferences'] as String,
      encryptedDatabase: json['encrypted_database'] as String?,
      databasePath: (json['database_path'] as String?) ?? '',
      salt: Uint8List.fromList((json['salt'] as List).cast<int>()),
      hmac: json['hmac'] as String?,
      checksum: json['checksum'] as String?,
    );
  }
}

/// Result of export operation
class ExportResult {
  final bool success;
  final String? bundlePath;
  final String? errorMessage;
  final int? bundleSize;
  final ExportType? exportType;
  final int? recordCount; // Number of records exported

  ExportResult.success({
    required this.bundlePath,
    required this.bundleSize,
    this.exportType,
    this.recordCount,
  }) : success = true,
       errorMessage = null;

  ExportResult.failure(this.errorMessage)
    : success = false,
      bundlePath = null,
      bundleSize = null,
      exportType = null,
      recordCount = null;

  @override
  String toString() => success
      ? 'ExportResult(success, type: ${exportType?.name ?? "full"}, records: $recordCount, path: $bundlePath, size: ${bundleSize! / 1024}KB)'
      : 'ExportResult(failure: $errorMessage)';
}

/// Result of import operation
class ImportResult {
  final bool success;
  final String? errorMessage;
  final int recordsRestored;
  final String? originalDeviceId;
  final String? originalUsername;
  final DateTime? backupTimestamp;

  ImportResult.success({
    required this.recordsRestored,
    this.originalDeviceId,
    this.originalUsername,
    this.backupTimestamp,
  }) : success = true,
       errorMessage = null;

  ImportResult.failure(this.errorMessage)
    : success = false,
      recordsRestored = 0,
      originalDeviceId = null,
      originalUsername = null,
      backupTimestamp = null;

  @override
  String toString() => success
      ? 'ImportResult(success, records: $recordsRestored, from: $originalUsername @ $originalDeviceId)'
      : 'ImportResult(failure: $errorMessage)';
}

/// Passphrase validation result
class PassphraseValidation {
  final bool isValid;
  final double strength; // 0.0 to 1.0
  final List<String> warnings;

  const PassphraseValidation({
    required this.isValid,
    required this.strength,
    required this.warnings,
  });

  bool get isWeak => strength < 0.3;
  bool get isMedium => strength >= 0.3 && strength < 0.7;
  bool get isStrong => strength >= 0.7;
}
