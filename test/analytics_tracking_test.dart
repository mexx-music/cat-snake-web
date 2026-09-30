import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cat_snake/constants/game_constants.dart';
import 'package:cat_snake/game/board_geometry.dart';
import 'package:cat_snake/game/game_collision.dart';
import 'package:cat_snake/l10n/generated/app_localizations.dart';
import 'package:cat_snake/main.dart';
import 'package:cat_snake/promo/promo_scene.dart';
import 'package:cat_snake/screens/game_page.dart';
import 'package:cat_snake/services/analytics_service.dart';
import 'package:cat_snake/services/game_analytics_tracker.dart';

void main() {
  test('analytics dimensions use stable normalized values', () {
    expect(analyticsLevelName(GameLevel.meadow), 'meadow');
    expect(analyticsLevelName(GameLevel.livingRoom), 'living_room');
    expect(analyticsLevelName(GameLevel.garden), 'garden');
    expect(analyticsLevelIndex(GameLevel.meadow), 1);
    expect(analyticsLevelIndex(GameLevel.livingRoom), 2);
    expect(analyticsLevelIndex(GameLevel.garden), 3);
    expect(analyticsBoardLayout(BoardLayout.standard), 'standard');
    expect(
      analyticsBoardLayout(BoardLayout.phonePortrait),
      'phone_portrait',
    );
    expect(analyticsLanguage('de'), 'de');
    expect(analyticsLanguage('en_US'), 'en');
  });

  group('game analytics tracker', () {
    test('logs game_start exactly once per real round', () async {
      final service = _RecordingAnalyticsService();
      final tracker = GameAnalyticsTracker(service, clock: _FakeClock());
      const start = GameStartAnalyticsEvent(
        levelName: 'living_room',
        levelIndex: 2,
        boardLayout: 'standard',
        language: 'en',
      );

      tracker.startRound(start);
      tracker.startRound(start);
      await _flushAnalytics();

      expect(service.starts, hasLength(1));
      expect(service.starts.single.levelName, 'living_room');
      expect(service.starts.single.levelIndex, 2);
      expect(service.starts.single.boardLayout, 'standard');
      expect(service.starts.single.language, 'en');

      tracker.endRound(
        score: 10,
        snakeLength: 4,
        endReason: GameEndReason.self,
      );
      tracker.startRound(start);
      await _flushAnalytics();
      expect(service.starts, hasLength(2));
    });

    test('logs game_over once and excludes paused time', () async {
      final service = _RecordingAnalyticsService();
      final clock = _FakeClock();
      final tracker = GameAnalyticsTracker(service, clock: clock);
      tracker.startRound(
        const GameStartAnalyticsEvent(
          levelName: 'garden',
          levelIndex: 3,
          boardLayout: 'phone_portrait',
          language: 'de',
        ),
      );

      clock.advance(const Duration(seconds: 4));
      tracker.pauseRound();
      clock.advance(const Duration(seconds: 20));
      tracker.resumeRound();
      clock.advance(const Duration(seconds: 3));
      tracker.endRound(
        score: 270,
        snakeLength: 19,
        endReason: GameEndReason.obstacle,
      );
      tracker.endRound(
        score: 999,
        snakeLength: 99,
        endReason: GameEndReason.wall,
      );
      await _flushAnalytics();

      expect(service.gameOvers, hasLength(1));
      final event = service.gameOvers.single;
      expect(event.levelName, 'garden');
      expect(event.levelIndex, 3);
      expect(event.score, 270);
      expect(event.snakeLength, 19);
      expect(event.roundDurationSeconds, 7);
      expect(event.endReason, GameEndReason.obstacle);
    });

    for (final reason in GameEndReason.values) {
      test('forwards ${reason.name} as a stable end reason', () async {
        final service = _RecordingAnalyticsService();
        final tracker = GameAnalyticsTracker(service, clock: _FakeClock());
        tracker.startRound(
          const GameStartAnalyticsEvent(
            levelName: 'meadow',
            levelIndex: 1,
            boardLayout: 'standard',
            language: 'de',
          ),
        );
        tracker.endRound(score: 0, snakeLength: 3, endReason: reason);
        await _flushAnalytics();

        expect(service.gameOvers.single.endReason, reason);
      });
    }

    test('analytics failures never escape into gameplay', () async {
      final tracker = GameAnalyticsTracker(
        const _ThrowingAnalyticsService(),
        clock: _FakeClock(),
      );

      tracker.startRound(
        const GameStartAnalyticsEvent(
          levelName: 'meadow',
          levelIndex: 1,
          boardLayout: 'standard',
          language: 'de',
        ),
      );
      tracker.endRound(
        score: 0,
        snakeLength: 3,
        endReason: GameEndReason.wall,
      );

      await _flushAnalytics();
    });
  });

  testWidgets('real phone round reports normalized start parameters once',
      (tester) async {
    SharedPreferences.setMockInitialValues({'cat_snake_language': 'de'});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final service = _RecordingAnalyticsService();

    await tester.pumpWidget(CatSnakeApp(analyticsService: service));
    await tester.pump();
    await tester.tap(find.byTooltip('Sound an/aus'));
    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(service.starts, hasLength(1));
    final event = service.starts.single;
    expect(event.levelName, 'meadow');
    expect(event.levelIndex, 1);
    expect(event.boardLayout, 'phone_portrait');
    expect(event.language, 'de');
    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('promo autoplay and promo game over emit no analytics events',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(720, 1280));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _RecordingAnalyticsService();

    for (final scene in [
      PromoSceneDefinition.demo,
      PromoSceneDefinition.all.firstWhere((scene) => scene.showGameOver),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('de'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: GamePage(
            onLocaleChanged: (_) {},
            promoScene: scene,
            analyticsService: service,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpWidget(const SizedBox.shrink());
    }

    expect(service.starts, isEmpty);
    expect(service.gameOvers, isEmpty);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('analytics start failure does not stop a real round',
      (tester) async {
    SharedPreferences.setMockInitialValues({'cat_snake_language': 'de'});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(844, 390));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const CatSnakeApp(analyticsService: _ThrowingAnalyticsService()),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Sound an/aus'));
    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pump();

    expect(find.byKey(const Key('start-button')), findsNothing);
    expect(find.byKey(const Key('game-board')), findsOneWidget);
    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _flushAnalytics() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _FakeClock implements MonotonicClock {
  Duration _elapsed = Duration.zero;

  @override
  Duration get elapsed => _elapsed;

  void advance(Duration duration) => _elapsed += duration;
}

class _RecordingAnalyticsService implements AnalyticsService {
  final List<GameStartAnalyticsEvent> starts = [];
  final List<GameOverAnalyticsEvent> gameOvers = [];

  @override
  Future<void> logGameStart(GameStartAnalyticsEvent event) async {
    starts.add(event);
  }

  @override
  Future<void> logGameOver(GameOverAnalyticsEvent event) async {
    gameOvers.add(event);
  }
}

class _ThrowingAnalyticsService implements AnalyticsService {
  const _ThrowingAnalyticsService();

  @override
  Future<void> logGameStart(GameStartAnalyticsEvent event) async {
    throw StateError('analytics unavailable');
  }

  @override
  Future<void> logGameOver(GameOverAnalyticsEvent event) async {
    throw StateError('analytics unavailable');
  }
}
