#!/usr/bin/env bash
# Explor Plus: نسخة احتياطية مشفّرة لقاعدة البيانات + اختبار استعادة حقيقي
#
# بيعمل:
#   1) نسخة كاملة (الجداول + الحسابات + بيانات الملفات) من Supabase بـ pg_dump
#   2) بيرجّعها على قاعدة فاضية وبيتأكد إنه عدد الحسابات والطلبات والحركات… طابق
#   3) بيفحص إنه رصيد كل زبون = مجموع حركاته بالمحفظة
#   4) بيشفّر النسخة (AES-256) عشان الريبو عام، وبيمسح النسخة غير المشفّرة
#   5) (اختياري) بيبعتلك النتيجة على تلجرام
#
# المتغيرات: SUPABASE_DB_URL  BACKUP_PASSPHRASE  RESTORE_DB_URL  [TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID]
# فك التشفير: openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in FILE.dump.enc -out FILE.dump
set -euo pipefail

OUT="${1:-backup}"
mkdir -p "$OUT"
STAMP="$(date -u +%Y%m%d-%H%M)"
DUMP="$OUT/explorplus-$STAMP.dump"
STATUS="❌ فشلت"
DETAILS=""

notify() {
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -fsS -o /dev/null "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=💾 النسخة الاحتياطية اليومية: ${STATUS}${DETAILS}" || true
  fi
}
cleanup() { rm -f "$DUMP"; notify; }
trap cleanup EXIT

: "${SUPABASE_DB_URL:?SUPABASE_DB_URL missing}"
: "${BACKUP_PASSPHRASE:?BACKUP_PASSPHRASE missing}"
: "${RESTORE_DB_URL:?RESTORE_DB_URL missing}"

COUNTS="
select 'auth.users', count(*) from auth.users
union all select 'profiles', count(*) from public.profiles
union all select 'products', count(*) from public.products
union all select 'stock_items', count(*) from public.stock_items
union all select 'orders', count(*) from public.orders
union all select 'topups', count(*) from public.topups
union all select 'wallet_tx', count(*) from public.wallet_tx
union all select 'reports', count(*) from public.reports
order by 1"

echo "== 1) counts before backup"
psql "$SUPABASE_DB_URL" -X -At -F ' ' -c "$COUNTS" > "$OUT/before.txt"

echo "== 2) pg_dump"
pg_dump "$SUPABASE_DB_URL" -Fc --no-owner --no-privileges \
  --schema=public --schema=auth --schema=storage \
  --exclude-table-data='public.site_presence' \
  -f "$DUMP"
psql "$SUPABASE_DB_URL" -X -At -F ' ' -c "$COUNTS" > "$OUT/after.txt"

echo "== 3) restore into an empty database"
psql "$RESTORE_DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated','service_role','authenticator','supabase_auth_admin',
                           'supabase_storage_admin','supabase_admin','dashboard_user','pgbouncer'] loop
    if not exists (select 1 from pg_roles where rolname = r) then execute format('create role %I nologin', r); end if;
  end loop;
end $$;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
SQL
# بعض أجزاء Supabase الداخلية (pg_net, pg_cron…) مش موجودة بقاعدة الاختبار، فأخطاؤها متوقعة.
# المهم إنه البيانات ترجع كاملة، وهاد اللي بنفحصه تحت.
pg_restore --no-owner --no-privileges -d "$RESTORE_DB_URL" "$DUMP" > "$OUT/restore.log" 2>&1 || true
echo "restore warnings: $(grep -c 'error' "$OUT/restore.log" || true)"

echo "== 4) compare"
psql "$RESTORE_DB_URL" -X -At -F ' ' -c "$COUNTS" > "$OUT/restored.txt"
FAIL=0
while read -r name restored; do
  b=$(awk -v n="$name" '$1==n{print $2}' "$OUT/before.txt")
  a=$(awk -v n="$name" '$1==n{print $2}' "$OUT/after.txt")
  lo=$(( b < a ? b : a )); hi=$(( b > a ? b : a ))
  if [ -z "$b" ] || [ "$restored" -lt "$lo" ] || [ "$restored" -gt "$hi" ]; then
    echo "MISMATCH $name"; FAIL=1
  else
    echo "ok $name"
  fi
done < "$OUT/restored.txt"

# كل رصيد لازم يساوي مجموع حركات المحفظة (إذا لا: في تعديل مباشر على الرصيد)
MISMATCH_BAL=$(psql "$RESTORE_DB_URL" -X -At -c "
  select count(*) from public.profiles p
  where p.balance <> coalesce((select sum(amount) from public.wallet_tx t where t.user_id = p.id), 0)")
echo "balance/ledger mismatches: $MISMATCH_BAL"

rm -f "$OUT/before.txt" "$OUT/after.txt" "$OUT/restored.txt" "$OUT/restore.log"
if [ "$FAIL" -ne 0 ]; then DETAILS=$'\nالاستعادة ما رجّعت كل البيانات. افتح GitHub Actions.'; exit 1; fi

echo "== 5) encrypt"
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -in "$DUMP" -out "$DUMP.enc" -pass env:BACKUP_PASSPHRASE
SIZE=$(du -h "$DUMP.enc" | cut -f1)
STATUS="✅ تمت، واختبار الاستعادة نجح"
DETAILS=$'\n'"الحجم: $SIZE (مشفّرة)"
if [ "$MISMATCH_BAL" != "0" ]; then DETAILS="$DETAILS"$'\n'"⚠️ في $MISMATCH_BAL حساب رصيده مش مطابق لحركات المحفظة"; fi
echo "done: $DUMP.enc ($SIZE)"
