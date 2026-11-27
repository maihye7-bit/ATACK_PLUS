-- Phase 1 Repair 003 regression: sync devices and audit references.
BEGIN;
DO $sync_integrity$
DECLARE
  s1 UUID:=gen_random_uuid(); s2 UUID:=gen_random_uuid();
  u1 UUID:=gen_random_uuid(); u2 UUID:=gen_random_uuid();
  d1 UUID:=gen_random_uuid(); d2 UUID:=gen_random_uuid();
  p1 UUID:=gen_random_uuid(); p2 UUID:=gen_random_uuid(); sm2 UUID:=gen_random_uuid();
  v_failed BOOLEAN;
BEGIN
  INSERT INTO public.stores(id,name) VALUES(s1,'Sync integrity A'),(s2,'Sync integrity B');
  INSERT INTO public.users(id,store_id,username,full_name) VALUES
    (u1,s1,'sync_integrity_user_a','Sync User A'),
    (u2,s2,'sync_integrity_user_b','Sync User B');
  INSERT INTO public.devices(id,store_id,device_name,device_type) VALUES
    (d1,s1,'sync-device-a','DESKTOP'),
    (d2,s2,'sync-device-b','PHONE');
  INSERT INTO public.products(id,store_id,name,primary_unit_id) VALUES
    (p1,s1,'Sync product A','pcs'),(p2,s2,'Sync product B','pcs');
  INSERT INTO public.stock_movements(id,product_id,type,quantity,unit_id,cost_per_unit,total_value,user_id)
    VALUES(sm2,p2,'IN',1,'pcs',1,1,u2);

  INSERT INTO public.sync_cursors(store_id,device_id,table_name,last_pull_seq)
    VALUES(s1,d1::TEXT,'products',0);
  INSERT INTO public.sync_log(store_id,device_id,operation,status)
    VALUES(s1,d1::TEXT,'PULL','SUCCESS');
  INSERT INTO public.sync_outbox(store_id,device_id,table_name,operation,record_uuid,
    idempotency_key,record_json,payload_hash)
    VALUES(s1,d1::TEXT,'products','INSERT',p1,gen_random_uuid(),
      jsonb_build_object('id',p1,'store_id',s1),'sync-test-hash');
  INSERT INTO public.audit_logs(store_id,user_id,entity_type,entity_id,action,device_id)
    VALUES(s1,u1,'products',p1,'SYNC',d1::TEXT);
  INSERT INTO public.tombstones(store_id,table_name,record_uuid,deleted_by)
    VALUES(s1,'products',p1,u1);
  INSERT INTO public.sync_conflicts(store_id,table_name,record_uuid,conflict_type,
    local_record_json,remote_record_json,resolved_by)
    VALUES(s1,'products',p1,'PRICE',
      jsonb_build_object('id',p1,'store_id',s1),
      jsonb_build_object('id',p1,'store_id',s1),u1);

  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.sync_cursors(store_id,device_id,table_name,last_pull_seq)
      VALUES(s1,d2::TEXT,'products',0);
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store sync cursor device was accepted'; END IF;

  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.sync_outbox(store_id,device_id,table_name,operation,record_uuid,
      idempotency_key,record_json,payload_hash)
      VALUES(s1,d1::TEXT,'products','INSERT',p1,gen_random_uuid(),
        jsonb_build_object('id',p1,'store_id',s2),'bad-sync-hash');
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Outbox payload with a different store was accepted'; END IF;

  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.sync_log(store_id,device_id,operation,status)
      VALUES(s1,d2::TEXT,'PUSH','SUCCESS');
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store sync log device was accepted'; END IF;

  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.audit_logs(store_id,user_id,action,device_id)
      VALUES(s1,u1,'SYNC',d2::TEXT);
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store audit device was accepted'; END IF;

  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.tombstones(store_id,table_name,record_uuid,deleted_by)
      VALUES(s1,'products',p2,u1);
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store tombstone target was accepted'; END IF;

  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.sync_conflicts(store_id,table_name,record_uuid,conflict_type,
      local_record_json,remote_record_json,resolved_by)
      VALUES(s1,'products',p1,'PRICE',
        jsonb_build_object('id',p1,'store_id',s2),
        jsonb_build_object('id',p1,'store_id',s1),u1);
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store sync conflict snapshot was accepted'; END IF;

  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.sync_conflicts(store_id,table_name,record_uuid,conflict_type,
      local_record_json,remote_record_json,resolved_by)
      VALUES(s1,'stock_movements',sm2,'INVENTORY',
        jsonb_build_object('id',sm2,'store_id',s1),
        jsonb_build_object('id',sm2,'store_id',s1),u1);
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store sync conflict target was accepted'; END IF;

  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.sync_conflicts(store_id,table_name,record_uuid,conflict_type,
      local_record_json,remote_record_json,resolved_by)
      VALUES(s1,'products',p1,'PRICE',
        jsonb_build_object('id',p1,'store_id',s1),
        jsonb_build_object('id',p1,'store_id',s1),u2);
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store conflict resolver was accepted'; END IF;

  v_failed:=FALSE;
  BEGIN
    UPDATE public.devices SET store_id=s2 WHERE id=d1;
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Device store reassignment with sync history was accepted'; END IF;

  RAISE NOTICE 'PASS: sync device, tombstone, conflict and audit same-store regressions';
END
$sync_integrity$;
ROLLBACK;
