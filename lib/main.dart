import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_handler.dart';
import 'dashboard_screen.dart';

late MyAudioHandler audioHandler;
late AudioPlayer windowsPlayer;

sherpa.OfflineTts? globalTts;
String? globalCurrentModelId;

/// Global theme mode notifier — 0 = system, 1 = light, 2 = dark.
final ValueNotifier<int> appThemeNotifier = ValueNotifier<int>(0);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    sherpa.initBindings();
  } catch (e) {
    debugPrint('[START_ERROR] Bindings fail: $e');
  }

  final prefs = await SharedPreferences.getInstance();
  appThemeNotifier.value = prefs.getInt('theme_mode') ?? 0;

  final bool isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  if (isMobile) {
    audioHandler = await AudioService.init(
      builder: () => MyAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.free_voice_reader.channel.audio',
        androidNotificationChannelName: 'Čtečka souborů',
        androidNotificationOngoing: true,
        androidShowNotificationBadge: true,
      ),
    );
  } else {
    windowsPlayer = AudioPlayer();
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: appThemeNotifier,
      builder: (context, themeMode, child) {
        final ThemeMode mode = themeMode == 1
            ? ThemeMode.light
            : themeMode == 2
            ? ThemeMode.dark
            : ThemeMode.system;

        return MaterialApp(
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFF1A73E8),
            scaffoldBackgroundColor: const Color(0xFFF8F9FA),
            cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorSchemeSeed: const Color(0xFF1A73E8),
            scaffoldBackgroundColor: const Color(0xFF121212),
            cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
          ),
          home: const DashboardScreen(),
        );
      },
    );
  }
}