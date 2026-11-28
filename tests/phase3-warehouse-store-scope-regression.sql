-- Stage 3 Part A: per-store warehouse migration and referential-integrity regression.
DO $test$
DECLARE
    v_store_a UUID := 'a3000000-0000-4000-8000-000000000001';
    v_store_b UUID := 'a3000000-0000-4000-8000-000000000002';
    v_product_a UUID := 'a3000000-0000-4000-8000-000000000021';
    v_location_a TEXT;
    v_location_b TEXT;
    v_new_store UUID := 'a3000000-0000-4000-8000-000000000003';
BEGIN
    IF (SELECT COUNT(*) FROM public.locations WHERE store_id IN (v_store_a,v_store_b)) <> 6 THEN
        RAISE EXCEPTION 'Each legacy store must receive exactly three locations';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.locations WHERE store_id IN (v_store_a,v_store_b)
        GROUP BY store_id HAVING COUNT(*) FILTER (WHERE is_default AND is_active) <> 1
    ) THEN
        RAISE EXCEPTION 'Each store must have exactly one active default warehouse';
    END IF;
    IF EXISTS (
        SELECT code FROM public.locations WHERE store_id IN (v_store_a,v_store_b)
        GROUP BY code HAVING COUNT(DISTINCT id) <> 2 OR COUNT(*) <> 2
    ) THEN
        RAISE EXCEPTION 'Legacy warehouse codes must be independently represented per store';
    END IF;

    SELECT id INTO v_location_a FROM public.locations WHERE store_id=v_store_a AND code='main';
    SELECT id INTO v_location_b FROM public.locations WHERE store_id=v_store_b AND code='warehouse';
    IF v_location_a IS NULL OR v_location_b IS NULL OR v_location_a=v_location_b THEN
        RAISE EXCEPTION 'Store-scoped warehouse UUIDs were not generated';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.stock s JOIN public.locations l
          ON l.id=s.location_id AND l.store_id=s.store_id
         WHERE s.product_id=v_product_a AND s.store_id=v_store_a
           AND l.code='main' AND s.quantity=12 AND s.reserved_quantity=2
    ) THEN
        RAISE EXCEPTION 'Legacy stock balance or location mapping was not preserved';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.stock_movements sm JOIN public.locations l
          ON l.id=sm.location_id AND l.store_id=sm.store_id
         WHERE sm.product_id=v_product_a AND sm.store_id=v_store_a AND l.code='main'
    ) THEN
        RAISE EXCEPTION 'Legacy stock movement location mapping was not preserved';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.stock_adjustments sa JOIN public.locations l
          ON l.id=sa.location_id AND l.store_id=sa.store_id
         WHERE sa.store_id=v_store_a AND sa.adjustment_number='ST3-A-1' AND l.code='storage'
    ) THEN
        RAISE EXCEPTION 'Legacy stock adjustment location mapping was not preserved';
    END IF;

    -- The resolver accepts a code only within the supplied store and a UUID
    -- only when that exact UUID belongs to the supplied store.
    IF public.resolve_store_location_id(v_store_a,'main') IS DISTINCT FROM v_location_a THEN
        RAISE EXCEPTION 'Store-local location code resolution failed';
    END IF;
    BEGIN
        PERFORM public.resolve_store_location_id(v_store_a,v_location_b);
        RAISE EXCEPTION 'Cross-store location UUID unexpectedly resolved';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    -- New stores automatically receive their own default warehouse set.
    INSERT INTO public.stores(id,name) VALUES(v_new_store,'Stage3 New Store');
    IF (SELECT COUNT(*) FROM public.locations WHERE store_id=v_new_store) <> 3 THEN
        RAISE EXCEPTION 'New store did not receive three default locations';
    END IF;

    -- Product/store and location/store pairs are both enforced by composite FKs.
    BEGIN
        INSERT INTO public.stock(product_id,store_id,location_id,quantity,reserved_quantity)
        VALUES(v_product_a,v_store_a,v_location_b,1,0);
        RAISE EXCEPTION 'Cross-store stock location unexpectedly accepted';
    EXCEPTION WHEN check_violation OR foreign_key_violation THEN
        NULL;
    END;

    BEGIN
        INSERT INTO public.stock_movements(product_id,store_id,location_id,type,quantity,unit_id,
            cost_per_unit,total_value,user_id)
        VALUES(v_product_a,v_store_a,v_location_b,'IN',1,'pcs',10,10,
            'a3000000-0000-4000-8000-000000000011');
        RAISE EXCEPTION 'Cross-store stock movement location unexpectedly accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        NULL;
    END;
END
$test$;

ROLLBACK;
