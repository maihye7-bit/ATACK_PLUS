# ATACK PLUS --- حل التعارضات

## 1. مبدأ عدم استخدام Last Write Wins

**لا يُسمح بـ Last Write Wins في أي من:**
- أرقام الفواتير
- المخزون
- الديون والتسديدات
- حركات المالية

---

## 2. تصنيفات التعارض

```
ConflictType
├── INVENTORY    → تعارض في المخزون
├── INVOICE      → تعارض في الفاتورة
├── CUSTOMER_DEBTS → تعارض في ديون العميل
├── SUPPLIER_DEBTS → تعارض في ديون المورد
├── PRICE        → تعارض في الأسعار
└── DUPLICATE    → فاتورة/عملية مكررة
```

---

## 3. قواعد حل التعارض لكل فئة

### 3.1 المنتجات والأسعار

| الحالة | القاعدة | الخطوات |
|--------|---------|----------|
| اسم المنتج متغير | MERGE | 1. استخدم أحدث الإصدار<br>2. سجّل التغيير في audit_log |
| سعر جملة متغير | VALIDATE | 1. رفض التغيير غير المصرّح به<br>2. طلب موافقة المدير |
| وحدات التحويل متغيرة | MERGE | 1. دمج جميع الوحدات الجديدة<br>2. حفظ جميع التحويلات |
| صورة المنتج متغيرة | REJECT | 1. رفض التغيير<br>2. الاحتفاظ بالأصل |

### 3.2 الفواتير

| الحالة | القاعدة | الخطوات |
|--------|---------|----------|
| رقم فاتلة مكرر | REJECT | 1. رفض الفاتلة الجديدة<br>2. إرجاع خطأ: "رقم الفاتلة مكرر: XXX" |
| إجمالي الفاتلة متغير | CONFLICT_ALERT | 1. إشعار للمدير<br>2. عرض الفرق<br>3. اختيار الإصدار الأحدث |
| حالة الفاتلة متغيرة | VALIDATE | 1. فقط تحديثات صلاحية مسموحة<br>2. مثال: DRAFT → OPEN |
| حذف فاتيلة مفتوطة | PREVENT | 1. إبقاء الفاتلة موجودة<br>2. إلغاء العملية بدلاً من الحذف |

### 3.3 المخزون

| الحالة | القاعدة | الخطوات |
|--------|---------|----------|
| كمية متغيرة من جهازين | CONFLICT_ALERT | 1. اكتشاف: stock_A = 95, stock_B = 97, expected = 92<br>2. إشعار للمدير<br>3. عرض جميع الفاتاتير/المشتريات |
| حركة مخزون مكررة | REJECT | 1. فحص idempotency_key<br>2. رفض العملية الثانية |
| مخزون سالب | PREVENT | 1. منع العملية أثناء المزامنة<br>2. إظهار تحذير للمستخدم |
| تعديل مخزون يدوي | VALIDATE | 1. سبب مطلوب<br>2. توثيق بالمستخدم |

### 3.4 الديون والتسديدات

| الحالة | القاعدة | الخطوات |
|--------|---------|----------|
| دين متغير | CONFLICT_ALERT | 1. إشعار للمدير<br>2. عرض جميع التسديدات المعلقة |
| تسديد مكرر | REJECT | 1. فحص idempotency_key<br>2. إرجاع "العملية مكررة" |
| تسديد على فاتلة ملغاة | REJECT | 1. التحقق من حالة الفاتلة<br>2. رفض التسديد |
| رصيد زائد (overpayment) | RECORD | 1. تسجيل الرصيد الزائد<br>2. خيار: استرداد أو احتفاظ كرصيد |

### 3.5 المشتريات والموردين

| الحالة | القاعدة | الخطوات |
|--------|---------|----------|
| مشتراة مكرر | REJECT | 1. فحص رقم المشتراة فريد<br>2. رفض أو ربط بالمشتراة الموجود |
| ديون المورد متغيرة | CONFLICT_ALERT | 1. إشعار للمدير<br>2. توثيق الحركة المالية |

### 3.6 المرتجعات

| الحالة | القاعدة | الخطوات |
|--------|---------|----------|
| مرتجع مكرر | REJECT | 1. فحص rma_number فريد<br>2. رفض المرتجع الثاني |
| مرتجع على فاتلة ملغاة | PREVENT | 1. استرجاع الفاتلة أولاً |
| مرتجع ينقص مخزون غير كافي | PREVENT | 1. التحقق من المخزون قبل المرتجع |

---

## 4. خوارزمية حل التعارض التفصيلية

```dart
class ConflictResolver {
  ConflictResolutionResult resolve(
    String tableName,
    String recordUuid,
    Map<String, dynamic> localData,
    Map<String, dynamic> remoteData,
  ) {
    switch (tableName) {
      case 'invoices':
        return _resolveInvoiceConflict(localData, remoteData);
      case 'stock_movements':
        return _resolveStockConflict(localData, remoteData);
      case 'customer_ledgers':
        return _resolveDebtConflict(localData, remoteData);
      case 'products':
        return _resolveProductConflict(localData, remoteData);
      default:
        return ConflictResolutionResult.pending(
          reason: 'Unknown table type: $tableName',
        );
    }
  }

  ConflictResolutionResult _resolveStockConflict(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) {
    // لا نستخدم Last Write Wins
    final localQty = local['quantity'] as int;
    final remoteQty = remote['quantity'] as int;
    
    if (localQty == remoteQty) {
      return ConflictResolutionResult.acceptLocal(); // لا تعارض
    }
    
    // حفظ كل العمليات المتعارضة
    _saveConflictingOperations(local, remote);
    
    return ConflictResolutionResult.conflictAlert(
      reason: 'Stock conflict: local=$localQty, remote=$remoteQty',
      options: ['accept_local', 'accept_remote', 'merge'],
    );
  }
}
```

---

## 5. تخزين التعارضات

```sql
-- كل تعارض يُحفظ كسجل
INSERT INTO sync_conflicts (
    store_id, table_name, record_uuid, conflict_type,
    local_record_json, remote_record_json,
    resolution_notes
) VALUES (
    $store_id, $table_name, $record_uuid, $conflict_type,
    $local_json, $remote_json,
    'Detected during sync cycle at ' || NOW()
);

-- التعارض يُبقى حتى يحله المدير
-- لا يتم حذفه أو تغييره بصفة تلقائية
```

---

## 6. سيناريوهات اختبار حل التعارض

### سيناريو 1: بيع آخر كمية من جهازين

```
Step 1: Device A - Stock = 100, sells 5 → Stock = 95
        INSERT INTO sync_outbox (record_uuid = 'om-001', content = {qty: 95})

Step 2: Device B - Stock = 100, sells 3 → Stock = 97  
        INSERT INTO sync_outbox (record_uuid = 'om-002', content = {qty: 97})

Step 3: Sync يبدأ من Device A
        - SYNCED to Supabase: Stock = 95
        - change_seq = 100

Step 4: Sync يبدأ من Device B
        - INSERT INTO supabase.stock VALUES (qty = 97)
        - CONFLICT DETECTED: expected 95, got 97
        - INSERT INTO sync_conflicts (...)
        - Email/SMS notification to manager

Step 5: Manager reviews:
        - Shows: "Device A sold 5 units (stock: 95)"
        - Shows: "Device B sold 3 units (stock: 97)"
        - Options: Accept 92 (merge), Accept 95, Accept 97

Step 6: Manager chooses "Accept 92":
        - Stock updated to 92
        - OUTBOX 2 marked as CONFLICTED
        - sync_conflicts.resolution_status = 'ACCEPT_REMOTE'
```

### سيناريو 2: المرتجعات مع التعارض

```
Device A: Return 2 units → Stock: 80 → 82
Device B: Return 1 unit → Stock: 79 → 80

Sync Sequence:
  1. Device A SYNCED → stock = 82
  2. Device B SYNCED → CONFLICT → stock expected 82, got 80
  3. Conflict resolution: MERGE → stock = 81 (توزيع المخزون)
```

### سيناريو 3: ديون العملاء

```
Customer Debt: 1000 DZD

Device A: Collect 300 DZD → Debt: 700
Device B: Collect 200 DZD → Debt: 800

Conflict:
  - Expected: 500
  - Device A: 700
  - Device B: 800
  
Resolution: 
  - SHOW BOTH Transactions to customer
  - Accept 500 (sum of collections)
  - Record "overpayment": 300 DZD
```