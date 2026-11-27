-- D-055: controlled purchase amendments after partial receipt.
-- Applies after ATACK_PLUS_PURCHASE_RECEIVING_EXTENSIONS.sql.

BEGIN;
-- D-055: amendments after receipt require an independent privileged permission.
INSERT INTO public.permissions(code,description)
VALUES ('purchases.edit_after_receipt','Authorize purchase amendments after receipt')
ON CONFLICT(code) DO NOTHING;
INSERT INTO public.role_permissions(role_id,permission_id)
SELECT r.role_id,p.id FROM (VALUES ('owner')) r(role_id)
JOIN public.permissions p ON p.code='purchases.edit_after_receipt'
ON CONFLICT(role_id,permission_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.purchase_amendments (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 store_id UUID NOT NULL REFERENCES public.stores(id),
 purchase_id UUID NOT NULL REFERENCES public.purchases(id) ON DELETE RESTRICT,
 operation_id UUID NOT NULL UNIQUE,
 reason TEXT NOT NULL,
 old_values_json JSONB NOT NULL,
 new_values_json JSONB NOT NULL,
 changed_by UUID NOT NULL REFERENCES public.users(id),
 changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_purchase_amendments_purchase ON public.purchase_amendments(purchase_id,changed_at);
ALTER TABLE public.purchase_amendments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS purchase_amendments_store_read ON public.purchase_amendments;
CREATE POLICY purchase_amendments_store_read ON public.purchase_amendments
 FOR SELECT TO authenticated USING(store_id=public.current_user_store_id());
DROP POLICY IF EXISTS purchase_amendments_deny_insert ON public.purchase_amendments;
DROP POLICY IF EXISTS purchase_amendments_deny_update ON public.purchase_amendments;
DROP POLICY IF EXISTS purchase_amendments_deny_delete ON public.purchase_amendments;
CREATE POLICY purchase_amendments_deny_insert ON public.purchase_amendments AS RESTRICTIVE
 FOR INSERT TO authenticated WITH CHECK(false);
CREATE POLICY purchase_amendments_deny_update ON public.purchase_amendments AS RESTRICTIVE
 FOR UPDATE TO authenticated USING(false) WITH CHECK(false);
CREATE POLICY purchase_amendments_deny_delete ON public.purchase_amendments AS RESTRICTIVE
 FOR DELETE TO authenticated USING(false);
CREATE TRIGGER trg_purchase_amendments_log_change AFTER INSERT OR UPDATE OR DELETE ON public.purchase_amendments
 FOR EACH ROW EXECUTE FUNCTION public.trg_log_change();

CREATE OR REPLACE FUNCTION public.process_purchase_amendment(
 p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,extensions,public,pg_temp
AS $purchase_amendment$
DECLARE
 v_user UUID; v_replay BOOLEAN; v_id UUID:=(p_payload->>'id')::UUID;
 v_purchase UUID:=(p_payload->>'purchase_id')::UUID;
 v_reason TEXT:=NULLIF(btrim(p_payload->>'reason'),'');
 v_supplier UUID; v_row JSONB; v_item UUID; v_product UUID; v_unit TEXT;
 v_old_qty NUMERIC(18,4); v_old_price NUMERIC(18,4); v_old_cost NUMERIC(18,4);
 v_received NUMERIC(18,4); v_returned NUMERIC(18,4); v_closed NUMERIC(18,4);
 v_new_qty NUMERIC(18,4); v_new_price NUMERIC(18,4); v_new_cost NUMERIC(18,4);
 v_primary TEXT; v_factor NUMERIC(18,6); v_product_cost NUMERIC(18,4); v_stock_qty NUMERIC(18,4);
 v_received_base NUMERIC(18,4); v_cost_delta NUMERIC(18,4);
 v_inventory_delta NUMERIC(18,4); v_cogs_delta NUMERIC(18,4); v_transit_delta NUMERIC(18,4);
 v_inventory_cost_total NUMERIC(18,4):=0; v_cogs_cost_total NUMERIC(18,4):=0;
 v_transit_cost_total NUMERIC(18,4):=0;
 v_delta NUMERIC(18,4):=0; v_debt_reduction NUMERIC(18,4):=0; v_credit_increase NUMERIC(18,4):=0;
 v_old JSONB:='[]'::jsonb; v_new JSONB:='[]'::jsonb;
BEGIN
 IF v_reason IS NULL THEN RAISE EXCEPTION 'Purchase amendment reason is required'; END IF;
 IF COALESCE(jsonb_typeof(p_payload->'items'),'')<>'array' OR jsonb_array_length(p_payload->'items')=0 THEN
   RAISE EXCEPTION 'Amendment items must be a non-empty JSON array';
 END IF;
 SELECT c.app_user_id,c.already_processed INTO v_user,v_replay FROM public._claim_business_operation(
   p_store_id,p_operation_id,'purchase_amendment',v_id,p_payload,'purchases.edit_after_receipt') c;
 IF v_replay THEN RETURN jsonb_build_object('success',TRUE,'replayed',TRUE,'amendment_id',v_id); END IF;

 SELECT supplier_id INTO v_supplier FROM public.purchases
  WHERE id=v_purchase AND store_id=p_store_id AND status<>'CANCELLED' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found or cancelled'; END IF;

 FOR v_row IN SELECT e.value FROM jsonb_array_elements(p_payload->'items') e(value)
              ORDER BY e.value->>'purchase_item_id'
 LOOP
   v_item:=(v_row->>'purchase_item_id')::UUID;
   SELECT product_id,quantity_unit_id,quantity,unit_price,cost_per_unit,received_quantity,closed_quantity
     INTO v_product,v_unit,v_old_qty,v_old_price,v_old_cost,v_received,v_closed
     FROM public.purchase_items WHERE id=v_item AND purchase_id=v_purchase FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Purchase item not found in this purchase'; END IF;
   SELECT COALESCE(SUM(pri.quantity),0) INTO v_returned
     FROM public.purchase_return_items pri WHERE pri.purchase_item_id=v_item;
   v_new_qty:=COALESCE(NULLIF(v_row->>'quantity','')::NUMERIC,v_old_qty);
   v_new_price:=COALESCE(NULLIF(v_row->>'unit_price','')::NUMERIC,v_old_price);
   v_new_cost:=COALESCE(NULLIF(v_row->>'cost_per_unit','')::NUMERIC,v_old_cost);
   IF v_new_qty<=0 OR v_new_price<0 OR v_new_cost<0 THEN RAISE EXCEPTION 'Invalid amended purchase values'; END IF;
   IF v_new_qty<v_received+v_returned+v_closed THEN
     RAISE EXCEPTION 'Amended ordered quantity cannot be below received, returned and closed quantity for item %',v_item
       USING ERRCODE='23514';
   END IF;
   -- Closed quantities were financially cancelled by the closure RPC; do not re-add them.
   v_delta:=v_delta+((v_new_qty-v_closed)*v_new_price)-((v_old_qty-v_closed)*v_old_price);
   v_old:=v_old||jsonb_build_array(jsonb_build_object('purchase_item_id',v_item,
     'quantity',v_old_qty,'unit_price',v_old_price,'cost_per_unit',v_old_cost,
     'received_quantity',v_received,'closed_quantity',v_closed));
   v_new:=v_new||jsonb_build_array(jsonb_build_object('purchase_item_id',v_item,
     'quantity',v_new_qty,'unit_price',v_new_price,'cost_per_unit',v_new_cost,
     'received_quantity',v_received,'closed_quantity',v_closed));

   -- Revalue only the on-hand portion of received units; the consumed portion adjusts COGS.
   v_cost_delta:=(v_received-v_returned)*(v_new_cost-v_old_cost);
   v_transit_delta:=((v_new_qty-v_received-v_closed)*v_new_cost)-
                    ((v_old_qty-v_received-v_closed)*v_old_cost);
   v_inventory_delta:=0;
   IF v_received>0 AND v_cost_delta<>0 THEN
     SELECT p.primary_unit_id,p.cost_price,
       CASE WHEN v_unit=p.primary_unit_id THEN 1 ELSE pu.conversion_factor END
       INTO v_primary,v_product_cost,v_factor
       FROM public.products p LEFT JOIN public.product_units pu
         ON pu.product_id=p.id AND pu.unit_id=v_unit
      WHERE p.id=v_product AND p.store_id=p_store_id
      FOR UPDATE OF p;
     IF NOT FOUND OR v_factor IS NULL OR v_factor<=0 THEN
       RAISE EXCEPTION 'Cannot revalue amended received stock: invalid product unit';
     END IF;
     SELECT GREATEST(COALESCE(SUM(quantity),0),0) INTO v_stock_qty
       FROM public.stock WHERE product_id=v_product;
     v_received_base:=(v_received-v_returned)*v_factor;
     IF v_stock_qty>0 THEN
       v_inventory_delta:=v_cost_delta*LEAST(v_received_base,v_stock_qty)/v_received_base;
       IF v_product_cost+(v_inventory_delta/v_stock_qty)<0 THEN
         RAISE EXCEPTION 'Amendment would make weighted average product cost negative';
       END IF;
       UPDATE public.products SET cost_price=round(cost_price+(v_inventory_delta/v_stock_qty),4),
         updated_at=NOW() WHERE id=v_product;
     END IF;
   END IF;
   v_cogs_delta:=v_cost_delta-v_inventory_delta;
   v_inventory_cost_total:=v_inventory_cost_total+v_inventory_delta;
   v_cogs_cost_total:=v_cogs_cost_total+v_cogs_delta;
   v_transit_cost_total:=v_transit_cost_total+v_transit_delta;

   UPDATE public.purchase_items SET quantity=v_new_qty,unit_price=v_new_price,
     cost_per_unit=v_new_cost,line_total=v_new_qty*v_new_price,
     received=(v_received>=v_new_qty),
     received_date=CASE WHEN v_received>=v_new_qty THEN COALESCE(received_date,NOW()) ELSE NULL END
    WHERE id=v_item;
 END LOOP;

 -- Persist the amendment source before emitting its supplier-ledger adjustment.
 -- The enclosing transaction rolls both back if any later financial step fails.
 INSERT INTO public.purchase_amendments(id,store_id,purchase_id,operation_id,reason,
   old_values_json,new_values_json,changed_by)
 VALUES(v_id,p_store_id,v_purchase,p_operation_id,v_reason,v_old,v_new,v_user);

 IF v_delta<>0 THEN
   UPDATE public.purchases SET subtotal=subtotal+v_delta,total_amount=total_amount+v_delta,
     remaining_amount=GREATEST(remaining_amount+v_delta,0),
     status=CASE WHEN GREATEST(remaining_amount+v_delta,0)=0 THEN 'PAID'
                 WHEN paid_amount>0 THEN 'PARTIAL' ELSE 'OPEN' END,
     updated_at=NOW() WHERE id=v_purchase;
   IF v_delta>0 THEN
     UPDATE public.suppliers SET current_debt=current_debt+v_delta,updated_at=NOW() WHERE id=v_supplier;
   ELSE
     SELECT LEAST(current_debt,-v_delta) INTO v_debt_reduction
       FROM public.suppliers WHERE id=v_supplier FOR UPDATE;
     v_credit_increase:=(-v_delta)-v_debt_reduction;
     UPDATE public.suppliers SET current_debt=current_debt-v_debt_reduction,
       credit_balance=credit_balance+v_credit_increase,updated_at=NOW() WHERE id=v_supplier;
   END IF;
   INSERT INTO public.supplier_ledger(supplier_id,type,amount,balance,reference_id,description,created_by)
   SELECT v_supplier,'ADJUSTMENT',v_delta,current_debt-credit_balance,v_id,
     'Purchase amendment '||v_id::text,v_user FROM public.suppliers WHERE id=v_supplier;
 END IF;

 UPDATE public.purchase_amendments
    SET debt_reduction=CASE WHEN v_delta<0 THEN v_debt_reduction ELSE 0 END,
        supplier_credit_created=v_credit_increase,
        inventory_cost_delta=v_inventory_cost_total,
        cogs_cost_delta=v_cogs_cost_total,
        transit_cost_delta=v_transit_cost_total
  WHERE id=v_id;
 INSERT INTO public.audit_logs(store_id,user_id,entity_type,entity_id,action,old_values_json,new_values_json)
 VALUES(p_store_id,v_user,'PURCHASE_AMENDMENT',v_id,'UPDATE',v_old,
   jsonb_build_object('items',v_new,'reason',v_reason));

 UPDATE public.purchases p SET receiving_status=CASE
   WHEN EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id AND pi.closed_quantity>0) THEN 'CLOSED_PARTIAL'
   WHEN NOT EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id AND pi.received_quantity<pi.quantity) THEN 'COMPLETE'
   WHEN EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id AND pi.received_quantity>0) THEN 'PARTIAL'
   ELSE 'PENDING' END,updated_at=NOW() WHERE p.id=v_purchase;

 RETURN jsonb_build_object('success',TRUE,'replayed',FALSE,'amendment_id',v_id,'financial_delta',v_delta);
END;
$purchase_amendment$;

REVOKE ALL ON FUNCTION public.process_purchase_amendment(UUID,UUID,JSONB) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.process_purchase_amendment(UUID,UUID,JSONB) TO authenticated;
COMMIT;
