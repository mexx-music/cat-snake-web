import 'package:flutter/material.dart';

import 'promo_capture_app.dart';
import 'promo_scene.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final scene = PromoSceneDefinition.byId(
    Uri.base.queryParameters['scene'] ?? 'long-snake',
  );
  final language = Uri.base.queryParameters['lang'] == 'en' ? 'en' : 'de';
  runApp(PromoCaptureApp(scene: scene, locale: Locale(language)));
}
