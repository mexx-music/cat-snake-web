import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:cat_snake/constants/game_constants.dart';
import 'package:cat_snake/game/board_geometry.dart';

void main() {
  group('responsive board selection', () {
    test('small portrait phones use the portrait grid', () {
      expect(
        BoardGeometry.forViewport(const Size(390, 844)).layout,
        BoardLayout.phonePortrait,
      );
      expect(
        BoardGeometry.forViewport(const Size(430, 932)).layout,
        BoardLayout.phonePortrait,
      );
      expect(
        BoardGeometry.forViewport(const Size(412, 915)).layout,
        BoardLayout.phonePortrait,
      );
    });

    test('tablet, landscape and desktop keep the standard grid', () {
      expect(
        BoardGeometry.forViewport(const Size(820, 1180)).layout,
        BoardLayout.standard,
      );
      expect(
        BoardGeometry.forViewport(const Size(844, 390)).layout,
        BoardLayout.standard,
      );
      expect(
        BoardGeometry.forViewport(const Size(1440, 900)).layout,
        BoardLayout.standard,
      );
    });

    test('grid dimensions and the legacy standard layout stay stable', () {
      expect(BoardGeometry.standard.cols, 22);
      expect(BoardGeometry.standard.rows, 16);
      expect(BoardGeometry.phonePortrait.cols, 14);
      expect(BoardGeometry.phonePortrait.rows, 22);

      expect(
        BoardGeometry.standard.obstaclesFor(GameLevel.livingRoom),
        containsAll([
          const Point<int>(3, 3),
          const Point<int>(5, 4),
          const Point<int>(16, 10),
          const Point<int>(18, 11),
        ]),
      );
      expect(
        BoardGeometry.standard.obstaclesFor(GameLevel.garden),
        containsAll([
          const Point<int>(4, 3),
          const Point<int>(5, 5),
          const Point<int>(16, 3),
          const Point<int>(18, 4),
          const Point<int>(11, 13),
        ]),
      );
    });
  });

  group('board coordinate safety', () {
    for (final geometry in [
      BoardGeometry.standard,
      BoardGeometry.phonePortrait,
    ]) {
      test('${geometry.layout.name} keeps all level obstacles in bounds', () {
        for (final level in GameLevel.values) {
          final obstacles = geometry.obstaclesFor(level);
          expect(obstacles.every(geometry.contains), isTrue);
          expect(
            geometry.cols * geometry.rows - obstacles.length,
            greaterThanOrEqualTo(280),
          );
          expect(obstacles.contains(geometry.initialHead), isFalse);

          final freeCells = {
            for (var x = 0; x < geometry.cols; x += 1)
              for (var y = 0; y < geometry.rows; y += 1)
                if (!obstacles.contains(Point<int>(x, y))) Point<int>(x, y),
          };
          final visited = <Point<int>>{};
          final pending = <Point<int>>[freeCells.first];
          while (pending.isNotEmpty) {
            final current = pending.removeLast();
            if (!visited.add(current)) continue;
            for (final offset in const [
              Point<int>(1, 0),
              Point<int>(-1, 0),
              Point<int>(0, 1),
              Point<int>(0, -1),
            ]) {
              final neighbor = Point<int>(
                current.x + offset.x,
                current.y + offset.y,
              );
              if (freeCells.contains(neighbor) && !visited.contains(neighbor)) {
                pending.add(neighbor);
              }
            }
          }
          expect(
            visited.length,
            freeCells.length,
            reason: '${geometry.layout.name}/${level.name} must stay connected',
          );
        }
      });

      test('${geometry.layout.name} applies collision bounds and wrapping', () {
        expect(geometry.contains(const Point<int>(0, 0)), isTrue);
        expect(
          geometry.contains(Point<int>(geometry.cols - 1, geometry.rows - 1)),
          isTrue,
        );
        expect(geometry.contains(Point<int>(geometry.cols, 0)), isFalse);
        expect(geometry.contains(Point<int>(0, geometry.rows)), isFalse);
        expect(geometry.contains(const Point<int>(-1, 0)), isFalse);
        expect(
          geometry.wrap(const Point<int>(-1, -1)),
          Point<int>(geometry.cols - 1, geometry.rows - 1),
        );
        expect(
          geometry.wrap(Point<int>(geometry.cols, geometry.rows)),
          const Point<int>(0, 0),
        );
      });
    }
  });
}
