class PanicWipeRuntimeBridge {
  PanicWipeRuntimeBridge._();

  static Future<void> Function()? _disposeAppCore;
  static Future<void> Function()? _shutdownSecurityManager;
  static Future<void> Function()? _resetAppCoreSingleton;
  static Future<void> Function()? _initializeAppCore;

  static void configure({
    required Future<void> Function() disposeAppCore,
    required Future<void> Function() shutdownSecurityManager,
    required Future<void> Function() resetAppCoreSingleton,
    required Future<void> Function() initializeAppCore,
  }) {
    _disposeAppCore = disposeAppCore;
    _shutdownSecurityManager = shutdownSecurityManager;
    _resetAppCoreSingleton = resetAppCoreSingleton;
    _initializeAppCore = initializeAppCore;
  }

  static Future<void> disposeAppCore() async {
    final action = _disposeAppCore;
    if (action == null) {
      throw StateError(
        'Panic wipe runtime bridge is not configured for app-core disposal.',
      );
    }
    await action();
  }

  static Future<void> shutdownSecurityManager() async {
    final action = _shutdownSecurityManager;
    if (action == null) {
      throw StateError(
        'Panic wipe runtime bridge is not configured for security shutdown.',
      );
    }
    await action();
  }

  static Future<void> resetAppCoreSingleton() async {
    final action = _resetAppCoreSingleton;
    if (action == null) {
      throw StateError(
        'Panic wipe runtime bridge is not configured for app-core reset.',
      );
    }
    await action();
  }

  static Future<void> initializeAppCore() async {
    final action = _initializeAppCore;
    if (action == null) {
      throw StateError(
        'Panic wipe runtime bridge is not configured for app-core initialization.',
      );
    }
    await action();
  }
}
