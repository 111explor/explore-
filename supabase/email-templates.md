# قوالب الإيميل (Supabase ← Authentication ← Emails ← Templates)

الموقع بيطلب من الزبون **رمز من 6 أرقام**، فلازم الإيميل يحتوي `{{ .Token }}`.

## Confirm signup (تأكيد الحساب)
**Subject:**
```
رمز تأكيد حسابك بـ Explor Plus: {{ .Token }}
```
**Body:**
```html
<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;max-width:480px;margin:auto;padding:24px;background:#0c0e13;color:#f3f5f9;border-radius:16px">
  <h2 style="margin:0 0 8px">أهلاً فيك بـ Explor Plus 👋</h2>
  <p style="color:#c9cfdb">رمز تأكيد حسابك:</p>
  <p style="font-size:34px;letter-spacing:8px;font-weight:bold;text-align:center;background:#171b24;border-radius:12px;padding:14px;margin:16px 0;color:#ffffff">{{ .Token }}</p>
  <p style="color:#8d95a8;font-size:13px">اكتبه بصفحة التسجيل. إذا ما طلبت إنت هالحساب، تجاهل هالرسالة.</p>
</div>
```

## Reset Password (نسيت كلمة السر)
**Subject:**
```
رمز تغيير كلمة السر: {{ .Token }}
```
**Body:**
```html
<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;max-width:480px;margin:auto;padding:24px;background:#0c0e13;color:#f3f5f9;border-radius:16px">
  <h2 style="margin:0 0 8px">تغيير كلمة السر 🔑</h2>
  <p style="color:#c9cfdb">رمز تغيير كلمة السر:</p>
  <p style="font-size:34px;letter-spacing:8px;font-weight:bold;text-align:center;background:#171b24;border-radius:12px;padding:14px;margin:16px 0;color:#ffffff">{{ .Token }}</p>
  <p style="color:#8d95a8;font-size:13px">إذا ما طلبت إنت تغيير كلمة السر، تجاهل هالرسالة وحسابك بأمان.</p>
</div>
```
