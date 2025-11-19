// Preferences repository for managing app settings in SQLite
// Stores theme preference, notification settings, privacy settings, etc.

import 'package:logging/logging.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../../core/interfaces/i_preferences_repository.dart';
import '../database/database_helper.dart';

/// App preference keys
class PreferenceKeys {
  static const String themeMode = 'theme_mode'; // 'system', 'light', 'dark'
  static const String notificationsEnabled = 'notifications_enabled';
  static const String backgroundNotifications =
      'background_notifications'; // Android only
  static const String soundEnabled = 'sound_enabled';
  static const String vibrationEnabled = 'vibration_enabled';
  static const String showReadReceipts = 'show_read_receipts';
  static const String autoArchiveOldChats = 'auto_archive_old_chats';
  static const String archiveAfterDays = 'archive_after_days';
  static const String fontSize = 'font_size'; // 'small', 'medium', 'large'
  static const String showOnlineStatus = 'show_online_status';
  static const String allowNewContacts = 'allow_new_contacts';
  static const String dataBackupEnabled = 'data_backup_enabled';
  static const String lastBackupTime = 'last_backup_time';
  static const String autoConnectKnownContacts =
      'auto_connect_known_contacts'; // 🆕 Auto-connect to known contacts
}

/// Default preference values
class PreferenceDefaults {
  static const String themeMode = 'system';
  static const bool notificationsEnabled = true;
  static const bool backgroundNotifications =
      true; // Android only - enable system notifications
  static const bool soundEnabled = true;
  static const bool vibrationEnabled = true;
  static const bool showReadReceipts = true;
  static const bool autoArchiveOldChats = false;
  static const int archiveAfterDays = 90;
  static const String fontSize = 'medium';
  static const bool showOnlineStatus = true;
  static const bool allowNewContacts = true;
  static const bool dataBackupEnabled = false;
  static const int lastBackupTime = 0;
  static const bool autoConnectKnownContacts =
      false; // 🆕 Default: OFF for battery conservation
}

/// Value types for type-safe storage
enum PreferenceValueType { string, boolean, integer, double }

class PreferencesRepository implements IPreferencesRepository {
  static final _logger = Logger('PreferencesRepository');

  /// Get string preference
  Future<String> getString(String key, {String? defaultValue}) async {
    try {
      final db = await DatabaseHelper.database;
      final result = await db.query(
        'app_preferences',
        where: 'key = ? AND value_type = ?',
        whereArgs: [key, PreferenceValueType.string.name],
        limit: 1,
      );

      if (result.isEmpty) {
        return defaultValue ?? _getDefaultValue(key) as String;
      }

      return result.first['value'] as String;
    } catch (e) {
      _logger.warning('Failed to get string preference $key: $e');
      return defaultValue ?? _getDefaultValue(key) as String;
    }
  }

  /// Set string preference
  Future<void> setString(String key, String value) async {
    await _setValue(key, value, PreferenceValueType.string);
  }

  /// Get boolean preference
  Future<bool> getBool(String key, {bool? defaultValue}) async {
    try {
      final db = await DatabaseHelper.database;
      final result = await db.query(
        'app_preferences',
        where: 'key = ? AND value_type = ?',
        whereArgs: [key, PreferenceValueType.boolean.name],
        limit: 1,
      );

      if (result.isEmpty) {
        return defaultValue ?? _getDefaultValue(key) as bool;
      }

      final value = result.first['value'];

      // Handle type mismatch gracefully
      if (value is bool) {
        return value;
      } else if (value is String) {
        return value.toLowerCase() == 'true';
      } else {
        _logger.warning(
          'Unexpected value type for $key: ${value.runtimeType}, using default',
        );
        return defaultValue ?? _getDefaultValue(key) as bool;
      }
    } catch (e) {
      _logger.warning('Failed to get bool preference $key: $e');
      return defaultValue ?? _getDefaultValue(key) as bool;
    }
  }

  /// Set boolean preference
  Future<void> setBool(String key, bool value) async {
    await _setValue(key, value.toString(), PreferenceValueType.boolean);
  }

  /// Get integer preference
  Future<int> getInt(String key, {int? defaultValue}) async {
    try {
      final db = await DatabaseHelper.database;
      final result = await db.query(
        'app_preferences',
        where: 'key = ? AND value_type = ?',
        whereArgs: [key, PreferenceValueType.integer.name],
        limit: 1,
      );

      if (result.isEmpty) {
        return defaultValue ?? _getDefaultValue(key) as int;
      }

      return int.parse(result.first['value'] as String);
    } catch (e) {
      _logger.warning('Failed to get int preference $key: $e');
      return defaultValue ?? _getDefaultValue(key) as int;
    }
  }

  /// Set integer preference
  Future<void> setInt(String key, int value) async {
    await _setValue(key, value.toString(), PreferenceValueType.integer);
  }

  /// Get double preference
  Future<double> getDouble(String key, {double? defaultValue}) async {
    try {
      final db = await DatabaseHelper.database;
      final result = await db.query(
        'app_preferences',
        where: 'key = ? AND value_type = ?',
        whereArgs: [key, PreferenceValueType.double.name],
        limit: 1,
      );

      if (result.isEmpty) {
        return defaultValue ?? 0.0;
      }

      return double.parse(result.first['value'] as String);
    } catch (e) {
      _logger.warning('Failed to get double preference $key: $e');
      return defaultValue ?? 0.0;
    }
  }

  /// Set double preference
  Future<void> setDouble(String key, double value) async {
    await _setValue(key, value.toString(), PreferenceValueType.double);
  }

  /// Internal method to set a value with upsert
  Future<void> _setValue(
    String key,
    String value,
    PreferenceValueType type,
  ) async {
    try {
      final db = await DatabaseHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.insert('app_preferences', {
        'key': key,
        'value': value,
        'value_type': type.name,
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      _logger.fine('Set preference $key = $value (${type.name})');
    } catch (e) {
      _logger.severe('Failed to set preference $key: $e');
      rethrow;
    }
  }

  /// Get default value for a key
  dynamic _getDefaultValue(String key) {
    switch (key) {
      case PreferenceKeys.themeMode:
        return PreferenceDefaults.themeMode;
      case PreferenceKeys.notificationsEnabled:
        return PreferenceDefaults.notificationsEnabled;
      case PreferenceKeys.backgroundNotifications:
        return PreferenceDefaults.backgroundNotifications;
      case PreferenceKeys.soundEnabled:
        return PreferenceDefaults.soundEnabled;
      case PreferenceKeys.vibrationEnabled:
        return PreferenceDefaults.vibrationEnabled;
      case PreferenceKeys.showReadReceipts:
        return PreferenceDefaults.showReadReceipts;
      case PreferenceKeys.autoArchiveOldChats:
        return PreferenceDefaults.autoArchiveOldChats;
      case PreferenceKeys.archiveAfterDays:
        return PreferenceDefaults.archiveAfterDays;
      case PreferenceKeys.fontSize:
        return PreferenceDefaults.fontSize;
      case PreferenceKeys.showOnlineStatus:
        return PreferenceDefaults.showOnlineStatus;
      case PreferenceKeys.allowNewContacts:
        return PreferenceDefaults.allowNewContacts;
      case PreferenceKeys.dataBackupEnabled:
        return PreferenceDefaults.dataBackupEnabled;
      case PreferenceKeys.lastBackupTime:
        return PreferenceDefaults.lastBackupTime;
      case PreferenceKeys
          .autoConnectKnownContacts: // 🆕 Ensure default exists for auto-connect
        return PreferenceDefaults.autoConnectKnownContacts;
      default:
        return '';
    }
  }

  /// Delete a preference
  Future<void> delete(String key) async {
    try {
      final db = await DatabaseHelper.database;
      await db.delete('app_preferences', where: 'key = ?', whereArgs: [key]);
      _logger.fine('Deleted preference $key');
    } catch (e) {
      _logger.warning('Failed to delete preference $key: $e');
    }
  }

  /// Clear all preferences (reset to defaults)
  Future<void> clearAll() async {
    try {
      final db = await DatabaseHelper.database;
      await db.delete('app_preferences');
      _logger.info('Cleared all preferences');
    } catch (e) {
      _logger.severe('Failed to clear preferences: $e');
      rethrow;
    }
  }

  /// Get all preferences (for debugging/export)
  Future<Map<String, dynamic>> getAll() async {
    try {
      final db = await DatabaseHelper.database;
      final result = await db.query('app_preferences');

      final Map<String, dynamic> preferences = {};
      for (final row in result) {
        preferences[row['key'] as String] = row['value'];
      }

      return preferences;
    } catch (e) {
      _logger.severe('Failed to get all preferences: $e');
      return {};
    }
  }
}
