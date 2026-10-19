package ru.sru.sru

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.net.VpnService
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import ru.sru.sru.vpn.SruVpnService
import ru.sru.sru.vpn.VpnStatusBus
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit

/**
 * Мост Flutter ↔ VPN. Контракт описан в lib/core/vpn/vpn_engine.dart
 * (MethodChannelVpnEngine): start/stop/coreVersion и поток статусов.
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val REQUEST_VPN = 0x5652
        private const val REQUEST_NOTIFICATIONS = 0x5653
        private const val ICON_SIZE = 96
    }

    private var pendingIntent: Intent? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "ru.sru/vpn").setMethodCallHandler(::onMethodCall)
        EventChannel(messenger, "ru.sru/vpn/status").setStreamHandler(object : EventChannel.StreamHandler {
            private var listener: ((String) -> Unit)? = null

            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                listener = { s: String -> events.success(s) }.also(VpnStatusBus::addListener)
                events.success(VpnStatusBus.current)
            }

            override fun onCancel(arguments: Any?) {
                listener?.let(VpnStatusBus::removeListener)
                listener = null
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
                    .putExtra(SruVpnService.EXTRA_NAME, call.argument<String>("name") ?: "SruNaZapret")
                    .putExtra(SruVpnService.EXTRA_APP_MODE, call.argument<String>("appMode") ?: "off")
                    .putStringArrayListExtra(
                        SruVpnService.EXTRA_APPS,
                        ArrayList(call.argument<List<String>>("apps") ?: emptyList()),
                    )
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
            "installedApps" -> Thread {
                val apps = installedApps()
                runOnUiThread { result.success(apps) }
            }.start()
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

    /** Приложения с иконкой в лаунчере — для экрана раздельного туннелирования. */
    private fun installedApps(): List<Map<String, Any>> {
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        val activities = packageManager.queryIntentActivities(launcher, 0)
        return activities
            .filter { it.activityInfo.packageName != packageName }
            .distinctBy { it.activityInfo.packageName }
            .map { Triple(it.activityInfo.packageName, it.loadLabel(packageManager).toString(), it) }
            .sortedBy { it.second.lowercase() }
            .map { (pkg, label, info) ->
                mapOf("package" to pkg, "label" to label, "icon" to iconPng(info.loadIcon(packageManager)))
            }
    }

    private fun iconPng(d: Drawable): ByteArray {
        val bmp = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        d.setBounds(0, 0, ICON_SIZE, ICON_SIZE)
        d.draw(canvas)
        return ByteArrayOutputStream().use { out ->
            bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
            bmp.recycle()
            out.toByteArray()
        }
    }

    /**
     * Android 13+: без разрешения уведомление VPN (с кнопкой «Отключить») скрыто.
     * Спрашиваем один раз, при первом подключении; на работу VPN ответ не влияет.
     */
    private fun askNotificationsOnce() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        val prefs = getSharedPreferences("sru", MODE_PRIVATE)
        if (prefs.getBoolean("askedNotifications", false)) return
        prefs.edit().putBoolean("askedNotifications", true).apply()
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    /** Ответ на start() приходит, когда ядро подключилось или упало. */
    private fun launch(intent: Intent, result: MethodChannel.Result) {
        askNotificationsOnce()
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
