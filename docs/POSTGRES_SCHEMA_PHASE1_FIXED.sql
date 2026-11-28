-- ============================================================
-- ATACK PLUS PostgreSQL Schema
-- للتمثيل السحابي والمزامنة
-- Phase 1 hardening: per-store identifiers, Auth/RBAC checks, transactional cursors, invoice_items RLS
-- PostgreSQL >= 15 (target: Supabase PostgreSQL; requires Supabase Auth auth.uid())
-- ============================================================

-- تفعيل الإضافات المطلوبة
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
-- Resolve pgcrypto across Supabase (extensions schema) and vanilla PostgreSQL
-- (public schema) without depending on a caller's search_path.
CREATE OR REPLACE FUNCTION public.atack_digest(p_data BYTEA,p_algorithm TEXT)
RETURNS BYTEA
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp
AS $atack_digest$
DECLARE
    v_result BYTEA;
BEGIN
    IF to_regprocedure('extensions.digest(bytea,text)') IS NOT NULL THEN
        EXECUTE 'SELECT extensions.digest($1,$2)' INTO v_result
          USING p_data,p_algorithm;
    ELSIF to_regprocedure('public.digest(bytea,text)') IS NOT NULL THEN
        EXECUTE 'SELECT public.digest($1,$2)' INTO v_result
          USING p_data,p_algorithm;
    ELSE
        RAISE EXCEPTION 'pgcrypto digest(bytea,text) is not installed';
    END IF;
    RETURN v_result;
END;
$atack_digest$;
REVOKE ALL ON FUNCTION public.atack_digest(BYTEA,TEXT)
  FROM PUBLIC,anon,authenticated;


-- ============================================================
-- 1. stores (المتاجر)
-- ============================================================
CREATE TABLE stores (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    address TEXT,
    currency TEXT NOT NULL DEFAULT 'DZD' CHECK(currency = 'DZD'),
    tax_number TEXT,
    fiscal_year_start_month INTEGER NOT NULL DEFAULT 1 CHECK(fiscal_year_start_month BETWEEN 1 AND 12),
    barcode_prefix TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_stores_name ON stores(name);

-- ============================================================
-- 2. devices (الأجهزة)
-- ============================================================
CREATE TABLE devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    device_name TEXT NOT NULL,
    device_type TEXT NOT NULL CHECK(device_type IN ('PHONE', 'TABLET', 'DESKTOP')),
    last_seen TIMESTAMPTZ,
    is_online BOOLEAN DEFAULT FALSE,
    app_version TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE,
    CONSTRAINT unique_device_per_store UNIQUE (store_id, device_name)
);

CREATE INDEX idx_devices_store ON devices(store_id);
CREATE INDEX idx_devices_online ON devices(is_online);

-- ============================================================
-- 3. users (المستخدمون)
-- ============================================================
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_user_id UUID UNIQUE, -- Supabase Auth UID; set during account provisioning
    store_id UUID NOT NULL,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT, -- Deprecated: authentication credentials are managed by Supabase Auth, never stored here.
    full_name TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    failed_login_attempts INTEGER DEFAULT 0,
    locked_until TIMESTAMPTZ,
    last_login_at TIMESTAMPTZ,
    password_changed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE
);

CREATE INDEX idx_users_username ON users(username);
CREATE INDEX idx_users_store ON users(store_id);

-- ============================================================
-- 4. Roles & Permissions
-- ============================================================
CREATE TABLE roles (
    id TEXT PRIMARY KEY CHECK(id IN ('owner', 'cashier')),
    name TEXT NOT NULL,
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE
);

CREATE TABLE permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code TEXT NOT NULL UNIQUE,
    description TEXT
);

CREATE TABLE role_permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_id TEXT NOT NULL,
    permission_id UUID NOT NULL,
    granted_at TIMESTAMPTZ DEFAULT NOW(),
    FOREIGN KEY (role_id) REFERENCES roles(id),
    FOREIGN KEY (permission_id) REFERENCES permissions(id),
    UNIQUE(role_id, permission_id)
);

-- ============================================================
-- 5. user_roles (ربط المستخدمين بالأدوار)
-- ============================================================
CREATE TABLE user_roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    role_id TEXT NOT NULL,
    granted_by UUID,
    granted_at TIMESTAMPTZ DEFAULT NOW(),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (role_id) REFERENCES roles(id),
    FOREIGN KEY (granted_by) REFERENCES users(id),
    CONSTRAINT unique_user_role UNIQUE (user_id, role_id)
);

-- ============================================================
-- 6. units
-- ============================================================
CREATE TABLE units (
    id TEXT PRIMARY KEY CHECK(id IN ('pcs', 'g', 'kg', 'liter', 'box', 'carton')),
    name TEXT NOT NULL,
    symbol TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 7. categories و brands و products
-- ============================================================
CREATE TABLE categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    parent_id UUID,
    name TEXT NOT NULL,
    code TEXT,
    sort_order INTEGER DEFAULT 0,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE,
    FOREIGN KEY (parent_id) REFERENCES categories(id)
);

CREATE INDEX idx_categories_store ON categories(store_id);
CREATE INDEX idx_categories_parent ON categories(parent_id);

CREATE TABLE brands (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    name TEXT NOT NULL,
    scent TEXT,
    size TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE
);

CREATE TABLE products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    barcode TEXT,
    name TEXT NOT NULL,
    description TEXT,
    category_id UUID,
    brand_id UUID,
    primary_unit_id TEXT NOT NULL,
    cost_price NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(cost_price >= 0),
    default_sale_price NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(default_sale_price >= 0),
    tax_rate NUMERIC(5,2) DEFAULT 0 CHECK(tax_rate BETWEEN 0 AND 100),
    minimum_stock NUMERIC(18,4) DEFAULT 0 CHECK(minimum_stock >= 0),
    max_stock NUMERIC(18,4) CHECK(max_stock IS NULL OR max_stock >= minimum_stock),
    weight NUMERIC(10,3),
    length NUMERIC(10,3),
    width NUMERIC(10,3),
    height NUMERIC(10,3),
    expiry_enabled BOOLEAN DEFAULT FALSE,
    batch_enabled BOOLEAN DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    deleted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
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

-- ============================================================
-- 7b. product_units
-- ============================================================
CREATE TABLE product_units (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id UUID NOT NULL,
    unit_id TEXT NOT NULL,
    conversion_factor NUMERIC(18,6) NOT NULL CHECK(conversion_factor > 0),
    sale_price NUMERIC(18,4) CHECK(sale_price >= 0),
    purchase_price NUMERIC(18,4) CHECK(purchase_price >= 0),
    is_primary BOOLEAN DEFAULT FALSE,
    is_default BOOLEAN DEFAULT FALSE,
    sort_order INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
    FOREIGN KEY (unit_id) REFERENCES units(id),
    UNIQUE(product_id, unit_id)
);

CREATE INDEX idx_product_units_product ON product_units(product_id);
CREATE INDEX idx_product_units_unit ON product_units(unit_id);

-- ============================================================
-- 8. stock و stock_movements
-- ============================================================
CREATE TABLE locations (
    id TEXT PRIMARY KEY CHECK(id IN ('main', 'warehouse', 'storage')),
    name TEXT NOT NULL,
    is_default BOOLEAN DEFAULT FALSE
);

CREATE TABLE stock (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id UUID NOT NULL,
    location_id TEXT NOT NULL DEFAULT 'main',
    quantity NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(quantity >= 0),
    reserved_quantity NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(reserved_quantity >= 0 AND reserved_quantity <= quantity),
    available_quantity NUMERIC(18,4) GENERATED ALWAYS AS (quantity - reserved_quantity) STORED,
    last_updated TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
    FOREIGN KEY (location_id) REFERENCES locations(id),
    CONSTRAINT unique_product_location UNIQUE (product_id, location_id)
);

-- Trigger function لتحديث last_updated عند تغيير الكميات
CREATE OR REPLACE FUNCTION trg_stock_last_updated_fn()
RETURNS TRIGGER AS $$
BEGIN
    NEW.last_updated := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_stock_last_updated
BEFORE UPDATE OF quantity, reserved_quantity ON stock FOR EACH ROW
EXECUTE FUNCTION trg_stock_last_updated_fn();

CREATE TABLE stock_movements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id UUID NOT NULL,
    location_id TEXT NOT NULL DEFAULT 'main',
    type TEXT NOT NULL CHECK(type IN ('IN', 'OUT', 'ADJUSTMENT', 'RETURN_IN', 'RETURN_OUT')),
    quantity NUMERIC(18,4) NOT NULL CHECK(quantity > 0),
    unit_id TEXT NOT NULL,
    cost_per_unit NUMERIC(18,4) NOT NULL CHECK(cost_per_unit >= 0),
    total_value NUMERIC(18,4) NOT NULL CHECK(total_value >= 0),
    reference_id UUID,
    reference_type TEXT CHECK(reference_type IN ('invoice', 'purchase', 'adjustment', 'return')),
    batch_number TEXT,
    expiry_date TIMESTAMPTZ,
    reason TEXT,
    user_id UUID NOT NULL,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (product_id) REFERENCES products(id),
    FOREIGN KEY (unit_id) REFERENCES units(id),
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX idx_stock_movements_product ON stock_movements(product_id);
CREATE INDEX idx_stock_movements_date ON stock_movements(created_at);
CREATE INDEX idx_stock_movements_reference ON stock_movements(reference_type, reference_id);
CREATE INDEX idx_stock_movements_sync ON stock_movements(sync_status);

-- ============================================================
-- 9. customers و customer_ledgers و payments
-- ============================================================
CREATE TABLE customers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
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
    is_active BOOLEAN DEFAULT TRUE,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE
);

CREATE TABLE customer_ledgers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id UUID NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('SALE', 'PAYMENT', 'RETURN', 'ADJUSTMENT')),
    amount NUMERIC(18,4) NOT NULL,
    balance NUMERIC(18,4) NOT NULL,
    reference_id UUID,
    description TEXT,
    created_by UUID NOT NULL,
    device_sync_id TEXT,
    is_synced BOOLEAN DEFAULT FALSE,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (customer_id) REFERENCES customers(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE INDEX idx_customer_ledgers_customer ON customer_ledgers(customer_id);
CREATE INDEX idx_customer_ledgers_date ON customer_ledgers(created_at);

CREATE TABLE customer_payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id UUID NOT NULL,
    amount NUMERIC(18,4) NOT NULL CHECK(amount > 0),
    payment_method TEXT NOT NULL CHECK(payment_method IN ('CASH', 'CARD', 'BANK_TRANSFER', 'MOBILE')),
    reference_no TEXT,
    notes TEXT,
    created_by UUID NOT NULL,
    device_sync_id TEXT,
    is_synced BOOLEAN DEFAULT FALSE,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (customer_id) REFERENCES customers(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);


-- ============================================================
-- 10. suppliers و purchases
-- ============================================================
CREATE TABLE suppliers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
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
    is_active BOOLEAN DEFAULT TRUE,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE
);

CREATE TABLE purchases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    purchase_number TEXT NOT NULL,
    supplier_id UUID NOT NULL,
    grn_number TEXT,
    supplier_invoice_no TEXT,
    supplier_invoice_amount NUMERIC(18,4),
    purchase_date TIMESTAMPTZ NOT NULL,
    received_date TIMESTAMPTZ,
    subtotal NUMERIC(18,4) DEFAULT 0,
    discount_total NUMERIC(18,4) DEFAULT 0,
    tax_total NUMERIC(18,4) DEFAULT 0,
    total_amount NUMERIC(18,4) DEFAULT 0,
    paid_amount NUMERIC(18,4) DEFAULT 0,
    remaining_amount NUMERIC(18,4) DEFAULT 0,
    payment_method TEXT CHECK(payment_method IN ('CASH', 'CARD', 'BANK_TRANSFER', 'MOBILE')),
    notes TEXT,
    created_by UUID NOT NULL,
    device_sync_id TEXT,
    is_synced BOOLEAN DEFAULT FALSE,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    status TEXT CHECK(status IN ('DRAFT', 'OPEN', 'PARTIAL', 'PAID', 'CANCELLED')) DEFAULT 'OPEN',
    deleted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (supplier_id) REFERENCES suppliers(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE TABLE purchase_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_id UUID NOT NULL,
    product_id UUID NOT NULL,
    quantity NUMERIC(18,4) NOT NULL CHECK(quantity > 0),
    quantity_unit_id TEXT NOT NULL,
    unit_price NUMERIC(18,4) NOT NULL CHECK(unit_price >= 0),
    cost_per_unit NUMERIC(18,4) NOT NULL CHECK(cost_per_unit >= 0),
    tax_rate NUMERIC(5,2) DEFAULT 0,
    tax_amount NUMERIC(18,4) DEFAULT 0,
    line_total NUMERIC(18,4) NOT NULL,
    batch_number TEXT,
    expiry_date TIMESTAMPTZ,
    received BOOLEAN DEFAULT FALSE,
    received_date TIMESTAMPTZ,
    is_synced BOOLEAN DEFAULT FALSE,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (purchase_id) REFERENCES purchases(id) ON DELETE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
    FOREIGN KEY (quantity_unit_id) REFERENCES units(id) ON DELETE RESTRICT
);

-- ============================================================
-- 10b. supplier_ledger و supplier_payments
-- ============================================================
CREATE TABLE supplier_ledger (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id UUID NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('PURCHASE', 'PAYMENT', 'ADJUSTMENT')),
    amount NUMERIC(18,4) NOT NULL,
    balance NUMERIC(18,4) NOT NULL,
    reference_id UUID,
    description TEXT,
    created_by UUID NOT NULL,
    device_sync_id TEXT,
    is_synced BOOLEAN DEFAULT FALSE,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (supplier_id) REFERENCES suppliers(id) ON DELETE CASCADE,
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE INDEX idx_supplier_ledger_supplier ON supplier_ledger(supplier_id);
CREATE INDEX idx_supplier_ledger_date ON supplier_ledger(created_at);

CREATE TABLE supplier_payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id UUID NOT NULL,
    amount NUMERIC(18,4) NOT NULL CHECK(amount > 0),
    payment_method TEXT NOT NULL CHECK(payment_method IN ('CASH', 'CARD', 'BANK_TRANSFER', 'MOBILE')),
    reference_no TEXT,
    notes TEXT,
    created_by UUID NOT NULL,
    device_sync_id TEXT,
    is_synced BOOLEAN DEFAULT FALSE,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (supplier_id) REFERENCES suppliers(id) ON DELETE CASCADE,
    FOREIGN KEY (created_by) REFERENCES users(id)
);

-- Trigger: منع تجاوز مجموع مخصصات المورد لمبلغ الدفعة
CREATE OR REPLACE FUNCTION validate_supplier_payment_allocations()
RETURNS TRIGGER AS $$
DECLARE
    v_supplier_debt NUMERIC(18,4);
    v_other_payments NUMERIC(18,4);
BEGIN
    -- Serialize all payment changes for this supplier.
    SELECT current_debt INTO v_supplier_debt
    FROM suppliers
    WHERE id = NEW.supplier_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Supplier not found';
    END IF;

    IF v_supplier_debt IS NULL OR v_supplier_debt < 0 THEN
        RAISE EXCEPTION 'Supplier debt is invalid';
    END IF;

    SELECT COALESCE(SUM(amount), 0)
      INTO v_other_payments
      FROM supplier_payments
     WHERE supplier_id = NEW.supplier_id
       AND id IS DISTINCT FROM NEW.id;

    IF v_other_payments + NEW.amount > v_supplier_debt THEN
        RAISE EXCEPTION 'Total supplier payments exceed current debt';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_supplier_payment
BEFORE INSERT OR UPDATE OF supplier_id, amount ON supplier_payments
FOR EACH ROW EXECUTE FUNCTION validate_supplier_payment_allocations();

-- ============================================================
-- 11. invoices و invoice_items
-- ============================================================
CREATE TABLE invoices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    invoice_number TEXT NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('SALE', 'PURCHASE')),
    customer_id UUID,
    supplier_id UUID,
    invoice_date TIMESTAMPTZ NOT NULL,
    due_date TIMESTAMPTZ,
    subtotal NUMERIC(18,4) NOT NULL DEFAULT 0,
    discount_total NUMERIC(18,4) DEFAULT 0,
    tax_total NUMERIC(18,4) DEFAULT 0,
    total_amount NUMERIC(18,4) NOT NULL DEFAULT 0,
    paid_amount NUMERIC(18,4) DEFAULT 0,
    remaining_amount NUMERIC(18,4) DEFAULT 0,
    payment_method TEXT CHECK(payment_method IN ('CASH', 'CARD', 'BANK_TRANSFER', 'MOBILE')),
    notes TEXT,
    created_by UUID NOT NULL,
    device_sync_id TEXT,
    is_synced BOOLEAN DEFAULT FALSE,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    status TEXT CHECK(status IN ('DRAFT', 'OPEN', 'PAID', 'PARTIAL', 'CANCELLED', 'DELETED')) DEFAULT 'OPEN',
    deleted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
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

CREATE TABLE invoice_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id UUID NOT NULL,
    product_id UUID NOT NULL,
    quantity NUMERIC(18,4) NOT NULL CHECK(quantity > 0),
    quantity_unit_id TEXT NOT NULL,
    unit_price NUMERIC(18,4) NOT NULL CHECK(unit_price >= 0),
    cost_per_unit NUMERIC(18,4) CHECK(cost_per_unit >= 0),
    discount_percent NUMERIC(5,2) DEFAULT 0 CHECK(discount_percent BETWEEN 0 AND 100),
    discount_amount NUMERIC(18,4) DEFAULT 0,
    tax_rate NUMERIC(5,2) DEFAULT 0,
    tax_amount NUMERIC(18,4) DEFAULT 0,
    line_total NUMERIC(18,4) NOT NULL,
    batch_number TEXT,
    expiry_date TIMESTAMPTZ,
    is_synced BOOLEAN DEFAULT FALSE,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (invoice_id) REFERENCES invoices(id) ON DELETE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(id),
    FOREIGN KEY (quantity_unit_id) REFERENCES units(id)
);

CREATE INDEX idx_invoice_items_invoice ON invoice_items(invoice_id);
CREATE INDEX idx_invoice_items_product ON invoice_items(product_id);
CREATE INDEX idx_invoice_items_sync ON invoice_items(sync_status);

-- ============================================================
-- payment_allocations (بعد invoices و invoice_items)
-- ============================================================
CREATE TABLE payment_allocations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payment_id UUID NOT NULL,
    invoice_id UUID NOT NULL,
    allocated_amount NUMERIC(18,4) NOT NULL CHECK(allocated_amount > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (payment_id) REFERENCES customer_payments(id) ON DELETE CASCADE,
    FOREIGN KEY (invoice_id) REFERENCES invoices(id) ON DELETE CASCADE,
    UNIQUE(payment_id, invoice_id)
);

-- Trigger: منع تجاوز مجموع المخصصات لمبلغ الفاتورة أو الدفعة
CREATE OR REPLACE FUNCTION validate_payment_allocations()
RETURNS TRIGGER AS $$
DECLARE
    v_invoice_remaining NUMERIC(18,4);
    v_payment_amount NUMERIC(18,4);
    v_invoice_allocated NUMERIC(18,4);
    v_payment_allocated NUMERIC(18,4);
BEGIN
    -- Lock both parent rows in deterministic order to serialize concurrent allocations.
    PERFORM 1 FROM invoices WHERE id = NEW.invoice_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Invoice not found'; END IF;
    PERFORM 1 FROM customer_payments WHERE id = NEW.payment_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Customer payment not found'; END IF;

    SELECT remaining_amount INTO v_invoice_remaining FROM invoices WHERE id = NEW.invoice_id;
    SELECT amount INTO v_payment_amount FROM customer_payments WHERE id = NEW.payment_id;

    SELECT COALESCE(SUM(allocated_amount), 0) INTO v_invoice_allocated
    FROM payment_allocations WHERE invoice_id = NEW.invoice_id AND id IS DISTINCT FROM NEW.id;
    SELECT COALESCE(SUM(allocated_amount), 0) INTO v_payment_allocated
    FROM payment_allocations WHERE payment_id = NEW.payment_id AND id IS DISTINCT FROM NEW.id;

    IF v_invoice_allocated + NEW.allocated_amount > v_invoice_remaining THEN
        RAISE EXCEPTION 'Total allocations exceed invoice remaining amount';
    END IF;
    IF v_payment_allocated + NEW.allocated_amount > v_payment_amount THEN
        RAISE EXCEPTION 'Total allocations exceed payment amount';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_payment_allocations
BEFORE INSERT OR UPDATE ON payment_allocations FOR EACH ROW
EXECUTE FUNCTION validate_payment_allocations();

-- ============================================================
-- 12. sales_returns
-- ============================================================
CREATE TABLE sales_returns (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    return_number TEXT NOT NULL,
    original_invoice_id UUID NOT NULL,
    reason TEXT,
    total_amount NUMERIC(18,4) NOT NULL DEFAULT 0,
    refund_method TEXT CHECK(refund_method IN ('CREDIT', 'CASH', 'EXCHANGE')),
    notes TEXT,
    created_by UUID NOT NULL,
    device_sync_id TEXT,
    is_synced BOOLEAN DEFAULT FALSE,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (original_invoice_id) REFERENCES invoices(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE TABLE return_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    return_id UUID NOT NULL,
    product_id UUID NOT NULL,
    quantity NUMERIC(18,4) NOT NULL CHECK(quantity > 0),
    unit_price NUMERIC(18,4) NOT NULL CHECK(unit_price >= 0),
    line_total NUMERIC(18,4) NOT NULL,
    batch_number TEXT,
    expiry_date TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (return_id) REFERENCES sales_returns(id) ON DELETE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(id)
);

-- ============================================================
-- 13. expenses و revenues
-- ============================================================
CREATE TABLE expenses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    category TEXT NOT NULL,
    description TEXT,
    amount NUMERIC(18,4) NOT NULL CHECK(amount > 0),
    expense_date TIMESTAMPTZ NOT NULL,
    payment_method TEXT CHECK(payment_method IN ('CASH', 'CARD', 'BANK_TRANSFER', 'MOBILE')),
    receipt_number TEXT,
    attachment_path TEXT,
    created_by UUID NOT NULL,
    device_sync_id TEXT,
    is_synced BOOLEAN DEFAULT FALSE,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE TABLE revenues (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    category TEXT NOT NULL,
    description TEXT,
    amount NUMERIC(18,4) NOT NULL CHECK(amount > 0),
    revenue_date TIMESTAMPTZ NOT NULL,
    source TEXT,
    created_by UUID NOT NULL,
    device_sync_id TEXT,
    is_synced BOOLEAN DEFAULT FALSE,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

-- ============================================================
-- 14. المزامنة (Sync System)
-- ============================================================

-- 14.1 processed_operations (Idempotency)
CREATE TABLE processed_operations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    operation_id UUID NOT NULL,                   -- idempotency key (ثابت لكل عملية)
    operation_type TEXT NOT NULL CHECK(operation_type IN ('sync_insert', 'sync_update', 'sync_delete', 'sync_conflict')),
    entity_table TEXT NOT NULL,
    entity_uuid UUID NOT NULL,
    payload_hash TEXT NOT NULL,                    -- SHA256 hash of the payload
    processed_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(store_id, operation_id)
);

CREATE INDEX idx_processed_ops_store ON processed_operations(store_id);
CREATE INDEX idx_processed_ops_entity ON processed_operations(entity_table, entity_uuid);
CREATE INDEX idx_processed_ops_hash ON processed_operations(payload_hash);

-- 14.2 sync_cursors
CREATE TABLE sync_cursors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    device_id TEXT NOT NULL,
    table_name TEXT NOT NULL,
    cursor_value TEXT,
    last_pull_seq BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    UNIQUE(store_id, device_id, table_name)
);

CREATE INDEX idx_sync_cursors_store ON sync_cursors(store_id, device_id);
CREATE INDEX idx_sync_cursors_seq ON sync_cursors(last_pull_seq);

-- Transactional per-store cursor allocator. The row lock is held until commit,
-- so a later committed transaction cannot expose a higher cursor before a lower one.
CREATE TABLE store_sync_counters (
    store_id UUID PRIMARY KEY REFERENCES stores(id) ON DELETE CASCADE,
    last_cursor BIGINT NOT NULL DEFAULT 0 CHECK (last_cursor >= 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 14.3 change_log (Central Change Log)
CREATE TABLE change_log (
    id BIGSERIAL PRIMARY KEY,                     -- change_seq (auto-incrementing)
    store_id UUID NOT NULL,
    sync_cursor BIGINT NOT NULL,
    table_name TEXT NOT NULL,
    record_uuid UUID NOT NULL,
    operation TEXT NOT NULL CHECK(operation IN ('INSERT', 'UPDATE', 'DELETE')),
    old_values_json JSONB,
    new_values_json JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_change_log_cursor ON change_log(sync_cursor);
CREATE INDEX idx_change_log_table ON change_log(table_name);
CREATE INDEX idx_change_log_record ON change_log(record_uuid);
CREATE INDEX idx_change_log_created ON change_log(created_at);
CREATE INDEX idx_change_log_store ON change_log(store_id);
CREATE UNIQUE INDEX uq_change_log_store_cursor ON change_log(store_id, sync_cursor);

-- 14.4 sync_outbox
CREATE TABLE sync_outbox (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    device_id TEXT NOT NULL,
    table_name TEXT NOT NULL,
    operation TEXT NOT NULL CHECK(operation IN ('INSERT', 'UPDATE', 'DELETE')),
    record_uuid UUID NOT NULL,
    idempotency_key UUID NOT NULL,
    record_json JSONB NOT NULL,
    payload_hash TEXT NOT NULL,
    status TEXT DEFAULT 'PENDING' CHECK(status IN ('PENDING', 'IN_PROGRESS', 'SYNCED', 'FAILED', 'CONFLICT')),
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3,
    error_message TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    last_attempt TIMESTAMPTZ,
    synced_at TIMESTAMPTZ,
    FOREIGN KEY (store_id) REFERENCES stores(id)
);

CREATE INDEX idx_outbox_status ON sync_outbox(status);
CREATE INDEX idx_outbox_store ON sync_outbox(store_id);
CREATE INDEX idx_outbox_table ON sync_outbox(table_name);
CREATE INDEX idx_outbox_created ON sync_outbox(created_at);
CREATE INDEX idx_outbox_idempotency ON sync_outbox(idempotency_key);
CREATE INDEX idx_outbox_payload ON sync_outbox(payload_hash);

-- 14.5 sync_conflicts
CREATE TABLE sync_conflicts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    table_name TEXT NOT NULL,
    record_uuid UUID NOT NULL,
    conflict_type TEXT NOT NULL CHECK(conflict_type IN ('INVENTORY', 'INVOICE', 'CUSTOMER_DEBT', 'SUPPLIER_DEBT', 'PRICE', 'DUPLICATE')),
    local_record_json JSONB NOT NULL,
    remote_record_json JSONB NOT NULL,
    resolution_status TEXT DEFAULT 'PENDING' CHECK(resolution_status IN ('PENDING', 'ACCEPT_LOCAL', 'ACCEPT_REMOTE', 'MERGE')),
    resolution_notes TEXT,
    resolved_by UUID,
    resolved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (resolved_by) REFERENCES users(id)
);

CREATE INDEX idx_conflicts_pending ON sync_conflicts(resolution_status) WHERE resolution_status = 'PENDING';
CREATE INDEX idx_conflicts_table ON sync_conflicts(table_name);

-- 14.5 tombstones
CREATE TABLE tombstones (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    table_name TEXT NOT NULL,
    record_uuid UUID NOT NULL,
    deleted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_by UUID NOT NULL,
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('PENDING', 'SYNCED', 'ERROR')),
    synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (deleted_by) REFERENCES users(id),
    CONSTRAINT unique_tombstone UNIQUE (table_name, record_uuid)
);

CREATE INDEX idx_tombstones_store ON tombstones(store_id);
CREATE INDEX idx_tombstones_record ON tombstones(table_name, record_uuid);
CREATE INDEX idx_tombstones_sync ON tombstones(sync_status);
CREATE INDEX idx_tombstones_deleted_at ON tombstones(deleted_at);

-- 14.6 sync_log
CREATE TABLE sync_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    device_id TEXT NOT NULL,
    operation TEXT NOT NULL CHECK(operation IN ('PUSH', 'PULL', 'FULL_SYNC', 'CONFLICT_RESOLUTION')),
    status TEXT NOT NULL CHECK(status IN ('STARTED', 'SUCCESS', 'ERROR', 'CONFLICT')),
    records_processed INTEGER DEFAULT 0,
    duration_seconds REAL,
    error_message TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id)
);

CREATE INDEX idx_sync_log_store ON sync_log(store_id);
CREATE INDEX idx_sync_log_created ON sync_log(created_at);

-- ============================================================
-- 15. audit_logs (سجل التدقيق)
-- ============================================================
CREATE TABLE audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    user_id UUID NOT NULL,
    entity_type TEXT,
    entity_id UUID,
    action TEXT NOT NULL CHECK(action IN ('CREATE', 'UPDATE', 'DELETE', 'VOID', 'SYNC')),
    old_values_json JSONB,
    new_values_json JSONB,
    ip_address TEXT,
    device_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX idx_audit_logs_date ON audit_logs(created_at);
CREATE INDEX idx_audit_logs_entity ON audit_logs(entity_type, entity_id);
CREATE INDEX idx_audit_logs_user ON audit_logs(user_id);
CREATE INDEX idx_audit_logs_store ON audit_logs(store_id);


-- Per-store business identifiers: match the SQLite schema semantics.
CREATE UNIQUE INDEX uq_categories_store_code ON categories(store_id, code) WHERE code IS NOT NULL;
CREATE UNIQUE INDEX uq_products_store_barcode ON products(store_id, barcode) WHERE barcode IS NOT NULL;
CREATE UNIQUE INDEX uq_customers_store_code ON customers(store_id, code);
CREATE UNIQUE INDEX uq_suppliers_store_code ON suppliers(store_id, code);
CREATE UNIQUE INDEX uq_invoices_store_number ON invoices(store_id, invoice_number);
CREATE UNIQUE INDEX uq_purchases_store_number ON purchases(store_id, purchase_number);
CREATE UNIQUE INDEX uq_sales_returns_store_number ON sales_returns(store_id, return_number);

-- ============================================================
-- Cross-store referential integrity
-- Prevent records in one store from referencing another store's
-- categories, brands, customers, suppliers or invoices.
-- ============================================================
ALTER TABLE categories
    ADD CONSTRAINT uq_categories_id_store UNIQUE (id, store_id);
ALTER TABLE brands
    ADD CONSTRAINT uq_brands_id_store UNIQUE (id, store_id);
ALTER TABLE customers
    ADD CONSTRAINT uq_customers_id_store UNIQUE (id, store_id);
ALTER TABLE suppliers
    ADD CONSTRAINT uq_suppliers_id_store UNIQUE (id, store_id);
ALTER TABLE invoices
    ADD CONSTRAINT uq_invoices_id_store UNIQUE (id, store_id);
ALTER TABLE users
    ADD CONSTRAINT uq_users_id_store UNIQUE (id, store_id);

ALTER TABLE categories DROP CONSTRAINT IF EXISTS categories_parent_id_fkey;
ALTER TABLE categories
    ADD CONSTRAINT fk_categories_parent_same_store
    FOREIGN KEY (parent_id, store_id) REFERENCES categories(id, store_id);

ALTER TABLE products DROP CONSTRAINT IF EXISTS products_category_id_fkey;
ALTER TABLE products DROP CONSTRAINT IF EXISTS products_brand_id_fkey;
ALTER TABLE products
    ADD CONSTRAINT fk_products_category_same_store
    FOREIGN KEY (category_id, store_id) REFERENCES categories(id, store_id),
    ADD CONSTRAINT fk_products_brand_same_store
    FOREIGN KEY (brand_id, store_id) REFERENCES brands(id, store_id);

ALTER TABLE invoices DROP CONSTRAINT IF EXISTS invoices_customer_id_fkey;
ALTER TABLE invoices DROP CONSTRAINT IF EXISTS invoices_supplier_id_fkey;
ALTER TABLE invoices
    ADD CONSTRAINT fk_invoices_customer_same_store
    FOREIGN KEY (customer_id, store_id) REFERENCES customers(id, store_id),
    ADD CONSTRAINT fk_invoices_supplier_same_store
    FOREIGN KEY (supplier_id, store_id) REFERENCES suppliers(id, store_id);

ALTER TABLE purchases DROP CONSTRAINT IF EXISTS purchases_supplier_id_fkey;
ALTER TABLE purchases
    ADD CONSTRAINT fk_purchases_supplier_same_store
    FOREIGN KEY (supplier_id, store_id) REFERENCES suppliers(id, store_id);

ALTER TABLE sales_returns DROP CONSTRAINT IF EXISTS sales_returns_original_invoice_id_fkey;
ALTER TABLE sales_returns
    ADD CONSTRAINT fk_sales_returns_invoice_same_store
    FOREIGN KEY (original_invoice_id, store_id) REFERENCES invoices(id, store_id);

ALTER TABLE invoices
    ADD CONSTRAINT fk_invoices_creator_same_store
    FOREIGN KEY (created_by, store_id) REFERENCES users(id, store_id);
ALTER TABLE purchases
    ADD CONSTRAINT fk_purchases_creator_same_store
    FOREIGN KEY (created_by, store_id) REFERENCES users(id, store_id);
ALTER TABLE sales_returns
    ADD CONSTRAINT fk_sales_returns_creator_same_store
    FOREIGN KEY (created_by, store_id) REFERENCES users(id, store_id);
ALTER TABLE expenses
    ADD CONSTRAINT fk_expenses_creator_same_store
    FOREIGN KEY (created_by, store_id) REFERENCES users(id, store_id);
ALTER TABLE revenues
    ADD CONSTRAINT fk_revenues_creator_same_store
    FOREIGN KEY (created_by, store_id) REFERENCES users(id, store_id);
ALTER TABLE audit_logs
    ADD CONSTRAINT fk_audit_logs_user_same_store
    FOREIGN KEY (user_id, store_id) REFERENCES users(id, store_id);
ALTER TABLE sync_conflicts
    ADD CONSTRAINT fk_sync_conflicts_resolver_same_store
    FOREIGN KEY (resolved_by, store_id) REFERENCES users(id, store_id);
ALTER TABLE tombstones
    ADD CONSTRAINT fk_tombstones_deleter_same_store
    FOREIGN KEY (deleted_by, store_id) REFERENCES users(id, store_id);

-- Cross-store checks for dependent tables that do not carry store_id.
CREATE OR REPLACE FUNCTION public.validate_same_store_references()
RETURNS TRIGGER AS $$
DECLARE
    v_store_a UUID;
    v_store_b UUID;
    v_store_c UUID;
    v_reference_count INTEGER;
    v_reference_store_count INTEGER;
BEGIN
    CASE TG_TABLE_NAME
      WHEN 'invoice_items' THEN
        SELECT store_id INTO v_store_a FROM invoices WHERE id = NEW.invoice_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM products WHERE id = NEW.product_id FOR SHARE;
      WHEN 'purchase_items' THEN
        SELECT store_id INTO v_store_a FROM purchases WHERE id = NEW.purchase_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM products WHERE id = NEW.product_id FOR SHARE;
      WHEN 'return_items' THEN
        SELECT store_id INTO v_store_a FROM sales_returns WHERE id = NEW.return_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM products WHERE id = NEW.product_id FOR SHARE;
      WHEN 'stock_movements' THEN
        SELECT store_id INTO v_store_a FROM products WHERE id = NEW.product_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM users WHERE id = NEW.user_id FOR SHARE;
        IF (NEW.reference_type IS NULL) <> (NEW.reference_id IS NULL) THEN
            RAISE EXCEPTION 'Stock movement reference type and ID must both be NULL or both be set';
        END IF;
        IF NEW.reference_type IS NOT NULL THEN
            CASE NEW.reference_type
              WHEN 'invoice' THEN
                SELECT store_id INTO v_store_c FROM invoices WHERE id = NEW.reference_id FOR SHARE;
              WHEN 'purchase' THEN
                SELECT store_id INTO v_store_c FROM purchases WHERE id = NEW.reference_id FOR SHARE;
              WHEN 'adjustment' THEN
                SELECT store_id INTO v_store_c FROM stock_adjustments WHERE id = NEW.reference_id FOR SHARE;
              WHEN 'return' THEN
                -- The existing business model uses reference_type='return' for
                -- both sales_returns and purchase_returns. Require exactly one
                -- matching parent so a UUID collision cannot make the reference ambiguous.
                PERFORM 1 FROM sales_returns WHERE id = NEW.reference_id FOR SHARE;
                PERFORM 1 FROM purchase_returns WHERE id = NEW.reference_id FOR SHARE;
                SELECT COUNT(*), COUNT(DISTINCT store_id)
                  INTO v_reference_count, v_reference_store_count
                  FROM (
                    SELECT store_id FROM sales_returns WHERE id = NEW.reference_id
                    UNION ALL
                    SELECT store_id FROM purchase_returns WHERE id = NEW.reference_id
                  ) AS return_refs;
                IF v_reference_count <> 1 OR v_reference_store_count <> 1 THEN
                    RAISE EXCEPTION 'Stock movement return reference must resolve to exactly one return record';
                END IF;
                SELECT store_id INTO v_store_c
                  FROM (
                    SELECT store_id FROM sales_returns WHERE id = NEW.reference_id
                    UNION ALL
                    SELECT store_id FROM purchase_returns WHERE id = NEW.reference_id
                  ) AS return_refs
                 LIMIT 1;
              ELSE
                RAISE EXCEPTION 'Unsupported stock movement reference type: %', NEW.reference_type;
            END CASE;
            IF v_store_c IS NULL OR v_store_c IS DISTINCT FROM v_store_a THEN
                RAISE EXCEPTION 'Stock movement reference must belong to the product store';
            END IF;
        END IF;
      WHEN 'customer_payments' THEN
        SELECT store_id INTO v_store_a FROM customers WHERE id = NEW.customer_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM users WHERE id = NEW.created_by FOR SHARE;
      WHEN 'customer_ledgers' THEN
        SELECT store_id INTO v_store_a FROM customers WHERE id = NEW.customer_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM users WHERE id = NEW.created_by FOR SHARE;
      WHEN 'supplier_payments' THEN
        SELECT store_id INTO v_store_a FROM suppliers WHERE id = NEW.supplier_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM users WHERE id = NEW.created_by FOR SHARE;
      WHEN 'supplier_ledger' THEN
        SELECT store_id INTO v_store_a FROM suppliers WHERE id = NEW.supplier_id FOR SHARE;
        SELECT store_id INTO v_store_b FROM users WHERE id = NEW.created_by FOR SHARE;
      WHEN 'product_units' THEN
        SELECT store_id INTO v_store_a FROM products WHERE id = NEW.product_id FOR SHARE;
        v_store_b := v_store_a;
      WHEN 'user_roles' THEN
        SELECT store_id INTO v_store_a FROM users WHERE id = NEW.user_id FOR SHARE;
        IF NEW.granted_by IS NOT NULL THEN
          SELECT store_id INTO v_store_b FROM users WHERE id = NEW.granted_by FOR SHARE;
        ELSE
          v_store_b := v_store_a;
        END IF;
      WHEN 'payment_allocations' THEN
        SELECT store_id INTO v_store_a FROM invoices WHERE id = NEW.invoice_id FOR SHARE;
        SELECT c.store_id INTO v_store_b
          FROM customer_payments cp
          JOIN customers c ON c.id = cp.customer_id
         WHERE cp.id = NEW.payment_id
         FOR SHARE OF cp, c;
        IF NOT EXISTS (
            SELECT 1 FROM invoices i
            JOIN customer_payments cp ON cp.id = NEW.payment_id
            WHERE i.id = NEW.invoice_id AND i.customer_id = cp.customer_id
        ) THEN
            RAISE EXCEPTION 'Payment allocation must link a payment and invoice for the same customer';
        END IF;
      ELSE
        RAISE EXCEPTION 'Unsupported table for same-store validation: %', TG_TABLE_NAME;
    END CASE;
    IF v_store_a IS NULL OR v_store_b IS NULL OR v_store_a IS DISTINCT FROM v_store_b THEN
        RAISE EXCEPTION 'Cross-store or missing reference rejected for table %', TG_TABLE_NAME;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE TRIGGER trg_invoice_items_same_store BEFORE INSERT OR UPDATE ON invoice_items
FOR EACH ROW EXECUTE FUNCTION public.validate_same_store_references();
CREATE TRIGGER trg_purchase_items_same_store BEFORE INSERT OR UPDATE ON purchase_items
FOR EACH ROW EXECUTE FUNCTION public.validate_same_store_references();
CREATE TRIGGER trg_return_items_same_store BEFORE INSERT OR UPDATE ON return_items
FOR EACH ROW EXECUTE FUNCTION public.validate_same_store_references();
CREATE TRIGGER trg_stock_movements_same_store BEFORE INSERT OR UPDATE ON stock_movements
FOR EACH ROW EXECUTE FUNCTION public.validate_same_store_references();
CREATE TRIGGER trg_customer_payments_same_store BEFORE INSERT OR UPDATE ON customer_payments
FOR EACH ROW EXECUTE FUNCTION public.validate_same_store_references();
CREATE TRIGGER trg_customer_ledgers_same_store BEFORE INSERT OR UPDATE ON customer_ledgers
FOR EACH ROW EXECUTE FUNCTION public.validate_same_store_references();
CREATE TRIGGER trg_supplier_payments_same_store BEFORE INSERT OR UPDATE ON supplier_payments
FOR EACH ROW EXECUTE FUNCTION public.validate_same_store_references();
CREATE TRIGGER trg_supplier_ledger_same_store BEFORE INSERT OR UPDATE ON supplier_ledger
FOR EACH ROW EXECUTE FUNCTION public.validate_same_store_references();
CREATE TRIGGER trg_product_units_same_store BEFORE INSERT OR UPDATE ON product_units
FOR EACH ROW EXECUTE FUNCTION public.validate_same_store_references();
CREATE TRIGGER trg_user_roles_same_store BEFORE INSERT OR UPDATE ON user_roles
FOR EACH ROW EXECUTE FUNCTION public.validate_same_store_references();
CREATE TRIGGER trg_payment_allocations_same_store BEFORE INSERT OR UPDATE ON payment_allocations
FOR EACH ROW EXECUTE FUNCTION public.validate_same_store_references();

-- ============================================================
-- Functions & Triggers
-- ============================================================

-- Trigger function لتحديث updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- تطبيق triggers على الجداول التي تحتوي على updated_at
CREATE TRIGGER trg_stores_updated_at
    BEFORE UPDATE ON stores FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_categories_updated_at
    BEFORE UPDATE ON categories FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_brands_updated_at
    BEFORE UPDATE ON brands FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_products_updated_at
    BEFORE UPDATE ON products FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_customers_updated_at
    BEFORE UPDATE ON customers FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_suppliers_updated_at
    BEFORE UPDATE ON suppliers FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_purchases_updated_at
    BEFORE UPDATE ON purchases FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_invoices_updated_at
    BEFORE UPDATE ON invoices FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_sales_returns_updated_at
    BEFORE UPDATE ON sales_returns FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_customer_payments_updated_at
    BEFORE UPDATE ON customer_payments FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_supplier_payments_updated_at
    BEFORE UPDATE ON supplier_payments FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_sync_cursors_updated_at
    BEFORE UPDATE ON sync_cursors FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_sync_conflicts_updated_at
    BEFORE UPDATE ON sync_conflicts FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- Change Log Triggers — سجل التغييرات تلقائياً على الجداول التجارية
-- ============================================================
CREATE OR REPLACE FUNCTION trg_log_change()
RETURNS TRIGGER AS $$
DECLARE
    v_row JSONB;
    v_store_id UUID;
    v_record_id UUID;
BEGIN
    IF TG_OP = 'DELETE' THEN v_row := to_jsonb(OLD); ELSE v_row := to_jsonb(NEW); END IF;

    IF TG_TABLE_NAME = 'stores' THEN
        v_store_id := (v_row->>'id')::UUID;
    ELSIF v_row ? 'store_id' THEN
        v_store_id := (v_row->>'store_id')::UUID;
    ELSIF v_row ? 'invoice_id' THEN
        SELECT store_id INTO v_store_id FROM invoices WHERE id=(v_row->>'invoice_id')::UUID;
    ELSIF v_row ? 'purchase_id' THEN
        SELECT store_id INTO v_store_id FROM purchases WHERE id=(v_row->>'purchase_id')::UUID;
    ELSIF v_row ? 'customer_id' THEN
        SELECT store_id INTO v_store_id FROM customers WHERE id=(v_row->>'customer_id')::UUID;
    ELSIF v_row ? 'supplier_id' THEN
        SELECT store_id INTO v_store_id FROM suppliers WHERE id=(v_row->>'supplier_id')::UUID;
    ELSIF v_row ? 'original_invoice_id' THEN
        SELECT store_id INTO v_store_id FROM invoices WHERE id=(v_row->>'original_invoice_id')::UUID;
    ELSIF TG_TABLE_NAME = 'return_items' AND v_row ? 'return_id' THEN
        SELECT store_id INTO v_store_id FROM sales_returns
        WHERE id=(v_row->>'return_id')::UUID;
    ELSIF v_row ? 'product_id' THEN
        SELECT store_id INTO v_store_id FROM products WHERE id=(v_row->>'product_id')::UUID;
    ELSE
        RAISE EXCEPTION 'Cannot resolve store_id for change-log table %',TG_TABLE_NAME;
    END IF;

    IF v_store_id IS NULL THEN
        -- Never allow a DELETE to commit without its own Change Log event.
        -- If ownership cannot be resolved, fail the statement and roll back atomically.
        RAISE EXCEPTION 'Cannot resolve store for change-log row in %',TG_TABLE_NAME;
    END IF;
    v_record_id := (v_row->>'id')::UUID;
    IF TG_OP='INSERT' THEN
        PERFORM log_change(v_store_id,TG_TABLE_NAME,v_record_id,'INSERT',NULL,to_jsonb(NEW)); RETURN NEW;
    ELSIF TG_OP='UPDATE' THEN
        PERFORM log_change(v_store_id,TG_TABLE_NAME,v_record_id,'UPDATE',to_jsonb(OLD),to_jsonb(NEW)); RETURN NEW;
    ELSE
        PERFORM log_change(v_store_id,TG_TABLE_NAME,v_record_id,'DELETE',to_jsonb(OLD),NULL); RETURN OLD;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- تطبيق trigger log_change على الجداول التجارية الرئيسية
CREATE TRIGGER trg_stores_log_change     AFTER INSERT OR UPDATE OR DELETE ON stores          FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_products_log_change   AFTER INSERT OR UPDATE OR DELETE ON products        FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_customers_log_change  AFTER INSERT OR UPDATE OR DELETE ON customers       FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_suppliers_log_change  AFTER INSERT OR UPDATE OR DELETE ON suppliers       FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_purchases_log_change  AFTER INSERT OR UPDATE OR DELETE ON purchases       FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_invoices_log_change   AFTER INSERT OR UPDATE OR DELETE ON invoices        FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_sales_returns_log     AFTER INSERT OR UPDATE OR DELETE ON sales_returns   FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_customer_payments_log AFTER INSERT OR UPDATE OR DELETE ON customer_payments FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_supplier_payments_log AFTER INSERT OR UPDATE OR DELETE ON supplier_payments FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_stock_movements_log   AFTER INSERT OR UPDATE OR DELETE ON stock_movements   FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_categories_log       AFTER INSERT OR UPDATE OR DELETE ON categories       FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_brands_log          AFTER INSERT OR UPDATE OR DELETE ON brands          FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_product_units_log   AFTER INSERT OR UPDATE OR DELETE ON product_units   FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_stock_log           AFTER INSERT OR UPDATE OR DELETE ON stock           FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_purchase_items_log  AFTER INSERT OR UPDATE OR DELETE ON purchase_items  FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_customer_ledgers_log AFTER INSERT OR UPDATE OR DELETE ON customer_ledgers FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_payment_allocations_log AFTER INSERT OR UPDATE OR DELETE ON payment_allocations FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_invoice_items_log   AFTER INSERT OR UPDATE OR DELETE ON invoice_items   FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_supplier_ledger_log AFTER INSERT OR UPDATE OR DELETE ON supplier_ledger FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_return_items_log    AFTER INSERT OR UPDATE OR DELETE ON return_items    FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_expenses_log        AFTER INSERT OR UPDATE OR DELETE ON expenses        FOR EACH ROW EXECUTE FUNCTION trg_log_change();
CREATE TRIGGER trg_revenues_log        AFTER INSERT OR UPDATE OR DELETE ON revenues        FOR EACH ROW EXECUTE FUNCTION trg_log_change();
-- ============================================================
-- Sync Functions — Version 2 (آمنة ونفسية)
-- ============================================================

-- 1. Per-store transactional cursor allocator.
-- Unlike nextval(), the row lock remains held until transaction commit,
-- preventing a committed high cursor from hiding a later-committed low cursor.
CREATE OR REPLACE FUNCTION get_next_change_cursor(p_store_id UUID)
RETURNS BIGINT AS $$
DECLARE
    v_cursor BIGINT;
BEGIN
    INSERT INTO public.store_sync_counters(store_id, last_cursor)
    VALUES (p_store_id, 0)
    ON CONFLICT (store_id) DO NOTHING;

    UPDATE public.store_sync_counters
       SET last_cursor = last_cursor + 1,
           updated_at = NOW()
     WHERE store_id = p_store_id
     RETURNING last_cursor INTO v_cursor;

    IF v_cursor IS NULL THEN
        RAISE EXCEPTION 'Could not allocate sync cursor for store %', p_store_id;
    END IF;
    RETURN v_cursor;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- 3. إدخال entry في change_log (يُستدعى من triggers آلية)
CREATE OR REPLACE FUNCTION log_change(
    p_store_id UUID,
    p_table_name TEXT,
    p_record_uuid UUID,
    p_operation TEXT,
    p_old_values JSONB DEFAULT NULL,
    p_new_values JSONB DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    INSERT INTO change_log (sync_cursor, store_id, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (get_next_change_cursor(p_store_id), p_store_id, p_table_name, p_record_uuid, p_operation, p_old_values, p_new_values);
END;
$$ LANGUAGE plpgsql;

-- 4. Idempotency ذري: prevent duplicate processing باستخدام ON CONFLICT
CREATE OR REPLACE FUNCTION atomic_process_operation(
    p_store_id UUID, p_operation_id UUID, p_operation_type TEXT,
    p_entity_table TEXT, p_entity_uuid UUID, p_payload_hash TEXT
) RETURNS TABLE(success BOOLEAN, conflict BOOLEAN, result_json JSONB) AS $$
DECLARE
    v_hash TEXT;
    v_inserted BOOLEAN := FALSE;
BEGIN
    INSERT INTO processed_operations
        (store_id, operation_id, operation_type, entity_table, entity_uuid, payload_hash)
    VALUES (p_store_id, p_operation_id, p_operation_type, p_entity_table, p_entity_uuid, p_payload_hash)
    ON CONFLICT (store_id, operation_id) DO NOTHING;
    v_inserted := FOUND;

    IF v_inserted THEN
        RETURN QUERY SELECT TRUE, FALSE, jsonb_build_object('new', TRUE);
        RETURN;
    END IF;

    SELECT po.payload_hash INTO v_hash
    FROM processed_operations po
    WHERE po.store_id = p_store_id AND po.operation_id = p_operation_id
    FOR UPDATE;

    RETURN QUERY SELECT (v_hash = p_payload_hash), (v_hash IS DISTINCT FROM p_payload_hash), jsonb_build_object('new', FALSE);
END;
$$ LANGUAGE plpgsql;

-- 5. Duplicated key check (legacy safe wrapper)
CREATE OR REPLACE FUNCTION check_and_mark_processed(
    p_store_id UUID,
    p_operation_id UUID,
    p_operation_type TEXT,
    p_entity_table TEXT,
    p_entity_uuid UUID,
    p_payload_hash TEXT
) RETURNS BOOLEAN AS $$
DECLARE
    v_hash TEXT;
    v_inserted BOOLEAN;
BEGIN
    INSERT INTO processed_operations
        (store_id, operation_id, operation_type, entity_table, entity_uuid, payload_hash)
    VALUES
        (p_store_id, p_operation_id, p_operation_type, p_entity_table, p_entity_uuid, p_payload_hash)
    ON CONFLICT (store_id, operation_id) DO NOTHING;

    v_inserted := FOUND;
    IF v_inserted THEN
        RETURN TRUE;
    END IF;

    SELECT payload_hash INTO v_hash
      FROM processed_operations
     WHERE store_id = p_store_id AND operation_id = p_operation_id
     FOR UPDATE;

    RETURN v_hash = p_payload_hash;
END;
$$ LANGUAGE plpgsql;

-- Function: إنشاء entry في Outbox
CREATE OR REPLACE FUNCTION create_outbox_entry(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_operation TEXT,
    p_record_uuid UUID,
    p_idempotency_key UUID,
    p_record_json JSONB
) RETURNS UUID AS $$
DECLARE
    v_outbox_id UUID;
    v_payload_hash TEXT;
BEGIN
    v_payload_hash := encode(public.atack_digest(convert_to(p_record_json::text,'UTF8'), 'sha256'), 'hex');

    INSERT INTO sync_outbox
        (store_id, device_id, table_name, operation, record_uuid, idempotency_key, record_json, payload_hash)
    VALUES
        (p_store_id, p_device_id, p_table_name, p_operation, p_record_uuid, p_idempotency_key, p_record_json, v_payload_hash)
    RETURNING id INTO v_outbox_id;

    RETURN v_outbox_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- Function: تطبيق عملية تجارية فعّالة من Outbox
-- يدعم INSERT/UPDATE/DELETE مع allowlist، التحقق من ملكية المتجر،
-- وتنفيذ ذري مع تسجيل Idempotency
--============================================================
CREATE OR REPLACE FUNCTION apply_outbox_operation(p_outbox_id UUID)
RETURNS JSONB AS $$
DECLARE
    v_row sync_outbox%ROWTYPE;
    v_allowed_tables CONSTANT TEXT[] := ARRAY[
        'categories','brands','products','product_units','customers','suppliers','purchases','invoices',
        'invoice_items','purchase_items','stock','stock_movements','customer_ledgers','customer_payments',
        'payment_allocations','supplier_ledger','supplier_payments','sales_returns','return_items',
        'expenses','revenues','user_roles'
    ];
    v_store_id UUID;
    v_current_store_id UUID;
    v_parent_id UUID;
    v_parent_table TEXT;
    v_parent_fk TEXT;
    v_cols TEXT;
    v_insert_cols TEXT;
    v_exists BOOLEAN;
    v_affected BIGINT;
    v_idempotency RECORD;
BEGIN
    SELECT * INTO v_row FROM sync_outbox WHERE id = p_outbox_id FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('success',FALSE,'error','Outbox entry not found'); END IF;
    IF auth.uid() IS NULL AND COALESCE(auth.role(), '') <> 'service_role' THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;
    IF auth.uid() IS NOT NULL AND v_row.store_id IS DISTINCT FROM public.current_user_store_id() THEN
        RAISE EXCEPTION 'Outbox entry does not belong to the authenticated store';
    END IF;
    IF COALESCE(auth.role(), '') <> 'service_role' THEN
        IF NOT public.has_store_permission(v_row.store_id, CASE
            WHEN v_row.table_name IN ('categories','brands','products','product_units') THEN 'products.write'
            WHEN v_row.table_name IN ('stock','stock_movements') THEN 'inventory.write'
            WHEN v_row.table_name IN ('invoices','invoice_items') THEN 'sales.write'
            WHEN v_row.table_name IN ('purchases','purchase_items') THEN 'purchases.write'
            WHEN v_row.table_name IN ('customers') THEN 'customers.write'
            WHEN v_row.table_name IN ('customer_payments','customer_ledgers','payment_allocations') THEN 'customers.payments'
            WHEN v_row.table_name IN ('suppliers') THEN 'suppliers.write'
            WHEN v_row.table_name IN ('supplier_payments','supplier_ledger') THEN 'suppliers.payments'
            WHEN v_row.table_name IN ('sales_returns','return_items') THEN 'sales.write'
            WHEN v_row.table_name IN ('expenses','revenues') THEN 'reports.financial'
            WHEN v_row.table_name IN ('user_roles') THEN 'users.manage'
            ELSE 'sync.manage'
        END) THEN
            RAISE EXCEPTION 'Permission denied for outbox table %', v_row.table_name;
        END IF;
    END IF;
    IF v_row.status NOT IN ('PENDING','IN_PROGRESS') THEN
        RETURN jsonb_build_object('success',FALSE,'error','Entry already processed','status',v_row.status);
    END IF;
    IF NOT (v_row.table_name = ANY(v_allowed_tables)) THEN
        RAISE EXCEPTION 'Table % is not allowed for sync', v_row.table_name;
    END IF;
    IF v_row.table_name = ANY(ARRAY[
        'invoices','invoice_items','purchases','purchase_items','stock','stock_movements',
        'customer_ledgers','customer_payments','payment_allocations','supplier_ledger',
        'supplier_payments','sales_returns','return_items','expenses','revenues'
    ]) THEN
        RAISE EXCEPTION 'Table % is transaction-derived; use a dedicated atomic business RPC, not generic row sync', v_row.table_name;
    END IF;
    IF v_row.operation NOT IN ('INSERT','UPDATE','DELETE') THEN
        RAISE EXCEPTION 'Unsupported operation %', v_row.operation;
    END IF;

    -- Resolve store ownership without assuming every child table has store_id.
    CASE v_row.table_name
      WHEN 'product_units' THEN v_parent_table := 'products'; v_parent_fk := 'product_id';
      WHEN 'user_roles' THEN v_parent_table := 'users'; v_parent_fk := 'user_id';
      WHEN 'invoice_items' THEN v_parent_table := 'invoices'; v_parent_fk := 'invoice_id';
      WHEN 'purchase_items' THEN v_parent_table := 'purchases'; v_parent_fk := 'purchase_id';
      WHEN 'stock' THEN v_parent_table := 'products'; v_parent_fk := 'product_id';
      WHEN 'stock_movements' THEN v_parent_table := 'products'; v_parent_fk := 'product_id';
      WHEN 'customer_ledgers' THEN v_parent_table := 'customers'; v_parent_fk := 'customer_id';
      WHEN 'customer_payments' THEN v_parent_table := 'customers'; v_parent_fk := 'customer_id';
      WHEN 'payment_allocations' THEN v_parent_table := 'invoices'; v_parent_fk := 'invoice_id';
      WHEN 'sales_returns' THEN v_parent_table := 'invoices'; v_parent_fk := 'original_invoice_id';
      WHEN 'return_items' THEN v_parent_table := 'sales_returns'; v_parent_fk := 'return_id';
      WHEN 'supplier_ledger' THEN v_parent_table := 'suppliers'; v_parent_fk := 'supplier_id';
      WHEN 'supplier_payments' THEN v_parent_table := 'suppliers'; v_parent_fk := 'supplier_id';
      ELSE v_parent_table := NULL; v_parent_fk := NULL;
    END CASE;

    IF v_row.operation = 'INSERT' THEN
      IF v_parent_table IS NULL THEN
        v_store_id := NULLIF(v_row.record_json->>'store_id','')::UUID;
      ELSE
        EXECUTE format('SELECT store_id FROM %I WHERE id=$1',v_parent_table)
          INTO v_store_id USING NULLIF(v_row.record_json->>v_parent_fk,'')::UUID;
      END IF;
    ELSE
      -- UPDATE/DELETE must first prove that the existing target row belongs to this store.
      IF v_parent_table IS NULL THEN
        EXECUTE format('SELECT store_id FROM %I WHERE id=$1',v_row.table_name)
          INTO v_current_store_id USING v_row.record_uuid;
        v_store_id := v_current_store_id;

        IF v_row.operation = 'UPDATE'
           AND v_row.record_json ? 'store_id'
           AND NULLIF(v_row.record_json->>'store_id','')::UUID IS DISTINCT FROM v_current_store_id THEN
          RAISE EXCEPTION 'An update cannot move a record between stores';
        END IF;
      ELSE
        EXECUTE format(
          'SELECT p.store_id, c.%I FROM %I c JOIN %I p ON p.id=c.%I WHERE c.id=$1',
          v_parent_fk, v_row.table_name, v_parent_table, v_parent_fk
        ) INTO v_current_store_id, v_parent_id USING v_row.record_uuid;
        v_store_id := v_current_store_id;

        IF v_row.operation = 'UPDATE' AND v_row.record_json ? v_parent_fk THEN
          EXECUTE format('SELECT store_id FROM %I WHERE id=$1',v_parent_table)
            INTO v_current_store_id
            USING NULLIF(v_row.record_json->>v_parent_fk,'')::UUID;
          IF v_current_store_id IS DISTINCT FROM v_store_id THEN
            RAISE EXCEPTION 'An update cannot move a child record between stores';
          END IF;
        END IF;
      END IF;
    END IF;

    IF v_store_id IS NULL OR v_store_id <> v_row.store_id THEN
      RAISE EXCEPTION 'Store ownership mismatch or target/parent record missing';
    END IF;

    BEGIN
      SELECT * INTO v_idempotency FROM atomic_process_operation(
        v_row.store_id, v_row.idempotency_key, 'sync_' || lower(v_row.operation),
        v_row.table_name, v_row.record_uuid, v_row.payload_hash);
      IF v_idempotency.conflict THEN RAISE EXCEPTION 'Idempotency key reused with different payload'; END IF;
      IF NOT v_idempotency.success THEN RAISE EXCEPTION 'Could not register idempotency key'; END IF;
      IF COALESCE((v_idempotency.result_json->>'new')::BOOLEAN,FALSE) = FALSE THEN
        UPDATE sync_outbox SET status='SYNCED', synced_at=NOW() WHERE id=p_outbox_id;
        RETURN jsonb_build_object('success',TRUE,'duplicate',TRUE,'outbox_id',p_outbox_id);
      END IF;

      IF v_row.operation = 'INSERT' THEN
        SELECT string_agg(format('%I',a.attname),', ' ORDER BY a.attnum) INTO v_insert_cols
        FROM pg_attribute a
        WHERE a.attrelid=to_regclass(format('%I',v_row.table_name))
          AND a.attnum>0 AND NOT a.attisdropped AND a.attgenerated=''
          AND v_row.record_json ? a.attname;
        IF v_insert_cols IS NULL THEN RAISE EXCEPTION 'No valid fields supplied for insert'; END IF;
        EXECUTE format('INSERT INTO %I (%s) SELECT %s FROM jsonb_populate_record(NULL::%I,$1)',
                       v_row.table_name,v_insert_cols,v_insert_cols,v_row.table_name) USING v_row.record_json;
      ELSIF v_row.operation = 'UPDATE' THEN
        SELECT string_agg(format('%I = r.%I',a.attname,a.attname),', ' ORDER BY a.attnum) INTO v_cols
        FROM pg_attribute a
        WHERE a.attrelid = to_regclass(format('%I',v_row.table_name))
          AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname NOT IN ('id','created_at','store_id') AND a.attgenerated=''
          AND v_row.record_json ? a.attname;
        IF v_cols IS NULL THEN RAISE EXCEPTION 'No permitted fields to update'; END IF;
        EXECUTE format('UPDATE %I AS t SET %s FROM (SELECT (jsonb_populate_record(NULL::%I,$1)).*) AS r WHERE t.id=$2',
                       v_row.table_name,v_cols,v_row.table_name) USING v_row.record_json,v_row.record_uuid;
        GET DIAGNOSTICS v_affected = ROW_COUNT;
        IF v_affected = 0 THEN RAISE EXCEPTION 'Update target not found'; END IF;
      ELSE
        EXECUTE format('DELETE FROM %I WHERE id=$1',v_row.table_name) USING v_row.record_uuid;
        GET DIAGNOSTICS v_affected = ROW_COUNT;
        IF v_affected = 0 THEN RAISE EXCEPTION 'Delete target not found'; END IF;
      END IF;
      UPDATE sync_outbox SET status='SYNCED',synced_at=NOW(),error_message=NULL WHERE id=p_outbox_id;
      RETURN jsonb_build_object('success',TRUE,'outbox_id',p_outbox_id);
    EXCEPTION WHEN OTHERS THEN
      UPDATE sync_outbox SET status='FAILED',error_message=SQLERRM,last_attempt=NOW(),retry_count=retry_count+1
      WHERE id=p_outbox_id;
      RETURN jsonb_build_object('success',FALSE,'error',SQLERRM);
    END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Legacy wrapper for backward compatibility
CREATE OR REPLACE FUNCTION process_outbox_entry(
    p_outbox_id UUID,
    p_status TEXT,
    p_error_message TEXT DEFAULT NULL
) RETURNS BOOLEAN AS $$
DECLARE
    v_row sync_outbox%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM sync_outbox WHERE id = p_outbox_id FOR UPDATE;
    IF v_row IS NULL THEN RETURN FALSE; END IF;

    IF p_status = 'SYNCED' THEN
        UPDATE sync_outbox SET status = p_status, synced_at = NOW() WHERE id = p_outbox_id;
        PERFORM check_and_mark_processed(
            v_row.store_id, v_row.idempotency_key,
            'sync_insert', v_row.table_name, v_row.record_uuid, v_row.payload_hash
        );
    ELSIF p_status IN ('FAILED', 'CONFLICT') THEN
        UPDATE sync_outbox
        SET status = p_status, error_message = p_error_message, last_attempt = NOW(),
            retry_count = retry_count + 1
        WHERE id = p_outbox_id;
    ELSE
        RETURN FALSE;
    END IF;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- Function: جلب records غير متزامنة لجهاز معين
CREATE OR REPLACE FUNCTION get_unsynced_records(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_since_cursor BIGINT DEFAULT 0
) RETURNS TABLE(
    record_uuid UUID,
    operation TEXT,
    record_json JSONB,
    sync_cursor BIGINT,
    changed_at TIMESTAMPTZ
) AS $$
BEGIN
    IF p_since_cursor < 0 THEN
        RAISE EXCEPTION 'p_since_cursor must be non-negative';
    END IF;
    IF auth.uid() IS NOT NULL THEN
        IF p_store_id IS DISTINCT FROM public.current_user_store_id() THEN
            RAISE EXCEPTION 'Store membership required';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM public.devices d
             WHERE d.id::TEXT = p_device_id AND d.store_id = p_store_id
        ) THEN
            RAISE EXCEPTION 'Device is not registered for this store';
        END IF;
    ELSIF COALESCE(auth.role(), '') <> 'service_role' THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    RETURN QUERY
    SELECT cl.record_uuid,
           cl.operation,
           CASE WHEN cl.operation = 'DELETE' THEN cl.old_values_json ELSE cl.new_values_json END,
           cl.sync_cursor,
           cl.created_at
      FROM public.change_log cl
     WHERE cl.store_id = p_store_id
       AND cl.sync_cursor > p_since_cursor
       AND cl.table_name = p_table_name
     ORDER BY cl.sync_cursor ASC
     LIMIT 500;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ACK only after the client has committed the entire Pull page locally.
CREATE OR REPLACE FUNCTION public.acknowledge_sync_cursor(
    p_store_id UUID,
    p_device_id TEXT,
    p_table_name TEXT,
    p_cursor BIGINT
) RETURNS BOOLEAN AS $$
DECLARE
    v_max_cursor BIGINT;
BEGIN
    IF p_cursor < 0 THEN RAISE EXCEPTION 'Cursor must be non-negative'; END IF;
    IF auth.uid() IS NOT NULL THEN
        IF p_store_id IS DISTINCT FROM public.current_user_store_id() THEN
            RAISE EXCEPTION 'Store membership required';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM public.devices d WHERE d.id::TEXT = p_device_id AND d.store_id = p_store_id) THEN
            RAISE EXCEPTION 'Device is not registered for this store';
        END IF;
    ELSIF COALESCE(auth.role(), '') <> 'service_role' THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    SELECT COALESCE(MAX(cl.sync_cursor), 0) INTO v_max_cursor
      FROM public.change_log cl
     WHERE cl.store_id = p_store_id AND cl.table_name = p_table_name;
    IF p_cursor > v_max_cursor THEN
        RAISE EXCEPTION 'Cannot acknowledge a cursor beyond the latest change';
    END IF;
    IF p_cursor > 0 AND NOT EXISTS (
        SELECT 1 FROM public.change_log cl
         WHERE cl.store_id = p_store_id
           AND cl.table_name = p_table_name
           AND cl.sync_cursor = p_cursor
    ) THEN
        RAISE EXCEPTION 'Acknowledged cursor must identify a change for this table';
    END IF;

    INSERT INTO public.sync_cursors(store_id, device_id, table_name, last_pull_seq, cursor_value)
    VALUES (p_store_id, p_device_id, p_table_name, p_cursor, p_cursor::TEXT)
    ON CONFLICT (store_id, device_id, table_name)
    DO UPDATE SET last_pull_seq = GREATEST(sync_cursors.last_pull_seq, EXCLUDED.last_pull_seq),
                  cursor_value = GREATEST(sync_cursors.last_pull_seq, EXCLUDED.last_pull_seq)::TEXT,
                  updated_at = NOW();
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Function: حل تعارض مزامنة (قبول local/remote أو merge فعلي)
-- عند اختيار MERGE يستخدم p_merged_json إن وُجد، وإلا يستخدم record من جدول المتجر
CREATE OR REPLACE FUNCTION resolve_sync_conflict(
    p_conflict_id UUID, p_resolution TEXT, p_resolved_by UUID, p_merged_json JSONB DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_conflict sync_conflicts%ROWTYPE;
    v_final JSONB;
    v_cols TEXT;
    v_affected BIGINT;
    v_target_store_id UUID;
    v_parent_table TEXT;
    v_parent_fk TEXT;
BEGIN
    SELECT * INTO v_conflict FROM sync_conflicts WHERE id=p_conflict_id FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('success',FALSE,'error','Conflict not found'); END IF;
    IF auth.uid() IS NULL OR v_conflict.store_id IS DISTINCT FROM public.current_user_store_id() THEN
        RAISE EXCEPTION 'Authenticated store membership required';
    END IF;
    IF NOT public.has_store_permission(v_conflict.store_id, 'sync.manage') THEN
        RAISE EXCEPTION 'sync.manage permission required to resolve conflicts';
    END IF;
    IF v_conflict.table_name IN ('invoices','invoice_items','purchases','purchase_items','stock','stock_movements',
                                 'customer_ledgers','supplier_ledger','customer_payments','supplier_payments',
                                 'payment_allocations','sales_returns','return_items','expenses','revenues') THEN
        RAISE EXCEPTION 'Financial and inventory records are event-derived and cannot be resolved by generic row overwrite';
    END IF;
    IF p_resolved_by IS DISTINCT FROM (
        SELECT u.id FROM public.users u
         WHERE u.auth_user_id = auth.uid() AND u.store_id = v_conflict.store_id AND u.is_active = TRUE
         LIMIT 1
    ) THEN
        RAISE EXCEPTION 'Resolved-by user does not match authenticated user';
    END IF;
    IF v_conflict.resolution_status IS NOT NULL AND v_conflict.resolution_status <> 'PENDING' THEN
        RETURN jsonb_build_object('success',FALSE,'error','Conflict already resolved');
    END IF;
    IF p_resolution NOT IN ('ACCEPT_LOCAL','ACCEPT_REMOTE','MERGE') THEN
        RETURN jsonb_build_object('success',FALSE,'error','Invalid resolution type');
    END IF;
    IF v_conflict.table_name NOT IN ('categories','brands','products','product_units','customers','suppliers',
       'purchases','invoices','expenses','revenues','stock','stock_movements','invoice_items','purchase_items',
       'customer_payments','customer_ledgers','supplier_payments','supplier_ledger','sales_returns','return_items',
       'user_roles') THEN
        RAISE EXCEPTION 'Table % is not allowed for conflict resolution',v_conflict.table_name;
    END IF;
    -- Resolve the target row's actual store; never trust store_id from conflict JSON.
    CASE v_conflict.table_name
      WHEN 'product_units' THEN v_parent_table := 'products'; v_parent_fk := 'product_id';
      WHEN 'user_roles' THEN v_parent_table := 'users'; v_parent_fk := 'user_id';
      WHEN 'invoice_items' THEN v_parent_table := 'invoices'; v_parent_fk := 'invoice_id';
      WHEN 'purchase_items' THEN v_parent_table := 'purchases'; v_parent_fk := 'purchase_id';
      WHEN 'stock' THEN v_parent_table := 'products'; v_parent_fk := 'product_id';
      WHEN 'stock_movements' THEN v_parent_table := 'products'; v_parent_fk := 'product_id';
      WHEN 'customer_payments' THEN v_parent_table := 'customers'; v_parent_fk := 'customer_id';
      WHEN 'customer_ledgers' THEN v_parent_table := 'customers'; v_parent_fk := 'customer_id';
      WHEN 'payment_allocations' THEN v_parent_table := 'invoices'; v_parent_fk := 'invoice_id';
      WHEN 'supplier_payments' THEN v_parent_table := 'suppliers'; v_parent_fk := 'supplier_id';
      WHEN 'supplier_ledger' THEN v_parent_table := 'suppliers'; v_parent_fk := 'supplier_id';
      WHEN 'sales_returns' THEN v_parent_table := 'invoices'; v_parent_fk := 'original_invoice_id';
      WHEN 'return_items' THEN v_parent_table := 'sales_returns'; v_parent_fk := 'return_id';
      ELSE v_parent_table := NULL; v_parent_fk := NULL;
    END CASE;

    IF v_parent_table IS NULL THEN
        EXECUTE format('SELECT store_id FROM %I WHERE id=$1',v_conflict.table_name)
          INTO v_target_store_id USING v_conflict.record_uuid;
    ELSE
        EXECUTE format(
          'SELECT p.store_id FROM %I c JOIN %I p ON p.id=c.%I WHERE c.id=$1',
          v_conflict.table_name, v_parent_table, v_parent_fk
        ) INTO v_target_store_id USING v_conflict.record_uuid;
    END IF;
    IF v_target_store_id IS NULL OR v_target_store_id IS DISTINCT FROM v_conflict.store_id THEN
        RAISE EXCEPTION 'Conflict target does not belong to the authenticated store';
    END IF;

    v_final := CASE p_resolution WHEN 'ACCEPT_LOCAL' THEN v_conflict.local_record_json
                 WHEN 'ACCEPT_REMOTE' THEN v_conflict.remote_record_json ELSE COALESCE(p_merged_json, v_conflict.local_record_json) END;
    IF v_final IS NULL OR jsonb_typeof(v_final) <> 'object' THEN
        RETURN jsonb_build_object('success',FALSE,'error','Resolution payload must be a JSON object');
    END IF;
    SELECT string_agg(format('%I = r.%I',a.attname,a.attname),', ' ORDER BY a.attnum) INTO v_cols
    FROM pg_attribute a WHERE a.attrelid=to_regclass(format('%I',v_conflict.table_name))
      AND a.attnum>0 AND NOT a.attisdropped AND a.attname NOT IN ('id','created_at','store_id') AND a.attgenerated=''
      AND v_final ? a.attname;
    IF v_cols IS NULL THEN RETURN jsonb_build_object('success',FALSE,'error','No permitted fields in resolution payload'); END IF;
    EXECUTE format('UPDATE %I AS t SET %s FROM (SELECT (jsonb_populate_record(NULL::%I,$1)).*) AS r WHERE t.id=$2',
                   v_conflict.table_name,v_cols,v_conflict.table_name) USING v_final,v_conflict.record_uuid;
    GET DIAGNOSTICS v_affected = ROW_COUNT;
    IF v_affected = 0 THEN RAISE EXCEPTION 'Conflict target record not found'; END IF;
    UPDATE sync_conflicts SET resolution_status=p_resolution,resolved_by=p_resolved_by,
      resolved_at=NOW(),resolution_notes=p_resolution || ' applied' WHERE id=p_conflict_id;
    RETURN jsonb_build_object('success',TRUE,'action',p_resolution);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Function: تسجيل tombstone عند الحذف الناعم
CREATE OR REPLACE FUNCTION soft_delete_record(
    p_table_name TEXT,
    p_record_uuid UUID,
    p_store_id UUID,
    p_deleted_by UUID
) RETURNS VOID AS $$
BEGIN
    INSERT INTO tombstones (store_id, table_name, record_uuid, deleted_by)
    VALUES (p_store_id, p_table_name, p_record_uuid, p_deleted_by);
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- RLS Configuration Note
-- ============================================================
-- RLS يعتمد على هوية Supabase Auth (auth.uid())، ولا يثق في GUC يرسله العميل.

-- ============================================================
-- RLS: تمكين على الجداول التي تحمل store_id مباشرة أو عبر FK
-- ============================================================
ALTER TABLE invoices              ENABLE ROW LEVEL SECURITY;
ALTER TABLE products              ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers             ENABLE ROW LEVEL SECURITY;
ALTER TABLE suppliers             ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchases             ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_items        ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoice_items         ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_movements       ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_payments     ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_ledgers      ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales_returns         ENABLE ROW LEVEL SECURITY;
ALTER TABLE return_items          ENABLE ROW LEVEL SECURITY;
ALTER TABLE expenses              ENABLE ROW LEVEL SECURITY;
ALTER TABLE revenues              ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplier_payments     ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplier_ledger       ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_allocations   ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_outbox           ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_conflicts        ENABLE ROW LEVEL SECURITY;
ALTER TABLE tombstones            ENABLE ROW LEVEL SECURITY;

-- RLS على users و audit_logs — عزل حسب user.store_id مباشرة
ALTER TABLE stores                ENABLE ROW LEVEL SECURITY;
ALTER TABLE users                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs            ENABLE ROW LEVEL SECURITY;
ALTER TABLE change_log            ENABLE ROW LEVEL SECURITY;
ALTER TABLE processed_operations  ENABLE ROW LEVEL SECURITY;
ALTER TABLE devices                ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories             ENABLE ROW LEVEL SECURITY;
ALTER TABLE brands                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_cursors           ENABLE ROW LEVEL SECURITY;
ALTER TABLE store_sync_counters    ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_log               ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_units          ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_roles             ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- Helper: استخراج store_id من جلسة التطبيق (غير قابل للتزوير من العميل)
-- يربط users.auth_user_id بهوية Supabase Auth عبر auth.uid()
-- ============================================================
CREATE OR REPLACE FUNCTION current_user_store_id()
RETURNS UUID AS $$
    SELECT u.store_id FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.is_active = TRUE LIMIT 1;
$$ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public, pg_temp;

-- ============================================================
-- Generic policy factory — يولد 4 سياسات لجدول يحمل store_id مباشرة
-- ============================================================
CREATE OR REPLACE FUNCTION make_store_policies(
    p_table TEXT,
    p_store_col TEXT DEFAULT 'store_id'
) RETURNS VOID AS $$
DECLARE
    v_policy TEXT;
BEGIN
    -- SELECT
    v_policy := 'store_isolation_select_' || p_table;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = p_table AND policyname = v_policy) THEN
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR SELECT USING (%I = public.current_user_store_id())',
            v_policy, p_table, p_store_col
        );
    END IF;

    -- INSERT
    v_policy := 'store_isolation_insert_' || p_table;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = p_table AND policyname = v_policy) THEN
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR INSERT WITH CHECK (%I = public.current_user_store_id())',
            v_policy, p_table, p_store_col
        );
    END IF;

    -- UPDATE
    v_policy := 'store_isolation_update_' || p_table;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = p_table AND policyname = v_policy) THEN
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR UPDATE USING (%I = public.current_user_store_id()) WITH CHECK (%I = public.current_user_store_id())',
            v_policy, p_table, p_store_col, p_store_col
        );
    END IF;

    -- DELETE
    v_policy := 'store_isolation_delete_' || p_table;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = p_table AND policyname = v_policy) THEN
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR DELETE USING (%I = public.current_user_store_id())',
            v_policy, p_table, p_store_col
        );
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- Helper: سياسات للجداول التابعة (بدون store_id المباشر)
-- تستخدم subquery للانضمام للجدول الأب
-- ============================================================
CREATE OR REPLACE FUNCTION make_dependent_policies(
    p_table TEXT,
    p_parent_table TEXT,
    p_fk_col TEXT,
    p_parent_store_col TEXT DEFAULT 'store_id'
) RETURNS VOID AS $$
DECLARE
    v_policy TEXT;
    v_using TEXT;
BEGIN
    v_using := format('EXISTS (SELECT 1 FROM %I p WHERE p.id = %I.%I AND p.%I = public.current_user_store_id())',
                      p_parent_table, p_table, p_fk_col, p_parent_store_col);

    -- SELECT
    v_policy := 'store_isolation_select_' || p_table;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = p_table AND policyname = v_policy) THEN
        EXECUTE format('CREATE POLICY %I ON %I FOR SELECT USING (%s)', v_policy, p_table, v_using);
    END IF;

    -- INSERT
    v_policy := 'store_isolation_insert_' || p_table;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = p_table AND policyname = v_policy) THEN
        EXECUTE format('CREATE POLICY %I ON %I FOR INSERT WITH CHECK (%s)', v_policy, p_table, v_using);
    END IF;

    -- UPDATE
    v_policy := 'store_isolation_update_' || p_table;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = p_table AND policyname = v_policy) THEN
        EXECUTE format('CREATE POLICY %I ON %I FOR UPDATE USING (%s)', v_policy, p_table, v_using);
    END IF;

    -- DELETE
    v_policy := 'store_isolation_delete_' || p_table;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = p_table AND policyname = v_policy) THEN
        EXECUTE format('CREATE POLICY %I ON %I FOR DELETE USING (%s)', v_policy, p_table, v_using);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- تطبيق السياسات على الجداول التي تحمل store_id مباشرة
-- ============================================================
SELECT make_store_policies('invoices');
SELECT make_store_policies('products');
SELECT make_store_policies('customers');
SELECT make_store_policies('suppliers');
SELECT make_store_policies('purchases');
SELECT make_store_policies('expenses');
SELECT make_store_policies('revenues');
SELECT make_store_policies('sync_outbox');
SELECT make_store_policies('sync_conflicts');
SELECT make_store_policies('tombstones');
SELECT make_store_policies('devices');
SELECT make_store_policies('categories');
SELECT make_store_policies('brands');
SELECT make_store_policies('change_log');
SELECT make_store_policies('sync_cursors');
SELECT make_store_policies('store_sync_counters');
SELECT make_store_policies('sync_log');
SELECT make_store_policies('audit_logs');
SELECT make_store_policies('processed_operations');

-- ============================================================
-- سياسات للجداول التابعة (store_id عبر FK للجدول الأب)
-- ============================================================
SELECT make_dependent_policies('purchase_items', 'purchases', 'purchase_id');
SELECT make_dependent_policies('invoice_items', 'invoices', 'invoice_id');
SELECT make_dependent_policies('stock', 'products', 'product_id');
SELECT make_dependent_policies('stock_movements', 'products', 'product_id');
SELECT make_dependent_policies('customer_ledgers', 'customers', 'customer_id');
SELECT make_dependent_policies('customer_payments', 'customers', 'customer_id');
SELECT make_dependent_policies('payment_allocations', 'invoices', 'invoice_id');
SELECT make_dependent_policies('sales_returns', 'invoices', 'original_invoice_id');
SELECT make_dependent_policies('return_items', 'sales_returns', 'return_id');
SELECT make_dependent_policies('supplier_payments', 'suppliers', 'supplier_id');
SELECT make_dependent_policies('supplier_ledger', 'suppliers', 'supplier_id');
SELECT make_dependent_policies('product_units', 'products', 'product_id');
SELECT make_dependent_policies('user_roles', 'users', 'user_id');

-- stores has id instead of store_id; expose only the authenticated user's store.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='stores' AND policyname='store_self_access') THEN
        CREATE POLICY store_self_access ON stores FOR ALL
          USING (id = public.current_user_store_id())
          WITH CHECK (id = public.current_user_store_id());
    END IF;
END $$;

-- ============================================================
-- جدول users: عزل حسب store_id الخاص بالمستخدم
-- ============================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'users' AND policyname = 'store_isolation_select') THEN
        CREATE POLICY store_isolation_select ON users
            FOR SELECT USING (store_id = public.current_user_store_id());
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'users' AND policyname = 'store_isolation_insert') THEN
        CREATE POLICY store_isolation_insert ON users
            FOR INSERT WITH CHECK (store_id = public.current_user_store_id());
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'users' AND policyname = 'store_isolation_update') THEN
        CREATE POLICY store_isolation_update ON users
            FOR UPDATE USING (store_id = public.current_user_store_id()) WITH CHECK (store_id = public.current_user_store_id());
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'users' AND policyname = 'store_isolation_delete') THEN
        CREATE POLICY store_isolation_delete ON users
            FOR DELETE USING (store_id = public.current_user_store_id());
    END IF;
END $$;

-- Resolve authorization from Supabase Auth identity + store membership + RBAC.
-- This function never trusts a client-provided user_id or store_id by itself.
CREATE OR REPLACE FUNCTION public.has_store_permission(
    p_store_id UUID,
    p_permission_code TEXT
) RETURNS BOOLEAN AS $$
    SELECT auth.uid() IS NOT NULL AND EXISTS (
        SELECT 1
          FROM public.users u
          JOIN public.user_roles ur ON ur.user_id = u.id
          JOIN public.role_permissions rp ON rp.role_id = ur.role_id
          JOIN public.permissions p ON p.id = rp.permission_id
         WHERE u.auth_user_id = auth.uid()
           AND u.store_id = p_store_id
           AND u.is_active = TRUE
           AND p.code = p_permission_code
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- RBAC write restrictions. The earlier store policies are permissive; these
-- RESTRICTIVE policies AND the role check with store isolation.
DO $$
DECLARE
    r RECORD;
    v_expr TEXT;
BEGIN
    FOR r IN SELECT * FROM (VALUES
        ('categories', 'public.has_store_permission(store_id, ''products.write'')'),
        ('brands', 'public.has_store_permission(store_id, ''products.write'')'),
        ('products', 'public.has_store_permission(store_id, ''products.write'')'),
        ('product_units', 'EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_units.product_id AND public.has_store_permission(p.store_id, ''products.write''))'),
        ('customers', 'public.has_store_permission(store_id, ''customers.write'')'),
        ('suppliers', 'public.has_store_permission(store_id, ''suppliers.write'')'),
        ('purchases', 'public.has_store_permission(store_id, ''purchases.write'')'),
        ('expenses', 'public.has_store_permission(store_id, ''reports.financial'')'),
        ('revenues', 'public.has_store_permission(store_id, ''reports.financial'')'),
        ('devices', 'public.has_store_permission(store_id, ''sync.manage'')'),
        ('users', 'public.has_store_permission(store_id, ''users.manage'')'),
        ('user_roles', 'public.has_store_permission(public.current_user_store_id(), ''users.manage'')'),
        ('stores', 'public.has_store_permission(id, ''settings.write'')')
    ) AS x(table_name, permission_expr)
    LOOP
        v_expr := r.permission_expr;
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'rbac_insert_' || r.table_name, r.table_name);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'rbac_update_' || r.table_name, r.table_name);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'rbac_delete_' || r.table_name, r.table_name);
        EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (%s)', 'rbac_insert_' || r.table_name, r.table_name, v_expr);
        EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR UPDATE TO authenticated USING (%s) WITH CHECK (%s)', 'rbac_update_' || r.table_name, r.table_name, v_expr, v_expr);
        EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR DELETE TO authenticated USING (%s)', 'rbac_delete_' || r.table_name, r.table_name, v_expr);
    END LOOP;
END $$;

-- Transactional and derived tables are read-only to authenticated REST clients.
-- Only SECURITY DEFINER business RPCs / trusted server jobs may write them.
DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'invoices','invoice_items','purchases','purchase_items','stock','stock_movements',
        'customer_ledgers','customer_payments','payment_allocations','supplier_ledger',
        'supplier_payments','sales_returns','return_items','expenses','revenues',
        'change_log','processed_operations','sync_outbox','sync_conflicts','tombstones',
        'sync_log','sync_cursors','audit_logs','store_sync_counters'
    ] LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'deny_direct_insert_' || t, t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'deny_direct_update_' || t, t);
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'deny_direct_delete_' || t, t);
        EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false)', 'deny_direct_insert_' || t, t);
        EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false)', 'deny_direct_update_' || t, t);
        EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR DELETE TO authenticated USING (false)', 'deny_direct_delete_' || t, t);
    END LOOP;
END $$;

-- Global lookup / RBAC definition tables are readable but not writable by app users.
ALTER TABLE locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE units ENABLE ROW LEVEL SECURITY;
ALTER TABLE roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_permissions ENABLE ROW LEVEL SECURITY;
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['locations','units','roles','permissions','role_permissions'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'authenticated_read_' || t, t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)', 'authenticated_read_' || t, t);
        EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON public.%I FROM anon, authenticated', t);
        EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    END LOOP;
END $$;

-- ============================================================
-- Secure first-store provisioning for a newly authenticated Supabase user.
-- Passwords remain exclusively in Supabase Auth; this function creates the
-- initial store and application user in one transaction.
-- ============================================================
CREATE OR REPLACE FUNCTION create_store_for_authenticated_user(
    p_store_name TEXT,
    p_full_name TEXT,
    p_username TEXT,
    p_email TEXT DEFAULT NULL,
    p_phone TEXT DEFAULT NULL
) RETURNS TABLE(store_id UUID, app_user_id UUID) AS $$
DECLARE
    v_auth_uid UUID;
    v_store_id UUID;
    v_app_user_id UUID;
BEGIN
    v_auth_uid := auth.uid();
    IF v_auth_uid IS NULL THEN
        RAISE EXCEPTION 'A Supabase-authenticated user is required';
    END IF;
    IF NULLIF(btrim(p_store_name), '') IS NULL
       OR NULLIF(btrim(p_full_name), '') IS NULL
       OR NULLIF(btrim(p_username), '') IS NULL THEN
        RAISE EXCEPTION 'Store name, full name and username are required';
    END IF;
    IF EXISTS (SELECT 1 FROM public.users WHERE auth_user_id = v_auth_uid) THEN
        RAISE EXCEPTION 'This Auth user already belongs to a store';
    END IF;

    INSERT INTO public.stores(name)
    VALUES (btrim(p_store_name))
    RETURNING id INTO v_store_id;

    INSERT INTO public.users(
        auth_user_id, store_id, username, password_hash,
        full_name, email, phone, is_active
    )
    VALUES (
        v_auth_uid, v_store_id, btrim(p_username), NULL,
        btrim(p_full_name), NULLIF(btrim(p_email), ''), NULLIF(btrim(p_phone), ''), TRUE
    )
    RETURNING id INTO v_app_user_id;

    INSERT INTO public.user_roles(user_id, role_id, granted_by)
    VALUES (v_app_user_id, 'owner', v_app_user_id);

    RETURN QUERY SELECT v_store_id, v_app_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- audit_logs & change_log: يعتمد على store_id مباشرة
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'audit_logs' AND policyname = 'store_isolation_all') THEN
        CREATE POLICY store_isolation_all ON audit_logs
            FOR ALL USING (store_id = public.current_user_store_id());
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'change_log' AND policyname = 'store_isolation_all') THEN
        CREATE POLICY store_isolation_all ON change_log
            FOR ALL USING (store_id = public.current_user_store_id());
    END IF;
END $$;

-- ============================================================
-- Idempotency Check Function (للاستخدام من التطبيق)
-- ============================================================
CREATE OR REPLACE FUNCTION check_idempotency_and_process(
    p_store_id UUID,
    p_operation_id UUID,
    p_operation_type TEXT,
    p_entity_table TEXT,
    p_entity_uuid UUID,
    p_record_json JSONB
) RETURNS TABLE(
    success BOOLEAN,
    error_message TEXT,
    conflict BOOLEAN
) AS $$
DECLARE
    v_payload_hash TEXT;
    v_result RECORD;
BEGIN
    IF p_record_json IS NULL OR jsonb_typeof(p_record_json) <> 'object' THEN
        RETURN QUERY SELECT FALSE, 'Payload must be a JSON object'::TEXT, FALSE;
        RETURN;
    END IF;

    v_payload_hash := encode(public.atack_digest(convert_to(p_record_json::text,'UTF8'), 'sha256'), 'hex');

    SELECT * INTO v_result
      FROM atomic_process_operation(
          p_store_id, p_operation_id, p_operation_type,
          p_entity_table, p_entity_uuid, v_payload_hash
      );

    IF v_result.conflict THEN
        RETURN QUERY SELECT FALSE, 'Idempotency key conflict: same ID, different payload'::TEXT, TRUE;
    ELSIF NOT v_result.success THEN
        RETURN QUERY SELECT FALSE, 'Could not register operation'::TEXT, FALSE;
    ELSE
        RETURN QUERY SELECT TRUE, NULL::TEXT, FALSE;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- Foreign Keys Summary (للتوثيق)
-- ============================================================

/*
Foreign Keys Summary:
-------------------------
devices -> stores (store_id) ON DELETE CASCADE
users -> stores (store_id) ON DELETE CASCADE
categories -> stores (store_id) ON DELETE CASCADE
categories -> categories (parent_id) ON DELETE SET NULL
brands -> stores (store_id) ON DELETE CASCADE
products -> stores (store_id) ON DELETE CASCADE
products -> categories (category_id) ON DELETE SET NULL
products -> brands (brand_id) ON DELETE SET NULL
products -> units (primary_unit_id) ON DELETE RESTRICT
product_units -> products (product_id) ON DELETE CASCADE
product_units -> units (unit_id) ON DELETE RESTRICT
stock -> products (product_id) ON DELETE CASCADE
stock -> locations (location_id) ON DELETE RESTRICT
stock_movements -> products (product_id) ON DELETE CASCADE
stock_movements -> units (unit_id) ON DELETE RESTRICT
stock_movements -> users (user_id) ON DELETE RESTRICT
invoices -> stores (store_id) ON DELETE CASCADE
invoices -> customers (customer_id) ON DELETE SET NULL
invoices -> suppliers (supplier_id) ON DELETE SET NULL
invoices -> users (created_by) ON DELETE RESTRICT
invoice_items -> invoices (invoice_id) ON DELETE CASCADE
invoice_items -> products (product_id) ON DELETE RESTRICT
invoice_items -> units (quantity_unit_id) ON DELETE RESTRICT
customers -> stores (store_id) ON DELETE CASCADE
customer_ledgers -> customers (customer_id) ON DELETE CASCADE
customer_ledgers -> users (created_by) ON DELETE RESTRICT
customer_payments -> customers (customer_id) ON DELETE CASCADE
customer_payments -> users (created_by) ON DELETE RESTRICT
payment_allocations -> customer_payments (payment_id) ON DELETE CASCADE
payment_allocations -> invoices (invoice_id) ON DELETE CASCADE
suppliers -> stores (store_id) ON DELETE CASCADE
purchases -> stores (store_id) ON DELETE CASCADE
purchases -> suppliers (supplier_id) ON DELETE CASCADE
purchases -> users (created_by) ON DELETE RESTRICT
purchase_items -> purchases (purchase_id) ON DELETE CASCADE
purchase_items -> products (product_id) ON DELETE RESTRICT
purchase_items -> units (quantity_unit_id) ON DELETE RESTRICT
stock -> products (product_id) ON DELETE CASCADE
stock_movements -> products (product_id) ON DELETE CASCADE
stock_movements -> locations (location_id) ON DELETE RESTRICT
stock_movements -> units (unit_id) ON DELETE RESTRICT
stock_movements -> users (user_id) ON DELETE RESTRICT
sales_returns -> stores (store_id) ON DELETE CASCADE
sales_returns -> invoices (original_invoice_id) ON DELETE RESTRICT
sales_returns -> users (created_by) ON DELETE RESTRICT
return_items -> sales_returns (return_id) ON DELETE CASCADE
return_items -> products (product_id) ON DELETE RESTRICT
expenses -> stores (store_id) ON DELETE CASCADE
expenses -> users (created_by) ON DELETE RESTRICT
revenues -> stores (store_id) ON DELETE CASCADE
revenues -> users (created_by) ON DELETE RESTRICT
sync_outbox -> stores (store_id) ON DELETE CASCADE
sync_cursors -> stores (store_id) ON DELETE CASCADE
tombstones -> stores (store_id) ON DELETE CASCADE
tombstones -> users (deleted_by) ON DELETE RESTRICT
sync_log -> stores (store_id) ON DELETE CASCADE
audit_logs -> stores (store_id) ON DELETE CASCADE
audit_logs -> users (user_id) ON DELETE RESTRICT
*/

-- ============================================================
-- Seed Data (البيانات الأولية) — تُنفذ مرة واحدة بعد إنشاء المخطط
-- ============================================================

-- Units (الوحدات)
INSERT INTO units (id, name, symbol, is_active) VALUES
('pcs',  'قطعة',  'قطعة',  TRUE),
('g',    'جرام',  'جم',    TRUE),
('kg',   'كيلو',  'كجم',   TRUE),
('liter','لتر',   'لتر',   TRUE),
('box',  'صندوق', 'صندوق', TRUE),
('carton','كرتونة','كرتونة',TRUE)
ON CONFLICT (id) DO NOTHING;

-- Locations (المواقع)
INSERT INTO locations (id, name, is_default) VALUES
('main',      'المتجر الرئيسي',     TRUE),
('warehouse', 'المستودع',          FALSE),
('storage',   'مخزن إضافي',        FALSE)
ON CONFLICT (id) DO NOTHING;

-- Roles (الأدوار)
INSERT INTO roles (id, name, description, is_active) VALUES
('owner',   'المالك', 'صلاحيات كاملة للمالك / Super Admin', TRUE),
('cashier', 'بائع',   'المفتاح التقني المعتمد لحساب البائع', TRUE)
ON CONFLICT (id) DO NOTHING;

-- Permissions (الصلاحيات الأساسية)
INSERT INTO permissions (code, description) VALUES
('stores.read',       'عرض المتاجر'),
('stores.write',      'تعديل المتاجر'),
('products.read',     'عرض المنتجات'),
('products.write',    'إضافة/تعديل المنتجات'),
('products.delete',   'حذف المنتجات'),
('inventory.read',    'عرض المخزون'),
('inventory.write',   'تعديل المخزون'),
('sales.read',        'عرض المبيعات'),
('sales.write',       'إنشاء فواتير مبيعات'),
('sales.void',        'إلغاء فواتير مبيعات'),
('purchases.read',    'عرض المشتريات'),
('purchases.write',   'إنشاء فواتير مشتريات'),
('purchases.receive', 'استلام مشتريات'),
('customers.read',    'عرض العملاء'),
('customers.write',   'إضافة/تعديل العملاء'),
('customers.payments','استلام مدفوعات العملاء'),
('suppliers.read',    'عرض الموردين'),
('suppliers.write',   'إضافة/تعديل الموردين'),
('suppliers.payments','سداد الموردين'),
('reports.financial', 'تقارير مالية'),
('reports.inventory', 'تقارير مخزون'),
('settings.read',     'عرض الإعدادات'),
('settings.write',    'تعديل الإعدادات'),
('users.manage',      'إدارة المستخدمين والأدوار'),
('sync.manage',       'إدارة المزامنة')
ON CONFLICT (code) DO NOTHING;

-- ربط الأدوار بالصلاحيات (مبدئي - يُعدل لاحقاً حسب الحاجة)
-- Owner: كل شيء
INSERT INTO role_permissions (role_id, permission_id)
SELECT 'owner', id FROM permissions
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Cashier: المبيعات والعملاء
INSERT INTO role_permissions (role_id, permission_id)
SELECT 'cashier', id FROM permissions
WHERE code IN ('products.read', 'inventory.read', 'sales.read', 'sales.write', 'sales.void',
               'customers.read', 'customers.write', 'customers.payments', 'reports.inventory')
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- ============================================================
-- Foreign Keys Summary (محدث)
-- ============================================================
/*
Foreign Keys Summary (مطابق لتعريفات CREATE TABLE):
---------------------------------------------------
CASCADE:
- devices.store_id -> stores.id
- users.store_id -> stores.id
- categories.store_id -> stores.id
- brands.store_id -> stores.id
- products.store_id -> stores.id
- customers.store_id -> stores.id
- suppliers.store_id -> stores.id
- stock.product_id -> products.id
- product_units.product_id -> products.id
- user_roles.user_id -> users.id
- purchase_items.purchase_id -> purchases.id
- purchase_items.product_id -> products.id
- invoice_items.invoice_id -> invoices.id
- payment_allocations.payment_id -> customer_payments.id
- payment_allocations.invoice_id -> invoices.id
- supplier_ledger.supplier_id -> suppliers.id
- supplier_payments.supplier_id -> suppliers.id
- return_items.return_id -> sales_returns.id

RESTRICT:
- purchase_items.quantity_unit_id -> units.id

NO ACTION (PostgreSQL default; deletion is blocked while referenced):
- categories.parent_id -> categories.id
- products.category_id -> categories.id
- products.brand_id -> brands.id
- products.primary_unit_id -> units.id
- stock.location_id -> locations.id
- stock_movements.product_id -> products.id
- stock_movements.unit_id -> units.id
- stock_movements.user_id -> users.id
- customer_ledgers.customer_id -> customers.id
- customer_ledgers.created_by -> users.id
- customer_payments.customer_id -> customers.id
- customer_payments.created_by -> users.id
- supplier_ledger.created_by -> users.id
- supplier_payments.created_by -> users.id
- purchases.store_id -> stores.id
- purchases.supplier_id -> suppliers.id
- purchases.created_by -> users.id
- invoices.store_id -> stores.id
- invoices.customer_id -> customers.id
- invoices.supplier_id -> suppliers.id
- invoices.created_by -> users.id
- invoice_items.product_id -> products.id
- invoice_items.quantity_unit_id -> units.id
- sales_returns.store_id -> stores.id
- sales_returns.original_invoice_id -> invoices.id
- sales_returns.created_by -> users.id
- return_items.product_id -> products.id
- expenses.store_id -> stores.id
- expenses.created_by -> users.id
- revenues.store_id -> stores.id
- revenues.created_by -> users.id
- sync_outbox.store_id -> stores.id
- sync_cursors.store_id -> stores.id
- sync_conflicts.store_id -> stores.id
- sync_conflicts.resolved_by -> users.id
- tombstones.store_id -> stores.id
- tombstones.deleted_by -> users.id
- sync_log.store_id -> stores.id
- audit_logs.store_id -> stores.id
- audit_logs.user_id -> users.id
- product_units.unit_id -> units.id
- user_roles.role_id -> roles.id
- user_roles.granted_by -> users.id
- role_permissions.role_id -> roles.id
- role_permissions.permission_id -> permissions.id

Note: NO ACTION is the actual behavior where no ON DELETE clause appears.
*/

-- ============================================================
-- انتهاء المخطط
-- ============================================================


-- ============================================================
-- Function privilege hardening (Supabase)
-- SECURITY DEFINER functions must not remain executable by PUBLIC/anon.
-- ============================================================
REVOKE ALL ON FUNCTION public.current_user_store_id() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.make_store_policies(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.make_dependent_policies(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_next_change_cursor(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.acknowledge_sync_cursor(UUID, TEXT, TEXT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.has_store_permission(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_change(UUID, TEXT, UUID, TEXT, JSONB, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_log_change() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.validate_same_store_references() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.apply_outbox_operation(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resolve_sync_conflict(UUID, TEXT, UUID, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_store_for_authenticated_user(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;

-- Authenticated users may resolve only their own store's conflicts and provision one store.
GRANT EXECUTE ON FUNCTION public.current_user_store_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_store_permission(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_sync_conflict(UUID, TEXT, UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_store_for_authenticated_user(TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_unsynced_records(UUID, TEXT, TEXT, BIGINT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.acknowledge_sync_cursor(UUID, TEXT, TEXT, BIGINT) TO authenticated, service_role;

-- Outbox processing is available to authenticated members (function checks store ownership)
-- and to trusted server-side service-role workers.
GRANT EXECUTE ON FUNCTION public.apply_outbox_operation(UUID) TO authenticated, service_role;

-- Helpers are migration-time only; keep them unavailable to application roles.
REVOKE ALL ON FUNCTION public.atomic_process_operation(UUID, UUID, TEXT, TEXT, UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.check_and_mark_processed(UUID, UUID, TEXT, TEXT, UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.check_idempotency_and_process(UUID, UUID, TEXT, TEXT, UUID, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_outbox_entry(UUID, TEXT, TEXT, TEXT, UUID, UUID, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.soft_delete_record(TEXT, UUID, UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.process_outbox_entry(UUID, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_unsynced_records(UUID, TEXT, TEXT, BIGINT) FROM PUBLIC;

