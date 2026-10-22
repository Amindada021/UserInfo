import 'dart:async';
import 'dart:io';

import 'csv_source.dart';
import 'restore_progress.dart';
import 'userinfo_database.dart';

/// Transfers large SQLite databases in 1 MB blocks without loading them into
/// Dart memory. The selected backup is verified before replacing live data.
class DatabaseTransferService {
  DatabaseTransferService(this.database, this.source);

  final UserInfoDatabase database;
  final CsvSource source;

  Future<int> exportDatabase() async {
    return database.withDatabaseClosed((filename) async {
      if (!await File(filename).exists()) {
        throw StateError('دیتابیس موجود نیست');
      }
      return source.exportDatabase(filename);
    });
  }

  Future<int> restoreDatabase({
    void Function(RestoreProgress)? onProgress,
  }) async {
    StreamSubscription<Map<dynamic, dynamic>>? subscription;
    // Listen before launching Android's picker: the first 0-byte event is
    // delivered when the user selects a document.
    subscription = source.restoreCopyProgress.listen((event) {
      onProgress?.call(RestoreProgress.fromNative(event));
    });
    try {
      onProgress?.call(const RestoreProgress(stage: RestoreStage.selecting));
      return await database.withDatabaseClosed((filename) async {
        final incomingPath = '$filename.incoming';
        final previousPath = '$filename.before_restore';
        final incoming = File(incomingPath);
        final previous = File(previousPath);
        if (await incoming.exists()) await incoming.delete();
        RestoreProgress? lastCopy;
        try {
          // Record total copy bytes for the checking/replacing stages.
          await subscription?.cancel();
          subscription = source.restoreCopyProgress.listen((event) {
            final status = RestoreProgress.fromNative(event);
            lastCopy = status;
            onProgress?.call(status);
          });
          final bytes = await source.importDatabase(incomingPath);
          if (bytes <= 0) {
            throw const FormatException('فایل دیتابیس خالی است');
          }
          onProgress?.call(RestoreProgress(
            stage: RestoreStage.checking,
            copiedBytes: bytes,
            totalBytes: lastCopy?.totalBytes ?? bytes,
          ));
          await database.validateDatabaseFile(incomingPath);

          onProgress?.call(RestoreProgress(
            stage: RestoreStage.replacing,
            copiedBytes: bytes,
            totalBytes: lastCopy?.totalBytes ?? bytes,
          ));
          final original = File(filename);
          if (await previous.exists()) await previous.delete();
          final hadOriginal = await original.exists();
          if (hadOriginal) await original.rename(previousPath);

          try {
            await incoming.rename(filename);
            // Old WAL files must never be paired with the restored database.
            for (final suffix in ['-wal', '-shm']) {
              final sidecar = File('$filename$suffix');
              if (await sidecar.exists()) await sidecar.delete();
            }
          } catch (_) {
            if (hadOriginal && await previous.exists() &&
                !await original.exists()) {
              await previous.rename(filename);
            }
            rethrow;
          }
          onProgress?.call(RestoreProgress(
            stage: RestoreStage.complete,
            copiedBytes: bytes,
            totalBytes: lastCopy?.totalBytes ?? bytes,
          ));
          // Keep previous data as a rollback copy next to the database.
          return bytes;
        } finally {
          if (await incoming.exists()) await incoming.delete();
        }
      });
    } finally {
      await subscription.cancel();
    }
  }
}
