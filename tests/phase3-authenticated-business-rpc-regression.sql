-- Authenticated-role business RPC regression.
-- Fixtures are created by phase2-business-regression.sql; this test deliberately
-- switches from the PostgreSQL migration owner to the actual authenticated role.
BEGIN;

SELECT set_config('request.jwt.claim.sub',
  '20000000-0000-4000-8000-000000000001', TRUE);
SELECT set_config('request.jwt.claim.role','authenticated',TRUE);
SET LOCAL ROLE authenticated;

DO $authenticated_business_rpc$
DECLARE
  v_store UUID := '10000000-0000-4000-8000-000000000001';
  v_product UUID := '50000000-0000-4000-8000-000000000001';
  v_invoice UUID := '80000000-0000-4000-8000-000000000099';
  v_operation UUID := '60000000-0000-4000-8000-000000000099';
  v_payload JSONB;
  v_result JSONB;
BEGIN
  IF current_user <> 'authenticated' THEN
    RAISE EXCEPTION 'Business RPC test is not running as authenticated: %', current_user;
  END IF;
  IF auth.uid() IS DISTINCT FROM '20000000-0000-4000-8000-000000000001'::UUID THEN
    RAISE EXCEPTION 'Authenticated role did not resolve the expected Auth subject';
  END IF;
  IF public.current_user_store_id() IS DISTINCT FROM v_store THEN
    RAISE EXCEPTION 'Authenticated RPC resolved the wrong store';
  END IF;

  v_payload := jsonb_build_object(
    'id',v_invoice,
    'invoice_number','AUTHENTICATED-RPC-REGRESSION',
    'paid_amount',7,
    'payment_method','CASH',
    'items',jsonb_build_array(jsonb_build_object(
      'product_id',v_product,'quantity',1,'unit_id','pcs',
      'unit_price',7,'discount_amount',0
    ))
  );

  v_result := public.process_sale_invoice(v_store,v_operation,v_payload);
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Authenticated owner could not execute permitted sale RPC: %',v_result;
  END IF;

  v_result := public.process_sale_invoice(v_store,v_operation,v_payload);
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE
     OR COALESCE((v_result->>'replayed')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Authenticated sale RPC replay was not idempotent: %',v_result;
  END IF;

  RAISE NOTICE 'PASS: business sale RPC executed as authenticated with resolved Auth identity, store scope and idempotent replay';
END
$authenticated_business_rpc$;

ROLLBACK;
