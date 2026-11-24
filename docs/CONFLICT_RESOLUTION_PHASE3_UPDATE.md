# ATACK PLUS — Conflict Resolution Update (Phase 3)

## New Conflict Handling for Phase 3 Operations

This document extends `CONFLICT_RESOLUTION.md` with Phase 3 conflict resolution rules.

## Phase 3 Conflict Types

| Conflict Type | Tables Involved | Resolution Strategy |
|---------------|-----------------|---------------------|
| `ADJUSTMENT` | stock_adjustments | CONFLICT_ALERT to manager |
| `RETURN` | purchase_returns, sales_returns | REJECT if invalid; otherwise ACCEPT_LOCAL |
| `BATCH` | inventory_batches | MERGE non-conflicting batches |

## Phase 3 Conflict Resolution Rules

### 3.1 Stock Adjustments

| Scenario | Rule | Action |
|----------|------|--------|
| Simultaneous adjustments on same product | CONFLICT_ALERT | Notify manager, don't auto-resolve |
| Adjustment exceeding available stock | PREVENT | Reject adjustment with error |
| Negative stock result from adjustment | PREVENT | Reject during RPC execution |
| Adjustment with missing reason | REJECT | RPC requires reason field |

**Resolution Algorithm for Adjustment Conflicts:**
```
1. Detect conflict during sync
2. INSERT INTO sync_conflicts (conflict_type='ADJUSTMENT')
3. Email/SMS notification to manager
4. Manager reviews:
   - Device A: increased by 10 at reason "Found stock"
   - Device B: decreased by 5 at reason "Damaged"
5. Manager chooses resolution:
   - ACCEPT_LOCAL: Use Device A's adjustment
   - ACCEPT_REMOTE: Use Device B's adjustment
   - MERGE: Apply both in timestamp order
6. System creates corrective ADJUSTMENT entry
```

### 3.2 Purchase Returns

| Scenario | Rule | Action |
|----------|------|--------|
| Return quantity > purchased quantity | PREVENT | Reject return in RPC |
| Return for already-cancelled purchase | PREVENT | Reject return |
| Duplicate return operation_id | REJECT/DUPLICATE | Return replayed=true |
| Return for different store's purchase | PREVENT | Cross-store validation error |

**Resolution for Purchase Return Conflicts:**
- **Cannot be auto-resolved via generic function**
- Must use `process_purchase_return` RPC
- RPC validates stock availability before processing
- If sync conflict occurs, requires manual review

### 3.3 Sales Returns

| Scenario | Rule | Action |
|----------|------|--------|
| Return quantity > sold quantity | PREVENT | Reject return |
| Return of already-cancelled invoice | PREVENT | Reject return |
| Mixed good/defective items | MERGE | Create separate movements |

**Sales Return Conflict Resolution:**
```
Device A: Return 2 good units
Device B: Return 1 good unit + 1 defective unit

Sync Resolution:
1. Stock should increase by 2 (only good items)
2. Defective return recorded but no stock change
3. Both returns appear in sales_returns
```

### 3.4 Inventory Batches

| Scenario | Rule | Action |
|----------|------|--------|
| Overlapping batches same product | MERGE | If expiry differs |
| Duplicate batch number | REJECT | Unique constraint |
| Expiry date modification | REJECT | Immutable field |

### 3.5 Financial Records (Journal Entries)

**Phase 3 Rule: Financial records are INSERT-ONLY**

```
DO NOT ALLOW:
- UPDATE on general_ledger
- UPDATE on journal_entries  
- DELETE on financial tables

ALLOW:
- INSERT via RPC functions only
- SELECT with RLS filtering
```

If a financial error is discovered:
1. Create correcting journal entry (reverse + correct)
2. Document in description field
3. Add reference to correction

## Cross-Table Conflict Scenarios (Phase 3)

### Stock Adjustment vs Sale

```
Precondition:
- Product stock = 100
- Device A: Sale 5 units (stock: 95)
- Device B: Adjustment +10 units (stock: 110)

Sync sequence:
1. Device A syncs: stock = 95, movement = OUT
2. Device B syncs: CONFLICT (expected 95, got 110)
3. Resolution: CONFLICT_ALERT
4. Correct stock: 105 (95 + 10 adjustment after sale)
5. Manager action: Accept remote (adjustment), adjust sale quantity if needed
```

### Purchase Return vs New Sale

```
Precondition:
- Product stock = 100
- Original purchase: 100 units received
- Device A: Return 10 units to supplier
- Device B: Sell 5 units (without sync)

Sync sequence:
1. Device B syncs first: stock = 95
2. Device A syncs return: stock should be 105
3. CONFLICT DETECTED: expected 95, got 105
4. Resolution options:
   - MANUAL: Manager reviews both operations
   - AUTO: Apply return's stock impact (increase by 10) → 105
```

## Phase 3 Conflict Resolution Functions

### Enhanced resolve_sync_conflict Function

The base function now includes Phase 3 tables:

```sql
-- Conflict resolution now checks financial tables
IF v_conflict.table_name IN (
    'journal_entries', 'general_ledger', 'chart_of_accounts'
) THEN
    RAISE EXCEPTION 'Financial records cannot be resolved by generic row overwrite';
END IF;

-- Phase 3 specific handling
CASE v_conflict.table_name
  WHEN 'stock_adjustments' THEN
    -- Return CONFLICT_ALERT, not auto-resolve
    v_resolution_allowed := ARRAY['ACCEPT_LOCAL', 'ACCEPT_REMOTE'];
  WHEN 'purchase_returns' THEN
    -- Validate against original purchase
    -- Check if return quantity is valid
  WHEN 'inventory_batches' THEN
    -- Validate batch constraints
END CASE;
```

## Manual Conflict Resolution Workflow (Phase 3)

### Stock Adjustment Conflicts

1. **Notification**
   - System sends alert: "Stock conflict for Product X"
   - Shows both adjustments with timestamps

2. **Review Steps**
   - Check original sales/purchases for both adjustments
   - Verify actual physical count
   - Determine correct stock level

3. **Resolution Options**
   - Accept Local Adjustment
   - Accept Remote Adjustment  
   - Merge Adjustments (apply in order)
   - Create corrective adjustment

4. **Audit Trail**
   - System logs resolution decision
   - Creates audit_logs entry
   - Updates sync_conflicts record

### Purchase Return Conflicts

1. **Detection**
   - Return attempts to add stock that was already returned
   - Return quantity exceeds available returned stock

2. **Action**
   - Reject duplicate return
   - Show user: "This return was already processed"
   - Do not create new stock movement

## Phase 3 Testing Scenarios

### Scenario 1: Stock adjustment conflicts

```
Setup:
- Product stock = 50
- Device A: Adjust +20 (reason: "Found after count")
- Device B: Adjust -10 (reason: "Damaged items")

Both devices offline, then sync concurrently:

Expected:
- CONFLICT created in sync_conflicts
- Manager notified
- Resolution: Create corrective adjustment
```

### Scenario 2: Return of already-returned items

```
Setup:
- Original sale: 10 units
- Device A: Return 5 units (good)
- Device B: Return 5 units (trying again)

Sync sequence:
1. Device A: Stock = 55, 5 returned
2. Device B: CONFLICT - quantity already returned
3. Resolution: REJECT second return
4. User sees: "Items already returned"

Actual Result:
- First return processed
- Second returns marked as CONFLICT
- Stock not increased again
```

### Scenario 3: Financial record attempt via generic sync

```
Setup:
- Attempt to INSERT into journal_entries via apply_outbox_operation

Expected:
- ERROR: "Table journal_entries is transaction-derived; use a dedicated atomic business RPC"
- outbox entry marked as FAILED
- Audit log records the attempt
```

## Phase 3 Conflict Resolution Priority

When multiple phase 3 operations conflict:

1. **Financial records first** - Never auto-resolve
2. **Stock movements** - Prevent negative stock
3. **Returns** - Validate against original documents
4. **Adjustments** - Alert manager
5. **Batches** - Merge non-conflicting

## Reporting Conflicts

### Conflict Report Structure

```sql
SELECT 
    c.id,
    c.conflict_type,
    c.table_name,
    c.local_record_json,
    c.remote_record_json,
    c.created_at,
    u.username as resolved_by
FROM sync_conflicts c
LEFT JOIN users u ON u.id = c.resolved_by
WHERE c.store_id = $store_id 
  AND c.resolution_status = 'PENDING'
ORDER BY c.created_at DESC
LIMIT 50;
```

### Manager Dashboard Query

```sql
-- Get all pending conflicts with summary
SELECT 
    table_name,
    conflict_type,
    COUNT(*) as pending_count,
    MAX(created_at) as oldest_pending
FROM sync_conflicts
WHERE resolution_status = 'PENDING'
GROUP BY table_name, conflict_type;
```

## Phase 3 Rollback from Conflict

If a conflict resolution is incorrect:

1. Do NOT edit financial records directly
2. Create reversing journal entry
3. Apply correct adjustment via proper RPC
4. Update sync_conflicts with "CORRECTIVE" notes
5. Document in audit_logs

---

*This update replaces conflicting sections in CONFLICT_RESOLUTION.md for Phase 3 features.*