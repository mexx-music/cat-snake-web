enum GameEndReason { wall, self, obstacle }

/// Returns the reason why a proposed move ends the round.
///
/// The order mirrors the gameplay rules: a solid board boundary is evaluated
/// before obstacles and the snake body. Wrapped moves are already translated
/// back into the board before this function is called.
GameEndReason? collisionEndReason({
  required bool wrapWalls,
  required bool isInsideBoard,
  required bool hitsObstacle,
  required bool hitsSelf,
}) {
  if (!wrapWalls && !isInsideBoard) return GameEndReason.wall;
  if (hitsObstacle) return GameEndReason.obstacle;
  if (hitsSelf) return GameEndReason.self;
  return null;
}
