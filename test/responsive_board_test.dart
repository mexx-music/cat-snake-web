import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cat_snake/main.dart';

void main() {
  testWidgets('small portrait phone renders a real 14 by 22 board',
      (tester) async {
    SharedPreferences.setMockInitialValues({'cat_snake_language': 'de'});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const CatSnakeApp());
    await tester.pump();

    final painter = _boardPainter(tester);
    expect(painter.cols, 14);
    expect(painter.rows, 22);
    expect(tester.getSize(find.byKey(const Key('game-board'))).height,
        greaterThan(tester.getSize(find.byKey(const Key('game-board'))).width));
    _expectValidEntities(painter);
    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tablet portrait keeps the legacy 22 by 16 board',
      (tester) async {
    SharedPreferences.setMockInitialValues({'cat_snake_language': 'de'});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(820, 1180);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const CatSnakeApp());
    await tester.pump();

    final painter = _boardPainter(tester);
    expect(painter.cols, 22);
    expect(painter.rows, 16);
    _expectValidEntities(painter);
    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('phone landscape keeps the legacy 22 by 16 board',
      (tester) async {
    SharedPreferences.setMockInitialValues({'cat_snake_language': 'de'});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(844, 390);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const CatSnakeApp());
    await tester.pump();

    final painter = _boardPainter(tester);
    expect(painter.cols, 22);
    expect(painter.rows, 16);
    _expectValidEntities(painter);
    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

dynamic _boardPainter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .singleWhere(
      (paint) => paint.painter.runtimeType.toString() == '_BoardPainter',
    )
    .painter;

void _expectValidEntities(dynamic painter) {
  final cols = painter.cols as int;
  final rows = painter.rows as int;
  final obstacles = painter.obstacles as Set<Point<int>>;
  final snake = painter.snake as List<Point<int>>;
  final food = painter.food as Point<int>?;
  final mouse = painter.mouse as Point<int>?;

  bool isInside(Point<int> point) =>
      point.x >= 0 && point.x < cols && point.y >= 0 && point.y < rows;

  expect(obstacles.every(isInside), isTrue);
  expect(snake.every(isInside), isTrue);
  expect(food, isNotNull);
  expect(mouse, isNotNull);
  expect(isInside(food!), isTrue);
  expect(isInside(mouse!), isTrue);
  expect(obstacles.contains(food), isFalse);
  expect(obstacles.contains(mouse), isFalse);
  expect(snake.contains(food), isFalse);
  expect(snake.contains(mouse), isFalse);
  expect(food, isNot(mouse));
}
