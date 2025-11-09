import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

/// Ensures the sqlite3 dynamic library can be located inside sandboxed tests.
///
/// sqflite_common_ffi expects `libsqlite3.so` / `sqlite3.dll` to be present on
/// the host system. In constrained CI environments that library might live at a
/// different path or be missing the unversioned symlink (`libsqlite3.so`), so
/// we proactively point sqlite3 at a known-good path.
class NativeSqliteLoader {
  static bool _configured = false;

  /// Registers a deterministic sqlite3 loader for the current platform.
  ///
  /// Safe to call multiple times; the override is only applied once per process
  /// and per isolate (sqflite_common_ffi runs inside its own isolate).
  static void ensureInitialized() {
    if (_configured) return;

    final os = _detectOperatingSystem();
    final opener = _resolveDynamicLibraryOpener();

    if (os != null && opener != null) {
      open.overrideFor(os, opener);
    } else if (opener == null) {
      // ignore: avoid_print
      print(
        '⚠️ NativeSqliteLoader: Unable to locate sqlite3 dynamic library. '
        'Falling back to system defaults.',
      );
    }

    _configured = true;
  }

  static OperatingSystem? _detectOperatingSystem() {
    if (Platform.isLinux) return OperatingSystem.linux;
    if (Platform.isMacOS) return OperatingSystem.macOS;
    if (Platform.isWindows) return OperatingSystem.windows;
    return null;
  }

  static DynamicLibrary Function()? _resolveDynamicLibraryOpener() {
    final envPath = Platform.environment['SQLITE_FFI_LIB_PATH'];
    final workspaceRoot = Directory.current.path;

    final candidates = <String>[
      if (envPath != null && envPath.isNotEmpty) envPath,
    ];

    if (Platform.isLinux) {
      candidates.addAll([
        p.join(
          workspaceRoot,
          'third_party',
          'sqlite',
          'linux-x64',
          'libsqlite3.so',
        ),
        '/usr/lib/x86_64-linux-gnu/libsqlite3.so',
        '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
        '/lib/x86_64-linux-gnu/libsqlite3.so.0',
      ]);
    } else if (Platform.isMacOS) {
      candidates.addAll([
        p.join(
          workspaceRoot,
          'third_party',
          'sqlite',
          'macos',
          'libsqlite3.dylib',
        ),
        '/usr/lib/libsqlite3.dylib',
      ]);
    } else if (Platform.isWindows) {
      candidates.addAll([
        p.join(
          workspaceRoot,
          'third_party',
          'sqlite',
          'windows-x64',
          'sqlite3.dll',
        ),
        r'C:\Windows\System32\sqlite3.dll',
      ]);
    }

    for (final path in candidates) {
      final resolved = _resolveIfExists(path);
      if (resolved != null) {
        return () => DynamicLibrary.open(resolved);
      }
    }
    return null;
  }

  static String? _resolveIfExists(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      return file.resolveSymbolicLinksSync();
    } catch (_) {
      return file.path;
    }
  }
}
