class CatchWebPushResult {
  const CatchWebPushResult({
    required this.ok,
    this.message = '',
  });

  final bool ok;
  final String message;
}

Future<bool> catchWebPushSupported() async => false;

Future<String> catchWebPushStatus() async => 'unsupported';

Future<CatchWebPushResult> catchWebPushEnable(String apiUrl) async {
  return const CatchWebPushResult(
    ok: false,
    message: 'Web PushはWeb版でのみ利用できます',
  );
}

Future<CatchWebPushResult> catchWebPushSync(
  String apiUrl,
  List<Map<String, dynamic>> reminders,
) async {
  return const CatchWebPushResult(ok: false);
}

Future<CatchWebPushResult> catchWebPushTest(String apiUrl) async {
  return const CatchWebPushResult(ok: false);
}
