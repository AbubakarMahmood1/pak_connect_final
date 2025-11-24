import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../controllers/settings_controller.dart';

class AboutSection extends StatelessWidget {
  const AboutSection({super.key, required this.controller});

  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.info),
            title: const Text('About PakConnect'),
            subtitle: const Text('Version 1.0.0'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showAbout(context),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.help),
            title: const Text('Help & Support'),
            subtitle: const Text('Get help using the app'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showHelp(context),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.privacy_tip),
            title: const Text('Privacy Policy'),
            subtitle: const Text('How we handle your data'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showPrivacyPolicy(context),
          ),
        ],
      ),
    );
  }

  void _showAbout(BuildContext context) {
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
        const SizedBox(height: 16),
        const Text(
          'Secure peer-to-peer messaging with mesh networking and end-to-end encryption.',
        ),
        const SizedBox(height: 12),
        const Text('Features:', style: TextStyle(fontWeight: FontWeight.w600)),
        const Text('• Offline messaging via Bluetooth'),
        const Text('• End-to-end encryption'),
        const Text('• Mesh network relay'),
        const Text('• No internet required'),
        const Text('• No data collection'),
        const SizedBox(height: 12),
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

  void _showHelp(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Help & Support'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
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
              Text('For more help, visit our documentation.'),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Future<void> _showPrivacyPolicy(BuildContext context) async {
    try {
      final markdownContent = await controller.loadPrivacyPolicyMarkdown();
      if (!context.mounted) return;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Row(
            children: [
              Icon(
                Icons.privacy_tip,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              const Text('Privacy Policy'),
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
                h3: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                p: const TextStyle(fontSize: 14, height: 1.5),
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
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Privacy Policy'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Your Privacy Matters',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                const Text('PakConnect is designed with privacy at its core:'),
                const SizedBox(height: 8),
                const Text('• All messages are end-to-end encrypted'),
                const Text('• No data is sent to external servers'),
                const Text('• No tracking or analytics'),
                const Text('• All data stays on your device'),
                const Text('• Open-source encryption protocols'),
                const SizedBox(height: 12),
                Text(
                  'We never have access to your messages or contacts. Error loading full policy: $e',
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
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }
  }
}
