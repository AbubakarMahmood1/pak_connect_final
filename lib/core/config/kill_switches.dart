/// Runtime kill switches to simplify debugging/triage.
///
/// Defaults are all `false` (features enabled). Toggle to true to disable
/// specific subsystems without ripping code paths apart.
import 'package:pak_connect/domain/entities/preference_keys.dart';

class KillSwitches {
  static bool disableHealthChecks = false;
  static bool disableQueueSync = false;
  static bool disableAutoConnect = false;
  static bool disableDualRoleAuto = false;
  static bool disableDiscoveryScheduler = false;

  /// Load persisted values (SharedPreferences-backed PreferencesRepository).
  static Future<void> load({
    required Future<bool> Function(String key, {bool defaultValue}) getBool,
  }) async {
    disableHealthChecks = await getBool(
      PreferenceKeys.killSwitchHealthChecks,
      defaultValue: false,
    );
    disableQueueSync = await getBool(
      PreferenceKeys.killSwitchQueueSync,
      defaultValue: false,
    );
    disableAutoConnect = await getBool(
      PreferenceKeys.killSwitchAutoConnect,
      defaultValue: false,
    );
    disableDualRoleAuto = await getBool(
      PreferenceKeys.killSwitchDualRole,
      defaultValue: false,
    );
    disableDiscoveryScheduler = await getBool(
      PreferenceKeys.killSwitchDiscoveryScheduler,
      defaultValue: false,
    );
  }

  /// Persist and apply toggles at runtime.
  static Future<void> set({
    required Future<void> Function(String key, bool value) setBool,
    bool? healthChecks,
    bool? queueSync,
    bool? autoConnect,
    bool? dualRole,
    bool? discoveryScheduler,
  }) async {
    if (healthChecks != null) {
      disableHealthChecks = healthChecks;
      await setBool(PreferenceKeys.killSwitchHealthChecks, healthChecks);
    }
    if (queueSync != null) {
      disableQueueSync = queueSync;
      await setBool(PreferenceKeys.killSwitchQueueSync, queueSync);
    }
    if (autoConnect != null) {
      disableAutoConnect = autoConnect;
      await setBool(PreferenceKeys.killSwitchAutoConnect, autoConnect);
    }
    if (dualRole != null) {
      disableDualRoleAuto = dualRole;
      await setBool(PreferenceKeys.killSwitchDualRole, dualRole);
    }
    if (discoveryScheduler != null) {
      disableDiscoveryScheduler = discoveryScheduler;
      await setBool(PreferenceKeys.killSwitchDiscoveryScheduler, discoveryScheduler);
    }
  }
}
