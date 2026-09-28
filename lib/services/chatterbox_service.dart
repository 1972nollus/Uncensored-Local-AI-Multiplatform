import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Offline iOS CoreML voice; downloads model weights once on explicit request.
class ChatterboxService {
  static const _channel = MethodChannel('portable_ai/chatterbox');

  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<Map<String, dynamic>> status() async {
    if (!supported) return {'downloaded': false, 'loaded': false};
    return Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('status') ?? {});
  }

  Future<void> download() async {
    if (!supported) throw UnsupportedError('Chatterbox vereist iOS 18+.');
    await _channel.invokeMethod<void>('download');
  }

  Future<void> load() async {
    if (!supported) throw UnsupportedError('Chatterbox vereist iOS 18+.');
    await _channel.invokeMethod<void>('load');
  }

  Future<void> speak(String text, {required String language,
      double exaggeration = 0.7}) async {
    await _channel.invokeMethod<void>('speak', {
      'text': text, 'language': language, 'exaggeration': exaggeration,
    });
  }

  Future<void> stop() async {
    if (supported) await _channel.invokeMethod<void>('stop');
  }

  Future<void> unload() async {
    if (supported) await _channel.invokeMethod<void>('unload');
  }
}
