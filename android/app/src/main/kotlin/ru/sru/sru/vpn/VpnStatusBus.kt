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

    /** Подписчики (EventChannel Flutter, плитка в шторке): "connected" или "error:<текст>". */
    private val listeners = mutableSetOf<(String) -> Unit>()

    fun addListener(l: (String) -> Unit) = main.post { listeners.add(l) }

    fun removeListener(l: (String) -> Unit) = main.post { listeners.remove(l) }

    /** Ожидающий ответа вызов start() из Flutter: (ошибка или null). */
    var pendingStart: ((String?) -> Unit)? = null

    fun post(status: String, error: String? = null) {
        current = status
        main.post {
            val event = if (status == ERROR) "error:${error ?: "неизвестная ошибка"}" else status
            listeners.toList().forEach { it(event) }
            when (status) {
                CONNECTED -> pendingStart?.invoke(null).also { pendingStart = null }
                ERROR, DISCONNECTED -> pendingStart?.invoke(error ?: "VPN отключён").also { pendingStart = null }
            }
        }
    }
}
