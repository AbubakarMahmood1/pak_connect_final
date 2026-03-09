// Settings screen for app preferences and configuration
// Manages theme, notifications, privacy, and data settings

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../controllers/settings_controller.dart';
import '../providers/ble_providers.dart';
import '../widgets/settings/about_section.dart';
import '../widgets/settings/appearance_section.dart';
import '../widgets/settings/data_storage_section.dart';
import '../widgets/settings/developer_tools_section.dart';
import '../widgets/settings/notification_section.dart';
import '../widgets/settings/privacy_section.dart';
import '../widgets/settings/settings_section_header.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.controller});

  /// Optional controller injection seam for tests.
  final SettingsController? controller;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _logger = Logger('SettingsScreen');
  late final SettingsController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? SettingsController(logger: _logger);
    _controller
      ..addListener(_onControllerChanged)
      ..initialize();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  Future<void> _handleOnlineStatusChange(bool value) async {
    await _controller.setOnlineStatus(value);
    final bleService = ref.read(connectionServiceProvider);
    if (bleService.isPeripheralMode) {
      await bleService.refreshAdvertising(showOnlineStatus: value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _controller.isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const SettingsSectionHeader(title: 'Appearance'),
                const AppearanceSection(),

                const Divider(height: 24),

                const SettingsSectionHeader(title: 'Notifications'),
                NotificationSection(
                  controller: _controller,
                  onShowError: _showError,
                ),

                const Divider(height: 24),

                const SettingsSectionHeader(title: 'Privacy'),
                PrivacySection(
                  hintBroadcastEnabled: _controller.hintBroadcastEnabled,
                  showReadReceipts: _controller.showReadReceipts,
                  showOnlineStatus: _controller.showOnlineStatus,
                  allowNewContacts: _controller.allowNewContacts,
                  autoConnectKnownContacts:
                      _controller.autoConnectKnownContacts,
                  rateLimitUnknown: _controller.rateLimitUnknown,
                  rateLimitKnown: _controller.rateLimitKnown,
                  rateLimitFriend: _controller.rateLimitFriend,
                  onHintBroadcastChanged: (value) async {
                    await _controller.setHintBroadcastEnabled(value);
                  },
                  onReadReceiptsChanged: (value) async {
                    await _controller.setReadReceipts(value);
                  },
                  onOnlineStatusChanged: _handleOnlineStatusChange,
                  onAllowNewContactsChanged: (value) async {
                    await _controller.setAllowNewContacts(value);
                  },
                  onAutoConnectChanged: (value) async {
                    _logger.info(
                      'AUTO-CONNECT SETTING: ${value ? "ENABLED" : "DISABLED"}',
                    );
                    await _controller.setAutoConnectKnownContacts(value);
                  },
                  onRateLimitUnknownChanged: (value) async {
                    await _controller.setRateLimitUnknown(value);
                  },
                  onRateLimitKnownChanged: (value) async {
                    await _controller.setRateLimitKnown(value);
                  },
                  onRateLimitFriendChanged: (value) async {
                    await _controller.setRateLimitFriend(value);
                  },
                  onShowMessage: _showSnack,
                ),

                const Divider(height: 24),

                const SettingsSectionHeader(title: 'Data & Storage'),
                DataStorageSection(controller: _controller),

                const Divider(height: 24),

                const SettingsSectionHeader(title: 'About'),
                AboutSection(controller: _controller),

                if (kDebugMode) ...[
                  const Divider(height: 24),
                  const SettingsSectionHeader(title: '🛠️ Developer Tools'),
                  DeveloperToolsSection(
                    controller: _controller,
                    onShowMessage: _showSnack,
                    onShowError: _showError,
                  ),
                ],

                const SizedBox(height: 32),
              ],
            ),
    );
  }
}
