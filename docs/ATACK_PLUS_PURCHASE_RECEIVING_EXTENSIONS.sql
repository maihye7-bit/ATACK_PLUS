-- D-052 through D-059: durable receipt records, rejected/excess/substitute goods,
-- and authorized closure of outstanding purchase quantities.
-- Apply after ATACK_PLUS_BUSINESS_RETURNS_REPAIR.sql.

BEGIN;

-- D-054: closing undeliverable purchase remainder is a separate privileged action.
INSERT INTO public.permissions(code,description)
VALUES ('purchases.close_remaining','Authorize closing unreceived purchase quantities')
ON CONFLICT(code) DO NOTHING;
INSERT INTO public.role_permissions(role_id,permission_id)
SELECT r.role_id,p.id FROM (VALUES ('owner')) r(role_id)
JOIN public.permissions p ON p.code='purchases.close_remaining'
ON CONFLICT(role_id,permission_id) DO NOTHING;

ALTER TABLE public.purchase_items ADD COLUMN IF NOT EXISTS excess_received_quantity NUMERIC(18,4) NOT NULL DEFAULT 0;
ALTER TABLE public.purchase_items ADD COLUMN IF NOT EXISTS closed_quantity NUMERIC(18,4) NOT NULL DEFAULT 0;
ALTER TABLE public.purchase_items DROP CONSTRAINT IF EXISTS purchase_items_excess_received_quantity_check;
ALTER TABLE public.purchase_items ADD CONSTRAINT purchase_items_excess_received_quantity_check CHECK (excess_received_quantity>=0);
ALTER TABLE public.purchase_items DROP CONSTRAINT IF EXISTS purchase_items_closed_quantity_check;
ALTER TABLE public.purchase_items ADD CONSTRAINT purchase_items_closed_quantity_check
  CHECK (closed_quantity>=0 AND received_quantity+closed_quantity<=quantity);

ALTER TABLE public.purchases DROP CONSTRAINT IF EXISTS purchases_receiving_status_check;
ALTER TABLE public.purchases ADD CONSTRAINT purchases_receiving_status_check
  CHECK (receiving_status IN ('PENDING','PARTIAL','COMPLETE','CLOSED','CLOSED_PARTIAL'));

CREATE TABLE IF NOT EXISTS public.purchase_receipts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id UUID NOT NULL REFERENCES public.stores(id),
  purchase_id UUID NOT NULL REFERENCES public.purchases(id) ON DELETE RESTRICT,
  receipt_number TEXT NOT NULL,
  operation_id UUID NOT NULL UNIQUE,
  received_by UUID NOT NULL REFERENCES public.users(id),
  approved_by UUID REFERENCES public.users(id),
  notes TEXT,
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(store_id,receipt_number)
);
CREATE TABLE IF NOT EXISTS public.purchase_receipt_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id UUID NOT NULL REFERENCES public.stores(id),
  receipt_id UUID NOT NULL REFERENCES public.purchase_receipts(id) ON DELETE CASCADE,
  purchase_item_id UUID NOT NULL REFERENCES public.purchase_items(id) ON DELETE RESTRICT,
  original_product_id UUID NOT NULL REFERENCES public.products(id),
  actual_product_id UUID NOT NULL REFERENCES public.products(id),
  ordered_quantity NUMERIC(18,4) NOT NULL,
  accepted_quantity NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(accepted_quantity>=0),
  excess_quantity NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(excess_quantity>=0),
  rejected_quantity NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(rejected_quantity>=0),
  quantity_unit_id TEXT NOT NULL REFERENCES public.units(id),
  unit_cost NUMERIC(18,4) NOT NULL CHECK(unit_cost>=0),
  unit_price NUMERIC(18,4) NOT NULL CHECK(unit_price>=0),
  excess_reason TEXT,
  rejection_reason TEXT,
  packaging_condition TEXT,
  photo_paths JSONB NOT NULL DEFAULT '[]'::jsonb,
  substitute_reason TEXT,
  batch_number TEXT,
  expiry_date TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_purchase_receipts_purchase ON public.purchase_receipts(purchase_id,received_at);
CREATE INDEX IF NOT EXISTS idx_purchase_receipt_items_item ON public.purchase_receipt_items(purchase_item_id);
ALTER TABLE public.purchase_receipt_items ADD COLUMN IF NOT EXISTS batch_number TEXT;
ALTER TABLE public.purchase_receipt_items ADD COLUMN IF NOT EXISTS expiry_date TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS idx_purchase_receipt_items_actual_product ON public.purchase_receipt_items(actual_product_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_purchase_receipt_item_per_line ON public.purchase_receipt_items(receipt_id,purchase_item_id);
ALTER TABLE public.purchase_receipt_items DROP CONSTRAINT IF EXISTS purchase_receipt_items_photo_paths_array_check;
ALTER TABLE public.purchase_receipt_items ADD CONSTRAINT purchase_receipt_items_photo_paths_array_check
  CHECK (jsonb_typeof(photo_paths)='array');

CREATE TABLE IF NOT EXISTS public.purchase_closures (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id UUID NOT NULL REFERENCES public.stores(id),
  purchase_id UUID NOT NULL REFERENCES public.purchases(id) ON DELETE RESTRICT,
  operation_id UUID NOT NULL UNIQUE,
  reason TEXT NOT NULL,
  closed_by UUID NOT NULL REFERENCES public.users(id),
  closed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS public.purchase_closure_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id UUID NOT NULL REFERENCES public.stores(id),
  closure_id UUID NOT NULL REFERENCES public.purchase_closures(id) ON DELETE CASCADE,
  purchase_item_id UUID NOT NULL REFERENCES public.purchase_items(id) ON DELETE RESTRICT,
  quantity NUMERIC(18,4) NOT NULL CHECK(quantity>0),
  reason TEXT NOT NULL
);

-- Record pre-existing initial receipts once, preserving legacy rows.
INSERT INTO public.purchase_receipts(store_id,purchase_id,receipt_number,operation_id,received_by,notes)
SELECT p.store_id,p.id,'INITIAL-'||p.purchase_number,gen_random_uuid(),p.created_by,'Backfilled initial receipt from legacy purchase creation'
  FROM public.purchases p
 WHERE EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id AND pi.received_quantity>0)
   AND NOT EXISTS(SELECT 1 FROM public.purchase_receipts pr WHERE pr.purchase_id=p.id);
INSERT INTO public.purchase_receipt_items(store_id,receipt_id,purchase_item_id,original_product_id,actual_product_id,
  ordered_quantity,accepted_quantity,quantity_unit_id,unit_cost,unit_price,batch_number,expiry_date)
SELECT p.store_id,pr.id,pi.id,pi.product_id,pi.product_id,pi.quantity,pi.received_quantity,
  pi.quantity_unit_id,pi.cost_per_unit,pi.unit_price,pi.batch_number,pi.expiry_date
 FROM public.purchase_items pi JOIN public.purchases p ON p.id=pi.purchase_id
 JOIN public.purchase_receipts pr ON pr.purchase_id=p.id AND pr.notes='Backfilled initial receipt from legacy purchase creation'
WHERE pi.received_quantity>0
  AND NOT EXISTS(SELECT 1 FROM public.purchase_receipt_items pri WHERE pri.purchase_item_id=pi.id);

-- Special permissions are intentionally restricted to owner/admin.
INSERT INTO public.permissions(code,description) VALUES
 ('purchases.close_remaining','Close outstanding purchase quantities with reason'),
 ('purchases.receive_excess','Approve excess purchase receipt'),
 ('purchases.receive_substitute','Approve substitute product receipt'),
 ('purchases.edit_after_receipt','Amend purchase after partial receipt')
ON CONFLICT(code) DO NOTHING;
INSERT INTO public.role_permissions(role_id,permission_id)
SELECT r.role_id,p.id FROM (VALUES('owner')) r(role_id)
JOIN public.permissions p ON p.code IN
 ('purchases.close_remaining','purchases.receive_excess','purchases.receive_substitute','purchases.edit_after_receipt')
ON CONFLICT(role_id,permission_id) DO NOTHING;

-- RLS: store-scoped reads; all writes go through SECURITY DEFINER RPCs.
DO $rls$
DECLARE t TEXT;
BEGIN
 FOREACH t IN ARRAY ARRAY['purchase_receipts','purchase_receipt_items','purchase_closures','purchase_closure_items'] LOOP
   EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
   EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',t||'_store_read',t);
   EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (store_id=public.current_user_store_id())',t||'_store_read',t);
   EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',t||'_deny_insert',t);
   EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',t||'_deny_update',t);
   EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',t||'_deny_delete',t);
   EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK(false)',t||'_deny_insert',t);
   EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR UPDATE TO authenticated USING(false) WITH CHECK(false)',t||'_deny_update',t);
   EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR DELETE TO authenticated USING(false)',t||'_deny_delete',t);
 END LOOP;
END
$rls$;

CREATE TRIGGER trg_purchase_receipts_log_change AFTER INSERT OR UPDATE OR DELETE ON public.purchase_receipts
 FOR EACH ROW EXECUTE FUNCTION public.trg_log_change();
CREATE TRIGGER trg_purchase_receipt_items_log_change AFTER INSERT OR UPDATE OR DELETE ON public.purchase_receipt_items
 FOR EACH ROW EXECUTE FUNCTION public.trg_log_change();
CREATE TRIGGER trg_purchase_closures_log_change AFTER INSERT OR UPDATE OR DELETE ON public.purchase_closures
 FOR EACH ROW EXECUTE FUNCTION public.trg_log_change();
CREATE TRIGGER trg_purchase_closure_items_log_change AFTER INSERT OR UPDATE OR DELETE ON public.purchase_closure_items
 FOR EACH ROW EXECUTE FUNCTION public.trg_log_change();

-- Wrap the existing purchase RPC so initial quantities also receive durable receipt records.
DO $rename_purchase$
BEGIN
 IF to_regprocedure('public.process_purchase_base(uuid,uuid,jsonb)') IS NULL THEN
   ALTER FUNCTION public.process_purchase(UUID,UUID,JSONB) RENAME TO process_purchase_base;
 END IF;
END
$rename_purchase$;
REVOKE ALL ON FUNCTION public.process_purchase_base(UUID,UUID,JSONB) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.process_purchase(
 p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,extensions,public,pg_temp
AS $purchase_wrapper$
DECLARE
 v_result JSONB; v_purchase UUID; v_user UUID; v_receipt UUID;
 v_number TEXT; v_location TEXT:=COALESCE(NULLIF(p_payload->>'location_id',''),'main');
BEGIN
 v_result:=public.process_purchase_base(p_store_id,p_operation_id,p_payload);
 IF COALESCE((v_result->>'replayed')::boolean,FALSE) THEN RETURN v_result; END IF;
 v_purchase:=(v_result->>'purchase_id')::UUID;
 SELECT id INTO v_user FROM public.users WHERE auth_user_id=auth.uid() AND store_id=p_store_id AND is_active;
 SELECT purchase_number INTO v_number FROM public.purchases WHERE id=v_purchase;
 IF EXISTS(SELECT 1 FROM public.purchase_items WHERE purchase_id=v_purchase AND received_quantity>0) THEN
   INSERT INTO public.purchase_receipts(store_id,purchase_id,receipt_number,operation_id,received_by,notes)
   VALUES(p_store_id,v_purchase,'INITIAL-'||v_number,p_operation_id,v_user,'Initial receipt during purchase creation')
   RETURNING id INTO v_receipt;
   INSERT INTO public.purchase_receipt_items(store_id,receipt_id,purchase_item_id,original_product_id,actual_product_id,
     ordered_quantity,accepted_quantity,quantity_unit_id,unit_cost,unit_price,batch_number,expiry_date)
   SELECT p_store_id,v_receipt,pi.id,pi.product_id,pi.product_id,pi.quantity,pi.received_quantity,
     pi.quantity_unit_id,pi.cost_per_unit,pi.unit_price,pi.batch_number,pi.expiry_date
    FROM public.purchase_items pi WHERE pi.purchase_id=v_purchase AND pi.received_quantity>0;
 END IF;
 RETURN v_result;
END;
$purchase_wrapper$;
REVOKE ALL ON FUNCTION public.process_purchase(UUID,UUID,JSONB) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.process_purchase(UUID,UUID,JSONB) TO authenticated;

CREATE OR REPLACE FUNCTION public.process_purchase_receipt(
 p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,extensions,public,pg_temp
AS $receipt_rpc$
DECLARE
 v_user UUID; v_replay BOOLEAN; v_receipt UUID:=(p_payload->>'id')::UUID;
 v_purchase UUID:=(p_payload->>'purchase_id')::UUID;
 v_location TEXT:=COALESCE(NULLIF(p_payload->>'location_id',''),'main');
 v_number TEXT; v_row JSONB; v_item UUID; v_product UUID; v_actual UUID;
 v_qty NUMERIC(18,4); v_excess NUMERIC(18,4); v_rejected NUMERIC(18,4);
 v_ordered NUMERIC(18,4); v_received NUMERIC(18,4); v_closed NUMERIC(18,4);
 v_unit TEXT; v_primary TEXT; v_factor NUMERIC(18,6); v_cost NUMERIC(18,4);
 v_price NUMERIC(18,4); v_actual_cost NUMERIC(18,4); v_actual_price NUMERIC(18,4);
 v_old_qty NUMERIC(18,4); v_old_cost NUMERIC(18,4); v_base NUMERIC(18,4);
 v_stock UUID; v_supplier UUID; v_excess_value NUMERIC(18,4):=0;
 v_accepted_total NUMERIC(18,4):=0; v_excess_total NUMERIC(18,4):=0;
 v_rejected_total NUMERIC(18,4):=0; v_reason TEXT; v_sub_reason TEXT;
 v_purchase_delta NUMERIC(18,4):=0; v_debt_reduction NUMERIC(18,4):=0; v_credit_increase NUMERIC(18,4):=0;
 v_approver UUID; v_batch TEXT; v_expiry TIMESTAMPTZ;
BEGIN
 IF v_location NOT IN ('main','warehouse','storage') THEN RAISE EXCEPTION 'Invalid stock location'; END IF;
 IF COALESCE(jsonb_typeof(p_payload->'items'),'')<>'array' OR jsonb_array_length(p_payload->'items')=0 THEN
   RAISE EXCEPTION 'Receipt items must be a non-empty JSON array';
 END IF;
 SELECT c.app_user_id,c.already_processed INTO v_user,v_replay
  FROM public._claim_business_operation(p_store_id,p_operation_id,'purchase_receipt',v_receipt,p_payload,'purchases.receive') c;
 IF v_replay THEN RETURN jsonb_build_object('success',TRUE,'replayed',TRUE,'receipt_id',v_receipt); END IF;
 SELECT purchase_number,supplier_id INTO v_number,v_supplier FROM public.purchases
  WHERE id=v_purchase AND store_id=p_store_id AND status<>'CANCELLED' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found or cancelled'; END IF;
 v_approver:=NULLIF(p_payload->>'approved_by','')::UUID;
 INSERT INTO public.purchase_receipts(id,store_id,purchase_id,receipt_number,operation_id,received_by,approved_by,notes)
 VALUES(v_receipt,p_store_id,v_purchase,'RCV-'||v_receipt::text,p_operation_id,v_user,v_approver,p_payload->>'notes');

 FOR v_row IN SELECT e.value FROM jsonb_array_elements(p_payload->'items') e(value)
              ORDER BY e.value->>'purchase_item_id'
 LOOP
   v_item:=(v_row->>'purchase_item_id')::UUID;
   v_qty:=COALESCE(NULLIF(v_row->>'accepted_quantity','')::NUMERIC,NULLIF(v_row->>'quantity','')::NUMERIC,0);
   v_excess:=COALESCE(NULLIF(v_row->>'excess_quantity','')::NUMERIC,0);
   v_rejected:=COALESCE(NULLIF(v_row->>'rejected_quantity','')::NUMERIC,0);
   v_reason:=NULLIF(v_row->>'rejection_reason','');
   v_sub_reason:=NULLIF(v_row->>'substitute_reason','');
   IF v_qty<0 OR v_excess<0 OR v_rejected<0 OR (v_qty+v_excess+v_rejected)=0 THEN
     RAISE EXCEPTION 'Receipt quantities must be non-negative and at least one must be positive';
   END IF;
   IF v_rejected>0 AND v_reason IS NULL THEN RAISE EXCEPTION 'Rejection reason is required'; END IF;
   IF v_excess>0 THEN
     IF NOT public.has_store_permission(p_store_id,'purchases.receive_excess') OR v_approver IS DISTINCT FROM v_user
       OR NULLIF(v_row->>'excess_reason','') IS NULL THEN
       RAISE EXCEPTION 'Excess receipt requires special permission, approval and reason' USING ERRCODE='42501';
     END IF;
   END IF;

   SELECT pi.product_id,pi.quantity,pi.received_quantity,pi.closed_quantity,pi.quantity_unit_id,
          pi.cost_per_unit,pi.unit_price,pi.batch_number,pi.expiry_date
     INTO v_product,v_ordered,v_received,v_closed,v_unit,v_cost,v_price,v_batch,v_expiry
     FROM public.purchase_items pi WHERE pi.id=v_item AND pi.purchase_id=v_purchase FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Purchase item not found in this purchase'; END IF;
   IF v_qty>v_ordered-v_received-v_closed THEN
     RAISE EXCEPTION 'Accepted quantity exceeds outstanding ordered quantity' USING ERRCODE='23514';
   END IF;
   IF NULLIF(v_row->>'substitute_product_id','') IS NOT NULL THEN
     IF NOT public.has_store_permission(p_store_id,'purchases.receive_substitute')
       OR v_approver IS DISTINCT FROM v_user OR v_sub_reason IS NULL THEN
       RAISE EXCEPTION 'Substitute receipt requires special permission, approval and reason' USING ERRCODE='42501';
     END IF;
     v_actual:=(v_row->>'substitute_product_id')::UUID;
     v_actual_cost:=COALESCE(NULLIF(v_row->>'substitute_cost_per_unit','')::NUMERIC,v_cost);
     v_actual_price:=COALESCE(NULLIF(v_row->>'substitute_unit_price','')::NUMERIC,v_price);
   ELSE
     v_actual:=v_product; v_actual_cost:=v_cost; v_actual_price:=v_price;
   END IF;
   SELECT p.primary_unit_id,
     CASE WHEN v_unit=p.primary_unit_id THEN 1 ELSE pu.conversion_factor END
    INTO v_primary,v_factor FROM public.products p
    LEFT JOIN public.product_units pu ON pu.product_id=p.id AND pu.unit_id=v_unit
   WHERE p.id=v_actual AND p.store_id=p_store_id AND p.is_active AND p.deleted_at IS NULL;
   IF v_factor IS NULL OR v_factor<=0 THEN RAISE EXCEPTION 'Receipt unit is not configured for actual product'; END IF;

   INSERT INTO public.purchase_receipt_items(store_id,receipt_id,purchase_item_id,original_product_id,actual_product_id,
     ordered_quantity,accepted_quantity,excess_quantity,rejected_quantity,quantity_unit_id,unit_cost,unit_price,
     excess_reason,rejection_reason,packaging_condition,photo_paths,substitute_reason,batch_number,expiry_date)
   VALUES(p_store_id,v_receipt,v_item,v_product,v_actual,v_ordered,v_qty,v_excess,v_rejected,v_unit,
     v_actual_cost,v_actual_price,NULLIF(v_row->>'excess_reason',''),v_reason,
     NULLIF(v_row->>'packaging_condition',''),COALESCE(v_row->'photo_paths','[]'::jsonb),v_sub_reason,
     COALESCE(NULLIF(v_row->>'batch_number',''),v_batch),
     COALESCE(NULLIF(v_row->>'expiry_date','')::TIMESTAMPTZ,v_expiry));

   IF v_qty+v_excess>0 THEN
     v_base:=(v_qty+v_excess)*v_factor;
     INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity)
     VALUES(v_actual,v_location,0,0) ON CONFLICT(product_id,location_id) DO NOTHING;
     PERFORM 1 FROM public.stock WHERE product_id=v_actual ORDER BY location_id FOR UPDATE;
     SELECT COALESCE(SUM(quantity),0) INTO v_old_qty FROM public.stock WHERE product_id=v_actual;
     SELECT cost_price INTO v_old_cost FROM public.products WHERE id=v_actual FOR UPDATE;
     SELECT id INTO v_stock FROM public.stock WHERE product_id=v_actual AND location_id=v_location;
     UPDATE public.stock SET quantity=quantity+v_base WHERE id=v_stock;
     UPDATE public.products SET cost_price=CASE WHEN v_old_qty<=0 THEN round(v_actual_cost/v_factor,4)
       ELSE round(((v_old_qty*v_old_cost)+((v_qty+v_excess)*v_actual_cost))/(v_old_qty+v_base),4) END,
       updated_at=NOW() WHERE id=v_actual;
     INSERT INTO public.stock_movements(product_id,location_id,type,quantity,unit_id,cost_per_unit,total_value,
       reference_id,reference_type,batch_number,expiry_date,reason,user_id)
     VALUES(v_actual,v_location,'IN',v_base,v_primary,v_actual_cost/v_factor,v_base*(v_actual_cost/v_factor),
       v_purchase,'purchase',v_batch,v_expiry,'Purchase receipt '||v_receipt::text,v_user);
   END IF;
   UPDATE public.purchase_items SET received_quantity=received_quantity+v_qty,
     excess_received_quantity=excess_received_quantity+v_excess,
     received=(received_quantity+v_qty)>=quantity,
     received_date=CASE WHEN (received_quantity+v_qty)>=quantity THEN NOW() ELSE received_date END
    WHERE id=v_item;

   v_purchase_delta:=v_purchase_delta+(v_qty*(v_actual_price-v_price))+(v_excess*v_actual_price);
   v_accepted_total:=v_accepted_total+(v_qty*v_factor);
   v_excess_total:=v_excess_total+(v_excess*v_factor);
   v_rejected_total:=v_rejected_total+v_rejected;
   IF v_excess>0 OR v_rejected>0 OR v_actual<>v_product THEN
     INSERT INTO public.audit_logs(store_id,user_id,entity_type,entity_id,action,new_values_json)
     VALUES(p_store_id,v_user,'PURCHASE_RECEIPT_ITEM',
       (SELECT id FROM public.purchase_receipt_items WHERE receipt_id=v_receipt AND purchase_item_id=v_item),
       'CREATE',to_jsonb(v_row)||jsonb_build_object('original_product_id',v_product,'actual_product_id',v_actual,
         'excess_quantity',v_excess,'rejected_quantity',v_rejected,'approved_by',v_approver));
   END IF;
 END LOOP;

 IF v_purchase_delta<>0 THEN
   UPDATE public.purchases SET subtotal=subtotal+v_purchase_delta,total_amount=total_amount+v_purchase_delta,
     remaining_amount=GREATEST(remaining_amount+v_purchase_delta,0),
     status=CASE WHEN GREATEST(remaining_amount+v_purchase_delta,0)=0 THEN 'PAID'
                 WHEN paid_amount>0 THEN 'PARTIAL' ELSE 'OPEN' END,
     updated_at=NOW() WHERE id=v_purchase;
   IF v_purchase_delta>0 THEN
     UPDATE public.suppliers SET current_debt=current_debt+v_purchase_delta,updated_at=NOW() WHERE id=v_supplier;
     INSERT INTO public.supplier_ledger(supplier_id,type,amount,balance,reference_id,description,created_by)
     SELECT v_supplier,'ADJUSTMENT',v_purchase_delta,current_debt-credit_balance,
       v_receipt,'Approved excess/substitute price adjustment for purchase '||v_number,v_user
      FROM public.suppliers WHERE id=v_supplier;
   ELSE
     SELECT LEAST(current_debt,-v_purchase_delta) INTO v_debt_reduction
       FROM public.suppliers WHERE id=v_supplier FOR UPDATE;
     v_credit_increase:=(-v_purchase_delta)-v_debt_reduction;
     UPDATE public.suppliers SET current_debt=current_debt-v_debt_reduction,
       credit_balance=credit_balance+v_credit_increase,updated_at=NOW() WHERE id=v_supplier;
     INSERT INTO public.supplier_ledger(supplier_id,type,amount,balance,reference_id,description,created_by)
     SELECT v_supplier,'ADJUSTMENT',v_purchase_delta,current_debt-credit_balance,
       v_receipt,'Approved substitute price adjustment for purchase '||v_number,v_user
      FROM public.suppliers WHERE id=v_supplier;
   END IF;
 END IF;

 UPDATE public.purchases p SET receiving_status=CASE
   WHEN EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id AND pi.closed_quantity>0) THEN 'CLOSED_PARTIAL'
   WHEN NOT EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id
                    AND pi.received_quantity<pi.quantity) THEN 'COMPLETE'
   WHEN EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id
                 AND (pi.received_quantity>0 OR pi.excess_received_quantity>0)) THEN 'PARTIAL'
   ELSE 'PENDING' END,
   received_date=CASE WHEN NOT EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id
                    AND pi.received_quantity+pi.closed_quantity<pi.quantity) THEN NOW() ELSE NULL END,
   updated_at=NOW() WHERE p.id=v_purchase;
 RETURN jsonb_build_object('success',TRUE,'replayed',FALSE,'receipt_id',v_receipt,
   'accepted_base_quantity',v_accepted_total,'excess_base_quantity',v_excess_total,
   'rejected_quantity',v_rejected_total);
END;
$receipt_rpc$;

CREATE OR REPLACE FUNCTION public.process_purchase_close_remaining(
 p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,extensions,public,pg_temp
AS $close_remaining$
DECLARE
 v_user UUID; v_replay BOOLEAN; v_id UUID:=(p_payload->>'id')::UUID;
 v_purchase UUID:=(p_payload->>'purchase_id')::UUID; v_reason TEXT:=NULLIF(btrim(p_payload->>'reason'),'');
 v_row JSONB; v_item UUID; v_qty NUMERIC(18,4); v_ordered NUMERIC(18,4);
 v_received NUMERIC(18,4); v_closed NUMERIC(18,4); v_closure UUID; v_price NUMERIC(18,4);
 v_supplier UUID; v_supplier_debt NUMERIC(18,4); v_applied NUMERIC(18,4);
 v_new_credit NUMERIC(18,4); v_closure_total NUMERIC(18,4):=0;
BEGIN
 IF v_reason IS NULL THEN RAISE EXCEPTION 'A closure reason is required'; END IF;
 IF COALESCE(jsonb_typeof(p_payload->'items'),'')<>'array' OR jsonb_array_length(p_payload->'items')=0 THEN
   RAISE EXCEPTION 'Closure items must be a non-empty JSON array';
 END IF;
 SELECT c.app_user_id,c.already_processed INTO v_user,v_replay FROM public._claim_business_operation(
   p_store_id,p_operation_id,'purchase_close_remaining',v_id,p_payload,'purchases.close_remaining') c;
 IF v_replay THEN RETURN jsonb_build_object('success',TRUE,'replayed',TRUE,'closure_id',v_id); END IF;
 SELECT supplier_id INTO v_supplier FROM public.purchases
  WHERE id=v_purchase AND store_id=p_store_id AND status<>'CANCELLED' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found or cancelled'; END IF;
 INSERT INTO public.purchase_closures(id,store_id,purchase_id,operation_id,reason,closed_by)
 VALUES(v_id,p_store_id,v_purchase,p_operation_id,v_reason,v_user);
 FOR v_row IN SELECT e.value FROM jsonb_array_elements(p_payload->'items') e(value)
              ORDER BY e.value->>'purchase_item_id'
 LOOP
   v_item:=(v_row->>'purchase_item_id')::UUID; v_qty:=(v_row->>'quantity')::NUMERIC;
   SELECT quantity,received_quantity,closed_quantity,unit_price
     INTO v_ordered,v_received,v_closed,v_price
    FROM public.purchase_items WHERE id=v_item AND purchase_id=v_purchase FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Purchase item not found'; END IF;
   IF v_qty IS NULL OR v_qty<=0 OR v_qty>v_ordered-v_received-v_closed THEN
     RAISE EXCEPTION 'Closed quantity exceeds outstanding quantity' USING ERRCODE='23514';
   END IF;
   UPDATE public.purchase_items SET closed_quantity=closed_quantity+v_qty WHERE id=v_item;
   INSERT INTO public.purchase_closure_items(store_id,closure_id,purchase_item_id,quantity,reason)
   VALUES(p_store_id,v_id,v_item,v_qty,COALESCE(NULLIF(v_row->>'reason',''),v_reason));
   v_closure_total:=v_closure_total+(v_qty*v_price);
 END LOOP;

 -- Closed, unreceived quantities are cancelled financially as well as operationally.
 IF v_closure_total>0 THEN
   UPDATE public.purchases SET subtotal=GREATEST(subtotal-v_closure_total,0),
     total_amount=GREATEST(total_amount-v_closure_total,0),
     remaining_amount=GREATEST(remaining_amount-v_closure_total,0),
     status=CASE WHEN GREATEST(remaining_amount-v_closure_total,0)=0 THEN 'PAID'
                 WHEN paid_amount>0 THEN 'PARTIAL' ELSE 'OPEN' END,
     updated_at=NOW() WHERE id=v_purchase;
   SELECT current_debt INTO v_supplier_debt FROM public.suppliers
    WHERE id=v_supplier AND store_id=p_store_id FOR UPDATE;
   v_applied:=LEAST(v_supplier_debt,v_closure_total);
   v_new_credit:=v_closure_total-v_applied;
   UPDATE public.suppliers SET current_debt=current_debt-v_applied,
     credit_balance=credit_balance+v_new_credit,updated_at=NOW() WHERE id=v_supplier;
   INSERT INTO public.supplier_ledger(supplier_id,type,amount,balance,reference_id,description,created_by)
   SELECT v_supplier,'ADJUSTMENT',-v_closure_total,current_debt-credit_balance,v_id,
     'Closed unreceived purchase quantity '||v_id::text,v_user
    FROM public.suppliers WHERE id=v_supplier;
   UPDATE public.purchase_closures SET financial_delta=-v_closure_total,
     applied_to_debt=v_applied,supplier_credit_created=v_new_credit WHERE id=v_id;
 END IF;

 UPDATE public.purchases p SET receiving_status=CASE
   WHEN EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id AND pi.closed_quantity>0) THEN 'CLOSED_PARTIAL'
   WHEN NOT EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id
                    AND pi.received_quantity<pi.quantity) THEN 'COMPLETE'
   WHEN EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id
                 AND (pi.received_quantity>0 OR pi.excess_received_quantity>0)) THEN 'PARTIAL'
   ELSE 'PENDING' END,
   received_date=CASE WHEN NOT EXISTS(SELECT 1 FROM public.purchase_items pi WHERE pi.purchase_id=p.id
                    AND pi.received_quantity+pi.closed_quantity<pi.quantity) THEN NOW() ELSE NULL END,
   updated_at=NOW() WHERE p.id=v_purchase;
 INSERT INTO public.audit_logs(store_id,user_id,entity_type,entity_id,action,new_values_json)
 VALUES(p_store_id,v_user,'PURCHASE_CLOSURE',v_id,'CREATE',p_payload);
 RETURN jsonb_build_object('success',TRUE,'replayed',FALSE,'closure_id',v_id);
END;
$close_remaining$;

REVOKE ALL ON FUNCTION public.process_purchase_receipt(UUID,UUID,JSONB) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.process_purchase_close_remaining(UUID,UUID,JSONB) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.process_purchase_receipt(UUID,UUID,JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_purchase_close_remaining(UUID,UUID,JSONB) TO authenticated;

COMMIT;
