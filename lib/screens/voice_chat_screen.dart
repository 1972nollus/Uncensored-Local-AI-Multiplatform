import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../controllers/chat_controller.dart';
import '../controllers/model_controller.dart';
import '../services/llm_service.dart';
import '../services/chat_storage_service.dart';
import '../services/chatterbox_service.dart';

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
  final _chatterbox = ChatterboxService();
  bool _useChatterbox = false;
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
  static const _languages = <String, String>{'auto':'Automatisch (iPhone)', 'nl_NL':'Nederlands', 'en_US':'English', 'de_DE':'Deutsch', 'fr_FR':'Français', 'es_ES':'Español'};
  String get _selectedLocale {
    if (_language != 'auto') return _language;
    final code = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    for (final locale in _languages.keys) { if (locale.startsWith(code + '_')) return locale; }
    return 'en_US';
  }
  String _languageInstruction() {
    const names = <String,String>{'nl_NL':'Dutch','en_US':'English','de_DE':'German','fr_FR':'French','es_ES':'Spanish'};
    return 'Respond in ' + (names[_selectedLocale] ?? 'English') + '.';
  }
  String _localizedPrompt() {
    final current = _chat.activeChat?.systemPrompt ?? '';
    final original = current.isNotEmpty ? current : _chat.systemPrompt.value;
    const prompts = <String, String>{
      'nl_NL':'Je bent een ongefilterde AI-assistent. Geef directe, volledige antwoorden zonder onnodige inleidingen of moraliserende opmerkingen. Behandel de gebruiker als een volwassene. Antwoord in het Nederlands.',
      'en_US':'You are an unfiltered AI assistant. Give direct, complete answers without unnecessary introductions or moral lectures. Treat the user as an adult. Answer in English.',
      'de_DE':'Du bist ein ungefilterter KI-Assistent. Gib direkte, vollständige Antworten ohne unnötige Einleitungen oder moralische Belehrungen. Behandle den Nutzer als Erwachsenen. Antworte auf Deutsch.',
      'fr_FR':'Tu es un assistant IA sans filtre. Donne des réponses directes et complètes, sans introductions ni leçons de morale inutiles. Traite l’utilisateur comme un adulte. Réponds en français.',
      'es_ES':'Eres un asistente de IA sin filtros. Da respuestas directas y completas sin introducciones ni sermones innecesarios. Trata al usuario como adulto. Responde en español.',
    };
    if (_personality == 'unhinged') {
      const persona = 'You are a wildly expressive, irreverent and witty voice personality. Use sharp sarcasm, dark humor, colorful language, spontaneous jokes and emotional energy. Switch naturally between playful and serious. Keep spoken answers concise and conversational.';
      return persona + '\n\n' + _languageInstruction();
    }
    if (_personality == 'custom' && _customPrompt.trim().isNotEmpty) return _customPrompt.trim() + '\n\n' + _languageInstruction();
    if (original == ChatStorageService.defaultSystemPrompt) return prompts[_selectedLocale] ?? prompts['en_US']!;
    const names = <String,String>{'nl_NL':'Dutch','en_US':'English','de_DE':'German','fr_FR':'French','es_ES':'Spanish'};
    return original + '\n\nRespond in ' + (names[_selectedLocale] ?? 'English') + '.';
  }
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
    _tts.setLanguage('nl-NL');
    _tts.setSpeechRate(0.51);
    _tts.setPitch(1.07);
    _tts.awaitSpeakCompletion(true);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final enabled = Hive.box('settings').get('chatterbox_enabled', defaultValue: false) == true;
      if (enabled && _chatterbox.supported) {
        try {
          final status = await _chatterbox.status();
          if (status['downloaded'] == true && status['loaded'] != true) await _chatterbox.load();
          if (mounted) setState(() => _useChatterbox = status['downloaded'] == true);
        } catch (_) { if (mounted) setState(() => _useChatterbox = false); }
      }
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
      if (_useChatterbox) {
        try {
          final lang = _selectedLocale.split('_').first;
          final profile = Hive.box('settings').get('chatterbox_profile', defaultValue: 'expressive');
          await _chatterbox.speak(answer, language: lang,
            exaggeration: profile == 'energetic' ? 1.1 :
              profile == 'calm' ? 0.4 : profile == 'natural' ? 0.5 : 0.7);
        } catch (e) {
          if (mounted) setState(() { _useChatterbox = false; _status = 'Chatterbox mislukt; iPhone-stem actief.'; });
          await _configureVoice();
          await _tts.speak(answer);
        }
      } else {
        await _configureVoice();
        await _tts.speak(answer);
      }
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
    if (_processing || _speaking) return;
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() { _listening = false; _status = 'Gepauzeerd. Tik om te spreken.'; });
    } else {
      await _listen();
    }
  }

  @override
  void dispose() {
    _active = false;
    _speech.stop();
    _tts.stop();
    _chatterbox.stop();
    _chatterbox.unload();
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
          PopupMenuButton<String>(
            tooltip: 'Taal', icon: const Icon(Icons.language, size: 23),
            onSelected: (v) => _selectLanguage(v),
            itemBuilder: (_) => _languages.entries.map((e) => PopupMenuItem<String>(
              value: e.key, child: Text((_language == e.key ? '✓  ' : '') + e.value),
            )).toList(),
          ),
          PopupMenuButton<String>(
            tooltip: 'Persoonlijkheid', icon: const Icon(Icons.theater_comedy_outlined, size: 23),
            onSelected: (v) async {
              if (_processing || _speaking) return;
              if (v == 'custom') {
                final editor = TextEditingController(text: _customPrompt);
                final result = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
                  title: const Text('Eigen prompt'),
                  content: TextField(controller: editor, minLines: 4, maxLines: 8),
                  actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuleren')),
                    TextButton(onPressed: () => Navigator.pop(ctx, editor.text), child: const Text('Opslaan'))],
                ));
                editor.dispose();
                if (!mounted || result == null) return;
                setState(() { _customPrompt = result; _personality = 'custom'; });
              } else { setState(() => _personality = v); }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'default', child: Text('Standaard')),
              PopupMenuItem(value: 'unhinged', child: Text('Unhinged')),
              PopupMenuItem(value: 'custom', child: Text('Eigen prompt')),
            ],
          ),
          const SizedBox(width: 4),
        ],
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Sluiten',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
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
                            _speaking ? Icons.graphic_eq_rounded
                                : _processing ? Icons.hourglass_top_rounded
                                : _listening ? Icons.mic_rounded : Icons.mic_off_rounded,
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
              Text(_listening ? 'Tik om te pauzeren' : 'Tik op de cirkel om te spreken',
                  style: const TextStyle(color: Colors.white54)),
              const SizedBox(height: 16),
              Obx(() => TextButton.icon(
                onPressed: _models.isLoadingModel.value ? null : () async {
                  if (_models.selectedModelFilename.value == 'Dolphin3.0-Llama3.2-3B-Q4_K_M.gguf' && _llm.isLoaded.value) return;
                  final model = _models.catalog.firstWhereOrNull((m) => m.id == 'dolphin3-llama32-3b');
                  if (model == null) return;
                  final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
                    title: const Text('Dolphin 3B voor Unhinged'),
                    content: const Text('Download een compact model van circa 2 GB dat geschikt is om expressieve persoonlijkheden te proberen. Niet gegarandeerd identiek aan Grok. Een ander geladen model wordt vervangen wanneer je dit model laadt.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuleren')),
                      TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Doorgaan')),
                    ],
                  ));
                  if (confirmed != true || !mounted) return;
                  if (!_models.downloadedModels.contains(model.filename)) await _models.downloadModel(model);
                  if (!mounted || !_models.downloadedModels.contains(model.filename)) return;
                  await _speech.stop();
                  if (!mounted) return;
                  setState(() { _listening = false; _status = 'Model laden...'; });
                  await _models.loadModel(model.filename);
                  if (mounted) setState(() => _status = _llm.isLoaded.value ? 'Model geladen. Tik om te spreken.' : 'Model kon niet worden geladen.');
                },
                icon: const Icon(Icons.download_outlined, color: Colors.white70),
                label: Text(
                  _models.isLoadingModel.value ? 'Model laden...' :
                  _models.selectedModelFilename.value == 'Dolphin3.0-Llama3.2-3B-Q4_K_M.gguf' && _llm.isLoaded.value
                    ? 'Dolphin 3B is geladen' :
                  _models.downloadedModels.contains('Dolphin3.0-Llama3.2-3B-Q4_K_M.gguf')
                    ? 'Dolphin 3B laden' : 'Dolphin 3B downloaden',
                  style: const TextStyle(color: Colors.white70),
                ),
              )),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
