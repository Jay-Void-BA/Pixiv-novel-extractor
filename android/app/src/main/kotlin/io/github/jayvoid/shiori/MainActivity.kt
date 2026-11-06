package io.github.jayvoid.shiori

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.webkit.CookieManager

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiori/pixiv_cookies")
            .setMethodCallHandler { call, result ->
                if (call.method != "getSession") {
                    result.notImplemented()
                } else {
                    val cookies = CookieManager.getInstance().getCookie("https://www.pixiv.net/")
                    val session = cookies?.split(";")?.map { it.trim() }
                        ?.firstOrNull { it.startsWith("PHPSESSID=") }
                        ?.substringAfter("PHPSESSID=")
                    result.success(session)
                }
            }
    }
}
