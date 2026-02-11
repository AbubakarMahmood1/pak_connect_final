// Re-export the core test harness implementation.
//
// This keeps legacy imports stable for suites under `test/` while allowing
// the actual implementation (which imports core DI modules) to live under
// `test/core/**` for layer-boundary checks.
export '../core/test_helpers/test_setup.dart';
