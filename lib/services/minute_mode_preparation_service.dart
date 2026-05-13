import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'question_generator_service.dart';

enum MinuteModePreparationStatus {
  idle,
  pending,
  ready,
}

class MinuteModePreparedRun {
  const MinuteModePreparedRun({
    required this.gameId,
    required this.category,
    required this.questions,
  });

  final String gameId;
  final String category;
  final List<Map<String, dynamic>> questions;
}

class MinuteModePreparationService extends ChangeNotifier {
  MinuteModePreparationService._();

  static final MinuteModePreparationService instance =
      MinuteModePreparationService._();

  static const int gemEntryCost = 5;
  static const int questionTargetCount = 15;
  static const String _preparedRunStorageKey = 'minute_mode_prepared_run';

  final _supabase = Supabase.instance.client;

  MinuteModePreparationStatus _status = MinuteModePreparationStatus.idle;
  MinuteModePreparedRun? _preparedRun;

  MinuteModePreparationStatus get status => _status;

  bool get isPending => _status == MinuteModePreparationStatus.pending;

  bool get isReady => _status == MinuteModePreparationStatus.ready;

  Future<void> restorePreparedRun() async {
    _preparedRun = null;
    _status = MinuteModePreparationStatus.idle;

    final user = _supabase.auth.currentUser;
    if (user == null) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_preparedRunStorageKeyForUser(user.id));
    if (raw == null || raw.isEmpty) {
      return;
    }

    try {
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      final statusRaw = (payload['status'] ?? '').toString();
      final status = _statusFromStorage(statusRaw);

      if (status == MinuteModePreparationStatus.pending) {
        _status = MinuteModePreparationStatus.pending;
        notifyListeners();
        return;
      }

      if (status != MinuteModePreparationStatus.ready) {
        await prefs.remove(_preparedRunStorageKeyForUser(user.id));
        return;
      }

      final gameId = (payload['game_id'] ?? '').toString();
      final category = (payload['category'] ?? '').toString();
      final questionsRaw = (payload['questions'] as List<dynamic>? ?? const []);
      final questions = questionsRaw
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();

      if (gameId.isEmpty || category.isEmpty || questions.isEmpty) {
        await prefs.remove(_preparedRunStorageKeyForUser(user.id));
        return;
      }

      _preparedRun = MinuteModePreparedRun(
        gameId: gameId,
        category: category,
        questions: questions,
      );
      _status = status;
      notifyListeners();
    } catch (_) {
      await prefs.remove(_preparedRunStorageKeyForUser(user.id));
    }
  }

  Future<bool> startPreparation({required String category}) async {
    if (isPending || isReady) return false;

    final user = _supabase.auth.currentUser;
    if (user == null) return false;

    _status = MinuteModePreparationStatus.pending;
    await persistStatusOnly();
    notifyListeners();
    unawaited(_runPreparation(userId: user.id, category: category));
    return true;
  }

  Future<void> _runPreparation({
    required String userId,
    required String category,
  }) async {
    var gemsDeducted = false;
    String? gameId;

    try {
      final latestProfile = await _supabase
          .from('user_profiles')
          .select('gem_count')
          .eq('id', userId)
          .single();

      final latestGemCount = (latestProfile['gem_count'] ?? 0) as int;
      if (latestGemCount < gemEntryCost) {
        await clearPersistedPreparedRun();
        _status = MinuteModePreparationStatus.idle;
        notifyListeners();
        return;
      }

      await _supabase
          .from('user_profiles')
          .update({'gem_count': latestGemCount - gemEntryCost}).eq('id', userId);
      gemsDeducted = true;

      final gameInsert = await _supabase
          .from('unlimited_mode')
          .insert({
            'creator_id': userId,
            'player_categories': {
              userId: [category],
            },
            'scores': {userId: 0},
            'status': 'pending',
          })
          .select('id')
          .single();

      gameId = (gameInsert['id'] ?? '').toString();
      if (gameId.isEmpty) {
        throw Exception('Failed to create minute mode game.');
      }
      final loadedQuestions = await generateQuestionsForCategories(
        categoryNames: [category],
        round: 1,
        questionTargetCountOverride: questionTargetCount,
        allowedDifficultiesOverride: ['easy', 'medium'],
      );

      if (loadedQuestions.isEmpty) {
        throw Exception('No questions generated for minute mode.');
      }

      _preparedRun = MinuteModePreparedRun(
        gameId: gameId,
        category: category,
        questions: loadedQuestions,
      );
      await persistPreparedRun();
      _status = MinuteModePreparationStatus.ready;
      notifyListeners();

      try {
        await _supabase
            .from('unlimited_mode')
            .update({'status': 'ready'}).eq('id', gameId);
      } catch (_) {
        // Fallback for DBs that do not yet allow "ready" in status checks.
        try {
          await _supabase
              .from('unlimited_mode')
              .update({'status': 'active'}).eq('id', gameId);
        } catch (_) {}
      }
    } catch (_) {
      if (gameId != null && gameId.isNotEmpty) {
        try {
          await _supabase
              .from('unlimited_mode')
              .update({'status': 'failed'}).eq('id', gameId);
        } catch (_) {}
      }

      if (gemsDeducted) {
        try {
          final row = await _supabase
              .from('user_profiles')
              .select('gem_count')
              .eq('id', userId)
              .single();
          final currentGemCount = (row['gem_count'] ?? 0) as int;
          await _supabase.from('user_profiles').update(
            {'gem_count': currentGemCount + gemEntryCost},
          ).eq('id', userId);
        } catch (_) {}
      }

      _preparedRun = null;
      await clearPersistedPreparedRun();
      _status = MinuteModePreparationStatus.idle;
      notifyListeners();
    }
  }

  Future<void> markRunActive() async {
    final run = _preparedRun;
    if (run == null) return;
    try {
      await _supabase
          .from('unlimited_mode')
          .update({'status': 'active'}).eq('id', run.gameId);
    } catch (_) {}
  }

  MinuteModePreparedRun? consumePreparedRun() {
    final run = _preparedRun;
    _preparedRun = null;
    unawaited(clearPersistedPreparedRun());
    _status = MinuteModePreparationStatus.idle;
    notifyListeners();
    return run;
  }

  String _preparedRunStorageKeyForUser(String userId) {
    return '$_preparedRunStorageKey:$userId';
  }

  MinuteModePreparationStatus _statusFromStorage(String value) {
    switch (value) {
      case 'pending':
        return MinuteModePreparationStatus.pending;
      case 'ready':
        return MinuteModePreparationStatus.ready;
      default:
        return MinuteModePreparationStatus.idle;
    }
  }

  String _statusToStorage(MinuteModePreparationStatus status) {
    switch (status) {
      case MinuteModePreparationStatus.pending:
        return 'pending';
      case MinuteModePreparationStatus.ready:
        return 'ready';
      case MinuteModePreparationStatus.idle:
        return 'idle';
    }
  }

  Future<void> persistStatusOnly() async {
    final user = _supabase.auth.currentUser;
    if (user == null) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final payload = {
      'status': _statusToStorage(_status),
    };
    await prefs.setString(
      _preparedRunStorageKeyForUser(user.id),
      jsonEncode(payload),
    );
  }

  Future<void> persistPreparedRun() async {
    final user = _supabase.auth.currentUser;
    final run = _preparedRun;
    if (user == null || run == null) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final payload = {
      'status': _statusToStorage(MinuteModePreparationStatus.ready),
      'game_id': run.gameId,
      'category': run.category,
      'questions': run.questions,
    };
    await prefs.setString(
      _preparedRunStorageKeyForUser(user.id),
      jsonEncode(payload),
    );
  }

  Future<void> clearPersistedPreparedRun() async {
    final user = _supabase.auth.currentUser;
    if (user == null) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_preparedRunStorageKeyForUser(user.id));
  }
}
