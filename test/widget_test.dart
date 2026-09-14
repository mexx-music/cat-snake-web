import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cat_snake/main.dart';

void main() {
  testWidgets('places controls beside the board in landscape', (tester) async {
    await tester.binding.setSurfaceSize(const Size(844, 390));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CatSnakeApp());
    await tester.pump();

    expect(find.text('Cat Snake'), findsOneWidget);
    expect(find.byKey(const Key('game-board')), findsOneWidget);
    expect(find.byKey(const Key('dpad')), findsOneWidget);
    expect(find.byKey(const Key('start-button')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('start-button')), findsOneWidget);

    final boardCenter = tester.getCenter(find.byKey(const Key('game-board')));
    final dPadCenter = tester.getCenter(find.byKey(const Key('dpad')));
    expect(dPadCenter.dx, greaterThan(boardCenter.dx));

    await tester.tap(find.byTooltip('Sound an/aus'));
    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pump();
    expect(find.byKey(const Key('start-button')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
