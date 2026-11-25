# ATACK PLUS — Phase 2 RPC Integration Guide

## Apply order

1. Create a disposable PostgreSQL 15+ / Supabase staging project.
2. Apply `POSTGRES_SCHEMA_PHASE1_FIXED.sql` to an empty database.
3. Apply `ATACK_PLUS_PHASE2_BUSINESS_RPCS.sql`.
4. Run the Phase 2 test matrix in `TEST_PLAN_PHASE2_UPDATED.md` before connecting Flutter.

Do not apply this migration to production before a full backup and staging validation.

## Supabase RPC calls

All UUIDs must be generated once and persisted in the local SQLite outbox. Reuse the same `operation_id`, entity `id`, and exact payload for every retry. Do not generate new UUIDs on retry.

### 1. Sale

RPC: `process_sale_invoice`

Arguments:
- `p_store_id`: store UUID associated with the authenticated user.
- `p_operation_id`: stable UUID for this business operation.
- `p_payload`: example:

```json
{
  "id": "11111111-1111-4111-8111-111111111111",
  "invoice_number": "INV-000001",
  "customer_id": "22222222-2222-4222-8222-222222222222",
  "invoice_date": "2026-11-22T10:00:00Z",
  "location_id": "main",
  "paid_amount": 100.0000,
  "payment_method": "CASH",
  "items": [
    {
      "id": "33333333-3333-4333-8333-333333333333",
      "product_id": "44444444-4444-4444-8444-444444444444",
      "quantity": 2,
      "unit_id": "carton",
      "unit_price": 75.0000,
      "discount_amount": 0,
      "tax_rate": 0
    }
  ]
}
```

A credit balance requires `customer_id`. A sale without a customer must be fully paid in this RPC version. Quantity is converted to the product's primary unit on the server. If available stock is insufficient, the entire transaction rolls back.

### 2. Purchase

RPC: `process_purchase`

Payload fields: `id`, `purchase_number`, `supplier_id`, optional `purchase_date`, `location_id`, `paid_amount`, `payment_method`, `notes`, and non-empty `items[]`. Each item requires `product_id`, `quantity`, `unit_id`, and `unit_price`; `cost_per_unit`, `tax_rate`, batch and expiry are optional.

The server calculates totals, receives the quantities into stock, writes movements and supplier ledger entries, and records an optional supplier payment atomically.

### 3. Partial purchase receiving

The purchase RPC accepts an optional `received_quantity` on each item. If omitted, it defaults to the ordered quantity for backward compatibility. Set it to zero to create an order without receiving stock, or to a value between zero and the ordered quantity for an initial partial receipt.

For each later receipt, call `process_purchase_receipt`:

- `p_store_id`: authenticated user's store UUID.
- `p_operation_id`: stable UUID for this receipt operation.
- `p_payload`: `{id, purchase_id, location_id?, items:[{purchase_item_id, quantity}]}`.

The RPC requires `purchases.receive`. It locks the purchase and purchase lines, rejects quantities above the outstanding amount, updates `purchase_items.received_quantity`, stock, stock movements, weighted average cost, and `purchases.receiving_status` atomically. Replaying the same operation ID and payload is safe.

Receiving status is tracked independently from payment status:
- `PENDING`: no line quantity received.
- `PARTIAL`: at least one quantity received and at least one line remains outstanding.
- `COMPLETE`: every purchase line is fully received.
- `CLOSED`: reserved for a future explicit close-remaining operation; not set by this RPC.

### 4. Receiving, rejected goods, excess and substitute products

Every later receipt is stored as a separate `purchase_receipts` record with its own `purchase_receipt_items`. The initial quantity received during purchase creation is also recorded. Each line preserves ordered, accepted, excess and rejected quantities separately.

`process_purchase_receipt` item fields:
- `purchase_item_id`, `accepted_quantity`: accepted quantity against the ordered amount.
- `rejected_quantity`, `rejection_reason`, `packaging_condition`, `photo_paths`: rejected goods remain in the receipt record but do not enter saleable stock or count as received.
- `excess_quantity`, `excess_reason`: requires `purchases.receive_excess` and `approved_by`; approved excess enters stock and adjusts purchase value and supplier debt.
- `substitute_product_id`, `substitute_reason`, `substitute_cost_per_unit`, `substitute_unit_price`: requires `purchases.receive_substitute` and `approved_by`; only the approved substitute enters stock, and the purchase value is adjusted to the substitute price.
- `location_id` selects the receiving stock location.

Use `process_purchase_close_remaining` to close outstanding quantities that cannot be supplied. It requires `purchases.close_remaining`, a reason, and item quantities. Closed quantities never enter stock and are preserved with the user, date, and reason. The purchase is marked `CLOSED_PARTIAL`.

Use `process_purchase_amendment` to amend a purchase after receipt. It requires `purchases.edit_after_receipt`, a reason, and the purchase item changes. It records old/new values, adjusts supplier debt and totals atomically, and rejects a new ordered quantity below the already received plus closed quantity. Existing receipt and return records are never rewritten.

For a return against a specific receipt (especially a substitute or excess line), pass `purchase_receipt_item_id` in the `process_purchase_return` item. This ensures the actual received product, cost, unit, and quantity cap are used. Returns can be made before all ordered quantities are received, but never exceed the accepted quantity on the selected receipt line.

### 5. Customer payment

RPC: `process_customer_payment`

Payload fields: `id`, `customer_id`, `amount`, `payment_method`, optional `reference_no`, `notes`, and optional `allocations[]` (`invoice_id`, `amount`). Explicit allocations are applied first; any remainder is allocated FIFO to the customer's oldest outstanding sale invoices. If the whole payment cannot be allocated, the transaction is rejected. Payments larger than current debt are rejected in this version.

### 6. Supplier payment

RPC: `process_supplier_payment`

Payload fields: `id`, `supplier_id`, `amount`, `payment_method`, optional `reference_no`, and `notes`. The payment must not exceed current supplier debt.

## Idempotency response

- First successful execution returns `success=true` and `replayed=false`.
- Exact retry returns `success=true` and `replayed=true` without duplicating business rows or movements.
- Reusing an operation UUID with a different payload or a different RPC name is rejected.

## Important constraints

- The RPCs require a Supabase-authenticated user with membership in the supplied store and the matching RBAC permission.
- Never put the Supabase `service_role` key in Android, Windows, or any client application.
- Do not call direct INSERT/UPDATE on invoices, purchases, payments, ledgers, stock or stock movements from Flutter.
- This release does not yet implement sales returns, purchase returns, expenses/revenues, stock transfers, partial GRN receiving, or offline stock reservation between devices.
- Audit logging for all business RPCs remains a production-readiness task.
- PostgreSQL execution and concurrency tests are still required; static review is not runtime validation.
