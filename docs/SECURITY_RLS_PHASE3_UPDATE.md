# ATACK PLUS — Security and RLS Update (Phase 3)

## New RLS Policies for Phase 3 Tables

### Tables Added in Phase 3

```sql
-- Enable RLS on new tables
ALTER TABLE purchase_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_return_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE chart_of_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE general_ledger ENABLE ROW LEVEL SECURITY;
```

### Store Isolation Policies

```sql
-- Purchase Returns
CREATE POLICY purchase_returns_store_isolation ON purchase_returns
    FOR ALL USING (store_id = public.current_user_store_id())
    WITH CHECK (store_id = public.current_user_store_id());

CREATE POLICY purchase_return_items_store_isolation ON purchase_return_items
    FOR ALL USING (
        EXISTS (SELECT 1 FROM purchase_returns pr 
                WHERE pr.id = return_id AND pr.store_id = public.current_user_store_id())
    );

-- Stock Adjustments
CREATE POLICY stock_adjustments_store_isolation ON stock_adjustments
    FOR ALL USING (store_id = public.current_user_store_id())
    WITH CHECK (store_id = public.current_user_store_id());

-- Inventory Batches
CREATE POLICY inventory_batches_store_isolation ON inventory_batches
    FOR ALL USING (store_id = public.current_user_store_id())
    WITH CHECK (store_id = public.current_user_store_id());

-- Stock Alerts
CREATE POLICY stock_alerts_store_isolation ON stock_alerts
    FOR ALL USING (store_id = public.current_user_store_id())
    WITH CHECK (store_id = public.current_user_store_id());

-- Chart of Accounts
CREATE POLICY chart_of_accounts_store_isolation ON chart_of_accounts
    FOR ALL USING (store_id = public.current_user_store_id())
    WITH CHECK (store_id = public.current_user_store_id());

-- Journal Entries
CREATE POLICY journal_entries_store_isolation ON journal_entries
    FOR ALL USING (store_id = public.current_user_store_id())
    WITH CHECK (store_id = public.current_user_store_id());

-- General Ledger
CREATE POLICY general_ledger_store_isolation ON general_ledger
    FOR ALL USING (store_id = public.current_user_store_id())
    WITH CHECK (store_id = public.current_user_store_id());
```

## Phase 3 Permission Requirements

### New Permission Codes

Based on Phase 3 requirements, these permissions should be present in `permissions` table:

| Permission Code | Role Usage |
|-----------------|------------|
| `purchases.return` | Required for `process_purchase_return` RPC |
| `inventory.adjust` | Required for `process_stock_adjustment` RPC |
| `reports.view` | Required for `check_inventory_expiry` and `check_low_stock` |
| `accounting.view` | Required to read journal entries and ledger |
| `accounting.create` | Required to create journal entries (typically system only) |

### Default Role Permissions

Update `role_permissions` table:

| Role | Additional Permissions Granted |
|------|-------------------------------|
| `owner` | All Phase 3 permissions |
| `admin` | All Phase 3 permissions |
| `accountant` | `purchases.return`, `inventory.adjust`, `reports.view`, `accounting.view` |
| `cashier` | `purchases.return` (limited by store) |
| `stock_keeper` | `inventory.adjust`, `reports.view` |

## Phase 3 Cross-Store Validation

### Purchase Return Store Validation

```sql
CREATE OR REPLACE FUNCTION public.validate_purchase_return_same_store()
RETURNS TRIGGER AS $$
DECLARE
    v_purchase_store UUID;
BEGIN
    SELECT p.store_id INTO v_purchase_store 
    FROM purchases p 
    WHERE p.id = NEW.original_purchase_id;
    
    IF v_purchase_store IS DISTINCT FROM NEW.store_id THEN
        RAISE EXCEPTION 'Purchase return must reference a purchase from the same store';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_purchase_returns_same_store
    BEFORE INSERT OR UPDATE ON purchase_returns
    FOR EACH ROW EXECUTE FUNCTION public.validate_purchase_return_same_store();
```

### Return Items Store Validation

The `purchase_return_items` and `return_items` (sales returns) benefit from existing cross-store validation via the `validate_same_store_references` function already defined in the base schema.

## Financial Data Protection (Phase 3)

### Journal Entries Immutability

Financial records in Phase 3 must follow the same principles as Phase 2:

```sql
-- Journal entries should only be created via RPC
-- Not directly from application
REVOKE INSERT, UPDATE, DELETE ON journal_entries FROM PUBLIC, anon, authenticated;
GRANT SELECT ON journal_entries TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_stock_adjustment TO authenticated;
```

### General Ledger Immutability

Ledger entries from business operations:
- Should be immutable (no direct UPDATE/DELETE)
- Only created through proper RPC calls
- Must balance (debit = credit)

```sql
-- Prevent direct modification
CREATE POLICY prevent_direct_ledger_modification ON general_ledger
    FOR UPDATE, DELETE USING (false);
```

## Audit Logging for Phase 3

### Additional Tables Requiring Audit

```sql
-- Change log triggers for new tables
CREATE TRIGGER trg_purchase_returns_log_change
    AFTER INSERT OR UPDATE OR DELETE ON purchase_returns
    FOR EACH ROW EXECUTE FUNCTION trg_log_change();

CREATE TRIGGER trg_stock_adjustments_log_change
    AFTER INSERT OR UPDATE OR DELETE ON stock_adjustments
    FOR EACH ROW EXECUTE FUNCTION trg_log_change();
```

### New Audit Actions

Phase 3 adds these important operations to audit:
- Stock adjustments (`ADJUSTMENT`)
- Purchase returns (`VOID` equivalent)
- Journal entry creation (`SYNC` for automated entries)

## Device Authentication Updates (Phase 3)

### New Sync Operations

Phase 3 introduces additional sync operation types:

| Operation Type | Description |
|----------------|-------------|
| `purchase_return` | Purchase return via RPC |
| `sale_return` | Sales return via RPC |
| `stock_adjustment` | Stock adjustment via RPC |
| `inventory_sync` | Batch/lot data sync |

### Device Permission Checks

Phase 3 operations require the same device/store validation as Phase 2, but with additional financial permission checks.

## Security Testing Checklist (Phase 3)

Before Phase 3 deployment, verify:

1. **Store Isolation**
   - [ ] User from store A cannot read purchase_returns from store B
   - [ ] User cannot create return for purchase from another store
   - [ ] Stock adjustments isolated by store

2. **Permission Enforcement**
   - [ ] Users without `purchases.return` cannot execute `process_purchase_return`
   - [ ] Users without `inventory.adjust` cannot execute `process_stock_adjustment`
   - [ ] Users without `reports.view` cannot call report functions

3. **Financial Data Protection**
   - [ ] General ledger only writable via RPC
   - [ ] Journal entries cannot be modified after creation
   - [ ] Balance sheet/debit-credit always balance

4. **Audit Completeness**
   - [ ] All stock adjustments logged in audit_logs
   - [ ] All returns logged with proper user/store context
   - [ ] Financial operations traceable

5. **Concurrency Safety**
   - [ ] Multiple devices cannot create conflicting adjustments
   - [ ] Return quantity cannot exceed available stock
   - [ ] Debt adjustments are serialized

## Error Handling and Security

### Common Security Errors

| Error Message | SQLSTATE | Cause |
|---------------|----------|-------|
| User is not an active member of this store | 42501 | auth.uid() doesn't match store |
| Missing permission: purchases.return | 42501 | Role lacks permission |
| Purchase return must reference a purchase from the same store | P0001 | Cross-store reference |
| Insufficient stock available for product % to return | 23514 | Business rule violation |
| Reason for adjustment is required | P0001 | Missing required field |

### Row-Level Security Best Practices

Phase 3 follows these RLS principles:

1. **Never trust client-provided store_id** - Always use `current_user_store_id()`
2. **Validate relationships** - Check parent records belong to same store
3. **Use deterministic paths** - Always validate through `auth.uid()`
4. **Block direct financial writes** - Financial tables only writable via RPC
5. **Serialize critical operations** - Use row locks in RPC functions

## Permission Migration Script

Run this after applying Phase 3 schema to ensure permissions:

```sql
-- Add Phase 3 permissions if not exist
INSERT INTO permissions (code, description) VALUES
    ('purchases.return', 'Create purchase returns'),
    ('inventory.adjust', 'Adjust stock quantities'),
    ('reports.view', 'View inventory and financial reports'),
    ('accounting.view', 'View journal entries and ledger'),
    ('accounting.create', 'Create journal entries')
ON CONFLICT (code) DO NOTHING;

-- Grant permissions to roles
-- This requires knowing the permission IDs, but using a one-time setup:
WITH role_perms AS MATERIALIZED (
    SELECT 
        r.id as role_id,
        p.id as perm_id,
        p.code,
        'owner' as granted_role
    FROM roles r
    CROSS JOIN permissions p
    WHERE p.code IN ('purchases.return', 'inventory.adjust', 'reports.view', 'accounting.view')
)
INSERT INTO role_permissions (role_id, permission_id, granted_by)
SELECT rp.role_id, rp.perm_id, u.id
FROM role_perms rp
JOIN users u ON u.role_id = 'owner'
ON CONFLICT DO NOTHING;
```

---

*This update replaces conflicting sections in SECURITY_RLS.md for Phase 3 features.*