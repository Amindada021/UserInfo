import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/csv_source.dart';
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
    return MaterialApp(
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
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const HomePage(),
    );
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
  final TextEditingController _search = TextEditingController();
  late final ImportController _import = ImportController(_database, _source);
  late final ExportService _export = ExportService();

  List<Map<String, Object?>> _rows = const [];
  final Set<int> _selected = {};
  bool _showFullDetails = false;
  String _searchType = 'name';
  Timer? _debounce;
  int _page = 0;
  int _pageSize = 20;
  int _count = 0;
  String _bank = '';
  bool _missingMobile = false;
  bool _busy = true;
  bool _showImportSummary = false;
  Map<String, String> _fieldFilters = {};
  String _birthFrom = '';
  String _birthTo = '';

  SearchFilters get _filter => SearchFilters(
        query: _search.text,
        searchType: _searchType,
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
    if (mounted) setState(() {});
  }

  Future<void> _bootstrap() async {
    try {
      await _database.discardInterruptedImports();
      _showFullDetails = await _database.showFullDetails();
      await _load();
    } catch (error) {
      _message('خطای راه‌اندازی دیتابیس: $error');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load({bool resetPage = false}) async {
    if (resetPage) _page = 0;
    if (mounted) setState(() => _busy = true);
    try {
      final count = await _database.count(_filter);
      final lastPage = count == 0 ? 0 : (count - 1) ~/ _pageSize;
      if (_page > lastPage) _page = lastPage;
      final rows = await _database.search(
          _filter, page: _page, pageSize: _pageSize);
      if (mounted) {
        setState(() {
          _count = count;
          _rows = rows;
        });
      }
    } catch (error) {
      _message('خطا در خواندن نتایج: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
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
    _debounce = Timer(const Duration(milliseconds: 350),
        () => _load(resetPage: true));
  }

  Future<void> _pickAndImport() async {
    if (_import.busy) return;
    try {
      final documents = await _source.pick();
      if (documents.isEmpty) return;
      if (mounted) setState(() => _showImportSummary = true);
      await _import.importDocuments(documents);
      if (_import.lastError != null) {
        _message('ایمپورت ناقص: ${_import.lastError}');
      } else {
        _message(_import.stage);
      }
      await _load(resetPage: true);
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
    final showFull = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('تنظیمات نمایش',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SwitchListTile.adaptive(
              title: const Text('نمایش اطلاعات کامل همه اشخاص'),
              subtitle: const Text('یک تنظیم برای تمام کارت‌ها، نه جداگانه برای هر شخص'),
              value: _showFullDetails,
              onChanged: (v) => Navigator.pop(sheetContext, v),
            ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
    if (showFull == null || showFull == _showFullDetails) return;
    if (showFull && !await _confirmSensitive()) return;
    await _database.setShowFullDetails(showFull);
    if (mounted) setState(() => _showFullDetails = showFull);
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

  Widget _personCard(Map<String, Object?> row) {
    final id = row['id'] as int;
    final name = row['full_name']?.toString() ?? 'بدون نام';
    final visible = _showFullDetails;
    return Card(
      key: ValueKey(id),
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
          const SizedBox(height: 8),
          LinearProgressIndicator(value: fraction),
          const SizedBox(height: 4),
          Text(fraction == null
                  ? 'درصد نامعلوم (حجم فایل اعلام نشده)'
                  : '${(fraction * 100).toStringAsFixed(1)}٪ از بایت‌های ورودی خوانده شده',
              style: const TextStyle(fontSize: 12)),
          if (_import.busy)
            Align(alignment: Alignment.centerLeft,
              child: TextButton(
                  onPressed: _import.cancel, child: const Text('توقف ایمن'))),
        ]),
      ),
    );
  }

  Widget _pager() {
    final start = _count == 0 ? 0 : _page * _pageSize + 1;
    final end = (_page + 1) * _pageSize > _count
        ? _count : (_page + 1) * _pageSize;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Wrap(
          spacing: 12, runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Text('$start تا $end از $_count',
                style: const TextStyle(fontSize: 12)),
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
              onPressed: _page > 0 ? () {
                _page--;
                _load();
              } : null,
              icon: const Icon(Icons.chevron_right),
            ),
            Text('صفحه ${_page + 1}'),
            IconButton(
              tooltip: 'صفحه بعد',
              onPressed: end < _count ? () {
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
        title: const Text('UserInfo',
            style: TextStyle(fontWeight: FontWeight.w700)),
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
          PopupMenuButton<String>(
            onSelected: (item) {
              if (item == 'export') _showExportOptions();
              if (item == 'delete') _deleteEverything();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'export', child: Text('خروجی PDF / Excel')),
              PopupMenuItem(value: 'delete', child: Text('حذف همه اطلاعات')),
            ],
          ),
        ],
      ),
      body: SafeArea(
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
            if (_showImportSummary) _progressPanel(),
            const SizedBox(height: 8),
            if (_selected.isNotEmpty)
              Card(child: Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('${_selected.length} انتخاب‌شده'),
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
              Expanded(child: Text('$_count نتیجه',
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
                        itemBuilder: (context, i) => _personCard(_rows[i]),
                      )),
            _pager(),
          ]),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _import.removeListener(_onImportChanged);
    _import.dispose();
    _database.dispose();
    super.dispose();
  }
}
