package ru.sru.sru.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import ru.sru.sru.MainActivity
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * VPN-сервис: поднимает TUN через [VpnService.Builder] и запускает ядро
 * (Xray-core, файл libsrucore.so из android/core) отдельным процессом.
 *
 * TUN-дескриптор передаётся ядру через unix-сокет (SCM_RIGHTS), потому что
 * процессы, запущенные из Java, не наследуют файловые дескрипторы.
 * Трафик самого приложения (и ядра — у него тот же UID) исключён из VPN через
 * addDisallowedApplication, поэтому соединения ядра с сервером не зацикливаются.
 */
class SruVpnService : VpnService() {
    companion object {
        const val ACTION_START = "ru.sru.sru.vpn.START"
        const val ACTION_STOP = "ru.sru.sru.vpn.STOP"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_NAME = "name"

        private const val TAG = "SruVpn"
        private const val CHANNEL_ID = "vpn"
        private const val NOTIFICATION_ID = 1
        private const val MTU = 1500
        private const val TUN_ADDRESS = "172.19.0.1"
        private const val TUN_ADDRESS6 = "fdfe:dcba:9876::1"

        /** Внутри TUN DNS перехватывает Xray (правило port 53 → dns-out). */
        private const val TUN_DNS = "1.1.1.1"

        fun coreBinary(context: Context) = File(context.applicationInfo.nativeLibraryDir, "libsrucore.so")
    }

    private val worker = Executors.newSingleThreadExecutor()
    private var tun: ParcelFileDescriptor? = null
    private var core: Process? = null
    private var control: LocalSocket? = null

    @Volatile
    private var stopping = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val config = intent.getStringExtra(EXTRA_CONFIG)
                val name = intent.getStringExtra(EXTRA_NAME) ?: "SRU VPN"
                if (config == null) {
                    VpnStatusBus.post(VpnStatusBus.ERROR, "Нет конфигурации")
                    return START_NOT_STICKY
                }
                goForeground(name)
                VpnStatusBus.post(VpnStatusBus.CONNECTING)
                worker.execute { start(config, name) }
            }
            ACTION_STOP -> worker.execute { stop(null) }
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        // Пользователь отключил VPN в системных настройках или включил другой VPN.
        worker.execute { stop(null) }
    }

    override fun onDestroy() {
        stopInternal()
        worker.shutdownNow()
        super.onDestroy()
    }

    private fun start(config: String, name: String) {
        stopInternal()
        stopping = false
        try {
            val assetDir = CoreAssets.ensure(this)
            val tunFd = establishTun(name)
            tun = tunFd
            val dir = noBackupFilesDir
            val cfg = File(dir, "config.json").apply { writeText(config) }
            val sock = File(dir, "core.sock")
            sock.delete()

            val proc = ProcessBuilder(
                coreBinary(this).path, "run", sock.path, cfg.path, assetDir.path, systemDns(),
            ).redirectErrorStream(true).start()
            core = proc
            val log = CoreLog(proc)

            val socket = connect(sock, proc, log)
            control = socket
            socket.setFileDescriptorsForSend(arrayOf(tunFd.fileDescriptor))
            socket.outputStream.write("start\n".toByteArray())
            socket.outputStream.flush()
            socket.soTimeout = 15_000
            val answer = socket.inputStream.bufferedReader().readLine()
                ?: throw IOException("Ядро завершилось: ${log.tail()}")
            if (answer != "ok") throw IOException(answer.removePrefix("error:"))
            socket.soTimeout = 0

            // Ядро упало само — сообщаем и гасим VPN.
            Thread {
                proc.waitFor()
                // core === proc: не реагируем на выход ядра от предыдущего подключения.
                worker.execute { if (!stopping && core === proc) stop("Ядро остановилось: ${log.tail()}") }
            }.apply { isDaemon = true }.start()

            updateNotification(name)
            VpnStatusBus.post(VpnStatusBus.CONNECTED)
        } catch (e: Exception) {
            Log.e(TAG, "start failed", e)
            stop(e.message ?: e.toString())
        }
    }

    private fun establishTun(name: String): ParcelFileDescriptor {
        val builder = Builder()
            .setSession(name)
            .setMtu(MTU)
            .addAddress(TUN_ADDRESS, 30)
            .addRoute("0.0.0.0", 0)
            .addAddress(TUN_ADDRESS6, 126)
            .addRoute("::", 0)
            .addDnsServer(TUN_DNS)
            .addDisallowedApplication(packageName)
            .setConfigureIntent(openAppIntent())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
        return builder.establish() ?: throw IOException("Нет разрешения на VPN")
    }

    /** DNS-серверы физической сети — нужны ядру, чтобы найти адрес VPN-сервера. */
    private fun systemDns(): String {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return ""
        val network = cm.activeNetwork ?: return ""
        val props = cm.getLinkProperties(network) ?: return ""
        return props.dnsServers.mapNotNull { it.hostAddress }.joinToString(",")
    }

    private fun connect(sock: File, proc: Process, log: CoreLog): LocalSocket {
        val deadline = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < deadline) {
            if (!proc.isAlive) throw IOException("Ядро не запустилось: ${log.tail()}")
            if (sock.exists()) {
                val s = LocalSocket()
                try {
                    s.connect(LocalSocketAddress(sock.path, LocalSocketAddress.Namespace.FILESYSTEM))
                    return s
                } catch (e: IOException) {
                    s.close()
                }
            }
            Thread.sleep(50)
        }
        throw IOException("Ядро не отвечает: ${log.tail()}")
    }

    private fun stop(error: String?) {
        stopInternal()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
        if (error != null) {
            VpnStatusBus.post(VpnStatusBus.ERROR, error)
        } else {
            VpnStatusBus.post(VpnStatusBus.DISCONNECTED)
        }
    }

    private fun stopInternal() {
        stopping = true
        try {
            control?.close() // ядро видит закрытие сокета и выходит само
        } catch (_: IOException) {
        }
        control = null
        core?.let { p ->
            if (!p.waitFor(2, TimeUnit.SECONDS)) p.destroy()
        }
        core = null
        try {
            tun?.close()
        } catch (_: IOException) {
        }
        tun = null
    }

    // ---------- уведомление ----------

    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
    )

    private fun notification(title: String, text: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "VPN", NotificationManager.IMPORTANCE_LOW),
            )
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val stopIntent = PendingIntent.getService(
            this, 1, Intent(this, SruVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return builder
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(openAppIntent())
            .addAction(Notification.Action.Builder(null, "Отключить", stopIntent).build())
            .build()
    }

    private fun goForeground(name: String) {
        val n = notification(name, "Подключение…")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun updateNotification(name: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, notification(name, "Подключено"))
    }
}

/** Последние строки вывода ядра — для понятных сообщений об ошибках и logcat. */
private class CoreLog(proc: Process) {
    private val lines = ArrayDeque<String>()

    init {
        Thread {
            proc.inputStream.bufferedReader().forEachLine { line ->
                Log.i("SruCore", line)
                synchronized(lines) {
                    lines.addLast(line)
                    if (lines.size > 20) lines.removeFirst()
                }
            }
        }.apply { isDaemon = true }.start()
    }

    fun tail(): String = synchronized(lines) { lines.takeLast(3).joinToString(" | ") }
}
