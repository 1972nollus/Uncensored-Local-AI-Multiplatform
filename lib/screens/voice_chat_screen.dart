import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audio_session/audio_session.dart' as audio_session;
import 'package:audioplayers/audioplayers.dart';
import 'package:get/get.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:supertonic_flutter/supertonic_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../controllers/chat_controller.dart';
import '../controllers/model_controller.dart';
import '../services/llm_service.dart';
import '../services/conversation_prompt_service.dart';
import '../services/supertonic_service.dart';

/// Hands-free turn-based voice chat. Recognition, local inference and TTS run
/// sequentially to avoid feeding the app's own spoken answer to the microphone.
class VoiceChatScreen extends StatefulWidget {
  const VoiceChatScreen({super.key});
  @override
  State<VoiceChatScreen> createState() => _VoiceChatScreenState();
}

class _VoiceChatScreenState extends State<VoiceChatScreen>
    with SingleTickerProviderStateMixin {
  final _speech = stt.SpeechToText();
  final _tts = FlutterTts();
  final _supertonic = SupertonicTTS();
  final _supertonicPlayer = TTSAudioPlayer();
  final _supertonicState = SupertonicService.instance;
  final _chat = Get.find<ChatController>();
  final _models = Get.find<ModelController>();
  final _llm = Get.find<LlmService>();
  late final AnimationController _pulse;
  bool _active = true;
  bool _listening = false;
  bool _processing = false;
  bool _speaking = false;
  bool _submitted = false;
  bool _turnCancelled = false;
  String _recognized = '';
  String _reply = '';
  String _status = 'Spraakmodus starten...';
  double _level = 0;
  String _language = 'nl_NL';
  String _personality = 'default';
  String _customPrompt = '';
  String _voiceStyle = 'expressive';
  String? _voiceId;
  String _ttsEngine = 'apple';
  String _supertonicVoice = 'F1';
  bool _supertonicReady = false;
  bool _supertonicLoading = false;
  List<Map<String,String>> _voices = [];
  Future<void> _configureVoice() async {
    final locale = _selectedLocale.replaceAll('_', '-');
    await _tts.setLanguage(locale);
    switch (_voiceStyle) {
      case 'energetic': await _tts.setSpeechRate(0.57); await _tts.setPitch(1.14); break;
      case 'calm': await _tts.setSpeechRate(0.43); await _tts.setPitch(0.96); break;
      case 'expressive': await _tts.setSpeechRate(0.51); await _tts.setPitch(1.07); break;
      default: await _tts.setSpeechRate(0.48); await _tts.setPitch(1.0);
    }
    if (_voiceId != null) await _tts.setVoice({'identifier': _voiceId!});
  }
  String get _supertonicLanguage => _selectedLocale.split('_').first.toLowerCase();

  Future<bool> _ensureSupertonic() async {
    if (_supertonicReady) return true;
    if (_supertonicLoading) return false;
    if (!await SupertonicTTS.modelsReady()) {
      if (mounted) setState(() => _status = 'Download Supertonic 3 eerst via Settings.');
      return false;
    }
    _supertonicLoading = true;
    if (mounted) setState(() => _status = 'Supertonic 3 starten...');
    try {
      await _supertonic.initialize();
      _supertonicReady = true;
      return true;
    } catch (e) {
      if (mounted) setState(() => _status = 'Supertonic kon niet starten: $e');
      return false;
    } finally { _supertonicLoading = false; }
  }

  Future<void> _saveVoicePrefs() async {
    final box = Hive.box('settings');
    await box.put('voice_tts_engine', _ttsEngine);
    await box.put('voice_supertonic_voice', _supertonicVoice);
    await box.put('voice_apple_style', _voiceStyle);
    if (_voiceId == null) { await box.delete('voice_apple_id'); }
    else { await box.put('voice_apple_id', _voiceId); }
  }

  Future<void> _preparePlaybackSession() async {
    await _speech.stop();
    if (Platform.isIOS) {
      final session = await audio_session.AudioSession.instance;
      await session.configure(const audio_session.AudioSessionConfiguration(
        avAudioSessionCategory: audio_session.AVAudioSessionCategory.playback,
        avAudioSessionMode: audio_session.AVAudioSessionMode.spokenAudio,
        avAudioSessionRouteSharingPolicy: audio_session.AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: audio_session.AVAudioSessionSetActiveOptions.none,
      ));
      await session.setActive(true);
    }
    await Future.delayed(const Duration(milliseconds: 120));
  }

  Future<void> _speakText(String text) async {
    await _preparePlaybackSession();
    if (_ttsEngine == 'supertonic') {
      if (await _ensureSupertonic()) {
        final result = await _supertonic.synthesize(text, language: _supertonicLanguage, voiceStyle: _supertonicVoice, config: const TTSConfig(speechSpeed: 1.05, denoisingSteps: 5));
        final completed = _supertonicPlayer.playerStateStream.firstWhere((state) => state == PlayerState.completed);
        await _supertonicPlayer.play(result);
        await completed.timeout(const Duration(minutes: 2));
        return;
      }
    }
    await _configureVoice();
    await _tts.speak(text);
  }

  Future<void> _stopSpeaking() async {
    await _tts.stop();
    await _supertonicPlayer.stop();
  }

  Future<void> _previewVoice() async {
    if (!mounted) return;
    setState(() => _status = _ttsEngine == 'supertonic'
        ? 'Supertonic stem voorbereiden...'
        : 'Apple-stem voorbereiden...');
    try {
      await _speakText(_selectedLocale == 'nl_NL'
          ? 'Hallo! Dit is mijn nieuwe stem. Wat zullen we bespreken?'
          : 'Hello! This is my new voice. What shall we discuss?');
      if (mounted) setState(() => _status = 'Stemtest voltooid.');
    } catch (e) {
      if (mounted) setState(() => _status = 'Stemfout: $e');
    }
  }

  Future<void> _voiceSettings() async {
    await _speech.stop();
    if (mounted) setState(() => _listening = false);
    try {
      final raw = await _tts.getVoices;
      final locale = _selectedLocale.replaceAll('_', '-').toLowerCase();
      if (raw is List) {
        _voices = raw.whereType<Map>().where((v) =>
          (v['locale'] ?? '').toString().replaceAll('_', '-').toLowerCase() == locale
          && (v['identifier'] ?? '').toString().isNotEmpty).map((v) =>
          {'id': v['identifier'].toString(), 'name': (v['name'] ?? v['identifier']).toString()}).toList();
      }
    } catch (_) {}
    if (!mounted) return;
    await showModalBottomSheet<void>(context: context, isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, refresh) => SafeArea(
        child: Padding(padding: const EdgeInsets.all(20), child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Steminstellingen', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          DropdownButton<String>(value: _ttsEngine, isExpanded: true, items: const [
            DropdownMenuItem(value: 'apple', child: Text('Apple iPhone-stemmen')),
            DropdownMenuItem(value: 'supertonic', child: Text('Supertonic 3 · Neural offline')),
          ], onChanged: (v) async {
            if (v == null) return;
            if (v == 'supertonic' && !await _supertonicState.refresh()) {
              if (mounted) setState(() => _status = 'Download Supertonic 3 eerst via Settings.');
              return;
            }
            refresh(() => _ttsEngine = v);
            await _saveVoicePrefs();
          }),
          if (_ttsEngine == 'supertonic') DropdownButton<String>(value: _supertonicVoice, isExpanded: true,
            items: const ['M1','M2','M3','M4','M5','F1','F2','F3','F4','F5'].map((v) => DropdownMenuItem(value: v, child: Text('Supertonic $v'))).toList(),
            onChanged: (v) async { if (v != null) { refresh(() => _supertonicVoice = v); await _saveVoicePrefs(); } }),
          const SizedBox(height: 12),
          if (_ttsEngine == 'apple') DropdownButton<String>(value: _voiceStyle, isExpanded: true, items: const [
            DropdownMenuItem(value: 'natural', child: Text('Natuurlijk')),
            DropdownMenuItem(value: 'expressive', child: Text('Expressief')),
            DropdownMenuItem(value: 'energetic', child: Text('Energiek')),
            DropdownMenuItem(value: 'calm', child: Text('Rustig')),
          ], onChanged: (v) async { if (v == null) return; refresh(() => _voiceStyle = v); await _configureVoice(); await _saveVoicePrefs(); }),
          if (_ttsEngine == 'apple') DropdownButton<String>(value: _voiceId, isExpanded: true, hint: const Text('Automatische iPhone-stem'),
            items: [const DropdownMenuItem<String>(value: null, child: Text('Automatische iPhone-stem')),
              ..._voices.map((v) => DropdownMenuItem<String>(value: v['id'], child: Text(v['name']!)))],
            onChanged: (v) async { refresh(() => _voiceId = v);
              if (v == null) await _tts.clearVoice(); await _configureVoice(); await _saveVoicePrefs(); }),
          Text(_ttsEngine == 'supertonic' ? 'Supertonic 3 draait lokaal. Modellen beheer je via Settings.' : 'Apple TTS draait volledig lokaal.', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: _previewVoice,
            icon: const Icon(Icons.play_arrow), label: const Text('Stem beluisteren')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Sluiten')),
        ])))),
    );
  }
  String get _selectedLocale => _language;
  String _localizedPrompt() => ConversationPromptService.currentPrompt(
    language: _selectedLocale,
    character: _personality,
  );
  Future<void> _selectLanguage(String value) async {
    if (_processing || _speaking || value == _language) return;
    await _speech.stop();
    if (!mounted) return;
    setState(() { _language = value; _listening = false; _status = 'Taal gewijzigd. Tik om te spreken.'; });
    final locale = _selectedLocale.replaceAll('_', '-');
    if (await _tts.isLanguageAvailable(locale) == true) {
      _voiceId = null;
      await _tts.clearVoice();
      await _configureVoice();
    }
  }

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1250),
    )..repeat(reverse: true);
    final settings = Hive.box('settings');
    _language = settings.get('conversation_language', defaultValue: 'nl_NL') as String;
    _personality = settings.get('conversation_character', defaultValue: 'default') as String;
    _customPrompt = settings.get('conversation_custom_prompt', defaultValue: '') as String;
    _ttsEngine = settings.get('voice_tts_engine', defaultValue: 'apple') as String;
    _supertonicVoice = settings.get('voice_supertonic_voice', defaultValue: 'F1') as String;
    _voiceStyle = settings.get('voice_apple_style', defaultValue: 'expressive') as String;
    _voiceId = settings.get('voice_apple_id') as String?;
    _tts.setLanguage(_selectedLocale.replaceAll('_', '-'));
    _tts.setSpeechRate(0.51);
    _tts.setPitch(1.07);
    _tts.awaitSpeakCompletion(true);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) await _listen();
    });
  }

  Future<void> _listen() async {
    if (!_active || _processing || _speaking || _listening || !mounted) return;
    if (!_llm.isLoaded.value) {
      setState(() => _status = 'Laad eerst een AI-model in Chat.');
      return;
    }
    _submitted = false;
    _turnCancelled = false;
    _recognized = '';
    try {
      final ready = await _speech.initialize(
        onError: (error) {
          if (!mounted || !_active) return;
          if (error.errorMsg == 'error_no_match') {
            setState(() { _listening = false; _status = 'Niet verstaan. Tik op de cirkel om opnieuw te spreken.'; });
          } else {
            setState(() { _listening = false; _status = 'Spraakfout: ${error.errorMsg}'; });
          }
        },
        onStatus: (status) {
          if (!mounted || !_active) return;
          if (status == 'done' || status == 'notListening') {
            setState(() => _listening = false);
          }
        },
      );
      if (!ready || !_active || !mounted) {
        if (mounted) setState(() => _status = 'Geen toegang tot spraakherkenning.');
        return;
      }
      final locales = await _speech.locales();
      final selected = _selectedLocale;
      if (!locales.any((l) => l.localeId.replaceAll('-', '_').toLowerCase() == selected.toLowerCase())) {
        setState(() => _status = 'Deze taal is niet beschikbaar op je iPhone.');
        return;
      }
      setState(() { _listening = true; _status = 'Ik luister...'; _level = 0; });
      await _speech.listen(
        localeId: selected,
        listenFor: const Duration(seconds: 45),
        pauseFor: const Duration(seconds: 2),
        onSoundLevelChange: (level) {
          if (mounted && _listening) {
            setState(() => _level = ((level + 2) / 18).clamp(0.0, 1.0));
          }
        },
        onResult: (result) {
          if (!mounted || !_active || _submitted) return;
          setState(() => _recognized = result.recognizedWords);
          if (result.finalResult && _recognized.trim().isNotEmpty) {
            _submitted = true;
            final spoken = _recognized.trim();
            Future.microtask(() => _answer(spoken));
          }
        },
      );
    } catch (e) {
      if (mounted) setState(() { _listening = false; _status = 'Microfoon: $e'; });
    }
  }

  Future<void> _answer(String spoken) async {
    if (!_active || _processing || !mounted) return;
    if (_llm.isGenerating.value || _chat.isGenerating.value) {
      setState(() => _status = 'Vorige generatie wordt nog afgerond. Tik zo opnieuw.');
      return;
    }
    _processing = true;
    await _speech.stop();
    if (!mounted || !_active) return;
    setState(() { _listening = false; _status = 'AI denkt na...'; _level = 0; });
    try {
      if (_chat.activeChat == null) _chat.newChat();
      await _chat.sendMessage(
        spoken,
        modelFilename: _models.selectedModelFilename.value,
        systemPromptOverride: _localizedPrompt(),
      );
      if (!_active || !mounted || _turnCancelled) return;
      final answer = _chat.activeChat?.messages.last.content.trim() ?? '';
      if (answer.isEmpty || answer.startsWith('⚠')) {
        setState(() { _reply = answer; _status = 'Geen antwoord. Tik om opnieuw te spreken.'; });
        return;
      }
      setState(() { _reply = answer; _speaking = true; _status = 'AI spreekt...'; });
      await _speakText(answer);
    } catch (e) {
      if (mounted) setState(() => _status = 'Fout: $e');
      return;
    } finally {
      _processing = false;
      _speaking = false;
    }
    if (_active && mounted && !_turnCancelled) {
      setState(() => _status = 'Volgende vraag...');
      await Future.delayed(const Duration(milliseconds: 350));
      if (_active && mounted) await _listen();
    }
  }

  Future<void> _toggle() async {
    if (_listening) {
      // Cancel this recognition turn completely. A late finalResult must not be sent.
      _submitted = true;
      _turnCancelled = true;
      await _speech.cancel();
      if (mounted) setState(() {
        _listening = false;
        _recognized = '';
        _level = 0;
        _status = 'Geannuleerd. Tik om opnieuw te spreken.';
      });
      return;
    }
    if (_speaking) {
      _turnCancelled = true;
      await _stopSpeaking();
      if (mounted) setState(() {
        _speaking = false;
        _status = 'Voorlezen gestopt. Tik om te spreken.';
      });
      return;
    }
    if (_processing) {
      _turnCancelled = true;
      await _chat.stopGeneration();
      if (mounted) setState(() {
        _processing = false;
        _status = 'Antwoord gestopt. Tik om te spreken.';
      });
      return;
    }
    await _listen();
  }

  @override
  void dispose() {
    _active = false;
    _speech.stop();
    _tts.stop();
    _supertonicPlayer.stop();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: const Color(0xFF10131B),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text('Live spraak', style: TextStyle(fontSize: 18)),
        titleSpacing: 0,
        actions: [
          IconButton(icon: const Icon(Icons.record_voice_over_outlined, size: 23),
            tooltip: 'Steminstellingen', onPressed: _voiceSettings),
          const SizedBox(width: 4),
        ],
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Sluiten',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SizedBox.expand(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Center(
              child: SizedBox(
                width: double.infinity,
                child: Column(
            children: [
              const Spacer(),
              AnimatedBuilder(
                animation: _pulse,
                builder: (_, __) {
                  final phase = _pulse.value;
                  final activity = _listening
                      ? (0.10 + _level * 0.30 + phase * 0.05)
                      : _processing
                          ? (0.08 + phase * 0.10)
                          : _speaking
                              ? (0.10 + phase * 0.16)
                              : (0.02 + phase * 0.025);
                  final coreSize = 166.0 + activity * 125;
                  final haloSize = coreSize + 24 + activity * 55;
                  final listeningScale = _listening ? 1.0 + _level * 0.07 : 1.0;
                  return GestureDetector(
                    onTap: _toggle,
                    child: SizedBox(
                      width: 260,
                      height: 260,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 90),
                            width: haloSize,
                            height: haloSize,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  color.withValues(alpha: 0.24 + activity * 0.30),
                                  color.withValues(alpha: 0.07),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.58, 1.0],
                              ),
                            ),
                          ),
                          Transform.scale(
                            scale: listeningScale,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 85),
                              curve: Curves.easeOut,
                              width: coreSize,
                              height: coreSize * (_listening ? 0.96 + _level * 0.07 : 1.0),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(coreSize * 0.48),
                                gradient: RadialGradient(
                                  center: Alignment(-0.18 + phase * 0.18, -0.22 + phase * 0.12),
                                  colors: const [
                                    Color(0xFFC2B7FF),
                                    Color(0xFF7767F2),
                                    Color(0xFF4942C7),
                                    Color(0xFF29296F),
                                  ],
                                  stops: const [0.0, 0.38, 0.73, 1.0],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: color.withValues(alpha: 0.25 + activity * 0.55),
                                    blurRadius: 30 + activity * 85,
                                    spreadRadius: 2 + activity * 22,
                                  ),
                                ],
                              ),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                child: Icon(
                                  (_speaking || _processing || _listening)
                                      ? Icons.stop_rounded
                                      : Icons.mic_rounded,
                                  key: ValueKey(_speaking || _processing || _listening),
                                  size: 46,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 32),
              Text(_status, textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 21)),
              const SizedBox(height: 22),
              Text(_recognized, textAlign: TextAlign.center,
                  maxLines: 3, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFFBDBED1), fontSize: 16)),
              const SizedBox(height: 16),
              if (_reply.isNotEmpty)
                Flexible(child: SingleChildScrollView(
                  child: Text(_reply, textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 15)),
                )),
              const Spacer(),
              Text((_listening || _speaking || _processing) ? 'Tik op de cirkel om te stoppen' : 'Tik op de cirkel om te spreken',
                  style: const TextStyle(color: Colors.white54)),
              const SizedBox(height: 16),
              const SizedBox(height: 12),
            ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
