"""Read back every durable row for an alternating two-tenant fresh-commit workload."""
import argparse
from contextlib import closing
from itertools import zip_longest
import json
from pathlib import Path
import shutil
import sqlite3
import tempfile


def check(database, count):
    if type(count) is not int or count < 1:
        raise ValueError("expected a positive fresh commit count")
    sizes = ((count + 1) // 2, count // 2)

    def expected(table):
        for tenant, size in enumerate(sizes):
            if table == "tenants":
                yield tenant, size
                continue
            for job in range(size):
                key, digest = 4294967296 + job, job % 2
                if table == "reports":
                    yield tenant, job, digest, bytes([digest])
                elif table == "jobs":
                    yield tenant, job, job, "pending"
                else:
                    yield tenant, key, digest, tenant, key, digest, job, job

    queries = {
        "tenants": "SELECT tenant, next FROM tenants ORDER BY tenant",
        "reports": "SELECT tenant, id, digest, payload FROM reports ORDER BY tenant, id",
        "jobs": "SELECT tenant, id, report, status FROM jobs ORDER BY tenant, id",
        "request_keys": "SELECT tenant,key,digest,r_tenant,r_key,r_digest,r_report,r_job "
                        "FROM request_keys ORDER BY tenant,key",
    }
    # The runner has stopped the service. Open a private copy so SQLite can
    # rebuild the shared-memory index and recover committed WAL frames.
    with tempfile.TemporaryDirectory() as temp:
        snapshot = Path(temp) / "jobs.db"
        shutil.copyfile(database, snapshot)
        wal = Path(str(database) + "-wal")
        if wal.exists():
            shutil.copyfile(wal, Path(str(snapshot) + "-wal"))
        with closing(sqlite3.connect(snapshot)) as db:
            db.execute("BEGIN")
            if db.execute("PRAGMA integrity_check(1)").fetchone() != ("ok",):
                raise ValueError("SQLite database integrity check failed")
            if db.execute("PRAGMA foreign_key_check").fetchone() is not None:
                raise ValueError("SQLite foreign key check failed")
            if db.execute("PRAGMA user_version").fetchone() != (1,):
                raise ValueError("unexpected durable store format version")
            metadata = db.execute("SELECT k, v FROM meta ORDER BY k")
            if metadata.fetchmany(3) != [("schema", "fenrir.host.service-store/1"), ("upgrade", "v1")]:
                raise ValueError("unexpected durable store version metadata")
            for table, sql in queries.items():
                for index, (row, want) in enumerate(zip_longest(db.execute(sql), expected(table))):
                    if row != want:
                        raise ValueError(f"{table} row {index} differs: expected {want!r}, got {row!r}")
    return dict(commits=count, tenant_counts=list(sizes), checked_tables=list(queries))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path)
    parser.add_argument("count", type=int)
    args = parser.parse_args()
    print(json.dumps(check(args.database, args.count)))
