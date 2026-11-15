package dev.marchello.sharik

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.util.Size
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * Lists images / videos / audio from MediaStore so the Send screen can show them.
 * Only metadata is returned (id, name, path, size, ...); files are never copied or read here.
 */
class MediaPlugin(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "dev.marchello.sharik/media"
        private const val PERMISSION_REQUEST_CODE = 4711
        private const val MAX_ITEMS = 10000
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingPermission: MethodChannel.Result? = null
    private var pendingKind: String = "images"

    fun dispose() {
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermission" -> result.success(hasPermission(call.argument<String>("kind") ?: "images"))
            "requestPermission" -> requestPermission(call.argument<String>("kind") ?: "images", result)
            "diagnostics" -> result.success(diagnostics())
            "openAppSettings" -> {
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.fromParts("package", activity.packageName, null))
                try {
                    activity.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }
            "list" -> {
                val kind = call.argument<String>("kind")
                if (kind == null) {
                    result.error("bad_args", "kind is required", null)
                    return
                }
                runAsync(result) { list(kind) }
            }
            "thumbnail" -> {
                val kind = call.argument<String>("kind")
                val id = call.argument<Number>("id")?.toLong()
                if (kind == null || id == null) {
                    result.error("bad_args", "kind and id are required", null)
                    return
                }
                runAsync(result) { thumbnail(kind, id) }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Android 13+ replaced READ_EXTERNAL_STORAGE by one permission per media type; asking for the
     * old one there is silently denied (no dialog), which is why nothing showed up before.
     */
    private fun permissionFor(kind: String): String =
        if (Build.VERSION.SDK_INT >= 33) {
            when (kind) {
                "videos" -> "android.permission.READ_MEDIA_VIDEO"
                "audio" -> "android.permission.READ_MEDIA_AUDIO"
                else -> "android.permission.READ_MEDIA_IMAGES"
            }
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

    /** Plain-text state shown in the app when something goes wrong. */
    private fun diagnostics(): String {
        val names = if (Build.VERSION.SDK_INT >= 33) {
            listOf("READ_MEDIA_IMAGES", "READ_MEDIA_VIDEO", "READ_MEDIA_AUDIO")
        } else {
            listOf("READ_EXTERNAL_STORAGE")
        }
        val sb = StringBuilder("Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
        for (n in names) {
            val granted = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                activity.checkSelfPermission("android.permission.$n") == PackageManager.PERMISSION_GRANTED
            sb.append("\n$n: ${if (granted) "granted" else "denied"}")
        }
        try {
            @Suppress("DEPRECATION")
            val info = activity.packageManager.getPackageInfo(activity.packageName, PackageManager.GET_PERMISSIONS)
            val req = info.requestedPermissions
            val flags = info.requestedPermissionsFlags
            for (n in names) {
                val i = req?.indexOf("android.permission.$n") ?: -1
                sb.append(
                    if (i < 0) "\n$n declared: NO"
                    else "\n$n declared: yes, system flag granted: ${(flags[i] and 2) != 0}"
                )
            }
            sb.append("\ntargetSdk: ${activity.applicationInfo.targetSdkVersion}")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                sb.append("\nrationale: ${activity.shouldShowRequestPermissionRationale("android.permission.${names[0]}")}")
            }
        } catch (e: Exception) {
            sb.append("\n(diag error: ${e.message})")
        }
        return sb.toString()
    }

    private fun hasPermission(kind: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return activity.checkSelfPermission(permissionFor(kind)) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestPermission(kind: String, result: MethodChannel.Result) {
        if (hasPermission(kind)) {
            result.success(true)
            return
        }
        if (pendingPermission != null) {
            // a dialog is already on screen: never stack a second one, just report the current state
            result.success(false)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            pendingKind = kind
            pendingPermission = result
            // Ask for the whole media group in ONE request (images + videos + audio on 13+),
            // so the user is not asked again for every tab.
            val wanted = if (Build.VERSION.SDK_INT >= 33) {
                arrayOf(
                    "android.permission.READ_MEDIA_IMAGES",
                    "android.permission.READ_MEDIA_VIDEO",
                    "android.permission.READ_MEDIA_AUDIO"
                )
            } else {
                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
            }
            try {
                activity.requestPermissions(wanted, PERMISSION_REQUEST_CODE)
            } catch (e: Exception) {
                pendingPermission = null
                result.success(false)
            }
        } else {
            result.success(true)
        }
    }

    /** Called by MainActivity.onRequestPermissionsResult */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST_CODE) return
        val pending = pendingPermission
        pendingPermission = null
        // Judge by the real state, not by grantResults[0]: the answer can be mixed.
        pending?.success(hasPermission(pendingKind))
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                mainHandler.post { result.error("failed", e.message, null) }
            }
        }
    }

    private fun contentUri(kind: String): Uri = when (kind) {
        "images" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        "videos" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        else -> throw IllegalArgumentException("Unknown kind: $kind")
    }

    @Suppress("DEPRECATION")
    private fun list(kind: String): List<Map<String, Any?>> {
        val full = ArrayList<String>().apply {
            add(MediaStore.MediaColumns._ID)
            add(MediaStore.MediaColumns.DISPLAY_NAME)
            add(MediaStore.MediaColumns.DATA) // deprecated on Q+, but still readable with the media permission
            add(MediaStore.MediaColumns.SIZE)
            if (kind != "images") add(MediaStore.MediaColumns.DURATION)
            if (kind == "audio") add(MediaStore.Audio.Media.ARTIST)
        }.toTypedArray()
        val minimal = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.DATA,
            MediaStore.MediaColumns.SIZE
        )

        return try {
            query(kind, full)
        } catch (e: SecurityException) {
            throw e
        } catch (e: Exception) {
            // an optional column is missing on this device: retry with the bare minimum
            query(kind, minimal)
        }
    }

    @Suppress("DEPRECATION")
    private fun query(kind: String, projection: Array<String>): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        activity.contentResolver.query(
            contentUri(kind),
            projection,
            null,
            null,
            "${MediaStore.MediaColumns.DATE_MODIFIED} DESC"
        )?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameCol = c.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
            val dataCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA)
            val sizeCol = c.getColumnIndex(MediaStore.MediaColumns.SIZE)
            val durCol = c.getColumnIndex(MediaStore.MediaColumns.DURATION)
            val artistCol = c.getColumnIndex(MediaStore.Audio.Media.ARTIST)

            while (c.moveToNext() && out.size < MAX_ITEMS) {
                val path = c.getString(dataCol) ?: continue
                out.add(
                    mapOf(
                        "id" to c.getLong(idCol),
                        "name" to ((if (nameCol >= 0) c.getString(nameCol) else null) ?: path.substringAfterLast('/')),
                        "path" to path,
                        "size" to (if (sizeCol >= 0) c.getLong(sizeCol) else 0L),
                        "duration" to (if (durCol >= 0) c.getLong(durCol) else 0L),
                        "artist" to (if (artistCol >= 0) c.getString(artistCol) else null)
                    )
                )
            }
        }
        return out
    }

    /** JPEG bytes of a small thumbnail (used for videos; images are decoded by Flutter itself). */
    @Suppress("DEPRECATION")
    private fun thumbnail(kind: String, id: Long): ByteArray? {
        val bitmap: Bitmap? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val uri = ContentUris.withAppendedId(contentUri(kind), id)
            try {
                activity.contentResolver.loadThumbnail(uri, Size(256, 256), null)
            } catch (e: Exception) {
                null
            }
        } else if (kind == "videos") {
            MediaStore.Video.Thumbnails.getThumbnail(
                activity.contentResolver, id, MediaStore.Video.Thumbnails.MINI_KIND, null
            )
        } else {
            MediaStore.Images.Thumbnails.getThumbnail(
                activity.contentResolver, id, MediaStore.Images.Thumbnails.MINI_KIND, null
            )
        }
        if (bitmap == null) return null
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 80, stream)
        return stream.toByteArray()
    }
}
