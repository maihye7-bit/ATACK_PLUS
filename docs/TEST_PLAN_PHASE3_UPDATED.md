# ATACK PLUS — Phase 3 Test Plan (Returns, Inventory, Accounting)
# Builds upon TEST_PLAN_PHASE2_UPDATED.md

## 1. Phase 3 Test Categories

| Category | Unit Tests | Integration Tests | E2E Tests |
|----------|------------|-------------------|-----------|
| Sales Returns | 4 | 2 | 3 |
| Purchase Returns | 3 | 2 | 2 |
| Stock Adjustments | 3 | 2 | 2 |
| Inventory Expiry/Batch | 2 | 1 | 1 |
| Accounting (Ledger, COA, Reports) | 4 | 2 | 2 |
| Audit Logging | 2 | 1 | 1 |
| Security (RLS, Permissions) | 3 | 1 | 1 |

## 2. Sales Returns Tests (RPC: process_sale_return)

### Test Case STR-01: Full return with good items

```
Precondition:
- Product "Detergent" stock = 100 units
- Invoice INV-001 for 5 units created by Device A
- Device A online

Steps:
1. Call process_sale_return with id, invoice_id="INV-001", items=[{product_id, quantity: 5}], return_condition="GOOD"
2. Verify sales_returns row created
3. Verify stock increased by 5 units
4. Verify stock_movements type="RETURN_IN" created
5. Verify customer_ledgers entry with type="RETURN"

Expected Result:
- Return created with total_amount = 5 * unit_price
- Stock = 105 (original 100 + 5 returned)
- Ledger shows credit for customer
- Status: SYNCED

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

### Test Case STR-02: Partial return

```
Precondition:
- Invoice INV-002 for 10 units, customer debt = 5000 DZD
- Device B online

Steps:
1. Return 3 units from INV-002
2. Verify stock increased by 3 units
3. Verify customer_ledgers debt reduced by 3*unit_price
4. Verify stock.movements.quantity = 3

Expected Result:
- Partial return processed correctly
- Customer debt reduced proportionally
- No double-counting of return amounts

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

### Test Case STR-03: Return of defective/unusable items

```
Precondition:
- Product "Soap" stock = 10 units
- Return items with return_condition="DEFECTIVE"

Steps:
1. Process return with return_condition="DEFECTIVE"
2. Verify stock NOT increased
3. Verify movement still logged
4. Verify ledger entry created

Expected Result:
- Stock unchanged (or could be special handling)
- Return recorded for accounting
- Movement shows reason for no stock increase

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

### Test Case STR-04: Prevent return exceeding original quantity

```
Precondition:
- Invoice INV-003 has 3 units returned already
- Attempt to return 4 more units from same invoice

Steps:
1. Try to return 4 units when only 3 were sold (or less available)
2. Verify error raised

Expected Result:
- Exception: "Insufficient stock available for product % to return"
- No return record created

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

### Test Case STR-05: Idempotency of returns

```
Precondition:
- First return call succeeded

Steps:
1. Call same process_sale_return with identical operation_id and payload
2. Verify response includes replayed=true

Expected Result:
- Success, replayed=true
- No duplicate stock movement
- No duplicate ledger entry
- Return count unchanged

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

### Test Case STR-06: Return replay with different payload

```
Precondition:
- operation_id "return-001" already processed with quantity=5

Steps:
1. Call same operation_id with quantity=10
2. Verify error raised

Expected Result:
- Error: "Payload mismatch for idempotency key"
- outbox.status = 'CONFLICT'

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

## 3. Purchase Returns Tests (RPC: process_purchase_return)

### Test Case PRR-01: Full purchase return with credit

```
Precondition:
- Purchase PUR-001 received 50 units at cost 100 DZD/unit
- Supplier debt = 5000 DZD
- Device online

Steps:
1. Call process_purchase_return with items=[{product_id, quantity: 10}]
2. Verify purchase_returns row created
3. Verify stock reduced by 10 units
4. Verify supplier_ledger entry with negative amount
5. Verify supplier.current_debt reduced by 1000 DZD

Expected Result:
- Return record created
- Stock = original - 10
- Supplier debt reduced
- Credit method keeps debt reduction

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

### Test Case PRR-02: Purchase return with cash refund

```
Precondition:
- Same as PRR-01

Steps:
1. Call with refund_method="CASH"
2. Verify supplier_payments row created
3. Verify supplier_ledger PAYMENT entry
4. Verify supplier.current_debt updated

Expected Result:
- Payment record created
- Debt reduced by returned amount
- Proper accounting entries

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

### Test Case PRR-03: Return quantity exceeds available stock

```
Precondition:
- Only 5 units received in purchase
- Attempt to return 10 units

Steps:
1. Call process_purchase_return with quantity=10
2. Verify error

Expected Result:
- Exception: "Insufficient stock available for product % to return"

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

## 4. Stock Adjustment Tests (RPC: process_stock_adjustment)

### Test Case ADJ-01: Stock increase for lost/damaged items

```
Precondition:
- Product stock = 100 units
- Reason: "Found after inventory"

Steps:
1. Call process_stock_adjustment with adjustment_type="INCREASE", quantity=5
2. Verify stock_adjustments row created
3. Verify stock now = 105
4. Verify stock_movements type="ADJUSTMENT" created
5. Verify journal_entries created with CREDIT

Expected Result:
- Stock increased
- Proper journal entry (credit to inventory)
- Adjustment reason recorded

Actual Result: [تُملأ أثناء التنفيذ]
Status: ✅ PASS / ❌ FAIL
```

### Test Case ADJ-02: Stock decrease for damaged items

```
Precondition:
- Product stock = 100 units
- Device online

Steps:
1. Call process_stock_adjustment with adjustment_type="DECREASE", quantity=5
2. Verify stock_adjustments created
3. Verify stock = 95
4. Verify journal_entries created with DEBIT

Expected Result:
- Stock decreased
- Proper journal entry (debit to inventory expense)
- Reason required and recorded

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

### Test Case ADJ-03: Prevent negative stock adjustment

```
Precondition:
- Product stock = 3 units
- Attempt to decrease by 5 units

Steps:
1. Call process_stock_adjustment with quantity=5
2. Verify error raised

Expected Result:
- Exception: "Cannot decrease stock below zero"

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

### Test Case ADJ-04: Reason is required

```
Precondition:
- Device online

Steps:
1. Call process_stock_adjustment without reason
2. Verify error

Expected Result:
- Exception: "Reason for adjustment is required"

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

## 5. Inventory Expiry/Batch Tests

### Test Case INV-EXP-01: Check products expiring within 30 days

```
Precondition:
- Product with expiry_enabled=true
- Batch with expiry_date = NOW() + 15 days
- Device with reports.view permission

Steps:
1. Call check_inventory_expiry(store_id)
2. Verify returns products expiring soon

Expected Result:
- Returns list of products with expiry_date within 30 days
- Includes batch_number and quantity

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

### Test Case INV-LOW-01: Check low stock items

```
Precondition:
- Product with minimum_stock = 10
- Current available = 8
- Device with reports.view permission

Steps:
1. Call check_low_stock(store_id)
2. Verify returns low stock items

Expected Result:
- Returns products below minimum_stock threshold
- Shows current quantity vs minimum

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

## 6. Accounting Tests

### Test Case ACC-01: Double-entry balance validation

```
Precondition:
- After various business transactions
- Multiple journal entries created

Steps:
1. Query v_trial_balance
2. Verify total_debit = total_credit for each account
3. Verify sum of all balances = 0

Expected Result:
- Every journal entry has equal debit and credit
- Trial balance is balanced
- No orphaned entries

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

### Test Case ACC-02: Sale creates proper journal entries

```
Precondition:
- Sale of 1000 DZD cash, 50 DZD tax = 1050 DZD total
- COA has account 1200 (Inventory) and 4000 (Sales)

Steps:
1. Process sale via process_sale_invoice
2. Verify journal entry created
3. Verify ledger entries in general_ledger

Expected Result:
- Debit: Cash/Bank account
- Credit: Sales Revenue account
- Tax entry if applicable

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

### Test Case ACC-03: Return creates proper reversing entries

```
Precondition:
- After ACC-02, customer debt = 1050 DZD

Steps:
1. Process return via process_sale_return
2. Verify reversing ledger entries
3. Verify debt reduced

Expected Result:
- Credit: Sales Revenue (reverse)
- Debit: Customer account (reduce debt)

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

### Test Case ACC-04: Balance Sheet view accuracy

```
Precondition:
- Various transactions posted

Steps:
1. Query v_balance_sheet
2. Verify asset = liability + equity (accounting equation)

Expected Result:
- Balance sheet balances correctly
- No negative asset values outside normal range

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

## 7. Audit Logging Tests

### Test Case AUD-01: All critical operations logged

```
Precondition:
- Operations: sale, purchase, return, adjustment

Steps:
1. Perform each operation as user
2. Query audit_logs for user_id and store_id
3. Verify action, entity_type, entity_id recorded

Expected Result:
- Each operation creates audit_logs entry
- Contains user_id, store_id, action, entity info
- Cannot be modified/deleted by user

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

### Test Case AUD-02: Audit log protected by RLS

```
Precondition:
- Audit entry exists for store A

Steps:
1. Try to read audit_logs as user from store B
2. Try to modify audit_logs row

Expected Result:
- User cannot read other store's audit entries
- User cannot modify any audit entry

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

## 8. Security Tests

### Test Case SEC-01: Store isolation for returns

```
Precondition:
- Sale return exists in store A
- User from store B

Steps:
1. Try to read purchase_returns as user from store B
2. Try to create return for purchase from store A

Expected Result:
- User B cannot read return records from store A
- User B cannot create return for store A's purchase

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

### Test Case SEC-02: Permission enforcement for stock adjustment

```
Precondition:
- User with cashier role (no inventory.write permission)

Steps:
1. Call process_stock_adjustment
2. Verify error

Expected Result:
- Error 42501: "Missing permission: inventory.write"

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

### Test Case SEC-03: Cannot modify ledger directly

```
Precondition:
- General ledger entries exist

Steps:
1. Try to UPDATE general_ledger directly
2. Try to DELETE from journal_entries

Expected Result:
- RLS blocks direct write
- Only RPC functions can create/modify financial records

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

## 9. Concurrency Tests

### Test Case CONC-01: Concurrent stock adjustments

```
Precondition:
- Product stock = 100
- Device A and Device B attempt adjustment simultaneously

Steps:
1. Device A: increase 10 units
2. Device B: decrease 5 units (concurrently)
3. Verify one succeeds, one may conflict

Expected Result:
- No database race conditions
- Final stock = 105 (or 95 if different order)
- Both adjustments logged

Actual Result: [تُملأ أثناء التنفيط]
Status: ✅ PASS / ❌ FAIL
```

## 10. Integration Test Execution Order

1. Apply ATACK_PLUS_PHASE3_RETURNS_INVENTORY_ACCOUNTING.sql to clean database
2. Verify new tables exist
3. Verify new functions compile without errors
4. Verify new RLS policies are enforced
5. Run individual test cases above
6. Run concurrent test cases with multiple sessions
7. Verify audit log entries created for all operations

## 11. Environment Requirements

| Test Area | Required Environment |
|-----------|---------------------|
| SQLite Schema | SQLite 3.38+ with WAL mode |
| PostgreSQL Schema | PostgreSQL 15+ or Supabase |
| RPC Tests | Auth user with proper role |
| Concurrency Tests | Multiple database sessions |
| Integration Tests | Supabase staging project |

## 12. Test Execution Log Template

| ID | Environment | Test Steps | Expected | Actual | Status | Error Log |
|---|---|---|---|---|---|---|
| STR-01 | PostgreSQL | process_sale_return full | Stock +5, ledger | - | NOT RUN | - |
| PRR-01 | PostgreSQL | process_purchase_return | Debt reduced | - | NOT RUN | - |
| ADJ-01 | PostgreSQL | Stock increase | Stock +5, journal | - | NOT RUN | - |
| ACC-01 | PostgreSQL | Trial balance | Balanced | - | NOT RUN | - |
| SEC-01 | Supabase | Store isolation | Denied | - | NOT RUN | - |
| CONC-01 | PostgreSQL | Concurrent adj | No race | - | NOT RUN | - |

## 13. Production Deployment Checklist

Before deploying Phase 3 to production:

- [ ] Full PostgreSQL backup completed
- [ ] Staging environment tests: ALL PASS
- [ ] Test plan executed and logged
- [ ] RLS policies tested with real users
- [ ] Conflict resolution tested
- [ ] Audit logging verified
- [ ] Double-entry accounting verified
- [ ] Inventory adjustments verified
- [ ] Performance benchmarks recorded
- [ ] Rollback plan documented and tested

## 14. Verified Concurrent Returns and Stock Adjustments (2026-11-26)

Executed in the isolated PostgreSQL 16 CI database by
`tests/phase3-concurrency-returns-adjustments.sh`.

| Scenario | Verified result |
|---|---|
| Two simultaneous returns against separate invoices belonging to the same customer | PASS — both returns persisted; customer debt and credit remained correct; stock, return movements, customer ledgers and balanced journal entries reconciled |
| Two simultaneous stock adjustments against the same product (+10 and -5) | PASS — final quantity was 105; both adjustment records and stock movements persisted; both accounting journals balanced and reconciled to their ledger lines |

The return regression also validates that accounting allocation is read from the persisted result of the underlying return RPC, rather than from a stale pre-call customer-balance snapshot.

The first CI attempt exposed a fixture collision in generated adjustment numbers (the RPC derives its default number from the first eight UUID characters). The test was corrected to supply distinct explicit adjustment numbers. The final SQL workflow run passed, including both concurrency scenarios; the Supabase Auth integration workflow for the same test revision also passed.

Scope note: these results verify the two concurrency scenarios above in CI. They do not constitute staging or production acceptance, nor do they mark every Phase 3 test-plan item as executed.
