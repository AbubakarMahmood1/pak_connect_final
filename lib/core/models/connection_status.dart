import 'package:flutter/material.dart';

enum ConnectionStatus { connected, connecting, nearby, recent, offline }

extension ConnectionStatusExtension on ConnectionStatus {
  Color get color {
    switch (this) {
      case ConnectionStatus.connected:
        return Colors.green;
      case ConnectionStatus.connecting:
        return Colors.orange;
      case ConnectionStatus.nearby:
        return Colors.blue;
      case ConnectionStatus.recent:
        return Colors.grey;
      case ConnectionStatus.offline:
        return Colors.grey.shade700;
    }
  }

  IconData get icon {
    switch (this) {
      case ConnectionStatus.connected:
        return Icons.circle;
      case ConnectionStatus.connecting:
        return Icons.pending;
      case ConnectionStatus.nearby:
        return Icons.radar;
      case ConnectionStatus.recent:
        return Icons.schedule;
      case ConnectionStatus.offline:
        return Icons.circle_outlined;
    }
  }

  String get label {
    switch (this) {
      case ConnectionStatus.connected:
        return 'Connected';
      case ConnectionStatus.connecting:
        return 'Connecting...';
      case ConnectionStatus.nearby:
        return 'Nearby';
      case ConnectionStatus.recent:
        return 'Recently seen';
      case ConnectionStatus.offline:
        return 'Offline';
    }
  }
}
