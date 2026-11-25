-- User-role delegation and device-visibility security regressions.
INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 ('99000000-0000-4000-8000-000000000005','20000000-0000-4000-8000-000000000005',
  '10000000-0000-4000-8000-000000000001','phase3_admin_user','Phase 3 Admin',TRUE),
 ('99000000-0000-4000-8000-000000000006','20000000-0000-4000-8000-000000000006',
  '10000000-0000-4000-8000-000000000001','phase3_role_target','Phase 3 Role Target',TRUE),
 ('99000000-0000-4000-8000-000000000007','20000000-0000-4000-8000-000000000007',
  '10000000-0000-4000-8000-000000000001','phase3_single_role','Phase 3 Single Role',TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.user_roles(user_id,role_id)
VALUES
 ('99000000-0000-4000-8000-000000000005','admin'),
 ('99000000-0000-4000-8000-000000000007','cashier')
ON CONFLICT DO NOTHING;

INSERT INTO public.devices(id,store_id,device_name,device_type,is_online)
VALUES
 ('91000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','Admin Test Device','DESKTOP',TRUE),
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
DO $admin_role_limits$
DECLARE denied BOOLEAN:=FALSE; result JSONB; n INTEGER;
BEGIN
  BEGIN
    PERFORM public.manage_store_user_role(
      '99000000-0000-4000-8000-000000000006','owner','GRANT');
  EXCEPTION WHEN raise_exception THEN denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Admin was able to grant owner role'; END IF;

  result:=public.manage_store_user_role(
    '99000000-0000-4000-8000-000000000006','cashier','GRANT');
  IF COALESCE((result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Admin could not grant a role within their permission set: %',result;
  END IF;
  result:=public.manage_store_user_role(
    '99000000-0000-4000-8000-000000000006','stock_keeper','GRANT');
  IF COALESCE((result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Admin could not grant a second permitted role: %',result;
  END IF;
  result:=public.manage_store_user_role(
    '99000000-0000-4000-8000-000000000006','cashier','REVOKE');
  IF COALESCE((result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Admin could not revoke a role within their permission set: %',result;
  END IF;

  denied:=FALSE;
  BEGIN
    PERFORM public.manage_store_user_role(
      '30000000-0000-4000-8000-000000000001','owner','REVOKE');
  EXCEPTION WHEN raise_exception THEN denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Admin was able to revoke the owner role'; END IF;

  denied:=FALSE;
  BEGIN
    PERFORM public.manage_store_user_role(
      '99000000-0000-4000-8000-000000000007','cashier','REVOKE');
  EXCEPTION WHEN raise_exception THEN denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'RPC allowed removal of a target user''s final role'; END IF;

  denied:=FALSE;
  BEGIN
    PERFORM public.manage_store_user_role(
      '99000000-0000-4000-8000-000000000007','cashier',NULL);
  EXCEPTION WHEN raise_exception THEN denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'RPC treated NULL action as REVOKE'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.user_roles
      WHERE user_id='99000000-0000-4000-8000-000000000007' AND role_id='cashier') THEN
    RAISE EXCEPTION 'NULL role action removed the target role';
  END IF;

  denied:=FALSE;
  BEGIN
    PERFORM public.manage_store_user_role(
      '30000000-0000-4000-8000-000000000004','cashier','GRANT');
  EXCEPTION WHEN raise_exception THEN denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Cross-store role grant was accepted'; END IF;

  SELECT count(*) INTO n FROM public.user_roles
   WHERE user_id='99000000-0000-4000-8000-000000000006';
  IF n<>1 OR NOT EXISTS(SELECT 1 FROM public.user_roles
      WHERE user_id='99000000-0000-4000-8000-000000000006' AND role_id='stock_keeper') THEN
    RAISE EXCEPTION 'Role delegation did not persist the expected role set';
  END IF;
  RAISE NOTICE 'PASS: admin cannot escalate to owner, can manage only covered roles, and cannot cross stores or remove final roles';
END
$admin_role_limits$;
ROLLBACK;

BEGIN;
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',TRUE);
SET LOCAL ROLE authenticated;
DO $owner_role_grant$
DECLARE result JSONB;
BEGIN
  result:=public.manage_store_user_role(
    '99000000-0000-4000-8000-000000000006','admin','GRANT');
  IF COALESCE((result->>'success')::BOOLEAN,FALSE) IS NOT TRUE
     OR NOT EXISTS(SELECT 1 FROM public.user_roles
       WHERE user_id='99000000-0000-4000-8000-000000000006' AND role_id='admin') THEN
    RAISE EXCEPTION 'Owner could not grant admin role: %',result;
  END IF;
  RAISE NOTICE 'PASS: owner can grant a role covered by the owner permission set';
END
$owner_role_grant$;
ROLLBACK;

BEGIN;
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000005',TRUE);
SET LOCAL ROLE authenticated;
DO $device_visibility$
DECLARE n INTEGER; denied BOOLEAN:=FALSE;
BEGIN
  SELECT count(*) INTO n FROM public.devices;
  IF n<1 OR EXISTS(SELECT 1 FROM public.devices WHERE store_id='10000000-0000-4000-8000-000000000002') THEN
    RAISE EXCEPTION 'Sync manager device visibility is not store-scoped';
  END IF;
  SELECT count(*) INTO n FROM public.user_roles;
  IF n<1 THEN RAISE EXCEPTION 'Users manager cannot view role assignments'; END IF;
  RAISE NOTICE 'PASS: sync manager sees only own-store devices and users manager sees role assignments';
END
$device_visibility$;
ROLLBACK;

BEGIN;
SELECT set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000007',TRUE);
SET LOCAL ROLE authenticated;
DO $cashier_visibility$
DECLARE n INTEGER; denied BOOLEAN:=FALSE;
BEGIN
  SELECT count(*) INTO n FROM public.devices;
  IF n<>0 THEN RAISE EXCEPTION 'Cashier can view devices without sync.manage'; END IF;
  SELECT count(*) INTO n FROM public.user_roles;
  IF n<>0 THEN RAISE EXCEPTION 'Cashier can view role assignments without users.manage'; END IF;
  BEGIN
    INSERT INTO public.devices(store_id,device_name,device_type)
    VALUES('10000000-0000-4000-8000-000000000001','Unauthorized Cashier Device','PHONE');
  EXCEPTION WHEN insufficient_privilege THEN denied:=TRUE;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Cashier direct device registration was not denied'; END IF;
  RAISE NOTICE 'PASS: non-manager cannot view devices/roles or register a device';
END
$cashier_visibility$;
ROLLBACK;
