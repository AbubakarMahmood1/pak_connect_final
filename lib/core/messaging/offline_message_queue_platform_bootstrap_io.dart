import 'dart:io';

import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite_ffi;

Future<void> ensureOfflineQueueDatabaseFactoryReady() async {
  if (Platform.isAndroid || Platform.isIOS) {
    return;
  }

  if (sqflite_common.databaseFactory != sqflite_ffi.databaseFactoryFfi) {
    sqflite_ffi.sqfliteFfiInit();
    sqflite_common.databaseFactory = sqflite_ffi.databaseFactoryFfi;
  }
}
