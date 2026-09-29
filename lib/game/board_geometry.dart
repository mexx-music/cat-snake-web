import 'dart:math';
import 'dart:ui';

import '../constants/game_constants.dart';

enum BoardLayout { standard, phonePortrait }

/// Central logical board definition. Rendering derives the cell size from
/// these dimensions; gameplay, spawning and collision checks use the same
/// coordinate space.
class BoardGeometry {
  const BoardGeometry._({
    required this.layout,
    required this.cols,
    required this.rows,
  });

  static const double phonePortraitMaxWidth = 600;
  static const double phonePortraitMinAspectRatio = 1.35;

  static const standard = BoardGeometry._(
    layout: BoardLayout.standard,
    cols: 22,
    rows: 16,
  );

  static const phonePortrait = BoardGeometry._(
    layout: BoardLayout.phonePortrait,
    cols: 14,
    rows: 22,
  );

  final BoardLayout layout;
  final int cols;
  final int rows;

  static BoardGeometry forViewport(Size viewport) {
    final isPortrait = viewport.height > viewport.width;
    final aspectRatio = viewport.height / viewport.width;
    final isSmallPhone = viewport.width <= phonePortraitMaxWidth;
    return isPortrait &&
            isSmallPhone &&
            aspectRatio >= phonePortraitMinAspectRatio
        ? phonePortrait
        : standard;
  }

  Point<int> get initialHead => Point<int>(cols ~/ 2 - 1, rows ~/ 2);

  bool contains(Point<int> point) =>
      point.x >= 0 && point.x < cols && point.y >= 0 && point.y < rows;

  Point<int> wrap(Point<int> point) => Point<int>(
        (point.x + cols) % cols,
        (point.y + rows) % rows,
      );

  Set<Point<int>> obstaclesFor(GameLevel level) {
    if (level == GameLevel.meadow) return {};

    return switch ((layout, level)) {
      (BoardLayout.standard, GameLevel.livingRoom) => {
          for (var x = 3; x <= 5; x++)
            for (var y = 3; y <= 4; y++) Point<int>(x, y),
          for (var x = 16; x <= 18; x++)
            for (var y = 10; y <= 11; y++) Point<int>(x, y),
        },
      (BoardLayout.standard, GameLevel.garden) => {
          for (var x = 4; x <= 5; x++)
            for (var y = 3; y <= 5; y++) Point<int>(x, y),
          for (var x = 16; x <= 18; x++)
            for (var y = 3; y <= 4; y++) Point<int>(x, y),
          for (var y = 11; y <= 13; y++) Point<int>(11, y),
        },
      (BoardLayout.phonePortrait, GameLevel.livingRoom) => {
          for (var x = 2; x <= 4; x++)
            for (var y = 4; y <= 5; y++) Point<int>(x, y),
          for (var x = 9; x <= 11; x++)
            for (var y = 15; y <= 16; y++) Point<int>(x, y),
        },
      (BoardLayout.phonePortrait, GameLevel.garden) => {
          for (var x = 2; x <= 3; x++)
            for (var y = 4; y <= 6; y++) Point<int>(x, y),
          for (var x = 10; x <= 11; x++)
            for (var y = 4; y <= 6; y++) Point<int>(x, y),
          for (var y = 15; y <= 17; y++) Point<int>(6, y),
        },
      _ => {},
    };
  }
}
