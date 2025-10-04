// Profile screen showing user info, QR code, and statistics
// Displays avatar, username, device ID, statistics, and QR for sharing

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/ble_providers.dart';
import '../../data/repositories/user_preferences.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/chats_repository.dart';
import 'dart:convert';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final UserPreferences _userPreferences = UserPreferences();
  final ContactRepository _contactRepository = ContactRepository();
  final ChatsRepository _chatsRepository = ChatsRepository();

  String _deviceId = '';
  String _publicKey = '';

  // Statistics
  int _contactCount = 0;
  int _chatCount = 0;
  int _messageCount = 0;
  int _verifiedContactCount = 0;

  bool _isLoadingStats = true;

  @override
  void initState() {
    super.initState();
    _loadProfileData();
    _loadStatistics();
  }

  Future<void> _loadProfileData() async {
    final deviceId = await _userPreferences.getDeviceId();
    final publicKey = await _userPreferences.getPublicKey();

    if (mounted) {
      setState(() {
        _deviceId = deviceId ?? 'N/A';
        _publicKey = publicKey;
      });
    }
  }

  Future<void> _loadStatistics() async {
    setState(() => _isLoadingStats = true);

    final contactCount = await _contactRepository.getContactCount();
    final chatCount = await _chatsRepository.getChatCount();
    final messageCount = await _chatsRepository.getTotalMessageCount();
    final verifiedContactCount = await _contactRepository.getVerifiedContactCount();

    if (mounted) {
      setState(() {
        _contactCount = contactCount;
        _chatCount = chatCount;
        _messageCount = messageCount;
        _verifiedContactCount = verifiedContactCount;
        _isLoadingStats = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usernameAsync = ref.watch(usernameProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('Profile'),
        actions: [
          IconButton(
            onPressed: _shareProfile,
            icon: Icon(Icons.share),
            tooltip: 'Share profile',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _loadProfileData();
          await _loadStatistics();
        },
        child: SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Avatar and username
              _buildAvatarSection(usernameAsync, theme),

              SizedBox(height: 24),

              // Device ID card
              _buildDeviceIdCard(theme),

              SizedBox(height: 16),

              // QR Code card
              _buildQRCodeCard(usernameAsync, theme),

              SizedBox(height: 16),

              // Statistics cards
              _buildStatisticsSection(theme),

              SizedBox(height: 16),

              // Action buttons
              _buildActionButtons(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvatarSection(AsyncValue<String> usernameAsync, ThemeData theme) {
    return usernameAsync.when(
      data: (username) => Column(
        children: [
          // Large avatar
          GestureDetector(
            onTap: () => _editDisplayName(username),
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.primaryContainer,
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  username.isNotEmpty ? username[0].toUpperCase() : 'U',
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          ),

          SizedBox(height: 16),

          // Username with edit button
          GestureDetector(
            onTap: () => _editDisplayName(username),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  username.isEmpty ? 'Set your name' : username,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(width: 8),
                Icon(
                  Icons.edit,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
              ],
            ),
          ),
        ],
      ),
      loading: () => CircularProgressIndicator(),
      error: (error, stack) => Icon(Icons.error),
    );
  }

  Widget _buildDeviceIdCard(ThemeData theme) {
    return Card(
      child: ListTile(
        leading: Icon(Icons.smartphone, color: theme.colorScheme.primary),
        title: Text('Device ID'),
        subtitle: Text(
          _deviceId.isEmpty ? 'Loading...' : _deviceId,
          style: TextStyle(fontFamily: 'monospace'),
        ),
        trailing: IconButton(
          icon: Icon(Icons.copy, size: 20),
          onPressed: () => _copyToClipboard(_deviceId, 'Device ID'),
        ),
      ),
    );
  }

  Widget _buildQRCodeCard(AsyncValue<String> usernameAsync, ThemeData theme) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Your QR Code',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Icon(Icons.qr_code_2, color: theme.colorScheme.primary),
              ],
            ),

            SizedBox(height: 8),

            Text(
              'Others can scan this to add you as a contact',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),

            SizedBox(height: 16),

            // QR Code
            if (_publicKey.isNotEmpty)
              Center(
                child: usernameAsync.when(
                  data: (username) => Container(
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(
                      data: _generateQRData(username),
                      version: QrVersions.auto,
                      size: 200,
                      backgroundColor: Colors.white,
                    ),
                  ),
                  loading: () => SizedBox(
                    width: 200,
                    height: 200,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (error, stack) => SizedBox(
                    width: 200,
                    height: 200,
                    child: Center(child: Icon(Icons.error)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatisticsSection(ThemeData theme) {
    if (_isLoadingStats) {
      return Card(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text(
            'Statistics',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),

        // Stats grid
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.3,
          children: [
            _buildStatCard(
              theme,
              icon: Icons.contacts,
              label: 'Contacts',
              value: _contactCount.toString(),
              color: Colors.blue,
            ),
            _buildStatCard(
              theme,
              icon: Icons.chat,
              label: 'Chats',
              value: _chatCount.toString(),
              color: Colors.green,
            ),
            _buildStatCard(
              theme,
              icon: Icons.message,
              label: 'Messages',
              value: _messageCount.toString(),
              color: Colors.orange,
            ),
            _buildStatCard(
              theme,
              icon: Icons.verified_user,
              label: 'Verified',
              value: _verifiedContactCount.toString(),
              color: Colors.purple,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatCard(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 32),
            SizedBox(height: 8),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
              ),
            ),
            SizedBox(height: 4),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: () => _regenerateKeys(),
          icon: Icon(Icons.refresh),
          label: Text('Regenerate Encryption Keys'),
        ),
      ],
    );
  }

  String _generateQRData(String username) {
    final qrData = {
      'displayName': username,
      'publicKey': _publicKey,
      'deviceId': _deviceId,
      'version': 1,
    };
    return jsonEncode(qrData);
  }

  void _editDisplayName(String currentName) async {
    final controller = TextEditingController(text: currentName);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit Display Name'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: 'Your name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text('Save'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && result != currentName) {
      try {
        await ref.read(usernameProvider.notifier).updateUsername(result);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Name updated successfully')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to update name: $e')),
          );
        }
      }
    }
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied to clipboard')),
    );
  }

  void _shareProfile() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Show QR code to share your profile')),
    );
  }

  void _regenerateKeys() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning, color: Theme.of(context).colorScheme.error),
            SizedBox(width: 8),
            Text('Regenerate Keys?'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This will generate new encryption keys for your device.'),
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
                  Text(
                    '⚠️ Warning:',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '• Existing contacts will need to re-verify you\n'
                    '• Encrypted message history may be affected\n'
                    '• You\'ll need to share your new QR code',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                      fontSize: 12,
                    ),
                  ),
                ],
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
            child: Text('Regenerate'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _userPreferences.regenerateKeyPair();
        await _loadProfileData(); // Reload to show new public key

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Encryption keys regenerated successfully'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to regenerate keys: $e'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    }
  }
}
