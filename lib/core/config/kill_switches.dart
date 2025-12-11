/// Runtime kill switches to simplify debugging/triage.
///
/// Defaults are all `false` (features enabled). Toggle to true to disable
/// specific subsystems without ripping code paths apart.
class KillSwitches {
  static bool disableHealthChecks = false;
  static bool disableQueueSync = false;
  static bool disableAutoConnect = false;
}
