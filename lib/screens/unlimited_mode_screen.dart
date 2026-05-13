import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../constants/trivia_category_map.dart';
import '../dialogs/game_score_dialog.dart';
import '../services/minute_mode_preparation_service.dart';
import '../styles/question_style.dart';
import '../widgets/app_background.dart';

class UnlimitedModeScreen extends StatefulWidget {
  const UnlimitedModeScreen({
    super.key,
    this.preparedRun,
  });

  final MinuteModePreparedRun? preparedRun;

  @override
  State<UnlimitedModeScreen> createState() => _UnlimitedModeScreenState();
}

class _UnlimitedModeScreenState extends State<UnlimitedModeScreen> {
  static const int gemEntryCost = 5;
  static const int runDurationSeconds = 60;
  static const int timePenaltyOnWrongSeconds = 3;
  static const int questionTargetCount = 15;
  static const int rewardGemAmount = 10;
  static const int minimumScoreForReward = 10;

  final supabase = Supabase.instance.client;
  final random = Random();

  List<String> categoryOptions = [];
  String? selectedCategory;

  bool loadingCategories = true;
  bool isPreparingRun = false;
  bool loadingQuestions = false;
  bool runInProgress = false;
  bool turnUpdateInProgress = false;
  bool runFinalized = false;
  bool runSummaryShowing = false;
  bool exitPenaltyApplied = false;

  int timeLeft = runDurationSeconds;
  int currentQuestionIndex = 0;
  int roundScore = 0;
  int correctAnswersCount = 0;
  int rewardedGems = 0;

  String? temporaryGameId;
  String? selectedAnswer;
  bool revealAnswers = false;
  bool advanceScheduled = false;
  bool gameStarted = false;
  bool gemsDeducted = false;
  bool preserveBackgroundPreparedRunOnExit = false;

  Timer? timer;

  List<Map<String, dynamic>> questions = [];
  List<String> currentAnswers = [];

  @override
  void initState() {
    super.initState();
    if (widget.preparedRun != null) {
      loadingCategories = false;
      startPreparedRun(widget.preparedRun!);
      return;
    }
    loadCategoryOptions();
  }

  void startPreparedRun(MinuteModePreparedRun run) {
    questions = run.questions;
    temporaryGameId = run.gameId;
    selectedCategory = run.category;
    loadingQuestions = false;
    isPreparingRun = false;
    runInProgress = true;
    gameStarted = true;
    timeLeft = runDurationSeconds;
    currentQuestionIndex = 0;
    roundScore = 0;
    correctAnswersCount = 0;
    selectedAnswer = null;
    revealAnswers = false;
    buildAnswers();
    startRunTimer();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> loadCategoryOptions() async {
    setState(() {
      loadingCategories = true;
    });

    try {
      final rows = await supabase.from('categories').select('category_name');
      final fromDb = rows
          .map<String>((row) => (row['category_name'] ?? '').toString())
          .where((name) => triviaCategoryMap.containsKey(name))
          .toSet()
          .toList();

      final source = fromDb.isEmpty ? triviaCategoryMap.keys.toList() : fromDb;
      source.shuffle(random);

      setState(() {
        categoryOptions = source.take(5).toList();
        loadingCategories = false;
      });
    } catch (_) {
      final fallback = triviaCategoryMap.keys.toList()..shuffle(random);
      setState(() {
        categoryOptions = fallback.take(5).toList();
        loadingCategories = false;
      });
    }
  }

  int pointsForDifficulty(String difficulty) {
    switch (difficulty.toLowerCase()) {
      case 'easy':
        return 1;
      case 'medium':
        return 2;
      case 'hard':
        return 3;
      default:
        return 0;
    }
  }

  int totalPossiblePoints() {
    return questions.fold<int>(
      0,
      (sum, q) => sum + pointsForDifficulty((q['difficulty'] ?? '').toString()),
    );
  }

  void buildAnswers() {
    final q = questions[currentQuestionIndex];
    currentAnswers = [
      q['correct_answer'] as String,
      ...List<String>.from(q['wrong_answers'] as List<dynamic>),
    ];
    currentAnswers.shuffle(random);
  }

  void startRunTimer() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || runFinalized) {
        t.cancel();
        return;
      }

      if (timeLeft <= 0) {
        t.cancel();
        unawaited(showRunSummaryAndExit());
        return;
      }

      setState(() {
        timeLeft--;
      });

      if (timeLeft <= 0) {
        t.cancel();
        unawaited(showRunSummaryAndExit());
      }
    });
  }

  Future<void> refundEntryCostIfNeeded(String userId) async {
    if (!gemsDeducted || gameStarted) return;

    try {
      final row = await supabase
          .from('user_profiles')
          .select('gem_count')
          .eq('id', userId)
          .single();
      final currentGemCount = (row['gem_count'] ?? 0) as int;

      await supabase
          .from('user_profiles')
          .update({'gem_count': currentGemCount + gemEntryCost}).eq('id', userId);
      gemsDeducted = false;
    } catch (_) {
      // Best effort refund.
    }
  }

  Future<bool> cleanupTemporaryGameArtifacts() async {
    final gameId = temporaryGameId;
    if (gameId == null) return true;

    try {
      await supabase.from('unlimited_mode').delete().eq('id', gameId);
      temporaryGameId = null;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> applyExitPenaltyGem() async {
    if (exitPenaltyApplied) return;

    final user = supabase.auth.currentUser;
    if (user == null) return;

    final row = await supabase
        .from('user_profiles')
        .select('gem_count')
        .eq('id', user.id)
        .single();

    final currentGemCount = (row['gem_count'] ?? 0) as int;
    final updatedGemCount = max(0, currentGemCount - 1);

    await supabase
        .from('user_profiles')
        .update({'gem_count': updatedGemCount}).eq('id', user.id);
    exitPenaltyApplied = true;
  }

  Future<void> handleBackRequest() async {
    // During active prep/gameplay, keep existing leave behavior.
    if (isPreparingRun || loadingQuestions || runInProgress) {
      if (!mounted) return;
      Navigator.pop(context);
      return;
    }

    final shouldLeave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Leave Minute Mode?'),
          content: const Text(
            'Leaving Minute Mode now will cost 1 gem. \n And categories will refresh',
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Stay'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Leave'),
            ),
          ],
        );
      },
    );

    if (shouldLeave != true) {
      return;
    }

    try {
      await applyExitPenaltyGem();
    } catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Could not leave Minute Mode'),
          content: Text('Failed to apply exit gem cost: $e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> startRun() async {
    final category = selectedCategory;

    if (category == null) {
      return;
    }

    setState(() {
      isPreparingRun = true;
    });

    final queued = await MinuteModePreparationService.instance
        .startPreparation(category: category);
    if (!mounted) return;

    if (queued) {
      preserveBackgroundPreparedRunOnExit = true;
      Navigator.pop(context);
      return;
    }

    setState(() {
      isPreparingRun = false;
    });
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Could not start mode'),
        content: const Text(
          'Minute Mode could not be queued. It may already be loading.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void scheduleAdvance() {
    if (advanceScheduled || runFinalized) return;
    advanceScheduled = true;

    Future.delayed(const Duration(milliseconds: 700), () {
      if (!mounted || runFinalized) return;
      nextQuestion();
    });
  }

  void checkAnswer(String selected) {
    if (revealAnswers || runFinalized || questions.isEmpty || timeLeft <= 0) {
      return;
    }

    final q = questions[currentQuestionIndex];
    final correct = q['correct_answer'] as String;
    final difficulty = (q['difficulty'] ?? '').toString();

    if (selected == correct) {
      roundScore += pointsForDifficulty(difficulty);
      correctAnswersCount++;
    } else {
      timeLeft = max(0, timeLeft - timePenaltyOnWrongSeconds);
    }

    setState(() {
      selectedAnswer = selected;
      revealAnswers = true;
    });

    if (timeLeft <= 0) {
      unawaited(showRunSummaryAndExit());
      return;
    }

    scheduleAdvance();
  }

  void nextQuestion() {
    if (runFinalized) return;

    if (timeLeft <= 0) {
      unawaited(showRunSummaryAndExit());
      return;
    }

    if (currentQuestionIndex < questions.length - 1) {
      setState(() {
        currentQuestionIndex++;
        revealAnswers = false;
        selectedAnswer = null;
        advanceScheduled = false;
      });
      buildAnswers();
      return;
    }

    unawaited(showRunSummaryAndExit());
  }

  Color getAnswerBackground(String answerText) {
    if (!revealAnswers || questions.isEmpty) {
      return Colors.white;
    }

    final correct = questions[currentQuestionIndex]['correct_answer'] as String;
    if (answerText == correct) {
      return Colors.green;
    }

    final pickedWrong = selectedAnswer != null && selectedAnswer != correct;
    if (pickedWrong && answerText == selectedAnswer) {
      return Colors.red;
    }

    return Colors.white;
  }

  Color getAnswerTextColor(String answerText) {
    final bg = getAnswerBackground(answerText);
    return bg == Colors.white ? Colors.black : Colors.white;
  }

  Widget buildAnswerButton(String text) {
    final backgroundColor = getAnswerBackground(text);
    final textColor = getAnswerTextColor(text);

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: () => checkAnswer(text),
        style: QuestionStyles.answerButtonStyle.copyWith(
          backgroundColor: WidgetStatePropertyAll(backgroundColor),
          foregroundColor: WidgetStatePropertyAll(textColor),
          minimumSize: const WidgetStatePropertyAll(Size(0, 55)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          softWrap: true,
          overflow: TextOverflow.visible,
          style: QuestionStyles.answerTextStyle.copyWith(color: textColor),
        ),
      ),
    );
  }

  Future<void> finalizeRun() async {
    if (runFinalized || turnUpdateInProgress) return;

    turnUpdateInProgress = true;

    try {
      final userId = supabase.auth.currentUser!.id;

      final row = await supabase
          .from('user_profiles')
          .select('gem_count, correct_answers')
          .eq('id', userId)
          .single();

      final currentGemCount = (row['gem_count'] ?? 0) as int;
      final currentCorrectAnswers = (row['correct_answers'] ?? 0) as int;
      rewardedGems = roundScore > minimumScoreForReward ? rewardGemAmount : 0;

      await supabase.from('user_profiles').update({
        'gem_count': currentGemCount + rewardedGems,
        'correct_answers': currentCorrectAnswers + correctAnswersCount,
      }).eq('id', userId);

      final gameId = temporaryGameId;
      if (gameId != null) {
        await supabase
            .from('unlimited_mode')
            .update({
              'status': 'ended',
              'scores': {userId: roundScore},
            })
            .eq('id', gameId);
      }

      runFinalized = true;
    } finally {
      turnUpdateInProgress = false;
    }
  }

  Future<void> showRunSummaryAndExit() async {
    if (!mounted || runFinalized || runSummaryShowing) return;
    runSummaryShowing = true;

    timer?.cancel();

    final finalizeFuture = finalizeRun();

    await showTurnScoreDialog(
      context: context,
      finalizeFuture: finalizeFuture,
      earnedPoints: roundScore,
      possiblePoints: totalPossiblePoints(),
      scoreLabel: 'Score',
    );

    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Minute Mode Complete'),
          content: Text(
            rewardedGems > 0
                ? 'Score: $roundScore. Reward earned: $rewardedGems gems.'
                : 'Score: $roundScore. No gem reward this run.',
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        );
      },
    );

    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> abandonRunIfNeeded() async {
    timer?.cancel();
    if (preserveBackgroundPreparedRunOnExit) {
      return;
    }

    if (!gameStarted && supabase.auth.currentUser != null) {
      await refundEntryCostIfNeeded(supabase.auth.currentUser!.id);
    }
  }

  Widget buildCategoryPicker() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            const Text(
              'Minute Mode',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Pick 1 category. 60 seconds total, -5 seconds for wrong answers.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            const Text(
              'Entry cost: 5 gems | Reward: 10 gems if score is above 10',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 18),
            if (loadingCategories)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: categoryOptions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final category = categoryOptions[index];
                    final isSelected = selectedCategory == category;

                    return ElevatedButton(
                      onPressed: isPreparingRun
                          ? null
                          : () {
                              setState(() {
                                selectedCategory = category;
                              });
                            },
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 58),
                        backgroundColor:
                            isSelected ? const Color(0xFFD6E6FF) : null,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              category,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Icon(
                            isSelected
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: selectedCategory == null || isPreparingRun
                  ? null
                  : startRun,
              child: const Text('Start Minute Mode'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: isPreparingRun ? null : handleBackRequest,
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildLoadingState() {
    return const SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 14),
            Text('Loading Questions'),
          ],
        ),
      ),
    );
  }

  Widget buildGameplay() {
    if (questions.isEmpty) {
      return const SafeArea(
        child: Center(
          child: Text('No questions available for this run.'),
        ),
      );
    }

    final q = questions[currentQuestionIndex];
    final progress = timeLeft / runDurationSeconds;

    return SafeArea(
      child: Stack(
        children: [
          Column(
            children: [
              const SizedBox(height: 100),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Card(
                  elevation: 6,
                  shape: QuestionStyles.questionCardShape,
                  child: Container(
                    height: MediaQuery.of(context).size.height * 0.20,
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    alignment: Alignment.center,
                    child: Text(
                      q['question']?.toString() ?? '',
                      textAlign: TextAlign.center,
                      style: QuestionStyles.questionTextStyle,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: currentAnswers.map((a) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: buildAnswerButton(a),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Score: $roundScore',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          Positioned(
            top: 10,
            right: 10,
            child: Container(
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: QuestionStyles.timerContainerDecoration,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 42,
                        height: 42,
                        child: CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 5,
                          backgroundColor: QuestionStyles.timerBackgroundColor,
                          color: QuestionStyles.timerColor,
                        ),
                      ),
                      Text(
                        '$timeLeft',
                        style:
                            QuestionStyles.timerTextStyle.copyWith(fontSize: 14),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          unawaited(abandonRunIfNeeded());
          return;
        }
        unawaited(handleBackRequest());
      },
      child: Scaffold(
        body: AppBackground(
          child: loadingQuestions
              ? buildLoadingState()
              : runInProgress
                  ? buildGameplay()
                  : buildCategoryPicker(),
        ),
      ),
    );
  }
}
