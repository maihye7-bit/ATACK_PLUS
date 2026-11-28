import pathlib
import sqlite3

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIGRATION = (ROOT / "docs" / "SQLITE_MIGRATION_PHASE3_WAREHOUSES.sql").read_text(encoding="utf-8")

def uuid(n):
    return f"a3000000-0000-4000-8000-{n:012d}"

db = sqlite3.connect(":memory:")
db.execute("PRAGMA foreign_keys=ON")
db.executescript(f"""
CREATE TABLE stores(id TEXT PRIMARY KEY,name TEXT NOT NULL);
CREATE TABLE products(id TEXT PRIMARY KEY,store_id TEXT NOT NULL,FOREIGN KEY(store_id) REFERENCES stores(id));
CREATE TABLE users(id TEXT PRIMARY KEY,store_id TEXT NOT NULL,FOREIGN KEY(store_id) REFERENCES stores(id));
CREATE TABLE units(id TEXT PRIMARY KEY);
CREATE TABLE locations(
  id TEXT PRIMARY KEY CHECK(id IN ('main','warehouse','storage')),
  name TEXT NOT NULL,is_default INTEGER DEFAULT 0
);
CREATE TABLE stock(
  id TEXT PRIMARY KEY,product_id TEXT NOT NULL,location_id TEXT NOT NULL DEFAULT 'main',
  quantity NUMERIC NOT NULL DEFAULT 0,reserved_quantity NUMERIC NOT NULL DEFAULT 0,last_updated TEXT DEFAULT (datetime('now')),
  FOREIGN KEY(product_id) REFERENCES products(id),
  FOREIGN KEY(location_id) REFERENCES locations(id)
);
CREATE TABLE stock_movements(
  id TEXT PRIMARY KEY,product_id TEXT NOT NULL,location_id TEXT NOT NULL DEFAULT 'main',
  type TEXT NOT NULL,quantity NUMERIC NOT NULL,unit_id TEXT NOT NULL,
  cost_per_unit NUMERIC NOT NULL,total_value NUMERIC NOT NULL,reference_id TEXT,reference_type TEXT,reason TEXT,user_id TEXT NOT NULL,created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY(product_id) REFERENCES products(id),
  FOREIGN KEY(user_id) REFERENCES users(id)
);
CREATE TABLE stock_adjustments(
  id TEXT PRIMARY KEY,store_id TEXT NOT NULL,product_id TEXT NOT NULL,
  adjustment_number TEXT NOT NULL,adjustment_type TEXT NOT NULL,reason TEXT NOT NULL,
  quantity NUMERIC NOT NULL,unit_id TEXT NOT NULL,cost_per_unit NUMERIC NOT NULL,
  total_value NUMERIC NOT NULL,created_by TEXT NOT NULL,created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY(store_id) REFERENCES stores(id),
  FOREIGN KEY(product_id) REFERENCES products(id),
  FOREIGN KEY(created_by) REFERENCES users(id)
);
CREATE TABLE change_log(
  id INTEGER PRIMARY KEY AUTOINCREMENT,store_id TEXT NOT NULL,sync_cursor INTEGER NOT NULL,
  table_name TEXT NOT NULL,record_uuid TEXT NOT NULL,operation TEXT NOT NULL,
  old_values_json TEXT,new_values_json TEXT,created_at TEXT DEFAULT (datetime('now'))
);
INSERT INTO stores VALUES ('{uuid(1)}','Store A'),('{uuid(2)}','Store B');
INSERT INTO users VALUES ('{uuid(11)}','{uuid(1)}'),('{uuid(12)}','{uuid(2)}');
INSERT INTO products VALUES ('{uuid(21)}','{uuid(1)}'),('{uuid(22)}','{uuid(2)}');
INSERT INTO units VALUES ('pcs');
INSERT INTO locations VALUES
 ('main','Main',1),('warehouse','Warehouse',0),('storage','Storage',0);
INSERT INTO stock(id,product_id,location_id,quantity,reserved_quantity) VALUES
 ('{uuid(31)}','{uuid(21)}','main',12,2),
 ('{uuid(32)}','{uuid(22)}','warehouse',7,1);
INSERT INTO stock_movements(id,product_id,location_id,type,quantity,unit_id,cost_per_unit,total_value,user_id) VALUES
 ('{uuid(41)}','{uuid(21)}','main','IN',12,'pcs',10,120,'{uuid(11)}'),
 ('{uuid(42)}','{uuid(22)}','warehouse','IN',7,'pcs',20,140,'{uuid(12)}');
INSERT INTO stock_adjustments(id,store_id,product_id,adjustment_number,adjustment_type,reason,quantity,unit_id,cost_per_unit,total_value,created_by)
VALUES ('{uuid(51)}','{uuid(1)}','{uuid(21)}','ST3-ADJ-1','INCREASE','legacy fixture',2,'pcs',10,20,'{uuid(11)}');
""")
db.commit()

db.executescript(MIGRATION)
db.execute("PRAGMA foreign_keys=ON")
# D-016 upgrade removes the legacy non-negative CHECK while requiring
# operation/device/reason evidence before a local stock balance can go below zero.
NEGATIVE_MIGRATION = (ROOT / "docs" / "SQLITE_MIGRATION_PHASE3_NEGATIVE_STOCK.sql").read_text(encoding="utf-8")
# Capture the exact SQLite statement/trigger context if an upgrade fails.
migration_trace = []
db.set_trace_callback(lambda statement: migration_trace.append(statement))
try:
    db.executescript(NEGATIVE_MIGRATION)
except sqlite3.Error:
    print("SQLite negative-stock migration trace (last 25 statements):")
    for statement in migration_trace[-25:]:
        print(f"  {statement}")
    raise
finally:
    db.set_trace_callback(None)
db.execute("PRAGMA foreign_keys=ON")

# Legacy rows are remapped to independent per-store UUID locations without losing balances.
locations = db.execute("SELECT store_id,code,id FROM locations ORDER BY store_id,code").fetchall()
assert len(locations) == 6, locations
assert len({row[2] for row in locations}) == 6, locations
assert all(len(row[2]) == 36 for row in locations), locations
assert db.execute("SELECT COUNT(*) FROM locations WHERE store_id=? AND code='main' AND is_default=1", (uuid(1),)).fetchone()[0] == 1
assert db.execute("""
 SELECT COUNT(*) FROM stock s JOIN locations l ON l.id=s.location_id AND l.store_id=s.store_id
 WHERE s.product_id=? AND s.store_id=? AND l.code='main' AND s.quantity=12 AND s.reserved_quantity=2
""", (uuid(21),uuid(1))).fetchone()[0] == 1
assert db.execute("""
 SELECT COUNT(*) FROM stock_movements m JOIN locations l ON l.id=m.location_id AND l.store_id=m.store_id
 WHERE m.product_id=? AND m.store_id=? AND l.code='main'
""", (uuid(21),uuid(1))).fetchone()[0] == 1
assert db.execute("""
 SELECT COUNT(*) FROM stock_adjustments a JOIN locations l ON l.id=a.location_id AND l.store_id=a.store_id
 WHERE a.id=? AND l.code='main'
""", (uuid(51),)).fetchone()[0] == 1

# A newly created store receives its own default locations, and those rows enter Change Log.
new_store = uuid(3)
db.execute("INSERT INTO stores(id,name) VALUES (?,?)", (new_store,"Store C"))
assert db.execute("SELECT COUNT(*) FROM locations WHERE store_id=?", (new_store,)).fetchone()[0] == 3
assert db.execute("SELECT COUNT(*) FROM change_log WHERE store_id=? AND table_name='locations' AND operation='INSERT'", (new_store,)).fetchone()[0] == 3

# Cross-store and inactive warehouse writes are rejected for all inventory entities.
store_a_main = db.execute("SELECT id FROM locations WHERE store_id=? AND code='main'", (uuid(1),)).fetchone()[0]
store_b_main = db.execute("SELECT id FROM locations WHERE store_id=? AND code='main'", (uuid(2),)).fetchone()[0]
for statement, params in [
    ("INSERT INTO stock(id,product_id,location_id,quantity,reserved_quantity,store_id) VALUES (?,?,?,?,?,?)",
     (uuid(61),uuid(21),store_b_main,1,0,uuid(1))),
    ("INSERT INTO stock_movements(id,product_id,location_id,type,quantity,unit_id,cost_per_unit,total_value,user_id,store_id) VALUES (?,?,?,?,?,?,?,?,?,?)",
     (uuid(62),uuid(21),store_b_main,"IN",1,"pcs",10,10,uuid(11),uuid(1))),
    ("INSERT INTO stock_adjustments(id,store_id,product_id,adjustment_number,adjustment_type,reason,quantity,unit_id,cost_per_unit,total_value,created_by,location_id) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
     (uuid(63),uuid(1),uuid(21),"ST3-ADJ-X","INCREASE","cross store",1,"pcs",10,10,uuid(11),store_b_main)),
]:
    try:
        db.execute(statement, params)
        raise AssertionError("Cross-store inventory write unexpectedly succeeded")
    except sqlite3.IntegrityError:
        pass

db.execute("UPDATE locations SET is_active=0 WHERE id=? AND store_id=?", (store_a_main,uuid(1)))
try:
    db.execute("INSERT INTO stock(id,product_id,location_id,quantity,reserved_quantity,store_id) VALUES (?,?,?,?,?,?)",
               (uuid(64),uuid(21),store_a_main,1,0,uuid(1)))
    raise AssertionError("Inactive warehouse accepted a stock write")
except sqlite3.IntegrityError:
    pass

# Negative balances are rejected without an authorized movement.
store_a_main = db.execute("SELECT id FROM locations WHERE store_id=? AND code='main'", (uuid(1),)).fetchone()[0]
db.execute("UPDATE locations SET is_active=1 WHERE id=? AND store_id=?", (store_a_main,uuid(1)))
db.execute("UPDATE stock SET quantity=0,reserved_quantity=0 WHERE product_id=? AND store_id=?",
           (uuid(21),uuid(1)))
try:
    db.execute("UPDATE stock SET quantity=-1 WHERE product_id=? AND store_id=?",
               (uuid(21),uuid(1)))
    raise AssertionError("Negative stock was accepted without an authorization movement")
except sqlite3.IntegrityError:
    pass

operation = uuid(71)
device = uuid(72)
db.execute(
    """INSERT INTO stock_movements
       (id,product_id,store_id,location_id,type,quantity,unit_id,cost_per_unit,total_value,
        reference_id,reference_type,reason,user_id,operation_id,device_id,shortage_quantity,negative_stock_authorized)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
    (uuid(73),uuid(21),uuid(1),store_a_main,"OUT",1,"pcs",10,10,None,None,
     "approved offline negative sale",uuid(11),operation,device,1,1)
)
db.execute("UPDATE stock SET quantity=-1,last_operation_id=? WHERE product_id=? AND store_id=?",
           (operation,uuid(21),uuid(1)))
assert db.execute("SELECT quantity,last_operation_id FROM stock WHERE product_id=? AND store_id=?",
                  (uuid(21),uuid(1))).fetchone() == (-1,operation)

# Movement and adjustment evidence cannot claim authorization without a device.
try:
    db.execute(
        """INSERT INTO stock_movements
           (id,product_id,store_id,location_id,type,quantity,unit_id,cost_per_unit,total_value,
            reason,user_id,operation_id,shortage_quantity,negative_stock_authorized)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (uuid(74),uuid(21),uuid(1),store_a_main,"OUT",1,"pcs",10,10,
         "missing device",uuid(11),uuid(75),1,1)
    )
    raise AssertionError("Negative movement without device id was accepted")
except sqlite3.IntegrityError:
    pass

db.execute(
    """INSERT INTO stock_adjustments
       (id,store_id,product_id,adjustment_number,adjustment_type,reason,quantity,unit_id,
        cost_per_unit,total_value,created_by,location_id,operation_id,device_id,
        shortage_quantity,negative_stock_authorized)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
    (uuid(76),uuid(1),uuid(21),"ST3-NEG-1","DECREASE","approved offline adjustment",1,
     "pcs",10,10,uuid(11),store_a_main,uuid(77),device,1,1)
)
assert db.execute(
    "SELECT COUNT(*) FROM change_log WHERE table_name='stock_movements' AND operation='INSERT' AND record_uuid=?",
    (uuid(73),)
).fetchone()[0] == 1
assert db.execute(
    "SELECT COUNT(*) FROM change_log WHERE table_name='stock_adjustments' AND operation='INSERT' AND record_uuid=?",
    (uuid(76),)
).fetchone()[0] == 1

fk_errors = db.execute("PRAGMA foreign_key_check").fetchall()
assert not fk_errors, fk_errors
print("PASS: SQLite warehouse remap and D-016 negative stock evidence/atomic guard regression")
db.close()
