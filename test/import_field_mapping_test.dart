import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:userinfo/data/csv_source.dart';
import 'package:userinfo/data/import_controller.dart';
import 'package:userinfo/data/userinfo_database.dart';
import 'import_resume_test.dart' show SyntheticSource;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<Map<String, Object?>> importOne(String csv) async {
    final folder = await Directory.systemTemp.createTemp('userinfo_csv_fields_');
    final database = UserInfoDatabase(
        databasePath: '${folder.path}/userinfo.sqlite');
    final content = Uint8List.fromList(utf8.encode(csv));
    final importer = ImportController(database, SyntheticSource(content));
    try {
      await importer.importDocuments([
        CsvDocument(
            uri: 'synthetic:columns', name: 'synthetic.csv',
            size: content.length),
      ]);
      expect(importer.lastError, isNull);
      expect(await database.totalRecords(), 1);
      return (await database.search(const SearchFilters())).single;
    } finally {
      importer.dispose();
      await database.dispose();
      await folder.delete(recursive: true);
    }
  }

  test('Bank Melli preserves leading zero identifiers and Persian name',
      () async {
    final row = await importOne(
      'NATIONAL_CODE,CARD_NO,FULL_NAME,BIRTH_DATE,MOBILE\n'
      '0000001234,0000000000012345,محمد يوسفي,1380/01/01,09120000001\n');
    expect(row['bank'], 'ملی');
    expect(row['national_code'], '0000001234');
    expect(row['card_no'], '0000000000012345');
    expect(row['mobile'], '09120000001');
    expect(row['normalized_name'], 'محمد یوسفی');
    expect(row['normalized_father'], '');
    expect(row['normalized_city'], '');
    expect(row['normalized_province'], '');
  });

  test('Bank Mellat preserves all mapped fields and multiline quoted CSV',
      () async {
    final row = await importOne(
      'NATIONAL_CODE,ACCOUNT_NUMBER,FULL_NAME,FATHER_NAME,'
      'ID_NUMBER,BIRTH_DATE,CITY_NAME,PROVINCE_NAME,BIRTH_CITY,'
      'BIRTH_PROVINCE,ADDRESS,CARD_NO,MOBILE\n'
      '0000004321,000057,علی كريمي,حسين,009,1360/02/03,'
      'تهران,تهران,ری,تهران,"خیابان اول\nکوچه دوم",'
      '0000000000000201,09120000002\n');
    expect(row['bank'], 'ملت');
    expect(row['national_code'], '0000004321');
    expect(row['account_number'], '000057');
    expect(row['full_name'], 'علی كريمي');
    expect(row['father_name'], 'حسين');
    expect(row['id_number'], '009');
    expect(row['birth_city'], 'ری');
    expect(row['birth_province'], 'تهران');
    expect(row['address'], 'خیابان اول\nکوچه دوم');
    expect(row['card_no'], '0000000000000201');
    expect(row['mobile'], '09120000002');
    expect(row['normalized_name'], 'علی کریمی');
    expect(row['normalized_father'], 'حسین');
    expect(row['normalized_city'], 'تهران');
    expect(row['normalized_province'], 'تهران');
  });
}
