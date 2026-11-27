-- Consolidate the operational RBAC model to one store owner and individual sellers.
-- Legacy role rows are retained for FK/history safety, but are made inactive and
-- stripped of permissions. Active legacy assignments must be remapped explicitly
-- before this migration is allowed to proceed; no account is silently promoted.
BEGIN;

DO $legacy_assignment_preflight$
DECLARE
  v_assignments TEXT;
BEGIN
  SELECT string_agg(format('%s=%s',c.role_id,c.role_count),', ' ORDER BY c.role_id)
    INTO v_assignments
    FROM (
      SELECT ur.role_id,count(*) AS role_count
        FROM public.user_roles ur
        JOIN public.users u ON u.id=ur.user_id
       WHERE u.is_active=TRUE
         AND ur.role_id IN ('admin','accountant','stock_keeper')
       GROUP BY ur.role_id
    ) c;

  IF v_assignments IS NOT NULL THEN
    RAISE EXCEPTION
      'Owner/seller role consolidation blocked: active users still have legacy role assignments (%). Review and explicitly remap each account before retrying; no automatic promotion is permitted.',
      v_assignments;
  END IF;
END
$legacy_assignment_preflight$;

-- Keep the existing cashier key as a technical seller-role identifier. Renaming
-- the key would break existing user_roles foreign keys and application contracts.
UPDATE public.roles
   SET name='بائع',
       description='الدور التقني المعتمد لحساب البائع؛ صلاحيات بيع محدودة ببياناته',
       is_active=TRUE
 WHERE id='cashier';

-- Do not drop legacy role rows: historical FK references may exist. Disable them
-- and remove every permission grant so they cannot authorize any active user.
DELETE FROM public.role_permissions
 WHERE role_id IN ('admin','accountant','stock_keeper');

UPDATE public.roles
   SET is_active=FALSE,
       description=COALESCE(description,'') ||
         CASE WHEN COALESCE(description,'')='' THEN '' ELSE ' — ' END ||
         'دور قديم غير معتمد؛ معطل ولا يمنح أي صلاحيات'
 WHERE id IN ('admin','accountant','stock_keeper');

-- Permission resolution must independently reject inactive roles. This is a
-- defense-in-depth guard even if an inactive role is accidentally re-granted.
CREATE OR REPLACE FUNCTION public.has_store_permission(
    p_store_id UUID,
    p_permission_code TEXT
) RETURNS BOOLEAN AS $$
    SELECT auth.uid() IS NOT NULL AND EXISTS (
        SELECT 1
          FROM public.users u
          JOIN public.user_roles ur ON ur.user_id = u.id
          JOIN public.roles r ON r.id = ur.role_id AND r.is_active=TRUE
          JOIN public.role_permissions rp ON rp.role_id = ur.role_id
          JOIN public.permissions p ON p.id = rp.permission_id
         WHERE u.auth_user_id = auth.uid()
           AND u.store_id = p_store_id
           AND u.is_active = TRUE
           AND p.code = p_permission_code
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

DO $role_model_assertions$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.roles WHERE id='owner' AND is_active=TRUE)
     OR NOT EXISTS (SELECT 1 FROM public.roles WHERE id='cashier' AND is_active=TRUE) THEN
    RAISE EXCEPTION 'Required owner or seller (cashier technical key) role is missing/inactive';
  END IF;
  IF EXISTS (SELECT 1 FROM public.roles
      WHERE id IN ('admin','accountant','stock_keeper') AND is_active=TRUE) THEN
    RAISE EXCEPTION 'A legacy role remains active after owner/seller consolidation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.role_permissions
      WHERE role_id IN ('admin','accountant','stock_keeper')) THEN
    RAISE EXCEPTION 'A legacy role still has permission grants';
  END IF;
END
$role_model_assertions$;

COMMIT;
