// Trust status indicator with visual feedback

import 'package:flutter/material.dart';
import '../../domain/entities/contact.dart';

/// Visual badge showing contact's trust/verification status
class TrustStatusBadge extends StatelessWidget {
  final TrustStatus status;
  final BadgeStyle style;

  const TrustStatusBadge({
    super.key,
    required this.status,
    this.style = BadgeStyle.chip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = _getTrustConfig(status);

    switch (style) {
      case BadgeStyle.chip:
        return _buildChip(context, theme, config);
      case BadgeStyle.icon:
        return _buildIcon(context, config);
      case BadgeStyle.compact:
        return _buildCompact(context, theme, config);
    }
  }

  Widget _buildChip(
    BuildContext context,
    ThemeData theme,
    _TrustConfig config,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: config.color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: config.color.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(config.icon, size: 14, color: config.color),
          const SizedBox(width: 4),
          Text(
            config.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: config.color,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIcon(BuildContext context, _TrustConfig config) {
    return Tooltip(
      message: config.description,
      child: Icon(config.icon, size: 18, color: config.color),
    );
  }

  Widget _buildCompact(
    BuildContext context,
    ThemeData theme,
    _TrustConfig config,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(config.icon, size: 12, color: config.color),
        const SizedBox(width: 4),
        Text(
          config.label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: config.color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  _TrustConfig _getTrustConfig(TrustStatus status) {
    switch (status) {
      case TrustStatus.verified:
        return _TrustConfig(
          icon: Icons.verified,
          label: 'Verified',
          description: 'Identity confirmed',
          color: const Color(0xFF1976D2), // Blue 700
        );
      case TrustStatus.newContact:
        return _TrustConfig(
          icon: Icons.person_add_outlined,
          label: 'New',
          description: 'Not yet verified',
          color: const Color(0xFF616161), // Grey 700
        );
      case TrustStatus.keyChanged:
        return _TrustConfig(
          icon: Icons.warning,
          label: 'Key Changed',
          description: 'Security warning - verify identity',
          color: const Color(0xFFD32F2F), // Red 700
        );
    }
  }
}

enum BadgeStyle { chip, icon, compact }

class _TrustConfig {
  final IconData icon;
  final String label;
  final String description;
  final Color color;

  const _TrustConfig({
    required this.icon,
    required this.label,
    required this.description,
    required this.color,
  });
}
