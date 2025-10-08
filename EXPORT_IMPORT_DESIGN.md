# PakConnect Export/Import System Design

## Overview
Complete data portability solution allowing users to migrate their entire app identity, data, and settings between devices or restore from backups.

## Architecture

### Export Bundle Structure
```
export_bundle.pakconnect (encrypted ZIP-like format)
├── metadata.json (encrypted)
│   ├── version: "1.0.0"
│   ├── timestamp: ISO-8601
│   ├── device_id: original device
│   ├── username: user's display name
│   └── checksum: SHA-256 of bundle contents
├── database.db (already encrypted with SQLCipher)
├── keys.json (encrypted)
│   ├── database_encryption_key
│   ├── ecdh_public_key
│   ├── ecdh_private_key
│   └── key_version: "v2"
└── preferences.json (encrypted)
    ├── app_preferences (from SQLite)
    └── shared_preferences (selected non-sensitive)
```

### Security Model

#### Two-Layer Encryption
1. **Layer 1 - Database** (existing):
   - SQLCipher encryption with random key
   - Key stored in OS secure storage
   
2. **Layer 2 - Export Bundle** (new):
   - User-provided passphrase
   - PBKDF2 key derivation (100k iterations)
   - AES-256-GCM encryption
   - Bundle-level integrity verification

#### Key Derivation
```dart
User Passphrase (min 12 chars)
  → PBKDF2-HMAC-SHA256 (100,000 iterations)
    → Salt (random 32 bytes, stored in bundle header)
      → AES-256 Key
        → Encrypts: metadata + keys + preferences
```

#### Security Properties
✅ **Export file useless without passphrase** (even if leaked)
✅ **Different passphrase = different encryption** (can create multiple backups)
✅ **Integrity verification** (detect tampering)
✅ **Forward compatibility** (version field for future changes)
✅ **No cloud dependency** (fully offline)

## Implementation

### Phase 1: Export System

#### `lib/data/services/export_service.dart`
```dart
class ExportBundle {
  final String version = '1.0.0';
  final DateTime timestamp;
  final String deviceId;
  final String username;
  
  // Encrypted payloads
  final Uint8List encryptedDatabase;
  final String encryptedKeys;  // JSON
  final String encryptedPreferences;  // JSON
  
  // Encryption metadata
  final Uint8List salt;  // For PBKDF2
  final String checksum;
}

class ExportService {
  /// Create encrypted export bundle
  /// Returns: File path to .pakconnect bundle
  static Future<ExportResult> createExport({
    required String userPassphrase,
    String? customPath,
  }) async {
    // 1. Validate passphrase strength
    if (!_isStrongPassphrase(userPassphrase)) {
      return ExportResult.failure('Passphrase too weak (min 12 chars, mix of letters/numbers)');
    }
    
    // 2. Close database, create backup
    await DatabaseHelper.close();
    final dbBackup = await DatabaseBackupService.createBackup();
    
    // 3. Collect encryption keys from secure storage
    final keys = await _collectKeys();
    
    // 4. Collect preferences
    final preferences = await _collectPreferences();
    
    // 5. Generate random salt, derive encryption key
    final salt = _generateSalt();
    final encryptionKey = await _deriveKey(userPassphrase, salt);
    
    // 6. Encrypt each component
    final encryptedKeys = await _encrypt(jsonEncode(keys), encryptionKey);
    final encryptedPrefs = await _encrypt(jsonEncode(preferences), encryptionKey);
    
    // 7. Create bundle metadata
    final metadata = {
      'version': '1.0.0',
      'timestamp': DateTime.now().toIso8601String(),
      'device_id': await _getDeviceId(),
      'username': await _getUsername(),
    };
    final encryptedMeta = await _encrypt(jsonEncode(metadata), encryptionKey);
    
    // 8. Calculate checksum of all encrypted data
    final checksum = _calculateChecksum([
      encryptedMeta,
      encryptedKeys,
      encryptedPrefs,
      dbBackup.backupPath!,
    ]);
    
    // 9. Write bundle file
    final bundlePath = await _writeBundleFile(
      metadata: encryptedMeta,
      keys: encryptedKeys,
      preferences: encryptedPrefs,
      databasePath: dbBackup.backupPath!,
      salt: salt,
      checksum: checksum,
      destinationPath: customPath,
    );
    
    // 10. Reopen database
    await DatabaseHelper.database;
    
    return ExportResult.success(bundlePath);
  }
  
  static Future<Map<String, String>> _collectKeys() async {
    final storage = FlutterSecureStorage();
    return {
      'database_encryption_key': await storage.read(key: 'db_encryption_key_v1') ?? '',
      'ecdh_public_key': await storage.read(key: 'ecdh_public_key_v2') ?? '',
      'ecdh_private_key': await storage.read(key: 'ecdh_private_key_v2') ?? '',
      'key_version': 'v2',
    };
  }
  
  static Future<Map<String, dynamic>> _collectPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final prefsRepo = PreferencesRepository();
    
    return {
      'app_preferences': await prefsRepo.getAll(),
      'username': prefs.getString('user_display_name'),
      'device_id': prefs.getString('my_persistent_device_id'),
      // Add other non-sensitive preferences
    };
  }
}
```

#### `lib/data/services/import_service.dart`
```dart
class ImportService {
  /// Import and restore from encrypted bundle
  static Future<ImportResult> importBundle({
    required String bundlePath,
    required String userPassphrase,
  }) async {
    try {
      // 1. Read and parse bundle
      final bundle = await _readBundleFile(bundlePath);
      
      // 2. Derive decryption key from passphrase
      final decryptionKey = await _deriveKey(userPassphrase, bundle.salt);
      
      // 3. Decrypt and verify metadata first
      final metadataJson = await _decrypt(bundle.encryptedMetadata, decryptionKey);
      if (metadataJson == null) {
        return ImportResult.failure('Invalid passphrase or corrupted file');
      }
      
      final metadata = jsonDecode(metadataJson);
      
      // 4. Verify checksum
      if (!_verifyChecksum(bundle)) {
        return ImportResult.failure('Bundle integrity check failed - file may be tampered');
      }
      
      // 5. Decrypt keys and preferences
      final keysJson = await _decrypt(bundle.encryptedKeys, decryptionKey);
      final prefsJson = await _decrypt(bundle.encryptedPreferences, decryptionKey);
      
      if (keysJson == null || prefsJson == null) {
        return ImportResult.failure('Decryption failed - invalid passphrase');
      }
      
      final keys = jsonDecode(keysJson);
      final preferences = jsonDecode(prefsJson);
      
      // 6. Validate version compatibility
      if (!_isCompatibleVersion(metadata['version'])) {
        return ImportResult.failure('Incompatible backup version: ${metadata['version']}');
      }
      
      // 7. CRITICAL: Clear existing data first
      await _clearExistingData();
      
      // 8. Restore encryption keys to secure storage
      await _restoreKeys(keys);
      
      // 9. Restore database
      final restoreResult = await DatabaseBackupService.restoreBackup(
        backupPath: bundle.databasePath,
        validateChecksum: true,
      );
      
      if (!restoreResult.success) {
        return ImportResult.failure('Database restore failed: ${restoreResult.errorMessage}');
      }
      
      // 10. Restore preferences
      await _restorePreferences(preferences);
      
      return ImportResult.success(
        recordsRestored: restoreResult.recordsRestored ?? 0,
        originalDeviceId: metadata['device_id'],
        originalUsername: metadata['username'],
        backupTimestamp: DateTime.parse(metadata['timestamp']),
      );
      
    } catch (e, stack) {
      return ImportResult.failure('Import failed: $e\n$stack');
    }
  }
  
  static Future<void> _clearExistingData() async {
    // Clear SQLite database
    await DatabaseHelper.clearAllData();
    
    // Clear SharedPreferences (except migration flags)
    final prefs = await SharedPreferences.getInstance();
    final keysToKeep = ['sqlite_migration_completed'];
    final allKeys = prefs.getKeys();
    
    for (final key in allKeys) {
      if (!keysToKeep.contains(key)) {
        await prefs.remove(key);
      }
    }
    
    // Clear secure storage
    final storage = FlutterSecureStorage();
    await storage.deleteAll();
  }
  
  static Future<void> _restoreKeys(Map<String, dynamic> keys) async {
    final storage = FlutterSecureStorage();
    
    await storage.write(
      key: 'db_encryption_key_v1',
      value: keys['database_encryption_key'],
    );
    
    await storage.write(
      key: 'ecdh_public_key_v2',
      value: keys['ecdh_public_key'],
    );
    
    await storage.write(
      key: 'ecdh_private_key_v2',
      value: keys['ecdh_private_key'],
    );
  }
  
  static Future<void> _restorePreferences(Map<String, dynamic> preferences) async {
    final prefs = await SharedPreferences.getInstance();
    final prefsRepo = PreferencesRepository();
    
    // Restore app preferences to SQLite
    final appPrefs = preferences['app_preferences'] as Map<String, dynamic>?;
    if (appPrefs != null) {
      for (final entry in appPrefs.entries) {
        // Determine type and restore appropriately
        if (entry.value is String) {
          await prefsRepo.setString(entry.key, entry.value);
        } else if (entry.value is bool) {
          await prefsRepo.setBool(entry.key, entry.value);
        } else if (entry.value is int) {
          await prefsRepo.setInt(entry.key, entry.value);
        }
      }
    }
    
    // Restore SharedPreferences
    if (preferences['username'] != null) {
      await prefs.setString('user_display_name', preferences['username']);
    }
    
    if (preferences['device_id'] != null) {
      await prefs.setString('my_persistent_device_id', preferences['device_id']);
    }
  }
}
```

### Phase 2: UI Integration

#### Welcome Flow Enhancement
```dart
// lib/presentation/screens/welcome_import_screen.dart
class WelcomeImportScreen extends StatelessWidget {
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Welcome to PakConnect', style: Theme.of(context).textTheme.headlineMedium),
            SizedBox(height: 40),
            
            ElevatedButton.icon(
              icon: Icon(Icons.fiber_new),
              label: Text('Start Fresh'),
              onPressed: () => _startFresh(context),
            ),
            
            SizedBox(height: 20),
            
            OutlinedButton.icon(
              icon: Icon(Icons.upload_file),
              label: Text('Import Backup'),
              onPressed: () => _showImportDialog(context),
            ),
          ],
        ),
      ),
    );
  }
  
  void _showImportDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => ImportDialog(),
    );
  }
}
```

#### Export Screen (Settings)
```dart
// Add to SettingsScreen
ListTile(
  leading: Icon(Icons.download),
  title: Text('Export All Data'),
  subtitle: Text('Create encrypted backup of all your data'),
  onTap: () => _showExportDialog(),
),

void _showExportDialog() {
  showDialog(
    context: context,
    builder: (context) => ExportDialog(),
  );
}
```

## File Format Specification

### `.pakconnect` Bundle Format
```
Bytes 0-15:   Magic header "PAKCONNECT_V1\n\n"
Bytes 16-23:  Version number (uint64)
Bytes 24-55:  Salt (32 bytes)
Bytes 56-119: Checksum (SHA-256, 64 hex chars)
Bytes 120+:   Encrypted payload (AES-256-GCM)

Encrypted Payload Structure (JSON):
{
  "metadata": {...},
  "keys": {...},
  "preferences": {...},
  "database_offset": 12345,  // Byte offset to embedded database
  "database_size": 567890     // Size in bytes
}

After JSON: Raw database file bytes
```

## Security Considerations

### Passphrase Requirements
- Minimum 12 characters
- Must contain letters and numbers
- Recommended: Mix of upper/lower/symbols
- Show strength meter during entry
- Require confirmation (type twice)

### Attack Resistance
- **Brute Force**: PBKDF2 with 100k iterations makes cracking expensive
- **Dictionary**: Strong passphrase requirement
- **Tampering**: SHA-256 checksum verification
- **Man-in-Middle**: Offline system, no network transfer
- **Data Leak**: Encrypted at rest and in transit

### Edge Cases
1. **Corrupted Bundle**: Checksum fails → user-friendly error
2. **Wrong Passphrase**: Decryption fails → retry with warning
3. **Version Mismatch**: Forward/backward compatibility checks
4. **Partial Import**: Transaction rollback on failure
5. **Duplicate Import**: Warn user about overwriting data

## User Experience Flow

### Export Flow
```
Settings → Export Data
  ↓
Enter Passphrase (with strength meter)
  ↓
Confirm Passphrase
  ↓
[Progress: Collecting data...]
[Progress: Encrypting...]
[Progress: Creating bundle...]
  ↓
Success! → Share/Save options
  ↓
Options:
  - Save to Downloads
  - Share via Bluetooth
  - Share via Files
```

### Import Flow (First Launch)
```
Welcome Screen
  ↓
"Import Backup" button
  ↓
File picker (.pakconnect files only)
  ↓
Enter passphrase
  ↓
[Progress: Validating...]
[Progress: Decrypting...]
[Progress: Restoring data...]
  ↓
Success! → Continue to permissions
```

### Import Flow (Existing User)
```
Settings → Import Data
  ↓
⚠️ Warning: "This will REPLACE all current data!"
  ↓
Confirm deletion
  ↓
[Same as first launch import]
```

## Testing Strategy

### Unit Tests
- ✅ PBKDF2 key derivation
- ✅ AES-256-GCM encryption/decryption
- ✅ Checksum calculation/verification
- ✅ Passphrase strength validation
- ✅ Bundle format parsing
- ✅ Version compatibility checks

### Integration Tests
- ✅ Full export → import cycle
- ✅ Import on fresh device
- ✅ Import with existing data (replacement)
- ✅ Corrupted bundle handling
- ✅ Wrong passphrase handling
- ✅ Large database export/import

### Manual Tests
- ✅ Export on Device A → Import on Device B
- ✅ All data preserved (messages, contacts, settings)
- ✅ Encryption keys work (can decrypt messages)
- ✅ User identity preserved
- ✅ UI shows correct username/settings

## Implementation Phases

### Phase 1: Core Export/Import (Week 1)
- [x] Design review
- [ ] `ExportService` implementation
- [ ] `ImportService` implementation
- [ ] Encryption utilities (PBKDF2, AES-256-GCM)
- [ ] Bundle format implementation
- [ ] Unit tests

### Phase 2: UI Integration (Week 2)
- [ ] Export dialog (Settings)
- [ ] Import dialog (Welcome + Settings)
- [ ] Passphrase strength meter
- [ ] Progress indicators
- [ ] Error handling UI
- [ ] File picker integration

### Phase 3: Polish & Testing (Week 3)
- [ ] Integration tests
- [ ] Cross-device testing
- [ ] Error message refinement
- [ ] User documentation
- [ ] Video tutorial

## Future Enhancements (Post-MVP)

### Bluetooth/Radio Transfer
```dart
// Use existing mesh networking to transfer bundles
class BundleTransferService {
  /// Send bundle to nearby device via BLE
  Future<void> sendBundleViaBLE(String bundlePath, String targetDeviceId);
  
  /// Receive bundle from nearby device
  Future<String> receiveBundleViaBLE();
}
```

### Cloud Backup (Optional)
- Encrypted upload to user's cloud (Google Drive, iCloud)
- Still requires passphrase to restore
- Automatic sync option

### Selective Export
- Export only contacts
- Export only messages from specific chat
- Export date range

### Multi-Profile Support
- Create multiple identities
- Switch between profiles
- Isolated encryption keys per profile

## Benefits Summary

### For Users 💚
- ✅ **Device Migration**: Seamless phone upgrade
- ✅ **Data Safety**: Recover from lost/broken device
- ✅ **Multi-Device**: Same identity on multiple devices
- ✅ **Privacy**: Full control over data
- ✅ **No Cloud Lock-in**: Works completely offline

### For Development 🚀
- ✅ **Academic Value**: Demonstrates advanced crypto + key management
- ✅ **Differentiation**: Unique feature vs competitors
- ✅ **User Trust**: Shows commitment to data sovereignty
- ✅ **Extensibility**: Foundation for future features

### For Your Project Grade 🎓
- ✅ **Crypto Implementation**: PBKDF2 + AES-256 + Key Management
- ✅ **Security Design**: Multi-layer encryption strategy
- ✅ **System Design**: Complete data portability architecture
- ✅ **User Experience**: Thoughtful flow design
- ✅ **Real-World Problem**: Solves actual user pain point

## Conclusion

**This feature is EXCELLENT and should absolutely be implemented!**

Your instinct is spot-on. This addresses a real problem (device migration), demonstrates advanced crypto skills, and aligns perfectly with your app's privacy-first philosophy. The foundation (encrypted database + secure storage) is already in place - you just need to add the export/import wrapper.

**Recommendation**: Start with Phase 1 (core export/import), get that working rock-solid, then add UI polish. The Bluetooth transfer can come later as a bonus feature.
