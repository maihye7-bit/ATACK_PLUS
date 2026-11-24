-- ============================================================
-- ATACK PLUS SQLite Migration - Phase 3
-- SQLite >= 3.38.0 with WAL mode enabled
-- ============================================================

--PRAGMA foreign_keys = ON;
--PRAGMA journal_mode = WAL;
--PRAGMA synchronous = NORMAL;
--PRAGMA recursive_triggers = ON;

BEGIN TRANSACTION;

-- ============================================================
-- 1. New Tables for Phase 3
-- ============================================================

-- Purchase Returns
CREATE TABLE IF NOT EXISTS purchase_returns (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    return_number TEXT NOT NULL,
    original_purchase_id TEXT NOT NULL CHECK(length(original_purchase_id) = 36),
    reason TEXT,
    total_amount NUMERIC(18,4) NOT NULL DEFAULT 0,
    refund_method TEXT CHECK(refund_method IN ('CREDIT', 'CASH', 'BANK_TRANSFER', 'MOBILE')),
    notes TEXT,
    created_by TEXT NOT NULL CHECK(length(created_by) = 36),
    device_sync_id TEXT,
    is_synced INTEGER DEFAULT 0 CHECK(is_synced IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (original_purchase_id) REFERENCES purchases(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_purchase_returns_store_number ON purchase_returns(store_id, return_number);
CREATE INDEX IF NOT EXISTS idx_purchase_returns_purchase ON purchase_returns(original_purchase_id);

CREATE TABLE IF NOT EXISTS purchase_return_items (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    return_id TEXT NOT NULL CHECK(length(return_id) = 36),
    product_id TEXT NOT NULL CHECK(length(product_id) = 36),
    quantity NUMERIC(18,4) NOT NULL CHECK(quantity > 0),
    quantity_unit_id TEXT NOT NULL,
    unit_price NUMERIC(18,4) NOT NULL CHECK(unit_price >= 0),
    line_total NUMERIC(18,4) NOT NULL,
    batch_number TEXT,
    expiry_date TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (return_id) REFERENCES purchase_returns(id) ON DELETE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
    FOREIGN KEY (quantity_unit_id) REFERENCES units(id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_purchase_return_items_return ON purchase_return_items(return_id);
CREATE INDEX IF NOT EXISTS idx_purchase_return_items_product ON purchase_return_items(product_id);

-- Stock Adjustments
CREATE TABLE IF NOT EXISTS stock_adjustments (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    adjustment_number TEXT NOT NULL,
    product_id TEXT NOT NULL CHECK(length(product_id) = 36),
    adjustment_type TEXT NOT NULL CHECK(adjustment_type IN ('INCREASE', 'DECREASE')),
    reason TEXT NOT NULL,
    quantity NUMERIC(18,4) NOT NULL CHECK(quantity > 0),
    unit_id TEXT NOT NULL,
    cost_per_unit NUMERIC(18,4) NOT NULL CHECK(cost_per_unit >= 0),
    total_value NUMERIC(18,4) NOT NULL CHECK(total_value >= 0),
    refund_method TEXT CHECK(refund_method IN ('CREDIT', 'CASH', 'BANK_TRANSFER', 'MOBILE')),
    created_by TEXT NOT NULL CHECK(length(created_by) = 36),
    device_sync_id TEXT,
    is_synced INTEGER DEFAULT 0 CHECK(is_synced IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (product_id) REFERENCES products(id),
    FOREIGN KEY (unit_id) REFERENCES units(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_stock_adjustments_store_number ON stock_adjustments(store_id, adjustment_number);
CREATE INDEX IF NOT EXISTS idx_stock_adjustments_product ON stock_adjustments(product_id);
CREATE INDEX IF NOT EXISTS idx_stock_adjustments_created ON stock_adjustments(created_at);

-- Inventory Batches (for batch/lot tracking)
CREATE TABLE IF NOT EXISTS inventory_batches (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    product_id TEXT NOT NULL CHECK(length(product_id) = 36),
    batch_number TEXT NOT NULL,
    quantity NUMERIC(18,4) NOT NULL CHECK(quantity >= 0),
    reserved_quantity NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(reserved_quantity >= 0 AND reserved_quantity <= quantity),
    available_quantity NUMERIC(18,4) GENERATED ALWAYS AS (quantity - reserved_quantity) STORED,
    expiry_date TEXT,
    cost_per_unit NUMERIC(18,4) NOT NULL CHECK(cost_per_unit >= 0),
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (product_id) REFERENCES products(id),
    UNIQUE(store_id, product_id, batch_number)
);

CREATE INDEX IF NOT EXISTS idx_inventory_batches_product ON inventory_batches(product_id);
CREATE INDEX IF NOT EXISTS idx_inventory_batches_expiry ON inventory_batches(expiry_date) WHERE expiry_date IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_inventory_batches_batch ON inventory_batches(batch_number);

-- Stock Alerts
CREATE TABLE IF NOT EXISTS stock_alerts (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    product_id TEXT NOT NULL CHECK(length(product_id) = 36),
    alert_type TEXT NOT NULL CHECK(alert_type IN ('LOW_STOCK', 'EXPIRY_SOON')),
    current_quantity NUMERIC(18,4) NOT NULL,
    threshold NUMERIC(18,4) NOT NULL,
    message TEXT NOT NULL,
    is_acknowledged INTEGER DEFAULT 0 CHECK(is_acknowledged IN (0, 1)),
    acknowledged_by TEXT CHECK(length(acknowledged_by) = 36),
    acknowledged_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (product_id) REFERENCES products(id),
    FOREIGN KEY (acknowledged_by) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_stock_alerts_product ON stock_alerts(product_id);
CREATE INDEX IF NOT EXISTS idx_stock_alerts_type ON stock_alerts(alert_type);
CREATE INDEX IF NOT EXISTS idx_stock_alerts_unacked ON stock_alerts(is_acknowledged) WHERE is_acknowledged = 0;

-- Chart of Accounts
CREATE TABLE IF NOT EXISTS chart_of_accounts (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    account_code TEXT NOT NULL,
    account_name TEXT NOT NULL,
    account_type TEXT NOT NULL CHECK(account_type IN (
        'ASSET', 'LIABILITY', 'EQUITY', 'REVENUE', 'EXPENSE',
        'CURRENT_ASSET', 'CURRENT_LIABILITY', 'COST_OF_GOODS_SOLD', 'INCOME'
    )),
    parent_id TEXT CHECK(length(parent_id) = 36),
    is_active INTEGER DEFAULT 1 CHECK(is_active IN (0, 1)),
    sort_order INTEGER DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (parent_id) REFERENCES chart_of_accounts(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_chart_accounts_store_code ON chart_of_accounts(store_id, account_code);
CREATE INDEX IF NOT EXISTS idx_chart_accounts_type ON chart_of_accounts(account_type);

-- Journal Entries
CREATE TABLE IF NOT EXISTS journal_entries (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    entry_number TEXT NOT NULL,
    entry_date TEXT NOT NULL,
    description TEXT,
    source_type TEXT CHECK(source_type IN ('SALE', 'PURCHASE', 'RETURN', 'PAYMENT', 'EXPENSE', 'REVENUE', 'ADJUSTMENT', 'TRANSFER')),
    source_id TEXT CHECK(length(source_id) = 36),
    total_debit NUMERIC(18,4) NOT NULL DEFAULT 0,
    total_credit NUMERIC(18,4) NOT NULL DEFAULT 0,
    is_posted INTEGER DEFAULT 1 CHECK(is_posted IN (0, 1)),
    posted_by TEXT NOT NULL CHECK(length(posted_by) = 36),
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (posted_by) REFERENCES users(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_journal_entries_store_number ON journal_entries(store_id, entry_number);
CREATE INDEX IF NOT EXISTS idx_journal_entries_date ON journal_entries(entry_date);

-- General Ledger
CREATE TABLE IF NOT EXISTS general_ledger (
    id TEXT PRIMARY KEY CHECK(length(id) = 36),
    store_id TEXT NOT NULL CHECK(length(store_id) = 36),
    journal_entry_id TEXT NOT NULL CHECK(length(journal_entry_id) = 36),
    account_id TEXT NOT NULL CHECK(length(account_id) = 36),
    entry_type TEXT NOT NULL CHECK(entry_type IN ('DEBIT', 'CREDIT')),
    amount NUMERIC(18,4) NOT NULL CHECK(amount > 0),
    currency TEXT NOT NULL DEFAULT 'DZD',
    description TEXT,
    reference_id TEXT CHECK(length(reference_id) = 36),
    reference_table TEXT,
    created_by TEXT NOT NULL CHECK(length(created_by) = 36),
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (journal_entry_id) REFERENCES journal_entries(id),
    FOREIGN KEY (account_id) REFERENCES chart_of_accounts(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_general_ledger_account ON general_ledger(account_id);
CREATE INDEX IF NOT EXISTS idx_general_ledger_journal ON general_ledger(journal_entry_id);
CREATE INDEX IF NOT EXISTS idx_general_ledger_reference ON general_ledger(reference_table, reference_id);

-- ============================================================
-- 2. Update Change Log Triggers
-- ============================================================

-- Add triggers to outbox tables (already present in base schema, ensure Phase 3 tables included)
-- Note: SQLite triggers for change_log are complex; ensure they fire for new tables during Flutter sync operations

-- ============================================================
-- 3. SQLite-Specific Notes
-- ============================================================

-- IMPORTANT: SQLite does not have check constraints with subqueries
-- Ensure quantity validation happens in Flutter or via RPC

-- For negative stock prevention:
-- This must be validated in the Flutter app before sync
-- or enforced via RPC on the server

-- Batch/expiry validation:
CREATE TRIGGER IF NOT EXISTS trg_inventory_batches_update_updated_at
AFTER UPDATE ON inventory_batches
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE inventory_batches SET updated_at = datetime('now') WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_journal_entries_update_updated_at
AFTER UPDATE ON journal_entries
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE journal_entries SET updated_at = datetime('now') WHERE id = OLD.id;
END;

-- ============================================================
-- 4. Data Migration (if upgrading from Phase 2)
-- ============================================================

-- No data migration needed - Phase 3 tables are new
-- Existing data in Phase 1 & 2 tables remains unchanged

-- ============================================================
-- 5. Verification Queries
-- ============================================================

-- Verify tables created:
-- SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%return%' OR name LIKE '%adjustment%' OR name LIKE '%journal%' OR name LIKE '%ledger%' OR name LIKE '%batch%' OR name LIKE '%alert%' OR name LIKE '%chart%';

-- Verify indexes:
-- SELECT name FROM sqlite_master WHERE type='index' AND name LIKE '%purchase_return%' OR name LIKE '%stock_adjustment%' OR name LIKE '%inventory_batch%' OR name LIKE '%stock_alert%' OR name LIKE '%chart_account%' OR name LIKE '%journal_%' OR name LIKE '%general_ledger%';

COMMIT;

-- ============================================================
-- 6. Post-Migration Steps
-- ============================================================

-- 1. Run Flutter tests: flutter test test/unit/database/stock_test.dart
-- 2. Test with SQLite: flutter test test/integration/offline_test.dart
-- 3. Verify sync works for new tables
-- 4. Check that all new fields appear in Flutter models

-- ============================================================
-- End of Phase 3 SQLite Migration
-- ============================================================