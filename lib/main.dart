import 'dart:async';

import 'package:share_plus/share_plus.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/csv_source.dart';
import 'data/database_transfer_service.dart';
import 'data/restore_progress.dart';
import 'security/passcode_gate.dart';
import 'data/export_service.dart';
import 'data/import_controller.dart';
import 'data/userinfo_database.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const UserInfoApp());
}

class UserInfoApp extends StatelessWidget {
  const UserInfoApp({super.key});

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF12685C);
    return AnimatedBuilder(
      animation: AppAppearance.mode,
      builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'UserInfo',
      locale: const Locale('fa'),
      supportedLocales: const [Locale('fa')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: green),
        scaffoldBackgroundColor: const Color(0xFFF5F7F5),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          margin: const EdgeInsets.symmetric(vertical: 5),
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFE4E9E6)),
          ),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
            seedColor: green, brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF121B1B),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
      ),
      themeMode: AppAppearance.mode.value,
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const PasscodeGate(child: HomePage()),
    ));
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final UserInfoDatabase _database = UserInfoDatabase();
  final CsvSource _source = CsvSource();
  late final DatabaseTransferService _transfer =
      DatabaseTransferService(_database, _source);
  final TextEditingController _search = TextEditingController();
  late final ImportController _import = ImportController(_database, _source);
  late final ExportService _export = ExportService();

  List<Map<String, Object?>> _rows = const [];
  final Set<int> _selected = {};
  bool _showFullDetails = false;
  bool _favoritesOnly = false;
  bool _maintenanceBusy = false;
  RestoreProgress? _restoreProgress;
  final Stopwatch _restoreElapsed = Stopwatch();
  Timer? _restoreTicker;
  bool _buildingIndex = false;
  NameIndexStatus? _indexStatus;
  String? _indexError;
  String _searchType = 'name';
  Timer? _debounce;
  int _page = 0;
  int _pageSize = 20;
  int? _count;
  bool _hasNext = false;
  bool _counting = false;
  final List<int?> _pageCursors = [null];
  String _bank = '';
  bool _missingMobile = false;
  bool _busy = true;
  bool _showImportSummary = false;
  int _partialRecords = 0;
  bool _refreshInProgress = false;
  DateTime _lastImportRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastImportRefreshCount = 0;
  Map<String, String> _fieldFilters = {};
  String _birthFrom = '';
  String _birthTo = '';

  SearchFilters get _filter => SearchFilters(
        query: _search.text,
        searchType: _searchType,
        favoritesOnly: _favoritesOnly,
        bank: _bank,
        fields: _fieldFilters,
        missingMobile: _missingMobile,
        birthFrom: _birthFrom,
        birthTo: _birthTo,
      );

  @override
  void initState() {
    super.initState();
    _import.addListener(_onImportChanged);
    _bootstrap();
  }

  void _onImportChanged() {
    if (!mounted) return;
    setState(() {});
    final now = DateTime.now();
    if (_import.busy &&
        _import.inserted - _lastImportRefreshCount >= 2500 &&
        now.difference(_lastImportRefresh) >= const Duration(seconds: 6)) {
      _lastImportRefresh = now;
      _lastImportRefreshCount = _import.inserted;
      _refreshVisibleDuringImport();
    }
  }

  /// Progress is committed batch by batch; keep the list visible while the
  /// long import runs, without repeatedly entering the full-screen busy state.
  Future<void> _refreshVisibleDuringImport() async {
    if (_refreshInProgress) return;
    _refreshInProgress = true;
    try {
      // Refresh through the same generation guard and cursor as typed queries.
      await _load();
    } catch (_) {
      // A transient concurrent-read failure must not stop the importer.
    } finally {
      _refreshInProgress = false;
    }
  }

  Future<void> _bootstrap() async {
    try {
      await _database.discardInterruptedImports();
      _partialRecords = await _database.partialRecordCount();
      _showFullDetails = await _database.showFullDetails();
      final savedTheme = await _database.getSetting('theme_mode');
      AppAppearance.mode.value =
          savedTheme == 'dark' ? ThemeMode.dark : ThemeMode.light;
      _indexStatus = await _database.nameIndexStatus();
      await _load();
      _buildNameIndex();
    } catch (error) {
      _message('خطای راه‌اندازی دیتابیس: $error');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _buildNameIndex() async {
    if (_buildingIndex || _maintenanceBusy) return;
    _buildingIndex = true;
    try {
      var status = await _database.nameIndexStatus();
      var checkedAt = -100000;

      while (mounted && !status.ready && !_maintenanceBusy) {
        // Avoid competing for SQLite writes while importing millions of rows.
        if (_import.busy) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          status = await _database.nameIndexStatus();
          continue;
        }
        // Keep each SQLite transaction bounded, so interruption does not
        // discard the indexed part of a 5M or 100M-record database.
        if (status.done - checkedAt >= 100000) {
          final available = await _source.freeBytes();
          if (available < 64 * 1024 * 1024) {
            throw StateError('فضای خالی کمتر از ۶۴ مگابایت است؛ برای ادامه ایندکس فضا آزاد کن.');
          }
          checkedAt = status.done;
        }
        status = await _database.buildNameIndexChunk(limit: 2500);
        if (mounted) setState(() => _indexStatus = status);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      if (mounted && status.ready) {
        setState(() {
          _indexStatus = status;
          _indexError = null;
        });
        await _load(resetPage: true);
      }
    } catch (error) {
      if (mounted) setState(() => _indexError = error.toString());
    } finally {
      _buildingIndex = false;
    }
  }

  int _searchGeneration = 0;

  Future<void> _load({bool resetPage = false}) async {
    if (_maintenanceBusy) return;
    if (resetPage) {
      _page = 0;
      _pageCursors..clear()..add(null);
    }
    final generation = ++_searchGeneration;
    final filters = _filter;
    final requestedCursor = _pageCursors[_page];
    final requestedSize = _pageSize;
    if (mounted) setState(() => _busy = true);
    try {
      // Show the first page before performing potentially expensive COUNT.
      // In a 100-million-row DB, even FTS MATCH COUNT may take noticeable time
      // for very broad terms. Stale responses from fast typing are discarded.
      final rows = await _database.search(
          filters, beforeId: requestedCursor, pageSize: requestedSize + 1);
      if (generation != _searchGeneration) return;
      if (mounted) {
        setState(() {
          _hasNext = rows.length > requestedSize;
          _rows = rows.take(requestedSize).toList();
          _count = null;
          _busy = false;
        });
      }

    } catch (error) {
      if (generation == _searchGeneration) {
        _message('خطا در خواندن نتایج: $error');
      }
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => _busy = false);
      }
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    ++_searchGeneration;
    _page = 0;
    _pageCursors..clear()..add(null);
    if (mounted) setState(() => _busy = true);
    _debounce = Timer(const Duration(milliseconds: 350),
        () => _load(resetPage: true));
  }

  Future<void> _pickAndImport() async {
    if (_import.busy) return;
    try {
      final documents = await _source.pick();
      if (documents.isEmpty) return;
      if (await _database.hasLegacyImports()) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
          title: const Text('توجه به فایل‌های قدیمی'),
          content: const Text('نسخه قبلی اثر انگشت فایل ذخیره نکرده است. فایل‌هایی که قبلاً کامل یا ناقص وارد کرده‌ای را دوباره انتخاب نکن؛ امکان تشخیص تکراری بودن آن‌ها وجود ندارد. ادامه فقط برای فایل جدید است.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('فایل جدید است')),
          ],
        ));
        if (proceed != true) return;
      }
      if (mounted) setState(() => _showImportSummary = true);
      await _import.importDocuments(documents);
      _partialRecords = await _database.partialRecordCount();
      if (_import.lastError != null) {
        _message('ایمپورت ناقص: ${_import.lastError}');
      } else {
        _message(_import.stage);
      }
      await _load(resetPage: true);
      // Newly imported names were intentionally not tokenized during CSV
      // import. Resume background indexing now that bulk inserts are done.
      _indexStatus = await _database.nameIndexStatus();
      if (mounted) setState(() {});
      _buildNameIndex();
    } catch (error) {
      _message('انتخاب فایل ناموفق بود: $error');
    }
  }

  Future<bool> _confirmSensitive() async {
    if (_showFullDetails) return true;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('نمایش اطلاعات حساس'),
            content: const Text(
                'شماره کارت، کد ملی و اطلاعات شخصی قابل کپی یا صدور خواهند بود. '
                'فایل‌ها و کلیپ‌بورد ممکن است توسط برنامه‌های دیگر خوانده شوند. ادامه می‌دهی؟'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('انصراف')),
              FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('تأیید')),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _copyRecord(Map<String, Object?> record,
      {bool sensitive = false}) async {
    if (sensitive && !await _confirmSensitive()) return;
    final keys = sensitive
        ? ExportService.fullColumns
        : ExportService.safeColumns;
    final text = [
      for (final key in keys)
        if (record[key] != null && record[key].toString().isNotEmpty)
          '${ExportService.labels[key]}: ${record[key]}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    _message('اطلاعات در کلیپ‌بورد کپی شد');
  }

  Future<void> _copySelection() async {
    if (_selected.isEmpty) return;
    final sensitive = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('کپی افراد انتخاب‌شده'),
        content: const Text('فقط نام و بانک کپی شود یا تمام فیلدهای افراد؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('اطلاعات اصلی')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('تمام اطلاعات')),
        ],
      ),
    );
    if (sensitive == null) return;
    if (sensitive && !await _confirmSensitive()) return;
    try {
      final rows = await _database.byIds(_selected);
      final keys = sensitive
          ? ExportService.fullColumns : ExportService.safeColumns;
      final text = rows.map((row) => [
        for (final key in keys)
          if (row[key] != null && row[key].toString().isNotEmpty)
            '${ExportService.labels[key]}: ${row[key]}',
      ].join('\n')).join('\n---------------\n');
      await Clipboard.setData(ClipboardData(text: text));
      _message('${rows.length} رکورد کپی شد');
    } catch (error) {
      _message('خطا در کپی: $error');
    }
  }

  Future<void> _showExportOptions() async {
    if (_rows.isEmpty && _selected.isEmpty) return;
    final result = await showModalBottomSheet<(bool, bool, bool)>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        var selectedOnly = _selected.isNotEmpty;
        const sensitive = true;
        var pdf = false;
        return StatefulBuilder(builder: (context, update) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('خروجی گزارش', style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
                SwitchListTile(
                  title: const Text('فقط افراد انتخاب‌شده'),
                  subtitle: Text('${_selected.length} رکورد انتخاب شده'),
                  value: selectedOnly,
                  onChanged: _selected.isEmpty
                      ? null : (v) => update(() => selectedOnly = v),
                ),
                const ListTile(
                  leading: Icon(Icons.fact_check_outlined),
                  title: Text('خروجی کامل همه فیلدهای موجود'),
                  subtitle: Text('هر دو فرمت شامل تمام ۱۴ ستون هستند'),
                ),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Excel')),
                    ButtonSegment(value: true, label: Text('PDF')),
                  ],
                  selected: {pdf},
                  onSelectionChanged: (v) => update(() => pdf = v.first),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.ios_share),
                  label: const Text('تهیه خروجی'),
                  onPressed: () => Navigator.pop(sheetContext,
                      (selectedOnly, sensitive, pdf)),
                ),
                const SizedBox(height: 12),
              ]),
            ),
          );
        });
      },
    );
    if (result == null) return;
    final (selectedOnly, sensitive, pdf) = result;
    if (sensitive && !await _confirmSensitive()) return;
    try {
      final rows = selectedOnly
          ? await _database.byIds(_selected)
          : List<Map<String, Object?>>.from(_rows);
      if (pdf) {
        await _export.pdf(rows, sensitive: sensitive);
      } else {
        await _export.excel(rows, sensitive: sensitive);
      }
    } catch (error) {
      _message('خروجی ایجاد نشد: $error');
    }
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('تنظیمات UserInfo',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SwitchListTile.adaptive(
              title: const Text('نمایش اطلاعات کامل همه اشخاص'),
              value: _showFullDetails,
              onChanged: (value) async {
                if (value && !await _confirmSensitive()) return;
                await _database.setShowFullDetails(value);
                if (mounted) setState(() => _showFullDetails = value);
                if (sheetContext.mounted) Navigator.pop(sheetContext);
              },
            ),
            ListTile(
              leading: Icon(AppAppearance.mode.value == ThemeMode.dark
                  ? Icons.dark_mode : Icons.light_mode),
              title: const Text('حالت روشن / تاریک'),
              subtitle: Text(AppAppearance.mode.value == ThemeMode.dark
                  ? 'تاریک' : 'روشن'),
              onTap: () async {
                final next = AppAppearance.mode.value == ThemeMode.dark
                    ? ThemeMode.light : ThemeMode.dark;
                await _database.setSetting(
                    'theme_mode', next == ThemeMode.dark ? 'dark' : 'light');
                AppAppearance.mode.value = next;
                if (sheetContext.mounted) Navigator.pop(sheetContext);
              },
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('گرفتن بکاپ کامل دیتابیس SQLite'),
              subtitle: const Text('ذخیره فایل دیتابیس در محل انتخابی گوشی'),
              onTap: () {
                Navigator.pop(sheetContext);
                _backupDatabase();
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_backup_restore),
              title: const Text('بازیابی دیتابیس از بکاپ'),
              subtitle: const Text('جایگزین اطلاعات فعلی؛ نیازمند تأیید'),
              onTap: () {
                Navigator.pop(sheetContext);
                _restoreDatabase();
              },
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _backupDatabase() async {
    if (_import.busy || _maintenanceBusy) {
      _message('هنگام ایمپورت یا انتقال قبلی، بکاپ ممکن نیست');
      return;
    }
    setState(() => _maintenanceBusy = true);
    try {
      final bytes = await _transfer.exportDatabase();
      _message('بکاپ دیتابیس ذخیره شد: $bytes بایت');
    } catch (error) {
      _message('بکاپ ذخیره نشد یا انتخاب فایل لغو شد: $error');
    } finally {
      if (mounted) {
        setState(() => _maintenanceBusy = false);
        _buildNameIndex();
      }
    }
  }

  Future<void> _restoreDatabase() async {
    if (_import.busy || _maintenanceBusy) {
      _message('هنگام ایمپورت، بازیابی دیتابیس ممکن نیست');
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('بازیابی کامل دیتابیس'),
        content: const Text(
          'اطلاعات فعلی با دیتابیس بکاپ جایگزین می‌شوند. '
          'پیش از ادامه یک نسخه پشتیبان جداگانه داشته باش. '
          'این عملیات ممکن است روی دیتابیس بزرگ طولانی شود. ادامه می‌دهی؟',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false),
              child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(c, true),
              child: const Text('انتخاب بکاپ و بازیابی')),
        ],
      ),
    ) ?? false;
    if (!approved || !mounted) return;
    _restoreElapsed
      ..reset()
      ..start();
    _restoreTicker?.cancel();
    _restoreTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    setState(() {
      _maintenanceBusy = true;
      _restoreProgress = const RestoreProgress(stage: RestoreStage.selecting);
    });
    try {
      await _transfer.restoreDatabase(onProgress: (progress) {
        if (mounted) setState(() => _restoreProgress = progress);
      });
      _selected.clear();
      _partialRecords = await _database.partialRecordCount();
      _indexStatus = await _database.nameIndexStatus();
      await _loadAfterRestore();
      _message('دیتابیس از بکاپ بازیابی شد');
    } catch (error) {
      _message('بازیابی انجام نشد: $error');
    } finally {
      _restoreTicker?.cancel();
      _restoreTicker = null;
      _restoreElapsed.stop();
      if (mounted) {
        setState(() {
          _maintenanceBusy = false;
          _restoreProgress = null;
        });
        await _load(resetPage: true);
        _buildNameIndex();
      }
    }
  }

  String _restoreSize(int bytes) {
    if (bytes < 1024) return '$bytes بایت';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} کیلوبایت';
    if (bytes < 1073741824) {
      return '${(bytes / 1048576).toStringAsFixed(1)} مگابایت';
    }
    return '${(bytes / 1073741824).toStringAsFixed(2)} گیگابایت';
  }

  String _restoreDuration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}'
        : '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _restoreOverlay() {
    final info = _restoreProgress!;
    final copying = info.stage == RestoreStage.copying;
    final checking = info.stage == RestoreStage.checking;
    final title = switch (info.stage) {
      RestoreStage.selecting => 'انتخاب فایل بکاپ',
      RestoreStage.copying => 'مرحله ۱ از ۳ — انتقال فایل',
      RestoreStage.checking => 'مرحله ۲ از ۳ — بررسی سلامت دیتابیس',
      RestoreStage.replacing => 'مرحله ۳ از ۳ — جایگزینی دیتابیس',
      RestoreStage.complete => 'بازیابی انجام شد',
    };
    final percent = info.copyFraction;
    final speed = info.bytesPerSecond;
    final eta = info.estimatedCopyRemaining;
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              margin: const EdgeInsets.all(20),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.settings_backup_restore, size: 24),
                      const SizedBox(width: 10),
                      Expanded(child: Text(title,
                        style: const TextStyle(fontSize: 16,
                            fontWeight: FontWeight.bold))),
                    ]),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: copying ? percent : null,
                      minHeight: 9,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    const SizedBox(height: 10),
                    if (copying) ...[
                      Text(percent == null
                          ? 'منتقل‌شده: ${_restoreSize(info.copiedBytes)}'
                          : 'انتقال فایل: ${(percent * 100).toStringAsFixed(1)}٪'),
                      Text(info.totalBytes == null
                          ? 'حجم کل فایل توسط انتخابگر اعلام نشده'
                          : '${_restoreSize(info.copiedBytes)} از '
                              '${_restoreSize(info.totalBytes!)}'),
                      if (speed != null)
                        Text('سرعت انتقال: ${_restoreSize(speed.round())} در ثانیه'),
                      Text(eta == null
                          ? 'زمان باقی‌مانده کپی: در حال محاسبه...'
                          : 'زمان تقریبی باقی‌مانده کپی: '
                              '${_restoreDuration(eta)}'),
                    ] else if (checking) ...[
                      Text('کپی ${_restoreSize(info.copiedBytes)} کامل شد.'),
                      const Text('در حال بررسی سلامت SQLite؛ '
                          'برای این مرحله درصد و زمان دقیق در دسترس نیست.'),
                    ] else if (info.stage == RestoreStage.replacing)
                      const Text('بکاپ بررسی شد؛ در حال جایگزینی دیتابیس...'),
                    if (info.stage == RestoreStage.selecting)
                      const Text('فایل بکاپ را در انتخابگر اندروید انتخاب کن.'),
                    const SizedBox(height: 8),
                    Text('زمان سپری‌شده: ${_restoreDuration(_restoreElapsed.elapsed)}',
                      style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12),
                    const Text('برنامه را تا پایان باز نگه دار. '
                        'دیتابیس فعلی فقط پس از تأیید سلامت بکاپ جایگزین می‌شود.',
                        style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadAfterRestore() async {
    // Restore closes the prior SQLite handle; the next query opens the new DB.
    _showFullDetails = await _database.showFullDetails();
    final theme = await _database.getSetting('theme_mode');
    AppAppearance.mode.value =
        theme == 'dark' ? ThemeMode.dark : ThemeMode.light;
    if (mounted) setState(() {});
  }

  Future<void> _toggleFavorite(Map<String, Object?> record) async {
    try {
      final nowFavorite = await _database.toggleFavorite(record['id'] as int);
      if (_favoritesOnly && !nowFavorite) {
        await _load(resetPage: true);
      } else if (mounted) {
        setState(() {
          final idx = _rows.indexWhere((r) => r['id'] == record['id']);
          if (idx >= 0) {
            final updated = Map<String, Object?>.from(_rows[idx]);
            updated['is_favorite'] = nowFavorite ? 1 : 0;
            _rows = [..._rows]..[idx] = updated;
          }
        });
      }
    } catch (error) {
      _message('تغییر علاقه‌مندی ناموفق بود: $error');
    }
  }

  String _recordAsText(Map<String, Object?> record) =>
      ExportService.fullColumns
          .where((key) => (record[key] ?? '').toString().isNotEmpty)
          .map((key) => '${ExportService.labels[key]}: ${record[key]}')
          .join('\n');

  Future<void> _sharePerson(Map<String, Object?> record) async {
    if (!await _confirmSensitive()) return;
    try {
      await SharePlus.instance.share(ShareParams(
        text: _recordAsText(record), subject: 'اطلاعات شخص UserInfo'));
    } catch (error) {
      _message('اشتراک‌گذاری انجام نشد: $error');
    }
  }

  Future<void> _shareSelection() async {
    if (_selected.isEmpty || _selected.length > 500) {
      _message('برای اشتراک‌گذاری متنی بین ۱ تا ۵۰۰ رکورد انتخاب کن');
      return;
    }
    if (!await _confirmSensitive()) return;
    try {
      final rows = await _database.byIds(_selected);
      await SharePlus.instance.share(ShareParams(
        text: rows.map(_recordAsText).join('\n\n──────────\n\n'),
        subject: 'اطلاعات منتخب UserInfo',
      ));
    } catch (error) {
      _message('اشتراک‌گذاری ناموفق بود: $error');
    }
  }

  Future<void> _editPerson(Map<String, Object?> record) async {
    if (_import.busy || _maintenanceBusy) {
      _message('ویرایش پس از پایان ایمپورت امکان‌پذیر است');
      return;
    }
    final controllers = {
      for (final field in UserInfoDatabase.allowedFields)
        field: TextEditingController(text: (record[field] ?? '').toString()),
    };
    try {
      final save = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                16, 4, 16, MediaQuery.viewInsetsOf(sheetContext).bottom + 16),
            child: SizedBox(
              height: MediaQuery.sizeOf(sheetContext).height * 0.8,
              child: Column(children: [
                const Text('ویرایش اطلاعات شخص',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Expanded(child: ListView(children: [
                  for (final field in UserInfoDatabase.allowedFields)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: TextField(
                        controller: controllers[field],
                        decoration: InputDecoration(
                            labelText: ExportService.labels[field] ?? field),
                      ),
                    ),
                ])),
                FilledButton.icon(
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('ذخیره تغییرات'),
                  onPressed: () => Navigator.pop(sheetContext, true),
                ),
              ]),
            ),
          ),
        ),
      );
      if (save != true) return;
      final changed = <String, String?>{
        for (final item in controllers.entries)
          if (item.value.text != (record[item.key] ?? '').toString())
            item.key: item.value.text,
      };
      if (changed.isEmpty) return;
      await _database.updatePerson(record['id'] as int, changed);
      await _load();
      _message('اطلاعات ویرایش شد');
    } catch (error) {
      _message('ویرایش ذخیره نشد: $error');
    } finally {
      for (final controller in controllers.values) {
        controller.dispose();
      }
    }
  }

  Future<void> _deleteEverything() async {
    if (_import.busy) {
      _message('ابتدا ایمپورت را متوقف کن');
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف همه اطلاعات؟'),
        content: const Text(
            'تمام رکوردها، بانک‌ها و سوابق ایمپورت از دیتابیس برنامه '
            'حذف می‌شوند. این کار قابل بازگشت نیست. '
            'فایل‌های CSV اصلی روی گوشی حذف نخواهند شد.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('انصراف')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('بله، حذف همه اطلاعات')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _database.deleteEverything();
      _selected.clear();
      _partialRecords = 0;
      await _load(resetPage: true);
      _message('اطلاعات برنامه حذف شد');
    } catch (error) {
      _message('حذف انجام نشد: $error');
    }
  }

  Future<void> _openFilters() async {
    final controllers = {
      for (final entry in ExportService.labels.entries)
        if (UserInfoDatabase.allowedFields.contains(entry.key))
          entry.key: TextEditingController(
              text: _fieldFilters[entry.key] ?? ''),
    };
    final from = TextEditingController(text: _birthFrom);
    final to = TextEditingController(text: _birthTo);
    var selectedBank = _bank;
    var missing = _missingMobile;
    final apply = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (bottomContext) => StatefulBuilder(
        builder: (context, redraw) => Padding(
          padding: EdgeInsets.fromLTRB(
              16, 0, 16, MediaQuery.viewInsetsOf(context).bottom + 12),
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.75,
            child: Column(children: [
              const Text('فیلتر پیشرفته', style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 12),
              Expanded(child: ListView(children: [
                DropdownButtonFormField<String>(
                  initialValue: selectedBank,
                  decoration: const InputDecoration(labelText: 'بانک'),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('همه بانک‌ها')),
                    DropdownMenuItem(value: 'ملی', child: Text('بانک ملی')),
                    DropdownMenuItem(value: 'ملت', child: Text('بانک ملت')),
                  ],
                  onChanged: (v) => redraw(() => selectedBank = v ?? ''),
                ),
                const SizedBox(height: 8),
                for (final entry in controllers.entries) ...[
                  TextField(
                    controller: entry.value,
                    decoration: InputDecoration(
                      labelText: ExportService.labels[entry.key],
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Row(children: [
                  Expanded(child: TextField(controller: from,
                      decoration: const InputDecoration(
                          labelText: 'تولد از (۱۳۶۰-۰۱-۰۱)'))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: to,
                      decoration: const InputDecoration(
                          labelText: 'تولد تا'))),
                ]),
                SwitchListTile(
                    title: const Text('فقط افراد بدون موبایل'),
                    value: missing,
                    onChanged: (v) => redraw(() => missing = v)),
              ])),
              Row(children: [
                TextButton(
                  onPressed: () {
                    selectedBank = '';
                    missing = false;
                    for (final controller in controllers.values) {
                      controller.clear();
                    }
                    from.clear();
                    to.clear();
                    redraw(() {});
                  },
                  child: const Text('پاک‌کردن'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.pop(bottomContext, true),
                  child: const Text('اعمال فیلترها'),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
    if (apply == true) {
      _bank = selectedBank;
      _missingMobile = missing;
      _fieldFilters = {
        for (final entry in controllers.entries)
          if (entry.value.text.trim().isNotEmpty)
            entry.key: entry.value.text.trim(),
      };
      _birthFrom = from.text.trim();
      _birthTo = to.text.trim();
      await _load(resetPage: true);
    }
    for (final controller in controllers.values) {
      controller.dispose();
    }
    from.dispose();
    to.dispose();
  }

  String _masked(String? value) {
    if (value == null || value.isEmpty) return 'ثبت نشده';
    return '•••• ${value.length > 4 ? value.substring(value.length - 4) : value}';
  }

  Widget _detailRow(Map<String, Object?> record, String key, bool visible) {
    final value = record[key]?.toString();
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    final display = visible || const ['full_name', 'bank']
            .contains(key)
        ? value : _masked(value);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(children: [
        SizedBox(width: 105,
          child: Text(ExportService.labels[key] ?? key,
              style: TextStyle(color: Colors.grey.shade700, fontSize: 12))),
        Expanded(child: SelectableText(display,
            style: const TextStyle(fontSize: 13))),
        IconButton(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: 'کپی این فیلد',
          onPressed: visible || const ['full_name', 'bank']
              .contains(key)
              ? () async {
                  await Clipboard.setData(ClipboardData(text: value));
                  _message('کپی شد');
                }
              : null,
        ),
      ]),
    );
  }

  Widget _personCard(Map<String, Object?> row, int index) {
    final id = row['id'] as int;
    final name = row['full_name']?.toString() ?? 'بدون نام';
    final visible = _showFullDetails;
    final alternate = index.isOdd;
    final selected = _selected.contains(id);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      key: ValueKey(id),
      color: selected
          ? (dark ? const Color(0xFF194D40) : const Color(0xFFD9EEE5))
          : alternate
              ? (dark ? const Color(0xFF23353F) : const Color(0xFFE8F2F7))
              : (dark ? const Color(0xFF202B2B) : Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          width: 1.2,
          color: selected
              ? const Color(0xFF78B69D)
              : alternate
                  ? const Color(0xFF537282)
                  : (dark ? const Color(0xFF3C4F4A)
                      : const Color(0xFFDCE7E2)),
        ),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 10),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        leading: Checkbox(
          value: _selected.contains(id),
          onChanged: (v) => setState(() {
            if (v == true) {
              _selected.add(id);
            } else {
              _selected.remove(id);
            }
          }),
        ),
        title: Text(name,
            maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        subtitle: Row(children: [
          Text('بانک ${row['bank']}', style: const TextStyle(fontSize: 12)),
          const Spacer(),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'علاقه‌مندی',
            icon: Icon((row['is_favorite'] as num? ?? 0) == 1
                ? Icons.star_rounded : Icons.star_border_rounded,
                color: (row['is_favorite'] as num? ?? 0) == 1
                    ? Colors.amber.shade700 : null, size: 21),
            onPressed: () => _toggleFavorite(row),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'ویرایش رکورد',
            icon: const Icon(Icons.edit_outlined, size: 19),
            onPressed: () => _editPerson(row),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'اشتراک‌گذاری',
            icon: const Icon(Icons.share_outlined, size: 19),
            onPressed: () => _sharePerson(row),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy_all_outlined, size: 19),
            tooltip: 'کپی تمام اطلاعات این شخص',
            onPressed: () => _copyRecord(row, sensitive: true),
          ),
        ]),
        children: [
          for (final key in ExportService.labels.keys)
            _detailRow(row, key, visible),
        ],
      ),
    );
  }

  Widget _progressPanel() {
    final fraction = _import.fraction;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_import.stage,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(_import.currentName, maxLines: 1,
              overflow: TextOverflow.ellipsis),
          Text('فایل ${_import.fileIndex} از ${_import.fileCount} | '
              '${_import.inserted} رکورد ثبت‌شده | '
              '${_import.invalidRows} ردیف ناسازگار',
              style: const TextStyle(fontSize: 12)),
          const Text(
            'اجرای طولانی با اعلان اندروید محافظت می‌شود؛ '
            'بااین‌حال خاموش‌شدن اجباری برنامه یا راه‌اندازی مجدد گوشی '
            'می‌تواند فایل جاری را ناتمام بگذارد.',
            style: TextStyle(fontSize: 11, color: Color(0xFF52726B)),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: fraction),
          const SizedBox(height: 4),
          Text(fraction == null
                  ? 'درصد نامعلوم (حجم فایل اعلام نشده)'
                  : '${(fraction * 100).toStringAsFixed(1)}٪ از بایت‌های ورودی خوانده شده',
              style: const TextStyle(fontSize: 12)),
          Text('ردیف‌های ردشده: ${_import.invalidRows} | '
              'فایل‌های ناقص: ${_import.failedFiles}',
              style: const TextStyle(fontSize: 12)),
          if (_import.logLocation != null) ...[
            const SizedBox(height: 5),
            SelectableText('گزارش خطا روی گوشی: ${_import.logLocation}',
                style: const TextStyle(fontSize: 12)),
          ],
          if (_import.lastError != null) ...[
            const SizedBox(height: 6),
            SelectableText('آخرین خطا: ${_import.lastError}',
                style: const TextStyle(color: Colors.red, fontSize: 12)),
          ],
          if (_import.busy)
            Align(alignment: Alignment.centerLeft,
              child: TextButton(
                  onPressed: _import.cancel, child: const Text('توقف ایمن'))),
        ]),
      ),
    );
  }

  Widget _pager() {
    final start = _rows.isEmpty ? 0 : _page * _pageSize + 1;
    final end = _page * _pageSize + _rows.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Wrap(
          spacing: 12, runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Text('$start تا $end${_count == null ? '' : ' از $_count'}',
                style: const TextStyle(fontSize: 12)),
            TextButton(
              onPressed: _busy || _counting ? null : () async {
                setState(() => _counting = true);
                final generation = _searchGeneration;
                try {
                  final count = await _database.count(_filter);
                  if (mounted && generation == _searchGeneration) {
                    setState(() => _count = count);
                  }
                } catch (_) {
                  _message('شمارش دقیق انجام نشد');
                } finally {
                  if (mounted) setState(() => _counting = false);
                }
              },
              child: const Text('شمارش دقیق'),
            ),
            DropdownButton<int>(
              value: _pageSize,
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 20, child: Text('۲۰ تایی')),
                DropdownMenuItem(value: 50, child: Text('۵۰ تایی')),
                DropdownMenuItem(value: 100, child: Text('۱۰۰ تایی')),
              ],
              onChanged: (size) {
                if (size == null) return;
                setState(() => _pageSize = size);
                _load(resetPage: true);
              },
            ),
            IconButton(
              tooltip: 'صفحه قبل',
              onPressed: !_busy && _page > 0 ? () {
                _page--;
                _load();
              } : null,
              icon: const Icon(Icons.chevron_right),
            ),
            Text('صفحه ${_page + 1}'),
            IconButton(
              tooltip: 'صفحه بعد',
              onPressed: !_busy && _hasNext ? () {
                _pageCursors.removeRange(_page + 1, _pageCursors.length);
                _pageCursors.add(_rows.last['id'] as int);
                _page++;
                _load();
              } : null,
              icon: const Icon(Icons.chevron_left),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/brand/userinfo_logo.png',
                height: 30, width: 30,
                semanticLabel: 'لوگوی UserInfo'),
            const SizedBox(width: 8),
            const Text('UserInfo',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: 'ایمپورت CSV',
            onPressed: _import.busy ? null : _pickAndImport,
          ),
          IconButton(
            icon: const Icon(Icons.filter_list),
            tooltip: 'فیلترها',
            onPressed: _openFilters,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'تنظیمات',
            onPressed: _openSettings,
          ),
          IconButton(
            tooltip: _favoritesOnly ? 'نمایش همه' : 'فقط علاقه‌مندی‌ها',
            icon: Icon(_favoritesOnly
                ? Icons.star_rounded : Icons.star_border_rounded),
            onPressed: () {
              setState(() => _favoritesOnly = !_favoritesOnly);
              _load(resetPage: true);
            },
          ),
          PopupMenuButton<String>(
            onSelected: (item) {
              if (item == 'export') _showExportOptions();
              if (item == 'delete') _deleteEverything();
              if (item == 'backup') _backupDatabase();
              if (item == 'restore') _restoreDatabase();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'export', child: Text('خروجی PDF / Excel')),
              PopupMenuItem(value: 'backup', child: Text('بکاپ کامل SQLite')),
              PopupMenuItem(value: 'restore', child: Text('بازیابی دیتابیس')),
              PopupMenuItem(value: 'delete', child: Text('حذف همه اطلاعات')),
            ],
          ),
        ],
      ),
      body: Stack(children: [
        SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(children: [
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'name', icon: Icon(Icons.person_search, size: 16),
                    label: Text('نام و فامیل')),
                  ButtonSegment(value: 'mobile', icon: Icon(Icons.phone_android, size: 16),
                    label: Text('موبایل')),
                  ButtonSegment(value: 'national', icon: Icon(Icons.badge_outlined, size: 16),
                    label: Text('کد ملی')),
                ],
                selected: {_searchType},
                onSelectionChanged: (items) {
                  setState(() {
                    _searchType = items.first;
                    _search.clear();
                  });
                  _load(resetPage: true);
                },
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _search,
              keyboardType: _searchType == 'name' ? TextInputType.text
                  : TextInputType.phone,
              onChanged: (value) {
                setState(() {});
                _onSearchChanged(value);
              },
              decoration: InputDecoration(
                hintText: _searchType == 'name' ? 'نام یا نام خانوادگی...'
                    : _searchType == 'mobile' ? 'شماره موبایل...' : 'کد ملی...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty ? null : IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    setState(_search.clear);
                    _load(resetPage: true);
                  },
                ),
              ),
            ),
            if (_indexStatus != null && !_indexStatus!.ready)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('در حال ساخت ایندکس جستجو: '
                          '${(_indexStatus!.fraction * 100).toStringAsFixed(1)}٪',
                          style: const TextStyle(fontSize: 12)),
                      Text('برآورد اولیه فضای باقی‌مانده ایندکس: حدود '
                          '${((_indexStatus!.target - _indexStatus!.done) * 256 / 1048576).ceil()} مگابایت؛ بسته به داده متغیر است.',
                          style: const TextStyle(fontSize: 11)),
                      const SizedBox(height: 5),
                      LinearProgressIndicator(value: _indexStatus!.fraction),
                      const Text(
                        'رکوردهای قبلی حذف نمی‌شوند. تا پایان ایندکس، '
                        'نتایج جستجو فقط شامل بخش ایندکس‌شده است.',
                        style: TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            if (_indexError != null)
              ListTile(
                leading: const Icon(Icons.warning_amber_rounded),
                title: const Text('خطا در ساخت ایندکس'),
                subtitle: Text(_indexError!),
                trailing: TextButton(
                  onPressed: _buildNameIndex,
                  child: const Text('تلاش مجدد'),
                ),
              ),
            if (_maintenanceBusy)
              const LinearProgressIndicator(),
            if (_showImportSummary) _progressPanel(),
            if (_partialRecords > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Text(
                  '$_partialRecords رکورد از ایمپورت‌های ناقص حفظ شده‌اند. '
                  'ادامه خودکار فقط برای فایل‌های شروع‌شده در نسخه جدید پشتیبانی می‌شود.',
                  style: const TextStyle(color: Color(0xFF895400), fontSize: 12),
                ),
              ),
            const SizedBox(height: 8),
            if (_selected.isNotEmpty)
              Card(child: Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('${_selected.length} انتخاب‌شده'),
                      TextButton.icon(
                        onPressed: _shareSelection,
                        icon: const Icon(Icons.share_outlined, size: 18),
                        label: const Text('اشتراک‌گذاری'),
                      ),
                      TextButton.icon(
                        onPressed: _copySelection,
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('کپی منتخب'),
                      ),
                      TextButton.icon(
                        onPressed: _showExportOptions,
                        icon: const Icon(Icons.ios_share, size: 18),
                        label: const Text('خروجی')),
                      IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: 'لغو انتخاب',
                        onPressed: () => setState(_selected.clear),
                      ),
                    ]),
              )),
            Row(children: [
              Expanded(child: Text(_count == null ? 'نتایج جستجو' : '$_count نتیجه',
                  style: const TextStyle(fontWeight: FontWeight.bold))),
              TextButton(
                onPressed: _rows.isEmpty ? null : () => setState(() {
                  for (final row in _rows) {
                    _selected.add(row['id'] as int);
                  }
                }),
                child: const Text('انتخاب این صفحه'),
              ),
            ]),
            Expanded(child: _busy
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? const Center(child: Text(
                        'رکوردی یافت نشد. ابتدا فایل CSV وارد کن.'))
                    : ListView.builder(
                        itemCount: _rows.length,
                        itemBuilder: (context, i) =>
                            _personCard(_rows[i], _page * _pageSize + i),
                      )),
            _pager(),
          ]),
        ),
      ),
      if (_maintenanceBusy && _restoreProgress != null)
        _restoreOverlay(),
      ]),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _restoreTicker?.cancel();
    _search.dispose();
    _import.removeListener(_onImportChanged);
    _import.dispose();
    _database.dispose();
    super.dispose();
  }
}
