// Theme provider with persistent storage
// Manages app theme mode (light/dark/system) with database persistence

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import '../../data/repositories/preferences_repository.dart';

final _logger = Logger('ThemeProvider');

/// Provider for preferences repository
final preferencesRepositoryProvider = Provider<PreferencesRepository>((ref) {
  return PreferencesRepository();
});

/// Theme mode notifier with database persistence
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    _loadThemeMode();
    return ThemeMode.system;
  }

  /// Load theme mode from database
  Future<void> _loadThemeMode() async {
    try {
      final preferencesRepo = ref.read(preferencesRepositoryProvider);
      final themeModeString = await preferencesRepo.getString(
        PreferenceKeys.themeMode,
        defaultValue: PreferenceDefaults.themeMode,
      );

      state = _parseThemeMode(themeModeString);
      _logger.info('Loaded theme mode: $themeModeString');
    } catch (e) {
      _logger.warning('Failed to load theme mode, using default: $e');
      state = ThemeMode.system;
    }
  }

  /// Set theme mode and persist to database
  Future<void> setThemeMode(ThemeMode mode) async {
    try {
      final preferencesRepo = ref.read(preferencesRepositoryProvider);
      await preferencesRepo.setString(
        PreferenceKeys.themeMode,
        _themeModeToString(mode),
      );

      state = mode;
      _logger.info('Theme mode changed to: ${_themeModeToString(mode)}');
    } catch (e) {
      _logger.severe('Failed to set theme mode: $e');
      rethrow;
    }
  }

  /// Parse theme mode from string
  ThemeMode _parseThemeMode(String value) {
    switch (value.toLowerCase()) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
      default:
        return ThemeMode.system;
    }
  }

  /// Convert theme mode to string
  String _themeModeToString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }
}

/// Provider for theme mode
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(() {
  return ThemeModeNotifier();
});

/// Helper to get theme mode name for UI display
String getThemeModeName(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return 'Light';
    case ThemeMode.dark:
      return 'Dark';
    case ThemeMode.system:
      return 'System';
  }
}

/// Helper to get theme mode icon
IconData getThemeModeIcon(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return Icons.light_mode;
    case ThemeMode.dark:
      return Icons.dark_mode;
    case ThemeMode.system:
      return Icons.brightness_auto;
  }
}
