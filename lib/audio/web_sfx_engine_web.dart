import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Low-latency sound effects for browsers.
///
/// Short tones are scheduled directly on one reusable AudioContext. This
/// avoids network, decoding and HTMLAudio startup delays during gameplay.
class WebSfxEngine {
  web.AudioContext? _context;
  web.GainNode? _musicMaster;
  bool _musicMasterConnected = false;
  Timer? _musicTimer;
  bool _disposed = false;
  bool _primed = false;
  bool _musicPlaying = false;
  int _musicTheme = 0;
  int _musicVariation = 0;
  int _musicStep = 0;

  Future<void> unlock() async {
    if (_disposed) return;

    final context = _context ??= _createContext();
    try {
      if (context.state != 'running') {
        await context.resume().toDart.timeout(const Duration(seconds: 1));
      }
      if (!_primed && context.state == 'running') {
        _primed = true;
        _tone(
          context,
          frequency: 440,
          endFrequency: 440,
          duration: 0.012,
          volume: 0.0001,
        );
      }
    } catch (_) {
      // Some browsers keep the context suspended until another user gesture.
    }
  }

  web.AudioContext _createContext() {
    try {
      return web.AudioContext(
        web.AudioContextOptions(latencyHint: 'interactive'.toJS),
      );
    } catch (_) {
      return web.AudioContext();
    }
  }

  void playEat() {
    _play((context) {
      _tone(
        context,
        frequency: 620,
        endFrequency: 900,
        duration: 0.1,
        volume: 0.18,
      );
      _tone(
        context,
        frequency: 860,
        endFrequency: 1220,
        delay: 0.055,
        duration: 0.12,
        volume: 0.12,
        type: 'triangle',
      );
    });
  }

  void playMouse() {
    _play((context) {
      _tone(
        context,
        frequency: 920,
        endFrequency: 1550,
        duration: 0.13,
        volume: 0.14,
        type: 'triangle',
      );
      _tone(
        context,
        frequency: 1320,
        endFrequency: 760,
        delay: 0.09,
        duration: 0.14,
        volume: 0.11,
        type: 'triangle',
      );
    });
  }

  void playGameOver() {
    _play((context) {
      for (final note in const [
        (0.0, 392.0),
        (0.14, 311.0),
        (0.28, 233.0),
      ]) {
        _tone(
          context,
          frequency: note.$2,
          endFrequency: note.$2 * 0.88,
          delay: note.$1,
          duration: 0.2,
          volume: 0.14,
          type: 'triangle',
        );
      }
    });
  }

  /// Starts a quiet, looping melody generated in the shared AudioContext.
  ///
  /// Each level has its own tempo and note palette. A round can select one of
  /// three variations without loading or decoding another audio file.
  void startMusic({required int theme, required int variation}) {
    if (_disposed) return;

    final nextTheme = theme < 0 ? 0 : (theme > 2 ? 2 : theme);
    final nextVariation = variation < 0 ? 0 : (variation > 2 ? 2 : variation);
    final melodyChanged =
        nextTheme != _musicTheme || nextVariation != _musicVariation;

    _musicTheme = nextTheme;
    _musicVariation = nextVariation;
    if (melodyChanged) {
      _musicStep = 0;
    }
    _musicPlaying = true;
    _musicTimer?.cancel();

    final context = _context;
    if (context != null && context.state == 'running') {
      _fadeMusicIn(context);
      _playMusicStep(context);
    } else {
      unawaited(_resumeMusic());
    }
    _musicTimer = Timer.periodic(
      _musicInterval,
      (_) {
        final activeContext = _context;
        if (_musicPlaying &&
            activeContext != null &&
            activeContext.state == 'running') {
          _playMusicStep(activeContext);
        }
      },
    );
  }

  void pauseMusic() {
    _musicPlaying = false;
    _musicTimer?.cancel();
    _musicTimer = null;

    final context = _context;
    final master = _musicMaster;
    if (context == null || master == null || context.state != 'running') return;
    final now = context.currentTime;
    master.gain.cancelScheduledValues(now);
    master.gain.setValueAtTime(master.gain.value, now);
    master.gain.linearRampToValueAtTime(0.0001, now + 0.08);
  }

  Future<void> _resumeMusic() async {
    await unlock();
    final context = _context;
    if (_musicPlaying &&
        !_disposed &&
        context != null &&
        context.state == 'running') {
      _fadeMusicIn(context);
      _playMusicStep(context);
    }
  }

  Duration get _musicInterval => switch (_musicTheme) {
        0 => const Duration(milliseconds: 560),
        1 => const Duration(milliseconds: 430),
        _ => const Duration(milliseconds: 340),
      };

  List<double> get _musicPattern => switch ((_musicTheme, _musicVariation)) {
        // Wiese: luftig, ruhig, mit Pausen zwischen den Tönen.
        (0, 0) => const [523.25, 0, 659.25, 0, 783.99, 0, 659.25, 0],
        (0, 1) => const [587.33, 0, 698.46, 0, 880.00, 0, 698.46, 0],
        (0, _) => const [493.88, 0, 659.25, 0, 739.99, 0, 587.33, 0],

        // Wohnzimmer: warm und etwas verspielter.
        (1, 0) => const [
            261.63,
            329.63,
            392.00,
            523.25,
            392.00,
            329.63,
            293.66,
            392.00
          ],
        (1, 1) => const [
            293.66,
            349.23,
            440.00,
            587.33,
            440.00,
            392.00,
            329.63,
            440.00
          ],
        (1, _) => const [
            329.63,
            392.00,
            493.88,
            392.00,
            523.25,
            440.00,
            392.00,
            293.66
          ],

        // Garten: heller, flinker und abenteuerlicher.
        (2, 0) => const [
            392.00,
            493.88,
            587.33,
            783.99,
            659.25,
            587.33,
            493.88,
            659.25
          ],
        (2, 1) => const [
            440.00,
            523.25,
            659.25,
            880.00,
            739.99,
            659.25,
            587.33,
            698.46
          ],
        (2, _) => const [
            349.23,
            440.00,
            523.25,
            698.46,
            587.33,
            523.25,
            440.00,
            587.33
          ],
        _ => const [523.25, 659.25, 783.99, 659.25],
      };

  void _fadeMusicIn(web.AudioContext context) {
    final master = _ensureMusicMaster(context);
    final now = context.currentTime;
    master.gain.cancelScheduledValues(now);
    master.gain.setValueAtTime(0.0001, now);
    master.gain.linearRampToValueAtTime(1, now + 0.12);
  }

  void _playMusicStep(web.AudioContext context) {
    final pattern = _musicPattern;
    final frequency = pattern[_musicStep % pattern.length];
    _musicStep++;
    if (frequency <= 0) return;

    final master = _ensureMusicMaster(context);
    final duration = switch (_musicTheme) {
      0 => 0.42,
      1 => 0.28,
      _ => 0.21,
    };
    final volume = switch (_musicTheme) {
      0 => 0.035,
      1 => 0.031,
      _ => 0.026,
    };
    _tone(
      context,
      frequency: frequency,
      endFrequency: frequency,
      duration: duration,
      volume: volume,
      type: _musicTheme == 0 ? 'sine' : 'triangle',
      destination: master,
    );

    // Ein sehr leiser Grundton macht die Melodie rund, ohne die Effekte zu
    // überdecken. Er erklingt nur auf jedem vierten Schritt.
    if (_musicStep % 4 == 1) {
      _tone(
        context,
        frequency: frequency / 2,
        endFrequency: frequency / 2,
        duration: duration * 1.7,
        volume: volume * 0.45,
        type: 'sine',
        destination: master,
      );
    }
  }

  web.GainNode _ensureMusicMaster(web.AudioContext context) {
    final master = _musicMaster ??= context.createGain();
    if (!_musicMasterConnected) {
      master.connect(context.destination);
      _musicMasterConnected = true;
    }
    return master;
  }

  void _play(void Function(web.AudioContext context) sound) {
    if (_disposed) return;
    final context = _context;
    if (context == null || context.state != 'running') {
      unawaited(_resumeAndPlay(sound));
      return;
    }
    sound(context);
  }

  Future<void> _resumeAndPlay(
    void Function(web.AudioContext context) sound,
  ) async {
    await unlock();
    final context = _context;
    if (!_disposed && context != null && context.state == 'running') {
      sound(context);
    }
  }

  void _tone(
    web.AudioContext context, {
    required double frequency,
    required double endFrequency,
    required double duration,
    required double volume,
    double delay = 0,
    String type = 'sine',
    web.AudioNode? destination,
  }) {
    final start = context.currentTime + delay;
    final end = start + duration;
    final oscillator = context.createOscillator();
    final gain = context.createGain();

    oscillator.type = type;
    oscillator.frequency.setValueAtTime(frequency, start);
    oscillator.frequency.exponentialRampToValueAtTime(endFrequency, end);
    gain.gain.setValueAtTime(0.0001, start);
    gain.gain.linearRampToValueAtTime(volume, start + 0.008);
    gain.gain.exponentialRampToValueAtTime(0.0001, end);

    oscillator.connect(gain);
    gain.connect(destination ?? context.destination);
    oscillator.onended = ((web.Event _) {
      oscillator.disconnect();
      gain.disconnect();
    }).toJS;
    oscillator.start(start);
    oscillator.stop(end + 0.015);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _musicPlaying = false;
    _musicTimer?.cancel();
    _musicTimer = null;
    _musicMaster?.disconnect();
    _musicMaster = null;
    _musicMasterConnected = false;
    final context = _context;
    _context = null;
    if (context == null || context.state == 'closed') return;
    try {
      await context.close().toDart.timeout(const Duration(seconds: 1));
    } catch (_) {
      // The browser may already have released the context.
    }
  }
}
