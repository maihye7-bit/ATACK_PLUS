-- Regression tests for store isolation and role-based SELECT visibility.
DO $rbac_read_catalog$
DECLARE
  r RECORD;
  v_count INTEGER:=0;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('categories','products.read'),('brands','products.read'),('products','products.read'),
      ('product_units','products.read'),('customers','customers.read'),('suppliers','suppliers.read'),
      ('purchases','purchases.read'),('purchase_items','purchases.read'),
      ('invoices','sales.read'),('invoice_items','sales.read'),
      ('sales_returns','sales.read'),('return_items','sales.read'),
      ('stock','inventory.read'),('stock_movements','inventory.adjust'),
      ('customer_ledgers','customers.payments'),('customer_payments','customers.payments'),
      ('payment_allocations','customers.payments'),('supplier_ledger','suppliers.payments'),
      ('supplier_payments','suppliers.payments'),('expenses','reports.financial'),
      ('revenues','reports.financial'),('processed_operations','sync.manage'),
      ('sync_cursors','sync.manage'),('store_sync_counters','sync.manage'),
      ('change_log','sync.manage'),('sync_outbox','sync.manage'),
      ('sync_conflicts','sync.manage'),('tombstones','sync.manage'),
      ('purchase_returns','purchases.read'),('purchase_return_items','purchases.read'),
      ('stock_adjustments','inventory.adjust'),
      ('inventory_batches','inventory.adjust'),('stock_alerts','inventory.adjust'),('chart_of_accounts','reports.financial'),
      ('general_ledger','reports.financial'),('journal_entries','reports.financial'),
      ('purchase_receipts','purchases.read'),('purchase_receipt_items','purchases.read'),
      ('purchase_closures','purchases.read'),('purchase_closure_items','purchases.read'),
      ('purchase_amendments','purchases.read')
    ) AS x(table_name, permission_code)
  LOOP
    IF NOT has_table_privilege('authenticated',format('public.%I',r.table_name),'SELECT') THEN
      RAISE EXCEPTION 'authenticated lacks SELECT ACL on public.%',r.table_name;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname='public' AND tablename=r.table_name
         AND policyname='rbac_read_'||r.table_name
         AND cmd='SELECT' AND permissive='RESTRICTIVE'
         AND roles @> ARRAY['authenticated']::name[]
    ) THEN
      RAISE EXCEPTION 'Missing restrictive read RBAC policy on public.%',r.table_name;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.permissions WHERE code=r.permission_code) THEN
      RAISE EXCEPTION 'Read policy references undefined permission %',r.permission_code;
    END IF;
    v_count:=v_count+1;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
      AND tablename='users' AND policyname='rbac_read_users'
      AND cmd='SELECT' AND permissive='RESTRICTIVE') THEN
    RAISE EXCEPTION 'Users self-profile / users.manage read policy is missing';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
      AND tablename='customer_ledgers' AND policyname='rbac_read_customer_ledgers'
      AND cmd='SELECT' AND permissive='RESTRICTIVE')
     OR NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
      AND tablename='customer_payments' AND policyname='rbac_read_customer_payments'
      AND cmd='SELECT' AND permissive='RESTRICTIVE')
     OR NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
      AND tablename='payment_allocations' AND policyname='rbac_read_payment_allocations'
      AND cmd='SELECT' AND permissive='RESTRICTIVE') THEN
    RAISE EXCEPTION 'Seller-specific customer payment, ledger or allocation read policies are missing';
  END IF;

  IF NOT has_table_privilege('authenticated','public.stores','SELECT') THEN
    RAISE EXCEPTION 'authenticated lacks SELECT ACL on public.stores';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
      AND tablename='stores' AND policyname='store_self_access'
      AND cmd='ALL' AND permissive='PERMISSIVE') THEN
    RAISE EXCEPTION 'Stores self-access RLS policy is missing';
  END IF;

  IF position('reports.view' in pg_get_functiondef('public.check_low_stock(uuid)'::regprocedure))>0
     OR position('reports.view' in pg_get_functiondef('public.check_inventory_expiry(uuid)'::regprocedure))>0 THEN
    RAISE EXCEPTION 'Inventory report RPC references an undefined reports.view permission';
  END IF;
  -- Every static permission referenced by a SECURITY DEFINER RPC must exist in the RBAC catalog.
  FOR r IN
    SELECT DISTINCT (m.matches)[1] AS permission_code
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace
      CROSS JOIN LATERAL regexp_matches(
        p.prosrc,
        'has_store_permission\s*\([^,]+,\s*''([^'']+)''',
        'g'
      ) AS m(matches)
     WHERE n.nspname='public'
  LOOP
    IF NOT EXISTS (SELECT 1 FROM public.permissions WHERE code=r.permission_code) THEN
      RAISE EXCEPTION 'RPC references undefined RBAC permission %',r.permission_code;
    END IF;
  END LOOP;

  -- The explicit function permission references above are catalog-checked;
  -- callable entry points are exercised by the business, sync, user and audit regressions.

  RAISE NOTICE 'PASS: % business/sync tables have explicit restrictive read RBAC, users profile read is bounded, and report RPC permissions are defined',v_count;
END
$rbac_read_catalog$;


BEGIN;
-- The operational model is one store owner/superadmin plus individual sellers.
-- The current database role key 'cashier' supplies the seller's sales permissions;
-- it does not imply a separate cashier job in the business model.
INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 ('99100000-0000-4000-8000-000000000001','20100000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001','rbac_read_seller','RBAC Read Seller',TRUE),
 ('99100000-0000-4000-8000-000000000002','20100000-0000-4000-8000-000000000002',
  '10000000-0000-4000-8000-000000000001','rbac_read_owner','RBAC Read Owner',TRUE)
ON CONFLICT(id) DO NOTHING;

-- Create one owner invoice and one seller invoice in the same store.
INSERT INTO public.invoices(
 id,store_id,invoice_number,type,invoice_date,total_amount,created_by
) VALUES
 (
  '88000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001',
  'RBAC-OWNER-ALL-880001','SALE',NOW(),0,
  '30000000-0000-4000-8000-000000000001'
 ),
 (
  '88000000-0000-4000-8000-000000000002',
  '10000000-0000-4000-8000-000000000001',
  'RBAC-SELLER-OWN-880002','SALE',NOW(),0,
  '99100000-0000-4000-8000-000000000001'
 )
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.user_roles(user_id,role_id)
VALUES
 ('99100000-0000-4000-8000-000000000001','cashier'),
 ('99100000-0000-4000-8000-000000000002','owner')
ON CONFLICT(user_id,role_id) DO NOTHING;

SELECT set_config('request.jwt.claim.sub','20100000-0000-4000-8000-000000000001',TRUE);
SET LOCAL ROLE authenticated;
DO $seller_reads$
DECLARE n INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.stores;
  IF n<>1 OR NOT EXISTS(SELECT 1 FROM public.stores WHERE id='10000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Seller must see only the store resolved from their Auth identity';
  END IF;
  SELECT count(*) INTO n FROM public.invoices;
  IF n<>1 OR NOT EXISTS(
      SELECT 1 FROM public.invoices WHERE id='88000000-0000-4000-8000-000000000002'
    ) OR EXISTS(
      SELECT 1 FROM public.invoices WHERE id='88000000-0000-4000-8000-000000000001'
    ) THEN
    RAISE EXCEPTION 'Seller invoice visibility must contain only invoices created by that seller';
  END IF;
  IF EXISTS(SELECT 1 FROM public.invoice_items ii
      JOIN public.invoices i ON i.id=ii.invoice_id
      WHERE i.created_by<>'99100000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Seller can read another seller''s invoice items';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_returns sr
      JOIN public.invoices i ON i.id=sr.original_invoice_id
      WHERE i.created_by<>'99100000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Seller can read another seller''s returns';
  END IF;
  IF EXISTS(SELECT 1 FROM public.purchases) THEN RAISE EXCEPTION 'Seller can read purchases without delegated purchase permissions'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.stock WHERE product_id='50000000-0000-4000-8000-000000000001') THEN RAISE EXCEPTION 'Seller cannot read inventory needed for sales'; END IF;
  IF EXISTS(SELECT 1 FROM public.journal_entries) THEN RAISE EXCEPTION 'Seller can read owner-only financial journals'; END IF;
  SELECT count(*) INTO n FROM public.users WHERE id='99100000-0000-4000-8000-000000000001';
  IF n<>1 OR EXISTS(SELECT 1 FROM public.users WHERE id='99100000-0000-4000-8000-000000000002')
     OR EXISTS(SELECT 1 FROM public.users WHERE id='30000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Seller profile visibility is not restricted to the caller''s own profile';
  END IF;
  PERFORM * FROM public.check_low_stock('10000000-0000-4000-8000-000000000001');
  PERFORM * FROM public.check_inventory_expiry('10000000-0000-4000-8000-000000000001');
  RAISE NOTICE 'PASS: seller sees only their own invoices, related returns, required product/stock data and own profile';
END
$seller_reads$;
RESET ROLE;

SELECT set_config('request.jwt.claim.sub','20100000-0000-4000-8000-000000000002',TRUE);
SET LOCAL ROLE authenticated;
DO $owner_reads$
DECLARE n INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.stores;
  IF n<>1 OR NOT EXISTS(SELECT 1 FROM public.stores WHERE id='10000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Owner must see only its own store';
  END IF;
  SELECT count(*) INTO n FROM public.invoices;
  IF n<2
     OR NOT EXISTS(SELECT 1 FROM public.invoices WHERE id='88000000-0000-4000-8000-000000000001')
     OR NOT EXISTS(SELECT 1 FROM public.invoices WHERE id='88000000-0000-4000-8000-000000000002') THEN
    RAISE EXCEPTION 'Owner must see invoices from all sellers in the store';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.purchases WHERE id='70000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Owner cannot read store purchases';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.stock WHERE product_id='50000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Owner cannot read store inventory';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.chart_of_accounts WHERE store_id='10000000-0000-4000-8000-000000000001')
     OR NOT EXISTS(SELECT 1 FROM public.general_ledger WHERE store_id='10000000-0000-4000-8000-000000000001')
     OR NOT EXISTS(SELECT 1 FROM public.journal_entries WHERE store_id='10000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Owner cannot read complete store accounting records';
  END IF;
  SELECT count(*) INTO n FROM public.users WHERE store_id='10000000-0000-4000-8000-000000000001';
  IF n<2 THEN RAISE EXCEPTION 'Owner cannot see store users including sellers'; END IF;
  IF EXISTS(SELECT 1 FROM public.users WHERE store_id<>'10000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Owner read another store''s user profiles';
  END IF;
  RAISE NOTICE 'PASS: owner sees all sellers'' invoices, purchases, inventory, accounting and seller profiles with cross-store isolation';
END
$owner_reads$;
RESET ROLE;

ROLLBACK;
