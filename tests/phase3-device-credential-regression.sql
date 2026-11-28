-- D3.2 / R2 regression: bind authenticated sync calls to the assigned user and device secret.
-- Runs after D3.2 R1 Pull RBAC hardening on disposable PostgreSQL CI only.
BEGIN;

INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 ('99100000-0000-4000-8000-000000000021','20300000-0000-4000-8000-000000000021',
  '10000000-0000-4000-8000-000000000001','d32_r2_owner','D3.2 R2 Owner',TRUE),
 ('99100000-0000-4000-8000-000000000022','20300000-0000-4000-8000-000000000022',
  '10000000-0000-4000-8000-000000000001','d32_r2_seller_a','D3.2 R2 Seller A',TRUE),
 ('99100000-0000-4000-8000-000000000023','20300000-0000-4000-8000-000000000023',
  '10000000-0000-4000-8000-000000000001','d32_r2_seller_b','D3.2 R2 Seller B',TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.user_roles(user_id,role_id)
VALUES
 ('99100000-0000-4000-8000-000000000021','owner'),
 ('99100000-0000-4000-8000-000000000022','cashier'),
 ('99100000-0000-4000-8000-000000000023','cashier')
ON CONFLICT (user_id,role_id) DO NOTHING;

-- Owner-managed provisioning binds the device to Seller A and returns the raw
-- high-entropy token once. Only its hash is stored in device_credentials.
SELECT set_config('request.jwt.claim.sub','20300000-0000-4000-8000-000000000021',TRUE);
SELECT set_config('request.jwt.claim.role','authenticated',TRUE);
SET LOCAL ROLE authenticated;
DO $owner_provision$
DECLARE
  v_result JSONB;
  v_device_id TEXT;
  v_token TEXT;
BEGIN
  IF has_table_privilege(current_user,'public.devices','INSERT')
     OR has_table_privilege(current_user,'public.devices','UPDATE')
     OR has_table_privilege(current_user,'public.devices','DELETE') THEN
    RAISE EXCEPTION 'Authenticated owner retains direct device-table mutation privileges';
  END IF;
  IF has_table_privilege(current_user,'public.device_credentials','SELECT') THEN
    RAISE EXCEPTION 'Authenticated can read private device credential material';
  END IF;

  v_result := public.register_sync_device(
    '99100000-0000-4000-8000-000000000022',
    'D3.2 R2 Seller A Desktop','DESKTOP'
  );
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Owner device provisioning failed: %',v_result;
  END IF;
  v_device_id := v_result->>'device_id';
  v_token := v_result->>'device_token';
  IF v_device_id IS NULL OR v_token IS NULL OR v_token !~ '^[0-9a-f]{64}
    RAISE EXCEPTION 'Provisioning did not return a UUID and 64-hex credential';
  END IF;
  PERFORM set_config('atack_test.d32_r2_device_id',v_device_id,TRUE);
  PERFORM set_config('atack_test.d32_r2_token_v1',v_token,TRUE);

  RAISE NOTICE 'PASS: owner can provision a user-bound device and receive its one-time credential';
END
$owner_provision$;
RESET ROLE;
DO $credential_hash_storage$
BEGIN
  IF EXISTS (
      SELECT 1 FROM public.device_credentials
       WHERE device_id=current_setting('atack_test.d32_r2_device_id')::UUID
         AND token_hash=current_setting('atack_test.d32_r2_token_v1')
  ) THEN
    RAISE EXCEPTION 'Raw device token was stored instead of its hash';
  END IF;
  IF NOT EXISTS (
      SELECT 1 FROM public.device_credentials
       WHERE device_id=current_setting('atack_test.d32_r2_device_id')::UUID
         AND token_hash=encode(public.atack_digest(
           convert_to(current_setting('atack_test.d32_r2_token_v1'),'UTF8'),'sha256'),'hex')
  ) THEN
    RAISE EXCEPTION 'Device credential hash was not persisted';
  END IF;
  RAISE NOTICE 'PASS: only the one-way credential hash is persisted';
END
$credential_hash_storage$;

-- Seller A can use the assigned device only with its current credential.
SELECT set_config('request.jwt.claim.sub','20300000-0000-4000-8000-000000000022',TRUE);
SET LOCAL ROLE authenticated;
DO $seller_a_device$
DECLARE
  v_store UUID := '10000000-0000-4000-8000-000000000001';
  v_device TEXT := current_setting('atack_test.d32_r2_device_id');
  v_token TEXT := current_setting('atack_test.d32_r2_token_v1');
  v_outbox UUID;
  v_result JSONB;
  v_denied BOOLEAN := FALSE;
  v_error TEXT;
BEGIN
  IF NOT has_function_privilege(current_user,
      'public.get_unsynced_records(uuid,text,text,bigint,text)','EXECUTE')
     OR has_function_privilege(current_user,
      'public.get_unsynced_records(uuid,text,text,bigint)','EXECUTE')
     OR has_function_privilege(current_user,
      'public.acknowledge_sync_cursor(uuid,text,text,bigint)','EXECUTE')
     OR has_function_privilege(current_user,
      'public.create_outbox_entry(uuid,text,text,text,uuid,uuid,jsonb)','EXECUTE')
     OR has_function_privilege(current_user,
      'public.apply_outbox_operation(uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'Tokenless sync RPC remains executable by authenticated';
  END IF;

  PERFORM * FROM public.get_unsynced_records(v_store,v_device,'products',0,v_token);
  IF NOT public.acknowledge_sync_cursor(v_store,v_device,'products',0,v_token) THEN
    RAISE EXCEPTION 'Authenticated device could not acknowledge its initial cursor';
  END IF;

  BEGIN
    PERFORM * FROM public.get_unsynced_records(
      v_store,v_device,'products',0,repeat('0',64));
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Device authentication failed%' THEN RAISE; END IF;
    v_denied := TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Wrong device token was accepted by Pull'; END IF;

  v_outbox := public.create_outbox_entry(
    v_store,v_device,'customers','INSERT',
    '99400000-0000-4000-8000-000000000021',
    '99500000-0000-4000-8000-000000000021',
    jsonb_build_object(
      'id','99400000-0000-4000-8000-000000000021',
      'store_id',v_store,
      'code','D32-R2-OUTBOX-CUSTOMER',
      'name','D3.2 R2 Outbox Customer',
      'is_active',TRUE
    ),
    v_token
  );
  v_result := public.apply_outbox_operation(v_outbox,v_device,v_token);
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Credential-bound Outbox apply failed: %',v_result;
  END IF;
  RAISE NOTICE 'PASS: assigned seller device can Pull, ACK and Push only with its credential';
END
$seller_a_device$;
RESET ROLE;

-- Seller B cannot impersonate Seller A's registered device, even in the same store.
SELECT set_config('request.jwt.claim.sub','20300000-0000-4000-8000-000000000023',TRUE);
SET LOCAL ROLE authenticated;
DO $seller_b_impersonation$
DECLARE
  v_denied BOOLEAN := FALSE;
  v_error TEXT;
BEGIN
  BEGIN
    PERFORM * FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      current_setting('atack_test.d32_r2_device_id'),'products',0,
      current_setting('atack_test.d32_r2_token_v1')
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Device authentication failed%' THEN RAISE; END IF;
    v_denied := TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Seller B impersonated Seller A device'; END IF;

  v_denied := FALSE;
  BEGIN
    PERFORM public.register_sync_device(
      '99100000-0000-4000-8000-000000000023','Unauthorized Seller Device','PHONE'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%sync.manage permission required%' THEN RAISE; END IF;
    v_denied := TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Seller was allowed to provision a device'; END IF;
  RAISE NOTICE 'PASS: another seller cannot impersonate or provision a device';
END
$seller_b_impersonation$;
RESET ROLE;

-- Owner rotation invalidates the old secret and issues a new one; revocation
-- permanently disables that device ID. Replacement uses a newly provisioned device.
SELECT set_config('request.jwt.claim.sub','20300000-0000-4000-8000-000000000021',TRUE);
SET LOCAL ROLE authenticated;
DO $owner_rotate_revoke$
DECLARE
  v_device UUID := current_setting('atack_test.d32_r2_device_id')::UUID;
  v_result JSONB;
  v_token_v2 TEXT;
BEGIN
  v_result := public.rotate_sync_device_credential(v_device);
  v_token_v2 := v_result->>'device_token';
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE
     OR v_token_v2 IS NULL
     OR v_token_v2 !~ '^[0-9a-f]{64}

ROLLBACK;
 THEN
    RAISE EXCEPTION 'Provisioning did not return a UUID and 64-hex credential';
  END IF;
  PERFORM set_config('atack_test.d32_r2_device_id',v_device_id,TRUE);
  PERFORM set_config('atack_test.d32_r2_token_v1',v_token,TRUE);

  RAISE NOTICE 'PASS: owner can provision a user-bound device and receive its one-time credential';
END
$owner_provision$;
RESET ROLE;
DO $credential_hash_storage$
BEGIN
  IF EXISTS (
      SELECT 1 FROM public.device_credentials
       WHERE device_id=current_setting('atack_test.d32_r2_device_id')::UUID
         AND token_hash=current_setting('atack_test.d32_r2_token_v1')
  ) THEN
    RAISE EXCEPTION 'Raw device token was stored instead of its hash';
  END IF;
  IF NOT EXISTS (
      SELECT 1 FROM public.device_credentials
       WHERE device_id=current_setting('atack_test.d32_r2_device_id')::UUID
         AND token_hash=encode(public.atack_digest(
           convert_to(current_setting('atack_test.d32_r2_token_v1'),'UTF8'),'sha256'),'hex')
  ) THEN
    RAISE EXCEPTION 'Device credential hash was not persisted';
  END IF;
  RAISE NOTICE 'PASS: only the one-way credential hash is persisted';
END
$credential_hash_storage$;

-- Seller A can use the assigned device only with its current credential.
SELECT set_config('request.jwt.claim.sub','20300000-0000-4000-8000-000000000022',TRUE);
SET LOCAL ROLE authenticated;
DO $seller_a_device$
DECLARE
  v_store UUID := '10000000-0000-4000-8000-000000000001';
  v_device TEXT := current_setting('atack_test.d32_r2_device_id');
  v_token TEXT := current_setting('atack_test.d32_r2_token_v1');
  v_outbox UUID;
  v_result JSONB;
  v_denied BOOLEAN := FALSE;
  v_error TEXT;
BEGIN
  IF NOT has_function_privilege(current_user,
      'public.get_unsynced_records(uuid,text,text,bigint,text)','EXECUTE')
     OR has_function_privilege(current_user,
      'public.get_unsynced_records(uuid,text,text,bigint)','EXECUTE')
     OR has_function_privilege(current_user,
      'public.acknowledge_sync_cursor(uuid,text,text,bigint)','EXECUTE')
     OR has_function_privilege(current_user,
      'public.create_outbox_entry(uuid,text,text,text,uuid,uuid,jsonb)','EXECUTE')
     OR has_function_privilege(current_user,
      'public.apply_outbox_operation(uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'Tokenless sync RPC remains executable by authenticated';
  END IF;

  PERFORM * FROM public.get_unsynced_records(v_store,v_device,'products',0,v_token);
  IF NOT public.acknowledge_sync_cursor(v_store,v_device,'products',0,v_token) THEN
    RAISE EXCEPTION 'Authenticated device could not acknowledge its initial cursor';
  END IF;

  BEGIN
    PERFORM * FROM public.get_unsynced_records(
      v_store,v_device,'products',0,repeat('0',64));
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Device authentication failed%' THEN RAISE; END IF;
    v_denied := TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Wrong device token was accepted by Pull'; END IF;

  v_outbox := public.create_outbox_entry(
    v_store,v_device,'customers','INSERT',
    '99400000-0000-4000-8000-000000000021',
    '99500000-0000-4000-8000-000000000021',
    jsonb_build_object(
      'id','99400000-0000-4000-8000-000000000021',
      'store_id',v_store,
      'code','D32-R2-OUTBOX-CUSTOMER',
      'name','D3.2 R2 Outbox Customer',
      'is_active',TRUE
    ),
    v_token
  );
  v_result := public.apply_outbox_operation(v_outbox,v_device,v_token);
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Credential-bound Outbox apply failed: %',v_result;
  END IF;
  RAISE NOTICE 'PASS: assigned seller device can Pull, ACK and Push only with its credential';
END
$seller_a_device$;
RESET ROLE;

-- Seller B cannot impersonate Seller A's registered device, even in the same store.
SELECT set_config('request.jwt.claim.sub','20300000-0000-4000-8000-000000000023',TRUE);
SET LOCAL ROLE authenticated;
DO $seller_b_impersonation$
DECLARE
  v_denied BOOLEAN := FALSE;
  v_error TEXT;
BEGIN
  BEGIN
    PERFORM * FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      current_setting('atack_test.d32_r2_device_id'),'products',0,
      current_setting('atack_test.d32_r2_token_v1')
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Device authentication failed%' THEN RAISE; END IF;
    v_denied := TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Seller B impersonated Seller A device'; END IF;

  v_denied := FALSE;
  BEGIN
    PERFORM public.register_sync_device(
      '99100000-0000-4000-8000-000000000023','Unauthorized Seller Device','PHONE'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%sync.manage permission required%' THEN RAISE; END IF;
    v_denied := TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Seller was allowed to provision a device'; END IF;
  RAISE NOTICE 'PASS: another seller cannot impersonate or provision a device';
END
$seller_b_impersonation$;
RESET ROLE;

-- Owner rotation invalidates the old secret and issues a new one; revocation
-- permanently disables that device ID. Replacement uses a newly provisioned device.
SELECT set_config('request.jwt.claim.sub','20300000-0000-4000-8000-000000000021',TRUE);
SET LOCAL ROLE authenticated;
DO $owner_rotate_revoke$
DECLARE
  v_device UUID := current_setting('atack_test.d32_r2_device_id')::UUID;
  v_result JSONB;
  v_token_v2 TEXT;
BEGIN
  v_result := public.rotate_sync_device_credential(v_device);
  v_token_v2 := v_result->>'device_token';
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE
     OR v_token_v2 !~ '^[0-9a-f]{64}$'
     OR (v_result->>'credential_version')::INTEGER <> 2 THEN
    RAISE EXCEPTION 'Credential rotation failed: %',v_result;
  END IF;
  PERFORM set_config('atack_test.d32_r2_token_v2',v_token_v2,TRUE);
  IF NOT public.revoke_sync_device(v_device) THEN
    RAISE EXCEPTION 'Owner could not revoke the device';
  END IF;
  IF NOT public.revoke_sync_device(v_device) THEN
    RAISE EXCEPTION 'Repeated device revocation was not idempotent';
  END IF;
  RAISE NOTICE 'PASS: owner rotation and revocation are audited and idempotent';
END
$owner_rotate_revoke$;
RESET ROLE;

SELECT set_config('request.jwt.claim.sub','20300000-0000-4000-8000-000000000022',TRUE);
SET LOCAL ROLE authenticated;
DO $revoked_device_denial$
DECLARE denied BOOLEAN := FALSE; v_error TEXT;
BEGIN
  BEGIN
    PERFORM * FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      current_setting('atack_test.d32_r2_device_id'),'products',0,
      current_setting('atack_test.d32_r2_token_v2')
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Device authentication failed%' THEN RAISE; END IF;
    denied := TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Revoked device credential was accepted'; END IF;
  RAISE NOTICE 'PASS: revoked device cannot Pull';
END
$revoked_device_denial$;
RESET ROLE;

ROLLBACK;

     OR (v_result->>'credential_version')::INTEGER <> 2 THEN
    RAISE EXCEPTION 'Credential rotation failed: %',v_result;
  END IF;
  PERFORM set_config('atack_test.d32_r2_token_v2',v_token_v2,TRUE);
  RAISE NOTICE 'PASS: owner rotation issues a new credential version';
END
$owner_rotate_revoke$;
RESET ROLE;

-- Rotation immediately invalidates the previous token but preserves the active device.
SELECT set_config('request.jwt.claim.sub','20300000-0000-4000-8000-000000000022',TRUE);
SET LOCAL ROLE authenticated;
DO $rotated_token_checks$
DECLARE denied BOOLEAN := FALSE; v_error TEXT;
BEGIN
  BEGIN
    PERFORM * FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      current_setting('atack_test.d32_r2_device_id'),'products',0,
      current_setting('atack_test.d32_r2_token_v1')
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Device authentication failed%' THEN RAISE; END IF;
    denied := TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Rotated-out device token was still accepted'; END IF;
  PERFORM * FROM public.get_unsynced_records(
    '10000000-0000-4000-8000-000000000001',
    current_setting('atack_test.d32_r2_device_id'),'products',0,
    current_setting('atack_test.d32_r2_token_v2')
  );
  RAISE NOTICE 'PASS: rotated token works and the previous token is rejected';
END
$rotated_token_checks$;
RESET ROLE;

SELECT set_config('request.jwt.claim.sub','20300000-0000-4000-8000-000000000021',TRUE);
SET LOCAL ROLE authenticated;
DO $owner_revoke$
BEGIN
  IF NOT public.revoke_sync_device(
      current_setting('atack_test.d32_r2_device_id')::UUID
  ) THEN
    RAISE EXCEPTION 'Owner could not revoke the device';
  END IF;
  IF NOT public.revoke_sync_device(
      current_setting('atack_test.d32_r2_device_id')::UUID
  ) THEN
    RAISE EXCEPTION 'Repeated device revocation was not idempotent';
  END IF;
  RAISE NOTICE 'PASS: owner revocation is audited and idempotent';
END
$owner_revoke$;
RESET ROLE;

SELECT set_config('request.jwt.claim.sub','20300000-0000-4000-8000-000000000022',TRUE);
SET LOCAL ROLE authenticated;
DO $revoked_device_denial$
DECLARE denied BOOLEAN := FALSE; v_error TEXT;
BEGIN
  BEGIN
    PERFORM * FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      current_setting('atack_test.d32_r2_device_id'),'products',0,
      current_setting('atack_test.d32_r2_token_v2')
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Device authentication failed%' THEN RAISE; END IF;
    denied := TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Revoked device credential was accepted'; END IF;
  RAISE NOTICE 'PASS: revoked device cannot Pull';
END
$revoked_device_denial$;
RESET ROLE;

ROLLBACK;
 THEN
    RAISE EXCEPTION 'Provisioning did not return a UUID and 64-hex credential';
  END IF;
  PERFORM set_config('atack_test.d32_r2_device_id',v_device_id,TRUE);
  PERFORM set_config('atack_test.d32_r2_token_v1',v_token,TRUE);

  RAISE NOTICE 'PASS: owner can provision a user-bound device and receive its one-time credential';
END
$owner_provision$;
RESET ROLE;
DO $credential_hash_storage$
BEGIN
  IF EXISTS (
      SELECT 1 FROM public.device_credentials
       WHERE device_id=current_setting('atack_test.d32_r2_device_id')::UUID
         AND token_hash=current_setting('atack_test.d32_r2_token_v1')
  ) THEN
    RAISE EXCEPTION 'Raw device token was stored instead of its hash';
  END IF;
  IF NOT EXISTS (
      SELECT 1 FROM public.device_credentials
       WHERE device_id=current_setting('atack_test.d32_r2_device_id')::UUID
         AND token_hash=encode(public.atack_digest(
           convert_to(current_setting('atack_test.d32_r2_token_v1'),'UTF8'),'sha256'),'hex')
  ) THEN
    RAISE EXCEPTION 'Device credential hash was not persisted';
  END IF;
  RAISE NOTICE 'PASS: only the one-way credential hash is persisted';
END
$credential_hash_storage$;

-- Seller A can use the assigned device only with its current credential.
SELECT set_config('request.jwt.claim.sub','20300000-0000-4000-8000-000000000022',TRUE);
SET LOCAL ROLE authenticated;
DO $seller_a_device$
DECLARE
  v_store UUID := '10000000-0000-4000-8000-000000000001';
  v_device TEXT := current_setting('atack_test.d32_r2_device_id');
  v_token TEXT := current_setting('atack_test.d32_r2_token_v1');
  v_outbox UUID;
  v_result JSONB;
  v_denied BOOLEAN := FALSE;
  v_error TEXT;
BEGIN
  IF NOT has_function_privilege(current_user,
      'public.get_unsynced_records(uuid,text,text,bigint,text)','EXECUTE')
     OR has_function_privilege(current_user,
      'public.get_unsynced_records(uuid,text,text,bigint)','EXECUTE')
     OR has_function_privilege(current_user,
      'public.acknowledge_sync_cursor(uuid,text,text,bigint)','EXECUTE')
     OR has_function_privilege(current_user,
      'public.create_outbox_entry(uuid,text,text,text,uuid,uuid,jsonb)','EXECUTE')
     OR has_function_privilege(current_user,
      'public.apply_outbox_operation(uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'Tokenless sync RPC remains executable by authenticated';
  END IF;

  PERFORM * FROM public.get_unsynced_records(v_store,v_device,'products',0,v_token);
  IF NOT public.acknowledge_sync_cursor(v_store,v_device,'products',0,v_token) THEN
    RAISE EXCEPTION 'Authenticated device could not acknowledge its initial cursor';
  END IF;

  BEGIN
    PERFORM * FROM public.get_unsynced_records(
      v_store,v_device,'products',0,repeat('0',64));
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Device authentication failed%' THEN RAISE; END IF;
    v_denied := TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Wrong device token was accepted by Pull'; END IF;

  v_outbox := public.create_outbox_entry(
    v_store,v_device,'customers','INSERT',
    '99400000-0000-4000-8000-000000000021',
    '99500000-0000-4000-8000-000000000021',
    jsonb_build_object(
      'id','99400000-0000-4000-8000-000000000021',
      'store_id',v_store,
      'code','D32-R2-OUTBOX-CUSTOMER',
      'name','D3.2 R2 Outbox Customer',
      'is_active',TRUE
    ),
    v_token
  );
  v_result := public.apply_outbox_operation(v_outbox,v_device,v_token);
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Credential-bound Outbox apply failed: %',v_result;
  END IF;
  RAISE NOTICE 'PASS: assigned seller device can Pull, ACK and Push only with its credential';
END
$seller_a_device$;
RESET ROLE;

-- Seller B cannot impersonate Seller A's registered device, even in the same store.
SELECT set_config('request.jwt.claim.sub','20300000-0000-4000-8000-000000000023',TRUE);
SET LOCAL ROLE authenticated;
DO $seller_b_impersonation$
DECLARE
  v_denied BOOLEAN := FALSE;
  v_error TEXT;
BEGIN
  BEGIN
    PERFORM * FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      current_setting('atack_test.d32_r2_device_id'),'products',0,
      current_setting('atack_test.d32_r2_token_v1')
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Device authentication failed%' THEN RAISE; END IF;
    v_denied := TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Seller B impersonated Seller A device'; END IF;

  v_denied := FALSE;
  BEGIN
    PERFORM public.register_sync_device(
      '99100000-0000-4000-8000-000000000023','Unauthorized Seller Device','PHONE'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%sync.manage permission required%' THEN RAISE; END IF;
    v_denied := TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Seller was allowed to provision a device'; END IF;
  RAISE NOTICE 'PASS: another seller cannot impersonate or provision a device';
END
$seller_b_impersonation$;
RESET ROLE;

-- Owner rotation invalidates the old secret and issues a new one; revocation
-- permanently disables that device ID. Replacement uses a newly provisioned device.
SELECT set_config('request.jwt.claim.sub','20300000-0000-4000-8000-000000000021',TRUE);
SET LOCAL ROLE authenticated;
DO $owner_rotate_revoke$
DECLARE
  v_device UUID := current_setting('atack_test.d32_r2_device_id')::UUID;
  v_result JSONB;
  v_token_v2 TEXT;
BEGIN
  v_result := public.rotate_sync_device_credential(v_device);
  v_token_v2 := v_result->>'device_token';
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE
     OR v_token_v2 !~ '^[0-9a-f]{64}$'
     OR (v_result->>'credential_version')::INTEGER <> 2 THEN
    RAISE EXCEPTION 'Credential rotation failed: %',v_result;
  END IF;
  PERFORM set_config('atack_test.d32_r2_token_v2',v_token_v2,TRUE);
  IF NOT public.revoke_sync_device(v_device) THEN
    RAISE EXCEPTION 'Owner could not revoke the device';
  END IF;
  IF NOT public.revoke_sync_device(v_device) THEN
    RAISE EXCEPTION 'Repeated device revocation was not idempotent';
  END IF;
  RAISE NOTICE 'PASS: owner rotation and revocation are audited and idempotent';
END
$owner_rotate_revoke$;
RESET ROLE;

SELECT set_config('request.jwt.claim.sub','20300000-0000-4000-8000-000000000022',TRUE);
SET LOCAL ROLE authenticated;
DO $revoked_device_denial$
DECLARE denied BOOLEAN := FALSE; v_error TEXT;
BEGIN
  BEGIN
    PERFORM * FROM public.get_unsynced_records(
      '10000000-0000-4000-8000-000000000001',
      current_setting('atack_test.d32_r2_device_id'),'products',0,
      current_setting('atack_test.d32_r2_token_v2')
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Device authentication failed%' THEN RAISE; END IF;
    denied := TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Revoked device credential was accepted'; END IF;
  RAISE NOTICE 'PASS: revoked device cannot Pull';
END
$revoked_device_denial$;
RESET ROLE;

ROLLBACK;
