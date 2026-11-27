-- Owner/seller-only role model regression.
-- 'cashier' is retained solely as the technical database key for seller accounts.
BEGIN;

DO $role_catalog$
DECLARE v_active_roles TEXT[];
BEGIN
  SELECT array_agg(id ORDER BY id) INTO v_active_roles
    FROM public.roles WHERE is_active=TRUE;
  IF v_active_roles IS DISTINCT FROM ARRAY['cashier','owner']::TEXT[] THEN
    RAISE EXCEPTION 'Expected only owner and seller(cashier key) to be active; found %',v_active_roles;
  END IF;

  IF EXISTS (SELECT 1 FROM public.role_permissions
      WHERE role_id IN ('admin','accountant','stock_keeper')) THEN
    RAISE EXCEPTION 'Legacy roles still carry permission grants';
  END IF;
  IF EXISTS (SELECT 1 FROM public.users u
      JOIN public.user_roles ur ON ur.user_id=u.id
      WHERE u.is_active=TRUE
        AND ur.role_id IN ('admin','accountant','stock_keeper')) THEN
    RAISE EXCEPTION 'An active user still has a legacy role assignment';
  END IF;

  IF position('r.is_active' IN pg_get_functiondef(
      'public.has_store_permission(uuid,text)'::regprocedure))=0 THEN
    RAISE EXCEPTION 'Permission resolver does not exclude inactive roles';
  END IF;
  RAISE NOTICE 'PASS: only owner and seller technical role are active; legacy roles are disabled and unprivileged';
END
$role_catalog$;

INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 ('99200000-0000-4000-8000-000000000001','20200000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001','owner_seller_matrix_target','Owner Seller Matrix Target',TRUE)
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.user_roles(user_id,role_id)
VALUES ('99200000-0000-4000-8000-000000000001','cashier')
ON CONFLICT(user_id,role_id) DO NOTHING;

SET LOCAL ROLE authenticated;
DO $owner_seller_permissions$
DECLARE
  v_store UUID:='10000000-0000-4000-8000-000000000001';
  v_denied BOOLEAN;
  v_error TEXT;
  v_legacy TEXT;
BEGIN
  -- The store owner has the complete operational and administrative authority.
  PERFORM set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',TRUE);
  IF NOT public.has_store_permission(v_store,'users.manage')
     OR NOT public.has_store_permission(v_store,'settings.write')
     OR NOT public.has_store_permission(v_store,'audit.read')
     OR NOT public.has_store_permission(v_store,'purchases.write')
     OR NOT public.has_store_permission(v_store,'purchases.return')
     OR NOT public.has_store_permission(v_store,'inventory.adjust')
     OR NOT public.has_store_permission(v_store,'inventory.allow_negative')
     OR NOT public.has_store_permission(v_store,'reports.financial')
     OR NOT public.has_store_permission(v_store,'sync.manage') THEN
    RAISE EXCEPTION 'Owner is missing one or more Super Admin permissions';
  END IF;

  -- Seller can perform sales/customer collection and read required catalog/stock.
  PERFORM set_config('request.jwt.claim.sub','20200000-0000-4000-8000-000000000001',TRUE);
  IF NOT public.has_store_permission(v_store,'sales.read')
     OR NOT public.has_store_permission(v_store,'sales.write')
     OR NOT public.has_store_permission(v_store,'customers.read')
     OR NOT public.has_store_permission(v_store,'customers.payments')
     OR NOT public.has_store_permission(v_store,'products.read')
     OR NOT public.has_store_permission(v_store,'inventory.read')
     OR public.has_store_permission(v_store,'users.manage')
     OR public.has_store_permission(v_store,'purchases.write')
     OR public.has_store_permission(v_store,'purchases.return')
     OR public.has_store_permission(v_store,'suppliers.payments')
     OR public.has_store_permission(v_store,'inventory.write')
     OR public.has_store_permission(v_store,'inventory.adjust')
     OR public.has_store_permission(v_store,'reports.financial')
     OR public.has_store_permission(v_store,'audit.read')
     OR public.has_store_permission(v_store,'sync.manage') THEN
    RAISE EXCEPTION 'Seller permission boundary is broader or narrower than the approved business model';
  END IF;

  -- Owner cannot provision a legacy job role, even though its FK row is retained.
  PERFORM set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',TRUE);
  FOREACH v_legacy IN ARRAY ARRAY['admin','accountant','stock_keeper'] LOOP
    v_denied:=FALSE;
    BEGIN
      PERFORM public.manage_store_user_role(
        '99200000-0000-4000-8000-000000000001',v_legacy,'GRANT');
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error NOT LIKE '%Target role does not exist or is inactive%' THEN RAISE; END IF;
      v_denied:=TRUE;
    END;
    IF NOT v_denied THEN
      RAISE EXCEPTION 'Owner was able to assign inactive legacy role %',v_legacy;
    END IF;
  END LOOP;

  RAISE NOTICE 'PASS: owner has Super Admin authority; seller is limited to sales and own activity; inactive legacy roles cannot be assigned';
END
$owner_seller_permissions$;

ROLLBACK;
