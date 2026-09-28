import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class LeaderboardEntry {
  const LeaderboardEntry({
    required this.userId,
    required this.playerName,
    required this.score,
  });

  final String userId;
  final String playerName;
  final int score;
}

class LeaderboardService {
  bool get isAvailable => Firebase.apps.isNotEmpty;
  String? get currentUserId =>
      isAvailable ? FirebaseAuth.instance.currentUser?.uid : null;

  CollectionReference<Map<String, dynamic>> _scores(String level) =>
      FirebaseFirestore.instance
          .collection('leaderboards')
          .doc(level)
          .collection('scores');

  Future<User?> _ensureSignedIn() async {
    if (!isAvailable) return null;
    try {
      return FirebaseAuth.instance.currentUser ??
          (await FirebaseAuth.instance.signInAnonymously()).user;
    } catch (error) {
      debugPrint('Anonyme Anmeldung fehlgeschlagen: $error');
      return null;
    }
  }

  Stream<List<LeaderboardEntry>> watchTop(
    String level, {
    int limit = 20,
  }) {
    if (!isAvailable) return Stream.value(const []);

    return _scores(level)
        .orderBy('score', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(
                (doc) => LeaderboardEntry(
                  userId: doc.id,
                  playerName: (doc.data()['playerName'] as String?) ?? 'Katze',
                  score: (doc.data()['score'] as num?)?.toInt() ?? 0,
                ),
              )
              .toList(growable: false),
        );
  }

  Future<bool> submitHighScore({
    required String level,
    required String playerName,
    required int score,
  }) async {
    final user = await _ensureSignedIn();
    if (user == null) return false;

    try {
      final reference = _scores(level).doc(user.uid);
      return FirebaseFirestore.instance.runTransaction((transaction) async {
        final existing = await transaction.get(reference);
        final previousScore =
            (existing.data()?['score'] as num?)?.toInt() ?? -1;
        if (previousScore > score) return false;

        transaction.set(reference, {
          'playerName': playerName.trim(),
          'score': score,
          'achievedAt': FieldValue.serverTimestamp(),
        });
        return true;
      });
    } catch (error) {
      debugPrint('Highscore konnte nicht übertragen werden: $error');
      return false;
    }
  }
}
