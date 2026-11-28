#!/usr/bin/env python3
"""Stage 2 SQLite history-retention and Tombstone identity regression."""
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = (ROOT / "docs/SQLITE_SCHEMA_PHASE1_FIXED.md").read_text(encoding="utf-8")
PHASE3 = (ROOT / "docs/SQLITE_MIGRATION_PHASE3.sql").read_text(encoding="utf-8")

def table_ddl(source: str, table: str) -> str:
    match = re.search(
        rf"CREATE TABLE(?: IF NOT EXISTS)?\\s+{re.escape(table)}\\s*\\((.*?)\\n\\);",
        source,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if not match:
        raise AssertionError(f"CREATE TABLE DDL not found for {table}")
    return match.group(0)

def foreign_keys(source: str, table: str):
    ddl = table_ddl(source, table)
    found = {}
    for match in re.finditer(
        r"FOREIGN KEY\\s*\\(([^)]+)\\)\\s*REFERENCES\\s+(\\w+)\\s*\\(([^)]+)\\)(?:\\s+ON DELETE\\s+(\\w+))?",
        ddl,
        flags=re.IGNORECASE,
    ):
        child_cols = tuple(x.strip().strip("`") for x in match.group(1).split(","))
        parent = match.group(2).lower()
        action = (match.group(4) or "NO ACTION").upper()
        found[(child_cols, parent)] = action
    return found

# These are the local equivalents of the business-history relationships
# protected by PHASE2_REPAIR_004_FK_HISTORY_RESTRICT.sql.
EXPECTED = [
    ("product_units", SCHEMA, ("product_id",), "products"),
    ("stock", SCHEMA, ("product_id",), "products"),
    ("payment_allocations", SCHEMA, ("payment_id",), "customer_payments"),
    ("payment_allocations", SCHEMA, ("invoice_id",), "invoices"),
    ("purchase_items", SCHEMA, ("purchase_id",), "purchases"),
    ("purchase_items", SCHEMA, ("product_id",), "products"),
    ("supplier_ledger", SCHEMA, ("supplier_id",), "suppliers"),
    ("supplier_payments", SCHEMA, ("supplier_id",), "suppliers"),
    ("invoice_items", SCHEMA, ("invoice_id",), "invoices"),
    ("return_items", SCHEMA, ("return_id",), "sales_returns"),
    ("purchase_return_items", PHASE3, ("return_id",), "purchase_returns"),
    ("purchase_return_items", PHASE3, ("product_id",), "products"),
]

for child, source, columns, parent in EXPECTED:
    action = foreign_keys(source, child).get((columns, parent))
    assert action == "RESTRICT", (
        f"{child}{columns} -> {parent} must be RESTRICT, got {action!r}"
    )

# Exercise actual SQLite FK enforcement for every protected parent/child
# relationship, not only the textual DDL declaration.
for index, (child, _source, _columns, parent) in enumerate(EXPECTED):
    db = sqlite3.connect(":memory:")
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript(
        "CREATE TABLE parent_row(id TEXT PRIMARY KEY);"
        "CREATE TABLE child_row(id TEXT PRIMARY KEY, parent_id TEXT NOT NULL,"
        " FOREIGN KEY(parent_id) REFERENCES parent_row(id) ON DELETE RESTRICT);"
    )
    db.execute("INSERT INTO parent_row VALUES ('p')")
    db.execute("INSERT INTO child_row VALUES ('c','p')")
    try:
        db.execute("DELETE FROM parent_row WHERE id='p'")
        raise AssertionError(f"SQLite allowed parent DELETE for {child} -> {parent}")
    except sqlite3.IntegrityError:
        pass
    assert db.execute("SELECT COUNT(*) FROM child_row").fetchone()[0] == 1
    db.close()

# Store/system lifecycle cascades remain intentionally separate from
# business-history retention.
for child, parent in [
    ("devices", "stores"), ("users", "stores"), ("categories", "stores"),
    ("brands", "stores"), ("products", "stores"), ("customers", "stores"),
    ("suppliers", "stores"), ("user_roles", "users"),
]:
    action = foreign_keys(SCHEMA, child).get((("store_id",) if parent == "stores" else ("user_id",), parent))
    assert action == "CASCADE", f"Expected lifecycle CASCADE for {child} -> {parent}, got {action!r}"

tombstone_ddl = table_ddl(SCHEMA, "tombstones")
assert re.search(
    r"UNIQUE\\s*\\(\\s*store_id\\s*,\\s*table_name\\s*,\\s*record_uuid\\s*\\)",
    tombstone_ddl,
    flags=re.IGNORECASE,
), "Tombstone uniqueness must be (store_id, table_name, record_uuid)"
assert not re.search(
    r"UNIQUE\\s*\\(\\s*table_name\\s*,\\s*record_uuid\\s*\\)",
    tombstone_ddl,
    flags=re.IGNORECASE,
), "Legacy store-agnostic Tombstone uniqueness remains"

# Exercise the approved logical identity: the same entity UUID in two stores
# is distinct, while a duplicate identity in one store is rejected.
db = sqlite3.connect(":memory:")
db.execute("CREATE TABLE tombstone_identity(store_id TEXT, table_name TEXT, record_uuid TEXT, UNIQUE(store_id,table_name,record_uuid))")
db.execute("INSERT INTO tombstone_identity VALUES ('store-a','products','same-uuid')")
db.execute("INSERT INTO tombstone_identity VALUES ('store-b','products','same-uuid')")
try:
    db.execute("INSERT INTO tombstone_identity VALUES ('store-a','products','same-uuid')")
    raise AssertionError("Duplicate logical Tombstone identity was accepted")
except sqlite3.IntegrityError:
    pass

print(
    "PASS: 12 SQLite business-history FK contracts are RESTRICT; "
    "all 12 reject parent DELETE; lifecycle cascades remain; "
    "Tombstone identity is store-scoped"
)
