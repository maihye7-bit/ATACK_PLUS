# ATACK PLUS — Sync Design Update (Phase 3)

## Changes in Phase 3

This document updates `SYNC_DESIGN.md` with Phase 3 sync considerations.

## New Tables for Sync

The following tables added in Phase 3 require synchronization:

| Table | Sync Direction | Conflict Type |
|-------|---------------|---------------|
| `purchase_returns` | PUSH/PULL | INVOICE |
| `purchase_return_items` | PUSH/PULL | INVOICE |
| `stock_adjustments` | PUSH/PULL | INVENTORY |
| `inventory_batches` | PUSH/PULL | INVENTORY |
| `stock_alerts` | PUSH | DUPLICATE |
| `chart_of_accounts` | PUSH/PULL | PRICE |
| `journal_entries` | INSERT-ONLY | INVOICE |
| `general_ledger` | INSERT-ONLY | CUSTOMER_DEBTS |

## Conflict Resolution Updates (Phase 3)

### New Conflict Types

| Type | When Triggered | Resolution |
|------|---------------|------------|
| `INVENTORY` | Stock discrepancy | CONFLICT_ALERT to manager |
| `INVOICE` | Duplicate or modified invoice | REJECT or VALIDATE |
| `CUSTOMER_DEBTS` | Payment allocation conflict | ACCEPT (sum of valid payments) |
| `SUPPLIER_DEBTS` | Supplier payment conflict | CONFLICT_ALERT |
| `PRICE` | Product price conflict | VALIDATE (keep original) |
| `DUPLICATE` | Duplicate operation detected | REJECT |
| `ADJUSTMENT` | Stock adjustment conflict | CONFLICT_ALERT |

### Phase 3 Conflict Handling

#### Stock Adjustments
```sql
-- Stock adjustment conflicts require manager review
INSERT INTO sync_conflicts (
    store_id, table_name, record_uuid, conflict_type,
    local_record_json, remote_record_json,
    resolution_notes
) VALUES (
    $store_id, 'stock_adjustments', $adjustment_uuid, 'INVENTORY',
    $local_json, $remote_json,
    'Stock adjustment conflict - requires manager review'
);
```

#### Purchase Returns
```sql
-- Purchase return conflicts - verify stock availability
-- Cannot return more than originally purchased/received
```

#### Inventory Batches
```sql
-- Batch conflicts require expiry date check
-- Cannot have overlapping batches with same expiry
```

#### Journal Entries (Read-Only for Sync)
```sql
-- Journal entries should NOT be synced as INSERT-ONLY
-- Financial records must be created through proper RPC calls
-- Not through generic row sync
```

## Phase 3 Sync Outbox Rules

### Transaction-Derived Tables (Cannot be in Outbox)

The following tables MUST NOT be directly inserted into `sync_outbox`:

- `general_ledger` (only via RPC)
- `journal_entries` (only via RPC)
- `chart_of_accounts` (managed via proper procedures)

### Allowed Operations in Outbox

| Table | Operation | Notes |
|-------|-----------|-------|
| `stock` | INSERT/UPDATE | Only via RPC (process_sale_invoice, process_purchase, etc.) |
| `stock_adjustments` | INSERT | Via `process_stock_adjustment` RPC |
| `purchase_returns` | INSERT | Via `process_purchase_return` RPC |
| `sales_returns` | INSERT | Via `process_sale_return` RPC |
| `inventory_batches` | INSERT/UPDATE | Direct allowed |
| `stock_alerts` | INSERT | Auto-generated |

## Sync Performance Considerations (Phase 3)

### Bulk Operations
- Phase 3 introduces batch/lot tracking which may have many records per product
- Consider pagination limits for `inventory_batches` sync
- Use `LIMIT 500` in sync pull queries

### Change Log Entries
Phase 3 adds these tables to automatic change logging:

```sql
-- Already included via trg_log_change()
CREATE TRIGGER trg_purchase_returns_log_change AFTER INSERT...
CREATE TRIGGER trg_purchase_return_items_log_change AFTER INSERT...
CREATE TRIGGER trg_stock_adjustments_log_change AFTER INSERT...
CREATE TRIGGER trg_journal_entries_log_change AFTER INSERT...
CREATE TRIGGER trg_general_ledger_log_change AFTER INSERT...
```

## Offline Scenarios (Phase 3)

### Stock Adjustment Offline
When device is offline:
1. Stock adjustment saved locally
2. Outbox entry created with status 'PENDING'
3. Stock not actually updated until synced
4. On reconnect: RPC validates and applies

### Purchase Return Offline
When device is offline:
1. Check local stock availability from previous purchase
2. Cannot verify stock actually received
3. On reconnect: RPC validates against synced purchase

## Sync Flow for Phase 3 Operations

```
Device A Offline → Stock Adjustment:
  1. Create stock_adjustments row in SQLite
  2. Create outbox entry with status='PENDING'
  3. Update local stock (UI shows updated value)
  4. Device reconnects
  5. RPC validates adjustment
  6. Creates stock movement
  7. Updates general_ledger
  8. Mark outbox as 'SYNCED'
  9. Pull changes to other devices

Device B Offline → Purchase Return:
  1. Verify original purchase exists locally
  2. Check stock for return quantity
  3. Create purchase_returns + items locally
  4. Create outbox entries
  5. On reconnect: RPC processes return
  6. Stock reduced, supplier ledger updated
  7. Other devices pull changes
```

## Idempotency Updates (Phase 3)

Phase 3 RPCs follow the same pattern as Phase 2:

```
Device → Supabase:
  POST process_purchase_return(store_id, operation_id, payload)

Response:
  - First success: {success: true, replayed: false}
  - Exact retry: {success: true, replayed: true}
  - Different payload: {"error": "Payload mismatch..."}
```

## Phase 3 Integration Checklist

- [ ] New tables added to `change_log` triggers
- [ ] RLS policies created for all new tables
- [ ] RPC functions added to `apply_outbox_operation` allowlist if needed
- [ ] Conflict resolution function updated if needed
- [ ] Sync cursors updated for new tables
- [ ] Test sync with offline stock adjustment
- [ ] Test sync with offline return
- [ ] Verify audit logs created for sync operations

## Phase 3 Rollback Considerations

If Phase 3 needs rollback:

1. Delete audit log entries for new operations
2. Revert stock to pre-adjustment levels (manual process)
3. Delete journal entries for new financial records
4. Mark all Phase 3 outbox entries as FAILED
5. Notify all devices to delete Phase 3 local data

⚠️ **Warning**: Rolling back financial/ledger data may require manual reconciliation.

---

*This update replaces conflicting sections in SYNC_DESIGN.md for Phase 3 features.*