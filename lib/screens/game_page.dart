import 'dart:ui'; // für BackdropFilter / ImageFilter.blur
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:ui' as ui;
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
  Direction _previousDirection = Direction.right;
  Direction? _pendingDir;
  Point<int>? food;

  // Maus (langsam, bewegt sich selten)
  Point<int>? mouse;
  final int _mouseStepEvery =
      12; // je größer, desto seltener bewegt sich die Maus
  int _mouseTick = 0;

  // Game loop
  Timer? _timer;
  int tickMs = 180;
  int score = 0;
  bool _gameStarted = false;
  bool paused = false;
  bool wrapWalls = true; // Wrap standardmäßig EIN

  // Audio
  AudioPlayer? _bgm;
  AudioPlayer? _sfxEat;
  AudioPlayer? _sfxMouse;
  AudioPlayer? _sfxOver;
  bool soundOn = true;

  // Bonus-Animation (verlängert + Fade)
  late final AnimationController _moveCtrl;
  late final AnimationController _bonusCtrl;
  late final Animation<double> _bonusT;
  late final Animation<double> _bonusOpacity;
  Point<int>? _bonusAt; // Grid-Position des Effekts

  CatSkin selectedSkin = CatSkin.red; // Standard-Skin
  ui.Image? _headImage; // Kopf-Bild

  // Dynamische Farben aus dem Kopf-Bild ableiten
  Future<(Color bodyDark, Color bodyLight)> _colorsFromHead(
      ui.Image img) async {
    // 1) ui.Image -> PNG-Bytes
    final bdPng = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bdPng == null) {
      // Fallback-Farben
      return (const Color(0xFF2C5364), const Color(0xFF9EE7FF));
    }
    final bytesPng = bdPng.buffer.asUint8List();

    // 2) Klein decodieren (performant)
    final codec = await ui.instantiateImageCodec(
      bytesPng,
      targetWidth: 32,
      targetHeight: 32,
    );
    final f = await codec.getNextFrame();
    final small = f.image;

    // 3) RGBA holen
    final bd = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) {
      return (const Color(0xFF2C5364), const Color(0xFF9EE7FF));
    }
    final bytes = bd.buffer.asUint8List();

    // 4) Histogramm über grob quantisierte Farben (5 Bit/Kanal)
    final hist = <int, int>{};
    for (int i = 0; i < bytes.length; i += 4) {
      final r = bytes[i];
      final g = bytes[i + 1];
      final b = bytes[i + 2];
      final a = bytes[i + 3];
      if (a < 16) continue; // sehr transparente Pixel ignorieren

      final rq = r >> 3, gq = g >> 3, bq = b >> 3; // 0..31
      final key = (rq << 10) | (gq << 5) | bq;
      hist[key] = (hist[key] ?? 0) + 1;
    }

    if (hist.isEmpty) {
      return (const Color(0xFF2C5364), const Color(0xFF9EE7FF));
    }

    // 5) Dominante Bucket-Farbe
    var bestKey = hist.entries.reduce((a, b) => a.value > b.value ? a : b).key;
    final rq = (bestKey >> 10) & 31;
    final gq = (bestKey >> 5) & 31;
    final bq = bestKey & 31;

    final r = (rq << 3) | 0x7; // Mitte der Stufe
    final g = (gq << 3) | 0x7;
    final b = (bq << 3) | 0x7;

    final base = HSLColor.fromColor(Color.fromARGB(255, r, g, b));
    final bodyDark =
        base.withLightness((base.lightness * 0.55).clamp(0.0, 1.0)).toColor();
    final bodyLight =
        base.withLightness((base.lightness * 1.25).clamp(0.0, 1.0)).toColor();

    return (bodyDark, bodyLight);
  }

  Color? _autoBodyDark;
  Color? _autoBodyLight;

  Future<void> _recomputeBodyColorsFromHead() async {
    final img = _headImage;
    if (img == null) {
      setState(() {
        _autoBodyDark = null;
        _autoBodyLight = null;
      });
      return;
    }
    try {
      final (d, l) = await _colorsFromHead(img);
      if (!mounted) return;
      setState(() {
        _autoBodyDark = d;
        _autoBodyLight = l;
      });
    } catch (e) {
      debugPrint('Color extract failed: $e');
      setState(() {
        _autoBodyDark = null;
        _autoBodyLight = null;
      });
    }
  }

  Future<void> _loadHeadImage() async {
    try {
      final data = await rootBundle.load(headAsset[selectedSkin]!);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      setState(() => _headImage = frame.image);
      await _recomputeBodyColorsFromHead(); // Farben neu berechnen
    } catch (e) {
      debugPrint('Fehler beim Laden des Kopf-Bildes: $e');
      setState(() => _headImage = null); // Fallback
    }
  }

  void _newGame() {
    _timer?.cancel();
    score = 0;
    tickMs = 180;
    _gameStarted = false;
    paused = false;
    dir = Direction.right;
    _previousDirection = Direction.right;
    _pendingDir = null;

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

  Future<void> _startGame() async {
    if (_gameStarted) return;
    setState(() {
      _gameStarted = true;
      paused = false;
    });
    _startTimer();
    await _startBgmIfAllowed();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(milliseconds: tickMs), (_) => _tick());
  }

  void _togglePause() async {
    if (!_gameStarted) return;
    setState(() => paused = !paused);
    if (paused) _moveCtrl.value = 1;
    if (!soundOn) return;

    if (paused) {
      await _pauseBgm();
    } else {
      await _startBgmIfAllowed();
    }
  }

  void _spawnFood() {
    final occupied = snake.toSet()..addAll({if (mouse != null) mouse!});
    while (true) {
      final p = Point<int>(_rand.nextInt(cols), _rand.nextInt(rows));
      if (!occupied.contains(p)) {
        food = p;
        return;
      }
    }
  }

  void _spawnMouse() {
    final occupied = snake.toSet()..addAll({if (food != null) food!});
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
      if (!snake.contains(cand) && (food == null || cand != food)) {
        mouse = cand;
        return;
      }
    }
    // sonst stehen bleiben
  }

  void _changeDir(Direction next) {
    if (!_gameStarted) return;
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
    HapticFeedback.mediumImpact();
    _bonusCtrl.forward(from: 0);
  }

  void _tick() {
    if (!mounted || !_gameStarted || paused) return;

    _previousDirection = dir;
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
    if (snake.take(snake.length - 1).contains(next)) {
      _gameOver();
      return;
    }

    _previousSnake = List.of(snake);
    _moveCtrl.stop();
    _moveCtrl.duration = Duration(milliseconds: max(45, tickMs - 20));
    _moveCtrl.value = 0;
    setState(() {
      // 1) Kopf vorrücken
      snake = [next, ...snake];

      // 2) Gefressen?
      final ateFood = (food != null && next == food);
      final ateMouse = (mouse != null && next == mouse);

      if (ateFood) {
        score += 10;
        if (tickMs > 70 && score % 30 == 0) {
          tickMs -= 10;
          _startTimer();
        }
        if (soundOn) _playSfx('sfx/eat.wav');
        _spawnFood();
      } else if (ateMouse) {
        score += 30; // Bonus
        if (soundOn) _playSfx('sfx/mouse.wav');
        if (tickMs > 60) {
          tickMs -= 5;
          _startTimer();
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
        score += 30;
        if (soundOn) _playSfx('sfx/mouse.wav');
        _showMouseBonus(snake.first);
        _spawnMouse();
      }
    });
    _moveCtrl.forward();
  }

  void _gameOver() {
    _timer?.cancel();
    setState(() => _gameStarted = false);
    if (soundOn) _playSfx('sfx/game_over.wav');
    unawaited(_pauseBgm());

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Game Over'),
        content: Text('Score: $score'),
        actions: [
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
        Widget tile(String label, CatSkin skin, String asset) {
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
                  child: Image.asset(
                    asset,
                    width: 72,
                    height: 72,
                    fit: BoxFit.contain,
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
                tile('Red', CatSkin.red, skinAsset[CatSkin.red]!),
                tile('Blacky', CatSkin.black, skinAsset[CatSkin.black]!),
                tile('Felix', CatSkin.tuxedo, skinAsset[CatSkin.tuxedo]!),
              ],
            ),
          ),
        );
      },
    );

    if (choice != null) {
      setState(() => selectedSkin = choice);
      await _loadHeadImage();
      await _recomputeBodyColorsFromHead();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _moveCtrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: tickMs - 20),
      value: 1,
    );

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

    // Kopf-Bild laden
    _loadHeadImage();

    // Spielfeld vorbereiten; gestartet wird bewusst über den Start-Button.
    _newGame();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _moveCtrl.dispose();
    _bonusCtrl.dispose();
    _bgmSub?.cancel();
    for (final player in [_bgm, _sfxEat, _sfxMouse, _sfxOver]) {
      if (player != null) unawaited(_disposeAudioPlayer(player));
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed || paused || !mounted) return;
    setState(() => paused = true);
    _moveCtrl.value = 1;
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
    final (fallbackDark, fallbackLight) = skinBodyColors[selectedSkin]!;
    final bodyDark = _autoBodyDark ?? fallbackDark;
    final bodyLight = _autoBodyLight ?? fallbackLight;

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
                          final useSideControls = constraints.maxWidth >= 620 &&
                              constraints.maxWidth >
                                  constraints.maxHeight * 1.35;
                          final board = _buildBoard(bodyDark, bodyLight);
                          final controls = Center(
                            child: _DPad(
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
                        previousDirection: _previousDirection,
                        skin: selectedSkin,
                        movement: _moveCtrl,
                        bodyDark: bodyDark,
                        bodyLight: bodyLight,
                        headImage: _headImage,
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
                        child: Row(
                          children: [
                            const Icon(Icons.stars, size: 18),
                            const SizedBox(width: 6),
                            const Text('Score: '),
                            Text(
                              '$score',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (compact)
                            actionButton(
                              tooltip: wrapWalls
                                  ? 'Rand-Warp ausschalten'
                                  : 'Rand-Warp einschalten',
                              icon: Icons.all_inclusive,
                              color: wrapWalls
                                  ? Colors.tealAccent
                                  : Colors.white54,
                              onPressed: () =>
                                  setState(() => wrapWalls = !wrapWalls),
                            )
                          else ...[
                            const Text('Wrap'),
                            Switch(
                              value: wrapWalls,
                              onChanged: (v) => setState(() => wrapWalls = v),
                            ),
                          ],
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
                            onPressed: () async {
                              setState(() => soundOn = !soundOn);
                              if (soundOn) {
                                await _startBgmIfAllowed();
                              } else {
                                await _pauseBgm();
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
                  center: center, t: t, cell: cell, fade: fade),
              size: Size.infinite,
            ),
            Positioned(
              left: center.dx - 90,
              top: center.dy - 22 - (t * 36),
              child: Opacity(
                opacity: fade,
                child: Transform.scale(
                  scale: 0.9 + 0.3 * (1 - t),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                          color: Colors.white, fontWeight: FontWeight.w700),
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

class _BonusRipplePainter extends CustomPainter {
  final Offset center;
  final double t; // 0..1
  final double cell;
  final double fade; // 0..1

  _BonusRipplePainter({
    required this.center,
    required this.t,
    required this.cell,
    required this.fade,
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

    canvas.drawCircle(center, r1, p1);
    canvas.drawCircle(center, r2, p2);
    canvas.drawCircle(center, r3, p3);
  }

  @override
  bool shouldRepaint(covariant _BonusRipplePainter old) {
    return old.t != t ||
        old.center != center ||
        old.cell != cell ||
        old.fade != fade;
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
  final Direction previousDirection;
  final CatSkin skin;
  final Animation<double> movement;

  final Color bodyDark;
  final Color bodyLight;
  final ui.Image? headImage; // NEU

  _BoardPainter({
    required this.rows,
    required this.cols,
    required this.cell,
    required this.snake,
    required this.previousSnake,
    required this.food,
    required this.mouse,
    required this.direction,
    required this.previousDirection,
    required this.skin,
    required this.movement,
    required this.bodyDark,
    required this.bodyLight,
    required this.headImage,
  }) : super(repaint: movement);

  @override
  void paint(Canvas canvas, Size size) {
    final W = cell * cols;
    final H = cell * rows;

    // Hintergrund + Grid (Glasoptik)
    final gridPaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

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

    // „Glas“-Füllung
    final boardRect = Rect.fromLTWH(0, 0, W, H);
    final bgPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0x26FFFFFF), Color(0x0DFFFFFF)],
      ).createShader(boardRect);
    canvas.drawRRect(boardRRect, bgPaint);

    // dezentes Grid
    for (int y = 0; y <= rows; y++) {
      canvas.drawLine(Offset(0, y * cell), Offset(W, y * cell), gridPaint);
    }
    for (int x = 0; x <= cols; x++) {
      canvas.drawLine(Offset(x * cell, 0), Offset(x * cell, H), gridPaint);
    }

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
      final bend = sin(snake.length * 1.7) * cell * 0.12;
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

    // Futter (🐟)
    if (food != null) {
      final fCenter = Offset((food!.x + 0.5) * cell, (food!.y + 0.5) * cell);
      _drawEmoji(canvas, '🐟', fCenter, cell * 0.9);
    }

    // Maus (🐭)
    if (mouse != null) {
      final mCenter = Offset((mouse!.x + 0.5) * cell, (mouse!.y + 0.5) * cell);
      _drawEmoji(canvas, '🐭', mCenter, cell * 0.9);
    }

    // Kopf zeichnen
    if (snake.isNotEmpty) {
      final headCenter = wrap(centers.first);
      final headSize = cell * 1.02;
      double angleFor(Direction value) => switch (value) {
            Direction.right => 0.0,
            Direction.down => pi / 2,
            Direction.left => pi,
            Direction.up => -pi / 2,
          };
      final previousAngle = angleFor(previousDirection);
      final targetAngle = angleFor(direction);
      var angleDelta = (targetAngle - previousAngle + pi) % (2 * pi) - pi;
      if (angleDelta == -pi) angleDelta = pi;
      final angle = previousAngle + angleDelta * moveT;

      canvas.drawCircle(
        headCenter + Offset(0, cell * 0.08),
        headSize * 0.45,
        Paint()..color = Colors.black.withValues(alpha: 0.22),
      );
      canvas.save();
      canvas.translate(headCenter.dx, headCenter.dy);
      canvas.rotate(angle);
      final dst = Rect.fromCenter(
        center: Offset.zero,
        width: headSize,
        height: headSize,
      );

      if (headImage != null) {
        canvas.drawImageRect(
          headImage!,
          Rect.fromLTWH(
              0, 0, headImage!.width.toDouble(), headImage!.height.toDouble()),
          dst,
          Paint(),
        );
      } else {
        _drawEmoji(canvas, '🐱', Offset.zero, headSize); // Fallback
      }
      canvas.restore();
    }

    canvas.restore();
  }

  void _drawEmoji(Canvas canvas, String emoji, Offset center, double sizePx) {
    final tp = TextPainter(
      text: TextSpan(text: emoji, style: TextStyle(fontSize: sizePx)),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    final pos = center - Offset(tp.width / 2, tp.height / 2);
    tp.paint(canvas, pos);
  }

  @override
  bool shouldRepaint(covariant _BoardPainter old) {
    return old.snake != snake ||
        old.previousSnake != previousSnake ||
        old.food != food ||
        old.mouse != mouse ||
        old.direction != direction ||
        old.previousDirection != previousDirection ||
        old.skin != skin ||
        old.cell != cell ||
        old.cols != cols ||
        old.rows != rows ||
        old.bodyDark != bodyDark ||
        old.bodyLight != bodyLight ||
        old.headImage != headImage; // NEU
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
