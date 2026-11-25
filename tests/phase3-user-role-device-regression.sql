-- Owner/seller role delegation and device-visibility security regressions.
INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 ('99000000-0000-4000-8000-000000000005','20000000-0000-4000-8000-000000000005',
  '10000000-0000-4000-8000-000000000001','phase3_seller_user','Phase 3 Seller',TRUE),
 ('99000000-0000-4000-8000-000000000006','20000000-0000-4000-8000-000000000006',
  '10000000-0000-4000-8000-000000000001','phase3_role_target','Phase 3 Role Target',TRUE),
 ('99000000-0000-4000-8000-000000000007','20000000-0000-4000-8000-000000000007',
  '10000000-0000-4000-8000-000000000001','phase3_single_role','Phase 3 Single Role',TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.user_roles(user_id,role_id)
VALUES ('99000000-0000-4000-8000-000000000005','cashier'),
       ('99000000-0000-4000-8000-000000000007','cashier')
ON CONFLICT DO NOTHING;

INSERT INTO public.devices(id,store_id,device_name,device_type,is_online)
VALUES
 ('91000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','Owner Test Device','DESKTOP',TRUE),
 ('92000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000002','Other Store Device','DESKTOP',TRUE)
ON CONFLICT (id) DO NOTHING;

DO $role_acl$
BEGIN
  IF has_table_privilege('authenticated','public.user_roles','INSERT')
     OR has_table_privilege('authenticated','public.user_roles','UPDATE')
     OR has_table_privilege('authenticated','public.user_roles','DELETE')
     OR has_table_privilege('authenticated','public.user_roles','TRUNCATE') THEN
    RAISE EXCEPTION 'authenticated retains direct user_roles write privileges';
  END IF;
  IF NOT has_function_privilege('authenticated',
      'public.manage_store_user_role(uuid,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'Authenticated cannot call the controlled role-management RPC';
  END IF;
  RAISE NOTICE 'PASS: direct role writes are revoked and controlled role RPC is executable';
END
$role_acl$;

BEGIN;
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000005',TRUE);
SET LOCAL ROLE authenticated;
DO $seller_role_limits$
DECLARE denied BOOLEAN:=FALSE; v_error TEXT;
BEGIN
  BEGIN
    PERFORM public.manage_store_user_role(
      '99000000-0000-4000-8000-000000000006','owner','GRANT');
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%users.manage permission required%' THEN RAISE; END IF;
    denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Seller was able to grant the owner role'; END IF;

  denied:=FALSE;
  BEGIN
    PERFORM public.manage_store_user_role(
      '99000000-0000-4000-8000-000000000006','cashier','GRANT');
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%users.manage permission required%' THEN RAISE; END IF;
    denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Seller was able to manage another user role'; END IF;
  IF EXISTS(SELECT 1 FROM public.user_roles WHERE user_id='99000000-0000-4000-8000-000000000006') THEN
    RAISE EXCEPTION 'Seller role-management denial left an unexpected role assignment';
  END IF;
  RAISE NOTICE 'PASS: seller cannot grant owner or manage another seller''s roles';
END
$seller_role_limits$;
ROLLBACK;

BEGIN;
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',TRUE);
SET LOCAL ROLE authenticated;
DO $owner_role_management$
DECLARE result JSONB; denied BOOLEAN:=FALSE; v_error TEXT; n INTEGER;
BEGIN
  result:=public.manage_store_user_role(
    '99000000-0000-4000-8000-000000000006','cashier','GRANT');
  IF COALESCE((result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Owner could not grant seller role: %',result;
  END IF;
  result:=public.manage_store_user_role(
    '99000000-0000-4000-8000-000000000006','stock_keeper','GRANT');
  IF COALESCE((result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Owner could not grant an optional delegated role: %',result;
  END IF;
  result:=public.manage_store_user_role(
    '99000000-0000-4000-8000-000000000006','cashier','REVOKE');
  IF COALESCE((result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Owner could not revoke a delegated role: %',result;
  END IF;

  denied:=FALSE;
  BEGIN
    PERFORM public.manage_store_user_role(
      '99000000-0000-4000-8000-000000000007','cashier','REVOKE');
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Cannot revoke the target user''s final role%' THEN RAISE; END IF;
    denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'RPC allowed removal of a target user''s final role'; END IF;

  denied:=FALSE;
  BEGIN
    PERFORM public.manage_store_user_role(
      '99000000-0000-4000-8000-000000000007','cashier',NULL);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Action must be GRANT or REVOKE%' THEN RAISE; END IF;
    denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'RPC treated NULL action as REVOKE'; END IF;

  denied:=FALSE;
  BEGIN
    PERFORM public.manage_store_user_role(
      '30000000-0000-4000-8000-000000000004','cashier','GRANT');
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%Target user is missing, inactive or belongs to another store%' THEN RAISE; END IF;
    denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Cross-store role grant was accepted'; END IF;

  SELECT count(*) INTO n FROM public.user_roles
   WHERE user_id='99000000-0000-4000-8000-000000000006';
  IF n<>1 OR NOT EXISTS(SELECT 1 FROM public.user_roles
      WHERE user_id='99000000-0000-4000-8000-000000000006' AND role_id='stock_keeper') THEN
    RAISE EXCEPTION 'Owner delegation did not persist the expected optional role';
  END IF;
  RAISE NOTICE 'PASS: owner can manage seller roles and optional delegation without crossing stores or removing a final role';
END
$owner_role_management$;
ROLLBACK;

BEGIN;
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',TRUE);
SET LOCAL ROLE authenticated;
DO $owner_device_visibility$
DECLARE n INTEGER;
BEGIN
  SELECT count(*) INTO n FROM public.devices;
  IF n<1 OR EXISTS(SELECT 1 FROM public.devices WHERE store_id='10000000-0000-4000-8000-000000000002') THEN
    RAISE EXCEPTION 'Owner device visibility is not restricted to the owner''s store';
  END IF;
  SELECT count(*) INTO n FROM public.user_roles;
  IF n<1 THEN RAISE EXCEPTION 'Owner cannot view seller role assignments'; END IF;
  RAISE NOTICE 'PASS: owner sees own-store devices and role assignments';
END
$owner_device_visibility$;
ROLLBACK;

BEGIN;
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000005',TRUE);
SET LOCAL ROLE authenticated;
DO $seller_visibility$
DECLARE n INTEGER; denied BOOLEAN:=FALSE;
BEGIN
  SELECT count(*) INTO n FROM public.devices;
  IF n<>0 THEN RAISE EXCEPTION 'Seller can view devices without sync.manage'; END IF;
  SELECT count(*) INTO n FROM public.user_roles;
  IF n<>0 THEN RAISE EXCEPTION 'Seller can view role assignments without users.manage'; END IF;
  BEGIN
    INSERT INTO public.devices(store_id,device_name,device_type)
    VALUES('10000000-0000-4000-8000-000000000001','Unauthorized Seller Device','PHONE');
  EXCEPTION WHEN insufficient_privilege THEN denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Seller direct device registration was not denied'; END IF;
  RAISE NOTICE 'PASS: seller cannot view devices/role assignments or register a device';
END
$seller_visibility$;
ROLLBACK;
