"""Small controlled host experiments, not Android throughput predictions."""
import json, os, sqlite3, tempfile, time

def matrix(n=100000):
    output=[]
    for journal,sync,cache,temp,mmap in [('DELETE','FULL',2048,'DEFAULT',0),('WAL','FULL',2048,'DEFAULT',0),('WAL','NORMAL',2048,'DEFAULT',0),('WAL','FULL',8192,'MEMORY',0),('WAL','FULL',8192,'MEMORY',67108864)]:
        for batch in [1000,2000,5000]:
            with tempfile.TemporaryDirectory() as d:
                filename=os.path.join(d,'synthetic.db'); db=sqlite3.connect(filename)
                db.executescript(f'PRAGMA journal_mode={journal}; PRAGMA synchronous={sync}; PRAGMA cache_size=-{cache}; PRAGMA temp_store={temp}; PRAGMA mmap_size={mmap}; CREATE TABLE r(id INTEGER PRIMARY KEY,n TEXT); CREATE INDEX idx_n ON r(n);')
                t=time.perf_counter()
                for start in range(0,n,batch):
                    db.executemany('INSERT INTO r VALUES(?,?)',((i,'نمونه ساختگی '+str(i%1000)) for i in range(start,min(start+batch,n))))
                    db.commit()
                elapsed=time.perf_counter()-t
                output.append(dict(journal=journal,sync=sync,cache_kib=cache,temp=temp,mmap=mmap,batch=batch,rows_sec=n/elapsed,db_bytes=os.path.getsize(filename),wal_bytes=os.path.getsize(filename+'-wal') if os.path.exists(filename+'-wal') else 0))
                db.close()
    engines=[]
    for engine in ['fts4','fts5','token','btree']:
        with tempfile.TemporaryDirectory() as d:
            filename=os.path.join(d,'synthetic.db');db=sqlite3.connect(filename)
            try:
                if engine in ['fts4','fts5']:
                    db.execute(f'CREATE VIRTUAL TABLE names USING {engine}(name)')
                    sql='INSERT INTO names(rowid,name) VALUES(?,?)'
                else:
                    db.execute('CREATE TABLE names(id INTEGER, name TEXT)')
                    db.execute('CREATE INDEX idx_names ON names(name,id)')
                    sql='INSERT INTO names VALUES(?,?)'
                t=time.perf_counter()
                for start in range(0,n,2000):
                    if engine=='token':
                        rows=((i,word) for i in range(start,start+2000) for word in ('نمونه','ساختگی',str(i%1000)))
                    else: rows=((i,'نمونه ساختگی '+str(i%1000)) for i in range(start,start+2000))
                    db.executemany(sql,rows);db.commit()
                elapsed=time.perf_counter()-t
                if engine in ['fts4','fts5']: query="SELECT rowid FROM names WHERE names MATCH 'ساخت*' LIMIT 20"
                else: query="SELECT id FROM names WHERE name>='ساخت' AND name<'ساخث' LIMIT 20"
                t=time.perf_counter(); count=len(db.execute(query).fetchall());ms=(time.perf_counter()-t)*1000
                engines.append(dict(engine=engine,rows_sec=n/elapsed,db_bytes=os.path.getsize(filename),query_ms=ms,result_count=count))
            except sqlite3.OperationalError as e: engines.append(dict(engine=engine,available=False,error=str(e)))
            finally: db.close()
    return {'rows':n,'sqlite':sqlite3.sqlite_version,'settings':output,'engines':engines,'note':'B-tree cannot match non-leading name words. Token index result is single-term only; not equivalent to FTS AND. No Android claim.'}
if __name__=='__main__': print(json.dumps(matrix(),ensure_ascii=False,indent=2))
