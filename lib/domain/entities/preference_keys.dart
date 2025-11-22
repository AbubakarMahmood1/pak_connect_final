/// Shared preference key definitions accessible to domain and core layers.
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

/// Default values for [PreferenceKeys].
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
