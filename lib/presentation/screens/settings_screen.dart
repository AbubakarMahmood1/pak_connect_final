// Settings screen for app preferences and configuration
// Manages theme, notifications, privacy, and data settings

import 'package:flutter/foundation.dart'; // For kDebugMode
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For rootBundle
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../providers/theme_provider.dart';
import '../providers/ble_providers.dart';
import '../../data/repositories/preferences_repository.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/chats_repository.dart';
import '../../data/repositories/user_preferences.dart';
import '../../data/database/database_helper.dart';
import '../widgets/export_dialog.dart';
import '../widgets/import_dialog.dart';
import 'permission_screen.dart';
import '../../domain/services/auto_archive_scheduler.dart';
import '../../domain/services/notification_service.dart';
import '../../domain/services/notification_handler_factory.dart';
import '../../core/services/simple_crypto.dart';
import '../../core/security/message_security.dart';
import '../../core/security/hint_cache_manager.dart';
import '../../core/security/ephemeral_key_manager.dart';
import '../../core/app_core.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final PreferencesRepository _preferencesRepository = PreferencesRepository();
  final ContactRepository _contactRepository = ContactRepository();

  // Notification settings
  bool _notificationsEnabled = PreferenceDefaults.notificationsEnabled;
  bool _backgroundNotifications = PreferenceDefaults.backgroundNotifications;
  bool _soundEnabled = PreferenceDefaults.soundEnabled;
  bool _vibrationEnabled = PreferenceDefaults.vibrationEnabled;

  // Privacy settings
  bool _showReadReceipts = PreferenceDefaults.showReadReceipts;
  bool _showOnlineStatus = PreferenceDefaults.showOnlineStatus;
  bool _allowNewContacts = PreferenceDefaults.allowNewContacts;
  bool _hintBroadcastEnabled = true; // Spy mode toggle (default: hints enabled)

  // Data settings
  bool _autoArchiveOldChats = PreferenceDefaults.autoArchiveOldChats;
  int _archiveAfterDays = PreferenceDefaults.archiveAfterDays;

  // Developer tools statistics (debug only)
  int _contactCount = 0;
  int _chatCount = 0;
  int _messageCount = 0;

  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    setState(() => _isLoading = true);

    // Load notification settings
    _notificationsEnabled = await _preferencesRepository.getBool(
      PreferenceKeys.notificationsEnabled,
    );
    _backgroundNotifications = await _preferencesRepository.getBool(
      PreferenceKeys.backgroundNotifications,
    );
    _soundEnabled = await _preferencesRepository.getBool(
      PreferenceKeys.soundEnabled,
    );
    _vibrationEnabled = await _preferencesRepository.getBool(
      PreferenceKeys.vibrationEnabled,
    );

    // Load privacy settings
    _showReadReceipts = await _preferencesRepository.getBool(
      PreferenceKeys.showReadReceipts,
    );
    _showOnlineStatus = await _preferencesRepository.getBool(
      PreferenceKeys.showOnlineStatus,
    );
    _allowNewContacts = await _preferencesRepository.getBool(
      PreferenceKeys.allowNewContacts,
    );

    // Load spy mode setting
    final userPrefs = UserPreferences();
    _hintBroadcastEnabled = await userPrefs.getHintBroadcastEnabled();

    // Load data settings
    _autoArchiveOldChats = await _preferencesRepository.getBool(
      PreferenceKeys.autoArchiveOldChats,
    );
    _archiveAfterDays = await _preferencesRepository.getInt(
      PreferenceKeys.archiveAfterDays,
    );

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  /// Swap notification handler between foreground and background
  /// Android only - swaps to BackgroundNotificationHandlerImpl when enabled
  Future<void> _swapNotificationHandler(bool enableBackground) async {
    try {
      final handler = enableBackground
          ? NotificationHandlerFactory.createBackgroundHandler()
          : NotificationHandlerFactory.createDefault();
      
      await NotificationService.swapHandler(handler);
      
      // No snackbar - toggle switch provides visual feedback
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update notification handler: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      appBar: AppBar(title: Text('Settings')),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // Appearance section
                _buildSectionHeader(theme, 'Appearance'),
                _buildThemeSelector(theme, themeMode),

                Divider(height: 24),

                // Notifications section
                _buildSectionHeader(theme, 'Notifications'),
                _buildNotificationSettings(theme),

                Divider(height: 24),

                // Privacy section
                _buildSectionHeader(theme, 'Privacy'),
                _buildPrivacySettings(theme),

                Divider(height: 24),

                // Data & Storage section
                _buildSectionHeader(theme, 'Data & Storage'),
                _buildDataSettings(theme),

                Divider(height: 24),

                // About section
                _buildSectionHeader(theme, 'About'),
                _buildAboutSettings(theme),

                // Developer Tools (Debug builds only)
                if (kDebugMode) ...[
                  Divider(height: 24),
                  _buildSectionHeader(theme, '🛠️ Developer Tools'),
                  _buildDeveloperTools(theme),
                ],

                SizedBox(height: 32),
              ],
            ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildThemeSelector(ThemeData theme, ThemeMode currentMode) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.palette, size: 20, color: theme.colorScheme.primary),
                SizedBox(width: 12),
                Text(
                  'Theme',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildThemeOption(theme, ThemeMode.light, currentMode),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: _buildThemeOption(theme, ThemeMode.dark, currentMode),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: _buildThemeOption(
                    theme,
                    ThemeMode.system,
                    currentMode,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThemeOption(
    ThemeData theme,
    ThemeMode mode,
    ThemeMode currentMode,
  ) {
    final isSelected = mode == currentMode;

    return InkWell(
      onTap: () => ref.read(themeModeProvider.notifier).setThemeMode(mode),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? theme.colorScheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          children: [
            Icon(
              getThemeModeIcon(mode),
              color: isSelected
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurfaceVariant,
            ),
            SizedBox(height: 4),
            Text(
              getThemeModeName(mode),
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: isSelected
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotificationSettings(ThemeData theme) {
    // Check if background notifications are supported on this platform
    final supportsBackgroundNotifications = 
        NotificationHandlerFactory.isBackgroundNotificationSupported();
    
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          SwitchListTile(
            secondary: Icon(Icons.notifications),
            title: Text('Enable Notifications'),
            subtitle: Text('Receive notifications for new messages'),
            value: _notificationsEnabled,
            onChanged: (value) async {
              setState(() => _notificationsEnabled = value);
              await _preferencesRepository.setBool(
                PreferenceKeys.notificationsEnabled,
                value,
              );
            },
          ),
          if (_notificationsEnabled) ...[
            // Background notifications toggle (Android only)
            if (supportsBackgroundNotifications) ...[
              Divider(height: 1),
              SwitchListTile(
                secondary: Icon(Icons.phonelink),
                title: Text('System Notifications'),
                subtitle: Text(
                  'Show notifications even when app is closed (Android)',
                ),
                value: _backgroundNotifications,
                onChanged: (value) async {
                  setState(() => _backgroundNotifications = value);
                  await _preferencesRepository.setBool(
                    PreferenceKeys.backgroundNotifications,
                    value,
                  );
                  
                  // Swap notification handler based on setting
                  await _swapNotificationHandler(value);
                },
              ),
            ],
            Divider(height: 1),
            SwitchListTile(
              secondary: Icon(Icons.volume_up),
              title: Text('Sound'),
              subtitle: Text('Play sound for new messages'),
              value: _soundEnabled,
              onChanged: (value) async {
                setState(() => _soundEnabled = value);
                await _preferencesRepository.setBool(
                  PreferenceKeys.soundEnabled,
                  value,
                );
              },
            ),
            Divider(height: 1),
            SwitchListTile(
              secondary: Icon(Icons.vibration),
              title: Text('Vibration'),
              subtitle: Text('Vibrate for new messages'),
              value: _vibrationEnabled,
              onChanged: (value) async {
                setState(() => _vibrationEnabled = value);
                await _preferencesRepository.setBool(
                  PreferenceKeys.vibrationEnabled,
                  value,
                );
              },
            ),
            Divider(height: 1),
            ListTile(
              leading: Icon(Icons.notifications_active),
              title: Text('Test Notification'),
              subtitle: Text('Test current notification settings'),
              trailing: Icon(Icons.chevron_right),
              onTap: () => _testNotification(),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _testNotification() async {
    try {
      await NotificationService.showTestNotification(
        playSound: _soundEnabled,
        vibrate: _vibrationEnabled,
      );
      
      // No snackbar - the notification itself is the feedback
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to test notification: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Widget _buildPrivacySettings(ThemeData theme) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          // ========== SPY MODE TOGGLE ==========
          SwitchListTile(
            secondary: Icon(_hintBroadcastEnabled ? Icons.wifi_tethering : Icons.visibility_off),
            title: Text('Broadcast Hints'),
            subtitle: Text(
              _hintBroadcastEnabled
                  ? 'Friends can see when you\'re online'
                  : '🕵️ Spy mode: Chat anonymously with friends',
              style: TextStyle(
                color: _hintBroadcastEnabled
                    ? theme.textTheme.bodySmall?.color
                    : theme.colorScheme.primary,
                fontWeight: _hintBroadcastEnabled ? FontWeight.normal : FontWeight.w600,
              ),
            ),
            value: _hintBroadcastEnabled,
            onChanged: (value) async {
              setState(() => _hintBroadcastEnabled = value);
              final userPrefs = UserPreferences();
              await userPrefs.setHintBroadcastEnabled(value);

              // Show feedback
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      value
                          ? 'Spy mode disabled - friends will know it\'s you'
                          : '🕵️ Spy mode enabled - chat anonymously',
                    ),
                    duration: Duration(seconds: 3),
                  ),
                );
              }
            },
          ),
          Divider(height: 1),
          SwitchListTile(
            secondary: Icon(Icons.check_circle),
            title: Text('Read Receipts'),
            subtitle: Text('Let others know when you\'ve read their messages'),
            value: _showReadReceipts,
            onChanged: (value) async {
              setState(() => _showReadReceipts = value);
              await _preferencesRepository.setBool(
                PreferenceKeys.showReadReceipts,
                value,
              );
            },
          ),
          Divider(height: 1),
          SwitchListTile(
            secondary: Icon(Icons.circle),
            title: Text('Online Status'),
            subtitle: Text('Show when you\'re online'),
            value: _showOnlineStatus,
            onChanged: (value) async {
              setState(() => _showOnlineStatus = value);
              await _preferencesRepository.setBool(
                PreferenceKeys.showOnlineStatus,
                value,
              );

              // Only refresh advertising if in peripheral mode
              // Pass the value directly to avoid stale cache issues
              final bleService = ref.read(bleServiceProvider);
              if (bleService.isPeripheralMode) {
                await bleService.refreshAdvertising(showOnlineStatus: value);
              }
            },
          ),
          Divider(height: 1),
          SwitchListTile(
            secondary: Icon(Icons.person_add),
            title: Text('Allow New Contacts'),
            subtitle: Text('Anyone can add you as a contact'),
            value: _allowNewContacts,
            onChanged: (value) async {
              setState(() => _allowNewContacts = value);
              await _preferencesRepository.setBool(
                PreferenceKeys.allowNewContacts,
                value,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDataSettings(ThemeData theme) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          SwitchListTile(
            secondary: Icon(Icons.auto_delete),
            title: Text('Auto-Archive Old Chats'),
            subtitle: Text('Automatically archive inactive chats'),
            value: _autoArchiveOldChats,
            onChanged: (value) async {
              setState(() => _autoArchiveOldChats = value);
              await _preferencesRepository.setBool(
                PreferenceKeys.autoArchiveOldChats,
                value,
              );
              // Restart scheduler to apply changes
              await AutoArchiveScheduler.restart();
            },
          ),
          if (_autoArchiveOldChats) ...[
            Divider(height: 1),
            ListTile(
              leading: Icon(Icons.calendar_today),
              title: Text('Archive After'),
              subtitle: Text('$_archiveAfterDays days of inactivity'),
              trailing: Icon(Icons.chevron_right),
              onTap: () => _showArchiveDaysDialog(),
            ),
            Divider(height: 1),
            ListTile(
              leading: Icon(Icons.sync),
              title: Text('Check Inactive Chats Now'),
              subtitle: Text('Manually trigger auto-archive check'),
              trailing: Icon(Icons.chevron_right),
              onTap: () => _manualAutoArchiveCheck(),
            ),
          ],
          Divider(height: 1),
          ListTile(
            leading: Icon(Icons.download_rounded),
            title: Text('Export All Data'),
            subtitle: Text('Create encrypted backup of all data'),
            trailing: Icon(Icons.chevron_right),
            onTap: () => _showExportDialog(),
          ),
          Divider(height: 1),
          ListTile(
            leading: Icon(Icons.upload_file_rounded),
            title: Text('Import Backup'),
            subtitle: Text('Restore data from backup file'),
            trailing: Icon(Icons.chevron_right),
            onTap: () => _showImportDialog(),
          ),
          Divider(height: 1),
          ListTile(
            leading: Icon(Icons.storage),
            title: Text('Storage Usage'),
            subtitle: Text('View app storage usage'),
            trailing: Icon(Icons.chevron_right),
            onTap: () => _showStorageInfo(),
          ),
          Divider(height: 1),
          ListTile(
            leading: Icon(Icons.delete_forever, color: theme.colorScheme.error),
            title: Text(
              'Clear All Data',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            subtitle: Text('Delete all messages, chats, and contacts'),
            trailing: Icon(Icons.chevron_right, color: theme.colorScheme.error),
            onTap: () => _confirmClearData(),
          ),
        ],
      ),
    );
  }

  Widget _buildAboutSettings(ThemeData theme) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          ListTile(
            leading: Icon(Icons.info),
            title: Text('About PakConnect'),
            subtitle: Text('Version 1.0.0'),
            trailing: Icon(Icons.chevron_right),
            onTap: () => _showAbout(),
          ),
          Divider(height: 1),
          ListTile(
            leading: Icon(Icons.help),
            title: Text('Help & Support'),
            subtitle: Text('Get help using the app'),
            trailing: Icon(Icons.chevron_right),
            onTap: () => _showHelp(),
          ),
          Divider(height: 1),
          ListTile(
            leading: Icon(Icons.privacy_tip),
            title: Text('Privacy Policy'),
            subtitle: Text('How we handle your data'),
            trailing: Icon(Icons.chevron_right),
            onTap: () => _showPrivacyPolicy(),
          ),
        ],
      ),
    );
  }

  void _showArchiveDaysDialog() async {
    int? selectedValue = _archiveAfterDays;
    final theme = Theme.of(context);

    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Auto-Archive After'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Archive chats that have been inactive for:'),
              SizedBox(height: 16),
              // Use SegmentedButton for modern, future-proof UI
              SegmentedButton<int>(
                segments: [30, 60, 90, 180, 365]
                    .map(
                      (days) =>
                          ButtonSegment<int>(value: days, label: Text('$days')),
                    )
                    .toList(),
                selected: selectedValue != null
                    ? <int>{selectedValue!}
                    : <int>{},
                onSelectionChanged: (Set<int> selection) {
                  if (selection.isNotEmpty) {
                    setState(() => selectedValue = selection.first);
                  }
                },
                showSelectedIcon: false,
              ),
              SizedBox(height: 8),
              Text(
                'days of inactivity',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selectedValue),
              child: Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (result != null && result != _archiveAfterDays) {
      setState(() => _archiveAfterDays = result);
      await _preferencesRepository.setInt(
        PreferenceKeys.archiveAfterDays,
        result,
      );
      // Restart scheduler to apply new threshold
      await AutoArchiveScheduler.restart();
    }
  }

  Future<void> _manualAutoArchiveCheck() async {
    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Checking for inactive chats...'),
          ],
        ),
      ),
    );

    try {
      // Trigger manual check
      final archivedCount = await AutoArchiveScheduler.checkNow();

      // Close loading dialog
      if (mounted) Navigator.pop(context);

      // Show result
      if (mounted) {
        final message = archivedCount > 0
            ? 'Auto-archived $archivedCount inactive chat${archivedCount == 1 ? '' : 's'}'
            : 'No inactive chats found';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: archivedCount > 0 ? Colors.green : null,
            action: archivedCount > 0
                ? SnackBarAction(
                    label: 'View',
                    textColor: Colors.white,
                    onPressed: () {
                      // Navigate to archive screen
                      // (Will be implemented with archive screen integration)
                    },
                  )
                : null,
          ),
        );

        // Reload chats if any were archived
        if (archivedCount > 0) {
          // Trigger UI refresh (if chats screen is visible)
          setState(() {});
        }
      }
    } catch (e) {
      // Close loading dialog
      if (mounted) Navigator.pop(context);

      // Show error
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to check inactive chats: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  void _showStorageInfo() async {
    // Show loading dialog first
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(child: CircularProgressIndicator()),
    );

    try {
      // Get actual database size
      final sizeInfo = await DatabaseHelper.getDatabaseSize();
      final sizeMB = sizeInfo['size_mb'] ?? '0.00';
      final sizeKB = sizeInfo['size_kb'] ?? '0.00';
      final exists = sizeInfo['exists'] ?? false;

      // Close loading dialog
      if (mounted) Navigator.pop(context);

      // Show storage info dialog
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Storage Usage'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (exists) ...[
                  Text('Database: $sizeMB MB'),
                  SizedBox(height: 8),
                  Text('($sizeKB KB)'),
                  SizedBox(height: 16),
                  Text(
                    'Includes: messages, chats, contacts, archives',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ] else ...[
                  Text('No database found'),
                  SizedBox(height: 8),
                  Text('Storage: 0 MB'),
                ],
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      // Close loading dialog
      if (mounted) Navigator.pop(context);

      // Show error
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to calculate storage: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  void _confirmClearData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning, color: Theme.of(context).colorScheme.error),
            SizedBox(width: 8),
            Text('Clear All Data?'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This will permanently delete:'),
            SizedBox(height: 12),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('• All messages', style: TextStyle(fontSize: 14)),
                  Text('• All chats', style: TextStyle(fontSize: 14)),
                  Text('• All contacts', style: TextStyle(fontSize: 14)),
                  Text('• Archived data', style: TextStyle(fontSize: 14)),
                ],
              ),
            ),
            SizedBox(height: 12),
            Text(
              'This action cannot be undone!',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        // Show loading indicator
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(width: 16),
                  Text('Clearing all data...'),
                ],
              ),
              duration: Duration(seconds: 30),
            ),
          );
        }

        // Get database instance
        final db = await DatabaseHelper.database;

        // Clear all tables in the correct order (respecting foreign key constraints)
        await db.transaction((txn) async {
          // Delete data in reverse dependency order
          await txn.delete('archived_messages');
          await txn.delete('archived_chats');
          await txn.delete('deleted_message_ids');
          await txn.delete('queue_sync_state');
          await txn.delete('offline_message_queue');
          await txn.delete('messages');
          await txn.delete('chats');
          await txn.delete('contact_last_seen');
          await txn.delete('device_mappings');
          await txn.delete('contacts');
          await txn.delete('migration_metadata');
          await txn.delete('app_preferences');
        });

        // Clear secure storage (shared secrets, keys)
        final contactRepo = ContactRepository();
        final allContacts = await contactRepo.getAllContacts();
        for (final contact in allContacts.values) {
          await contactRepo.deleteContact(contact.publicKey);
        }

        // Clear preferences
        await _preferencesRepository.clearAll();

        // Show success message and navigate back to permission screen
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('All data cleared successfully'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 2),
            ),
          );

          // Wait a moment for user to see the success message
          await Future.delayed(Duration(seconds: 2));

          // Navigate back to permission screen
          if (mounted) {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (context) => const PermissionScreen()),
              (route) => false,
            );
          }
        }
      } catch (e) {
        // Show error message
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to clear data: $e'),
              backgroundColor: Theme.of(context).colorScheme.error,
              duration: Duration(seconds: 5),
            ),
          );
        }
      }
    }
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'PakConnect',
      applicationVersion: '1.0.0',
      applicationIcon: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.message,
          color: Theme.of(context).colorScheme.onPrimary,
          size: 24,
        ),
      ),
      children: [
        SizedBox(height: 16),
        Text(
          'Secure peer-to-peer messaging with mesh networking and end-to-end encryption.',
        ),
        SizedBox(height: 12),
        Text('Features:', style: TextStyle(fontWeight: FontWeight.w600)),
        Text('• Offline messaging via Bluetooth'),
        Text('• End-to-end encryption'),
        Text('• Mesh network relay'),
        Text('• No internet required'),
        Text('• No data collection'),
        SizedBox(height: 12),
        Text(
          'Your messages never leave your devices.',
          style: TextStyle(
            fontStyle: FontStyle.italic,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }

  void _showHelp() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Help & Support'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Getting Started',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 8),
              Text('1. Enable Bluetooth'),
              Text('2. Tap + to discover nearby devices'),
              Text('3. Exchange QR codes for secure contacts'),
              Text('4. Start chatting offline!'),
              SizedBox(height: 16),
              Text(
                'For more help, visit our documentation.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Got it'),
          ),
        ],
      ),
    );
  }

  void _showPrivacyPolicy() async {
    try {
      // Load markdown from assets
      final markdownContent = await rootBundle.loadString('assets/privacy_policy.md');
      
      if (!mounted) return;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.privacy_tip, color: Theme.of(context).colorScheme.primary),
              SizedBox(width: 8),
              Text('Privacy Policy'),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Markdown(
              data: markdownContent,
              selectable: true,
              shrinkWrap: true,
              styleSheet: MarkdownStyleSheet(
                h1: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
                h2: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
                h3: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                p: TextStyle(fontSize: 14, height: 1.5),
                listBullet: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      // Fallback to basic dialog if markdown fails
      if (!mounted) return;
      
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Privacy Policy'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your Privacy Matters',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 12),
                Text('PakConnect is designed with privacy at its core:'),
                SizedBox(height: 8),
                Text('• All messages are end-to-end encrypted'),
                Text('• No data is sent to external servers'),
                Text('• No tracking or analytics'),
                Text('• All data stays on your device'),
                Text('• Open-source encryption protocols'),
                SizedBox(height: 12),
                Text(
                  'We never have access to your messages or contacts.',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                SizedBox(height: 12),
                Text('Error loading full policy: $e'),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Close'),
            ),
          ],
        ),
      );
    }
  }

  void _showExportDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const ExportDialog(),
    );
  }

  void _showImportDialog() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const ImportDialog(),
    );

    // If import was successful, reload preferences
    if (result == true && mounted) {
      await _loadPreferences();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Data imported successfully! Please restart the app.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      }
    }
  }

  // ==================== DEVELOPER TOOLS (DEBUG ONLY) ====================

  Widget _buildDeveloperTools(ThemeData theme) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
      child: Column(
        children: [
          // Warning banner
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: theme.colorScheme.error,
                  size: 20,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Debug Build Only - These tools will not appear in release',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Test Notification
          ListTile(
            leading: Icon(Icons.notifications_active, color: Colors.orange),
            title: Text('Test Notification'),
            subtitle: Text('Test sound & vibration settings'),
            trailing: FilledButton.icon(
              onPressed: () async {
                await NotificationService.showTestNotification();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Test notification triggered')),
                  );
                }
              },
              icon: Icon(Icons.play_arrow, size: 16),
              label: Text('Test'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.orange,
              ),
            ),
          ),
          
          Divider(height: 1),

          // Test Auto-Archive
          ListTile(
            leading: Icon(Icons.archive, color: Colors.brown),
            title: Text('Check Inactive Chats'),
            subtitle: Text('Manually trigger auto-archive check'),
            trailing: FilledButton.icon(
              onPressed: () async {
                final count = await AutoArchiveScheduler.checkNow();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        count > 0 
                          ? '✅ Archived $count inactive chat${count == 1 ? '' : 's'}'
                          : 'No inactive chats found',
                      ),
                      duration: Duration(seconds: 3),
                    ),
                  );
                }
              },
              icon: Icon(Icons.play_arrow, size: 16),
              label: Text('Check'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.brown,
              ),
            ),
          ),

          Divider(height: 1),

          // Battery Status
          ListTile(
            leading: Icon(Icons.battery_charging_full, color: Colors.lightGreen),
            title: Text('Battery Optimizer'),
            subtitle: Text('View battery level and power mode'),
            trailing: FilledButton.icon(
              onPressed: _showBatteryInfo,
              icon: Icon(Icons.info, size: 16),
              label: Text('View'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.lightGreen,
              ),
            ),
          ),

          Divider(height: 1),

          // Database Info
          ListTile(
            leading: Icon(Icons.storage, color: Colors.teal),
            title: Text('Database Info'),
            subtitle: Text('View detailed database statistics'),
            trailing: FilledButton.icon(
              onPressed: _showDatabaseInfo,
              icon: Icon(Icons.info, size: 16),
              label: Text('View'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.teal,
              ),
            ),
          ),

          Divider(height: 1),

          // Clear Cache
          ListTile(
            leading: Icon(Icons.delete_sweep, color: Colors.deepOrange),
            title: Text('Clear Cache'),
            subtitle: Text('Clear temporary cached data'),
            trailing: FilledButton.icon(
              onPressed: _clearCache,
              icon: Icon(Icons.delete, size: 16),
              label: Text('Clear'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.deepOrange,
              ),
            ),
          ),

          Divider(height: 1),

          // Check Integrity
          ListTile(
            leading: Icon(Icons.verified, color: Colors.blue),
            title: Text('Database Integrity'),
            subtitle: Text('Verify database health'),
            trailing: FilledButton.icon(
              onPressed: _checkDatabaseIntegrity,
              icon: Icon(Icons.play_arrow, size: 16),
              label: Text('Check'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.blue,
              ),
            ),
          ),

          SizedBox(height: 8),
        ],
      ),
    );
  }

  void _showBatteryInfo() async {
    try {
      final batteryInfo = AppCore.instance.batteryOptimizer.getCurrentInfo();
      
      if (!mounted) return;

      // Battery icon based on level
      IconData batteryIcon;
      Color batteryColor;
      
      if (batteryInfo.isCharging) {
        batteryIcon = Icons.battery_charging_full;
        batteryColor = Colors.green;
      } else if (batteryInfo.level >= 80) {
        batteryIcon = Icons.battery_full;
        batteryColor = Colors.green;
      } else if (batteryInfo.level >= 50) {
        batteryIcon = Icons.battery_std;
        batteryColor = Colors.lightGreen;
      } else if (batteryInfo.level >= 30) {
        batteryIcon = Icons.battery_5_bar;
        batteryColor = Colors.orange;
      } else if (batteryInfo.level >= 15) {
        batteryIcon = Icons.battery_3_bar;
        batteryColor = Colors.deepOrange;
      } else {
        batteryIcon = Icons.battery_alert;
        batteryColor = Colors.red;
      }

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Row(
            children: [
              Icon(batteryIcon, color: batteryColor),
              SizedBox(width: 8),
              Text('Battery Optimizer'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Battery Level
              _buildInfoRow('Battery Level', '${batteryInfo.level}%'),
              Divider(),
              
              // Battery State
              _buildInfoRow(
                'State', 
                batteryInfo.isCharging ? '⚡ Charging' : '🔋 On Battery',
              ),
              Divider(),
              
              // Power Mode
              _buildInfoRow('Power Mode', batteryInfo.powerMode.name.toUpperCase()),
              SizedBox(height: 8),
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        batteryInfo.modeDescription,
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 12),
              
              // Last Update
              Text(
                'Last updated: ${_formatTime(batteryInfo.lastUpdate)}',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to load battery info: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
  
  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  void _showDatabaseInfo() async {
    try {
      // Load statistics
      _contactCount = await _contactRepository.getContactCount();
      final chatsRepo = ChatsRepository();
      _chatCount = await chatsRepo.getChatCount();
      _messageCount = await chatsRepo.getTotalMessageCount();

      final sizeInfo = await DatabaseHelper.getDatabaseSize();
      final sizeMB = sizeInfo['size_mb'] ?? '0.00';
      final sizeKB = sizeInfo['size_kb'] ?? '0.00';
      final sizeBytes = sizeInfo['size_bytes'] ?? 0;

      if (!mounted) return;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.storage, color: Theme.of(context).colorScheme.primary),
              SizedBox(width: 8),
              Text('Database Info'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInfoRow('Size (MB)', '$sizeMB MB'),
              SizedBox(height: 8),
              _buildInfoRow('Size (KB)', '$sizeKB KB'),
              SizedBox(height: 8),
              _buildInfoRow('Size (Bytes)', sizeBytes.toString()),
              SizedBox(height: 16),
              Text(
                'Statistics:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 8),
              _buildInfoRow('Contacts', '$_contactCount'),
              _buildInfoRow('Chats', '$_chatCount'),
              _buildInfoRow('Messages', '$_messageCount'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  void _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Clear Cache?'),
        content: Text(
          'This will clear temporary cached data. '
          'Your messages and contacts will not be affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      // 1. Clear SimpleCrypto conversation keys (pairing keys)
      SimpleCrypto.clearAllConversationKeys();
      
      // 2. Clear ECDH shared secret cache from memory
      // (Note: Secure storage keeps them, but memory cache is cleared)
      
      // 3. Clear processed message cache (replay protection)
      await MessageSecurity.clearProcessedMessages();
      
      // 4. Clear hint cache
      HintCacheManager.clearCache();
      
      // 5. Clear ephemeral session (rotate to new keys)
      await EphemeralKeyManager.rotateSession();
      
      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white),
              SizedBox(width: 8),
              Expanded(
                child: Text('Cache cleared:\n• Conversation keys\n• Message cache\n• Hint cache\n• Ephemeral session'),
              ),
            ],
          ),
          backgroundColor: Color(0xFF1976D2),
          duration: Duration(seconds: 4),
        ),
      );
      
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to clear cache: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _checkDatabaseIntegrity() async {
    try {
      final db = await DatabaseHelper.database;
      final result = await db.rawQuery('PRAGMA integrity_check');
      
      if (!mounted) return;

      final isOk = result.isNotEmpty && 
                   result.first.containsValue('ok');

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Row(
            children: [
              Icon(
                isOk ? Icons.check_circle : Icons.error,
                color: isOk 
                  ? Theme.of(context).colorScheme.primary 
                  : Theme.of(context).colorScheme.error,
              ),
              SizedBox(width: 8),
              Text('Database Integrity'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isOk 
                  ? '✅ Database is healthy'
                  : '⚠️ Database has issues',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: isOk 
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.error,
                ),
              ),
              SizedBox(height: 12),
              Text('Result:'),
              SizedBox(height: 4),
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  result.toString(),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error checking integrity: $e')),
      );
    }
  }
}
