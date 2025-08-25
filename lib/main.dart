import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'dart:io' show Platform;
import 'presentation/screens/permission_screen.dart';
import 'package:flutter/services.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  hierarchicalLoggingEnabled = true;
  
  // Set up logging to filter out Windows threading errors
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
  final message = record.message;
  
  // Filter out all the spam logs
  if (message.contains('platform thread') ||
      message.contains('gralloc4') ||
      message.contains('@set_metadata') ||
      message.contains('FrameInsert open fail') ||
      message.contains('MirrorManager') ||
      message.contains('libEGL') ||
      message.contains('PerfMonitor') ||
      message.contains('WindowOnBackDispatcher')) {
    return; // Skip these spam logs
  }
  
  print('${record.level.name}: ${record.time}: ${record.message}');
});
  
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Chat',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: PermissionScreen(),
    );
  }
}