import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import '../controllers/chat_controller.dart';
import '../controllers/model_controller.dart';
import '../services/llm_service.dart';

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

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1250),
    )..repeat(reverse: true);
    _tts.setLanguage('nl-NL');
    _tts.setSpeechRate(0.48);
    _tts.awaitSpeakCompletion(true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _listen());
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
      setState(() { _listening = true; _status = 'Ik luister...'; _level = 0; });
      await _speech.listen(
        localeId: 'nl_NL',
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
      );
      if (!_active || !mounted) return;
      final answer = _chat.activeChat?.messages.last.content.trim() ?? '';
      if (answer.isEmpty || answer.startsWith('⚠')) {
        setState(() { _reply = answer; _status = 'Geen antwoord. Tik om opnieuw te spreken.'; });
        return;
      }
      setState(() { _reply = answer; _speaking = true; _status = 'AI spreekt...'; });
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
        title: const Text('Live spraak'),
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
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
