import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cat_snake/promo/promo_capture_app.dart';
import 'package:cat_snake/promo/promo_scene.dart';

void main() {
  testWidgets('all promo scenes render without changing normal gameplay',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(720, 1280));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    for (final scene in PromoSceneDefinition.all) {
      await tester.pumpWidget(
        PromoCaptureApp(scene: scene, locale: const Locale('de')),
      );
      await tester.pump();
      await tester.pump(
        Duration(milliseconds: scene.showGameOver ? 650 : 80),
      );
      expect(find.byKey(const Key('game-board')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: scene.id);
      await tester.pumpWidget(const SizedBox.shrink());
    }

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('promo demo follows its deterministic turn sequence',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(720, 1280));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const PromoCaptureApp(
        scene: PromoSceneDefinition.demo,
        locale: Locale('de'),
      ),
    );
    await tester.pump();
    for (var frame = 0; frame < 65; frame += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final boardPaint =
        tester.widgetList<CustomPaint>(find.byType(CustomPaint)).singleWhere(
              (paint) =>
                  paint.painter.runtimeType.toString() == '_BoardPainter',
            );
    expect(
      (boardPaint.painter as dynamic).direction.toString(),
      'Direction.down',
    );
    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
