import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'package:xml/xml.dart';

const catchCloudTaskName = 'catch-free-direct-sync';
const catchCloudUniqueName = 'catch-free-periodic-sync';

@pragma('vm:entry-point')
void catchCloudCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != catchCloudTaskName) return true;
    try {
      final result = await CatchCloudService().sync();
      if (result.newItemCount > 0) {
        final plugin = FlutterLocalNotificationsPlugin();
        const settings = InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        );
        await plugin.initialize(settings: settings);
        final nullableResults = result.watchResults.cast<Map<String, dynamic>?>();
        final priceAlert = nullableResults.firstWhere(
          (item) => item?['watchType'] == 'price',
          orElse: () => null,
        );
        // v0.17: background search must never claim a date was confirmed.
        // Date confirmation is only accepted in the foreground.
        final Map<String, dynamic>? dateAlert = null;
        final title = priceAlert != null
            ? 'Catch: 価格条件を達成'
            : dateAlert != null
                ? 'Catch: 日時が確定しました'
                : 'Catchが新着を見つけました';
        final body = priceAlert != null
            ? (priceAlert['summary']?.toString() ?? '指定した価格を下回りました。')
            : dateAlert != null
                ? '${dateAlert['title'] ?? '予定'} をカレンダーへ自動保存しました。'
                : 'Teams・ウォッチチャットに${result.newItemCount}件の更新があります。';
        await plugin.show(
          id: DateTime.now().millisecondsSinceEpoch.remainder(2147483000),
          title: title,
          body: body,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'catch_free_updates',
              'Catchの無料同期',
              channelDescription: 'Teams・ウォッチ・価格条件の新着通知',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
        );
      }
      return true;
    } catch (_) {
      return false;
    }
  });
}

class CloudSyncResult {
  const CloudSyncResult({
    required this.tasks,
    required this.watchResults,
    required this.teamsConnected,
    required this.needsAdminConsent,
  });

  final List<Map<String, dynamic>> tasks;
  final List<Map<String, dynamic>> watchResults;
  final bool teamsConnected;
  final bool needsAdminConsent;
  int get newItemCount => tasks.length + watchResults.length;
}

class TeamsDeviceLogin {
  const TeamsDeviceLogin({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int expiresIn;
  final int interval;
}

class EventDateMatch {
  const EventDateMatch({
    required this.date,
    required this.hasExplicitTime,
    required this.evidence,
  });

  final DateTime date;
  final bool hasExplicitTime;
  final String evidence;
}

class EventDateVerification {
  const EventDateVerification({
    required this.consensus,
    required this.candidates,
    required this.checkedSources,
  });

  final EventDateMatch? consensus;
  final List<EventDateMatch> candidates;
  final int checkedSources;

  bool get canAutoSave => consensus != null && consensus!.hasExplicitTime;
}

class CatchCloudService {
  static const _clientIdKey = 'catch_free_teams_client_id';
  static const _tenantKey = 'catch_free_teams_tenant';
  static const _accessKey = 'catch_free_teams_access';
  static const _refreshKey = 'catch_free_teams_refresh';
  static const _expiresKey = 'catch_free_teams_expires';
  static const _tasksKey = 'catch_cloud_task_inbox';
  static const _resultsKey = 'catch_cloud_watch_inbox';
  static const _watchesKey = 'catch_free_watches';
  static const _lastSyncKey = 'catch_cloud_last_sync';
  static const _lastAiKey = 'catch_free_last_ai_check';
  static const _priceAlertStateKey = 'catch_free_price_alert_state';
  static const _appStorageKey = 'catch_app_data_v1';
  static const _scopes =
      'offline_access openid profile '
      'https://graph.microsoft.com/EduRoster.ReadBasic '
      'https://graph.microsoft.com/EduAssignments.ReadBasic';

  // v0.5との互換名。無料ニュース検索はキー不要なので常に利用可能。
  Future<String> getApiUrl() async => 'free-news-search';
  Future<void> setApiUrl(String value) async {}
  Future<bool> isConfigured() async => true;

  Future<String> getTeamsClientId() async =>
      (await SharedPreferences.getInstance()).getString(_clientIdKey) ?? '';

  Future<String> getTeamsTenant() async =>
      (await SharedPreferences.getInstance()).getString(_tenantKey) ?? 'organizations';

  Future<void> setTeamsConfig(String clientId, String tenant) async {
    final id = clientId.trim();
    if (!RegExp(r'^[0-9a-fA-F-]{30,40}$').hasMatch(id)) {
      throw const FormatException('MicrosoftのアプリケーションIDを確認してください');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_clientIdKey, id);
    await prefs.setString(_tenantKey, tenant.trim().isEmpty ? 'organizations' : tenant.trim());
  }

  Future<bool> isTeamsConnected() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_refreshKey) ?? '').isNotEmpty ||
        (prefs.getString(_accessKey) ?? '').isNotEmpty;
  }

  Future<TeamsDeviceLogin> beginTeamsLogin() async {
    final id = await getTeamsClientId();
    if (id.isEmpty) throw StateError('先にMicrosoft連携設定を保存してください');
    final tenant = await getTeamsTenant();
    final response = await http.post(
      Uri.parse('https://login.microsoftonline.com/$tenant/oauth2/v2.0/devicecode'),
      headers: const {'content-type': 'application/x-www-form-urlencoded'},
      body: {'client_id': id, 'scope': _scopes},
    ).timeout(const Duration(seconds: 30));
    final data = _object(response.body);
    if (response.statusCode != 200) {
      throw StateError(data['error_description']?.toString() ?? 'Microsoftログインを開始できませんでした');
    }
    return TeamsDeviceLogin(
      deviceCode: data['device_code']?.toString() ?? '',
      userCode: data['user_code']?.toString() ?? '',
      verificationUri: data['verification_uri']?.toString() ?? 'https://microsoft.com/devicelogin',
      expiresIn: (data['expires_in'] as num?)?.toInt() ?? 900,
      interval: (data['interval'] as num?)?.toInt() ?? 5,
    );
  }

  Future<void> completeTeamsLogin(TeamsDeviceLogin login) async {
    final id = await getTeamsClientId();
    final tenant = await getTeamsTenant();
    final deadline = DateTime.now().add(Duration(seconds: login.expiresIn));
    var wait = login.interval.clamp(3, 15).toInt();
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(seconds: wait));
      final response = await http.post(
        Uri.parse('https://login.microsoftonline.com/$tenant/oauth2/v2.0/token'),
        headers: const {'content-type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'client_id': id,
          'device_code': login.deviceCode,
        },
      ).timeout(const Duration(seconds: 30));
      final data = _object(response.body);
      if (response.statusCode == 200) {
        await _saveTokens(data);
        return;
      }
      final error = data['error']?.toString();
      if (error == 'authorization_pending') continue;
      if (error == 'slow_down') {
        wait += 5;
        continue;
      }
      throw StateError(data['error_description']?.toString() ?? 'Microsoftログインに失敗しました');
    }
    throw StateError('ログイン時間切れです。もう一度試してください');
  }

  Future<void> _saveTokens(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final access = data['access_token']?.toString() ?? '';
    if (access.isEmpty) throw StateError('Microsoftトークンを取得できませんでした');
    await prefs.setString(_accessKey, access);
    final refresh = data['refresh_token']?.toString() ?? '';
    if (refresh.isNotEmpty) await prefs.setString(_refreshKey, refresh);
    final seconds = (data['expires_in'] as num?)?.toInt() ?? 3600;
    await prefs.setString(
      _expiresKey,
      DateTime.now().add(Duration(seconds: seconds - 60)).toIso8601String(),
    );
  }

  Future<String> _token() async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getString(_accessKey) ?? '';
    final expires = DateTime.tryParse(prefs.getString(_expiresKey) ?? '');
    if (current.isNotEmpty && expires != null && expires.isAfter(DateTime.now())) return current;
    final refresh = prefs.getString(_refreshKey) ?? '';
    if (refresh.isEmpty) throw StateError('Microsoft Teamsへ接続してください');
    final id = await getTeamsClientId();
    final tenant = await getTeamsTenant();
    final response = await http.post(
      Uri.parse('https://login.microsoftonline.com/$tenant/oauth2/v2.0/token'),
      headers: const {'content-type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'refresh_token',
        'client_id': id,
        'refresh_token': refresh,
        'scope': _scopes,
      },
    ).timeout(const Duration(seconds: 30));
    final data = _object(response.body);
    if (response.statusCode != 200) {
      throw StateError(data['error_description']?.toString() ?? 'Teamsへ再ログインしてください');
    }
    await _saveTokens(data);
    return data['access_token']?.toString() ?? '';
  }

  Future<List<Map<String, dynamic>>> _teamsTasks() async {
    if (!await isTeamsConnected()) return const [];
    final token = await _token();
    final classes = await _graph('https://graph.microsoft.com/v1.0/education/me/classes', token);
    final output = <Map<String, dynamic>>[];
    for (final classroom in classes) {
      final classId = classroom['id']?.toString() ?? '';
      if (classId.isEmpty) continue;
      final name = classroom['displayName']?.toString() ?? 'Microsoft Teams';
      final items = await _graph(
        'https://graph.microsoft.com/v1.0/education/classes/${Uri.encodeComponent(classId)}/assignments?\$select=id,displayName,dueDateTime,status',
        token,
      );
      for (final item in items) {
        if (item['status']?.toString() == 'draft') continue;
        final id = item['id']?.toString() ?? '';
        final due = DateTime.tryParse(item['dueDateTime']?.toString() ?? '');
        if (id.isEmpty || due == null) continue;
        if (due.isBefore(DateTime.now().subtract(const Duration(days: 30)))) continue;
        output.add({
          'externalId': 'teams:$classId:$id',
          'title': item['displayName']?.toString() ?? 'Teamsのタスク',
          'subject': name,
          'deadline': due.toLocal().toIso8601String(),
        });
      }
    }
    return output;
  }

  Future<List<Map<String, dynamic>>> _graph(String firstUrl, String token) async {
    final output = <Map<String, dynamic>>[];
    String? url = firstUrl;
    while (url != null && url.isNotEmpty) {
      final response = await http.get(
        Uri.parse(url),
        headers: {'authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 30));
      final data = _object(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = data['error'];
        final message = error is Map ? error['message']?.toString() : null;
        if (response.statusCode == 403) {
          throw StateError('学校管理者によるTeams権限の承認が必要です');
        }
        throw StateError(message ?? 'Teamsの取得に失敗しました (${response.statusCode})');
      }
      final values = data['value'];
      if (values is List) {
        output.addAll(values.whereType<Map>().map((e) => Map<String, dynamic>.from(e)));
      }
      url = data['@odata.nextLink']?.toString();
    }
    return output;
  }

  Future<void> uploadWatches(List<Map<String, dynamic>> watches) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_watchesKey, jsonEncode(watches));
  }

  Future<EventDateVerification> verifyEventDateAcrossSources({
    required String keyword,
    required String title,
    required String url,
    required String previewText,
  }) async {
    final base = keyword.trim().isEmpty ? title.trim() : keyword.trim();
    final queryText = '$base $title'
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final sources = <Map<String, String>>[];
    final seen = <String>{};
    final seenHeadlines = <String>{};

    Future<void> addSource(String sourceUrl, String text, String label) async {
      final cleanUrl = sourceUrl.trim();
      final host = Uri.tryParse(cleanUrl)?.host.toLowerCase() ?? '';
      final key = host.contains('news.google.com') && label.trim().isNotEmpty
          ? 'news-source:${label.trim().toLowerCase()}'
          : host.isNotEmpty
              ? host
              : '$label:${text.hashCode}';
      if (!seen.add(key)) return;
      final firstLine = text
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.trim().toLowerCase())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '');
      final headlineKey = firstLine.replaceAll(RegExp(r'\s+'), ' ');
      if (headlineKey.length >= 12 && !seenHeadlines.add(headlineKey)) return;
      var fullText = text;
      if (cleanUrl.isNotEmpty) {
        fullText = await loadEventSourceText(url: cleanUrl, previewText: text);
      }
      if (fullText.trim().isNotEmpty) {
        sources.add({'url': cleanUrl, 'label': label, 'text': fullText});
      }
    }

    await addSource(url, '$title\n$previewText', 'primary');

    final queries = <String>{
      queryText,
      '$queryText 公式',
      '$base site:x.com',
      '$base site:twitter.com',
    };
    final searchCandidates = <Map<String, dynamic>>[];
    for (final query in queries) {
      final found = await _searchAll(query, base);
      for (final item in found) {
        final itemTitle = item['title']?.toString() ?? '';
        final itemUrl = item['url']?.toString() ?? '';
        final description = item['summary']?.toString() ?? '';
        final source = item['source']?.toString() ?? '';
        if (itemTitle.isEmpty || itemUrl.isEmpty) continue;
        if (!_isRelevantResult(base, '$itemTitle $description $source')) continue;
        final host = Uri.tryParse(itemUrl)?.host.toLowerCase() ?? '';
        final official = _looksOfficial(itemUrl, source, itemTitle, description);
        final social = host.contains('x.com') || host.contains('twitter.com');
        final engine = item['engine']?.toString() ?? '';
        searchCandidates.add({
          'url': itemUrl,
          'text': '$itemTitle\n$description',
          'label': source.isEmpty ? host : source,
          'score': (official ? 220 : 0) + (social ? 90 : 0) + (engine == 'Bing RSS' ? 35 : engine == 'Google' ? 25 : 10),
        });
      }
    }
    searchCandidates.sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));
    for (final item in searchCandidates.take(6)) {
      await addSource(
        item['url']?.toString() ?? '',
        item['text']?.toString() ?? '',
        item['label']?.toString() ?? 'search',
      );
    }

    final dated = <EventDateMatch>[];
    for (final source in sources) {
      final match = _bestEventDate(source['text'] ?? '');
      if (match != null && match.hasExplicitTime) dated.add(match);
    }

    EventDateMatch? consensus;
    if (dated.length >= 2) {
      final groups = <String, List<EventDateMatch>>{};
      for (final match in dated) {
        final jst = match.date.toUtc().add(const Duration(hours: 9));
        final key = '${jst.year}-${jst.month}-${jst.day}-${jst.hour}-${jst.minute}';
        groups.putIfAbsent(key, () => <EventDateMatch>[]).add(match);
      }
      final agreed = groups.values.where((group) => group.length >= 2).toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      if (agreed.isNotEmpty) {
        final chosen = agreed.first.first;
        consensus = EventDateMatch(
          date: chosen.date,
          hasExplicitTime: true,
          evidence: '複数の公開情報で一致（${agreed.first.length}件）',
        );
      }
    }

    final uniqueCandidates = <EventDateMatch>[];
    final candidateKeys = <String>{};
    for (final match in dated) {
      final jst = match.date.toUtc().add(const Duration(hours: 9));
      final key = '${jst.year}-${jst.month}-${jst.day}-${jst.hour}-${jst.minute}';
      if (candidateKeys.add(key)) uniqueCandidates.add(match);
    }
    return EventDateVerification(
      consensus: consensus,
      candidates: uniqueCandidates,
      checkedSources: sources.length,
    );
  }

  Future<EventDateMatch?> resolveEventDate({
    required String url,
    required String previewText,
  }) async {
    final sourceText = await loadEventSourceText(
      url: url,
      previewText: previewText,
    );
    return _bestEventDate(sourceText);
  }

  Future<String> loadEventSourceText({
    required String url,
    required String previewText,
  }) async {
    var sourceText = previewText;
    if (url.trim().isNotEmpty) {
      try {
        final response = await http.get(
          Uri.parse(url),
          headers: const {
            'user-agent':
                'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36',
            'accept-language': 'ja,en-US;q=0.8,en;q=0.6',
          },
        ).timeout(const Duration(seconds: 15));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          sourceText = '$sourceText\n${_visiblePageText(response.body)}';
        } else {
          throw Exception('direct fetch ${response.statusCode}');
        }
      } catch (_) {
        // JS依存ページやBot対策で直接本文を取得できない場合はReader経由を試す。
        try {
          final reader = await http.get(
            Uri.parse('https://r.jina.ai/$url'),
            headers: const {'accept': 'text/plain', 'user-agent': 'Catch/0.13 Android'},
          ).timeout(const Duration(seconds: 18));
          if (reader.statusCode >= 200 && reader.statusCode < 300 && reader.body.trim().isNotEmpty) {
            sourceText = '$sourceText\n${reader.body}';
          }
        } catch (_) {
          // 最後は検索結果のタイトル・抜粋だけで日時候補を判定する。
        }
      }
    }
    return sourceText.length > 50000 ? sourceText.substring(0, 50000) : sourceText;
  }

  static String _visiblePageText(String html) {
    final meta = RegExp(
      r'''<meta[^>]+(?:name|property)=["'][^"']*(?:description|title)[^"']*["'][^>]+content=["']([^"']+)''',
      caseSensitive: false,
    ).allMatches(html).map((match) => match.group(1) ?? '').join(' ');
    final jsonLd = RegExp(
      r'''<script[^>]+type=["']application/ld\+json["'][^>]*>([\s\S]*?)</script>''',
      caseSensitive: false,
    ).allMatches(html).map((match) => match.group(1) ?? '').join(' ');
    final body = html
        .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(?:p|li|div|h1|h2|h3)>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), ' ');
    return _decodeHtml('$meta\n$jsonLd\n$body')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n+'), '\n')
        .trim();
  }

  static String _decodeHtml(String value) => value
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('\\u5e74', '年')
      .replaceAll('\\u6708', '月')
      .replaceAll('\\u65e5', '日');

  static EventDateMatch? _bestEventDate(String source) {
    final normalized = source
        .replaceAll('：', ':')
        .replaceAll('／', '/')
        .replaceAll(RegExp(r'\s+'), ' ');
    final expression = RegExp(
      r'(?:(20\d{2})\s*[年/.-]\s*)?(\d{1,2})\s*[月/.-]\s*(\d{1,2})\s*日?(?:\s*[（(]?[月火水木金土日]?[）)]?)?(?:\s*(\d{1,2})\s*[:時]\s*(\d{1,2})?\s*分?)?',
    );
    EventDateMatch? best;
    var bestScore = -999;
    final now = DateTime.now();
    for (final match in expression.allMatches(normalized)) {
      final month = int.tryParse(match.group(2) ?? '');
      final day = int.tryParse(match.group(3) ?? '');
      if (month == null || day == null || month < 1 || month > 12 || day < 1 || day > 31) {
        continue;
      }
      var year = int.tryParse(match.group(1) ?? '') ?? now.year;
      final nearbyStart = (match.start - 10).clamp(0, normalized.length);
      final nearbyEnd = (match.end + 120).clamp(0, normalized.length);
      final nearby = normalized.substring(nearbyStart, nearbyEnd);
      final nearbyTime = RegExp(
        r'(?:午前|午後)?\s*(\d{1,2})\s*(?::|時)\s*(\d{1,2})?\s*分?',
      ).firstMatch(nearby);
      final isNoon = RegExp(r'正午').hasMatch(nearby);
      final hourText = match.group(4) ?? nearbyTime?.group(1);
      final minuteText = match.group(5) ?? nearbyTime?.group(2);
      final hasTime = hourText != null || isNoon;
      var hour = isNoon ? 12 : (int.tryParse(hourText ?? '') ?? 12);
      final minute = int.tryParse(minuteText ?? '') ?? 0;
      if (nearbyTime != null && RegExp(r'午後').hasMatch(nearby.substring(0, nearbyTime.end)) && hour < 12) hour += 12;
      if (nearbyTime != null && RegExp(r'午前').hasMatch(nearby.substring(0, nearbyTime.end)) && hour == 12) hour = 0;
      if (hour > 23 || minute > 59) continue;
      var date = DateTime(year, month, day, hour, minute);
      final zoneText = nearby.toUpperCase();
      int? utcOffsetMinutes;
      if (zoneText.contains('JST') || zoneText.contains('日本時間')) {
        utcOffsetMinutes = 9 * 60;
      } else if (zoneText.contains('UTC') || zoneText.contains('GMT')) {
        final offset = RegExp(r'(?:UTC|GMT)\s*([+-])\s*(\d{1,2})(?::?(\d{2}))?').firstMatch(zoneText);
        if (offset == null) {
          utcOffsetMinutes = 0;
        } else {
          final sign = offset.group(1) == '-' ? -1 : 1;
          utcOffsetMinutes = sign * ((int.tryParse(offset.group(2) ?? '') ?? 0) * 60 + (int.tryParse(offset.group(3) ?? '') ?? 0));
        }
      } else if (zoneText.contains('PDT')) {
        utcOffsetMinutes = -7 * 60;
      } else if (zoneText.contains('PST')) {
        utcOffsetMinutes = -8 * 60;
      } else if (zoneText.contains('EDT')) {
        utcOffsetMinutes = -4 * 60;
      } else if (zoneText.contains('EST')) {
        utcOffsetMinutes = -5 * 60;
      }
      if (utcOffsetMinutes != null) {
        final utc = DateTime.utc(year, month, day, hour, minute)
            .subtract(Duration(minutes: utcOffsetMinutes));
        date = utc.toLocal();
      }
      if (match.group(1) == null && date.isBefore(now.subtract(const Duration(days: 30)))) {
        year++;
        if (utcOffsetMinutes != null) {
          final utc = DateTime.utc(year, month, day, hour, minute)
              .subtract(Duration(minutes: utcOffsetMinutes));
          date = utc.toLocal();
        } else {
          date = DateTime(year, month, day, hour, minute);
        }
      }
      if (date.month != month || date.day != day) continue;
      final start = (match.start - 45).clamp(0, normalized.length);
      final end = (match.end + (hasTime ? 120 : 45)).clamp(0, normalized.length);
      final evidence = normalized.substring(start, end);
      var score = hasTime ? 60 : 10;
      if (RegExp(r'(出現|開催|開始|発売|公開|配信|実施|締切|期限|開演|登場)').hasMatch(evidence)) {
        score += 35;
      }
      if (RegExp(r'(更新日|更新日時|投稿日|投稿時刻|掲載日|掲載日時|最終更新|記事公開|公開日時|配信日時|pubDate)', caseSensitive: false).hasMatch(evidence)) score -= 120;
      if (date.isAfter(now.subtract(const Duration(days: 1)))) score += 10;
      if (match.group(1) != null) score += 5;
      if (score > bestScore) {
        bestScore = score;
        best = EventDateMatch(
          date: date,
          hasExplicitTime: hasTime,
          evidence: evidence.trim(),
        );
      }
    }
    return best;
  }


  static String _watchMode(String keyword) {
    // v0.13: 汎用ルーター。特定ジャンル名ではなく「知りたい情報の型」で振り分ける。
    if (_priceThresholdYen(keyword) != null ||
        RegExp(r'(価格|値段|最安|セール|割引|安くなったら|下回ったら)').hasMatch(keyword)) {
      return 'price';
    }
    if (RegExp(r'(天気|予報|雨|晴れ|曇り|雪|降水|気温|最高気温|最低気温|湿度|風速|台風)').hasMatch(keyword)) {
      return 'weather';
    }
    if (RegExp(r'(いつ|何時|日時|日程|発売日|発売時間|開催日|開催時間|開始日|開始時間|登場日|登場時間|配信日|配信時間|降臨|出現|来る日|来る時間)').hasMatch(keyword)) {
      return 'date';
    }
    return 'news';
  }

  static int? _priceThresholdYen(String keyword) {
    final text = keyword.replaceAll(',', '').replaceAll('，', '').replaceAll('￥', '¥');
    final man = RegExp(r'(\d+(?:\.\d+)?)\s*万円').firstMatch(text);
    if (man != null) {
      final v = double.tryParse(man.group(1) ?? '');
      if (v != null) return (v * 10000).round();
    }
    final yen = RegExp(r'(?:¥\s*)?(\d{3,8})\s*円').firstMatch(text);
    if (yen != null) return int.tryParse(yen.group(1) ?? '');
    final under = RegExp(r'(?:under|below|less than)\s*¥?\s*(\d{3,8})', caseSensitive: false).firstMatch(text);
    if (under != null) return int.tryParse(under.group(1) ?? '');
    return null;
  }

  static String _cleanWatchQuery(String keyword) {
    var value = keyword
        .replaceAll(RegExp(r'[？?！!]'), ' ')
        .replaceAll(RegExp(r'(教えて|知りたい|調べて|検索して|について|いつですか|いつ|何時)'), ' ');
    if (_priceThresholdYen(keyword) != null) {
      value = value
          .replaceAll(RegExp(r'\d+(?:\.\d+)?\s*万円(?:以下|未満|切ったら|を切ったら|より安くなったら)?'), ' ')
          .replaceAll(RegExp(r'[¥￥]?\s*[\d,，]+\s*円(?:以下|未満|切ったら|を切ったら|より安くなったら)?'), ' ')
          .replaceAll(RegExp(r'(値段|価格|最安値|安くなったら|下回ったら|下がったら|以下になったら|未満になったら|通知して)'), ' ');
    }
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static List<String> _watchTerms(String keyword) {
    var value = _cleanWatchQuery(keyword)
        .replaceAll(RegExp(r'[、。,.!?！？「」『』【】()（）/\\・:：]'), ' ');
    final raw = RegExp(r'[A-Za-z0-9][A-Za-z0-9._+\-]*|[ァ-ヶー]{2,}|[一-龯々]{2,}|[ぁ-ん]{2,}')
        .allMatches(value)
        .map((m) => (m.group(0) ?? '').trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final generic = <String>{
      '公式','発表','予定','情報','最新','開催','開始','発売','公開','登場','出現','来る','くる',
      'アイテムショップ','ショップ','クエスト','イベント','日時','時間','日程','価格','値段','最安値',
      '以下','未満','通知','監視','比較','サイト','商品','通販','販売',
    };
    final out = <String>[];
    for (final token in raw) {
      if (token.length < 2 || generic.contains(token)) continue;
      if (!out.any((e) => e.toLowerCase() == token.toLowerCase())) out.add(token);
    }
    return out.take(8).toList();
  }

  static bool _isRelevantResult(String keyword, String text) {
    final normalized = text.toLowerCase();
    final terms = _watchTerms(keyword);
    if (terms.isEmpty) return true;
    final hits = terms.where((t) => normalized.contains(t.toLowerCase())).length;
    if (terms.length == 1) return hits == 1;
    if (terms.length == 2) return hits == 2;
    return hits >= 2 && hits / terms.length >= 0.5;
  }

  static bool _looksOfficial(String url, String source, String title, String summary) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    final all = '$host $source $title $summary'.toLowerCase();
    if (RegExp(r'(公式|official|オフィシャル|運営|メーカー|主催)').hasMatch(all)) return true;
    if (host.endsWith('.go.jp') || host.endsWith('.lg.jp') || host.endsWith('.ac.jp')) return true;
    return false;
  }


  static String? _extractWeatherPlace(String keyword) {
    final normalized = keyword
        .replaceAll(RegExp(r'[「」『』【】()（）!?！？、。]'), ' ')
        .replaceAll(RegExp(r'(天気|予報|雨|晴れ|曇り|雪|降水確率|降水|気温|最高気温|最低気温|湿度|風速|いつ|何時|何日|なる日|なる時間|降る日|降る時間|教えて|知りたい|調べて|通知して|になったら|だったら|なら)'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final suffix = RegExp(r'([一-龯々ぁ-んァ-ヶー]{2,}(?:都|道|府|県|市|区|町|村))').firstMatch(keyword);
    if (suffix != null) return suffix.group(1);
    final latin = RegExp(r'([A-Za-z][A-Za-z .-]{1,40})').firstMatch(normalized);
    if (latin != null) return latin.group(1)?.trim();
    final jp = RegExp(r'([一-龯々ぁ-んァ-ヶー]{2,12})').firstMatch(normalized);
    return jp?.group(1)?.trim();
  }

  static String _weatherLabel(int code) {
    if (code == 0) return '快晴';
    if (code <= 2) return '晴れ';
    if (code == 3) return '曇り';
    if ({45, 48}.contains(code)) return '霧';
    if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82) || (code >= 95 && code <= 99)) return '雨';
    if ((code >= 71 && code <= 77) || (code >= 85 && code <= 86)) return '雪';
    return '天気';
  }

  static bool _weatherMatches(String keyword, int code, double precip, double temp) {
    final q = keyword;
    final asksRain = RegExp(r'(雨|降水|降る)').hasMatch(q);
    final asksSun = RegExp(r'(晴れ|晴天|快晴)').hasMatch(q);
    final asksSnow = RegExp(r'(雪|降雪)').hasMatch(q);
    final asksCloud = RegExp(r'(曇り|くもり)').hasMatch(q);
    final above = RegExp(r'(-?\d+(?:\.\d+)?)\s*度(?:以上|超|を超)').firstMatch(q);
    final below = RegExp(r'(-?\d+(?:\.\d+)?)\s*度(?:以下|未満|を下回)').firstMatch(q);
    if (above != null) {
      final v = double.tryParse(above.group(1) ?? '');
      if (v != null && temp < v) return false;
    }
    if (below != null) {
      final v = double.tryParse(below.group(1) ?? '');
      if (v != null && temp > v) return false;
    }
    final conditionFlags = [asksRain, asksSun, asksSnow, asksCloud].where((e) => e).length;
    if (conditionFlags > 0) {
      final rainOk = asksRain && ((code >= 51 && code <= 67) || (code >= 80 && code <= 82) || (code >= 95 && code <= 99) || precip > 0.1);
      final sunOk = asksSun && code <= 2 && precip <= 0.1;
      final snowOk = asksSnow && ((code >= 71 && code <= 77) || (code >= 85 && code <= 86));
      final cloudOk = asksCloud && code == 3;
      if (!(rainOk || sunOk || snowOk || cloudOk)) return false;
    }
    return true;
  }

  Future<Map<String, dynamic>?> _geocodeWeatherPlace(String keyword) async {
    final place = _extractWeatherPlace(keyword);
    if (place == null || place.isEmpty) return null;
    final uri = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
      'name': place,
      'count': '5',
      'language': 'ja',
      'format': 'json',
    });
    final response = await http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) return null;
    final obj = _object(response.body);
    final results = obj['results'];
    if (results is! List || results.isEmpty) return null;
    final maps = results.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    if (maps.isEmpty) return null;
    // 日本語の市区町村名は完全一致を優先。見つからなければ先頭候補。
    maps.sort((a, b) {
      int score(Map<String, dynamic> m) {
        final name = m['name']?.toString() ?? '';
        final admin1 = m['admin1']?.toString() ?? '';
        var v = name == place ? 100 : (place.contains(name) || name.contains(place) ? 60 : 0);
        if (keyword.contains(admin1) && admin1.isNotEmpty) v += 30;
        if ((m['country_code']?.toString() ?? '').toUpperCase() == 'JP') v += 10;
        return v;
      }
      return score(b).compareTo(score(a));
    });
    return maps.first;
  }

  Future<Map<String, dynamic>?> _weatherWatchResult(String keyword) async {
    final geo = await _geocodeWeatherPlace(keyword);
    if (geo == null) return null;
    final lat = geo['latitude'];
    final lon = geo['longitude'];
    if (lat is! num || lon is! num) return null;
    final name = geo['name']?.toString() ?? _extractWeatherPlace(keyword) ?? '指定地点';
    final countryCode = (geo['country_code']?.toString() ?? '').toUpperCase();

    Future<Map<String, dynamic>?> loadForecast(String host, String path, Map<String, String> extra) async {
      final params = <String, String>{
        'latitude': lat.toString(),
        'longitude': lon.toString(),
        'hourly': 'temperature_2m,precipitation,weather_code',
        'timezone': 'auto',
        'forecast_days': countryCode == 'JP' && path.contains('jma') ? '7' : '16',
        ...extra,
      };
      final r = await http.get(Uri.https(host, path, params)).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      return _object(r.body);
    }

    final genericFuture = loadForecast('api.open-meteo.com', '/v1/forecast', const {});
    final jmaFuture = countryCode == 'JP'
        ? loadForecast('api.open-meteo.com', '/v1/jma', const {})
        : Future<Map<String, dynamic>?>.value(null);
    final data = await Future.wait([genericFuture, jmaFuture]);
    final generic = data[0];
    final jma = data[1];
    if (generic == null) return null;

    List<Map<String, dynamic>> slots(Map<String, dynamic> source) {
      final hourly = source['hourly'];
      if (hourly is! Map) return const [];
      final map = Map<String, dynamic>.from(hourly);
      final times = map['time'];
      final temps = map['temperature_2m'];
      final precips = map['precipitation'];
      final codes = map['weather_code'];
      if (times is! List || temps is! List || precips is! List || codes is! List) return const [];
      final n = [times.length, temps.length, precips.length, codes.length].reduce((a,b)=>a<b?a:b);
      final out = <Map<String, dynamic>>[];
      for (var i=0;i<n;i++) {
        final t = DateTime.tryParse(times[i].toString());
        final temp = (temps[i] as num?)?.toDouble();
        final precip = (precips[i] as num?)?.toDouble();
        final code = (codes[i] as num?)?.toInt();
        if (t == null || temp == null || precip == null || code == null) continue;
        if (_weatherMatches(keyword, code, precip, temp)) {
          out.add({'time': t, 'temp': temp, 'precip': precip, 'code': code});
        }
      }
      return out;
    }

    final primary = slots(generic);
    final secondary = jma == null ? <Map<String, dynamic>>[] : slots(jma);
    if (primary.isEmpty) return {
      'id': 'weather:${base64Url.encode(utf8.encode('$keyword|$name|none'))}',
      'keyword': keyword,
      'title': '$name の予報を確認しました',
      'summary': '現在の予報期間では条件に一致する時間は見つかりませんでした。予報更新後も監視を続けます。',
      'url': 'https://open-meteo.com/',
      'source': countryCode == 'JP' ? 'Open-Meteo / JMAモデル' : 'Open-Meteo',
      'foundAt': DateTime.now().toIso8601String(),
      'watchType': 'weather',
    };

    bool closeHour(DateTime a, DateTime b) => a.difference(b).inMinutes.abs() <= 60;
    final verified = <Map<String, dynamic>>[];
    for (final a in primary) {
      final at = a['time'] as DateTime;
      final agrees = secondary.any((b) => closeHour(at, b['time'] as DateTime));
      if (secondary.isEmpty || agrees) verified.add(a);
    }
    final chosen = (verified.isNotEmpty ? verified : primary).take(8).toList();
    String fmt(DateTime d) => '${d.month}/${d.day} ${d.hour.toString().padLeft(2,'0')}:00';
    final summary = chosen.map((e) {
      final d = e['time'] as DateTime;
      final temp = (e['temp'] as double).toStringAsFixed(1);
      final precip = (e['precip'] as double).toStringAsFixed(1);
      final label = _weatherLabel(e['code'] as int);
      return '${fmt(d)} $label ${temp}℃ 降水${precip}mm';
    }).join(' / ');
    final modelText = countryCode == 'JP'
        ? (verified.isNotEmpty ? 'Open-Meteo Best Match とJMA系モデルで一致する時間を優先' : 'Open-Meteo Best Match（JMA系モデルと不一致の候補を含む）')
        : 'Open-Meteo Best Match';
    final fingerprint = base64Url.encode(utf8.encode('$keyword|$name|$summary'));
    return {
      'id': 'weather:$fingerprint',
      'keyword': keyword,
      'title': '$name の条件に合う予報',
      'summary': '$summary\n$modelText',
      'url': 'https://open-meteo.com/',
      'source': modelText,
      'foundAt': DateTime.now().toIso8601String(),
      'watchType': 'weather',
      'candidateSourceCount': countryCode == 'JP' ? 2 : 1,
    };
  }

  static List<int> _extractPrices(String text) {
    final cleaned = text.replaceAll('，', ',').replaceAll('￥', '¥');
    final values = <int>[];
    for (final m in RegExp(r'¥\s*([\d,]{3,12})').allMatches(cleaned)) {
      final v = int.tryParse((m.group(1) ?? '').replaceAll(',', ''));
      if (v != null && v >= 100 && v <= 100000000) values.add(v);
    }
    for (final m in RegExp(r'([\d,]{3,12})\s*円').allMatches(cleaned)) {
      final v = int.tryParse((m.group(1) ?? '').replaceAll(',', ''));
      if (v != null && v >= 100 && v <= 100000000) values.add(v);
    }
    for (final m in RegExp(r'(\d+(?:\.\d+)?)\s*万円').allMatches(cleaned)) {
      final v = double.tryParse(m.group(1) ?? '');
      if (v != null) {
        final yen = (v * 10000).round();
        if (yen >= 100 && yen <= 100000000) values.add(yen);
      }
    }
    values.sort();
    return values.toSet().toList();
  }

  static String _unwrapGoogleUrl(String href) {
    if (href.startsWith('/url?')) {
      final uri = Uri.tryParse('https://www.google.com$href');
      return uri?.queryParameters['q'] ?? uri?.queryParameters['url'] ?? '';
    }
    return href;
  }


  Future<List<Map<String, dynamic>>> _readerGoogleSearch(String query, String keyword) async {
    // Google の検索結果ページを Jina Reader でテキスト化して取得する。
    // HTML 構造変更や同意画面の影響を受けにくく、APIキー不要の基本利用を想定。
    final google = Uri.https('www.google.com', '/search', {
      'q': query,
      'hl': 'ja',
      'gl': 'jp',
      'num': '10',
      'filter': '0',
    }).toString();
    final readerUri = Uri.parse('https://r.jina.ai/$google');
    final response = await http.get(
      readerUri,
      headers: const {
        'accept': 'text/plain',
        'user-agent': 'Catch/0.13 Android',
      },
    ).timeout(const Duration(seconds: 18));
    if (response.statusCode < 200 || response.statusCode >= 300 || response.body.trim().isEmpty) {
      return const [];
    }

    final body = response.body;
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    final links = RegExp(r'\[([^\]\n]{3,220})\]\((https?://[^)\s]+)\)', caseSensitive: false)
        .allMatches(body);
    for (final match in links) {
      final title = _decodeHtml((match.group(1) ?? '').replaceAll(RegExp(r'\s+'), ' ').trim());
      final url = _decodeHtml(match.group(2) ?? '').trim();
      final parsed = Uri.tryParse(url);
      if (title.isEmpty || parsed == null || !url.startsWith('http')) continue;
      final host = parsed.host.toLowerCase();
      if (host.isEmpty || host.contains('google.') || host == 'r.jina.ai') continue;
      final aroundStart = (match.start - 180).clamp(0, body.length);
      final aroundEnd = (match.end + 420).clamp(0, body.length);
      final snippet = body.substring(aroundStart, aroundEnd)
          .replaceAll(RegExp(r'[#>*_`]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (!_isRelevantResult(keyword, '$title $snippet $host')) continue;
      final key = '$host|${title.toLowerCase()}';
      if (!seen.add(key)) continue;
      out.add({
        'title': title,
        'url': url,
        'summary': snippet.length > 360 ? '${snippet.substring(0, 360)}…' : snippet,
        'source': host,
        'engine': 'Google Reader',
      });
      if (out.length >= 10) break;
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _bingRssSearch(String query, String keyword) async {
    final uri = Uri.https('www.bing.com', '/search', {
      'q': query,
      'format': 'rss',
      'setlang': 'ja-jp',
      'cc': 'jp',
    });
    final response = await http.get(
      uri,
      headers: const {
        'user-agent':
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36',
        'accept-language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.5',
      },
    ).timeout(const Duration(seconds: 18));
    if (response.statusCode != 200 || response.body.trim().isEmpty) {
      return const [];
    }
    try {
      final document = XmlDocument.parse(response.body);
      final out = <Map<String, dynamic>>[];
      for (final item in document.findAllElements('item').take(15)) {
        final title = _decodeHtml(item.getElement('title')?.innerText.trim() ?? '');
        final resultUrl = item.getElement('link')?.innerText.trim() ?? '';
        final description = _decodeHtml(
          item.getElement('description')?.innerText.trim() ?? '',
        );
        if (title.isEmpty || !resultUrl.startsWith('http')) continue;
        if (!_isRelevantResult(keyword, '$title $description')) continue;
        final host = Uri.tryParse(resultUrl)?.host.toLowerCase() ?? '';
        out.add({
          'title': title,
          'url': resultUrl,
          'summary': description.length > 360
              ? '${description.substring(0, 360)}…'
              : description,
          'source': host,
          'engine': 'Bing RSS',
        });
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> _googleWebSearch(String query, String keyword) async {
    final uri = Uri.https('www.google.com', '/search', {
      'q': query, 'hl': 'ja', 'gl': 'jp', 'num': '10', 'filter': '0', 'gbv': '1',
    });
    final response = await http.get(uri, headers: const {
      'user-agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36',
      'accept-language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.5',
    }).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return const [];
    final html = response.body;
    final out = <Map<String, dynamic>>[];
    final matches = RegExp(r'<a[^>]+href="([^"]+)"[^>]*>[\s\S]*?<h3[^>]*>([\s\S]*?)</h3>', caseSensitive: false).allMatches(html);
    for (final match in matches) {
      final resultUrl = _unwrapGoogleUrl(_decodeHtml(match.group(1) ?? ''));
      if (!resultUrl.startsWith('http') || resultUrl.contains('google.com/')) continue;
      final title = _visiblePageText(match.group(2) ?? '');
      final aroundStart = (match.start - 250).clamp(0, html.length);
      final aroundEnd = (match.end + 650).clamp(0, html.length);
      final snippet = _visiblePageText(html.substring(aroundStart, aroundEnd));
      if (!_isRelevantResult(keyword, '$title $snippet')) continue;
      final host = Uri.tryParse(resultUrl)?.host.toLowerCase() ?? '';
      out.add({'title': title, 'url': resultUrl, 'summary': snippet.length > 320 ? '${snippet.substring(0, 320)}…' : snippet, 'source': host, 'engine': 'Google'});
      if (out.length >= 10) break;
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _bingWebSearch(String query, String keyword) async {
    final uri = Uri.https('www.bing.com', '/search', {'q': query, 'setlang': 'ja-jp', 'cc': 'jp'});
    final response = await http.get(uri, headers: const {'user-agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36'}).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return const [];
    final out = <Map<String, dynamic>>[];
    final blocks = RegExp(r'<li[^>]+class="[^"]*b_algo[^"]*"[^>]*>([\s\S]*?)</li>', caseSensitive: false).allMatches(response.body);
    for (final b in blocks) {
      final raw = b.group(1) ?? '';
      final a = RegExp(r'<h2[^>]*>\s*<a[^>]+href="([^"]+)"[^>]*>([\s\S]*?)</a>', caseSensitive: false).firstMatch(raw);
      if (a == null) continue;
      final url = _decodeHtml(a.group(1) ?? '');
      if (!url.startsWith('http')) continue;
      final title = _visiblePageText(a.group(2) ?? '');
      final summary = _visiblePageText(raw);
      if (!_isRelevantResult(keyword, '$title $summary')) continue;
      out.add({'title': title, 'url': url, 'summary': summary.length > 320 ? '${summary.substring(0, 320)}…' : summary, 'source': Uri.tryParse(url)?.host.toLowerCase() ?? 'bing', 'engine': 'Bing'});
      if (out.length >= 10) break;
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _duckDuckGoSearch(String query, String keyword) async {
    final uri = Uri.https('html.duckduckgo.com', '/html/', {'q': query, 'kl': 'jp-jp'});
    final response = await http.get(uri, headers: const {'user-agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36'}).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return const [];
    final out = <Map<String, dynamic>>[];
    final links = RegExp(r'<a[^>]+class="[^"]*result__a[^"]*"[^>]+href="([^"]+)"[^>]*>([\s\S]*?)</a>', caseSensitive: false).allMatches(response.body);
    for (final m in links) {
      var url = _decodeHtml(m.group(1) ?? '');
      if (url.contains('uddg=')) {
        final parsed = Uri.tryParse(url.startsWith('//') ? 'https:$url' : url);
        url = parsed?.queryParameters['uddg'] ?? url;
      }
      if (!url.startsWith('http')) continue;
      final title = _visiblePageText(m.group(2) ?? '');
      final aroundEnd = (m.end + 600).clamp(0, response.body.length);
      final summary = _visiblePageText(response.body.substring(m.end, aroundEnd));
      if (!_isRelevantResult(keyword, '$title $summary')) continue;
      out.add({'title': title, 'url': url, 'summary': summary.length > 320 ? '${summary.substring(0, 320)}…' : summary, 'source': Uri.tryParse(url)?.host.toLowerCase() ?? 'duckduckgo', 'engine': 'DuckDuckGo'});
      if (out.length >= 10) break;
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _googleNewsSearch(String query, String keyword) async {
    final uri = Uri.https('news.google.com', '/rss/search', {'q': query, 'hl': 'ja', 'gl': 'JP', 'ceid': 'JP:ja'});
    final response = await http.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return const [];
    final document = XmlDocument.parse(response.body);
    final out = <Map<String, dynamic>>[];
    for (final item in document.findAllElements('item').take(12)) {
      final title = item.getElement('title')?.innerText.trim() ?? '';
      final resultUrl = item.getElement('link')?.innerText.trim() ?? '';
      final description = item.getElement('description')?.innerText ?? '';
      final source = item.getElement('source')?.innerText.trim() ?? '';
      final summary = _visiblePageText(description);
      if (title.isEmpty || resultUrl.isEmpty || !_isRelevantResult(keyword, '$title $summary $source')) continue;
      out.add({'title': title, 'url': resultUrl, 'summary': summary, 'source': source, 'engine': 'Google News'});
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _searchAll(String query, String keyword, {bool includeNews = true}) async {
    // v0.11: structured feeds first. Search-engine HTML changes frequently and can
    // return consent / anti-bot pages, so it is only used as a fallback.
    final primaryGroups = await Future.wait<List<Map<String, dynamic>>>([
      _readerGoogleSearch(query, keyword).catchError((_) => <Map<String, dynamic>>[]),
      _bingRssSearch(query, keyword).catchError((_) => <Map<String, dynamic>>[]),
      if (includeNews)
        _googleNewsSearch(query, keyword).catchError((_) => <Map<String, dynamic>>[]),
    ]);

    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    void mergeGroup(List<Map<String, dynamic>> group) {
      for (final item in group) {
        final url = item['url']?.toString() ?? '';
        final title = item['title']?.toString() ?? '';
        final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
        final key = '$host|${title.toLowerCase()}';
        if (url.isEmpty || title.isEmpty || !seen.add(key)) continue;
        out.add(item);
      }
    }

    for (final group in primaryGroups) {
      mergeGroup(group);
    }

    // Only spend time on brittle HTML endpoints when structured search did not
    // return enough relevant pages. One failing engine never fails the watch.
    if (out.length < 4) {
      final fallbackGroups = await Future.wait<List<Map<String, dynamic>>>([
        _bingWebSearch(query, keyword).catchError((_) => <Map<String, dynamic>>[]),
        _duckDuckGoSearch(query, keyword).catchError((_) => <Map<String, dynamic>>[]),
        _googleWebSearch(query, keyword).catchError((_) => <Map<String, dynamic>>[]),
      ]);
      for (final group in fallbackGroups) {
        mergeGroup(group);
      }
    }
    return out;
  }

  Future<CloudSyncResult> checkAiNow() async {
    final prefs = await SharedPreferences.getInstance();
    final found = await _aiResults();
    await _merge(prefs, _resultsKey, found, 'id');
    // 手動更新では「新着だけ」ではなく今回の検索結果をそのまま返す。
    // 同じ結果でも画面を更新できるため、永久に「新着なし」表示にならない。
    return CloudSyncResult(
      tasks: const [],
      watchResults: found,
      teamsConnected: false,
      needsAdminConsent: false,
    );
  }

  Future<CloudSyncResult> sync() async {
    final prefs = await SharedPreferences.getInstance();
    var consent = false;
    List<Map<String, dynamic>> teams = const [];
    try {
      teams = await _teamsTasks();
    } catch (error) {
      if (error.toString().contains('管理者')) {
        consent = true;
      } else {
        rethrow;
      }
    }
    final lastAi = DateTime.tryParse(prefs.getString(_lastAiKey) ?? '');
    final ai = (await isConfigured()) &&
            (lastAi == null || DateTime.now().difference(lastAi) >= const Duration(hours: 1))
        ? await _aiResults()
        : <Map<String, dynamic>>[];
    final newTasks = await _merge(prefs, _tasksKey, teams, 'externalId');
    final newResults = await _merge(prefs, _resultsKey, ai, 'id');
    await prefs.setString(_lastSyncKey, DateTime.now().toIso8601String());
    return CloudSyncResult(
      tasks: newTasks,
      watchResults: newResults,
      teamsConnected: await isTeamsConnected(),
      needsAdminConsent: consent,
    );
  }

  Future<void> _persistBackgroundSchedule({
    required String title,
    required DateTime date,
    required String externalId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> data = <String, dynamic>{};
    try {
      final raw = jsonDecode(prefs.getString(_appStorageKey) ?? '{}');
      if (raw is Map) data = Map<String, dynamic>.from(raw);
    } catch (_) {}
    final schedules = (data['schedules'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final index = schedules.indexWhere((e) => e['externalId']?.toString() == externalId);
    final reminder = data['defaultReminderMinutes'] as int? ?? 30;
    final record = <String, dynamic>{
      'title': title,
      'date': date.toIso8601String(),
      'externalId': externalId,
      'completed': false,
      'reminderMinutes': reminder,
      'notificationId': 0,
    };
    if (index >= 0) {
      schedules[index] = {...schedules[index], ...record};
    } else {
      schedules.add(record);
    }
    data['schedules'] = schedules;
    await prefs.setString(_appStorageKey, jsonEncode(data));
  }

  Future<List<Map<String, dynamic>>> _aiResults() async {
    final prefs = await SharedPreferences.getInstance();
    final decoded = jsonDecode(prefs.getString(_watchesKey) ?? '[]');
    final watches = decoded is List
        ? decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : <Map<String, dynamic>>[];
    final output = <Map<String, dynamic>>[];

    for (final watch in watches) {
      if (watch['enabled'] != true) continue;
      final keyword = watch['keyword']?.toString().trim() ?? '';
      if (keyword.isEmpty) continue;
      final mode = _watchMode(keyword);
      final base = _cleanWatchQuery(keyword);
      final terms = _watchTerms(keyword);
      final queryBase = terms.length >= 2
          ? terms.take(5).join(' ')
          : (base.isEmpty ? keyword : base);

      // 天気は検索記事ではなく予報データを直接使う。
      // ここが失敗しても通常検索へ落として「0件」で終わらせない。
      if (mode == 'weather') {
        try {
          final weather = await _weatherWatchResult(keyword);
          if (weather != null) {
            output.add(weather);
            continue;
          }
        } catch (_) {}
      }

      // 価格条件は軽量検索。本文を全件クロールせず、検索結果の価格表記を優先。
      if (mode == 'price') {
        final threshold = _priceThresholdYen(keyword);
        if (threshold != null) {
          final found = <Map<String, dynamic>>[];
          try {
            found.addAll(await _googleNewsSearch('$queryBase 価格', keyword));
          } catch (_) {}
          if (found.length < 3) {
            try {
              found.addAll(await _bingRssSearch('$queryBase 価格', keyword));
            } catch (_) {}
          }
          final seen = <String>{};
          final candidates = <Map<String, dynamic>>[];
          for (final item in found) {
            final title = item['title']?.toString() ?? '';
            final summary = item['summary']?.toString() ?? '';
            final url = item['url']?.toString() ?? '';
            if (title.isEmpty || url.isEmpty || !seen.add(url)) continue;
            final prices = _extractPrices('$title $summary');
            if (prices.isEmpty) continue;
            candidates.add({...item, 'price': prices.first});
          }
          candidates.sort((a,b)=>(a['price'] as int).compareTo(b['price'] as int));
          if (candidates.isNotEmpty) {
            final best = candidates.first;
            final price = best['price'] as int;
            final fingerprint = base64Url.encode(utf8.encode('$keyword|${best['url']}|$price'));
            output.add({
              'id':'price:$fingerprint',
              'keyword':keyword,
              'title': price <= threshold ? '価格条件を達成: ${best['title']}' : '現在の価格候補: ${best['title']}',
              'summary':'¥$price / 目標 ¥$threshold',
              'url':best['url'],
              'source':best['source'] ?? '',
              'foundAt':DateTime.now().toIso8601String(),
              'watchType':'price',
              'currentPrice':price,
              'targetPrice':threshold,
              'comparedSources':candidates.length,
            });
            continue;
          }
        }
      }

      // 安定版の基本検索: v0.6で実績のあったGoogle News RSSを最優先。
      // 足りない時だけBing RSSを足す。HTML検索やReaderは使わない。
      final raw = <Map<String, dynamic>>[];
      try {
        raw.addAll(await _googleNewsSearch(queryBase, keyword));
      } catch (_) {}
      if (raw.length < 3) {
        try {
          raw.addAll(await _bingRssSearch(queryBase, keyword));
        } catch (_) {}
      }

      final unique = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final item in raw) {
        final title = item['title']?.toString().trim() ?? '';
        final url = item['url']?.toString().trim() ?? '';
        if (title.isEmpty || url.isEmpty || !seen.add(url)) continue;
        unique.add(item);
      }

      // 関連判定で全部0件にならないよう、まず関連度の高いものを優先し、
      // 足りない分は検索上位から補う。
      final relevant = unique.where((item) {
        final text = '${item['title'] ?? ''} ${item['summary'] ?? ''} ${item['source'] ?? ''}';
        return _isRelevantResult(keyword, text);
      }).toList();
      final chosen = <Map<String, dynamic>>[];
      for (final item in relevant) {
        if (chosen.length >= 3) break;
        chosen.add(item);
      }
      for (final item in unique) {
        if (chosen.length >= 3) break;
        if (!chosen.contains(item)) chosen.add(item);
      }

      for (final item in chosen.take(3)) {
        final title = item['title']?.toString() ?? '';
        final url = item['url']?.toString() ?? '';
        final summary = item['summary']?.toString() ?? '';
        final source = item['source']?.toString() ?? '';
        final fingerprint = base64Url.encode(utf8.encode('$keyword|$url'));
        output.add({
          'id':'stable:$fingerprint',
          'keyword':keyword,
          'title':title,
          'summary':summary,
          'url':url,
          'source':source,
          'foundAt':DateTime.now().toIso8601String(),
          'watchType':mode == 'weather' ? 'news' : mode,
          'autoSaved':false,
          'dateStatus': mode == 'date' ? 'manual' : '',
        });
      }
    }
    await prefs.setString(_lastAiKey, DateTime.now().toIso8601String());
    return output;
  }

  static Map<String, dynamic> _object(String body) {
    if (body.trim().isEmpty) return <String, dynamic>{};
    final value = jsonDecode(body);
    return value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  }

  Future<List<Map<String, dynamic>>> _merge(
    SharedPreferences prefs,
    String key,
    List<Map<String, dynamic>> incoming,
    String identity,
  ) async {
    if (incoming.isEmpty) return <Map<String, dynamic>>[];
    final decoded = jsonDecode(prefs.getString(key) ?? '[]');
    final existing = decoded is List
        ? decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : <Map<String, dynamic>>[];
    final seenKey = '${key}_seen';
    final ids = <String>{
      ...?prefs.getStringList(seenKey),
      ...existing.map((e) => e[identity]?.toString() ?? ''),
    };
    final added = <Map<String, dynamic>>[];
    for (final item in incoming) {
      final id = item[identity]?.toString() ?? '';
      if (id.isNotEmpty && ids.add(id)) {
        existing.add(item);
        added.add(item);
      }
    }
    await prefs.setString(key, jsonEncode(existing));
    await prefs.setStringList(seenKey, ids.where((e) => e.isNotEmpty).toList().reversed.take(2000).toList());
    return added;
  }

  Future<List<Map<String, dynamic>>> takeTaskInbox() => _take(_tasksKey);
  Future<List<Map<String, dynamic>>> takeWatchInbox() => _take(_resultsKey);

  Future<List<Map<String, dynamic>>> _take(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final decoded = jsonDecode(prefs.getString(key) ?? '[]');
    final result = decoded is List
        ? decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : <Map<String, dynamic>>[];
    await prefs.remove(key);
    return result;
  }

  Future<DateTime?> lastSync() async => DateTime.tryParse(
      (await SharedPreferences.getInstance()).getString(_lastSyncKey) ?? '');

  Future<void> configureBackgroundSync() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (!await isConfigured() && !await isTeamsConnected()) return;
    await Workmanager().registerPeriodicTask(
      catchCloudUniqueName,
      catchCloudTaskName,
      frequency: const Duration(hours: 1),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }
}
