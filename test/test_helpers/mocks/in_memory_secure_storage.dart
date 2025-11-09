import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';

/// Minimal in-memory implementation of [FlutterSecureStoragePlatform] for tests.
///
/// The production plugin relies on a MethodChannel that is unavailable inside
/// `flutter test`. Register this class via
/// `FlutterSecureStoragePlatform.instance = InMemorySecureStorage();` to avoid
/// `MissingPluginException` when code under test uses [FlutterSecureStorage].
class InMemorySecureStorage extends FlutterSecureStoragePlatform {
  final Map<String, Map<String, String>> _namespacedStorage = {};

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    _bucket(options)[key] = value;
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    return _bucket(options)[key];
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async {
    return _bucket(options).containsKey(key);
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    _bucket(options).remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async {
    return Map<String, String>.from(_bucket(options));
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    _bucket(options).clear();
  }

  Map<String, String> _bucket(Map<String, String> options) {
    final namespace = _namespace(options);
    return _namespacedStorage.putIfAbsent(namespace, () => <String, String>{});
  }

  String _namespace(Map<String, String> options) {
    if (options.isEmpty) return 'default';
    final sorted = options.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return sorted.map((entry) => '${entry.key}:${entry.value}').join('|');
  }
}
