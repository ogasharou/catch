import 'dart:js_interop';

@JS('catchRecognizeImage')
external JSPromise<JSString> _catchRecognizeImage(JSString dataUrl);

Future<String> recognizeWebImage(String dataUrl) async {
  final result = await _catchRecognizeImage(dataUrl.toJS).toDart;
  return result.toDart;
}
