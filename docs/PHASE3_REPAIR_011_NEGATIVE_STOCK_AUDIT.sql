-- Stage 3 / Part B: complete D-016 negative-stock authorization and evidence.
-- Negative stock remains possible only through trusted business RPCs that validate
-- permission, reason, and a credential-bound registered device.

BEGIN;

SELECT pg_advisory_xact_lock(hashtext('atack_plus:stage3:negative_stock_audit'));

LOCK TABLE public.devices, public.stock_movements, public.stock_adjustments,
           public.processed_operations
    IN ACCESS EXCLUSIVE MODE;

ALTER TABLE public.devices
    ADD CONSTRAINT uq_devices_id_store UNIQUE (id,store_id);

ALTER TABLE public.stock_movements
    ADD COLUMN operation_id UUID,
    ADD COLUMN device_id UUID,
    ADD COLUMN shortage_quantity NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN negative_stock_authorized BOOLEAN NOT NULL DEFAULT FALSE,
    ADD CONSTRAINT ck_stock_movements_negative_evidence CHECK (
        (negative_stock_authorized=FALSE AND shortage_quantity=0)
        OR
        (negative_stock_authorized=TRUE AND shortage_quantity>0
         AND operation_id IS NOT NULL AND device_id IS NOT NULL
         AND NULLIF(BTRIM(reason),'') IS NOT NULL)
    ),
    ADD CONSTRAINT fk_stock_movements_operation FOREIGN KEY (store_id,operation_id)
        REFERENCES public.processed_operations(store_id,operation_id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_stock_movements_device FOREIGN KEY (device_id,store_id)
        REFERENCES public.devices(id,store_id) ON DELETE RESTRICT;

ALTER TABLE public.stock_adjustments
    ADD COLUMN operation_id UUID,
    ADD COLUMN device_id UUID,
    ADD COLUMN shortage_quantity NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN negative_stock_authorized BOOLEAN NOT NULL DEFAULT FALSE,
    ADD CONSTRAINT ck_stock_adjustments_negative_evidence CHECK (
        (negative_stock_authorized=FALSE AND shortage_quantity=0)
        OR
        (negative_stock_authorized=TRUE AND shortage_quantity>0
         AND operation_id IS NOT NULL AND device_id IS NOT NULL
         AND NULLIF(BTRIM(reason),'') IS NOT NULL)
    ),
    ADD CONSTRAINT fk_stock_adjustments_operation FOREIGN KEY (store_id,operation_id)
        REFERENCES public.processed_operations(store_id,operation_id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_stock_adjustments_device FOREIGN KEY (device_id,store_id)
        REFERENCES public.devices(id,store_id) ON DELETE RESTRICT;

CREATE INDEX idx_stock_movements_operation ON public.stock_movements(store_id,operation_id)
    WHERE operation_id IS NOT NULL;
CREATE INDEX idx_stock_movements_device ON public.stock_movements(store_id,device_id)
    WHERE device_id IS NOT NULL;
CREATE INDEX idx_stock_adjustments_operation ON public.stock_adjustments(store_id,operation_id)
    WHERE operation_id IS NOT NULL;
CREATE INDEX idx_stock_adjustments_device ON public.stock_adjustments(store_id,device_id)
    WHERE device_id IS NOT NULL;

-- Direct PostgREST writes must not bypass the D-016 permission/device contract.
ALTER TABLE public.stock ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS stock_store_select ON public.stock;
CREATE POLICY stock_store_select ON public.stock
    FOR SELECT TO authenticated
    USING (store_id=public.current_user_store_id());
DROP POLICY IF EXISTS stock_movements_store_select ON public.stock_movements;
CREATE POLICY stock_movements_store_select ON public.stock_movements
    FOR SELECT TO authenticated
    USING (store_id=public.current_user_store_id());

DROP POLICY IF EXISTS sec_deny_direct_insert_stock ON public.stock;
DROP POLICY IF EXISTS sec_deny_direct_update_stock ON public.stock;
DROP POLICY IF EXISTS sec_deny_direct_delete_stock ON public.stock;
DROP POLICY IF EXISTS sec_deny_direct_insert_stock_movements ON public.stock_movements;
DROP POLICY IF EXISTS sec_deny_direct_update_stock_movements ON public.stock_movements;
DROP POLICY IF EXISTS sec_deny_direct_delete_stock_movements ON public.stock_movements;

CREATE POLICY sec_deny_direct_insert_stock ON public.stock
    AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK(FALSE);
CREATE POLICY sec_deny_direct_update_stock ON public.stock
    AS RESTRICTIVE FOR UPDATE TO authenticated USING(FALSE) WITH CHECK(FALSE);
CREATE POLICY sec_deny_direct_delete_stock ON public.stock
    AS RESTRICTIVE FOR DELETE TO authenticated USING(FALSE);
CREATE POLICY sec_deny_direct_insert_stock_movements ON public.stock_movements
    AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK(FALSE);
CREATE POLICY sec_deny_direct_update_stock_movements ON public.stock_movements
    AS RESTRICTIVE FOR UPDATE TO authenticated USING(FALSE) WITH CHECK(FALSE);
CREATE POLICY sec_deny_direct_delete_stock_movements ON public.stock_movements
    AS RESTRICTIVE FOR DELETE TO authenticated USING(FALSE);

REVOKE ALL ON public.stock,public.stock_movements FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.stock,public.stock_movements TO authenticated;
REVOKE TRUNCATE ON public.stock,public.stock_movements FROM PUBLIC,anon,authenticated;

COMMIT;
