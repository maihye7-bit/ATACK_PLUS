-- Stage 3 / Part A: store-scoped warehouses and same-store inventory references.
-- Existing location codes (main/warehouse/storage) are retained as codes, while
-- every store receives independent UUID-backed location records.
-- This migration is transactional and deliberately fails on ambiguous legacy data.

BEGIN;

SELECT pg_advisory_xact_lock(hashtext('atack_plus:stage3:store_scoped_warehouses'));

LOCK TABLE public.stores, public.locations, public.products,
           public.stock, public.stock_movements
    IN ACCESS EXCLUSIVE MODE;

DO $preflight$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.locations
         WHERE id NOT IN ('main','warehouse','storage')
    ) THEN
        RAISE EXCEPTION 'Stage 3 warehouse migration: unexpected legacy location code; manual mapping required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.locations
         WHERE id IN ('main','warehouse','storage')
         GROUP BY id HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'Stage 3 warehouse migration: duplicate legacy location codes';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.stock s
        LEFT JOIN public.products p ON p.id=s.product_id
        WHERE p.id IS NULL
    ) THEN
        RAISE EXCEPTION 'Stage 3 warehouse migration: stock row has no owning product';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.stock_movements sm
        LEFT JOIN public.products p ON p.id=sm.product_id
        WHERE p.id IS NULL
    ) THEN
        RAISE EXCEPTION 'Stage 3 warehouse migration: stock movement has no owning product';
    END IF;
    IF to_regclass('public.stock_adjustments') IS NULL THEN
        RAISE EXCEPTION 'Stage 3 warehouse migration: stock_adjustments table is missing';
    END IF;
END
$preflight$;

CREATE TEMP TABLE stage3_legacy_locations (
    old_id TEXT PRIMARY KEY,
    location_name TEXT NOT NULL,
    was_default BOOLEAN NOT NULL
) ON COMMIT DROP;

INSERT INTO stage3_legacy_locations(old_id,location_name,was_default)
SELECT id,name,COALESCE(is_default,FALSE)
  FROM public.locations;

-- A clean installation can have no stores yet. The store INSERT trigger below
-- will create the three defaults for every store created after this migration.
CREATE TEMP TABLE stage3_location_map (
    store_id UUID NOT NULL,
    old_id TEXT NOT NULL,
    new_id TEXT NOT NULL,
    location_name TEXT NOT NULL,
    was_default BOOLEAN NOT NULL,
    PRIMARY KEY(store_id,old_id),
    UNIQUE(new_id)
) ON COMMIT DROP;

INSERT INTO stage3_location_map(store_id,old_id,new_id,location_name,was_default)
SELECT s.id, l.old_id, gen_random_uuid()::TEXT, l.location_name, l.was_default
  FROM public.stores s
 CROSS JOIN stage3_legacy_locations l;

-- Remove the legacy single-column references before replacing the global keys.
ALTER TABLE public.stock DROP CONSTRAINT IF EXISTS stock_location_id_fkey;
ALTER TABLE public.stock_adjustments DROP CONSTRAINT IF EXISTS stock_adjustments_location_id_fkey;
ALTER TABLE public.stock_movements DROP CONSTRAINT IF EXISTS stock_movements_location_id_fkey;

ALTER TABLE public.locations DROP CONSTRAINT IF EXISTS locations_pkey;
ALTER TABLE public.locations DROP CONSTRAINT IF EXISTS locations_id_check;
ALTER TABLE public.locations ADD COLUMN IF NOT EXISTS store_id UUID;
ALTER TABLE public.locations ADD COLUMN IF NOT EXISTS code TEXT;
ALTER TABLE public.locations ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE public.locations ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE public.locations ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

ALTER TABLE public.stock ADD COLUMN IF NOT EXISTS store_id UUID;
ALTER TABLE public.stock_movements ADD COLUMN IF NOT EXISTS store_id UUID;

-- Every existing balance and movement is assigned using the product's actual
-- store, never using a client-supplied store or a global location code.
UPDATE public.stock s
   SET store_id=p.store_id,
       location_id=m.new_id
  FROM public.products p
  JOIN stage3_location_map m ON m.store_id=p.store_id
 WHERE p.id=s.product_id
   AND m.old_id=s.location_id;

UPDATE public.stock_movements sm
   SET store_id=p.store_id,
       location_id=m.new_id
  FROM public.products p
  JOIN stage3_location_map m ON m.store_id=p.store_id
 WHERE p.id=sm.product_id
   AND m.old_id=sm.location_id;

UPDATE public.stock_adjustments sa
   SET location_id=m.new_id
  FROM stage3_location_map m
 WHERE m.store_id=sa.store_id
   AND m.old_id=sa.location_id;

DO $post_map$
BEGIN
    IF EXISTS (SELECT 1 FROM public.stock WHERE store_id IS NULL OR location_id IN ('main','warehouse','storage')) THEN
        RAISE EXCEPTION 'Stage 3 warehouse migration: one or more stock rows could not be mapped';
    END IF;
    IF EXISTS (SELECT 1 FROM public.stock_movements WHERE store_id IS NULL OR location_id IN ('main','warehouse','storage')) THEN
        RAISE EXCEPTION 'Stage 3 warehouse migration: one or more stock movements could not be mapped';
    END IF;
    IF EXISTS (SELECT 1 FROM public.stock_adjustments WHERE location_id IS NULL OR location_id IN ('main','warehouse','storage')) THEN
        RAISE EXCEPTION 'Stage 3 warehouse migration: one or more stock adjustments could not be mapped';
    END IF;
END
$post_map$;

DELETE FROM public.locations;

ALTER TABLE public.locations
    ALTER COLUMN id TYPE TEXT,
    ALTER COLUMN store_id SET NOT NULL,
    ALTER COLUMN code SET NOT NULL;

ALTER TABLE public.locations
    ADD CONSTRAINT locations_pkey PRIMARY KEY (id),
    ADD CONSTRAINT uq_locations_id_store UNIQUE (id,store_id),
    ADD CONSTRAINT uq_locations_store_code UNIQUE (store_id,code),
    ADD CONSTRAINT fk_locations_store FOREIGN KEY (store_id) REFERENCES public.stores(id) ON DELETE CASCADE;

INSERT INTO public.locations(id,store_id,code,name,is_default,is_active)
SELECT new_id,store_id,old_id,location_name,was_default,TRUE
  FROM stage3_location_map;

-- Ensure exactly one active default location per store.
CREATE UNIQUE INDEX IF NOT EXISTS uq_locations_one_active_default
    ON public.locations(store_id) WHERE is_default AND is_active;

-- Composite FKs need a matching candidate key on products.
ALTER TABLE public.products
    ADD CONSTRAINT uq_products_id_store UNIQUE (id,store_id);

ALTER TABLE public.stock
    ALTER COLUMN store_id SET NOT NULL,
    ALTER COLUMN location_id DROP DEFAULT,
    ADD CONSTRAINT fk_stock_product_store FOREIGN KEY (product_id,store_id)
        REFERENCES public.products(id,store_id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_stock_location_store FOREIGN KEY (location_id,store_id)
        REFERENCES public.locations(id,store_id) ON DELETE RESTRICT;

ALTER TABLE public.stock_movements
    ALTER COLUMN store_id SET NOT NULL,
    ALTER COLUMN location_id DROP DEFAULT,
    ADD CONSTRAINT fk_stock_movements_product_store FOREIGN KEY (product_id,store_id)
        REFERENCES public.products(id,store_id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_stock_movements_location_store FOREIGN KEY (location_id,store_id)
        REFERENCES public.locations(id,store_id) ON DELETE RESTRICT;

ALTER TABLE public.stock_adjustments
    ALTER COLUMN location_id DROP DEFAULT,
    ADD CONSTRAINT fk_stock_adjustments_product_store FOREIGN KEY (product_id,store_id)
        REFERENCES public.products(id,store_id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_stock_adjustments_location_store FOREIGN KEY (location_id,store_id)
        REFERENCES public.locations(id,store_id) ON DELETE RESTRICT;

-- Location rows are created automatically for every newly provisioned store.
CREATE OR REPLACE FUNCTION public.create_default_store_locations()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp
AS $locations$
BEGIN
    INSERT INTO public.locations(id,store_id,code,name,is_default,is_active)
    VALUES
      (gen_random_uuid()::TEXT,NEW.id,'main','المتجر الرئيسي',TRUE,TRUE),
      (gen_random_uuid()::TEXT,NEW.id,'warehouse','المستودع',FALSE,TRUE),
      (gen_random_uuid()::TEXT,NEW.id,'storage','مخزن إضافي',FALSE,TRUE)
    ON CONFLICT (store_id,code) DO NOTHING;
    RETURN NEW;
END;
$locations$;

DROP TRIGGER IF EXISTS trg_stores_create_default_locations ON public.stores;
CREATE TRIGGER trg_stores_create_default_locations
AFTER INSERT ON public.stores
FOR EACH ROW EXECUTE FUNCTION public.create_default_store_locations();

-- Accept a legacy code or a location UUID, but always resolve inside p_store_id.
CREATE OR REPLACE FUNCTION public.resolve_store_location_id(
    p_store_id UUID,
    p_location_ref TEXT DEFAULT NULL
) RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp
AS $resolve_location$
DECLARE
    v_id TEXT;
    v_ref TEXT := COALESCE(NULLIF(BTRIM(p_location_ref),''),'main');
BEGIN
    SELECT l.id INTO v_id
      FROM public.locations l
     WHERE l.store_id=p_store_id
       AND l.is_active
       AND (l.id=v_ref OR l.code=v_ref)
     LIMIT 1;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'Location % is not active or does not belong to store %',v_ref,p_store_id
            USING ERRCODE='23514';
    END IF;
    RETURN v_id;
END;
$resolve_location$;

-- Resolve legacy location codes at the database boundary and derive store
-- ownership from the product. Callers cannot assign stock to another store.
CREATE OR REPLACE FUNCTION public.resolve_inventory_row_location()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp
AS $inventory_location$
DECLARE
    v_product_store UUID;
BEGIN
    SELECT p.store_id INTO v_product_store
      FROM public.products p WHERE p.id=NEW.product_id FOR SHARE;
    IF v_product_store IS NULL THEN
        RAISE EXCEPTION 'Inventory product does not exist';
    END IF;
    IF TG_TABLE_NAME='stock_adjustments' THEN
        IF NEW.store_id IS DISTINCT FROM v_product_store THEN
            RAISE EXCEPTION 'Stock adjustment product belongs to another store' USING ERRCODE='23514';
        END IF;
    ELSE
        IF NEW.store_id IS NOT NULL AND NEW.store_id IS DISTINCT FROM v_product_store THEN
            RAISE EXCEPTION 'Inventory row product belongs to another store' USING ERRCODE='23514';
        END IF;
        NEW.store_id := v_product_store;
    END IF;
    NEW.location_id := public.resolve_store_location_id(v_product_store,NEW.location_id);
    RETURN NEW;
END;
$inventory_location$;

DROP TRIGGER IF EXISTS trg_stock_resolve_location ON public.stock;
CREATE TRIGGER trg_stock_resolve_location
BEFORE INSERT OR UPDATE OF product_id,store_id,location_id ON public.stock
FOR EACH ROW EXECUTE FUNCTION public.resolve_inventory_row_location();

DROP TRIGGER IF EXISTS trg_stock_movements_resolve_location ON public.stock_movements;
CREATE TRIGGER trg_stock_movements_resolve_location
BEFORE INSERT OR UPDATE OF product_id,store_id,location_id ON public.stock_movements
FOR EACH ROW EXECUTE FUNCTION public.resolve_inventory_row_location();

DROP TRIGGER IF EXISTS trg_stock_adjustments_resolve_location ON public.stock_adjustments;
CREATE TRIGGER trg_stock_adjustments_resolve_location
BEFORE INSERT OR UPDATE OF product_id,store_id,location_id ON public.stock_adjustments
FOR EACH ROW EXECUTE FUNCTION public.resolve_inventory_row_location();

-- Warehouse records are first-class store-scoped sync entities.
DROP TRIGGER IF EXISTS trg_locations_log_change ON public.locations;
CREATE TRIGGER trg_locations_log_change
AFTER INSERT OR UPDATE ON public.locations
FOR EACH ROW EXECUTE FUNCTION public.trg_log_change();

-- Store-scoped warehouse visibility.
ALTER TABLE public.locations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS locations_store_isolation ON public.locations;
CREATE POLICY locations_store_isolation ON public.locations
    FOR SELECT USING (store_id=public.current_user_store_id());
DROP POLICY IF EXISTS locations_owner_manage ON public.locations;
CREATE POLICY locations_owner_manage ON public.locations
    FOR ALL USING (store_id=public.current_user_store_id()
                   AND public.has_store_permission(store_id,'users.manage'))
             WITH CHECK (store_id=public.current_user_store_id()
                         AND public.has_store_permission(store_id,'users.manage'));

REVOKE INSERT,UPDATE,DELETE ON public.locations FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.locations TO authenticated;

-- Location configuration is append/deactivate only; never physically delete history.
CREATE OR REPLACE FUNCTION public.create_store_location(
    p_store_id UUID,p_code TEXT,p_name TEXT,p_is_default BOOLEAN DEFAULT FALSE
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp
AS $create_location$
DECLARE
    v_id TEXT;
BEGIN
    IF p_store_id IS DISTINCT FROM public.current_user_store_id()
       OR NOT public.has_store_permission(p_store_id,'users.manage') THEN
        RAISE EXCEPTION 'Only the store owner may create warehouses' USING ERRCODE='42501';
    END IF;
    IF p_code IS NULL OR p_code !~ '^[a-z][a-z0-9_-]{1,39}$'
       OR p_name IS NULL OR BTRIM(p_name)='' THEN
        RAISE EXCEPTION 'A valid warehouse code and name are required';
    END IF;
    IF p_is_default THEN
        UPDATE public.locations SET is_default=FALSE,updated_at=NOW()
         WHERE store_id=p_store_id AND is_default;
    END IF;
    INSERT INTO public.locations(id,store_id,code,name,is_default,is_active)
    VALUES(gen_random_uuid()::TEXT,p_store_id,p_code,BTRIM(p_name),COALESCE(p_is_default,FALSE),TRUE)
    RETURNING id INTO v_id;
    INSERT INTO public.audit_logs(store_id,user_id,entity_type,entity_id,action,new_values_json)
    SELECT p_store_id,u.id,'LOCATION',v_id::UUID,'CREATE',
           jsonb_build_object('code',p_code,'name',BTRIM(p_name),'is_default',COALESCE(p_is_default,FALSE))
      FROM public.users u WHERE u.auth_user_id=auth.uid() AND u.store_id=p_store_id;
    RETURN v_id;
END;
$create_location$;

CREATE OR REPLACE FUNCTION public.deactivate_store_location(
    p_store_id UUID,p_location_id TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp
AS $deactivate_location$
DECLARE
    v_user UUID;
BEGIN
    SELECT u.id INTO v_user FROM public.users u
     WHERE u.auth_user_id=auth.uid() AND u.store_id=p_store_id AND u.is_active;
    IF v_user IS NULL OR p_store_id IS DISTINCT FROM public.current_user_store_id()
       OR NOT public.has_store_permission(p_store_id,'users.manage') THEN
        RAISE EXCEPTION 'Only the store owner may deactivate warehouses' USING ERRCODE='42501';
    END IF;
    IF EXISTS (SELECT 1 FROM public.locations WHERE id=p_location_id AND store_id=p_store_id AND is_default) THEN
        RAISE EXCEPTION 'Choose another default warehouse before deactivating this one';
    END IF;
    IF EXISTS (SELECT 1 FROM public.stock WHERE location_id=p_location_id AND store_id=p_store_id
                AND (quantity<>0 OR reserved_quantity<>0)) THEN
        RAISE EXCEPTION 'Warehouse has a non-zero stock balance';
    END IF;
    UPDATE public.locations SET is_active=FALSE,updated_at=NOW()
     WHERE id=p_location_id AND store_id=p_store_id AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'Warehouse not found or already inactive'; END IF;
    INSERT INTO public.audit_logs(store_id,user_id,entity_type,entity_id,action,old_values_json)
    VALUES(p_store_id,v_user,'LOCATION',p_location_id::UUID,'DEACTIVATE',
           jsonb_build_object('location_id',p_location_id));
END;
$deactivate_location$;

REVOKE ALL ON FUNCTION public.resolve_store_location_id(UUID,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.create_default_store_locations() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.resolve_inventory_row_location() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.create_store_location(UUID,TEXT,TEXT,BOOLEAN) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.deactivate_store_location(UUID,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_store_location(UUID,TEXT,TEXT,BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_store_location(UUID,TEXT) TO authenticated;

COMMIT;
