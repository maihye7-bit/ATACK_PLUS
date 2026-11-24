# ATACK PLUS --- SQLite Schema (v1)

## قاعدة البيانات المحلية SQLite

### ملاحظات هامة

- يستخدم **TEXT** لتخزين UUID (36 حرف مع الفواصل القياسية: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)
- الصيغة الصحيحة للوقت الموحد: `datetime('now')` يعيد UTC في SQLite
- نفعّل `PRAGMA foreign_keys = ON` في كل اتصال بالقاعدة
- `WAL` mode مفعل لتحسين الأداء مع القراءة المتوازية
- `updated_at` يُحدث عبر BEFORE UPDATE trigger لتجنب recursion من AFTER UPDATE + self-update

---

```sql
-- ATACK PLUS - SQLite Local Database Schema v1
-- إصدار: 1.0.0
-- SQLite >= 3.38.0
-- جميع التواريخ مخزنة كـ TEXT بصيغة ISO 8601 UTC (datetime('now'))

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA recursive_triggers = ON;
```

---

## 1. stores (المتاجر)

```sql
CREATE TABLE stores (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),              -- UUID
    name TEXT NOT NULL CHECK(length(name) > 0),
    address TEXT,
    currency TEXT NOT NULL DEFAULT 'DZD' CHECK(currency = 'DZD'),
    tax_number TEXT,
    fiscal_year_start_month INTEGER NOT NULL DEFAULT 1 CHECK(fiscal_year_start_month BETWEEN 1 AND 12),
    barcode_prefix TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_stores_name ON stores(name);
```

---

## 2. devices (الأجهزة)

```sql
CREATE TABLE devices (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),              -- UUID
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    device_name TEXT NOT NULL,
    device_type TEXT NOT NULL CHECK(device_type IN ('PHONE', 'TABLET', 'DESKTOP')),
    last_seen TEXT,
    is_online INTEGER DEFAULT 0 CHECK(is_online IN (0, 1)),
    app_version TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE,
    CONSTRAINT unique_device_per_store UNIQUE (store_id, device_name)
);

CREATE INDEX idx_devices_store ON devices(store_id);
CREATE INDEX idx_devices_online ON devices(is_online);
```

---

## 3. users (المستخدمون)

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
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE
);

CREATE INDEX idx_users_username ON users(username);
CREATE INDEX idx_users_store ON users(store_id);
```

---

## 4. roles و permissions

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
    granted_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (role_id) REFERENCES roles(id),
    FOREIGN KEY (permission_id) REFERENCES permissions(id),
    UNIQUE(role_id, permission_id)
);

CREATE TABLE user_roles (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    user_id TEXT NOT NULL CHECK(length(user_id) = 36),
    role_id TEXT NOT NULL CHECK(role_id IN ('owner', 'admin', 'accountant', 'cashier', 'stock_keeper')),
    granted_by TEXT CHECK(length(granted_by) = 36),
    granted_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (role_id) REFERENCES roles(id),
    FOREIGN KEY (granted_by) REFERENCES users(id)
);
```

---

## 5. units

```sql
CREATE TABLE units (
    id TEXT PRIMARY KEY CHECK(id IN ('pcs', 'g', 'kg', 'liter', 'box', 'carton')),
    name TEXT NOT NULL,
    symbol TEXT,
    is_active INTEGER DEFAULT 1 CHECK(is_active IN (0, 1)),
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
```

---

## 6. categories و brands و products

```sql
CREATE TABLE categories (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    parent_id TEXT CHECK(parent_id IS NULL OR length(parent_id) = 36),
    name TEXT NOT NULL,
    code TEXT,
    sort_order INTEGER DEFAULT 0,
    is_active INTEGER DEFAULT 1 CHECK(is_active IN (0, 1)),
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE,
    FOREIGN KEY (parent_id) REFERENCES categories(id)
);

CREATE UNIQUE INDEX uq_categories_store_code ON categories(store_id, code) WHERE code IS NOT NULL;

CREATE TABLE brands (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    name TEXT NOT NULL,
    scent TEXT,
    size TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE
);

CREATE TABLE products (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    barcode TEXT,
    name TEXT NOT NULL,
    description TEXT,
    category_id TEXT CHECK(length(category_id) = 36),
    brand_id TEXT CHECK(length(brand_id) = 36),
    primary_unit_id TEXT NOT NULL CHECK(primary_unit_id IN ('pcs', 'g', 'kg', 'liter', 'box', 'carton')),
    cost_price NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(cost_price >= 0),
    default_sale_price NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(default_sale_price >= 0),
    tax_rate NUMERIC(5,2) DEFAULT 0 CHECK(tax_rate BETWEEN 0 AND 100),
    minimum_stock NUMERIC(18,4) DEFAULT 0 CHECK(minimum_stock >= 0),
    max_stock NUMERIC(18,4) CHECK(max_stock IS NULL OR max_stock >= minimum_stock),
    weight NUMERIC(10,3),
    length NUMERIC(10,3),
    width NUMERIC(10,3),
    height NUMERIC(10,3),
    expiry_enabled INTEGER DEFAULT 0 CHECK(expiry_enabled IN (0, 1)),
    batch_enabled INTEGER DEFAULT 0 CHECK(batch_enabled IN (0, 1)),
    is_active INTEGER NOT NULL DEFAULT 1 CHECK(is_active IN (0, 1)),
    deleted_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE,
    FOREIGN KEY (category_id) REFERENCES categories(id),
    FOREIGN KEY (brand_id) REFERENCES brands(id),
    FOREIGN KEY (primary_unit_id) REFERENCES units(id)
);

CREATE INDEX idx_products_barcode ON products(barcode);
CREATE INDEX idx_products_name ON products(name);
CREATE INDEX idx_products_store ON products(store_id);
CREATE INDEX idx_products_category ON products(category_id);
CREATE INDEX idx_products_brand ON products(brand_id);
CREATE INDEX idx_products_active ON products(is_active);
CREATE UNIQUE INDEX uq_products_store_barcode ON products(store_id, barcode) WHERE barcode IS NOT NULL;
```

---

## 7. product_units

```sql
CREATE TABLE product_units (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    product_id TEXT NOT NULL CHECK(length(product_id) = 36),
    unit_id TEXT NOT NULL CHECK(unit_id IN ('pcs', 'g', 'kg', 'liter', 'box', 'carton')),
    conversion_factor NUMERIC(18,6) NOT NULL CHECK(conversion_factor > 0),
    sale_price NUMERIC(18,4) CHECK(sale_price >= 0),
    purchase_price NUMERIC(18,4) CHECK(purchase_price >= 0),
    is_primary INTEGER DEFAULT 0 CHECK(is_primary IN (0, 1)),
    is_default INTEGER DEFAULT 0 CHECK(is_default IN (0, 1)),
    sort_order INTEGER DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
    FOREIGN KEY (unit_id) REFERENCES units(id),
    UNIQUE(product_id, unit_id)
);

CREATE INDEX idx_product_units_product ON product_units(product_id);
CREATE INDEX idx_product_units_unit ON product_units(unit_id);
```

---

## 8. stock و stock_movements

```sql
CREATE TABLE locations (
    id TEXT PRIMARY KEY CHECK(id IN ('main', 'warehouse', 'storage')),
    name TEXT NOT NULL,
    is_default INTEGER DEFAULT 0 CHECK(is_default IN (0, 1))
);

CREATE TABLE stock (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    product_id TEXT NOT NULL CHECK(length(product_id) = 36),
    location_id TEXT NOT NULL DEFAULT 'main',
    quantity NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(quantity >= 0),
    reserved_quantity NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(reserved_quantity >= 0 AND reserved_quantity <= quantity),
    available_quantity NUMERIC(18,4) GENERATED ALWAYS AS (quantity - reserved_quantity) STORED,
    last_updated TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
    FOREIGN KEY (location_id) REFERENCES locations(id),
    CONSTRAINT unique_product_location UNIQUE (product_id, location_id)
);

CREATE INDEX idx_stock_product ON stock(product_id);
CREATE INDEX idx_stock_location ON stock(location_id);

CREATE TABLE stock_movements (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    product_id TEXT NOT NULL CHECK(length(product_id) = 36),
    location_id TEXT NOT NULL DEFAULT 'main',
    type TEXT NOT NULL CHECK(type IN ('IN', 'OUT', 'ADJUSTMENT', 'RETURN_IN', 'RETURN_OUT')),
    quantity NUMERIC(18,4) NOT NULL CHECK(quantity > 0),
    unit_id TEXT NOT NULL CHECK(unit_id IN ('pcs', 'g', 'kg', 'liter', 'box', 'carton')),
    cost_per_unit NUMERIC(18,4) NOT NULL CHECK(cost_per_unit >= 0),
    total_value NUMERIC(18,4) NOT NULL CHECK(total_value >= 0),
    reference_id TEXT CHECK(length(reference_id) = 36),
    reference_type TEXT CHECK(reference_type IN ('invoice', 'purchase', 'adjustment', 'return')),
    batch_number TEXT,
    expiry_date TEXT,
    reason TEXT,
    user_id TEXT NOT NULL CHECK(length(user_id) = 36),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (product_id) REFERENCES products(id),
    FOREIGN KEY (unit_id) REFERENCES units(id),
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX idx_stock_movements_product ON stock_movements(product_id);
CREATE INDEX idx_stock_movements_date ON stock_movements(created_at);
CREATE INDEX idx_stock_movements_reference ON stock_movements(reference_type, reference_id);
CREATE INDEX idx_stock_movements_sync ON stock_movements(sync_status);
```

---

## 8. customers و customer_ledgers و payments

```sql
CREATE TABLE customers (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    address TEXT,
    city TEXT,
    tax_number TEXT,
    credit_limit NUMERIC(18,4) DEFAULT 0 CHECK(credit_limit >= 0),
    current_debt NUMERIC(18,4) DEFAULT 0 CHECK(current_debt >= 0),
    total_sales NUMERIC(18,4) DEFAULT 0 CHECK(total_sales >= 0),
    is_active INTEGER DEFAULT 1 CHECK(is_active IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX uq_customers_store_code ON customers(store_id, code);

CREATE TABLE customer_ledgers (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    customer_id TEXT NOT NULL CHECK(length(customer_id) = 36),
    type TEXT NOT NULL CHECK(type IN ('SALE', 'PAYMENT', 'RETURN', 'ADJUSTMENT')),
    amount NUMERIC(18,4) NOT NULL,
    balance NUMERIC(18,4) NOT NULL,
    reference_id TEXT CHECK(length(reference_id) = 36),
    description TEXT,
    created_by TEXT NOT NULL CHECK(length(created_by) = 36),
    device_sync_id TEXT,
    is_synced INTEGER DEFAULT 0 CHECK(is_synced IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (customer_id) REFERENCES customers(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE INDEX idx_customer_ledgers_customer ON customer_ledgers(customer_id);
CREATE INDEX idx_customer_ledgers_date ON customer_ledgers(created_at);

CREATE TABLE customer_payments (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    customer_id TEXT NOT NULL CHECK(length(customer_id) = 36),
    amount NUMERIC(18,4) NOT NULL CHECK(amount > 0),
    payment_method TEXT NOT NULL CHECK(payment_method IN ('CASH', 'CARD', 'BANK_TRANSFER', 'MOBILE')),
    reference_no TEXT,
    notes TEXT,
    created_by TEXT NOT NULL CHECK(length(created_by) = 36),
    device_sync_id TEXT,
    is_synced INTEGER DEFAULT 0 CHECK(is_synced IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (customer_id) REFERENCES customers(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE TABLE payment_allocations (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    payment_id TEXT NOT NULL CHECK(length(payment_id) = 36),
    invoice_id TEXT NOT NULL CHECK(length(invoice_id) = 36),
    allocated_amount NUMERIC(18,4) NOT NULL CHECK(allocated_amount > 0),
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (payment_id) REFERENCES customer_payments(id) ON DELETE CASCADE,
    FOREIGN KEY (invoice_id) REFERENCES invoices(id) ON DELETE CASCADE,
    UNIQUE(payment_id, invoice_id)
);
```

---

## 9. suppliers و purchases

```sql
CREATE TABLE suppliers (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    address TEXT,
    city TEXT,
    tax_number TEXT,
    contact_person TEXT,
    payment_terms TEXT,
    current_debt NUMERIC(18,4) DEFAULT 0 CHECK(current_debt >= 0),
    is_active INTEGER DEFAULT 1 CHECK(is_active IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX uq_suppliers_store_code ON suppliers(store_id, code);

CREATE TABLE purchases (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    purchase_number TEXT NOT NULL,
    supplier_id TEXT NOT NULL CHECK(length(supplier_id) = 36),
    grn_number TEXT,
    supplier_invoice_no TEXT,
    supplier_invoice_amount NUMERIC(18,4),
    purchase_date TEXT NOT NULL,
    received_date TEXT,
    subtotal NUMERIC(18,4) DEFAULT 0,
    discount_total NUMERIC(18,4) DEFAULT 0,
    tax_total NUMERIC(18,4) DEFAULT 0,
    total_amount NUMERIC(18,4) DEFAULT 0,
    paid_amount NUMERIC(18,4) DEFAULT 0,
    remaining_amount NUMERIC(18,4) DEFAULT 0,
    payment_method TEXT CHECK(payment_method IN ('CASH', 'CARD', 'BANK_TRANSFER', 'MOBILE')),
    notes TEXT,
    created_by TEXT NOT NULL CHECK(length(created_by) = 36),
    device_sync_id TEXT,
    is_synced INTEGER DEFAULT 0 CHECK(is_synced IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    status TEXT CHECK(status IN ('DRAFT', 'OPEN', 'PARTIAL', 'PAID', 'CANCELLED')) DEFAULT 'OPEN',
    deleted_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (supplier_id) REFERENCES suppliers(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE UNIQUE INDEX uq_purchases_store_number ON purchases(store_id, purchase_number);

CREATE TABLE purchase_items (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    purchase_id TEXT NOT NULL CHECK(length(purchase_id) = 36),
    product_id TEXT NOT NULL CHECK(length(product_id) = 36),
    quantity NUMERIC(18,4) NOT NULL CHECK(quantity > 0),
    quantity_unit_id TEXT NOT NULL CHECK(quantity_unit_id IN ('pcs', 'g', 'kg', 'liter', 'box', 'carton')),
    unit_price NUMERIC(18,4) NOT NULL CHECK(unit_price >= 0),
    cost_per_unit NUMERIC(18,4) NOT NULL CHECK(cost_per_unit >= 0),
    tax_rate NUMERIC(5,2) DEFAULT 0,
    tax_amount NUMERIC(18,4) DEFAULT 0,
    line_total NUMERIC(18,4) NOT NULL,
    batch_number TEXT,
    expiry_date TEXT,
    received INTEGER DEFAULT 0 CHECK(received IN (0, 1)),
    received_date TEXT,
    is_synced INTEGER DEFAULT 0 CHECK(is_synced IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (purchase_id) REFERENCES purchases(id) ON DELETE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
    FOREIGN KEY (quantity_unit_id) REFERENCES units(id) ON DELETE RESTRICT
);
```

---

## 10b. supplier_ledger و supplier_payments

```sql
CREATE TABLE supplier_ledger (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    supplier_id TEXT NOT NULL CHECK(length(supplier_id) = 36),
    type TEXT NOT NULL CHECK(type IN ('PURCHASE', 'PAYMENT', 'ADJUSTMENT')),
    amount NUMERIC(18,4) NOT NULL,
    balance NUMERIC(18,4) NOT NULL,
    reference_id TEXT CHECK(length(reference_id) = 36),
    description TEXT,
    created_by TEXT NOT NULL CHECK(length(created_by) = 36),
    device_sync_id TEXT,
    is_synced INTEGER DEFAULT 0 CHECK(is_synced IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (supplier_id) REFERENCES suppliers(id) ON DELETE CASCADE,
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE INDEX idx_supplier_ledger_supplier ON supplier_ledger(supplier_id);
CREATE INDEX idx_supplier_ledger_date ON supplier_ledger(created_at);

CREATE TABLE supplier_payments (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    supplier_id TEXT NOT NULL CHECK(length(supplier_id) = 36),
    amount NUMERIC(18,4) NOT NULL CHECK(amount > 0),
    payment_method TEXT NOT NULL CHECK(payment_method IN ('CASH', 'CARD', 'BANK_TRANSFER', 'MOBILE')),
    reference_no TEXT,
    notes TEXT,
    created_by TEXT NOT NULL CHECK(length(created_by) = 36),
    device_sync_id TEXT,
    is_synced INTEGER DEFAULT 0 CHECK(is_synced IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (supplier_id) REFERENCES suppliers(id) ON DELETE CASCADE,
    FOREIGN KEY (created_by) REFERENCES users(id)
);
```

---

## 11. invoices و invoice_items

```sql
CREATE TABLE invoices (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    invoice_number TEXT NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('SALE', 'PURCHASE')),
    customer_id TEXT CHECK(customer_id IS NULL OR length(customer_id) = 36),
    supplier_id TEXT CHECK(supplier_id IS NULL OR length(supplier_id) = 36),
    invoice_date TEXT NOT NULL,
    due_date TEXT,
    subtotal NUMERIC(18,4) NOT NULL DEFAULT 0,
    discount_total NUMERIC(18,4) DEFAULT 0,
    tax_total NUMERIC(18,4) DEFAULT 0,
    total_amount NUMERIC(18,4) NOT NULL DEFAULT 0,
    paid_amount NUMERIC(18,4) DEFAULT 0,
    remaining_amount NUMERIC(18,4) DEFAULT 0,
    payment_method TEXT CHECK(payment_method IN ('CASH', 'CARD', 'BANK_TRANSFER', 'MOBILE')),
    notes TEXT,
    created_by TEXT NOT NULL CHECK(length(created_by) = 36),
    device_sync_id TEXT,
    is_synced INTEGER DEFAULT 0 CHECK(is_synced IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    status TEXT CHECK(status IN ('DRAFT', 'OPEN', 'PAID', 'PARTIAL', 'CANCELLED', 'DELETED')) DEFAULT 'OPEN',
    deleted_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (customer_id) REFERENCES customers(id),
    FOREIGN KEY (supplier_id) REFERENCES suppliers(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE INDEX idx_invoices_number ON invoices(invoice_number);
CREATE INDEX idx_invoices_customer ON invoices(customer_id);
CREATE INDEX idx_invoices_supplier ON invoices(supplier_id);
CREATE INDEX idx_invoices_status ON invoices(status);
CREATE INDEX idx_invoices_date ON invoices(invoice_date);
CREATE INDEX idx_invoices_synced ON invoices(is_synced);

CREATE UNIQUE INDEX uq_invoices_store_number ON invoices(store_id, invoice_number);

CREATE TABLE invoice_items (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    invoice_id TEXT NOT NULL CHECK(length(invoice_id) = 36),
    product_id TEXT NOT NULL CHECK(length(product_id) = 36),
    quantity NUMERIC(18,4) NOT NULL CHECK(quantity > 0),
    quantity_unit_id TEXT NOT NULL CHECK(quantity_unit_id IN ('pcs', 'g', 'kg', 'liter', 'box', 'carton')),
    unit_price NUMERIC(18,4) NOT NULL CHECK(unit_price >= 0),
    cost_per_unit NUMERIC(18,4) CHECK(cost_per_unit >= 0),
    discount_percent NUMERIC(5,2) DEFAULT 0 CHECK(discount_percent BETWEEN 0 AND 100),
    discount_amount NUMERIC(18,4) DEFAULT 0,
    tax_rate NUMERIC(5,2) DEFAULT 0,
    tax_amount NUMERIC(18,4) DEFAULT 0,
    line_total NUMERIC(18,4) NOT NULL,
    batch_number TEXT,
    expiry_date TEXT,
    is_synced INTEGER DEFAULT 0 CHECK(is_synced IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (invoice_id) REFERENCES invoices(id) ON DELETE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(id),
    FOREIGN KEY (quantity_unit_id) REFERENCES units(id)
);

CREATE INDEX idx_invoice_items_invoice ON invoice_items(invoice_id);
CREATE INDEX idx_invoice_items_product ON invoice_items(product_id);
CREATE INDEX idx_invoice_items_sync ON invoice_items(sync_status);
```

---

## 11. sales_returns

```sql
CREATE TABLE sales_returns (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    return_number TEXT NOT NULL,
    original_invoice_id TEXT NOT NULL CHECK(length(original_invoice_id) = 36),
    reason TEXT,
    total_amount NUMERIC(18,4) NOT NULL DEFAULT 0,
    refund_method TEXT CHECK(refund_method IN ('CREDIT', 'CASH', 'EXCHANGE')),
    notes TEXT,
    created_by TEXT NOT NULL CHECK(length(created_by) = 36),
    device_sync_id TEXT,
    is_synced INTEGER DEFAULT 0 CHECK(is_synced IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (original_invoice_id) REFERENCES invoices(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE UNIQUE INDEX uq_returns_store_number ON sales_returns(store_id, return_number);

CREATE TABLE return_items (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    return_id TEXT NOT NULL CHECK(length(return_id) = 36),
    product_id TEXT NOT NULL CHECK(length(product_id) = 36),
    quantity NUMERIC(18,4) NOT NULL CHECK(quantity > 0),
    unit_price NUMERIC(18,4) NOT NULL CHECK(unit_price >= 0),
    line_total NUMERIC(18,4) NOT NULL,
    batch_number TEXT,
    expiry_date TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (return_id) REFERENCES sales_returns(id) ON DELETE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(id)
);
```

---

## 12. expenses و revenues

```sql
CREATE TABLE expenses (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    category TEXT NOT NULL,
    description TEXT,
    amount NUMERIC(18,4) NOT NULL,
    expense_date TEXT NOT NULL,
    payment_method TEXT CHECK(payment_method IN ('CASH', 'CARD', 'BANK_TRANSFER', 'MOBILE')),
    receipt_number TEXT,
    attachment_path TEXT,
    created_by TEXT NOT NULL CHECK(length(created_by) = 36),
    device_sync_id TEXT,
    is_synced INTEGER DEFAULT 0 CHECK(is_synced IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE TABLE revenues (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    category TEXT NOT NULL,
    description TEXT,
    amount NUMERIC(18,4) NOT NULL,
    revenue_date TEXT NOT NULL,
    source TEXT,
    created_by TEXT NOT NULL CHECK(length(created_by) = 36),
    device_sync_id TEXT,
    is_synced INTEGER DEFAULT 0 CHECK(is_synced IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);
```

---

## 13. نظام المزامنة (Sync System)

```sql
CREATE TABLE processed_operations (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    operation_id TEXT NOT NULL CHECK(length(operation_id) = 36),
    operation_type TEXT NOT NULL CHECK(operation_type IN ('sync_insert', 'sync_update', 'sync_delete', 'sync_conflict')),
    entity_table TEXT NOT NULL,
    entity_uuid TEXT NOT NULL CHECK(length(entity_uuid) = 36),
    payload_hash TEXT NOT NULL,
    processed_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(store_id, operation_id)
);

CREATE INDEX idx_processed_ops_store ON processed_operations(store_id);
CREATE INDEX idx_processed_ops_entity ON processed_operations(entity_table, entity_uuid);
CREATE INDEX idx_processed_ops_hash ON processed_operations(payload_hash);

CREATE TABLE sync_cursors (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    device_id TEXT NOT NULL,
    table_name TEXT NOT NULL,
    cursor_value TEXT,
    last_pull_seq BIGINT DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    UNIQUE(store_id, device_id, table_name)
);

CREATE TABLE change_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    sync_cursor INTEGER NOT NULL,
    table_name TEXT NOT NULL,
    record_uuid TEXT NOT NULL CHECK(length(record_uuid) = 36),
    operation TEXT NOT NULL CHECK(operation IN ('INSERT', 'UPDATE', 'DELETE')),
    old_values_json TEXT,
    new_values_json TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_change_log_cursor ON change_log(sync_cursor);
CREATE INDEX idx_change_log_table ON change_log(table_name);
CREATE INDEX idx_change_log_record ON change_log(record_uuid);
CREATE INDEX idx_change_log_created ON change_log(created_at);

CREATE TABLE sync_outbox (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    device_id TEXT NOT NULL,
    table_name TEXT NOT NULL,
    operation TEXT NOT NULL CHECK(operation IN ('INSERT', 'UPDATE', 'DELETE')),
    record_uuid TEXT NOT NULL CHECK(length(record_uuid) = 36),
    idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) = 36),
    record_json TEXT NOT NULL,
    payload_hash TEXT NOT NULL,
    status TEXT DEFAULT 'PENDING' CHECK(status IN ('PENDING', 'IN_PROGRESS', 'SYNCED', 'FAILED', 'CONFLICT')),
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3,
    error_message TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    last_attempt TEXT,
    synced_at TEXT,
    FOREIGN KEY (store_id) REFERENCES stores(id)
);

CREATE INDEX idx_outbox_status ON sync_outbox(status);
CREATE INDEX idx_outbox_store ON sync_outbox(store_id);
CREATE INDEX idx_outbox_table ON sync_outbox(table_name);
CREATE INDEX idx_outbox_created ON sync_outbox(created_at);
CREATE INDEX idx_outbox_idempotency ON sync_outbox(idempotency_key);

CREATE TABLE sync_conflicts (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    table_name TEXT NOT NULL,
    record_uuid TEXT NOT NULL CHECK(length(record_uuid) = 36),
    conflict_type TEXT NOT NULL CHECK(conflict_type IN ('INVENTORY', 'INVOICE', 'CUSTOMER_DEBT', 'PRICE', 'DUPLICATE')),
    local_record_json TEXT NOT NULL,
    remote_record_json TEXT NOT NULL,
    resolution_status TEXT DEFAULT 'PENDING' CHECK(resolution_status IN ('PENDING', 'ACCEPT_LOCAL', 'ACCEPT_REMOTE', 'MERGE')),
    resolution_notes TEXT,
    resolved_by TEXT CHECK(length(resolved_by) = 36),
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    resolved_at TEXT,
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (resolved_by) REFERENCES users(id)
);

CREATE INDEX idx_conflicts_pending ON sync_conflicts(resolution_status) WHERE resolution_status = 'PENDING';

CREATE TABLE tombstones (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    table_name TEXT NOT NULL,
    record_uuid TEXT NOT NULL CHECK(length(record_uuid) = 36),
    deleted_at TEXT NOT NULL DEFAULT (datetime('now')),
    deleted_by TEXT NOT NULL CHECK(length(deleted_by) = 36),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('PENDING', 'SYNCED', 'ERROR')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (deleted_by) REFERENCES users(id),
    CONSTRAINT unique_tombstone UNIQUE (table_name, record_uuid)
);

CREATE INDEX idx_tombstones_store ON tombstones(store_id);
CREATE INDEX idx_tombstones_record ON tombstones(table_name, record_uuid);
CREATE INDEX idx_tombstones_sync ON tombstones(sync_status);
CREATE INDEX idx_tombstones_deleted_at ON tombstones(deleted_at);

CREATE TABLE sync_log (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    device_id TEXT NOT NULL,
    operation TEXT NOT NULL CHECK(operation IN ('PUSH', 'PULL', 'FULL_SYNC', 'CONFLICT_RESOLUTION')),
    status TEXT NOT NULL CHECK(status IN ('STARTED', 'SUCCESS', 'ERROR', 'CONFLICT')),
    records_processed INTEGER DEFAULT 0,
    duration_seconds REAL,
    error_message TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id)
);
```

---

## 14. audit_logs (سجل التدقيق)

```sql
CREATE TABLE audit_logs (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    user_id TEXT NOT NULL CHECK(length(user_id) = 36),
    entity_type TEXT,
    entity_id TEXT CHECK(length(entity_id) = 36),
    action TEXT NOT NULL CHECK(action IN ('CREATE', 'UPDATE', 'DELETE', 'VOID', 'SYNC')),
    old_values_json TEXT,
    new_values_json TEXT,
    ip_address TEXT,
    device_id TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX idx_audit_logs_date ON audit_logs(created_at);
CREATE INDEX idx_audit_logs_entity ON audit_logs(entity_type, entity_id);
CREATE INDEX idx_audit_logs_user ON audit_logs(user_id);
```

---

## 15. Triggers (更新 updated_at 时间戳)

SQLite 触发器模式：AFTER UPDATE + 自更新，并以 WHEN 防止递归触发

```sql
CREATE TRIGGER trg_stores_updated_at
AFTER UPDATE ON stores FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE stores SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = OLD.id;
END;

CREATE TRIGGER trg_users_updated_at
AFTER UPDATE ON users FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE users SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = OLD.id;
END;

CREATE TRIGGER trg_categories_updated_at
AFTER UPDATE ON categories FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE categories SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = OLD.id;
END;

CREATE TRIGGER trg_brands_updated_at
AFTER UPDATE ON brands FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE brands SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = OLD.id;
END;

CREATE TRIGGER trg_products_updated_at
AFTER UPDATE ON products FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE products SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = OLD.id;
END;

CREATE TRIGGER trg_customers_updated_at
AFTER UPDATE ON customers FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE customers SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = OLD.id;
END;

CREATE TRIGGER trg_suppliers_updated_at
AFTER UPDATE ON suppliers FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE suppliers SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = OLD.id;
END;

CREATE TRIGGER trg_purchases_updated_at
AFTER UPDATE ON purchases FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE purchases SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = OLD.id;
END;

CREATE TRIGGER trg_invoices_updated_at
AFTER UPDATE ON invoices FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE invoices SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = OLD.id;
END;

CREATE TRIGGER trg_sales_returns_updated_at
AFTER UPDATE ON sales_returns FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE sales_returns SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = OLD.id;
END;

CREATE TRIGGER trg_customer_payments_updated_at
AFTER UPDATE ON customer_payments FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE customer_payments SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = OLD.id;
END;

CREATE TRIGGER trg_supplier_payments_updated_at
AFTER UPDATE ON supplier_payments FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE supplier_payments SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = OLD.id;
END;

CREATE TRIGGER trg_sync_cursors_updated_at
AFTER UPDATE ON sync_cursors FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE sync_cursors SET updated_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = OLD.id;
END;

CREATE TRIGGER trg_sync_conflicts_resolved_at
AFTER UPDATE ON sync_conflicts FOR EACH ROW
WHEN NEW.resolution_status != OLD.resolution_status AND NEW.resolved_at IS OLD.resolved_at
BEGIN
    UPDATE sync_conflicts SET resolved_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = OLD.id;
END;

-- Trigger لتحديث stock.last_updated عند تغيير الكميات
CREATE TRIGGER trg_stock_last_updated
AFTER UPDATE OF quantity, reserved_quantity ON stock FOR EACH ROW
WHEN NEW.last_updated IS OLD.last_updated
BEGIN
    UPDATE stock SET last_updated = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = OLD.id;
END;

-- ============================================================
-- Change Log Triggers — تعبئة change_log تلقائياً
-- ============================================================
CREATE TRIGGER trg_stores_log_change
AFTER INSERT ON stores
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, new_values_json)
    VALUES (NEW.id,
            (SELECT COALESCE(MAX(sync_cursor), 0) + 1 FROM change_log WHERE store_id = NEW.id),
            'stores', NEW.id, 'INSERT', json_object(
                'id', NEW.id, 'store_id', NEW.id, 'name', NEW.name,
                'address', NEW.address, 'currency', NEW.currency,
                'tax_number', NEW.tax_number, 'fiscal_year_start_month', NEW.fiscal_year_start_month,
                'barcode_prefix', NEW.barcode_prefix, 'created_at', NEW.created_at, 'updated_at', NEW.updated_at
            ));
END;

CREATE TRIGGER trg_stores_log_change_upd
AFTER UPDATE ON stores
WHEN NEW.id IS NOT OLD.id OR NEW.name IS NOT OLD.name OR NEW.address IS NOT OLD.address OR NEW.currency IS NOT OLD.currency OR NEW.tax_number IS NOT OLD.tax_number OR NEW.fiscal_year_start_month IS NOT OLD.fiscal_year_start_month OR NEW.barcode_prefix IS NOT OLD.barcode_prefix OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.id,
            (SELECT COALESCE(MAX(sync_cursor), 0) + 1 FROM change_log WHERE store_id = NEW.id),
            'stores', NEW.id, 'UPDATE',
            json_object(
                'id', OLD.id, 'store_id', OLD.id, 'name', OLD.name,
                'address', OLD.address, 'currency', OLD.currency,
                'tax_number', OLD.tax_number, 'fiscal_year_start_month', OLD.fiscal_year_start_month,
                'barcode_prefix', OLD.barcode_prefix, 'created_at', OLD.created_at, 'updated_at', OLD.updated_at
            ),
            json_object(
                'id', NEW.id, 'store_id', NEW.id, 'name', NEW.name,
                'address', NEW.address, 'currency', NEW.currency,
                'tax_number', NEW.tax_number, 'fiscal_year_start_month', NEW.fiscal_year_start_month,
                'barcode_prefix', NEW.barcode_prefix, 'created_at', NEW.created_at, 'updated_at', NEW.updated_at
            ));
END;

CREATE TRIGGER trg_stores_log_change_del
AFTER DELETE ON stores
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json)
    VALUES (OLD.id,
            (SELECT COALESCE(MAX(sync_cursor), 0) + 1 FROM change_log WHERE store_id = OLD.id),
            'stores', OLD.id, 'DELETE',
            json_object(
                'id', OLD.id, 'store_id', OLD.id, 'name', OLD.name,
                'address', OLD.address, 'currency', OLD.currency,
                'tax_number', OLD.tax_number, 'fiscal_year_start_month', OLD.fiscal_year_start_month,
                'barcode_prefix', OLD.barcode_prefix, 'created_at', OLD.created_at, 'updated_at', OLD.updated_at
            ));
END;

-- تكرار نفس النمط للجداول التجارية الرئيسية:
-- products, customers, suppliers, purchases, invoices, sales_returns,
-- customer_payments, supplier_payments, stock_movements
-- (للاختصار يتم تفعيلها في التطبيق عند الحاجة، لكن التريجرات أعلاه كافية كنموذج)

-- Products triggers
CREATE TRIGGER trg_products_log_change
AFTER INSERT ON products
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, new_values_json)
    VALUES (NEW.store_id,
            (SELECT COALESCE(MAX(sync_cursor), 0) + 1 FROM change_log WHERE store_id = NEW.store_id),
            'products', NEW.id, 'INSERT', json_object(
                'id', NEW.id, 'store_id', NEW.store_id, 'barcode', NEW.barcode,
                'name', NEW.name, 'description', NEW.description, 'category_id', NEW.category_id,
                'brand_id', NEW.brand_id, 'primary_unit_id', NEW.primary_unit_id,
                'cost_price', NEW.cost_price, 'default_sale_price', NEW.default_sale_price,
                'tax_rate', NEW.tax_rate, 'minimum_stock', NEW.minimum_stock, 'max_stock', NEW.max_stock,
                'weight', NEW.weight, 'length', NEW.length, 'width', NEW.width, 'height', NEW.height,
                'expiry_enabled', NEW.expiry_enabled, 'batch_enabled', NEW.batch_enabled,
                'is_active', NEW.is_active, 'deleted_at', NEW.deleted_at,
                'created_at', NEW.created_at, 'updated_at', NEW.updated_at
            ));
END;

CREATE TRIGGER trg_products_log_change_upd
AFTER UPDATE ON products
WHEN NEW.id IS NOT OLD.id OR NEW.store_id IS NOT OLD.store_id OR NEW.barcode IS NOT OLD.barcode OR NEW.name IS NOT OLD.name OR NEW.description IS NOT OLD.description OR NEW.category_id IS NOT OLD.category_id OR NEW.brand_id IS NOT OLD.brand_id OR NEW.primary_unit_id IS NOT OLD.primary_unit_id OR NEW.cost_price IS NOT OLD.cost_price OR NEW.default_sale_price IS NOT OLD.default_sale_price OR NEW.tax_rate IS NOT OLD.tax_rate OR NEW.minimum_stock IS NOT OLD.minimum_stock OR NEW.max_stock IS NOT OLD.max_stock OR NEW.weight IS NOT OLD.weight OR NEW.length IS NOT OLD.length OR NEW.width IS NOT OLD.width OR NEW.height IS NOT OLD.height OR NEW.expiry_enabled IS NOT OLD.expiry_enabled OR NEW.batch_enabled IS NOT OLD.batch_enabled OR NEW.is_active IS NOT OLD.is_active OR NEW.deleted_at IS NOT OLD.deleted_at OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id,
            (SELECT COALESCE(MAX(sync_cursor), 0) + 1 FROM change_log WHERE store_id = NEW.store_id),
            'products', NEW.id, 'UPDATE',
            json_object(
                'id', OLD.id, 'store_id', OLD.store_id, 'barcode', OLD.barcode,
                'name', OLD.name, 'description', OLD.description, 'category_id', OLD.category_id,
                'brand_id', OLD.brand_id, 'primary_unit_id', OLD.primary_unit_id,
                'cost_price', OLD.cost_price, 'default_sale_price', OLD.default_sale_price,
                'tax_rate', OLD.tax_rate, 'minimum_stock', OLD.minimum_stock, 'max_stock', OLD.max_stock,
                'weight', OLD.weight, 'length', OLD.length, 'width', OLD.width, 'height', OLD.height,
                'expiry_enabled', OLD.expiry_enabled, 'batch_enabled', OLD.batch_enabled,
                'is_active', OLD.is_active, 'deleted_at', OLD.deleted_at,
                'created_at', OLD.created_at, 'updated_at', OLD.updated_at
            ),
            json_object(
                'id', NEW.id, 'store_id', NEW.store_id, 'barcode', NEW.barcode,
                'name', NEW.name, 'description', NEW.description, 'category_id', NEW.category_id,
                'brand_id', NEW.brand_id, 'primary_unit_id', NEW.primary_unit_id,
                'cost_price', NEW.cost_price, 'default_sale_price', NEW.default_sale_price,
                'tax_rate', NEW.tax_rate, 'minimum_stock', NEW.minimum_stock, 'max_stock', NEW.max_stock,
                'weight', NEW.weight, 'length', NEW.length, 'width', NEW.width, 'height', NEW.height,
                'expiry_enabled', NEW.expiry_enabled, 'batch_enabled', NEW.batch_enabled,
                'is_active', NEW.is_active, 'deleted_at', NEW.deleted_at,
                'created_at', NEW.created_at, 'updated_at', NEW.updated_at
            ));
END;

CREATE TRIGGER trg_products_log_change_del
AFTER DELETE ON products
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json)
    VALUES (OLD.store_id,
            (SELECT COALESCE(MAX(sync_cursor), 0) + 1 FROM change_log WHERE store_id = OLD.store_id),
            'products', OLD.id, 'DELETE',
            json_object(
                'id', OLD.id, 'store_id', OLD.store_id, 'barcode', OLD.barcode,
                'name', OLD.name, 'description', OLD.description, 'category_id', OLD.category_id,
                'brand_id', OLD.brand_id, 'primary_unit_id', OLD.primary_unit_id,
                'cost_price', OLD.cost_price, 'default_sale_price', OLD.default_sale_price,
                'tax_rate', OLD.tax_rate, 'minimum_stock', OLD.minimum_stock, 'max_stock', OLD.max_stock,
                'weight', OLD.weight, 'length', OLD.length, 'width', OLD.width, 'height', OLD.height,
                'expiry_enabled', OLD.expiry_enabled, 'batch_enabled', OLD.batch_enabled,
                'is_active', OLD.is_active, 'deleted_at', OLD.deleted_at,
                'created_at', OLD.created_at, 'updated_at', OLD.updated_at
            ));
END;

-- Customers triggers
CREATE TRIGGER trg_customers_log_change
AFTER INSERT ON customers
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, new_values_json)
    VALUES (NEW.store_id,
            (SELECT COALESCE(MAX(sync_cursor), 0) + 1 FROM change_log WHERE store_id = NEW.store_id),
            'customers', NEW.id, 'INSERT', json_object(
                'id', NEW.id, 'store_id', NEW.store_id, 'code', NEW.code,
                'name', NEW.name, 'email', NEW.email, 'phone', NEW.phone,
                'address', NEW.address, 'city', NEW.city, 'tax_number', NEW.tax_number,
                'credit_limit', NEW.credit_limit, 'current_debt', NEW.current_debt,
                'total_sales', NEW.total_sales, 'is_active', NEW.is_active,
                'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at,
                'created_at', NEW.created_at, 'updated_at', NEW.updated_at
            ));
END;

CREATE TRIGGER trg_customers_log_change_upd
AFTER UPDATE ON customers
WHEN NEW.id IS NOT OLD.id OR NEW.store_id IS NOT OLD.store_id OR NEW.code IS NOT OLD.code OR NEW.name IS NOT OLD.name OR NEW.email IS NOT OLD.email OR NEW.phone IS NOT OLD.phone OR NEW.address IS NOT OLD.address OR NEW.city IS NOT OLD.city OR NEW.tax_number IS NOT OLD.tax_number OR NEW.credit_limit IS NOT OLD.credit_limit OR NEW.current_debt IS NOT OLD.current_debt OR NEW.total_sales IS NOT OLD.total_sales OR NEW.is_active IS NOT OLD.is_active OR NEW.sync_status IS NOT OLD.sync_status OR NEW.synced_at IS NOT OLD.synced_at OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id,
            (SELECT COALESCE(MAX(sync_cursor), 0) + 1 FROM change_log WHERE store_id = NEW.store_id),
            'customers', NEW.id, 'UPDATE',
            json_object(
                'id', OLD.id, 'store_id', OLD.store_id, 'code', OLD.code,
                'name', OLD.name, 'email', OLD.email, 'phone', OLD.phone,
                'address', OLD.address, 'city', OLD.city, 'tax_number', OLD.tax_number,
                'credit_limit', OLD.credit_limit, 'current_debt', OLD.current_debt,
                'total_sales', OLD.total_sales, 'is_active', OLD.is_active,
                'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at,
                'created_at', OLD.created_at, 'updated_at', OLD.updated_at
            ),
            json_object(
                'id', NEW.id, 'store_id', NEW.store_id, 'code', NEW.code,
                'name', NEW.name, 'email', NEW.email, 'phone', NEW.phone,
                'address', NEW.address, 'city', NEW.city, 'tax_number', NEW.tax_number,
                'credit_limit', NEW.credit_limit, 'current_debt', NEW.current_debt,
                'total_sales', NEW.total_sales, 'is_active', NEW.is_active,
                'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at,
                'created_at', NEW.created_at, 'updated_at', NEW.updated_at
            ));
END;

CREATE TRIGGER trg_customers_log_change_del
AFTER DELETE ON customers
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json)
    VALUES (OLD.store_id,
            (SELECT COALESCE(MAX(sync_cursor), 0) + 1 FROM change_log WHERE store_id = OLD.store_id),
            'customers', OLD.id, 'DELETE',
            json_object(
                'id', OLD.id, 'store_id', OLD.store_id, 'code', OLD.code,
                'name', OLD.name, 'email', OLD.email, 'phone', OLD.phone,
                'address', OLD.address, 'city', OLD.city, 'tax_number', OLD.tax_number,
                'credit_limit', OLD.credit_limit, 'current_debt', OLD.current_debt,
                'total_sales', OLD.total_sales, 'is_active', OLD.is_active,
                'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at,
                'created_at', OLD.created_at, 'updated_at', OLD.updated_at
            ));
END;

-- Suppliers triggers
CREATE TRIGGER trg_suppliers_log_change
AFTER INSERT ON suppliers
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, new_values_json)
    VALUES (NEW.store_id,
            (SELECT COALESCE(MAX(sync_cursor), 0) + 1 FROM change_log WHERE store_id = NEW.store_id),
            'suppliers', NEW.id, 'INSERT', json_object(
                'id', NEW.id, 'store_id', NEW.store_id, 'code', NEW.code,
                'name', NEW.name, 'email', NEW.email, 'phone', NEW.phone,
                'address', NEW.address, 'city', NEW.city, 'tax_number', NEW.tax_number,
                'contact_person', NEW.contact_person, 'payment_terms', NEW.payment_terms,
                'current_debt', NEW.current_debt, 'is_active', NEW.is_active,
                'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at,
                'created_at', NEW.created_at, 'updated_at', NEW.updated_at
            ));
END;

CREATE TRIGGER trg_suppliers_log_change_upd
AFTER UPDATE ON suppliers
WHEN NEW.id IS NOT OLD.id OR NEW.store_id IS NOT OLD.store_id OR NEW.code IS NOT OLD.code OR NEW.name IS NOT OLD.name OR NEW.email IS NOT OLD.email OR NEW.phone IS NOT OLD.phone OR NEW.address IS NOT OLD.address OR NEW.city IS NOT OLD.city OR NEW.tax_number IS NOT OLD.tax_number OR NEW.contact_person IS NOT OLD.contact_person OR NEW.payment_terms IS NOT OLD.payment_terms OR NEW.current_debt IS NOT OLD.current_debt OR NEW.is_active IS NOT OLD.is_active OR NEW.sync_status IS NOT OLD.sync_status OR NEW.synced_at IS NOT OLD.synced_at OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id,
            (SELECT COALESCE(MAX(sync_cursor), 0) + 1 FROM change_log WHERE store_id = NEW.store_id),
            'suppliers', NEW.id, 'UPDATE',
            json_object(
                'id', OLD.id, 'store_id', OLD.store_id, 'code', OLD.code,
                'name', OLD.name, 'email', OLD.email, 'phone', OLD.phone,
                'address', OLD.address, 'city', OLD.city, 'tax_number', OLD.tax_number,
                'contact_person', OLD.contact_person, 'payment_terms', OLD.payment_terms,
                'current_debt', OLD.current_debt, 'is_active', OLD.is_active,
                'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at,
                'created_at', OLD.created_at, 'updated_at', OLD.updated_at
            ),
            json_object(
                'id', NEW.id, 'store_id', NEW.store_id, 'code', NEW.code,
                'name', NEW.name, 'email', NEW.email, 'phone', NEW.phone,
                'address', NEW.address, 'city', NEW.city, 'tax_number', NEW.tax_number,
                'contact_person', NEW.contact_person, 'payment_terms', NEW.payment_terms,
                'current_debt', NEW.current_debt, 'is_active', NEW.is_active,
                'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at,
                'created_at', NEW.created_at, 'updated_at', NEW.updated_at
            ));
END;

CREATE TRIGGER trg_suppliers_log_change_del
AFTER DELETE ON suppliers
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json)
    VALUES (OLD.store_id,
            (SELECT COALESCE(MAX(sync_cursor), 0) + 1 FROM change_log WHERE store_id = OLD.store_id),
            'suppliers', OLD.id, 'DELETE',
            json_object(
                'id', OLD.id, 'store_id', OLD.store_id, 'code', OLD.code,
                'name', OLD.name, 'email', OLD.email, 'phone', OLD.phone,
                'address', OLD.address, 'city', OLD.city, 'tax_number', OLD.tax_number,
                'contact_person', OLD.contact_person, 'payment_terms', OLD.payment_terms,
                'current_debt', OLD.current_debt, 'is_active', OLD.is_active,
                'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at,
                'created_at', OLD.created_at, 'updated_at', OLD.updated_at
            ));
END;

-- Invoices triggers
CREATE TRIGGER trg_invoices_log_change
AFTER INSERT ON invoices
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, new_values_json)
    VALUES (NEW.store_id,
            (SELECT COALESCE(MAX(sync_cursor), 0) + 1 FROM change_log WHERE store_id = NEW.store_id),
            'invoices', NEW.id, 'INSERT', json_object(
                'id', NEW.id, 'store_id', NEW.store_id, 'invoice_number', NEW.invoice_number,
                'type', NEW.type, 'customer_id', NEW.customer_id, 'supplier_id', NEW.supplier_id,
                'invoice_date', NEW.invoice_date, 'due_date', NEW.due_date,
                'subtotal', NEW.subtotal, 'discount_total', NEW.discount_total,
                'tax_total', NEW.tax_total, 'total_amount', NEW.total_amount,
                'paid_amount', NEW.paid_amount, 'remaining_amount', NEW.remaining_amount,
                'payment_method', NEW.payment_method, 'notes', NEW.notes,
                'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id,
                'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status,
                'synced_at', NEW.synced_at, 'status', NEW.status, 'deleted_at', NEW.deleted_at,
                'created_at', NEW.created_at, 'updated_at', NEW.updated_at
            ));
END;

CREATE TRIGGER trg_invoices_log_change_upd
AFTER UPDATE ON invoices
WHEN NEW.id IS NOT OLD.id OR NEW.store_id IS NOT OLD.store_id OR NEW.invoice_number IS NOT OLD.invoice_number OR NEW.type IS NOT OLD.type OR NEW.customer_id IS NOT OLD.customer_id OR NEW.supplier_id IS NOT OLD.supplier_id OR NEW.invoice_date IS NOT OLD.invoice_date OR NEW.due_date IS NOT OLD.due_date OR NEW.subtotal IS NOT OLD.subtotal OR NEW.discount_total IS NOT OLD.discount_total OR NEW.tax_total IS NOT OLD.tax_total OR NEW.total_amount IS NOT OLD.total_amount OR NEW.paid_amount IS NOT OLD.paid_amount OR NEW.remaining_amount IS NOT OLD.remaining_amount OR NEW.payment_method IS NOT OLD.payment_method OR NEW.notes IS NOT OLD.notes OR NEW.created_by IS NOT OLD.created_by OR NEW.device_sync_id IS NOT OLD.device_sync_id OR NEW.is_synced IS NOT OLD.is_synced OR NEW.sync_status IS NOT OLD.sync_status OR NEW.synced_at IS NOT OLD.synced_at OR NEW.status IS NOT OLD.status OR NEW.deleted_at IS NOT OLD.deleted_at OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id,
            (SELECT COALESCE(MAX(sync_cursor), 0) + 1 FROM change_log WHERE store_id = NEW.store_id),
            'invoices', NEW.id, 'UPDATE',
            json_object(
                'id', OLD.id, 'store_id', OLD.store_id, 'invoice_number', OLD.invoice_number,
                'type', OLD.type, 'customer_id', OLD.customer_id, 'supplier_id', OLD.supplier_id,
                'invoice_date', OLD.invoice_date, 'due_date', OLD.due_date,
                'subtotal', OLD.subtotal, 'discount_total', OLD.discount_total,
                'tax_total', OLD.tax_total, 'total_amount', OLD.total_amount,
                'paid_amount', OLD.paid_amount, 'remaining_amount', OLD.remaining_amount,
                'payment_method', OLD.payment_method, 'notes', OLD.notes,
                'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id,
                'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status,
                'synced_at', OLD.synced_at, 'status', OLD.status, 'deleted_at', OLD.deleted_at,
                'created_at', OLD.created_at, 'updated_at', OLD.updated_at
            ),
            json_object(
                'id', NEW.id, 'store_id', NEW.store_id, 'invoice_number', NEW.invoice_number,
                'type', NEW.type, 'customer_id', NEW.customer_id, 'supplier_id', NEW.supplier_id,
                'invoice_date', NEW.invoice_date, 'due_date', NEW.due_date,
                'subtotal', NEW.subtotal, 'discount_total', NEW.discount_total,
                'tax_total', NEW.tax_total, 'total_amount', NEW.total_amount,
                'paid_amount', NEW.paid_amount, 'remaining_amount', NEW.remaining_amount,
                'payment_method', NEW.payment_method, 'notes', NEW.notes,
                'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id,
                'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status,
                'synced_at', NEW.synced_at, 'status', NEW.status, 'deleted_at', NEW.deleted_at,
                'created_at', NEW.created_at, 'updated_at', NEW.updated_at
            ));
END;

CREATE TRIGGER trg_invoices_log_change_del
AFTER DELETE ON invoices
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json)
    VALUES (OLD.store_id,
            (SELECT COALESCE(MAX(sync_cursor), 0) + 1 FROM change_log WHERE store_id = OLD.store_id),
            'invoices', OLD.id, 'DELETE',
            json_object(
                'id', OLD.id, 'store_id', OLD.store_id, 'invoice_number', OLD.invoice_number,
                'type', OLD.type, 'customer_id', OLD.customer_id, 'supplier_id', OLD.supplier_id,
                'invoice_date', OLD.invoice_date, 'due_date', OLD.due_date,
                'subtotal', OLD.subtotal, 'discount_total', OLD.discount_total,
                'tax_total', OLD.tax_total, 'total_amount', OLD.total_amount,
                'paid_amount', OLD.paid_amount, 'remaining_amount', OLD.remaining_amount,
                'payment_method', OLD.payment_method, 'notes', OLD.notes,
                'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id,
                'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status,
                'synced_at', OLD.synced_at, 'status', OLD.status, 'deleted_at', OLD.deleted_at,
                'created_at', OLD.created_at, 'updated_at', OLD.updated_at
            ));
END;

-- Stock movements triggers
CREATE TRIGGER trg_stock_movements_log_change
AFTER INSERT ON stock_movements
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, new_values_json)
    VALUES ((SELECT store_id FROM products WHERE id = NEW.product_id),
            (SELECT COALESCE(MAX(cl.sync_cursor), 0) + 1 FROM change_log cl JOIN products p ON p.store_id = cl.store_id WHERE p.id = NEW.product_id),
            'stock_movements', NEW.id, 'INSERT', json_object(
                'id', NEW.id, 'product_id', NEW.product_id, 'location_id', NEW.location_id,
                'type', NEW.type, 'quantity', NEW.quantity, 'unit_id', NEW.unit_id,
                'cost_per_unit', NEW.cost_per_unit, 'total_value', NEW.total_value,
                'reference_id', NEW.reference_id, 'reference_type', NEW.reference_type,
                'batch_number', NEW.batch_number, 'expiry_date', NEW.expiry_date,
                'reason', NEW.reason, 'user_id', NEW.user_id,
                'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at,
                'created_at', NEW.created_at
            ));
END;

CREATE TRIGGER trg_stock_movements_log_change_upd
AFTER UPDATE ON stock_movements
WHEN NEW.id IS NOT OLD.id OR NEW.product_id IS NOT OLD.product_id OR NEW.location_id IS NOT OLD.location_id OR NEW.type IS NOT OLD.type OR NEW.quantity IS NOT OLD.quantity OR NEW.unit_id IS NOT OLD.unit_id OR NEW.cost_per_unit IS NOT OLD.cost_per_unit OR NEW.total_value IS NOT OLD.total_value OR NEW.reference_id IS NOT OLD.reference_id OR NEW.reference_type IS NOT OLD.reference_type OR NEW.batch_number IS NOT OLD.batch_number OR NEW.expiry_date IS NOT OLD.expiry_date OR NEW.reason IS NOT OLD.reason OR NEW.user_id IS NOT OLD.user_id OR NEW.sync_status IS NOT OLD.sync_status OR NEW.synced_at IS NOT OLD.synced_at OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM products WHERE id = NEW.product_id),
            (SELECT COALESCE(MAX(cl.sync_cursor), 0) + 1 FROM change_log cl JOIN products p ON p.store_id = cl.store_id WHERE p.id = NEW.product_id),
            'stock_movements', NEW.id, 'UPDATE',
            json_object(
                'id', OLD.id, 'product_id', OLD.product_id, 'location_id', OLD.location_id,
                'type', OLD.type, 'quantity', OLD.quantity, 'unit_id', OLD.unit_id,
                'cost_per_unit', OLD.cost_per_unit, 'total_value', OLD.total_value,
                'reference_id', OLD.reference_id, 'reference_type', OLD.reference_type,
                'batch_number', OLD.batch_number, 'expiry_date', OLD.expiry_date,
                'reason', OLD.reason, 'user_id', OLD.user_id,
                'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at,
                'created_at', OLD.created_at
            ),
            json_object(
                'id', NEW.id, 'product_id', NEW.product_id, 'location_id', NEW.location_id,
                'type', NEW.type, 'quantity', NEW.quantity, 'unit_id', NEW.unit_id,
                'cost_per_unit', NEW.cost_per_unit, 'total_value', NEW.total_value,
                'reference_id', NEW.reference_id, 'reference_type', NEW.reference_type,
                'batch_number', NEW.batch_number, 'expiry_date', NEW.expiry_date,
                'reason', NEW.reason, 'user_id', NEW.user_id,
                'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at,
                'created_at', NEW.created_at
            ));
END;

CREATE TRIGGER trg_stock_movements_log_change_del
AFTER DELETE ON stock_movements
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json)
    VALUES ((SELECT store_id FROM products WHERE id = OLD.product_id),
            (SELECT COALESCE(MAX(cl.sync_cursor), 0) + 1 FROM change_log cl JOIN products p ON p.store_id = cl.store_id WHERE p.id = OLD.product_id),
            'stock_movements', OLD.id, 'DELETE',
            json_object(
                'id', OLD.id, 'product_id', OLD.product_id, 'location_id', OLD.location_id,
                'type', OLD.type, 'quantity', OLD.quantity, 'unit_id', OLD.unit_id,
                'cost_per_unit', OLD.cost_per_unit, 'total_value', OLD.total_value,
                'reference_id', OLD.reference_id, 'reference_type', OLD.reference_type,
                'batch_number', OLD.batch_number, 'expiry_date', OLD.expiry_date,
                'reason', OLD.reason, 'user_id', OLD.user_id,
                'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at,
                'created_at', OLD.created_at
            ));
END;


-- Additional Change Log Triggers: all remaining business tables (excluding users to avoid syncing password hashes).
CREATE TRIGGER trg_product_units_log_insert
AFTER INSERT ON product_units
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM products WHERE id = NEW.product_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM products WHERE id = NEW.product_id)),
            'product_units', NEW.id, 'INSERT', NULL, json_object('id', NEW.id, 'product_id', NEW.product_id, 'unit_id', NEW.unit_id, 'conversion_factor', NEW.conversion_factor, 'sale_price', NEW.sale_price, 'purchase_price', NEW.purchase_price, 'is_primary', NEW.is_primary, 'is_default', NEW.is_default, 'sort_order', NEW.sort_order, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_product_units_log_update
AFTER UPDATE ON product_units
WHEN NEW.id IS NOT OLD.id OR NEW.product_id IS NOT OLD.product_id OR NEW.unit_id IS NOT OLD.unit_id OR NEW.conversion_factor IS NOT OLD.conversion_factor OR NEW.sale_price IS NOT OLD.sale_price OR NEW.purchase_price IS NOT OLD.purchase_price OR NEW.is_primary IS NOT OLD.is_primary OR NEW.is_default IS NOT OLD.is_default OR NEW.sort_order IS NOT OLD.sort_order OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM products WHERE id = NEW.product_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM products WHERE id = NEW.product_id)),
            'product_units', NEW.id, 'UPDATE', json_object('id', OLD.id, 'product_id', OLD.product_id, 'unit_id', OLD.unit_id, 'conversion_factor', OLD.conversion_factor, 'sale_price', OLD.sale_price, 'purchase_price', OLD.purchase_price, 'is_primary', OLD.is_primary, 'is_default', OLD.is_default, 'sort_order', OLD.sort_order, 'created_at', OLD.created_at), json_object('id', NEW.id, 'product_id', NEW.product_id, 'unit_id', NEW.unit_id, 'conversion_factor', NEW.conversion_factor, 'sale_price', NEW.sale_price, 'purchase_price', NEW.purchase_price, 'is_primary', NEW.is_primary, 'is_default', NEW.is_default, 'sort_order', NEW.sort_order, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_product_units_log_delete
AFTER DELETE ON product_units
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM products WHERE id = OLD.product_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM products WHERE id = OLD.product_id)),
            'product_units', OLD.id, 'DELETE', json_object('id', OLD.id, 'product_id', OLD.product_id, 'unit_id', OLD.unit_id, 'conversion_factor', OLD.conversion_factor, 'sale_price', OLD.sale_price, 'purchase_price', OLD.purchase_price, 'is_primary', OLD.is_primary, 'is_default', OLD.is_default, 'sort_order', OLD.sort_order, 'created_at', OLD.created_at), NULL);
END;
CREATE TRIGGER trg_stock_log_insert
AFTER INSERT ON stock
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM products WHERE id = NEW.product_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM products WHERE id = NEW.product_id)),
            'stock', NEW.id, 'INSERT', NULL, json_object('id', NEW.id, 'product_id', NEW.product_id, 'location_id', NEW.location_id, 'quantity', NEW.quantity, 'reserved_quantity', NEW.reserved_quantity, 'last_updated', NEW.last_updated));
END;
CREATE TRIGGER trg_stock_log_update
AFTER UPDATE ON stock
WHEN NEW.id IS NOT OLD.id OR NEW.product_id IS NOT OLD.product_id OR NEW.location_id IS NOT OLD.location_id OR NEW.quantity IS NOT OLD.quantity OR NEW.reserved_quantity IS NOT OLD.reserved_quantity
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM products WHERE id = NEW.product_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM products WHERE id = NEW.product_id)),
            'stock', NEW.id, 'UPDATE', json_object('id', OLD.id, 'product_id', OLD.product_id, 'location_id', OLD.location_id, 'quantity', OLD.quantity, 'reserved_quantity', OLD.reserved_quantity, 'last_updated', OLD.last_updated), json_object('id', NEW.id, 'product_id', NEW.product_id, 'location_id', NEW.location_id, 'quantity', NEW.quantity, 'reserved_quantity', NEW.reserved_quantity, 'last_updated', NEW.last_updated));
END;
CREATE TRIGGER trg_stock_log_delete
AFTER DELETE ON stock
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM products WHERE id = OLD.product_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM products WHERE id = OLD.product_id)),
            'stock', OLD.id, 'DELETE', json_object('id', OLD.id, 'product_id', OLD.product_id, 'location_id', OLD.location_id, 'quantity', OLD.quantity, 'reserved_quantity', OLD.reserved_quantity, 'last_updated', OLD.last_updated), NULL);
END;
CREATE TRIGGER trg_purchases_log_insert
AFTER INSERT ON purchases
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = NEW.store_id),
            'purchases', NEW.id, 'INSERT', NULL, json_object('id', NEW.id, 'store_id', NEW.store_id, 'purchase_number', NEW.purchase_number, 'supplier_id', NEW.supplier_id, 'grn_number', NEW.grn_number, 'supplier_invoice_no', NEW.supplier_invoice_no, 'supplier_invoice_amount', NEW.supplier_invoice_amount, 'purchase_date', NEW.purchase_date, 'received_date', NEW.received_date, 'subtotal', NEW.subtotal, 'discount_total', NEW.discount_total, 'tax_total', NEW.tax_total, 'total_amount', NEW.total_amount, 'paid_amount', NEW.paid_amount, 'remaining_amount', NEW.remaining_amount, 'payment_method', NEW.payment_method, 'notes', NEW.notes, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'status', NEW.status, 'deleted_at', NEW.deleted_at, 'created_at', NEW.created_at, 'updated_at', NEW.updated_at));
END;
CREATE TRIGGER trg_purchases_log_update
AFTER UPDATE ON purchases
WHEN NEW.id IS NOT OLD.id OR NEW.store_id IS NOT OLD.store_id OR NEW.purchase_number IS NOT OLD.purchase_number OR NEW.supplier_id IS NOT OLD.supplier_id OR NEW.grn_number IS NOT OLD.grn_number OR NEW.supplier_invoice_no IS NOT OLD.supplier_invoice_no OR NEW.supplier_invoice_amount IS NOT OLD.supplier_invoice_amount OR NEW.purchase_date IS NOT OLD.purchase_date OR NEW.received_date IS NOT OLD.received_date OR NEW.subtotal IS NOT OLD.subtotal OR NEW.discount_total IS NOT OLD.discount_total OR NEW.tax_total IS NOT OLD.tax_total OR NEW.total_amount IS NOT OLD.total_amount OR NEW.paid_amount IS NOT OLD.paid_amount OR NEW.remaining_amount IS NOT OLD.remaining_amount OR NEW.payment_method IS NOT OLD.payment_method OR NEW.notes IS NOT OLD.notes OR NEW.created_by IS NOT OLD.created_by OR NEW.device_sync_id IS NOT OLD.device_sync_id OR NEW.is_synced IS NOT OLD.is_synced OR NEW.sync_status IS NOT OLD.sync_status OR NEW.synced_at IS NOT OLD.synced_at OR NEW.status IS NOT OLD.status OR NEW.deleted_at IS NOT OLD.deleted_at OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = NEW.store_id),
            'purchases', NEW.id, 'UPDATE', json_object('id', OLD.id, 'store_id', OLD.store_id, 'purchase_number', OLD.purchase_number, 'supplier_id', OLD.supplier_id, 'grn_number', OLD.grn_number, 'supplier_invoice_no', OLD.supplier_invoice_no, 'supplier_invoice_amount', OLD.supplier_invoice_amount, 'purchase_date', OLD.purchase_date, 'received_date', OLD.received_date, 'subtotal', OLD.subtotal, 'discount_total', OLD.discount_total, 'tax_total', OLD.tax_total, 'total_amount', OLD.total_amount, 'paid_amount', OLD.paid_amount, 'remaining_amount', OLD.remaining_amount, 'payment_method', OLD.payment_method, 'notes', OLD.notes, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'status', OLD.status, 'deleted_at', OLD.deleted_at, 'created_at', OLD.created_at, 'updated_at', OLD.updated_at), json_object('id', NEW.id, 'store_id', NEW.store_id, 'purchase_number', NEW.purchase_number, 'supplier_id', NEW.supplier_id, 'grn_number', NEW.grn_number, 'supplier_invoice_no', NEW.supplier_invoice_no, 'supplier_invoice_amount', NEW.supplier_invoice_amount, 'purchase_date', NEW.purchase_date, 'received_date', NEW.received_date, 'subtotal', NEW.subtotal, 'discount_total', NEW.discount_total, 'tax_total', NEW.tax_total, 'total_amount', NEW.total_amount, 'paid_amount', NEW.paid_amount, 'remaining_amount', NEW.remaining_amount, 'payment_method', NEW.payment_method, 'notes', NEW.notes, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'status', NEW.status, 'deleted_at', NEW.deleted_at, 'created_at', NEW.created_at, 'updated_at', NEW.updated_at));
END;
CREATE TRIGGER trg_purchases_log_delete
AFTER DELETE ON purchases
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (OLD.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = OLD.store_id),
            'purchases', OLD.id, 'DELETE', json_object('id', OLD.id, 'store_id', OLD.store_id, 'purchase_number', OLD.purchase_number, 'supplier_id', OLD.supplier_id, 'grn_number', OLD.grn_number, 'supplier_invoice_no', OLD.supplier_invoice_no, 'supplier_invoice_amount', OLD.supplier_invoice_amount, 'purchase_date', OLD.purchase_date, 'received_date', OLD.received_date, 'subtotal', OLD.subtotal, 'discount_total', OLD.discount_total, 'tax_total', OLD.tax_total, 'total_amount', OLD.total_amount, 'paid_amount', OLD.paid_amount, 'remaining_amount', OLD.remaining_amount, 'payment_method', OLD.payment_method, 'notes', OLD.notes, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'status', OLD.status, 'deleted_at', OLD.deleted_at, 'created_at', OLD.created_at, 'updated_at', OLD.updated_at), NULL);
END;
CREATE TRIGGER trg_purchase_items_log_insert
AFTER INSERT ON purchase_items
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM purchases WHERE id = NEW.purchase_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM purchases WHERE id = NEW.purchase_id)),
            'purchase_items', NEW.id, 'INSERT', NULL, json_object('id', NEW.id, 'purchase_id', NEW.purchase_id, 'product_id', NEW.product_id, 'quantity', NEW.quantity, 'quantity_unit_id', NEW.quantity_unit_id, 'unit_price', NEW.unit_price, 'cost_per_unit', NEW.cost_per_unit, 'tax_rate', NEW.tax_rate, 'tax_amount', NEW.tax_amount, 'line_total', NEW.line_total, 'batch_number', NEW.batch_number, 'expiry_date', NEW.expiry_date, 'received', NEW.received, 'received_date', NEW.received_date, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_purchase_items_log_update
AFTER UPDATE ON purchase_items
WHEN NEW.id IS NOT OLD.id OR NEW.purchase_id IS NOT OLD.purchase_id OR NEW.product_id IS NOT OLD.product_id OR NEW.quantity IS NOT OLD.quantity OR NEW.quantity_unit_id IS NOT OLD.quantity_unit_id OR NEW.unit_price IS NOT OLD.unit_price OR NEW.cost_per_unit IS NOT OLD.cost_per_unit OR NEW.tax_rate IS NOT OLD.tax_rate OR NEW.tax_amount IS NOT OLD.tax_amount OR NEW.line_total IS NOT OLD.line_total OR NEW.batch_number IS NOT OLD.batch_number OR NEW.expiry_date IS NOT OLD.expiry_date OR NEW.received IS NOT OLD.received OR NEW.received_date IS NOT OLD.received_date OR NEW.is_synced IS NOT OLD.is_synced OR NEW.sync_status IS NOT OLD.sync_status OR NEW.synced_at IS NOT OLD.synced_at OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM purchases WHERE id = NEW.purchase_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM purchases WHERE id = NEW.purchase_id)),
            'purchase_items', NEW.id, 'UPDATE', json_object('id', OLD.id, 'purchase_id', OLD.purchase_id, 'product_id', OLD.product_id, 'quantity', OLD.quantity, 'quantity_unit_id', OLD.quantity_unit_id, 'unit_price', OLD.unit_price, 'cost_per_unit', OLD.cost_per_unit, 'tax_rate', OLD.tax_rate, 'tax_amount', OLD.tax_amount, 'line_total', OLD.line_total, 'batch_number', OLD.batch_number, 'expiry_date', OLD.expiry_date, 'received', OLD.received, 'received_date', OLD.received_date, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at), json_object('id', NEW.id, 'purchase_id', NEW.purchase_id, 'product_id', NEW.product_id, 'quantity', NEW.quantity, 'quantity_unit_id', NEW.quantity_unit_id, 'unit_price', NEW.unit_price, 'cost_per_unit', NEW.cost_per_unit, 'tax_rate', NEW.tax_rate, 'tax_amount', NEW.tax_amount, 'line_total', NEW.line_total, 'batch_number', NEW.batch_number, 'expiry_date', NEW.expiry_date, 'received', NEW.received, 'received_date', NEW.received_date, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_purchase_items_log_delete
AFTER DELETE ON purchase_items
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM purchases WHERE id = OLD.purchase_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM purchases WHERE id = OLD.purchase_id)),
            'purchase_items', OLD.id, 'DELETE', json_object('id', OLD.id, 'purchase_id', OLD.purchase_id, 'product_id', OLD.product_id, 'quantity', OLD.quantity, 'quantity_unit_id', OLD.quantity_unit_id, 'unit_price', OLD.unit_price, 'cost_per_unit', OLD.cost_per_unit, 'tax_rate', OLD.tax_rate, 'tax_amount', OLD.tax_amount, 'line_total', OLD.line_total, 'batch_number', OLD.batch_number, 'expiry_date', OLD.expiry_date, 'received', OLD.received, 'received_date', OLD.received_date, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at), NULL);
END;
CREATE TRIGGER trg_customer_ledgers_log_insert
AFTER INSERT ON customer_ledgers
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM customers WHERE id = NEW.customer_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM customers WHERE id = NEW.customer_id)),
            'customer_ledgers', NEW.id, 'INSERT', NULL, json_object('id', NEW.id, 'customer_id', NEW.customer_id, 'type', NEW.type, 'amount', NEW.amount, 'balance', NEW.balance, 'reference_id', NEW.reference_id, 'description', NEW.description, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_customer_ledgers_log_update
AFTER UPDATE ON customer_ledgers
WHEN NEW.id IS NOT OLD.id OR NEW.customer_id IS NOT OLD.customer_id OR NEW.type IS NOT OLD.type OR NEW.amount IS NOT OLD.amount OR NEW.balance IS NOT OLD.balance OR NEW.reference_id IS NOT OLD.reference_id OR NEW.description IS NOT OLD.description OR NEW.created_by IS NOT OLD.created_by OR NEW.device_sync_id IS NOT OLD.device_sync_id OR NEW.is_synced IS NOT OLD.is_synced OR NEW.sync_status IS NOT OLD.sync_status OR NEW.synced_at IS NOT OLD.synced_at OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM customers WHERE id = NEW.customer_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM customers WHERE id = NEW.customer_id)),
            'customer_ledgers', NEW.id, 'UPDATE', json_object('id', OLD.id, 'customer_id', OLD.customer_id, 'type', OLD.type, 'amount', OLD.amount, 'balance', OLD.balance, 'reference_id', OLD.reference_id, 'description', OLD.description, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at), json_object('id', NEW.id, 'customer_id', NEW.customer_id, 'type', NEW.type, 'amount', NEW.amount, 'balance', NEW.balance, 'reference_id', NEW.reference_id, 'description', NEW.description, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_customer_ledgers_log_delete
AFTER DELETE ON customer_ledgers
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM customers WHERE id = OLD.customer_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM customers WHERE id = OLD.customer_id)),
            'customer_ledgers', OLD.id, 'DELETE', json_object('id', OLD.id, 'customer_id', OLD.customer_id, 'type', OLD.type, 'amount', OLD.amount, 'balance', OLD.balance, 'reference_id', OLD.reference_id, 'description', OLD.description, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at), NULL);
END;
CREATE TRIGGER trg_customer_payments_log_insert
AFTER INSERT ON customer_payments
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM customers WHERE id = NEW.customer_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM customers WHERE id = NEW.customer_id)),
            'customer_payments', NEW.id, 'INSERT', NULL, json_object('id', NEW.id, 'customer_id', NEW.customer_id, 'amount', NEW.amount, 'payment_method', NEW.payment_method, 'reference_no', NEW.reference_no, 'notes', NEW.notes, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at, 'updated_at', NEW.updated_at));
END;
CREATE TRIGGER trg_customer_payments_log_update
AFTER UPDATE ON customer_payments
WHEN NEW.id IS NOT OLD.id OR NEW.customer_id IS NOT OLD.customer_id OR NEW.amount IS NOT OLD.amount OR NEW.payment_method IS NOT OLD.payment_method OR NEW.reference_no IS NOT OLD.reference_no OR NEW.notes IS NOT OLD.notes OR NEW.created_by IS NOT OLD.created_by OR NEW.device_sync_id IS NOT OLD.device_sync_id OR NEW.is_synced IS NOT OLD.is_synced OR NEW.sync_status IS NOT OLD.sync_status OR NEW.synced_at IS NOT OLD.synced_at OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM customers WHERE id = NEW.customer_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM customers WHERE id = NEW.customer_id)),
            'customer_payments', NEW.id, 'UPDATE', json_object('id', OLD.id, 'customer_id', OLD.customer_id, 'amount', OLD.amount, 'payment_method', OLD.payment_method, 'reference_no', OLD.reference_no, 'notes', OLD.notes, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at, 'updated_at', OLD.updated_at), json_object('id', NEW.id, 'customer_id', NEW.customer_id, 'amount', NEW.amount, 'payment_method', NEW.payment_method, 'reference_no', NEW.reference_no, 'notes', NEW.notes, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at, 'updated_at', NEW.updated_at));
END;
CREATE TRIGGER trg_customer_payments_log_delete
AFTER DELETE ON customer_payments
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM customers WHERE id = OLD.customer_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM customers WHERE id = OLD.customer_id)),
            'customer_payments', OLD.id, 'DELETE', json_object('id', OLD.id, 'customer_id', OLD.customer_id, 'amount', OLD.amount, 'payment_method', OLD.payment_method, 'reference_no', OLD.reference_no, 'notes', OLD.notes, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at, 'updated_at', OLD.updated_at), NULL);
END;
CREATE TRIGGER trg_payment_allocations_log_insert
AFTER INSERT ON payment_allocations
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM invoices WHERE id = NEW.invoice_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM invoices WHERE id = NEW.invoice_id)),
            'payment_allocations', NEW.id, 'INSERT', NULL, json_object('id', NEW.id, 'payment_id', NEW.payment_id, 'invoice_id', NEW.invoice_id, 'allocated_amount', NEW.allocated_amount, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_payment_allocations_log_update
AFTER UPDATE ON payment_allocations
WHEN NEW.id IS NOT OLD.id OR NEW.payment_id IS NOT OLD.payment_id OR NEW.invoice_id IS NOT OLD.invoice_id OR NEW.allocated_amount IS NOT OLD.allocated_amount OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM invoices WHERE id = NEW.invoice_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM invoices WHERE id = NEW.invoice_id)),
            'payment_allocations', NEW.id, 'UPDATE', json_object('id', OLD.id, 'payment_id', OLD.payment_id, 'invoice_id', OLD.invoice_id, 'allocated_amount', OLD.allocated_amount, 'created_at', OLD.created_at), json_object('id', NEW.id, 'payment_id', NEW.payment_id, 'invoice_id', NEW.invoice_id, 'allocated_amount', NEW.allocated_amount, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_payment_allocations_log_delete
AFTER DELETE ON payment_allocations
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM invoices WHERE id = OLD.invoice_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM invoices WHERE id = OLD.invoice_id)),
            'payment_allocations', OLD.id, 'DELETE', json_object('id', OLD.id, 'payment_id', OLD.payment_id, 'invoice_id', OLD.invoice_id, 'allocated_amount', OLD.allocated_amount, 'created_at', OLD.created_at), NULL);
END;
CREATE TRIGGER trg_supplier_ledger_log_insert
AFTER INSERT ON supplier_ledger
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM suppliers WHERE id = NEW.supplier_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM suppliers WHERE id = NEW.supplier_id)),
            'supplier_ledger', NEW.id, 'INSERT', NULL, json_object('id', NEW.id, 'supplier_id', NEW.supplier_id, 'type', NEW.type, 'amount', NEW.amount, 'balance', NEW.balance, 'reference_id', NEW.reference_id, 'description', NEW.description, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_supplier_ledger_log_update
AFTER UPDATE ON supplier_ledger
WHEN NEW.id IS NOT OLD.id OR NEW.supplier_id IS NOT OLD.supplier_id OR NEW.type IS NOT OLD.type OR NEW.amount IS NOT OLD.amount OR NEW.balance IS NOT OLD.balance OR NEW.reference_id IS NOT OLD.reference_id OR NEW.description IS NOT OLD.description OR NEW.created_by IS NOT OLD.created_by OR NEW.device_sync_id IS NOT OLD.device_sync_id OR NEW.is_synced IS NOT OLD.is_synced OR NEW.sync_status IS NOT OLD.sync_status OR NEW.synced_at IS NOT OLD.synced_at OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM suppliers WHERE id = NEW.supplier_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM suppliers WHERE id = NEW.supplier_id)),
            'supplier_ledger', NEW.id, 'UPDATE', json_object('id', OLD.id, 'supplier_id', OLD.supplier_id, 'type', OLD.type, 'amount', OLD.amount, 'balance', OLD.balance, 'reference_id', OLD.reference_id, 'description', OLD.description, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at), json_object('id', NEW.id, 'supplier_id', NEW.supplier_id, 'type', NEW.type, 'amount', NEW.amount, 'balance', NEW.balance, 'reference_id', NEW.reference_id, 'description', NEW.description, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_supplier_ledger_log_delete
AFTER DELETE ON supplier_ledger
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM suppliers WHERE id = OLD.supplier_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM suppliers WHERE id = OLD.supplier_id)),
            'supplier_ledger', OLD.id, 'DELETE', json_object('id', OLD.id, 'supplier_id', OLD.supplier_id, 'type', OLD.type, 'amount', OLD.amount, 'balance', OLD.balance, 'reference_id', OLD.reference_id, 'description', OLD.description, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at), NULL);
END;
CREATE TRIGGER trg_supplier_payments_log_insert
AFTER INSERT ON supplier_payments
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM suppliers WHERE id = NEW.supplier_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM suppliers WHERE id = NEW.supplier_id)),
            'supplier_payments', NEW.id, 'INSERT', NULL, json_object('id', NEW.id, 'supplier_id', NEW.supplier_id, 'amount', NEW.amount, 'payment_method', NEW.payment_method, 'reference_no', NEW.reference_no, 'notes', NEW.notes, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at, 'updated_at', NEW.updated_at));
END;
CREATE TRIGGER trg_supplier_payments_log_update
AFTER UPDATE ON supplier_payments
WHEN NEW.id IS NOT OLD.id OR NEW.supplier_id IS NOT OLD.supplier_id OR NEW.amount IS NOT OLD.amount OR NEW.payment_method IS NOT OLD.payment_method OR NEW.reference_no IS NOT OLD.reference_no OR NEW.notes IS NOT OLD.notes OR NEW.created_by IS NOT OLD.created_by OR NEW.device_sync_id IS NOT OLD.device_sync_id OR NEW.is_synced IS NOT OLD.is_synced OR NEW.sync_status IS NOT OLD.sync_status OR NEW.synced_at IS NOT OLD.synced_at OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM suppliers WHERE id = NEW.supplier_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM suppliers WHERE id = NEW.supplier_id)),
            'supplier_payments', NEW.id, 'UPDATE', json_object('id', OLD.id, 'supplier_id', OLD.supplier_id, 'amount', OLD.amount, 'payment_method', OLD.payment_method, 'reference_no', OLD.reference_no, 'notes', OLD.notes, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at, 'updated_at', OLD.updated_at), json_object('id', NEW.id, 'supplier_id', NEW.supplier_id, 'amount', NEW.amount, 'payment_method', NEW.payment_method, 'reference_no', NEW.reference_no, 'notes', NEW.notes, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at, 'updated_at', NEW.updated_at));
END;
CREATE TRIGGER trg_supplier_payments_log_delete
AFTER DELETE ON supplier_payments
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM suppliers WHERE id = OLD.supplier_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM suppliers WHERE id = OLD.supplier_id)),
            'supplier_payments', OLD.id, 'DELETE', json_object('id', OLD.id, 'supplier_id', OLD.supplier_id, 'amount', OLD.amount, 'payment_method', OLD.payment_method, 'reference_no', OLD.reference_no, 'notes', OLD.notes, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at, 'updated_at', OLD.updated_at), NULL);
END;
CREATE TRIGGER trg_sales_returns_log_insert
AFTER INSERT ON sales_returns
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = NEW.store_id),
            'sales_returns', NEW.id, 'INSERT', NULL, json_object('id', NEW.id, 'store_id', NEW.store_id, 'return_number', NEW.return_number, 'original_invoice_id', NEW.original_invoice_id, 'reason', NEW.reason, 'total_amount', NEW.total_amount, 'refund_method', NEW.refund_method, 'notes', NEW.notes, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at, 'updated_at', NEW.updated_at));
END;
CREATE TRIGGER trg_sales_returns_log_update
AFTER UPDATE ON sales_returns
WHEN NEW.id IS NOT OLD.id OR NEW.store_id IS NOT OLD.store_id OR NEW.return_number IS NOT OLD.return_number OR NEW.original_invoice_id IS NOT OLD.original_invoice_id OR NEW.reason IS NOT OLD.reason OR NEW.total_amount IS NOT OLD.total_amount OR NEW.refund_method IS NOT OLD.refund_method OR NEW.notes IS NOT OLD.notes OR NEW.created_by IS NOT OLD.created_by OR NEW.device_sync_id IS NOT OLD.device_sync_id OR NEW.is_synced IS NOT OLD.is_synced OR NEW.sync_status IS NOT OLD.sync_status OR NEW.synced_at IS NOT OLD.synced_at OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = NEW.store_id),
            'sales_returns', NEW.id, 'UPDATE', json_object('id', OLD.id, 'store_id', OLD.store_id, 'return_number', OLD.return_number, 'original_invoice_id', OLD.original_invoice_id, 'reason', OLD.reason, 'total_amount', OLD.total_amount, 'refund_method', OLD.refund_method, 'notes', OLD.notes, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at, 'updated_at', OLD.updated_at), json_object('id', NEW.id, 'store_id', NEW.store_id, 'return_number', NEW.return_number, 'original_invoice_id', NEW.original_invoice_id, 'reason', NEW.reason, 'total_amount', NEW.total_amount, 'refund_method', NEW.refund_method, 'notes', NEW.notes, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at, 'updated_at', NEW.updated_at));
END;
CREATE TRIGGER trg_sales_returns_log_delete
AFTER DELETE ON sales_returns
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (OLD.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = OLD.store_id),
            'sales_returns', OLD.id, 'DELETE', json_object('id', OLD.id, 'store_id', OLD.store_id, 'return_number', OLD.return_number, 'original_invoice_id', OLD.original_invoice_id, 'reason', OLD.reason, 'total_amount', OLD.total_amount, 'refund_method', OLD.refund_method, 'notes', OLD.notes, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at, 'updated_at', OLD.updated_at), NULL);
END;
CREATE TRIGGER trg_return_items_log_insert
AFTER INSERT ON return_items
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM sales_returns WHERE id = NEW.return_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM sales_returns WHERE id = NEW.return_id)),
            'return_items', NEW.id, 'INSERT', NULL, json_object('id', NEW.id, 'return_id', NEW.return_id, 'product_id', NEW.product_id, 'quantity', NEW.quantity, 'unit_price', NEW.unit_price, 'line_total', NEW.line_total, 'batch_number', NEW.batch_number, 'expiry_date', NEW.expiry_date, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_return_items_log_update
AFTER UPDATE ON return_items
WHEN NEW.id IS NOT OLD.id OR NEW.return_id IS NOT OLD.return_id OR NEW.product_id IS NOT OLD.product_id OR NEW.quantity IS NOT OLD.quantity OR NEW.unit_price IS NOT OLD.unit_price OR NEW.line_total IS NOT OLD.line_total OR NEW.batch_number IS NOT OLD.batch_number OR NEW.expiry_date IS NOT OLD.expiry_date OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM sales_returns WHERE id = NEW.return_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM sales_returns WHERE id = NEW.return_id)),
            'return_items', NEW.id, 'UPDATE', json_object('id', OLD.id, 'return_id', OLD.return_id, 'product_id', OLD.product_id, 'quantity', OLD.quantity, 'unit_price', OLD.unit_price, 'line_total', OLD.line_total, 'batch_number', OLD.batch_number, 'expiry_date', OLD.expiry_date, 'created_at', OLD.created_at), json_object('id', NEW.id, 'return_id', NEW.return_id, 'product_id', NEW.product_id, 'quantity', NEW.quantity, 'unit_price', NEW.unit_price, 'line_total', NEW.line_total, 'batch_number', NEW.batch_number, 'expiry_date', NEW.expiry_date, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_return_items_log_delete
AFTER DELETE ON return_items
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM sales_returns WHERE id = OLD.return_id), (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = (SELECT store_id FROM sales_returns WHERE id = OLD.return_id)),
            'return_items', OLD.id, 'DELETE', json_object('id', OLD.id, 'return_id', OLD.return_id, 'product_id', OLD.product_id, 'quantity', OLD.quantity, 'unit_price', OLD.unit_price, 'line_total', OLD.line_total, 'batch_number', OLD.batch_number, 'expiry_date', OLD.expiry_date, 'created_at', OLD.created_at), NULL);
END;
CREATE TRIGGER trg_expenses_log_insert
AFTER INSERT ON expenses
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = NEW.store_id),
            'expenses', NEW.id, 'INSERT', NULL, json_object('id', NEW.id, 'store_id', NEW.store_id, 'category', NEW.category, 'description', NEW.description, 'amount', NEW.amount, 'expense_date', NEW.expense_date, 'payment_method', NEW.payment_method, 'receipt_number', NEW.receipt_number, 'attachment_path', NEW.attachment_path, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_expenses_log_update
AFTER UPDATE ON expenses
WHEN NEW.id IS NOT OLD.id OR NEW.store_id IS NOT OLD.store_id OR NEW.category IS NOT OLD.category OR NEW.description IS NOT OLD.description OR NEW.amount IS NOT OLD.amount OR NEW.expense_date IS NOT OLD.expense_date OR NEW.payment_method IS NOT OLD.payment_method OR NEW.receipt_number IS NOT OLD.receipt_number OR NEW.attachment_path IS NOT OLD.attachment_path OR NEW.created_by IS NOT OLD.created_by OR NEW.device_sync_id IS NOT OLD.device_sync_id OR NEW.is_synced IS NOT OLD.is_synced OR NEW.sync_status IS NOT OLD.sync_status OR NEW.synced_at IS NOT OLD.synced_at OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = NEW.store_id),
            'expenses', NEW.id, 'UPDATE', json_object('id', OLD.id, 'store_id', OLD.store_id, 'category', OLD.category, 'description', OLD.description, 'amount', OLD.amount, 'expense_date', OLD.expense_date, 'payment_method', OLD.payment_method, 'receipt_number', OLD.receipt_number, 'attachment_path', OLD.attachment_path, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at), json_object('id', NEW.id, 'store_id', NEW.store_id, 'category', NEW.category, 'description', NEW.description, 'amount', NEW.amount, 'expense_date', NEW.expense_date, 'payment_method', NEW.payment_method, 'receipt_number', NEW.receipt_number, 'attachment_path', NEW.attachment_path, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_expenses_log_delete
AFTER DELETE ON expenses
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (OLD.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = OLD.store_id),
            'expenses', OLD.id, 'DELETE', json_object('id', OLD.id, 'store_id', OLD.store_id, 'category', OLD.category, 'description', OLD.description, 'amount', OLD.amount, 'expense_date', OLD.expense_date, 'payment_method', OLD.payment_method, 'receipt_number', OLD.receipt_number, 'attachment_path', OLD.attachment_path, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at), NULL);
END;
CREATE TRIGGER trg_revenues_log_insert
AFTER INSERT ON revenues
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = NEW.store_id),
            'revenues', NEW.id, 'INSERT', NULL, json_object('id', NEW.id, 'store_id', NEW.store_id, 'category', NEW.category, 'description', NEW.description, 'amount', NEW.amount, 'revenue_date', NEW.revenue_date, 'source', NEW.source, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_revenues_log_update
AFTER UPDATE ON revenues
WHEN NEW.id IS NOT OLD.id OR NEW.store_id IS NOT OLD.store_id OR NEW.category IS NOT OLD.category OR NEW.description IS NOT OLD.description OR NEW.amount IS NOT OLD.amount OR NEW.revenue_date IS NOT OLD.revenue_date OR NEW.source IS NOT OLD.source OR NEW.created_by IS NOT OLD.created_by OR NEW.device_sync_id IS NOT OLD.device_sync_id OR NEW.is_synced IS NOT OLD.is_synced OR NEW.sync_status IS NOT OLD.sync_status OR NEW.synced_at IS NOT OLD.synced_at OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = NEW.store_id),
            'revenues', NEW.id, 'UPDATE', json_object('id', OLD.id, 'store_id', OLD.store_id, 'category', OLD.category, 'description', OLD.description, 'amount', OLD.amount, 'revenue_date', OLD.revenue_date, 'source', OLD.source, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at), json_object('id', NEW.id, 'store_id', NEW.store_id, 'category', NEW.category, 'description', NEW.description, 'amount', NEW.amount, 'revenue_date', NEW.revenue_date, 'source', NEW.source, 'created_by', NEW.created_by, 'device_sync_id', NEW.device_sync_id, 'is_synced', NEW.is_synced, 'sync_status', NEW.sync_status, 'synced_at', NEW.synced_at, 'created_at', NEW.created_at));
END;
CREATE TRIGGER trg_revenues_log_delete
AFTER DELETE ON revenues
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (OLD.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = OLD.store_id),
            'revenues', OLD.id, 'DELETE', json_object('id', OLD.id, 'store_id', OLD.store_id, 'category', OLD.category, 'description', OLD.description, 'amount', OLD.amount, 'revenue_date', OLD.revenue_date, 'source', OLD.source, 'created_by', OLD.created_by, 'device_sync_id', OLD.device_sync_id, 'is_synced', OLD.is_synced, 'sync_status', OLD.sync_status, 'synced_at', OLD.synced_at, 'created_at', OLD.created_at), NULL);
END;
CREATE TRIGGER trg_categories_log_insert
AFTER INSERT ON categories
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = NEW.store_id),
            'categories', NEW.id, 'INSERT', NULL, json_object('id', NEW.id, 'store_id', NEW.store_id, 'parent_id', NEW.parent_id, 'name', NEW.name, 'code', NEW.code, 'sort_order', NEW.sort_order, 'is_active', NEW.is_active, 'created_at', NEW.created_at, 'updated_at', NEW.updated_at));
END;
CREATE TRIGGER trg_categories_log_update
AFTER UPDATE ON categories
WHEN NEW.id IS NOT OLD.id OR NEW.store_id IS NOT OLD.store_id OR NEW.parent_id IS NOT OLD.parent_id OR NEW.name IS NOT OLD.name OR NEW.code IS NOT OLD.code OR NEW.sort_order IS NOT OLD.sort_order OR NEW.is_active IS NOT OLD.is_active OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = NEW.store_id),
            'categories', NEW.id, 'UPDATE', json_object('id', OLD.id, 'store_id', OLD.store_id, 'parent_id', OLD.parent_id, 'name', OLD.name, 'code', OLD.code, 'sort_order', OLD.sort_order, 'is_active', OLD.is_active, 'created_at', OLD.created_at, 'updated_at', OLD.updated_at), json_object('id', NEW.id, 'store_id', NEW.store_id, 'parent_id', NEW.parent_id, 'name', NEW.name, 'code', NEW.code, 'sort_order', NEW.sort_order, 'is_active', NEW.is_active, 'created_at', NEW.created_at, 'updated_at', NEW.updated_at));
END;
CREATE TRIGGER trg_categories_log_delete
AFTER DELETE ON categories
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (OLD.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = OLD.store_id),
            'categories', OLD.id, 'DELETE', json_object('id', OLD.id, 'store_id', OLD.store_id, 'parent_id', OLD.parent_id, 'name', OLD.name, 'code', OLD.code, 'sort_order', OLD.sort_order, 'is_active', OLD.is_active, 'created_at', OLD.created_at, 'updated_at', OLD.updated_at), NULL);
END;
CREATE TRIGGER trg_brands_log_insert
AFTER INSERT ON brands
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = NEW.store_id),
            'brands', NEW.id, 'INSERT', NULL, json_object('id', NEW.id, 'store_id', NEW.store_id, 'name', NEW.name, 'scent', NEW.scent, 'size', NEW.size, 'created_at', NEW.created_at, 'updated_at', NEW.updated_at));
END;
CREATE TRIGGER trg_brands_log_update
AFTER UPDATE ON brands
WHEN NEW.id IS NOT OLD.id OR NEW.store_id IS NOT OLD.store_id OR NEW.name IS NOT OLD.name OR NEW.scent IS NOT OLD.scent OR NEW.size IS NOT OLD.size OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = NEW.store_id),
            'brands', NEW.id, 'UPDATE', json_object('id', OLD.id, 'store_id', OLD.store_id, 'name', OLD.name, 'scent', OLD.scent, 'size', OLD.size, 'created_at', OLD.created_at, 'updated_at', OLD.updated_at), json_object('id', NEW.id, 'store_id', NEW.store_id, 'name', NEW.name, 'scent', NEW.scent, 'size', NEW.size, 'created_at', NEW.created_at, 'updated_at', NEW.updated_at));
END;
CREATE TRIGGER trg_brands_log_delete
AFTER DELETE ON brands
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (OLD.store_id, (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id = OLD.store_id),
            'brands', OLD.id, 'DELETE', json_object('id', OLD.id, 'store_id', OLD.store_id, 'name', OLD.name, 'scent', OLD.scent, 'size', OLD.size, 'created_at', OLD.created_at, 'updated_at', OLD.updated_at), NULL);
END;

-- ============================================================
-- Seed Data (البيانات الأولية) — تُنفذ مرة واحدة بعد إنشاء المخطط
-- ============================================================

-- Units (الوحدات)
INSERT INTO units (id, name, symbol, is_active) VALUES
('pcs',  'قطعة',  'قطعة',  1),
('g',    'جرام',  'جم',    1),
('kg',   'كيلو',  'كجم',   1),
('liter','لتر',   'لتر',   1),
('box',  'صندوق', 'صندوق', 1),
('carton','كرتونة','كرتونة',1)
ON CONFLICT (id) DO NOTHING;

-- Locations (المواقع)
INSERT INTO locations (id, name, is_default) VALUES
('main',      'المتجر الرئيسي',     1),
('warehouse', 'المستودع',          0),
('storage',   'مخزن إضافي',        0)
ON CONFLICT (id) DO NOTHING;

-- Roles (الأدوار)
INSERT INTO roles (id, name, description, is_active) VALUES
('owner',        'المالك',        'صلاحيات كاملة',       1),
('admin',        'مدير',          'إدارة كاملة للمتجر',    1),
('accountant',   'محاسب',         'وصول للمالية والحسابات',1),
('cashier',      'كاشير',         'مبيعات ونقاط بيع',     1),
('stock_keeper', 'أمين مخزن',     'إدارة المخزون والشراء', 1)
ON CONFLICT (id) DO NOTHING;

-- Permissions (الصلاحيات الأساسية) — معرفات UUID صريحة بطول 36
INSERT INTO permissions (id, code, description) VALUES
('11111111-1111-1111-1111-111111111111', 'stores.read',       'عرض المتاجر'),
('22222222-2222-2222-2222-222222222222', 'stores.write',      'تعديل المتاجر'),
('33333333-3333-3333-3333-333333333333', 'products.read',     'عرض المنتجات'),
('44444444-4444-4444-4444-444444444444', 'products.write',    'إضافة/تعديل المنتجات'),
('55555555-5555-5555-5555-555555555555', 'products.delete',   'حذف المنتجات'),
('66666666-6666-6666-6666-666666666666', 'inventory.read',    'عرض المخزون'),
('77777777-7777-7777-7777-777777777777', 'inventory.write',   'تعديل المخزون'),
('88888888-8888-8888-8888-888888888888', 'sales.read',        'عرض المبيعات'),
('99999999-9999-9999-9999-999999999999', 'sales.write',       'إنشاء فواتير مبيعات'),
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'sales.void',        'إلغاء فواتير مبيعات'),
('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'purchases.read',    'عرض المشتريات'),
('cccccccc-cccc-cccc-cccc-cccccccccccc', 'purchases.write',   'إنشاء فواتير مشتريات'),
('dddddddd-dddd-dddd-dddd-dddddddddddd', 'purchases.receive', 'استلام مشتريات'),
('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'customers.read',    'عرض العملاء'),
('ffffffff-ffff-ffff-ffff-ffffffffffff', 'customers.write',   'إضافة/تعديل العملاء'),
('11111111-2222-3333-4444-555555555555', 'customers.payments','استلام مدفوعات العملاء'),
('22222222-3333-4444-5555-666666666666', 'suppliers.read',    'عرض الموردين'),
('33333333-4444-5555-6666-777777777777', 'suppliers.write',   'إضافة/تعديل الموردين'),
('44444444-5555-6666-7777-888888888888', 'suppliers.payments','سداد الموردين'),
('55555555-6666-7777-8888-999999999999', 'reports.financial', 'تقارير مالية'),
('66666666-7777-8888-9999-aaaaaaaaaaaa', 'reports.inventory', 'تقارير مخزون'),
('77777777-8888-9999-aaaa-bbbbbbbbbbbb', 'settings.read',     'عرض الإعدادات'),
('88888888-9999-aaaa-bbbb-cccccccccccc', 'settings.write',    'تعديل الإعدادات'),
('99999999-aaaa-bbbb-cccc-dddddddddddd', 'users.manage',      'إدارة المستخدمين والأدوار'),
('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'sync.manage',       'إدارة المزامنة')
ON CONFLICT (code) DO NOTHING;

-- ربط الأدوار بالصلاحيات — INSERT OR IGNORE للنمط SQLite
-- Owner: كل شيء
INSERT OR IGNORE INTO role_permissions (id, role_id, permission_id)
SELECT lower(hex(randomblob(16))), 'owner', id FROM permissions;

-- Admin: كل شيء ما عدا settings.write
INSERT OR IGNORE INTO role_permissions (id, role_id, permission_id)
SELECT lower(hex(randomblob(16))), 'admin', id FROM permissions WHERE code != 'settings.write';

-- Accountant
INSERT OR IGNORE INTO role_permissions (id, role_id, permission_id)
SELECT lower(hex(randomblob(16))), 'accountant', id FROM permissions
WHERE code IN ('reports.financial', 'reports.inventory', 'customers.read', 'suppliers.read',
               'customers.payments', 'suppliers.payments', 'sales.read', 'purchases.read');

-- Cashier
INSERT OR IGNORE INTO role_permissions (id, role_id, permission_id)
SELECT lower(hex(randomblob(16))), 'cashier', id FROM permissions
WHERE code IN ('products.read', 'inventory.read', 'sales.read', 'sales.write', 'sales.void',
               'customers.read', 'customers.write', 'customers.payments', 'reports.inventory');

-- Stock Keeper
INSERT OR IGNORE INTO role_permissions (id, role_id, permission_id)
SELECT lower(hex(randomblob(16))), 'stock_keeper', id FROM permissions
WHERE code IN ('products.read', 'products.write', 'inventory.read', 'inventory.write',
               'purchases.read', 'purchases.write', 'purchases.receive', 'suppliers.read',
               'reports.inventory');
```

---

## 16. Foreign Keys Summary

هذا الملخص مولّد وفق تعريفات `FOREIGN KEY` الفعلية في المخطط، وليس وصفاً افتراضياً.

| الجدول | العمود | المرجع | onDelete |
|---|---|---|---|
| `audit_logs` | `user_id` | `users(id)` | `NO ACTION` |
| `audit_logs` | `store_id` | `stores(id)` | `NO ACTION` |
| `brands` | `store_id` | `stores(id)` | `CASCADE` |
| `categories` | `parent_id` | `categories(id)` | `NO ACTION` |
| `categories` | `store_id` | `stores(id)` | `CASCADE` |
| `customer_ledgers` | `created_by` | `users(id)` | `NO ACTION` |
| `customer_ledgers` | `customer_id` | `customers(id)` | `NO ACTION` |
| `customer_payments` | `created_by` | `users(id)` | `NO ACTION` |
| `customer_payments` | `customer_id` | `customers(id)` | `NO ACTION` |
| `customers` | `store_id` | `stores(id)` | `CASCADE` |
| `devices` | `store_id` | `stores(id)` | `CASCADE` |
| `expenses` | `created_by` | `users(id)` | `NO ACTION` |
| `expenses` | `store_id` | `stores(id)` | `NO ACTION` |
| `invoice_items` | `quantity_unit_id` | `units(id)` | `NO ACTION` |
| `invoice_items` | `product_id` | `products(id)` | `NO ACTION` |
| `invoice_items` | `invoice_id` | `invoices(id)` | `CASCADE` |
| `invoices` | `created_by` | `users(id)` | `NO ACTION` |
| `invoices` | `supplier_id` | `suppliers(id)` | `NO ACTION` |
| `invoices` | `customer_id` | `customers(id)` | `NO ACTION` |
| `invoices` | `store_id` | `stores(id)` | `NO ACTION` |
| `payment_allocations` | `invoice_id` | `invoices(id)` | `CASCADE` |
| `payment_allocations` | `payment_id` | `customer_payments(id)` | `CASCADE` |
| `product_units` | `unit_id` | `units(id)` | `NO ACTION` |
| `product_units` | `product_id` | `products(id)` | `CASCADE` |
| `products` | `primary_unit_id` | `units(id)` | `NO ACTION` |
| `products` | `brand_id` | `brands(id)` | `NO ACTION` |
| `products` | `category_id` | `categories(id)` | `NO ACTION` |
| `products` | `store_id` | `stores(id)` | `CASCADE` |
| `purchase_items` | `quantity_unit_id` | `units(id)` | `RESTRICT` |
| `purchase_items` | `product_id` | `products(id)` | `CASCADE` |
| `purchase_items` | `purchase_id` | `purchases(id)` | `CASCADE` |
| `purchases` | `created_by` | `users(id)` | `NO ACTION` |
| `purchases` | `supplier_id` | `suppliers(id)` | `NO ACTION` |
| `purchases` | `store_id` | `stores(id)` | `NO ACTION` |
| `return_items` | `product_id` | `products(id)` | `NO ACTION` |
| `return_items` | `return_id` | `sales_returns(id)` | `CASCADE` |
| `revenues` | `created_by` | `users(id)` | `NO ACTION` |
| `revenues` | `store_id` | `stores(id)` | `NO ACTION` |
| `role_permissions` | `permission_id` | `permissions(id)` | `NO ACTION` |
| `role_permissions` | `role_id` | `roles(id)` | `NO ACTION` |
| `sales_returns` | `created_by` | `users(id)` | `NO ACTION` |
| `sales_returns` | `original_invoice_id` | `invoices(id)` | `NO ACTION` |
| `sales_returns` | `store_id` | `stores(id)` | `NO ACTION` |
| `stock` | `location_id` | `locations(id)` | `NO ACTION` |
| `stock` | `product_id` | `products(id)` | `CASCADE` |
| `stock_movements` | `user_id` | `users(id)` | `NO ACTION` |
| `stock_movements` | `unit_id` | `units(id)` | `NO ACTION` |
| `stock_movements` | `product_id` | `products(id)` | `NO ACTION` |
| `supplier_ledger` | `created_by` | `users(id)` | `NO ACTION` |
| `supplier_ledger` | `supplier_id` | `suppliers(id)` | `CASCADE` |
| `supplier_payments` | `created_by` | `users(id)` | `NO ACTION` |
| `supplier_payments` | `supplier_id` | `suppliers(id)` | `CASCADE` |
| `suppliers` | `store_id` | `stores(id)` | `CASCADE` |
| `sync_conflicts` | `resolved_by` | `users(id)` | `NO ACTION` |
| `sync_conflicts` | `store_id` | `stores(id)` | `NO ACTION` |
| `sync_cursors` | `store_id` | `stores(id)` | `NO ACTION` |
| `sync_log` | `store_id` | `stores(id)` | `NO ACTION` |
| `sync_outbox` | `store_id` | `stores(id)` | `NO ACTION` |
| `tombstones` | `deleted_by` | `users(id)` | `NO ACTION` |
| `tombstones` | `store_id` | `stores(id)` | `NO ACTION` |
| `user_roles` | `granted_by` | `users(id)` | `NO ACTION` |
| `user_roles` | `role_id` | `roles(id)` | `NO ACTION` |
| `user_roles` | `user_id` | `users(id)` | `CASCADE` |
| `users` | `store_id` | `stores(id)` | `CASCADE` |

---

## 17. ملاحظات التنفيذ

1. **جميع UUID مخزنة كـ TEXT بطول 36 حرف بالضبط** (مع الفواصل القياسية)
2. **جميع التواريخ بصيغة UTC باستخدام `datetime('now')`**
3. **Soft Delete عبر حقل `deleted_at` وليس حذف فعلي**
4. **All timestamps are stored as ISO 8601 strings in UTC**
5. **Foreign keys are enforced via PRAGMA foreign_keys = ON**
6. **Triggers تستخدم AFTER UPDATE + self-update مع WHEN guard**؛ التحديث الداخلي يغيّر updated_at بدقة milliseconds حتى لا يتكرر trigger بلا نهاية
7. **JSON fields مخزنة كنص TEXT** (بدلاً من JSON/JSONB)


---

## 18. قيود سلامة إضافية (Multi-store integrity)

تمنع هذه المشغلات ربط سجل بمرجع تابع لمتجر آخر، حتى عندما تكون المفاتيح الأجنبية صحيحة شكلياً.
كما أن أرقام الفواتير وأكواد العملاء والموردين والباركود أصبحت فريدة داخل المتجر بدلاً من فرض التفرد عالمياً.

```sql
-- Products: category and brand must belong to the same store.
CREATE TRIGGER trg_products_store_refs_ins BEFORE INSERT ON products
BEGIN
  SELECT CASE WHEN NEW.category_id IS NOT NULL AND NOT EXISTS
    (SELECT 1 FROM categories c WHERE c.id=NEW.category_id AND c.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Product category belongs to another store') END;
  SELECT CASE WHEN NEW.brand_id IS NOT NULL AND NOT EXISTS
    (SELECT 1 FROM brands b WHERE b.id=NEW.brand_id AND b.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Product brand belongs to another store') END;
END;
CREATE TRIGGER trg_products_store_refs_upd BEFORE UPDATE OF store_id, category_id, brand_id ON products
BEGIN
  SELECT CASE WHEN NEW.category_id IS NOT NULL AND NOT EXISTS
    (SELECT 1 FROM categories c WHERE c.id=NEW.category_id AND c.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Product category belongs to another store') END;
  SELECT CASE WHEN NEW.brand_id IS NOT NULL AND NOT EXISTS
    (SELECT 1 FROM brands b WHERE b.id=NEW.brand_id AND b.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Product brand belongs to another store') END;
END;

-- Invoices and purchases: referenced business partner and creator must belong to same store.
CREATE TRIGGER trg_invoices_store_refs_ins BEFORE INSERT ON invoices
BEGIN
  SELECT CASE WHEN NEW.customer_id IS NOT NULL AND NOT EXISTS
    (SELECT 1 FROM customers c WHERE c.id=NEW.customer_id AND c.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Invoice customer belongs to another store') END;
  SELECT CASE WHEN NEW.supplier_id IS NOT NULL AND NOT EXISTS
    (SELECT 1 FROM suppliers s WHERE s.id=NEW.supplier_id AND s.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Invoice supplier belongs to another store') END;
  SELECT CASE WHEN NOT EXISTS
    (SELECT 1 FROM users u WHERE u.id=NEW.created_by AND u.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Invoice creator belongs to another store') END;
END;
CREATE TRIGGER trg_invoices_store_refs_upd BEFORE UPDATE OF store_id, customer_id, supplier_id, created_by ON invoices
BEGIN
  SELECT CASE WHEN NEW.customer_id IS NOT NULL AND NOT EXISTS
    (SELECT 1 FROM customers c WHERE c.id=NEW.customer_id AND c.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Invoice customer belongs to another store') END;
  SELECT CASE WHEN NEW.supplier_id IS NOT NULL AND NOT EXISTS
    (SELECT 1 FROM suppliers s WHERE s.id=NEW.supplier_id AND s.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Invoice supplier belongs to another store') END;
  SELECT CASE WHEN NOT EXISTS
    (SELECT 1 FROM users u WHERE u.id=NEW.created_by AND u.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Invoice creator belongs to another store') END;
END;

CREATE TRIGGER trg_purchases_store_refs_ins BEFORE INSERT ON purchases
BEGIN
  SELECT CASE WHEN NOT EXISTS
    (SELECT 1 FROM suppliers s WHERE s.id=NEW.supplier_id AND s.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Purchase supplier belongs to another store') END;
  SELECT CASE WHEN NOT EXISTS
    (SELECT 1 FROM users u WHERE u.id=NEW.created_by AND u.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Purchase creator belongs to another store') END;
END;
CREATE TRIGGER trg_purchases_store_refs_upd BEFORE UPDATE OF store_id, supplier_id, created_by ON purchases
BEGIN
  SELECT CASE WHEN NOT EXISTS
    (SELECT 1 FROM suppliers s WHERE s.id=NEW.supplier_id AND s.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Purchase supplier belongs to another store') END;
  SELECT CASE WHEN NOT EXISTS
    (SELECT 1 FROM users u WHERE u.id=NEW.created_by AND u.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Purchase creator belongs to another store') END;
END;

-- Line items: product must belong to the parent document's store.
CREATE TRIGGER trg_invoice_items_store_ins BEFORE INSERT ON invoice_items
BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM products p JOIN invoices i ON i.id=NEW.invoice_id
    WHERE p.id=NEW.product_id AND p.store_id=i.store_id)
    THEN RAISE(ABORT, 'Invoice item product belongs to another store') END;
END;
CREATE TRIGGER trg_invoice_items_store_upd BEFORE UPDATE OF invoice_id, product_id ON invoice_items
BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM products p JOIN invoices i ON i.id=NEW.invoice_id
    WHERE p.id=NEW.product_id AND p.store_id=i.store_id)
    THEN RAISE(ABORT, 'Invoice item product belongs to another store') END;
END;
CREATE TRIGGER trg_purchase_items_store_ins BEFORE INSERT ON purchase_items
BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM products p JOIN purchases pu ON pu.id=NEW.purchase_id
    WHERE p.id=NEW.product_id AND p.store_id=pu.store_id)
    THEN RAISE(ABORT, 'Purchase item product belongs to another store') END;
END;
CREATE TRIGGER trg_purchase_items_store_upd BEFORE UPDATE OF purchase_id, product_id ON purchase_items
BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM products p JOIN purchases pu ON pu.id=NEW.purchase_id
    WHERE p.id=NEW.product_id AND p.store_id=pu.store_id)
    THEN RAISE(ABORT, 'Purchase item product belongs to another store') END;
END;

-- Returns: invoice and return must be in the same store.
CREATE TRIGGER trg_sales_returns_store_ins BEFORE INSERT ON sales_returns
BEGIN
  SELECT CASE WHEN NOT EXISTS
    (SELECT 1 FROM invoices i WHERE i.id=NEW.original_invoice_id AND i.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Return invoice belongs to another store') END;
  SELECT CASE WHEN NOT EXISTS
    (SELECT 1 FROM users u WHERE u.id=NEW.created_by AND u.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Return creator belongs to another store') END;
END;
CREATE TRIGGER trg_sales_returns_store_upd BEFORE UPDATE OF store_id, original_invoice_id, created_by ON sales_returns
BEGIN
  SELECT CASE WHEN NOT EXISTS
    (SELECT 1 FROM invoices i WHERE i.id=NEW.original_invoice_id AND i.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Return invoice belongs to another store') END;
  SELECT CASE WHEN NOT EXISTS
    (SELECT 1 FROM users u WHERE u.id=NEW.created_by AND u.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Return creator belongs to another store') END;
END;

-- Payments/ledgers: customer or supplier and creating user must be in same store.
CREATE TRIGGER trg_customer_payments_store_ins BEFORE INSERT ON customer_payments
BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM customers c JOIN users u ON u.id=NEW.created_by
    WHERE c.id=NEW.customer_id AND c.store_id=u.store_id)
    THEN RAISE(ABORT, 'Customer payment references another store') END;
END;
CREATE TRIGGER trg_supplier_payments_store_ins BEFORE INSERT ON supplier_payments
BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM suppliers s JOIN users u ON u.id=NEW.created_by
    WHERE s.id=NEW.supplier_id AND s.store_id=u.store_id)
    THEN RAISE(ABORT, 'Supplier payment references another store') END;
END;

-- Stock movements and all financial ledger rows must use same-store actors.
CREATE TRIGGER trg_stock_movements_store_ins BEFORE INSERT ON stock_movements
BEGIN
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM products p JOIN users u ON u.id=NEW.user_id
    WHERE p.id=NEW.product_id AND p.store_id=u.store_id)
    THEN RAISE(ABORT, 'Stock movement product/user belongs to another store') END;
END;
CREATE TRIGGER trg_stock_movements_store_upd BEFORE UPDATE OF product_id, user_id ON stock_movements
BEGIN
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM products p JOIN users u ON u.id=NEW.user_id
    WHERE p.id=NEW.product_id AND p.store_id=u.store_id)
    THEN RAISE(ABORT, 'Stock movement product/user belongs to another store') END;
END;
CREATE TRIGGER trg_customer_ledgers_store_ins BEFORE INSERT ON customer_ledgers
BEGIN
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM customers c JOIN users u ON u.id=NEW.created_by
    WHERE c.id=NEW.customer_id AND c.store_id=u.store_id)
    THEN RAISE(ABORT, 'Customer ledger references another store') END;
END;
CREATE TRIGGER trg_supplier_ledgers_store_ins BEFORE INSERT ON supplier_ledger
BEGIN
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM suppliers s JOIN users u ON u.id=NEW.created_by
    WHERE s.id=NEW.supplier_id AND s.store_id=u.store_id)
    THEN RAISE(ABORT, 'Supplier ledger references another store') END;
END;
CREATE TRIGGER trg_return_items_store_ins BEFORE INSERT ON return_items
BEGIN
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM sales_returns r JOIN products p ON p.id=NEW.product_id
    WHERE r.id=NEW.return_id AND r.store_id=p.store_id)
    THEN RAISE(ABORT, 'Return item product belongs to another store') END;
END;
CREATE TRIGGER trg_return_items_store_upd BEFORE UPDATE OF return_id, product_id ON return_items
BEGIN
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM sales_returns r JOIN products p ON p.id=NEW.product_id
    WHERE r.id=NEW.return_id AND r.store_id=p.store_id)
    THEN RAISE(ABORT, 'Return item product belongs to another store') END;
END;
CREATE TRIGGER trg_expenses_creator_store_ins BEFORE INSERT ON expenses
BEGIN
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM users u WHERE u.id=NEW.created_by AND u.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Expense creator belongs to another store') END;
END;
CREATE TRIGGER trg_revenues_creator_store_ins BEFORE INSERT ON revenues
BEGIN
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM users u WHERE u.id=NEW.created_by AND u.store_id=NEW.store_id)
    THEN RAISE(ABORT, 'Revenue creator belongs to another store') END;
END;
```

**ملاحظة تشغيلية:** يجب على التطبيق تنفيذ `PRAGMA foreign_keys = ON` لكل اتصال SQLite جديد، واستخدام معاملة واحدة (`BEGIN IMMEDIATE`) عند ترحيل/حفظ العمليات المالية والمخزنية. لا تعتمد على `MAX(sync_cursor)+1` كبديل عن UUID للعملية؛ cursor هنا تسلسل تغييرات لكل متجر، و`operation_id` يبقى مفتاح idempotency مستقل.
