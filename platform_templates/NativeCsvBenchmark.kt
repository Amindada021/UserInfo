package com.amindada021.userinfo

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.os.SystemClock
import java.io.BufferedReader
import java.io.File
import java.io.FileInputStream
import java.io.InputStreamReader
import java.security.MessageDigest

/**
 * ISOLATED BENCHMARK ONLY. Not a production CSV parser or import option.
 *
 * The generated fixture has exactly five plain (unquoted) CSV columns.
 * The existing Dart CSV parser supports malformed, quoted and multiline
 * records and remains the only supported production import implementation.
 */
internal object NativeCsvBenchmark {
    fun run(
        context: Context,
        csvPath: String,
        databasePath: String,
        fileId: Int,
        batchRows: Int,
        maxRows: Int
    ): Map<String, Any> {
        require(batchRows in 100..150000 && maxRows in 1..1000000 && fileId > 0)
        val root = File(context.cacheDir, "userinfo_native_compare").canonicalFile
        val csv = File(csvPath).canonicalFile
        val destination = File(databasePath).canonicalFile
        require(csv.path.startsWith(root.path + File.separator))
        require(destination.path.startsWith(root.path + File.separator))
        require(csv.exists() && destination.exists())
        require(csv.length() in 1..(512L * 1024L * 1024L))

        val totalStart = SystemClock.elapsedRealtimeNanos()
        val shaStart = SystemClock.elapsedRealtimeNanos()
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(csv).use { input ->
            val buffer = ByteArray(1024 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                if (count > 0) digest.update(buffer, 0, count)
            }
        }
        // Prevent the digest from being optimized away (and verify the hash
        // is computed), but never return data-derived fingerprints in logs.
        check(digest.digest().size == 32)
        val shaMs = (SystemClock.elapsedRealtimeNanos() - shaStart) / 1e6

        val insertStart = SystemClock.elapsedRealtimeNanos()
        val db = SQLiteDatabase.openDatabase(
            destination.path, null, SQLiteDatabase.OPEN_READWRITE
        )
        val names = listOf(
            "file_id", "bank", "part", "row_number", "national_code",
            "account_number", "full_name", "father_name", "id_number",
            "birth_date", "city_name", "province_name", "birth_city",
            "birth_province", "address", "card_no", "mobile",
            "normalized_name", "normalized_father", "normalized_city",
            "normalized_province"
        )
        val placeholders = List(names.size) { "?" }.joinToString(",")
        val insertSql =
            "INSERT INTO records(${names.joinToString(",")}) VALUES ($placeholders)"
        val batchDurations = ArrayList<Double>()
        var inserted = 0
        var pending = 0
        var batchStart = 0L
        var peakRssKb = 0L
        try {
            db.compileStatement(insertSql).use { statement ->
                fun commitPending() {
                    if (pending == 0) return
                    db.execSQL(
                        "UPDATE files SET imported_count=imported_count+? WHERE id=?",
                        arrayOf(pending, fileId)
                    )
                    db.setTransactionSuccessful()
                    db.endTransaction()
                    batchDurations.add(
                        (SystemClock.elapsedRealtimeNanos() - batchStart) / 1e6
                    )
                    pending = 0
                    peakRssKb = maxOf(
                        peakRssKb,
                        android.os.Debug.getPss().toLong()
                    )
                }
                try {
                    BufferedReader(InputStreamReader(FileInputStream(csv), Charsets.UTF_8),
                        1024 * 1024).use { reader ->
                        val header = reader.readLine()
                        require(header ==
                            "NATIONAL_CODE,CARD_NO,FULL_NAME,BIRTH_DATE,MOBILE")
                        while (inserted < maxRows) {
                            val line = reader.readLine() ?: break
                            // Synthetic fixture only; quoted/multiline CSV
                            // is intentionally excluded from this benchmark.
                            require('"' !in line)
                            val values = line.split(',', limit = 5)
                            require(values.size == 5)
                            if (pending == 0) {
                                db.beginTransaction()
                                batchStart = SystemClock.elapsedRealtimeNanos()
                            }
                            statement.clearBindings()
                            statement.bindLong(1, fileId.toLong())
                            statement.bindString(2, "ملی")
                            statement.bindString(3, "")
                            statement.bindLong(4, (inserted + 1).toLong())
                            statement.bindString(5, values[0])
                            statement.bindString(7, values[2])
                            if (values[3].isNotEmpty()) {
                                statement.bindString(10, values[3])
                            }
                            statement.bindString(16, values[1])
                            statement.bindString(17, values[4])
                            statement.bindString(18, values[2])
                            statement.bindString(19, "")
                            statement.bindString(20, "")
                            statement.bindString(21, "")
                            statement.executeInsert()
                            inserted++
                            pending++
                            if (pending >= batchRows) commitPending()
                        }
                    }
                    commitPending()
                } finally {
                    // Any uncommitted rows roll back. This is a disposable DB.
                    if (db.inTransaction()) db.endTransaction()
                }
            }
            val insertMs = (SystemClock.elapsedRealtimeNanos() - insertStart) / 1e6
            val overallMs = (SystemClock.elapsedRealtimeNanos() - totalStart) / 1e6
            db.rawQuery("SELECT COUNT(*) FROM records", null).use { cursor ->
                check(cursor.moveToFirst() && cursor.getLong(0) == inserted.toLong())
            }
            val sorted = batchDurations.sorted()
            return mapOf(
                "rows" to inserted,
                "batch_rows" to batchRows,
                "sha_ms" to shaMs,
                "parse_and_insert_ms" to insertMs,
                "total_ms" to overallMs,
                "rows_per_second" to (inserted * 1000.0 / overallMs),
                "batch_p50_ms" to sorted[sorted.size / 2],
                "batch_p95_ms" to sorted[
                    ((sorted.size * 0.95).toInt()).coerceAtMost(sorted.lastIndex)
                ],
                "sqlite_bytes" to destination.length(),
                "peak_pss_kb" to peakRssKb
            )
        } finally {
            db.close()
        }
    }
}
