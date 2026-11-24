# ATACK PLUS --- تصميم المزامنة

## 1. نظرة عامة على التدفق

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Device A       │     │  Device B       │     │  Supabase     │
│  (SQLite)       │     │  (SQLite)       │     │  (PostgreSQL) │
└─────────────────┘     └─────────────────┘     └─────────────────┘
       │ │                       │ │                       │ │
       │ │                       │ │                       │ │
       ├─► Outbox PUSH ──────────┼─► Outbox PUSH ──────────┤
       │                         │                         │
       │ ◄─ Pull Changes ────────┼◄─ Pull Changes ────────┤
       │                         │                         │
       │ ◄─ Conflict ←───────────┼◄─ Conflict ←────────────┤
       │                         │                         │
       └─────────────────────────┴─────────────────────────┘
```

---

## 2. تدفق البيانات بين الأجهزة

### مرحلة 1: الحفظ المحلي (Local Save)

```
1. User Action → UI
2. Repository.insertInvoice()
3. BEGIN TRANSACTION (SQLite)
4. INSERT INTO invoices VALUES (...)
5. INSERT INTO invoice_items VALUES (...)
6. INSERT INTO stock_movements VALUES (...)
7. INSERT INTO customer_ledgers VALUES (...)
8. INSERT INTO sync_outbox (status = 'PENDING') VALUES (...)
9. INSERT INTO change_log VALUES (...)  ← sync_cursor = max
10. COMMIT TRANSACTION
11. Return success to user
```

### مرحلة 2: Push إلى Supabase

```
1. Background Sync Service يكتشف outbox غير مُزامن
2. لكل outbox item:
   a. BEGIN TRANSACTION (Supabase)
   b. SELECT FROM processed_operations WHERE operation_id = idempotency_key
   c. IF EXISTS → mark as DUPLICATE, UPDATE outbox.status = 'SYNCED'
   d. IF NOT EXISTS:
      - CALL process_sync_operation() [RPC Function]
      - INSERT INTO processed_operations (...)
      - UPDATE outbox.status = 'SYNCED'
   e. COMMIT
3. UPDATE sync_cursors.last_sync_seq = MAX(change_log.sync_cursor)
```

### مرحلة 3: Pull من Supabase

```
1. SELECT * FROM change_log 
   WHERE store_id = $store_id 
   AND sync_cursor > $last_cursor 
   ORDER BY sync_cursor ASC 
   LIMIT 100
   
2. لكل سجل:
   a. IF operation = 'INSERT':
      - ابحث عن التعارض
      - INSERT INTO جدول SQLite
   b. IF operation = 'UPDATE':
      - ابحث عن التعارض
      - UPDATE INTO جدول SQLite
   c. IF operation = 'DELETE':
      - حذف من SQLite أو INSERT INTO tombstones
   
3. UPDATE sync_cursors.last_sync_seq
```

---

## 3. Idempotency - معالجة التكرار

### 3.1 بنية Idempotency Key

```
UUID v7: 018f3b6e-7e3a-7b3f-a8e4-5c3b2a1d0e9f
│         │
│         └─ Timestamp portion (148 bits)
└─ Randomness portion (80 bits)
```

### 3.2 معالجة طلبين متزامنين

```
Device A sends operation_id = 018f3b6e...:
  Request 1: process_sync_operation(018f3b6e, {invoice_data: {...}})
  
  Request 1 arrives at Supabase:
    BEGIN TRANSACTION
      SELECT 1 FROM processed_operations WHERE operation_id = 018f3b6e
      → NOT FOUND
      INSERT INTO invoices ... (transaction 1)
      INSERT INTO processed_operations (operation_id = 018f3b6e, ...)
    COMMIT
    → Result: SUCCESS, applied = TRUE
  
  Request 2 arrives (concurrent):
    BEGIN TRANSACTION
      SELECT 1 FROM processed_operations WHERE operation_id = 018f3b6e
      → FOUND (by Request 1)
    ROLLBACK
    → Result: DUPLICATE, applied = FALSE
```

### 3.3 معالجة تغيير المحتوى مع الحفاظ على idempotency_key

```
Scenario: Two different payloads with same operation_id

Request 1: operation_id = abc123, payload = {amount: 1000}
Request 2: operation_id = abc123, payload = {amount: 1500}

Result after Request 1 processes:
  - processed_operations.operation_id = abc123
  - payload_hash = SHA256("{amount: 1000}")

Request 2 arrives:
  - operation_id = abc123 EXISTS in processed_operations
  - Compare payload_hash:
    - NEW: SHA256("{amount: 1500}") ≠ OLD: SHA256("{amount: 1000}")
  - RETURN: CONFLICT_DETECTED, error = "Payload mismatch for idempotency key"
  - Status: outbox.status = 'CONFLICT'
```

---

## 4. Change Log المركزي

### 4.1 بنية change_seq

```
change_log.id (BIGSERIAL)
├── 1: INSERT invoice INV-001
├── 2: INSERT invoice INV-002
├── 3: UPDATE stock product-1 quantity -5
├── 4: INSERT customer_payment PAY-001
└── ...
```

### 4.2 عدم تخطي التغييرات

```
Device A متصل:
  - sync_cursor = 100
  - Pull changes WHERE sync_cursor > 100
  - Sync cursor = 120
  - UPDATE sync_cursors SET last_sync_seq = 120

Device A ينهار أثناء Pull (بين السطر 50 و 100):
  - Device A يبدأ من جديد مع sync_cursor = 100
  - لا يفقد أي تغييرات
  - Supabase لا يحذف التغييرات حتى 30 يوم
```

### 4.3 Pagination و Pull

```
Initial Pull:
  SELECT * FROM change_log
  WHERE store_id = $store_id AND sync_cursor > $last_cursor
  ORDER BY sync_cursor ASC
  LIMIT 100

Response:
  - records: [change1, change2, ...]
  - last_sync_seq: 150
  - device ACK: {"last_processed": 150}

Device ACK:
  UPDATE sync_cursors 
  SET last_sync_seq = 150, last_sync_at = NOW()
  WHERE device_id = 'device-a' AND store_id = $store_id
```

### 4.4 استكمال المزامنة بعد الانقطاع

```
Device A يعيد التشغيل بعد انقطاع:
  - يقرأ sync_cursors.last_sync_seq = 100
  - يبدأ Pull من sync_cursor = 101
  - Supabase يرسل جميع التغييرات المفقودة
  - يتم معالجة جميع التغييرات
  - sync_cursors يُحدّث لتصل إلى 200
```

---

## 5. Conflict Resolution Rules

### 5.1 قواعد المنتجات والأسعار

| الحالة | القاعدة | السلوك |
|--------|---------|--------|
| اسم المنتج يتغير | MERGE | اختيار الإصدار الأحدث |
| الوحدات تتغير | MERGE | دمج جميع الوحدات المتوفرة |
| سعر البيع يتغير | PRESERVE | الاحتفاظ بالأقدم (أكثر أماناً) |
| صورة المنتج | REJECT | إبقاء الصورة الأصلية |

### 5.2 قواعد الفواتير والمرتجعات

| الحالة | القاعدة | السلوك |
|--------|---------|--------|
| رقم فاتيرة مكرر | REJECT | رفض الفاتورة الجديدة |
| حالة فاتلة متغيرة | VALIDATE | فقط تسمح بالتحديثات الصلاحة |
| مرتجع مرتبط بفاتلة محذوفة | PREVENT | يجب استرجاع الفاتلة أولاً |
| إلغاء فاتلة موجودة | REJECT | الفاتورة الكاملة لا يمكن إلغاؤها |

### 5.3 قواعد المخزون

| الحالة | القاعدة | السلوك |
|--------|---------|--------|
| مخزون متغير | CONFLICT_ALERT | إشعار للمدير |
| حركة مخزون مكررة | REJECT | فقط حركة واحدة مسموحة |
| تعديل مخزون يدوي | VALIDATE | يجب سبب وتوثيق |
| مخزون سالب | PREVENT | منع العملية أثناء المزامنة |

### 5.4 قواعد الديون والتسديدات

| الحالة | القاعدة | السلوك |
|--------|---------|--------|
| دين متغير | CONFLICT_ALERT | إشعار للمدير |
| تسديد مكرر | REJECT | idempotency_key يمنع التكرار |
| تسديد على فاتلة ملغاة | REJECT | الفاتلة غير صالحة |
| رصيد زائد | RECORD | تسجيل الرصيد الزائد كـ "overpayment" |

---

## 6. Tombstones Management

### 6.1 دورة حياة Tombstone

```
CREATE → SYNCED → Retained(30 days) → ARCHIVE → DELETE

Timeline:
Day 0:   DELETE operation → INSERT INTO tombstones
Day 1-29: Syced to all devices
Day 30:  Tombstone محذوف من PostgreSQL (تخزين محدود)
         لكن يبقى في SQLite على جهاز الاحتفاظ (30 يوم)
```

### 6.2 جهاز غير متصل لفترة طويلة

```
Device C متصل بعد 45 يوم من الفشل:
  1. يطلب Full Sync
  2. PostgreSQL لا يحتوي على tombstones قديمة (> 30 يوم)
  3. Device C يطلب sync_full_data = true
  4. يتم إرسال qائمة BY_ID لكل جدول
  5. Device C يحذف السجلات المفقودة محلياً
```

### 6.3 متى تكون إعادة المزامنة الكاملة إلزامية؟

```
Full Sync مطلوب عند:
1. sync_cursors.last_sync_seq > MAX(change_log.id) - 30_days
2. اختلاف عدد السجلات بين SQLite و PostgreSQL > 10%
3. Device جديد يبدأ من الصفر
4. استعادة بعد فقدان نسخة احتياطية
```