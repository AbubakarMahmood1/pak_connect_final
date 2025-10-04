// Modern contact avatar with Material Design 3 styling

import 'package:flutter/material.dart';

/// Circular avatar showing contact's initial with color-coded background
class ContactAvatar extends StatelessWidget {
  final String displayName;
  final double radius;
  final bool showBorder;
  final Color? backgroundColor;
  final Color? foregroundColor;

  const ContactAvatar({
    super.key,
    required this.displayName,
    this.radius = 20,
    this.showBorder = false,
    this.backgroundColor,
    this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';

    // Generate consistent color from name
    final colorIndex = displayName.hashCode.abs() % _avatarColors.length;
    final defaultBgColor = _avatarColors[colorIndex];

    final bgColor = backgroundColor ?? defaultBgColor;
    final fgColor = foregroundColor ?? _getContrastColor(bgColor);

    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: bgColor,
      child: Text(
        initial,
        style: TextStyle(
          color: fgColor,
          fontSize: radius * 0.8,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
    );

    if (!showBorder) {
      return avatar;
    }

    // Add border for emphasis
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.2),
          width: 2,
        ),
      ),
      child: avatar,
    );
  }

  /// Get contrasting text color for background
  Color _getContrastColor(Color background) {
    final luminance = background.computeLuminance();
    return luminance > 0.5 ? Colors.black87 : Colors.white;
  }

  /// Material Design 3 color palette for avatars
  static final List<Color> _avatarColors = [
    const Color(0xFF1976D2), // Blue
    const Color(0xFF388E3C), // Green
    const Color(0xFFD32F2F), // Red
    const Color(0xFFF57C00), // Orange
    const Color(0xFF7B1FA2), // Purple
    const Color(0xFF0097A7), // Cyan
    const Color(0xFFC2185B), // Pink
    const Color(0xFF5D4037), // Brown
    const Color(0xFF512DA8), // Deep Purple
    const Color(0xFF00796B), // Teal
    const Color(0xFFFBC02D), // Yellow
    const Color(0xFF455A64), // Blue Grey
  ];
}

/// Large avatar for detail screens with hero animation support
class LargeContactAvatar extends StatelessWidget {
  final String displayName;
  final String? heroTag;

  const LargeContactAvatar({
    super.key,
    required this.displayName,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = ContactAvatar(
      displayName: displayName,
      radius: 48,
      showBorder: true,
    );

    if (heroTag != null) {
      return Hero(
        tag: heroTag!,
        child: avatar,
      );
    }

    return avatar;
  }
}
