-- Phase 3 accounting hardening and automatic double-entry posting.
-- Applied after all Phase 2/3 RPC repair files.
BEGIN;

-- Preserve how customer/supplier credits split between debt settlement and carry-forward.
ALTER TABLE public.sales_returns
  ADD COLUMN IF NOT EXISTS applied_to_debt NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(applied_to_debt>=0),
  ADD COLUMN IF NOT EXISTS customer_credit_created NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(customer_credit_created>=0);
ALTER TABLE public.purchase_returns
  ADD COLUMN IF NOT EXISTS applied_to_debt NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(applied_to_debt>=0),
  ADD COLUMN IF NOT EXISTS supplier_credit_created NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(supplier_credit_created>=0);

-- Complete the per-store chart of accounts. TVA is intentionally absent (D-029).
CREATE OR REPLACE FUNCTION public.seed_default_chart_of_accounts(p_store_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp
AS $seed_coa$
BEGIN
  INSERT INTO public.chart_of_accounts(store_id,account_code,account_name,account_type,is_active)
  VALUES
    (p_store_id,'1000','Cash on Hand','CURRENT_ASSET',TRUE),
    (p_store_id,'1100','Bank Accounts','CURRENT_ASSET',TRUE),
    (p_store_id,'1110','Card Clearing','CURRENT_ASSET',TRUE),
    (p_store_id,'1120','Mobile Payment Clearing','CURRENT_ASSET',TRUE),
    (p_store_id,'1200','Inventory','ASSET',TRUE),
    (p_store_id,'1210','Goods in Transit','CURRENT_ASSET',TRUE),
    (p_store_id,'1300','Trade Receivables','CURRENT_ASSET',TRUE),
    (p_store_id,'2000','Trade Payables','CURRENT_LIABILITY',TRUE),
    (p_store_id,'2100','Customer Credit Balances','CURRENT_LIABILITY',TRUE),
    (p_store_id,'2200','Supplier Advances','CURRENT_ASSET',TRUE),
    (p_store_id,'4000','Sales Revenue','REVENUE',TRUE),
    (p_store_id,'4010','Sales Returns','REVENUE',TRUE),
    (p_store_id,'4100','Inventory Adjustment Gain','REVENUE',TRUE),
    (p_store_id,'4200','Purchase Return Gain','REVENUE',TRUE),
    (p_store_id,'5000','Cost of Goods Sold','COST_OF_GOODS_SOLD',TRUE),
    (p_store_id,'5100','Inventory Adjustment Loss','EXPENSE',TRUE),
    (p_store_id,'5200','Purchase Return Loss','EXPENSE',TRUE)
  ON CONFLICT(store_id,account_code) DO NOTHING;
END;
$seed_coa$;

SELECT public.seed_default_chart_of_accounts(id) FROM public.stores;

CREATE OR REPLACE FUNCTION public.trg_seed_store_chart_of_accounts()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp
AS $seed_store$
BEGIN
  PERFORM public.seed_default_chart_of_accounts(NEW.id);
  RETURN NEW;
END;
$seed_store$;
DROP TRIGGER IF EXISTS trg_seed_store_chart_of_accounts ON public.stores;
CREATE TRIGGER trg_seed_store_chart_of_accounts
AFTER INSERT ON public.stores
FOR EACH ROW EXECUTE FUNCTION public.trg_seed_store_chart_of_accounts();

-- The source key prevents duplicate journals for retried business operations.
CREATE UNIQUE INDEX IF NOT EXISTS uq_journal_entries_store_source
ON public.journal_entries(store_id,source_type,source_id)
WHERE source_type IS NOT NULL AND source_id IS NOT NULL;

-- Ensure every ledger line references a real journal header.
DO $journal_fk$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.general_ledger'::regclass
      AND conname='general_ledger_journal_entry_id_fkey'
  ) THEN
    ALTER TABLE public.general_ledger
      ADD CONSTRAINT general_ledger_journal_entry_id_fkey
      FOREIGN KEY(journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE RESTRICT;
  END IF;
END;
$journal_fk$;

CREATE OR REPLACE FUNCTION public.validate_journal_entry_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp
AS $validate_journal$
DECLARE
  v_journal_id UUID;
  v_store UUID;
  v_debit NUMERIC(18,4);
  v_credit NUMERIC(18,4);
  v_header_debit NUMERIC(18,4);
  v_header_credit NUMERIC(18,4);
  v_count INTEGER;
BEGIN
  IF TG_TABLE_NAME='journal_entries' THEN
    v_journal_id:=COALESCE(NEW.id,OLD.id);
  ELSE
    v_journal_id:=COALESCE(NEW.journal_entry_id,OLD.journal_entry_id);
  END IF;

  SELECT store_id,total_debit,total_credit
    INTO v_store,v_header_debit,v_header_credit
    FROM public.journal_entries WHERE id=v_journal_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT COALESCE(SUM(CASE WHEN entry_type='DEBIT' THEN amount ELSE 0 END),0),
         COALESCE(SUM(CASE WHEN entry_type='CREDIT' THEN amount ELSE 0 END),0),
         COUNT(*)
    INTO v_debit,v_credit,v_count
    FROM public.general_ledger WHERE journal_entry_id=v_journal_id;

  IF v_count<2 OR v_debit<>v_credit
     OR v_debit<>v_header_debit OR v_credit<>v_header_credit THEN
    RAISE EXCEPTION 'Unbalanced journal %: lines debit %, credit %, header debit %, credit %',
      v_journal_id,v_debit,v_credit,v_header_debit,v_header_credit
      USING ERRCODE='23514';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.general_ledger gl
    JOIN public.chart_of_accounts coa ON coa.id=gl.account_id
    WHERE gl.journal_entry_id=v_journal_id
      AND (gl.store_id<>v_store OR coa.store_id<>v_store)
  ) THEN
    RAISE EXCEPTION 'Journal % contains cross-store ledger lines',v_journal_id
      USING ERRCODE='23514';
  END IF;
  RETURN NULL;
END;
$validate_journal$;

DROP TRIGGER IF EXISTS trg_validate_journal_header_balance ON public.journal_entries;
CREATE CONSTRAINT TRIGGER trg_validate_journal_header_balance
AFTER INSERT OR UPDATE ON public.journal_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION public.validate_journal_entry_balance();

DROP TRIGGER IF EXISTS trg_validate_general_ledger_balance ON public.general_ledger;
CREATE CONSTRAINT TRIGGER trg_validate_general_ledger_balance
AFTER INSERT OR UPDATE OR DELETE ON public.general_ledger
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION public.validate_journal_entry_balance();

-- Single trusted posting primitive. All source operations post within their own
-- transaction; unbalanced, cross-store or duplicate source entries are rejected.
CREATE OR REPLACE FUNCTION public._post_journal_entry(
  p_store_id UUID,
  p_source_type TEXT,
  p_source_id UUID,
  p_description TEXT,
  p_posted_by UUID,
  p_lines JSONB,
  p_entry_date TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp
AS $post_journal$
DECLARE
  v_id UUID;
  v_entry_no TEXT;
  v_debit NUMERIC(18,4):=0;
  v_credit NUMERIC(18,4):=0;
  v_line JSONB;
  v_account UUID;
  v_amount NUMERIC(18,4);
  v_type TEXT;
  v_existing_debit NUMERIC(18,4);
  v_existing_credit NUMERIC(18,4);
  v_existing_count INTEGER;
BEGIN
  IF p_source_type NOT IN ('SALE','PURCHASE','RETURN','PAYMENT','EXPENSE','REVENUE','ADJUSTMENT','TRANSFER')
     OR p_source_id IS NULL OR p_posted_by IS NULL THEN
    RAISE EXCEPTION 'Invalid journal source or posting user';
  END IF;
  IF jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)<2 THEN
    RAISE EXCEPTION 'A journal requires at least two ledger lines';
  END IF;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
  LOOP
    v_type:=v_line->>'entry_type';
    v_amount:=(v_line->>'amount')::NUMERIC;
    IF v_type NOT IN ('DEBIT','CREDIT') OR v_amount IS NULL OR v_amount<=0 THEN
      RAISE EXCEPTION 'Invalid journal line';
    END IF;
    SELECT id INTO v_account FROM public.chart_of_accounts
      WHERE store_id=p_store_id AND account_code=v_line->>'account_code' AND is_active;
    IF v_account IS NULL THEN
      RAISE EXCEPTION 'Missing active account % for store %',v_line->>'account_code',p_store_id;
    END IF;
    IF v_type='DEBIT' THEN v_debit:=v_debit+v_amount;
    ELSE v_credit:=v_credit+v_amount; END IF;
  END LOOP;
  IF v_debit=0 OR v_debit<>v_credit THEN
    RAISE EXCEPTION 'Journal is not balanced: debit %, credit %',v_debit,v_credit
      USING ERRCODE='23514';
  END IF;

  SELECT id,total_debit,total_credit INTO v_id,v_existing_debit,v_existing_credit
    FROM public.journal_entries
   WHERE store_id=p_store_id AND source_type=p_source_type AND source_id=p_source_id;
  IF FOUND THEN
    SELECT COUNT(*) INTO v_existing_count FROM public.general_ledger WHERE journal_entry_id=v_id;
    IF v_existing_debit<>v_debit OR v_existing_credit<>v_credit
       OR v_existing_count<>jsonb_array_length(p_lines) THEN
      RAISE EXCEPTION 'Journal source %/% already exists with different posting',p_source_type,p_source_id;
    END IF;
    RETURN v_id;
  END IF;

  v_id:=gen_random_uuid();
  v_entry_no:='JE-'||to_char(COALESCE(p_entry_date,NOW()),'YYYYMMDD')||'-'||substr(replace(v_id::text,'-',''),1,12);
  INSERT INTO public.journal_entries(
    id,store_id,entry_number,entry_date,description,source_type,source_id,
    total_debit,total_credit,is_posted,posted_by
  ) VALUES (
    v_id,p_store_id,v_entry_no,COALESCE(p_entry_date,NOW()),p_description,p_source_type,p_source_id,
    v_debit,v_credit,TRUE,p_posted_by
  );

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
  LOOP
    SELECT id INTO v_account FROM public.chart_of_accounts
      WHERE store_id=p_store_id AND account_code=v_line->>'account_code' AND is_active;
    INSERT INTO public.general_ledger(
      store_id,journal_entry_id,account_id,entry_type,amount,description,
      reference_id,reference_table,created_by
    ) VALUES (
      p_store_id,v_id,v_account,v_line->>'entry_type',(v_line->>'amount')::NUMERIC,
      COALESCE(v_line->>'description',p_description),p_source_id,p_source_type,p_posted_by
    );
  END LOOP;
  RETURN v_id;
END;
$post_journal$;

REVOKE ALL ON FUNCTION public.seed_default_chart_of_accounts(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._post_journal_entry(UUID,TEXT,UUID,TEXT,UUID,JSONB,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;

-- Sales: revenue, tender/receivable and cost of goods sold are posted atomically.
ALTER FUNCTION public.process_sale_invoice(UUID,UUID,JSONB) RENAME TO process_sale_invoice_pre_accounting;
REVOKE ALL ON FUNCTION public.process_sale_invoice_pre_accounting(UUID,UUID,JSONB) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.process_sale_invoice(
 p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,extensions,public,pg_temp
AS $sale_accounting$
DECLARE
 v_result JSONB; v_invoice UUID:=(p_payload->>'id')::UUID;
 v_user UUID; v_customer UUID; v_total NUMERIC(18,4); v_paid NUMERIC(18,4);
 v_due NUMERIC(18,4); v_method TEXT; v_cogs NUMERIC(18,4);
 v_lines JSONB:='[]'::JSONB; v_tender TEXT;
BEGIN
 v_result:=public.process_sale_invoice_pre_accounting(p_store_id,p_operation_id,p_payload);
 IF COALESCE((v_result->>'replayed')::BOOLEAN,FALSE) THEN RETURN v_result; END IF;
 SELECT created_by,customer_id,total_amount,paid_amount,remaining_amount,
        COALESCE(payment_method,'CASH')
   INTO v_user,v_customer,v_total,v_paid,v_due,v_method
   FROM public.invoices WHERE id=v_invoice AND store_id=p_store_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Sale invoice missing after successful RPC'; END IF;
 v_tender:=CASE v_method WHEN 'CASH' THEN '1000' WHEN 'CARD' THEN '1110'
   WHEN 'BANK_TRANSFER' THEN '1100' ELSE '1120' END;
 IF v_due>0 THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code','1300','entry_type','DEBIT','amount',v_due,'description','Sale receivable'));
 END IF;
 IF v_paid>0 THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code',v_tender,'entry_type','DEBIT','amount',v_paid,'description','Sale settlement'));
 END IF;
 IF v_total>0 THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code','4000','entry_type','CREDIT','amount',v_total,'description','Sales revenue'));
 END IF;
 SELECT COALESCE(SUM(total_value),0) INTO v_cogs
   FROM public.stock_movements
  WHERE reference_id=v_invoice AND reference_type='invoice' AND type='OUT';
 IF v_cogs>0 THEN
   v_lines:=v_lines||jsonb_build_array(
     jsonb_build_object('account_code','5000','entry_type','DEBIT','amount',v_cogs,'description','Cost of goods sold'),
     jsonb_build_object('account_code','1200','entry_type','CREDIT','amount',v_cogs,'description','Inventory issued')
   );
 END IF;
 IF jsonb_array_length(v_lines)>=2 THEN
   PERFORM public._post_journal_entry(p_store_id,'SALE',v_invoice,'Sale invoice '||v_invoice::TEXT,v_user,v_lines,
     (SELECT invoice_date FROM public.invoices WHERE id=v_invoice));
 END IF;
 RETURN v_result;
END;
$sale_accounting$;

-- Purchases: received stock plus unreceived goods-in-transit, offset by payables
-- and the actual tender. This also handles an initial partial receipt.
ALTER FUNCTION public.process_purchase(UUID,UUID,JSONB) RENAME TO process_purchase_pre_accounting;
REVOKE ALL ON FUNCTION public.process_purchase_pre_accounting(UUID,UUID,JSONB) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.process_purchase(
 p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,extensions,public,pg_temp
AS $purchase_accounting$
DECLARE
 v_result JSONB; v_purchase UUID; v_user UUID; v_total NUMERIC(18,4);
 v_paid NUMERIC(18,4); v_due NUMERIC(18,4); v_method TEXT;
 v_received_value NUMERIC(18,4); v_lines JSONB:='[]'::JSONB; v_tender TEXT;
BEGIN
 v_result:=public.process_purchase_pre_accounting(p_store_id,p_operation_id,p_payload);
 IF COALESCE((v_result->>'replayed')::BOOLEAN,FALSE) THEN RETURN v_result; END IF;
 v_purchase:=(v_result->>'purchase_id')::UUID;
 SELECT created_by,total_amount,paid_amount,remaining_amount,COALESCE(payment_method,'CASH')
   INTO v_user,v_total,v_paid,v_due,v_method
   FROM public.purchases WHERE id=v_purchase AND store_id=p_store_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Purchase missing after successful RPC'; END IF;
 SELECT COALESCE(SUM(total_value),0) INTO v_received_value
   FROM public.stock_movements
  WHERE reference_id=v_purchase AND reference_type='purchase' AND type='IN';
 v_tender:=CASE v_method WHEN 'CASH' THEN '1000' WHEN 'CARD' THEN '1110'
   WHEN 'BANK_TRANSFER' THEN '1100' ELSE '1120' END;
 IF v_received_value>0 THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code','1200','entry_type','DEBIT','amount',v_received_value,'description','Received purchase inventory'));
 END IF;
 IF v_total>v_received_value THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code','1210','entry_type','DEBIT','amount',v_total-v_received_value,'description','Unreceived purchase goods'));
 ELSIF v_received_value>v_total THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code','4200','entry_type','CREDIT','amount',v_received_value-v_total,'description','Purchase cost variance'));
 END IF;
 IF v_due>0 THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code','2000','entry_type','CREDIT','amount',v_due,'description','Supplier payable'));
 END IF;
 IF v_paid>0 THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code',v_tender,'entry_type','CREDIT','amount',v_paid,'description','Purchase settlement'));
 END IF;
 IF jsonb_array_length(v_lines)>=2 THEN
   PERFORM public._post_journal_entry(p_store_id,'PURCHASE',v_purchase,'Purchase '||v_purchase::TEXT,v_user,v_lines,
     (SELECT purchase_date FROM public.purchases WHERE id=v_purchase));
 END IF;
 RETURN v_result;
END;
$purchase_accounting$;

-- Customer receipts: debit the actual tender account, credit receivables.
ALTER FUNCTION public.process_customer_payment(UUID,UUID,JSONB) RENAME TO process_customer_payment_pre_accounting;
REVOKE ALL ON FUNCTION public.process_customer_payment_pre_accounting(UUID,UUID,JSONB) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.process_customer_payment(
 p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,extensions,public,pg_temp
AS $customer_payment_accounting$
DECLARE
 v_result JSONB; v_id UUID:=(p_payload->>'id')::UUID; v_user UUID;
 v_amount NUMERIC(18,4); v_method TEXT; v_tender TEXT; v_lines JSONB;
BEGIN
 v_result:=public.process_customer_payment_pre_accounting(p_store_id,p_operation_id,p_payload);
 IF COALESCE((v_result->>'replayed')::BOOLEAN,FALSE) THEN RETURN v_result; END IF;
 SELECT cp.created_by,cp.amount,cp.payment_method INTO v_user,v_amount,v_method
   FROM public.customer_payments cp JOIN public.customers c ON c.id=cp.customer_id
  WHERE cp.id=v_id AND c.store_id=p_store_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Customer payment missing after successful RPC'; END IF;
 v_tender:=CASE v_method WHEN 'CASH' THEN '1000' WHEN 'CARD' THEN '1110'
   WHEN 'BANK_TRANSFER' THEN '1100' ELSE '1120' END;
 v_lines:=jsonb_build_array(
   jsonb_build_object('account_code',v_tender,'entry_type','DEBIT','amount',v_amount,'description','Customer payment received'),
   jsonb_build_object('account_code','1300','entry_type','CREDIT','amount',v_amount,'description','Customer receivable settled')
 );
 PERFORM public._post_journal_entry(p_store_id,'PAYMENT',v_id,'Customer payment '||v_id::TEXT,v_user,v_lines);
 RETURN v_result;
END;
$customer_payment_accounting$;

-- Supplier payments: debit payables and credit the actual tender account.
ALTER FUNCTION public.process_supplier_payment(UUID,UUID,JSONB) RENAME TO process_supplier_payment_pre_accounting;
REVOKE ALL ON FUNCTION public.process_supplier_payment_pre_accounting(UUID,UUID,JSONB) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.process_supplier_payment(
 p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,extensions,public,pg_temp
AS $supplier_payment_accounting$
DECLARE
 v_result JSONB; v_id UUID:=(p_payload->>'id')::UUID; v_user UUID;
 v_amount NUMERIC(18,4); v_method TEXT; v_tender TEXT; v_lines JSONB;
BEGIN
 v_result:=public.process_supplier_payment_pre_accounting(p_store_id,p_operation_id,p_payload);
 IF COALESCE((v_result->>'replayed')::BOOLEAN,FALSE) THEN RETURN v_result; END IF;
 SELECT sp.created_by,sp.amount,sp.payment_method INTO v_user,v_amount,v_method
   FROM public.supplier_payments sp JOIN public.suppliers s ON s.id=sp.supplier_id
  WHERE sp.id=v_id AND s.store_id=p_store_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Supplier payment missing after successful RPC'; END IF;
 v_tender:=CASE v_method WHEN 'CASH' THEN '1000' WHEN 'CARD' THEN '1110'
   WHEN 'BANK_TRANSFER' THEN '1100' ELSE '1120' END;
 v_lines:=jsonb_build_array(
   jsonb_build_object('account_code','2000','entry_type','DEBIT','amount',v_amount,'description','Supplier payable settled'),
   jsonb_build_object('account_code',v_tender,'entry_type','CREDIT','amount',v_amount,'description','Supplier payment')
 );
 PERFORM public._post_journal_entry(p_store_id,'PAYMENT',v_id,'Supplier payment '||v_id::TEXT,v_user,v_lines);
 RETURN v_result;
END;
$supplier_payment_accounting$;

-- Sales returns reverse revenue/receivable and restore inventory only for good goods.
ALTER FUNCTION public.process_sale_return(UUID,UUID,JSONB) RENAME TO process_sale_return_pre_accounting;
REVOKE ALL ON FUNCTION public.process_sale_return_pre_accounting(UUID,UUID,JSONB) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.process_sale_return(
 p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,extensions,public,pg_temp
AS $sale_return_accounting$
DECLARE
 v_result JSONB; v_id UUID:=(p_payload->>'id')::UUID; v_user UUID;
 v_total NUMERIC(18,4); v_applied NUMERIC(18,4); v_credit NUMERIC(18,4);
 v_inventory NUMERIC(18,4); v_lines JSONB:='[]'::JSONB;
BEGIN
 v_result:=public.process_sale_return_pre_accounting(p_store_id,p_operation_id,p_payload);
 IF COALESCE((v_result->>'replayed')::BOOLEAN,FALSE) THEN RETURN v_result; END IF;
 SELECT created_by,total_amount,applied_to_debt,customer_credit_created
   INTO v_user,v_total,v_applied,v_credit
   FROM public.sales_returns WHERE id=v_id AND store_id=p_store_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Sales return missing after successful RPC'; END IF;
 IF v_total>0 THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code','4010','entry_type','DEBIT','amount',v_total,'description','Sales return'));
 END IF;
 IF v_applied>0 THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code','1300','entry_type','CREDIT','amount',v_applied,'description','Customer receivable reduced'));
 END IF;
 IF v_credit>0 THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code','2100','entry_type','CREDIT','amount',v_credit,'description','Customer credit balance created'));
 END IF;
 SELECT COALESCE(SUM(total_value),0) INTO v_inventory
   FROM public.stock_movements WHERE reference_id=v_id AND reference_type='return' AND type='RETURN_IN';
 IF v_inventory>0 THEN
   v_lines:=v_lines||jsonb_build_array(
     jsonb_build_object('account_code','1200','entry_type','DEBIT','amount',v_inventory,'description','Returned saleable inventory'),
     jsonb_build_object('account_code','5000','entry_type','CREDIT','amount',v_inventory,'description','Reverse cost of goods sold')
   );
 END IF;
 IF jsonb_array_length(v_lines)>=2 THEN
   PERFORM public._post_journal_entry(p_store_id,'RETURN',v_id,'Sales return '||v_id::TEXT,v_user,v_lines);
 END IF;
 RETURN v_result;
END;
$sale_return_accounting$;

-- Purchase returns reduce supplier payables or create supplier advances; no cash payout.
ALTER FUNCTION public.process_purchase_return(UUID,UUID,JSONB) RENAME TO process_purchase_return_pre_accounting;
REVOKE ALL ON FUNCTION public.process_purchase_return_pre_accounting(UUID,UUID,JSONB) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.process_purchase_return(
 p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,extensions,public,pg_temp
AS $purchase_return_accounting$
DECLARE
 v_result JSONB; v_id UUID:=(p_payload->>'id')::UUID; v_user UUID;
 v_total NUMERIC(18,4); v_applied NUMERIC(18,4); v_credit NUMERIC(18,4);
 v_inventory NUMERIC(18,4); v_lines JSONB:='[]'::JSONB;
BEGIN
 v_result:=public.process_purchase_return_pre_accounting(p_store_id,p_operation_id,p_payload);
 IF COALESCE((v_result->>'replayed')::BOOLEAN,FALSE) THEN RETURN v_result; END IF;
 SELECT created_by,total_amount,applied_to_debt,supplier_credit_created
   INTO v_user,v_total,v_applied,v_credit
   FROM public.purchase_returns WHERE id=v_id AND store_id=p_store_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Purchase return missing after successful RPC'; END IF;
 IF v_applied>0 THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code','2000','entry_type','DEBIT','amount',v_applied,'description','Supplier payable reduced'));
 END IF;
 IF v_credit>0 THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code','2200','entry_type','DEBIT','amount',v_credit,'description','Supplier advance credit created'));
 END IF;
 SELECT COALESCE(SUM(total_value),0) INTO v_inventory
   FROM public.stock_movements WHERE reference_id=v_id AND reference_type='return' AND type='RETURN_OUT';
 IF v_inventory>0 THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code','1200','entry_type','CREDIT','amount',v_inventory,'description','Inventory returned to supplier'));
 END IF;
 IF v_total>v_inventory THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code','4200','entry_type','CREDIT','amount',v_total-v_inventory,'description','Purchase return cost difference'));
 ELSIF v_inventory>v_total THEN
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_code','5200','entry_type','DEBIT','amount',v_inventory-v_total,'description','Purchase return cost difference'));
 END IF;
 IF jsonb_array_length(v_lines)>=2 THEN
   PERFORM public._post_journal_entry(p_store_id,'RETURN',v_id,'Purchase return '||v_id::TEXT,v_user,v_lines);
 END IF;
 RETURN v_result;
END;
$purchase_return_accounting$;

REVOKE ALL ON FUNCTION public.process_sale_return_pre_accounting(UUID,UUID,JSONB) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.process_purchase_return_pre_accounting(UUID,UUID,JSONB) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.process_sale_return(UUID,UUID,JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_purchase_return(UUID,UUID,JSONB) TO authenticated;

-- Trial balance and financial reports are store-scoped and execute with caller RLS.
CREATE OR REPLACE VIEW public.v_trial_balance WITH (security_invoker=true) AS
SELECT coa.account_code,coa.account_name,coa.account_type,
 COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='DEBIT'),0) AS total_debit,
 COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='CREDIT'),0) AS total_credit,
 COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='DEBIT'),0)-
 COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='CREDIT'),0) AS balance,
 coa.store_id
FROM public.chart_of_accounts coa
LEFT JOIN public.general_ledger gl ON gl.account_id=coa.id AND gl.store_id=coa.store_id
WHERE coa.is_active
GROUP BY coa.store_id,coa.id,coa.account_code,coa.account_name,coa.account_type
ORDER BY coa.store_id,coa.account_code;

CREATE OR REPLACE VIEW public.v_balance_sheet WITH (security_invoker=true) AS
SELECT coa.account_code,coa.account_name,coa.account_type,
 COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='DEBIT'),0)-
 COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='CREDIT'),0) AS balance,
 coa.store_id
FROM public.chart_of_accounts coa
LEFT JOIN public.general_ledger gl ON gl.account_id=coa.id AND gl.store_id=coa.store_id
WHERE coa.is_active AND coa.account_type IN ('ASSET','LIABILITY','EQUITY','CURRENT_ASSET','CURRENT_LIABILITY')
GROUP BY coa.store_id,coa.id,coa.account_code,coa.account_name,coa.account_type
HAVING COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='DEBIT'),0)-
       COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='CREDIT'),0)<>0
ORDER BY coa.store_id,coa.account_code;

CREATE OR REPLACE VIEW public.v_income_statement WITH (security_invoker=true) AS
SELECT coa.account_code,coa.account_name,coa.account_type,
 COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='DEBIT'),0)-
 COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='CREDIT'),0) AS balance,
 coa.store_id
FROM public.chart_of_accounts coa
LEFT JOIN public.general_ledger gl ON gl.account_id=coa.id AND gl.store_id=coa.store_id
WHERE coa.is_active AND coa.account_type IN ('REVENUE','EXPENSE','COST_OF_GOODS_SOLD','INCOME')
GROUP BY coa.store_id,coa.id,coa.account_code,coa.account_name,coa.account_type
HAVING COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='DEBIT'),0)-
       COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='CREDIT'),0)<>0
ORDER BY coa.store_id,coa.account_code;

GRANT SELECT ON public.v_trial_balance,public.v_balance_sheet,public.v_income_statement TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_sale_invoice(UUID,UUID,JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_purchase(UUID,UUID,JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_customer_payment(UUID,UUID,JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_supplier_payment(UUID,UUID,JSONB) TO authenticated;

COMMIT;
