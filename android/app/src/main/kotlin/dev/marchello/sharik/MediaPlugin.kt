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
            result.error("busy", "A permission request is already running", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            pendingKind = kind
            pendingPermission = result
            activity.requestPermissions(arrayOf(permissionFor(kind)), PERMISSION_REQUEST_CODE)
        } else {
            result.success(true)
        }
    }

    /** Called by MainActivity.onRequestPermissionsResult */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST_CODE) return
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(granted)
        pendingPermission = null
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
        if (!hasPermission(kind)) throw SecurityException("Media permission not granted")

        val projection = ArrayList<String>().apply {
            add(MediaStore.MediaColumns._ID)
            add(MediaStore.MediaColumns.DISPLAY_NAME)
            add(MediaStore.MediaColumns.DATA) // deprecated on Q+, but still readable with READ_EXTERNAL_STORAGE
            add(MediaStore.MediaColumns.SIZE)
            if (kind != "images") add(MediaStore.MediaColumns.DURATION)
            if (kind == "audio") add(MediaStore.Audio.Media.ARTIST)
        }.toTypedArray()

        val out = ArrayList<Map<String, Any?>>()
        activity.contentResolver.query(
            contentUri(kind),
            projection,
            null,
            null,
            "${MediaStore.MediaColumns.DATE_MODIFIED} DESC"
        )?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val dataCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA)
            val sizeCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val durCol = if (kind != "images") c.getColumnIndexOrThrow(MediaStore.MediaColumns.DURATION) else -1
            val artistCol = if (kind == "audio") c.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST) else -1

            while (c.moveToNext() && out.size < MAX_ITEMS) {
                val path = c.getString(dataCol) ?: continue
                out.add(
                    mapOf(
                        "id" to c.getLong(idCol),
                        "name" to (c.getString(nameCol) ?: path.substringAfterLast('/')),
                        "path" to path,
                        "size" to c.getLong(sizeCol),
                        "duration" to if (durCol >= 0) c.getLong(durCol) else 0L,
                        "artist" to if (artistCol >= 0) c.getString(artistCol) else null
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
