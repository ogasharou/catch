import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';
import 'package:workmanager/workmanager.dart';

import 'cloud_sync.dart';
import 'web_ocr_stub.dart' if (dart.library.js_interop) 'web_ocr_web.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await Workmanager().initialize(catchCloudCallbackDispatcher);
  }
  runApp(const CatchApp());
}

// ============================================================
// Catch
// ============================================================

class CatchApp extends StatelessWidget {
  const CatchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Catch',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4468E8),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF6F7FB),
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
      ),
      home: const MainScreen(),
    );
  }
}

// ============================================================
// データ
// ============================================================

class Assignment {
  Assignment({
    required this.title,
    required this.subject,
    required this.deadline,
    this.completed = false,
    this.reminderMinutes = -1,
    this.notificationId = 0,
    this.source = 'local',
    this.externalId = '',
  });

  String title;
  String subject;
  DateTime deadline;
  bool completed;
  int reminderMinutes;
  int notificationId;
  String source;
  String externalId;

  Map<String, dynamic> toJson() => {
    'title': title,
    'subject': subject,
    'deadline': deadline.toIso8601String(),
    'completed': completed,
    'reminderMinutes': reminderMinutes,
    'notificationId': notificationId,
    'source': source,
    'externalId': externalId,
  };

  factory Assignment.fromJson(Map<String, dynamic> json) => Assignment(
    title: json['title'] as String? ?? '',
    subject: json['subject'] as String? ?? 'その他',
    deadline: DateTime.tryParse(json['deadline'] as String? ?? '') ??
        DateTime.now(),
    completed: json['completed'] as bool? ?? false,
    reminderMinutes: json['reminderMinutes'] as int? ?? -1,
    notificationId: json['notificationId'] as int? ?? 0,
    source: json['source'] as String? ?? 'local',
    externalId: json['externalId'] as String? ?? '',
  );
}

class ScheduleItem {
  ScheduleItem({
    required this.title,
    required this.date,
    this.externalId = '',
    this.completed = false,
    this.reminderMinutes = -1,
    this.notificationId = 0,
  });

  String title;
  DateTime date;
  String externalId;
  bool completed;
  int reminderMinutes;
  int notificationId;

  Map<String, dynamic> toJson() => {
    'title': title,
    'date': date.toIso8601String(),
    'externalId': externalId,
    'completed': completed,
    'reminderMinutes': reminderMinutes,
    'notificationId': notificationId,
  };

  factory ScheduleItem.fromJson(Map<String, dynamic> json) => ScheduleItem(
    title: json['title'] as String? ?? '',
    date: DateTime.tryParse(json['date'] as String? ?? '') ?? DateTime.now(),
    externalId: json['externalId'] as String? ?? '',
    completed: json['completed'] as bool? ?? false,
    reminderMinutes: json['reminderMinutes'] as int? ?? -1,
    notificationId: json['notificationId'] as int? ?? 0,
  );
}

class WatchItem {
  WatchItem({
    required this.keyword,
    this.enabled = true,
    this.lastCheckedAt,
  });

  String keyword;
  bool enabled;
  DateTime? lastCheckedAt;

  Map<String, dynamic> toJson() => {
    'keyword': keyword,
    'enabled': enabled,
    'lastCheckedAt': lastCheckedAt?.toIso8601String(),
  };

  factory WatchItem.fromJson(Map<String, dynamic> json) => WatchItem(
    keyword: json['keyword'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
    lastCheckedAt: DateTime.tryParse(json['lastCheckedAt'] as String? ?? ''),
  );
}

class WatchResult {
  WatchResult({
    required this.id,
    required this.keyword,
    required this.title,
    required this.summary,
    required this.url,
    required this.foundAt,
    this.watchType = 'news',
    this.currentPrice,
    this.targetPrice,
    this.comparedSources = 0,
    this.candidateEventAt,
    this.candidateSourceCount = 0,
    this.autoSaved = false,
  });

  final String id;
  final String keyword;
  final String title;
  final String summary;
  final String url;
  final DateTime foundAt;
  final String watchType;
  final int? currentPrice;
  final int? targetPrice;
  final int comparedSources;
  DateTime? candidateEventAt;
  int candidateSourceCount;
  bool autoSaved;

  factory WatchResult.fromJson(Map<String, dynamic> json) => WatchResult(
        id: json['id'] as String? ?? '',
        keyword: json['keyword'] as String? ?? '',
        title: json['title'] as String? ?? '新しい情報',
        summary: json['summary'] as String? ?? '',
        url: json['url'] as String? ?? '',
        foundAt: DateTime.tryParse(json['foundAt'] as String? ?? '') ?? DateTime.now(),
        watchType: json['watchType'] as String? ?? 'news',
        currentPrice: json['currentPrice'] as int?,
        targetPrice: json['targetPrice'] as int?,
        comparedSources: json['comparedSources'] as int? ?? 0,
        candidateEventAt: DateTime.tryParse(json['candidateEventAt'] as String? ?? ''),
        candidateSourceCount: json['candidateSourceCount'] as int? ?? 0,
        autoSaved: json['autoSaved'] as bool? ?? false,
      );
}


class DailyWeather {
  DailyWeather({
    required this.date,
    required this.weatherCode,
    required this.maxTemp,
    required this.minTemp,
    required this.precipitationProbability,
  });

  final DateTime date;
  final int weatherCode;
  final double maxTemp;
  final double minTemp;
  final int precipitationProbability;
}

class CalendarEntry {
  CalendarEntry.forSchedule(ScheduleItem item)
      : schedule = item,
        assignment = null,
        title = item.title,
        date = item.date,
        completed = item.completed;

  CalendarEntry.forAssignment(Assignment item)
      : schedule = null,
        assignment = item,
        title = item.title,
        date = item.deadline,
        completed = item.completed;

  final ScheduleItem? schedule;
  final Assignment? assignment;
  final String title;
  final DateTime date;
  final bool completed;

  bool get isAssignment => assignment != null;
}

// ============================================================
// メイン画面
// ============================================================

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  static const _storageKey = 'catch_app_data_v1';
  static const _notificationChannelId = 'catch_reminders';
  static const Map<int, String> reminderOptions = {
    -1: '通知なし',
    0: '開始時刻',
    5: '5分前',
    10: '10分前',
    30: '30分前',
    60: '1時間前',
    1440: '1日前',
  };

  final FlutterLocalNotificationsPlugin notificationPlugin =
      FlutterLocalNotificationsPlugin();

  final ImagePicker _imagePicker = ImagePicker();

  static const MethodChannel teamsCaptureChannel =
      MethodChannel('catch/teams_capture');
  final TextEditingController watchChatController = TextEditingController();
  String? selectedWatchKeyword;
  bool teamsCaptureStarting = false;
  bool teamsCaptureWaitingOverlayPermission = false;

  int selectedIndex = 0;

  final List<Assignment> assignments = [];

  final List<ScheduleItem> schedules = [];

  final List<WatchItem> watches = [];

  final List<WatchResult> watchResults = [];

  final CatchCloudService cloudService = CatchCloudService();

  String cloudApiUrl = '';
  bool cloudSyncing = false;
  int _watchVerifyGeneration = 0;
  final Set<String> _watchVerifyingIds = <String>{};
  bool teamsConnected = false;
  bool teamsNeedsAdminConsent = false;
  DateTime? lastCloudSync;
  String cloudMessage = '無料ウォッチ検索を利用できます';

  DateTime selectedDate = DateTime.now();

  bool notificationsEnabled = true;
  int defaultReminderMinutes = 30;
  bool notificationsReady = false;

  bool weatherEnabled = true;
  bool weatherLoading = false;
  String weatherMessage = '現在地の天気を取得します';
  DateTime? weatherUpdatedAt;
  final Map<String, DailyWeather> weatherByDate = <String, DailyWeather>{};

  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initializeApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    watchChatController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      takePendingTeamsCapture();
      _resumeScreenCatchAfterOverlayPermission();
      if (weatherEnabled &&
          (weatherUpdatedAt == null ||
              DateTime.now().difference(weatherUpdatedAt!).inHours >= 3)) {
        unawaited(refreshCalendarWeather());
      }
    }
  }

  Future<void> _resumeScreenCatchAfterOverlayPermission() async {
    if (!teamsCaptureWaitingOverlayPermission ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      final allowed =
          await teamsCaptureChannel.invokeMethod<bool>('hasOverlayPermission') ?? false;
      if (!mounted) return;
      if (!allowed) {
        // User came back without enabling it. Do not reopen Settings in a loop.
        teamsCaptureWaitingOverlayPermission = false;
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('画面からCatchを使うには、Catchの「他のアプリの上に表示」を許可してください。'),
          ),
        );
        return;
      }

      teamsCaptureWaitingOverlayPermission = false;
      setState(() {});
      // Let Android finish returning from Settings before opening MediaProjection.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      await startTeamsScreenCapture();
    } catch (_) {
      teamsCaptureWaitingOverlayPermission = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> initializeApp() async {
    try {
      await initializeNotifications();
    } catch (_) {
      notificationsReady = false;
    }
    await loadData();
    if (watches.isNotEmpty) selectedWatchKeyword ??= watches.first.keyword;
    await ensureNotificationIds();
    await loadCloudIntegration();
    try {
      await syncAllNotifications();
    } catch (_) {
      // 通知を作れない端末でも、アプリ本体はそのまま利用できる。
    }
    await takePendingTeamsCapture();
    if (weatherEnabled) {
      unawaited(refreshCalendarWeather());
    }
  }

  Future<void> loadCloudIntegration() async {
    cloudApiUrl = await cloudService.getApiUrl();
    teamsConnected = await cloudService.isTeamsConnected();
    lastCloudSync = await cloudService.lastSync();
    await uploadWatches();
    await importCloudInbox();
    if (cloudApiUrl.isEmpty && !teamsConnected) {
      if (mounted) setState(() => cloudMessage = '無料ウォッチ検索を利用できます');
      return;
    }
    await cloudService.configureBackgroundSync();
    await syncCloud(showMessage: false);
  }

  Future<void> importCloudInbox() async {
    final remoteTasks = await cloudService.takeTaskInbox();
    final remoteResults = await cloudService.takeWatchInbox();
    var changed = false;
    for (final item in remoteTasks) {
      final externalId = item['externalId'] as String? ?? '';
      if (externalId.isEmpty ||
          assignments.any((task) => task.externalId == externalId)) {
        continue;
      }
      assignments.add(
        Assignment(
          title: item['title'] as String? ?? 'Teamsのタスク',
          subject: item['subject'] as String? ?? 'Microsoft Teams',
          deadline: DateTime.tryParse(item['deadline'] as String? ?? '') ??
              DateTime.now().add(const Duration(days: 1)),
          reminderMinutes: defaultReminderMinutes,
          notificationId: newNotificationId(),
          source: 'teams',
          externalId: externalId,
        ),
      );
      changed = true;
    }
    final knownResultIds = watchResults.map((result) => result.id).toSet();
    final importedResults = <WatchResult>[];
    for (final item in remoteResults) {
      final result = WatchResult.fromJson(item);
      if (result.id.isNotEmpty && knownResultIds.add(result.id)) {
        watchResults.insert(0, result);
        importedResults.add(result);
        final watch = watches.where((entry) => entry.keyword == result.keyword);
        if (watch.isNotEmpty) watch.first.lastCheckedAt = result.foundAt;
        changed = true;
      }
    }
    if (changed) await saveData();
  }

  Future<void> autoSaveWatchResultDate(WatchResult result) async {
    if (result.id.isEmpty || result.autoSaved || result.watchType == 'price' || !_looksLikeDateWatch(result.keyword)) return;
    try {
      final verification = await cloudService.verifyEventDateAcrossSources(
        keyword: result.keyword,
        title: result.title,
        url: result.url,
        previewText: result.summary,
      );
      final match = verification.consensus;
      if (match == null || !match.hasExplicitTime) {
        if (verification.candidates.isNotEmpty) {
          result
            ..candidateEventAt = verification.candidates.first.date
            ..candidateSourceCount = verification.checkedSources
            ..autoSaved = false;
          await saveData();
          if (mounted) setState(() {});
        }
        return;
      }
      final externalId = 'watch-date:${result.id}';
      final existing = schedules.where((item) => item.externalId == externalId);
      if (existing.isNotEmpty) {
        existing.first
          ..date = match.date
          ..title = result.title;
      } else {
        schedules.add(
          ScheduleItem(
            title: result.title,
            date: match.date,
            externalId: externalId,
            reminderMinutes: defaultReminderMinutes,
            notificationId: newNotificationId(),
          ),
        );
      }
      result
        ..candidateEventAt = match.date
        ..candidateSourceCount = verification.checkedSources
        ..autoSaved = true;
      await saveData();
      await refreshNotificationsSafely();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('複数サイトで日時が一致したため自動保存しました: ${formatDateTime(match.date)}')),
        );
      }
    } catch (_) {
      // 照合に失敗しても、新着記事自体はウォッチチャットに残す。
    }
  }

  Future<void> syncCloud({bool showMessage = true}) async {
    if (cloudSyncing) return;
    if (mounted) setState(() => cloudSyncing = true);
    try {
      final result = await cloudService.sync();
      await importCloudInbox();
      lastCloudSync = await cloudService.lastSync();
      teamsConnected = result.teamsConnected;
      teamsNeedsAdminConsent = result.needsAdminConsent;
      cloudMessage = result.newItemCount == 0
          ? '同期済み・新着なし'
          : '${result.newItemCount}件の新着を取り込みました';
      await syncAllNotifications();
      if (showMessage && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(cloudMessage)),
        );
      }
    } catch (error) {
      cloudMessage = '同期失敗: $error';
      if (showMessage && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(cloudMessage)),
        );
      }
    } finally {
      if (mounted) setState(() => cloudSyncing = false);
    }
  }

  Future<void> _applyCurrentWatchResults(List<Map<String, dynamic>> items) async {
    var changed = false;
    for (final item in items) {
      final result = WatchResult.fromJson(item);
      if (result.id.isEmpty) continue;
      final index = watchResults.indexWhere((e) => e.id == result.id);
      if (index >= 0) {
        // 日時の手動確認済み状態は維持する。
        final old = watchResults[index];
        result.candidateEventAt ??= old.candidateEventAt;
        if (result.candidateSourceCount == 0) result.candidateSourceCount = old.candidateSourceCount;
        result.autoSaved = result.autoSaved || old.autoSaved;
        watchResults[index] = result;
      } else {
        watchResults.insert(0, result);
      }
      final matches = watches.where((w) => w.keyword == result.keyword);
      if (matches.isNotEmpty) matches.first.lastCheckedAt = DateTime.now();
      changed = true;
    }
    if (changed) await saveData();
  }

  Future<void> checkAiNow() async {
    _watchVerifyGeneration++;
    if (cloudSyncing || cloudApiUrl.isEmpty) return;
    if (mounted) setState(() => cloudSyncing = true);
    try {
      final result = await cloudService.checkAiNow();
      await _applyCurrentWatchResults(result.watchResults);
      // inboxは定期同期との互換用。重複はIDで無害化される。
      await importCloudInbox();
      cloudMessage = result.watchResults.isEmpty
          ? '検索しましたが候補が見つかりませんでした'
          : '${result.watchResults.length}件の候補を表示しました';
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(cloudMessage)));
      }
    } catch (error) {
      cloudMessage = '検索失敗: $error';
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(cloudMessage)));
      }
    } finally {
      if (mounted) setState(() => cloudSyncing = false);
    }
  }

  Future<void> uploadWatches() async {
    try {
      await cloudService.uploadWatches(
        watches
            .map((watch) => {
                  'keyword': watch.keyword,
                  'enabled': watch.enabled,
                })
            .toList(),
      );
      await cloudService.configureBackgroundSync();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ウォッチの同期に失敗しました: $error')),
      );
    }
  }

  Future<void> startTeamsScreenCapture() async {
    if (kIsWeb) {
      await startIosScreenshotCatch();
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await startIosScreenshotCatch();
      return;
    }

    if (defaultTargetPlatform != TargetPlatform.android) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('この端末では画面Catchを利用できません')),
      );
      return;
    }

    if (teamsCaptureStarting) return;
    setState(() => teamsCaptureStarting = true);
    try {
      final result = await teamsCaptureChannel
          .invokeMapMethod<String, dynamic>('startCapture');
      if (!mounted) return;
      final status = result?['status']?.toString() ?? '';
      if (status == 'overlay_permission') {
        teamsCaptureWaitingOverlayPermission = true;
        setState(() {});
      }
      final message = status == 'overlay_permission'
          ? '設定で「Catch」を開いて「他のアプリの上に表示」を許可してください。戻れば自動で続きます。'
          : status == 'requested'
              ? '画面共有を許可してください。許可後、他のアプリ上にCatchボタンが表示されます。'
              : result?['message']?.toString() ?? '画面取り込みを開始しました';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('画面取り込みを開始できません: ${error.message}')),
      );
    } finally {
      if (mounted) setState(() => teamsCaptureStarting = false);
    }
  }

  Future<void> startIosScreenshotCatch() async {
    if (teamsCaptureStarting) return;
    setState(() => teamsCaptureStarting = true);
    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
        requestFullMetadata: false,
      );
      if (image == null || !mounted) return;

      String text;
      if (kIsWeb) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('スクショを読み取り中… 初回は少し時間がかかります'),
            duration: Duration(seconds: 8),
          ),
        );
        final bytes = await image.readAsBytes();
        final mime = image.mimeType ?? 'image/png';
        final dataUrl = 'data:$mime;base64,${base64Encode(bytes)}';
        text = (await recognizeWebImage(dataUrl)).trim();
      } else {
        final recognizer =
            TextRecognizer(script: TextRecognitionScript.japanese);
        try {
          final input = InputImage.fromFilePath(image.path);
          final recognized = await recognizer.processImage(input);
          text = recognized.text.trim();
        } finally {
          await recognizer.close();
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('画像から文字を読み取れませんでした')),
        );
        return;
      }
      await showTeamsOcrConfirmation(text);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('スクショの読み取りに失敗しました: $error')),
      );
    } finally {
      if (mounted) setState(() => teamsCaptureStarting = false);
    }
  }

  Future<void> takePendingTeamsCapture() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final result = await teamsCaptureChannel
          .invokeMapMethod<String, dynamic>('takePendingResult');
      if (result == null || result.isEmpty || !mounted) return;
      final error = result['error']?.toString() ?? '';
      if (error.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('読み取りに失敗しました: $error')),
        );
        return;
      }
      final text = result['text']?.toString().trim() ?? '';
      if (text.isEmpty) return;
      await showTeamsOcrConfirmation(text);
    } catch (_) {
      // Android以外や、旧バージョンからの更新直後でもアプリは起動させる。
    }
  }

  String cleanScreenOcrText(String rawText) {
    final now = DateTime.now();
    final currentTimes = <String>{};
    for (var offset = -2; offset <= 2; offset++) {
      final value = now.add(Duration(minutes: offset));
      final h24 = value.hour.toString();
      final h24p = value.hour.toString().padLeft(2, '0');
      final min = value.minute.toString().padLeft(2, '0');
      currentTimes
        ..add('$h24:$min')
        ..add('$h24p:$min');
    }

    final uiWords = RegExp(
      r'(画面共有|画面収録|録画中|recording|screen\s*(?:share|sharing|recording)|キャスト中|共有中)',
      caseSensitive: false,
    );
    final catchOwnUi = RegExp(
      r'^(?:\d+\s*)?(?:Catch|画面からCatch|スクショからCatch|確認して(?:タスク|予定)に追加|読み取った文字を確認|スクショの解析結果を確認|キャンセル|開始)$',
      caseSensitive: false,
    );
    final timeOnly = RegExp(
      r'^\s*(?:[01]?\d|2[0-3])[:：][0-5]\d\s*(?:[AP]M|午前|午後)?\s*$',
      caseSensitive: false,
    );
    final elapsedOnly = RegExp(r'^\s*\d{1,2}[:：]\d{2}(?::\d{2})?\s*$');

    final cleaned = <String>[];
    for (final rawLine in rawText.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (line.isEmpty) continue;
      if (uiWords.hasMatch(line)) continue;
      if (catchOwnUi.hasMatch(line)) continue;

      final normalizedTime = line.replaceAll('：', ':');
      // Status bar current time and capture elapsed timers must never become
      // assignment/event times. Only discard standalone UI-like time lines;
      // dates such as "9/18 15:00" are preserved.
      if (currentTimes.contains(normalizedTime)) continue;
      if (elapsedOnly.hasMatch(normalizedTime) && timeOnly.hasMatch(normalizedTime)) {
        continue;
      }
      cleaned.add(line);
    }
    return cleaned.join('\n').trim();
  }

  bool containsExplicitTime(String text) {
    final normalized = text.replaceAll('：', ':');
    return RegExp(r'(?:[01]?\d|2[0-3])\s*(?::|時)\s*[0-5]?\d?').hasMatch(normalized) ||
        RegExp(r'(?:午前|午後)\s*\d{1,2}\s*時').hasMatch(normalized) ||
        RegExp(r'\d{1,2}\s*時\s*(?:半|[0-5]?\d\s*分)').hasMatch(normalized);
  }

  Future<EventDateMatch?> extractBestDateWithAi(String text) async {
    if (text.trim().isEmpty) return null;
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.iOS) {
      final parsed = extractDeadlineFromText(text);
      if (parsed == null) return null;
      return EventDateMatch(
        date: parsed,
        hasExplicitTime: containsExplicitTime(text),
        evidence: text.length > 160 ? text.substring(0, 160) : text,
      );
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    try {
      final limited = text.length > 50000 ? text.substring(0, 50000) : text;
      final raw = await teamsCaptureChannel.invokeListMethod<dynamic>(
        'extractDateTimes',
        {'text': limited},
      );
      EventDateMatch? best;
      var bestScore = -999;
      final now = DateTime.now();
      for (final item in raw ?? const <dynamic>[]) {
        if (item is! Map) continue;
        final millis = (item['timestampMillis'] as num?)?.toInt();
        if (millis == null) continue;
        final extractedDate = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
        final evidence = item['text']?.toString() ?? '';
        final hasTime = containsExplicitTime(evidence);
        // ML Kit may attach the current time to a date-only entity. Never use
        // that incidental time as an event time.
        final date = hasTime
            ? extractedDate
            : DateTime(extractedDate.year, extractedDate.month, extractedDate.day, 12);
        var score = hasTime ? 80 : 20;
        if (date.isAfter(now.subtract(const Duration(days: 1)))) score += 20;
        if (date.isAfter(now.add(const Duration(days: 730)))) score -= 30;
        if (score > bestScore) {
          bestScore = score;
          best = EventDateMatch(date: date, hasExplicitTime: hasTime, evidence: evidence);
        }
      }
      return best;
    } catch (_) {
      return null;
    }
  }

  bool looksLikeTeamsAssignmentText(String text) {
    return RegExp(
      r'(期限|提出しました|提出されていません|複数回提出できます|自分の作業|点数|終了日)',
    ).hasMatch(text);
  }

  ({DateTime date, bool hasExplicitTime})? extractTeamsDeadline(String text) {
    final normalized = text
        .replaceAll('：', ':')
        .replaceAll('／', '/')
        .replaceAll(RegExp(r'[ \t]+'), ' ');

    DateTime? parseDate(String value) {
      final full = RegExp(
        r'(20\d{2})\s*[年/.-]\s*(\d{1,2})\s*[月/.-]\s*(\d{1,2})\s*日?'
        r'(?:\s*[（(]?[月火水木金土日]?[）)]?)?'
        r'(?:\s*(\d{1,2})\s*[:時]\s*(\d{1,2})?\s*分?)?',
      ).firstMatch(value);
      if (full == null) return null;
      return DateTime(
        int.parse(full.group(1)!),
        int.parse(full.group(2)!),
        int.parse(full.group(3)!),
        int.tryParse(full.group(4) ?? '') ?? 12,
        int.tryParse(full.group(5) ?? '') ?? 0,
      );
    }

    bool hasTime(String value) => RegExp(
      r'(?:[01]?\d|2[0-3])\s*(?::|時)\s*[0-5]\d?',
    ).hasMatch(value);

    // Highest priority: a date/time attached directly to "期限".
    final directDeadline = RegExp(
      r'期限\s*[:：]?\s*'
      r'((?:20\d{2})\s*[年/.-]\s*\d{1,2}\s*[月/.-]\s*\d{1,2}\s*日?'
      r'(?:\s*[（(]?[月火水木金土日]?[）)]?)?'
      r'(?:\s*\d{1,2}\s*[:時]\s*\d{1,2}\s*分?)?)',
    ).firstMatch(normalized);
    if (directDeadline != null) {
      final evidence = directDeadline.group(1)!;
      final date = parseDate(evidence);
      if (date != null) {
        return (date: date, hasExplicitTime: hasTime(evidence));
      }
    }

    // OCR often separates "期限" and its value onto two lines.
    final lines = normalized
        .split(RegExp(r'[\r\n]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!RegExp(r'^期限\s*[:：]?$').hasMatch(line)) continue;

      for (var j = i + 1; j < lines.length && j <= i + 2; j++) {
        final candidate = lines[j];
        // Never interpret submission history as the deadline.
        if (RegExp(r'(提出しました|提出済み|提出を取り消す)').hasMatch(candidate)) {
          continue;
        }
        final date = parseDate(candidate);
        if (date != null) {
          return (date: date, hasExplicitTime: hasTime(candidate));
        }
      }
    }

    // Secondary fallback used by Teams itself: "終了日".
    final endDate = RegExp(
      r'終了日\s*[:：]?\s*'
      r'((?:20\d{2})\s*[年/.-]\s*\d{1,2}\s*[月/.-]\s*\d{1,2}\s*日?'
      r'(?:\s*\d{1,2}\s*[:時]\s*\d{1,2}\s*分?)?)',
    ).firstMatch(normalized);
    if (endDate != null) {
      final evidence = endDate.group(1)!;
      final date = parseDate(evidence);
      if (date != null) {
        return (date: date, hasExplicitTime: hasTime(evidence));
      }
    }

    return null;
  }

  DateTime? extractDeadlineFromText(String text) {
    final normalized = text.replaceAll('：', ':').replaceAll('／', '/');
    final full = RegExp(
      r'(20\d{2})\s*[年/.-]\s*(\d{1,2})\s*[月/.-]\s*(\d{1,2})\s*日?(?:\s*[（(]?[月火水木金土日]?[）)]?)?(?:\s*(\d{1,2})\s*[:時]\s*(\d{1,2})?\s*分?)?',
    ).firstMatch(normalized);
    if (full != null) {
      return DateTime(
        int.parse(full.group(1)!),
        int.parse(full.group(2)!),
        int.parse(full.group(3)!),
        int.tryParse(full.group(4) ?? '') ?? 12,
        int.tryParse(full.group(5) ?? '') ?? 0,
      );
    }
    final short = RegExp(
      r'(\d{1,2})\s*[月/]\s*(\d{1,2})\s*日?(?:\s*(\d{1,2})\s*[:時]\s*(\d{1,2})?\s*分?)?',
    ).firstMatch(normalized);
    if (short != null) {
      final now = DateTime.now();
      var value = DateTime(
        now.year,
        int.parse(short.group(1)!),
        int.parse(short.group(2)!),
        int.tryParse(short.group(3) ?? '') ?? 12,
        int.tryParse(short.group(4) ?? '') ?? 0,
      );
      if (value.isBefore(now.subtract(const Duration(days: 30)))) {
        value = DateTime(value.year + 1, value.month, value.day, value.hour, value.minute);
      }
      return value;
    }
    return null;
  }

  ({String title, String subject, DateTime deadline}) parseTeamsOcr(String text) {
    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((line) => line.length >= 2)
        .toList();

    final numericOnly = RegExp(r'^[\d\s.,:：/\-]+$');
    final courseLine = RegExp(r'^\[\s*\d+\s*\].+');
    final teamsUi = RegExp(
      r'^(提出されていません|提出しました|遅れて提出する|提出を取り消す|'
      r'複数回提出できます|手順|参考資料|自分の作業|点数|点数なし|'
      r'添付|新規|期限|終了日|戻る)$',
    );
    final ignored = RegExp(
      r'^(Microsoft Teams|Teams|Catch|画面からCatch|スクショからCatch|'
      r'開始|キャンセル|ホーム|タスク|予定|ウォッチ|設定)$',
      caseSensitive: false,
    );
    final attachmentLike = RegExp(
      r'\.(?:pdf|pptx?|xlsx?|docx?|zip|png|jpe?g)$',
      caseSensitive: false,
    );
    final dateLike = RegExp(
      r'(20\d{2}\s*[年/.-]\s*\d{1,2}\s*[月/.-]\s*\d{1,2}|'
      r'\d{1,2}\s*[月/]\s*\d{1,2}|'
      r'\d{1,2}:\d{2})',
    );

    String subject = '';
    for (final line in lines) {
      if (courseLine.hasMatch(line)) {
        subject = line;
        break;
      }
    }

    // Teams places the assignment title immediately before the "期限" area.
    // Walk backwards from that anchor and collect up to two wrapped title lines.
    var deadlineIndex = -1;
    for (var i = 0; i < lines.length; i++) {
      if (RegExp(r'^期限(?:\s|$)').hasMatch(lines[i])) {
        deadlineIndex = i;
        break;
      }
    }

    bool validTitleLine(String line) {
      if (line == subject) return false;
      if (ignored.hasMatch(line)) return false;
      if (teamsUi.hasMatch(line)) return false;
      if (numericOnly.hasMatch(line)) return false;
      if (dateLike.hasMatch(line)) return false;
      if (attachmentLike.hasMatch(line)) return false;
      if (RegExp(r'(提出しました|提出されていません|点満点|複数回提出)').hasMatch(line)) {
        return false;
      }
      return RegExp(r'[一-龠ぁ-んァ-ヶA-Za-z]').hasMatch(line);
    }

    final titleParts = <String>[];
    if (deadlineIndex > 0) {
      for (var i = deadlineIndex - 1; i >= 0 && titleParts.length < 2; i--) {
        final line = lines[i];
        if (!validTitleLine(line)) {
          if (titleParts.isNotEmpty) break;
          continue;
        }
        titleParts.insert(0, line);
      }
    }

    String title = titleParts.join(' ').trim();

    // Fallback for OCR layouts where "期限" was not detected correctly.
    if (title.isEmpty) {
      final candidates = lines.where(validTitleLine).toList();
      int score(String line) {
        var value = 0;
        if (line.length >= 4) value += 10;
        if (line.length >= 8) value += 8;
        if (RegExp(r'(課題|設計書|プログラミング|レポート|小テスト)').hasMatch(line)) {
          value += 20;
        }
        if (courseLine.hasMatch(line)) value -= 50;
        if (line.length > 70) value -= 10;
        return value;
      }
      if (candidates.isNotEmpty) {
        candidates.sort((a, b) => score(b).compareTo(score(a)));
        title = candidates.first;
      }
    }

    if (title.isEmpty) title = 'Teamsから取り込んだ課題';

    final teamsDeadline = extractTeamsDeadline(text);
    return (
      title: title,
      subject: subject,
      deadline: teamsDeadline?.date ??
          DateTime.now().add(const Duration(days: 1)),
    );
  }

  String inferOcrSaveTarget(String text) {
    final normalized = text.toLowerCase();

    // Task/deadline-like language gets priority because a due date must not
    // accidentally become a normal calendar event.
    final taskWords = RegExp(
      r'(課題|宿題|提出|締切|期限|レポート|assignment|homework|due|submit)',
      caseSensitive: false,
    );
    if (taskWords.hasMatch(normalized)) return 'task';

    final scheduleWords = RegExp(
      r'(予定|開催|開始|集合|予約|イベント|試合|授業|会議|面談|説明会|ライブ|発売|配信|event|meeting|schedule|reservation)',
      caseSensitive: false,
    );
    if (scheduleWords.hasMatch(normalized)) return 'schedule';

    // Ambiguous screenshots stay conservative and default to task, but the
    // user must confirm the category before saving.
    return 'task';
  }

  Future<void> showTeamsOcrConfirmation(String rawText) async {
    final cleanedText = cleanScreenOcrText(rawText);
    final sourceText = cleanedText.isEmpty ? rawText : cleanedText;
    final parsed = parseTeamsOcr(sourceText);
    final titleController = TextEditingController(text: parsed.title);
    final subjectController = TextEditingController(text: parsed.subject);

    final isTeamsAssignment = looksLikeTeamsAssignmentText(sourceText);
    final teamsDeadline =
        isTeamsAssignment ? extractTeamsDeadline(sourceText) : null;

    // On a Teams assignment page, only "期限" (or Teams' matching "終了日")
    // is allowed to determine the deadline. Dates in "提出しました" are
    // submission history and must never override it.
    final aiDate = isTeamsAssignment
        ? null
        : await extractBestDateWithAi(sourceText);

    var deadline = teamsDeadline?.date ?? aiDate?.date ?? parsed.deadline;
    var hasExplicitOcrTime = teamsDeadline?.hasExplicitTime ??
        aiDate?.hasExplicitTime ??
        false;
    var saveTarget = inferOcrSaveTarget(sourceText);

    final shouldSave = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final bottomInset = MediaQuery.of(context).viewInsets.bottom;

          return AnimatedPadding(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: EdgeInsets.only(bottom: bottomInset),
            child: FractionallySizedBox(
              heightFactor: 0.92,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'スクショの解析結果を確認',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: SingleChildScrollView(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF2F3FF),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text(
                                '読み取り結果は間違う可能性があります。名前・カテゴリ・日時を確認し、必要なら修正してから追加してください。',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            if (looksLikeTeamsAssignmentText(sourceText)) ...[
                              const SizedBox(height: 10),
                              const Text(
                                'Teams課題として解析：締切は「期限」を最優先し、「提出しました」の日時は除外しています。',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            const Text(
                              'カテゴリ',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 7),
                            SegmentedButton<String>(
                              segments: const [
                                ButtonSegment<String>(
                                  value: 'task',
                                  label: Text('タスク'),
                                  icon: Icon(Icons.task_alt),
                                ),
                                ButtonSegment<String>(
                                  value: 'schedule',
                                  label: Text('予定'),
                                  icon: Icon(Icons.event),
                                ),
                              ],
                              selected: {saveTarget},
                              onSelectionChanged: (value) {
                                setDialogState(
                                  () => saveTarget = value.first,
                                );
                              },
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: titleController,
                              textInputAction: TextInputAction.next,
                              decoration: InputDecoration(
                                labelText:
                                    saveTarget == 'task' ? 'タスク名' : '予定名',
                                border: const OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: subjectController,
                              textInputAction: TextInputAction.done,
                              decoration: InputDecoration(
                                labelText: saveTarget == 'task'
                                    ? '教科・分類'
                                    : '分類・メモ（任意）',
                                border: const OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Card(
                              margin: EdgeInsets.zero,
                              child: ListTile(
                                leading: const Icon(Icons.event),
                                title: Text(
                                  saveTarget == 'task' ? '締切日時' : '予定日時',
                                ),
                                subtitle: Text(
                                  hasExplicitOcrTime
                                      ? formatDateTime(deadline)
                                      : '${formatDateTime(deadline)}（時刻を確認してください）',
                                ),
                                trailing:
                                    const Icon(Icons.edit_calendar_outlined),
                                onTap: () async {
                                  FocusScope.of(dialogContext).unfocus();

                                  final date = await showDatePicker(
                                    context: dialogContext,
                                    initialDate: deadline,
                                    firstDate: DateTime(2000),
                                    lastDate: DateTime.now()
                                        .add(const Duration(days: 3650)),
                                  );
                                  if (date == null ||
                                      !dialogContext.mounted) {
                                    return;
                                  }

                                  final time = await showTimePicker(
                                    context: dialogContext,
                                    initialTime:
                                        TimeOfDay.fromDateTime(deadline),
                                  );
                                  if (time == null) return;

                                  setDialogState(() {
                                    deadline = DateTime(
                                      date.year,
                                      date.month,
                                      date.day,
                                      time.hour,
                                      time.minute,
                                    );
                                    hasExplicitOcrTime = true;
                                  });
                                },
                              ),
                            ),
                            if (!hasExplicitOcrTime)
                              const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text(
                                  '時間が画面から確定できなかったので、日時をタップして選んでください。',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            const SizedBox(height: 8),
                            ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              title: const Text(
                                '読み取った文字を確認',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              children: [
                                SelectableText(
                                  rawText,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: const Text('キャンセル'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: FilledButton(
                            onPressed: hasExplicitOcrTime
                                ? () => Navigator.pop(dialogContext, true)
                                : null,
                            child: Text(
                              saveTarget == 'task'
                                  ? 'タスクに追加'
                                  : '予定に追加',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    if (shouldSave != true || titleController.text.trim().isEmpty) return;

    if (saveTarget == 'schedule') {
      final item = ScheduleItem(
        title: titleController.text.trim(),
        date: deadline,
        externalId: 'screen-ocr:${DateTime.now().microsecondsSinceEpoch}',
        reminderMinutes: defaultReminderMinutes,
        notificationId: newNotificationId(),
      );
      updateAndSave(() {
        schedules.add(item);
        selectedDate = deadline;
      });
      await refreshNotificationsSafely();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('予定・カレンダー・通知へ登録しました')),
      );
      return;
    }

    final item = Assignment(
      title: titleController.text.trim(),
      subject: subjectController.text.trim().isEmpty
          ? '画面からCatch'
          : subjectController.text.trim(),
      deadline: deadline,
      reminderMinutes: defaultReminderMinutes,
      notificationId: newNotificationId(),
      source: 'screen_ocr',
      externalId: 'screen-ocr:${DateTime.now().microsecondsSinceEpoch}',
    );
    updateAndSave(() {
      assignments.add(item);
      selectedDate = deadline;
    });
    await refreshNotificationsSafely();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('タスク・カレンダー・通知へ登録しました')),
    );
  }

  Future<void> editCloudUrl() async {
    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('無料ウォッチ検索'),
        content: const Text(
          '無料検索を優先して候補を最大3件表示します。日時は必要なときだけ「複数サイトで日時確認」で照合できます。天気は予報データを直接確認します。',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> connectTeams() async {
    final clientController = TextEditingController(
      text: await cloudService.getTeamsClientId(),
    );
    final tenantController = TextEditingController(
      text: await cloudService.getTeamsTenant(),
    );
    final shouldLogin = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Microsoft Teamsを設定'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Microsoft Entraで登録したアプリのIDを入力します。クライアントシークレットは不要です。',
              ),
              const SizedBox(height: 14),
              TextField(
                controller: clientController,
                decoration: const InputDecoration(
                  labelText: 'アプリケーション（クライアント）ID',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tenantController,
                decoration: const InputDecoration(
                  labelText: 'テナントID',
                  hintText: 'organizations のままでも可',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                await cloudService.setTeamsConfig(
                  clientController.text,
                  tenantController.text,
                );
                if (dialogContext.mounted) Navigator.pop(dialogContext, true);
              } on FormatException catch (error) {
                if (!dialogContext.mounted) return;
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(content: Text(error.message)),
                );
              }
            },
            child: const Text('保存してログイン'),
          ),
        ],
      ),
    );
    if (shouldLogin != true || !mounted) return;
    try {
      final login = await cloudService.beginTeamsLogin();
      if (!await launchUrl(
        Uri.parse(login.verificationUri),
        mode: LaunchMode.externalApplication,
      )) {
        throw StateError('Microsoftのログイン画面を開けませんでした');
      }
      if (!mounted) return;
      final waitForLogin = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Microsoftへログイン'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('開いたページで学校アカウントへログインし、次のコードを入力してください。'),
              const SizedBox(height: 16),
              SelectableText(
                login.userCode,
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('入力した・接続を待つ'),
            ),
          ],
        ),
      );
      if (waitForLogin != true || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microsoftのログイン完了を待っています…')),
      );
      await cloudService.completeTeamsLogin(login);
      teamsConnected = true;
      cloudMessage = 'Teams接続済み';
      await cloudService.configureBackgroundSync();
      await syncCloud();
      if (mounted) setState(() {});
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Teams接続に失敗しました: $error')),
      );
    }
  }

  Future<void> loadData() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = preferences.getString(_storageKey);

      if (saved != null) {
        final data = jsonDecode(saved) as Map<String, dynamic>;

        assignments
          ..clear()
          ..addAll(
            (data['assignments'] as List<dynamic>? ?? const [])
                .map((item) => Assignment.fromJson(
                      Map<String, dynamic>.from(item as Map),
                    )),
          );
        schedules
          ..clear()
          ..addAll(
            (data['schedules'] as List<dynamic>? ?? const [])
                .map((item) => ScheduleItem.fromJson(
                      Map<String, dynamic>.from(item as Map),
                    )),
          );
        watches
          ..clear()
          ..addAll(
            (data['watches'] as List<dynamic>? ?? const [])
                .map((item) => WatchItem.fromJson(
                      Map<String, dynamic>.from(item as Map),
                    )),
          );
        watchResults
          ..clear()
          ..addAll(
            (data['watchResults'] as List<dynamic>? ?? const [])
                .map((item) => WatchResult.fromJson(
                      Map<String, dynamic>.from(item as Map),
                    )),
          );

        // A WatchResult is only "saved" while its linked calendar entry exists.
        // This also repairs old data where the calendar item was deleted but
        // the Watch card remained stuck on "保存済み".
        for (final result in watchResults) {
          if (!result.autoSaved) continue;
          final externalId = 'watch-date:${result.id}';
          final stillSaved =
              schedules.any((item) => item.externalId == externalId);
          if (!stillSaved) {
            result.autoSaved = false;
          }
        }

        notificationsEnabled =
            data['notificationsEnabled'] as bool? ?? true;
        defaultReminderMinutes =
            data['defaultReminderMinutes'] as int? ?? 30;
        weatherEnabled = data['weatherEnabled'] as bool? ?? true;
      }
    } catch (_) {
      // 保存データが壊れていても、初期状態でアプリを起動できるようにする。
    }

    if (mounted) {
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<void> saveData() async {
    final preferences = await SharedPreferences.getInstance();
    final data = {
      'assignments': assignments.map((item) => item.toJson()).toList(),
      'schedules': schedules.map((item) => item.toJson()).toList(),
      'watches': watches.map((item) => item.toJson()).toList(),
      'watchResults': watchResults
          .map((item) => {
                'id': item.id,
                'keyword': item.keyword,
                'title': item.title,
                'summary': item.summary,
                'url': item.url,
                'foundAt': item.foundAt.toIso8601String(),
                'watchType': item.watchType,
                'currentPrice': item.currentPrice,
                'targetPrice': item.targetPrice,
                'comparedSources': item.comparedSources,
                'candidateEventAt': item.candidateEventAt?.toIso8601String(),
                'candidateSourceCount': item.candidateSourceCount,
                'autoSaved': item.autoSaved,
              })
          .toList(),
      'notificationsEnabled': notificationsEnabled,
      'defaultReminderMinutes': defaultReminderMinutes,
      'weatherEnabled': weatherEnabled,
    };
    await preferences.setString(_storageKey, jsonEncode(data));
  }

  void updateAndSave(VoidCallback change) {
    setState(change);
    saveData();
    refreshNotificationsSafely();
  }

  Future<void> refreshNotificationsSafely() async {
    try {
      await syncAllNotifications();
    } catch (_) {
      // 通知に失敗しても入力内容の保存と画面操作は継続する。
    }
  }

  Future<void> initializeNotifications() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    tz_data.initializeTimeZones();
    try {
      final currentTimeZone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(currentTimeZone.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Asia/Tokyo'));
    }

    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await notificationPlugin.initialize(settings: initializationSettings);
    await notificationPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    notificationsReady = true;
  }

  int newNotificationId() {
    final value = DateTime.now().microsecondsSinceEpoch.remainder(2147483000);
    return value == 0 ? 1 : value;
  }

  Future<void> ensureNotificationIds() async {
    var changed = false;
    final usedIds = <int>{};

    for (final assignment in assignments) {
      if (assignment.notificationId == 0 ||
          usedIds.contains(assignment.notificationId)) {
        assignment.notificationId = newNotificationId() + usedIds.length;
        changed = true;
      }
      usedIds.add(assignment.notificationId);
    }
    for (final item in schedules) {
      if (item.notificationId == 0 || usedIds.contains(item.notificationId)) {
        item.notificationId = newNotificationId() + usedIds.length;
        changed = true;
      }
      usedIds.add(item.notificationId);
    }

    if (changed) await saveData();
  }

  Future<void> syncAllNotifications() async {
    if (!notificationsReady) return;

    await notificationPlugin.cancelAll();
    if (!notificationsEnabled) return;

    for (final assignment in assignments) {
      await scheduleReminder(
        id: assignment.notificationId,
        title: assignment.title,
        eventDate: assignment.deadline,
        reminderMinutes: assignment.reminderMinutes,
        completed: assignment.completed,
        typeLabel: 'タスク',
      );
    }
    for (final item in schedules) {
      await scheduleReminder(
        id: item.notificationId,
        title: item.title,
        eventDate: item.date,
        reminderMinutes: item.reminderMinutes,
        completed: item.completed,
        typeLabel: '予定',
      );
    }
  }

  Future<void> scheduleReminder({
    required int id,
    required String title,
    required DateTime eventDate,
    required int reminderMinutes,
    required bool completed,
    required String typeLabel,
  }) async {
    if (id == 0 || completed || reminderMinutes < 0) return;

    final notificationTime =
        eventDate.subtract(Duration(minutes: reminderMinutes));
    if (!notificationTime.isAfter(DateTime.now())) return;

    await notificationPlugin.zonedSchedule(
      id: id,
      title: '$typeLabelの時間が近づいています',
      body: '$title ・ ${formatDateTime(eventDate)}',
      scheduledDate: tz.TZDateTime.from(notificationTime, tz.local),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _notificationChannelId,
          'Catchのリマインダー',
          channelDescription: '予定とタスクの事前通知',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: typeLabel,
    );
  }

  Future<void> showTestNotification() async {
    if (!notificationsReady) return;
    await notificationPlugin.show(
      id: newNotificationId(),
      title: 'Catch テスト通知',
      body: '通知は正常に動いています。',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _notificationChannelId,
          'Catchのリマインダー',
          channelDescription: '予定とタスクの事前通知',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final pages = [
      buildHome(),
      buildAssignments(),
      buildCalendar(),
      buildWatch(),
      buildSettings(),
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFF6F7FB),
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.bolt_rounded,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            const Text(
              'Catch',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),

      body: pages[selectedIndex],

      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            selectedIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'ホーム',
          ),
          NavigationDestination(
            icon: Icon(Icons.assignment_outlined),
            selectedIcon: Icon(Icons.assignment),
            label: 'タスク',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: '予定',
          ),
          NavigationDestination(
            icon: Icon(Icons.travel_explore_outlined),
            selectedIcon: Icon(Icons.travel_explore),
            label: 'ウォッチ',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '設定',
          ),
        ],
      ),
    );
  }

  // ============================================================
  // ホーム
  // ============================================================

  Widget buildHome() {
    final activeAssignments =
    assignments.where((assignment) => !assignment.completed).toList();

    activeAssignments.sort(
          (a, b) => a.deadline.compareTo(b.deadline),
    );

    final todaySchedules = schedules.where((item) {
      return isSameDay(item.date, DateTime.now()) && !item.completed;
    }).toList();

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Text(
          greeting(),
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),

        const SizedBox(height: 5),

        Text(
          '今日必要な情報をCatchしよう。',
          style: TextStyle(
            color: Colors.grey.shade700,
            fontSize: 15,
          ),
        ),

        const SizedBox(height: 18),

        Card(
          color: const Color(0xFFECEFFF),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const CircleAvatar(
                  child: Icon(Icons.document_scanner_outlined),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (kIsWeb || defaultTargetPlatform == TargetPlatform.iOS)
                            ? 'スクショからCatch'
                            : '画面からCatch',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        (kIsWeb || defaultTargetPlatform == TargetPlatform.iOS)
                            ? 'スクショから名前・カテゴリ・日時を推定し、確認してから追加します'
                            : '他のアプリの画面から、課題名・予定・日時を1画面だけ読み取ります',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: teamsCaptureStarting
                      ? null
                      : ((kIsWeb || defaultTargetPlatform == TargetPlatform.iOS)
                          ? startIosScreenshotCatch
                          : startTeamsScreenCapture),
                  child: teamsCaptureStarting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          (kIsWeb || defaultTargetPlatform == TargetPlatform.iOS)
                              ? '画像を選ぶ'
                              : '開始',
                        ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 24),

        // AI Catch
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [
                Color(0xFF405DE6),
                Color(0xFF7357E8),
              ],
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.auto_awesome,
                    color: Colors.white,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'AI Catch',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              Text(
                watches.isEmpty
                    ? '調べてほしいことをウォッチに登録すると\n新着ニュースを継続的に確認します。'
                    : '${watches.where((w) => w.enabled).length}件のテーマを監視中',
                style: const TextStyle(
                  color: Colors.white,
                  height: 1.5,
                ),
              ),

              const SizedBox(height: 16),

              FilledButton.tonal(
                onPressed: () {
                  setState(() {
                    selectedIndex = 3;
                  });
                },
                child: const Text('ウォッチを見る'),
              ),
            ],
          ),
        ),

        const SizedBox(height: 26),

        sectionTitle(
          '今日やること',
          Icons.check_circle_outline,
        ),

        const SizedBox(height: 10),

        if (todaySchedules.isEmpty)
          emptyCard(
            '今日の予定はありません',
            '予定タブから追加できます。',
          )
        else
          ...todaySchedules.map(
                (item) => scheduleCard(item),
          ),

        const SizedBox(height: 26),

        sectionTitle(
          '期限が近いタスク',
          Icons.schedule,
        ),

        const SizedBox(height: 10),

        if (activeAssignments.isEmpty)
          emptyCard(
            '登録されているタスクはありません',
            'タスクタブの＋から追加できます。',
          )
        else
          ...activeAssignments.take(3).map(
                (assignment) => assignmentCard(assignment),
          ),
      ],
    );
  }

  // ============================================================
  // タスク
  // ============================================================

  Widget buildAssignments() {
    final active =
    assignments.where((assignment) => !assignment.completed).toList();

    final completed =
    assignments.where((assignment) => assignment.completed).toList();

    active.sort(
          (a, b) => a.deadline.compareTo(b.deadline),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: showAddAssignmentDialog,
        icon: const Icon(Icons.add),
        label: const Text('タスクを追加'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const Text(
            'タスク',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 6),

          Text(
            '${active.length}件の未完了タスク',
            style: TextStyle(
              color: Colors.grey.shade700,
            ),
          ),

          const SizedBox(height: 14),

            if (active.isEmpty)
            emptyCard(
              'タスクはありません',
              '右下の「タスクを追加」から登録できます。',
            )
          else
            ...active.map(
                  (assignment) => assignmentCard(assignment),
            ),

          if (completed.isNotEmpty) ...[
            const SizedBox(height: 30),
            sectionTitle(
              '完了済み',
              Icons.done_all,
            ),
            const SizedBox(height: 10),
            ...completed.map(
                  (assignment) => assignmentCard(assignment),
            ),
          ],

          const SizedBox(height: 90),
        ],
      ),
    );
  }

  Widget assignmentCard(Assignment assignment) {
    final days = daysUntil(assignment.deadline);

    String deadlineText;

    if (days < 0) {
      deadlineText = '${days.abs()}日超過';
    } else if (days == 0) {
      deadlineText = '今日まで';
    } else if (days == 1) {
      deadlineText = '明日まで';
    } else {
      deadlineText = 'あと$days日';
    }

    Color deadlineColor;

    if (days < 0) {
      deadlineColor = Colors.red;
    } else if (days <= 1) {
      deadlineColor = Colors.orange;
    } else {
      deadlineColor = Theme.of(context).colorScheme.primary;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 8,
          ),
          leading: Checkbox(
            value: assignment.completed,
            onChanged: (value) {
              updateAndSave(() {
                assignment.completed = value ?? false;
              });
            },
          ),
          title: Text(
            assignment.title,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              decoration: assignment.completed
                  ? TextDecoration.lineThrough
                  : null,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              '${assignment.subject} ・ ${formatDateTime(assignment.deadline)}'
              '${assignment.reminderMinutes >= 0 ? ' ・ ${reminderLabel(assignment.reminderMinutes)}通知' : ''}',
            ),
          ),
          trailing: assignment.completed
              ? const Icon(
            Icons.check_circle,
            color: Colors.green,
          )
              : Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: deadlineColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              deadlineText,
              style: TextStyle(
                color: deadlineColor,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          onTap: () => showEditAssignmentDialog(assignment),
          onLongPress: () {
            updateAndSave(() {
              assignments.remove(assignment);
            });
          },
        ),
      ),
    );
  }

  String _weatherDateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  String weatherEmoji(int code) {
    if (code == 0) return '☀️';
    if (code == 1 || code == 2) return '🌤️';
    if (code == 3) return '☁️';
    if (code == 45 || code == 48) return '🌫️';
    if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) {
      return '🌧️';
    }
    if ((code >= 71 && code <= 77) || code == 85 || code == 86) {
      return '🌨️';
    }
    if (code >= 95) return '⛈️';
    return '🌡️';
  }

  String weatherLabel(int code) {
    if (code == 0) return '晴れ';
    if (code == 1) return 'ほぼ晴れ';
    if (code == 2) return '晴れ時々くもり';
    if (code == 3) return 'くもり';
    if (code == 45 || code == 48) return '霧';
    if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) {
      return '雨';
    }
    if ((code >= 71 && code <= 77) || code == 85 || code == 86) {
      return '雪';
    }
    if (code >= 95) return '雷雨';
    return '天気';
  }

  Future<void> refreshCalendarWeather() async {
    if (!weatherEnabled || weatherLoading) return;

    if (mounted) {
      setState(() {
        weatherLoading = true;
        weatherMessage = '現在地と天気を取得中…';
      });
    }

    try {
      final locationServiceEnabled =
          await Geolocator.isLocationServiceEnabled();
      if (!locationServiceEnabled) {
        throw Exception('端末の位置情報がOFFです');
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        throw Exception('位置情報の許可が必要です');
      }
      if (permission == LocationPermission.deniedForever) {
        throw Exception(
          kIsWeb
              ? 'ブラウザのアドレスバー横のサイト設定から位置情報を許可してください'
              : '設定からCatchの位置情報を許可してください',
        );
      }

      const settings = LocationSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 0,
      );
      final position = await Geolocator.getCurrentPosition(
        locationSettings: settings,
      ).timeout(const Duration(seconds: 15));

      final uri = Uri.https(
        'api.open-meteo.com',
        '/v1/forecast',
        <String, String>{
          'latitude': position.latitude.toStringAsFixed(5),
          'longitude': position.longitude.toStringAsFixed(5),
          'daily':
              'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max',
          'timezone': 'auto',
          'forecast_days': '16',
        },
      );

      final response =
          await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw Exception('天気データを取得できませんでした');
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final daily = Map<String, dynamic>.from(decoded['daily'] as Map);
      final dates = (daily['time'] as List<dynamic>? ?? const []);
      final codes = (daily['weather_code'] as List<dynamic>? ?? const []);
      final maxTemps =
          (daily['temperature_2m_max'] as List<dynamic>? ?? const []);
      final minTemps =
          (daily['temperature_2m_min'] as List<dynamic>? ?? const []);
      final rain =
          (daily['precipitation_probability_max'] as List<dynamic>? ??
              const []);

      final fetched = <String, DailyWeather>{};
      final count = [
        dates.length,
        codes.length,
        maxTemps.length,
        minTemps.length,
        rain.length,
      ].reduce((a, b) => a < b ? a : b);

      for (var i = 0; i < count; i++) {
        final date = DateTime.tryParse(dates[i].toString());
        if (date == null) continue;
        final weather = DailyWeather(
          date: date,
          weatherCode: (codes[i] as num?)?.toInt() ?? -1,
          maxTemp: (maxTemps[i] as num?)?.toDouble() ?? 0,
          minTemp: (minTemps[i] as num?)?.toDouble() ?? 0,
          precipitationProbability: (rain[i] as num?)?.toInt() ?? 0,
        );
        fetched[_weatherDateKey(date)] = weather;
      }

      if (!mounted) return;
      setState(() {
        weatherByDate
          ..clear()
          ..addAll(fetched);
        weatherUpdatedAt = DateTime.now();
        weatherMessage =
            '現在地付近・${fetched.length}日分を更新しました';
        weatherLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        weatherLoading = false;
        weatherMessage =
            error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Widget selectedDayWeatherCard() {
    if (!weatherEnabled) return const SizedBox.shrink();

    final weather = weatherByDate[_weatherDateKey(selectedDate)];
    if (weather == null) {
      return Card(
        child: ListTile(
          leading: weatherLoading
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_outlined),
          title: const Text('この日の天気'),
          subtitle: Text(
            weatherLoading
                ? '天気を取得中…'
                : '予報期間外、またはまだ取得できていません',
          ),
          trailing: IconButton(
            tooltip: '天気を更新',
            onPressed: weatherLoading ? null : refreshCalendarWeather,
            icon: const Icon(Icons.refresh),
          ),
        ),
      );
    }

    return Card(
      child: ListTile(
        leading: Text(
          weatherEmoji(weather.weatherCode),
          style: const TextStyle(fontSize: 30),
        ),
        title: Text(
          '${weatherLabel(weather.weatherCode)}  '
          '${weather.maxTemp.round()}℃ / ${weather.minTemp.round()}℃',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '降水確率 ${weather.precipitationProbability}% ・ 現在地付近',
        ),
        trailing: IconButton(
          tooltip: '天気を更新',
          onPressed: weatherLoading ? null : refreshCalendarWeather,
          icon: weatherLoading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        ),
      ),
    );
  }

  // ============================================================
  // カレンダー
  // ============================================================

  Widget buildCalendar() {
    final dayEntries = calendarEntriesForDay(selectedDate);
    final monthEntries = calendarEntriesForMonth(selectedDate);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: showAddScheduleDialog,
        icon: const Icon(Icons.add),
        label: const Text('予定を追加'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const Text(
            'カレンダー',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 20),

          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 600;

                  return TableCalendar<CalendarEntry>(
                    firstDay: DateTime(2025),
                    lastDay: DateTime(2035, 12, 31),
                    focusedDay: selectedDate,
                    startingDayOfWeek: StartingDayOfWeek.monday,
                    availableCalendarFormats: const {
                      CalendarFormat.month: '月',
                    },
                    calendarFormat: CalendarFormat.month,
                    rowHeight: compact ? 72 : 92,
                    daysOfWeekHeight: 28,
                    selectedDayPredicate: (date) =>
                        isSameDay(date, selectedDate),
                    eventLoader: calendarEntriesForDay,
                    onDaySelected: (selected, focused) {
                      setState(() {
                        selectedDate = selected;
                      });
                    },
                    onPageChanged: (focused) {
                      setState(() {
                        selectedDate = focused;
                      });
                    },
                    headerStyle: const HeaderStyle(
                      titleCentered: true,
                      formatButtonVisible: false,
                    ),
                    calendarStyle: const CalendarStyle(
                      outsideDaysVisible: true,
                      markersMaxCount: 0,
                    ),
                    calendarBuilders: CalendarBuilders<CalendarEntry>(
                      headerTitleBuilder: (context, date) => Text(
                        '${date.year}年 ${date.month}月',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      dowBuilder: (context, date) {
                        const labels = ['月', '火', '水', '木', '金', '土', '日'];
                        return Center(
                          child: Text(
                            labels[date.weekday - 1],
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: date.weekday == DateTime.sunday
                                  ? Colors.red
                                  : date.weekday == DateTime.saturday
                                      ? Colors.blue
                                      : Colors.grey.shade700,
                            ),
                          ),
                        );
                      },
                      defaultBuilder: (context, date, focused) =>
                          calendarDayCell(date, compact: compact),
                      todayBuilder: (context, date, focused) =>
                          calendarDayCell(
                            date,
                            isToday: true,
                            compact: compact,
                          ),
                      selectedBuilder: (context, date, focused) =>
                          calendarDayCell(
                            date,
                            isSelected: true,
                            compact: compact,
                          ),
                      outsideBuilder: (context, date, focused) =>
                          calendarDayCell(
                            date,
                            isOutside: true,
                            compact: compact,
                          ),
                    ),
                  );
                },
              ),
            ),
          ),

          const SizedBox(height: 12),

          selectedDayWeatherCard(),

          const SizedBox(height: 18),

          sectionTitle('今月の予定・タスク', Icons.view_agenda_outlined),

          const SizedBox(height: 10),

          if (monthEntries.isEmpty)
            emptyCard(
              '今月の予定・タスクはありません',
              '予定やタスクを追加すると、ここに表示されます。',
            )
          else
            ...monthEntries.map(
              (entry) => monthCalendarEntryCard(entry),
            ),

          const SizedBox(height: 24),

          Text(
            '${formatDate(selectedDate)} の予定・タスク',
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 12),

          if (dayEntries.isEmpty)
            emptyCard(
              'この日の予定・タスクはありません',
              '予定またはタスクを登録すると、ここに表示されます。',
            )
          else
            ...dayEntries.map(
                  (entry) => calendarEntryDetailCard(entry),
            ),

          const SizedBox(height: 90),
        ],
      ),
    );
  }

  void deleteScheduleAndUnlockWatch(ScheduleItem item) {
    updateAndSave(() {
      schedules.remove(item);

      const watchPrefix = 'watch-date:';
      if (item.externalId.startsWith(watchPrefix)) {
        final resultId = item.externalId.substring(watchPrefix.length);
        for (final result in watchResults) {
          if (result.id == resultId) {
            result.autoSaved = false;
            break;
          }
        }
      }
    });
  }

  Widget scheduleCard(ScheduleItem item) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: ListTile(
          leading: Checkbox(
            value: item.completed,
            onChanged: (value) {
              updateAndSave(() {
                item.completed = value ?? false;
              });
            },
          ),
          title: Text(
            item.title,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              decoration:
              item.completed ? TextDecoration.lineThrough : null,
            ),
          ),
          subtitle: Text(
            '${formatDateTime(item.date)}'
            '${item.reminderMinutes >= 0 ? ' ・ ${reminderLabel(item.reminderMinutes)}通知' : ''}',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '編集',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => showEditScheduleDialog(item),
              ),
              IconButton(
                tooltip: '削除',
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  deleteScheduleAndUnlockWatch(item);
                },
              ),
            ],
          ),
          onTap: () => showEditScheduleDialog(item),
        ),
      ),
    );
  }

  Widget monthCalendarEntryCard(CalendarEntry entry) {
    final colorScheme = Theme.of(context).colorScheme;
    final entryColor = entry.isAssignment ? Colors.orange : colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          leading: Container(
            width: 58,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            decoration: BoxDecoration(
              color: entryColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${entry.date.month}/${entry.date.day}',
              style: TextStyle(
                color: entryColor,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          title: Text(
            entry.title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              decoration: entry.completed ? TextDecoration.lineThrough : null,
            ),
          ),
          subtitle: Text(
            '${entry.isAssignment ? 'タスク' : '予定'} ・ ${formatTime(entry.date)}',
          ),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => editCalendarEntry(entry),
        ),
      ),
    );
  }

  List<CalendarEntry> calendarEntriesForDay(DateTime date) {
    final entries = <CalendarEntry>[
      ...schedules
          .where((item) => isSameDay(item.date, date))
          .map(CalendarEntry.forSchedule),
      ...assignments
          .where((item) => isSameDay(item.deadline, date))
          .map(CalendarEntry.forAssignment),
    ];
    return entries;
  }

  List<CalendarEntry> calendarEntriesForMonth(DateTime month) {
    final entries = <CalendarEntry>[
      ...schedules
          .where((item) =>
              item.date.year == month.year && item.date.month == month.month)
          .map(CalendarEntry.forSchedule),
      ...assignments
          .where((item) =>
              item.deadline.year == month.year &&
              item.deadline.month == month.month)
          .map(CalendarEntry.forAssignment),
    ];
    entries.sort((a, b) => a.date.compareTo(b.date));
    return entries;
  }

  Widget calendarEntryDetailCard(CalendarEntry entry) {
    if (entry.assignment != null) {
      return assignmentCard(entry.assignment!);
    }
    return scheduleCard(entry.schedule!);
  }

  void editCalendarEntry(CalendarEntry entry) {
    if (entry.assignment != null) {
      showEditAssignmentDialog(entry.assignment!);
    } else {
      showEditScheduleDialog(entry.schedule!);
    }
  }

  Widget calendarDayCell(
    DateTime date, {
    bool isToday = false,
    bool isSelected = false,
    bool isOutside = false,
    bool compact = false,
  }) {
    final dayEntries = calendarEntriesForDay(date);
    final colorScheme = Theme.of(context).colorScheme;
    final visibleEntry = dayEntries.isEmpty ? null : dayEntries.first;
    final entryColor = visibleEntry?.isAssignment == true
        ? Colors.orange
        : colorScheme.primary;

    return Container(
      margin: const EdgeInsets.all(2),
      padding: const EdgeInsets.fromLTRB(3, 4, 3, 3),
      decoration: BoxDecoration(
        color: isSelected
            ? colorScheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSelected
              ? colorScheme.primary
              : isToday
                  ? colorScheme.primary.withValues(alpha: 0.5)
                  : Colors.transparent,
          width: isSelected ? 1.5 : 1,
        ),
      ),
      child: Column(
        children: [
          Text(
            '${date.day}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected || isToday
                  ? FontWeight.bold
                  : FontWeight.normal,
              color: isOutside
                  ? Colors.grey.shade400
                  : isSelected
                      ? colorScheme.primary
                      : null,
            ),
          ),
          if (weatherEnabled &&
              weatherByDate[_weatherDateKey(date)] != null) ...[
            const SizedBox(height: 1),
            Builder(
              builder: (context) {
                final weather =
                    weatherByDate[_weatherDateKey(date)]!;
                return Text(
                  compact
                      ? '${weatherEmoji(weather.weatherCode)} ${weather.maxTemp.round()}°'
                      : '${weatherEmoji(weather.weatherCode)} '
                          '${weather.maxTemp.round()}°/${weather.minTemp.round()}°',
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    fontSize: compact ? 9 : 10,
                    fontWeight: FontWeight.w600,
                    color: isOutside
                        ? Colors.grey.shade400
                        : Colors.grey.shade700,
                  ),
                );
              },
            ),
          ],
          if (visibleEntry != null && compact) ...[
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: visibleEntry.completed
                    ? Colors.grey.shade400
                    : entryColor,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                dayEntries.length == 1 ? '●' : '${dayEntries.length}件',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
          if (visibleEntry != null && !compact) ...[
            const SizedBox(height: 2),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              decoration: BoxDecoration(
                color: visibleEntry.completed
                    ? Colors.grey.shade300
                    : entryColor,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                visibleEntry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: visibleEntry.completed
                      ? Colors.grey.shade700
                      : Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (dayEntries.length > 1)
              Text(
                'ほか${dayEntries.length - 1}件',
                style: TextStyle(
                  fontSize: 10,
                  color: isOutside
                      ? Colors.grey.shade400
                      : colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ],
      ),
    );
  }

  // ============================================================
  // ウォッチ検索チャット
  // ============================================================

  bool _looksLikeDateWatch(String keyword) => RegExp(
        r'(いつ|何時|日時|日程|発売日|発売時間|開催日|開催時間|開始日|開始時間|登場日|登場時間|配信日|配信時間|降臨|出現|来る日|来る時間)',
      ).hasMatch(keyword);

  int? _watchPriceThreshold(String keyword) {
    final text = keyword.replaceAll(',', '').replaceAll('，', '').replaceAll('￥', '¥');
    final man = RegExp(r'(\d+(?:\.\d+)?)\s*万円').firstMatch(text);
    if (man != null) {
      final v = double.tryParse(man.group(1) ?? '');
      if (v != null) return (v * 10000).round();
    }
    final yen = RegExp(r'(?:¥\s*)?(\d{3,8})\s*円').firstMatch(text);
    return yen == null ? null : int.tryParse(yen.group(1) ?? '');
  }

  String _watchStatusText(WatchItem watch) {
    if (!watch.enabled) return '監視を一時停止中';
    final price = _watchPriceThreshold(watch.keyword);
    if (price != null) return '価格監視中・複数サイトを比較して ¥$price 以下で通知';
    if (_looksLikeDateWatch(watch.keyword)) return '日時確定待ち・確定するまで自動監視を継続';
    return '監視中・新着はこの会話へ追加されます';
  }

  Future<void> submitWatchChat() async {
    final query = watchChatController.text.trim();
    if (query.isEmpty || cloudSyncing) return;
    watchChatController.clear();
    final existing = watches.where((watch) => watch.keyword == query);
    if (existing.isEmpty) {
      updateAndSave(() {
        watches.insert(0, WatchItem(keyword: query));
        selectedWatchKeyword = query;
      });
      await uploadWatches();
    } else {
      setState(() {
        existing.first.enabled = true;
        selectedWatchKeyword = query;
      });
      await saveData();
      await uploadWatches();
    }
    await checkAiNow();
  }

  Future<void> removeWatchConversation(WatchItem watch) async {
    updateAndSave(() {
      watches.remove(watch);
      watchResults.removeWhere((result) => result.keyword == watch.keyword);
      if (selectedWatchKeyword == watch.keyword) {
        selectedWatchKeyword = watches.isEmpty ? null : watches.first.keyword;
      }
    });
    await uploadWatches();
  }

  Future<void> quickConfirmWatchCandidate(WatchResult result) async {
    final candidate = result.candidateEventAt;
    if (candidate == null) return;
    final externalId = 'watch-date:${result.id}';
    updateAndSave(() {
      final existing = schedules.where((item) => item.externalId == externalId);
      if (existing.isNotEmpty) {
        existing.first
          ..title = result.title
          ..date = candidate;
      } else {
        schedules.add(ScheduleItem(
          title: result.title,
          date: candidate,
          externalId: externalId,
          reminderMinutes: defaultReminderMinutes,
          notificationId: newNotificationId(),
        ));
      }
      result.autoSaved = true;
      selectedDate = candidate;
    });
    await refreshNotificationsSafely();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('候補時刻を確認して保存しました: ${formatDateTime(candidate)}')),
    );
  }

  Future<void> confirmWatchDateChoice(
    WatchResult result,
    DateTime suggested,
  ) async {
    if (!mounted) return;

    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('日時を確認'),
        content: Text(
          'この情報元から読み取った日時は\n'
          '${formatDateTime(suggested)}\n\n'
          'この日時で保存するか、自分で日時を選び直してください。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'cancel'),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'edit'),
            child: const Text('日時を選び直す'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'save'),
            child: const Text('この日時で保存'),
          ),
        ],
      ),
    );

    if (!mounted || action == null || action == 'cancel') return;

    DateTime selected = suggested;
    if (action == 'edit') {
      final pickedDate = await showDatePicker(
        context: context,
        initialDate: suggested,
        firstDate: DateTime(DateTime.now().year - 1),
        lastDate: DateTime(DateTime.now().year + 10, 12, 31),
      );
      if (!mounted || pickedDate == null) return;

      final pickedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(suggested),
      );
      if (!mounted || pickedTime == null) return;

      selected = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );

      final finalOk = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('この日時で保存しますか？'),
          content: Text(formatDateTime(selected)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('戻る'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (finalOk != true) return;
    }

    result
      ..candidateEventAt = selected
      ..autoSaved = false;
    await saveData();
    if (!mounted) return;
    await quickConfirmWatchCandidate(result);
  }

  Future<void> chooseWatchResult(WatchResult result) async {
    DateTime? chosenDate = result.candidateEventAt;

    if (chosenDate == null && result.url.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('この情報元から日時を読み取っています…'),
          duration: Duration(seconds: 10),
        ),
      );
      try {
        final match = await cloudService.resolveEventDate(
          url: result.url,
          previewText: '${result.title}\n${result.summary}',
        );
        chosenDate = match?.date;
        if (chosenDate != null) {
          result
            ..candidateEventAt = chosenDate
            ..candidateSourceCount = 1
            ..autoSaved = false;
          await saveData();
          if (mounted) setState(() {});
        }
      } catch (_) {
        chosenDate = null;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }

    if (chosenDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('この検索結果から日時を読み取れませんでした。情報元を確認するか、下の複数サイト照合を使ってください。'),
          duration: Duration(seconds: 6),
        ),
      );
      return;
    }

    await confirmWatchDateChoice(result, chosenDate);
  }

  Future<void> saveWatchDateToCalendar(WatchResult result, DateTime? date) async {
    if (!mounted || _watchVerifyingIds.contains(result.id)) return;

    final generation = ++_watchVerifyGeneration;
    _watchVerifyingIds.add(result.id);
    setState(() {});

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('複数サイトの日時を照合中… 完了するまで続けます'),
        duration: Duration(hours: 1),
      ),
    );

    EventDateVerification verification;
    try {
      verification = await cloudService.verifyEventDateAcrossSources(
        keyword: result.keyword,
        title: result.title,
        url: result.url,
        previewText: result.summary,
      );
    } catch (_) {
      verification = const EventDateVerification(
        consensus: null,
        candidates: <EventDateMatch>[],
        checkedSources: 0,
      );
    } finally {
      _watchVerifyingIds.remove(result.id);
      if (mounted) setState(() {});
    }

    // A newer verification/search started while this request was running.
    // Ignore this response completely so an old result can never appear later.
    if (!mounted || generation != _watchVerifyGeneration) return;

    // The card no longer exists in the current results: also treat it as stale.
    if (!watchResults.any((item) => item.id == result.id)) return;

    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    if (verification.consensus != null &&
        verification.consensus!.hasExplicitTime) {
      result
        ..candidateEventAt = verification.consensus!.date
        ..candidateSourceCount = verification.checkedSources
        ..autoSaved = false;
      await saveData();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '日時候補を確認: ${formatDateTime(verification.consensus!.date)} '
            '（${verification.checkedSources}件確認）\n'
            '間違い防止のため、保存ボタンで確定してください。',
          ),
          duration: const Duration(seconds: 7),
        ),
      );
      return;
    }

    if (verification.candidates.isNotEmpty) {
      result
        ..candidateEventAt = verification.candidates.first.date
        ..candidateSourceCount = verification.checkedSources
        ..autoSaved = false;
      await saveData();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '日時は一致しませんでした。候補: '
            '${formatDateTime(verification.candidates.first.date)} '
            '（${verification.checkedSources}件確認）',
          ),
          duration: const Duration(seconds: 7),
        ),
      );
      return;
    }

    // Even when cross-source verification times out or finds no agreement,
    // keep the date already extracted from the original result as a visible
    // manual-confirmation candidate. Do not throw useful information away.
    final fallbackDate = result.candidateEventAt ?? date;
    final now = DateTime.now();
    final plausibleFallback = fallbackDate != null &&
        fallbackDate.year >= now.year - 1 &&
        fallbackDate.year <= now.year + 10;

    if (plausibleFallback && fallbackDate != null) {
      result
        ..candidateEventAt = fallbackDate
        ..candidateSourceCount =
            verification.checkedSources > 0 ? verification.checkedSources : 1
        ..autoSaved = false;
      await saveData();
      if (!mounted) return;
      setState(() {});

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '複数サイトでは確定できませんでした。日時候補: '
            '${formatDateTime(fallbackDate)}\n'
            '情報元を確認して、正しければ保存できます。',
          ),
          duration: const Duration(seconds: 8),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('確実な日時も日時候補も取得できませんでした。情報元から手動確認できます。'),
        duration: Duration(seconds: 6),
      ),
    );
  }

  Widget watchResultBubble(WatchResult result) {
    final candidate = result.candidateEventAt;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 620),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome, size: 18),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    result.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            if (result.summary.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(result.summary),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (result.url.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => launchUrl(Uri.parse(result.url)),
                    icon: const Icon(Icons.open_in_new, size: 17),
                    label: const Text('情報元'),
                  ),
                if (result.watchType == 'price' && result.currentPrice != null)
                  Chip(
                    avatar: const Icon(Icons.price_check, size: 17),
                    label: Text('¥${result.currentPrice} / 目標 ¥${result.targetPrice ?? 0}'),
                  )
                else if (result.autoSaved && candidate != null)
                  Chip(
                    avatar: const Icon(Icons.verified, size: 17),
                    label: Text('保存済み ${formatDateTime(candidate)}'),
                  )
                else if (_looksLikeDateWatch(result.keyword))
                  FilledButton.tonalIcon(
                    onPressed: () => chooseWatchResult(result),
                    icon: const Icon(Icons.check_circle_outline, size: 17),
                    label: const Text('これにする'),
                  )
              ],
            ),
            if (result.watchType == 'price' && result.currentPrice != null) ...[
              const SizedBox(height: 6),
              Text(
                '価格条件を達成・${result.comparedSources}サイト比較',
                style: TextStyle(fontSize: 12, color: Colors.green.shade800, fontWeight: FontWeight.w600),
              ),
            ],
            if (candidate != null && !result.autoSaved) ...[
              const SizedBox(height: 6),
              Text(
                '日時候補: ${formatDateTime(candidate)} ・「これにする」で確認してから保存',
                style: TextStyle(fontSize: 12, color: Colors.orange.shade800, fontWeight: FontWeight.w600),
              ),
            ],
            if (candidate == null &&
                !result.autoSaved &&
                _looksLikeDateWatch(result.keyword)) ...[
              const SizedBox(height: 6),
              Text(
                '日時はまだ未抽出。「これにする」でこの情報元から読み取ります。',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              '確認 ${formatDateTime(result.foundAt)}',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildWatch() {
    WatchItem? selected;
    for (final watch in watches) {
      if (watch.keyword == selectedWatchKeyword) {
        selected = watch;
        break;
      }
    }
    final activeWatch = selected;
    final results = activeWatch == null
        ? <WatchResult>[]
        : watchResults.where((result) => result.keyword == activeWatch.keyword).toList();
    results.sort((a, b) => a.foundAt.compareTo(b.foundAt));

    return Scaffold(
      backgroundColor: Colors.transparent,
      drawerEnableOpenDragGesture: true,
      drawerEdgeDragWidth: 56,
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    setState(() => selectedWatchKeyword = null);
                  },
                  icon: const Icon(Icons.add_comment_outlined),
                  label: const Text('新しい検索'),
                ),
              ),
              const ListTile(
                leading: Icon(Icons.history),
                title: Text('監視中のチャット', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              Expanded(
                child: watches.isEmpty
                    ? const Center(child: Text('まだチャットはありません'))
                    : ListView.builder(
                        itemCount: watches.length,
                        itemBuilder: (context, index) {
                          final watch = watches[index];
                          final count = watchResults
                              .where((result) => result.keyword == watch.keyword)
                              .length;
                          return ListTile(
                            selected: selectedWatchKeyword == watch.keyword,
                            leading: Icon(
                              watch.enabled ? Icons.notifications_active_outlined : Icons.pause_circle_outline,
                            ),
                            title: Text(watch.keyword, maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(watch.enabled ? '監視中・$count件' : '一時停止・$count件'),
                            onTap: () {
                              setState(() => selectedWatchKeyword = watch.keyword);
                              Navigator.pop(context);
                            },
                            trailing: PopupMenuButton<String>(
                              onSelected: (value) async {
                                if (value == 'toggle') {
                                  updateAndSave(() => watch.enabled = !watch.enabled);
                                  await uploadWatches();
                                } else if (value == 'delete') {
                                  await removeWatchConversation(watch);
                                }
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'toggle',
                                  child: Text(watch.enabled ? '監視を一時停止' : '監視を再開'),
                                ),
                                const PopupMenuItem(value: 'delete', child: Text('削除')),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
      body: Builder(
        builder: (watchContext) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: () => Scaffold.of(watchContext).openDrawer(),
                    icon: const Icon(Icons.menu),
                    tooltip: '履歴を開く',
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          activeWatch?.keyword ?? 'ウォッチ検索チャット',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                        ),
                        Text(
                          activeWatch == null
                              ? '知りたい情報を送ると、その後も同じチャットを監視します'
                              : _watchStatusText(activeWatch),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: cloudSyncing ? null : checkAiNow,
                    icon: cloudSyncing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    tooltip: '今すぐ更新',
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: activeWatch == null
                  ? ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        const SizedBox(height: 30),
                        const Icon(Icons.travel_explore, size: 58),
                        const SizedBox(height: 18),
                        const Text(
                          '何の最新情報をCatchする？',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '例：学校行事の開催日\n質問を送ると監視が始まり、更新は同じチャットへ追加されます。',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade700, height: 1.5),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Align(
                          alignment: Alignment.centerRight,
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 520),
                            margin: const EdgeInsets.only(bottom: 14),
                            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Text(activeWatch.keyword),
                          ),
                        ),
                        if (results.isEmpty)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Text(
                                _watchPriceThreshold(activeWatch.keyword) != null
                                    ? '価格監視を開始しました。複数サイトを比較し、指定価格以下になったとき通知します。'
                                    : _looksLikeDateWatch(activeWatch.keyword)
                                        ? '検索済み。確定日時はまだ見つかっていません。新しい情報が出るまで監視を続けます。'
                                        : '監視を開始しました。まだ新着はありません。右上の更新でも確認できます。',
                              ),
                            ),
                          )
                        else ...[
                          ...results.take(3).map(watchResultBubble),
                          if (_looksLikeDateWatch(activeWatch.keyword)) ...[
                            const SizedBox(height: 2),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: _watchVerifyingIds.isNotEmpty
                                    ? null
                                    : () {
                                        final visible = results.take(3).toList();
                                        if (visible.isEmpty) return;
                                        final seed = visible.firstWhere(
                                          (item) => item.candidateEventAt != null,
                                          orElse: () => visible.first,
                                        );
                                        saveWatchDateToCalendar(
                                          seed,
                                          seed.candidateEventAt,
                                        );
                                      },
                                icon: const Icon(Icons.fact_check_outlined),
                                label: Text(
                                  _watchVerifyingIds.isNotEmpty
                                      ? '複数サイトを照合中…'
                                      : 'この${results.take(3).length}件＋複数サイトで照合する',
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '3件のどれかを信用できるなら「これにする」。怪しいときだけ上の照合を使えます。',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                          ],
                        ],
                      ],
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: watchChatController,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => submitWatchChat(),
                        decoration: InputDecoration(
                          hintText: '知りたい最新情報を入力',
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: cloudSyncing ? null : submitWatchChat,
                      icon: const Icon(Icons.arrow_upward),
                      tooltip: '送信して監視開始',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 設定
  // ============================================================

  Widget buildSettings() {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text(
          '設定',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),

        const SizedBox(height: 22),

        const Text(
          '通知',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),

        const SizedBox(height: 8),

        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('通知を有効にする'),
                subtitle: const Text('タスクと予定を指定時刻に通知'),
                value: notificationsEnabled,
                onChanged: (value) {
                  updateAndSave(() {
                    notificationsEnabled = value;
                  });
                },
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: DropdownButtonFormField<int>(
                  initialValue: defaultReminderMinutes,
                  decoration: const InputDecoration(
                    labelText: '新規登録時の初期通知',
                    border: OutlineInputBorder(),
                  ),
                  items: reminderOptions.entries
                      .map(
                        (entry) => DropdownMenuItem<int>(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                      )
                      .toList(),
                  onChanged: notificationsEnabled
                      ? (value) {
                          if (value == null) return;
                          updateAndSave(() {
                            defaultReminderMinutes = value;
                          });
                        }
                      : null,
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.notifications_active_outlined),
                title: const Text('テスト通知を送る'),
                subtitle: const Text('Android端末で通知許可を確認できます'),
                enabled: notificationsEnabled && notificationsReady,
                onTap: notificationsEnabled && notificationsReady
                    ? () async {
                        await showTestNotification();
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('テスト通知を送りました')),
                        );
                      }
                    : null,
              ),
            ],
          ),
        ),

        const SizedBox(height: 28),

        const Text(
          '天気',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),

        const SizedBox(height: 8),

        Card(
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.cloud_outlined),
                title: const Text('カレンダーに天気を表示'),
                subtitle: Text(
                  kIsWeb
                      ? 'ブラウザの位置情報を天気取得時だけ使用します'
                      : '現在地は天気取得時だけ使用します',
                ),
                value: weatherEnabled,
                onChanged: (value) async {
                  setState(() {
                    weatherEnabled = value;
                    if (!value) {
                      weatherByDate.clear();
                      weatherMessage = '天気表示はOFFです';
                    }
                  });
                  await saveData();
                  if (value) {
                    await refreshCalendarWeather();
                  }
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: weatherLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location_outlined),
                title: const Text('現在地の天気を更新'),
                subtitle: Text(weatherMessage),
                enabled: weatherEnabled && !weatherLoading,
                trailing: const Icon(Icons.refresh),
                onTap: weatherEnabled && !weatherLoading
                    ? refreshCalendarWeather
                    : null,
              ),
              if (weatherEnabled)
                ListTile(
                  leading: const Icon(Icons.location_on_outlined),
                  title: Text(
                    kIsWeb ? 'ブラウザの位置情報を許可' : '位置情報の設定を開く',
                  ),
                  subtitle: const Text('許可を変更したい場合'),
                  onTap: () async {
                    if (kIsWeb) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'ブラウザのアドレスバー横にあるサイト設定から、位置情報を「許可」にしてください。',
                          ),
                        ),
                      );
                    } else {
                      await Geolocator.openAppSettings();
                    }
                  },
                ),
            ],
          ),
        ),

        const SizedBox(height: 30),

        Center(
          child: Text(
            'Catch v0.37',
            style: TextStyle(
              color: Colors.grey.shade600,
            ),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // 追加ダイアログ
  // ============================================================

  Future<void> showEditAssignmentDialog(Assignment assignment) async {
    final titleController = TextEditingController(text: assignment.title);
    final subjectController = TextEditingController(text: assignment.subject);
    DateTime deadline = assignment.deadline;
    int reminderMinutes = assignment.reminderMinutes;

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('タスクを編集'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(labelText: 'タスク名'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: subjectController,
                      decoration: const InputDecoration(labelText: 'カテゴリ'),
                    ),
                    const SizedBox(height: 20),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.event),
                      title: const Text('期限の日付'),
                      subtitle: Text(formatDate(deadline)),
                      onTap: () async {
                        final result = await showDatePicker(
                          context: context,
                          initialDate: deadline,
                          firstDate: DateTime(2025),
                          lastDate: DateTime(2035),
                        );

                        if (result != null) {
                          setDialogState(() {
                            deadline = DateTime(
                              result.year,
                              result.month,
                              result.day,
                              deadline.hour,
                              deadline.minute,
                            );
                          });
                        }
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.schedule),
                      title: const Text('期限の時刻'),
                      subtitle: Text(formatTime(deadline)),
                      onTap: () async {
                        final result = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(deadline),
                        );
                        if (result != null) {
                          setDialogState(() {
                            deadline = DateTime(
                              deadline.year,
                              deadline.month,
                              deadline.day,
                              result.hour,
                              result.minute,
                            );
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      initialValue: reminderMinutes,
                      decoration: const InputDecoration(
                        labelText: '事前通知',
                        border: OutlineInputBorder(),
                      ),
                      items: reminderOptions.entries
                          .map(
                            (entry) => DropdownMenuItem<int>(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => reminderMinutes = value);
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('キャンセル'),
                ),
                FilledButton(
                  onPressed: () {
                    if (titleController.text.trim().isEmpty) {
                      return;
                    }

                    updateAndSave(() {
                      assignment.title = titleController.text.trim();
                      assignment.subject = subjectController.text.trim().isEmpty
                          ? 'その他'
                          : subjectController.text.trim();
                      assignment.deadline = deadline;
                      assignment.reminderMinutes = reminderMinutes;
                    });
                    Navigator.pop(dialogContext);
                  },
                  child: const Text('更新'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> showEditScheduleDialog(ScheduleItem item) async {
    final controller = TextEditingController(text: item.title);
    DateTime date = item.date;
    int reminderMinutes = item.reminderMinutes;

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('予定を編集'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: '予定名'),
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.event),
                      title: const Text('日付'),
                      subtitle: Text(formatDate(date)),
                      onTap: () async {
                        final result = await showDatePicker(
                          context: context,
                          initialDate: date,
                          firstDate: DateTime(2025),
                          lastDate: DateTime(2035),
                        );

                        if (result != null) {
                          setDialogState(() {
                            date = DateTime(
                              result.year,
                              result.month,
                              result.day,
                              date.hour,
                              date.minute,
                            );
                          });
                        }
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.schedule),
                      title: const Text('時刻'),
                      subtitle: Text(formatTime(date)),
                      onTap: () async {
                        final result = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(date),
                        );
                        if (result != null) {
                          setDialogState(() {
                            date = DateTime(
                              date.year,
                              date.month,
                              date.day,
                              result.hour,
                              result.minute,
                            );
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      initialValue: reminderMinutes,
                      decoration: const InputDecoration(
                        labelText: '事前通知',
                        border: OutlineInputBorder(),
                      ),
                      items: reminderOptions.entries
                          .map(
                            (entry) => DropdownMenuItem<int>(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => reminderMinutes = value);
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('キャンセル'),
                ),
                FilledButton(
                  onPressed: () {
                    if (controller.text.trim().isEmpty) {
                      return;
                    }

                    updateAndSave(() {
                      item.title = controller.text.trim();
                      item.date = date;
                      item.reminderMinutes = reminderMinutes;
                      selectedDate = date;
                    });
                    Navigator.pop(dialogContext);
                  },
                  child: const Text('更新'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> showAddAssignmentDialog() async {
    final titleController = TextEditingController();
    final subjectController = TextEditingController();

    final initialDay = DateTime.now().add(const Duration(days: 7));
    DateTime deadline = DateTime(
      initialDay.year,
      initialDay.month,
      initialDay.day,
      17,
    );
    int reminderMinutes = defaultReminderMinutes;

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('タスクを追加'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: 'タスク名',
                        hintText: '例：資料を提出',
                      ),
                    ),

                    const SizedBox(height: 12),

                    TextField(
                      controller: subjectController,
                      decoration: const InputDecoration(
                        labelText: 'カテゴリ',
                        hintText: '例：仕事、学校、個人',
                      ),
                    ),

                    const SizedBox(height: 20),

                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.event),
                      title: const Text('期限の日付'),
                      subtitle: Text(formatDate(deadline)),
                      onTap: () async {
                        final result = await showDatePicker(
                          context: context,
                          initialDate: deadline,
                          firstDate: DateTime.now().subtract(
                            const Duration(days: 365),
                          ),
                          lastDate: DateTime(2035),
                        );

                        if (result != null) {
                          setDialogState(() {
                            deadline = DateTime(
                              result.year,
                              result.month,
                              result.day,
                              deadline.hour,
                              deadline.minute,
                            );
                          });
                        }
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.schedule),
                      title: const Text('期限の時刻'),
                      subtitle: Text(formatTime(deadline)),
                      onTap: () async {
                        final result = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(deadline),
                        );
                        if (result != null) {
                          setDialogState(() {
                            deadline = DateTime(
                              deadline.year,
                              deadline.month,
                              deadline.day,
                              result.hour,
                              result.minute,
                            );
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      initialValue: reminderMinutes,
                      decoration: const InputDecoration(
                        labelText: '事前通知',
                        border: OutlineInputBorder(),
                      ),
                      items: reminderOptions.entries
                          .map(
                            (entry) => DropdownMenuItem<int>(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => reminderMinutes = value);
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                  },
                  child: const Text('キャンセル'),
                ),
                FilledButton(
                  onPressed: () {
                    if (titleController.text.trim().isEmpty) {
                      return;
                    }

                    updateAndSave(() {
                      assignments.add(
                        Assignment(
                          title: titleController.text.trim(),
                          subject: subjectController.text.trim().isEmpty
                              ? 'その他'
                              : subjectController.text.trim(),
                          deadline: deadline,
                          reminderMinutes: reminderMinutes,
                          notificationId: newNotificationId(),
                        ),
                      );
                    });

                    Navigator.pop(dialogContext);
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> showAddScheduleDialog() async {
    final controller = TextEditingController();
    DateTime date = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      9,
    );
    int reminderMinutes = defaultReminderMinutes;

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('予定を追加'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: '予定名',
                        hintText: '例：打ち合わせ',
                      ),
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.event),
                      title: const Text('日付'),
                      subtitle: Text(formatDate(date)),
                      onTap: () async {
                        final result = await showDatePicker(
                          context: context,
                          initialDate: date,
                          firstDate:
                              DateTime.now().subtract(const Duration(days: 365)),
                          lastDate: DateTime(2035),
                        );
                        if (result != null) {
                          setDialogState(() {
                            date = DateTime(
                              result.year,
                              result.month,
                              result.day,
                              date.hour,
                              date.minute,
                            );
                          });
                        }
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.schedule),
                      title: const Text('時刻'),
                      subtitle: Text(formatTime(date)),
                      onTap: () async {
                        final result = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(date),
                        );
                        if (result != null) {
                          setDialogState(() {
                            date = DateTime(
                              date.year,
                              date.month,
                              date.day,
                              result.hour,
                              result.minute,
                            );
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      initialValue: reminderMinutes,
                      decoration: const InputDecoration(
                        labelText: '事前通知',
                        border: OutlineInputBorder(),
                      ),
                      items: reminderOptions.entries
                          .map(
                            (entry) => DropdownMenuItem<int>(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => reminderMinutes = value);
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('キャンセル'),
                ),
                FilledButton(
                  onPressed: () {
                    if (controller.text.trim().isEmpty) return;
                    updateAndSave(() {
                      schedules.add(
                        ScheduleItem(
                          title: controller.text.trim(),
                          date: date,
                          reminderMinutes: reminderMinutes,
                          notificationId: newNotificationId(),
                        ),
                      );
                      selectedDate = date;
                    });
                    Navigator.pop(dialogContext);
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ============================================================
  // 共通UI
  // ============================================================

  Widget sectionTitle(String title, IconData icon) {
    return Row(
      children: [
        Icon(
          icon,
          size: 21,
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget emptyCard(
      String title,
      String subtitle,
      ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 35,
              color: Colors.grey.shade500,
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void showInfo(
      String title,
      String message,
      ) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  // ============================================================
  // 日付処理
  // ============================================================

  bool isSameDay(
      DateTime a,
      DateTime b,
      ) {
    return a.year == b.year &&
        a.month == b.month &&
        a.day == b.day;
  }

  int daysUntil(DateTime date) {
    final now = DateTime.now();

    final today = DateTime(
      now.year,
      now.month,
      now.day,
    );

    final target = DateTime(
      date.year,
      date.month,
      date.day,
    );

    return target.difference(today).inDays;
  }

  String formatDate(DateTime date) {
    return '${date.year}/${date.month}/${date.day}';
  }

  String formatTime(DateTime date) {
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String formatDateTime(DateTime date) {
    return '${formatDate(date)} ${formatTime(date)}';
  }

  String reminderLabel(int minutes) {
    return reminderOptions[minutes] ?? '$minutes分前';
  }

  String greeting() {
    final hour = DateTime.now().hour;

    if (hour < 11) {
      return 'おはよう';
    }

    if (hour < 18) {
      return 'こんにちは';
    }

    return 'こんばんは';
  }
}
