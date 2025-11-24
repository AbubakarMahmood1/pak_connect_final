import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import '../../../core/security/hint_cache_manager.dart';
import '../../../core/services/hint_advertisement_service.dart';
import '../../../core/security/security_types.dart';
import '../../../core/utils/string_extensions.dart';
import '../../../domain/entities/contact.dart';
import 'discovery_types.dart';

class DiscoveryDeviceTile extends StatelessWidget {
  const DiscoveryDeviceTile({
    super.key,
    required this.device,
    required this.advertisement,
    required this.isKnownContact,
    required this.contacts,
    required this.attemptState,
    required this.isConnectedAsCentral,
    required this.isConnectedAsPeripheral,
    required this.onConnect,
    required this.onRetry,
    required this.onOpenChat,
    required this.onError,
    required this.logger,
  });

  final Peripheral device;
  final DiscoveredEventArgs? advertisement;
  final bool isKnownContact;
  final Map<String, Contact> contacts;
  final ConnectionAttemptState attemptState;
  final bool isConnectedAsCentral;
  final bool isConnectedAsPeripheral;
  final Future<void> Function() onConnect;
  final VoidCallback onRetry;
  final VoidCallback onOpenChat;
  final void Function(String message) onError;
  final Logger logger;

  @override
  Widget build(BuildContext context) {
    final resolution = _resolveContact(advertisement, contacts, logger);
    final deviceName = resolution.deviceName;
    final matchedContact = resolution.matchedContact;
    final isContactResolved = resolution.isResolved;

    final rssi = advertisement?.rssi ?? -100;
    final signalStrength = _getSignalStrength(rssi);

    final isPaired = matchedContact != null;
    final isVerified = matchedContact?.trustStatus == TrustStatus.verified;
    final securityLevel = matchedContact?.securityLevel ?? SecurityLevel.low;

    final isActuallyConnected = isConnectedAsCentral || isConnectedAsPeripheral;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Card(
        elevation: isContactResolved ? 2 : 1,
        child: ListTile(
          leading: _buildAvatar(context, isContactResolved, isVerified),
          title: Text(
            deviceName,
            style: TextStyle(
              fontWeight: isContactResolved
                  ? FontWeight.bold
                  : FontWeight.normal,
            ),
          ),
          subtitle: _buildSubtitle(
            context,
            signalStrength,
            isContactResolved,
            isPaired,
            isVerified,
            securityLevel,
            isActuallyConnected,
          ),
          trailing: _buildTrailingIcon(attemptState, rssi, isActuallyConnected),
          onTap: () {
            if (isActuallyConnected) {
              onOpenChat();
              return;
            }

            switch (attemptState) {
              case ConnectionAttemptState.connecting:
                onError('Connection in progress, please wait...');
                return;
              case ConnectionAttemptState.failed:
                onRetry();
                return;
              case ConnectionAttemptState.connected:
              case ConnectionAttemptState.none:
                break;
            }

            onConnect();
          },
        ),
      ),
    );
  }

  Widget _buildAvatar(
    BuildContext context,
    bool isContactResolved,
    bool isVerified,
  ) {
    return Stack(
      children: [
        CircleAvatar(
          backgroundColor: isContactResolved
              ? (isVerified
                    ? Colors.green.withValues(alpha: 0.2)
                    : Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.2))
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(
            isContactResolved
                ? (isVerified ? Icons.verified_user : Icons.person)
                : Icons.bluetooth,
            color: isContactResolved
                ? (isVerified
                      ? Colors.green
                      : Theme.of(context).colorScheme.primary)
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (isContactResolved)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: isVerified ? Colors.green : Colors.blue,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSubtitle(
    BuildContext context,
    String signalStrength,
    bool isContactResolved,
    bool isPaired,
    bool isVerified,
    SecurityLevel securityLevel,
    bool isActuallyConnected,
  ) {
    final signalRow = Row(
      children: [
        Icon(
          _getSignalIcon(signalStrength),
          size: 16,
          color: _getSignalColor(signalStrength),
        ),
        const SizedBox(width: 4),
        Text('Signal: $signalStrength', style: const TextStyle(fontSize: 12)),
      ],
    );

    final connectionBadge = _buildConnectionStatusBadge(attemptState);

    final roleBadges = _buildRoleBadges(
      isConnectedAsCentral,
      isConnectedAsPeripheral,
    );

    if (isContactResolved || isPaired) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          signalRow,
          if (isContactResolved || isPaired) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (isContactResolved)
                  _buildChip(
                    context,
                    'CONTACT',
                    Theme.of(context).colorScheme.primary,
                  ),
                if (isPaired) _buildSecurityChip(securityLevel),
                if (isVerified)
                  _buildChip(
                    context,
                    'VERIFIED',
                    Colors.green,
                    icon: Icons.verified,
                  ),
                ...roleBadges,
                connectionBadge,
              ],
            ),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        signalRow,
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [...roleBadges, connectionBadge],
        ),
      ],
    );
  }

  Widget _buildChip(
    BuildContext context,
    String label,
    Color color, {
    IconData? icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: color),
            const SizedBox(width: 2),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSecurityChip(SecurityLevel level) {
    final color = _getSecurityColor(level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_getSecurityIcon(level), size: 10, color: color),
          const SizedBox(width: 2),
          Text(
            _getSecurityLabel(level),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildRoleBadges(
    bool isConnectedAsCentral,
    bool isConnectedAsPeripheral,
  ) {
    if (isConnectedAsCentral && isConnectedAsPeripheral) {
      return [_buildRoleChip('BOTH ROLES', Colors.purple)];
    }

    if (isConnectedAsCentral) {
      return [_buildRoleChip('CENTRAL', Colors.blue)];
    }

    if (isConnectedAsPeripheral) {
      return [_buildRoleChip('PERIPHERAL', Colors.amber)];
    }

    return [];
  }

  Widget _buildRoleChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Widget _buildConnectionStatusBadge(ConnectionAttemptState attemptState) {
    String label;
    Color color;
    IconData icon;

    switch (attemptState) {
      case ConnectionAttemptState.connected:
        label = 'CONNECTED';
        color = Colors.green;
        icon = Icons.link;
        break;
      case ConnectionAttemptState.connecting:
        label = 'CONNECTING';
        color = Colors.orange;
        icon = Icons.sync;
        break;
      case ConnectionAttemptState.failed:
        label = 'RETRY';
        color = Colors.red;
        icon = Icons.refresh;
        break;
      case ConnectionAttemptState.none:
        label = 'TAP TO CONNECT';
        color = Colors.blue;
        icon = Icons.bluetooth;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrailingIcon(
    ConnectionAttemptState attemptState,
    int rssi,
    bool isActuallyConnected,
  ) {
    if (attemptState == ConnectionAttemptState.connecting) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(Colors.orange),
        ),
      );
    } else if (isActuallyConnected) {
      return const Icon(Icons.chat, color: Colors.green);
    } else if (attemptState == ConnectionAttemptState.failed) {
      return const Icon(Icons.refresh, color: Colors.red);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSignalStrengthBars(rssi),
        const SizedBox(width: 8),
        const Icon(Icons.chevron_right, color: Colors.grey),
      ],
    );
  }

  Widget _buildSignalStrengthBars(int rssi) {
    final strength = _getSignalStrengthLevel(rssi);
    final color = _getSignalStrengthColor(rssi);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(4, (index) {
        final isActive = index < strength;
        final barHeight = 4.0 + (index * 3.0);

        return Container(
          width: 3,
          height: barHeight,
          margin: EdgeInsets.only(left: index > 0 ? 2 : 0),
          decoration: BoxDecoration(
            color: isActive ? color : Colors.grey.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }

  _ResolvedContact _resolveContact(
    DiscoveredEventArgs? advertisement,
    Map<String, Contact> contacts,
    Logger logger,
  ) {
    String deviceName = 'Unknown Device';
    bool isContactResolved = false;
    Contact? matchedContact;

    if (advertisement != null &&
        advertisement.advertisement.manufacturerSpecificData.isNotEmpty) {
      deviceName = _resolveDeviceNameFromHints(advertisement, logger);
      isContactResolved = deviceName != 'Unknown Device';

      if (isContactResolved) {
        matchedContact = contacts.values
            .where((contact) => contact.displayName == deviceName)
            .firstOrNull;
      }
    }

    if (!isContactResolved && isKnownContact) {
      matchedContact = contacts.values
          .where(
            (contact) => contact.publicKey.contains(device.uuid.toString()),
          )
          .firstOrNull;

      if (matchedContact != null) {
        deviceName = matchedContact.displayName;
        isContactResolved = true;
      }
    }

    if (!isContactResolved) {
      deviceName = 'Device ${device.uuid.toString().shortId(8)}';
    }

    return _ResolvedContact(
      deviceName: deviceName,
      matchedContact: matchedContact,
      isResolved: isContactResolved,
    );
  }

  String _resolveDeviceNameFromHints(
    DiscoveredEventArgs advertisement,
    Logger logger,
  ) {
    try {
      for (final manufacturerData
          in advertisement.advertisement.manufacturerSpecificData) {
        if (manufacturerData.id != 0x2E19) continue;
        final parsed = HintAdvertisementService.parseAdvertisement(
          manufacturerData.data,
        );
        if (parsed == null || parsed.isIntro) {
          continue;
        }
        final contactHint = HintCacheManager.matchBlindedHintSync(
          nonce: parsed.nonce,
          hintBytes: parsed.hintBytes,
        );
        if (contactHint != null) {
          final name = contactHint.contact.contact.displayName;
          if (name.isNotEmpty) {
            logger.fine('Resolved device name from hint: $name');
            return name;
          }
        }
      }
    } catch (e) {
      logger.warning('Error resolving device name from hints: $e');
    }

    return 'Unknown Device';
  }

  String _getSignalStrength(int rssi) {
    if (rssi >= -50) return 'Excellent';
    if (rssi >= -60) return 'Good';
    if (rssi >= -70) return 'Fair';
    return 'Poor';
  }

  IconData _getSignalIcon(String strength) {
    switch (strength) {
      case 'Excellent':
        return Icons.signal_wifi_4_bar;
      case 'Good':
        return Icons.network_wifi_3_bar;
      case 'Fair':
        return Icons.network_wifi_2_bar;
      default:
        return Icons.network_wifi_1_bar;
    }
  }

  Color _getSignalColor(String strength) {
    switch (strength) {
      case 'Excellent':
        return Colors.green;
      case 'Good':
        return Colors.lightGreen;
      case 'Fair':
        return Colors.orange;
      default:
        return Colors.red;
    }
  }

  int _getSignalStrengthLevel(int rssi) {
    if (rssi >= -50) return 4;
    if (rssi >= -60) return 3;
    if (rssi >= -70) return 2;
    if (rssi >= -80) return 1;
    return 0;
  }

  Color _getSignalStrengthColor(int rssi) {
    if (rssi >= -50) return Colors.green;
    if (rssi >= -60) return Colors.lightGreen;
    if (rssi >= -70) return Colors.orange;
    if (rssi >= -80) return Colors.deepOrange;
    return Colors.red;
  }

  IconData _getSecurityIcon(SecurityLevel level) {
    switch (level) {
      case SecurityLevel.high:
        return Icons.verified_user;
      case SecurityLevel.medium:
        return Icons.lock;
      case SecurityLevel.low:
        return Icons.lock_open;
    }
  }

  Color _getSecurityColor(SecurityLevel level) {
    switch (level) {
      case SecurityLevel.high:
        return Colors.green;
      case SecurityLevel.medium:
        return Colors.blue;
      case SecurityLevel.low:
        return Colors.orange;
    }
  }

  String _getSecurityLabel(SecurityLevel level) {
    switch (level) {
      case SecurityLevel.high:
        return 'ECDH';
      case SecurityLevel.medium:
        return 'PAIRED';
      case SecurityLevel.low:
        return 'BASIC';
    }
  }
}

class _ResolvedContact {
  _ResolvedContact({
    required this.deviceName,
    required this.matchedContact,
    required this.isResolved,
  });

  final String deviceName;
  final Contact? matchedContact;
  final bool isResolved;
}
