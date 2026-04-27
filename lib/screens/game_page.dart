import 'dart:ui'; // für BackdropFilter / ImageFilter.blur
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:ui' as ui;
import 'package:flutter/services.dart' show rootBundle;
import '../constants/game_constants.dart';

class GamePage extends StatefulWidget {
  const GamePage({super.key});

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage>
    with SingleTickerProviderStateMixin {
  // Spielfeld
  static const int rows = 22;
  static const int cols = 16;

  final Random _rand = Random();
  List<Point<int>> snake = [];
  Direction dir = Direction.right;
  Point<int>? food;

  // Maus (langsam, bewegt sich selten)
  Point<int>? mouse;
  int _mouseStepEvery = 12; // je größer, desto seltener bewegt sich die Maus
  int _mouseTick = 0;

  // Game loop
  Timer? _timer;
  int tickMs = 180;
  int score = 0;
  bool paused = false;
  bool wrapWalls = true; // Wrap standardmäßig EIN

  // Audio
  late AudioPlayer _bgm; // wird in _initAudio erstellt
  final AudioPlayer _sfxEat = AudioPlayer();
  final AudioPlayer _sfxMouse = AudioPlayer();
  final AudioPlayer _sfxOver = AudioPlayer();
  bool soundOn = true;

  // Bonus-Animation (verlängert + Fade)
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

  void _newGame() async {
    _timer?.cancel();
    score = 0;
    tickMs = 180;
    paused = false;
    dir = Direction.right;

    snake = [
      Point<int>(cols ~/ 2 - 1, rows ~/ 2),
      Point<int>(cols ~/ 2 - 2, rows ~/ 2),
      Point<int>(cols ~/ 2 - 3, rows ~/ 2),
    ];

    mouse = null;
    _mouseTick = 0;

    _spawnFood();
    _spawnMouse();
    _startTimer();

    // WICHTIG: nur auf User-Geste hin (dieser Button-Click) starten
    await _startBgmIfAllowed();

    setState(() {});
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(milliseconds: tickMs), (_) => _tick());
  }

  void _togglePause() async {
    setState(() => paused = !paused);
    if (!soundOn) return;

    if (paused) {
      await _bgm.pause();
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
        if (cand.x < 0 || cand.x >= cols || cand.y < 0 || cand.y >= rows)
          continue;
      }
      if (!snake.contains(cand) && (food == null || cand != food)) {
        mouse = cand;
        return;
      }
    }
    // sonst stehen bleiben
  }

  void _changeDir(Direction next) {
    if ((dir == Direction.up && next == Direction.down) ||
        (dir == Direction.down && next == Direction.up) ||
        (dir == Direction.left && next == Direction.right) ||
        (dir == Direction.right && next == Direction.left)) {
      return;
    }
    setState(() => dir = next);
  }

  void _showMouseBonus(Point<int> at) {
    _bonusAt = at;
    HapticFeedback.mediumImpact();
    _bonusCtrl.forward(from: 0);
  }

  void _tick() {
    if (!mounted || paused) return;

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

    if (snake.contains(next)) {
      _gameOver();
      return;
    }

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
        if (soundOn) _sfxEat.play(AssetSource('sfx/eat.wav'));
        _spawnFood();
      } else if (ateMouse) {
        score += 30; // Bonus
        if (soundOn) _sfxMouse.play(AssetSource('sfx/mouse.wav'));
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
        if (soundOn) _sfxMouse.play(AssetSource('sfx/mouse.wav'));
        _showMouseBonus(snake.first);
        _spawnMouse();
      }
    });
  }

  void _gameOver() {
    _timer?.cancel();
    if (soundOn) _sfxOver.play(AssetSource('sfx/game_over.wav'));
    _bgm.pause();

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
            child: const Text('Neu starten'),
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

  Future<void> _verifyAssets() async {
    for (final p in const [
      'assets/cats/black.png',
      'assets/cats/red.png',
      'assets/cats/tux.png', // wichtig!
    ]) {
      try {
        await rootBundle.load(p);
      } catch (e) {
        debugPrint('Asset fehlt: $p -> $e');
      }
    }
  }

  Future<void> _pickSkin() async {
    final choice = await showModalBottomSheet<CatSkin?>(
      context: context,
      backgroundColor: Colors.black.withOpacity(0.7),
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

    // Audio nach dem ersten Frame initialisieren (mobil sicherer)
    WidgetsBinding.instance.addPostFrameCallback((_) => _initAudio());

    // Spiel starten + sofort loslaufen
    _newGame();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      paused = false;
      _tick(); // erster Schritt sofort
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _bonusCtrl.dispose();
    _bgmSub?.cancel();
    _bgm.stop();
    _bgm.dispose();
    _sfxEat.dispose();
    _sfxMouse.dispose();
    _sfxOver.dispose();
    super.dispose();
  }

  bool _bgmEverStarted =
      false; // Haben wir schon einmal wirklich play() gemacht?
  PlayerState _bgmState = PlayerState.stopped;
  StreamSubscription<PlayerState>? _bgmSub;

  Future<void> _initAudio() async {
    _bgm = AudioPlayer();
    await _bgm.setReleaseMode(ReleaseMode.loop);
    await _bgm.setVolume(0.80); // vorher 0.35 -> etwas lauter

    // Kein setSource, kein play — Quelle wird beim ersten Start gesetzt.
    _bgmSub?.cancel();
    _bgmSub = _bgm.onPlayerStateChanged.listen((s) => _bgmState = s);
  }

  Future<void> _startBgmIfAllowed() async {
    if (!soundOn) return;

    if (!_bgmEverStarted) {
      // Erstes Mal: richtige Quelle spielen (User-Geste nötig, z.B. Button „Neu“)
      await _bgm.play(AssetSource('music/ukulele.mp3'));
      _bgmEverStarted = true;
    } else if (_bgmState != PlayerState.playing) {
      // Danach reicht resume()
      await _bgm.resume();
    }
  }

  @override
  Widget build(BuildContext context) {
    final (fallbackDark, fallbackLight) = skinBodyColors[selectedSkin]!;
    final bodyDark = _autoBodyDark ?? fallbackDark;
    final bodyLight = _autoBodyLight ?? fallbackLight;

    return Scaffold(
      appBar: AppBar(title: const Text('Cat Snake'), centerTitle: true),
      body: SafeArea(
        child: Stack(
          children: [
            // Hintergrund-Gradient
            Positioned.fill(
              child: DecoratedBox(
                decoration: const BoxDecoration(
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
            // Inhalt
            Column(
              children: [
                _buildHud(),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final cell = _cellSize(constraints.biggest);
                      return GestureDetector(
                        onHorizontalDragUpdate: _onHorizontalDrag,
                        onVerticalDragUpdate: _onVerticalDrag,
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: cols / rows,
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
                                      food: food,
                                      mouse: mouse,
                                      bodyDark: bodyDark, // Dynamische Farben
                                      bodyLight: bodyLight, // Dynamische Farben
                                      headImage: _headImage,
                                    ),
                                  ),
                                  // vorhandenes Bonus-Overlay:
                                  IgnorePointer(child: _buildBonusFx(cell)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 12, top: 6),
                  child: _DPad(
                    onUp: () => _changeDir(Direction.up),
                    onDown: () => _changeDir(Direction.down),
                    onLeft: () => _changeDir(Direction.left),
                    onRight: () => _changeDir(Direction.right),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHud() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Colors.black.withOpacity(0.35),
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
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        const Text('Wrap'),
                        Switch(
                          value: wrapWalls,
                          onChanged: (v) => setState(() => wrapWalls = v),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: paused ? 'Fortsetzen' : 'Pause',
                          onPressed: _togglePause,
                          icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                        ),
                        IconButton(
                          tooltip: 'Katze wählen',
                          onPressed: _pickSkin,
                          icon: const Icon(Icons.pets),
                        ),
                        IconButton(
                          tooltip: 'Sound an/aus',
                          onPressed: () async {
                            setState(() => soundOn = !soundOn);
                            if (soundOn) {
                              await _startBgmIfAllowed();
                            } else {
                              await _bgm.pause();
                            }
                          },
                          icon: Icon(
                              soundOn ? Icons.volume_up : Icons.volume_off),
                        ),
                        const SizedBox(width: 4),
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
                                horizontal: 14, vertical: 10),
                            textStyle:
                                const TextStyle(fontWeight: FontWeight.w600),
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
      ),
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
                          color: Colors.black.withOpacity(0.3),
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
      ..color = Colors.teal.withOpacity(0.70 * fade);

    final p2 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withOpacity(0.45 * fade);

    final p3 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.tealAccent.withOpacity(0.25 * fade);

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
  final Point<int>? food;
  final Point<int>? mouse;

  final Color bodyDark;
  final Color bodyLight;
  final ui.Image? headImage; // NEU

  _BoardPainter({
    required this.rows,
    required this.cols,
    required this.cell,
    required this.snake,
    required this.food,
    required this.mouse,
    required this.bodyDark,
    required this.bodyLight,
    required this.headImage,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final W = cell * cols;
    final H = cell * rows;

    // Hintergrund + Grid (Glasoptik)
    final gridPaint = Paint()
      ..color = Colors.grey.withOpacity(0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    final boardRRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, W, H),
      const Radius.circular(16),
    );

    // weicher Schatten
    final shadow = Paint()
      ..color = Colors.black.withOpacity(0.25)
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

    // Zentren der Zellen (original)
    final centersOrig = <Offset>[
      for (final p in snake) Offset((p.x + 0.5) * cell, (p.y + 0.5) * cell),
    ];

    // Unwrap: wähle pro Segment die nächstliegende gewrappt/geoffsette Position
    List<Offset> _unwrapCenters(List<Offset> c) {
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

    Offset _wrap(Offset o) {
      double wrap1(double v, double max) {
        final m = v % max;
        return m < 0 ? m + max : m;
      }

      return Offset(wrap1(o.dx, W), wrap1(o.dy, H));
    }

    final centers = _unwrapCenters(centersOrig);

    // Clip auf Brett
    canvas.save();
    canvas.clipRRect(boardRRect);

    // Schatten unter dem Körper
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.12)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    double radiusAt(int i) {
      final headR = cell * 0.42;
      final tailR = cell * 0.25;
      if (centers.length <= 1) return headR;
      final t = 1.0 - (i / (centers.length - 1));
      return tailR + (headR - tailR) * t;
    }

    for (int i = centers.length - 1; i > 0; i--) {
      final double w = 2.0 * min(radiusAt(i), radiusAt(i - 1)).toDouble() + 2.0;
      shadowPaint.strokeWidth = w;
      canvas.drawLine(
        centers[i] + const Offset(0, 2),
        centers[i - 1] + const Offset(0, 2),
        shadowPaint,
      );
    }

    // Körperlinien (glatt, runde Kappen)
    final bodyPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    for (int i = centers.length - 1; i > 0; i--) {
      final t = 1.0 - (i / (centers.length - 1));
      final color = Color.lerp(bodyDark, bodyLight, t)!.withOpacity(0.95);
      bodyPaint
        ..color = color
        ..strokeWidth = 2.0 * min(radiusAt(i), radiusAt(i - 1)).toDouble();
      canvas.drawLine(centers[i], centers[i - 1], bodyPaint);
    }

    // Gelenk-Kreise (Weichzeichnung) – in Skin-Farben (dunkel → hell)
    final jointPaint = Paint()..style = PaintingStyle.fill;
    for (int i = centers.length - 1; i >= 0; i--) {
      final r = radiusAt(i);
      final t = 1.0 - (i / centers.length); // 0 (=Schwanz) … 1 (=Kopf)
      jointPaint.color = Color.lerp(bodyDark, bodyLight, t)!;
      canvas.drawCircle(_wrap(centers[i]), r, jointPaint);

      // dezenter Glanz
      final highlight = Paint()..color = Colors.white.withOpacity(0.08);
      canvas.drawCircle(
          _wrap(centers[i]) + Offset(-r * 0.25, -r * 0.25), r * 0.7, highlight);
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
      final head = snake.first;
      final headCenter = Offset((head.x + 0.5) * cell, (head.y + 0.5) * cell);
      final headSize = cell * 0.9;
      final dst = Rect.fromCenter(
        center: headCenter,
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
        _drawEmoji(canvas, '🐱', headCenter, headSize); // Fallback
      }
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
        old.food != food ||
        old.mouse != mouse ||
        old.cell != cell ||
        old.cols != cols ||
        old.rows != rows ||
        old.headImage != headImage; // NEU
  }
}

class _DPad extends StatelessWidget {
  final VoidCallback onUp;
  final VoidCallback onDown;
  final VoidCallback onLeft;
  final VoidCallback onRight;

  const _DPad({
    required this.onUp,
    required this.onDown,
    required this.onLeft,
    required this.onRight,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final btnStyle = ElevatedButton.styleFrom(
      minimumSize: const Size(64, 64),
      shape: const CircleBorder(),
      padding: EdgeInsets.zero,
    );
    return SizedBox(
      width: 260,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            ElevatedButton(
                onPressed: onUp,
                style: btnStyle,
                child: const Icon(Icons.keyboard_arrow_up, size: 36)),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            ElevatedButton(
                onPressed: onLeft,
                style: btnStyle,
                child: const Icon(Icons.keyboard_arrow_left, size: 36)),
            const SizedBox(width: 16),
            ElevatedButton(
                onPressed: onRight,
                style: btnStyle,
                child: const Icon(Icons.keyboard_arrow_right, size: 36)),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            ElevatedButton(
                onPressed: onDown,
                style: btnStyle,
                child: const Icon(Icons.keyboard_arrow_down, size: 36)),
          ]),
        ],
      ),
    );
  }
}