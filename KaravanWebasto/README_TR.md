# Karavan Webasto — iPhone HeatGenie/Boygu kontrolü

Bu proje, HeatGenie/Boygu ailesindeki Bluetooth dizel ısıtıcıları doğrudan iPhone'dan kontrol etmek için hazırlanmış ilk beta sürümdür.

## Bizim cihazda doğruladığımız BLE yapısı

- Servis: `181A`
- Notify/Read: `3A00`
- Write: `3A01`

Uygulama karakteristikleri yalnızca UUID'ye göre değil, BLE özelliklerine göre de bulur; bu yüzden aynı protokolü kullanan başka HeatGenie/Boygu kontrolcülerinde de çalışma ihtimali vardır.

## Bu beta sürüm ne yapıyor?

- HeatGenie/Boygu ısıtıcısını tarar ve bağlanır.
- Ortam sıcaklığını, kasa sıcaklığını ve voltajı okur.
- Pompa / fan / kızdırma durumunu gösterir.
- Normal START ve STOP/CLEAR komutlarını gönderir.
- Kullanıcı seçebilir:
  - START sıcaklığı
  - STOP sıcaklığı
- Otomatik termostatı aç/kapatır.
- "Karavandan Ayrıldım" düğmesi otomasyonu kapatır ve gerekiyorsa normal STOP/CLEAR verir.
- Teknik tanılama için ham F2 paketini gösterir.

## Otomasyon mantığı

Önerilen **hibrit yöntem** kullanılır:

1. Uygulama ısıtıcının kendi `Start/Stop` modunu etkinleştirir.
2. `STOP` sıcaklığını ısıtıcının kendi hedef sıcaklığına gönderir.
3. Kontrol kartının otomatik STOP'u çalışır (bizim cihazda bu bölüm zaten test edildi).
4. Isıtıcı tamamen `OFF` olduktan ve ortam `START` sıcaklığına indikten sonra uygulama normal START komutunu gönderir.
5. Böylece mevcut kartın çalışmayan otomatik yeniden-START kısmını iPhone tamamlar.

Örnek:

- START: 20°C
- STOP: 25°C

Davranış:

- 25°C → kartın kendi STOP/CLEAR döngüsü
- 20°C ve altı → iPhone normal START gönderir
- 20–25°C → durum korunur

Uygulama ayrıca STOP sıcaklığının START'tan en az 2°C yüksek olmasını zorunlu tutar.

## Güvenlik mantığı

- CLEAR/soğutma sırasında otomatik START verilmez.
- Kasa sıcaklığı yüksekken yeniden START engellenir.
- STOP sonrası en az 120 saniye bekleme vardır.
- Cihaz hata bildiriyorsa otomatik START yapılmaz.
- Bluetooth bağlantısı yoksa otomatik START yapılamaz.
- STOP komutu elektriği kesmez; kontrolcünün normal soğutma sürecini başlatır.

Bu uygulama karbonmonoksit alarmının, doğru egzoz montajının ve elektrik güvenliğinin yerini tutmaz.

## Kaynak / protokol

HeatGenie/Boygu komut ve durum paketi yapısı şu açık kaynaklı MIT projedeki doğrulanmış protokol uygulamasına göre Swift'e aktarılmıştır:

- https://github.com/Spettacolo83/homeassistant-diesel-heater
- `diesel_heater_ble/src/diesel_heater_ble/protocol.py`
- `docs/protocols/HEATGENIE.md`

Kullanılan doğrulanmış işlemler:

- Status request
- Power ON/OFF
- Running mode
- Target temperature
- HeatGenie `AA` zarfı + nibble-wise CRC16

## Mac olmadan IPA oluşturma

Projede GitHub Actions dosyası hazır: `.github/workflows/build-ios.yml`.

### 1. GitHub'da boş bir repo oluştur

Örneğin:

`karavan-webasto-ios`

Bu ZIP içindeki dosyaların tamamını repo köküne yükle.

### 2. GitHub Actions'a gir

Repo → **Actions** → **Build unsigned iOS IPA**.

İlk `push` sonrası otomatik çalışır. İstersen **Run workflow** ile de elle başlatabilirsin.

### 3. Artifact'i indir

Build bitince:

`KaravanWebasto-unsigned`

artifact'ini indir. İçinde:

`KaravanWebasto-unsigned.ipa`

olacak.

### 4. Windows'tan iPhone'a yükle

Sideloadly gibi bir iOS sideload aracıyla IPA'yı kendi Apple hesabınla imzalayıp iPhone'a yükleyebilirsin.

İlk açılışta:

- Bluetooth izni ver.
- HeatGenie uygulamasını tamamen kapat (aynı anda iki uygulama BLE bağlantısı için yarışmasın).
- "Isıtıcıyı Bul" → HeatGenie/Boygu cihazını seç.

## İlk test sırası

Otomasyonu hemen açma.

1. Bağlan.
2. Ortam / kasa / voltaj verileri doğru mu kontrol et.
3. Karavandayken **START** tuşunu dene.
4. Isıtıcı gerçekten ateşleyince **STOP / CLEAR** tuşunu dene.
5. CLEAR tamamlanıp OFF olduğundan emin ol.
6. Ancak bunlar doğru çalışırsa otomatik termostatı etkinleştir.
7. İlk otomasyon testini gözetim altında yap.

## Önemli iOS sınırlaması

Proje `bluetooth-central` arka plan modunu ve CoreBluetooth state restoration kullanır. Ancak iOS'ta kullanıcı uygulamayı uygulama değiştiriciden **zorla kapatırsa**, arka plan Bluetooth otomasyonu çalışmayabilir.

Bu nedenle uygulama:

- Bağlantı varsa otomatik START yapabilir.
- Bağlantı yoksa START yapmaz.
- Isıtıcının kendi STOP hedefini ayrıca ayarladığı için bağlantı kaybında güvenli tarafta kalmayı hedefler.

## Sürüm

`0.1.0-beta`

İlk hedef: bizim RE5011 / HeatGenie kontrolcüde veri okuma + normal START/STOP'u doğrulamak.
