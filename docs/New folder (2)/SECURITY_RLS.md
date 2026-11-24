# ATACK PLUS --- الأمان والصلاحيات (RLS)

## 1. مبادئ الأمان الأساسية

1. **Row Level Security (RLS)** على جميع الجداول الحساسة
2. **Supabase Functions** للمنطق المالي
3. **No secrets in client** - جميع المفاتيح السرية في الخادم
4. **Audit Trail** لجميع العمليات الحساسة
5. **Device authentication** عبر `device_id`

---

## 2. RLS Policies على PostgreSQL

### 2.1 سياسة المتجر (store-level isolation)

```sql
-- كل جدول يحتوي على store_id
ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
-- ... جميع الجداول المهمة

-- سياسة عرض
CREATE POLICY "invoices_store_access" ON invoices
FOR SELECT
USING (store_id = current_setting('app.current_store')::UUID);

-- سياسة إدراج
CREATE POLICY "invoices_insert_access" ON invoices
FOR INSERT
WITH CHECK (store_id = current_setting('app.current_store')::UUID);

-- سياسة تحديث
CREATE POLICY "invoices_update_access" ON invoices
FOR UPDATE
USING (store_id = current_setting('app.current_store')::UUID);

-- سياسة حذف
CREATE POLICY "invoices_delete_access" ON invoices
FOR DELETE
USING (store_id = current_setting('app.current_store')::UUID);
```

### 2.2 سياسة المستخدم (user-level access)

```sql
-- المدير يرى كل شيء
CREATE POLICY "users_admin_access" ON users
FOR ALL
TO admin_role
USING (true);

-- الكاشير يرى بعض المستخدمين فقط
CREATE POLICY "users_cashier_access" ON users
FOR SELECT
TO cashier_role
USING (role IN ('admin', 'accountant'));
```

---

## 3. الصلاحيات حسب الدور

| الدور | قابلية الوصول |
|-------|---------------|
| **Owner** | جميع القواعد، جميع العمليات |
| **Admin** | جميع القواعد، عدم حذف المتجر |
| **Accountant** | قراءة/كتابة المال، لا يحذف |
| **Cashier** | فقط المبيعات والعملاء |
| **Stock Keeper** | فقط المخزون |

---

## 4. Foreign Keys والتحقق

### 4.1 التحقق من الصلاحيات في PostgreSQL

```sql
-- Function للتحقق من صلاحية المستخدم
CREATE OR REPLACE FUNCTION check_user_permission(
    p_user_id UUID,
    p_permission_code TEXT
) RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM user_roles ur
        JOIN role_permissions rp ON ur.role_id = rp.role_id
        JOIN permissions p ON rp.permission_id = p.id
        WHERE ur.user_id = p_user_id
          AND p.code = p_permission_code
          AND ur.role_id IN ('owner', 'admin')
           OR p.code = ANY(ARRAY['sales.create', 'sales.view', 'inventory.adjust'])
    );
END;
$$ LANGUAGE plpgsql;
```

### 4.2 مثال على موافقة عملية

```sql
CREATE OR REPLACE FUNCTION process_sale_invoice(
    p_user_id UUID,
    p_store_id UUID,
    p_customer_id UUID,
    p_items JSONB
) RETURNS UUID AS $$
DECLARE
    v_invoice_id UUID;
BEGIN
    -- 1. تحقق من الصلاحية
    IF NOT check_user_permission(p_user_id, 'sales.create') THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;
    
    -- 2. تحقق من المتجر
    IF NOT EXISTS (SELECT 1 FROM stores WHERE id = p_store_id) THEN
        RAISE EXCEPTION 'Invalid store';
    END IF;
    
    -- 3. إنشاء الفاتلة
    INSERT INTO invoices (id, store_id, customer_id, ...)
    VALUES (gen_random_uuid(), p_store_id, p_customer_id, ...)
    RETURNING id INTO v_invoice_id;
    
    RETURN v_invoice_id;
END;
$$ LANGUAGE plpgsql;
```

---

## 5. Audit Log

```sql
CREATE TABLE audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    user_id UUID NOT NULL,
    entity_type TEXT,
    entity_id UUID,
    action TEXT CHECK(action IN ('CREATE', 'UPDATE', 'DELETE', 'VOID', 'SYNC')),
    old_values JSONB,
    new_values JSONB,
    ip_address TEXT,
    device_id TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Trigger للـ Audit Log
CREATE OR REPLACE FUNCTION audit_log_trigger()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO audit_logs (store_id, user_id, entity_type, entity_id, action, old_values, new_values)
    VALUES (
        NEW.store_id,
        current_setting('app.user_id')::UUID,
        TG_TABLE_NAME,
        COALESCE(NEW.id, OLD.id),
        TG_OP,
        CASE WHEN TG_OP = 'UPDATE' THEN row_to_json(OLD) END,
        row_to_json(NEW)
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- تطبيق Trigger على جميع الجداول الحساسة
CREATE TRIGGER invoices_audit AFTER INSERT OR UPDATE OR DELETE ON invoices
FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
```

---

## 6. محاسبة الوصول (Access Tracking)

```sql
-- جدول تتبع الوصول
CREATE TABLE access_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    user_id UUID NOT NULL,
    device_id TEXT,
    ip_address TEXT,
    action TEXT,
    resource TEXT,
    success INTEGER CHECK(success IN (0, 1)),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_access_logs_user ON access_logs(user_id);
CREATE INDEX idx_access_logs_store ON access_logs(store_id);
CREATE INDEX idx_access_logs_time ON access_logs(created_at);
```

---

## 7. حماية من تعدد المستخدمين (Concurrent User Protection)

```sql
-- Prevent double login from same user
CREATE UNIQUE INDEX unique_user_session 
ON user_sessions (user_id, device_id) 
WHERE is_active = true;

-- Prevent overlapping sync operations
CREATE UNIQUE INDEX unique_device_sync 
ON sync_operations (device_id, status) 
WHERE status = 'IN_PROGRESS';
```

---

## 8. موافقة المالك (Owner Approval)

```sql
-- جدول طلبات الموافقة
CREATE TABLE approval_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id UUID NOT NULL,
    requested_by UUID NOT NULL,
    action_type TEXT NOT NULL,  -- 'DELETE_PRODUCT', 'VOID_INVOICE', 'ADJUST_STOCK'
    entity_id UUID,
    entity_data JSONB,
    status TEXT DEFAULT 'PENDING' CHECK(status IN ('PENDING', 'APPROVED', 'REJECTED')),
    approved_by UUID,
    approved_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
```