-- Correct stock adjustment valuation, D-021 permission, D-016 negative stock gate,
-- and balanced double-entry journal posting.

BEGIN;

-- D-016: permit negative quantity only through the privileged RPC.
-- The original inline CHECKs were auto-named stock_check/stock_check1 by
-- PostgreSQL. Drop both as well as the explicit names used by earlier drafts;
-- otherwise the old quantity >= 0 check still blocks D-016 negative stock.
ALTER TABLE public.stock DROP CONSTRAINT IF EXISTS stock_quantity_check;
ALTER TABLE public.stock DROP CONSTRAINT IF EXISTS stock_reserved_quantity_check;
ALTER TABLE public.stock DROP CONSTRAINT IF EXISTS stock_check;
ALTER TABLE public.stock DROP CONSTRAINT IF EXISTS stock_check1;
ALTER TABLE public.stock ADD CONSTRAINT stock_reserved_quantity_check
 CHECK(reserved_quantity>=0 AND reserved_quantity<=GREATEST(quantity,0));

ALTER TABLE public.stock_adjustments ADD COLUMN IF NOT EXISTS location_id TEXT NOT NULL DEFAULT 'main';
ALTER TABLE public.stock_adjustments DROP CONSTRAINT IF EXISTS stock_adjustments_location_id_fkey;
ALTER TABLE public.stock_adjustments ADD CONSTRAINT stock_adjustments_location_id_fkey
 FOREIGN KEY(location_id) REFERENCES public.locations(id);

INSERT INTO public.permissions(code,description) VALUES
 ('inventory.adjust','Authorize inventory stock adjustments'),
 ('inventory.allow_negative','Authorize stock below zero with audit')
ON CONFLICT(code) DO NOTHING;
INSERT INTO public.role_permissions(role_id,permission_id)
SELECT r.role_id,p.id FROM (VALUES('owner')) r(role_id)
JOIN public.permissions p ON p.code IN ('inventory.adjust','inventory.allow_negative')
ON CONFLICT(role_id,permission_id) DO NOTHING;

-- Minimum accounts needed for balanced stock adjustment entries.
INSERT INTO public.chart_of_accounts(store_id,account_code,account_name,account_type,is_active)
SELECT s.id,a.code,a.name,a.type,TRUE
 FROM public.stores s
 CROSS JOIN (VALUES
   ('1200','Inventory','ASSET'),
   ('4100','Inventory Adjustment Gain','REVENUE'),
   ('5100','Inventory Adjustment Loss','EXPENSE')
 ) a(code,name,type)
ON CONFLICT(store_id,account_code) DO NOTHING;

CREATE OR REPLACE FUNCTION public.process_stock_adjustment(
 p_store_id UUID,p_operation_id UUID,p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,extensions,public,pg_temp
AS $stock_adjustment$
DECLARE
 v_user UUID; v_replay BOOLEAN; v_id UUID:=(p_payload->>'id')::UUID;
 v_product UUID:=(p_payload->>'product_id')::UUID;
 v_type TEXT:=p_payload->>'adjustment_type';
 v_reason TEXT:=NULLIF(btrim(p_payload->>'reason'),'');
 v_quantity NUMERIC(18,4):=(p_payload->>'quantity')::NUMERIC;
 v_unit TEXT:=p_payload->>'unit_id';
 v_location TEXT:=COALESCE(NULLIF(p_payload->>'location_id',''),'main');
 v_input_cost NUMERIC(18,4):=NULLIF(p_payload->>'cost_per_unit','')::NUMERIC;
 v_factor NUMERIC(18,6); v_primary TEXT;
 v_current_cost NUMERIC(18,4); v_cost_base NUMERIC(18,4);
 v_old_qty NUMERIC(18,4); v_current_qty NUMERIC(18,4); v_reserved NUMERIC(18,4);
 v_new_qty NUMERIC(18,4); v_new_cost NUMERIC(18,4);
 v_base_qty NUMERIC(18,4); v_total NUMERIC(18,4); v_stock UUID;
 v_journal UUID; v_inventory_account UUID; v_offset_account UUID;
 v_entry_no TEXT;
 v_device_id UUID; v_device_token TEXT; v_shortage NUMERIC(18,4):=0;
BEGIN
 SELECT c.app_user_id,c.already_processed INTO v_user,v_replay
  FROM public._claim_business_operation(p_store_id,p_operation_id,'stock_adjustment',v_id,p_payload-'device_token','inventory.adjust') c;
 IF v_replay THEN RETURN jsonb_build_object('success',TRUE,'replayed',TRUE,'adjustment_id',v_id); END IF;
 v_location:=public.resolve_store_location_id(p_store_id,v_location);

 IF v_type NOT IN ('INCREASE','DECREASE') THEN RAISE EXCEPTION 'Invalid adjustment type'; END IF;
 IF v_reason IS NULL THEN RAISE EXCEPTION 'Reason for adjustment is required'; END IF;
 IF v_quantity IS NULL OR v_quantity<=0 THEN RAISE EXCEPTION 'Quantity must be positive'; END IF;

 SELECT p.primary_unit_id,p.cost_price,
        CASE WHEN v_unit=p.primary_unit_id THEN 1 ELSE pu.conversion_factor END
   INTO v_primary,v_current_cost,v_factor
   FROM public.products p LEFT JOIN public.product_units pu
     ON pu.product_id=p.id AND pu.unit_id=v_unit
  WHERE p.id=v_product AND p.store_id=p_store_id AND p.is_active AND p.deleted_at IS NULL
  FOR UPDATE OF p;
 IF NOT FOUND THEN RAISE EXCEPTION 'Product does not belong to this store or is inactive'; END IF;
 IF v_factor IS NULL OR v_factor<=0 THEN RAISE EXCEPTION 'Unit is not configured for product'; END IF;

 v_base_qty:=v_quantity*v_factor;
 IF v_type='INCREASE' THEN
   v_cost_base:=COALESCE(v_input_cost/v_factor,v_current_cost,0);
 ELSE
   -- A decrease removes inventory at the current weighted-average cost.
   v_cost_base:=COALESCE(v_current_cost,0);
 END IF;
 v_total:=round(v_base_qty*v_cost_base,4);

 INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity)
 VALUES(v_product,v_location,0,0) ON CONFLICT(product_id,location_id) DO NOTHING;
 PERFORM 1 FROM public.stock WHERE product_id=v_product ORDER BY location_id FOR UPDATE;
 SELECT COALESCE(SUM(quantity),0) INTO v_old_qty FROM public.stock WHERE product_id=v_product;
 SELECT id,quantity,reserved_quantity INTO v_stock,v_current_qty,v_reserved
  FROM public.stock WHERE product_id=v_product AND location_id=v_location;
 IF v_type='INCREASE' THEN
   v_new_qty:=v_current_qty+v_base_qty;
 ELSE
   v_new_qty:=v_current_qty-v_base_qty;
   -- A privileged negative-stock adjustment may cross zero only when no
   -- reserved quantity exists. Check the special permission before the
   -- ordinary reserved-stock guard so callers receive the correct denial.
   IF v_new_qty<0 THEN
     IF NOT public.has_store_permission(p_store_id,'inventory.allow_negative') THEN
       RAISE EXCEPTION 'Negative stock requires inventory.allow_negative' USING ERRCODE='42501';
     END IF;
     v_shortage:=GREATEST(v_base_qty-(v_current_qty-v_reserved),0);
     IF NULLIF(BTRIM(p_payload->>'device_id'),'') IS NULL
        OR NULLIF(p_payload->>'device_token','') IS NULL THEN
       RAISE EXCEPTION 'A registered device credential is required for negative stock'
         USING ERRCODE='42501';
     END IF;
     v_device_id:=(p_payload->>'device_id')::UUID;
     v_device_token:=p_payload->>'device_token';
     PERFORM public.assert_sync_device_credential(p_store_id,v_device_id::TEXT,v_device_token);
   END IF;
   IF v_new_qty<v_reserved AND NOT (v_new_qty<0 AND v_reserved=0) THEN
     RAISE EXCEPTION 'Cannot adjust stock using reserved quantity' USING ERRCODE='23514';
   END IF;
 END IF;

 INSERT INTO public.stock_adjustments(id,store_id,adjustment_number,product_id,adjustment_type,
   reason,quantity,unit_id,cost_per_unit,total_value,created_by,location_id,
   operation_id,device_id,shortage_quantity,negative_stock_authorized)
 VALUES(v_id,p_store_id,COALESCE(NULLIF(p_payload->>'adjustment_number',''),
   'ADJ-'||to_char(NOW(),'YYYYMMDD')||'-'||substr(replace(v_id::text,'-',''),1,8)),
   v_product,v_type,v_reason,v_quantity,v_unit,v_cost_base,v_total,v_user,v_location,
   p_operation_id,CASE WHEN v_shortage>0 THEN v_device_id ELSE NULL END,
   v_shortage,(v_shortage>0));

 UPDATE public.stock SET quantity=v_new_qty WHERE id=v_stock;
 IF v_type='INCREASE' THEN
   v_new_cost:=CASE WHEN v_old_qty<=0 THEN v_cost_base
     ELSE round(((v_old_qty*v_current_cost)+(v_base_qty*v_cost_base))/(v_old_qty+v_base_qty),4) END;
   UPDATE public.products SET cost_price=v_new_cost,updated_at=NOW() WHERE id=v_product;
 END IF;

 INSERT INTO public.stock_movements(product_id,location_id,type,quantity,unit_id,cost_per_unit,total_value,
   reference_id,reference_type,reason,user_id,operation_id,device_id,shortage_quantity,negative_stock_authorized)
 VALUES(v_product,v_location,'ADJUSTMENT',v_base_qty,v_primary,v_cost_base,v_total,
   v_id,'adjustment',CASE WHEN v_shortage>0 THEN 'Negative stock adjustment: '||v_reason
                          ELSE 'Stock adjustment: '||v_reason END,
   v_user,p_operation_id,CASE WHEN v_shortage>0 THEN v_device_id ELSE NULL END,
   v_shortage,(v_shortage>0));

 IF v_total>0 THEN
   INSERT INTO public.chart_of_accounts(store_id,account_code,account_name,account_type,is_active)
   VALUES
     (p_store_id,'1200','Inventory','ASSET',TRUE),
     (p_store_id,'4100','Inventory Adjustment Gain','REVENUE',TRUE),
     (p_store_id,'5100','Inventory Adjustment Loss','EXPENSE',TRUE)
   ON CONFLICT(store_id,account_code) DO NOTHING;
   SELECT id INTO v_inventory_account FROM public.chart_of_accounts
    WHERE store_id=p_store_id AND account_code='1200' AND is_active;
   IF v_type='INCREASE' THEN
     SELECT id INTO v_offset_account FROM public.chart_of_accounts
      WHERE store_id=p_store_id AND account_code='4100' AND is_active;
   ELSE
     SELECT id INTO v_offset_account FROM public.chart_of_accounts
      WHERE store_id=p_store_id AND account_code='5100' AND is_active;
   END IF;
   IF v_inventory_account IS NULL OR v_offset_account IS NULL THEN
     RAISE EXCEPTION 'Required inventory adjustment accounts are not configured';
   END IF;
   v_journal:=gen_random_uuid();
   v_entry_no:='ADJ-'||to_char(NOW(),'YYYYMMDD')||'-'||substr(replace(v_journal::text,'-',''),1,8);
   INSERT INTO public.journal_entries(id,store_id,entry_number,entry_date,description,source_type,source_id,
     total_debit,total_credit,posted_by)
   VALUES(v_journal,p_store_id,v_entry_no,NOW(),'Stock adjustment: '||v_reason,'ADJUSTMENT',v_id,
     v_total,v_total,v_user);
   IF v_type='INCREASE' THEN
     INSERT INTO public.general_ledger(store_id,journal_entry_id,account_id,entry_type,amount,
       description,reference_id,reference_table,created_by)
     VALUES
       (p_store_id,v_journal,v_inventory_account,'DEBIT',v_total,'Inventory increase',v_id,'ADJUSTMENT',v_user),
       (p_store_id,v_journal,v_offset_account,'CREDIT',v_total,'Inventory adjustment gain',v_id,'ADJUSTMENT',v_user);
   ELSE
     INSERT INTO public.general_ledger(store_id,journal_entry_id,account_id,entry_type,amount,
       description,reference_id,reference_table,created_by)
     VALUES
       (p_store_id,v_journal,v_offset_account,'DEBIT',v_total,'Inventory adjustment loss',v_id,'ADJUSTMENT',v_user),
       (p_store_id,v_journal,v_inventory_account,'CREDIT',v_total,'Inventory decrease',v_id,'ADJUSTMENT',v_user);
   END IF;
 END IF;

 IF v_new_qty<0 THEN
   INSERT INTO public.audit_logs(store_id,user_id,entity_type,entity_id,action,new_values_json)
   VALUES(p_store_id,v_user,'STOCK_ADJUSTMENT',v_id,'UPDATE',
     jsonb_build_object('event','NEGATIVE_STOCK','old_quantity',v_current_qty,'new_quantity',v_new_qty,
       'adjusted_quantity',v_base_qty,'shortage_quantity',v_shortage,'reason',v_reason,
       'permission','inventory.allow_negative','operation_id',p_operation_id,'device_id',v_device_id));
 END IF;
 RETURN jsonb_build_object('success',TRUE,'replayed',FALSE,'adjustment_id',v_id,
   'new_quantity',v_new_qty,'cost_per_unit',v_cost_base,'total_value',v_total);
END;
$stock_adjustment$;

REVOKE ALL ON FUNCTION public.process_stock_adjustment(UUID,UUID,JSONB) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.process_stock_adjustment(UUID,UUID,JSONB) TO authenticated;
COMMIT;
