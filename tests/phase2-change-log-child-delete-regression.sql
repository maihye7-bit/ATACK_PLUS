-- Stage 2 / Part 3-D3.1: Change Log ownership and child DELETE regression.
-- Disposable PostgreSQL 16 CI database only. All fixture data is rolled back.
BEGIN;
INSERT INTO public.units(id,name,symbol) VALUES ('pcs','Piece','pc') ON CONFLICT(id) DO NOTHING;
INSERT INTO public.locations(id,name,is_default) VALUES ('main','Main',TRUE) ON CONFLICT(id) DO NOTHING;
INSERT INTO public.stores(id,name) VALUES ('31000000-0000-4000-8000-000000000001','D3.1 Test Store');
INSERT INTO public.users(id,store_id,username,full_name) VALUES
 ('32000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','d31_change_log_owner','D3.1 Test User');
INSERT INTO public.products(id,store_id,name,primary_unit_id) VALUES
 ('33000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','D3.1 Product','pcs');
INSERT INTO public.customers(id,store_id,code,name) VALUES
 ('34000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','D31-CUST','D3.1 Customer');
INSERT INTO public.suppliers(id,store_id,code,name,current_debt) VALUES
 ('35000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','D31-SUP','D3.1 Supplier',100);
INSERT INTO public.invoices(id,store_id,invoice_number,type,customer_id,invoice_date,total_amount,remaining_amount,created_by) VALUES
 ('36000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','D31-INV','SALE','34000000-0000-4000-8000-000000000001',NOW(),10,10,'32000000-0000-4000-8000-000000000001');
INSERT INTO public.purchases(id,store_id,purchase_number,supplier_id,purchase_date,created_by) VALUES
 ('37000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','D31-PUR','35000000-0000-4000-8000-000000000001',NOW(),'32000000-0000-4000-8000-000000000001');
INSERT INTO public.customer_payments(id,customer_id,amount,payment_method,created_by) VALUES
 ('41000000-0000-4000-8000-000000000001','34000000-0000-4000-8000-000000000001',10,'CASH','32000000-0000-4000-8000-000000000001');
INSERT INTO public.sales_returns(id,store_id,return_number,original_invoice_id,created_by) VALUES
 ('42000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','D31-SRET','36000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001');
INSERT INTO public.purchase_returns(id,store_id,return_number,original_purchase_id,created_by) VALUES
 ('43000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','D31-PRET','37000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001');

INSERT INTO public.product_units(id,product_id,unit_id,conversion_factor) VALUES
 ('44000000-0000-4000-8000-000000000001','33000000-0000-4000-8000-000000000001','pcs',1);
INSERT INTO public.stock(id,product_id,location_id,quantity) VALUES
 ('45000000-0000-4000-8000-000000000001','33000000-0000-4000-8000-000000000001','main',5);
INSERT INTO public.purchase_items(id,purchase_id,product_id,quantity,quantity_unit_id,unit_price,cost_per_unit,line_total) VALUES
 ('46000000-0000-4000-8000-000000000001','37000000-0000-4000-8000-000000000001','33000000-0000-4000-8000-000000000001',1,'pcs',2,2,2);
INSERT INTO public.invoice_items(id,invoice_id,product_id,quantity,quantity_unit_id,unit_price,cost_per_unit,line_total) VALUES
 ('47000000-0000-4000-8000-000000000001','36000000-0000-4000-8000-000000000001','33000000-0000-4000-8000-000000000001',1,'pcs',10,2,10);
INSERT INTO public.payment_allocations(id,payment_id,invoice_id,allocated_amount) VALUES
 ('48000000-0000-4000-8000-000000000001','41000000-0000-4000-8000-000000000001','36000000-0000-4000-8000-000000000001',1);
INSERT INTO public.customer_ledgers(id,customer_id,type,amount,balance,reference_id,created_by) VALUES
 ('49000000-0000-4000-8000-000000000001','34000000-0000-4000-8000-000000000001','SALE',1,1,
  '36000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001');
INSERT INTO public.supplier_ledger(id,supplier_id,type,amount,balance,reference_id,created_by) VALUES
 ('4a000000-0000-4000-8000-000000000001','35000000-0000-4000-8000-000000000001','PURCHASE',1,1,
  '37000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001');
INSERT INTO public.supplier_payments(id,supplier_id,amount,payment_method,created_by) VALUES
 ('4b000000-0000-4000-8000-000000000001','35000000-0000-4000-8000-000000000001',1,'CASH','32000000-0000-4000-8000-000000000001');
INSERT INTO public.return_items(id,return_id,product_id,quantity,unit_price,line_total) VALUES
 ('4c000000-0000-4000-8000-000000000001','42000000-0000-4000-8000-000000000001','33000000-0000-4000-8000-000000000001',1,10,10);
INSERT INTO public.purchase_return_items(id,return_id,product_id,quantity,quantity_unit_id,unit_price,line_total) VALUES
 ('4d000000-0000-4000-8000-000000000001','43000000-0000-4000-8000-000000000001','33000000-0000-4000-8000-000000000001',1,'pcs',2,2);

DELETE FROM public.product_units WHERE id='44000000-0000-4000-8000-000000000001';
DELETE FROM public.stock WHERE id='45000000-0000-4000-8000-000000000001';
DELETE FROM public.purchase_items WHERE id='46000000-0000-4000-8000-000000000001';
DELETE FROM public.invoice_items WHERE id='47000000-0000-4000-8000-000000000001';
DELETE FROM public.payment_allocations WHERE id='48000000-0000-4000-8000-000000000001';
DELETE FROM public.customer_ledgers WHERE id='49000000-0000-4000-8000-000000000001';
DELETE FROM public.supplier_ledger WHERE id='4a000000-0000-4000-8000-000000000001';
DELETE FROM public.supplier_payments WHERE id='4b000000-0000-4000-8000-000000000001';
DELETE FROM public.return_items WHERE id='4c000000-0000-4000-8000-000000000001';
DELETE FROM public.purchase_return_items WHERE id='4d000000-0000-4000-8000-000000000001';
DELETE FROM public.customer_payments WHERE id='41000000-0000-4000-8000-000000000001';

DO $child_events$
DECLARE e record;
BEGIN
 FOR e IN SELECT * FROM (VALUES
  ('product_units','44000000-0000-4000-8000-000000000001'::uuid),
  ('stock','45000000-0000-4000-8000-000000000001'::uuid),
  ('purchase_items','46000000-0000-4000-8000-000000000001'::uuid),
  ('invoice_items','47000000-0000-4000-8000-000000000001'::uuid),
  ('payment_allocations','48000000-0000-4000-8000-000000000001'::uuid),
  ('customer_ledgers','49000000-0000-4000-8000-000000000001'::uuid),
  ('supplier_ledger','4a000000-0000-4000-8000-000000000001'::uuid),
  ('supplier_payments','4b000000-0000-4000-8000-000000000001'::uuid),
  ('return_items','4c000000-0000-4000-8000-000000000001'::uuid),
  ('purchase_return_items','4d000000-0000-4000-8000-000000000001'::uuid),
  ('customer_payments','41000000-0000-4000-8000-000000000001'::uuid)
 ) AS x(table_name,record_uuid)
 LOOP
  IF NOT EXISTS (SELECT 1 FROM public.change_log cl
   WHERE cl.store_id='31000000-0000-4000-8000-000000000001'
    AND cl.table_name=e.table_name AND cl.record_uuid=e.record_uuid AND cl.operation='DELETE') THEN
   RAISE EXCEPTION 'Missing child DELETE Change Log event for %.%',e.table_name,e.record_uuid;
  END IF;
 END LOOP;
END;
$child_events$;

-- Direct deletion of a store-owned child must create its own event.
INSERT INTO public.categories(id,store_id,name) VALUES
 ('54000000-0000-4000-8000-000000000001',
  '31000000-0000-4000-8000-000000000001','D3.1 Direct Category Delete');
DELETE FROM public.categories WHERE id='54000000-0000-4000-8000-000000000001';
DO $direct_category_event$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM public.change_log
  WHERE store_id='31000000-0000-4000-8000-000000000001'
   AND table_name='categories'
   AND record_uuid='54000000-0000-4000-8000-000000000001'
   AND operation='DELETE') THEN
  RAISE EXCEPTION 'Direct category DELETE missed its Change Log event';
 END IF;
END;
$direct_category_event$;

-- Store CASCADE currently cannot safely allocate a cursor after the
-- store_sync_counters row is cascaded. It must fail closed and roll back.
INSERT INTO public.stores(id,name) VALUES
 ('51000000-0000-4000-8000-000000000001','D3.1 Cascade Guard Store');
INSERT INTO public.categories(id,store_id,name) VALUES
 ('52000000-0000-4000-8000-000000000001',
  '51000000-0000-4000-8000-000000000001','D3.1 Cascade Guard Category');
DO $cascade_fail_closed$
DECLARE failed boolean := FALSE;
BEGIN
 BEGIN
  DELETE FROM public.stores WHERE id='51000000-0000-4000-8000-000000000001';
 EXCEPTION WHEN OTHERS THEN failed := TRUE;
 END;
 IF NOT failed THEN
  RAISE EXCEPTION 'Store cascade unexpectedly committed without stable cursor ownership';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM public.stores WHERE id='51000000-0000-4000-8000-000000000001')
 OR NOT EXISTS (SELECT 1 FROM public.categories WHERE id='52000000-0000-4000-8000-000000000001') THEN
  RAISE EXCEPTION 'Failed store cascade did not roll back parent and child rows';
 END IF;
 IF EXISTS (SELECT 1 FROM public.change_log
  WHERE store_id='51000000-0000-4000-8000-000000000001'
   AND table_name='categories'
   AND record_uuid='52000000-0000-4000-8000-000000000001'
   AND operation='DELETE') THEN
  RAISE EXCEPTION 'Failed store cascade left a partial child DELETE event';
 END IF;
END;
$cascade_fail_closed$;

CREATE FUNCTION pg_temp.d31_reject_category_delete_log()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
 IF NEW.table_name='categories' AND NEW.operation='DELETE'
  AND NEW.record_uuid='53000000-0000-4000-8000-000000000001'::uuid THEN
  RAISE EXCEPTION 'D3.1 forced Change Log failure';
 END IF;
 RETURN NEW;
END;
$fn$;
CREATE TRIGGER d31_force_change_log_failure BEFORE INSERT ON public.change_log
FOR EACH ROW EXECUTE FUNCTION pg_temp.d31_reject_category_delete_log();
INSERT INTO public.categories(id,store_id,name) VALUES
 ('53000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','D3.1 Rollback Category');
DO $rollback$
DECLARE failed boolean := FALSE;
BEGIN
 BEGIN
  DELETE FROM public.categories WHERE id='53000000-0000-4000-8000-000000000001';
 EXCEPTION WHEN OTHERS THEN failed := TRUE;
 END;
 IF NOT failed THEN RAISE EXCEPTION 'Change Log failure did not abort source DELETE'; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.categories WHERE id='53000000-0000-4000-8000-000000000001') THEN
  RAISE EXCEPTION 'Source row was deleted despite Change Log failure';
 END IF;
 IF EXISTS (SELECT 1 FROM public.change_log WHERE table_name='categories'
  AND record_uuid='53000000-0000-4000-8000-000000000001' AND operation='DELETE') THEN
  RAISE EXCEPTION 'Failed DELETE left a Change Log event';
 END IF;
END;
$rollback$;
DROP TRIGGER d31_force_change_log_failure ON public.change_log;

DO $catalog_contract$
DECLARE
 def text;
 branch text;
 missing text[];
 expected text[] := ARRAY[
  'stores','products','customers','suppliers','purchases','invoices','sales_returns',
  'customer_payments','supplier_payments','stock_movements','categories','brands',
  'product_units','stock','purchase_items','customer_ledgers','payment_allocations',
  'invoice_items','supplier_ledger','return_items','expenses','revenues',
  'purchase_returns','purchase_return_items','stock_adjustments','inventory_batches',
  'journal_entries','general_ledger','stock_alerts','chart_of_accounts',
  'purchase_receipts','purchase_receipt_items','purchase_closures','purchase_closure_items'
 ];
BEGIN
 def := pg_get_functiondef('public.trg_log_change()'::regprocedure);
 branch := substring(def FROM position('IF v_store_id IS NULL THEN' IN def)
  FOR position('v_record_id :=' IN def)-position('IF v_store_id IS NULL THEN' IN def));
 IF branch NOT LIKE '%RAISE EXCEPTION%' OR position('RETURN OLD' IN branch)>0 THEN
  RAISE EXCEPTION 'Unresolved-store DELETE path is not fail-closed';
 END IF;
 SELECT array_agg(x.table_name ORDER BY x.table_name) INTO missing
 FROM unnest(expected) x(table_name)
 WHERE NOT EXISTS (
  SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relname=x.table_name
   AND t.tgfoid='public.trg_log_change()'::regprocedure AND t.tgenabled<>'D'
   AND (t.tgtype & 1)=1 AND (t.tgtype & 2)=0 AND (t.tgtype & 28)=28
 );
 IF missing IS NOT NULL THEN
  RAISE EXCEPTION 'Missing enabled AFTER ROW Change Log trigger on: %',array_to_string(missing,', ');
 END IF;
END;
$catalog_contract$;
ROLLBACK;
