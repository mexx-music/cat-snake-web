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

    final boardPaint = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .singleWhere(
            (paint) => paint.painter.runtimeType.toString() == '_BoardPainter');
    final movement =
        (boardPaint.painter as dynamic).movement as Animation<double>;

    // Der bildschirmgetaktete Lauf bewegt sich auf jedem Frame weiter und
    // beginnt am Feldwechsel ohne Stillstand direkt mit dem nächsten Weg.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final beforeFieldChange = movement.value;
    expect(beforeFieldChange, greaterThan(0.5));

    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final afterFieldChange = movement.value;
    expect(afterFieldChange, lessThan(beforeFieldChange));

    await tester.pump(const Duration(milliseconds: 16));
    expect(movement.value, greaterThan(afterFieldChange));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
