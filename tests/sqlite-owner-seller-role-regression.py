#!/usr/bin/env python3
"""Regression checks for the offline SQLite owner/seller role migration."""
from pathlib import Path
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = (ROOT / "docs/SQLITE_MIGRATION_OWNER_SELLER_ROLES.sql").read_text(encoding="utf-8")
SCHEMA = (ROOT / "docs/SQLITE_SCHEMA_PHASE1_FIXED.md").read_text(encoding="utf-8")

assert "CHECK(id IN ('owner', 'cashier'))" in SCHEMA
assert "CHECK(role_id IN ('owner', 'cashier'))" in SCHEMA
assert "('admin'," not in SCHEMA
assert "('accountant'," not in SCHEMA
assert "('stock_keeper'," not in SCHEMA
assert "('cashier',      'كاشير'" not in SCHEMA

def make_db(*, legacy_assignment=False, inactive_legacy_user=False):
    db = sqlite3.connect(":memory:")
    db.executescript("""
        PRAGMA foreign_keys=ON;
        CREATE TABLE users(id TEXT PRIMARY KEY, is_active INTEGER NOT NULL);
        CREATE TABLE roles(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT,
            is_active INTEGER NOT NULL
        );
        CREATE TABLE role_permissions(role_id TEXT, permission_id TEXT);
        CREATE TABLE user_roles(user_id TEXT, role_id TEXT);
        INSERT INTO roles VALUES
          ('owner','المالك','full',1),
          ('admin','مدير','legacy admin',1),
          ('accountant','محاسب','legacy accountant',1),
          ('cashier','كاشير','seller compatibility key',1),
          ('stock_keeper','أمين مخزن','legacy stock',1);
        INSERT INTO users VALUES ('legacy-user',1);
        INSERT INTO role_permissions VALUES
          ('owner','p-owner'),('admin','p-admin'),
          ('accountant','p-accountant'),('cashier','p-seller'),
          ('stock_keeper','p-stock');
    """)
    if legacy_assignment:
        db.execute("INSERT INTO user_roles VALUES ('legacy-user','admin')")
    elif inactive_legacy_user:
        db.execute("UPDATE users SET is_active=0 WHERE id='legacy-user'")
        db.execute("INSERT INTO user_roles VALUES ('legacy-user','admin')")
    else:
        db.execute("INSERT INTO user_roles VALUES ('legacy-user','cashier')")
    return db

# An active legacy assignment must stop the migration without changing role state.
blocked = make_db(legacy_assignment=True)
try:
    blocked.executescript(MIGRATION)
    raise AssertionError("Migration accepted an active legacy role assignment")
except sqlite3.IntegrityError:
    blocked.rollback()
assert blocked.execute("SELECT is_active FROM roles WHERE id='admin'").fetchone()[0] == 1
assert blocked.execute("SELECT COUNT(*) FROM role_permissions WHERE role_id='admin'").fetchone()[0] == 1

# Historical assignments belonging to inactive users are retained, but disabled.
legacy = make_db(inactive_legacy_user=True)
legacy.executescript(MIGRATION)
assert legacy.execute("SELECT id FROM roles WHERE is_active=1 ORDER BY id").fetchall() == [
    ("cashier",), ("owner",)
]
assert legacy.execute(
    "SELECT COUNT(*) FROM role_permissions WHERE role_id IN ('admin','accountant','stock_keeper')"
).fetchone()[0] == 0
assert legacy.execute(
    "SELECT COUNT(*) FROM user_roles WHERE user_id='legacy-user' AND role_id='admin'"
).fetchone()[0] == 1
assert legacy.execute("SELECT name FROM roles WHERE id='cashier'").fetchone()[0] == "بائع"

# The same migration must also be safe on a fresh schema that contains only two roles.
fresh = sqlite3.connect(":memory:")
fresh.executescript("""
    CREATE TABLE users(id TEXT PRIMARY KEY, is_active INTEGER NOT NULL);
    CREATE TABLE roles(
        id TEXT PRIMARY KEY CHECK(id IN ('owner','cashier')),
        name TEXT NOT NULL, description TEXT, is_active INTEGER NOT NULL
    );
    CREATE TABLE role_permissions(
        role_id TEXT CHECK(role_id IN ('owner','cashier')), permission_id TEXT
    );
    CREATE TABLE user_roles(
        user_id TEXT, role_id TEXT CHECK(role_id IN ('owner','cashier'))
    );
    INSERT INTO roles VALUES
      ('owner','المالك','owner',1),('cashier','بائع','seller',1);
    INSERT INTO users VALUES ('seller-user',1);
    INSERT INTO user_roles VALUES ('seller-user','cashier');
    INSERT INTO role_permissions VALUES ('owner','p-owner'),('cashier','p-seller');
""")
fresh.executescript(MIGRATION)
assert fresh.execute("SELECT COUNT(*) FROM roles WHERE is_active=1").fetchone()[0] == 2
assert fresh.execute("SELECT COUNT(*) FROM user_roles").fetchone()[0] == 1

print("PASS: SQLite owner/seller schema and migration guard, legacy retention, permission removal and fresh-schema compatibility")
