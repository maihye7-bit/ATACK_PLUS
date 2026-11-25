-- D-053/D-057: purchase returns are linked to the exact accepted receipt line,
-- including approved substitute products and approved excess quantities.

BEGIN;
ALTER TABLE public.purchase_return_items ADD COLUMN IF NOT EXISTS purchase_item_id UUID;
ALTER TABLE public.purchase_return_items ADD COLUMN IF NOT EXISTS purchase_receipt_item_id UUID;
ALTER TABLE public.purchase_return_items DROP CONSTRAINT IF EXISTS purchase_return_items_purchase_item_id_fkey;
ALTER TABLE public.purchase_return_items ADD CONSTRAINT purchase_return_items_purchase_item_id_fkey
 FOREIGN KEY(purchase_item_id) REFERENCES public.purchase_items(id) ON DELETE RESTRICT;
ALTER TABLE public.purchase_return_items DROP CONSTRAINT IF EXISTS purchase_return_items_purchase_receipt_item_id_fkey;
ALTER TABLE public.purchase_return_items ADD CONSTRAINT purchase_return_items_purchase_receipt_item_id_fkey
 FOREIGN KEY(purchase_receipt_item_id) REFERENCES public.purchase_receipt_items(id) ON DELETE RESTRICT;
CREATE INDEX IF NOT EXISTS idx_purchase_return_items_receipt_source ON public.purchase_return_items(purchase_receipt_item_id);

CREATE OR REPLACE FUNCTION public.process_purchase_return(
 p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,extensions,public,pg_temp
AS $purchase_return_v2$
DECLARE
 v_user UUID; v_replay BOOLEAN; v_return_id UUID:=(p_payload->>'id')::UUID;
 v_purchase_id UUID:=(p_payload->>'purchase_id')::UUID;
 v_return_number TEXT:=NULLIF(btrim(p_payload->>'return_number'),'');
 v_location TEXT:=COALESCE(NULLIF(p_payload->>'location_id',''),'main');
 v_refund_method TEXT:=COALESCE(NULLIF(p_payload->>'refund_method',''),'CREDIT');
 v_supplier UUID; v_supplier_debt NUMERIC(18,4); v_supplier_credit NUMERIC(18,4);
 v_total NUMERIC(18,4):=0; v_applied NUMERIC(18,4); v_new_credit NUMERIC(18,4);
 v_row JSONB; v_product UUID; v_item UUID; v_receipt_item UUID;
 v_qty NUMERIC(18,4); v_received NUMERIC(18,4); v_returned NUMERIC(18,4);
 v_unit TEXT; v_primary TEXT; v_factor NUMERIC(18,6);
 v_cost NUMERIC(18,4); v_price NUMERIC(18,4); v_line_qty NUMERIC(18,4); v_line_total NUMERIC(18,4);
 v_stock UUID; v_available NUMERIC(18,4); v_batch TEXT; v_expiry TIMESTAMPTZ;
 v_old_qty NUMERIC(18,4); v_current_cost NUMERIC(18,4); v_new_cost NUMERIC(18,4);
BEGIN
 IF v_location NOT IN ('main','warehouse','storage') THEN RAISE EXCEPTION 'Invalid stock location'; END IF;
 IF v_refund_method<>'CREDIT' THEN
   RAISE EXCEPTION 'Automatic cash/bank refunds are disabled; return value is credited to the supplier';
 END IF;
 IF COALESCE(jsonb_typeof(p_payload->'items'),'')<>'array' OR jsonb_array_length(p_payload->'items')=0 THEN
   RAISE EXCEPTION 'Return items must be a non-empty JSON array';
 END IF;
 SELECT c.app_user_id,c.already_processed INTO v_user,v_replay
  FROM public._claim_business_operation(p_store_id,p_operation_id,'purchase_return',v_return_id,p_payload,'purchases.return') c;
 IF v_replay THEN RETURN jsonb_build_object('success',TRUE,'replayed',TRUE,'return_id',v_return_id); END IF;
 SELECT supplier_id INTO v_supplier FROM public.purchases
  WHERE id=v_purchase_id AND store_id=p_store_id AND status<>'CANCELLED' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Original purchase not found or cancelled'; END IF;
 INSERT INTO public.purchase_returns(id,store_id,return_number,original_purchase_id,reason,refund_method,total_amount,created_by)
 VALUES(v_return_id,p_store_id,v_return_number,v_purchase_id,p_payload->>'reason','CREDIT',0,v_user);

 FOR v_row IN SELECT e.value FROM jsonb_array_elements(p_payload->'items') e(value)
              ORDER BY COALESCE(e.value->>'purchase_receipt_item_id',e.value->>'purchase_item_id',e.value->>'product_id')
 LOOP
   v_qty:=(v_row->>'quantity')::NUMERIC;
   v_receipt_item:=NULLIF(v_row->>'purchase_receipt_item_id','')::UUID;
   v_item:=NULLIF(v_row->>'purchase_item_id','')::UUID;
   IF v_qty IS NULL OR v_qty<=0 THEN RAISE EXCEPTION 'Invalid purchase return quantity'; END IF;

   IF v_receipt_item IS NOT NULL THEN
     SELECT pri.purchase_item_id,pri.actual_product_id,
       pri.accepted_quantity+pri.excess_quantity,pri.quantity_unit_id,pri.unit_cost,pri.unit_price,
       pri.batch_number,pri.expiry_date
      INTO v_item,v_product,v_received,v_unit,v_cost,v_price,v_batch,v_expiry
      FROM public.purchase_receipt_items pri JOIN public.purchase_receipts pr ON pr.id=pri.receipt_id
     WHERE pri.id=v_receipt_item AND pr.purchase_id=v_purchase_id AND pr.store_id=p_store_id
     FOR UPDATE OF pri;
     IF NOT FOUND THEN RAISE EXCEPTION 'Receipt line not found in original purchase'; END IF;
     SELECT COALESCE(SUM(quantity),0) INTO v_returned FROM public.purchase_return_items
       WHERE purchase_receipt_item_id=v_receipt_item;
   ELSE
     IF v_item IS NULL THEN
       SELECT pi.id INTO v_item FROM public.purchase_items pi
        WHERE pi.purchase_id=v_purchase_id AND pi.product_id=(v_row->>'product_id')::UUID
          AND (NULLIF(v_row->>'unit_id','') IS NULL OR pi.quantity_unit_id=v_row->>'unit_id')
          AND pi.received_quantity+pi.excess_received_quantity-
            COALESCE((SELECT SUM(pri.quantity) FROM public.purchase_return_items pri
                       WHERE pri.purchase_item_id=pi.id),0)>=v_qty
        ORDER BY pi.id LIMIT 1 FOR UPDATE;
     END IF;
     SELECT pi.product_id,pi.received_quantity+pi.excess_received_quantity,pi.quantity_unit_id,
       pi.cost_per_unit,pi.unit_price,pi.batch_number,pi.expiry_date
      INTO v_product,v_received,v_unit,v_cost,v_price,v_batch,v_expiry
      FROM public.purchase_items pi WHERE pi.id=v_item AND pi.purchase_id=v_purchase_id FOR UPDATE;
     IF NOT FOUND THEN RAISE EXCEPTION 'Purchase item not found in original purchase'; END IF;
     SELECT COALESCE(SUM(quantity),0) INTO v_returned FROM public.purchase_return_items
       WHERE purchase_item_id=v_item;
   END IF;
   IF NULLIF(v_row->>'product_id','') IS NOT NULL AND (v_row->>'product_id')::UUID<>v_product THEN
     RAISE EXCEPTION 'Returned product must match the actual product received';
   END IF;
   IF v_returned+v_qty>v_received THEN
     RAISE EXCEPTION 'Purchase return exceeds accepted received quantity' USING ERRCODE='23514';
   END IF;

   SELECT p.primary_unit_id,
     CASE WHEN v_unit=p.primary_unit_id THEN 1 ELSE pu.conversion_factor END,
     p.cost_price
    INTO v_primary,v_factor,v_current_cost FROM public.products p
    LEFT JOIN public.product_units pu ON pu.product_id=p.id AND pu.unit_id=v_unit
   WHERE p.id=v_product AND p.store_id=p_store_id AND p.is_active
   FOR UPDATE OF p;
   IF v_factor IS NULL OR v_factor<=0 THEN RAISE EXCEPTION 'Original receipt unit conversion is invalid'; END IF;
   v_line_qty:=v_qty*v_factor;
   v_line_total:=v_qty*v_price;
   v_batch:=COALESCE(NULLIF(v_row->>'batch_number',''),v_batch);
   v_expiry:=COALESCE(NULLIF(v_row->>'expiry_date','')::TIMESTAMPTZ,v_expiry);

   PERFORM 1 FROM public.stock WHERE product_id=v_product ORDER BY location_id FOR UPDATE;
   SELECT COALESCE(SUM(quantity),0) INTO v_old_qty FROM public.stock WHERE product_id=v_product;
   SELECT s.id,s.quantity-s.reserved_quantity INTO v_stock,v_available
    FROM public.stock s WHERE s.product_id=v_product AND s.location_id=v_location;
   IF v_stock IS NULL OR v_available<v_line_qty THEN
     RAISE EXCEPTION 'Insufficient available stock in location % for purchase return',v_location USING ERRCODE='23514';
   END IF;

   INSERT INTO public.purchase_return_items(return_id,product_id,quantity,quantity_unit_id,unit_price,line_total,
     batch_number,expiry_date,purchase_item_id,purchase_receipt_item_id)
   VALUES(v_return_id,v_product,v_qty,v_unit,v_price,v_line_total,v_batch,v_expiry,v_item,v_receipt_item);
   UPDATE public.stock SET quantity=quantity-v_line_qty WHERE id=v_stock;
   v_new_cost:=CASE WHEN v_old_qty-v_line_qty<=0 THEN 0
     ELSE GREATEST(round(((v_old_qty*v_current_cost)-(v_line_qty*(v_cost/v_factor)))/(v_old_qty-v_line_qty),4),0) END;
   UPDATE public.products SET cost_price=v_new_cost,updated_at=NOW() WHERE id=v_product;
   INSERT INTO public.stock_movements(product_id,location_id,type,quantity,unit_id,cost_per_unit,total_value,
     reference_id,reference_type,batch_number,expiry_date,reason,user_id)
   VALUES(v_product,v_location,'RETURN_OUT',v_line_qty,v_primary,v_cost/v_factor,v_line_qty*(v_cost/v_factor),
     v_return_id,'return',v_batch,v_expiry,'Purchase return '||v_return_number,v_user);
   v_total:=v_total+v_line_total;
 END LOOP;

 UPDATE public.purchase_returns SET total_amount=v_total WHERE id=v_return_id;
 SELECT current_debt,credit_balance INTO v_supplier_debt,v_supplier_credit
  FROM public.suppliers WHERE id=v_supplier AND store_id=p_store_id FOR UPDATE;
 v_applied:=LEAST(v_supplier_debt,v_total); v_new_credit:=v_total-v_applied;
 UPDATE public.suppliers SET current_debt=current_debt-v_applied,
   credit_balance=credit_balance+v_new_credit,updated_at=NOW() WHERE id=v_supplier;
 INSERT INTO public.supplier_ledger(supplier_id,type,amount,balance,reference_id,description,created_by)
 VALUES(v_supplier,'RETURN',-v_total,(v_supplier_debt-v_applied)-(v_supplier_credit+v_new_credit),
   v_return_id,'Purchase return '||v_return_number,v_user);
 UPDATE public.purchase_returns
    SET applied_to_debt=v_applied,supplier_credit_created=v_new_credit
  WHERE id=v_return_id;
 RETURN jsonb_build_object('success',TRUE,'replayed',FALSE,'return_id',v_return_id,'total_amount',v_total);
END;
$purchase_return_v2$;

REVOKE ALL ON FUNCTION public.process_purchase_return(UUID,UUID,JSONB) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.process_purchase_return(UUID,UUID,JSONB) TO authenticated;
COMMIT;
