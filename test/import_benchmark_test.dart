import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:userinfo/core/text_normalizer.dart';
import 'package:userinfo/data/csv_source.dart';
import 'package:userinfo/data/import_controller.dart';
import 'package:userinfo/data/userinfo_database.dart';
import '../tool/benchmarks/legacy_csv_parser.dart';
import 'import_resume_test.dart' show SyntheticSource;

void main() {
  test('synthetic end-to-end host import including new fingerprint pass', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    const count = 100000;
    final content = StringBuffer('NATIONAL_CODE,CARD_NO,FULL_NAME,BIRTH_DATE,MOBILE\n');
    for(var i=0;i<count;i++) {
      content.writeln('0000000000,0000000000000000,نمونه ساختگی $i,,09000000000');
    }
    final bytes = Uint8List.fromList(utf8.encode(content.toString()));
    final doc = CsvDocument(uri:'synthetic:test', name:'synthetic.csv', size:bytes.length);
    final results=<Object>[];
    for(final mode in ['legacy', 'current_with_sha256']) {
      final temp=await Directory.systemTemp.createTemp('userinfo_pipeline_');
      final database=UserInfoDatabase(databasePath:'${temp.path}/synthetic.sqlite');
      final source=SyntheticSource(bytes);
      try {
        await database.db;
        final watch=Stopwatch()..start();
        if(mode=='legacy') {
          await database.beginFastImport();
          final fileId=await database.beginFile(bank:'ملی');
          await source.open(doc);
          Stream<List<int>> input() async* {
            while(true) { final chunk=await source.read(); if(chunk==null) break; yield chunk; }
          }
          final buffer=<Map<String,Object?>>[];
          Future<void> flush() async {
            final handle=await database.db;
            await handle.transaction((tx) async {
              final batch=tx.batch();
              for(final row in buffer) { batch.insert('records',row); }
              await batch.commit(noResult:true);
              await tx.rawUpdate('UPDATE files SET imported_count=imported_count+? WHERE id=?',[buffer.length,fileId]);
            });
            buffer.clear();
          }
          await for(final row in const LegacyCsvStreamParser().parseWithErrors(input())) {
            if(row.recordNumber==1) continue;
            final cells=row.fields!;
            buffer.add({'file_id':fileId,'bank':'ملی','part':'','row_number':row.recordNumber-1,
              for(final field in UserInfoDatabase.allowedFields) field:null,
              'national_code':TextNormalizer.cleaned(cells[0]),'card_no':TextNormalizer.cleaned(cells[1]),
              'full_name':TextNormalizer.cleaned(cells[2]),'birth_date':TextNormalizer.cleaned(cells[3]),
              'mobile':TextNormalizer.cleaned(cells[4]),'normalized_name':TextNormalizer.normalize(cells[2]),
              'normalized_father':TextNormalizer.normalize(''),'normalized_city':TextNormalizer.normalize(''),
              'normalized_province':TextNormalizer.normalize('')});
            if(buffer.length>=1500) await flush();
          }
          if(buffer.isNotEmpty) await flush();
          await source.close();
          await database.finishFile(fileId);
          await database.finishFastImport();
        } else {
          final importer=ImportController(database,source);
          await importer.importDocuments([doc]);
          expect(importer.lastError,isNull);
          importer.dispose();
        }
        watch.stop();
        expect(await database.totalRecords(),count);
        results.add({'mode':mode,'rows':count,'elapsed_ms':watch.elapsedMilliseconds,
          'rows_sec':count*1000000/watch.elapsedMicroseconds,'max_rss_bytes':ProcessInfo.maxRss});
      } finally { await database.dispose(); await temp.delete(recursive:true); }
    }
    // ignore: avoid_print
    print('USERINFO_PIPELINE_BENCHMARK ${jsonEncode(results)}');
  },skip:!const bool.fromEnvironment('USERINFO_RUN_BENCHMARK'),timeout:const Timeout(Duration(minutes:10)));
}
