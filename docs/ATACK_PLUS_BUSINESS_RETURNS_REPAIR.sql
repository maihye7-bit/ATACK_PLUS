-- ATACK PLUS business return corrections.
-- Apply after Phase 1, Phase 2, and Phase 3 SQL migrations.
-- Aligns returns with D-014/D-015 and binds each return to its original source line.

BEGIN;

-- Preserve customer/supplier credits separately from outstanding debt.
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS credit_balance NUMERIC(18,4) NOT NULL DEFAULT 0;
ALTER TABLE public.customers DROP CONSTRAINT IF EXISTS customers_credit_balance_check;
ALTER TABLE public.customers ADD CONSTRAINT customers_credit_balance_check CHECK (credit_balance >= 0);
ALTER TABLE public.suppliers ADD COLUMN IF NOT EXISTS credit_balance NUMERIC(18,4) NOT NULL DEFAULT 0;
ALTER TABLE public.suppliers DROP CONSTRAINT IF EXISTS suppliers_credit_balance_check;
ALTER TABLE public.suppliers ADD CONSTRAINT suppliers_credit_balance_check CHECK (credit_balance >= 0);

-- Bind return lines to the exact original invoice/purchase line and preserve unit/cost snapshots.
ALTER TABLE public.return_items ADD COLUMN IF NOT EXISTS invoice_item_id UUID;
ALTER TABLE public.return_items ADD COLUMN IF NOT EXISTS quantity_unit_id TEXT;
ALTER TABLE public.return_items ADD COLUMN IF NOT EXISTS cost_per_unit NUMERIC(18,4) NOT NULL DEFAULT 0;
ALTER TABLE public.return_items ADD COLUMN IF NOT EXISTS return_condition TEXT NOT NULL DEFAULT 'GOOD';
ALTER TABLE public.return_items DROP CONSTRAINT IF EXISTS return_items_invoice_item_id_fkey;
ALTER TABLE public.return_items ADD CONSTRAINT return_items_invoice_item_id_fkey
  FOREIGN KEY (invoice_item_id) REFERENCES public.invoice_items(id) ON DELETE RESTRICT;
ALTER TABLE public.return_items DROP CONSTRAINT IF EXISTS return_items_quantity_unit_id_fkey;
ALTER TABLE public.return_items ADD CONSTRAINT return_items_quantity_unit_id_fkey
  FOREIGN KEY (quantity_unit_id) REFERENCES public.units(id) ON DELETE RESTRICT;
ALTER TABLE public.return_items DROP CONSTRAINT IF EXISTS return_items_return_condition_check;
ALTER TABLE public.return_items ADD CONSTRAINT return_items_return_condition_check
  CHECK (return_condition IN ('GOOD','DEFECTIVE','UNSALEABLE'));

ALTER TABLE public.purchase_return_items ADD COLUMN IF NOT EXISTS purchase_item_id UUID;
ALTER TABLE public.purchase_return_items DROP CONSTRAINT IF EXISTS purchase_return_items_purchase_item_id_fkey;
ALTER TABLE public.purchase_return_items ADD CONSTRAINT purchase_return_items_purchase_item_id_fkey
  FOREIGN KEY (purchase_item_id) REFERENCES public.purchase_items(id) ON DELETE RESTRICT;
CREATE INDEX IF NOT EXISTS idx_return_items_source_invoice_item ON public.return_items(invoice_item_id);
CREATE INDEX IF NOT EXISTS idx_purchase_return_items_source_purchase_item ON public.purchase_return_items(purchase_item_id);

-- The Phase 1 seed omitted the permission required by the existing purchase-return RPC.
INSERT INTO public.permissions(code,description)
VALUES ('purchases.return','Authorize purchase returns')
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.role_permissions(role_id,permission_id)
SELECT r.role_id,p.id
  FROM (VALUES ('owner')) AS r(role_id)
  CROSS JOIN public.permissions p
 WHERE p.code='purchases.return'
ON CONFLICT (role_id,permission_id) DO NOTHING;

-- The return ledger event is a first-class supplier-ledger movement.
ALTER TABLE public.supplier_ledger DROP CONSTRAINT IF EXISTS supplier_ledger_type_check;
ALTER TABLE public.supplier_ledger ADD CONSTRAINT supplier_ledger_type_check
  CHECK (type IN ('PURCHASE','PAYMENT','RETURN','ADJUSTMENT'));

CREATE OR REPLACE FUNCTION public.process_sale_return(
    p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,extensions,public,pg_temp
AS $sale_return$
DECLARE
    v_user UUID; v_replay BOOLEAN;
    v_return_id UUID := (p_payload->>'id')::UUID;
    v_invoice_id UUID := (p_payload->>'invoice_id')::UUID;
    v_return_number TEXT := NULLIF(btrim(p_payload->>'return_number'),'');
    v_refund_method TEXT := COALESCE(NULLIF(p_payload->>'refund_method',''),'CREDIT');
    v_location TEXT := COALESCE(NULLIF(p_payload->>'location_id',''),'main');
    v_customer UUID; v_customer_debt NUMERIC(18,4); v_customer_credit NUMERIC(18,4);
    v_total NUMERIC(18,4):=0; v_applied NUMERIC(18,4); v_new_credit NUMERIC(18,4);
    v_item JSONB; v_product UUID; v_item_id UUID; v_qty NUMERIC(18,4);
    v_original_qty NUMERIC(18,4); v_returned_qty NUMERIC(18,4);
    v_unit TEXT; v_original_unit TEXT; v_factor NUMERIC(18,6); v_primary TEXT;
    v_original_line_total NUMERIC(18,4); v_unit_price NUMERIC(18,4);
    v_cost NUMERIC(18,4); v_line_qty NUMERIC(18,4); v_line_total NUMERIC(18,4);
    v_old_qty NUMERIC(18,4); v_current_cost NUMERIC(18,4); v_new_cost NUMERIC(18,4);
    v_condition TEXT; v_batch TEXT; v_expiry TIMESTAMPTZ; v_stock UUID;
BEGIN
    IF v_refund_method<>'CREDIT' THEN
      RAISE EXCEPTION 'Automatic cash/card refunds are disabled; return value is credited to the customer';
    END IF;
    IF COALESCE(jsonb_typeof(p_payload->'items'),'')<>'array' OR jsonb_array_length(p_payload->'items')=0 THEN
      RAISE EXCEPTION 'Return items must be a non-empty JSON array';
    END IF;

    SELECT c.app_user_id,c.already_processed INTO v_user,v_replay
      FROM public._claim_business_operation(p_store_id,p_operation_id,'sale_return',v_return_id,p_payload,'sales.write') c;
    IF v_replay THEN RETURN jsonb_build_object('success',TRUE,'replayed',TRUE,'return_id',v_return_id); END IF;
    v_location:=public.resolve_store_location_id(p_store_id,v_location);

    SELECT customer_id INTO v_customer FROM public.invoices
     WHERE id=v_invoice_id AND store_id=p_store_id AND type='SALE' AND status<>'CANCELLED'
     FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Original sale invoice not found or not valid for return'; END IF;

    INSERT INTO public.sales_returns(id,store_id,return_number,original_invoice_id,reason,
      refund_method,total_amount,created_by)
    VALUES(v_return_id,p_store_id,v_return_number,v_invoice_id,p_payload->>'reason','CREDIT',0,v_user);

    FOR v_item IN SELECT e.value FROM jsonb_array_elements(p_payload->'items') e(value)
                  ORDER BY COALESCE(e.value->>'invoice_item_id',e.value->>'product_id')
    LOOP
      v_product:=(v_item->>'product_id')::UUID;
      v_qty:=(v_item->>'quantity')::NUMERIC;
      v_item_id:=NULLIF(v_item->>'invoice_item_id','')::UUID;
      v_unit:=NULLIF(v_item->>'unit_id','');
      v_condition:=COALESCE(NULLIF(v_item->>'return_condition',''),NULLIF(p_payload->>'return_condition',''),'GOOD');
      IF v_qty IS NULL OR v_qty<=0 THEN RAISE EXCEPTION 'Invalid return quantity'; END IF;
      IF v_condition NOT IN ('GOOD','DEFECTIVE','UNSALEABLE') THEN RAISE EXCEPTION 'Invalid return condition'; END IF;

      IF v_item_id IS NULL THEN
        SELECT ii.id,ii.quantity,ii.quantity_unit_id,ii.line_total,COALESCE(ii.cost_per_unit,p.cost_price,0),
               ii.batch_number,ii.expiry_date
          INTO v_item_id,v_original_qty,v_original_unit,v_original_line_total,v_cost,v_batch,v_expiry
          FROM public.invoice_items ii JOIN public.products p ON p.id=ii.product_id
         WHERE ii.invoice_id=v_invoice_id AND ii.product_id=v_product
           AND (v_unit IS NULL OR ii.quantity_unit_id=v_unit)
           AND ii.quantity-COALESCE((SELECT SUM(ri.quantity) FROM public.return_items ri
                                     WHERE ri.invoice_item_id=ii.id),0)>=v_qty
         ORDER BY ii.id LIMIT 1 FOR UPDATE OF ii;
      ELSE
        SELECT ii.quantity,ii.quantity_unit_id,ii.line_total,COALESCE(ii.cost_per_unit,p.cost_price,0),
               ii.batch_number,ii.expiry_date
          INTO v_original_qty,v_original_unit,v_original_line_total,v_cost,v_batch,v_expiry
          FROM public.invoice_items ii JOIN public.products p ON p.id=ii.product_id
         WHERE ii.id=v_item_id AND ii.invoice_id=v_invoice_id AND ii.product_id=v_product
         FOR UPDATE;
      END IF;
      IF v_item_id IS NULL THEN RAISE EXCEPTION 'Return quantity exceeds unreturned original sale quantity' USING ERRCODE='23514'; END IF;
      IF v_unit IS NOT NULL AND v_unit<>v_original_unit THEN RAISE EXCEPTION 'Return unit must match original invoice line unit'; END IF;

      SELECT COALESCE(SUM(ri.quantity),0) INTO v_returned_qty
        FROM public.return_items ri WHERE ri.invoice_item_id=v_item_id;
      IF v_returned_qty+v_qty>v_original_qty THEN
        RAISE EXCEPTION 'Return quantity exceeds sold quantity for invoice item %',v_item_id USING ERRCODE='23514';
      END IF;

      SELECT p.primary_unit_id,
             CASE WHEN v_original_unit=p.primary_unit_id THEN 1 ELSE pu.conversion_factor END,
             p.cost_price
        INTO v_primary,v_factor,v_current_cost
        FROM public.products p LEFT JOIN public.product_units pu
          ON pu.product_id=p.id AND pu.unit_id=v_original_unit
       WHERE p.id=v_product AND p.store_id=p_store_id AND p.is_active
       FOR UPDATE OF p;
      v_cost:=COALESCE(v_cost,v_current_cost,0);
      IF v_factor IS NULL OR v_factor<=0 THEN RAISE EXCEPTION 'Original invoice unit conversion is invalid'; END IF;

      v_line_qty:=v_qty*v_factor;
      v_line_total:=round((v_original_line_total/v_original_qty)*v_qty,4);
      v_unit_price:=round(v_line_total/v_qty,4);
      v_batch:=COALESCE(NULLIF(v_item->>'batch_number',''),v_batch);
      v_expiry:=COALESCE(NULLIF(v_item->>'expiry_date','')::TIMESTAMPTZ,v_expiry);

      INSERT INTO public.return_items(return_id,product_id,quantity,unit_price,line_total,
        batch_number,expiry_date,invoice_item_id,quantity_unit_id,cost_per_unit,return_condition)
      VALUES(v_return_id,v_product,v_qty,v_unit_price,v_line_total,v_batch,v_expiry,
        v_item_id,v_original_unit,v_cost,v_condition);

      IF v_condition='GOOD' THEN
        INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity)
        VALUES(v_product,v_location,0,0) ON CONFLICT(product_id,location_id) DO NOTHING;
        PERFORM 1 FROM public.stock WHERE product_id=v_product ORDER BY location_id FOR UPDATE;
        SELECT COALESCE(SUM(quantity),0) INTO v_old_qty FROM public.stock WHERE product_id=v_product;
        SELECT id INTO v_stock FROM public.stock
         WHERE product_id=v_product AND location_id=v_location;
        UPDATE public.stock SET quantity=quantity+v_line_qty WHERE id=v_stock;
        v_new_cost:=CASE WHEN v_old_qty<=0 THEN v_cost
          ELSE round(((v_old_qty*v_current_cost)+(v_line_qty*v_cost))/(v_old_qty+v_line_qty),4) END;
        UPDATE public.products SET cost_price=v_new_cost,updated_at=NOW() WHERE id=v_product;
        INSERT INTO public.stock_movements(product_id,location_id,type,quantity,unit_id,cost_per_unit,total_value,
          reference_id,reference_type,batch_number,expiry_date,reason,user_id)
        VALUES(v_product,v_location,'RETURN_IN',v_line_qty,v_primary,v_cost,v_line_qty*v_cost,
          v_return_id,'return',v_batch,v_expiry,'Good sale return '||v_return_number,v_user);
      END IF;
      v_total:=v_total+v_line_total;
    END LOOP;

    UPDATE public.sales_returns SET total_amount=v_total WHERE id=v_return_id;
    IF v_customer IS NOT NULL THEN
      SELECT current_debt,credit_balance INTO v_customer_debt,v_customer_credit
        FROM public.customers WHERE id=v_customer AND store_id=p_store_id FOR UPDATE;
      v_applied:=LEAST(v_customer_debt,v_total);
      v_new_credit:=v_total-v_applied;
      UPDATE public.customers SET current_debt=current_debt-v_applied,
        credit_balance=credit_balance+v_new_credit,updated_at=NOW()
       WHERE id=v_customer;
      INSERT INTO public.customer_ledgers(customer_id,type,amount,balance,reference_id,description,created_by)
      VALUES(v_customer,'RETURN',-v_total,
        (v_customer_debt-v_applied)-(v_customer_credit+v_new_credit),
        v_return_id,'Sale return '||v_return_number,v_user);
      UPDATE public.sales_returns
         SET applied_to_debt=v_applied,customer_credit_created=v_new_credit
       WHERE id=v_return_id;
    END IF;

    RETURN jsonb_build_object('success',TRUE,'replayed',FALSE,'return_id',v_return_id,'total_amount',v_total);
END;
$sale_return$;

CREATE OR REPLACE FUNCTION public.process_purchase_return(
    p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,extensions,public,pg_temp
AS $purchase_return$
DECLARE
    v_user UUID; v_replay BOOLEAN;
    v_return_id UUID := (p_payload->>'id')::UUID;
    v_purchase_id UUID := (p_payload->>'purchase_id')::UUID;
    v_return_number TEXT := NULLIF(btrim(p_payload->>'return_number'),'');
    v_refund_method TEXT := COALESCE(NULLIF(p_payload->>'refund_method',''),'CREDIT');
    v_location TEXT := COALESCE(NULLIF(p_payload->>'location_id',''),'main');
    v_supplier UUID; v_supplier_debt NUMERIC(18,4); v_supplier_credit NUMERIC(18,4);
    v_total NUMERIC(18,4):=0; v_applied NUMERIC(18,4); v_new_credit NUMERIC(18,4);
    v_item JSONB; v_product UUID; v_item_id UUID; v_qty NUMERIC(18,4);
    v_ordered NUMERIC(18,4); v_received NUMERIC(18,4); v_returned NUMERIC(18,4);
    v_unit TEXT; v_original_unit TEXT; v_factor NUMERIC(18,6); v_primary TEXT;
    v_cost NUMERIC(18,4); v_line_qty NUMERIC(18,4); v_line_total NUMERIC(18,4);
    v_stock UUID; v_available NUMERIC(18,4); v_batch TEXT; v_expiry TIMESTAMPTZ;
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

    INSERT INTO public.purchase_returns(id,store_id,return_number,original_purchase_id,reason,
      refund_method,total_amount,created_by)
    VALUES(v_return_id,p_store_id,v_return_number,v_purchase_id,p_payload->>'reason','CREDIT',0,v_user);

    FOR v_item IN SELECT e.value FROM jsonb_array_elements(p_payload->'items') e(value)
                  ORDER BY COALESCE(e.value->>'purchase_item_id',e.value->>'product_id')
    LOOP
      v_product:=(v_item->>'product_id')::UUID;
      v_qty:=(v_item->>'quantity')::NUMERIC;
      v_item_id:=NULLIF(v_item->>'purchase_item_id','')::UUID;
      v_unit:=NULLIF(v_item->>'unit_id','');
      IF v_qty IS NULL OR v_qty<=0 THEN RAISE EXCEPTION 'Invalid purchase return quantity'; END IF;

      IF v_item_id IS NULL THEN
        SELECT pi.id,pi.quantity,pi.received_quantity,pi.quantity_unit_id,pi.cost_per_unit,
               pi.batch_number,pi.expiry_date
          INTO v_item_id,v_ordered,v_received,v_original_unit,v_cost,v_batch,v_expiry
          FROM public.purchase_items pi
         WHERE pi.purchase_id=v_purchase_id AND pi.product_id=v_product
           AND (v_unit IS NULL OR pi.quantity_unit_id=v_unit)
           AND pi.received_quantity-COALESCE((SELECT SUM(pri.quantity) FROM public.purchase_return_items pri
                                               WHERE pri.purchase_item_id=pi.id),0)>=v_qty
         ORDER BY pi.id LIMIT 1 FOR UPDATE OF pi;
      ELSE
        SELECT pi.quantity,pi.received_quantity,pi.quantity_unit_id,pi.cost_per_unit,
               pi.batch_number,pi.expiry_date
          INTO v_ordered,v_received,v_original_unit,v_cost,v_batch,v_expiry
          FROM public.purchase_items pi
         WHERE pi.id=v_item_id AND pi.purchase_id=v_purchase_id AND pi.product_id=v_product
         FOR UPDATE;
      END IF;
      IF v_item_id IS NULL THEN RAISE EXCEPTION 'Return quantity exceeds received and unreturned purchase quantity' USING ERRCODE='23514'; END IF;
      IF v_unit IS NOT NULL AND v_unit<>v_original_unit THEN RAISE EXCEPTION 'Return unit must match original purchase line unit'; END IF;

      SELECT COALESCE(SUM(pri.quantity),0) INTO v_returned
        FROM public.purchase_return_items pri WHERE pri.purchase_item_id=v_item_id;
      IF v_returned+v_qty>v_received THEN
        RAISE EXCEPTION 'Purchase return exceeds quantity received on original purchase item %',v_item_id USING ERRCODE='23514';
      END IF;

      SELECT p.primary_unit_id,
             CASE WHEN v_original_unit=p.primary_unit_id THEN 1 ELSE pu.conversion_factor END
        INTO v_primary,v_factor
        FROM public.products p LEFT JOIN public.product_units pu
          ON pu.product_id=p.id AND pu.unit_id=v_original_unit
       WHERE p.id=v_product AND p.store_id=p_store_id AND p.is_active;
      IF v_factor IS NULL OR v_factor<=0 THEN RAISE EXCEPTION 'Original purchase unit conversion is invalid'; END IF;

      v_line_qty:=v_qty*v_factor;
      v_line_total:=v_qty*v_cost;
      v_batch:=COALESCE(NULLIF(v_item->>'batch_number',''),v_batch);
      v_expiry:=COALESCE(NULLIF(v_item->>'expiry_date','')::TIMESTAMPTZ,v_expiry);

      SELECT s.id,s.quantity-s.reserved_quantity INTO v_stock,v_available
        FROM public.stock s WHERE s.product_id=v_product AND s.location_id=v_location FOR UPDATE;
      IF v_stock IS NULL OR v_available<v_line_qty THEN
        RAISE EXCEPTION 'Insufficient available stock in location % for purchase return',v_location USING ERRCODE='23514';
      END IF;

      INSERT INTO public.purchase_return_items(return_id,product_id,quantity,quantity_unit_id,unit_price,
        line_total,batch_number,expiry_date,purchase_item_id)
      VALUES(v_return_id,v_product,v_qty,v_original_unit,v_cost,v_line_total,v_batch,v_expiry,v_item_id);

      UPDATE public.stock SET quantity=quantity-v_line_qty WHERE id=v_stock;
      INSERT INTO public.stock_movements(product_id,location_id,type,quantity,unit_id,cost_per_unit,total_value,
        reference_id,reference_type,batch_number,expiry_date,reason,user_id)
      VALUES(v_product,v_location,'RETURN_OUT',v_line_qty,v_primary,v_cost/v_factor,v_line_qty*(v_cost/v_factor),
        v_return_id,'return',v_batch,v_expiry,'Purchase return '||v_return_number,v_user);
      v_total:=v_total+v_line_total;
    END LOOP;

    UPDATE public.purchase_returns SET total_amount=v_total WHERE id=v_return_id;
    SELECT current_debt,credit_balance INTO v_supplier_debt,v_supplier_credit
      FROM public.suppliers WHERE id=v_supplier AND store_id=p_store_id FOR UPDATE;
    v_applied:=LEAST(v_supplier_debt,v_total);
    v_new_credit:=v_total-v_applied;
    UPDATE public.suppliers SET current_debt=current_debt-v_applied,
      credit_balance=credit_balance+v_new_credit,updated_at=NOW()
     WHERE id=v_supplier;
    INSERT INTO public.supplier_ledger(supplier_id,type,amount,balance,reference_id,description,created_by)
    VALUES(v_supplier,'RETURN',-v_total,(v_supplier_debt-v_applied)-(v_supplier_credit+v_new_credit),
      v_return_id,'Purchase return '||v_return_number,v_user);

    RETURN jsonb_build_object('success',TRUE,'replayed',FALSE,'return_id',v_return_id,'total_amount',v_total);
END;
$purchase_return$;

REVOKE ALL ON FUNCTION public.process_sale_return(UUID,UUID,JSONB) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.process_purchase_return(UUID,UUID,JSONB) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.process_sale_return(UUID,UUID,JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_purchase_return(UUID,UUID,JSONB) TO authenticated;

COMMIT;
