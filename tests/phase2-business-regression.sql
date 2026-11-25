-- Phase 2 business regression tests (PostgreSQL 16 + Auth shim).
-- These tests exercise real RPC transactions, not only migration compilation.
DO $phase2_test$
DECLARE
    v_store UUID := '10000000-0000-4000-8000-000000000001';
    v_auth UUID := '20000000-0000-4000-8000-000000000001';
    v_user UUID := '30000000-0000-4000-8000-000000000001';
    v_supplier UUID := '40000000-0000-4000-8000-000000000001';
    v_product UUID := '50000000-0000-4000-8000-000000000001';
    v_result JSONB;
    v_cost NUMERIC(18,4);
    v_stock NUMERIC(18,4);
    v_tax NUMERIC(18,4);
    v_total NUMERIC(18,4);
BEGIN
    INSERT INTO public.stores(id,name) VALUES(v_store,'Phase 2 RPC Test Store');
    INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
    VALUES(v_user,v_auth,v_store,'phase2_test_user','Phase 2 Test User',TRUE);
    INSERT INTO public.user_roles(user_id,role_id) VALUES(v_user,'owner');
    INSERT INTO public.suppliers(id,store_id,code,name,is_active)
    VALUES(v_supplier,v_store,'PH2-SUP-001','Phase 2 Test Supplier',TRUE);
    INSERT INTO public.products(id,store_id,name,primary_unit_id,cost_price,is_active)
    VALUES(v_product,v_store,'Weighted Cost Test','pcs',0,TRUE);

    PERFORM set_config('request.jwt.claim.sub',v_auth::text,TRUE);

    -- First receipt: 10 units at 10 DZD each.
    v_result := public.process_purchase(
      v_store,'60000000-0000-4000-8000-000000000001',
      jsonb_build_object(
        'id','70000000-0000-4000-8000-000000000001',
        'purchase_number','PH2-PUR-001','supplier_id',v_supplier,
        'paid_amount',0,
        'items',jsonb_build_array(jsonb_build_object(
          'product_id',v_product,'quantity',10,'unit_id','pcs',
          'unit_price',10,'cost_per_unit',10,'tax_rate',19
        ))
      )
    );
    IF (v_result->>'success')::boolean IS DISTINCT FROM TRUE THEN
      RAISE EXCEPTION 'First purchase RPC did not succeed: %',v_result;
    END IF;

    -- Second receipt: 10 units at 20 DZD; expected weighted cost = 15.
    v_result := public.process_purchase(
      v_store,'60000000-0000-4000-8000-000000000002',
      jsonb_build_object(
        'id','70000000-0000-4000-8000-000000000002',
        'purchase_number','PH2-PUR-002','supplier_id',v_supplier,
        'paid_amount',0,
        'items',jsonb_build_array(jsonb_build_object(
          'product_id',v_product,'quantity',10,'unit_id','pcs',
          'unit_price',20,'cost_per_unit',20,'tax_rate',19
        ))
      )
    );

    SELECT cost_price INTO v_cost FROM public.products WHERE id=v_product;
    SELECT quantity INTO v_stock FROM public.stock WHERE product_id=v_product AND location_id='main';
    SELECT tax_total,total_amount INTO v_tax,v_total FROM public.purchases
      WHERE id='70000000-0000-4000-8000-000000000002';

    IF v_cost IS DISTINCT FROM 15.0000 THEN
      RAISE EXCEPTION 'Weighted average cost expected 15, got %',v_cost;
    END IF;
    IF v_stock IS DISTINCT FROM 20.0000 THEN
      RAISE EXCEPTION 'Purchase stock expected 20, got %',v_stock;
    END IF;
    IF v_tax IS DISTINCT FROM 0.0000 OR v_total IS DISTINCT FROM 200.0000 THEN
      RAISE EXCEPTION 'D-029 purchase VAT must remain zero; tax %, total %',v_tax,v_total;
    END IF;

    -- Sale payload may contain a legacy tax_rate, but v1 must not calculate VAT.
    v_result := public.process_sale_invoice(
      v_store,'60000000-0000-4000-8000-000000000003',
      jsonb_build_object(
        'id','80000000-0000-4000-8000-000000000001',
        'invoice_number','PH2-INV-001','paid_amount',50,
        'payment_method','CASH',
        'items',jsonb_build_array(jsonb_build_object(
          'product_id',v_product,'quantity',1,'unit_id','pcs',
          'unit_price',50,'tax_rate',19
        ))
      )
    );
    SELECT tax_total,total_amount INTO v_tax,v_total FROM public.invoices
      WHERE id='80000000-0000-4000-8000-000000000001';
    IF v_tax IS DISTINCT FROM 0.0000 OR v_total IS DISTINCT FROM 50.0000 THEN
      RAISE EXCEPTION 'D-029 sale VAT must remain zero; tax %, total %',v_tax,v_total;
    END IF;

    RAISE NOTICE 'PASS: weighted average cost, purchase stock, purchase VAT deferral, sale VAT deferral';
END
$phase2_test$;

-- D-052: initial partial receipt, incremental receipt, replay, over-receipt rejection,
-- and final completion must update only the actually received stock.
DO $partial_receipt_test$
DECLARE
    v_store UUID := '10000000-0000-4000-8000-000000000001';
    v_auth UUID := '20000000-0000-4000-8000-000000000001';
    v_supplier UUID := '40000000-0000-4000-8000-000000000001';
    v_product UUID := '50000000-0000-4000-8000-000000000002';
    v_purchase UUID := '70000000-0000-4000-8000-000000000003';
    v_item UUID := '71000000-0000-4000-8000-000000000003';
    v_result JSONB;
    v_qty NUMERIC(18,4);
    v_received NUMERIC(18,4);
    v_status TEXT;
    v_cost NUMERIC(18,4);
BEGIN
    PERFORM set_config('request.jwt.claim.sub',v_auth::text,TRUE);
    INSERT INTO public.products(id,store_id,name,primary_unit_id,cost_price,is_active)
    VALUES(v_product,v_store,'Partial Receipt Test','pcs',10,TRUE);
    INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity)
    VALUES(v_product,'main',10,0);

    v_result:=public.process_purchase(
      v_store,'60000000-0000-4000-8000-000000000004',
      jsonb_build_object('id',v_purchase,'purchase_number','PH2-PUR-PARTIAL',
        'supplier_id',v_supplier,'paid_amount',0,
        'items',jsonb_build_array(jsonb_build_object('id',v_item,'product_id',v_product,
          'quantity',10,'received_quantity',4,'unit_id','pcs','unit_price',30,
          'cost_per_unit',30)))
    );
    SELECT quantity INTO v_qty FROM public.stock WHERE product_id=v_product AND location_id='main';
    SELECT received_quantity INTO v_received FROM public.purchase_items WHERE id=v_item;
    SELECT receiving_status INTO v_status FROM public.purchases WHERE id=v_purchase;
    SELECT cost_price INTO v_cost FROM public.products WHERE id=v_product;
    IF v_qty IS DISTINCT FROM 14 OR v_received IS DISTINCT FROM 4 OR v_status IS DISTINCT FROM 'PARTIAL'
       OR v_cost IS DISTINCT FROM 15.7143 THEN
      RAISE EXCEPTION 'Initial partial receipt mismatch: stock %, received %, status %, weighted cost %',v_qty,v_received,v_status,v_cost;
    END IF;

    v_result:=public.process_purchase_receipt(
      v_store,'60000000-0000-4000-8000-000000000005',
      jsonb_build_object('id','72000000-0000-4000-8000-000000000003','purchase_id',v_purchase,
        'items',jsonb_build_array(jsonb_build_object('purchase_item_id',v_item,'accepted_quantity',3,
          'rejected_quantity',2,'rejection_reason','Damaged packaging',
          'packaging_condition','TORN','photo_paths',jsonb_build_array('evidence/photo-1.jpg'))))
    );
    IF (v_result->>'replayed')::boolean IS DISTINCT FROM FALSE THEN RAISE EXCEPTION 'First receipt unexpectedly replayed'; END IF;

    -- Exact retry is idempotent.
    v_result:=public.process_purchase_receipt(
      v_store,'60000000-0000-4000-8000-000000000005',
      jsonb_build_object('id','72000000-0000-4000-8000-000000000003','purchase_id',v_purchase,
        'items',jsonb_build_array(jsonb_build_object('purchase_item_id',v_item,'quantity',3)))
    );
    IF (v_result->>'replayed')::boolean IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'Receipt retry was not idempotent'; END IF;

    SELECT quantity INTO v_qty FROM public.stock WHERE product_id=v_product AND location_id='main';
    IF v_qty IS DISTINCT FROM 17 THEN RAISE EXCEPTION 'Receipt replay duplicated stock or receipt stock mismatch: %',v_qty; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.purchase_receipt_items
       WHERE receipt_id='72000000-0000-4000-8000-000000000003'
         AND rejected_quantity=2 AND rejection_reason='Damaged packaging'
         AND packaging_condition='TORN' AND jsonb_array_length(photo_paths)=1) THEN
      RAISE EXCEPTION 'Rejected goods were not preserved in the receipt record';
    END IF;

    -- Over-receipt must roll back without changing the received quantity or stock.
    BEGIN
      PERFORM public.process_purchase_receipt(
        v_store,'60000000-0000-4000-8000-000000000006',
        jsonb_build_object('id','72000000-0000-4000-8000-000000000004','purchase_id',v_purchase,
          'items',jsonb_build_array(jsonb_build_object('purchase_item_id',v_item,'quantity',4)))
      );
      RAISE EXCEPTION 'Over-receipt unexpectedly succeeded';
    EXCEPTION WHEN check_violation THEN
      NULL;
    END;

    PERFORM public.process_purchase_receipt(
      v_store,'60000000-0000-4000-8000-000000000007',
      jsonb_build_object('id','72000000-0000-4000-8000-000000000005','purchase_id',v_purchase,
        'items',jsonb_build_array(jsonb_build_object('purchase_item_id',v_item,'quantity',3)))
    );
    SELECT quantity INTO v_qty FROM public.stock WHERE product_id=v_product AND location_id='main';
    SELECT received_quantity INTO v_received FROM public.purchase_items WHERE id=v_item;
    SELECT receiving_status INTO v_status FROM public.purchases WHERE id=v_purchase;
    IF v_qty IS DISTINCT FROM 20 OR v_received IS DISTINCT FROM 10 OR v_status IS DISTINCT FROM 'COMPLETE' THEN
      RAISE EXCEPTION 'Final receipt mismatch: stock %, received %, status %',v_qty,v_received,v_status;
    END IF;
    RAISE NOTICE 'PASS: partial receiving, idempotent receipt replay, over-receipt rejection, final completion';
END
$partial_receipt_test$;

-- D-014/D-015: returns must be capped by the original source line, use original
-- prices/costs, avoid automatic cash refunds, and preserve customer/supplier credits.
DO $returns_regression$
DECLARE
    v_store UUID := '10000000-0000-4000-8000-000000000001';
    v_auth UUID := '20000000-0000-4000-8000-000000000001';
    v_supplier UUID := '40000000-0000-4000-8000-000000000001';
    v_sale_product UUID := '50000000-0000-4000-8000-000000000001';
    v_purchase_product UUID := '50000000-0000-4000-8000-000000000002';
    v_customer UUID := '90000000-0000-4000-8000-000000000001';
    v_invoice UUID := '80000000-0000-4000-8000-000000000002';
    v_invoice_item UUID;
    v_result JSONB;
    v_stock NUMERIC(18,4);
    v_total NUMERIC(18,4);
    v_debt NUMERIC(18,4);
    v_credit NUMERIC(18,4);
    v_payments_before INTEGER;
    v_payments_after INTEGER;
BEGIN
    PERFORM set_config('request.jwt.claim.sub',v_auth::text,TRUE);

    -- Paid customer sale: return must create customer credit, not an outgoing payment.
    INSERT INTO public.customers(id,store_id,code,name,current_debt,credit_balance,is_active)
    VALUES(v_customer,v_store,'PH2-CUST-001','Return Credit Test',0,0,TRUE);
    v_result:=public.process_sale_invoice(
      v_store,'60000000-0000-4000-8000-000000000008',
      jsonb_build_object('id',v_invoice,'invoice_number','PH2-INV-CREDIT',
        'customer_id',v_customer,'paid_amount',50,'payment_method','CASH',
        'items',jsonb_build_array(jsonb_build_object('product_id',v_sale_product,
          'quantity',1,'unit_id','pcs','unit_price',50)))
    );
    SELECT id INTO v_invoice_item FROM public.invoice_items WHERE invoice_id=v_invoice;
    SELECT count(*) INTO v_payments_before FROM public.customer_payments WHERE customer_id=v_customer;

    v_result:=public.process_sale_return(
      v_store,'60000000-0000-4000-8000-000000000009',
      jsonb_build_object('id','91000000-0000-4000-8000-000000000001',
        'invoice_id',v_invoice,'return_number','PH2-SRET-001','refund_method','CREDIT',
        'return_condition','GOOD',
        'items',jsonb_build_array(jsonb_build_object('invoice_item_id',v_invoice_item,
          'product_id',v_sale_product,'quantity',1,'unit_id','pcs','unit_price',999)))
    );
    SELECT total_amount INTO v_total FROM public.sales_returns
      WHERE id='91000000-0000-4000-8000-000000000001';
    SELECT current_debt,credit_balance INTO v_debt,v_credit
      FROM public.customers WHERE id=v_customer;
    SELECT count(*) INTO v_payments_after FROM public.customer_payments WHERE customer_id=v_customer;
    IF v_total IS DISTINCT FROM 50 OR v_debt IS DISTINCT FROM 0 OR v_credit IS DISTINCT FROM 50
       OR v_payments_after IS DISTINCT FROM v_payments_before THEN
      RAISE EXCEPTION 'Sale return credit mismatch: total %, debt %, credit %, payments before/after %/%',
        v_total,v_debt,v_credit,v_payments_before,v_payments_after;
    END IF;

    -- Replaying the same sale return must not duplicate stock or customer credit.
    v_result:=public.process_sale_return(
      v_store,'60000000-0000-4000-8000-000000000009',
      jsonb_build_object('id','91000000-0000-4000-8000-000000000001',
        'invoice_id',v_invoice,'return_number','PH2-SRET-001','refund_method','CREDIT',
        'return_condition','GOOD',
        'items',jsonb_build_array(jsonb_build_object('invoice_item_id',v_invoice_item,
          'product_id',v_sale_product,'quantity',1,'unit_id','pcs','unit_price',999)))
    );
    IF (v_result->>'replayed')::boolean IS DISTINCT FROM TRUE THEN
      RAISE EXCEPTION 'Sale return retry was not idempotent';
    END IF;
    SELECT quantity INTO v_stock FROM public.stock WHERE product_id=v_sale_product AND location_id='main';
    IF v_stock IS DISTINCT FROM 19 THEN RAISE EXCEPTION 'Sale return stock mismatch: %',v_stock; END IF;

    -- A second return of the already-returned sold quantity must be rejected.
    BEGIN
      PERFORM public.process_sale_return(
        v_store,'60000000-0000-4000-8000-000000000010',
        jsonb_build_object('id','91000000-0000-4000-8000-000000000002',
          'invoice_id',v_invoice,'return_number','PH2-SRET-002',
          'items',jsonb_build_array(jsonb_build_object('invoice_item_id',v_invoice_item,
            'product_id',v_sale_product,'quantity',1,'unit_id','pcs')))
      );
      RAISE EXCEPTION 'Over-return unexpectedly succeeded';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    -- Purchase return is limited to quantities received on the exact purchase line.
    v_result:=public.process_purchase_return(
      v_store,'60000000-0000-4000-8000-000000000011',
      jsonb_build_object('id','92000000-0000-4000-8000-000000000001',
        'purchase_id','70000000-0000-4000-8000-000000000003',
        'return_number','PH2-PRET-001','refund_method','CREDIT',
        'items',jsonb_build_array(jsonb_build_object('purchase_item_id',
          '71000000-0000-4000-8000-000000000003','product_id',v_purchase_product,
          'quantity',2,'unit_id','pcs','unit_price',0)))
    );
    SELECT total_amount INTO v_total FROM public.purchase_returns
      WHERE id='92000000-0000-4000-8000-000000000001';
    SELECT quantity INTO v_stock FROM public.stock
      WHERE product_id=v_purchase_product AND location_id='main';
    SELECT current_debt,credit_balance INTO v_debt,v_credit
      FROM public.suppliers WHERE id=v_supplier;
    IF v_total IS DISTINCT FROM 60 OR v_stock IS DISTINCT FROM 18
       OR v_debt IS DISTINCT FROM 540 OR v_credit IS DISTINCT FROM 0 THEN
      RAISE EXCEPTION 'Purchase return mismatch: total %, stock %, supplier debt %, credit %',
        v_total,v_stock,v_debt,v_credit;
    END IF;

    BEGIN
      PERFORM public.process_purchase_return(
        v_store,'60000000-0000-4000-8000-000000000012',
        jsonb_build_object('id','92000000-0000-4000-8000-000000000002',
          'purchase_id','70000000-0000-4000-8000-000000000003',
          'return_number','PH2-PRET-002',
          'items',jsonb_build_array(jsonb_build_object('purchase_item_id',
            '71000000-0000-4000-8000-000000000003','product_id',v_purchase_product,
            'quantity',9,'unit_id','pcs')))
      );
      RAISE EXCEPTION 'Purchase over-return unexpectedly succeeded';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    RAISE NOTICE 'PASS: sale return source-line cap, original price, customer credit, no cash payout, purchase received-quantity cap and supplier ledger';
END
$returns_regression$;

-- D-054/D-056/D-057: authorized closure, approved excess, and explicit substitute.
DO $receiving_extensions_test$
DECLARE
 v_store UUID:='10000000-0000-4000-8000-000000000001';
 v_auth UUID:='20000000-0000-4000-8000-000000000001';
 v_user UUID:='30000000-0000-4000-8000-000000000001';
 v_supplier UUID:='40000000-0000-4000-8000-000000000001';
 v_excess_product UUID:='50000000-0000-4000-8000-000000000003';
 v_close_product UUID:='50000000-0000-4000-8000-000000000004';
 v_original_product UUID:='50000000-0000-4000-8000-000000000005';
 v_substitute_product UUID:='50000000-0000-4000-8000-000000000006';
 v_result JSONB; v_stock NUMERIC(18,4); v_total NUMERIC(18,4);
 v_received NUMERIC(18,4); v_excess NUMERIC(18,4); v_closed NUMERIC(18,4);
 v_status TEXT; v_debt_before NUMERIC(18,4); v_debt_after NUMERIC(18,4);
BEGIN
 PERFORM set_config('request.jwt.claim.sub',v_auth::text,TRUE);
 INSERT INTO public.products(id,store_id,name,primary_unit_id,cost_price,is_active) VALUES
  (v_excess_product,v_store,'Excess Receipt Product','pcs',0,TRUE),
  (v_close_product,v_store,'Close Remaining Product','pcs',0,TRUE),
  (v_original_product,v_store,'Original Ordered Product','pcs',0,TRUE),
  (v_substitute_product,v_store,'Approved Substitute Product','pcs',0,TRUE);

 -- D-056: the requested 5 and approved excess 2 are separately stored; both enter stock.
 v_result:=public.process_purchase(v_store,'60000000-0000-4000-8000-000000000013',
  jsonb_build_object('id','70000000-0000-4000-8000-000000000004',
   'purchase_number','PH2-PUR-EXCESS','supplier_id',v_supplier,'paid_amount',0,
   'items',jsonb_build_array(jsonb_build_object('id','71000000-0000-4000-8000-000000000004',
    'product_id',v_excess_product,'quantity',5,'received_quantity',0,'unit_id','pcs',
    'unit_price',20,'cost_per_unit',20))));
 SELECT current_debt INTO v_debt_before FROM public.suppliers WHERE id=v_supplier;
 v_result:=public.process_purchase_receipt(v_store,'60000000-0000-4000-8000-000000000014',
  jsonb_build_object('id','73000000-0000-4000-8000-000000000004',
   'purchase_id','70000000-0000-4000-8000-000000000004','approved_by',v_user,
   'items',jsonb_build_array(jsonb_build_object('purchase_item_id','71000000-0000-4000-8000-000000000004',
    'accepted_quantity',5,'excess_quantity',2,'excess_reason','Supplier delivered extra units'))));
 SELECT quantity INTO v_stock FROM public.stock WHERE product_id=v_excess_product AND location_id='main';
 SELECT received_quantity,excess_received_quantity INTO v_received,v_excess
  FROM public.purchase_items WHERE id='71000000-0000-4000-8000-000000000004';
 SELECT total_amount INTO v_total FROM public.purchases WHERE id='70000000-0000-4000-8000-000000000004';
 SELECT current_debt INTO v_debt_after FROM public.suppliers WHERE id=v_supplier;
 IF v_stock IS DISTINCT FROM 7 OR v_received IS DISTINCT FROM 5 OR v_excess IS DISTINCT FROM 2
    OR v_total IS DISTINCT FROM 140 OR v_debt_after-v_debt_before IS DISTINCT FROM 140 THEN
   RAISE EXCEPTION 'Approved excess receipt mismatch: stock %, received %, excess %, total %, debt delta %',
     v_stock,v_received,v_excess,v_total,v_debt_after-v_debt_before;
 END IF;

 -- D-054: close the remaining 3 of 5 after receiving 2; closed units never enter stock.
 v_result:=public.process_purchase(v_store,'60000000-0000-4000-8000-000000000015',
  jsonb_build_object('id','70000000-0000-4000-8000-000000000005',
   'purchase_number','PH2-PUR-CLOSE','supplier_id',v_supplier,'paid_amount',0,
   'items',jsonb_build_array(jsonb_build_object('id','71000000-0000-4000-8000-000000000005',
    'product_id',v_close_product,'quantity',5,'received_quantity',2,'unit_id','pcs',
    'unit_price',10,'cost_per_unit',10))));
 v_result:=public.process_purchase_close_remaining(v_store,'60000000-0000-4000-8000-000000000016',
  jsonb_build_object('id','74000000-0000-4000-8000-000000000005',
   'purchase_id','70000000-0000-4000-8000-000000000005','reason','Supplier discontinued remaining units',
   'items',jsonb_build_array(jsonb_build_object('purchase_item_id','71000000-0000-4000-8000-000000000005',
    'quantity',3))));
 SELECT quantity INTO v_stock FROM public.stock WHERE product_id=v_close_product AND location_id='main';
 SELECT closed_quantity INTO v_closed FROM public.purchase_items WHERE id='71000000-0000-4000-8000-000000000005';
 SELECT receiving_status INTO v_status FROM public.purchases WHERE id='70000000-0000-4000-8000-000000000005';
 IF v_stock IS DISTINCT FROM 2 OR v_closed IS DISTINCT FROM 3 OR v_status IS DISTINCT FROM 'CLOSED_PARTIAL'
    OR NOT EXISTS(SELECT 1 FROM public.purchase_closure_items WHERE closure_id='74000000-0000-4000-8000-000000000005') THEN
   RAISE EXCEPTION 'Close remaining mismatch: stock %, closed %, status %',v_stock,v_closed,v_status;
 END IF;

 -- D-057: explicit approved substitute updates only substitute stock and adjusts supplier value.
 v_result:=public.process_purchase(v_store,'60000000-0000-4000-8000-000000000017',
  jsonb_build_object('id','70000000-0000-4000-8000-000000000006',
   'purchase_number','PH2-PUR-SUB','supplier_id',v_supplier,'paid_amount',0,
   'items',jsonb_build_array(jsonb_build_object('id','71000000-0000-4000-8000-000000000006',
    'product_id',v_original_product,'quantity',3,'received_quantity',0,'unit_id','pcs',
    'unit_price',10,'cost_per_unit',10))));
 v_result:=public.process_purchase_receipt(v_store,'60000000-0000-4000-8000-000000000018',
  jsonb_build_object('id','73000000-0000-4000-8000-000000000006',
   'purchase_id','70000000-0000-4000-8000-000000000006','approved_by',v_user,
   'items',jsonb_build_array(jsonb_build_object('purchase_item_id','71000000-0000-4000-8000-000000000006',
    'accepted_quantity',3,'substitute_product_id',v_substitute_product,
    'substitute_cost_per_unit',15,'substitute_unit_price',15,'substitute_reason','Original unavailable; approved equivalent'))));
 SELECT COALESCE(SUM(quantity),0) INTO v_stock FROM public.stock WHERE product_id=v_original_product;
 IF v_stock<>0 OR NOT EXISTS(SELECT 1 FROM public.stock WHERE product_id=v_substitute_product AND quantity=3)
    OR NOT EXISTS(SELECT 1 FROM public.purchase_receipt_items WHERE receipt_id='73000000-0000-4000-8000-000000000006'
      AND original_product_id=v_original_product AND actual_product_id=v_substitute_product
      AND substitute_reason='Original unavailable; approved equivalent')
    OR (SELECT total_amount FROM public.purchases WHERE id='70000000-0000-4000-8000-000000000006')<>45 THEN
   RAISE EXCEPTION 'Approved substitute receipt mismatch';
 END IF;
 RAISE NOTICE 'PASS: rejected goods record, approved excess, approved substitute, and authorized partial closure';
END
$receiving_extensions_test$;
