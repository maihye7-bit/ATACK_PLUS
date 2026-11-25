-- Phase 3 security regression tests.
-- Runs as the real PostgreSQL authenticated role; auth.uid() is the CI shim.
INSERT INTO public.stores(id,name)
VALUES ('10000000-0000-4000-8000-000000000002','Phase 3 Security Store B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES ('30000000-0000-4000-8000-000000000002',
        '20000000-0000-4000-8000-000000000002',
        '10000000-0000-4000-8000-000000000002',
        'phase3_security_user_b','Phase 3 Security User B',TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.user_roles(user_id,role_id)
VALUES ('30000000-0000-4000-8000-000000000002','owner')
ON CONFLICT DO NOTHING;

INSERT INTO public.chart_of_accounts(id,store_id,account_code,account_name,account_type)
VALUES
 ('90000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','SEC-A','Security Store A','ASSET'),
 ('90000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','SEC-B','Security Store B','ASSET')
ON CONFLICT (id) DO NOTHING;

DO $privilege_audit$
DECLARE
  t TEXT;
  p TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'purchase_returns','purchase_return_items','stock_adjustments',
    'inventory_batches','stock_alerts','chart_of_accounts',
    'journal_entries','general_ledger',
    'purchase_receipts','purchase_receipt_items',
    'purchase_closures','purchase_closure_items',
    'purchase_amendments'
  ] LOOP
    IF NOT has_table_privilege('authenticated',format('public.%I',t),'SELECT') THEN
      RAISE EXCEPTION 'authenticated lacks required SELECT on %',t;
    END IF;
    IF EXISTS (
      SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid=c.relnamespace
        CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl,acldefault('r',c.relowner))) a
       WHERE n.nspname='public' AND c.relname=t AND a.grantee=0
         AND a.privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE')
    ) THEN
      RAISE EXCEPTION 'PUBLIC retains direct-write ACL on %',t;
    END IF;
    FOREACH p IN ARRAY ARRAY['INSERT','UPDATE','DELETE','TRUNCATE'] LOOP
      IF has_table_privilege('authenticated',format('public.%I',t),p) THEN
        RAISE EXCEPTION 'authenticated unexpectedly has % privilege on %',p,t;
      END IF;
    END LOOP;
    IF NOT (SELECT c.relrowsecurity FROM pg_class c
             JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE n.nspname='public' AND c.relname=t) THEN
      RAISE EXCEPTION 'RLS is not enabled on %',t;
    END IF;
    IF (SELECT count(*) FROM pg_policies
         WHERE schemaname='public' AND tablename=t
           AND permissive='RESTRICTIVE'
           AND policyname IN ('sec_deny_direct_insert_'||t,
                              'sec_deny_direct_update_'||t,
                              'sec_deny_direct_delete_'||t)) <> 3 THEN
      RAISE EXCEPTION 'Restrictive direct-write policies are incomplete on %',t;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS: Phase 3 table grants, RLS enablement and restrictive write-deny policies';
END
$privilege_audit$;

BEGIN;
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',TRUE);
SET LOCAL ROLE authenticated;

DO $store_isolation$
DECLARE
  v_visible INTEGER;
  v_store UUID;
  v_denied BOOLEAN:=FALSE;
BEGIN
  v_store:=public.current_user_store_id();
  IF v_store IS DISTINCT FROM '10000000-0000-4000-8000-000000000001'::UUID THEN
    RAISE EXCEPTION 'Authenticated identity resolved to wrong store: %',v_store;
  END IF;

  SELECT count(*) INTO v_visible FROM public.chart_of_accounts
   WHERE account_code IN ('SEC-A','SEC-B');
  IF v_visible<>1 OR EXISTS(SELECT 1 FROM public.chart_of_accounts WHERE account_code='SEC-B') THEN
    RAISE EXCEPTION 'Cross-store RLS leak: visible security accounts %',v_visible;
  END IF;

  -- The authenticated identity must see exactly its own store and no users
  -- belonging to the second store. The owner may list users in its own store.
  SELECT count(*) INTO v_visible FROM public.stores;
  IF v_visible<>1 OR NOT EXISTS (
    SELECT 1 FROM public.stores
     WHERE id='10000000-0000-4000-8000-000000000001'::uuid
  ) THEN
    RAISE EXCEPTION 'Stores RLS isolation failed: visible store count %',v_visible;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.users
     WHERE store_id='10000000-0000-4000-8000-000000000002'::uuid
  ) THEN
    RAISE EXCEPTION 'Users RLS leaked a profile from another store';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.users
     WHERE store_id='10000000-0000-4000-8000-000000000001'::uuid
  ) THEN
    RAISE EXCEPTION 'Authenticated owner cannot read users in its own store';
  END IF;

  BEGIN
    INSERT INTO public.chart_of_accounts(store_id,account_code,account_name,account_type)
    VALUES(v_store,'SEC-DIRECT','Unauthorized direct write','ASSET');
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Direct chart_of_accounts INSERT was not denied'; END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM public.process_stock_adjustment(
      '10000000-0000-4000-8000-000000000002',
      '60000000-0000-4000-8000-000000000099',
      '{"id":"76000000-0000-4000-8000-000000000099","adjustment_number":"CROSS-STORE","product_id":"50000000-0000-4000-8000-000000000001","adjustment_type":"INCREASE","reason":"cross-store security test","quantity":1,"unit_id":"pcs"}'::jsonb
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied:=TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Cross-store stock adjustment RPC was not denied'; END IF;

  RAISE NOTICE 'PASS: authenticated store isolation, direct-write denial and cross-store RPC denial';
END
$store_isolation$;

ROLLBACK;
