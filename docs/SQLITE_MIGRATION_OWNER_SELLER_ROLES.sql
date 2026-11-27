-- ATACK PLUS offline SQLite role consolidation.
-- Existing active users with legacy assignments must be reviewed and remapped
-- explicitly before this migration can continue. No user is silently promoted.
BEGIN IMMEDIATE;

CREATE TEMP TABLE _owner_seller_role_guard (
  ok INTEGER NOT NULL CHECK(ok=1)
);

INSERT INTO _owner_seller_role_guard(ok)
SELECT CASE WHEN EXISTS (
  SELECT 1
    FROM user_roles ur
    JOIN users u ON u.id=ur.user_id
   WHERE u.is_active=1
     AND ur.role_id IN ('admin','accountant','stock_keeper')
) THEN 0 ELSE 1 END;

DROP TABLE _owner_seller_role_guard;

DELETE FROM role_permissions
 WHERE role_id IN ('admin','accountant','stock_keeper');

UPDATE roles
   SET name='بائع',
       description='المفتاح التقني المعتمد لحساب البائع؛ صلاحيات بيع محدودة ببياناته',
       is_active=1
 WHERE id='cashier';

UPDATE roles
   SET is_active=0,
       description=COALESCE(description,'') ||
         CASE WHEN COALESCE(description,'')='' THEN '' ELSE ' — ' END ||
         'دور قديم غير معتمد؛ معطل ولا يمنح أي صلاحيات'
 WHERE id IN ('admin','accountant','stock_keeper');

COMMIT;
