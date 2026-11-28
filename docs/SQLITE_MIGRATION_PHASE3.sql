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
    operation_id TEXT,
    device_id TEXT,
    shortage_quantity NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(shortage_quantity >= 0),
    negative_stock_authorized INTEGER NOT NULL DEFAULT 0 CHECK(negative_stock_authorized IN (0,1)),
    is_synced INTEGER DEFAULT 0 CHECK(is_synced IN (0, 1)),
    sync_status TEXT DEFAULT 'PENDING' CHECK(sync_status IN ('SYNCED', 'PENDING', 'ERROR', 'CONFLICT')),
    synced_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (store_id) REFERENCES stores(id),
    FOREIGN KEY (original_purchase_id) REFERENCES purchases(id),
    CHECK(
      (negative_stock_authorized=0 AND shortage_quantity=0)
      OR (negative_stock_authorized=1 AND shortage_quantity>0
          AND operation_id IS NOT NULL AND device_id IS NOT NULL AND length(trim(reason))>0)
    ),
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
    FOREIGN KEY (return_id) REFERENCES purchase_returns(id) ON DELETE RESTRICT,
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE RESTRICT,
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

-- Purchase-return parent events use their own stable store_id.
CREATE TRIGGER IF NOT EXISTS trg_purchase_returns_log_insert
AFTER INSERT ON purchase_returns
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id,
            (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id=NEW.store_id),
            'purchase_returns', NEW.id, 'INSERT', NULL,
            json_object('id',NEW.id,'store_id',NEW.store_id,'return_number',NEW.return_number,
                        'original_purchase_id',NEW.original_purchase_id,'reason',NEW.reason,
                        'total_amount',NEW.total_amount,'refund_method',NEW.refund_method,'notes',NEW.notes,
                        'created_by',NEW.created_by,'device_sync_id',NEW.device_sync_id,
                        'is_synced',NEW.is_synced,'sync_status',NEW.sync_status,'synced_at',NEW.synced_at,
                        'created_at',NEW.created_at,'updated_at',NEW.updated_at));
END;

CREATE TRIGGER IF NOT EXISTS trg_purchase_returns_log_update
AFTER UPDATE ON purchase_returns
WHEN NEW.id IS NOT OLD.id OR NEW.store_id IS NOT OLD.store_id
  OR NEW.return_number IS NOT OLD.return_number
  OR NEW.original_purchase_id IS NOT OLD.original_purchase_id
  OR NEW.reason IS NOT OLD.reason OR NEW.total_amount IS NOT OLD.total_amount
  OR NEW.refund_method IS NOT OLD.refund_method OR NEW.notes IS NOT OLD.notes
  OR NEW.created_by IS NOT OLD.created_by OR NEW.device_sync_id IS NOT OLD.device_sync_id
  OR NEW.is_synced IS NOT OLD.is_synced OR NEW.sync_status IS NOT OLD.sync_status
  OR NEW.synced_at IS NOT OLD.synced_at OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (NEW.store_id,
            (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id=NEW.store_id),
            'purchase_returns', NEW.id, 'UPDATE',
            json_object('id',OLD.id,'store_id',OLD.store_id,'return_number',OLD.return_number,
                        'original_purchase_id',OLD.original_purchase_id,'reason',OLD.reason,
                        'total_amount',OLD.total_amount,'refund_method',OLD.refund_method,'notes',OLD.notes,
                        'created_by',OLD.created_by,'device_sync_id',OLD.device_sync_id,
                        'is_synced',OLD.is_synced,'sync_status',OLD.sync_status,'synced_at',OLD.synced_at,
                        'created_at',OLD.created_at,'updated_at',OLD.updated_at),
            json_object('id',NEW.id,'store_id',NEW.store_id,'return_number',NEW.return_number,
                        'original_purchase_id',NEW.original_purchase_id,'reason',NEW.reason,
                        'total_amount',NEW.total_amount,'refund_method',NEW.refund_method,'notes',NEW.notes,
                        'created_by',NEW.created_by,'device_sync_id',NEW.device_sync_id,
                        'is_synced',NEW.is_synced,'sync_status',NEW.sync_status,'synced_at',NEW.synced_at,
                        'created_at',NEW.created_at,'updated_at',NEW.updated_at));
END;

CREATE TRIGGER IF NOT EXISTS trg_purchase_returns_log_delete
AFTER DELETE ON purchase_returns
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES (OLD.store_id,
            (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id=OLD.store_id),
            'purchase_returns', OLD.id, 'DELETE',
            json_object('id',OLD.id,'store_id',OLD.store_id,'return_number',OLD.return_number,
                        'original_purchase_id',OLD.original_purchase_id,'reason',OLD.reason,
                        'total_amount',OLD.total_amount,'refund_method',OLD.refund_method,'notes',OLD.notes,
                        'created_by',OLD.created_by,'device_sync_id',OLD.device_sync_id,
                        'is_synced',OLD.is_synced,'sync_status',OLD.sync_status,'synced_at',OLD.synced_at,
                        'created_at',OLD.created_at,'updated_at',OLD.updated_at), NULL);
END;

-- Child ownership is resolved through the purchase-return parent. RESTRICT on
-- return_id guarantees that a parent cannot disappear before its child events.
CREATE TRIGGER IF NOT EXISTS trg_purchase_return_items_log_insert
AFTER INSERT ON purchase_return_items
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM purchase_returns WHERE id=NEW.return_id),
            (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log
              WHERE store_id=(SELECT store_id FROM purchase_returns WHERE id=NEW.return_id)),
            'purchase_return_items', NEW.id, 'INSERT', NULL,
            json_object('id',NEW.id,'return_id',NEW.return_id,'product_id',NEW.product_id,
                        'quantity',NEW.quantity,'quantity_unit_id',NEW.quantity_unit_id,
                        'unit_price',NEW.unit_price,'line_total',NEW.line_total,
                        'batch_number',NEW.batch_number,'expiry_date',NEW.expiry_date,
                        'created_at',NEW.created_at));
END;

CREATE TRIGGER IF NOT EXISTS trg_purchase_return_items_log_update
AFTER UPDATE ON purchase_return_items
WHEN NEW.id IS NOT OLD.id OR NEW.return_id IS NOT OLD.return_id
  OR NEW.product_id IS NOT OLD.product_id OR NEW.quantity IS NOT OLD.quantity
  OR NEW.quantity_unit_id IS NOT OLD.quantity_unit_id
  OR NEW.unit_price IS NOT OLD.unit_price OR NEW.line_total IS NOT OLD.line_total
  OR NEW.batch_number IS NOT OLD.batch_number OR NEW.expiry_date IS NOT OLD.expiry_date
  OR NEW.created_at IS NOT OLD.created_at
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM purchase_returns WHERE id=NEW.return_id),
            (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log
              WHERE store_id=(SELECT store_id FROM purchase_returns WHERE id=NEW.return_id)),
            'purchase_return_items', NEW.id, 'UPDATE',
            json_object('id',OLD.id,'return_id',OLD.return_id,'product_id',OLD.product_id,
                        'quantity',OLD.quantity,'quantity_unit_id',OLD.quantity_unit_id,
                        'unit_price',OLD.unit_price,'line_total',OLD.line_total,
                        'batch_number',OLD.batch_number,'expiry_date',OLD.expiry_date,
                        'created_at',OLD.created_at),
            json_object('id',NEW.id,'return_id',NEW.return_id,'product_id',NEW.product_id,
                        'quantity',NEW.quantity,'quantity_unit_id',NEW.quantity_unit_id,
                        'unit_price',NEW.unit_price,'line_total',NEW.line_total,
                        'batch_number',NEW.batch_number,'expiry_date',NEW.expiry_date,
                        'created_at',NEW.created_at));
END;

CREATE TRIGGER IF NOT EXISTS trg_purchase_return_items_log_delete
AFTER DELETE ON purchase_return_items
BEGIN
    INSERT INTO change_log (store_id, sync_cursor, table_name, record_uuid, operation, old_values_json, new_values_json)
    VALUES ((SELECT store_id FROM purchase_returns WHERE id=OLD.return_id),
            (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log
              WHERE store_id=(SELECT store_id FROM purchase_returns WHERE id=OLD.return_id)),
            'purchase_return_items', OLD.id, 'DELETE',
            json_object('id',OLD.id,'return_id',OLD.return_id,'product_id',OLD.product_id,
                        'quantity',OLD.quantity,'quantity_unit_id',OLD.quantity_unit_id,
                        'unit_price',OLD.unit_price,'line_total',OLD.line_total,
                        'batch_number',OLD.batch_number,'expiry_date',OLD.expiry_date,
                        'created_at',OLD.created_at), NULL);
END;

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