import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../screens/game_page.dart';
import '../services/analytics_service.dart';
import 'promo_scene.dart';

class PromoCaptureApp extends StatelessWidget {
  const PromoCaptureApp({
    required this.scene,
    this.locale = const Locale('de'),
    super.key,
  });

  final PromoSceneDefinition scene;
  final Locale locale;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
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
      home: GamePage(
        onLocaleChanged: (_) {},
        promoScene: scene,
        analyticsService: const NoopAnalyticsService(),
      ),
    );
  }
}
