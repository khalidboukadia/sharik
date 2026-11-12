package dev.marchello.sharik

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent.FLAG_ACTIVITY_NEW_TASK

class MainActivity: FlutterActivity() {
    private var appPackagePlugin: AppPackagePlugin? = null
    private var mediaPlugin: MediaPlugin? = null
    private var wifiPlugin: WifiPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val plugin = AppPackagePlugin(applicationContext)
        plugin.register()
        appPackagePlugin = plugin
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AppPackagePlugin.CHANNEL)
            .setMethodCallHandler(plugin)

        val media = MediaPlugin(this)
        mediaPlugin = media
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MediaPlugin.CHANNEL)
            .setMethodCallHandler(media)

        val wifi = WifiPlugin(this)
        wifiPlugin = wifi
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WifiPlugin.CHANNEL)
            .setMethodCallHandler(wifi)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        mediaPlugin?.onRequestPermissionsResult(requestCode, grantResults)
        wifiPlugin?.onRequestPermissionsResult(requestCode, grantResults)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        appPackagePlugin?.dispose()
        appPackagePlugin = null
        mediaPlugin?.dispose()
        mediaPlugin = null
        wifiPlugin?.dispose()
        wifiPlugin = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        if (intent.getIntExtra("org.chromium.chrome.extra.TASK_ID", -1) == this.taskId) {
            this.finish()
            intent.addFlags(FLAG_ACTIVITY_NEW_TASK);
            startActivity(intent);
        }
        super.onCreate(savedInstanceState)
    }
}
