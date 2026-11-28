-- Complete catalog-level security regression for every public table and SECURITY DEFINER function.
DO $security_catalog_test$
DECLARE
  r RECORD;
  v_table TEXT;
  v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count
    FROM pg_class c
    JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relkind IN ('r','p');
  IF v_count = 0 THEN RAISE EXCEPTION 'No public tables found'; END IF;

  FOR r IN
    SELECT c.relname, c.relrowsecurity
      FROM pg_class c
      JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind IN ('r','p')
  LOOP
    IF NOT r.relrowsecurity THEN
      RAISE EXCEPTION 'RLS is disabled on public table %', r.relname;
    END IF;
    IF has_table_privilege('anon', format('public.%I',r.relname), 'INSERT')
       OR has_table_privilege('anon', format('public.%I',r.relname), 'UPDATE')
       OR has_table_privilege('anon', format('public.%I',r.relname), 'DELETE')
       OR has_table_privilege('anon', format('public.%I',r.relname), 'TRUNCATE') THEN
      RAISE EXCEPTION 'anon has direct write privilege on public.%', r.relname;
    END IF;
  END LOOP;

  -- Financial, inventory-derived, identity, audit and synchronization state
  -- must not be directly mutated through PostgREST by authenticated clients.
  FOREACH v_table IN ARRAY ARRAY[
    'invoices','invoice_items','purchases','purchase_items','stock','stock_movements',
    'customer_ledgers','customer_payments','payment_allocations','supplier_ledger',
    'supplier_payments','sales_returns','return_items','expenses','revenues',
    'purchase_returns','purchase_return_items','stock_adjustments','inventory_batches',
    'stock_alerts','chart_of_accounts','journal_entries','general_ledger',
    'purchase_receipts','purchase_receipt_items','purchase_closures','purchase_closure_items',
    'purchase_amendments','processed_operations','change_log','sync_cursors',
    'store_sync_counters','sync_outbox','sync_conflicts','tombstones','sync_log',
    'audit_logs','user_roles','users','roles','permissions','role_permissions','units','locations',
    -- Master records use the dedicated soft-delete RPC; REST DELETE is never allowed.
    'categories','brands','products','customers','suppliers'
  ] LOOP
    IF has_table_privilege('authenticated', format('public.%I',v_table), 'INSERT')
       OR has_table_privilege('authenticated', format('public.%I',v_table), 'UPDATE')
       OR has_table_privilege('authenticated', format('public.%I',v_table), 'DELETE')
       OR has_table_privilege('authenticated', format('public.%I',v_table), 'TRUNCATE') THEN
      RAISE EXCEPTION 'authenticated has direct write privilege on protected table public.%', v_table;
    END IF;
  END LOOP;

  -- Every SECURITY DEFINER function must have a fixed safe search_path and
  -- must not be executable by PUBLIC or anon through implicit/default grants.
  FOR r IN
    SELECT p.oid, p.proname, pg_get_function_identity_arguments(p.oid) AS args,
           p.proconfig, p.proacl, p.proowner
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.prosecdef
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM unnest(COALESCE(r.proconfig, ARRAY[]::text[])) cfg
       WHERE cfg LIKE 'search_path=public, pg_temp%'
    ) THEN
      RAISE EXCEPTION 'SECURITY DEFINER function %.%(%) has no hardened search_path',
        'public',r.proname,r.args;
    END IF;

    IF EXISTS (
      SELECT 1
        FROM aclexplode(COALESCE(r.proacl, acldefault('f',r.proowner))) a
       WHERE a.grantee=0 AND a.privilege_type='EXECUTE'
    ) THEN
      RAISE EXCEPTION 'PUBLIC can execute SECURITY DEFINER function public.%(%)',
        r.proname,r.args;
    END IF;

    IF has_function_privilege('anon',r.oid,'EXECUTE') THEN
      RAISE EXCEPTION 'anon can execute SECURITY DEFINER function public.%(%)',
        r.proname,r.args;
    END IF;
  END LOOP;

  -- Master-data soft deletion is RPC-only: confirm the restrictive DELETE
  -- deny policy exists in addition to the missing direct table privilege.
  FOREACH v_table IN ARRAY ARRAY['categories','brands','products','customers','suppliers'] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname='public' AND tablename=v_table
         AND policyname='sec_deny_direct_delete_'||v_table
         AND permissive='RESTRICTIVE' AND cmd='DELETE'
    ) THEN
      RAISE EXCEPTION 'Missing restrictive direct DELETE denial for public.%',v_table;
    END IF;
  END LOOP;

  RAISE NOTICE 'PASS: all % public tables have RLS; anon has no table writes; protected tables are read-only to authenticated; all SECURITY DEFINER functions have safe search_path and no PUBLIC/anon execute',v_count;
END
$security_catalog_test$;
