// lib/main.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'l10n/generated/app_localizations.dart';
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

class CatSnakeApp extends StatefulWidget {
  const CatSnakeApp({super.key});

  @override
  State<CatSnakeApp> createState() => _CatSnakeAppState();
}

class _CatSnakeAppState extends State<CatSnakeApp> {
  static const _languageKey = 'cat_snake_language';
  Locale? _locale;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLocale());
  }

  Future<void> _loadLocale() async {
    final preferences = await SharedPreferences.getInstance();
    final languageCode = preferences.getString(_languageKey);
    if (!mounted || (languageCode != 'de' && languageCode != 'en')) return;
    setState(() => _locale = Locale(languageCode!));
  }

  Future<void> _setLocale(Locale locale) async {
    if (locale == _locale) return;
    setState(() => _locale = locale);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_languageKey, locale.languageCode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      debugShowCheckedModeBanner: false,
      locale: _locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      localeResolutionCallback: (deviceLocale, supportedLocales) =>
          deviceLocale?.languageCode == 'de'
              ? const Locale('de')
              : const Locale('en'),
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
      home: GamePage(onLocaleChanged: _setLocale),
    );
  }
}
