-- Phase 1 Repair 002 regression: Phase 3 extension and accounting relationships.
-- Disposable CI only; fixtures are rolled back.
BEGIN;
DO $extension_integrity$
DECLARE
  s1 UUID:=gen_random_uuid(); s2 UUID:=gen_random_uuid();
  u1 UUID:=gen_random_uuid(); u2 UUID:=gen_random_uuid();
  sup1 UUID:=gen_random_uuid(); sup2 UUID:=gen_random_uuid();
  cus1 UUID:=gen_random_uuid();
  p1 UUID:=gen_random_uuid(); p2 UUID:=gen_random_uuid();
  pur1 UUID:=gen_random_uuid(); pur2 UUID:=gen_random_uuid();
  pi1 UUID:=gen_random_uuid(); pi2 UUID:=gen_random_uuid();
  inv1 UUID:=gen_random_uuid(); inv2 UUID:=gen_random_uuid(); inv3 UUID:=gen_random_uuid();
  ii1 UUID:=gen_random_uuid(); ii2 UUID:=gen_random_uuid(); ii3 UUID:=gen_random_uuid();
  sr1 UUID:=gen_random_uuid(); pr1 UUID:=gen_random_uuid();
  adj1 UUID:=gen_random_uuid();
  receipt1 UUID:=gen_random_uuid(); receipt_item1 UUID:=gen_random_uuid();
  closure1 UUID:=gen_random_uuid(); closure_item1 UUID:=gen_random_uuid();
  amendment1 UUID:=gen_random_uuid();
  cp1 UUID:=gen_random_uuid(); sp1 UUID:=gen_random_uuid();
  coa1 UUID:=gen_random_uuid(); coa2 UUID:=gen_random_uuid();
  je1 UUID:=gen_random_uuid();
  v_failed BOOLEAN;
BEGIN
  INSERT INTO public.stores(id,name) VALUES(s1,'Extension store A'),(s2,'Extension store B');
  INSERT INTO public.users(id,store_id,username,full_name) VALUES
    (u1,s1,'extension_owner_a','Extension Owner A'),
    (u2,s2,'extension_owner_b','Extension Owner B');
  INSERT INTO public.suppliers(id,store_id,code,name,current_debt) VALUES
    (sup1,s1,'EX-SUP-A','Extension Supplier A',1000),
    (sup2,s2,'EX-SUP-B','Extension Supplier B',1000);
  INSERT INTO public.customers(id,store_id,code,name) VALUES(cus1,s1,'EX-CUS-A','Extension Customer A');
  INSERT INTO public.products(id,store_id,name,primary_unit_id) VALUES
    (p1,s1,'Extension product A','pcs'),(p2,s2,'Extension product B','pcs');

  INSERT INTO public.purchases(id,store_id,purchase_number,supplier_id,purchase_date,created_by)
    VALUES(pur1,s1,'EX-PUR-A',sup1,NOW(),u1),(pur2,s2,'EX-PUR-B',sup2,NOW(),u2);
  INSERT INTO public.purchase_items(id,purchase_id,product_id,quantity,quantity_unit_id,unit_price,cost_per_unit,line_total)
    VALUES(pi1,pur1,p1,10,'pcs',5,4,50),(pi2,pur2,p2,10,'pcs',5,4,50);

  INSERT INTO public.invoices(id,store_id,invoice_number,type,invoice_date,customer_id,created_by)
    VALUES(inv1,s1,'EX-INV-A','SALE',NOW(),cus1,u1),
          (inv2,s2,'EX-INV-B','SALE',NOW(),NULL,u2),
          (inv3,s1,'EX-INV-A2','SALE',NOW(),cus1,u1);
  INSERT INTO public.invoice_items(id,invoice_id,product_id,quantity,quantity_unit_id,unit_price,line_total)
    VALUES(ii1,inv1,p1,2,'pcs',10,20),(ii2,inv2,p2,2,'pcs',10,20),(ii3,inv3,p1,1,'pcs',10,10);

  INSERT INTO public.sales_returns(id,store_id,return_number,original_invoice_id,created_by)
    VALUES(sr1,s1,'EX-SRET-A',inv1,u1);
  INSERT INTO public.purchase_returns(id,store_id,return_number,original_purchase_id,created_by)
    VALUES(pr1,s1,'EX-PRET-A',pur1,u1);

  INSERT INTO public.stock_adjustments(id,store_id,adjustment_number,product_id,adjustment_type,
    reason,quantity,unit_id,cost_per_unit,total_value,created_by)
    VALUES(adj1,s1,'EX-ADJ-A',p1,'INCREASE','extension integrity',1,'pcs',4,4,u1);

  INSERT INTO public.purchase_receipts(id,store_id,purchase_id,receipt_number,operation_id,received_by)
    VALUES(receipt1,s1,pur1,'EX-RCV-A',gen_random_uuid(),u1);
  INSERT INTO public.purchase_receipt_items(id,store_id,receipt_id,purchase_item_id,original_product_id,
    actual_product_id,ordered_quantity,accepted_quantity,quantity_unit_id,unit_cost,unit_price)
    VALUES(receipt_item1,s1,receipt1,pi1,p1,p1,10,5,'pcs',4,5);

  INSERT INTO public.purchase_closures(id,store_id,purchase_id,operation_id,reason,closed_by)
    VALUES(closure1,s1,pur1,gen_random_uuid(),'extension integrity test',u1);
  INSERT INTO public.purchase_closure_items(id,store_id,closure_id,purchase_item_id,quantity,reason)
    VALUES(closure_item1,s1,closure1,pi1,1,'remaining quantity test');

  INSERT INTO public.purchase_amendments(id,store_id,purchase_id,operation_id,reason,old_values_json,new_values_json,changed_by)
    VALUES(amendment1,s1,pur1,gen_random_uuid(),'extension integrity test','[]'::jsonb,'[]'::jsonb,u1);

  -- Valid source links for returns and ledgers.
  INSERT INTO public.purchase_return_items(return_id,product_id,quantity,quantity_unit_id,unit_price,line_total,
    purchase_item_id,purchase_receipt_item_id)
    VALUES(pr1,p1,1,'pcs',4,4,pi1,receipt_item1);
  INSERT INTO public.return_items(return_id,product_id,quantity,unit_price,line_total,invoice_item_id,
    quantity_unit_id,cost_per_unit,return_condition)
    VALUES(sr1,p1,1,10,10,ii1,'pcs',4,'GOOD');

  INSERT INTO public.customer_payments(id,customer_id,amount,payment_method,created_by)
    VALUES(cp1,cus1,5,'CASH',u1);
  INSERT INTO public.supplier_payments(id,supplier_id,amount,payment_method,created_by)
    VALUES(sp1,sup1,5,'CASH',u1);
  INSERT INTO public.customer_ledgers(customer_id,type,amount,balance,reference_id,created_by) VALUES
    (cus1,'SALE',20,20,inv1,u1),
    (cus1,'PAYMENT',-5,15,cp1,u1),
    (cus1,'RETURN',-10,5,sr1,u1);
  INSERT INTO public.supplier_ledger(supplier_id,type,amount,balance,reference_id,created_by) VALUES
    (sup1,'PURCHASE',50,50,pur1,u1),
    (sup1,'PAYMENT',-5,45,sp1,u1),
    (sup1,'RETURN',-4,41,pr1,u1),
    (sup1,'ADJUSTMENT',1,42,receipt1,u1),
    (sup1,'ADJUSTMENT',1,43,closure1,u1),
    (sup1,'ADJUSTMENT',1,44,amendment1,u1);

  INSERT INTO public.inventory_batches(store_id,product_id,batch_number,quantity,cost_per_unit)
    VALUES(s1,p1,'EX-BATCH-A',5,4);
  INSERT INTO public.stock_alerts(store_id,product_id,alert_type,current_quantity,threshold,message,acknowledged_by)
    VALUES(s1,p1,'LOW_STOCK',1,2,'extension integrity',u1);

  INSERT INTO public.chart_of_accounts(id,store_id,account_code,account_name,account_type)
    VALUES(coa1,s1,'EX-1000','Extension asset A','ASSET'),
          (coa2,s2,'EX-1000','Extension asset B','ASSET');
  INSERT INTO public.journal_entries(id,store_id,entry_number,entry_date,source_type,source_id,
    total_debit,total_credit,posted_by)
    VALUES(je1,s1,'EX-JE-A',NOW(),'ADJUSTMENT',adj1,4,4,u1);
  INSERT INTO public.general_ledger(store_id,journal_entry_id,account_id,entry_type,amount,
    reference_id,reference_table,created_by)
    VALUES(s1,je1,coa1,'DEBIT',4,adj1,'ADJUSTMENT',u1);

  -- Receipt item cannot point to a purchase item from a different purchase/store.
  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.purchase_receipt_items(store_id,receipt_id,purchase_item_id,original_product_id,
      actual_product_id,ordered_quantity,accepted_quantity,quantity_unit_id,unit_cost,unit_price)
    VALUES(s1,receipt1,pi2,p1,p1,10,1,'pcs',4,5);
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-purchase receipt item was accepted'; END IF;

  -- Purchase return item cannot use a receipt line from another purchase/store.
  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.purchase_return_items(return_id,product_id,quantity,quantity_unit_id,unit_price,line_total,
      purchase_item_id,purchase_receipt_item_id)
    VALUES(pr1,p1,1,'pcs',4,4,pi2,receipt_item1);
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-purchase return item source was accepted'; END IF;

  -- Sales return item must reference a line on the return's exact original invoice.
  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.return_items(return_id,product_id,quantity,unit_price,line_total,invoice_item_id,
      quantity_unit_id,cost_per_unit,return_condition)
    VALUES(sr1,p1,1,10,10,ii3,'pcs',4,'GOOD');
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Return item from a different invoice was accepted'; END IF;

  -- A customer ledger cannot point to another store's invoice.
  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.customer_ledgers(customer_id,type,amount,balance,reference_id,created_by)
      VALUES(cus1,'SALE',20,20,inv2,u1);
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store customer ledger source was accepted'; END IF;

  -- A supplier ledger cannot point to another store's purchase.
  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.supplier_ledger(supplier_id,type,amount,balance,reference_id,created_by)
      VALUES(sup1,'PURCHASE',50,50,pur2,u1);
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store supplier ledger source was accepted'; END IF;

  -- Journal source and general-ledger reference must match their source header/store.
  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.journal_entries(store_id,entry_number,entry_date,source_type,source_id,
      total_debit,total_credit,posted_by)
    VALUES(s1,'EX-JE-BAD',NOW(),'PURCHASE',pur2,1,1,u1);
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store journal source was accepted'; END IF;

  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.general_ledger(store_id,journal_entry_id,account_id,entry_type,amount,
      reference_id,reference_table,created_by)
    VALUES(s1,je1,coa1,'DEBIT',1,pur1,'PURCHASE',u1);
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Mismatched general ledger source was accepted'; END IF;

  -- Composite FKs must reject direct cross-store extension rows.
  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.inventory_batches(store_id,product_id,batch_number,quantity,cost_per_unit)
      VALUES(s1,p2,'EX-BATCH-BAD',1,4);
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store inventory batch was accepted'; END IF;

  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.stock_alerts(store_id,product_id,alert_type,current_quantity,threshold,message)
      VALUES(s1,p2,'LOW_STOCK',1,2,'bad');
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store stock alert was accepted'; END IF;

  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.purchase_receipts(store_id,purchase_id,receipt_number,operation_id,received_by)
      VALUES(s1,pur2,'EX-RCV-BAD',gen_random_uuid(),u1);
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store purchase receipt was accepted'; END IF;

  v_failed:=FALSE;
  BEGIN
    INSERT INTO public.general_ledger(store_id,journal_entry_id,account_id,entry_type,amount,created_by)
      VALUES(s1,je1,coa2,'DEBIT',1,u1);
  EXCEPTION WHEN OTHERS THEN v_failed:=TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Cross-store chart-of-accounts link was accepted'; END IF;

  RAISE NOTICE 'PASS: Phase 3 same-store extension, ledger and journal reference regressions';
END
$extension_integrity$;
ROLLBACK;
