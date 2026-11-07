package io.github.jayvoid.shiori

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.webkit.CookieManager
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val vaultExecutor = Executors.newSingleThreadExecutor()
    private var vaultChannel: MethodChannel? = null

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
        val vault = SessionVault(applicationContext)
        val main = Handler(Looper.getMainLooper())
        vaultChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiori/session_vault")
        vaultChannel!!.setMethodCallHandler { call, result ->
            if (call.method !in setOf("read", "write", "delete")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            vaultExecutor.execute {
                try {
                    val value: Any? = when (call.method) {
                        "read" -> vault.read()
                        "write" -> {
                            vault.write(call.argument<String>("session") ?: "")
                            null
                        }
                        else -> { vault.clear(); null }
                    }
                    main.post { result.success(value) }
                } catch (_: Exception) {
                    // Do not include exception text, arguments, plaintext or key material.
                    main.post { result.error("vault_unavailable", "Secure session storage unavailable", null) }
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        vaultChannel?.setMethodCallHandler(null)
        vaultExecutor.shutdown()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
