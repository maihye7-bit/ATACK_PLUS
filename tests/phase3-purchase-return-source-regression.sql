-- Stage 3 purchase-return source and quantity regression.
-- Runs after BUSINESS_RETURNS_REPAIR, PURCHASE_RETURN_RECEIPT_LINK and accounting hardening.
BEGIN;

DO $purchase_return_source_regression$
DECLARE
  v_store UUID := '10000000-0000-4000-8000-000000000001';
  v_auth UUID := '20000000-0000-4000-8000-000000000001';
  v_user UUID := '30000000-0000-4000-8000-000000000001';
  v_supplier UUID := '40000000-0000-4000-8000-000000000001';
  v_product UUID := '50000000-0000-4000-8000-000000000001';
  v_purchase UUID := '93000000-0000-4000-8000-000000000001';
  v_purchase_item UUID := '94000000-0000-4000-8000-000000000001';
  v_receipt_a UUID := '95000000-0000-4000-8000-000000000001';
  v_receipt_b UUID := '95000000-0000-4000-8000-000000000002';
  v_receipt_item_a UUID := '96000000-0000-4000-8000-000000000001';
  v_receipt_item_b UUID := '96000000-0000-4000-8000-000000000002';
  v_return_a UUID := '97000000-0000-4000-8000-000000000001';
  v_return_b UUID := '97000000-0000-4000-8000-000000000002';
  v_return_c UUID := '97000000-0000-4000-8000-000000000003';
  v_result JSONB;
  v_error TEXT;
  v_failed BOOLEAN;
  v_qty NUMERIC(18,4);
BEGIN
  PERFORM set_config('request.jwt.claim.sub',v_auth::TEXT,TRUE);

  INSERT INTO public.purchases(
    id,store_id,purchase_number,supplier_id,purchase_date,subtotal,total_amount,
    paid_amount,remaining_amount,created_by,status
  ) VALUES (
    v_purchase,v_store,'PH3-PR-SOURCE-001',v_supplier,NOW(),40,40,40,0,v_user,'PAID'
  );

  INSERT INTO public.purchase_items(
    id,purchase_id,product_id,quantity,quantity_unit_id,unit_price,cost_per_unit,
    line_total,received_quantity,excess_received_quantity,closed_quantity
  ) VALUES (
    v_purchase_item,v_purchase,v_product,4,'pcs',10,10,40,4,0,0
  );

  INSERT INTO public.purchase_receipts(
    id,store_id,purchase_id,receipt_number,operation_id,received_by
  ) VALUES
    (v_receipt_a,v_store,v_purchase,'PH3-PR-RECEIPT-A',
     '98000000-0000-4000-8000-000000000001',v_user),
    (v_receipt_b,v_store,v_purchase,'PH3-PR-RECEIPT-B',
     '98000000-0000-4000-8000-000000000002',v_user);

  INSERT INTO public.purchase_receipt_items(
    id,store_id,receipt_id,purchase_item_id,original_product_id,actual_product_id,
    ordered_quantity,accepted_quantity,excess_quantity,rejected_quantity,
    quantity_unit_id,unit_cost,unit_price
  ) VALUES
    (v_receipt_item_a,v_store,v_receipt_a,v_purchase_item,v_product,v_product,2,2,0,0,'pcs',10,10),
    (v_receipt_item_b,v_store,v_receipt_b,v_purchase_item,v_product,v_product,2,2,0,0,'pcs',10,10);

  INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity)
  VALUES(v_product,'main',5,0)
  ON CONFLICT(product_id,location_id)
  DO UPDATE SET quantity=public.stock.quantity+5,reserved_quantity=0;

  -- First return uses the purchase-item compatibility path for three of four received units.
  v_result:=public.process_purchase_return(
    v_store,'98000000-0000-4000-8000-000000000011',
    jsonb_build_object(
      'id',v_return_a,'purchase_id',v_purchase,'return_number','PH3-PR-RETURN-A',
      'refund_method','CREDIT',
      'items',jsonb_build_array(jsonb_build_object(
        'purchase_item_id',v_purchase_item,'product_id',v_product,
        'quantity',3,'unit_id','pcs'
      ))
    )
  );
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE
     OR (v_result->>'total_amount')::NUMERIC<>30 THEN
    RAISE EXCEPTION 'Initial purchase-item return did not use the original purchase-line value: %',v_result;
  END IF;

  -- A receipt-specific second return must count the first purchase-item return too.
  -- The receipt line itself has two accepted units, but the purchase line has only one
  -- unreturned unit left after the first three-unit return.
  v_failed:=FALSE;
  BEGIN
    PERFORM public.process_purchase_return(
      v_store,'98000000-0000-4000-8000-000000000012',
      jsonb_build_object(
        'id',v_return_b,'purchase_id',v_purchase,'return_number','PH3-PR-RETURN-B',
        'refund_method','CREDIT',
        'items',jsonb_build_array(jsonb_build_object(
          'purchase_item_id',v_purchase_item,'purchase_receipt_item_id',v_receipt_item_a,
          'product_id',v_product,'quantity',2,'unit_id','pcs'
        ))
      )
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed:=TRUE;
    v_error:=SQLERRM;
  END;
  IF NOT v_failed OR position('aggregate across all receipt paths' IN COALESCE(v_error,''))=0 THEN
    RAISE EXCEPTION 'Cross-path purchase over-return was not rejected by the purchase-line aggregate guard: %',v_error;
  END IF;

  IF EXISTS(SELECT 1 FROM public.purchase_returns WHERE id=v_return_b)
     OR EXISTS(SELECT 1 FROM public.stock_movements WHERE reference_id=v_return_b AND reference_type='return') THEN
    RAISE EXCEPTION 'Rejected purchase return left partial business or inventory effects';
  END IF;

  SELECT COALESCE(SUM(quantity),0) INTO v_qty
    FROM public.purchase_return_items WHERE purchase_item_id=v_purchase_item;
  IF v_qty<>3 THEN
    RAISE EXCEPTION 'Purchase return quantity was not preserved after rejected retry: %',v_qty;
  END IF;

  -- D-015: supplier returns create supplier credit, never an automatic cash payout.
  v_failed:=FALSE;
  BEGIN
    PERFORM public.process_purchase_return(
      v_store,'98000000-0000-4000-8000-000000000013',
      jsonb_build_object(
        'id',v_return_c,'purchase_id',v_purchase,'return_number','PH3-PR-RETURN-C',
        'refund_method','CASH',
        'items',jsonb_build_array(jsonb_build_object(
          'purchase_item_id',v_purchase_item,'product_id',v_product,
          'quantity',1,'unit_id','pcs'
        ))
      )
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed:=TRUE;
    v_error:=SQLERRM;
  END;
  IF NOT v_failed OR position('Automatic cash/bank refunds are disabled' IN COALESCE(v_error,''))=0 THEN
    RAISE EXCEPTION 'Purchase return unexpectedly allowed an automatic cash refund: %',v_error;
  END IF;

  RAISE NOTICE 'PASS: purchase returns enforce original source, aggregate received quantity across receipt and compatibility paths, atomic rejection, and supplier-credit-only settlement';
END;
$purchase_return_source_regression$;

ROLLBACK;
