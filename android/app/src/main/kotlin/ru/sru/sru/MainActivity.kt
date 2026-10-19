package ru.sru.sru

import android.content.Intent
import android.net.VpnService
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import ru.sru.sru.vpn.SruVpnService
import ru.sru.sru.vpn.VpnStatusBus
import java.util.concurrent.TimeUnit

/**
 * Мост Flutter ↔ VPN. Контракт описан в lib/core/vpn/vpn_engine.dart
 * (MethodChannelVpnEngine): start/stop/coreVersion и поток статусов.
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val REQUEST_VPN = 0x5652
    }

    private var pendingIntent: Intent? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "ru.sru/vpn").setMethodCallHandler(::onMethodCall)
        EventChannel(messenger, "ru.sru/vpn/status").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                VpnStatusBus.listener = { events.success(it) }
                events.success(VpnStatusBus.current)
            }

            override fun onCancel(arguments: Any?) {
                VpnStatusBus.listener = null
            }
        })
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val config = call.argument<String>("config")
                if (config == null) {
                    result.error("ARGS", "Нет конфигурации", null)
                    return
                }
                val intent = Intent(this, SruVpnService::class.java)
                    .setAction(SruVpnService.ACTION_START)
                    .putExtra(SruVpnService.EXTRA_CONFIG, config)
                    .putExtra(SruVpnService.EXTRA_NAME, call.argument<String>("name") ?: "SRU VPN")
                val consent = VpnService.prepare(this)
                if (consent == null) {
                    launch(intent, result)
                } else {
                    // Первый запуск: система спрашивает разрешение на VPN.
                    pendingResult?.error("CANCELLED", "Запрос заменён новым", null)
                    pendingIntent = intent
                    pendingResult = result
                    @Suppress("DEPRECATION")
                    startActivityForResult(consent, REQUEST_VPN)
                }
            }
            "stop" -> {
                startService(Intent(this, SruVpnService::class.java).setAction(SruVpnService.ACTION_STOP))
                result.success(null)
            }
            "status" -> result.success(VpnStatusBus.current)
            "coreVersion" -> Thread {
                val version = try {
                    val p = ProcessBuilder(SruVpnService.coreBinary(this).path, "version").start()
                    p.waitFor(5, TimeUnit.SECONDS)
                    p.inputStream.bufferedReader().readLine()
                } catch (e: Exception) {
                    null
                }
                runOnUiThread { result.success(version) }
            }.start()
            else -> result.notImplemented()
        }
    }

    /** Ответ на start() приходит, когда ядро подключилось или упало. */
    private fun launch(intent: Intent, result: MethodChannel.Result) {
        VpnStatusBus.pendingStart = { error ->
            if (error == null) result.success(null) else result.error("VPN", error, null)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
    }

    @Deprecated("startActivityForResult нужен для VpnService.prepare")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_VPN) return
        val intent = pendingIntent
        val result = pendingResult ?: return
        pendingIntent = null
        pendingResult = null
        if (resultCode == RESULT_OK && intent != null) {
            launch(intent, result)
        } else {
            result.error("DENIED", "Разрешение на VPN не выдано", null)
        }
    }
}
