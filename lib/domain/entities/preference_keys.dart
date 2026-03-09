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
  static const String killSwitchHealthChecks = 'kill_switch_health_checks';
  static const String killSwitchQueueSync = 'kill_switch_queue_sync';
  static const String killSwitchAutoConnect = 'kill_switch_auto_connect';
  static const String killSwitchDualRole = 'kill_switch_dual_role';
  static const String killSwitchDiscoveryScheduler =
      'kill_switch_discovery_scheduler';

  // Rate limiting (user-facing)
  static const String rateLimitUnknownPerHour =
      'rate_limit_unknown_per_hour'; // messages from strangers
  static const String rateLimitKnownPerHour =
      'rate_limit_known_per_hour'; // messages from known contacts
  static const String rateLimitFriendPerHour =
      'rate_limit_friend_per_hour'; // messages from verified friends

  // Proof-of-work gas fees (free message thresholds per trust tier, daily)
  static const String powFreeThresholdUnknown =
      'pow_free_threshold_unknown'; // daily free messages for strangers
  static const String powFreeThresholdKnown =
      'pow_free_threshold_known'; // daily free messages for known contacts
  static const String powFreeThresholdFriend =
      'pow_free_threshold_friend'; // daily free messages for verified friends
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
  static const bool killSwitchHealthChecks = false;
  static const bool killSwitchQueueSync = false;
  static const bool killSwitchAutoConnect = false;
  static const bool killSwitchDualRole = false;
  static const bool killSwitchDiscoveryScheduler = false;

  // Rate limiting defaults
  static const int rateLimitUnknownPerHour = 5; // conservative for strangers
  static const int rateLimitKnownPerHour = 25; // relaxed for known contacts
  static const int rateLimitFriendPerHour = 100; // generous for verified friends

  // Proof-of-work gas fee defaults (daily free message thresholds)
  static const int powFreeThresholdUnknown = 50; // strangers: 50 free/day
  static const int powFreeThresholdKnown = 100; // known contacts: 100 free/day
  static const int powFreeThresholdFriend = 200; // verified friends: 200 free/day
}
