-- Explicit role matrix and privilege-escalation regression.
-- Uses the real seeded role_permissions plus the ordered Phase 3 permission migrations.
BEGIN;

INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
VALUES
 ('99100000-0000-4000-8000-000000000011','20100000-0000-4000-8000-000000000011',
  '10000000-0000-4000-8000-000000000001','matrix_admin','Role Matrix Admin',TRUE),
 ('99100000-0000-4000-8000-000000000012','20100000-0000-4000-8000-000000000012',
  '10000000-0000-4000-8000-000000000001','matrix_accountant','Role Matrix Accountant',TRUE),
 ('99100000-0000-4000-8000-000000000013','20100000-0000-4000-8000-000000000013',
  '10000000-0000-4000-8000-000000000001','matrix_seller','Role Matrix Seller',TRUE),
 ('99100000-0000-4000-8000-000000000014','20100000-0000-4000-8000-000000000014',
  '10000000-0000-4000-8000-000000000001','matrix_stock_keeper','Role Matrix Stock Keeper',TRUE),
 ('99100000-0000-4000-8000-000000000015','20100000-0000-4000-8000-000000000015',
  '10000000-0000-4000-8000-000000000001','matrix_target','Role Matrix Target',TRUE)
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.user_roles(user_id,role_id)
VALUES
 ('99100000-0000-4000-8000-000000000011','admin'),
 ('99100000-0000-4000-8000-000000000012','accountant'),
 ('99100000-0000-4000-8000-000000000013','cashier'),
 ('99100000-0000-4000-8000-000000000014','stock_keeper')
ON CONFLICT(user_id,role_id) DO NOTHING;

SET LOCAL ROLE authenticated;

DO $role_matrix$
DECLARE
  v_error TEXT;
  v_result JSONB;
  v_denied BOOLEAN;
BEGIN
  -- Owner / Super Admin.
  PERFORM set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',TRUE);
  IF NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','settings.write')
     OR NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','audit.read')
     OR NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','purchases.return')
     OR NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','inventory.adjust')
     OR NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','inventory.allow_negative') THEN
    RAISE EXCEPTION 'Owner role is missing one or more Super Admin permissions';
  END IF;

  -- Admin: privileged operations, but no settings.write or owner-only audit.read.
  PERFORM set_config('request.jwt.claim.sub','20100000-0000-4000-8000-000000000011',TRUE);
  IF NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','users.manage')
     OR NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','purchases.return')
     OR NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','inventory.adjust')
     OR public.has_store_permission('10000000-0000-4000-8000-000000000001','settings.write')
     OR public.has_store_permission('10000000-0000-4000-8000-000000000001','audit.read') THEN
    RAISE EXCEPTION 'Admin permission boundary does not match the approved matrix';
  END IF;

  -- Accountant: financial visibility and payment operations, no privileged stock/purchase mutation.
  PERFORM set_config('request.jwt.claim.sub','20100000-0000-4000-8000-000000000012',TRUE);
  IF NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','reports.financial')
     OR NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','customers.payments')
     OR NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','suppliers.payments')
     OR NOT public.has_store_permission('10000000-0000-4000-8000/000000000001','sales.read')
     OR NOT public.has_store_permission('10000000-0000-4000-8000/000000000001','purchases.read')
     OR public.has_store_permission('10000000-0000-4000-8000/000000000001','sales.write')
     OR public.has_store_permission('10000000-0000-4000-8000/000000000001','purchases.write')
     OR public.has_store_permission('10000000-0000-4000-8000/000000000001','purchases.return')
     OR public.has_store_permission('10000000-0000-4000-8000/000000000001','inventory.adjust')
     OR public.has_store_permission('10000000-0000-4000-8000/000000000001','audit.read') THEN
    RAISE EXCEPTION 'Accountant permission boundary does not match the approved matrix';
  END IF;

  -- Seller uses the existing cashier database key; this is not a separate cashier business role.
  PERFORM set_config('request.jwt.claim.sub','20100000-0000-4000-8000-000000000013',TRUE);
  IF NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','sales.write')
     OR NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','customers.payments')
     OR NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','inventory.read')
     OR NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','reports.inventory')
     OR public.has_store_permission('10000000-0000-4000-8000-000000000001','purchases.write')
     OR public.has_store_permission('10000000-0000-4000-8000-000000000001','purchases.return')
     OR public.has_store_permission('10000000-0000-4000-8000-000000000001','suppliers.payments')
     OR public.has_store_permission('10000000-0000-4000-8000-000000000001','inventory.write')
     OR public.has_store_permission('10000000-0000-4000-8000-000000000001','inventory.adjust')
     OR public.has_store_permission('10000000-0000-4000-8000-000000000001','reports.financial')
     OR public.has_store_permission('10000000-0000-4000-8000-000000000001','users.manage')
     OR public.has_store_permission('10000000-0000-4000-8000-000000000001','audit.read') THEN
    RAISE EXCEPTION 'Seller/cashier permission boundary does not match the approved matrix';
  END IF;

  -- Stock keeper: inventory and purchasing work, but no privileged adjustment/return rights.
  PERFORM set_config('request.jwt.claim.sub','20100000-0000-4000-8000-000000000014',TRUE);
  IF NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','products.write')
     OR NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','inventory.write')
     OR NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','purchases.write')
     OR NOT public.has_store_permission('10000000-0000-4000-8000-000000000001','purchases.receive')
     OR public.has_store_permission('10000000-0000-4000-8000-000000000001','inventory.adjust')
     OR public.has_store_permission('10000000-0000-4000-8000-000000000001','purchases.return')
     OR public.has_store_permission('10000000-0000-4000-8000-000000000001','sales.write')
     OR public.has_store_permission('10000000-0000-4000-8000-000000000001','reports.financial')
     OR public.has_store_permission('10000000-0000-4000-8000-000000000001','audit.read') THEN
    RAISE EXCEPTION 'Stock keeper permission boundary does not match the approved matrix';
  END IF;

  -- Admin can delegate seller access, but cannot escalate a user to owner.
  PERFORM set_config('request.jwt.claim.sub','20100000-0000-4000-8000-000000000011',TRUE);
  v_result:=public.manage_store_user_role(
    '99100000-0000-4000-8000-000000000015','cashier','GRANT');
  IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Admin could not grant a role within its own permission set: %',v_result;
  END IF;

  v_denied:=FALSE;
  BEGIN
    PERFORM public.manage_store_user_role(
      '99100000-0000-4000-8000-000000000015','owner','GRANT');
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
    IF v_error NOT LIKE '%Cannot manage a role containing permissions the caller does not hold%' THEN
      RAISE;
    END IF;
    v_denied:=TRUE;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'Admin was able to grant the full owner/Super Admin role';
  END IF;
  IF EXISTS(SELECT 1 FROM public.user_roles
      WHERE user_id='99100000-0000-4000-8000-000000000015' AND role_id='owner') THEN
    RAISE EXCEPTION 'Denied owner-role grant left an unexpected privilege assignment';
  END IF;

  RAISE NOTICE 'PASS: owner/admin/accountant/seller/stock_keeper role matrix and admin-to-owner escalation denial';
END
$role_matrix$;

ROLLBACK;
