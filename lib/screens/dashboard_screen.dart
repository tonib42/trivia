import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

//Models
import '../models/user_profile.dart';
import '../models/game.dart';

//Styles
import '../styles/dashboard_styles.dart';

//Screens
import 'player_select_screen.dart';
import 'settings_screen.dart';
import 'question_screen.dart';
import 'unlimited_mode_screen.dart';

//Dialogs
import '../dialogs/dashboard_dailogs.dart';
import '../dialogs/game_score_dialog.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/split_game_avatar.dart';
import '../widgets/app_background.dart';

//Services
import '../services/minute_mode_preparation_service.dart';
import '../services/question_generator_service.dart';

class DashboardScreen extends StatefulWidget
{
  final UserProfile userProfile;

  const DashboardScreen(
    {
      super.key,
      required this.userProfile,
    }
  );

  @override
  State<DashboardScreen> createState()
  {
    return _DashboardScreenState();
  }
}

class _DashboardScreenState extends State<DashboardScreen> 
{
  static const int gameCreationGemCost = 3;
  static const int minuteModeGemCost = 5;

  Color parseHexColor(String hex, {Color fallback = const Color(0xFF7D798A)})
  {
    final clean = hex.replaceAll('#', '').trim();
    if (clean.length != 6) return fallback;
    final value = int.tryParse(clean, radix: 16);
    if (value == null) return fallback;
    return Color(0xFF000000 | value);
  }

  Color blendWithWhite(Color color, double amount)
  {
    return Color.lerp(color, Colors.white, amount) ?? color;
  }

  Color blendWithBlack(Color color, double amount)
  {
    return Color.lerp(color, Colors.black, amount) ?? color;
  }

  BoxDecoration statsCardDecorationForProfile()
  {
    final base = parseHexColor(profile.statsCardColorHex);
    final top = blendWithWhite(base, 0.32);
    final bottom = blendWithBlack(base, 0.08);

    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          top,
          base,
          bottom,
        ],
      ),
      borderRadius: BorderRadius.circular(26),
      border: Border.all(
        color: blendWithWhite(base, 0.55),
        width: 2,
      ),
      boxShadow: [
        BoxShadow(
          color: blendWithBlack(base, 0.45).withValues(alpha: 0.35),
          blurRadius: 14,
          offset: const Offset(0, 6),
        ),
        BoxShadow(
          color: blendWithWhite(base, 0.6).withValues(alpha: 0.35),
          blurRadius: 8,
          offset: const Offset(0, -2),
        ),
      ],
    );
  }

  UserProfile fallbackProfile(String id)
  {
    return UserProfile.fromMap(
      {
        'id': id,
        'username': '?',
      },
    );
  }

  List<UserProfile> orderedPlayersForGame(
    Game game,
    Map<String, UserProfile> profilesById,
  )
  {
    final creator = profilesById[game.creatorId] ?? fallbackProfile(game.creatorId);

    final opponentId = game.playerIds.firstWhere(
      (id) => id != game.creatorId,
      orElse: () => game.creatorId,
    );
    final opponent = profilesById[opponentId] ?? fallbackProfile(opponentId);

    return [creator, opponent];
  }

  Widget buildGameAvatarButton(
    Game game,
    Map<String, UserProfile> profilesById, {
    VoidCallback? onTap,
  })
  {
    final players = orderedPlayersForGame(game, profilesById);

    final child = SplitGameAvatar(
      topLeftPlayer: players.first,
      bottomRightPlayer: players.last,
      size: DashboardStyles.gameCircleSize,
    );

    return Padding(
      padding: DashboardStyles.gameCirclePadding,
      child: GestureDetector(
        onTap: onTap,
        child: child,
      ),
    );
  }

  late UserProfile profile;
  final minuteModePreparation = MinuteModePreparationService.instance;

  @override
  void initState()
  {
    super.initState();
    profile = widget.userProfile;
    minuteModePreparation.addListener(onMinuteModePreparationChanged);
    unawaited(minuteModePreparation.restorePreparedRun());
  }

  @override
  void dispose()
  {
    minuteModePreparation.removeListener(onMinuteModePreparationChanged);
    super.dispose();
  }

  void onMinuteModePreparationChanged()
  {
    if (!mounted) return;
    setState(() {});
  }

  ButtonStyle minuteModeButtonStyle()
  {
    final status = minuteModePreparation.status;
    if (status == MinuteModePreparationStatus.pending)
    {
      return DashboardStyles.startGameButtonStyle.copyWith(
        backgroundColor: MaterialStateProperty.all(const Color(0xFFE53935)),
        foregroundColor: MaterialStateProperty.all(Colors.white),
      );
    }
    if (status == MinuteModePreparationStatus.ready)
    {
      return DashboardStyles.startGameButtonStyle.copyWith(
        backgroundColor: MaterialStateProperty.all(const Color(0xFF2E7D32)),
        foregroundColor: MaterialStateProperty.all(Colors.white),
      );
    }
    return DashboardStyles.startGameButtonStyle;
  }

  Future<void> showMinuteModePendingDialog() async
  {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Minute Mode"),
        content: const Text("Minute Mode is still loading."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }

  Future<void> showMinuteModeReadyDialog() async
  {
    final shouldStart = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Minute Mode"),
        content: const Text("Ready to play Minute Mode."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Back"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Start"),
          ),
        ],
      ),
    );

    if (shouldStart != true || !mounted) return;

    await minuteModePreparation.markRunActive();
    final run = minuteModePreparation.consumePreparedRun();
    if (run == null) return;

    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => UnlimitedModeScreen(preparedRun: run),
      ),
    );

    if (!mounted) return;
    await purgeEndedUnlimitedModeGames();
    await refreshUserProfile();
    setState(() {});
  }

  Future<void> refreshUserProfile() async
  {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) return;

    final data = await client
        .from('user_profiles')
        .select()
        .eq('id', user.id)
        .single();

    if (!mounted) return;

    setState(() {
      profile = UserProfile.fromMap(data);
    });
  }

  Future<void> purgeEndedUnlimitedModeGames() async
  {
    final client = Supabase.instance.client;

    List<dynamic> rows = [];
    try
    {
      rows = await client
          .from('unlimited_mode')
          .select('id')
          .eq('status', 'ended');
    }
    catch (_)
    {
      return;
    }

    final ids = rows
        .map<String>((row) => (row['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toList();

    for (final id in ids)
    {
      try
      {
        await client
            .from('unlimited_mode')
            .delete()
            .eq('id', id);
      }
      catch (_) {}
    }
  }

  Future<void> handleDashboardRefresh() async
  {
    await purgeEndedUnlimitedModeGames();
    await refreshUserProfile();
    if (!mounted) return;
    setState(() {});
  }

  Map<String, List<Game>> bucketGames(List<Game> games, String userId)
  {
    final buckets = <String, List<Game>>
    {
      "request": [],
      "waiting": [],
      "yourTurn": [],
      "theirTurn": [],
      "ended": [],
    };

    for (final game in games)
    {
      final accepted = game.acceptedPlayers[userId] ?? false;
      final allAccepted = game.acceptedPlayers.values.every((v) => v == true);

      if (game.status == "ended")
      {
        buckets["ended"]!.add(game);
      }
      else if (!accepted)
      {
        buckets["request"]!.add(game);
      }
      else if (!allAccepted)
      {
        buckets["waiting"]!.add(game);
      }
      else if (game.currentTurnPlayerId == userId)
      {
        buckets["yourTurn"]!.add(game);
      }
      else
      {
        buckets["theirTurn"]!.add(game);
      }
    }

    return buckets;
  }

Future<void> onRequestTap(Game game) async
{
  final client = Supabase.instance.client;

  final profile = await client
      .from('user_profiles')
      .select('username')
      .eq('id', game.creatorId)
      .single();

  final hostUsername = profile["username"];

  if (!mounted) return;

  final result = await showInviteDialog(
    context: context,
    hostUsername: hostUsername,
    gameId: game.id,
  );

  if (result == null)
  {
    return;
  }

  if (result.action == InviteAction.rejectGame)
  {
    try
    {
      await client
          .from('games')
          .delete()
          .eq('id', game.id);

      if (!mounted) return;
      setState(() {});
    }
    catch (e)
    {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar
      (
        SnackBar(content: Text("Failed to reject game: $e")),
      );
    }
    return;
  }

  final selectedCategories = result.categories;
  if (selectedCategories == null)
  {
    return;
  }

  if (selectedCategories.isNotEmpty)
  {
    final userId = client.auth.currentUser!.id;

    final updatedAccepted =
        Map<String, bool>.from(game.acceptedPlayers);

    final updatedCategories =
        Map<String, List<String>>.from(game.playerCategories);

    updatedAccepted[userId] = true;
    updatedCategories[userId] = selectedCategories;

    final allAccepted =
        updatedAccepted.values.every((v) => v == true);

    if (allAccepted)
    {
      // 1. Update game state
      await client.from('games').update(
      {
        "accepted_players": updatedAccepted,
        "player_categories": updatedCategories,
        "status": "active",
        "current_round": 1,
        "current_turn_player_id": game.creatorId,
      }).eq("id", game.id);

    if (!mounted) return;
    showGameCreatingDialog(context);

    await generateRoundQuestions
    (
      gameId: game.id,
      round: 1,
    );

    if (!mounted) return;
    Navigator.pop(context);
    }
    else
    {
      await client.from('games').update(
      {
        "accepted_players": updatedAccepted,
        "player_categories": updatedCategories,
      }).eq("id", game.id);
    }


    if (!mounted) return;
    setState(() {});
  }
}


  /**
   * Gets the info from the player select screen and the category select screen
   * as well as the user_profile of the current user to set up a game object
   * and store its values in the appropriate database table
   */
  Future<void> startNewGame(BuildContext context) async
  {
    if (profile.gemCount < gameCreationGemCost)
    {
      await showDialog<void>
      (
        context: context,
        builder: (_) => AlertDialog(
          title: const Text("Not enough gems"),
          content: const Text("You need at least 3 gems to start a new game."),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("OK"),
            ),
          ],
        ),
      );
      return;
    }

    final game = await Navigator.push<Game>
    (
      context,
      MaterialPageRoute(builder: (_) => const PlayerSelectScreen()),
    );

    if (game == null) return;

    final client = Supabase.instance.client;
    final userId = client.auth.currentUser!.id;
    final latestProfile = await client
        .from('user_profiles')
        .select('gem_count')
        .eq('id', userId)
        .single();

    final latestGemCount = (latestProfile['gem_count'] ?? 0) as int;
    if (latestGemCount < gameCreationGemCost)
    {
      if (!mounted) return;
      await showDialog<void>
      (
        context: context,
        builder: (_) => AlertDialog(
          title: const Text("Not enough gems"),
          content: const Text("You need at least 3 gems to start a new game."),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("OK"),
            ),
          ],
        ),
      );
      return;
    }

    final updatedGemCount = latestGemCount - gameCreationGemCost;

    await client
        .from('user_profiles')
        .update({'gem_count': updatedGemCount})
        .eq('id', userId);

    await client
        .from('games')
        .insert(game.toInsertJson());

    if (!mounted) return;
    setState(() {
      profile = profile.copyWith(gemCount: updatedGemCount);
    });
  }


/**
 * Gets all of the games that the current player is attached to
 */
Future<List<Game>> fetchMyGames() async
{
  await purgeEndedUnlimitedModeGames();
  final userId = Supabase.instance.client.auth.currentUser!.id;

  final data = await Supabase.instance.client
      .from('games')
      .select()
      .contains('player_ids', [userId]);

  final games =
      data.map<Game>((row) => Game.fromJson(row)).toList();

  return games;
}

Future<Map<String, UserProfile>> fetchProfilesForGames(List<Game> games) async
{
  final ids = <String>{};
  for (final game in games)
  {
    ids.addAll(game.playerIds);
  }

  if (ids.isEmpty)
  {
    return {};
  }

  final rows = await Supabase.instance.client
      .from('user_profiles')
      .select('id, username, rank, top_category, correct_answers, avatar_path, avatar_pending_path, avatar_status, avatar_color_hex, stats_card_color_hex')
      .inFilter('id', ids.toList());

  final map = <String, UserProfile>{};
  for (final row in rows)
  {
    final p = UserProfile.fromMap(row);
    map[p.id] = p;
  }

  return map;
}

Future<Map<String, String>> fetchUsernamesForPlayers(List<String> playerIds) async
{
  if (playerIds.isEmpty)
  {
    return {};
  }

  final rows = await Supabase.instance.client
      .from('user_profiles')
      .select('id, username')
      .inFilter('id', playerIds);

  final usernames = <String, String>{};
  for (final row in rows)
  {
    usernames[row['id'] as String] = row['username'] as String;
  }

  return usernames;
}

Future<bool> showActiveScoreDialogForGame(Game game, {required bool canPlay}) async
{
  final client = Supabase.instance.client;
  final userId = client.auth.currentUser!.id;
  final players = List<String>.from(game.playerIds);
  if (players.isEmpty)
  {
    return false;
  }

  final usernames = await fetchUsernamesForPlayers(players);

  final opponentId = players.firstWhere(
    (id) => id != userId,
    orElse: () => userId,
  );

  final currentUsername = usernames[userId] ?? profile.username;
  final opponentUsername = usernames[opponentId] ?? 'Opponent';
  final currentScore = game.scores[userId] ?? 0;
  final opponentScore = game.scores[opponentId] ?? 0;

  if (!mounted) return false;

  final playPressed = await showActiveGameScoreDialog(
    context: context,
    currentRound: game.currentRound,
    currentUsername: currentUsername,
    currentScore: currentScore,
    opponentUsername: opponentUsername,
    opponentScore: opponentScore,
    canPlay: canPlay,
  );

  return playPressed == true;
}

Future<void> onTheirTurnGameTap(Game game) async
{
  await showActiveScoreDialogForGame(game, canPlay: false);
}

Future<void> onYourTurnGameTap(Game game) async
{
  final shouldPlay = await showActiveScoreDialogForGame(game, canPlay: true);
  if (!shouldPlay || !mounted)
  {
    return;
  }

  final questionsReady = await areQuestionsReadyForGame(game);
  if (!questionsReady || !mounted)
  {
    await showGameStillLoadingDialog();
    return;
  }

  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => QuestionScreen(game: game),
    ),
  );
  if (!mounted) return;
  setState(() {});
}

int expectedQuestionCountForRound(int round)
{
  return round >= finalRoundNumber ? 1 : 5;
}

Future<bool> areQuestionsReadyForGame(Game game) async
{
  try
  {
    final requiredCount = expectedQuestionCountForRound(game.currentRound);
    final rows = await Supabase.instance.client
        .from('game_questions')
        .select('id')
        .eq('game_id', game.id)
        .eq('round', game.currentRound)
        .limit(requiredCount);

    return rows.length >= requiredCount;
  }
  catch (_)
  {
    return false;
  }
}

Future<void> showGameStillLoadingDialog() async
{
  if (!mounted) return;

  await showDialog<void>(
    context: context,
    builder: (dialogContext)
    {
      return AlertDialog(
        title: const Text("Game Still Loading"),
        content: const Text(
          "This game is still loading. Check internet connection and try again.",
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text("OK"),
          ),
        ],
      );
    },
  );
}

Future<void> onEndedGameTap(Game game) async
{
  final userId = Supabase.instance.client.auth.currentUser!.id;

  final players = List<String>.from(game.playerIds);
  if (players.isEmpty)
  {
    return;
  }

  final usernames = await fetchUsernamesForPlayers(players);

  final opponentId = players.firstWhere(
    (id) => id != userId,
    orElse: () => userId,
  );

  final currentUsername = usernames[userId] ?? profile.username;
  final opponentUsername = usernames[opponentId] ?? 'Opponent';

  final currentScore = game.scores[userId] ?? 0;
  final opponentScore = game.scores[opponentId] ?? 0;

  var winnerName = "Tie";
  if (game.scores.isNotEmpty)
  {
    final maxScore = game.scores.values.reduce((a, b) => a > b ? a : b);
    final winnerIds = game.scores.entries
        .where((entry) => entry.value == maxScore)
        .map((entry) => entry.key)
        .toList();

    if (winnerIds.length == 1)
    {
      winnerName = usernames[winnerIds.first] ?? "Unknown";
    }
  }

  if (!mounted) return;

  await showEndedGameScoreDialog(
    context: context,
    winnerName: winnerName,
    currentUsername: currentUsername,
    currentScore: currentScore,
    opponentUsername: opponentUsername,
    opponentScore: opponentScore,
  );
}
  
  Widget buildGameSection(
    String title,
    List<Game> games,
    Map<String, UserProfile> profilesById,
  )
  {
    if (games.isEmpty)
    {
      return Column
      (
        crossAxisAlignment: CrossAxisAlignment.start,
        children:
        [
          Text(title, style: DashboardStyles.sectionTitle),
          const SizedBox(height: 8),
          const Text("No games"),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children:
      [
        Text(title, style: DashboardStyles.sectionTitle),
        const SizedBox(height: 8),

        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: games
                .map((game) => buildGameAvatarButton(game, profilesById))
                .toList(),
          ),
        ),
      ],
    );
  }

  //================= NEW REQUEST SECTION =================
  Widget buildRequestSection(
    String title,
    List<Game> games,
    Map<String, UserProfile> profilesById,
  )
  {
    if (games.isEmpty)
    {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: DashboardStyles.sectionTitle),
          const SizedBox(height: 8),
          const Text("No games"),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: DashboardStyles.sectionTitle),
        const SizedBox(height: 8),

        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: games
                .map(
                  (game) => buildGameAvatarButton(
                    game,
                    profilesById,
                    onTap: () => onRequestTap(game),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget buildYourTurnSection(
    String title,
    List<Game> games,
    Map<String, UserProfile> profilesById,
  ) {
    if (games.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: DashboardStyles.sectionTitle),
          const SizedBox(height: 8),
          const Text("No games"),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: DashboardStyles.sectionTitle),
        const SizedBox(height: 8),

        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: games
                .map(
                  (game) => buildGameAvatarButton(
                    game,
                    profilesById,
                    onTap: () => onYourTurnGameTap(game),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget buildTheirTurnSection(
    String title,
    List<Game> games,
    Map<String, UserProfile> profilesById,
  )
  {
    if (games.isEmpty)
    {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: DashboardStyles.sectionTitle),
          const SizedBox(height: 8),
          const Text("No games"),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: DashboardStyles.sectionTitle),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: games
                .map(
                  (game) => buildGameAvatarButton(
                    game,
                    profilesById,
                    onTap: () => onTheirTurnGameTap(game),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget buildEndedSection(
    String title,
    List<Game> games,
    Map<String, UserProfile> profilesById,
  )
  {
    if (games.isEmpty)
    {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: DashboardStyles.sectionTitle),
          const SizedBox(height: 8),
          const Text("No games"),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: DashboardStyles.sectionTitle),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: games
                .map(
                  (game) => buildGameAvatarButton(
                    game,
                    profilesById,
                    onTap: () => onEndedGameTap(game),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }
  @override
  Widget build(BuildContext context)
  {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      extendBodyBehindAppBar: true,

      body: AppBackground(
        child: SafeArea(
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              CupertinoSliverRefreshControl(
                onRefresh: handleDashboardRefresh,
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
            children:
            [
              // TOP ROW
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children:
                [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(15),
                      decoration: statsCardDecorationForProfile(),
                      child: Row(
                        children:
                        [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children:
                              [
                                Text("Rank: ${profile.rank}", style: DashboardStyles.statsText),
                                Text("Top Category: ${profile.top_category}", style: DashboardStyles.statsText),
                                Text("Correct Answers: ${profile.correctAnswers}", style: DashboardStyles.statsText),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children:
                            [
                              const SizedBox(height: 6),
                              Image.asset(
                                "assets/images/gem_img.png",
                                width: 50,
                                height: 50,
                                fit: BoxFit.contain,
                              ),
                              const SizedBox(height: 2),
                              Text("${profile.gemCount}", style: DashboardStyles.statsText),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector
                  (
                    onTap: () async
                    {
                      final updatedProfile = await Navigator.push<UserProfile>
                      (
                        context,
                        MaterialPageRoute
                        (
                          builder: (_) => SettingsScreen(userProfile: profile),
                        ),
                      );

                      if (!mounted) return;

                      if (updatedProfile != null)
                      {
                        setState(() {
                          profile = updatedProfile;
                        });
                      }
                      else
                      {
                        await refreshUserProfile();
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Column
                      (
                        mainAxisSize: MainAxisSize.min,
                        children: 
                        [
                          ProfileAvatar
                          (
                            username: profile.username,
                            avatarPath: profile.avatarPath,
                            avatarStatus: profile.avatarStatus,
                            avatarColorHex: profile.avatarColorHex,
                            radius: 46,
                          ),

                          const SizedBox(height: 6),
                          Text
                          (
                            profile.username,
                            style: const TextStyle
                            (
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            )
                          ),
                        ]
                      ),
                    )

                  ),
                ],
              ),

              const SizedBox(height: 20),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children:
                [
                 Expanded(
                  child: 
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: 
                    [
                      // START GAME BUTTON
                      SizedBox
                      (
                        width: size.width * 0.45,
                        child: ElevatedButton(
                          onPressed: () => startNewGame(context),
                          style: DashboardStyles.startGameButtonStyle,
                          child: const Text("New Game", style: TextStyle(fontSize: 25, fontWeight: FontWeight.w100)),
                        ),
                      ),
                    ]
                  )
                 ),
                 Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: 
                    [
                      // START GAME BUTTON
                       SizedBox
                       (
                         width: size.width * 0.45,
                         child: ElevatedButton(
                           onPressed: () async
                           {
                             if (minuteModePreparation.isPending)
                             {
                               await showMinuteModePendingDialog();
                               return;
                             }

                             if (minuteModePreparation.isReady)
                             {
                               await showMinuteModeReadyDialog();
                               return;
                             }

                             final client = Supabase.instance.client;
                             final user = client.auth.currentUser;
                             if (user == null) return;

                             final latestProfile = await client
                                 .from('user_profiles')
                                 .select('gem_count')
                                 .eq('id', user.id)
                                 .single();

                             final latestGemCount =
                                 (latestProfile['gem_count'] ?? 0) as int;

                             if (latestGemCount < minuteModeGemCost)
                             {
                               if (!mounted) return;
                               await showDialog<void>
                               (
                                 context: context,
                                 builder: (_) => AlertDialog(
                                   title: const Text("Not enough gems"),
                                   content: const Text("You need at least 5 gems to play Minute Mode."),
                                   actions: [
                                     TextButton(
                                       onPressed: () => Navigator.pop(context),
                                       child: const Text("OK"),
                                     ),
                                   ],
                                 ),
                               );
                               return;
                             }

                              await Navigator.push<void>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const UnlimitedModeScreen(),
                                ),
                              );

                              if (!mounted) return;
                              await purgeEndedUnlimitedModeGames();
                              await refreshUserProfile();
                              setState(() {});
                            },
                           style: minuteModeButtonStyle(),
                           child: const Text("Minute Mode", style: TextStyle(fontSize: 25, fontWeight: FontWeight.w100)),
                         ),
                       ),
                    ]
                  )
                ],
              ),

              const SizedBox(height: 24),

              FutureBuilder<List<Game>>
              (
                future: fetchMyGames(),
                builder: (context, snapshot)
                {
                  if (!snapshot.hasData)
                  {
                    return const CircularProgressIndicator();
                  }

                  final games = snapshot.data!;

                  return FutureBuilder<Map<String, UserProfile>>(
                    future: fetchProfilesForGames(games),
                    builder: (context, profilesSnapshot)
                    {
                      if (!profilesSnapshot.hasData)
                      {
                        return const CircularProgressIndicator();
                      }

                      final profilesById = profilesSnapshot.data!;
                      final userId = Supabase.instance.client.auth.currentUser!.id;
                      final buckets = bucketGames(games, userId);
                      final requestGames = buckets["request"]!;
                      final waitingGames = buckets["waiting"]!;
                      final yourTurnGames = buckets["yourTurn"]!;
                      final theirTurnGames = buckets["theirTurn"]!;
                      final endedGames = buckets["ended"]!;

                      return Column
                      (
                        children:
                        [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: buildYourTurnSection(
                              "Your Turn",
                              yourTurnGames,
                              profilesById,
                            ),
                          ),
                          const SizedBox(height: 25),

                          Align(
                            alignment: Alignment.centerLeft,
                            child: buildTheirTurnSection(
                              "Their Turn",
                              theirTurnGames,
                              profilesById,
                            ),
                          ),
                          const SizedBox(height: 25),

                          Align(
                            alignment: Alignment.centerLeft,
                            child: buildGameSection(
                              "Waiting",
                              waitingGames,
                              profilesById,
                            ),
                          ),
                          const SizedBox(height: 25),

                          Align(
                            alignment: Alignment.centerLeft,
                            child: buildRequestSection(
                              "Request",
                              requestGames,
                              profilesById,
                            ),
                          ),
                          const SizedBox(height: 25),

                          Align(
                            alignment: Alignment.centerLeft,
                            child: buildEndedSection(
                              "Ended Games",
                              endedGames,
                              profilesById,
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
