# ATACK PLUS — Phase 3 RPC Integration Guide

## Apply Order

1. Ensure `POSTGRES_SCHEMA_PHASE1_FIXED.sql` is applied (Phase 1 base schema)
2. Ensure `ATACK_PLUS_PHASE2_BUSINESS_RPCS.sql` is applied (Phase 2 atomic operations)
3. Apply `ATACK_PLUS_PHASE3_RETURNS_INVENTORY_ACCOUNTING.sql`
4. Run Phase 3 tests in `TEST_PLAN_PHASE3_UPDATED.md` before connecting Flutter

Do not apply this migration to production before a full backup and staging validation.

## New Tables Added in Phase 3

| Table | Purpose |
|-------|---------|
| `purchase_returns` | Purchase returns header |
| `purchase_return_items` | Purchase return line items |
| `stock_adjustments` | Manual stock adjustments |
| `inventory_batches` | Batch/lot tracking with expiry |
| `stock_alerts` | Low stock and expiry alerts |
| `chart_of_accounts` | Double-entry accounting chart |
| `journal_entries` | Accounting journal entries |
| `general_ledger` | General ledger details |

## New RPC Functions

### 1. Sales Return

**RPC**: `process_sale_return`

**Arguments**:
- `p_store_id`: store UUID
- `p_operation_id`: stable UUID for idempotency
- `p_payload`: JSON object

**Payload Structure**:
```json
{
  "id": "uuid-of-return",
  "invoice_id": "original-invoice-uuid",
  "return_number": "RET-001",
  "refund_method": "CREDIT|CASH|BANK_TRANSFER|MOBILE",
  "return_condition": "GOOD|DEFECTIVE|UNSALEABLE",
  "reason": "Customer requested return",
  "items": [
    {
      "product_id": "product-uuid",
      "quantity": 2,
      "unit_id": "pcs",
      "unit_price": 50.0000,
      "batch_number": "BATCH-001",
      "expiry_date": "2026-12-31T00:00:00Z"
    }
  ]
}
```

**Returns**:
```json
{
  "success": true,
  "replayed": false,
  "return_id": "uuid",
  "total_amount": 100.0000
}
```

**Behavior**:
- Creates sales return record
- If `return_condition = "GOOD"`: increases stock, creates `RETURN_IN` movement
- If `return_condition IN ('DEFECTIVE', 'UNSALEABLE')`: records return without stock increase
- Creates customer ledger entry (negative amount)
- Updates customer debt
- Supports CREDIT, CASH, BANK_TRANSFER, MOBILE refund methods

### 2. Purchase Return

**RPC**: `process_purchase_return`

**Arguments**:
- `p_store_id`: store UUID
- `p_operation_id`: stable UUID for idempotency
- `p_payload`: JSON object

**Payload Structure**:
```json
{
  "id": "uuid-of-return",
  "purchase_id": "original-purchase-uuid",
  "return_number": "PUR-RET-001",
  "refund_method": "CREDIT|CASH|BANK_TRANSFER|MOBILE",
  "reference_no": "REF-123",
  "reason": "Damaged goods",
  "items": [
    {
      "product_id": "product-uuid",
      "quantity": 10,
      "unit_id": "pcs",
      "unit_price": 75.0000,
      "batch_number": "BATCH-002",
      "expiry_date": "2026-11-15T00:00:00Z"
    }
  ]
}
```

**Returns**:
```json
{
  "success": true,
  "replayed": false,
  "return_id": "uuid",
  "total_amount": 750.0000
}
```

**Behavior**:
- Creates purchase return record
- Decreases stock (`RETURN_OUT` movement)
- Creates supplier ledger entry (negative amount for credit method)
- For CASH/BANK_TRANSFER: creates `supplier_payments` record
- Updates supplier `current_debt` (reduction)

### 3. Stock Adjustment

**RPC**: `process_stock_adjustment`

**Arguments**:
- `p_store_id`: store UUID
- `p_operation_id`: stable UUID for idempotency
- `p_payload`: JSON object

**Payload Structure**:
```json
{
  "id": "uuid-of-adjustment",
  "product_id": "product-uuid",
  "adjustment_number": "ADJ-2026-001",
  "adjustment_type": "INCREASE|DECREASE",
  "reason": "Physical count discrepancy",
  "quantity": 5,
  "unit_id": "pcs",
  "cost_per_unit": 100.0000,
  "refund_method": "CREDIT"
}
```

**Returns**:
```json
{
  "success": true,
  "replayed": false,
  "adjustment_id": "uuid"
}
```

**Behavior**:
- Creates stock adjustment record
- Updates stock quantity (increase or decrease)
- Creates `ADJUSTMENT` stock movement
- Creates journal entry with proper debit/credit
- **Requires** `reason` field (mandatory)

### 4. Inventory Reports

**Reports**: `check_inventory_expiry`, `check_low_stock`

**Arguments**:
- `p_store_id`: store UUID

**Returns**:
- `check_inventory_expiry`: List of products expiring within 30 days
- `check_low_stock`: List of products below minimum stock

## Accounting Views

### Trial Balance View

```sql
SELECT * FROM v_trial_balance;
```

Returns: account_code, account_name, account_type, total_debit, total_credit, balance

### Balance Sheet View

```sql
SELECT * FROM v_balance_sheet;
```

Returns: Assets, Liabilities, Equity accounts with balances

### Income Statement View

```sql
SELECT * FROM v_income_statement;
```

Returns: Revenue and Expense accounts

## Permissions Required

| Operation | Required Permission |
|-----------|---------------------|
| Sales Return | `sales.write` |
| Purchase Return | `purchases.return` |
| Stock Adjustment | `inventory.write` |
| Check Expiry | `reports.view` |
| Check Low Stock | `reports.view` |

## Inventory Batch/Lot Tracking

### Enable Batch Tracking

Products can have `batch_enabled = true` to enable batch/lot tracking.

### Use Inventory Batches Table

```sql
SELECT * FROM inventory_batches WHERE store_id = $store_id;
```

Fields:
- `product_id`, `batch_number`, `quantity`, `expiry_date`, `cost_per_unit`
- `available_quantity` - calculated as `quantity - reserved_quantity`

### Generate Stock Alerts

```dart
// Flutter/Dart pseudo-code
final expiringSoon = await supabase.rpc('check_inventory_expiry', {
  'p_store_id': currentStoreId
});

final lowStock = await supabase.rpc('check_low_stock', {
  'p_store_id': currentStoreId
});

// Show alerts to user
for (final item in lowStock) {
  showInSnackBar('Low stock: ${item.product_name}');
}
```

## Journal Entries Flow

### Chart of Accounts Structure

Default accounts should be seeded:

| Code | Name | Type |
|------|------|------|
| 1000 | Cash | CURRENT_ASSET |
| 1100 | Bank | CURRENT_ASSET |
| 1200 | Inventory | ASSET |
| 2000 | Trade Payables | CURRENT_LIABILITY |
| 4000 | Sales Revenue | REVENUE |
| 5000 | Cost of Goods Sold | COST_OF_GOODS_SOLD |

### Journal Entry Creation

For sales:
- Debit: Cash/Bank (if paid) or Accounts Receivable
- Credit: Sales Revenue
- Credit: Tax Payable (if applicable)

For returns:
- Debit: Sales Returns (or Sales Revenue reverse)
- Credit: Accounts Receivable or Cash

For inventory adjustments:
- INCREASE: Credit Inventory
- DECREASE: Debit Inventory Adjustment

## Idempotency Handling

All Phase 3 RPCs support idempotency:

1. Generate UUID v7 for `operation_id` (includes timestamp + randomness)
2. Store in local SQLite outbox
3. Call RPC with same `operation_id`
4. First call: `success=true, replayed=false`
5. Retry with same payload: `success=true, replayed=true`
6. Retry with different payload: Error `Payload mismatch for idempotency key`

## Sync Integration

Phase 3 tables integrate with existing sync system:

1. New tables have RLS enabled
2. Tables are included in `apply_outbox_operation` allowlist if needed
3. `change_log` triggers fire automatically via `trg_log_change()`
4. Sync cursors work via `store_sync_counters`

## Flutter Integration Example

```dart
class PurchaseReturnRepository {
  Future<PurchaseReturnResult> processPurchaseReturn({
    required String storeId,
    required String operationId,
    required PurchaseReturnPayload payload,
  }) async {
    final response = await Supabase.instance.client.rpc(
      'process_purchase_return',
      params: {
        'p_store_id': storeId,
        'p_operation_id': operationId,
        'p_payload': payload.toJson(),
      },
    );

    if (response['success']) {
      if (response['replayed']) {
        // Already processed, no action needed
        return PurchaseReturnResult.replayed();
      }
      return PurchaseReturnResult.success(
        returnId: response['return_id'],
        totalAmount: response['total_amount'],
      );
    }
    throw Exception(response['error']);
  }
}

class StockAdjustmentRepository {
  Future<void> processStockAdjustment({
    required String storeId,
    required String operationId,
    required StockAdjustmentPayload payload,
  }) async {
    final response = await Supabase.instance.client.rpc(
      'process_stock_adjustment',
      params: {
        'p_store_id': storeId,
        'p_operation_id': operationId,
        'p_payload': payload.toJson(),
      },
    );

    if (!response['success']) {
      throw Exception(response['error']);
    }
  }
}
```

## Testing Checklist Before Production

- [ ] Apply migration to clean staging database
- [ ] All new RPC functions compile without errors
- [ ] Test idempotency for each RPC
- [ ] Test store isolation (user A cannot access store B data)
- [ ] Test permission enforcement (role without permission cannot execute)
- [ ] Test debit/credit balance in journal entries
- [ ] Test negative stock prevention
- [ ] Test defect return (no stock increase)
- [ ] Test CASH refund creates payment record
- [ ] Test audit logs created for all operations
- [ ] Run Phase 3 test matrix and all tests pass
- [ ] Performance test: 100 returns < 5 seconds
- [ ] Backup and rollback plan tested

## Common Errors and Solutions

| Error | Cause | Solution |
|-------|-------|----------|
| "Missing permission" | User lacks required role | Assign correct role/permission |
| "Insufficient stock" | Return quantity > available | Check original sold quantity |
| "Payload mismatch for idempotency key" | Same operation_id used with different data | Generate new operation_id |
| "Cannot decrease stock below zero" | Adjustment quantity > current stock | Use lower quantity or investigate |
| "Reason for adjustment is required" | Empty reason field | Provide valid reason string |

## Roll Forward / Roll Back

**Roll Forward** (apply migration):
```bash
# Apply using Supabase CLI or psql
psql -h host -U user -d database -f ATACK_PLUS_PHASE3_RETURNS_INVENTORY_ACCOUNTING.sql
```

**Roll Back**:
```sql
-- Drop new tables in reverse order
DROP TABLE IF EXISTS general_ledger CASCADE;
DROP TABLE IF EXISTS journal_entries CASCADE;
DROP TABLE IF EXISTS chart_of_accounts CASCADE;
DROP TABLE IF EXISTS purchase_returns CASCADE;
DROP TABLE IF EXISTS purchase_return_items CASCADE;
DROP TABLE IF EXISTS stock_adjustments CASCADE;
DROP TABLE IF EXISTS inventory_batches CASCADE;
DROP TABLE IF EXISTS stock_alerts CASCADE;

-- Drop RPC functions
DROP FUNCTION IF EXISTS public.process_sale_return(UUID, UUID, JSONB);
DROP FUNCTION IF EXISTS public.process_purchase_return(UUID, UUID, JSONB);
DROP FUNCTION IF EXISTS public.process_stock_adjustment(UUID, UUID, JSONB);
DROP FUNCTION IF EXISTS public.check_inventory_expiry(UUID);
DROP FUNCTION IF EXISTS public.check_low_stock(UUID);

-- Drop RLS policies for new tables
DROP POLICY IF EXISTS purchase_returns_store_isolation ON purchase_returns;
DROP POLICY IF EXISTS purchase_return_items_store_isolation ON purchase_return_items;
-- ... (others)
```

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)