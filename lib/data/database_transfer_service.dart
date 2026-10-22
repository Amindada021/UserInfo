import 'dart:io';

import 'csv_source.dart';
import 'userinfo_database.dart';

/// Offline database backup and restore. Both operations copy in 1 MB chunks on
/// Android; no SQLite data, personal records or file names reach a server.
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

  Future<int> restoreDatabase() async {
    return database.withDatabaseClosed((filename) async {
      final incomingPath = '$filename.incoming';
      final previousPath = '$filename.before_restore';
      final incoming = File(incomingPath);
      final previous = File(previousPath);
      if (await incoming.exists()) await incoming.delete();

      try {
        final bytes = await source.importDatabase(incomingPath);
        if (bytes <= 0) {
          throw const FormatException('فایل دیتابیس خالی است');
        }
        await database.validateDatabaseFile(incomingPath);

        // Keep the previous database until the new one has replaced it.
        final original = File(filename);
        if (await previous.exists()) await previous.delete();
        final hadOriginal = await original.exists();
        if (hadOriginal) await original.rename(previousPath);

        try {
          await incoming.rename(filename);
          // Orphaned WAL files must not be reused with the new database.
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

        // Leave a locally retained rollback copy. A future backup is still
        // recommended, particularly with a database containing 100M records.
        return bytes;
      } finally {
        if (await incoming.exists()) await incoming.delete();
      }
    });
  }
}
