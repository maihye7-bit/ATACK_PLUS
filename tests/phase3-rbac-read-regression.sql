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
      ('stock','inventory.read'),('stock_movements','inventory.read'),
      ('customer_ledgers','customers.payments'),('customer_payments','customers.payments'),
      ('payment_allocations','customers.payments'),('supplier_ledger','suppliers.payments'),
      ('supplier_payments','suppliers.payments'),('expenses','reports.financial'),
      ('revenues','reports.financial'),('processed_operations','sync.manage'),
      ('sync_cursors','sync.manage'),('store_sync_counters','sync.manage'),
      ('change_log','sync.manage'),('sync_outbox','sync.manage'),
      ('sync_conflicts','sync.manage'),('tombstones','sync.manage'),
      ('purchase_returns','purchases.read'),('purchase_return_items','purchases.read'),
      ('stock_adjustments','inventory.read'),('inventory_batches','inventory.read'),
      ('stock_alerts','inventory.read'),('chart_of_accounts','reports.financial'),
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
        pg_get_functiondef(p.oid),
        'has_store_permission\s*\([^,]+,\s*''([^'']+)''',
        'g'
      ) AS m(matches)
     WHERE n.nspname='public'
  LOOP
    IF NOT EXISTS (SELECT 1 FROM public.permissions WHERE code=r.permission_code) THEN
      RAISE EXCEPTION 'RPC references undefined RBAC permission %',r.permission_code;
    END IF;
  END LOOP;

  -- Every SECURITY DEFINER function callable by authenticated must derive authority
  -- from the Auth identity, the active store, a permission check, or the guarded
  -- business-operation claim helper.
  FOR r IN
    SELECT p.proname,pg_get_function_identity_arguments(p.oid) AS args,
           pg_get_functiondef(p.oid) AS body
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.prosecdef
       AND has_function_privilege('authenticated',p.oid,'EXECUTE')
  LOOP
    IF r.body NOT ILIKE '%auth.uid()%'
       AND r.body NOT ILIKE '%has_store_permission%'
       AND r.body NOT ILIKE '%current_user_store_id()%'
       AND r.body NOT ILIKE '%_claim_business_operation%' THEN
      RAISE EXCEPTION 'Authenticated can execute SECURITY DEFINER RPC without an identity/store/RBAC guard: %.%(%)',
        'public',r.proname,r.args;
    END IF;
  END LOOP;

  RAISE NOTICE 'PASS: % business/sync tables have explicit restrictive read RBAC, users profile read is bounded, and report RPC permissions are defined',v_count;
END
$rbac_read_catalog$;

BEGIN;
INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 ('99100000-0000-4000-8000-000000000001','20100000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001','rbac_read_cashier','RBAC Read Cashier',TRUE),
 ('99100000-0000-4000-8000-000000000002','20100000-0000-4000-8000-000000000002',
  '10000000-0000-4000-8000-000000000001','rbac_read_stockkeeper','RBAC Read Stock Keeper',TRUE),
 ('99100000-0000-4000-8000-000000000003','20100000-0000-4000-8000-000000000003',
  '10000000-0000-4000-8000-000000000001','rbac_read_accountant','RBAC Read Accountant',TRUE)
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.user_roles(user_id,role_id)
VALUES
 ('99100000-0000-4000-8000-000000000001','cashier'),
 ('99100000-0000-4000-8000-000000000002','stock_keeper'),
 ('99100000-0000-4000-8000-000000000003','accountant')
ON CONFLICT(user_id,role_id) DO NOTHING;

SELECT set_config('request.jwt.claim.sub','20100000-0000-4000-8000-000000000001',TRUE);
SET LOCAL ROLE authenticated;
DO $cashier_reads$
DECLARE n INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.invoices WHERE id='80000000-0000-4000-8000-000000000001';
  IF n<>1 THEN RAISE EXCEPTION 'Cashier cannot read permitted sales invoice'; END IF;
  IF EXISTS(SELECT 1 FROM public.purchases) THEN RAISE EXCEPTION 'Cashier can read purchases without purchases.read'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.stock WHERE product_id='50000000-0000-4000-8000-000000000001') THEN RAISE EXCEPTION 'Cashier cannot read inventory despite inventory.read'; END IF;
  IF EXISTS(SELECT 1 FROM public.journal_entries) THEN RAISE EXCEPTION 'Cashier can read financial journals without reports.financial'; END IF;
  SELECT count(*) INTO n FROM public.users WHERE id='99100000-0000-4000-8000-000000000001';
  IF n<>1 OR EXISTS(SELECT 1 FROM public.users WHERE id='30000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Cashier own-profile read boundary is incorrect';
  END IF;
  PERFORM * FROM public.check_low_stock('10000000-0000-4000-8000-000000000001');
  PERFORM * FROM public.check_inventory_expiry('10000000-0000-4000-8000-000000000001');
  RAISE NOTICE 'PASS: cashier sees sales and own profile only; inventory reports use reports.inventory';
END
$cashier_reads$;
RESET ROLE;

SELECT set_config('request.jwt.claim.sub','20100000-0000-4000-8000-000000000002',TRUE);
SET LOCAL ROLE authenticated;
DO $stockkeeper_reads$
DECLARE n INTEGER;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.products WHERE id='50000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Stock keeper cannot read permitted products';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.purchases WHERE id='70000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Stock keeper cannot read permitted purchases';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.stock WHERE product_id='50000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Stock keeper cannot read permitted inventory';
  END IF;
  IF EXISTS(SELECT 1 FROM public.invoices) THEN
    RAISE EXCEPTION 'Stock keeper can read sales without sales.read';
  END IF;
  IF EXISTS(SELECT 1 FROM public.journal_entries) THEN
    RAISE EXCEPTION 'Stock keeper can read financial journals without reports.financial';
  END IF;
  RAISE NOTICE 'PASS: stock keeper sees products, purchases and inventory but not sales or financial journals';
END
$stockkeeper_reads$;
RESET ROLE;

SELECT set_config('request.jwt.claim.sub','20100000-0000-4000-8000-000000000003',TRUE);
SET LOCAL ROLE authenticated;
DO $accountant_reads$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.chart_of_accounts WHERE store_id='10000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Accountant cannot read permitted chart of accounts';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.general_ledger WHERE store_id='10000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Accountant cannot read permitted general ledger';
  END IF;
  IF EXISTS(SELECT 1 FROM public.stock) THEN
    RAISE EXCEPTION 'Accountant can read stock without inventory.read';
  END IF;
  IF EXISTS(SELECT 1 FROM public.chart_of_accounts WHERE account_code='SEC-B') THEN
    RAISE EXCEPTION 'Accountant read policy leaked another store chart';
  END IF;
  RAISE NOTICE 'PASS: accountant sees financial records only within own store and not inventory';
END
$accountant_reads$;
RESET ROLE;
ROLLBACK;
