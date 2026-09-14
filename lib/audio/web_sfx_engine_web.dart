import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Low-latency sound effects for browsers.
///
/// Short tones are scheduled directly on one reusable AudioContext. This
/// avoids network, decoding and HTMLAudio startup delays during gameplay.
class WebSfxEngine {
  web.AudioContext? _context;
  bool _disposed = false;
  bool _primed = false;

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
    gain.connect(context.destination);
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
