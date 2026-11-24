package com.example.ros_tester

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    // Android drops incoming multicast on Wi-Fi unless an app holds this lock; ROS 2 (DDS) discovery
    // depends on multicast, so the direct connection holds it while connected.
    private var multicastLock: WifiManager.MulticastLock? = null
    private var links: MethodChannel? = null
    // A file the person is choosing a place for (Android's "save as"): its bytes and the call to answer.
    private var pendingSave: Pair<ByteArray, MethodChannel.Result>? = null
    private val saveRequest = 4207

    /** An approval link (https://mobile-ros.com/link/...) that opened or reached the app; others are ignored. */
    private fun approvalLink(intent: Intent?): String? {
        val uri = intent?.takeIf { it.action == Intent.ACTION_VIEW }?.data ?: return null
        return if (uri.scheme == "https" && uri.host == "mobile-ros.com" && uri.path?.startsWith("/link/") == true)
            uri.toString() else null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        links = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mobile_ros/links").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "initialLink") result.success(approvalLink(intent)) else result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mobile_ros/files").setMethodCallHandler { call, result ->
            if (call.method != "saveAs") return@setMethodCallHandler result.notImplemented()
            val bytes = call.argument<ByteArray>("bytes")
            val name = call.argument<String>("name") ?: "file"
            if (bytes == null) return@setMethodCallHandler result.error("args", "no bytes", null)
            pendingSave?.second?.success(false) // a second request replaces an unanswered one
            pendingSave = bytes to result
            val pick = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = call.argument<String>("mime") ?: "application/octet-stream"
                putExtra(Intent.EXTRA_TITLE, name)
            }
            try {
                startActivityForResult(pick, saveRequest)
            } catch (e: Exception) {
                pendingSave = null
                result.error("unavailable", e.message, null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mobile_ros/network").setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticast" -> {
                    if (multicastLock == null) {
                        // Devices without Wi-Fi have no WifiManager: discovery then relies on other networks.
                        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                        if (wifi == null) { result.success(false); return@setMethodCallHandler }
                        multicastLock = wifi.createMulticastLock("mobile_ros_dds").apply {
                            setReferenceCounted(false)
                            acquire()
                        }
                    }
                    result.success(true)
                }
                "releaseMulticast" -> {
                    multicastLock?.release()
                    multicastLock = null
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != saveRequest) return
        val (bytes, result) = pendingSave ?: return
        pendingSave = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) return result.success(false)
        Executors.newSingleThreadExecutor().execute {
            val ok = try {
                contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) } != null
            } catch (e: Exception) {
                false
            }
            runOnUiThread { result.success(ok) }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        approvalLink(intent)?.let { links?.invokeMethod("link", it) }
    }

    override fun onDestroy() {
        multicastLock?.release()
        multicastLock = null
        super.onDestroy()
    }
}
