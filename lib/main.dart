// lib/main.dart
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'firebase_options.dart';
import 'screens/game_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (kIsWeb) {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (error) {
      debugPrint('Firebase konnte nicht initialisiert werden: $error');
    }
  }

  // Optional, aber hilfreich: Audio-Kontext (Mix mit anderen Apps, Game-Usage etc.)
  await AudioPlayer.global.setAudioContext(
    const AudioContext(
      android: AudioContextAndroid(
        contentType: AndroidContentType.music,
        usageType: AndroidUsageType.game,
        audioFocus: AndroidAudioFocus.gainTransientMayDuck,
      ),
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.ambient,
        options: [AVAudioSessionOptions.mixWithOthers],
      ),
    ),
  );

  runApp(const CatSnakeApp());
}

class CatSnakeApp extends StatelessWidget {
  const CatSnakeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cat Snake',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF203A43),
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
      ),
      home: const GamePage(),
    );
  }
}
