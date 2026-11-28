-- D3.2 / R1 regression: SECURITY DEFINER Pull must enforce owner/seller read visibility.
-- Runs after RBAC read hardening and owner/seller role consolidation.
BEGIN;

INSERT INTO public.devices(id,store_id,device_name,device_type)
VALUES ('99300000-0000-4000-8000-000000000001',
        '10000000-0000-4000-8000-000000000001',
        'D3.2 R1 Pull visibility test','DESKTOP')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 ('99100000-0000-4000-8000-000000000011','20100000-0000-4000-8000-000000000011',
  '10000000-0000-4000-8000-000000000001','d32_r1_seller_a','D3.2 R1 Seller A',TRUE),
 ('99100000-0000-4000-8000-000000000012','20100000-0000-4000-8000-000000000012',
  '10000000-0000-4000-8000-000000000001','d32_r1_seller_b','D3.2 R1 Seller B',TRUE),
 ('99100000-0000-4000-8000-000000000013','20100000-0000-4000-8000-000000000013',
  '10000000-0000-4000-8000-000000000001','d32_r1_owner','D3.2 R1 Owner',TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.user_roles(user_id,role_id)
VALUES
 ('99100000-0000-4000-8000-000000000011','cashier'),
 ('99100000-0000-4000-8000-000000000012','cashier'),
 ('99100000-0000-4000-8000-000000000013','owner')
ON CONFLICT (user_id,role_id) DO NOTHING;

INSERT INTO public.customers(id,store_id,code,name)
VALUES ('99200000-0000-4000-8000-000000000001',
        '10000000-0000-4000-8000-000000000001',
        'D32-R1-CUSTOMER','D3.2 R1 Customer')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.suppliers(id,store_id,code,name)
VALUES ('99200000-0000-4000-8000-000000000002',
        '10000000-0000-4000-8000-000000000001',
        'D32-R1-SUPPLIER','D3.2 R1 Supplier')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.invoices(
 id,store_id,invoice_number,type,customer_id,invoice_date,total_amount,
 paid_amount,remaining_amount,created_by,status
) VALUES
 ('99400000-0000-4000-8000-000000000011',
  '10000000-0000-4000-8000-000000000001','D32-R1-SELLER-A','SALE',
  '99200000-0000-4000-8000-000000000001',NOW(),100,0,100,
  '99100000-0000-4000-8000-000000000011','OPEN'),
 ('99400000-0000-4000-8000-000000000012',
  '10000000-0000-4000-8000-000000000001','D32-R1-SELLER-B','SALE',
  '99200000-0000-4000-8000-000000000001',NOW(),100,0,100,
  '99100000-0000-4000-8000-000000000012','OPEN')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.sales_returns(
 id,store_id,return_number,original_invoice_id,total_amount,created_by
) VALUES
 ('99600000-0000-4000-8000-000000000011',
  '10000000-0000-4000-8000-000000000001','D32-R1-RETURN-A',
  '99400000-0000-4000-8000-000000000011',1,
  '99100000-0000-4000-8000-000000000011'),
 ('99600000-0000-4000-8000-000000000012',
  '10000000-0000-4000-8000-000000000001','D32-R1-RETURN-B',
  '99400000-0000-4000-8000-000000000012',1,
  '99100000-0000-4000-8000-000000000012')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.customer_payments(
 id,customer_id,amount,payment_method,created_by
) VALUES
 ('99800000-0000-4000-8000-000000000011',
  '99200000-0000-4000-8000-000000000001',10,'CASH',
  '99100000-0000-4000-8000-000000000011'),
 ('99800000-0000-4000-8000-000000000012',
  '99200000-0000-4000-8000-000000000001',10,'CASH',
  '99100000-0000-4000-8000-000000000012')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.customer_ledgers(
 id,customer_id,type,amount,balance,reference_id,description,created_by
) VALUES
 ('99900000-0000-4000-8000-000000000011',
  '99200000-0000-4000-8000-000000000001','PAYMENT',-10,-10,
  '99800000-0000-4000-8000-000000000011','D3.2 R1 Seller A ledger',
  '99100000-0000-4000-8000-000000000011'),
 ('99900000-0000-4000-8000-000000000012',
  '99200000-0000-4000-8000-000000000001','PAYMENT',-10,-10,
  '99800000-0000-4000-8000-000000000012','D3.2 R1 Seller B ledger',
  '99100000-0000-4000-8000-000000000012')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.payment_allocations(id,payment_id,invoice_id,allocated_amount)
VALUES
 ('aaa00000-0000-4000-8000-000000000011',
  '99800000-0000-4000-8000-000000000011',
  '99400000-0000-4000-8000-000000000011',1),
 ('aaa00000-0000-4000-8000-000000000012',
  '99800000-0000-4000-8000-000000000012',
  '99400000-0000-4000-8000-000000000012',1)
ON CONFLICT (id) DO NOTHING;

-- Explicit Change Log fixtures guarantee coverage even if a particular source
-- table's trigger is intentionally absent or disabled in the test schema.
SELECT public.log_change(
 '10000000-0000-4000-8000-000000000001','invoice_items',
 '99500000-0000-4000-8000-000000000011','INSERT',NULL,
 jsonb_build_object('id','99500000-0000-4000-8000-000000000011',
   'invoice_id','99400000-0000-4000-8000-000000000011'));
SELECT public.log_change(
 '10000000-0000-4000-8000-000000000001','invoice_items',
 '99500000-0000-4000-8000-000000000012','INSERT',NULL,
 jsonb_build_object('id','99500000-0000-4000-8000-000000000012',
   'invoice_id','99400000-0000-4000-8000-000000000012'));
SELECT public.log_change(
 '10000000-0000-4000-8000-000000000001','return_items',
 '99700000-0000-4000-8000-000000000011','INSERT',NULL,
 jsonb_build_object('id','99700000-0000-4000-8000-000000000011',
   'return_id','99600000-0000-4000-8000-000000000011'));
SELECT public.log_change(
 '10000000-0000-4000-8000-000000000001','return_items',
 '99700000-0000-4000-8000-000000000012','INSERT',NULL,
 jsonb_build_object('id','99700000-0000-4000-8000-000000000012',
   'return_id','99600000-0000-4000-8000-000000000012'));
SELECT public.log_change(
 '10000000-0000-4000-8000-000000000001','payment_allocations',
 'aaa00000-0000-4000-8000-000000000011','INSERT',NULL,
 jsonb_build_object('id','aaa00000-0000-4000-8000-000000000011',
   'payment_id','99800000-0000-4000-8000-000000000011',
   'invoice_id','99400000-0000-4000-8000-000000000011'));
SELECT public.log_change(
 '10000000-0000-4000-8000-000000000001','payment_allocations',
 'aaa00000-0000-4000-8000-000000000012','INSERT',NULL,
 jsonb_build_object('id','aaa00000-0000-4000-8000-000000000012',
   'payment_id','99800000-0000-4000-8000-000000000012',
   'invoice_id','99400000-0000-4000-8000-000000000012'));
SELECT public.log_change(
 '10000000-0000-4000-8000-000000000001','purchases',
 '99500000-0000-4000-8000-000000000021','INSERT',NULL,
 jsonb_build_object('id','99500000-0000-4000-8000-000000000021',
   'store_id','10000000-0000-4000-8000-000000000001'));
SELECT public.log_change(
 '10000000-0000-4000-8000-000000000001','sales_returns',
 '99600000-0000-4000-8000-000000000011','INSERT',NULL,
 jsonb_build_object('id','99600000-0000-4000-8000-000000000011',
   'store_id','10000000-0000-4000-8000-000000000001',
   'original_invoice_id','99400000-0000-4000-8000-000000000011'));
SELECT public.log_change(
 '10000000-0000-4000-8000-000000000001','sales_returns',
 '99600000-0000-4000-8000-000000000012','INSERT',NULL,
 jsonb_build_object('id','99600000-0000-4000-8000-000000000012',
   'store_id','10000000-0000-4000-8000-000000000001',
   'original_invoice_id','99400000-0000-4000-8000-000000000012'));
SELECT public.log_change(
 '10000000-0000-4000-8000-000000000001','supplier_payments',
 '99500000-0000-4000-8000-000000000022','INSERT',NULL,
 jsonb_build_object('id','99500000-0000-4000-8000-000000000022',
   'supplier_id','99200000-0000-4000-8000-000000000002'));
SELECT public.log_change(
 '10000000-0000-4000-8000-000000000001','products',
 '50000000-0000-4000-8000-000000000001','UPDATE',NULL,
 jsonb_build_object('id','50000000-0000-4000-8000-000000000001',
   'store_id','10000000-0000-4000-8000-000000000001'));
SELECT public.log_change(
 '10000000-0000-4000-8000-000000000001','tombstones',
 '99500000-0000-4000-8000-000000000031','INSERT',NULL,
 jsonb_build_object('id','99500000-0000-4000-8000-000000000031',
   'store_id','10000000-0000-4000-8000-000000000001',
   'table_name','products','record_uuid','50000000-0000-4000-8000-000000000001'));
SELECT public.log_change(
 '10000000-0000-4000-8000-000000000001','tombstones',
 '99500000-0000-4000-8000-000000000032','INSERT',NULL,
 jsonb_build_object('id','99500000-0000-4000-8000-000000000032',
   'store_id','10000000-0000-4000-8000-000000000001',
   'table_name','suppliers','record_uuid','99500000-0000-4000-8000-000000000041'));

-- Seller A: only its own sales chain and shared product data are visible.
SELECT set_config('request.jwt.claim.sub','20100000-0000-4000-8000-000000000011',TRUE);
SELECT set_config('request.jwt.claim.role','authenticated',TRUE);
SET LOCAL ROLE authenticated;
DO $seller_a_pull$
DECLARE n INTEGER;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','invoices',0)
      WHERE record_uuid='99400000-0000-4000-8000-000000000011')
     OR EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','invoices',0)
      WHERE record_uuid='99400000-0000-4000-8000-000000000012') THEN
    RAISE EXCEPTION 'Seller A Pull did not isolate invoice headers';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','invoice_items',0)
      WHERE record_uuid='99500000-0000-4000-8000-000000000011')
     OR EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','invoice_items',0)
      WHERE record_uuid='99500000-0000-4000-8000-000000000012') THEN
    RAISE EXCEPTION 'Seller A Pull did not inherit invoice-item ownership';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','return_items',0)
      WHERE record_uuid='99700000-0000-4000-8000-000000000011')
     OR EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','return_items',0)
      WHERE record_uuid='99700000-0000-4000-8000-000000000012') THEN
    RAISE EXCEPTION 'Seller A Pull did not inherit return-item invoice ownership';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','payment_allocations',0)
      WHERE record_uuid='aaa00000-0000-4000-8000-000000000011')
     OR EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','payment_allocations',0)
      WHERE record_uuid='aaa00000-0000-4000-8000-000000000012') THEN
    RAISE EXCEPTION 'Seller A Pull did not enforce both payment and invoice ownership';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','sales_returns',0)
      WHERE record_uuid='99600000-0000-4000-8000-000000000011')
     OR EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','sales_returns',0)
      WHERE record_uuid='99600000-0000-4000-8000-000000000012') THEN
    RAISE EXCEPTION 'Seller A Pull did not inherit original invoice ownership for sales returns';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','customer_ledgers',0)
      WHERE record_uuid='99900000-0000-4000-8000-000000000011')
     OR EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','customer_ledgers',0)
      WHERE record_uuid='99900000-0000-4000-8000-000000000012') THEN
    RAISE EXCEPTION 'Seller A Pull did not isolate customer ledger rows';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','customer_payments',0)
      WHERE record_uuid='99800000-0000-4000-8000-000000000011')
     OR EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','customer_payments',0)
      WHERE record_uuid='99800000-0000-4000-8000-000000000012') THEN
    RAISE EXCEPTION 'Seller A Pull did not isolate customer payments';
  END IF;
  IF EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','supplier_payments',0)
      WHERE record_uuid='99500000-0000-4000-8000-000000000022') THEN
    RAISE EXCEPTION 'Seller Pull exposed supplier payment events without suppliers.payments';
  END IF;
  IF EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','purchases',0)
      WHERE record_uuid='99500000-0000-4000-8000-000000000021') THEN
    RAISE EXCEPTION 'Seller Pull exposed a purchase event without purchases.read';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','products',0)
      WHERE record_uuid='50000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Seller Pull hid shared product data';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','tombstones',0)
      WHERE record_uuid='99500000-0000-4000-8000-000000000031')
     OR EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','tombstones',0)
      WHERE record_uuid='99500000-0000-4000-8000-000000000032') THEN
    RAISE EXCEPTION 'Seller Pull did not scope tombstones to readable master data';
  END IF;
  RAISE NOTICE 'PASS: seller Pull is restricted to own sales chain, shared products and authorized tombstones';
END
$seller_a_pull$;
RESET ROLE;

-- Seller B sees its own records, not Seller A's.
SELECT set_config('request.jwt.claim.sub','20100000-0000-4000-8000-000000000012',TRUE);
SET LOCAL ROLE authenticated;
DO $seller_b_pull$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','invoices',0)
      WHERE record_uuid='99400000-0000-4000-8000-000000000012')
     OR EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','invoices',0)
      WHERE record_uuid='99400000-0000-4000-8000-000000000011') THEN
    RAISE EXCEPTION 'Seller B Pull did not isolate invoice headers';
  END IF;
END
$seller_b_pull$;
RESET ROLE;

-- Owner retains store-wide visibility, including purchase and supplier tombstone events.
SELECT set_config('request.jwt.claim.sub','20100000-0000-4000-8000-000000000013',TRUE);
SET LOCAL ROLE authenticated;
DO $owner_pull$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','invoices',0)
      WHERE record_uuid='99400000-0000-4000-8000-000000000011')
     OR NOT EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','invoices',0)
      WHERE record_uuid='99400000-0000-4000-8000-000000000012')
     OR NOT EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','supplier_payments',0)
      WHERE record_uuid='99500000-0000-4000-8000-000000000022')
     OR NOT EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','purchases',0)
      WHERE record_uuid='99500000-0000-4000-8000-000000000021')
     OR NOT EXISTS (SELECT 1 FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      '99300000-0000-4000-8000-000000000001','tombstones',0)
      WHERE record_uuid='99500000-0000-4000-8000-000000000032') THEN
    RAISE EXCEPTION 'Owner Pull lost store-wide visibility';
  END IF;
  RAISE NOTICE 'PASS: owner Pull retains store-wide visibility';
END
$owner_pull$;
RESET ROLE;

ROLLBACK;
