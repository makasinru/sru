package ru.sru.sru.vpn

import android.content.Context
import android.content.Intent
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Последнее успешное подключение — чтобы плитка в шторке могла включить VPN,
 * не открывая приложение. Хранится в приватном каталоге приложения.
 */
data class LastSession(
    val config: String,
    val name: String,
    val appMode: String,
    val apps: List<String>,
    val tun: String? = null,
) {
    fun toStartIntent(context: Context): Intent = Intent(context, SruVpnService::class.java)
        .setAction(SruVpnService.ACTION_START)
        .putExtra(SruVpnService.EXTRA_CONFIG, config)
        .putExtra(SruVpnService.EXTRA_NAME, name)
        .putExtra(SruVpnService.EXTRA_APP_MODE, appMode)
        .putStringArrayListExtra(SruVpnService.EXTRA_APPS, ArrayList(apps))
        .apply { if (tun != null) putExtra(SruVpnService.EXTRA_TUN, tun) }

    fun save(context: Context) {
        val json = JSONObject()
            .put("config", config)
            .put("name", name)
            .put("appMode", appMode)
            .put("apps", JSONArray(apps))
            .put("tun", tun ?: JSONObject.NULL)
        file(context).writeText(json.toString())
    }

    companion object {
        private fun file(context: Context) = File(context.noBackupFilesDir, "last-session.json")

        fun load(context: Context): LastSession? = try {
            val j = JSONObject(file(context).readText())
            val apps = j.getJSONArray("apps")
            LastSession(
                j.getString("config"),
                j.getString("name"),
                j.getString("appMode"),
                List(apps.length()) { apps.getString(it) },
                if (j.isNull("tun")) null else j.optString("tun"),
            )
        } catch (_: Exception) {
            null
        }
    }
}
