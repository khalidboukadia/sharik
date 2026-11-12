package dev.marchello.sharik

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Everything Sharik needs to get two phones onto the same network, SHAREit style:
 *  - sender: start a local-only hotspot (SSID + password for the QR code), or open the
 *    system Wi-Fi / hotspot / location settings
 *  - receiver: join the sender's network from the scanned / pasted code
 */
class WifiPlugin(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "dev.marchello.sharik/wifi"
        private const val PERMISSION_REQUEST_CODE = 4712
    }

    private val context: Context = activity.applicationContext
    private val wifiManager = context.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val connectivity =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var joinCallback: ConnectivityManager.NetworkCallback? = null

    fun dispose() {
        stopHotspot()
        leaveWifi()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasLocationPermission" -> result.success(hasLocationPermission())
            "requestLocationPermission" -> requestLocationPermission(result)
            "isLocationEnabled" -> result.success(isLocationEnabled())
            "startHotspot" -> startHotspot(result)
            "stopHotspot" -> {
                stopHotspot()
                result.success(null)
            }
            "openSettings" -> result.success(openSettings(call.argument<String>("kind") ?: "wifi"))
            "joinWifi" -> {
                val ssid = call.argument<String>("ssid")
                if (ssid == null) {
                    result.error("bad_args", "ssid is required", null)
                    return
                }
                joinWifi(ssid, call.argument<String>("password"), result)
            }
            "leaveWifi" -> {
                leaveWifi()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------- permissions

    private fun hasLocationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestLocationPermission(result: MethodChannel.Result) {
        if (hasLocationPermission() || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(true)
            return
        }
        if (pendingPermission != null) {
            result.error("busy", "A permission request is already running", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            pendingPermission = result
            activity.requestPermissions(
                arrayOf(Manifest.permission.ACCESS_FINE_LOCATION),
                PERMISSION_REQUEST_CODE
            )
        }
    }

    /** Called by MainActivity.onRequestPermissionsResult */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST_CODE) return
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(granted)
        pendingPermission = null
    }

    @Suppress("DEPRECATION")
    private fun isLocationEnabled(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            (context.getSystemService(Context.LOCATION_SERVICE) as LocationManager).isLocationEnabled
        } else {
            Settings.Secure.getInt(
                context.contentResolver, Settings.Secure.LOCATION_MODE, Settings.Secure.LOCATION_MODE_OFF
            ) != Settings.Secure.LOCATION_MODE_OFF
        }
    }

    // ---------------------------------------------------------------- hotspot (sender)

    @Suppress("DEPRECATION")
    private fun startHotspot(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("unsupported", "Local-only hotspot needs Android 8.0+", null)
            return
        }
        if (!hasLocationPermission()) {
            result.error("permission", "Location permission is required", null)
            return
        }
        if (!isLocationEnabled()) {
            result.error("location_off", "Location services are off", null)
            return
        }

        stopHotspot()

        var answered = false
        fun answerOnce(block: () -> Unit) {
            if (answered) return
            answered = true
            block()
        }

        try {
            wifiManager.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(res: WifiManager.LocalOnlyHotspotReservation) {
                    reservation = res
                    val ssid: String?
                    val pass: String?
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val c = res.softApConfiguration
                        ssid = c.ssid
                        pass = c.passphrase
                    } else {
                        val c = res.wifiConfiguration
                        ssid = c?.SSID?.trim('"')
                        pass = c?.preSharedKey?.trim('"')
                    }
                    answerOnce {
                        if (ssid == null) {
                            result.error("hotspot_failed", "No SSID reported", null)
                        } else {
                            result.success(mapOf("ssid" to ssid, "password" to (pass ?: "")))
                        }
                    }
                }

                override fun onStopped() {
                    reservation = null
                }

                override fun onFailed(reason: Int) {
                    answerOnce { result.error("hotspot_failed", "reason=$reason", reason) }
                }
            }, mainHandler)
        } catch (e: SecurityException) {
            answerOnce { result.error("permission", e.message, null) }
        } catch (e: IllegalStateException) {
            answerOnce { result.error("hotspot_failed", e.message, null) }
        }
    }

    private fun stopHotspot() {
        try {
            reservation?.close()
        } catch (ignored: Exception) {
        }
        reservation = null
    }

    // ---------------------------------------------------------------- settings

    private fun openSettings(kind: String): Boolean {
        fun start(intent: Intent): Boolean = try {
            activity.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        } catch (e: SecurityException) {
            false
        }

        return when (kind) {
            "wifi" -> start(Intent(Settings.ACTION_WIFI_SETTINGS))
            "location" -> start(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
            "hotspot" ->
                // not a public API: works on most AOSP-like ROMs, otherwise fall back
                start(
                    Intent().setClassName(
                        "com.android.settings",
                        "com.android.settings.TetherSettings"
                    )
                ) || start(Intent(Settings.ACTION_WIRELESS_SETTINGS))
            else -> false
        }
    }

    // ---------------------------------------------------------------- join (receiver)

    @Suppress("DEPRECATION")
    private fun joinWifi(ssid: String, password: String?, result: MethodChannel.Result) {
        leaveWifi()

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // Android 9 and below: classic (deprecated) API, still works there
            try {
                val config = WifiConfiguration().apply {
                    SSID = "\"$ssid\""
                    if (password.isNullOrEmpty()) {
                        allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE)
                    } else {
                        preSharedKey = "\"$password\""
                    }
                }
                wifiManager.isWifiEnabled = true
                val id = wifiManager.addNetwork(config)
                if (id == -1) {
                    result.error("join_failed", "addNetwork failed", null)
                    return
                }
                wifiManager.disconnect()
                wifiManager.enableNetwork(id, true)
                wifiManager.reconnect()
                result.success(true)
            } catch (e: SecurityException) {
                result.error("join_failed", e.message, null)
            }
            return
        }

        // Android 10+: a network request only this app uses. The system asks the user to confirm.
        val specifier = WifiNetworkSpecifier.Builder().apply {
            setSsid(ssid)
            if (!password.isNullOrEmpty()) setWpa2Passphrase(password)
        }.build()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        var answered = false
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // make this app's sockets (Dart's dart:io too) use the new network
                connectivity.bindProcessToNetwork(network)
                if (!answered) {
                    answered = true
                    mainHandler.post { result.success(true) }
                }
            }

            override fun onUnavailable() {
                if (!answered) {
                    answered = true
                    mainHandler.post { result.error("join_failed", "Network unavailable or refused", null) }
                }
            }

            override fun onLost(network: Network) {
                connectivity.bindProcessToNetwork(null)
            }
        }

        joinCallback = callback
        try {
            connectivity.requestNetwork(request, callback)
        } catch (e: Exception) {
            joinCallback = null
            answered = true
            result.error("join_failed", e.message, null)
        }
    }

    private fun leaveWifi() {
        joinCallback?.let {
            try {
                connectivity.unregisterNetworkCallback(it)
            } catch (ignored: Exception) {
            }
        }
        joinCallback = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            connectivity.bindProcessToNetwork(null)
        }
    }
}
