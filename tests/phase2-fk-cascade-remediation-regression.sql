-- ATACK PLUS — Stage 2 / Part 3-D2 regression
-- Run only after PHASE2_REPAIR_004_FK_HISTORY_RESTRICT.sql on disposable CI DB.
BEGIN;

DO $fk_contract$
DECLARE
  e record;
  v_actual record;
  v_join text;
  v_join_delete text;
  v_has_child boolean;
  v_blocked boolean;
  v_delete_sql text;
  v_checked integer := 0;
  v_behavior_checked integer := 0;
BEGIN
  FOR e IN
    SELECT * FROM (VALUES
      ('invoice_items','invoice_items_invoice_id_fkey',ARRAY['invoice_id']::text[],'invoices',ARRAY['id']::text[]),
      ('payment_allocations','payment_allocations_invoice_id_fkey',ARRAY['invoice_id']::text[],'invoices',ARRAY['id']::text[]),
      ('payment_allocations','payment_allocations_payment_id_fkey',ARRAY['payment_id']::text[],'customer_payments',ARRAY['id']::text[]),
      ('product_units','product_units_product_id_fkey',ARRAY['product_id']::text[],'products',ARRAY['id']::text[]),
      ('stock','stock_product_id_fkey',ARRAY['product_id']::text[],'products',ARRAY['id']::text[]),
      ('purchase_items','purchase_items_product_id_fkey',ARRAY['product_id']::text[],'products',ARRAY['id']::text[]),
      ('purchase_items','purchase_items_purchase_id_fkey',ARRAY['purchase_id']::text[],'purchases',ARRAY['id']::text[]),
      ('purchase_return_items','purchase_return_items_product_id_fkey',ARRAY['product_id']::text[],'products',ARRAY['id']::text[]),
      ('purchase_return_items','purchase_return_items_return_id_fkey',ARRAY['return_id']::text[],'purchase_returns',ARRAY['id']::text[]),
      ('return_items','return_items_return_id_fkey',ARRAY['return_id']::text[],'sales_returns',ARRAY['id']::text[]),
      ('supplier_ledger','supplier_ledger_supplier_id_fkey',ARRAY['supplier_id']::text[],'suppliers',ARRAY['id']::text[]),
      ('supplier_payments','supplier_payments_supplier_id_fkey',ARRAY['supplier_id']::text[],'suppliers',ARRAY['id']::text[]),
      ('purchase_receipt_items','purchase_receipt_items_receipt_id_fkey',ARRAY['receipt_id']::text[],'purchase_receipts',ARRAY['id']::text[]),
      ('purchase_receipt_items','fk_purchase_receipt_items_receipt_store',ARRAY['receipt_id','store_id']::text[],'purchase_receipts',ARRAY['id','store_id']::text[]),
      ('purchase_closure_items','purchase_closure_items_closure_id_fkey',ARRAY['closure_id']::text[],'purchase_closures',ARRAY['id']::text[]),
      ('purchase_closure_items','fk_purchase_closure_items_closure_store',ARRAY['closure_id','store_id']::text[],'purchase_closures',ARRAY['id','store_id']::text[])
    ) AS x(source_table,constraint_name,source_columns,referenced_table,referenced_columns)
  LOOP
    SELECT
      c.confrelid,c.confdeltype,c.confupdtype,c.convalidated,
      c.condeferrable,c.condeferred,
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
      RAISE EXCEPTION 'FK is missing: %.%',e.source_table,e.constraint_name;
    END IF;
    IF v_actual.confrelid IS DISTINCT FROM format('public.%I',e.referenced_table)::regclass
       OR v_actual.source_columns IS DISTINCT FROM e.source_columns
       OR v_actual.referenced_columns IS DISTINCT FROM e.referenced_columns
       OR v_actual.confdeltype<>'r' OR v_actual.confupdtype<>'a'
       OR NOT v_actual.convalidated OR v_actual.condeferrable OR v_actual.condeferred THEN
      RAISE EXCEPTION 'FK contract failed: %.%',e.source_table,e.constraint_name;
    END IF;
    v_checked:=v_checked+1;

    -- Exercise real FK enforcement wherever the regression fixtures contain a
    -- dependent row. Each attempted parent DELETE runs in a PL/pgSQL subtransaction;
    -- the expected FK violation rolls back that DELETE and preserves all rows.
    SELECT string_agg(format('p.%I=c.%I',e.referenced_columns[k.ordinality],
                             e.source_columns[k.ordinality]),' AND ' ORDER BY k.ordinality)
      INTO v_join
      FROM generate_subscripts(e.source_columns,1) AS k(ordinality);

    EXECUTE format(
      'SELECT EXISTS (SELECT 1 FROM public.%I p JOIN public.%I c ON %s)',
      e.referenced_table,e.source_table,v_join
    ) INTO v_has_child;

    IF v_has_child THEN
      -- The subquery uses p2, not the outer DELETE alias p.
      v_join_delete:=replace(v_join,'p.','p2.');
      v_delete_sql:=format(
        'DELETE FROM public.%I p WHERE p.ctid=(SELECT p2.ctid FROM public.%I p2 JOIN public.%I c ON %s LIMIT 1)',
        e.referenced_table,e.referenced_table,e.source_table,v_join_delete
      );
      v_blocked:=FALSE;
      BEGIN
        EXECUTE v_delete_sql;
      EXCEPTION WHEN foreign_key_violation THEN
        v_blocked:=TRUE;
      END;
      IF NOT v_blocked THEN
        RAISE EXCEPTION 'Parent DELETE was not blocked for FK %.%',
          e.source_table,e.constraint_name;
      END IF;
      v_behavior_checked:=v_behavior_checked+1;
    ELSE
      RAISE NOTICE 'Behavior fixture skipped (no dependent row): %.%',
        e.source_table,e.constraint_name;
    END IF;
  END LOOP;

  IF v_checked<>16 THEN RAISE EXCEPTION 'Expected 16 FK contracts; checked %',v_checked; END IF;

  -- The nine lifecycle exclusions remain untouched and are still explicitly
  -- represented as CASCADE; they require their own separately approved lifecycle design.
  IF (SELECT count(*) FROM pg_constraint c
      JOIN pg_namespace n ON n.oid=c.connamespace
      WHERE n.nspname='public' AND c.contype='f' AND c.confdeltype='c')<>9 THEN
    RAISE EXCEPTION 'Expected exactly nine excluded lifecycle CASCADE constraints';
  END IF;

  RAISE NOTICE 'Verified 16 RESTRICT contracts; real dependent-row DELETE checks executed for % constraints',
    v_behavior_checked;
END;
$fk_contract$;

ROLLBACK;
