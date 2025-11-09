import 'package:pak_connect/core/utils/string_extensions.dart';

/// Provides safe preview helpers for logging sensitive identifiers.
extension StringShortIdExtension on String {
  /// Returns the first [maxChars] characters without throwing when the string
  /// is shorter than the requested length. When [maxChars] is zero or negative,
  /// an empty string is returned.
  String shortId([int maxChars = 16]) {
    if (isEmpty || maxChars <= 0) {
      return '';
    }
    if (length <= maxChars) {
      return this;
    }
    return substring(0, maxChars);
  }
}

extension NullableStringShortIdExtension on String? {
  /// Null-safe wrapper that returns an empty string when the source is null.
  String shortIdOrEmpty([int maxChars = 16]) =>
      this == null ? '' : this!.shortId(maxChars);
}
