import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../controllers/chat_controller.dart';
import '../controllers/model_controller.dart';
import '../services/llm_service.dart';
import '../services/conversation_prompt_service.dart';

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
  final _chat = Get.find<ChatController>();
  final _models = Get.find<ModelController>();
  final _llm = Get.find<LlmService>();
  late final AnimationController _pulse;
  bool _active = true;
  bool _listening = false;
  bool _processing = false;
  bool _speaking = false;
  bool _submitted = false;
  String _recognized = '';
  String _reply = '';
  String _status = 'Spraakmodus starten...';
  double _level = 0;
  String _language = 'nl_NL';
  String _personality = 'default';
  String _customPrompt = '';
  String _voiceStyle = 'expressive';
  String? _voiceId;
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
          DropdownButton<String>(value: _voiceStyle, isExpanded: true, items: const [
            DropdownMenuItem(value: 'natural', child: Text('Natuurlijk')),
            DropdownMenuItem(value: 'expressive', child: Text('Expressief')),
            DropdownMenuItem(value: 'energetic', child: Text('Energiek')),
            DropdownMenuItem(value: 'calm', child: Text('Rustig')),
          ], onChanged: (v) async { if (v == null) return; refresh(() => _voiceStyle = v); await _configureVoice(); }),
          DropdownButton<String>(value: _voiceId, isExpanded: true, hint: const Text('Automatische iPhone-stem'),
            items: [const DropdownMenuItem<String>(value: null, child: Text('Automatische iPhone-stem')),
              ..._voices.map((v) => DropdownMenuItem<String>(value: v['id'], child: Text(v['name']!)))],
            onChanged: (v) async { refresh(() => _voiceId = v);
              if (v == null) await _tts.clearVoice(); await _configureVoice(); }),
          const Text('Offline: tempo en toonhoogte. Echte emotionele spraak vereist een aparte stemengine.',
            style: TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: () async {
            await _configureVoice();
            await _tts.speak(_selectedLocale == 'nl_NL'
              ? 'Hallo! Dit is mijn nieuwe stem. Wat zullen we bespreken?'
              : 'Hello! This is my new voice. What shall we discuss?');
          }, icon: const Icon(Icons.play_arrow), label: const Text('Stem beluisteren')),
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
      if (!_active || !mounted) return;
      final answer = _chat.activeChat?.messages.last.content.trim() ?? '';
      if (answer.isEmpty || answer.startsWith('⚠')) {
        setState(() { _reply = answer; _status = 'Geen antwoord. Tik om opnieuw te spreken.'; });
        return;
      }
      setState(() { _reply = answer; _speaking = true; _status = 'AI spreekt...'; });
      await _configureVoice();
      await _tts.speak(answer);
    } catch (e) {
      if (mounted) setState(() => _status = 'Fout: $e');
      return;
    } finally {
      _processing = false;
      _speaking = false;
    }
    if (_active && mounted) {
      setState(() => _status = 'Volgende vraag...');
      await Future.delayed(const Duration(milliseconds: 350));
      if (_active && mounted) await _listen();
    }
  }

  Future<void> _toggle() async {
    if (_listening) {
      // Cancel this recognition turn completely. A late finalResult must not be sent.
      _submitted = true;
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
      await _tts.stop();
      if (mounted) setState(() {
        _speaking = false;
        _status = 'Voorlezen gestopt. Tik om te spreken.';
      });
      return;
    }
    if (_processing) {
      _chat.stopGeneration();
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
                  final wave = _listening
                      ? (0.06 + _level * 0.32 + _pulse.value * 0.06)
                      : _speaking ? 0.16 * _pulse.value : 0.035 * _pulse.value;
                  return GestureDetector(
                    onTap: _toggle,
                    child: SizedBox(
                      width: 240,
                      height: 240,
                      child: Center(
                        child: Container(
                          width: 160 + wave * 160,
                          height: 160 + wave * 160,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const RadialGradient(
                              colors: [Color(0xFFAD9CFF), Color(0xFF6254E9), Color(0xFF34338B)],
                              stops: [0.05, 0.65, 1],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: color.withValues(alpha: 0.32 + wave),
                                blurRadius: 28 + wave * 80,
                                spreadRadius: wave * 24,
                              ),
                            ],
                          ),
                          child: Icon(
                            (_speaking || _processing || _listening) ? Icons.stop_rounded : Icons.mic_rounded,
                            size: 48,
                            color: Colors.white,
                          ),
                        ),
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
