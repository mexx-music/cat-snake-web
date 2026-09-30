import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

import '../constants/game_constants.dart';
import '../game/board_geometry.dart';
import '../game/game_collision.dart';

String analyticsLevelName(GameLevel level) => switch (level) {
      GameLevel.meadow => 'meadow',
      GameLevel.livingRoom => 'living_room',
      GameLevel.garden => 'garden',
    };

int analyticsLevelIndex(GameLevel level) => level.index + 1;

String analyticsBoardLayout(BoardLayout layout) => switch (layout) {
      BoardLayout.standard => 'standard',
      BoardLayout.phonePortrait => 'phone_portrait',
    };

String analyticsLanguage(String localeName) =>
    localeName.startsWith('de') ? 'de' : 'en';

class GameStartAnalyticsEvent {
  const GameStartAnalyticsEvent({
    required this.levelName,
    required this.levelIndex,
    required this.boardLayout,
    required this.language,
  });

  final String levelName;
  final int levelIndex;
  final String boardLayout;
  final String language;
}

class GameOverAnalyticsEvent {
  const GameOverAnalyticsEvent({
    required this.levelName,
    required this.levelIndex,
    required this.score,
    required this.snakeLength,
    required this.roundDurationSeconds,
    required this.endReason,
  });

  final String levelName;
  final int levelIndex;
  final int score;
  final int snakeLength;
  final int roundDurationSeconds;
  final GameEndReason endReason;
}

abstract interface class AnalyticsService {
  Future<void> logGameStart(GameStartAnalyticsEvent event);

  Future<void> logGameOver(GameOverAnalyticsEvent event);
}

class NoopAnalyticsService implements AnalyticsService {
  const NoopAnalyticsService();

  @override
  Future<void> logGameStart(GameStartAnalyticsEvent event) async {}

  @override
  Future<void> logGameOver(GameOverAnalyticsEvent event) async {}
}

class FirebaseAnalyticsService implements AnalyticsService {
  FirebaseAnalyticsService({FirebaseAnalytics? analytics})
      : _analytics = analytics ?? FirebaseAnalytics.instance;

  final FirebaseAnalytics _analytics;

  @override
  Future<void> logGameStart(GameStartAnalyticsEvent event) => _logSafely(
        'game_start',
        {
          'level_name': event.levelName,
          'level_index': event.levelIndex,
          'board_layout': event.boardLayout,
          'language': event.language,
        },
      );

  @override
  Future<void> logGameOver(GameOverAnalyticsEvent event) => _logSafely(
        'game_over',
        {
          'level_name': event.levelName,
          'level_index': event.levelIndex,
          'score': event.score,
          'snake_length': event.snakeLength,
          'round_duration_seconds': event.roundDurationSeconds,
          'end_reason': event.endReason.name,
        },
      );

  Future<void> _logSafely(
    String name,
    Map<String, Object> parameters,
  ) async {
    try {
      await _analytics.logEvent(name: name, parameters: parameters);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Analytics-Ereignis $name konnte nicht gesendet werden: '
            '$error');
      }
    }
  }
}
