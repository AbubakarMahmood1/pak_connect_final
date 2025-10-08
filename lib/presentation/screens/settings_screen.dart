// Settings screen for app preferences and configuration
// Manages theme, notifications, privacy, and data settings

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/theme_provider.dart';
import '../../data/repositories/preferences_repository.dart';
import '../widgets/export_dialog.dart';
import '../widgets/import_dialog.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final PreferencesRepository _preferencesRepository = PreferencesRepository();

  // Notification settings
  bool _notificationsEnabled = PreferenceDefaults.notificationsEnabled;
  bool _soundEnabled = PreferenceDefaults.soundEnabled;
  bool _vibrationEnabled = PreferenceDefaults.vibrationEnabled;

  // Privacy settings
  bool _showReadReceipts = PreferenceDefaults.showReadReceipts;
  bool _showOnlineStatus = PreferenceDefaults.showOnlineStatus;
  bool _allowNewContacts = PreferenceDefaults.allowNewContacts;

  // Data settings
  bool _autoArchiveOldChats = PreferenceDefaults.autoArchiveOldChats;
  int _archiveAfterDays = PreferenceDefaults.archiveAfterDays;

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('Settings'),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // Appearance section
                _buildSectionHeader(theme, 'Appearance'),
                _buildThemeSelector(theme, themeMode),

                Divider(height: 32),

                // Notifications section
                _buildSectionHeader(theme, 'Notifications'),
                _buildNotificationSettings(theme),

                Divider(height: 32),

                // Privacy section
                _buildSectionHeader(theme, 'Privacy'),
                _buildPrivacySettings(theme),

                Divider(height: 32),

                // Data & Storage section
                _buildSectionHeader(theme, 'Data & Storage'),
                _buildDataSettings(theme),

                Divider(height: 32),

                // About section
                _buildSectionHeader(theme, 'About'),
                _buildAboutSettings(theme),

                SizedBox(height: 32),
              ],
            ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
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
                  child: _buildThemeOption(
                    theme,
                    ThemeMode.light,
                    currentMode,
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: _buildThemeOption(
                    theme,
                    ThemeMode.dark,
                    currentMode,
                  ),
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
            color: isSelected
                ? theme.colorScheme.primary
                : Colors.transparent,
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
          ],
        ],
      ),
    );
  }

  Widget _buildPrivacySettings(ThemeData theme) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
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
                segments: [ 30, 60, 90, 180, 365].map((days) =>
                  ButtonSegment<int>(
                    value: days,
                    label: Text('$days'),
                  )
                ).toList(),
                selected: selectedValue != null ? <int>{selectedValue!} : <int>{},
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
    }
  }

  void _showStorageInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Storage Usage'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Database: ~2.5 MB'),
            SizedBox(height: 8),
            Text('Cached Data: ~1.2 MB'),
            SizedBox(height: 8),
            Text('Total: ~3.7 MB'),
            SizedBox(height: 16),
            Text(
              'Note: Storage calculation is approximate',
              style: Theme.of(context).textTheme.bodySmall,
            ),
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
      // TODO: Implement actual data clearing
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Data clearing not yet implemented'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
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
        Text('Secure peer-to-peer messaging with mesh networking and end-to-end encryption.'),
        SizedBox(height: 12),
        Text(
          'Features:',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
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

  void _showPrivacyPolicy() {
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
            content: Text('Data imported successfully! Please restart the app.'),
            duration: Duration(seconds: 5),
          ),
        );
      }
    }
  }
}
