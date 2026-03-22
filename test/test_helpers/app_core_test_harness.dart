// Re-export AppCore for non-core test folders.
//
// This keeps the direct core implementation import out of suites under
// `test/` while preserving stable test access to AppCore controls.
export 'package:pak_connect/core/app_core.dart';
