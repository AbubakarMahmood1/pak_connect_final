import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'presentation/screens/permission_screen.dart';
import 'presentation/screens/chats_screen.dart';

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
      home: AppBootstrap(), // 🆕 Smart permission check
    );
  }
}

// 🆕 Smart startup screen that checks permissions first
class AppBootstrap extends ConsumerStatefulWidget {
  @override
  ConsumerState<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends ConsumerState<AppBootstrap> {
  bool _isChecking = true;
  bool _needsPermissions = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    try {
      bool needsPermission = false;

      if (Platform.isAndroid) {
        final deviceInfo = DeviceInfoPlugin();
        final androidInfo = await deviceInfo.androidInfo;
        
        List<Permission> requiredPermissions = [];
        
        if (androidInfo.version.sdkInt >= 31) {
          // Android 12+ - check granular BLE permissions
          requiredPermissions = [
            Permission.bluetoothScan,
            Permission.bluetoothAdvertise,
            Permission.bluetoothConnect,
          ];
        } else {
          // Android < 12 - check location permission
          requiredPermissions = [
            Permission.locationWhenInUse,
          ];
        }
        
        for (final permission in requiredPermissions) {
          final status = await permission.status;
          if (!status.isGranted) {
            needsPermission = true;
            break;
          }
        }
      }
      // iOS handles permissions automatically, no check needed
      
      if (mounted) {
        setState(() {
          _needsPermissions = needsPermission;
          _isChecking = false;
        });
      }
    } catch (e) {
      print('Permission check failed: $e');
      // On error, assume permissions needed to be safe
      if (mounted) {
        setState(() {
          _needsPermissions = true;
          _isChecking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      // Show loading while checking permissions
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.bluetooth,
                  size: 60,
                  color: Colors.white,
                ),
              ),
              SizedBox(height: 32),
              Text(
                'BLE Chat',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 32),
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text(
                'Checking permissions...',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }

    // Navigate based on permission status
    if (_needsPermissions) {
      return PermissionScreen();
    } else {
      return ChatsScreen();
    }
  }
}