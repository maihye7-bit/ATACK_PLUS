-- Stage 3 / Part A: migrate an existing SQLite database to store-scoped warehouses.
-- Apply once after SQLITE_MIGRATION_PHASE3.sql, with no open application transactions.
-- Foreign keys are disabled only for the table replacement; validation is required
-- immediately after this script and before the application reopens the database.

PRAGMA foreign_keys = OFF;
BEGIN IMMEDIATE;

CREATE TEMP TABLE stage3_old_locations AS
SELECT id AS old_id,name AS location_name,COALESCE(is_default,0) AS was_default
FROM locations;

CREATE TEMP TABLE stage3_location_map (
    store_id TEXT NOT NULL,
    old_id TEXT NOT NULL,
    new_id TEXT NOT NULL,
    location_name TEXT NOT NULL,
    was_default INTEGER NOT NULL,
    PRIMARY KEY(store_id,old_id),
    UNIQUE(new_id)
);

INSERT INTO stage3_location_map(store_id,old_id,new_id,location_name,was_default)
SELECT s.id,l.old_id,
       lower(hex(randomblob(4))||'-'||hex(randomblob(2))||'-'||hex(randomblob(2))||'-'||hex(randomblob(2))||'-'||hex(randomblob(6))),
       l.location_name,l.was_default
FROM stores s CROSS JOIN stage3_old_locations l;

ALTER TABLE stock ADD COLUMN store_id TEXT;
UPDATE stock
   SET store_id=(SELECT p.store_id FROM products p WHERE p.id=stock.product_id),
       location_id=(SELECT m.new_id FROM stage3_location_map m
                     WHERE m.store_id=(SELECT p.store_id FROM products p WHERE p.id=stock.product_id)
                       AND m.old_id=stock.location_id);

ALTER TABLE stock_movements ADD COLUMN store_id TEXT;
UPDATE stock_movements
   SET store_id=(SELECT p.store_id FROM products p WHERE p.id=stock_movements.product_id),
       location_id=(SELECT m.new_id FROM stage3_location_map m
                     WHERE m.store_id=(SELECT p.store_id FROM products p WHERE p.id=stock_movements.product_id)
                       AND m.old_id=stock_movements.location_id);

ALTER TABLE stock_adjustments ADD COLUMN location_id TEXT NOT NULL DEFAULT 'main';
UPDATE stock_adjustments
   SET location_id=(SELECT m.new_id FROM stage3_location_map m
                     WHERE m.store_id=stock_adjustments.store_id
                       AND m.old_id=stock_adjustments.location_id);

DROP TABLE locations;

CREATE TABLE locations (
    id TEXT PRIMARY KEY CHECK(length(id)=36),
    store_id TEXT NOT NULL CHECK(length(store_id)=36),
    code TEXT NOT NULL CHECK(length(code) BETWEEN 2 AND 40),
    name TEXT NOT NULL,
    is_default INTEGER NOT NULL DEFAULT 0 CHECK(is_default IN (0,1)),
    is_active INTEGER NOT NULL DEFAULT 1 CHECK(is_active IN (0,1)),
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY(store_id) REFERENCES stores(id) ON DELETE CASCADE,
    UNIQUE(store_id,code),
    UNIQUE(id,store_id)
);

INSERT INTO locations(id,store_id,code,name,is_default,is_active)
SELECT new_id,store_id,old_id,location_name,was_default,1 FROM stage3_location_map;

CREATE UNIQUE INDEX uq_locations_one_active_default
ON locations(store_id) WHERE is_default=1 AND is_active=1;

CREATE INDEX idx_locations_store ON locations(store_id);

CREATE TRIGGER trg_stores_create_default_locations
AFTER INSERT ON stores
BEGIN
    INSERT OR IGNORE INTO locations(id,store_id,code,name,is_default,is_active) VALUES
      (lower(hex(randomblob(4))||'-'||hex(randomblob(2))||'-'||hex(randomblob(2))||'-'||hex(randomblob(2))||'-'||hex(randomblob(6))),NEW.id,'main','المتجر الرئيسي',1,1),
      (lower(hex(randomblob(4))||'-'||hex(randomblob(2))||'-'||hex(randomblob(2))||'-'||hex(randomblob(2))||'-'||hex(randomblob(6))),NEW.id,'warehouse','المستودع',0,1),
      (lower(hex(randomblob(4))||'-'||hex(randomblob(2))||'-'||hex(randomblob(2))||'-'||hex(randomblob(2))||'-'||hex(randomblob(6))),NEW.id,'storage','مخزن إضافي',0,1);
END;

-- Validate ownership on every local write. The application must provide store_id;
-- it is not inferred from an untrusted client location code.
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

CREATE TRIGGER trg_stock_movements_store_location_ins
BEFORE INSERT ON stock_movements
WHEN NOT EXISTS (
    SELECT 1 FROM products p JOIN locations l
      ON l.id=NEW.location_id AND l.store_id=NEW.store_id AND l.is_active=1
     WHERE p.id=NEW.product_id AND p.store_id=NEW.store_id
)
BEGIN
    SELECT RAISE(ABORT,'Stock movement product/location must belong to the same store and active warehouse');
END;

CREATE TRIGGER trg_stock_movements_store_location_upd
BEFORE UPDATE OF product_id,store_id,location_id ON stock_movements
WHEN NOT EXISTS (
    SELECT 1 FROM products p JOIN locations l
      ON l.id=NEW.location_id AND l.store_id=NEW.store_id AND l.is_active=1
     WHERE p.id=NEW.product_id AND p.store_id=NEW.store_id
)
BEGIN
    SELECT RAISE(ABORT,'Stock movement product/location must belong to the same store and active warehouse');
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

-- Locations are server-owned reference data and are pulled by each registered device.
CREATE TRIGGER trg_locations_log_insert
AFTER INSERT ON locations
BEGIN
    INSERT INTO change_log(store_id,sync_cursor,table_name,record_uuid,operation,new_values_json)
    VALUES(NEW.store_id,
           (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id=NEW.store_id),
           'locations',NEW.id,'INSERT',
           json_object('id',NEW.id,'store_id',NEW.store_id,'code',NEW.code,'name',NEW.name,
                       'is_default',NEW.is_default,'is_active',NEW.is_active,
                       'created_at',NEW.created_at,'updated_at',NEW.updated_at));
END;

CREATE TRIGGER trg_locations_log_update
AFTER UPDATE ON locations
WHEN NEW.id IS NOT OLD.id OR NEW.store_id IS NOT OLD.store_id OR NEW.code IS NOT OLD.code
  OR NEW.name IS NOT OLD.name OR NEW.is_default IS NOT OLD.is_default
  OR NEW.is_active IS NOT OLD.is_active OR NEW.updated_at IS NOT OLD.updated_at
BEGIN
    INSERT INTO change_log(store_id,sync_cursor,table_name,record_uuid,operation,old_values_json,new_values_json)
    VALUES(NEW.store_id,
           (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id=NEW.store_id),
           'locations',NEW.id,'UPDATE',
           json_object('id',OLD.id,'store_id',OLD.store_id,'code',OLD.code,'name',OLD.name,
                       'is_default',OLD.is_default,'is_active',OLD.is_active,
                       'created_at',OLD.created_at,'updated_at',OLD.updated_at),
           json_object('id',NEW.id,'store_id',NEW.store_id,'code',NEW.code,'name',NEW.name,
                       'is_default',NEW.is_default,'is_active',NEW.is_active,
                       'created_at',NEW.created_at,'updated_at',NEW.updated_at));
END;

CREATE TRIGGER trg_locations_log_delete
AFTER DELETE ON locations
BEGIN
    INSERT INTO change_log(store_id,sync_cursor,table_name,record_uuid,operation,old_values_json)
    VALUES(OLD.store_id,
           (SELECT COALESCE(MAX(sync_cursor),0)+1 FROM change_log WHERE store_id=OLD.store_id),
           'locations',OLD.id,'DELETE',
           json_object('id',OLD.id,'store_id',OLD.store_id,'code',OLD.code,'name',OLD.name,
                       'is_default',OLD.is_default,'is_active',OLD.is_active,
                       'created_at',OLD.created_at,'updated_at',OLD.updated_at));
END;

DROP TABLE stage3_location_map;
DROP TABLE stage3_old_locations;

COMMIT;
PRAGMA foreign_keys = ON;
