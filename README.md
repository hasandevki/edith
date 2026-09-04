# Edith

Ray-Ban Meta (Gen 2) gözlüğü için kişisel sesli asistan. iPhone'da çalışır,
gözlüğün kamerasını ve mikrofonunu Meta'nın resmi **Wearables Device Access
Toolkit** SDK'sı üzerinden kullanır, beynini Claude'dan alır.

Döngü: **"Edith" de → soruyu sor → o anki kare + soru Claude'a gider → cevap
gözlüğün hoparlöründen okunur.**

## Mimari

```
Gözlük  --Bluetooth-->  Edith (iPhone, bu uygulama)  --HTTPS-->  Claude API
  kamera + mikrofon        Apple konuşma tanıma (tr-TR)
  hoparlör                 Apple seslendirme (tr-TR)
                           Meta AI uygulaması arka planda izin köprüsü
```

Kod gözlükte değil telefonda çalışır; gözlük SDK'ya kamera akışı, fotoğraf ve
Bluetooth ses verir. Gözlüğün fiziksel tuşu ve "Hey Meta" dokunulmadan Meta'da
kalır.

## Dosyalar

| Dosya | İş |
|---|---|
| `project.yml` | XcodeGen proje tanımı (CI'da `.xcodeproj` üretir) |
| `.github/workflows/build.yml` | GitHub'ın macOS sunucusunda derler, imzasız IPA üretir |
| `Edith/Info.plist` | İzin metinleri, arka plan modları, Meta SDK ayarları, `edith://` şeması |
| `Edith/Sources/Glasses/GlassesManager.swift` | Meta AI kaydı, oturum, kamera akışı, son kare |
| `Edith/Sources/Audio/SpeechListener.swift` | Sürekli konuşma tanıma (tr-TR), uyandırma kelimesi için |
| `Edith/Sources/Audio/Speaker.swift` | Cümle cümle seslendirme |
| `Edith/Sources/Brain/ClaudeClient.swift` | Claude Messages API, akış (SSE), görüntü + metin |
| `Edith/Sources/Brain/EdithController.swift` | Durum makinesi: dinle → uyan → gör → düşün → konuş |
| `Edith/Sources/Brain/Conversation.swift` | Geçmiş ve Edith'in kişiliği (sistem promptu) |

## Kurulum (Mac olmadan)

### 1. Meta AI uygulamasında Developer Mode

Meta AI → Ayarlar → Uygulama Bilgisi → sürüm numarasına 5 kez dokun →
Developer Mode → Aç. **Gözlük firmware güncellemesinden sonra bu ayar
kapanır**, tekrar aç. Meta AI uygulaması güncel olsun (iOS 26 ile eski
sürümlerde akış başlamıyor).

### 2. iPhone'da Developer Mode

Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu → Aç (yeniden başlatır).
Yandan yüklenen uygulamalar için gerekli.

### 3. GitHub'a yükle ve derlet

```bash
cd edith
git init
git add .
git commit -m "Edith v0.1"
```

GitHub'da yeni bir repo aç (public önerilir: macOS derleme dakikaları ücretsiz
ve sınırsız; private repoda macOS dakikaları 10 kat sayılır). Sonra:

```bash
git remote add origin https://github.com/KULLANICI/edith.git
git push -u origin main
```

Push ile **Actions** sekmesinde "Build Edith IPA" çalışır (ilk sefer 10-15 dk).
Bitince aynı sayfanın altındaki **Artifacts** kısmından `Edith-unsigned-ipa`
dosyasını indir, zip'i aç → `Edith-unsigned.ipa`.

Derleme kırmızıysa `build-log` artifact'ini indir ve `build.log` dosyasını
bu klasöre koy; hata oradan okunup düzeltilir.

### 4. Windows'tan iPhone'a yükle (Sideloadly, ücretsiz Apple ID)

1. Apple'ın sitesinden **iTunes** (Microsoft Store sürümü değil) veya
   **Apple Devices** uygulamasını kur. iPhone'u USB ile bağla, "Güven" de.
2. [Sideloadly](https://sideloadly.io) kur ve aç.
3. `Edith-unsigned.ipa` dosyasını Sideloadly'ye sürükle, cihaz olarak iPhone'u
   seç, Apple ID'ni gir (Apple ID şifreni sadece sen girersin; Sideloadly
   imzalama için kullanır), **Start**.
4. iPhone: Ayarlar → Genel → VPN ve Aygıt Yönetimi → Apple ID'n → **Güven**.

Ücretsiz Apple ID ile imza **7 gün** geçerli. Süre dolunca Sideloadly ile aynı
IPA'yı tekrar yükle (ayarlar ve API anahtarı silinmez). Aynı anda en fazla 3
yandan yüklenmiş uygulama olabilir.

Not: Ücretsiz imzada Wi-Fi yetkileri (HotspotConfiguration / wifi-info) düşer;
kamera akışı Bluetooth üzerinden gelir (SDK'nın belgelenen sınırı zaten 720p).
İleride ücretli Apple Developer hesabı olursa aynı proje TestFlight ile
yüklenir ve Wi-Fi aktarımı da açılır.

### 5. İlk açılış

1. **Ayarlar** (dişli) → **API anahtarı**: console.anthropic.com'dan alınan
   `sk-ant-...` anahtarını yapıştır. **API'yi dene** ile doğrula.
2. **Ses**: iPhone Ayarlar → Erişilebilirlik → Sesli İçerik → Sesler → Türkçe →
   **Yelda (Geliştirilmiş)** indir; sonra Edith ayarlarından seç. **Sesi dene**.
3. Ana ekran → **Gözlüğü bağla**: Meta AI açılır, onayla, Edith'e döner.
4. **Gözleri aç**: ilk seferde Meta AI kamera izni ister, onayla. Küçük
   önizlemede gözlüğün gördüğü kare belirir (gözlüğün LED'i yanar, bu normal).
5. **Dinlemeyi başlat**: mikrofon ve konuşma tanıma izinlerini ver.
6. Söyle: **"Edith, önümde ne var?"**

Test için ses olmadan yazarak da sorabilirsin ("Yazarak sor" kutusu).

## Kullanım notları

- **Uyandırma:** "Edith" (Ayarlar'dan değiştirilebilir). Konuşma tanıma
  "Edit" diye de duyabilir; ikisi de kabul edilir.
- **Araya girme:** Edith konuşurken "Edith" dersen susar ve yeni soruyu dinler.
- **Gözlük sapına tek dokunuş:** akış açıkken kamerayı duraklatır/devam
  ettirir. Basılı tutmak oturumu kapatır. Bunlar gözlüğün kendi davranışı.
- **Arka plan:** telefon cepteyken de çalışır (ses modu). Uygulamayı kaydırıp
  kapatırsan durur.
- **Pil:** kamera akışı gözlüğün pilini hızlı bitirir. Kullanmadığında
  "Gözleri kapat".
- **Kayıtlar:** sol üstteki liste simgesi; sorun olursa paylaş simgesiyle
  günlüğü dışa aktar.

## Sorun giderme

| Belirti | Sebep / çözüm |
|---|---|
| Kamera "cihaz bekleniyor"da takılı | Meta AI'da Developer Mode kapalı (firmware sonrası kapanır). Aç, gözlüğü kutuya koyup çıkar. |
| Akış: başlıyor → duruyor → kapalı | Meta AI uygulaması eski. Güncelle, Developer Mode'u kapatıp aç. |
| Kayıt hatası | Meta AI kurulu ve giriş yapılmış mı? Gözlük Meta AI'da eşleşmiş mi? |
| Mikrofon gözlükten değil telefondan | Gözlük Bluetooth'ta "bağlı" olmalı; Kayıtlar'da "Rota" satırına bak (bluetoothHFP olmalı). |
| Edith kendi sesini duyup uyanıyor | Ses modunda yankı bastırma var; yine olursa konuşma hızını düşür veya sesi kıs. |
| 7 gün sonra açılmıyor | Sideloadly ile yeniden yükle. |
