-- Phase 3 security hardening: authenticated users may read only their own
-- store's rows, but all writes to derived/financial tables must go through
-- SECURITY DEFINER RPCs that enforce RBAC and operation-level invariants.
BEGIN;

DO $security$
DECLARE
  t TEXT;
  v_read_expr TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'purchase_returns','purchase_return_items','stock_adjustments',
    'inventory_batches','stock_alerts','chart_of_accounts',
    'journal_entries','general_ledger',
    'purchase_receipts','purchase_receipt_items',
    'purchase_closures','purchase_closure_items',
    'purchase_amendments'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);

    IF t='purchase_return_items' THEN
      v_read_expr := 'EXISTS (SELECT 1 FROM public.purchase_returns pr WHERE pr.id = purchase_return_items.return_id AND pr.store_id = public.current_user_store_id())';
    ELSE
      v_read_expr := format('store_id = public.current_user_store_id()');
    END IF;

    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',t||'_store_isolation',t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',t||'_store_read',t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',t||'_store_select',t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (%s)',t||'_store_select',t,v_read_expr);

    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I','sec_deny_direct_insert_'||t,t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I','sec_deny_direct_update_'||t,t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I','sec_deny_direct_delete_'||t,t);
    EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false)','sec_deny_direct_insert_'||t,t);
    EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false)','sec_deny_direct_update_'||t,t);
    EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR DELETE TO authenticated USING (false)','sec_deny_direct_delete_'||t,t);

    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM anon, authenticated',t);
    EXECUTE format('GRANT SELECT ON TABLE public.%I TO authenticated',t);
  END LOOP;
END
$security$;

COMMIT;
