import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'test_helpers/test_setup.dart';

/// Ensures every test suite boots through the shared harness before executing.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final scriptPath = Platform.script.toFilePath();
  final label = _sanitizeLabel(p.basenameWithoutExtension(scriptPath));

  await TestSetup.initializeTestEnvironment(dbLabel: label);
  try {
    await testMain();
  } finally {
    await TestSetup.completeCleanup();
  }
}

String _sanitizeLabel(String input) =>
    input.replaceAll(RegExp('[^a-zA-Z0-9_]'), '_');
