package com.skillcraft.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.concurrent.thread

/**
 * Device services for SkillCraft over `skillcraft/device`:
 *  - appVersion(): versionName / versionCode from the installed package.
 *  - startRun({label}) / stopRun(): RunService (foreground service + wake
 *    lock) for the duration of a skill run; its notification's Stop arrives
 *    in Dart as an incoming "stopRequested" call.
 *  - ensureNotificationPermission(), isBatteryExempt(),
 *    requestBatteryExemption(): Android 13+ notifications and the system's
 *    "ignore battery optimisations" dialog.
 *  - setKeepScreenOn(bool): keeps the app on screen during agent runs; Android
 *    moves off-screen apps to slower cores (~3x slower inference measured).
 *  - importDocument({dest}): system file picker, streamed straight to `dest`
 *    (no intermediate cache copy, which matters for 1 GB model files).
 * Import progress is sent on the `skillcraft/import_progress` event channel.
 */
class MainActivity : FlutterActivity() {
    private var pendingImport: MethodChannel.Result? = null
    private var pendingDest: String? = null
    private var progressSink: EventChannel.EventSink? = null
    private var pendingNotificationPermission: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        val device = MethodChannel(messenger, "skillcraft/device")
        RunService.onStopRequested = { main.post { device.invokeMethod("stopRequested", null) } }
        device.setMethodCallHandler { call, result ->
            when (call.method) {
                "startRun" -> {
                    RunService.start(this, call.argument<String>("label") ?: "a skill")
                    result.success(null)
                }
                "stopRun" -> {
                    RunService.stop(this)
                    result.success(null)
                }
                "ensureNotificationPermission" -> {
                    if (android.os.Build.VERSION.SDK_INT < 33 ||
                        checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                        android.content.pm.PackageManager.PERMISSION_GRANTED
                    ) {
                        result.success(true)
                    } else {
                        pendingNotificationPermission = result
                        requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), NOTIFY_REQUEST)
                    }
                }
                "isBatteryExempt" -> {
                    val pm = getSystemService(POWER_SERVICE) as android.os.PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }
                "requestBatteryExemption" -> {
                    // Allowed for sideloaded apps; shows the system's own dialog.
                    @Suppress("BatteryLife")
                    val intent = Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                        .setData(Uri.parse("package:$packageName"))
                    startActivity(intent)
                    result.success(null)
                }
                "appVersion" -> {
                    val info = packageManager.getPackageInfo(packageName, 0)
                    @Suppress("DEPRECATION")
                    val code = if (android.os.Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
                    result.success(mapOf("name" to info.versionName, "code" to code))
                }
                "setKeepScreenOn" -> {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                "importDocument" -> {
                    if (pendingImport != null) {
                        result.error("busy", "An import is already running", null)
                        return@setMethodCallHandler
                    }
                    val dest = call.argument<String>("dest")
                    if (dest == null) {
                        result.error("args", "dest is required", null)
                        return@setMethodCallHandler
                    }
                    pendingImport = result
                    pendingDest = dest
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                    }
                    startActivityForResult(intent, IMPORT_REQUEST)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "skillcraft/import_progress").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    progressSink = events
                }

                override fun onCancel(arguments: Any?) {
                    progressSink = null
                }
            },
        )
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != IMPORT_REQUEST) return
        val result = pendingImport ?: return
        val dest = pendingDest!!
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            finishImport { result.success(null) } // cancelled
            return
        }
        val (name, size) = describe(uri)
        thread(name = "model-import") {
            val tmp = File("$dest.part")
            try {
                tmp.parentFile?.mkdirs()
                var copied = 0L
                var lastReport = 0L
                contentResolver.openInputStream(uri)!!.use { input ->
                    tmp.outputStream().use { output ->
                        val buf = ByteArray(1 shl 20)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            output.write(buf, 0, n)
                            copied += n
                            if (copied - lastReport >= (8 shl 20)) {
                                lastReport = copied
                                val done = copied
                                main.post { progressSink?.success(mapOf("copied" to done, "total" to size)) }
                            }
                        }
                    }
                }
                val target = File(dest)
                target.delete()
                if (!tmp.renameTo(target)) throw IllegalStateException("could not move into place")
                val bytes = copied
                finishImport { result.success(mapOf("name" to name, "bytes" to bytes)) }
            } catch (e: Exception) {
                tmp.delete()
                finishImport { result.error("io", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun finishImport(reply: () -> Unit) {
        main.post {
            pendingImport = null
            pendingDest = null
            reply()
        }
    }

    private fun describe(uri: Uri): Pair<String, Long> {
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val nameIdx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIdx = c.getColumnIndex(OpenableColumns.SIZE)
                val name = if (nameIdx >= 0) c.getString(nameIdx) else "model.gguf"
                val size = if (sizeIdx >= 0 && !c.isNull(sizeIdx)) c.getLong(sizeIdx) else -1L
                return name to size
            }
        }
        return "model.gguf" to -1L
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFY_REQUEST) return
        val granted = grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED
        pendingNotificationPermission?.success(granted)
        pendingNotificationPermission = null
    }

    override fun onDestroy() {
        RunService.onStopRequested = null
        super.onDestroy()
    }

    companion object {
        private const val IMPORT_REQUEST = 4207
        private const val NOTIFY_REQUEST = 4208
    }
}
