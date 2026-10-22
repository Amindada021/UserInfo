package com.amindada021.userinfo

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream

// SAF provides an InputStream directly from the selected document, without copying
// a 2 GB file to app cache. Only one stream may be open at once.
class MainActivity : FlutterActivity() {
    private val channelName = "userinfo/csv_stream"
    private val requestCode = 8612
    private var pendingPicker: MethodChannel.Result? = null
    private var currentStream: InputStream? = null
    private val ioExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "pick" -> {
                    if (pendingPicker != null) {
                        result.error("BUSY", "Document picker is already open", null)
                    } else {
                        pendingPicker = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        }
                        startActivityForResult(intent, requestCode)
                    }
                }
                "protectImport" -> {
                    try {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        if (enabled) {
                            val intent = Intent(this, ImportForegroundService::class.java)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            if (Build.VERSION.SDK_INT >= 33 &&
                                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 8613)
                            }
                        } else {
                            stopService(Intent(this, ImportForegroundService::class.java))
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("FOREGROUND_IMPORT_FAILED", e.message, null)
                    }
                }
                "importProgress" -> {
                    try {
                        val intent = Intent(this, ImportForegroundService::class.java)
                        intent.action = ImportForegroundService.ACTION_PROGRESS
                        intent.putExtra("fileIndex", call.argument<Int>("fileIndex") ?: 0)
                        intent.putExtra("fileCount", call.argument<Int>("fileCount") ?: 0)
                        intent.putExtra("percent", call.argument<Int>("percent") ?: -1)
                        startService(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        // A notification failure must never affect a CSV transaction.
                        result.success(false)
                    }
                }
                "open" -> {
                    try {
                        currentStream?.close()
                        val uri = Uri.parse(call.argument<String>("uri") ?: error("Missing URI"))
                        currentStream = contentResolver.openInputStream(uri)
                            ?: error("Cannot open selected document")
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_FAILED", e.message, null)
                    }
                }
                "read" -> {
                    ioExecutor.execute {
                        try {
                            val stream = currentStream ?: error("No input stream")
                            val buffer = ByteArray(256 * 1024)
                            val count = stream.read(buffer)
                            runOnUiThread {
                                result.success(if (count < 0) null else buffer.copyOf(count))
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("READ_FAILED", e.message, null) }
                        }
                    }
                }
                "pdfFont" -> {
                    val paths = listOf(
                        "/system/fonts/NotoNaskhArabic-Regular.ttf",
                        "/system/fonts/NotoNaskhArabicUI-Regular.ttf",
                        "/system/fonts/NotoSansArabic-Regular.ttf",
                        "/system/fonts/NotoSansArabicUI-Regular.ttf"
                    )
                    val font = paths.map { java.io.File(it) }.firstOrNull { it.canRead() }
                    result.success(font?.readBytes())
                }
                "close" -> {
                    try { currentStream?.close() } finally { currentStream = null }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated API is used for compatibility with FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != this.requestCode) return
        val callback = pendingPicker ?: return
        pendingPicker = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            callback.success(emptyList<Map<String, Any?>>())
            return
        }
        try {
            val uris = mutableListOf<Uri>()
            data.clipData?.let { clip ->
                for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
            }
            data.data?.let { if (!uris.contains(it)) uris.add(it) }
            val result = uris.map { uri ->
                try {
                    contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                } catch (_: SecurityException) {
                    // Some document providers don't support persistable permissions.
                }
                val info = mutableMapOf<String, Any?>(
                    "uri" to uri.toString(),
                    "name" to (uri.lastPathSegment ?: "unknown.csv"),
                    "size" to null
                )
                contentResolver.query(uri, null, null, null, null)?.use { cursor: Cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (nameIndex >= 0) info["name"] = cursor.getString(nameIndex)
                        if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) info["size"] = cursor.getLong(sizeIndex)
                    }
                }
                info
            }
            callback.success(result)
        } catch (e: Exception) {
            callback.error("PICK_FAILED", e.message, null)
        }
    }

    override fun onDestroy() {
        currentStream?.close()
        ioExecutor.shutdownNow()
        super.onDestroy()
    }
}
