package ru.sru.sru.vpn

import android.os.Handler
import android.os.Looper

/**
 * Состояние VPN внутри процесса: сервис публикует, Flutter-канал слушает.
 * Значения совпадают с VpnStatus в lib/core/vpn/vpn_engine.dart.
 */
object VpnStatusBus {
    const val DISCONNECTED = "disconnected"
    const val CONNECTING = "connecting"
    const val CONNECTED = "connected"
    const val ERROR = "error"

    private val main = Handler(Looper.getMainLooper())

    @Volatile
    var current: String = DISCONNECTED
        private set

    /** Событие для EventChannel: "connected" или "error:<текст>". */
    var listener: ((String) -> Unit)? = null

    /** Ожидающий ответа вызов start() из Flutter: (ошибка или null). */
    var pendingStart: ((String?) -> Unit)? = null

    fun post(status: String, error: String? = null) {
        current = status
        main.post {
            listener?.invoke(if (status == ERROR) "error:${error ?: "неизвестная ошибка"}" else status)
            when (status) {
                CONNECTED -> pendingStart?.invoke(null).also { pendingStart = null }
                ERROR, DISCONNECTED -> pendingStart?.invoke(error ?: "VPN отключён").also { pendingStart = null }
            }
        }
    }
}
