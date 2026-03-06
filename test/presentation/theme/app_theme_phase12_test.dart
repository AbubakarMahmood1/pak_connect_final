// Phase 12.12: app_theme.dart + ThemeManager coverage
// Targets: lightTheme, darkTheme, _buildTheme, _buildTextTheme,
//          ThemeManager.getSavedThemeMode (all branches), saveThemeMode,
//          isHighContrastEnabled, isReduceMotionEnabled,
//          CustomColorsExtension, CustomColors

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/presentation/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // ─── AppTheme ─────────────────────────────────────────────────────────
  group('AppTheme', () {
    test('lightTheme is Material3 with light brightness', () {
      final theme = AppTheme.lightTheme;
      expect(theme.useMaterial3, isTrue);
      expect(theme.brightness, Brightness.light);
      expect(theme.colorScheme.brightness, Brightness.light);
    });

    test('darkTheme is Material3 with dark brightness', () {
      final theme = AppTheme.darkTheme;
      expect(theme.useMaterial3, isTrue);
      expect(theme.brightness, Brightness.dark);
      expect(theme.colorScheme.brightness, Brightness.dark);
    });

    test('lightTheme has expected primary color', () {
      final theme = AppTheme.lightTheme;
      expect(theme.colorScheme.primary, const Color(0xFF6750A4));
    });

    test('darkTheme has expected primary color', () {
      final theme = AppTheme.darkTheme;
      expect(theme.colorScheme.primary, const Color(0xFFD0BCFF));
    });

    test('lightTheme contains appBarTheme', () {
      final theme = AppTheme.lightTheme;
      expect(theme.appBarTheme.elevation, 0);
      expect(theme.appBarTheme.scrolledUnderElevation, 3);
    });

    test('darkTheme contains appBarTheme', () {
      final theme = AppTheme.darkTheme;
      expect(theme.appBarTheme.elevation, 0);
    });

    test('lightTheme has text theme configured', () {
      final theme = AppTheme.lightTheme;
      expect(theme.textTheme.bodyMedium, isNotNull);
      expect(theme.textTheme.headlineMedium, isNotNull);
    });

    test('darkTheme has text theme configured', () {
      final theme = AppTheme.darkTheme;
      expect(theme.textTheme.bodyMedium, isNotNull);
    });

    test('lightTheme has card theme', () {
      final theme = AppTheme.lightTheme;
      expect(theme.cardTheme, isNotNull);
    });

    test('darkTheme has elevated button theme', () {
      final theme = AppTheme.darkTheme;
      expect(theme.elevatedButtonTheme, isNotNull);
    });

    test('lightTheme has input decoration theme', () {
      final theme = AppTheme.lightTheme;
      expect(theme.inputDecorationTheme, isNotNull);
    });

    test('darkTheme has floating action button theme', () {
      final theme = AppTheme.darkTheme;
      expect(theme.floatingActionButtonTheme, isNotNull);
    });
  });

  // ─── ThemeManager ─────────────────────────────────────────────────────
  group('ThemeManager', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    test('getSavedThemeMode returns system when no saved value', () async {
      SharedPreferences.setMockInitialValues({});
      final mode = await ThemeManager.getSavedThemeMode();
      expect(mode, ThemeMode.system);
    });

    test('getSavedThemeMode returns light', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'light'});
      final mode = await ThemeManager.getSavedThemeMode();
      expect(mode, ThemeMode.light);
    });

    test('getSavedThemeMode returns dark', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
      final mode = await ThemeManager.getSavedThemeMode();
      expect(mode, ThemeMode.dark);
    });

    test('getSavedThemeMode returns system for explicit system', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'system'});
      final mode = await ThemeManager.getSavedThemeMode();
      expect(mode, ThemeMode.system);
    });

    test('getSavedThemeMode returns system for unknown value', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'unknown'});
      final mode = await ThemeManager.getSavedThemeMode();
      expect(mode, ThemeMode.system);
    });

    test('saveThemeMode persists light mode', () async {
      SharedPreferences.setMockInitialValues({});
      await ThemeManager.saveThemeMode(ThemeMode.light);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme_mode'), 'light');
    });

    test('saveThemeMode persists dark mode', () async {
      SharedPreferences.setMockInitialValues({});
      await ThemeManager.saveThemeMode(ThemeMode.dark);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme_mode'), 'dark');
    });

    test('saveThemeMode persists system mode', () async {
      SharedPreferences.setMockInitialValues({});
      await ThemeManager.saveThemeMode(ThemeMode.system);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme_mode'), 'system');
    });

    test('round-trip: save then load returns same value', () async {
      SharedPreferences.setMockInitialValues({});
      await ThemeManager.saveThemeMode(ThemeMode.dark);
      final mode = await ThemeManager.getSavedThemeMode();
      expect(mode, ThemeMode.dark);
    });

    test('isHighContrastEnabled returns false', () {
      expect(ThemeManager.isHighContrastEnabled(), isFalse);
    });

    test('isReduceMotionEnabled returns false', () {
      expect(ThemeManager.isReduceMotionEnabled(), isFalse);
    });
  });

  // ─── CustomColors ─────────────────────────────────────────────────────
  group('CustomColorsExtension', () {
    test('lightTheme provides custom colors', () {
      final theme = AppTheme.lightTheme;
      final colors = theme.customColors;
      expect(colors.success, isNotNull);
      expect(colors.warning, isNotNull);
      expect(colors.onSuccess, Colors.white);
    });

    test('darkTheme provides custom colors', () {
      final theme = AppTheme.darkTheme;
      final colors = theme.customColors;
      expect(colors.success, isNotNull);
    });

    test('fallback custom colors when extension not registered', () {
      final plainTheme = ThemeData();
      final colors = plainTheme.customColors;
      expect(colors.success, const Color(0xFF198038));
      expect(colors.warning, const Color(0xFFE97500));
    });
  });
}
