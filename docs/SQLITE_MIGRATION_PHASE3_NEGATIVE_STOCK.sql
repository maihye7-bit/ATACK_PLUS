-- Existing SQLite database upgrade for D-016 negative-stock authorization.
-- Apply once after SQLITE_MIGRATION_PHASE3_WAREHOUSES.sql.
-- The application must insert the authorized stock movement first, then update
-- stock.last_operation_id and quantity in the same BEGIN IMMEDIATE transaction.

PRAGMA foreign_keys = OFF;
BEGIN IMMEDIATE;

CREATE UNIQUE INDEX IF NOT EXISTS uq_products_id_store ON products(id,store_id);

DROP TRIGGER IF EXISTS trg_stock_store_location_ins;
DROP TRIGGER IF EXISTS trg_stock_store_location_upd;
DROP TRIGGER IF EXISTS trg_stock_negative_authorization_ins;
DROP TRIGGER IF EXISTS trg_stock_negative_authorization_upd;
DROP TRIGGER IF EXISTS trg_stock_last_updated;
DROP TRIGGER IF EXISTS trg_stock_log_insert;
DROP TRIGGER IF EXISTS trg_stock_log_update;
DROP TRIGGER IF EXISTS trg_stock_log_delete;

DROP TRIGGER IF EXISTS trg_stock_movements_store_location_ins;
DROP TRIGGER IF EXISTS trg_stock_movements_store_location_upd;
DROP TRIGGER IF EXISTS trg_stock_movements_store_ins;
DROP TRIGGER IF EXISTS trg_stock_movements_store_upd;
DROP TRIGGER IF EXISTS trg_stock_movements_log_change;
DROP TRIGGER IF EXISTS trg_stock_movements_log_change_upd;
DROP TRIGGER IF EXISTS trg_stock_movements_log_change_del;

DROP TRIGGER IF EXISTS trg_stock_adjustments_store_location_ins;
DROP TRIGGER IF EXISTS trg_stock_adjustments_store_location_upd;
DROP TRIGGER IF EXISTS trg_stock_adjustments_negative_evidence_ins;
DROP TRIGGER IF EXISTS trg_stock_adjustments_negative_evidence_upd;
DROP TRIGGER IF EXISTS trg_stock_adjustments_log_insert;
DROP TRIGGER IF EXISTS trg_stock_adjustments_log_update;

ALTER TABLE stock_movements ADD COLUMN operation_id TEXT;
ALTER TABLE stock_movements ADD COLUMN device_id TEXT;
ALTER TABLE stock_movements ADD COLUMN shortage_quantity NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(shortage_quantity>=0);
ALTER TABLE stock_movements ADD COLUMN negative_stock_authorized INTEGER NOT NULL DEFAULT 0 CHECK(negative_stock_authorized IN (0,1));

ALTER TABLE stock_adjustments ADD COLUMN operation_id TEXT;
ALTER TABLE stock_adjustments ADD COLUMN device_id TEXT;
ALTER TABLE stock_adjustments ADD COLUMN shortage_quantity NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(shortage_quantity>=0);
ALTER TABLE stock_adjustments ADD COLUMN negative_stock_authorized INTEGER NOT NULL DEFAULT 0 CHECK(negative_stock_authorized IN (0,1));

CREATE TABLE stock_new (
    id TEXT PRIMARY KEY CHECK(length(id)=36),
    product_id TEXT NOT NULL CHECK(length(product_id)=36),
    store_id TEXT NOT NULL CHECK(length(store_id)=36),
    location_id TEXT NOT NULL,
    quantity NUMERIC(18,4) NOT NULL DEFAULT 0,
    reserved_quantity NUMERIC(18,4) NOT NULL DEFAULT 0
        CHECK(reserved_quantity>=0 AND reserved_quantity<=MAX(quantity,0)),
    available_quantity NUMERIC(18,4) GENERATED ALWAYS AS (quantity-reserved_quantity) STORED,
    last_updated TEXT NOT NULL DEFAULT (datetime('now')),
    last_operation_id TEXT,
    FOREIGN KEY(product_id,store_id) REFERENCES products(id,store_id) ON DELETE RESTRICT,
    FOREIGN KEY(location_id,store_id) REFERENCES locations(id,store_id) ON DELETE RESTRICT,
    UNIQUE(product_id,location_id)
);

INSERT INTO stock_new(id,product_id,store_id,location_id,quantity,reserved_quantity,last_updated,last_operation_id)
SELECT id,product_id,store_id,location_id,quantity,reserved_quantity,last_updated,NULL
FROM stock;

DROP TABLE stock;
ALTER TABLE stock_new RENAME TO stock;

CREATE INDEX idx_stock_product ON stock(product_id);
CREATE INDEX idx_stock_location ON stock(location_id);

-- Same-store, active warehouse validation.
CREATE TRIGGER trg_stock_store_location_ins
BEFORE INSERT ON stock
WHEN NOT EXISTS (
    SELECT 1 FROM products p JOIN locations l
      ON l.id=NEW.location_id AND l.store_id=NEW.store_id AND l.is_active=1
     WHERE p.id=NEW.product_id AND p.store_id=NEW.store_id
)
BEGIN
    SELECT RAISE(ABORT,'Stock product/location must belong to the same store and active warehouse');
END;

CREATE TRIGGER trg_stock_store_location_upd
BEFORE UPDATE OF product_id,store_id,location_id ON stock
WHEN NOT EXISTS (
    SELECT 1 FROM products p JOIN locations l
      ON l.id=NEW.location_id AND l.store_id=NEW.store_id AND l.is_active=1
     WHERE p.id=NEW.product_id AND p.store_id=NEW.store_id
)
BEGIN
    SELECT RAISE(ABORT,'Stock product/location must belong to the same store and active warehouse');
END;

-- A negative balance is valid only when the same transaction has already
-- recorded a matching authorized movement with operation/device/reason/shortage.
CREATE TRIGGER trg_stock_negative_authorization_ins
BEFORE INSERT ON stock
WHEN NEW.quantity<0 AND NOT EXISTS (
    SELECT 1 FROM stock_movements m
     WHERE m.store_id=NEW.store_id AND m.product_id=NEW.product_id
       AND m.location_id=NEW.location_id AND m.operation_id=NEW.last_operation_id
       AND m.negative_stock_authorized=1 AND m.shortage_quantity>0
       AND m.device_id IS NOT NULL AND length(trim(m.reason))>0
)
BEGIN
    SELECT RAISE(ABORT,'Negative stock requires an authorized movement in the same transaction');
END;

CREATE TRIGGER trg_stock_negative_authorization_upd
BEFORE UPDATE OF quantity,last_operation_id ON stock
WHEN NEW.quantity<0 AND NOT EXISTS (
    SELECT 1 FROM stock_movements m
     WHERE m.store_id=NEW.store_id AND m.product_id=NEW.product_id
       AND m.location_id=NEW.location_id AND m.operation_id=NEW.last_operation_id
       AND m.negative_stock_authorized=1 AND m.shortage_quantity>0
       AND m.device_id IS NOT NULL AND length(trim(m.reason))>0
)
BEGIN
    SELECT RAISE(ABORT,'Negative stock requires an authorized movement in the same transaction');
END;

CREATE TRIGGER trg_stock_last_updated
AFTER UPDATE OF quantity,reserved_quantity ON stock
FOR EACH ROW WHEN NEW.last_updated IS OLD.last_updated
BEGIN
    UPDATE stock SET last_updated=strftime('%Y-%m-%d %H:%M:%f','now') WHERE id=OLD.id;
END;

-- Stock balance Change Log includes the operation that produced the balance.
CREATE TRIGGER trg_stock_log_insert AFTER INSERT ON stock
BEGIN
    INSERT INTO change_log(store_id,sync_cursor,table_name,record_uuid,operation,new_values_json)
    VALUES(NEW.store_id,(SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id=NEW.store_id),
      'stock',NEW.id,'INSERT',
      json_object('id',NEW.id,'store_id',NEW.store_id,'product_id',NEW.product_id,
        'location_id',NEW.location_id,'quantity',NEW.quantity,'reserved_quantity',NEW.reserved_quantity,
        'last_updated',NEW.last_updated,'last_operation_id',NEW.last_operation_id));
END;
CREATE TRIGGER trg_stock_log_update AFTER UPDATE ON stock
WHEN NEW.id IS NOT OLD.id OR NEW.store_id IS NOT OLD.store_id OR NEW.product_id IS NOT OLD.product_id
  OR NEW.location_id IS NOT OLD.location_id OR NEW.quantity IS NOT OLD.quantity
  OR NEW.reserved_quantity IS NOT OLD.reserved_quantity OR NEW.last_operation_id IS NOT OLD.last_operation_id
BEGIN
    INSERT INTO change_log(store_id,sync_cursor,table_name,record_uuid,operation,old_values_json,new_values_json)
    VALUES(NEW.store_id,(SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id=NEW.store_id),
      'stock',NEW.id,'UPDATE',
      json_object('id',OLD.id,'store_id',OLD.store_id,'product_id',OLD.product_id,
        'location_id',OLD.location_id,'quantity',OLD.quantity,'reserved_quantity',OLD.reserved_quantity,
        'last_updated',OLD.last_updated,'last_operation_id',OLD.last_operation_id),
      json_object('id',NEW.id,'store_id',NEW.store_id,'product_id',NEW.product_id,
        'location_id',NEW.location_id,'quantity',NEW.quantity,'reserved_quantity',NEW.reserved_quantity,
        'last_updated',NEW.last_updated,'last_operation_id',NEW.last_operation_id));
END;
CREATE TRIGGER trg_stock_log_delete AFTER DELETE ON stock
BEGIN
    INSERT INTO change_log(store_id,sync_cursor,table_name,record_uuid,operation,old_values_json)
    VALUES(OLD.store_id,(SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id=OLD.store_id),
      'stock',OLD.id,'DELETE',
      json_object('id',OLD.id,'store_id',OLD.store_id,'product_id',OLD.product_id,
        'location_id',OLD.location_id,'quantity',OLD.quantity,'reserved_quantity',OLD.reserved_quantity,
        'last_updated',OLD.last_updated,'last_operation_id',OLD.last_operation_id));
END;

-- Evidence constraints for movement/adjustment rows.
CREATE TRIGGER trg_stock_movements_negative_evidence_ins
BEFORE INSERT ON stock_movements
WHEN NEW.negative_stock_authorized=1 AND
    (NEW.shortage_quantity<=0 OR NEW.operation_id IS NULL OR NEW.device_id IS NULL
     OR NEW.reason IS NULL OR length(trim(NEW.reason))=0)
BEGIN
    SELECT RAISE(ABORT,'Negative stock movement requires operation, device, shortage and reason');
END;
CREATE TRIGGER trg_stock_movements_negative_evidence_upd
BEFORE UPDATE OF negative_stock_authorized,shortage_quantity,operation_id,device_id,reason ON stock_movements
WHEN NEW.negative_stock_authorized=1 AND
    (NEW.shortage_quantity<=0 OR NEW.operation_id IS NULL OR NEW.device_id IS NULL
     OR NEW.reason IS NULL OR length(trim(NEW.reason))=0)
BEGIN
    SELECT RAISE(ABORT,'Negative stock movement requires operation, device, shortage and reason');
END;

CREATE TRIGGER trg_stock_movements_store_location_ins
BEFORE INSERT ON stock_movements
WHEN NOT EXISTS (
    SELECT 1 FROM products p JOIN locations l
      ON l.id=NEW.location_id AND l.store_id=NEW.store_id AND l.is_active=1
    JOIN users u ON u.id=NEW.user_id AND u.store_id=NEW.store_id
     WHERE p.id=NEW.product_id AND p.store_id=NEW.store_id
)
BEGIN
    SELECT RAISE(ABORT,'Stock movement product/location/user must belong to the same store');
END;
CREATE TRIGGER trg_stock_movements_store_location_upd
BEFORE UPDATE OF product_id,store_id,location_id,user_id ON stock_movements
WHEN NOT EXISTS (
    SELECT 1 FROM products p JOIN locations l
      ON l.id=NEW.location_id AND l.store_id=NEW.store_id AND l.is_active=1
    JOIN users u ON u.id=NEW.user_id AND u.store_id=NEW.store_id
     WHERE p.id=NEW.product_id AND p.store_id=NEW.store_id
)
BEGIN
    SELECT RAISE(ABORT,'Stock movement product/location/user must belong to the same store');
END;

-- Stock movement Change Log preserves the D-016 evidence envelope.
CREATE TRIGGER trg_stock_movements_log_change AFTER INSERT ON stock_movements
BEGIN
    INSERT INTO change_log(store_id,sync_cursor,table_name,record_uuid,operation,new_values_json)
    VALUES(NEW.store_id,(SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id=NEW.store_id),
      'stock_movements',NEW.id,'INSERT',
      json_object('id',NEW.id,'store_id',NEW.store_id,'product_id',NEW.product_id,
        'location_id',NEW.location_id,'type',NEW.type,'quantity',NEW.quantity,'unit_id',NEW.unit_id,
        'cost_per_unit',NEW.cost_per_unit,'total_value',NEW.total_value,'reference_id',NEW.reference_id,
        'reference_type',NEW.reference_type,'reason',NEW.reason,'user_id',NEW.user_id,
        'operation_id',NEW.operation_id,'device_id',NEW.device_id,'shortage_quantity',NEW.shortage_quantity,
        'negative_stock_authorized',NEW.negative_stock_authorized,'created_at',NEW.created_at));
END;
CREATE TRIGGER trg_stock_movements_log_change_upd AFTER UPDATE ON stock_movements
WHEN NEW.id IS NOT OLD.id OR NEW.store_id IS NOT OLD.store_id OR NEW.product_id IS NOT OLD.product_id
  OR NEW.location_id IS NOT OLD.location_id OR NEW.type IS NOT OLD.type OR NEW.quantity IS NOT OLD.quantity
  OR NEW.operation_id IS NOT OLD.operation_id OR NEW.device_id IS NOT OLD.device_id
  OR NEW.shortage_quantity IS NOT OLD.shortage_quantity OR NEW.negative_stock_authorized IS NOT OLD.negative_stock_authorized
BEGIN
    INSERT INTO change_log(store_id,sync_cursor,table_name,record_uuid,operation,old_values_json,new_values_json)
    VALUES(NEW.store_id,(SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id=NEW.store_id),
      'stock_movements',NEW.id,'UPDATE',
      json_object('id',OLD.id,'store_id',OLD.store_id,'product_id',OLD.product_id,
        'location_id',OLD.location_id,'type',OLD.type,'quantity',OLD.quantity,'unit_id',OLD.unit_id,
        'cost_per_unit',OLD.cost_per_unit,'total_value',OLD.total_value,'reference_id',OLD.reference_id,
        'reference_type',OLD.reference_type,'reason',OLD.reason,'user_id',OLD.user_id,
        'operation_id',OLD.operation_id,'device_id',OLD.device_id,'shortage_quantity',OLD.shortage_quantity,
        'negative_stock_authorized',OLD.negative_stock_authorized,'created_at',OLD.created_at),
      json_object('id',NEW.id,'store_id',NEW.store_id,'product_id',NEW.product_id,
        'location_id',NEW.location_id,'type',NEW.type,'quantity',NEW.quantity,'unit_id',NEW.unit_id,
        'cost_per_unit',NEW.cost_per_unit,'total_value',NEW.total_value,'reference_id',NEW.reference_id,
        'reference_type',NEW.reference_type,'reason',NEW.reason,'user_id',NEW.user_id,
        'operation_id',NEW.operation_id,'device_id',NEW.device_id,'shortage_quantity',NEW.shortage_quantity,
        'negative_stock_authorized',NEW.negative_stock_authorized,'created_at',NEW.created_at));
END;
CREATE TRIGGER trg_stock_movements_log_change_del AFTER DELETE ON stock_movements
BEGIN
    INSERT INTO change_log(store_id,sync_cursor,table_name,record_uuid,operation,old_values_json)
    VALUES(OLD.store_id,(SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id=OLD.store_id),
      'stock_movements',OLD.id,'DELETE',
      json_object('id',OLD.id,'store_id',OLD.store_id,'product_id',OLD.product_id,
        'location_id',OLD.location_id,'type',OLD.type,'quantity',OLD.quantity,'unit_id',OLD.unit_id,
        'cost_per_unit',OLD.cost_per_unit,'total_value',OLD.total_value,'reference_id',OLD.reference_id,
        'reference_type',OLD.reference_type,'reason',OLD.reason,'user_id',OLD.user_id,
        'operation_id',OLD.operation_id,'device_id',OLD.device_id,'shortage_quantity',OLD.shortage_quantity,
        'negative_stock_authorized',OLD.negative_stock_authorized,'created_at',OLD.created_at));
END;

CREATE TRIGGER trg_stock_adjustments_store_location_ins
BEFORE INSERT ON stock_adjustments
WHEN NOT EXISTS (
    SELECT 1 FROM products p JOIN locations l
      ON l.id=NEW.location_id AND l.store_id=NEW.store_id AND l.is_active=1
     WHERE p.id=NEW.product_id AND p.store_id=NEW.store_id
)
BEGIN
    SELECT RAISE(ABORT,'Stock adjustment product/location must belong to the same store and active warehouse');
END;
CREATE TRIGGER trg_stock_adjustments_store_location_upd
BEFORE UPDATE OF product_id,store_id,location_id ON stock_adjustments
WHEN NOT EXISTS (
    SELECT 1 FROM products p JOIN locations l
      ON l.id=NEW.location_id AND l.store_id=NEW.store_id AND l.is_active=1
     WHERE p.id=NEW.product_id AND p.store_id=NEW.store_id
)
BEGIN
    SELECT RAISE(ABORT,'Stock adjustment product/location must belong to the same store and active warehouse');
END;
CREATE TRIGGER trg_stock_adjustments_negative_evidence_ins
BEFORE INSERT ON stock_adjustments
WHEN NEW.negative_stock_authorized=1 AND
    (NEW.shortage_quantity<=0 OR NEW.operation_id IS NULL OR NEW.device_id IS NULL
     OR NEW.reason IS NULL OR length(trim(NEW.reason))=0)
BEGIN
    SELECT RAISE(ABORT,'Negative stock adjustment requires operation, device, shortage and reason');
END;
CREATE TRIGGER trg_stock_adjustments_negative_evidence_upd
BEFORE UPDATE OF negative_stock_authorized,shortage_quantity,operation_id,device_id,reason ON stock_adjustments
WHEN NEW.negative_stock_authorized=1 AND
    (NEW.shortage_quantity<=0 OR NEW.operation_id IS NULL OR NEW.device_id IS NULL
     OR NEW.reason IS NULL OR length(trim(NEW.reason))=0)
BEGIN
    SELECT RAISE(ABORT,'Negative stock adjustment requires operation, device, shortage and reason');
END;

CREATE TRIGGER trg_stock_adjustments_log_insert AFTER INSERT ON stock_adjustments
BEGIN
    INSERT INTO change_log(store_id,sync_cursor,table_name,record_uuid,operation,new_values_json)
    VALUES(NEW.store_id,(SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id=NEW.store_id),
      'stock_adjustments',NEW.id,'INSERT',
      json_object('id',NEW.id,'store_id',NEW.store_id,'adjustment_number',NEW.adjustment_number,
        'product_id',NEW.product_id,'adjustment_type',NEW.adjustment_type,'reason',NEW.reason,
        'quantity',NEW.quantity,'unit_id',NEW.unit_id,'cost_per_unit',NEW.cost_per_unit,
        'total_value',NEW.total_value,'created_by',NEW.created_by,'location_id',NEW.location_id,
        'operation_id',NEW.operation_id,'device_id',NEW.device_id,'shortage_quantity',NEW.shortage_quantity,
        'negative_stock_authorized',NEW.negative_stock_authorized,'created_at',NEW.created_at));
END;
CREATE TRIGGER trg_stock_adjustments_log_update AFTER UPDATE ON stock_adjustments
WHEN NEW.id IS NOT OLD.id OR NEW.store_id IS NOT OLD.store_id OR NEW.product_id IS NOT OLD.product_id
  OR NEW.location_id IS NOT OLD.location_id OR NEW.operation_id IS NOT OLD.operation_id
  OR NEW.device_id IS NOT OLD.device_id OR NEW.shortage_quantity IS NOT OLD.shortage_quantity
  OR NEW.negative_stock_authorized IS NOT OLD.negative_stock_authorized
BEGIN
    INSERT INTO change_log(store_id,sync_cursor,table_name,record_uuid,operation,old_values_json,new_values_json)
    VALUES(NEW.store_id,(SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id=NEW.store_id),
      'stock_adjustments',NEW.id,'UPDATE',
      json_object('id',OLD.id,'store_id',OLD.store_id,'adjustment_number',OLD.adjustment_number,
        'product_id',OLD.product_id,'adjustment_type',OLD.adjustment_type,'reason',OLD.reason,
        'quantity',OLD.quantity,'unit_id',OLD.unit_id,'cost_per_unit',OLD.cost_per_unit,
        'total_value',OLD.total_value,'created_by',OLD.created_by,'location_id',OLD.location_id,
        'operation_id',OLD.operation_id,'device_id',OLD.device_id,'shortage_quantity',OLD.shortage_quantity,
        'negative_stock_authorized',OLD.negative_stock_authorized,'created_at',OLD.created_at),
      json_object('id',NEW.id,'store_id',NEW.store_id,'adjustment_number',NEW.adjustment_number,
        'product_id',NEW.product_id,'adjustment_type',NEW.adjustment_type,'reason',NEW.reason,
        'quantity',NEW.quantity,'unit_id',NEW.unit_id,'cost_per_unit',NEW.cost_per_unit,
        'total_value',NEW.total_value,'created_by',NEW.created_by,'location_id',NEW.location_id,
        'operation_id',NEW.operation_id,'device_id',NEW.device_id,'shortage_quantity',NEW.shortage_quantity,
        'negative_stock_authorized',NEW.negative_stock_authorized,'created_at',NEW.created_at));
END;

COMMIT;
PRAGMA foreign_keys = ON;
