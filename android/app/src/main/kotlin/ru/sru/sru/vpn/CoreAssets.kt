package ru.sru.sru.vpn

import android.content.Context
import android.os.Build
import java.io.File

/**
 * geoip.dat / geosite.dat лежат в assets APK (их кладёт android/core/build.sh)
 * и копируются в файлы приложения при первом запуске и после обновления —
 * Xray читает их по пути из XRAY_LOCATION_ASSET.
 */
object CoreAssets {
    private val files = listOf("geoip.dat", "geosite.dat")

    fun ensure(context: Context): File {
        val dir = File(context.noBackupFilesDir, "geo").apply { mkdirs() }
        val stamp = File(dir, ".version")
        val version = appVersion(context)
        if (stamp.exists() && stamp.readText() == version && files.all { File(dir, it).exists() }) return dir
        for (name in files) {
            val tmp = File(dir, "$name.tmp")
            context.assets.open("geo/$name").use { input -> tmp.outputStream().use { input.copyTo(it) } }
            tmp.renameTo(File(dir, name))
        }
        stamp.writeText(version)
        return dir
    }

    private fun appVersion(context: Context): String {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        return "$code-${info.lastUpdateTime}"
    }
}
