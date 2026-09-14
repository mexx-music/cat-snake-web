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

class GamePage extends StatefulWidget {
  const GamePage({super.key});

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // Spielfeld
  static const int rows = 16;
  static const int cols = 22;

  final Random _rand = Random();
  List<Point<int>> snake = [];
  List<Point<int>> _previousSnake = [];
  Direction dir = Direction.right;
  Direction? _pendingDir;
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
  SharedPreferences? _preferences;
  bool _gameStarted = false;
  bool paused = false;
  bool wrapWalls = true; // Wrap standardmäßig EIN
  GameLevel selectedLevel = GameLevel.meadow;
  Set<Point<int>> obstacles = {};

  // Audio
  AudioPlayer? _bgm;
  AudioPlayer? _sfxEat;
  AudioPlayer? _sfxMouse;
  AudioPlayer? _sfxOver;
  final WebSfxEngine _webSfx = WebSfxEngine();
  bool soundOn = true;

  // Bonus-Animation (verlängert + Fade)
  late final AnimationController _moveCtrl;
  late final AnimationController _ambientCtrl;
  late final AnimationController _bonusCtrl;
  late final Animation<double> _bonusT;
  late final Animation<double> _bonusOpacity;
  Point<int>? _bonusAt; // Grid-Position des Effekts
  bool _isMouseBonusFx = false;

  CatSkin selectedSkin = CatSkin.red; // Standard-Skin

  int get highScore => _levelHighScores[selectedLevel] ?? 0;

  int get _bestEver => _levelHighScores.values.fold(0, max);

  bool _isLevelUnlocked(GameLevel level) =>
      _bestEver >= levelUnlockScore[level]!;

  String _levelHighScoreKey(GameLevel level) =>
      'cat_snake_high_score_${level.name}';

  Set<Point<int>> _obstaclesFor(GameLevel level) {
    switch (level) {
      case GameLevel.meadow:
        return {};
      case GameLevel.livingRoom:
        return {
          for (var x = 3; x <= 5; x++)
            for (var y = 3; y <= 4; y++) Point<int>(x, y),
          for (var x = 16; x <= 18; x++)
            for (var y = 10; y <= 11; y++) Point<int>(x, y),
        };
      case GameLevel.garden:
        return {
          for (var x = 4; x <= 5; x++)
            for (var y = 3; y <= 5; y++) Point<int>(x, y),
          for (var x = 16; x <= 18; x++)
            for (var y = 3; y <= 4; y++) Point<int>(x, y),
          for (var y = 11; y <= 13; y++) Point<int>(11, y),
        };
    }
  }

  void _newGame() {
    _gameTicker?.stop();
    _lastFrameTime = null;
    _tickElapsedMs = 0;
    score = 0;
    tickMs = levelStartSpeed[selectedLevel]!;
    _gameStarted = false;
    paused = false;
    wrapWalls = levelWrapWalls[selectedLevel]!;
    dir = Direction.right;
    _pendingDir = null;
    obstacles = _obstaclesFor(selectedLevel);

    snake = [
      const Point<int>(cols ~/ 2 - 1, rows ~/ 2),
      const Point<int>(cols ~/ 2 - 2, rows ~/ 2),
      const Point<int>(cols ~/ 2 - 3, rows ~/ 2),
    ];
    _previousSnake = List.of(snake);
    _moveCtrl.value = 1;

    mouse = null;
    _mouseTick = 0;

    _spawnFood();
    _spawnMouse();

    setState(() {});
  }

  Future<void> _loadHighScore() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _preferences = preferences;
      final legacyHighScore = preferences.getInt(_highScoreKey) ?? 0;
      final storedHighScores = {
        for (final level in GameLevel.values)
          level: preferences.getInt(_levelHighScoreKey(level)) ??
              (level == GameLevel.meadow ? legacyHighScore : 0),
      };
      if (!mounted) return;
      setState(() {
        for (final entry in storedHighScores.entries) {
          _levelHighScores[entry.key] =
              max(_levelHighScores[entry.key]!, entry.value);
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
      _gameStarted = true;
      paused = false;
    });
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
      _gameTicker?.stop();
      _lastFrameTime = null;
    } else {
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

  Point<int> _wrapPoint(Point<int> p) =>
      Point<int>((p.x + cols) % cols, (p.y + rows) % rows);

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
        if (cand.x < 0 || cand.x >= cols || cand.y < 0 || cand.y >= rows) {
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
    if (_pendingDir != null) return;
    if ((dir == Direction.up && next == Direction.down) ||
        (dir == Direction.down && next == Direction.up) ||
        (dir == Direction.left && next == Direction.right) ||
        (dir == Direction.right && next == Direction.left)) {
      return;
    }
    setState(() => _pendingDir = next);
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

    dir = _pendingDir ?? dir;
    _pendingDir = null;

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

    if (wrapWalls) {
      next = Point<int>((next.x + cols) % cols, (next.y + rows) % rows);
    } else {
      if (next.x < 0 || next.x >= cols || next.y < 0 || next.y >= rows) {
        _gameOver();
        return;
      }
    }

    // Das letzte Schwanzfeld wird in diesem Tick frei und ist daher sicher.
    if (obstacles.contains(next) ||
        snake.take(snake.length - 1).contains(next)) {
      _gameOver();
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

  void _gameOver() {
    _gameTicker?.stop();
    _lastFrameTime = null;
    setState(() => _gameStarted = false);
    if (soundOn) _playSfx('sfx/game_over.wav');
    unawaited(_pauseBgm());

    final finishedLevel = selectedLevel;
    final nextIndex = finishedLevel.index + 1;
    final nextLevel = nextIndex < GameLevel.values.length
        ? GameLevel.values[nextIndex]
        : null;
    final canContinue = nextLevel != null && _isLevelUnlocked(nextLevel);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Game Over'),
        content: Text(
          '${levelName[finishedLevel]}\nScore: $score\nLevel-Highscore: $highScore',
        ),
        actions: [
          if (canContinue)
            FilledButton.icon(
              onPressed: () {
                Navigator.of(ctx).pop();
                selectedLevel = nextLevel;
                _newGame();
              },
              icon: const Icon(Icons.arrow_forward),
              label: Text('Weiter: ${levelName[nextLevel]}'),
            ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _newGame();
            },
            child: const Text('Zum Start'),
          ),
        ],
      ),
    );
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
      backgroundColor: Colors.black.withValues(alpha: 0.7),
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
                      color: isSel ? Colors.tealAccent : Colors.transparent,
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
                  const Expanded(
                    child: Text(
                      'Level wählen',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    'Bester Score: $_bestEver',
                    style: const TextStyle(color: Colors.amberAccent),
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
                            name: levelName[level]!,
                            description: levelDescription[level]!,
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
    _newGame();
    unawaited(_loadHighScore());
    unawaited(_initAudio());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cat Snake'),
        centerTitle: true,
        toolbarHeight: 48,
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
                                    buttonSize: useSideControls ? 54 : 50,
                                    onUp: () => _changeDir(Direction.up),
                                    onDown: () => _changeDir(Direction.down),
                                    onLeft: () => _changeDir(Direction.left),
                                    onRight: () => _changeDir(Direction.right),
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
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.pets,
                                    color: Colors.white,
                                    size: 42,
                                  ),
                                  const SizedBox(height: 10),
                                  OutlinedButton.icon(
                                    key: const Key('level-button'),
                                    onPressed: _pickLevel,
                                    icon: Icon(_levelIcon(selectedLevel)),
                                    label: Text(
                                      'Level: ${levelName[selectedLevel]}',
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.white,
                                      side: const BorderSide(
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  FilledButton.icon(
                                    key: const Key('start-button'),
                                    onPressed: _startGame,
                                    icon: const Icon(Icons.play_arrow),
                                    label: const Text('Spiel starten'),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: Colors.teal,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 22,
                                        vertical: 14,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                    'Computer: Leertaste oder Enter',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
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
          return IconButton(
            tooltip: tooltip,
            constraints: iconConstraints,
            visualDensity: VisualDensity.compact,
            onPressed: onPressed,
            icon: Icon(icon, color: color),
          );
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: Colors.black.withValues(alpha: 0.35),
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
                              const Icon(Icons.stars, size: 18),
                              const SizedBox(width: 6),
                              Text(
                                'Score: $score',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 14),
                              const Icon(
                                Icons.emoji_events,
                                size: 18,
                                color: Colors.amberAccent,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                'Highscore: $highScore',
                                key: const Key('high-score-value'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: Colors.amberAccent,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Icon(_levelIcon(selectedLevel), size: 17),
                              const SizedBox(width: 5),
                              Text(
                                levelName[selectedLevel]!,
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
                              message: wrapWalls ? 'Rand-Warp' : 'Feste Wände',
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
                              wrapWalls ? 'Rand-Warp' : 'Feste Wände',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          actionButton(
                            tooltip: !_gameStarted
                                ? 'Spiel zuerst starten'
                                : paused
                                    ? 'Fortsetzen'
                                    : 'Pause',
                            onPressed: _gameStarted ? _togglePause : null,
                            icon: paused ? Icons.play_arrow : Icons.pause,
                          ),
                          actionButton(
                            tooltip: 'Katze wählen',
                            onPressed: _pickSkin,
                            icon: Icons.pets,
                          ),
                          actionButton(
                            tooltip: 'Sound an/aus',
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
                              tooltip: 'Neues Spiel',
                              icon: Icons.refresh,
                              color: Colors.tealAccent,
                              onPressed: _newGame,
                            )
                          else
                            ElevatedButton.icon(
                              onPressed: _newGame,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Neu'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.teal,
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
                        color: Colors.teal,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      child: const Text(
                        'MOUSE BONUS +30 🧀',
                        style: TextStyle(
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

class _LevelCard extends StatelessWidget {
  final IconData icon;
  final String name;
  final String description;
  final int highScore;
  final bool selected;
  final bool unlocked;
  final int unlockScore;
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
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = selected ? Colors.tealAccent : Colors.white38;
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
                color: unlocked ? Colors.tealAccent : Colors.white38,
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
                unlocked ? description : 'Ab $unlockScore Punkten',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60, fontSize: 10.5),
              ),
              const SizedBox(height: 4),
              Text(
                'Highscore: $highScore',
                style: TextStyle(
                  color: unlocked ? Colors.amberAccent : Colors.white30,
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
        final isSofa = obstacle.y < 8;
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
        if (obstacle.x >= 16) {
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
        } else if (obstacle.x <= 5) {
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

class _KeyboardHint extends StatelessWidget {
  const _KeyboardHint({super.key});

  @override
  Widget build(BuildContext context) {
    Widget keyCap(IconData icon) => Container(
          width: 34,
          height: 30,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: Colors.white24),
          ),
          child: Icon(icon, size: 20, color: Colors.white70),
        );

    return Semantics(
      label: 'Steuerung mit den Pfeiltasten',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [keyCap(Icons.keyboard_arrow_up)],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                keyCap(Icons.keyboard_arrow_left),
                const SizedBox(width: 4),
                keyCap(Icons.keyboard_arrow_down),
                const SizedBox(width: 4),
                keyCap(Icons.keyboard_arrow_right),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Steuerung: Pfeiltasten',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
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
  final double buttonSize;

  const _DPad({
    required this.onUp,
    required this.onDown,
    required this.onLeft,
    required this.onRight,
    this.buttonSize = 54,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final btnStyle = ElevatedButton.styleFrom(
      minimumSize: Size.square(buttonSize),
      shape: const CircleBorder(),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.padded,
    );
    return SizedBox(
      width: buttonSize * 3.6,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            ElevatedButton(
                onPressed: onUp,
                style: btnStyle,
                child: Icon(Icons.keyboard_arrow_up, size: buttonSize * 0.58)),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            ElevatedButton(
                onPressed: onLeft,
                style: btnStyle,
                child:
                    Icon(Icons.keyboard_arrow_left, size: buttonSize * 0.58)),
            SizedBox(width: buttonSize * 0.45),
            ElevatedButton(
                onPressed: onRight,
                style: btnStyle,
                child:
                    Icon(Icons.keyboard_arrow_right, size: buttonSize * 0.58)),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            ElevatedButton(
                onPressed: onDown,
                style: btnStyle,
                child:
                    Icon(Icons.keyboard_arrow_down, size: buttonSize * 0.58)),
          ]),
        ],
      ),
    );
  }
}
