import 'dart:convert';
import 'dart:js_interop';

class CatchWebPushResult {
  const CatchWebPushResult({
    required this.ok,
    this.message = '',
  });

  final bool ok;
  final String message;
}

@JS('catchPushSupported')
external JSBoolean _catchPushSupported();

@JS('catchPushStatus')
external JSString _catchPushStatus();

@JS('catchPushEnable')
external JSPromise<JSString> _catchPushEnable(JSString apiUrl);

@JS('catchPushSync')
external JSPromise<JSString> _catchPushSync(
  JSString apiUrl,
  JSString remindersJson,
);

@JS('catchPushTest')
external JSPromise<JSString> _catchPushTest(JSString apiUrl);

Future<bool> catchWebPushSupported() async {
  try {
    return _catchPushSupported().toDart;
  } catch (_) {
    return false;
  }
}

Future<String> catchWebPushStatus() async {
  try {
    return _catchPushStatus().toDart;
  } catch (_) {
    return 'unsupported';
  }
}

CatchWebPushResult _decodeResult(String raw) {
  try {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return CatchWebPushResult(
      ok: map['ok'] == true,
      message: map['message'] as String? ?? '',
    );
  } catch (_) {
    return const CatchWebPushResult(
      ok: false,
      message: '通知処理の応答を読み取れませんでした',
    );
  }
}

Future<CatchWebPushResult> catchWebPushEnable(String apiUrl) async {
  try {
    final raw = (await _catchPushEnable(apiUrl.toJS).toDart).toDart;
    return _decodeResult(raw);
  } catch (error) {
    return CatchWebPushResult(
      ok: false,
      message: '通知の有効化に失敗しました: $error',
    );
  }
}

Future<CatchWebPushResult> catchWebPushSync(
  String apiUrl,
  List<Map<String, dynamic>> reminders,
) async {
  try {
    final raw = (await _catchPushSync(
      apiUrl.toJS,
      jsonEncode(reminders).toJS,
    ).toDart).toDart;
    return _decodeResult(raw);
  } catch (error) {
    return CatchWebPushResult(
      ok: false,
      message: '通知予定の同期に失敗しました: $error',
    );
  }
}

Future<CatchWebPushResult> catchWebPushTest(String apiUrl) async {
  try {
    final raw = (await _catchPushTest(apiUrl.toJS).toDart).toDart;
    return _decodeResult(raw);
  } catch (error) {
    return CatchWebPushResult(
      ok: false,
      message: 'テスト通知に失敗しました: $error',
    );
  }
}
