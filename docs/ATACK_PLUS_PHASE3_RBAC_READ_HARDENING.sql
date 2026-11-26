-- Phase 3 RBAC read hardening: keep store isolation and enforce least-privilege reads.
BEGIN;

DO $rbac_read_policies$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('categories','products.read'),
      ('brands','products.read'),
      ('products','products.read'),
      ('product_units','products.read'),
      ('customers','customers.read'),
      ('suppliers','suppliers.read'),
      ('purchases','purchases.read'),
      ('purchase_items','purchases.read'),
      ('invoices','sales.read'),
      ('invoice_items','sales.read'),
      ('sales_returns','sales.read'),
      ('return_items','sales.read'),
      ('stock','inventory.read'),
      ('stock_movements','inventory.read'),
      ('customer_ledgers','customers.payments'),
      ('customer_payments','customers.payments'),
      ('payment_allocations','customers.payments'),
      ('supplier_ledger','suppliers.payments'),
      ('supplier_payments','suppliers.payments'),
      ('expenses','reports.financial'),
      ('revenues','reports.financial'),
      ('processed_operations','sync.manage'),
      ('sync_cursors','sync.manage'),
      ('store_sync_counters','sync.manage'),
      ('change_log','sync.manage'),
      ('sync_outbox','sync.manage'),
      ('sync_conflicts','sync.manage'),
      ('tombstones','sync.manage'),
      ('purchase_returns','purchases.read'),
      ('purchase_return_items','purchases.read'),
      ('stock_adjustments','inventory.adjust'),
      ('stock_movements','inventory.adjust'),
      ('inventory_batches','inventory.adjust'),
      ('stock_alerts','inventory.adjust'),
      ('chart_of_accounts','reports.financial'),
      ('general_ledger','reports.financial'),
      ('journal_entries','reports.financial'),
      ('purchase_receipts','purchases.read'),
      ('purchase_receipt_items','purchases.read'),
      ('purchase_closures','purchases.read'),
      ('purchase_closure_items','purchases.read'),
      ('purchase_amendments','purchases.read')
    ) AS x(table_name, permission_code)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='public' AND c.relname=r.table_name
         AND c.relkind IN ('r','p') AND c.relrowsecurity
    ) THEN
      RAISE EXCEPTION 'Cannot apply read RBAC: RLS is not enabled on public.%',r.table_name;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname='public' AND tablename=r.table_name
         AND cmd IN ('SELECT','ALL') AND permissive='PERMISSIVE'
    ) THEN
      RAISE EXCEPTION 'Cannot apply read RBAC: no store-scoped permissive SELECT policy on public.%',r.table_name;
    END IF;

    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',
                   'rbac_read_'||r.table_name,r.table_name);
    EXECUTE format('GRANT SELECT ON TABLE public.%I TO authenticated',r.table_name);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR SELECT TO authenticated USING (public.has_store_permission(public.current_user_store_id(), %L))',
      'rbac_read_'||r.table_name,r.table_name,r.permission_code
    );
  END LOOP;

  -- A member may read only the store row resolved from their Auth identity.
  -- The permissive store_self_access policy in Phase 1 supplies the RLS filter.
  GRANT SELECT ON TABLE public.stores TO authenticated;

  -- Users can always read their own profile; listing other users requires users.manage.
  GRANT SELECT ON TABLE public.users TO authenticated;
  DROP POLICY IF EXISTS rbac_read_users ON public.users;
  CREATE POLICY rbac_read_users ON public.users
    AS RESTRICTIVE FOR SELECT TO authenticated
    USING (
      auth.uid() IS NOT NULL
      AND (
        auth_user_id=auth.uid()
        OR public.has_store_permission(public.current_user_store_id(),'users.manage')
      )
    );

  -- Sales data is private to its seller. The owner (users.manage) can see
  -- every seller's invoices and their dependent line/return records.
  DROP POLICY IF EXISTS rbac_read_invoices ON public.invoices;
  CREATE POLICY rbac_read_invoices ON public.invoices
    AS RESTRICTIVE FOR SELECT TO authenticated
    USING (
      public.has_store_permission(public.current_user_store_id(),'sales.read')
      AND (
        public.has_store_permission(public.current_user_store_id(),'users.manage')
        OR created_by = (
          SELECT u.id FROM public.users u
           WHERE u.auth_user_id=auth.uid()
             AND u.store_id=public.current_user_store_id()
             AND u.is_active=TRUE
           LIMIT 1
        )
      )
    );

  DROP POLICY IF EXISTS rbac_read_invoice_items ON public.invoice_items;
  CREATE POLICY rbac_read_invoice_items ON public.invoice_items
    AS RESTRICTIVE FOR SELECT TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.invoices i
         WHERE i.id=invoice_items.invoice_id
           AND public.has_store_permission(i.store_id,'sales.read')
           AND (
             public.has_store_permission(i.store_id,'users.manage')
             OR i.created_by = (
               SELECT u.id FROM public.users u
                WHERE u.auth_user_id=auth.uid()
                  AND u.store_id=i.store_id AND u.is_active=TRUE
                LIMIT 1
             )
           )
      )
    );

  DROP POLICY IF EXISTS rbac_read_sales_returns ON public.sales_returns;
  CREATE POLICY rbac_read_sales_returns ON public.sales_returns
    AS RESTRICTIVE FOR SELECT TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.invoices i
         WHERE i.id=sales_returns.original_invoice_id
           AND i.store_id=sales_returns.store_id
           AND public.has_store_permission(i.store_id,'sales.read')
           AND (
             public.has_store_permission(i.store_id,'users.manage')
             OR i.created_by = (
               SELECT u.id FROM public.users u
                WHERE u.auth_user_id=auth.uid()
                  AND u.store_id=i.store_id AND u.is_active=TRUE
                LIMIT 1
             )
           )
      )
    );

  DROP POLICY IF EXISTS rbac_read_return_items ON public.return_items;
  CREATE POLICY rbac_read_return_items ON public.return_items
    AS RESTRICTIVE FOR SELECT TO authenticated
    USING (
      EXISTS (
        SELECT 1
          FROM public.sales_returns sr
          JOIN public.invoices i ON i.id=sr.original_invoice_id
         WHERE sr.id=return_items.return_id
           AND i.store_id=sr.store_id
           AND public.has_store_permission(i.store_id,'sales.read')
           AND (
             public.has_store_permission(i.store_id,'users.manage')
             OR i.created_by = (
               SELECT u.id FROM public.users u
                WHERE u.auth_user_id=auth.uid()
                  AND u.store_id=i.store_id AND u.is_active=TRUE
                LIMIT 1
             )
           )
      )
    );

  -- Seller-specific financial activity: a seller can read only payment and
  -- ledger rows created by that seller; the owner retains store-wide visibility.
  DROP POLICY IF EXISTS rbac_read_customer_ledgers ON public.customer_ledgers;
  CREATE POLICY rbac_read_customer_ledgers ON public.customer_ledgers
    AS RESTRICTIVE FOR SELECT TO authenticated
    USING (
      public.has_store_permission(public.current_user_store_id(),'customers.payments')
      AND (
        public.has_store_permission(public.current_user_store_id(),'users.manage')
        OR created_by = (
          SELECT u.id FROM public.users u
           WHERE u.auth_user_id=auth.uid()
             AND u.store_id=public.current_user_store_id()
             AND u.is_active=TRUE
           LIMIT 1
        )
      )
    );

  DROP POLICY IF EXISTS rbac_read_customer_payments ON public.customer_payments;
  CREATE POLICY rbac_read_customer_payments ON public.customer_payments
    AS RESTRICTIVE FOR SELECT TO authenticated
    USING (
      public.has_store_permission(public.current_user_store_id(),'customers.payments')
      AND (
        public.has_store_permission(public.current_user_store_id(),'users.manage')
        OR created_by = (
          SELECT u.id FROM public.users u
           WHERE u.auth_user_id=auth.uid()
             AND u.store_id=public.current_user_store_id()
             AND u.is_active=TRUE
           LIMIT 1
        )
      )
    );

  -- An individual seller sees only allocations from their own receipts to
  -- their own invoices. This avoids exposing another seller's invoice/payment
  -- relationship through the allocation table.
  DROP POLICY IF EXISTS rbac_read_payment_allocations ON public.payment_allocations;
  CREATE POLICY rbac_read_payment_allocations ON public.payment_allocations
    AS RESTRICTIVE FOR SELECT TO authenticated
    USING (
      EXISTS (
        SELECT 1
          FROM public.customer_payments cp
          JOIN public.customers c ON c.id=cp.customer_id
          JOIN public.invoices i ON i.id=payment_allocations.invoice_id
         WHERE cp.id=payment_allocations.payment_id
           AND i.customer_id=cp.customer_id
           AND i.store_id=c.store_id
           AND c.store_id=public.current_user_store_id()
           AND public.has_store_permission(c.store_id,'customers.payments')
           AND (
             public.has_store_permission(c.store_id,'users.manage')
             OR (
               cp.created_by = (
                 SELECT u.id FROM public.users u
                  WHERE u.auth_user_id=auth.uid()
                    AND u.store_id=c.store_id AND u.is_active=TRUE
                  LIMIT 1
               )
               AND i.created_by = (
                 SELECT u.id FROM public.users u
                  WHERE u.auth_user_id=auth.uid()
                    AND u.store_id=c.store_id AND u.is_active=TRUE
                  LIMIT 1
               )
             )
           )
      )
    );

END
$rbac_read_policies$;

COMMIT;
