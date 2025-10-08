# Export/Import Quick Reference

## Core Functionality ✅ COMPLETE

### Services (lib/data/services/export_import/)
- `export_bundle.dart` - Data models
- `encryption_utils.dart` - PBKDF2 + AES-256-GCM
- `export_service.dart` - Creates encrypted backups
- `import_service.dart` - Restores from backups

### Tests (test/)
- `export_import_test.dart` - 24 passing tests

## Quick API Reference

### Export Data
```dart
final result = await ExportService.createExport(
  userPassphrase: 'StrongPassword123!',
);
// Returns: ExportResult with bundlePath or error
```

### Import Data
```dart
final result = await ImportService.importBundle(
  bundlePath: '/path/to/backup.pakconnect',
  userPassphrase: 'StrongPassword123!',
);
// Returns: ImportResult with recordsRestored or error
```

### Validate Before Import
```dart
final info = await ImportService.validateBundle(
  bundlePath: '/path/to/backup.pakconnect',
  userPassphrase: 'StrongPassword123!',
);
// Returns: Map with 'valid' bool and bundle metadata
```

### Validate Passphrase Strength
```dart
final validation = EncryptionUtils.validatePassphrase('test123');
print(validation.isValid); // true/false
print(validation.strength); // 0.0 - 1.0
print(validation.warnings); // List<String>
```

## Security Summary

### Encryption
- **Algorithm**: AES-256-GCM
- **Key Derivation**: PBKDF2-HMAC-SHA256 (100k iterations)
- **Integrity**: SHA-256 checksums
- **Passphrase**: Minimum 12 chars, letters + numbers required

### Protection
✅ Export useless without passphrase
✅ Tamper detection via checksums
✅ Corruption detection
✅ Brute-force resistance (PBKDF2)
✅ No key reuse (unique salt per export)

## Next Steps (Phase 2 - UI)

### 1. Export Dialog (Settings Screen)
```dart
// Add to SettingsScreen
ElevatedButton(
  child: Text('Export All Data'),
  onPressed: () => showDialog(
    context: context,
    builder: (context) => ExportDialog(),
  ),
)
```

### 2. Import Option (Welcome Screen)
```dart
// Add to WelcomeScreen
OutlinedButton(
  child: Text('Import Backup'),
  onPressed: () => showDialog(
    context: context,
    builder: (context) => ImportDialog(),
  ),
)
```

### 3. UI Components to Create
- `ExportDialog` - Passphrase entry + progress
- `ImportDialog` - File picker + passphrase entry
- `PassphraseStrengthIndicator` - Visual strength meter
- `ExportHistoryList` - List of available exports

## File Locations

### Core Code
```
lib/data/services/export_import/
├── export_bundle.dart
├── encryption_utils.dart
├── export_service.dart
└── import_service.dart
```

### Future UI Code
```
lib/presentation/widgets/
├── export_dialog.dart
├── import_dialog.dart
└── passphrase_strength_indicator.dart

lib/presentation/screens/
├── welcome_import_screen.dart (modify existing)
└── settings_screen.dart (modify existing)
```

## Testing Commands

```bash
# Run export/import tests only
flutter test test/export_import_test.dart

# Run all tests
flutter test

# Run with verbose output
flutter test --reporter expanded
```

## Common Issues & Solutions

### Issue: "Weak passphrase" error
**Solution**: Use minimum 12 characters with letters AND numbers
```dart
// ❌ Bad
'password123'  // Too short (11 chars)
'mypassword'   // No numbers
'123456789012' // No letters

// ✅ Good  
'MyPassword123'
'SecurePass2024'
'ImportantData99'
```

### Issue: "Invalid passphrase" on import
**Solution**: Ensure exact same passphrase used for export
- Passphrases are case-sensitive
- Trailing spaces matter
- Consider showing/hiding passphrase toggle

### Issue: "Bundle integrity check failed"
**Solution**: File may be corrupted or tampered
- Re-download or re-export
- Verify file wasn't edited
- Check file wasn't truncated

### Issue: Import clears existing data
**Solution**: This is by design (documented behavior)
- Always warn users before import
- Consider creating backup before import
- Provide "cancel" option with confirmation

## Production Checklist

Before releasing to users:

- [ ] Add UI for export (Settings screen)
- [ ] Add UI for import (Welcome screen)
- [ ] Show passphrase strength meter
- [ ] Add export file sharing options
- [ ] Implement import file picker
- [ ] Add progress indicators
- [ ] Show clear warnings about data loss
- [ ] Test on real devices
- [ ] Test with large databases (10k+ messages)
- [ ] Document for users (help screen)
- [ ] Add error handling UI
- [ ] Consider auto-backup scheduling

## Example User Flow

### Export Flow
1. User opens Settings
2. Taps "Export All Data"
3. Enters strong passphrase (with strength meter)
4. Confirms passphrase
5. Sees progress indicator
6. Gets success message with file location
7. Can share via Bluetooth/Files

### Import Flow  
1. User opens app for first time (or chooses Import)
2. Selects "Import Backup"
3. Picks `.pakconnect` file
4. Enters passphrase
5. Sees validation preview (username, date, size)
6. Confirms import (warns about data loss)
7. Sees progress indicator
8. App restores all data
9. User continues to permission setup

## Performance Notes

- Export: ~2-3 seconds for typical database
- Import: ~3-4 seconds (includes restore + verification)
- PBKDF2: ~500ms (intentionally slow for security)
- Encryption: <100ms for typical data

## Future Enhancements

### Short-term
- Selective export (contacts only, messages only)
- Multiple export profiles
- Scheduled auto-exports

### Long-term  
- Cloud backup integration (still encrypted)
- Bluetooth transfer using mesh network
- Export compression (reduce file size)
- Incremental backups (only changes)

---

**Status**: Core implementation complete ✅  
**Next**: UI integration (Phase 2)  
**Blocker**: None - ready to proceed
