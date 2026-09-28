import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Optional ElevenLabs v3 expressive voice. API key never enters the repo.
class ExpressiveVoiceService {
  static const _storage = FlutterSecureStorage();
  final _player = AudioPlayer();
  static const _key = 'elevenlabs_api_key';
  static const _voice = 'elevenlabs_voice_id';
  Future<String> get apiKey async => await _storage.read(key: _key) ?? '';
  Future<String> get voiceId async => await _storage.read(key: _voice) ?? '';
  Future<void> save(String key, String voice) async {
    await _storage.write(key: _key, value: key.trim());
    await _storage.write(key: _voice, value: voice.trim());
  }
  Future<void> speak(String text, {bool expressive = false}) async {
    final key = await apiKey;
    final voice = await voiceId;
    if (key.isEmpty || voice.isEmpty) throw StateError('Vul je ElevenLabs API-sleutel en Voice ID in.');
    final requestText = expressive ? _expressiveText(text) : text;
    final response = await http.post(
      Uri.parse('https://api.elevenlabs.io/v1/text-to-speech/' + Uri.encodeComponent(voice)),
      headers: {'xi-api-key': key, 'Content-Type': 'application/json', 'Accept': 'audio/mpeg'},
      body: jsonEncode({'text': requestText, 'model_id': 'eleven_v3',
        'voice_settings': {'stability': 0.5}}),
    ).timeout(const Duration(seconds: 90));
    if (response.statusCode != 200) {
      throw StateError('ElevenLabs HTTP ${response.statusCode}: ${utf8.decode(response.bodyBytes).substring(0, response.bodyBytes.length.clamp(0, 200))}');
    }
    await _player.stop();
    await _player.play(BytesSource(response.bodyBytes));
    await _player.onPlayerComplete.first.timeout(const Duration(minutes: 5));
  }
  String _expressiveText(String text) {
    // Preserve the LLM's own emotion tags; do not force laughter into every reply.
    return text.replaceAll(RegExp(r'\\[laughing\\]', caseSensitive: false), '[laughs]')
      .replaceAll(RegExp(r'\\[shouting\\]', caseSensitive: false), '[shouts]');
  }
  Future<void> stop() => _player.stop();
  Future<void> dispose() => _player.dispose();
}
