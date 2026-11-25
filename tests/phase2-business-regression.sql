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
BEGIN
    PERFORM set_config('request.jwt.claim.sub',v_auth::text,TRUE);
    INSERT INTO public.products(id,store_id,name,primary_unit_id,cost_price,is_active)
    VALUES(v_product,v_store,'Partial Receipt Test','pcs',0,TRUE);

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
    IF v_qty IS DISTINCT FROM 4 OR v_received IS DISTINCT FROM 4 OR v_status IS DISTINCT FROM 'PARTIAL' THEN
      RAISE EXCEPTION 'Initial partial receipt mismatch: stock %, received %, status %',v_qty,v_received,v_status;
    END IF;

    v_result:=public.process_purchase_receipt(
      v_store,'60000000-0000-4000-8000-000000000005',
      jsonb_build_object('id','72000000-0000-4000-8000-000000000003','purchase_id',v_purchase,
        'items',jsonb_build_array(jsonb_build_object('purchase_item_id',v_item,'quantity',3)))
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
    IF v_qty IS DISTINCT FROM 7 THEN RAISE EXCEPTION 'Receipt replay duplicated stock: %',v_qty; END IF;

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
    IF v_qty IS DISTINCT FROM 10 OR v_received IS DISTINCT FROM 10 OR v_status IS DISTINCT FROM 'COMPLETE' THEN
      RAISE EXCEPTION 'Final receipt mismatch: stock %, received %, status %',v_qty,v_received,v_status;
    END IF;
    RAISE NOTICE 'PASS: partial receiving, idempotent receipt replay, over-receipt rejection, final completion';
END
$partial_receipt_test$;
