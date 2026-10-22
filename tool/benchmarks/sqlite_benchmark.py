"""Synthetic-only SQLite query/backfill benchmark; never opens a user database."""
import argparse, json, os, sqlite3, statistics, tempfile, time

def timed(fn, repeats=9):
    values=[]
    for _ in range(repeats):
        t=time.perf_counter(); fn(); values.append((time.perf_counter()-t)*1000)
    return {'p50_ms':statistics.median(values),'p95_ms':sorted(values)[-1]}

def run(n):
    with tempfile.TemporaryDirectory() as directory:
        db=sqlite3.connect(os.path.join(directory,'synthetic.sqlite'))
        db.executescript('''PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
        CREATE TABLE records(id INTEGER PRIMARY KEY, normalized_name TEXT, mobile TEXT);
        CREATE INDEX idx_mobile ON records(mobile);
        CREATE VIRTUAL TABLE fts USING fts4(normalized_name,tokenize=unicode61,order=DESC);''')
        t=time.perf_counter()
        for start in range(0,n,2000):
            db.executemany('INSERT INTO records VALUES(?,?,?)',
                ((i+1, 'نمونه ساختگی '+('حسینی محمدرضا' if i%1000==0 else 'آزمایشی')+str(i%500),f'09{i:09d}') for i in range(start,min(start+2000,n))))
            db.commit()
        insert=time.perf_counter()-t
        t=time.perf_counter(); db.execute('INSERT INTO fts(docid,normalized_name) SELECT id,normalized_name FROM records'); db.commit(); backfill=time.perf_counter()-t
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        before_bytes=os.path.getsize(os.path.join(directory,'synthetic.sqlite'))
        db.executescript('CREATE TABLE record_identifiers(record_id INTEGER PRIMARY KEY,mobile TEXT,national TEXT); CREATE INDEX idx_ident_mobile ON record_identifiers(mobile,record_id); CREATE INDEX idx_ident_national ON record_identifiers(national,record_id);')
        db.execute("INSERT INTO record_identifiers SELECT id,mobile,'0000000000' FROM records");db.commit()
        queries={
          'derived_identifier_range':("SELECT r.* FROM record_identifiers ids CROSS JOIN records r ON r.id=ids.record_id WHERE ids.mobile>=? AND ids.mobile<? ORDER BY r.id DESC LIMIT 20",('09000000100','09000000101')),
          'old_mobile_like':("SELECT * FROM records WHERE mobile LIKE ? ORDER BY id DESC LIMIT 20",('09000000100%',)),
          'mobile_range':("SELECT * FROM records WHERE mobile>=? AND mobile<? ORDER BY id DESC LIMIT 20",('09000000100','09000000101')),
          'old_name_fallback':("SELECT * FROM records WHERE normalized_name LIKE ? ORDER BY id DESC LIMIT 20",('%نامناموجود%',)),
          'fts_absent':("SELECT r.* FROM fts CROSS JOIN records r ON r.id=fts.docid WHERE fts MATCH ? ORDER BY fts.docid DESC LIMIT 20",('"نامناموجود*"',)),
          'fts_prefix':("SELECT r.* FROM fts CROSS JOIN records r ON r.id=fts.docid WHERE fts MATCH ? ORDER BY fts.docid DESC LIMIT 20",('"حسی*"',)),
          'deep_offset':('SELECT * FROM records ORDER BY id DESC LIMIT 20 OFFSET ?', (n-100,)),
          'keyset':('SELECT * FROM records WHERE id<? ORDER BY id DESC LIMIT 20',(101,)),
          'count':('SELECT COUNT(*) FROM records',()),
        }
        result={'rows':n,'sqlite':sqlite3.sqlite_version,'insert_rows_sec':n/insert,'backfill_rows_sec':n/backfill,'queries':{}}
        for key,(sql,args) in queries.items():
            result['queries'][key]={**timed(lambda:db.execute(sql,args).fetchall()),'plan':db.execute('EXPLAIN QUERY PLAN '+sql,args).fetchall()}
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        result['before_identifier_table_bytes']=before_bytes
        result['database_bytes']=os.path.getsize(os.path.join(directory,'synthetic.sqlite'))
        result['objects_bytes']=db.execute('SELECT name,SUM(pgsize) FROM dbstat GROUP BY name').fetchall()
        return result
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--rows',type=int,default=100000);p.add_argument('--output');a=p.parse_args()
    result=json.dumps(run(a.rows),ensure_ascii=False,indent=2)
    if a.output: open(a.output,'w').write(result+'\n')
    print(result)
