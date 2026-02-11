import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Mock implementation of FlutterSecureStorage for testing
///
/// This mock provides an in-memory storage that mimics FlutterSecureStorage behavior
/// without requiring platform-specific implementations. Perfect for unit tests.
class MockFlutterSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _storage = {};
  final Map<String, List<void Function(String?)>> _listeners = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _storage.remove(key);
    } else {
      _storage[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.remove(key);
  }

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.clear();
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return Map<String, String>.from(_storage);
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage.containsKey(key);
  }

  @override
  Future<bool> isCupertinoProtectedDataAvailable() async {
    return true; // Mock always returns true for testing
  }

  @override
  void registerListener({
    required String key,
    required void Function(String?) listener,
  }) {
    _listeners[key] = [...(_listeners[key] ?? const []), listener];
  }

  @override
  void unregisterAllListeners() {
    _listeners.clear();
  }

  @override
  void unregisterAllListenersForKey({required String key}) {
    _listeners.remove(key);
  }

  @override
  void unregisterListener({
    required String key,
    required void Function(String?) listener,
  }) {
    final listeners = _listeners[key];
    if (listeners == null) return;
    listeners.remove(listener);
    if (listeners.isEmpty) {
      _listeners.remove(key);
    }
  }

  @override
  Stream<bool>? get onCupertinoProtectedDataAvailabilityChanged {
    // Mock implementation - return empty stream for testing
    return Stream.empty();
  }

  @override
  AndroidOptions get aOptions => AndroidOptions();

  @override
  IOSOptions get iOptions => IOSOptions();

  @override
  LinuxOptions get lOptions => LinuxOptions();

  @override
  MacOsOptions get mOptions => MacOsOptions();

  @override
  WebOptions get webOptions => WebOptions();

  @override
  WindowsOptions get wOptions => WindowsOptions();

  @override
  Map<String, List<void Function(String?)>> get getListeners =>
      Map.unmodifiable(_listeners);

  // Additional helper methods for testing

  /// Clear all stored values (useful in tearDown)
  void clear() {
    _storage.clear();
  }

  /// Pre-populate storage with test data
  void seed(Map<String, String> data) {
    _storage.addAll(data);
  }

  /// Get all keys (for debugging)
  Set<String> get keys => _storage.keys.toSet();

  /// Check if storage is empty
  bool get isEmpty => _storage.isEmpty;

  /// Get number of stored items
  int get length => _storage.length;
}
