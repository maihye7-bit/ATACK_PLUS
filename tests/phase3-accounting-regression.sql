-- Phase 3 accounting regression: real business RPCs, balanced journals and store-scoped reports.
DO $accounting_regression$
DECLARE
 v_store UUID:='10000000-0000-4000-8000-000000000001';
 v_auth UUID:='20000000-0000-4000-8000-000000000001';
 v_user UUID:='30000000-0000-4000-8000-000000000001';
 v_supplier UUID:='40000000-0000-4000-8000-000000000001';
 v_product UUID:='50000000-0000-4000-8000-000000000001';
 v_customer UUID:='90000000-0000-4000-8000-000000000002';
 v_result JSONB;
 v_debit NUMERIC(18,4); v_credit NUMERIC(18,4);
 v_count INTEGER; v_journal UUID; v_proc TEXT; v_error TEXT;
BEGIN
 PERFORM set_config('request.jwt.claim.sub',v_auth::text,TRUE);

 -- The default chart must exist for every store and contain all posting accounts.
 IF (SELECT count(*) FROM public.chart_of_accounts
     WHERE store_id=v_store AND account_code IN
       ('1000','1100','1110','1120','1200','1210','1300','2000','2100','2200',
        '4000','4010','4100','4200','5000','5100','5200'))<>17 THEN
   RAISE EXCEPTION 'Default chart of accounts is incomplete';
 END IF;

 IF has_table_privilege('anon','public.v_trial_balance','SELECT')
    OR has_table_privilege('anon','public.v_balance_sheet','SELECT')
    OR has_table_privilege('anon','public.v_income_statement','SELECT')
    OR NOT has_table_privilege('authenticated','public.v_trial_balance','SELECT')
    OR NOT has_table_privilege('authenticated','public.v_balance_sheet','SELECT')
    OR NOT has_table_privilege('authenticated','public.v_income_statement','SELECT') THEN
   RAISE EXCEPTION 'Financial reporting view grants are unsafe';
 END IF;

 FOREACH v_proc IN ARRAY ARRAY[
   'public.process_sale_invoice(uuid,uuid,jsonb)',
   'public.process_purchase(uuid,uuid,jsonb)',
   'public.process_customer_payment(uuid,uuid,jsonb)',
   'public.process_supplier_payment(uuid,uuid,jsonb)',
   'public.process_sale_return(uuid,uuid,jsonb)',
   'public.process_purchase_return(uuid,uuid,jsonb)',
   'public.process_purchase_receipt(uuid,uuid,jsonb)',
   'public.process_purchase_amendment(uuid,uuid,jsonb)',
   'public.process_purchase_close_remaining(uuid,uuid,jsonb)'
 ] LOOP
   IF has_function_privilege('anon',v_proc,'EXECUTE')
      OR NOT has_function_privilege('authenticated',v_proc,'EXECUTE') THEN
     RAISE EXCEPTION 'Accounting RPC grants are unsafe for %',v_proc;
   END IF;
 END LOOP;

 -- A sale on credit, followed by a bank transfer collection, must create two distinct journals.
 INSERT INTO public.customers(id,store_id,code,name,current_debt,credit_balance,is_active)
 VALUES(v_customer,v_store,'ACC-CUST-001','Accounting Test Customer',0,0,TRUE);
 v_result:=public.process_sale_invoice(
   v_store,'60000000-0000-4000-8000-000000000080',
   jsonb_build_object('id','80000000-0000-4000-8000-000000000080',
     'invoice_number','ACC-INV-080','customer_id',v_customer,'paid_amount',0,
     'items',jsonb_build_array(jsonb_build_object('product_id',v_product,
       'quantity',1,'unit_id','pcs','unit_price',100)))
 );
 IF NOT EXISTS(
   SELECT 1 FROM public.journal_entries je
   JOIN public.general_ledger gl ON gl.journal_entry_id=je.id
   JOIN public.chart_of_accounts coa ON coa.id=gl.account_id
   WHERE je.store_id=v_store AND je.source_type='SALE'
     AND je.source_id='80000000-0000-4000-8000-000000000080'
     AND je.total_debit=je.total_credit
     AND gl.entry_type='CREDIT' AND coa.account_code='4000' AND gl.amount=100
 ) THEN
   RAISE EXCEPTION 'Credit sale journal missing or incorrect';
 END IF;
 v_result:=public.process_customer_payment(
   v_store,'60000000-0000-4000-8000-000000000081',
   jsonb_build_object('id','81000000-0000-4000-8000-000000000080',
     'customer_id',v_customer,'amount',40,'payment_method','BANK_TRANSFER')
 );
 SELECT id INTO v_journal FROM public.journal_entries
  WHERE source_type='PAYMENT' AND source_id='81000000-0000-4000-8000-000000000080'
    AND store_id=v_store;
 IF v_journal IS NULL OR NOT EXISTS(
   SELECT 1 FROM public.general_ledger gl JOIN public.chart_of_accounts coa ON coa.id=gl.account_id
    WHERE gl.journal_entry_id=v_journal AND gl.entry_type='DEBIT' AND coa.account_code='1100'
 ) OR NOT EXISTS(
   SELECT 1 FROM public.general_ledger gl JOIN public.chart_of_accounts coa ON coa.id=gl.account_id
    WHERE gl.journal_entry_id=v_journal AND gl.entry_type='CREDIT' AND coa.account_code='1300'
 ) THEN
   RAISE EXCEPTION 'Customer bank collection journal has incorrect accounts';
 END IF;

 -- A return against a partially settled credit invoice must first clear the remaining
 -- receivable, then create customer credit for the excess; all three balances must reconcile.
 INSERT INTO public.customers(id,store_id,code,name,current_debt,credit_balance,is_active)
 VALUES('90000000-0000-4000-8000-000000000009',v_store,'ACC-CUST-009',
        'Mixed Return Settlement Customer',0,0,TRUE);
 PERFORM public.process_sale_invoice(
   v_store,'60000000-0000-4000-8000-000000000083',
   jsonb_build_object('id','80000000-0000-4000-8000-000000000083',
     'invoice_number','ACC-INV-083','customer_id','90000000-0000-4000-8000-000000000009',
     'paid_amount',0,'items',jsonb_build_array(jsonb_build_object(
       'product_id',v_product,'quantity',1,'unit_id','pcs','unit_price',100)))
 );
 PERFORM public.process_customer_payment(
   v_store,'60000000-0000-4000-8000-000000000084',
   jsonb_build_object('id','81000000-0000-4000-8000-000000000083',
     'customer_id','90000000-0000-4000-8000-000000000009',
     'amount',70,'payment_method','CASH')
 );
 v_result:=public.process_sale_return(
   v_store,'60000000-0000-4000-8000-000000000085',
   jsonb_build_object('id','91000000-0000-4000-8000-000000000003',
     'invoice_id','80000000-0000-4000-8000-000000000083',
     'return_number','ACC-SRET-MIXED','refund_method','CREDIT','return_condition','GOOD',
     'items',(SELECT jsonb_agg(jsonb_build_object('invoice_item_id',ii.id,
       'product_id',ii.product_id,'quantity',1,'unit_id','pcs','unit_price',999))
       FROM public.invoice_items ii WHERE ii.invoice_id='80000000-0000-4000-8000-000000000083'))
 );
 IF NOT EXISTS(SELECT 1 FROM public.sales_returns
    WHERE id='91000000-0000-4000-8000-000000000003'
      AND total_amount=100 AND applied_to_debt=30 AND customer_credit_created=70) THEN
   RAISE EXCEPTION 'Mixed credit return did not allocate 30 to receivable and 70 to customer credit';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.customers
    WHERE id='90000000-0000-4000-8000-000000000009'
      AND current_debt=0 AND credit_balance=70) THEN
   RAISE EXCEPTION 'Mixed credit return left incorrect customer debt/credit balances';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.journal_entries je
    JOIN public.general_ledger gl ON gl.journal_entry_id=je.id
    JOIN public.chart_of_accounts coa ON coa.id=gl.account_id
    WHERE je.store_id=v_store AND je.source_type='RETURN'
      AND je.source_id='91000000-0000-4000-8000-000000000003'
      AND gl.entry_type='DEBIT' AND coa.account_code='4010' AND gl.amount=100)
    OR NOT EXISTS(SELECT 1 FROM public.journal_entries je
    JOIN public.general_ledger gl ON gl.journal_entry_id=je.id
    JOIN public.chart_of_accounts coa ON coa.id=gl.account_id
    WHERE je.store_id=v_store AND je.source_type='RETURN'
      AND je.source_id='91000000-0000-4000-8000-000000000003'
      AND gl.entry_type='CREDIT' AND coa.account_code='1300' AND gl.amount=30)
    OR NOT EXISTS(SELECT 1 FROM public.journal_entries je
    JOIN public.general_ledger gl ON gl.journal_entry_id=je.id
    JOIN public.chart_of_accounts coa ON coa.id=gl.account_id
    WHERE je.store_id=v_store AND je.source_type='RETURN'
      AND je.source_id='91000000-0000-4000-8000-000000000003'
      AND gl.entry_type='CREDIT' AND coa.account_code='2100' AND gl.amount=70) THEN
   RAISE EXCEPTION 'Mixed credit return journal does not split receivable and customer credit correctly';
 END IF;
 SELECT id INTO v_journal FROM public.journal_entries
  WHERE store_id=v_store AND source_type='RETURN'
    AND source_id='91000000-0000-4000-8000-000000000003';
 IF v_journal IS NULL OR NOT EXISTS(
    SELECT 1 FROM public.journal_entries je
     WHERE je.id=v_journal AND je.total_debit=je.total_credit
       AND je.total_debit=(SELECT COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='DEBIT'),0)
                             FROM public.general_ledger gl WHERE gl.journal_entry_id=je.id)
       AND je.total_credit=(SELECT COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='CREDIT'),0)
                              FROM public.general_ledger gl WHERE gl.journal_entry_id=je.id)
 ) THEN
   RAISE EXCEPTION 'Mixed credit return journal header and ledger totals do not balance';
 END IF;

 -- Supplier payment is posted against payables and the bank, not the cash drawer.
 v_result:=public.process_supplier_payment(
   v_store,'60000000-0000-4000-8000-000000000082',
   jsonb_build_object('id','82000000-0000-4000-8000-000000000080',
     'supplier_id',v_supplier,'amount',1,'payment_method','BANK_TRANSFER')
 );
 SELECT id INTO v_journal FROM public.journal_entries
  WHERE source_type='PAYMENT' AND source_id='82000000-0000-4000-8000-000000000080'
    AND store_id=v_store;
 IF v_journal IS NULL OR NOT EXISTS(
   SELECT 1 FROM public.general_ledger gl JOIN public.chart_of_accounts coa ON coa.id=gl.account_id
    WHERE gl.journal_entry_id=v_journal AND gl.entry_type='DEBIT' AND coa.account_code='2000'
 ) OR NOT EXISTS(
   SELECT 1 FROM public.general_ledger gl JOIN public.chart_of_accounts coa ON coa.id=gl.account_id
    WHERE gl.journal_entry_id=v_journal AND gl.entry_type='CREDIT' AND coa.account_code='1100'
 ) THEN
   RAISE EXCEPTION 'Supplier bank payment journal has incorrect accounts';
 END IF;

 IF NOT EXISTS(
   SELECT 1 FROM public.journal_entries je
   JOIN public.general_ledger gl ON gl.journal_entry_id=je.id
   JOIN public.chart_of_accounts coa ON coa.id=gl.account_id
   WHERE je.store_id=v_store AND je.source_type='SALE'
     AND je.source_id='80000000-0000-4000-8000-000000000002'
     AND gl.entry_type='DEBIT' AND coa.account_code='1000' AND gl.amount=50
 ) THEN RAISE EXCEPTION 'Cash sale was not posted to the cash drawer'; END IF;

 -- Every sale, purchase, return and payment exercised by the preceding business suite is posted once.
 IF EXISTS(
   SELECT 1 FROM public.invoices i
    WHERE i.store_id=v_store AND i.type='SALE' AND i.total_amount>0
      AND NOT EXISTS(SELECT 1 FROM public.journal_entries je
        WHERE je.store_id=i.store_id AND je.source_type='SALE' AND je.source_id=i.id)
 ) THEN RAISE EXCEPTION 'A sale invoice has no journal entry'; END IF;
 IF EXISTS(
   SELECT 1 FROM public.purchases p
    WHERE p.store_id=v_store AND p.total_amount>0
      AND NOT EXISTS(SELECT 1 FROM public.journal_entries je
        WHERE je.store_id=p.store_id AND je.source_type='PURCHASE' AND je.source_id=p.id)
 ) THEN RAISE EXCEPTION 'A purchase has no journal entry'; END IF;
 IF EXISTS(
   SELECT 1 FROM public.sales_returns r
    WHERE r.store_id=v_store AND r.total_amount>0
      AND NOT EXISTS(SELECT 1 FROM public.journal_entries je
        WHERE je.store_id=r.store_id AND je.source_type='RETURN' AND je.source_id=r.id)
 ) THEN RAISE EXCEPTION 'A sales return has no journal entry'; END IF;
 IF EXISTS(
   SELECT 1 FROM public.purchase_returns r
    WHERE r.store_id=v_store AND r.total_amount>0
      AND NOT EXISTS(SELECT 1 FROM public.journal_entries je
        WHERE je.store_id=r.store_id AND je.source_type='RETURN' AND je.source_id=r.id)
 ) THEN RAISE EXCEPTION 'A purchase return has no journal entry'; END IF;

 IF EXISTS(
   SELECT 1 FROM public.purchase_receipts pr
   WHERE pr.store_id=v_store AND pr.receipt_number NOT LIKE 'INITIAL-%'
     AND EXISTS(SELECT 1 FROM public.purchase_receipt_items pri
       WHERE pri.receipt_id=pr.id AND pri.accepted_quantity+pri.excess_quantity>0)
     AND NOT EXISTS(SELECT 1 FROM public.journal_entries je
       WHERE je.store_id=pr.store_id AND je.source_type='TRANSFER' AND je.source_id=pr.id)
 ) THEN RAISE EXCEPTION 'A subsequent purchase receipt has no inventory/transit reclassification'; END IF;
 IF EXISTS(
   SELECT 1 FROM public.purchase_amendments pa
   WHERE pa.store_id=v_store AND pa.id='75000000-0000-4000-8000-000000000007'
     AND NOT EXISTS(SELECT 1 FROM public.journal_entries je
       WHERE je.store_id=pa.store_id AND je.source_type='ADJUSTMENT' AND je.source_id=pa.id)
 ) THEN RAISE EXCEPTION 'Purchase amendment journal is missing'; END IF;
 IF EXISTS(
   SELECT 1 FROM public.purchase_closures pc
   WHERE pc.store_id=v_store AND pc.id='74000000-0000-4000-8000-000000000005'
     AND (pc.financial_delta<>-30 OR NOT EXISTS(
       SELECT 1 FROM public.journal_entries je
       WHERE je.store_id=pc.store_id AND je.source_type='ADJUSTMENT' AND je.source_id=pc.id))
 ) THEN RAISE EXCEPTION 'Purchase closure financial cancellation journal is missing'; END IF;

 IF NOT EXISTS(
   SELECT 1 FROM public.purchase_amendments pa
   WHERE pa.id='75000000-0000-4000-8000-000000000007'
     AND pa.inventory_cost_delta=6 AND pa.cogs_cost_delta=2 AND pa.transit_cost_delta=76
 ) OR NOT EXISTS(
   SELECT 1 FROM public.journal_entries je
   JOIN public.general_ledger gl ON gl.journal_entry_id=je.id
   JOIN public.chart_of_accounts coa ON coa.id=gl.account_id
   WHERE je.source_type='ADJUSTMENT' AND je.source_id='75000000-0000-4000-8000-000000000007'
     AND gl.entry_type='DEBIT' AND coa.account_code='5000' AND gl.amount=2
 ) THEN RAISE EXCEPTION 'Amendment did not split consumed cost into COGS and remaining inventory'; END IF;

 -- Goods in transit must reconcile to the ordered quantity still outstanding after receipts, closures and amendments.
 IF EXISTS(
   SELECT 1 FROM public.purchases p
   WHERE p.store_id=v_store AND ABS(
     COALESCE((
       SELECT SUM(CASE WHEN gl.entry_type='DEBIT' THEN gl.amount ELSE -gl.amount END)
       FROM public.general_ledger gl
       JOIN public.chart_of_accounts coa ON coa.id=gl.account_id
       JOIN public.journal_entries je ON je.id=gl.journal_entry_id
       WHERE gl.store_id=p.store_id AND coa.account_code='1210'
         AND (
           (je.source_type='PURCHASE' AND je.source_id=p.id)
           OR (je.source_type='TRANSFER' AND je.source_id IN
               (SELECT id FROM public.purchase_receipts WHERE purchase_id=p.id))
           OR (je.source_type='ADJUSTMENT' AND je.source_id IN
               (SELECT id FROM public.purchase_amendments WHERE purchase_id=p.id))
           OR (je.source_type='ADJUSTMENT' AND je.source_id IN
               (SELECT id FROM public.purchase_closures WHERE purchase_id=p.id))
         )
     ),0)-
     COALESCE((SELECT SUM((pi.quantity-pi.received_quantity-pi.closed_quantity)*pi.unit_price)
       FROM public.purchase_items pi WHERE pi.purchase_id=p.id),0)
   )>0.0001
 ) THEN RAISE EXCEPTION 'Goods-in-transit balance does not reconcile to outstanding purchase quantities'; END IF;

 IF EXISTS(
   SELECT 1 FROM public.general_ledger gl
   JOIN public.journal_entries je ON je.id=gl.journal_entry_id
   WHERE je.store_id=v_store AND
     (gl.reference_id IS DISTINCT FROM je.source_id
      OR gl.reference_table IS DISTINCT FROM je.source_type
      OR gl.store_id IS DISTINCT FROM je.store_id)
 ) THEN RAISE EXCEPTION 'General ledger source or store reference mismatch'; END IF;

 IF EXISTS(
   SELECT 1 FROM public.journal_entries je
   LEFT JOIN public.general_ledger gl ON gl.journal_entry_id=je.id
   GROUP BY je.id,je.total_debit,je.total_credit
   HAVING COUNT(gl.id)<2 OR COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='DEBIT'),0)<>je.total_debit
      OR COALESCE(SUM(gl.amount) FILTER(WHERE gl.entry_type='CREDIT'),0)<>je.total_credit
      OR je.total_debit<>je.total_credit
 ) THEN RAISE EXCEPTION 'Journal header/ledger totals are inconsistent'; END IF;

 SELECT COALESCE(SUM(total_debit),0),COALESCE(SUM(total_credit),0)
   INTO v_debit,v_credit FROM public.v_trial_balance WHERE store_id=v_store;
 IF v_debit<>v_credit THEN
   RAISE EXCEPTION 'Trial balance is not balanced: debit %, credit %',v_debit,v_credit;
 END IF;

 SELECT COALESCE(SUM(balance),0) INTO v_debit
   FROM public.v_balance_sheet WHERE store_id=v_store;
 IF v_debit<>0 THEN
   RAISE EXCEPTION 'Balance sheet equation does not balance after current earnings: %',v_debit;
 END IF;

 IF NOT EXISTS(SELECT 1 FROM public.v_income_statement
     WHERE store_id=v_store AND account_code='4000' AND balance>0)
    OR NOT EXISTS(SELECT 1 FROM public.v_income_statement
     WHERE store_id=v_store AND account_code='5000' AND balance>0) THEN
   RAISE EXCEPTION 'Income statement does not show revenue and COGS with positive normal balances';
 END IF;

 -- Use a real same-store adjustment source so the test reaches the deferred balance guard.
 INSERT INTO public.stock_adjustments(id,store_id,adjustment_number,product_id,adjustment_type,
   reason,quantity,unit_id,cost_per_unit,total_value,created_by)
 VALUES('83000000-0000-4000-8000-000000000081',v_store,'ACC-ADJ-081',v_product,
   'INCREASE','unbalanced journal source fixture',1,'pcs',1,1,v_user);

 -- A malformed journal must be rejected by the deferred database invariant.
 BEGIN
   INSERT INTO public.journal_entries(id,store_id,entry_number,entry_date,source_type,source_id,
     total_debit,total_credit,posted_by)
   VALUES('83000000-0000-4000-8000-000000000080',v_store,'ACC-UNBALANCED',NOW(),
     'ADJUSTMENT','83000000-0000-4000-8000-000000000081',1,1,v_user);
   INSERT INTO public.general_ledger(store_id,journal_entry_id,account_id,entry_type,amount,
     reference_id,reference_table,created_by)
   SELECT v_store,'83000000-0000-4000-8000-000000000080',id,'DEBIT',1,
     '83000000-0000-4000-8000-000000000081','ADJUSTMENT',v_user
     FROM public.chart_of_accounts WHERE store_id=v_store AND account_code='1200';
   SET CONSTRAINTS trg_validate_journal_header_balance,trg_validate_general_ledger_balance IMMEDIATE;
   RAISE EXCEPTION 'Unbalanced journal was unexpectedly accepted';
 EXCEPTION WHEN SQLSTATE '23514' THEN
   GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
   IF v_error NOT LIKE 'Unbalanced journal %: lines debit %' THEN RAISE; END IF;
 END;

 -- View execution must honor authenticated RLS and expose only the caller's store.
 INSERT INTO public.stores(id,name)
 VALUES('10000000-0000-4000-8000-000000000003','Accounting Store B')
 ON CONFLICT(id) DO NOTHING;
 SET LOCAL ROLE authenticated;
 IF EXISTS(SELECT 1 FROM public.v_trial_balance
            WHERE store_id<>'10000000-0000-4000-8000-000000000001') THEN
   RAISE EXCEPTION 'Trial balance view leaked another store';
 END IF;
 RESET ROLE;

 RAISE NOTICE 'PASS: default COA, sale/purchase/payment/return journals, bank-vs-cash mapping, deferred balance guard and store-scoped trial balance';
END
$accounting_regression$;
