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
/// **v2.1.0** bundles add incremental backup support with [baseTimestamp].
///
/// Supported bundles are self-contained: the database bytes are encrypted and
/// embedded in [encryptedDatabase], and integrity is protected by HMAC-SHA256
/// ([hmac]).
class ExportBundle {
  // Bundle metadata
  final String version;
  final DateTime timestamp;
  final String deviceId;
  final String username;
  final ExportType exportType;

  /// For incremental bundles: the cutoff timestamp — only records updated
  /// after this time are included. Null for full exports.
  final DateTime? baseTimestamp;

  // Encrypted payloads (base64 encoded)
  final String encryptedMetadata;
  final String encryptedKeys;
  final String encryptedPreferences;

  /// AES-256-GCM encrypted database bytes (base64).
  final String? encryptedDatabase;

  // Encryption metadata
  final Uint8List salt;

  /// HMAC-SHA256 keyed with the derived encryption key.
  final String? hmac;

  const ExportBundle({
    required this.version,
    required this.timestamp,
    required this.deviceId,
    required this.username,
    this.exportType = ExportType.full,
    this.baseTimestamp,
    required this.encryptedMetadata,
    required this.encryptedKeys,
    required this.encryptedPreferences,
    this.encryptedDatabase,
    required this.salt,
    this.hmac,
  });

  /// Whether this is a v2+ self-contained bundle.
  bool get isSelfContained =>
      encryptedDatabase != null && encryptedDatabase!.isNotEmpty;

  /// Whether this bundle contains only incremental changes since [baseTimestamp].
  bool get isIncremental => baseTimestamp != null;

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

    if (baseTimestamp != null) {
      json['base_timestamp'] = baseTimestamp!.toIso8601String();
    }

    if (encryptedDatabase != null && encryptedDatabase!.isNotEmpty) {
      json['encrypted_database'] = encryptedDatabase;
    }
    if (hmac != null && hmac!.isNotEmpty) {
      json['hmac'] = hmac;
    }

    return json;
  }

  /// Create from JSON (supports v1, v2, and v2.1 formats)
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
      baseTimestamp: json['base_timestamp'] != null
          ? DateTime.parse(json['base_timestamp'] as String)
          : null,
      encryptedMetadata: json['encrypted_metadata'] as String,
      encryptedKeys: json['encrypted_keys'] as String,
      encryptedPreferences: json['encrypted_preferences'] as String,
      encryptedDatabase: json['encrypted_database'] as String?,
      salt: Uint8List.fromList((json['salt'] as List).cast<int>()),
      hmac: json['hmac'] as String?,
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
