package com.amindada021.userinfo

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.content.ContentValues
import android.os.Environment
import android.provider.MediaStore
import java.io.OutputStream
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.nio.charset.StandardCharsets
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
    private val backupRequestCode = 8614
    private val restoreRequestCode = 8615
    private var pendingDatabaseTransfer: MethodChannel.Result? = null
    private var pendingDatabasePath: String? = null
    private var pendingPicker: MethodChannel.Result? = null
    private var currentStream: InputStream? = null
    private var importLog: OutputStream? = null
    private var importLogUri: Uri? = null
    private var importLogLocation: String? = null
    private val ioExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "exportDatabase" -> {
                    if (pendingDatabaseTransfer != null) {
                        result.error("BUSY", "A database transfer is already open", null)
                    } else {
                        pendingDatabaseTransfer = result
                        pendingDatabasePath = call.argument<String>("path")
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/octet-stream"
                            putExtra(Intent.EXTRA_TITLE, "UserInfo-backup.sqlite")
                        }
                        startActivityForResult(intent, backupRequestCode)
                    }
                }
                "importDatabase" -> {
                    if (pendingDatabaseTransfer != null) {
                        result.error("BUSY", "A database transfer is already open", null)
                    } else {
                        pendingDatabaseTransfer = result
                        pendingDatabasePath = call.argument<String>("path")
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivityForResult(intent, restoreRequestCode)
                    }
                }
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
                "openImportLog" -> {
                    try {
                        closeImportLog()
                        val name = "userinfo-import-" +
                            SimpleDateFormat("yyyyMMdd-HHmmss-SSS", Locale.US)
                                .format(Date()) + ".txt"
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            val metadata = ContentValues().apply {
                                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                                put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                                put(MediaStore.MediaColumns.RELATIVE_PATH,
                                    Environment.DIRECTORY_DOWNLOADS + "/UserInfo")
                                put(MediaStore.MediaColumns.IS_PENDING, 1)
                            }
                            val uri = contentResolver.insert(
                                MediaStore.Downloads.EXTERNAL_CONTENT_URI, metadata)
                                ?: error("Unable to create text log in Downloads")
                            importLogUri = uri
                            importLog = contentResolver.openOutputStream(uri, "w")
                                ?: error("Unable to open Downloads log")
                            importLogLocation = "Download/UserInfo/$name"
                        } else {
                            // Android 9 and below: safe app-owned external documents.
                            val folder = File(
                                getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS),
                                "UserInfo")
                            if (!folder.exists() && !folder.mkdirs()) {
                                error("Cannot create log directory")
                            }
                            val targetFile = File(folder, name)
                            importLog = FileOutputStream(targetFile)
                            importLogLocation = targetFile.absolutePath
                        }
                        appendImportLog(
                            "UserInfo CSV import diagnostics\\n" +
                            "Generated: " + Date().toString() + "\\n" +
                            "Source file, row and reason only. No personal field values.\\n")
                        result.success(importLogLocation)
                    } catch (e: Exception) {
                        closeImportLog()
                        result.error("LOG_OPEN_FAILED", e.message, null)
                    }
                }
                "appendImportLog" -> {
                    try {
                        appendImportLog(
                            call.argument<String>("text") ?: "")
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LOG_WRITE_FAILED", e.message, null)
                    }
                }
                "closeImportLog" -> {
                    try {
                        closeImportLog()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LOG_CLOSE_FAILED", e.message, null)
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
                "freeBytes" -> {
                    result.success(android.os.StatFs(applicationInfo.dataDir).availableBytes)
                }
                "read" -> {
                    ioExecutor.execute {
                        try {
                            val stream = currentStream ?: error("No input stream")
                            val buffer = ByteArray(1024 * 1024)
                            val count = stream.read(buffer)
                            runOnUiThread {
                                result.success(if (count < 0) null else if (count == buffer.size) buffer else buffer.copyOf(count))
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
        if (requestCode == backupRequestCode ||
            requestCode == restoreRequestCode) {
            val callback = pendingDatabaseTransfer
            val transferPath = pendingDatabasePath
            pendingDatabaseTransfer = null
            pendingDatabasePath = null
            if (callback == null || transferPath == null) return
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                callback.error("CANCELLED", "Document selection cancelled", null)
                return
            }
            val uri = data.data!!
            ioExecutor.execute {
                try {
                    val transferFile = File(transferPath)
                    if (requestCode == backupRequestCode &&
                        !transferFile.isFile) {
                        error("SQLite source is missing")
                    }
                    val copied = if (requestCode == backupRequestCode) {
                        transferFile.inputStream().buffered(1024 * 1024).use { input ->
                            (contentResolver.openOutputStream(uri, "w")
                                ?: error("Cannot write selected destination")).use { output ->
                                input.copyTo(output, 1024 * 1024)
                            }
                        }
                    } else {
                        transferFile.parentFile?.mkdirs()
                        (contentResolver.openInputStream(uri)
                            ?: error("Cannot read selected backup")).use { input ->
                            transferFile.outputStream().buffered(1024 * 1024).use { output ->
                                input.copyTo(output, 1024 * 1024)
                            }
                        }
                    }
                    runOnUiThread { callback.success(copied) }
                } catch (e: Exception) {
                    runOnUiThread { callback.error("TRANSFER_FAILED", e.message, null) }
                }
            }
            return
        }
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

    private fun appendImportLog(text: String) {
        val output = importLog ?: error("Log is not open")
        output.write(text.toByteArray(StandardCharsets.UTF_8))
        output.flush()
    }

    private fun closeImportLog() {
        try {
            importLog?.flush()
            importLog?.close()
        } finally {
            importLog = null
            val uri = importLogUri
            if (uri != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val metadata = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }
                contentResolver.update(uri, metadata, null, null)
            }
            importLogUri = null
            importLogLocation = null
        }
    }

    override fun onDestroy() {
        currentStream?.close()
        try { closeImportLog() } catch (_: Exception) { }
        ioExecutor.shutdownNow()
        super.onDestroy()
    }
}
