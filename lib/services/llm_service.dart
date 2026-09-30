import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import 'wakelock_service.dart';
import 'chat_storage_service.dart';
import 'log_service.dart';

/// Wraps llamadart's LlamaEngine for model loading, generation, and lifecycle.
class LlmService extends GetxService {
  LlamaEngine? _engine;
  LlamaBackend? _backend;

  final isLoaded = false.obs;
  final isGenerating = false.obs;
  final loadedModelPath = ''.obs;
  final tokensPerSecond = 0.0.obs;
  final lastGenerationTokens = 0.obs;
  final lastGenerationSpeed = 0.0.obs;

  // ── Loading progress tracking ──────────────────────────────
  final isLoadingModel = false.obs;
  final loadingProgress = 0.0.obs; // 0.0 to 1.0
  final loadingStatusMsg = ''.obs;
  bool _loadingCancelled = false;

  StreamSubscription? _generateSub;

  String get loadedModelFilename {
    final path = loadedModelPath.value;
    if (path.isEmpty) return '';
    return p.basename(path);
  }

  String get publicModelId {
    final filename = loadedModelFilename;
    if (filename.isEmpty) return 'local';
    final stem = filename.toLowerCase().endsWith('.gguf')
        ? filename.substring(0, filename.length - 5)
        : p.basenameWithoutExtension(filename);
    return stem
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  /// Initialize the service.
  Future<LlmService> init() async {
    // Backend is created fresh per loadModel() call — no init needed here
    return this;
  }

  /// Cancel an in-progress model load.
  void cancelLoading() {
    _loadingCancelled = true;
  }

  /// Load a GGUF model from [path] with progress tracking.
  Future<void> loadModel(String path) async {
    LogService? log;
    try { log = Get.find<LogService>(); } catch (_) {}

    // Verify file exists first
    final file = File(path);
    if (!await file.exists()) {
      log?.error('Model file not found: $path', source: 'LLM');
      throw Exception('Model file not found: $path');
    }

    final filename = p.basename(path);
    log?.info('Loading model: $filename', source: 'LLM');

    _loadingCancelled = false;
    isLoadingModel.value = true;
    loadingProgress.value = 0.0;
    loadingStatusMsg.value = 'Preparing...';

    // Enable wake lock during model loading (heavy memory operation)
    WakelockService? wakelockService;
    try {
      wakelockService = Get.find<WakelockService>();
    } catch (_) {}

    // Unload previous if any — MUST fully tear down engine + backend
    if (_engine != null || isLoaded.value) {
      loadingStatusMsg.value = 'Unloading previous model...';
      loadingProgress.value = 0.05;
      await _fullTeardown();
      // Give native side time to release resources
      await Future.delayed(const Duration(milliseconds: 500));
      if (_loadingCancelled) {
        _resetLoadingState();
        return;
      }
    }

    // Fresh backend + engine for every load — prevents stale native state
    // Wrapped in try-catch to handle SELinux crashes on Android where
    // ggml_backend_load_all() attempts to scan '/' which is denied.
    try {
      _backend = LlamaBackend();
      _engine = LlamaEngine(_backend!);
    } catch (e) {
      _backend = null;
      _engine = null;
      _resetLoadingState();
      log?.error('Engine init failed: $e', source: 'LLM');
      throw Exception(
        'Failed to initialize AI engine. '
        'This may be a device compatibility issue. '
        'Error: $e',
      );
    }

    try {
      loadingStatusMsg.value = 'Loading into memory...';
      loadingProgress.value = 0.1;

      // Get file size for display
      final fileSize = await file.length();
      final sizeGb = (fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1);
      loadingStatusMsg.value = 'Loading $sizeGb GB into memory...';

      // Start a timer to animate progress while loading
      Timer? progressTimer;
      progressTimer = Timer.periodic(const Duration(milliseconds: 300), (
        timer,
      ) {
        if (_loadingCancelled) {
          timer.cancel();
          return;
        }
        // Gradually increase progress (asymptotic approach to 0.95)
        final current = loadingProgress.value;
        if (current < 0.95) {
          loadingProgress.value = current + (0.95 - current) * 0.04;
        }
      });

      if (_loadingCancelled) {
        progressTimer.cancel();
        await _fullTeardown();
        _resetLoadingState();
        return;
      }

      // Use smaller context on Android to prevent OOM kills.
      // Desktop can handle 2048, but Android devices with limited RAM
      // need 1024 to avoid the Low Memory Killer (LMK).
      final contextSize = Platform.isIOS
          ? (fileSize < 3 * 1024 * 1024 * 1024 ? 1024 : 512)
         : Platform.isAndroid
             ? 1024
             : 2048;
     // Map the string backend to GpuBackend enum
      final storage = Get.find<ChatStorageService>();
      GpuBackend parsedBackend;
      switch (storage.backendType) {
        case 'vulkan':
          parsedBackend = GpuBackend.vulkan;
          break;
        case 'opencl':
          parsedBackend = GpuBackend.opencl;
          break;
        default:
          parsedBackend = GpuBackend.cpu;
      }

      // Stable path: use the explicit hardware setting. Automatic probing was
      // removed because a failed iOS Metal allocation can leave the native
      // runtime unable to load even a smaller model until the process restarts.
      final requestedGpuLayers = storage.gpuLayers;

      // Optimize threads: 4 for both generation and batch processing to keep memory stable.
      final params = ModelParams(
        contextSize: contextSize,
        gpuLayers: requestedGpuLayers, 
        preferredBackend: Platform.isIOS ? GpuBackend.cpu : parsedBackend,
        numberOfThreads: Platform.numberOfProcessors > 4 ? 4 : 0, 
        numberOfThreadsBatch: Platform.numberOfProcessors > 4 ? 4 : 0,
      );

      log?.info('Backend=$parsedBackend, GPU layers=$requestedGpuLayers, ctx=$contextSize, threads=${Platform.numberOfProcessors > 4 ? 4 : 0}', source: 'LLM');
await _engine!.loadModel(path, modelParams: params);
progressTimer.cancel();

// Runtime diagnostics only; never mutate the next model load from this value.
try {
  final activeBackend = await _engine!.getBackendName();
  final resolvedGpuLayers = await _engine!.getResolvedGpuLayers();
  log?.info(
    'Runtime backend=$activeBackend, resolved GPU layers=$resolvedGpuLayers, requested GPU layers=$requestedGpuLayers',
    source: 'LLM',
  );
} catch (e) {
  log?.warn('Runtime diagnostics unavailable: $e', source: 'LLM');
}

if (_loadingCancelled) {
      
        // User cancelled while loading — full cleanup
        await _fullTeardown();
        _resetLoadingState();
        return;
      }

      loadingProgress.value = 1.0;
      loadingStatusMsg.value = 'Ready!';
      isLoaded.value = true;
      loadedModelPath.value = path;
      log?.info('Model loaded successfully: $filename', source: 'LLM');

      // Enable wake lock for inference on mobile (keeps app from being killed)
      final modelName = p.basenameWithoutExtension(path);
      await wakelockService?.enableForInference(modelName: modelName);

      // Brief delay to show 100%
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      isLoaded.value = false;
      loadedModelPath.value = '';
      await _fullTeardown();
      log?.error('Model load failed: $e', source: 'LLM');
      if (Platform.isIOS && filename.toLowerCase().contains('gemma-4') && e.toString().toLowerCase().contains('context')) {
        log?.warn('Gemma 4 context creation failed. This may indicate insufficient free iOS memory or unsupported Gemma 4 features in the bundled llama.cpp runtime. Try a smaller GGUF and collect native diagnostics before changing backend settings.', source: 'LLM');
      }

      // Provide a clearer error message for common Android failures
      if (Platform.isAndroid) {
        final errStr = e.toString().toLowerCase();
        if (errStr.contains('memory') || errStr.contains('alloc')) {
          throw Exception(
            'Not enough RAM to load this model. '
            'Try a smaller model (e.g. Gemma 2 2B at 1.6 GB).',
          );
        }
      }
      rethrow;
    } finally {
      _resetLoadingState();
    }
  }

  void _resetLoadingState() {
    isLoadingModel.value = false;
    loadingProgress.value = 0.0;
    loadingStatusMsg.value = '';
    _loadingCancelled = false;
  }

  /// Tokens/patterns the model may emit that should be stripped from output.
  /// Covers ChatML, Llama, Gemma, Phi, Mistral, and other common formats.
  static final _stopPatterns = RegExp(
    r'<\|end\|>'
    r'|<\|eot_id\|>'
    r'|<\|endoftext\|>'
    r'|<\|im_end\|>'
    r'|<\|im_start\|>'
    r'|<end_of_turn>'
    r'|<start_of_turn>'
    r'|<\|assistant\|>'
    r'|<\|user\|>'
    r'|<\|system\|>'
    r'|<\|pad\|>'
    r'|</s>'
    r'|<s>'
    r'|\[INST\]'
    r'|\[/INST\]'
    r'|\[end\]',
  );

  /// Pattern that signals the model is hallucinating a new user turn — stop immediately.
  static final _userTurnPattern = RegExp(
    r'<\|user\|>|<\|im_start\|>\s*user|<start_of_turn>\s*user|\[INST\]',
  );

  /// Generate a streaming response.
  /// [messages] is a list of {role, content} maps.
  /// [systemPrompt] is prepended as a system message.
  /// Returns a Stream of String tokens.
  Stream<String> generate({
    required List<Map<String, String>> messages,
    String? systemPrompt,
    double temperature = 0.7,
  }) async* {
    if (_engine == null || !isLoaded.value) {
      throw StateError('No model loaded. Call loadModel() first.');
    }
    if (isGenerating.value) {
      throw StateError('Another generation is already in progress.');
    }

    isGenerating.value = true;
    tokensPerSecond.value = 0.0;
    final stopwatch = Stopwatch()..start();
    int tokenCount = 0;

    try {
      // Keep a conservative token budget for mobile, leaving room for output.
      // Character counts are an estimate; a future update should use the
      // model tokenizer for exact context accounting.
      final contextBudget = Platform.isIOS ? 420 : 1800;
      final recent = <Map<String, String>>[];
      var remaining = contextBudget;
      for (final message in messages.reversed) {
        final content = message['content'] ?? '';
        if (content.isEmpty) continue;
        if (recent.isNotEmpty && remaining < 80) break;
        final trimmed = content.length <= remaining
            ? content
            : content.substring(content.length - remaining);
        recent.insert(0, {'role': message['role'] ?? 'user', 'content': trimmed});
        remaining -= trimmed.length;
      }
      final chatMessages = <LlamaChatMessage>[];
      if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
        // Preserve full personality instructions. Truncating at 120 characters
        // silently destroyed the language/personality presets on iOS.
        final prompt = systemPrompt;
        chatMessages.add(LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text: prompt,
        ));
      }
      for (final message in recent) {
        final role = switch (message['role']) {
          'system' => LlamaChatRole.system,
          'assistant' => LlamaChatRole.assistant,
          _ => LlamaChatRole.user,
        };
        chatMessages.add(LlamaChatMessage.fromText(
          role: role,
          text: message['content'] ?? '',
        ));
      }
      // Let llamadart use the GGUF model's own chat template.
      final params = GenerationParams(
        temp: temperature,
        topP: 0.95,
        minP: 0.05,
        penalty: 1.0,
        maxTokens: Platform.isIOS ? 384 : 512,
      );
      await for (final chunk in _engine!.create(
        chatMessages,
        params: params,
        toolChoice: ToolChoice.none,
      )) {
        final choice = chunk.choices.isNotEmpty ? chunk.choices.first : null;
        final content = choice?.delta.content;
        if (content == null || content.isEmpty) continue;
        tokenCount++;
        if (stopwatch.elapsedMilliseconds > 0) {
          tokensPerSecond.value =
              tokenCount / (stopwatch.elapsedMilliseconds / 1000);
        }
        yield content;
      }
    } finally {
      stopwatch.stop();
      lastGenerationTokens.value = tokenCount;
      lastGenerationSpeed.value = tokensPerSecond.value;
      isGenerating.value = false;
    }
  }

  /// Generate a chat completion using llamadart's chat-template API.
  Stream<String> generateChatCompletion({
    required List<LlamaChatMessage> messages,
    GenerationParams params = const GenerationParams(),
  }) async* {
    if (_engine == null || !isLoaded.value) {
      throw StateError('No model loaded. Call loadModel() first.');
    }
    if (isGenerating.value) {
      throw StateError('Another generation is already in progress.');
    }

    isGenerating.value = true;
    tokensPerSecond.value = 0.0;
    final stopwatch = Stopwatch()..start();
    int tokenCount = 0;

    try {
      await for (final chunk in _engine!.create(
        messages,
        params: params,
        toolChoice: ToolChoice.none,
      )) {
        final choice = chunk.choices.isNotEmpty ? chunk.choices.first : null;
        final content = choice?.delta.content;
        if (content == null || content.isEmpty) continue;

        tokenCount++;
        if (stopwatch.elapsedMilliseconds > 0) {
          tokensPerSecond.value =
              tokenCount / (stopwatch.elapsedMilliseconds / 1000);
        }
        yield content;
      }
    } finally {
      stopwatch.stop();
      lastGenerationTokens.value = tokenCount;
      lastGenerationSpeed.value = tokensPerSecond.value;
      isGenerating.value = false;
    }
  }

  Future<int> countTokens(String text) async {
    if (_engine == null || !isLoaded.value) return 0;
    try {
      return await _engine!.getTokenCount(text);
    } catch (_) {
      return 0;
    }
  }

  /// Stop ongoing generation.
  Future<void> stopGeneration() async {
    _generateSub?.cancel();
    _generateSub = null;
    _engine?.cancelGeneration();

    // Do not clear isGenerating here. The active generate() iterator owns that
    // flag and clears it in its finally block after llama.cpp has actually
    // unwound. Starting another request before then causes
    // "Another generation is already in progress".
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (isGenerating.value && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 40));
    }
  }

  /// Full native teardown — dispose engine AND backend to prevent stale state.
  Future<void> _fullTeardown() async {
    // Never dispose a model while native generation is still running.
    await stopGeneration();
    await Future.delayed(const Duration(milliseconds: 100));
    if (_engine != null) {
      try {
        await _engine!.dispose();
      } catch (_) {
        // Engine may already be in broken state — ignore
      }
      _engine = null;
    }
    // Also destroy the backend — it can't be reused after engine disposal
    _backend = null;
    isLoaded.value = false;
    loadedModelPath.value = '';
    tokensPerSecond.value = 0.0;
  }

  /// Unload the current model and free memory.
  Future<void> unloadModel() async {
    await _fullTeardown();

    // Disable wake lock when model is unloaded
    try {
      final wakelockService = Get.find<WakelockService>();
      await wakelockService.disable();
    } catch (_) {}
  }

  /// Build a single prompt string from chat messages.
  String _buildPrompt(
    List<Map<String, String>> messages,
    String? systemPrompt,
  ) {
    final buffer = StringBuffer();

    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      buffer.writeln('<|system|>');
      buffer.writeln(systemPrompt);
      buffer.writeln('<|end|>');
    }

    for (final msg in messages) {
      final role = msg['role'] ?? 'user';
      final content = msg['content'] ?? '';
      buffer.writeln('<|$role|>');
      buffer.writeln(content);
      buffer.writeln('<|end|>');
    }

    buffer.writeln('<|assistant|>');
    return buffer.toString();
  }

  @override
  void onClose() {
    unloadModel();
    super.onClose();
  }
}
