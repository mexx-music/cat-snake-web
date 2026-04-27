class _GamePageState extends State<GamePage> {
  static const int rows = 22;
  static const int cols = 16;

  final Random _rand = Random();
  List<Point<int>> snake = [];
  Direction dir = Direction.right;
  Point<int>? food;
  Timer? _timer;
  int tickMs = 180;
  int score = 0;
  bool paused = false;
  bool wrapWalls = false;

  @override
  void initState() {
    super.initState();
    _newGame();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _newGame() {
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
    _spawnFood();
    _startTimer();
    setState(() {});
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(milliseconds: tickMs), (_) => _tick());
  }

  void _togglePause() => setState(() => paused = !paused);

  void _spawnFood() {
    final occupied = snake.toSet();
    while (true) {
      final p = Point<int>(_rand.nextInt(cols), _rand.nextInt(rows));
      if (!occupied.contains(p)) {
        food = p;
        return;
      }
    }
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
      snake = [next, ...snake];
      if (food != null && next == food) {
        score += 10;
        if (tickMs > 70 && score % 30 == 0) {
          tickMs -= 10;
          _startTimer();
        }
        _spawnFood();
      } else {
        snake.removeLast();
      }
    });
  }

  void _gameOver() {
    _timer?.cancel();
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

  // === HIER IST DIE build()-METHODE (wichtig!) ===
  @override
  Widget build(BuildContext context) {
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
                      Color(0xFF2C5364),
                    ],
                  ),
                ),
              ),
            ),

            // Inhalt
            Column(
              children: [
                _buildHud(), // Glas-Leiste oben

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
                            child: CustomPaint(
                              painter: _BoardPainter(
                                rows: rows,
                                cols: cols,
                                cell: cell,
                                snake: snake,
                                food: food,
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

  // HUD als eigene Methode (kein @override!)
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
                        const SizedBox(width: 4),
                        ElevatedButton.icon(
                          onPressed: _newGame,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Neu'),
                          style: ElevatedButton.styleFrom(
                            foregroundColor: Colors.white,
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

  double _cellSize(Size size) {
    final w = size.width, h = size.height;
    final cellW = w / cols, cellH = h / rows;
    return min(cellW, cellH);
  }
}
