/// Interface for preferences repository operations
///
/// Abstracts user preferences storage and retrieval to enable:
/// - Dependency injection
/// - Test mocking
/// - Alternative implementations
abstract class IPreferencesRepository {
  /// Get string preference
  Future<String?> getString(String key, {String? defaultValue});

  /// Set string preference
  Future<void> setString(String key, String value);

  /// Get boolean preference
  Future<bool?> getBool(String key, {bool? defaultValue});

  /// Set boolean preference
  Future<void> setBool(String key, bool value);

  /// Get integer preference
  Future<int?> getInt(String key, {int? defaultValue});

  /// Set integer preference
  Future<void> setInt(String key, int value);

  /// Get double preference
  Future<double?> getDouble(String key, {double? defaultValue});

  /// Set double preference
  Future<void> setDouble(String key, double value);

  /// Delete a preference
  Future<void> delete(String key);

  /// Clear all preferences
  Future<void> clearAll();

  /// Get all preferences
  Future<Map<String, dynamic>> getAll();
}
