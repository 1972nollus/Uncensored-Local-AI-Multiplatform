import 'dart:io';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supertonic_flutter/supertonic_flutter.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:audio_session/audio_session.dart' as audio_session;
import 'package:path_provider/path_provider.dart';
import 'package:get/get.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';

import '../theme/app_colors.dart';
import '../controllers/chat_controller.dart';
import '../controllers/model_controller.dart';
import '../controllers/theme_controller.dart';
import '../services/llm_service.dart';
import '../services/supertonic_service.dart';
import '../widgets/chat_sidebar.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/typing_indicator.dart';
import 'model_library_screen.dart';
import 'settings_screen.dart';
import 'voice_chat_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _chatCtrl = Get.find<ChatController>();
  final _modelCtrl = Get.find<ModelController>();
  final _llm = Get.find<LlmService>();
  final _themeCtrl = Get.find<ThemeController>();
  final _msgController = TextEditingController();
  final _scrollController = ScrollController();
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final SupertonicTTS _supertonic = SupertonicTTS();
  final AudioPlayer _supertonicPlayer = AudioPlayer();
  final SupertonicService _supertonicState = SupertonicService.instance;
  bool _supertonicReady = false;
  bool _isListening = false;
  bool _speakResponses = true;
  bool _sidebarOpen = true;
  bool _autoScrollToBottom = true;
  String? _lastRenderedChatId;

  // Mobile bottom nav index: 0=Chat, 1=Models, 2=Settings
  int _mobileTabIndex = 0;

  // Scaffold key for drawer
  final GlobalKey<ScaffoldState> _mobileScaffoldKey =
      GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleChatScroll);
    _tts.setVolume(1.0);
    _tts.awaitSpeakCompletion(true);
    _configureAppleVoice();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleChatScroll);
    _scrollController.dispose();
    _speech.stop();
    _tts.stop();
    _supertonicPlayer.dispose();
    _msgController.dispose();
    super.dispose();
  }

  void _handleChatScroll() {
    if (!_scrollController.hasClients) return;
    _autoScrollToBottom = _isNearBottom();
  }

  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels <= 120;
  }

  void _scrollToBottom({bool force = false}) {
    if (!force && !_autoScrollToBottom) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        if (!force && !_autoScrollToBottom) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;

    FocusManager.instance.primaryFocus?.unfocus();
    await _speech.stop();
    if (mounted) setState(() => _isListening = false);

    if (_chatCtrl.activeChat == null) {
      _chatCtrl.newChat();
    }

    _msgController.clear();
    _autoScrollToBottom = true;
    await _chatCtrl.sendMessage(
      text,
      modelFilename: _modelCtrl.selectedModelFilename.value,
    );
    _scrollToBottom(force: true);

    if (_speakResponses) {
      final chat = _chatCtrl.activeChat;
      if (chat != null && chat.messages.isNotEmpty) {
        final answer = chat.messages.last.content.trim();
        if (answer.isNotEmpty && !answer.startsWith('⚠')) {
          await _stopVoice();
          await _speakWithSavedVoice(answer);
        }
      }
    }
  }

  String get _conversationLocale =>
      (Hive.box('settings').get('conversation_language', defaultValue: 'nl_NL') as String);
  String get _ttsEngine =>
      (Hive.box('settings').get('voice_tts_engine', defaultValue: 'apple') as String);
  String get _supertonicVoice =>
      (Hive.box('settings').get('voice_supertonic_voice', defaultValue: 'F1') as String);
  String get _appleStyle =>
      (Hive.box('settings').get('voice_apple_style', defaultValue: 'expressive') as String);
  String? get _appleVoiceId => Hive.box('settings').get('voice_apple_id') as String?;

  Future<void> _configureAppleVoice() async {
    await _tts.setLanguage(_conversationLocale.replaceAll('_', '-'));
    switch (_appleStyle) {
      case 'energetic': await _tts.setSpeechRate(0.57); await _tts.setPitch(1.14); break;
      case 'calm': await _tts.setSpeechRate(0.43); await _tts.setPitch(0.96); break;
      case 'expressive': await _tts.setSpeechRate(0.51); await _tts.setPitch(1.07); break;
      default: await _tts.setSpeechRate(0.48); await _tts.setPitch(1.0);
    }
    final id = _appleVoiceId;
    if (id != null) await _tts.setVoice({'identifier': id});
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
  }

  Future<void> _speakWithSavedVoice(String text) async {
    await _preparePlaybackSession();
    if (_ttsEngine == 'supertonic' && await _supertonicState.refresh()) {
      if (!_supertonicReady) {
        await _supertonic.initialize();
        _supertonicReady = true;
      }
      final result = await _supertonic.synthesize(
        text,
        language: _conversationLocale.split('_').first.toLowerCase(),
        voiceStyle: _supertonicVoice,
        config: const TTSConfig(speechSpeed: 1.05, denoisingSteps: 5),
      );
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/supertonic_text_output.wav');
      await file.writeAsBytes(result.toWavBytes(), flush: true);
      final completed = _supertonicPlayer.onPlayerComplete.first;
      await _supertonicPlayer.play(DeviceFileSource(file.path));
      await completed.timeout(const Duration(minutes: 2));
      try { await file.delete(); } catch (_) {}
      return;
    }
    await _configureAppleVoice();
    await _tts.speak(text);
  }

  Future<void> _stopVoice() async {
    await _tts.stop();
    await _supertonicPlayer.stop();
  }

  Future<void> _showVoiceSettings() async {
    await _stopVoice();
    final box = Hive.box('settings');
    String engine = _ttsEngine;
    String superVoice = _supertonicVoice;
    String style = _appleStyle;
    String? voiceId = _appleVoiceId;
    List<Map<String, String>> voices = [];
    try {
      final raw = await _tts.getVoices;
      final locale = _conversationLocale.replaceAll('_', '-').toLowerCase();
      if (raw is List) {
        voices = raw.whereType<Map>().where((v) =>
          (v['locale'] ?? '').toString().replaceAll('_', '-').toLowerCase() == locale &&
          (v['identifier'] ?? '').toString().isNotEmpty).map((v) =>
          {'id': v['identifier'].toString(), 'name': (v['name'] ?? v['identifier']).toString()}).toList();
      }
    } catch (_) {}
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, refresh) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Steminstellingen', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            DropdownButton<String>(
              value: engine, isExpanded: true,
              items: const [
                DropdownMenuItem(value: 'apple', child: Text('Apple iPhone-stemmen')),
                DropdownMenuItem(value: 'supertonic', child: Text('Supertonic 3 · Neural offline')),
              ],
              onChanged: (v) async {
                if (v == null) return;
                if (v == 'supertonic' && !await _supertonicState.refresh()) {
                  if (mounted) Get.snackbar('Supertonic 3', 'Download Supertonic 3 eerst via Settings.');
                  return;
                }
                refresh(() => engine = v);
                await box.put('voice_tts_engine', v);
              },
            ),
            if (engine == 'supertonic') DropdownButton<String>(
              value: superVoice, isExpanded: true,
              items: const ['M1','M2','M3','M4','M5','F1','F2','F3','F4','F5']
                  .map((v) => DropdownMenuItem(value: v, child: Text('Supertonic $v'))).toList(),
              onChanged: (v) async {
                if (v == null) return;
                refresh(() => superVoice = v);
                await box.put('voice_supertonic_voice', v);
              },
            ),
            if (engine == 'apple') DropdownButton<String>(
              value: style, isExpanded: true,
              items: const [
                DropdownMenuItem(value: 'natural', child: Text('Natuurlijk')),
                DropdownMenuItem(value: 'expressive', child: Text('Expressief')),
                DropdownMenuItem(value: 'energetic', child: Text('Energiek')),
                DropdownMenuItem(value: 'calm', child: Text('Rustig')),
              ],
              onChanged: (v) async {
                if (v == null) return;
                refresh(() => style = v);
                await box.put('voice_apple_style', v);
              },
            ),
            if (engine == 'apple') DropdownButton<String>(
              value: voiceId != null && voices.any((v) => v['id'] == voiceId) ? voiceId : null,
              isExpanded: true,
              hint: const Text('Automatische iPhone-stem'),
              items: [
                const DropdownMenuItem<String>(value: null, child: Text('Automatische iPhone-stem')),
                ...voices.map((v) => DropdownMenuItem<String>(value: v['id'], child: Text(v['name']!))),
              ],
              onChanged: (v) async {
                refresh(() => voiceId = v);
                if (v == null) await box.delete('voice_apple_id');
                else await box.put('voice_apple_id', v);
              },
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () async {
                try {
                  await _speakWithSavedVoice(_conversationLocale == 'nl_NL'
                      ? 'Hallo! Dit is mijn nieuwe stem. Wat zullen we bespreken?'
                      : 'Hello! This is my new voice. What shall we discuss?');
                } catch (e) {
                  if (mounted) Get.snackbar('Stemfout', e.toString());
                }
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Stem beluisteren'),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Sluiten')),
          ]),
        ),
      )),
    );
    if (mounted) setState(() {});
  }

  Future<void> _toggleListening() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_isListening) {
      await _speech.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }

    final available = await _speech.initialize(
      onStatus: (status) {
        if ((status == 'done' || status == 'notListening') && mounted) {
          setState(() => _isListening = false);
        }
      },
      onError: (error) {
        if (mounted) {
          setState(() => _isListening = false);
          Get.snackbar('Speech recognition error', error.errorMsg);
        }
      },
    );
    if (!available) {
      Get.snackbar('Voice unavailable', 'Speech recognition is not available on this device.');
      return;
    }

    setState(() => _isListening = true);
    await _speech.listen(
      localeId: 'nl_NL',
      listenFor: const Duration(seconds: 60),
      pauseFor: const Duration(seconds: 3),
      onResult: (result) {
        _msgController.text = result.recognizedWords;
        _msgController.selection = TextSelection.collapsed(offset: _msgController.text.length);
        if (result.finalResult && mounted) {
          setState(() => _isListening = false);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isDesktop = width >= 768;

    return Stack(
      children: [
        if (isDesktop) _buildDesktopLayout() else _buildMobileLayout(),
        // ── Global model loading overlay ──
        _buildLoadingOverlay(),
      ],
    );
  }

  Widget _buildLoadingOverlay() {
    return Obx(() {
      if (!_modelCtrl.isImportingModel.value) return const SizedBox.shrink();

      final progress = _modelCtrl.loadingProgress.value;
      final percent = (progress * 100).clamp(0, 100).toInt();
      final msg = _modelCtrl.loadingStatusMsg.value;
      final filename = _modelCtrl.loadingModelFilename.value ?? 'Model';

      // Derive a short display name from the filename
      final displayName = filename.endsWith('.gguf')
          ? filename.substring(0, filename.length - 5)
          : filename;

      return Material(
        color: Colors.transparent,
        child: Container(
          color: Colors.black.withValues(alpha: 0.55),
          child: Center(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 40),
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: context.bgPanel,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.accent.withValues(alpha: 0.3),
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.accent.withValues(alpha: 0.1),
                    blurRadius: 40,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Circular progress
                  SizedBox(
                    width: 80,
                    height: 80,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 80,
                          height: 80,
                          child: CircularProgressIndicator(
                            value: progress <= 0 ? null : progress.clamp(0.0, 1.0),
                            strokeWidth: 5,
                            backgroundColor: context.border,
                            valueColor: const AlwaysStoppedAnimation(
                              AppColors.accent,
                            ),
                          ),
                        ),
                        if (percent > 0)
                          Text(
                            '$percent%',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: context.text,
                            ),
                          ),
                        if (percent <= 0)
                          Icon(
                            Icons.hourglass_empty_rounded,
                            size: 24,
                            color: context.textD,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Model name
                  Text(
                    displayName,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: context.text,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),

                  // Status message
                  Text(
                    msg.isNotEmpty ? msg : 'Importing file...',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.textM,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  
                  // Hint for large models
                  if (progress == 0)
                    Text(
                      'Large models (5GB+) take about 30-50 seconds for Android to process. Please wait.',
                      style: TextStyle(
                        fontSize: 10,
                        color: context.textD,
                        fontStyle: FontStyle.italic,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  const SizedBox(height: 20),

                  // Cancel button
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _modelCtrl.cancelImport(),
                      icon: const Icon(Icons.close_rounded, size: 16),
                      label: const Text('Cancel'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.red,
                        side: BorderSide(
                          color: AppColors.red.withValues(alpha: 0.4),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  // ═══════════════════════════════════════════════════════════════
  // MOBILE LAYOUT — Bottom nav with 3 tabs + drawer for chat history
  // ═══════════════════════════════════════════════════════════════
  Widget _buildMobileLayout() {
    return Scaffold(
      key: _mobileScaffoldKey,
      backgroundColor: context.bg,
      resizeToAvoidBottomInset: true,
      // ── Left drawer for chat history ──
      drawer: Drawer(
        backgroundColor: context.bg,
        child: SafeArea(
          child: Column(
            children: [
              // Drawer header
              Container(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: context.border, width: 0.5),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        gradient: AppColors.accentGradient,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.bolt_rounded,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Chat History',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: context.text,
                      ),
                    ),
                    const Spacer(),
                    // New chat button in drawer header
                    IconButton(
                      icon: Icon(
                        Icons.edit_square,
                        size: 20,
                        color: context.textM,
                      ),
                      onPressed: () {
                        _chatCtrl.newChat();
                        Navigator.pop(context); // close drawer
                      },
                      tooltip: 'New Chat',
                    ),
                  ],
                ),
              ),
              // Chat list
              Expanded(
                child: ChatSidebar(
                  onNewChat: () {
                    _chatCtrl.newChat();
                    Navigator.pop(context);
                  },
                  onSelectChat: (id) {
                    _chatCtrl.switchChat(id);
                    Navigator.pop(context);
                  },
                  onDeleteChat: (id) => _chatCtrl.deleteChat(id),
                  showNewChatButton: false,
                ),
              ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        bottom: false, // let the bottom nav handle the safe area
        child: IndexedStack(
          index: _mobileTabIndex,
          children: [
            // Tab 0: Chat
            _buildMobileChatTab(),
            // Tab 1: Models
            const ModelLibraryScreen(embedded: true),
            // Tab 2: Settings
            SettingsScreen(embedded: true, onClose: () {
              FocusManager.instance.primaryFocus?.unfocus();
              if (mounted) setState(() => _mobileTabIndex = 0);
            }),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: context.bg,
          border: Border(top: BorderSide(color: context.border, width: 0.5)),
        ),
        child: NavigationBar(
          selectedIndex: _mobileTabIndex,
          onDestinationSelected: (i) {
            FocusManager.instance.primaryFocus?.unfocus();
            setState(() => _mobileTabIndex = i);
          },
          backgroundColor: Colors.transparent,
          elevation: 0,
          indicatorColor: AppColors.accent.withOpacity(0.15),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          height: 64,
          destinations: [
            NavigationDestination(
              icon: Icon(Icons.chat_outlined, color: context.textM),
              selectedIcon: const Icon(
                Icons.chat_rounded,
                color: AppColors.accent,
              ),
              label: 'Chat',
            ),
            NavigationDestination(
              icon: Icon(Icons.widgets_outlined, color: context.textM),
              selectedIcon: const Icon(
                Icons.widgets_rounded,
                color: AppColors.accent,
              ),
              label: 'Models',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined, color: context.textM),
              selectedIcon: const Icon(
                Icons.settings_rounded,
                color: AppColors.accent,
              ),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileChatTab() {
    return Column(
      children: [
        // Mobile top bar — minimal with SafeArea for status bar
        SafeArea(
          bottom: false,
          child: _buildMobileTopBar(),
        ),
        // Model loading progress banner
        Obx(() {
          if (!_modelCtrl.isLoadingModel.value) return const SizedBox.shrink();
          final progress = _modelCtrl.loadingProgress.value;
          final percent = (progress * 100).clamp(0, 100).toInt();
          final msg = _modelCtrl.loadingStatusMsg.value;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.orange.withValues(alpha: 0.1),
              border: Border(
                bottom: BorderSide(color: AppColors.orange.withValues(alpha: 0.3)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(AppColors.orange),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        msg.isNotEmpty ? msg : 'Loading model...',
                        style: TextStyle(fontSize: 12, color: context.text),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.orange.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '$percent%',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.orange,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: context.border,
                    valueColor: const AlwaysStoppedAnimation(AppColors.orange),
                  ),
                ),
              ],
            ),
          );
        }),
        // Chat area
        Expanded(child: _buildChatArea()),
      ],
    );
  }

  Widget _buildMobileTopBar() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: context.bg,
        border: Border(bottom: BorderSide(color: context.border, width: 0.5)),
      ),
      child: Row(
        children: [
          // Sidebar / history button — opens drawer from left
          IconButton(
            icon: Icon(Icons.menu_rounded, size: 22, color: context.textM),
            onPressed: () => _mobileScaffoldKey.currentState?.openDrawer(),
            tooltip: 'Chat History',
          ),

          // Model selector dropdown
          Expanded(
            child: Center(
              child: Obx(() {
                final fname = _modelCtrl.selectedModelFilename.value;
                final info = fname != null
                    ? _modelCtrl.getModelInfo(fname)
                    : null;
                final loaded = _llm.isLoaded.value;
                final isLoading = _llm.isLoadingModel.value;
                final label = isLoading
                    ? 'Loading...'
                    : loaded
                    ? (info?.name ?? fname ?? 'Model')
                    : 'No model selected';

                return GestureDetector(
                  onTap: () => _showModelPicker(context),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Status dot
                      Container(
                        width: 7,
                        height: 7,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isLoading
                              ? AppColors.orange
                              : loaded
                              ? AppColors.green
                              : AppColors.red,
                        ),
                      ),
                      Flexible(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: loaded
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: loaded ? context.text : context.textD,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: context.textM,
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),

          // Always-visible entry point for the dedicated live voice screen.
          IconButton(
            icon: const Icon(Icons.graphic_eq_rounded, size: 25, color: AppColors.accent),
            tooltip: 'Live spraak',
            onPressed: () async {
              FocusManager.instance.primaryFocus?.unfocus();
              await _tts.stop();
              if (!mounted) return;
              Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const VoiceChatScreen(),
              ));
            },
          ),

          // New chat button — on the right
          IconButton(
            icon: Icon(Icons.edit_square, size: 20, color: context.textM),
            onPressed: () => _chatCtrl.newChat(),
            tooltip: 'New Chat',
          ),
        ],
      ),
    );
  }

  void _showModelPicker(BuildContext context) {
    final downloaded = _modelCtrl.downloadedModels;
    if (downloaded.isEmpty) {
      // No models — nudge user to Models tab
      setState(() => _mobileTabIndex = 1);
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: context.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: context.textD,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Text(
                      'Select Model',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: context.text,
                      ),
                    ),
                    const Spacer(),
                    // Unload button if model is loaded
                    Obx(() {
                      if (_llm.isLoaded.value) {
                        return TextButton.icon(
                          onPressed: () {
                            _modelCtrl.unloadCurrentModel();
                            Navigator.pop(context);
                          },
                          icon: const Icon(
                            Icons.eject_rounded,
                            size: 16,
                            color: AppColors.orange,
                          ),
                          label: const Text(
                            'Unload',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.orange,
                            ),
                          ),
                        );
                      }
                      return const SizedBox.shrink();
                    }),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(context);
                        setState(() => _mobileTabIndex = 1);
                      },
                      child: const Text(
                        'Browse All',
                        style: TextStyle(fontSize: 13, color: AppColors.accent),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              // Model list
              ...downloaded.map((filename) {
                final info = _modelCtrl.getModelInfo(filename);
                final isActive =
                    _modelCtrl.selectedModelFilename.value == filename &&
                    _llm.isLoaded.value;
                final isLoading =
                    _modelCtrl.loadingModelFilename.value == filename;
                return ListTile(
                  dense: true,
                  leading: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: isActive
                          ? AppColors.green.withOpacity(0.15)
                          : isLoading
                          ? AppColors.orange.withOpacity(0.15)
                          : context.bgHover,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: isLoading
                        ? const Padding(
                            padding: EdgeInsets.all(8),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.orange,
                            ),
                          )
                        : Icon(
                            isActive
                                ? Icons.check_rounded
                                : Icons.smart_toy_outlined,
                            size: 16,
                            color: isActive ? AppColors.green : context.textM,
                          ),
                  ),
                  title: Text(
                    info?.name ?? filename,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                      color: context.text,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: info != null
                      ? Text(
                          '${info.sizeGb} GB • Min ${info.minRamGb} GB RAM',
                          style: TextStyle(fontSize: 11, color: context.textD),
                        )
                      : null,
                  trailing: isActive
                      ? const Text(
                          'Active',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.green,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      : isLoading
                      ? const Text(
                          'Loading...',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.orange,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      : null,
                  onTap: () {
                    Navigator.pop(context);
                    if (!isActive && !isLoading) {
                      _modelCtrl.loadModel(filename);
                    }
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // DESKTOP LAYOUT — Sidebar + Top bar
  // ═══════════════════════════════════════════════════════════════
  Widget _buildDesktopLayout() {
    return Scaffold(
      backgroundColor: context.bg,
      body: Row(
        children: [
          // Sidebar
          if (_sidebarOpen)
            SizedBox(
              width: 260,
              child: Container(
                decoration: BoxDecoration(
                  color: context.bgSidebar,
                  border: Border(
                    right: BorderSide(color: context.border, width: 0.5),
                  ),
                ),
                child: ChatSidebar(
                  onNewChat: () => _chatCtrl.newChat(),
                  onSelectChat: (id) => _chatCtrl.switchChat(id),
                  onDeleteChat: (id) => _chatCtrl.deleteChat(id),
                ),
              ),
            ),

          // Main content
          Expanded(
            child: Column(
              children: [
                _buildDesktopTopBar(),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 800),
                      child: _buildChatArea(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopTopBar() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: context.bg,
        border: Border(bottom: BorderSide(color: context.border, width: 0.5)),
      ),
      child: Row(
        children: [
          // Sidebar toggle
          IconButton(
            icon: Icon(
              _sidebarOpen
                  ? Icons.view_sidebar_rounded
                  : Icons.view_sidebar_outlined,
              size: 20,
              color: context.textM,
            ),
            onPressed: () => setState(() => _sidebarOpen = !_sidebarOpen),
            tooltip: 'Toggle sidebar',
          ),

          const SizedBox(width: 8),

          // Model selector dropdown
          Obx(() {
            final fname = _modelCtrl.selectedModelFilename.value;
            final info = fname != null ? _modelCtrl.getModelInfo(fname) : null;
            return InkWell(
              onTap: () => Get.toNamed('/models'),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: context.bgHover.withOpacity(0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      info?.name ?? (fname ?? 'Select Model'),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: context.text,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: context.textM,
                    ),
                  ],
                ),
              ),
            );
          }),

          const Spacer(),

          // Engine status
          Obx(
            () => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _llm.isLoadingModel.value
                        ? AppColors.orange
                        : _llm.isLoaded.value
                        ? AppColors.green
                        : AppColors.red,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _llm.isLoadingModel.value
                      ? 'Loading... ${(_llm.loadingProgress.value * 100).toInt()}%'
                      : _llm.isLoaded.value
                      ? 'Ready'
                      : 'No Model',
                  style: TextStyle(fontSize: 12, color: context.textD),
                ),
                if (_llm.isLoaded.value && !_llm.isLoadingModel.value) ...[
                  const SizedBox(width: 8),
                  // Unload button on desktop
                  InkWell(
                    onTap: () => _modelCtrl.unloadCurrentModel(),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.eject_rounded,
                            size: 14,
                            color: AppColors.orange,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            'Unload',
                            style: TextStyle(
                              fontSize: 11,
                              color: context.textD,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (_llm.isGenerating.value) ...[
                  const SizedBox(width: 12),
                  Text(
                    '${_llm.tokensPerSecond.value.toStringAsFixed(1)} t/s',
                    style: TextStyle(fontSize: 12, color: context.textM),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Theme toggle
          Obx(
            () => IconButton(
              icon: Icon(
                _themeCtrl.isDarkMode
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
                size: 20,
                color: context.textM,
              ),
              onPressed: () => _themeCtrl.toggleTheme(),
              tooltip: 'Toggle theme',
            ),
          ),

          // Settings
          IconButton(
            icon: Icon(Icons.settings_outlined, size: 20, color: context.textM),
            onPressed: () => Get.toNamed('/settings'),
            tooltip: 'Settings',
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // SHARED — Chat area used by both layouts
  // ═══════════════════════════════════════════════════════════════
  Widget _buildChatArea() {
    return Column(
      children: [
        Expanded(
          child: Obx(() {
            final chat = _chatCtrl.activeChat;
            if (chat == null || chat.messages.isEmpty) {
              return _buildWelcome();
            }

            if (_lastRenderedChatId != chat.id) {
              _lastRenderedChatId = chat.id;
              _autoScrollToBottom = true;
              _scrollToBottom(force: true);
            }

            _scrollToBottom();

            return ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: 16),
              itemCount:
                  chat.messages.length + (_chatCtrl.isGenerating.value ? 1 : 0),
              itemBuilder: (context, index) {
                if (index < chat.messages.length) {
                  final msg = chat.messages[index];
                  // Show speed on the last AI message
                  final isLastAi =
                      msg.isAssistant && index == chat.messages.length - 1;
                  return ChatBubble(message: msg, showSpeed: isLastAi);
                }
                return const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TypingIndicator(),
                  ),
                );
              },
            );
          }),
        ),

        _buildInputArea(),
      ],
    );
  }

  Widget _buildWelcome() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                gradient: AppColors.accentGradient,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.bolt_rounded,
                size: 32,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'How can I help you?',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: context.text,
              ),
            ),
            const SizedBox(height: 8),
            Obx(
              () => Text(
                _llm.isLoaded.value
                    ? 'Type a message below to get started.'
                    : 'Select a model first to begin chatting.',
                style: TextStyle(fontSize: 14, color: context.textM),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Container(
        decoration: BoxDecoration(
          color: context.bgInput,
          border: Border.all(color: context.border),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(context.isDark ? 0.15 : 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Text field
            Expanded(
              child: TextField(
                controller: _msgController,
                maxLines: 5,
                minLines: 1,
                textInputAction: TextInputAction.newline,
                style: TextStyle(
                  fontSize: 15,
                  color: context.text,
                  height: 1.4,
                ),
                decoration: InputDecoration(
                  hintText: 'Ask anything...',
                  hintStyle: TextStyle(color: context.textD),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.fromLTRB(24, 14, 8, 14),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),

            // Open dedicated hands-free voice mode instead of the old mic.
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _circleButton(
                icon: Icons.graphic_eq_rounded,
                color: AppColors.accent,
                onTap: () async {
                  FocusManager.instance.primaryFocus?.unfocus();
                  await _tts.stop();
                  if (!mounted) return;
                  Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const VoiceChatScreen(),
                  ));
                },
                tooltip: 'Live spraak',
              ),
            ),

            // Toggle spoken responses
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _circleButton(
                icon: _speakResponses ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                color: _speakResponses ? AppColors.accent : context.textD,
                onTap: () {
                  setState(() => _speakResponses = !_speakResponses);
                  if (!_speakResponses) _tts.stop();
                },
                tooltip: _speakResponses ? 'Voice replies on' : 'Voice replies off',
              ),
            ),

            // Send / Stop
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 6),
              child: Obx(
                () => _chatCtrl.isGenerating.value
                    ? _circleButton(
                        icon: Icons.stop_rounded,
                        color: AppColors.red,
                        onTap: _chatCtrl.stopGeneration,
                        tooltip: 'Stop',
                      )
                    : _circleButton(
                        icon: Icons.arrow_upward_rounded,
                        color: AppColors.accent,
                        onTap: _send,
                        tooltip: 'Send',
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _circleButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
      ),
    );
  }
}
