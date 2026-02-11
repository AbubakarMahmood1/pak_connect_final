// Security level indicator with color coding and icons

import 'package:flutter/material.dart';
import '../../domain/models/security_level.dart';

/// Visual badge showing contact's security level
class SecurityLevelBadge extends StatelessWidget {
  final SecurityLevel level;
  final BadgeStyle style;

  const SecurityLevelBadge({
    super.key,
    required this.level,
    this.style = BadgeStyle.chip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = _getSecurityConfig(level);

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
    _SecurityConfig config,
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

  Widget _buildIcon(BuildContext context, _SecurityConfig config) {
    return Tooltip(
      message: config.description,
      child: Icon(config.icon, size: 18, color: config.color),
    );
  }

  Widget _buildCompact(
    BuildContext context,
    ThemeData theme,
    _SecurityConfig config,
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

  _SecurityConfig _getSecurityConfig(SecurityLevel level) {
    switch (level) {
      case SecurityLevel.high:
        return _SecurityConfig(
          icon: Icons.shield,
          label: 'High',
          description: 'ECDH Encrypted',
          color: const Color(0xFF2E7D32), // Green 800
        );
      case SecurityLevel.medium:
        return _SecurityConfig(
          icon: Icons.shield_outlined,
          label: 'Medium',
          description: 'Paired',
          color: const Color(0xFFEF6C00), // Orange 800
        );
      case SecurityLevel.low:
        return _SecurityConfig(
          icon: Icons.shield_outlined,
          label: 'Low',
          description: 'Basic Encryption',
          color: const Color(0xFF616161), // Grey 700
        );
    }
  }
}

enum BadgeStyle { chip, icon, compact }

class _SecurityConfig {
  final IconData icon;
  final String label;
  final String description;
  final Color color;

  const _SecurityConfig({
    required this.icon,
    required this.label,
    required this.description,
    required this.color,
  });
}
