import 'package:flutter/foundation.dart';
import 'package:supertonic_flutter/supertonic_flutter.dart';

/// Shared Supertonic model/download state used by Settings and Live Voice.
class SupertonicService {
  SupertonicService._();
  static final SupertonicService instance = SupertonicService._();

  final ValueNotifier<bool> installed = ValueNotifier<bool>(false);
  final ValueNotifier<bool> downloading = ValueNotifier<bool>(false);
  final ValueNotifier<double> progress = ValueNotifier<double>(0);
  final ValueNotifier<String> detail = ValueNotifier<String>('Status controleren...');

  Future<bool> refresh() async {
    try {
      final ready = await SupertonicTTS.modelsReady();
      installed.value = ready;
      if (!downloading.value) {
        progress.value = ready ? 1 : 0;
        detail.value = ready ? 'Supertonic 3 is geïnstalleerd' : 'Supertonic 3 is nog niet geïnstalleerd';
      }
      return ready;
    } catch (e) {
      installed.value = false;
      if (!downloading.value) detail.value = 'Status kon niet worden gecontroleerd';
      return false;
    }
  }

  Future<void> download() async {
    if (downloading.value) return;
    if (await refresh()) return;
    downloading.value = true;
    progress.value = 0;
    detail.value = 'Download voorbereiden...';
    try {
      await SupertonicTTS.preDownloadModels(
        onProgress: (done, total, file, fileProgress) {
          final safeTotal = total <= 0 ? 1 : total;
          final completedBeforeCurrent = done > 0 ? done - 1 : 0;
          progress.value = ((completedBeforeCurrent + fileProgress) / safeTotal).clamp(0.0, 1.0);
          detail.value = 'Bestand $done/$total · $file · ${(fileProgress * 100).round()}%';
        },
      );
      installed.value = await SupertonicTTS.modelsReady();
      progress.value = installed.value ? 1 : progress.value;
      detail.value = installed.value ? 'Supertonic 3 is geïnstalleerd' : 'Download niet volledig';
    } catch (e) {
      detail.value = 'Download mislukt: $e';
      rethrow;
    } finally {
      downloading.value = false;
    }
  }
}
