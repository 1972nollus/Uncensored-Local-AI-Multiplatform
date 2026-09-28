import Foundation
import Flutter
import AVFoundation
import ChatterboxCoreML

/// Native, opt-in, entirely on-device Chatterbox multilingual voice.
@MainActor
final class ChatterboxBridge {
    static let shared = ChatterboxBridge()
    private var model: ChatterboxCoreMLModel?
    private var player: AVAudioPlayer?
    private var busy = false
    private let repo = ModelRepository.Variant.multilingual

    private var home: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chatterbox", isDirectory: true)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "status":
            let dir = ModelRepository.existingModelDirectory(hfHome: home, repoId: repo.repoId)
            result(["downloaded": dir != nil, "loaded": model != nil, "busy": busy])
        case "download":
            guard !busy else { result(FlutterError(code: "busy", message: "Chatterbox is busy", details: nil)); return }
            busy = true
            Task {
                defer { busy = false }
                do {
                    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                    let snapshot = try await ModelRepository.download(
                        repoId: repo.repoId, hfHome: home, matching: repo.inferenceGlobs)
                    guard !snapshot.isPartiallyApplied && snapshot.stillStale.isEmpty else {
                        throw NSError(domain: "Chatterbox", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Incomplete download. Retry."])
                    }
                    result(true)
                } catch {
                    result(FlutterError(code: "download", message: error.localizedDescription, details: nil))
                }
            }
        case "load":
            guard !busy else { result(FlutterError(code: "busy", message: "Chatterbox is busy", details: nil)); return }
            busy = true
            Task {
                defer { busy = false }
                do {
                    guard let dir = ModelRepository.existingModelDirectory(hfHome: home, repoId: repo.repoId) else {
                        throw NSError(domain: "Chatterbox", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Download Chatterbox first."])
                    }
                    model = try await ChatterboxCoreMLModel.load(from: dir)
                    result(true)
                } catch {
                    model = nil
                    result(FlutterError(code: "load", message: error.localizedDescription, details: nil))
                }
            }
        case "speak":
            guard !busy, let model else {
                result(FlutterError(code: "notReady", message: "Load Chatterbox first.", details: nil))
                return
            }
            guard let args = call.arguments as? [String: Any],
                  let text = args["text"] as? String,
                  let language = args["language"] as? String else {
                result(FlutterError(code: "arguments", message: "Missing text/language", details: nil))
                return
            }
            let exaggeration = (args["exaggeration"] as? Double ?? 0.7).clamped(to: 0.25...1.5)
            busy = true
            Task {
                defer { busy = false }
                do {
                    let options = GenerationOptions.multilingual(
                        language: language, exaggeration: exaggeration, cfgWeight: 0.5)
                    let audio = try await model.generate(text, options: options)
                    let file = FileManager.default.temporaryDirectory
                        .appendingPathComponent("chatterbox-preview.caf")
                    try? FileManager.default.removeItem(at: file)
                    let writer = try AVAudioFile(forWriting: file,
                        settings: audio.format.settings)
                    try writer.write(from: audio)
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default,
                        options: [.defaultToSpeaker])
                    try AVAudioSession.sharedInstance().setActive(true)
                    player = try AVAudioPlayer(contentsOf: file)
                    player?.play()
                    while player?.isPlaying == true {
                        try await Task.sleep(for: .milliseconds(150))
                    }
                    result(true)
                } catch {
                    result(FlutterError(code: "speak", message: error.localizedDescription, details: nil))
                }
            }
        case "stop":
            player?.stop()
            result(true)
        case "unload":
            player?.stop()
            model = nil
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
