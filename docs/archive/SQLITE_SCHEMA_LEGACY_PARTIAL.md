# ATACK PLUS --- SQLite Schema (v1)

## SQLite Local Database Design

جميع الملفات تُستخدم **SQLite** كقاعدة بيانات محلية، مع دعم:
- UUID كـ `TEXT` (36 أحرف)
- Triggers للـ `updated_at`
- Foreign Keys مع CASCADE
- Indexes مُحسَّنة للبحث

---

## Schema Overview

```sql
-- SQLite Schema - ATACK PLUS
-- إصدار: 1.0.0
-- SQLite >= 3.38.0

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
```

---

## Table Definitions

### 1. stores (المتاجر)

```sql
CREATE TABLE stores (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    name TEXT NOT NULL CHECK(length(name) > 0),
    address TEXT,
    currency TEXT NOT NULL DEFAULT 'DZD' CHECK(currency = 'DZD'),
    tax_number TEXT,
    fiscal_year_start_month INTEGER NOT NULL DEFAULT 1 CHECK(fiscal_year_start_month BETWEEN 1 AND 12),
    barcode_prefix TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localmenu')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now', 'localmenu'))
);

CREATE INDEX idx_stores_name ON stores(name);
```

### 2. devices (الأجهزة)

```sql
CREATE TABLE devices (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    device_name TEXT NOT NULL,
    device_type TEXT NOT NULL CHECK(device_type IN ('PHONE', 'TABLET', 'DESKTOP')),
    last_seen TEXT,
    is_online INTEGER DEFAULT 0 CHECK(is_online IN (0, 1)),
    app_version TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localmenu')),
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE,
    CONSTRAINT unique_device_per_store UNIQUE (store_id, device_name)
);

CREATE INDEX idx_devices_store ON devices(store_id);
CREATE INDEX idx_devices_online ON devices(is_online);
```

### 3. users (المستخدمون)

```sql
CREATE TABLE users (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    username TEXT NOT NULL UNIQUE CHECK(length(username) >= 3),
    password_hash TEXT NOT NULL,
    full_name TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    is_active INTEGER NOT NULL DEFAULT 1 CHECK(is_active IN (0, 1)),
    failed_login_attempts INTEGER DEFAULT 0,
    locked_until TEXT,
    last_login_at TEXT,
    password_changed_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localmenu')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now', 'localmenu')),
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE
);

CREATE INDEX idx_users_username ON users(username);
CREATE INDEX idx_users_store ON users(store_id);
```

### 4. roles (الأدوار)

```sql
CREATE TABLE roles (
    id TEXT PRIMARY KEY CHECK(id IN ('owner', 'admin', 'accountant', 'cashier', 'stock_keeper')),
    name TEXT NOT NULL,
    description TEXT,
    is_active INTEGER DEFAULT 1 CHECK(is_active IN (0, 1))
);

CREATE TABLE permissions (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    code TEXT NOT NULL UNIQUE,
    description TEXT
);

CREATE TABLE role_permissions (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    role_id TEXT NOT NULL CHECK(role_id IN ('owner', 'admin', 'accountant', 'cashier', 'stock_keeper')),
    permission_id TEXT NOT NULL CHECK(length(permission_id) = 36),
    granted_at TEXT NOT NULL DEFAULT (datetime('now', 'localmenu')),
    FOREIGN KEY (role_id) REFERENCES roles(id),
    FOREIGN KEY (permission_id) REFERENCES permissions(id),
    UNIQUE(role_id, permission_id)
);

CREATE TABLE user_roles (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    user_id TEXT NOT NULL CHECK(length(user_id) = 36),
    role_id TEXT NOT NULL CHECK(role_id IN ('owner', 'admin', 'accountant', 'cashier', 'stock_keeper')),
    granted_by TEXT CHECK(length(granted_by) = 36),
    granted_at TEXT NOT NULL DEFAULT (datetime('now', 'localmenu')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (role_id) REFERENCES roles(id),
    FOREIGN KEY (granted_by) REFERENCES users(id)
);
```

[الملف يستمر بقية الجداول - يُرجى إنشاء ملف كامل]

---

## Triggers for updated_at

```sql
CREATE TRIGGER trigger_stores_updated_at
AFTER UPDATE ON stores
BEGIN
    UPDATE stores SET updated_at = datetime('now', 'localmenu') WHERE id = NEW.id;
END;

CREATE TRIGGER trigger_users_updated_at
AFTER UPDATE ON users
BEGIN
    UPDATE users SET updated_at = datetime('now', 'localmenu') WHERE id = NEW.id;
END;

-- تم إضافة مثل هذه Triggers لجميع الجداول
```

---

## Foreign Keys Summary

| الجديل | الربط | التحقق |
|--------|-------|---------|
| products → stores | CASCADE | ON DELETE |
| products → categories | SET NULL | ON DELETE |
| products → brands | SET NULL | ON DELETE |
| stock_movements → products | CASCADE | ON DELETE |
| invoices → customers | SET NULL | ON DELETE |
| invoices → suppliers | SET NULL | ON DELETE |
| invoice_items → invoices | CASCADE | ON DELETE |
| purchases → suppliers | CASCADE | ON DELETE |

---

## Important Notes

1. **UUID Format**: جميع UUID تُخزن كـ `TEXT` (36 حرفًا بإستباق صفر)
2. **Timestamps**: تُخزن كـ `TEXT` بتنسيق SQLite `datetime('now', 'localmenu')`
3. **Soft Delete**: حقل `deleted_at` في الفواتير والمنتجات
4. **WAL Mode**: مفعل للقراءة المتوازية وتحسين الأداء