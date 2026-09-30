import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show kIsWeb;

class DefaultFirebaseOptions {
  const DefaultFirebaseOptions._();

  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    throw UnsupportedError(
      'Firebase ist für Cat Snake derzeit nur im Web konfiguriert.',
    );
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBVVg14IHDEkFlyYuv4TXR7soyv-FUiYKU',
    appId: '1:968841719648:web:5450172dbfae8b2163b805',
    messagingSenderId: '968841719648',
    projectId: 'cat-snake',
    authDomain: 'cat-snake.firebaseapp.com',
    storageBucket: 'cat-snake.firebasestorage.app',
    measurementId: 'G-R5V7D9PPKS',
  );
}
