"""Synthetic host regression; not a 100M/device acceptance benchmark.

Creates an in-memory database only. Models a highly duplicated identifier,
which exposes the old range + ID sort even with an existing covering index.
"""
import json
import sqlite3
import statistics
import time

db = sqlite3.connect(':memory:')
db.executescript('''
CREATE TABLE records(id INTEGER PRIMARY KEY, mobile TEXT);
CREATE TABLE record_identifiers(record_id INTEGER PRIMARY KEY, mobile TEXT, national TEXT);
CREATE INDEX idx_ident_mobile ON record_identifiers(mobile, record_id);
''')
db.executemany('INSERT INTO records VALUES (?, ?)',
               ((i, '09120000000') for i in range(1, 1000001)))
db.execute('INSERT INTO record_identifiers SELECT id, mobile, NULL FROM records')
base = ('SELECT r.* FROM record_identifiers ids INDEXED BY idx_ident_mobile '
        'CROSS JOIN records r ON r.id=ids.record_id WHERE ')
queries = {
    'old': (base + 'ids.mobile>=? AND ids.mobile<? ORDER BY r.id DESC LIMIT 21',
            ['09120000000', '09120000000\U0010ffff']),
    'new': (base + 'ids.mobile=? ORDER BY ids.record_id DESC LIMIT 21', ['09120000000']),
}
report = {'sqlite': sqlite3.sqlite_version, 'synthetic_rows': 1000000,
          'scope': 'In-memory host SQL regression, not Flutter/device/100M acceptance'}
results = {}
for name, (sql, args) in queries.items():
    elapsed = []
    for _ in range(5):
        start = time.perf_counter()
        results[name] = db.execute(sql, args).fetchall()
        elapsed.append((time.perf_counter() - start) * 1000)
    report[name] = {'median_ms': statistics.median(elapsed),
                    'plan': [r[3] for r in db.execute('EXPLAIN QUERY PLAN ' + sql, args)]}
assert results['old'] == results['new']
assert not any('TEMP B-TREE' in p for p in report['new']['plan'])
assert any('SEARCH ids USING COVERING INDEX' in p for p in report['new']['plan'])
print(json.dumps(report, indent=2))
