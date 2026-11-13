package dev.marchello.sharik

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Environment
import android.content.ContentValues
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Bridges Flutter with the Android APIs needed to share installed apps:
 *  - getAppPackage: base APK + every split APK of an installed app (paths only, nothing is copied)
 *  - getAppSizes:   total size (base + splits) for many packages at once
 *  - install:       installs a directory of APK files as ONE PackageInstaller session
 */
class AppPackagePlugin(private val context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "dev.marchello.sharik/app_package"
        private const val ACTION_INSTALL_RESULT = "dev.marchello.sharik.INSTALL_RESULT"
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingInstalls = ConcurrentHashMap<Int, MethodChannel.Result>()
    private var registered = false

    private val installReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
            val sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)

            if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                // The system needs the user to confirm the installation.
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirm != null) {
                    confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    ctx.startActivity(confirm)
                }
                return
            }

            val result = pendingInstalls.remove(sessionId) ?: return
            result.success(
                mapOf(
                    "success" to (status == PackageInstaller.STATUS_SUCCESS),
                    "status" to status,
                    "message" to (intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "")
                )
            )
        }
    }

    fun register() {
        if (registered) return
        context.registerReceiver(installReceiver, IntentFilter(ACTION_INSTALL_RESULT))
        registered = true
    }

    fun dispose() {
        if (registered) {
            try {
                context.unregisterReceiver(installReceiver)
            } catch (ignored: IllegalArgumentException) {
            }
            registered = false
        }
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getAppPackage" -> {
                val pkg = call.argument<String>("packageName")
                if (pkg == null) {
                    result.error("bad_args", "packageName is required", null)
                    return
                }
                runAsync(result) { describePackage(pkg) }
            }
            "getAppSizes" -> {
                val pkgs = call.argument<List<String>>("packages") ?: emptyList()
                runAsync(result) {
                    val sizes = HashMap<String, Long>()
                    for (p in pkgs) {
                        try {
                            sizes[p] = apkFiles(context.packageManager.getApplicationInfo(p, 0)).sumOf { it.length() }
                        } catch (ignored: Exception) {
                        }
                    }
                    sizes
                }
            }
            "receiveDir" -> {
                val dir = (context.getExternalFilesDir(null) ?: context.filesDir)
                result.success(File(dir, "incoming").apply { mkdirs() }.absolutePath)
            }
            "deviceName" -> {
                val name = try {
                    Settings.Global.getString(context.contentResolver, "device_name")
                } catch (e: Exception) {
                    null
                }
                result.success(if (name.isNullOrBlank()) Build.MODEL else name)
            }
            "saveToDownloads" -> {
                val paths = call.argument<List<String>>("paths") ?: emptyList()
                runAsync(result) { saveToDownloads(paths) }
            }
            "install" -> {
                val dir = call.argument<String>("dir")
                val pkg = call.argument<String>("packageName")
                if (dir == null || pkg == null) {
                    result.error("bad_args", "dir and packageName are required", null)
                    return
                }
                install(dir, pkg, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: PackageManager.NameNotFoundException) {
                mainHandler.post { result.error("not_installed", e.message, null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("failed", e.message, null) }
            }
        }
    }

    private fun apkFiles(info: android.content.pm.ApplicationInfo): List<File> {
        val files = ArrayList<File>()
        files.add(File(info.sourceDir)) // base APK always first
        info.splitSourceDirs?.forEach { files.add(File(it)) }
        return files
    }

    private fun describePackage(pkg: String): Map<String, Any?> {
        val pm = context.packageManager
        val appInfo = pm.getApplicationInfo(pkg, 0)
        val pkgInfo = pm.getPackageInfo(pkg, 0)
        val files = apkFiles(appInfo)

        val versionCode: Long =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) pkgInfo.longVersionCode
            else @Suppress("DEPRECATION") pkgInfo.versionCode.toLong()

        return mapOf(
            "packageName" to pkg,
            "appName" to pm.getApplicationLabel(appInfo).toString(),
            "versionName" to (pkgInfo.versionName ?: ""),
            "versionCode" to versionCode,
            "files" to files.map {
                mapOf("name" to it.name, "path" to it.absolutePath, "size" to it.length())
            }
        )
    }

    /** Copies received files into Downloads/Sharik. Returns how many were saved. */
    @Suppress("DEPRECATION")
    private fun saveToDownloads(paths: List<String>): Int {
        var saved = 0
        for (path in paths) {
            val src = File(path)
            if (!src.isFile) continue

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, src.name)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/SharKhalid")
                }
                val resolver = context.contentResolver
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: continue
                resolver.openOutputStream(uri)?.use { out ->
                    FileInputStream(src).use { it.copyTo(out, 64 * 1024) }
                    saved++
                }
            } else {
                // Android 9 and below: plain file copy (needs the storage permission to be granted)
                val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "SharKhalid")
                if (dir.isDirectory || dir.mkdirs()) {
                    src.copyTo(File(dir, src.name), overwrite = true)
                    saved++
                }
            }
        }
        return saved
    }

    private fun install(dir: String, pkg: String, result: MethodChannel.Result) {
        executor.execute {
            val installer = context.packageManager.packageInstaller
            var sessionId = -1
            var session: PackageInstaller.Session? = null
            try {
                val apks = File(dir).listFiles { f -> f.isFile && f.name.endsWith(".apk") }
                    ?.sortedBy { it.name }
                    ?: emptyList()
                if (apks.isEmpty()) throw IllegalStateException("No APK files in $dir")

                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                params.setAppPackageName(pkg)

                sessionId = installer.createSession(params)
                val s = installer.openSession(sessionId)
                session = s

                // Stream every file straight into the session (no full-file buffering in RAM)
                for (apk in apks) {
                    FileInputStream(apk).use { input ->
                        s.openWrite(apk.name, 0, apk.length()).use { out ->
                            input.copyTo(out, 64 * 1024)
                            s.fsync(out)
                        }
                    }
                }

                pendingInstalls[sessionId] = result

                val intent = Intent(ACTION_INSTALL_RESULT).setPackage(context.packageName)
                var flags = PendingIntent.FLAG_UPDATE_CURRENT
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    // The system must be able to add extras to this intent.
                    flags = flags or PendingIntent.FLAG_MUTABLE
                }
                val pending = PendingIntent.getBroadcast(context, sessionId, intent, flags)
                s.commit(pending.intentSender)
            } catch (e: Exception) {
                pendingInstalls.remove(sessionId)
                try {
                    session?.abandon()
                } catch (ignored: Exception) {
                }
                mainHandler.post { result.error("install_failed", e.message, null) }
            } finally {
                try {
                    session?.close()
                } catch (ignored: Exception) {
                }
            }
        }
    }
}
