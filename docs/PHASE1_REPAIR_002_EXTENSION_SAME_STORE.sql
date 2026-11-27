-- Phase 1 Repair 002: same-store integrity for Phase 3 business extensions.
-- Apply after Phase 3 returns, purchase receiving/amendments/return-link and stock-adjustment SQL.
-- Existing rows are validated by PostgreSQL when composite FKs are added; any cross-store
-- legacy relationship aborts this transaction without rewriting business data.

BEGIN;

DO $precondition$
DECLARE
  v_required TEXT[] := ARRAY[
    'purchase_returns','purchase_return_items','stock_adjustments','inventory_batches','stock_alerts',
    'chart_of_accounts','general_ledger','journal_entries','purchase_receipts','purchase_receipt_items',
    'purchase_closures','purchase_closure_items','purchase_amendments'
  ];
  v_table TEXT;
BEGIN
  FOREACH v_table IN ARRAY v_required LOOP
    IF to_regclass('public.' || v_table) IS NULL THEN
      RAISE EXCEPTION 'Required Phase 3 table public.% is missing', v_table;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public'
      AND table_name='return_items' AND column_name='invoice_item_id') THEN
    RAISE EXCEPTION 'return_items.invoice_item_id is missing; apply business return repair first';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public'
      AND table_name='purchase_return_items' AND column_name='purchase_receipt_item_id') THEN
    RAISE EXCEPTION 'purchase_return_items.purchase_receipt_item_id is missing; apply receipt-link repair first';
  END IF;
END
$precondition$;

-- Composite unique keys required by same-store foreign keys.
CREATE UNIQUE INDEX IF NOT EXISTS uq_products_id_store_repair ON public.products(id,store_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_purchases_id_store_repair ON public.purchases(id,store_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_purchase_receipts_id_store_repair ON public.purchase_receipts(id,store_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_purchase_closures_id_store_repair ON public.purchase_closures(id,store_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_chart_accounts_id_store_repair ON public.chart_of_accounts(id,store_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_journal_entries_id_store_repair ON public.journal_entries(id,store_id);

-- Store-scoped parent references: preserve the existing single-column FKs and add
-- stronger composite FKs. The constraints validate existing rows before commit.
DO $same_store_fks$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.stock_adjustments'::regclass AND conname='fk_stock_adjustments_product_store') THEN
    ALTER TABLE public.stock_adjustments ADD CONSTRAINT fk_stock_adjustments_product_store
      FOREIGN KEY(product_id,store_id) REFERENCES public.products(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.stock_adjustments'::regclass AND conname='fk_stock_adjustments_creator_store') THEN
    ALTER TABLE public.stock_adjustments ADD CONSTRAINT fk_stock_adjustments_creator_store
      FOREIGN KEY(created_by,store_id) REFERENCES public.users(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.inventory_batches'::regclass AND conname='fk_inventory_batches_product_store') THEN
    ALTER TABLE public.inventory_batches ADD CONSTRAINT fk_inventory_batches_product_store
      FOREIGN KEY(product_id,store_id) REFERENCES public.products(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.stock_alerts'::regclass AND conname='fk_stock_alerts_product_store') THEN
    ALTER TABLE public.stock_alerts ADD CONSTRAINT fk_stock_alerts_product_store
      FOREIGN KEY(product_id,store_id) REFERENCES public.products(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.stock_alerts'::regclass AND conname='fk_stock_alerts_acknowledger_store') THEN
    ALTER TABLE public.stock_alerts ADD CONSTRAINT fk_stock_alerts_acknowledger_store
      FOREIGN KEY(acknowledged_by,store_id) REFERENCES public.users(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.purchase_returns'::regclass AND conname='fk_purchase_returns_purchase_store') THEN
    ALTER TABLE public.purchase_returns ADD CONSTRAINT fk_purchase_returns_purchase_store
      FOREIGN KEY(original_purchase_id,store_id) REFERENCES public.purchases(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.purchase_returns'::regclass AND conname='fk_purchase_returns_creator_store') THEN
    ALTER TABLE public.purchase_returns ADD CONSTRAINT fk_purchase_returns_creator_store
      FOREIGN KEY(created_by,store_id) REFERENCES public.users(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.chart_of_accounts'::regclass AND conname='fk_chart_accounts_parent_store') THEN
    ALTER TABLE public.chart_of_accounts ADD CONSTRAINT fk_chart_accounts_parent_store
      FOREIGN KEY(parent_id,store_id) REFERENCES public.chart_of_accounts(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.journal_entries'::regclass AND conname='fk_journal_entries_poster_store') THEN
    ALTER TABLE public.journal_entries ADD CONSTRAINT fk_journal_entries_poster_store
      FOREIGN KEY(posted_by,store_id) REFERENCES public.users(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.general_ledger'::regclass AND conname='fk_general_ledger_journal_store') THEN
    ALTER TABLE public.general_ledger ADD CONSTRAINT fk_general_ledger_journal_store
      FOREIGN KEY(journal_entry_id,store_id) REFERENCES public.journal_entries(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.general_ledger'::regclass AND conname='fk_general_ledger_account_store') THEN
    ALTER TABLE public.general_ledger ADD CONSTRAINT fk_general_ledger_account_store
      FOREIGN KEY(account_id,store_id) REFERENCES public.chart_of_accounts(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.general_ledger'::regclass AND conname='fk_general_ledger_creator_store') THEN
    ALTER TABLE public.general_ledger ADD CONSTRAINT fk_general_ledger_creator_store
      FOREIGN KEY(created_by,store_id) REFERENCES public.users(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.purchase_receipts'::regclass AND conname='fk_purchase_receipts_purchase_store') THEN
    ALTER TABLE public.purchase_receipts ADD CONSTRAINT fk_purchase_receipts_purchase_store
      FOREIGN KEY(purchase_id,store_id) REFERENCES public.purchases(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.purchase_receipts'::regclass AND conname='fk_purchase_receipts_receiver_store') THEN
    ALTER TABLE public.purchase_receipts ADD CONSTRAINT fk_purchase_receipts_receiver_store
      FOREIGN KEY(received_by,store_id) REFERENCES public.users(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.purchase_receipts'::regclass AND conname='fk_purchase_receipts_approver_store') THEN
    ALTER TABLE public.purchase_receipts ADD CONSTRAINT fk_purchase_receipts_approver_store
      FOREIGN KEY(approved_by,store_id) REFERENCES public.users(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.purchase_receipt_items'::regclass AND conname='fk_purchase_receipt_items_receipt_store') THEN
    ALTER TABLE public.purchase_receipt_items ADD CONSTRAINT fk_purchase_receipt_items_receipt_store
      FOREIGN KEY(receipt_id,store_id) REFERENCES public.purchase_receipts(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.purchase_receipt_items'::regclass AND conname='fk_purchase_receipt_items_original_product_store') THEN
    ALTER TABLE public.purchase_receipt_items ADD CONSTRAINT fk_purchase_receipt_items_original_product_store
      FOREIGN KEY(original_product_id,store_id) REFERENCES public.products(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.purchase_receipt_items'::regclass AND conname='fk_purchase_receipt_items_actual_product_store') THEN
    ALTER TABLE public.purchase_receipt_items ADD CONSTRAINT fk_purchase_receipt_items_actual_product_store
      FOREIGN KEY(actual_product_id,store_id) REFERENCES public.products(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.purchase_closures'::regclass AND conname='fk_purchase_closures_purchase_store') THEN
    ALTER TABLE public.purchase_closures ADD CONSTRAINT fk_purchase_closures_purchase_store
      FOREIGN KEY(purchase_id,store_id) REFERENCES public.purchases(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.purchase_closures'::regclass AND conname='fk_purchase_closures_actor_store') THEN
    ALTER TABLE public.purchase_closures ADD CONSTRAINT fk_purchase_closures_actor_store
      FOREIGN KEY(closed_by,store_id) REFERENCES public.users(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.purchase_closure_items'::regclass AND conname='fk_purchase_closure_items_closure_store') THEN
    ALTER TABLE public.purchase_closure_items ADD CONSTRAINT fk_purchase_closure_items_closure_store
      FOREIGN KEY(closure_id,store_id) REFERENCES public.purchase_closures(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.purchase_amendments'::regclass AND conname='fk_purchase_amendments_purchase_store') THEN
    ALTER TABLE public.purchase_amendments ADD CONSTRAINT fk_purchase_amendments_purchase_store
      FOREIGN KEY(purchase_id,store_id) REFERENCES public.purchases(id,store_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.purchase_amendments'::regclass AND conname='fk_purchase_amendments_actor_store') THEN
    ALTER TABLE public.purchase_amendments ADD CONSTRAINT fk_purchase_amendments_actor_store
      FOREIGN KEY(changed_by,store_id) REFERENCES public.users(id,store_id);
  END IF;
END
$same_store_fks$;

-- Validate relationships whose child rows do not carry store_id or whose
-- parent relation is indirect through a purchase/receipt header.
CREATE OR REPLACE FUNCTION public.validate_purchase_receipt_item_same_store()
RETURNS TRIGGER AS $$
DECLARE
  v_receipt_store UUID; v_receipt_purchase UUID;
  v_item_store UUID; v_item_purchase UUID; v_item_product UUID;
  v_original_store UUID; v_actual_store UUID;
BEGIN
  SELECT store_id,purchase_id INTO v_receipt_store,v_receipt_purchase
    FROM public.purchase_receipts WHERE id=NEW.receipt_id FOR SHARE;
  SELECT p.store_id,pi.purchase_id,pi.product_id
    INTO v_item_store,v_item_purchase,v_item_product
    FROM public.purchase_items pi JOIN public.purchases p ON p.id=pi.purchase_id
   WHERE pi.id=NEW.purchase_item_id FOR SHARE OF pi,p;
  SELECT store_id INTO v_original_store FROM public.products WHERE id=NEW.original_product_id FOR SHARE;
  SELECT store_id INTO v_actual_store FROM public.products WHERE id=NEW.actual_product_id FOR SHARE;

  IF v_receipt_store IS NULL OR v_item_store IS NULL
     OR NEW.store_id IS DISTINCT FROM v_receipt_store
     OR v_item_store IS DISTINCT FROM NEW.store_id
     OR v_item_purchase IS DISTINCT FROM v_receipt_purchase
     OR v_item_product IS DISTINCT FROM NEW.original_product_id
     OR v_original_store IS DISTINCT FROM NEW.store_id
     OR v_actual_store IS DISTINCT FROM NEW.store_id THEN
    RAISE EXCEPTION 'Purchase receipt item must match its receipt, original purchase line and store';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp;

CREATE OR REPLACE FUNCTION public.validate_purchase_closure_item_same_store()
RETURNS TRIGGER AS $$
DECLARE
  v_closure_store UUID; v_closure_purchase UUID;
  v_item_store UUID; v_item_purchase UUID;
BEGIN
  SELECT store_id,purchase_id INTO v_closure_store,v_closure_purchase
    FROM public.purchase_closures WHERE id=NEW.closure_id FOR SHARE;
  SELECT p.store_id,pi.purchase_id INTO v_item_store,v_item_purchase
    FROM public.purchase_items pi JOIN public.purchases p ON p.id=pi.purchase_id
   WHERE pi.id=NEW.purchase_item_id FOR SHARE OF pi,p;
  IF v_closure_store IS NULL OR v_item_store IS NULL
     OR NEW.store_id IS DISTINCT FROM v_closure_store
     OR v_item_store IS DISTINCT FROM NEW.store_id
     OR v_item_purchase IS DISTINCT FROM v_closure_purchase THEN
    RAISE EXCEPTION 'Purchase closure item must belong to the closure purchase and store';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp;

CREATE OR REPLACE FUNCTION public.validate_purchase_return_item_same_store()
RETURNS TRIGGER AS $$
DECLARE
  v_return_store UUID; v_original_purchase UUID;
  v_product_store UUID; v_item_store UUID; v_item_purchase UUID; v_item_product UUID;
  v_receipt_store UUID; v_receipt_purchase UUID; v_receipt_item UUID; v_receipt_product UUID;
BEGIN
  SELECT store_id,original_purchase_id INTO v_return_store,v_original_purchase
    FROM public.purchase_returns WHERE id=NEW.return_id FOR SHARE;
  SELECT store_id INTO v_product_store FROM public.products WHERE id=NEW.product_id FOR SHARE;
  IF v_return_store IS NULL OR v_product_store IS DISTINCT FROM v_return_store THEN
    RAISE EXCEPTION 'Purchase return item product and return must belong to the same store';
  END IF;

  IF NEW.purchase_item_id IS NOT NULL THEN
    SELECT p.store_id,pi.purchase_id,pi.product_id
      INTO v_item_store,v_item_purchase,v_item_product
      FROM public.purchase_items pi JOIN public.purchases p ON p.id=pi.purchase_id
     WHERE pi.id=NEW.purchase_item_id FOR SHARE OF pi,p;
    IF v_item_store IS DISTINCT FROM v_return_store
       OR v_item_purchase IS DISTINCT FROM v_original_purchase THEN
      RAISE EXCEPTION 'Purchase return item source line must belong to the original purchase and store';
    END IF;
    IF NEW.purchase_receipt_item_id IS NULL AND v_item_product IS DISTINCT FROM NEW.product_id THEN
      RAISE EXCEPTION 'Purchase return product must match its original purchase line without a receipt link';
    END IF;
  END IF;

  IF NEW.purchase_receipt_item_id IS NOT NULL THEN
    SELECT pr.store_id,pr.purchase_id,pri.purchase_item_id,pri.actual_product_id
      INTO v_receipt_store,v_receipt_purchase,v_receipt_item,v_receipt_product
      FROM public.purchase_receipt_items pri
      JOIN public.purchase_receipts pr ON pr.id=pri.receipt_id
     WHERE pri.id=NEW.purchase_receipt_item_id FOR SHARE OF pri,pr;
    IF v_receipt_store IS DISTINCT FROM v_return_store
       OR v_receipt_purchase IS DISTINCT FROM v_original_purchase
       OR v_receipt_product IS DISTINCT FROM NEW.product_id
       OR (NEW.purchase_item_id IS NOT NULL AND v_receipt_item IS DISTINCT FROM NEW.purchase_item_id) THEN
      RAISE EXCEPTION 'Purchase return receipt link must belong to the original purchase, product and store';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp;

CREATE OR REPLACE FUNCTION public.validate_return_item_source_same_store()
RETURNS TRIGGER AS $$
DECLARE
  v_return_store UUID; v_original_invoice UUID;
  v_line_invoice UUID; v_line_product UUID;
BEGIN
  IF NEW.invoice_item_id IS NULL THEN RETURN NEW; END IF;
  SELECT store_id,original_invoice_id INTO v_return_store,v_original_invoice
    FROM public.sales_returns WHERE id=NEW.return_id FOR SHARE;
  SELECT invoice_id,product_id INTO v_line_invoice,v_line_product
    FROM public.invoice_items WHERE id=NEW.invoice_item_id FOR SHARE;
  IF v_return_store IS NULL OR v_line_invoice IS DISTINCT FROM v_original_invoice
     OR v_line_product IS DISTINCT FROM NEW.product_id THEN
    RAISE EXCEPTION 'Sales return item must reference the matching original invoice line and product';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp;

CREATE OR REPLACE FUNCTION public.validate_ledger_reference_same_store()
RETURNS TRIGGER AS $$
DECLARE
  v_store UUID; v_related UUID; v_owner_store UUID;
  v_count INTEGER; v_store_count INTEGER;
BEGIN
  IF TG_TABLE_NAME='customer_ledgers' THEN
    IF NEW.reference_id IS NULL THEN
      IF NEW.type IN ('SALE','PAYMENT','RETURN') THEN
        RAISE EXCEPTION 'Customer ledger % entries require a source reference',NEW.type;
      END IF;
      RETURN NEW;
    END IF;
    CASE NEW.type
      WHEN 'SALE' THEN
        SELECT store_id,customer_id INTO v_store,v_related
          FROM public.invoices WHERE id=NEW.reference_id AND type='SALE' FOR SHARE;
      WHEN 'PAYMENT' THEN
        SELECT c.store_id,cp.customer_id INTO v_store,v_related
          FROM public.customer_payments cp JOIN public.customers c ON c.id=cp.customer_id
         WHERE cp.id=NEW.reference_id FOR SHARE OF cp,c;
      WHEN 'RETURN' THEN
        SELECT sr.store_id,i.customer_id INTO v_store,v_related
          FROM public.sales_returns sr JOIN public.invoices i ON i.id=sr.original_invoice_id
         WHERE sr.id=NEW.reference_id FOR SHARE OF sr,i;
      WHEN 'ADJUSTMENT' THEN
        RAISE EXCEPTION 'Customer ledger adjustment reference type is not mapped to a business source';
      ELSE
        RAISE EXCEPTION 'Unsupported customer ledger type %',NEW.type;
    END CASE;
    SELECT store_id INTO v_owner_store FROM public.customers WHERE id=NEW.customer_id FOR SHARE;
    IF v_store IS NULL OR v_store IS DISTINCT FROM v_owner_store OR v_related IS DISTINCT FROM NEW.customer_id THEN
      RAISE EXCEPTION 'Customer ledger source must belong to the same customer and store';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME='supplier_ledger' THEN
    IF NEW.reference_id IS NULL THEN
      IF NEW.type IN ('PURCHASE','PAYMENT','RETURN','ADJUSTMENT') THEN
        RAISE EXCEPTION 'Supplier ledger % entries require a source reference',NEW.type;
      END IF;
      RETURN NEW;
    END IF;
    CASE NEW.type
      WHEN 'PURCHASE' THEN
        SELECT store_id,supplier_id INTO v_store,v_related
          FROM public.purchases WHERE id=NEW.reference_id FOR SHARE;
      WHEN 'PAYMENT' THEN
        SELECT s.store_id,sp.supplier_id INTO v_store,v_related
          FROM public.supplier_payments sp JOIN public.suppliers s ON s.id=sp.supplier_id
         WHERE sp.id=NEW.reference_id FOR SHARE OF sp,s;
      WHEN 'RETURN' THEN
        SELECT pr.store_id,p.supplier_id INTO v_store,v_related
          FROM public.purchase_returns pr JOIN public.purchases p ON p.id=pr.original_purchase_id
         WHERE pr.id=NEW.reference_id FOR SHARE OF pr,p;
      WHEN 'ADJUSTMENT' THEN
        PERFORM 1 FROM public.purchase_receipts WHERE id=NEW.reference_id FOR SHARE;
        PERFORM 1 FROM public.purchase_closures WHERE id=NEW.reference_id FOR SHARE;
        PERFORM 1 FROM public.purchase_amendments WHERE id=NEW.reference_id FOR SHARE;
        SELECT COUNT(*),COUNT(DISTINCT store_id) INTO v_count,v_store_count
          FROM (
            SELECT p.store_id,p.supplier_id FROM public.purchase_receipts pr
              JOIN public.purchases p ON p.id=pr.purchase_id WHERE pr.id=NEW.reference_id
            UNION ALL
            SELECT p.store_id,p.supplier_id FROM public.purchase_closures pc
              JOIN public.purchases p ON p.id=pc.purchase_id WHERE pc.id=NEW.reference_id
            UNION ALL
            SELECT p.store_id,p.supplier_id FROM public.purchase_amendments pa
              JOIN public.purchases p ON p.id=pa.purchase_id WHERE pa.id=NEW.reference_id
          ) AS adjustment_sources;
        IF v_count<>1 OR v_store_count<>1 THEN
          RAISE EXCEPTION 'Supplier ledger adjustment source must resolve to exactly one purchase extension record';
        END IF;
        SELECT store_id,supplier_id INTO v_store,v_related
          FROM (
            SELECT p.store_id,p.supplier_id FROM public.purchase_receipts pr
              JOIN public.purchases p ON p.id=pr.purchase_id WHERE pr.id=NEW.reference_id
            UNION ALL
            SELECT p.store_id,p.supplier_id FROM public.purchase_closures pc
              JOIN public.purchases p ON p.id=pc.purchase_id WHERE pc.id=NEW.reference_id
            UNION ALL
            SELECT p.store_id,p.supplier_id FROM public.purchase_amendments pa
              JOIN public.purchases p ON p.id=pa.purchase_id WHERE pa.id=NEW.reference_id
          ) AS adjustment_sources LIMIT 1;
      ELSE
        RAISE EXCEPTION 'Unsupported supplier ledger type %',NEW.type;
    END CASE;
    SELECT store_id INTO v_owner_store FROM public.suppliers WHERE id=NEW.supplier_id FOR SHARE;
    IF v_store IS NULL OR v_store IS DISTINCT FROM v_owner_store OR v_related IS DISTINCT FROM NEW.supplier_id THEN
      RAISE EXCEPTION 'Supplier ledger source must belong to the same supplier and store';
    END IF;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Unsupported ledger table %',TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp;

CREATE OR REPLACE FUNCTION public.validate_journal_source_same_store()
RETURNS TRIGGER AS $$
DECLARE
  v_store UUID; v_count INTEGER; v_store_count INTEGER;
BEGIN
  IF (NEW.source_type IS NULL) <> (NEW.source_id IS NULL) THEN
    RAISE EXCEPTION 'Journal source type and source ID must both be NULL or both be set';
  END IF;
  IF NEW.source_type IS NULL THEN RETURN NEW; END IF;

  CASE NEW.source_type
    WHEN 'SALE' THEN
      SELECT store_id INTO v_store FROM public.invoices
       WHERE id=NEW.source_id AND type='SALE' FOR SHARE;
    WHEN 'PURCHASE' THEN
      SELECT store_id INTO v_store FROM public.purchases WHERE id=NEW.source_id FOR SHARE;
    WHEN 'EXPENSE' THEN
      SELECT store_id INTO v_store FROM public.expenses WHERE id=NEW.source_id FOR SHARE;
    WHEN 'REVENUE' THEN
      SELECT store_id INTO v_store FROM public.revenues WHERE id=NEW.source_id FOR SHARE;
    WHEN 'TRANSFER' THEN
      SELECT store_id INTO v_store FROM public.purchase_receipts WHERE id=NEW.source_id FOR SHARE;
    WHEN 'RETURN' THEN
      PERFORM 1 FROM public.sales_returns WHERE id=NEW.source_id FOR SHARE;
      PERFORM 1 FROM public.purchase_returns WHERE id=NEW.source_id FOR SHARE;
      SELECT COUNT(*),COUNT(DISTINCT store_id) INTO v_count,v_store_count
        FROM (
          SELECT store_id FROM public.sales_returns WHERE id=NEW.source_id
          UNION ALL
          SELECT store_id FROM public.purchase_returns WHERE id=NEW.source_id
        ) AS return_sources;
      IF v_count<>1 OR v_store_count<>1 THEN
        RAISE EXCEPTION 'Journal return source must resolve to exactly one return record';
      END IF;
      SELECT store_id INTO v_store FROM (
        SELECT store_id FROM public.sales_returns WHERE id=NEW.source_id
        UNION ALL
        SELECT store_id FROM public.purchase_returns WHERE id=NEW.source_id
      ) AS return_sources LIMIT 1;
    WHEN 'PAYMENT' THEN
      PERFORM 1 FROM public.customer_payments WHERE id=NEW.source_id FOR SHARE;
      PERFORM 1 FROM public.supplier_payments WHERE id=NEW.source_id FOR SHARE;
      SELECT COUNT(*),COUNT(DISTINCT store_id) INTO v_count,v_store_count
        FROM (
          SELECT c.store_id FROM public.customer_payments cp JOIN public.customers c ON c.id=cp.customer_id
           WHERE cp.id=NEW.source_id
          UNION ALL
          SELECT s.store_id FROM public.supplier_payments sp JOIN public.suppliers s ON s.id=sp.supplier_id
           WHERE sp.id=NEW.source_id
        ) AS payment_sources;
      IF v_count<>1 OR v_store_count<>1 THEN
        RAISE EXCEPTION 'Journal payment source must resolve to exactly one payment record';
      END IF;
      SELECT store_id INTO v_store FROM (
        SELECT c.store_id FROM public.customer_payments cp JOIN public.customers c ON c.id=cp.customer_id
         WHERE cp.id=NEW.source_id
        UNION ALL
        SELECT s.store_id FROM public.supplier_payments sp JOIN public.suppliers s ON s.id=sp.supplier_id
         WHERE sp.id=NEW.source_id
      ) AS payment_sources LIMIT 1;
    WHEN 'ADJUSTMENT' THEN
      PERFORM 1 FROM public.stock_adjustments WHERE id=NEW.source_id FOR SHARE;
      PERFORM 1 FROM public.purchase_amendments WHERE id=NEW.source_id FOR SHARE;
      PERFORM 1 FROM public.purchase_closures WHERE id=NEW.source_id FOR SHARE;
      SELECT COUNT(*),COUNT(DISTINCT store_id) INTO v_count,v_store_count
        FROM (
          SELECT store_id FROM public.stock_adjustments WHERE id=NEW.source_id
          UNION ALL
          SELECT store_id FROM public.purchase_amendments WHERE id=NEW.source_id
          UNION ALL
          SELECT store_id FROM public.purchase_closures WHERE id=NEW.source_id
        ) AS adjustment_sources;
      IF v_count<>1 OR v_store_count<>1 THEN
        RAISE EXCEPTION 'Journal adjustment source must resolve to exactly one adjustment record';
      END IF;
      SELECT store_id INTO v_store FROM (
        SELECT store_id FROM public.stock_adjustments WHERE id=NEW.source_id
        UNION ALL
        SELECT store_id FROM public.purchase_amendments WHERE id=NEW.source_id
        UNION ALL
        SELECT store_id FROM public.purchase_closures WHERE id=NEW.source_id
      ) AS adjustment_sources LIMIT 1;
    ELSE
      RAISE EXCEPTION 'Unsupported journal source type %',NEW.source_type;
  END CASE;

  IF v_store IS NULL OR v_store IS DISTINCT FROM NEW.store_id THEN
    RAISE EXCEPTION 'Journal source must belong to the journal store';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp;

CREATE OR REPLACE FUNCTION public.validate_general_ledger_source_same_store()
RETURNS TRIGGER AS $$
DECLARE
  v_store UUID; v_source_type TEXT; v_source_id UUID;
BEGIN
  SELECT store_id,source_type,source_id INTO v_store,v_source_type,v_source_id
    FROM public.journal_entries WHERE id=NEW.journal_entry_id FOR SHARE;
  IF v_store IS NULL OR v_store IS DISTINCT FROM NEW.store_id THEN
    RAISE EXCEPTION 'General ledger journal must belong to the ledger store';
  END IF;
  IF (NEW.reference_table IS NULL) <> (NEW.reference_id IS NULL) THEN
    RAISE EXCEPTION 'General ledger reference table and ID must both be NULL or both be set';
  END IF;
  IF v_source_type IS NOT NULL OR v_source_id IS NOT NULL THEN
    IF NEW.reference_table IS DISTINCT FROM v_source_type OR NEW.reference_id IS DISTINCT FROM v_source_id THEN
      RAISE EXCEPTION 'General ledger reference must match its journal source';
    END IF;
  ELSIF NEW.reference_table IS NOT NULL OR NEW.reference_id IS NOT NULL THEN
    RAISE EXCEPTION 'General ledger cannot add a source not present on its journal header';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp;

-- Extend parent-side ownership protection to all extension records referenced by
-- ledgers, journals, receipts, closures and returns.
CREATE OR REPLACE FUNCTION public.prevent_store_reassignment_with_dependents()
RETURNS TRIGGER AS $$
DECLARE v_has_dependents BOOLEAN := FALSE;
BEGIN
  IF NEW.store_id IS NOT DISTINCT FROM OLD.store_id THEN RETURN NEW; END IF;
  CASE TG_TABLE_NAME
    WHEN 'products' THEN
      SELECT EXISTS(SELECT 1 FROM public.stock WHERE product_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.stock_movements WHERE product_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.invoice_items WHERE product_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.purchase_items WHERE product_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.return_items WHERE product_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.product_units WHERE product_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.stock_adjustments WHERE product_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.purchase_return_items WHERE product_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.inventory_batches WHERE product_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.stock_alerts WHERE product_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.purchase_receipt_items WHERE original_product_id=OLD.id OR actual_product_id=OLD.id)
      INTO v_has_dependents;
    WHEN 'users' THEN
      SELECT EXISTS(SELECT 1 FROM public.stock_movements WHERE user_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.customer_payments WHERE created_by=OLD.id)
        OR EXISTS(SELECT 1 FROM public.customer_ledgers WHERE created_by=OLD.id)
        OR EXISTS(SELECT 1 FROM public.supplier_payments WHERE created_by=OLD.id)
        OR EXISTS(SELECT 1 FROM public.supplier_ledger WHERE created_by=OLD.id)
        OR EXISTS(SELECT 1 FROM public.user_roles WHERE user_id=OLD.id OR granted_by=OLD.id)
        OR EXISTS(SELECT 1 FROM public.stock_adjustments WHERE created_by=OLD.id)
        OR EXISTS(SELECT 1 FROM public.purchase_receipts WHERE received_by=OLD.id OR approved_by=OLD.id)
        OR EXISTS(SELECT 1 FROM public.purchase_closures WHERE closed_by=OLD.id)
        OR EXISTS(SELECT 1 FROM public.purchase_amendments WHERE changed_by=OLD.id)
        OR EXISTS(SELECT 1 FROM public.journal_entries WHERE posted_by=OLD.id)
        OR EXISTS(SELECT 1 FROM public.general_ledger WHERE created_by=OLD.id)
        OR EXISTS(SELECT 1 FROM public.stock_alerts WHERE acknowledged_by=OLD.id)
      INTO v_has_dependents;
    WHEN 'invoices' THEN
      SELECT EXISTS(SELECT 1 FROM public.invoice_items WHERE invoice_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.payment_allocations WHERE invoice_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.sales_returns WHERE original_invoice_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.stock_movements WHERE reference_type='invoice' AND reference_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.journal_entries WHERE source_type='SALE' AND source_id=OLD.id)
      INTO v_has_dependents;
    WHEN 'purchases' THEN
      SELECT EXISTS(SELECT 1 FROM public.purchase_items WHERE purchase_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.purchase_returns WHERE original_purchase_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.purchase_receipts WHERE purchase_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.purchase_closures WHERE purchase_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.purchase_amendments WHERE purchase_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.stock_movements WHERE reference_type='purchase' AND reference_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.journal_entries WHERE source_type='PURCHASE' AND source_id=OLD.id)
      INTO v_has_dependents;
    WHEN 'sales_returns' THEN
      SELECT EXISTS(SELECT 1 FROM public.return_items WHERE return_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.stock_movements WHERE reference_type='return' AND reference_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.customer_ledgers WHERE type='RETURN' AND reference_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.journal_entries WHERE source_type='RETURN' AND source_id=OLD.id)
      INTO v_has_dependents;
    WHEN 'purchase_returns' THEN
      SELECT EXISTS(SELECT 1 FROM public.purchase_return_items WHERE return_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.stock_movements WHERE reference_type='return' AND reference_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.supplier_ledger WHERE type='RETURN' AND reference_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.journal_entries WHERE source_type='RETURN' AND source_id=OLD.id)
      INTO v_has_dependents;
    WHEN 'stock_adjustments' THEN
      SELECT EXISTS(SELECT 1 FROM public.stock_movements WHERE reference_type='adjustment' AND reference_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.journal_entries WHERE source_type='ADJUSTMENT' AND source_id=OLD.id)
      INTO v_has_dependents;
    WHEN 'customers' THEN
      SELECT EXISTS(SELECT 1 FROM public.customer_payments WHERE customer_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.customer_ledgers WHERE customer_id=OLD.id)
      INTO v_has_dependents;
    WHEN 'suppliers' THEN
      SELECT EXISTS(SELECT 1 FROM public.supplier_payments WHERE supplier_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.supplier_ledger WHERE supplier_id=OLD.id)
      INTO v_has_dependents;
    WHEN 'purchase_receipts' THEN
      SELECT EXISTS(SELECT 1 FROM public.purchase_receipt_items WHERE receipt_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.supplier_ledger WHERE type='ADJUSTMENT' AND reference_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.journal_entries WHERE source_type='TRANSFER' AND source_id=OLD.id)
      INTO v_has_dependents;
    WHEN 'purchase_closures' THEN
      SELECT EXISTS(SELECT 1 FROM public.purchase_closure_items WHERE closure_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.supplier_ledger WHERE type='ADJUSTMENT' AND reference_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.journal_entries WHERE source_type='ADJUSTMENT' AND source_id=OLD.id)
      INTO v_has_dependents;
    WHEN 'purchase_amendments' THEN
      SELECT EXISTS(SELECT 1 FROM public.supplier_ledger WHERE type='ADJUSTMENT' AND reference_id=OLD.id)
        OR EXISTS(SELECT 1 FROM public.journal_entries WHERE source_type='ADJUSTMENT' AND source_id=OLD.id)
      INTO v_has_dependents;
    WHEN 'purchase_receipt_items' THEN
      SELECT EXISTS(SELECT 1 FROM public.purchase_return_items WHERE purchase_receipt_item_id=OLD.id)
      INTO v_has_dependents;
    ELSE
      RAISE EXCEPTION 'Unsupported parent table for same-store ownership guard: %',TG_TABLE_NAME;
  END CASE;
  IF v_has_dependents THEN
    RAISE EXCEPTION 'Cannot change store_id for % % while dependent business records exist',TG_TABLE_NAME,OLD.id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp;

-- Attach the extended child validation triggers.
DROP TRIGGER IF EXISTS trg_validate_purchase_receipt_item_store ON public.purchase_receipt_items;
CREATE TRIGGER trg_validate_purchase_receipt_item_store BEFORE INSERT OR UPDATE ON public.purchase_receipt_items
FOR EACH ROW EXECUTE FUNCTION public.validate_purchase_receipt_item_same_store();

DROP TRIGGER IF EXISTS trg_validate_purchase_closure_item_store ON public.purchase_closure_items;
CREATE TRIGGER trg_validate_purchase_closure_item_store BEFORE INSERT OR UPDATE ON public.purchase_closure_items
FOR EACH ROW EXECUTE FUNCTION public.validate_purchase_closure_item_same_store();

DROP TRIGGER IF EXISTS trg_validate_purchase_return_item_store ON public.purchase_return_items;
CREATE TRIGGER trg_validate_purchase_return_item_store BEFORE INSERT OR UPDATE ON public.purchase_return_items
FOR EACH ROW EXECUTE FUNCTION public.validate_purchase_return_item_same_store();

DROP TRIGGER IF EXISTS trg_validate_return_item_source_store ON public.return_items;
CREATE TRIGGER trg_validate_return_item_source_store BEFORE INSERT OR UPDATE ON public.return_items
FOR EACH ROW EXECUTE FUNCTION public.validate_return_item_source_same_store();

DROP TRIGGER IF EXISTS trg_validate_customer_ledger_source_store ON public.customer_ledgers;
CREATE TRIGGER trg_validate_customer_ledger_source_store BEFORE INSERT OR UPDATE ON public.customer_ledgers
FOR EACH ROW EXECUTE FUNCTION public.validate_ledger_reference_same_store();

DROP TRIGGER IF EXISTS trg_validate_supplier_ledger_source_store ON public.supplier_ledger;
CREATE TRIGGER trg_validate_supplier_ledger_source_store BEFORE INSERT OR UPDATE ON public.supplier_ledger
FOR EACH ROW EXECUTE FUNCTION public.validate_ledger_reference_same_store();

DROP TRIGGER IF EXISTS trg_validate_journal_source_store ON public.journal_entries;
CREATE TRIGGER trg_validate_journal_source_store BEFORE INSERT OR UPDATE ON public.journal_entries
FOR EACH ROW EXECUTE FUNCTION public.validate_journal_source_same_store();

DROP TRIGGER IF EXISTS trg_validate_general_ledger_source_store ON public.general_ledger;
CREATE TRIGGER trg_validate_general_ledger_source_store BEFORE INSERT OR UPDATE ON public.general_ledger
FOR EACH ROW EXECUTE FUNCTION public.validate_general_ledger_source_same_store();

-- Protect parent ownership for generic accounting/receipt references as well.
DROP TRIGGER IF EXISTS trg_guard_purchase_receipt_store ON public.purchase_receipts;
CREATE TRIGGER trg_guard_purchase_receipt_store BEFORE UPDATE OF store_id ON public.purchase_receipts
FOR EACH ROW EXECUTE FUNCTION public.prevent_store_reassignment_with_dependents();

DROP TRIGGER IF EXISTS trg_guard_purchase_closure_store ON public.purchase_closures;
CREATE TRIGGER trg_guard_purchase_closure_store BEFORE UPDATE OF store_id ON public.purchase_closures
FOR EACH ROW EXECUTE FUNCTION public.prevent_store_reassignment_with_dependents();

DROP TRIGGER IF EXISTS trg_guard_purchase_amendment_store ON public.purchase_amendments;
CREATE TRIGGER trg_guard_purchase_amendment_store BEFORE UPDATE OF store_id ON public.purchase_amendments
FOR EACH ROW EXECUTE FUNCTION public.prevent_store_reassignment_with_dependents();

DROP TRIGGER IF EXISTS trg_guard_purchase_receipt_item_store ON public.purchase_receipt_items;
CREATE TRIGGER trg_guard_purchase_receipt_item_store BEFORE UPDATE OF store_id ON public.purchase_receipt_items
FOR EACH ROW EXECUTE FUNCTION public.prevent_store_reassignment_with_dependents();

COMMIT;
