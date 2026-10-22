import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:userinfo/data/userinfo_database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('restore validator reads a real synthetic SQLite file unchanged',
      () async {
    final dir = await Directory.systemTemp.createTemp('userinfo_restore_check_');
    final filename = '${dir.path}/userinfo.sqlite';
    final userDb = UserInfoDatabase(databasePath: filename);
    try {
      await userDb.db;
      await userDb.dispose();
      final bytesBefore = await File(filename).length();
      expect(bytesBefore, greaterThan(0));
      await userDb.validateDatabaseFile(filename);
      expect(await File(filename).length(), bytesBefore);
    } finally {
      await userDb.dispose();
      await dir.delete(recursive: true);
    }
  });

  test('restore validator refuses non-database data', () async {
    final dir = await Directory.systemTemp.createTemp('userinfo_invalid_');
    final filename = '${dir.path}/invalid.sqlite';
    final userDb = UserInfoDatabase();
    try {
      await File(filename).writeAsString('not a sqlite database');
      await expectLater(userDb.validateDatabaseFile(filename), throwsException);
    } finally {
      await userDb.dispose();
      await dir.delete(recursive: true);
    }
  });
}
