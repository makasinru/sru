package ru.sru.sru.vpn

import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import ru.sru.sru.MainActivity

/**
 * Плитка в шторке быстрых настроек: включает последнее подключение и выключает VPN.
 * Если разрешения на VPN ещё нет или подключений не было — открывает приложение.
 */
class SruTileService : TileService() {
    private val listener: (String) -> Unit = { update() }

    override fun onStartListening() {
        super.onStartListening()
        VpnStatusBus.addListener(listener)
        update()
    }

    override fun onStopListening() {
        VpnStatusBus.removeListener(listener)
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        when (VpnStatusBus.current) {
            VpnStatusBus.CONNECTED, VpnStatusBus.CONNECTING ->
                startService(Intent(this, SruVpnService::class.java).setAction(SruVpnService.ACTION_STOP))
            else -> {
                val last = LastSession.load(this)
                if (last == null || VpnService.prepare(this) != null) {
                    openApp()
                    return
                }
                val intent = last.toStartIntent(this)
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                } catch (_: Exception) {
                    // Система не дала запустить сервис из фона — подключимся из приложения.
                    openApp()
                }
            }
        }
    }

    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(intent)
        }
    }

    private fun update() {
        val tile = qsTile ?: return
        tile.state = when (VpnStatusBus.current) {
            VpnStatusBus.CONNECTED, VpnStatusBus.CONNECTING -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        tile.label = "SruNaZapret"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = when (VpnStatusBus.current) {
                VpnStatusBus.CONNECTED -> "Подключено"
                VpnStatusBus.CONNECTING -> "Подключение…"
                else -> "Выключено"
            }
        }
        tile.updateTile()
    }
}
