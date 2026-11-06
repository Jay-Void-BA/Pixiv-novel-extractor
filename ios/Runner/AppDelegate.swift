import Flutter
import UIKit
import WebKit

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
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ShioriCookies") else { return }
    let channel = FlutterMethodChannel(name: "shiori/pixiv_cookies", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "getSession" else {
        result(FlutterMethodNotImplemented)
        return
      }
      WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
        let cookie = cookies.first {
          $0.name == "PHPSESSID" && ($0.domain == "pixiv.net" || $0.domain.hasSuffix(".pixiv.net"))
            && ($0.expiresDate == nil || $0.expiresDate! > Date())
        }
        result(cookie?.value)
      }
    }
  }
}
