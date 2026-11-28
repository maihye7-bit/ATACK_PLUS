-- Disposable CI fixture: create legacy global-location inventory rows before Stage 3 migration.
BEGIN;
INSERT INTO public.stores(id,name) VALUES
('a3000000-0000-4000-8000-000000000001','Stage3 Warehouse Store A'),
('a3000000-0000-4000-8000-000000000002','Stage3 Warehouse Store B');

INSERT INTO public.users(id,store_id,username,full_name,is_active) VALUES
('a3000000-0000-4000-8000-000000000011','a3000000-0000-4000-8000-000000000001','stage3_owner_a','Stage3 Owner A',TRUE),
('a3000000-0000-4000-8000-000000000012','a3000000-0000-4000-8000-000000000002','stage3_owner_b','Stage3 Owner B',TRUE);

INSERT INTO public.products(id,store_id,name,primary_unit_id,cost_price,default_sale_price,is_active) VALUES
('a3000000-0000-4000-8000-000000000021','a3000000-0000-4000-8000-000000000001','Stage3 Product A','pcs',10,15,TRUE),
('a3000000-0000-4000-8000-000000000022','a3000000-0000-4000-8000-000000000002','Stage3 Product B','pcs',20,30,TRUE);

INSERT INTO public.stock(product_id,location_id,quantity,reserved_quantity) VALUES
('a3000000-0000-4000-8000-000000000021','main',12,2),
('a3000000-0000-4000-8000-000000000022','warehouse',7,1);

INSERT INTO public.stock_movements(product_id,location_id,type,quantity,unit_id,cost_per_unit,total_value,user_id)
VALUES
('a3000000-0000-4000-8000-000000000021','main','IN',12,'pcs',10,120,'a3000000-0000-4000-8000-000000000011'),
('a3000000-0000-4000-8000-000000000022','warehouse','IN',7,'pcs',20,140,'a3000000-0000-4000-8000-000000000012');

INSERT INTO public.stock_adjustments(id,store_id,adjustment_number,product_id,adjustment_type,reason,
    quantity,unit_id,cost_per_unit,total_value,created_by,location_id)
VALUES
('a3000000-0000-4000-8000-000000000031','a3000000-0000-4000-8000-000000000001','ST3-A-1',
 'a3000000-0000-4000-8000-000000000021','INCREASE','legacy migration fixture',2,'pcs',10,20,
 'a3000000-0000-4000-8000-000000000011','storage');
COMMIT;
