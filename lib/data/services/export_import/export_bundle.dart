// Export bundle data model
// Represents the encrypted export package structure

import 'dart:typed_data';

/// Represents an encrypted export bundle
class ExportBundle {
  // Bundle metadata
  final String version;
  final DateTime timestamp;
  final String deviceId;
  final String username;
  
  // Encrypted payloads (base64 encoded)
  final String encryptedMetadata;
  final String encryptedKeys;
  final String encryptedPreferences;
  final String databasePath; // Path to encrypted database file
  
  // Encryption metadata
  final Uint8List salt; // For PBKDF2 key derivation
  final String checksum; // SHA-256 of all encrypted data
  
  const ExportBundle({
    required this.version,
    required this.timestamp,
    required this.deviceId,
    required this.username,
    required this.encryptedMetadata,
    required this.encryptedKeys,
    required this.encryptedPreferences,
    required this.databasePath,
    required this.salt,
    required this.checksum,
  });
  
  /// Convert to JSON for serialization
  Map<String, dynamic> toJson() => {
    'version': version,
    'timestamp': timestamp.toIso8601String(),
    'device_id': deviceId,
    'username': username,
    'encrypted_metadata': encryptedMetadata,
    'encrypted_keys': encryptedKeys,
    'encrypted_preferences': encryptedPreferences,
    'database_path': databasePath,
    'salt': salt.toList(),
    'checksum': checksum,
  };
  
  /// Create from JSON
  factory ExportBundle.fromJson(Map<String, dynamic> json) {
    return ExportBundle(
      version: json['version'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      deviceId: json['device_id'] as String,
      username: json['username'] as String,
      encryptedMetadata: json['encrypted_metadata'] as String,
      encryptedKeys: json['encrypted_keys'] as String,
      encryptedPreferences: json['encrypted_preferences'] as String,
      databasePath: json['database_path'] as String,
      salt: Uint8List.fromList((json['salt'] as List).cast<int>()),
      checksum: json['checksum'] as String,
    );
  }
}

/// Result of export operation
class ExportResult {
  final bool success;
  final String? bundlePath;
  final String? errorMessage;
  final int? bundleSize;
  
  ExportResult.success({
    required this.bundlePath,
    required this.bundleSize,
  })  : success = true,
        errorMessage = null;
  
  ExportResult.failure(this.errorMessage)
      : success = false,
        bundlePath = null,
        bundleSize = null;
  
  @override
  String toString() => success
      ? 'ExportResult(success, path: $bundlePath, size: ${bundleSize! / 1024}KB)'
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
  })  : success = true,
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
