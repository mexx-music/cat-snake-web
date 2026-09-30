import 'dart:ui'; // für BackdropFilter / ImageFilter.blur
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:ui' as ui;
import '../audio/web_sfx_engine.dart';
import '../constants/game_constants.dart';
import '../game/board_geometry.dart';
import '../game/game_collision.dart';
import '../l10n/generated/app_localizations.dart';
import '../promo/promo_scene.dart';
import '../services/analytics_service.dart';
import '../services/game_analytics_tracker.dart';
import '../services/leaderboard_service.dart';

String _localizedLevelName(AppLocalizations strings, GameLevel level) =>
    switch (level) {
      GameLevel.meadow => strings.meadow,
      GameLevel.livingRoom => strings.livingRoom,
      GameLevel.garden => strings.garden,
    };

String _localizedLevelDescription(
  AppLocalizations strings,
  GameLevel level,
) =>
    switch (level) {
      GameLevel.meadow => strings.meadowDescription,
      GameLevel.livingRoom => strings.livingRoomDescription,
      GameLevel.garden => strings.gardenDescription,
    };

class GamePage extends StatefulWidget {
  const GamePage({
    required this.onLocaleChanged,
    this.promoScene,
    this.analyticsService = const NoopAnalyticsService(),
    super.key,
  });

  final ValueChanged<Locale> onLocaleChanged;
  final PromoSceneDefinition? promoScene;
  final AnalyticsService analyticsService;

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  AppLocalizations get _strings => AppLocalizations.of(context);
  // Spielfeld: Standard bleibt 22×16; kleine Portrait-Handys nutzen 14×22.
  BoardGeometry _boardGeometry = BoardGeometry.standard;
  int get rows => _boardGeometry.rows;
  int get cols => _boardGeometry.cols;

  final Random _rand = Random();
  List<Point<int>> snake = [];
  List<Point<int>> _previousSnake = [];
  Direction dir = Direction.right;
  final List<Direction> _directionQueue = [];
  Point<int>? food;

  // Maus (langsam, bewegt sich selten)
  Point<int>? mouse;
  int get _mouseStepEvery => switch (selectedLevel) {
        GameLevel.meadow => 12,
        GameLevel.livingRoom => 9,
        GameLevel.garden => 7,
      };
  int _mouseTick = 0;

  // Game loop: bildschirmgetaktet statt Timer, damit die Bewegung zwischen
  // zwei logischen Rasterfeldern ohne Pause oder Timer-Jitter weiterläuft.
  Ticker? _gameTicker;
  Duration? _lastFrameTime;
  double _tickElapsedMs = 0;
  int tickMs = 180;
  int score = 0;
  final Map<GameLevel, int> _levelHighScores = {
    for (final level in GameLevel.values) level: 0,
  };
  static const String _highScoreKey = 'cat_snake_high_score';
  static const String _playerNameKey = 'cat_snake_player_name';
  SharedPreferences? _preferences;
  final LeaderboardService _leaderboard = LeaderboardService();
  String _playerName = '';
  int _roundStartingHighScore = 0;
  bool _endingGame = false;
  bool _gameStarted = false;
  bool paused = false;
  bool wrapWalls = true; // Wrap standardmäßig EIN
  GameLevel selectedLevel = GameLevel.meadow;
  Set<Point<int>> obstacles = {};
  late final GameAnalyticsTracker _analyticsTracker;

  // Audio
  AudioPlayer? _bgm;
  AudioPlayer? _sfxEat;
  AudioPlayer? _sfxMouse;
  AudioPlayer? _sfxOver;
  final WebSfxEngine _webSfx = WebSfxEngine();
  bool soundOn = true;
  int _musicVariation = -1;

  // Bonus-Animation (verlängert + Fade)
  late final AnimationController _moveCtrl;
  late final AnimationController _ambientCtrl;
  late final AnimationController _bonusCtrl;
  late final Animation<double> _bonusT;
  late final Animation<double> _bonusOpacity;
  Point<int>? _bonusAt; // Grid-Position des Effekts
  bool _isMouseBonusFx = false;
  int _promoTick = 0;

  CatSkin selectedSkin = CatSkin.red; // Standard-Skin

  int get highScore => _levelHighScores[selectedLevel] ?? 0;

  int get _bestEver => _levelHighScores.values.fold(0, max);

  bool _isLevelUnlocked(GameLevel level) =>
      _bestEver >= levelUnlockScore[level]!;

  String _levelHighScoreKey(GameLevel level) =>
      'cat_snake_high_score_${level.name}';

  void _applyPromoScene(PromoSceneDefinition scene) {
    selectedLevel = scene.level;
    snake = List.of(scene.snake);
    _previousSnake = List.of(scene.snake);
    dir = scene.direction;
    _directionQueue.clear();
    food = scene.food;
    mouse = scene.mouse;
    score = scene.score;
    _levelHighScores[scene.level] = scene.score;
    _roundStartingHighScore = scene.score;
    obstacles = _boardGeometry.obstaclesFor(scene.level);
    wrapWalls = levelWrapWalls[scene.level]!;
    tickMs = levelStartSpeed[scene.level]!;
    _gameStarted = scene.started;
    paused = false;
    soundOn = false;
    _moveCtrl.value = 1;
    _bonusAt = scene.bonusAt;
    _isMouseBonusFx = scene.mouseBonus;
    _promoTick = 0;
    if (scene.bonusAt != null) _bonusCtrl.value = 0.34;
  }

  void _newGame({bool notify = true}) {
    _analyticsTracker.cancelRound();
    _gameTicker?.stop();
    if (kIsWeb) _webSfx.pauseMusic();
    _lastFrameTime = null;
    _tickElapsedMs = 0;
    score = 0;
    tickMs = levelStartSpeed[selectedLevel]!;
    _gameStarted = false;
    paused = false;
    wrapWalls = levelWrapWalls[selectedLevel]!;
    dir = Direction.right;
    _directionQueue.clear();
    obstacles = _boardGeometry.obstaclesFor(selectedLevel);
    _musicVariation = _nextMusicVariation();

    final initialHead = _boardGeometry.initialHead;
    snake = [
      initialHead,
      Point<int>(initialHead.x - 1, initialHead.y),
      Point<int>(initialHead.x - 2, initialHead.y),
    ];
    _previousSnake = List.of(snake);
    _moveCtrl.value = 1;

    mouse = null;
    _mouseTick = 0;

    _spawnFood();
    _spawnMouse();

    if (notify && mounted) setState(() {});
  }

  int _nextMusicVariation() {
    if (_musicVariation < 0) return _rand.nextInt(3);
    // Garantiert eine andere Melodie als in der unmittelbar vorherigen Runde.
    return (_musicVariation + 1 + _rand.nextInt(2)) % 3;
  }

  Future<void> _loadHighScore() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _preferences = preferences;
      final storedPlayerName = preferences.getString(_playerNameKey) ?? '';
      final legacyHighScore = preferences.getInt(_highScoreKey) ?? 0;
      final storedHighScores = {
        for (final level in GameLevel.values)
          level: preferences.getInt(_levelHighScoreKey(level)) ??
              (level == GameLevel.meadow ? legacyHighScore : 0),
      };
      if (!mounted) return;
      setState(() {
        _playerName = storedPlayerName;
        for (final entry in storedHighScores.entries) {
          _levelHighScores[entry.key] =
              max(_levelHighScores[entry.key]!, entry.value);
        }
        if (!_gameStarted && score == 0) {
          _roundStartingHighScore = highScore;
        }
      });
    } catch (error) {
      debugPrint('Highscore konnte nicht geladen werden: $error');
    }
  }

  Future<void> _saveHighScore(GameLevel level, int value) async {
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setInt(_levelHighScoreKey(level), value);
      await preferences.setInt(_highScoreKey, _bestEver);
    } catch (error) {
      debugPrint('Highscore konnte nicht gespeichert werden: $error');
    }
  }

  void _addPoints(int points) {
    score += points;
    if (score <= highScore) return;
    _levelHighScores[selectedLevel] = score;
    unawaited(_saveHighScore(selectedLevel, score));
  }

  Future<void> _startGame() async {
    if (_gameStarted) return;
    if (soundOn) unawaited(_webSfx.unlock());
    setState(() {
      _roundStartingHighScore = highScore;
      _gameStarted = true;
      paused = false;
    });
    _analyticsTracker.startRound(
      GameStartAnalyticsEvent(
        levelName: analyticsLevelName(selectedLevel),
        levelIndex: analyticsLevelIndex(selectedLevel),
        boardLayout: analyticsBoardLayout(_boardGeometry.layout),
        language: analyticsLanguage(_strings.localeName),
      ),
    );
    _beginContinuousMovement();
    await _startBgmIfAllowed();
  }

  void _beginContinuousMovement() {
    _lastFrameTime = null;
    _tickElapsedMs = 0;
    _tick();
    if (_gameStarted && !paused) _gameTicker?.start();
  }

  void _onGameFrame(Duration elapsed) {
    if (!mounted || !_gameStarted || paused) return;

    final previousFrame = _lastFrameTime;
    _lastFrameTime = elapsed;
    if (previousFrame == null) return;

    // Große Sprünge (z. B. nach einem inaktiven Browser-Tab) begrenzen.
    final frameMs = min(
      50.0,
      (elapsed - previousFrame).inMicroseconds /
          Duration.microsecondsPerMillisecond,
    );
    _tickElapsedMs += frameMs;

    while (_tickElapsedMs >= tickMs && _gameStarted && !paused) {
      _tickElapsedMs -= tickMs;
      _tick();
    }

    if (_gameStarted && !paused) {
      _moveCtrl.value = (_tickElapsedMs / tickMs).clamp(0.0, 1.0);
    }
  }

  void _togglePause() async {
    if (!_gameStarted) return;
    setState(() => paused = !paused);
    if (paused) {
      _analyticsTracker.pauseRound();
      _gameTicker?.stop();
      _lastFrameTime = null;
    } else {
      _analyticsTracker.resumeRound();
      _lastFrameTime = null;
      _gameTicker?.start();
    }
    if (!soundOn) return;

    if (paused) {
      await _pauseBgm();
    } else {
      unawaited(_webSfx.unlock());
      await _startBgmIfAllowed();
    }
  }

  void _spawnFood() {
    final occupied = snake.toSet()
      ..addAll(obstacles)
      ..addAll({if (mouse != null) mouse!});
    while (true) {
      final p = Point<int>(_rand.nextInt(cols), _rand.nextInt(rows));
      if (!occupied.contains(p)) {
        food = p;
        return;
      }
    }
  }

  void _spawnMouse() {
    final occupied = snake.toSet()
      ..addAll(obstacles)
      ..addAll({if (food != null) food!});
    while (true) {
      final p = Point<int>(_rand.nextInt(cols), _rand.nextInt(rows));
      if (!occupied.contains(p)) {
        mouse = p;
        return;
      }
    }
  }

  Point<int> _wrapPoint(Point<int> point) => _boardGeometry.wrap(point);

  // Maus: sehr langsam & zufällig (bleibt oft stehen)
  void _moveMouseOnce() {
    if (mouse == null) {
      _spawnMouse();
      return;
    }
    final m = mouse!;
    final dirs = <Point<int>>[
      const Point(0, 0), // stehen bleiben (höhere Chance)
      const Point(0, 0),
      const Point(1, 0),
      const Point(-1, 0),
      const Point(0, 1),
      const Point(0, -1),
    ]..shuffle(_rand);

    for (var d in dirs) {
      var cand = Point<int>(m.x + d.x, m.y + d.y);
      if (wrapWalls) {
        cand = _wrapPoint(cand);
      } else {
        if (!_boardGeometry.contains(cand)) {
          continue;
        }
      }
      if (!snake.contains(cand) &&
          !obstacles.contains(cand) &&
          (food == null || cand != food)) {
        mouse = cand;
        return;
      }
    }
    // sonst stehen bleiben
  }

  void _changeDir(Direction next) {
    if (!_gameStarted) return;
    if (soundOn) unawaited(_webSfx.unlock());
    // Pro Tick genau eine Richtungsänderung puffern. So kann ein schneller
    // diagonaler Swipe die Katze nicht versehentlich in den Hals drehen.
    if (_directionQueue.isNotEmpty || _isOpposite(dir, next)) return;
    setState(() => _directionQueue.add(next));
  }

  bool _isOpposite(Direction first, Direction second) =>
      (first == Direction.up && second == Direction.down) ||
      (first == Direction.down && second == Direction.up) ||
      (first == Direction.left && second == Direction.right) ||
      (first == Direction.right && second == Direction.left);

  void _queueCombo(Direction vertical, Direction horizontal) {
    if (!_gameStarted || _directionQueue.isNotEmpty) return;
    if (soundOn) unawaited(_webSfx.unlock());

    // Die erste Richtung wird an die aktuelle Laufrichtung angepasst. So ist
    // z. B. ↗ sowohl von links (hoch, rechts) als auch von unten
    // (rechts, hoch) möglich, ohne eine verbotene Rückwärtsdrehung.
    final sequence = _isOpposite(dir, vertical)
        ? [horizontal, vertical]
        : [vertical, horizontal];
    final queued = <Direction>[];
    var previous = dir;
    for (final next in sequence) {
      if (next == previous || _isOpposite(previous, next)) continue;
      queued.add(next);
      previous = next;
    }
    if (queued.isEmpty) return;
    setState(() => _directionQueue.addAll(queued.take(2)));
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    if (!_gameStarted &&
        (event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.enter)) {
      unawaited(_startGame());
      return KeyEventResult.handled;
    }
    if (!_gameStarted) return KeyEventResult.ignored;

    final next = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => Direction.up,
      LogicalKeyboardKey.arrowDown => Direction.down,
      LogicalKeyboardKey.arrowLeft => Direction.left,
      LogicalKeyboardKey.arrowRight => Direction.right,
      _ => null,
    };

    if (next == null) return KeyEventResult.ignored;
    _changeDir(next);
    return KeyEventResult.handled;
  }

  void _showMouseBonus(Point<int> at) {
    _bonusAt = at;
    _isMouseBonusFx = true;
    HapticFeedback.mediumImpact();
    _bonusCtrl.forward(from: 0);
  }

  void _showFoodFx(Point<int> at) {
    _bonusAt = at;
    _isMouseBonusFx = false;
    HapticFeedback.lightImpact();
    _bonusCtrl.forward(from: 0);
  }

  void _tick() {
    if (!mounted || !_gameStarted || paused) return;

    final promoScene = widget.promoScene;
    if (promoScene?.autoPlay ?? false) {
      final scriptedDirection = promoScene!.demoTurns[_promoTick];
      if (scriptedDirection != null && !_isOpposite(dir, scriptedDirection)) {
        _directionQueue
          ..clear()
          ..add(scriptedDirection);
      }
      _promoTick += 1;
    }

    if (_directionQueue.isNotEmpty) {
      dir = _directionQueue.removeAt(0);
    }

    final head = snake.first;
    Point<int> next;
    switch (dir) {
      case Direction.up:
        next = Point<int>(head.x, head.y - 1);
        break;
      case Direction.down:
        next = Point<int>(head.x, head.y + 1);
        break;
      case Direction.left:
        next = Point<int>(head.x - 1, head.y);
        break;
      case Direction.right:
        next = Point<int>(head.x + 1, head.y);
        break;
    }

    if (wrapWalls) next = _boardGeometry.wrap(next);

    // Das letzte Schwanzfeld wird in diesem Tick frei und ist daher sicher.
    final endReason = collisionEndReason(
      wrapWalls: wrapWalls,
      isInsideBoard: _boardGeometry.contains(next),
      hitsObstacle: obstacles.contains(next),
      hitsSelf: snake.take(snake.length - 1).contains(next),
    );
    if (endReason != null) {
      _gameOver(endReason);
      return;
    }

    _previousSnake = List.of(snake);
    _moveCtrl.value = 0;
    setState(() {
      // 1) Kopf vorrücken
      snake = [next, ...snake];

      // 2) Gefressen?
      final ateFood = (food != null && next == food);
      final ateMouse = (mouse != null && next == mouse);

      if (ateFood) {
        _addPoints(10);
        if (tickMs > 70 && score % 30 == 0) {
          tickMs -= 10;
        }
        _showFoodFx(next);
        if (soundOn) _playSfx('sfx/eat.wav');
        _spawnFood();
      } else if (ateMouse) {
        _addPoints(30); // Bonus
        if (soundOn) _playSfx('sfx/mouse.wav');
        if (tickMs > 60) {
          tickMs -= 5;
        }
        _showMouseBonus(next);
        _spawnMouse();
      } else {
        snake.removeLast();
      }

      // 3) Maus bewegen (alle _mouseStepEvery Ticks)
      if (!ateMouse) {
        _mouseTick = (_mouseTick + 1) % _mouseStepEvery;
        if (_mouseTick == 0) {
          _moveMouseOnce();
        }
      }

      // 4) Sicherheit: falls Maus nach Bewegung unter dem Kopf landet
      if (mouse != null && snake.first == mouse) {
        _addPoints(30);
        if (soundOn) _playSfx('sfx/mouse.wav');
        _showMouseBonus(snake.first);
        _spawnMouse();
      }
    });
  }

  Future<void> _gameOver(GameEndReason endReason) async {
    if (_endingGame) return;
    _endingGame = true;
    _gameTicker?.stop();
    _lastFrameTime = null;
    setState(() => _gameStarted = false);
    if (soundOn) _playSfx('sfx/game_over.wav');
    unawaited(_pauseBgm());

    final finishedLevel = selectedLevel;
    final finalScore = score;
    _analyticsTracker.endRound(
      score: finalScore,
      snakeLength: snake.length,
      endReason: endReason,
    );
    final isNewHighScore =
        finalScore > 0 && finalScore > _roundStartingHighScore;
    final submittedGlobally = isNewHighScore
        ? await _askAndSubmitHighScore(finishedLevel, finalScore)
        : false;
    if (!mounted) return;

    final nextIndex = finishedLevel.index + 1;
    final nextLevel = nextIndex < GameLevel.values.length
        ? GameLevel.values[nextIndex]
        : null;
    final canContinue = nextLevel != null && _isLevelUnlocked(nextLevel);
    final strings = _strings;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF18343C),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: Color(0x66FFBE77)),
        ),
        title: Row(
          children: [
            const Icon(Icons.pets, color: Color(0xFFFFBE77)),
            const SizedBox(width: 10),
            Text(
              strings.gameOverTitle,
              style: const TextStyle(color: Color(0xFFFFE7C2)),
            ),
          ],
        ),
        content: Text(
          '${_localizedLevelName(strings, finishedLevel)}\n'
          '${strings.score}: $finalScore\n'
          '${strings.levelHighScore}: ${_levelHighScores[finishedLevel]}'
          '${submittedGlobally ? '\n${strings.globalSubmitted}' : ''}',
          style: const TextStyle(color: Colors.white70, height: 1.45),
        ),
        actions: [
          if (canContinue)
            FilledButton.icon(
              onPressed: () {
                Navigator.of(ctx).pop();
                selectedLevel = nextLevel;
                _newGame();
              },
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE98572),
              ),
              icon: const Icon(Icons.pets),
              label: Text(
                '${strings.continueLabel}: '
                '${_localizedLevelName(strings, nextLevel)}',
              ),
            ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _newGame();
            },
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFFFE7C2),
            ),
            child: Text(strings.backToStart),
          ),
        ],
      ),
    );
    _endingGame = false;
  }

  Future<bool> _askAndSubmitHighScore(
    GameLevel level,
    int finalScore,
  ) async {
    if (!_leaderboard.isAvailable || !mounted) return false;

    final strings = _strings;
    final controller = TextEditingController(text: _playerName);
    var canSubmit = controller.text.trim().isNotEmpty;
    final name = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          key: const Key('highscore-name-dialog'),
          backgroundColor: const Color(0xFF18343C),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Color(0x88FFD166)),
          ),
          title: Row(
            children: [
              const Icon(Icons.emoji_events, color: Color(0xFFFFD166)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  strings.newCatRecord,
                  style: const TextStyle(color: Color(0xFFFFE7C2)),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_localizedLevelName(strings, level)} · '
                '$finalScore ${strings.points}',
                style: const TextStyle(
                  color: Color(0xFFFFD166),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                strings.globalNameQuestion,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('player-name-field'),
                controller: controller,
                autofocus: true,
                maxLength: 16,
                textInputAction: TextInputAction.done,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: strings.yourName,
                  hintText: strings.nameHint,
                  labelStyle: const TextStyle(color: Color(0xFFFFBE77)),
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: Colors.black.withValues(alpha: 0.18),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFFFFBE77)),
                  ),
                  counterStyle: const TextStyle(color: Colors.white54),
                ),
                onChanged: (value) => setDialogState(
                  () => canSubmit = value.trim().isNotEmpty,
                ),
                onSubmitted: (value) {
                  final trimmed = value.trim();
                  if (trimmed.isNotEmpty) {
                    Navigator.of(dialogContext).pop(trimmed);
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
              child: Text(strings.localOnly),
            ),
            FilledButton.icon(
              key: const Key('submit-global-highscore'),
              onPressed: canSubmit
                  ? () => Navigator.of(dialogContext).pop(
                        controller.text.trim(),
                      )
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE98572),
              ),
              icon: const Icon(Icons.public),
              label: Text(strings.submit),
            ),
          ],
        ),
      ),
    );
    controller.dispose();

    if (name == null || name.isEmpty || !mounted) return false;
    _playerName = name;
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    _preferences = preferences;
    await preferences.setString(_playerNameKey, name);

    final submitted = await _leaderboard.submitHighScore(
      level: level.name,
      playerName: name,
      score: finalScore,
    );
    if (!mounted) return submitted;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          submitted ? strings.globalSubmitSuccess : strings.globalSubmitFailure,
        ),
      ),
    );
    return submitted;
  }

  Future<void> _showLeaderboard() async {
    final resumeAfterClosing = _gameStarted && !paused;
    if (resumeAfterClosing) {
      setState(() => paused = true);
      _analyticsTracker.pauseRound();
      _gameTicker?.stop();
      _lastFrameTime = null;
      unawaited(_pauseBgm());
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _LeaderboardSheet(
        service: _leaderboard,
        initialLevel: selectedLevel,
        playerName: _playerName,
      ),
    );
    if (resumeAfterClosing && mounted && _gameStarted) {
      setState(() => paused = false);
      _analyticsTracker.resumeRound();
      _lastFrameTime = null;
      _gameTicker?.start();
      unawaited(_startBgmIfAllowed());
    }
  }

  void _onHorizontalDrag(DragUpdateDetails d) {
    if (d.delta.dx > 0) {
      _changeDir(Direction.right);
    } else if (d.delta.dx < 0) {
      _changeDir(Direction.left);
    }
  }

  void _onVerticalDrag(DragUpdateDetails d) {
    if (d.delta.dy > 0) {
      _changeDir(Direction.down);
    } else if (d.delta.dy < 0) {
      _changeDir(Direction.up);
    }
  }

  Future<void> _pickSkin() async {
    final choice = await showModalBottomSheet<CatSkin?>(
      context: context,
      backgroundColor: const Color(0xFF18343C),
      barrierColor: Colors.black54,
      builder: (_) {
        Widget tile(String label, CatSkin skin) {
          final isSel = selectedSkin == skin;
          return GestureDetector(
            onTap: () => Navigator.pop(context, skin),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color:
                          isSel ? const Color(0xFFFFBE77) : Colors.transparent,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: CustomPaint(
                    painter: _CatPreviewPainter(skin),
                    size: const Size.square(72),
                  ),
                ),
                const SizedBox(height: 6),
                Text(label, style: const TextStyle(color: Colors.white)),
              ],
            ),
          );
        }

        return SafeArea(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                tile('Red', CatSkin.red),
                tile('Blacky', CatSkin.black),
                tile('Felix', CatSkin.tuxedo),
              ],
            ),
          ),
        );
      },
    );

    if (choice != null) {
      setState(() => selectedSkin = choice);
    }
  }

  IconData _levelIcon(GameLevel level) => switch (level) {
        GameLevel.meadow => Icons.grass,
        GameLevel.livingRoom => Icons.chair,
        GameLevel.garden => Icons.local_florist,
      };

  Future<void> _pickLevel() async {
    final strings = _strings;
    final choice = await showModalBottomSheet<GameLevel>(
      context: context,
      backgroundColor: const Color(0xFF18272D),
      barrierColor: Colors.black54,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.pets, color: Color(0xFFFFBE77)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      strings.chooseLevel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '${strings.bestScore}: $_bestEver',
                    style: const TextStyle(color: Color(0xFFFFD166)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 142,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final level in GameLevel.values)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: level == GameLevel.garden ? 0 : 8,
                          ),
                          child: _LevelCard(
                            key: Key('level-card-${level.name}'),
                            icon: _levelIcon(level),
                            name: _localizedLevelName(strings, level),
                            description:
                                _localizedLevelDescription(strings, level),
                            strings: strings,
                            highScore: _levelHighScores[level]!,
                            selected: selectedLevel == level,
                            unlocked: _isLevelUnlocked(level),
                            unlockScore: levelUnlockScore[level]!,
                            onTap: () => Navigator.pop(sheetContext, level),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (choice != null && choice != selectedLevel) {
      selectedLevel = choice;
      _newGame();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _analyticsTracker = GameAnalyticsTracker(
      widget.promoScene == null
          ? widget.analyticsService
          : const NoopAnalyticsService(),
    );

    _moveCtrl = AnimationController(
      vsync: this,
      value: 1,
    );
    _ambientCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _gameTicker = createTicker(_onGameFrame);

    // Bonus-Animation einrichten
    _bonusCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _bonusT = CurvedAnimation(parent: _bonusCtrl, curve: Curves.easeOutCubic);
    _bonusOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 35),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeOutQuad)),
        weight: 65,
      ),
    ]).animate(_bonusCtrl);
    _bonusCtrl.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        setState(() => _bonusAt = null);
      }
    });

    // Spielfeld vorbereiten; gestartet wird bewusst über den Start-Button.
    _newGame(notify: false);
    final promoScene = widget.promoScene;
    if (promoScene == null) {
      unawaited(_loadHighScore());
      unawaited(_initAudio());
    } else {
      _applyPromoScene(promoScene);
      if (promoScene.showGameOver) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_gameOver(GameEndReason.self));
        });
      } else if (promoScene.autoPlay) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_startGame());
        });
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextGeometry = widget.promoScene == null
        ? BoardGeometry.forViewport(MediaQuery.sizeOf(context))
        : BoardGeometry.standard;
    if (nextGeometry.layout == _boardGeometry.layout) return;

    _boardGeometry = nextGeometry;
    _newGame(notify: false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _analyticsTracker.cancelRound();
    _gameTicker?.dispose();
    _moveCtrl.dispose();
    _ambientCtrl.dispose();
    _bonusCtrl.dispose();
    _bgmSub?.cancel();
    unawaited(_webSfx.dispose());
    for (final player in [_bgm, _sfxEat, _sfxMouse, _sfxOver]) {
      if (player != null) unawaited(_disposeAudioPlayer(player));
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed || paused || !mounted) return;
    setState(() => paused = true);
    _analyticsTracker.pauseRound();
    _gameTicker?.stop();
    _lastFrameTime = null;
    unawaited(_pauseBgm());
  }

  bool _bgmEverStarted =
      false; // Haben wir schon einmal wirklich play() gemacht?
  bool _audioReady = false;
  PlayerState _bgmState = PlayerState.stopped;
  StreamSubscription<PlayerState>? _bgmSub;

  Future<void> _initAudio() async {
    if (_audioReady) return;
    if (kIsWeb) {
      _audioReady = true;
      return;
    }
    try {
      final player = _bgm ??= AudioPlayer();
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(0.80);
      _bgmSub?.cancel();
      _bgmSub = player.onPlayerStateChanged.listen((s) => _bgmState = s);
      _audioReady = true;
    } catch (e) {
      debugPrint('Audio konnte nicht initialisiert werden: $e');
    }
  }

  Future<void> _startBgmIfAllowed() async {
    if (!soundOn) return;
    if (kIsWeb) {
      await _webSfx.unlock();
      if (!soundOn || !_gameStarted || paused) return;
      _webSfx.startMusic(
        theme: selectedLevel.index,
        variation: _musicVariation,
      );
      return;
    }
    if (!_audioReady) await _initAudio();
    if (!_audioReady) return;
    final player = _bgm;
    if (player == null) return;

    try {
      if (!_bgmEverStarted) {
        await player.play(AssetSource('music/ukulele.mp3'));
        _bgmEverStarted = true;
      } else if (_bgmState != PlayerState.playing) {
        await player.resume();
      }
    } catch (e) {
      debugPrint('Hintergrundmusik konnte nicht gestartet werden: $e');
    }
  }

  Future<void> _pauseBgm() async {
    if (kIsWeb) {
      _webSfx.pauseMusic();
      return;
    }
    final player = _bgm;
    if (!_audioReady || player == null) return;
    try {
      await player.pause();
    } catch (e) {
      debugPrint('Hintergrundmusik konnte nicht pausiert werden: $e');
    }
  }

  void _playSfx(String asset) {
    if (kIsWeb) {
      switch (asset) {
        case 'sfx/eat.wav':
          _webSfx.playEat();
          return;
        case 'sfx/mouse.wav':
          _webSfx.playMouse();
          return;
        default:
          _webSfx.playGameOver();
          return;
      }
    }

    unawaited(() async {
      try {
        final player = switch (asset) {
          'sfx/eat.wav' => _sfxEat ??= AudioPlayer(),
          'sfx/mouse.wav' => _sfxMouse ??= AudioPlayer(),
          _ => _sfxOver ??= AudioPlayer(),
        };
        await player.play(AssetSource(asset));
      } catch (e) {
        debugPrint('Soundeffekt konnte nicht abgespielt werden: $e');
      }
    }());
  }

  Future<void> _disposeAudioPlayer(AudioPlayer player) async {
    try {
      await player.dispose();
    } catch (e) {
      debugPrint('AudioPlayer konnte nicht freigegeben werden: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final (bodyDark, bodyLight) = skinBodyColors[selectedSkin]!;
    final strings = _strings;
    final languageCode = Localizations.localeOf(context).languageCode;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.pets, color: Color(0xFFFFBE77), size: 22),
            SizedBox(width: 8),
            Text(
              'Cat Snake',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
            SizedBox(width: 8),
            Icon(Icons.pets, color: Color(0xFFE98572), size: 15),
          ],
        ),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            key: const Key('language-button'),
            tooltip: strings.language,
            onSelected: (code) => widget.onLocaleChanged(Locale(code)),
            icon: Text(
              languageCode.toUpperCase(),
              style: const TextStyle(
                color: Color(0xFFFFE7C2),
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'de',
                child: Text('DE · ${strings.germanLanguage}'),
              ),
              PopupMenuItem(
                value: 'en',
                child: Text('EN · ${strings.englishLanguage}'),
              ),
            ],
          ),
          IconButton(
            key: const Key('global-leaderboard-button'),
            tooltip: strings.globalLeaderboard,
            onPressed: _showLeaderboard,
            icon: const Icon(Icons.public, color: Color(0xFFFFD166)),
          ),
          const SizedBox(width: 4),
        ],
        toolbarHeight: 52,
        flexibleSpace: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF18343C), Color(0xFF285760)],
            ),
          ),
        ),
        shape: const Border(
          bottom: BorderSide(color: Color(0x556CD0BE)),
        ),
      ),
      body: Focus(
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: SafeArea(
          child: Stack(
            children: [
              // Hintergrund-Gradient
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF0F2027),
                        Color(0xFF203A43),
                        Color(0xFF2C5364)
                      ],
                    ),
                  ),
                ),
              ),
              const Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(painter: _CatBackdropPainter()),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Column(
                  children: [
                    _buildHud(),
                    const SizedBox(height: 8),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final useKeyboardControls =
                              switch (defaultTargetPlatform) {
                            TargetPlatform.macOS ||
                            TargetPlatform.windows ||
                            TargetPlatform.linux =>
                              true,
                            _ => false,
                          };
                          final useSideControls = constraints.maxWidth >= 620 &&
                              constraints.maxWidth >
                                  constraints.maxHeight * 1.35;
                          final board = _buildBoard(bodyDark, bodyLight);
                          final controls = Center(
                            child: useKeyboardControls
                                ? const _KeyboardHint(
                                    key: Key('keyboard-hint'),
                                  )
                                : _DPad(
                                    key: const Key('dpad'),
                                    buttonSize: useSideControls ? 62 : 58,
                                    onUp: () => _changeDir(Direction.up),
                                    onDown: () => _changeDir(Direction.down),
                                    onLeft: () => _changeDir(Direction.left),
                                    onRight: () => _changeDir(Direction.right),
                                    onUpLeft: () => _queueCombo(
                                      Direction.up,
                                      Direction.left,
                                    ),
                                    onUpRight: () => _queueCombo(
                                      Direction.up,
                                      Direction.right,
                                    ),
                                    onDownLeft: () => _queueCombo(
                                      Direction.down,
                                      Direction.left,
                                    ),
                                    onDownRight: () => _queueCombo(
                                      Direction.down,
                                      Direction.right,
                                    ),
                                  ),
                          );

                          if (useSideControls) {
                            return Row(
                              children: [
                                Expanded(child: board),
                                const SizedBox(width: 12),
                                SizedBox(
                                  width: min(230, constraints.maxWidth * 0.3),
                                  child: controls,
                                ),
                              ],
                            );
                          }

                          return Column(
                            children: [
                              Expanded(child: board),
                              const SizedBox(height: 6),
                              controls,
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBoard(Color bodyDark, Color bodyLight) {
    final strings = _strings;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cell = _cellSize(constraints.biggest);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: _onHorizontalDrag,
          onVerticalDragUpdate: _onVerticalDrag,
          child: Center(
            child: SizedBox(
              key: const Key('game-board'),
              width: cell * cols,
              height: cell * rows,
              child: RepaintBoundary(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(
                      painter: _BoardPainter(
                        rows: rows,
                        cols: cols,
                        cell: cell,
                        snake: snake,
                        previousSnake: _previousSnake,
                        food: food,
                        mouse: mouse,
                        direction: dir,
                        skin: selectedSkin,
                        level: selectedLevel,
                        obstacles: obstacles,
                        movement: _moveCtrl,
                        ambient: _ambientCtrl,
                        bodyDark: bodyDark,
                        bodyLight: bodyLight,
                      ),
                    ),
                    IgnorePointer(child: _buildBonusFx(cell)),
                    if (!_gameStarted)
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: ColoredBox(
                            color: Colors.black.withValues(alpha: 0.58),
                            child: Center(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      CustomPaint(
                                        painter:
                                            _CatPreviewPainter(selectedSkin),
                                        size: const Size.square(58),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        strings.readyTitle,
                                        style: const TextStyle(
                                          color: Color(0xFFFFE7C2),
                                          fontSize: 18,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        strings.readySubtitle,
                                        style: const TextStyle(
                                          color: Colors.white60,
                                          fontSize: 11,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      OutlinedButton.icon(
                                        key: const Key('level-button'),
                                        onPressed: _pickLevel,
                                        icon: Icon(_levelIcon(selectedLevel)),
                                        label: Text(
                                          '${strings.level}: '
                                          '${_localizedLevelName(strings, selectedLevel)}',
                                        ),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor:
                                              const Color(0xFFFFE7C2),
                                          side: const BorderSide(
                                            color: Color(0xAAFFBE77),
                                          ),
                                          backgroundColor: const Color(
                                            0x2218343C,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 7),
                                      FilledButton.icon(
                                        key: const Key('start-button'),
                                        onPressed: _startGame,
                                        icon: const Icon(Icons.pets),
                                        label: Text(strings.startGame),
                                        style: FilledButton.styleFrom(
                                          backgroundColor:
                                              const Color(0xFFE98572),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 24,
                                            vertical: 13,
                                          ),
                                          textStyle: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        strings.computerStartHint,
                                        style: const TextStyle(
                                          color: Colors.white60,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHud() {
    final strings = _strings;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        final iconConstraints = BoxConstraints.tightFor(
          width: compact ? 40 : 44,
          height: 40,
        );

        Widget actionButton({
          required String tooltip,
          required IconData icon,
          required VoidCallback? onPressed,
          Color? color,
        }) {
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.075),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white10),
            ),
            child: IconButton(
              tooltip: tooltip,
              constraints: iconConstraints,
              visualDensity: VisualDensity.compact,
              onPressed: onPressed,
              icon: Icon(icon, color: color),
            ),
          );
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFF112B32).withValues(alpha: 0.82),
                border: Border.all(
                  color: const Color(0xFFFFBE77).withValues(alpha: 0.18),
                ),
              ),
              child: IconTheme(
                data: const IconThemeData(color: Colors.white),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(color: Colors.white),
                  child: Row(
                    children: [
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Row(
                            children: [
                              const Icon(
                                Icons.pets,
                                size: 18,
                                color: Color(0xFFFFBE77),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${strings.score}: $score',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 14),
                              const Icon(
                                Icons.emoji_events,
                                size: 18,
                                color: Color(0xFFFFD166),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                '${strings.highScore}: $highScore',
                                key: const Key('high-score-value'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFFFD166),
                                ),
                              ),
                              const SizedBox(width: 14),
                              Icon(_levelIcon(selectedLevel), size: 17),
                              const SizedBox(width: 5),
                              Text(
                                _localizedLevelName(strings, selectedLevel),
                                key: const Key('current-level'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (compact)
                            Tooltip(
                              message: wrapWalls
                                  ? strings.wrapWalls
                                  : strings.solidWalls,
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 9),
                                child: Icon(
                                  wrapWalls
                                      ? Icons.all_inclusive
                                      : Icons.crop_square,
                                  color: Colors.tealAccent,
                                ),
                              ),
                            )
                          else
                            Text(
                              wrapWalls
                                  ? strings.wrapWalls
                                  : strings.solidWalls,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          actionButton(
                            tooltip: !_gameStarted
                                ? strings.startFirst
                                : paused
                                    ? strings.resume
                                    : strings.pause,
                            onPressed: _gameStarted ? _togglePause : null,
                            icon: paused ? Icons.play_arrow : Icons.pause,
                          ),
                          actionButton(
                            tooltip: strings.chooseCat,
                            onPressed: _pickSkin,
                            icon: Icons.pets,
                          ),
                          actionButton(
                            tooltip: strings.toggleSound,
                            onPressed: () {
                              final enableSound = !soundOn;
                              setState(() => soundOn = enableSound);
                              if (enableSound) {
                                unawaited(_webSfx.unlock());
                                unawaited(_startBgmIfAllowed());
                              } else {
                                unawaited(_pauseBgm());
                              }
                            },
                            icon: soundOn ? Icons.volume_up : Icons.volume_off,
                          ),
                          if (compact)
                            actionButton(
                              tooltip: strings.newGame,
                              icon: Icons.refresh,
                              color: Colors.tealAccent,
                              onPressed: _newGame,
                            )
                          else
                            ElevatedButton.icon(
                              onPressed: _newGame,
                              icon: const Icon(Icons.refresh),
                              label: Text(strings.newShort),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFE98572),
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: const StadiumBorder(),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                textStyle: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBonusFx(double cell) {
    if (_bonusAt == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _bonusCtrl,
      builder: (context, _) {
        final t = _bonusT.value; // 0..1 (Bewegung/Radius)
        final fade = _bonusOpacity.value; // 0..1 (Transparenz)
        final center = Offset(
          (_bonusAt!.x + 0.5) * cell,
          (_bonusAt!.y + 0.5) * cell,
        );

        return Stack(
          children: [
            CustomPaint(
              painter: _BonusRipplePainter(
                center: center,
                t: t,
                cell: cell,
                fade: fade,
                isMouseBonus: _isMouseBonusFx,
              ),
              size: Size.infinite,
            ),
            if (_isMouseBonusFx)
              Positioned(
                left: center.dx - 90,
                top: center.dy - 22 - (t * 36),
                child: Opacity(
                  opacity: fade,
                  child: Transform.scale(
                    scale: 0.9 + 0.3 * (1 - t),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE98572),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      child: Text(
                        '${_strings.mouseBonus} +30 🧀',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  double _cellSize(Size size) {
    final w = size.width, h = size.height;
    final cellW = w / cols, cellH = h / rows;
    return min(cellW, cellH);
  }
}

class _LeaderboardSheet extends StatefulWidget {
  const _LeaderboardSheet({
    required this.service,
    required this.initialLevel,
    required this.playerName,
  });

  final LeaderboardService service;
  final GameLevel initialLevel;
  final String playerName;

  @override
  State<_LeaderboardSheet> createState() => _LeaderboardSheetState();
}

class _LeaderboardSheetState extends State<_LeaderboardSheet> {
  late GameLevel _level = widget.initialLevel;

  IconData _levelIcon(GameLevel level) => switch (level) {
        GameLevel.meadow => Icons.grass,
        GameLevel.livingRoom => Icons.chair,
        GameLevel.garden => Icons.local_florist,
      };

  Color _rankColor(int rank) => switch (rank) {
        1 => const Color(0xFFFFD166),
        2 => const Color(0xFFDDE7EE),
        3 => const Color(0xFFD99A63),
        _ => Colors.white54,
      };

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;
    final strings = AppLocalizations.of(context);
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          key: const Key('world-leaderboard-sheet'),
          width: double.infinity,
          constraints: BoxConstraints(maxWidth: 680, maxHeight: maxHeight),
          decoration: const BoxDecoration(
            color: Color(0xFF162F36),
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.fromBorderSide(
              BorderSide(color: Color(0x44FFBE77)),
            ),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 10, 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.emoji_events,
                      color: Color(0xFFFFD166),
                      size: 30,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            strings.globalLeaderboard,
                            style: const TextStyle(
                              color: Color(0xFFFFE7C2),
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            strings.leaderboardSubtitle,
                            style: const TextStyle(color: Colors.white60),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: strings.close,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, color: Colors.white70),
                    ),
                  ],
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    for (final level in GameLevel.values)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ChoiceChip(
                          key: Key('leaderboard-level-${level.name}'),
                          selected: _level == level,
                          onSelected: (_) => setState(() => _level = level),
                          avatar: Icon(
                            _levelIcon(level),
                            size: 18,
                            color: _level == level
                                ? const Color(0xFF18343C)
                                : const Color(0xFFFFBE77),
                          ),
                          label: Text(_localizedLevelName(strings, level)),
                          selectedColor: const Color(0xFFFFBE77),
                          backgroundColor: Colors.white.withValues(alpha: 0.07),
                          side: BorderSide(
                            color: _level == level
                                ? const Color(0xFFFFBE77)
                                : Colors.white24,
                          ),
                          labelStyle: TextStyle(
                            color: _level == level
                                ? const Color(0xFF18343C)
                                : Colors.white70,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Expanded(child: _buildScores()),
              if (widget.playerName.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.pets,
                        color: Color(0xFFFFBE77),
                        size: 17,
                      ),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          '${strings.yourPlayerName}: ${widget.playerName}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white60),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScores() {
    final strings = AppLocalizations.of(context);
    if (!widget.service.isAvailable) {
      return _LeaderboardMessage(
        icon: Icons.cloud_off,
        title: strings.offlineAvailable,
        message: strings.offlineLeaderboardMessage,
      );
    }

    return StreamBuilder<List<LeaderboardEntry>>(
      stream: widget.service.watchTop(_level.name),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _LeaderboardMessage(
            icon: Icons.cloud_off,
            title: strings.noConnection,
            message: strings.tryAgain,
          );
        }
        if (!snapshot.hasData) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFFFFBE77)),
          );
        }

        final entries = snapshot.data!;
        if (entries.isEmpty) {
          return _LeaderboardMessage(
            icon: Icons.pets,
            title: strings.noEntries,
            message: strings.getFirstPlace,
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
          itemCount: entries.length,
          separatorBuilder: (_, __) => const SizedBox(height: 6),
          itemBuilder: (context, index) {
            final rank = index + 1;
            final entry = entries[index];
            final isMine = entry.userId == widget.service.currentUserId;
            return Container(
              key: Key('leaderboard-entry-$rank'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: isMine
                    ? const Color(0x33FFBE77)
                    : Colors.white.withValues(alpha: 0.055),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isMine ? const Color(0x88FFBE77) : Colors.white10,
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    child: Text(
                      rank <= 3 ? ['🥇', '🥈', '🥉'][index] : '$rank.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _rankColor(rank),
                        fontSize: rank <= 3 ? 22 : 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      entry.playerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isMine ? const Color(0xFFFFE7C2) : Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${entry.score}',
                    style: const TextStyle(
                      color: Color(0xFFFFD166),
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    strings.pointsShort,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _LeaderboardMessage extends StatelessWidget {
  const _LeaderboardMessage({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: const Color(0xFFFFBE77), size: 42),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFFFFE7C2),
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }
}

class _LevelCard extends StatelessWidget {
  final IconData icon;
  final String name;
  final String description;
  final int highScore;
  final bool selected;
  final bool unlocked;
  final int unlockScore;
  final AppLocalizations strings;
  final VoidCallback onTap;

  const _LevelCard({
    super.key,
    required this.icon,
    required this.name,
    required this.description,
    required this.highScore,
    required this.selected,
    required this.unlocked,
    required this.unlockScore,
    required this.strings,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = selected ? const Color(0xFFFFBE77) : Colors.white30;
    return Material(
      color: unlocked
          ? Colors.white.withValues(alpha: selected ? 0.14 : 0.07)
          : Colors.black.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: unlocked ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent, width: selected ? 2 : 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                unlocked ? icon : Icons.lock,
                color: unlocked ? const Color(0xFFFFBE77) : Colors.white38,
                size: 27,
              ),
              const SizedBox(height: 5),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: unlocked ? Colors.white : Colors.white54,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                unlocked
                    ? description
                    : '${strings.unlockAt} $unlockScore ${strings.unlockPoints}',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60, fontSize: 10.5),
              ),
              const SizedBox(height: 4),
              Text(
                '${strings.highScore}: $highScore',
                style: TextStyle(
                  color: unlocked ? const Color(0xFFFFD166) : Colors.white30,
                  fontSize: 10.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BonusRipplePainter extends CustomPainter {
  final Offset center;
  final double t; // 0..1
  final double cell;
  final double fade; // 0..1
  final bool isMouseBonus;

  _BonusRipplePainter({
    required this.center,
    required this.t,
    required this.cell,
    required this.fade,
    required this.isMouseBonus,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final base = cell * 0.6;
    final r1 = base + t * cell * 1.2;
    final r2 = base * 0.6 + t * cell * 0.9;
    final r3 = base * 0.3 + t * cell * 1.6;

    final p1 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.teal.withValues(alpha: 0.70 * fade);

    final p2 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.45 * fade);

    final p3 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.tealAccent.withValues(alpha: 0.25 * fade);

    if (isMouseBonus) {
      canvas.drawCircle(center, r1, p1);
      canvas.drawCircle(center, r2, p2);
      canvas.drawCircle(center, r3, p3);
    }

    // Sterne und Fellfunken fliegen beim Fressen vom Trefferpunkt weg.
    final sparklePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.amberAccent.withValues(alpha: fade);
    final furPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0xFFFFD6A0).withValues(alpha: fade * 0.85);
    for (var i = 0; i < 9; i++) {
      final angle = (i / 9) * pi * 2 + 0.35;
      final distance = cell * (0.22 + t * (0.75 + (i % 3) * 0.14));
      final particleCenter = center +
          Offset(
            cos(angle) * distance,
            sin(angle) * distance - t * cell * 0.18,
          );
      final radius = cell * (i.isEven ? 0.075 : 0.045) * (1 - t * 0.35);
      canvas.drawCircle(
        particleCenter,
        radius,
        i.isEven ? sparklePaint : furPaint,
      );
      if (i.isEven) {
        final rayPaint = Paint()
          ..color = sparklePaint.color
          ..strokeWidth = max(1, radius * 0.45)
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(
          particleCenter - Offset(radius * 1.8, 0),
          particleCenter + Offset(radius * 1.8, 0),
          rayPaint,
        );
        canvas.drawLine(
          particleCenter - Offset(0, radius * 1.8),
          particleCenter + Offset(0, radius * 1.8),
          rayPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BonusRipplePainter old) {
    return old.t != t ||
        old.center != center ||
        old.cell != cell ||
        old.fade != fade ||
        old.isMouseBonus != isMouseBonus;
  }
}

class _BoardPainter extends CustomPainter {
  final int rows;
  final int cols;
  final double cell;
  final List<Point<int>> snake;
  final List<Point<int>> previousSnake;
  final Point<int>? food;
  final Point<int>? mouse;
  final Direction direction;
  final CatSkin skin;
  final GameLevel level;
  final Set<Point<int>> obstacles;
  final Animation<double> movement;
  final Animation<double> ambient;

  final Color bodyDark;
  final Color bodyLight;

  _BoardPainter({
    required this.rows,
    required this.cols,
    required this.cell,
    required this.snake,
    required this.previousSnake,
    required this.food,
    required this.mouse,
    required this.direction,
    required this.skin,
    required this.level,
    required this.obstacles,
    required this.movement,
    required this.ambient,
    required this.bodyDark,
    required this.bodyLight,
  }) : super(repaint: Listenable.merge([movement, ambient]));

  @override
  void paint(Canvas canvas, Size size) {
    final W = cell * cols;
    final H = cell * rows;

    final boardRRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, W, H),
      const Radius.circular(16),
    );

    // weicher Schatten
    final shadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
    canvas.save();
    canvas.translate(0, 4);
    canvas.drawRRect(boardRRect, shadow);
    canvas.restore();

    // Jede Spielstufe bekommt eine klar erkennbare eigene Welt.
    final boardRect = Rect.fromLTWH(0, 0, W, H);
    final backgroundColors = switch (level) {
      GameLevel.meadow => const [
          Color(0xFF214B43),
          Color(0xFF173A38),
          Color(0xFF102B31),
        ],
      GameLevel.livingRoom => const [
          Color(0xFF9A6240),
          Color(0xFF70432F),
          Color(0xFF4B3029),
        ],
      GameLevel.garden => const [
          Color(0xFF437A45),
          Color(0xFF285D3B),
          Color(0xFF17443A),
        ],
    };
    final bgPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: backgroundColors,
      ).createShader(boardRect);
    canvas.drawRRect(boardRRect, bgPaint);

    canvas.save();
    canvas.clipRRect(boardRRect);
    _paintLevelDecorations(canvas, W, H);
    _paintObstacles(canvas);
    canvas.restore();

    final borderColor = switch (level) {
      GameLevel.meadow => const Color(0xFF9DD4B1),
      GameLevel.livingRoom => const Color(0xFFFFD09B),
      GameLevel.garden => const Color(0xFFB9E77D),
    };
    canvas.drawRRect(
      boardRRect.deflate(0.7),
      Paint()
        ..color = borderColor.withValues(alpha: 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );

    if (snake.isEmpty) return;

    Offset centerOf(Point<int> point) =>
        Offset((point.x + 0.5) * cell, (point.y + 0.5) * cell);

    Offset shortestTarget(Offset from, Offset to) {
      var dx = to.dx;
      var dy = to.dy;
      if (dx - from.dx > W / 2) dx -= W;
      if (from.dx - dx > W / 2) dx += W;
      if (dy - from.dy > H / 2) dy -= H;
      if (from.dy - dy > H / 2) dy += H;
      return Offset(dx, dy);
    }

    // Linear über fast den gesamten Spiel-Takt: kein schneller Satz am Anfang,
    // sondern gleichmäßiges Gleiten von einem Rasterfeld zum nächsten.
    final moveT = movement.value;
    final centersOrig = <Offset>[
      for (int i = 0; i < snake.length; i++)
        () {
          final current = centerOf(snake[i]);
          if (previousSnake.isEmpty) return current;
          final previous = centerOf(
            previousSnake[min(i, previousSnake.length - 1)],
          );
          return Offset.lerp(
            previous,
            shortestTarget(previous, current),
            moveT,
          )!;
        }(),
    ];

    // Unwrap: wähle pro Segment die nächstliegende gewrappt/geoffsette Position
    List<Offset> unwrapCenters(List<Offset> c) {
      if (c.isEmpty) return [];
      final out = <Offset>[c.first];
      for (int i = 1; i < c.length; i++) {
        final prev = out.last;
        Offset best = c[i];
        double bestDist = (best - prev).distance;
        for (final dx in [-W, 0.0, W]) {
          for (final dy in [-H, 0.0, H]) {
            final cand = c[i] + Offset(dx, dy);
            final d = (cand - prev).distance;
            if (d < bestDist) {
              best = cand;
              bestDist = d;
            }
          }
        }
        out.add(best);
      }
      return out;
    }

    Offset wrap(Offset o) {
      double wrap1(double v, double max) {
        final m = v % max;
        return m < 0 ? m + max : m;
      }

      return Offset(wrap1(o.dx, W), wrap1(o.dy, H));
    }

    final centers = unwrapCenters(centersOrig);

    // Clip auf Brett
    canvas.save();
    canvas.clipRRect(boardRRect);

    Offset catmullRom(
      Offset p0,
      Offset p1,
      Offset p2,
      Offset p3,
      double t,
    ) {
      final t2 = t * t;
      final t3 = t2 * t;
      return Offset(
        0.5 *
            ((2 * p1.dx) +
                (-p0.dx + p2.dx) * t +
                (2 * p0.dx - 5 * p1.dx + 4 * p2.dx - p3.dx) * t2 +
                (-p0.dx + 3 * p1.dx - 3 * p2.dx + p3.dx) * t3),
        0.5 *
            ((2 * p1.dy) +
                (-p0.dy + p2.dy) * t +
                (2 * p0.dy - 5 * p1.dy + 4 * p2.dy - p3.dy) * t2 +
                (-p0.dy + 3 * p1.dy - 3 * p2.dy + p3.dy) * t3),
      );
    }

    final tailCenters = List<Offset>.of(centers);
    if (tailCenters.length > 1) {
      final tail = tailCenters.last;
      final beforeTail = tailCenters[tailCenters.length - 2];
      final delta = tail - beforeTail;
      final distance = max(delta.distance, 0.001);
      final along = delta / distance;
      final sideways = Offset(-along.dy, along.dx);
      final bend =
          sin(ambient.value * pi * 2 + snake.length * 1.7) * cell * 0.18;
      tailCenters.add(tail + along * cell * 0.32 + sideways * bend);
    }

    final samples = <({Offset center, double progress, double radius})>[];
    if (tailCenters.length == 1) {
      samples.add((center: tailCenters.first, progress: 0, radius: cell * 0.4));
    } else {
      const samplesPerSegment = 5;
      final lastSegment = tailCenters.length - 1;
      for (int i = 0; i < lastSegment; i++) {
        final p0 = tailCenters[max(0, i - 1)];
        final p1 = tailCenters[i];
        final p2 = tailCenters[i + 1];
        final p3 = tailCenters[min(lastSegment, i + 2)];
        for (int step = 0; step < samplesPerSegment; step++) {
          final t = step / samplesPerSegment;
          final progress = (i + t) / lastSegment;
          final radius = ui.lerpDouble(cell * 0.4, cell * 0.1, progress)!;
          samples.add((
            center: catmullRom(p0, p1, p2, p3, t),
            progress: progress,
            radius: radius,
          ));
        }
      }
      samples.add((
        center: tailCenters.last,
        progress: 1,
        radius: cell * 0.1,
      ));
    }

    final shadowPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.black.withValues(alpha: 0.24);
    final outlinePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Color.lerp(bodyDark, Colors.black, 0.35)!;
    final furPaint = Paint()..style = PaintingStyle.fill;
    final shinePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.white.withValues(alpha: 0.055);

    for (final sample in samples.reversed) {
      canvas.drawCircle(
        wrap(sample.center + Offset(0, cell * 0.09)),
        sample.radius + cell * 0.055,
        shadowPaint,
      );
    }
    for (final sample in samples.reversed) {
      canvas.drawCircle(
        wrap(sample.center),
        sample.radius + cell * 0.045,
        outlinePaint,
      );
    }
    for (final sample in samples.reversed) {
      furPaint.color = Color.lerp(
        bodyLight,
        bodyDark,
        sample.progress * 0.82,
      )!;
      canvas.drawCircle(wrap(sample.center), sample.radius, furPaint);
    }
    for (final sample in samples.reversed) {
      canvas.drawCircle(
        wrap(sample.center +
            Offset(-sample.radius * 0.24, -sample.radius * 0.24)),
        sample.radius * 0.52,
        shinePaint,
      );
    }

    final patternColor = switch (skin) {
      CatSkin.red => const Color(0xFF6B2618).withValues(alpha: 0.68),
      CatSkin.black => Colors.white.withValues(alpha: 0.2),
      CatSkin.tuxedo => const Color(0xFFF4EBDD).withValues(alpha: 0.72),
    };
    final patternPaint = Paint()
      ..color = patternColor
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = cell * 0.095;
    for (final marker in const [0.25, 0.42, 0.59, 0.76]) {
      final index = (marker * (samples.length - 1)).round();
      final previous = samples[max(0, index - 1)].center;
      final next = samples[min(samples.length - 1, index + 1)].center;
      final delta = next - previous;
      if (delta.distance == 0) continue;
      final normal = Offset(-delta.dy, delta.dx) / delta.distance;
      final sample = samples[index];
      final center = wrap(sample.center);
      canvas.drawLine(
        center - normal * sample.radius * 0.62,
        center + normal * sample.radius * 0.62,
        patternPaint,
      );
    }

    // Futter im selben Cartoonstil wie die Katze.
    if (food != null) {
      final fCenter = Offset((food!.x + 0.5) * cell, (food!.y + 0.5) * cell);
      final fishPhase = ambient.value * pi * 2 + food!.x * 0.7 + food!.y * 0.35;
      _paintCartoonFish(
        canvas,
        fCenter + Offset(0, sin(fishPhase) * cell * 0.08),
        cell * 0.88,
        sin(fishPhase) * 0.07,
      );
    }

    // Maus mit weicher, leicht wippender Cartoon-Animation.
    if (mouse != null) {
      final mCenter = Offset((mouse!.x + 0.5) * cell, (mouse!.y + 0.5) * cell);
      final mousePhase = ambient.value * pi * 2 + mouse!.x * 0.45;
      _paintCartoonMouse(
        canvas,
        mCenter + Offset(0, sin(mousePhase) * cell * 0.035),
        cell * 0.9,
        sin(mousePhase) * 0.035,
      );
    }

    // Richtungsabhängiger Katzenkopf aus denselben Formen und Farben wie der
    // Schwanz. Die Draufsicht darf gedreht werden, ohne kopfüber zu wirken.
    if (snake.isNotEmpty) {
      final headCenter = wrap(centers.first);
      _paintCartoonCatHead(
        canvas,
        headCenter,
        cell * 1.14,
        skin,
        direction,
      );
    }

    canvas.restore();
  }

  void _paintLevelDecorations(Canvas canvas, double width, double height) {
    switch (level) {
      case GameLevel.meadow:
        for (final patch in const [
          (0.18, 0.2, 0.24),
          (0.78, 0.28, 0.3),
          (0.42, 0.78, 0.27),
          (0.9, 0.82, 0.18),
        ]) {
          final center = Offset(width * patch.$1, height * patch.$2);
          final radius = min(width, height) * patch.$3;
          canvas.drawCircle(
            center,
            radius,
            Paint()
              ..shader = RadialGradient(
                colors: [
                  const Color(0xFF79B982).withValues(alpha: 0.075),
                  Colors.transparent,
                ],
              ).createShader(Rect.fromCircle(center: center, radius: radius)),
          );
        }
        _paintGrass(canvas, width, height, 46, 0.12);
        for (var i = 0; i < 5; i++) {
          _paintPawPrint(
            canvas,
            Offset(width * (0.13 + i * 0.18), height * (0.78 - i * 0.12)),
            cell * 0.42,
            -0.42 + (i.isEven ? -0.08 : 0.08),
            const Color(0xFFD8E6C8).withValues(alpha: 0.085),
          );
        }
        break;
      case GameLevel.livingRoom:
        final seamPaint = Paint()
          ..color = const Color(0xFF3C251F).withValues(alpha: 0.27)
          ..strokeWidth = max(0.8, cell * 0.045);
        for (var y = cell * 1.8; y < height; y += cell * 2.2) {
          canvas.drawLine(Offset(0, y), Offset(width, y), seamPaint);
        }
        for (var row = 0; row < 8; row++) {
          final y = row * cell * 2.2;
          final offset = row.isEven ? cell * 3.2 : cell * 8.7;
          for (var x = offset; x < width; x += cell * 9.5) {
            canvas.drawLine(
              Offset(x, y),
              Offset(x, min(height, y + cell * 2.2)),
              seamPaint,
            );
          }
        }
        final rugRect = Rect.fromCenter(
          center: Offset(width * 0.52, height * 0.48),
          width: width * 0.34,
          height: height * 0.34,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rugRect, Radius.circular(cell * 0.7)),
          Paint()..color = const Color(0xFF2C7B78).withValues(alpha: 0.2),
        );
        _paintPawPrint(
          canvas,
          Offset(width * 0.84, height * 0.22),
          cell * 0.55,
          0.35,
          Colors.white.withValues(alpha: 0.08),
        );
        break;
      case GameLevel.garden:
        _paintGrass(canvas, width, height, 62, 0.16);
        final flowerColors = [
          const Color(0xFFFFD166),
          const Color(0xFFFF87A3),
          const Color(0xFFBCA7FF),
        ];
        for (var i = 0; i < 22; i++) {
          final center = Offset(
            ((i * 83 + 17) % 991) / 991 * width,
            ((i * 137 + 41) % 983) / 983 * height,
          );
          canvas.drawCircle(
            center,
            cell * 0.07,
            Paint()
              ..color =
                  flowerColors[i % flowerColors.length].withValues(alpha: 0.3),
          );
        }
        break;
    }
  }

  void _paintGrass(
    Canvas canvas,
    double width,
    double height,
    int count,
    double opacity,
  ) {
    final grassPaint = Paint()
      ..color = const Color(0xFFA8D19C).withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(0.7, cell * 0.035)
      ..strokeCap = StrokeCap.round;
    final breeze = sin(ambient.value * pi * 2) * cell * 0.055;
    for (var i = 0; i < count; i++) {
      final x = ((i * 73 + 29) % 997) / 997 * width;
      final y = ((i * 151 + 83) % 991) / 991 * height;
      final bladeHeight = cell * (0.12 + (i % 4) * 0.035);
      canvas.drawLine(
        Offset(x, y),
        Offset(x + breeze * (0.35 + (i % 3) * 0.2), y - bladeHeight),
        grassPaint,
      );
    }
  }

  void _paintObstacles(Canvas canvas) {
    for (final obstacle in obstacles) {
      final rect = Rect.fromLTWH(
        obstacle.x * cell + cell * 0.08,
        obstacle.y * cell + cell * 0.08,
        cell * 0.84,
        cell * 0.84,
      );
      final shadowRect = rect.shift(Offset(0, cell * 0.08));
      canvas.drawRRect(
        RRect.fromRectAndRadius(shadowRect, Radius.circular(cell * 0.18)),
        Paint()..color = Colors.black.withValues(alpha: 0.23),
      );

      if (level == GameLevel.livingRoom) {
        final isSofa = obstacle.y < rows / 2;
        final color =
            isSofa ? const Color(0xFFCB6F5C) : const Color(0xFFC4935B);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(cell * 0.2)),
          Paint()..color = color,
        );
        canvas.drawLine(
          rect.topLeft + Offset(cell * 0.13, cell * 0.17),
          rect.topRight + Offset(-cell * 0.13, cell * 0.17),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.22)
            ..strokeWidth = max(1, cell * 0.06)
            ..strokeCap = StrokeCap.round,
        );
      } else if (level == GameLevel.garden) {
        if (obstacle.x >= cols * 0.68) {
          canvas.drawOval(
            rect,
            Paint()..color = const Color(0xFF55AFC4),
          );
          canvas.drawArc(
            rect.deflate(cell * 0.18),
            -0.7,
            2.2,
            false,
            Paint()
              ..color = Colors.white.withValues(alpha: 0.28)
              ..style = PaintingStyle.stroke
              ..strokeWidth = max(1, cell * 0.06),
          );
        } else if (obstacle.x <= cols * 0.32) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, Radius.circular(cell * 0.22)),
            Paint()..color = const Color(0xFF704A31),
          );
          canvas.drawCircle(
            rect.center,
            cell * 0.18,
            Paint()..color = const Color(0xFFFFC857),
          );
          for (final angle in [0.0, pi / 2, pi, pi * 1.5]) {
            canvas.drawCircle(
              rect.center + Offset(cos(angle), sin(angle)) * cell * 0.19,
              cell * 0.12,
              Paint()..color = const Color(0xFFFF7D9B),
            );
          }
        } else {
          canvas.drawOval(
            rect,
            Paint()..color = const Color(0xFF83958A),
          );
          canvas.drawCircle(
            rect.center - Offset(cell * 0.13, cell * 0.1),
            cell * 0.12,
            Paint()..color = Colors.white.withValues(alpha: 0.17),
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BoardPainter old) {
    return old.snake != snake ||
        old.previousSnake != previousSnake ||
        old.food != food ||
        old.mouse != mouse ||
        old.direction != direction ||
        old.skin != skin ||
        old.level != level ||
        old.obstacles != obstacles ||
        old.cell != cell ||
        old.cols != cols ||
        old.rows != rows ||
        old.bodyDark != bodyDark ||
        old.bodyLight != bodyLight;
  }
}

void _paintPawPrint(
  Canvas canvas,
  Offset center,
  double size,
  double angle,
  Color color,
) {
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.rotate(angle);
  final paint = Paint()..color = color;
  canvas.drawOval(
    Rect.fromCenter(
      center: Offset(0, size * 0.12),
      width: size * 0.72,
      height: size * 0.62,
    ),
    paint,
  );
  for (final toe in const [
    Offset(-0.31, -0.27),
    Offset(-0.11, -0.4),
    Offset(0.12, -0.4),
    Offset(0.32, -0.25),
  ]) {
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(toe.dx * size, toe.dy * size),
        width: size * 0.25,
        height: size * 0.3,
      ),
      paint,
    );
  }
  canvas.restore();
}

class _CatPreviewPainter extends CustomPainter {
  final CatSkin skin;

  const _CatPreviewPainter(this.skin);

  @override
  void paint(Canvas canvas, Size size) {
    _paintCartoonCatHead(
      canvas,
      size.center(Offset.zero),
      min(size.width, size.height) * 0.86,
      skin,
      Direction.right,
    );
  }

  @override
  bool shouldRepaint(covariant _CatPreviewPainter oldDelegate) =>
      oldDelegate.skin != skin;
}

void _paintCartoonCatHead(
  Canvas canvas,
  Offset center,
  double size,
  CatSkin skin,
  Direction direction,
) {
  final angle = switch (direction) {
    Direction.right => 0.0,
    Direction.down => pi / 2,
    Direction.left => pi,
    Direction.up => -pi / 2,
  };
  final baseColor = switch (skin) {
    CatSkin.red => const Color(0xFFF18A43),
    CatSkin.black => const Color(0xFF343941),
    CatSkin.tuxedo => const Color(0xFF30343A),
  };
  final outlineColor = switch (skin) {
    CatSkin.red => const Color(0xFF71321E),
    CatSkin.black => const Color(0xFF111419),
    CatSkin.tuxedo => const Color(0xFF111419),
  };
  final muzzleColor = switch (skin) {
    CatSkin.red => const Color(0xFFFFD4A3),
    CatSkin.black => const Color(0xFF525A63),
    CatSkin.tuxedo => const Color(0xFFF5F1E8),
  };
  final eyeColor = switch (skin) {
    CatSkin.red => const Color(0xFF6ED7A7),
    CatSkin.black => const Color(0xFFF3D35D),
    CatSkin.tuxedo => const Color(0xFF72D6D0),
  };

  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.rotate(angle);

  final shadowPaint = Paint()
    ..color = Colors.black.withValues(alpha: 0.28)
    ..maskFilter = MaskFilter.blur(BlurStyle.normal, size * 0.07);
  canvas.drawOval(
    Rect.fromCenter(
      center: Offset(0, size * 0.07),
      width: size * 0.92,
      height: size * 0.76,
    ),
    shadowPaint,
  );

  Path ear(double sign) => Path()
    ..moveTo(size * 0.05, sign * size * 0.29)
    ..lineTo(size * 0.34, sign * size * 0.48)
    ..lineTo(size * 0.4, sign * size * 0.18)
    ..close();
  final outlinePaint = Paint()..color = outlineColor;
  canvas.drawPath(ear(-1), outlinePaint);
  canvas.drawPath(ear(1), outlinePaint);
  final innerEarPaint = Paint()..color = const Color(0xFFF29B9B);
  canvas.save();
  canvas.scale(0.82, 0.82);
  canvas.drawPath(ear(-1), innerEarPaint);
  canvas.drawPath(ear(1), innerEarPaint);
  canvas.restore();

  final headRect = Rect.fromCenter(
    center: Offset(-size * 0.025, 0),
    width: size * 0.88,
    height: size * 0.75,
  );
  canvas.drawOval(headRect.inflate(size * 0.045), outlinePaint);
  final headPaint = Paint()
    ..shader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color.lerp(baseColor, Colors.white, 0.2)!, baseColor],
    ).createShader(headRect);
  canvas.drawOval(headRect, headPaint);

  if (skin == CatSkin.red) {
    final stripePaint = Paint()
      ..color = const Color(0xFF9B4728)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.055
      ..strokeCap = StrokeCap.round;
    for (final y in [-0.21, 0.0, 0.21]) {
      canvas.drawLine(
        Offset(-size * 0.38, size * y),
        Offset(-size * 0.21, size * y * 0.78),
        stripePaint,
      );
    }
  } else if (skin == CatSkin.tuxedo) {
    final blaze = Path()
      ..moveTo(-size * 0.33, -size * 0.08)
      ..quadraticBezierTo(-size * 0.05, -size * 0.2, size * 0.2, 0)
      ..quadraticBezierTo(-size * 0.05, size * 0.2, -size * 0.33, size * 0.08)
      ..close();
    canvas.drawPath(blaze, Paint()..color = const Color(0xFFF5F1E8));
  }

  final muzzlePaint = Paint()..color = muzzleColor;
  canvas.drawOval(
    Rect.fromCenter(
      center: Offset(size * 0.2, -size * 0.105),
      width: size * 0.37,
      height: size * 0.25,
    ),
    muzzlePaint,
  );
  canvas.drawOval(
    Rect.fromCenter(
      center: Offset(size * 0.2, size * 0.105),
      width: size * 0.37,
      height: size * 0.25,
    ),
    muzzlePaint,
  );

  final eyePaint = Paint()..color = eyeColor;
  final pupilPaint = Paint()..color = const Color(0xFF132027);
  for (final sign in [-1.0, 1.0]) {
    final eye = Offset(size * 0.04, sign * size * 0.205);
    canvas.drawOval(
      Rect.fromCenter(
        center: eye,
        width: size * 0.17,
        height: size * 0.13,
      ),
      eyePaint,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: eye + Offset(size * 0.025, 0),
        width: size * 0.055,
        height: size * 0.1,
      ),
      pupilPaint,
    );
    canvas.drawCircle(
      eye + Offset(size * 0.045, -sign * size * 0.025),
      size * 0.018,
      Paint()..color = Colors.white,
    );
  }

  final nose = Path()
    ..moveTo(size * 0.41, 0)
    ..lineTo(size * 0.31, -size * 0.075)
    ..lineTo(size * 0.31, size * 0.075)
    ..close();
  canvas.drawPath(nose, Paint()..color = const Color(0xFFE8737D));

  final linePaint = Paint()
    ..color = outlineColor.withValues(alpha: 0.8)
    ..strokeWidth = max(1, size * 0.018)
    ..strokeCap = StrokeCap.round;
  canvas.drawLine(
    Offset(size * 0.32, 0),
    Offset(size * 0.24, size * 0.04),
    linePaint,
  );
  canvas.drawLine(
    Offset(size * 0.32, 0),
    Offset(size * 0.24, -size * 0.04),
    linePaint,
  );
  for (final sign in [-1.0, 1.0]) {
    canvas.drawLine(
      Offset(size * 0.29, sign * size * 0.1),
      Offset(size * 0.57, sign * size * 0.17),
      linePaint,
    );
    canvas.drawLine(
      Offset(size * 0.28, sign * size * 0.13),
      Offset(size * 0.55, sign * size * 0.27),
      linePaint,
    );
  }
  canvas.restore();
}

void _paintCartoonFish(
  Canvas canvas,
  Offset center,
  double size,
  double angle,
) {
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.rotate(angle);
  final outline = Paint()..color = const Color(0xFF164B63);
  final bodyRect = Rect.fromCenter(
    center: Offset(size * 0.05, 0),
    width: size * 0.68,
    height: size * 0.43,
  );
  final tail = Path()
    ..moveTo(-size * 0.27, 0)
    ..lineTo(-size * 0.5, -size * 0.25)
    ..lineTo(-size * 0.5, size * 0.25)
    ..close();
  canvas.drawPath(tail, outline);
  canvas.drawOval(bodyRect.inflate(size * 0.045), outline);
  canvas.drawPath(tail, Paint()..color = const Color(0xFF4CC5D7));
  canvas.drawOval(
    bodyRect,
    Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF88E5E9), Color(0xFF35AFC8)],
      ).createShader(bodyRect),
  );
  canvas.drawCircle(
    Offset(size * 0.25, -size * 0.07),
    size * 0.055,
    Paint()..color = Colors.white,
  );
  canvas.drawCircle(
    Offset(size * 0.27, -size * 0.07),
    size * 0.026,
    Paint()..color = const Color(0xFF12313B),
  );
  canvas.drawArc(
    Rect.fromCenter(
      center: Offset(size * 0.17, size * 0.06),
      width: size * 0.22,
      height: size * 0.15,
    ),
    0.15,
    1.05,
    false,
    Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(1, size * 0.025),
  );
  canvas.restore();
}

void _paintCartoonMouse(
  Canvas canvas,
  Offset center,
  double size,
  double angle,
) {
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.rotate(angle);
  final outline = Paint()
    ..color = const Color(0xFF39444D)
    ..style = PaintingStyle.stroke
    ..strokeWidth = max(1.2, size * 0.045)
    ..strokeCap = StrokeCap.round;
  final tailPath = Path()
    ..moveTo(-size * 0.28, size * 0.08)
    ..cubicTo(
      -size * 0.55,
      size * 0.18,
      -size * 0.48,
      -size * 0.32,
      -size * 0.22,
      -size * 0.28,
    );
  canvas.drawPath(
    tailPath,
    Paint()
      ..color = const Color(0xFFE8A0AA)
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(1.5, size * 0.055)
      ..strokeCap = StrokeCap.round,
  );
  final bodyRect = Rect.fromCenter(
    center: Offset(-size * 0.04, 0),
    width: size * 0.67,
    height: size * 0.48,
  );
  canvas.drawOval(
      bodyRect.inflate(size * 0.035), Paint()..color = outline.color);
  canvas.drawOval(bodyRect, Paint()..color = const Color(0xFFA9B4BE));
  for (final sign in [-1.0, 1.0]) {
    final earCenter = Offset(size * 0.08, sign * size * 0.2);
    canvas.drawCircle(earCenter, size * 0.14, Paint()..color = outline.color);
    canvas.drawCircle(
      earCenter,
      size * 0.105,
      Paint()..color = const Color(0xFFF0A8B1),
    );
  }
  final snout = Path()
    ..moveTo(size * 0.44, 0)
    ..lineTo(size * 0.17, -size * 0.19)
    ..lineTo(size * 0.17, size * 0.19)
    ..close();
  canvas.drawPath(snout, Paint()..color = const Color(0xFFCAD2D8));
  canvas.drawCircle(
    Offset(size * 0.43, 0),
    size * 0.055,
    Paint()..color = const Color(0xFFE87989),
  );
  canvas.drawCircle(
    Offset(size * 0.16, -size * 0.11),
    size * 0.045,
    Paint()..color = const Color(0xFF16242B),
  );
  for (final sign in [-1.0, 1.0]) {
    canvas.drawLine(
      Offset(size * 0.31, sign * size * 0.06),
      Offset(size * 0.54, sign * size * 0.13),
      outline,
    );
  }
  canvas.restore();
}

class _CatBackdropPainter extends CustomPainter {
  const _CatBackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final pawColor = const Color(0xFFFFE7C2).withValues(alpha: 0.045);
    for (final paw in [
      (Offset(size.width * 0.08, size.height * 0.2), -0.35, 46.0),
      (Offset(size.width * 0.91, size.height * 0.14), 0.42, 38.0),
      (Offset(size.width * 0.9, size.height * 0.82), -0.55, 52.0),
      (Offset(size.width * 0.12, size.height * 0.88), 0.35, 34.0),
    ]) {
      _paintPawPrint(canvas, paw.$1, paw.$3, paw.$2, pawColor);
    }

    final yarnColor = const Color(0xFFE98572).withValues(alpha: 0.07);
    final yarnPath = Path()
      ..moveTo(size.width * 0.68, size.height * 0.04)
      ..cubicTo(
        size.width * 0.61,
        size.height * 0.24,
        size.width * 0.78,
        size.height * 0.31,
        size.width * 0.72,
        size.height * 0.47,
      )
      ..cubicTo(
        size.width * 0.67,
        size.height * 0.61,
        size.width * 0.83,
        size.height * 0.68,
        size.width * 0.78,
        size.height * 0.88,
      );
    canvas.drawPath(
      yarnPath,
      Paint()
        ..color = yarnColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );
    final ballCenter = Offset(size.width * 0.79, size.height * 0.9);
    canvas.drawCircle(ballCenter, 17, Paint()..color = yarnColor);
    canvas.drawArc(
      Rect.fromCircle(center: ballCenter, radius: 11),
      -0.8,
      4.4,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.055)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _KeyboardHint extends StatelessWidget {
  const _KeyboardHint({super.key});

  @override
  Widget build(BuildContext context) {
    const keySize = 45.0;
    final strings = AppLocalizations.of(context);

    return Semantics(
      label: strings.keyboardControlSemantics,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF112B32).withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: const Color(0xFFFFBE77).withValues(alpha: 0.18),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PawControl(
                  key: Key('keycap-up'),
                  direction: Direction.up,
                  size: keySize,
                ),
              ],
            ),
            const SizedBox(height: 3),
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PawControl(
                  key: Key('keycap-left'),
                  direction: Direction.left,
                  size: keySize,
                ),
                SizedBox(width: 3),
                _PawControl(
                  key: Key('keycap-down'),
                  direction: Direction.down,
                  size: keySize,
                ),
                SizedBox(width: 3),
                _PawControl(
                  key: Key('keycap-right'),
                  direction: Direction.right,
                  size: keySize,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              strings.keyboardFunHint,
              style: const TextStyle(
                color: Color(0xFFFFE7C2),
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              strings.keyboardHint,
              style: const TextStyle(color: Colors.white54, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

class _DPad extends StatelessWidget {
  final VoidCallback onUp;
  final VoidCallback onDown;
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onUpLeft;
  final VoidCallback onUpRight;
  final VoidCallback onDownLeft;
  final VoidCallback onDownRight;
  final double buttonSize;

  const _DPad({
    required this.onUp,
    required this.onDown,
    required this.onLeft,
    required this.onRight,
    required this.onUpLeft,
    required this.onUpRight,
    required this.onDownLeft,
    required this.onDownRight,
    this.buttonSize = 54,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final gap = buttonSize * 0.08;
    final strings = AppLocalizations.of(context);
    return Semantics(
      label: strings.dpadSemantics,
      child: Container(
        padding: EdgeInsets.all(buttonSize * 0.12),
        decoration: BoxDecoration(
          color: const Color(0xFF112B32).withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(
            color: const Color(0xFFFFBE77).withValues(alpha: 0.16),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ComboPawCell(
                  key: const Key('combo-up-left'),
                  angle: -pi / 4,
                  size: buttonSize,
                  label: strings.comboUpLeft,
                  onPressed: onUpLeft,
                ),
                SizedBox(width: gap),
                _PawControl(
                  key: const Key('paw-up'),
                  direction: Direction.up,
                  size: buttonSize,
                  onPressed: onUp,
                ),
                SizedBox(width: gap),
                _ComboPawCell(
                  key: const Key('combo-up-right'),
                  angle: pi / 4,
                  size: buttonSize,
                  label: strings.comboUpRight,
                  onPressed: onUpRight,
                ),
              ],
            ),
            SizedBox(height: gap),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PawControl(
                  key: const Key('paw-left'),
                  direction: Direction.left,
                  size: buttonSize,
                  onPressed: onLeft,
                ),
                SizedBox(width: gap),
                SizedBox.square(
                  dimension: buttonSize,
                  child: Icon(
                    Icons.pets,
                    size: buttonSize * 0.45,
                    color: const Color(0xFFFFBE77).withValues(alpha: 0.26),
                  ),
                ),
                SizedBox(width: gap),
                _PawControl(
                  key: const Key('paw-right'),
                  direction: Direction.right,
                  size: buttonSize,
                  onPressed: onRight,
                ),
              ],
            ),
            SizedBox(height: gap),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ComboPawCell(
                  key: const Key('combo-down-left'),
                  angle: -3 * pi / 4,
                  size: buttonSize,
                  label: strings.comboDownLeft,
                  onPressed: onDownLeft,
                ),
                SizedBox(width: gap),
                _PawControl(
                  key: const Key('paw-down'),
                  direction: Direction.down,
                  size: buttonSize,
                  onPressed: onDown,
                ),
                SizedBox(width: gap),
                _ComboPawCell(
                  key: const Key('combo-down-right'),
                  angle: 3 * pi / 4,
                  size: buttonSize,
                  label: strings.comboDownRight,
                  onPressed: onDownRight,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PawControl extends StatelessWidget {
  final Direction direction;
  final double size;
  final VoidCallback? onPressed;

  const _PawControl({
    required this.direction,
    required this.size,
    this.onPressed,
    super.key,
  });

  IconData get _icon => switch (direction) {
        Direction.up => Icons.keyboard_arrow_up_rounded,
        Direction.down => Icons.keyboard_arrow_down_rounded,
        Direction.left => Icons.keyboard_arrow_left_rounded,
        Direction.right => Icons.keyboard_arrow_right_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final label = switch (direction) {
      Direction.up => strings.directionUp,
      Direction.down => strings.directionDown,
      Direction.left => strings.directionLeft,
      Direction.right => strings.directionRight,
    };
    final visual = SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _PawButtonPainter(direction),
        child: Center(
          child: Icon(
            _icon,
            size: size * 0.5,
            color: const Color(0xFF18343C),
          ),
        ),
      ),
    );

    if (onPressed == null) return visual;
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          splashColor: const Color(0xFFFFE7C2).withValues(alpha: 0.25),
          child: visual,
        ),
      ),
    );
  }
}

class _ComboPawCell extends StatelessWidget {
  const _ComboPawCell({
    required this.angle,
    required this.size,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final double angle;
  final double size;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final pawSize = size * 0.72;
    return SizedBox.square(
      dimension: size,
      child: Center(
        child: Semantics(
          button: true,
          label: label,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              splashColor: const Color(0xFFFFD166).withValues(alpha: 0.48),
              highlightColor: const Color(0xFFFFD166).withValues(alpha: 0.18),
              child: SizedBox.square(
                dimension: pawSize,
                child: CustomPaint(
                  painter: _PawButtonPainter.rotated(angle),
                  child: Center(
                    child: Transform.rotate(
                      angle: angle,
                      child: Icon(
                        Icons.arrow_upward_rounded,
                        size: pawSize * 0.44,
                        color: const Color(0xFF123E45),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PawButtonPainter extends CustomPainter {
  final Direction? direction;
  final double? rotation;
  final bool isCombo;

  const _PawButtonPainter(this.direction)
      : rotation = null,
        isCombo = false;

  const _PawButtonPainter.rotated(this.rotation)
      : direction = null,
        isCombo = true;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final angle = rotation ??
        switch (direction!) {
          Direction.up => 0.0,
          Direction.right => pi / 2,
          Direction.down => pi,
          Direction.left => -pi / 2,
        };
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);

    final glow = Paint()
      ..color = (isCombo ? const Color(0xFF6CD0BE) : const Color(0xFFFFBE77))
          .withValues(alpha: isCombo ? 0.22 : 0.12)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.09);
    canvas.drawCircle(Offset.zero, size.width * 0.43, glow);

    final outline = Paint()
      ..color = isCombo ? const Color(0xFF2F8075) : const Color(0xFF9C563F);
    final padColors = isCombo
        ? const [Color(0xFFB7F1E4), Color(0xFF58BDAE)]
        : const [Color(0xFFFFD49A), Color(0xFFE98572)];
    final pad = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: padColors,
      ).createShader(Rect.fromLTWH(
          -size.width / 2, -size.height / 2, size.width, size.height));

    final mainRect = Rect.fromCenter(
      center: Offset(0, size.height * 0.085),
      width: size.width * 0.62,
      height: size.height * 0.52,
    );
    canvas.drawOval(mainRect.inflate(size.width * 0.045), outline);
    canvas.drawOval(mainRect, pad);

    for (final toe in const [-0.27, 0.0, 0.27]) {
      final toeCenter = Offset(size.width * toe, -size.height * 0.28);
      canvas.drawCircle(toeCenter, size.width * 0.15, outline);
      canvas.drawCircle(toeCenter, size.width * 0.115, pad);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PawButtonPainter oldDelegate) =>
      oldDelegate.direction != direction ||
      oldDelegate.rotation != rotation ||
      oldDelegate.isCombo != isCombo;
}
