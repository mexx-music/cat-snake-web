import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cat_snake/audio/web_sfx_engine.dart';

void main() {
  testWidgets('handles all web sound effects without errors', (tester) async {
    final engine = WebSfxEngine();
    late Future<void> unlock;

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: FilledButton(
            onPressed: () => unlock = engine.unlock(),
            child: const Text('Audio starten'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Audio starten'));
    await tester.pump(const Duration(seconds: 2));
    await unlock;
    engine.playEat();
    engine.playMouse();
    engine.playGameOver();
    await tester.pump(const Duration(seconds: 2));
    final disposing = engine.dispose();
    await tester.pump(const Duration(seconds: 2));
    await disposing;

    expect(tester.takeException(), isNull);
  });
}
