-- Phase 1 same-store referential integrity regression.
-- Runs only against the disposable CI database; all fixture rows are rolled back.
BEGIN;
DO $same_store_test$
DECLARE
  s1 UUID := gen_random_uuid();
  s2 UUID := gen_random_uuid();
  u1 UUID := gen_random_uuid();
  u2 UUID := gen_random_uuid();
  p1 UUID := gen_random_uuid();
  p2 UUID := gen_random_uuid();
  sup1 UUID := gen_random_uuid();
  inv1 UUID := gen_random_uuid();
  inv2 UUID := gen_random_uuid();
  pur1 UUID := gen_random_uuid();
  ret1 UUID := gen_random_uuid();
  pret1 UUID := gen_random_uuid();
  adj1 UUID := gen_random_uuid();
  v_failed BOOLEAN;
BEGIN
  INSERT INTO stores(id,name) VALUES (s1,'Same-store test A'),(s2,'Same-store test B');
  INSERT INTO users(id,store_id,username,full_name) VALUES
    (u1,s1,'same_store_owner_a','Same Store Owner A'),
    (u2,s2,'same_store_owner_b','Same Store Owner B');
  INSERT INTO suppliers(id,store_id,code,name) VALUES
    (sup1,s1,'SS-SUP-A','Same-store supplier A');
  INSERT INTO products(id,store_id,name,primary_unit_id) VALUES
    (p1,s1,'Same-store product A','pcs'),
    (p2,s2,'Same-store product B','pcs');
  INSERT INTO invoices(id,store_id,invoice_number,type,invoice_date,created_by) VALUES
    (inv1,s1,'SS-INV-A','SALE',NOW(),u1),
    (inv2,s2,'SS-INV-B','SALE',NOW(),u2);
  INSERT INTO purchases(id,store_id,purchase_number,supplier_id,purchase_date,created_by) VALUES
    (pur1,s1,'SS-PUR-A',sup1,NOW(),u1);
  INSERT INTO sales_returns(id,store_id,return_number,original_invoice_id,created_by) VALUES
    (ret1,s1,'SS-RET-A',inv1,u1);
  INSERT INTO purchase_returns(id,store_id,return_number,original_purchase_id,created_by) VALUES
    (pret1,s1,'SS-PRET-A',pur1,u1);
  INSERT INTO stock_adjustments(id,store_id,adjustment_number,product_id,adjustment_type,
    reason,quantity,unit_id,cost_per_unit,total_value,created_by)
  VALUES(adj1,s1,'SS-ADJ-A',p1,'INCREASE','same-store integrity test',1,'pcs',1,1,u1);

  -- Same-store references of each supported reference type must succeed.
  INSERT INTO stock_movements(product_id,type,quantity,unit_id,cost_per_unit,total_value,
    reference_id,reference_type,user_id)
  VALUES
    (p1,'IN',1,'pcs',1,1,inv1,'invoice',u1),
    (p1,'IN',1,'pcs',1,1,pur1,'purchase',u1),
    (p1,'ADJUSTMENT',1,'pcs',1,1,adj1,'adjustment',u1),
    (p1,'RETURN_IN',1,'pcs',1,1,ret1,'return',u1),
    (p1,'RETURN_OUT',1,'pcs',1,1,pret1,'return',u1),
    (p1,'IN',1,'pcs',1,1,NULL,NULL,u1);

  -- A movement cannot attribute a product from store A to a user from store B.
  v_failed := FALSE;
  BEGIN
    INSERT INTO stock_movements(product_id,type,quantity,unit_id,cost_per_unit,total_value,user_id)
    VALUES(p1,'IN',1,'pcs',1,1,u2);
  EXCEPTION WHEN OTHERS THEN v_failed := TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store product/user movement was accepted'; END IF;

  -- A movement cannot reference an invoice from another store.
  v_failed := FALSE;
  BEGIN
    INSERT INTO stock_movements(product_id,type,quantity,unit_id,cost_per_unit,total_value,
      reference_id,reference_type,user_id)
    VALUES(p1,'IN',1,'pcs',1,1,inv2,'invoice',u1);
  EXCEPTION WHEN OTHERS THEN v_failed := TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store invoice reference was accepted'; END IF;

  -- Reference type and ID must be supplied together.
  v_failed := FALSE;
  BEGIN
    INSERT INTO stock_movements(product_id,type,quantity,unit_id,cost_per_unit,total_value,
      reference_id,reference_type,user_id)
    VALUES(p1,'IN',1,'pcs',1,1,inv1,NULL,u1);
  EXCEPTION WHEN OTHERS THEN v_failed := TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Incomplete stock movement reference was accepted'; END IF;

  -- A UUID that exists, but only in a different reference table, must not pass.
  v_failed := FALSE;
  BEGIN
    INSERT INTO stock_movements(product_id,type,quantity,unit_id,cost_per_unit,total_value,
      reference_id,reference_type,user_id)
    VALUES(p1,'IN',1,'pcs',1,1,pur1,'invoice',u1);
  EXCEPTION WHEN OTHERS THEN v_failed := TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Mismatched stock movement reference type was accepted'; END IF;

  -- Existing movement history makes parent store reassignment unsafe.
  v_failed := FALSE;
  BEGIN
    UPDATE products SET store_id=s2 WHERE id=p1;
  EXCEPTION WHEN OTHERS THEN v_failed := TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Product store reassignment with movement history was accepted'; END IF;

  v_failed := FALSE;
  BEGIN
    UPDATE users SET store_id=s2 WHERE id=u1;
  EXCEPTION WHEN OTHERS THEN v_failed := TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'User store reassignment with movement history was accepted'; END IF;

  RAISE NOTICE 'PASS: same-store stock movement references, cross-store rejection and NULL contract';
END
$same_store_test$;
ROLLBACK;
