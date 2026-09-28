import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ChatterboxBridge") {
      let channel = FlutterMethodChannel(name: "portable_ai/chatterbox", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        Task { @MainActor in ChatterboxBridge.shared.handle(call, result: result) }
      }
    }
  }
}
