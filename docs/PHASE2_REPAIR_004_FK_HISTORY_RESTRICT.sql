-- ATACK PLUS — Stage 2 / Part 3-D2
-- Protect committed business/financial history from FK-driven physical deletion.
-- Intended for an explicitly approved migration window only. CI applies this to
-- its disposable PostgreSQL service; this file is NOT auto-applied to live DBs.
BEGIN;

SELECT pg_advisory_xact_lock(hashtext('ATACK_PLUS_STAGE2_PART3_D2_FK_RESTRICT'));

CREATE TEMP TABLE _stage2_fk_restrict_plan (
  source_table text NOT NULL,
  constraint_name text NOT NULL,
  source_columns text[] NOT NULL,
  referenced_table text NOT NULL,
  referenced_columns text[] NOT NULL,
  PRIMARY KEY(source_table,constraint_name)
) ON COMMIT DROP;

INSERT INTO _stage2_fk_restrict_plan VALUES
('invoice_items','invoice_items_invoice_id_fkey',ARRAY['invoice_id'],'invoices',ARRAY['id']),
('payment_allocations','payment_allocations_invoice_id_fkey',ARRAY['invoice_id'],'invoices',ARRAY['id']),
('payment_allocations','payment_allocations_payment_id_fkey',ARRAY['payment_id'],'customer_payments',ARRAY['id']),
('product_units','product_units_product_id_fkey',ARRAY['product_id'],'products',ARRAY['id']),
('stock','stock_product_id_fkey',ARRAY['product_id'],'products',ARRAY['id']),
('purchase_items','purchase_items_product_id_fkey',ARRAY['product_id'],'products',ARRAY['id']),
('purchase_items','purchase_items_purchase_id_fkey',ARRAY['purchase_id'],'purchases',ARRAY['id']),
('purchase_return_items','purchase_return_items_product_id_fkey',ARRAY['product_id'],'products',ARRAY['id']),
('purchase_return_items','purchase_return_items_return_id_fkey',ARRAY['return_id'],'purchase_returns',ARRAY['id']),
('return_items','return_items_return_id_fkey',ARRAY['return_id'],'sales_returns',ARRAY['id']),
('supplier_ledger','supplier_ledger_supplier_id_fkey',ARRAY['supplier_id'],'suppliers',ARRAY['id']),
('supplier_payments','supplier_payments_supplier_id_fkey',ARRAY['supplier_id'],'suppliers',ARRAY['id']),
('purchase_receipt_items','purchase_receipt_items_receipt_id_fkey',ARRAY['receipt_id'],'purchase_receipts',ARRAY['id']),
('purchase_receipt_items','fk_purchase_receipt_items_receipt_store',ARRAY['receipt_id','store_id'],'purchase_receipts',ARRAY['id','store_id']),
('purchase_closure_items','purchase_closure_items_closure_id_fkey',ARRAY['closure_id'],'purchase_closures',ARRAY['id']),
('purchase_closure_items','fk_purchase_closure_items_closure_store',ARRAY['closure_id','store_id'],'purchase_closures',ARRAY['id','store_id']);

-- These ten lifecycle constraints are deliberately outside this business-history
-- migration. Their continued CASCADE behavior is not authorization to purge a store/user.
CREATE TEMP TABLE _stage2_fk_exclusions (
  source_table text NOT NULL,
  constraint_name text NOT NULL,
  referenced_table text NOT NULL,
  PRIMARY KEY(source_table,constraint_name)
) ON COMMIT DROP;

INSERT INTO _stage2_fk_exclusions VALUES
('brands','brands_store_id_fkey','stores'),
('categories','categories_store_id_fkey','stores'),
('customers','customers_store_id_fkey','stores'),
('devices','devices_store_id_fkey','stores'),
('products','products_store_id_fkey','stores'),
('suppliers','suppliers_store_id_fkey','stores'),
('users','users_store_id_fkey','stores'),
('user_roles','user_roles_user_id_fkey','users'),
('store_sync_counters','store_sync_counters_store_id_fkey','stores'),
('locations','fk_locations_store','stores');

-- Serialize DDL against concurrent writers. Stable alphabetical order reduces
-- the chance of lock-order deadlocks with other maintenance operations.
LOCK TABLE public.invoice_items, public.payment_allocations, public.product_units,
  public.purchase_closure_items, public.purchase_items, public.purchase_receipt_items,
  public.purchase_return_items, public.return_items, public.stock,
  public.supplier_ledger, public.supplier_payments
IN ACCESS EXCLUSIVE MODE;

DO $stage2_fk_preflight$
DECLARE
  e record;
  v_actual record;
  v_count integer := 0;
BEGIN
  FOR e IN SELECT * FROM pg_temp._stage2_fk_restrict_plan
           ORDER BY source_table,constraint_name
  LOOP
    SELECT
      c.confrelid,
      c.confdeltype,
      c.confupdtype,
      c.condeferrable,
      c.condeferred,
      c.convalidated,
      c.conislocal,
      c.coninhcount,
      (SELECT array_agg(a.attname::text ORDER BY k.ordinality)
         FROM unnest(c.conkey) WITH ORDINALITY k(attnum,ordinality)
         JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum) AS source_columns,
      (SELECT array_agg(a.attname::text ORDER BY k.ordinality)
         FROM unnest(c.confkey) WITH ORDINALITY k(attnum,ordinality)
         JOIN pg_attribute a ON a.attrelid=c.confrelid AND a.attnum=k.attnum) AS referenced_columns
    INTO v_actual
    FROM pg_constraint c
    WHERE c.contype='f'
      AND c.conrelid=format('public.%I',e.source_table)::regclass
      AND c.conname=e.constraint_name;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Required FK %.% is missing',e.source_table,e.constraint_name;
    END IF;
    IF v_actual.confrelid IS DISTINCT FROM format('public.%I',e.referenced_table)::regclass
       OR v_actual.source_columns IS DISTINCT FROM e.source_columns
       OR v_actual.referenced_columns IS DISTINCT FROM e.referenced_columns
       OR v_actual.confdeltype <> 'c'
       OR v_actual.confupdtype <> 'a'
       OR v_actual.condeferrable
       OR v_actual.condeferred
       OR NOT v_actual.convalidated
       OR NOT v_actual.conislocal
       OR v_actual.coninhcount <> 0 THEN
      RAISE EXCEPTION 'FK %.% drifted from approved precondition; refusing migration',
        e.source_table,e.constraint_name;
    END IF;
    v_count := v_count + 1;
  END LOOP;

  IF v_count <> 16 THEN
    RAISE EXCEPTION 'Expected 16 business FKs, found %',v_count;
  END IF;

  -- The lifecycle exclusions must still exist exactly as expected and remain CASCADE.
  FOR e IN SELECT * FROM pg_temp._stage2_fk_exclusions
           ORDER BY source_table,constraint_name
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint c
      WHERE c.contype='f'
        AND c.conrelid=format('public.%I',e.source_table)::regclass
        AND c.conname=e.constraint_name
        AND c.confrelid=format('public.%I',e.referenced_table)::regclass
        AND c.confdeltype='c'
        AND c.convalidated
    ) THEN
      RAISE EXCEPTION 'Excluded lifecycle FK %.% is missing or drifted',
        e.source_table,e.constraint_name;
    END IF;
  END LOOP;

  IF (SELECT count(*) FROM pg_constraint c
      JOIN pg_namespace n ON n.oid=c.connamespace
      WHERE c.contype='f' AND n.nspname='public' AND c.confdeltype='c') <> 26 THEN
    RAISE EXCEPTION 'Unexpected initial CASCADE FK inventory; expected 26 (25 legacy plus store-scoped locations)';
  END IF;
END;
$stage2_fk_preflight$;

-- Replace only the 16 approved delete actions. Column mappings, referenced keys,
-- ON UPDATE NO ACTION, validation and non-deferrable behavior are preserved.
DO $stage2_fk_alter$
DECLARE
  e record;
  v_source_cols text;
  v_reference_cols text;
BEGIN
  FOR e IN SELECT * FROM pg_temp._stage2_fk_restrict_plan
           ORDER BY source_table,constraint_name
  LOOP
    SELECT string_agg(format('%I',x),', ' ORDER BY ord)
      INTO v_source_cols
      FROM unnest(e.source_columns) WITH ORDINALITY AS a(x,ord);
    SELECT string_agg(format('%I',x),', ' ORDER BY ord)
      INTO v_reference_cols
      FROM unnest(e.referenced_columns) WITH ORDINALITY AS a(x,ord);

    EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I',
                   e.source_table,e.constraint_name);
    EXECUTE format(
      'ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (%s) REFERENCES public.%I (%s) ON UPDATE NO ACTION ON DELETE RESTRICT',
      e.source_table,e.constraint_name,v_source_cols,e.referenced_table,v_reference_cols
    );
  END LOOP;
END;
$stage2_fk_alter$;

DO $stage2_fk_postflight$
DECLARE
  e record;
  v_count integer := 0;
BEGIN
  FOR e IN SELECT * FROM pg_temp._stage2_fk_restrict_plan
           ORDER BY source_table,constraint_name
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint c
      WHERE c.contype='f'
        AND c.conrelid=format('public.%I',e.source_table)::regclass
        AND c.conname=e.constraint_name
        AND c.confrelid=format('public.%I',e.referenced_table)::regclass
        AND c.confdeltype='r'
        AND c.confupdtype='a'
        AND c.convalidated
        AND NOT c.condeferrable
        AND NOT c.condeferred
    ) THEN
      RAISE EXCEPTION 'Postflight failed for FK %.%',e.source_table,e.constraint_name;
    END IF;
    v_count := v_count + 1;
  END LOOP;

  IF v_count <> 16 THEN RAISE EXCEPTION 'Only % of 16 FKs were verified',v_count; END IF;
  IF (SELECT count(*) FROM pg_constraint c
      JOIN pg_namespace n ON n.oid=c.connamespace
      WHERE c.contype='f' AND n.nspname='public' AND c.confdeltype='c') <> 10 THEN
    RAISE EXCEPTION 'Postflight CASCADE count is not the approved ten lifecycle exclusions';
  END IF;
END;
$stage2_fk_postflight$;

COMMIT;
