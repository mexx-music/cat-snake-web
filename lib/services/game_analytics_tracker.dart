import 'dart:async';

import '../game/game_collision.dart';
import 'analytics_service.dart';

abstract interface class MonotonicClock {
  Duration get elapsed;
}

class StopwatchMonotonicClock implements MonotonicClock {
  StopwatchMonotonicClock() {
    _stopwatch.start();
  }

  final Stopwatch _stopwatch = Stopwatch();

  @override
  Duration get elapsed => _stopwatch.elapsed;
}

class GameAnalyticsTracker {
  GameAnalyticsTracker(
    this._service, {
    MonotonicClock? clock,
  }) : _clock = clock ?? StopwatchMonotonicClock();

  final AnalyticsService _service;
  final MonotonicClock _clock;

  GameStartAnalyticsEvent? _round;
  Duration _activeDuration = Duration.zero;
  Duration? _activeSince;
  bool _gameOverLogged = false;

  bool get hasActiveRound => _round != null;

  void startRound(GameStartAnalyticsEvent event) {
    if (hasActiveRound) return;
    _round = event;
    _activeDuration = Duration.zero;
    _activeSince = _clock.elapsed;
    _gameOverLogged = false;
    unawaited(_runSafely(() => _service.logGameStart(event)));
  }

  void pauseRound() {
    final activeSince = _activeSince;
    if (!hasActiveRound || activeSince == null) return;
    _activeDuration += _clock.elapsed - activeSince;
    _activeSince = null;
  }

  void resumeRound() {
    if (!hasActiveRound || _activeSince != null) return;
    _activeSince = _clock.elapsed;
  }

  void endRound({
    required int score,
    required int snakeLength,
    required GameEndReason endReason,
  }) {
    final round = _round;
    if (round == null || _gameOverLogged) return;
    _gameOverLogged = true;
    pauseRound();

    final event = GameOverAnalyticsEvent(
      levelName: round.levelName,
      levelIndex: round.levelIndex,
      score: score,
      snakeLength: snakeLength,
      roundDurationSeconds: _activeDuration.inSeconds,
      endReason: endReason,
    );
    _round = null;
    _activeSince = null;
    unawaited(_runSafely(() => _service.logGameOver(event)));
  }

  void cancelRound() {
    _round = null;
    _activeDuration = Duration.zero;
    _activeSince = null;
    _gameOverLogged = false;
  }

  Future<void> _runSafely(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Analytics must never affect gameplay, even when a fake or a future
      // service implementation throws outside its own error handling.
    }
  }
}
