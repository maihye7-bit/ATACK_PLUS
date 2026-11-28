-- D-016: negative stock requires permission, reason, a credential-bound device,
-- and durable operation/shortage evidence. Entire test is rolled back.
BEGIN;

DO $negative_stock$
DECLARE
    v_store UUID := 'a3000000-0000-4000-8000-000000000001';
    v_owner UUID := 'a3000000-0000-4000-8000-000000000011';
    v_owner_auth UUID := 'a3000000-0000-4000-8000-000000000101';
    v_seller UUID := 'a3000000-0000-4000-8000-000000000013';
    v_seller_auth UUID := 'a3000000-0000-4000-8000-000000000103';
    v_product UUID := 'a3000000-0000-4000-8000-000000000071';
    v_device UUID := 'a3000000-0000-4000-8000-000000000081';
    v_operation UUID := 'a3000000-0000-4000-8000-000000000091';
    v_invoice UUID := 'a3000000-0000-4000-8000-000000000092';
    v_adjustment_operation UUID := 'a3000000-0000-4000-8000-000000000093';
    v_adjustment UUID := 'a3000000-0000-4000-8000-000000000094';
    v_token TEXT := repeat('a',64);
    v_payload JSONB;
    v_result JSONB;
    v_location TEXT;
    v_count INTEGER;
    v_rejected BOOLEAN;
BEGIN
    INSERT INTO public.products(id,store_id,name,primary_unit_id,cost_price,default_sale_price,is_active)
    VALUES(v_product,v_store,'D-016 Negative Stock Product','pcs',10,15,TRUE);

    INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity)
    VALUES(v_product,'main',2,0);

    INSERT INTO public.devices(id,store_id,device_name,device_type,is_online)
    VALUES(v_device,v_store,'D-016 test device','DESKTOP',FALSE);

    INSERT INTO public.device_credentials(device_id,store_id,user_id,registered_by,token_hash,credential_version,issued_at)
    VALUES(v_device,v_store,v_owner,v_owner,
        encode(public.atack_digest(convert_to(v_token,'UTF8'),'sha256'),'hex'),1,NOW());

    INSERT INTO public.users(id,auth_user_id,store_id,username,full_name,is_active)
    VALUES(v_seller,v_seller_auth,v_store,'stage3_d016_seller','D-016 Seller',TRUE);
    INSERT INTO public.user_roles(user_id,role_id) VALUES(v_seller,'cashier');

    SELECT id INTO v_location FROM public.locations WHERE store_id=v_store AND code='main';

    -- Owner with permission, reason and active device credential may sell below zero.
    PERFORM set_config('request.jwt.claim.sub',v_owner_auth::TEXT,TRUE);
    IF NOT public.has_store_permission(v_store,'inventory.allow_negative') THEN
        RAISE EXCEPTION 'Owner fixture lacks inventory.allow_negative';
    END IF;
    v_payload:=jsonb_build_object(
        'id',v_invoice,'invoice_number','D016-NEG-001','paid_amount',75,
        'reason','Approved emergency sale before replenishment',
        'device_id',v_device,'device_token',v_token,
        'location_id',v_location,
        'items',jsonb_build_array(jsonb_build_object(
            'product_id',v_product,'quantity',5,'unit_id','pcs','unit_price',15
        ))
    );
    v_result:=public.process_sale_invoice(v_store,v_operation,v_payload);
    IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
        RAISE EXCEPTION 'Authorized negative sale did not succeed: %',v_result;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.stock WHERE product_id=v_product AND store_id=v_store
                    AND location_id=v_location AND quantity=-3 AND reserved_quantity=0) THEN
        RAISE EXCEPTION 'Authorized negative sale did not produce the expected -3 balance';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.stock_movements
         WHERE store_id=v_store AND product_id=v_product AND operation_id=v_operation
           AND device_id=v_device AND shortage_quantity=3
           AND negative_stock_authorized=TRUE
           AND reason ILIKE '%Approved emergency sale%'
    ) THEN
        RAISE EXCEPTION 'Negative sale movement is missing permission/device/shortage evidence';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.audit_logs
         WHERE store_id=v_store AND entity_id=(SELECT id FROM public.stock WHERE product_id=v_product AND store_id=v_store)
           AND new_values_json->>'event'='NEGATIVE_STOCK_SALE'
           AND new_values_json->>'operation_id'=v_operation::TEXT
           AND new_values_json->>'device_id'=v_device::TEXT
           AND (new_values_json->>'shortage_quantity')::NUMERIC=3
    ) THEN
        RAISE EXCEPTION 'Negative sale audit event is incomplete';
    END IF;

    -- Idempotent replay does not create a second movement or audit event.
    v_result:=public.process_sale_invoice(v_store,v_operation,v_payload);
    IF COALESCE((v_result->>'replayed')::BOOLEAN,FALSE) IS NOT TRUE THEN
        RAISE EXCEPTION 'Negative sale retry was not idempotent';
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.stock_movements
     WHERE store_id=v_store AND operation_id=v_operation;
    IF v_count<>1 THEN RAISE EXCEPTION 'Negative sale replay duplicated movement evidence'; END IF;

    -- Missing reason is rejected even for the owner.
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.process_sale_invoice(v_store,
            'a3000000-0000-4000-8000-000000000095'::UUID,
            v_payload || jsonb_build_object('id','a3000000-0000-4000-8000-000000000096',
                'invoice_number','D016-NEG-NOREASON') - 'reason');
    EXCEPTION WHEN OTHERS THEN v_rejected:=TRUE;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'Negative sale without reason was accepted'; END IF;

    -- Missing device credential is rejected even for the owner.
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.process_sale_invoice(v_store,
            'a3000000-0000-4000-8000-000000000097'::UUID,
            v_payload || jsonb_build_object('id','a3000000-0000-4000-8000-000000000098',
                'invoice_number','D016-NEG-NODEVICE') - 'device_id' - 'device_token');
    EXCEPTION WHEN OTHERS THEN v_rejected:=TRUE;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'Negative sale without device credential was accepted'; END IF;

    -- Seller can create sales but does not hold inventory.allow_negative.
    PERFORM set_config('request.jwt.claim.sub',v_seller_auth::TEXT,TRUE);
    IF NOT public.has_store_permission(v_store,'sales.write')
       OR public.has_store_permission(v_store,'inventory.allow_negative') THEN
        RAISE EXCEPTION 'Seller permission fixture does not represent sales-only access';
    END IF;
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.process_sale_invoice(v_store,
            'a3000000-0000-4000-8000-000000000099'::UUID,
            v_payload || jsonb_build_object('id','a3000000-0000-4000-8000-000000000100',
                'invoice_number','D016-SELLER-NEG') );
    EXCEPTION WHEN OTHERS THEN v_rejected:=TRUE;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'Seller without inventory.allow_negative oversold stock'; END IF;

    -- Owner adjustment path is subject to the same device/evidence contract.
    PERFORM set_config('request.jwt.claim.sub',v_owner_auth::TEXT,TRUE);
    v_payload:=jsonb_build_object(
        'id',v_adjustment,'product_id',v_product,'adjustment_type','DECREASE',
        'reason','Approved adjustment after stock discrepancy',
        'quantity',1,'unit_id','pcs','location_id',v_location,
        'device_id',v_device,'device_token',v_token
    );
    v_result:=public.process_stock_adjustment(v_store,v_adjustment_operation,v_payload);
    IF COALESCE((v_result->>'success')::BOOLEAN,FALSE) IS NOT TRUE THEN
        RAISE EXCEPTION 'Authorized negative adjustment did not succeed: %',v_result;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.stock_adjustments
         WHERE id=v_adjustment AND operation_id=v_adjustment_operation AND device_id=v_device
           AND negative_stock_authorized=TRUE AND shortage_quantity=4
    ) THEN
        RAISE EXCEPTION 'Negative adjustment evidence is incomplete';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.stock_movements
         WHERE reference_id=v_adjustment AND operation_id=v_adjustment_operation
           AND device_id=v_device AND negative_stock_authorized=TRUE AND shortage_quantity=4
    ) THEN
        RAISE EXCEPTION 'Negative adjustment movement evidence is incomplete';
    END IF;

    -- Revoked credentials cannot authorize a new negative sale.
    UPDATE public.device_credentials
       SET token_hash=NULL,revoked_at=NOW(),updated_at=NOW()
     WHERE device_id=v_device AND store_id=v_store;
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.process_sale_invoice(v_store,
            'a3000000-0000-4000-8000-000000000102'::UUID,
            v_payload || jsonb_build_object('id','a3000000-0000-4000-8000-000000000103',
                'invoice_number','D016-REVOKED-DEVICE','items',
                jsonb_build_array(jsonb_build_object('product_id',v_product,'quantity',1,'unit_id','pcs','unit_price',15))));
    EXCEPTION WHEN OTHERS THEN v_rejected:=TRUE;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'Revoked device credential authorized negative stock'; END IF;
END
$negative_stock$;

ROLLBACK;
