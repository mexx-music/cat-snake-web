import 'package:flutter_test/flutter_test.dart';

import 'package:cat_snake/game/game_collision.dart';

void main() {
  test('solid board boundary ends the round with wall', () {
    expect(
      collisionEndReason(
        wrapWalls: false,
        isInsideBoard: false,
        hitsObstacle: false,
        hitsSelf: false,
      ),
      GameEndReason.wall,
    );
  });

  test('obstacle collision ends the round with obstacle', () {
    expect(
      collisionEndReason(
        wrapWalls: false,
        isInsideBoard: true,
        hitsObstacle: true,
        hitsSelf: false,
      ),
      GameEndReason.obstacle,
    );
  });

  test('snake body collision ends the round with self', () {
    expect(
      collisionEndReason(
        wrapWalls: true,
        isInsideBoard: true,
        hitsObstacle: false,
        hitsSelf: true,
      ),
      GameEndReason.self,
    );
  });

  test('safe wrapped move does not end the round', () {
    expect(
      collisionEndReason(
        wrapWalls: true,
        isInsideBoard: true,
        hitsObstacle: false,
        hitsSelf: false,
      ),
      isNull,
    );
  });
}
