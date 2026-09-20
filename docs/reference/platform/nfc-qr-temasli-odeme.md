# NFC + QR ile Temaslı Ödeme

Bu doküman Flutter istemcisindeki "yaklaştır ve öde / okut ve öde" akışının
protokolünü ve bilinçli sınırlarını anlatır. **Backend'de hiçbir değişiklik
yok**: NFC ve QR yalnızca iki telefon arasındaki kısa bir el sıkışmadır,
ödemenin kendisi bilinen çek hattından (`POST /cheques` → imza →
`/tx/submit` → `confirm-*`) geçer. Bu yüzden zincir-üstü değişmezler
(`p2p-cek-ve-havuz-mimarisi.md` D1-D9) bu akıştan etkilenmez.

Kod: `frontend/lib/core/payments/payment_uri.dart` (format),
`frontend/lib/state/tap_providers.dart` (alıcı oturumu),
`frontend/lib/data/nfc/nfc_service.dart` (NFC taşıyıcı),
`frontend/android/.../nfc/HceService.kt` (Android Host Card Emulation).

## Neden yön "alıcı gösterir, gönderen okur"

`pay-escrow.lock()` alıcının adresini çek yazılırken zincire sabitler ve
`claim()` `receiver.require_auth()` ister. Kontratta hashlock, preimage ya da
claim-token yoktur. Yani gönderen alıcının adresini *önceden* bilmek zorunda:
bu bilgi alıcıdan gönderene akar. Ödeme sonrası ters yönde ikinci bir
bilgi (çekin `chequeId`'si) akar ki alıcı `/sync` beklemeden tahsil edebilsin.

## İki payload

### 1. Ödeme talebi — alıcı → gönderen (SEP-7)

```
web+stellar:pay?destination=G...&amount=25.50&asset_code=XLM
  &msg=ghoStellar&x_req=<uuid-v4>&x_exp=<unix-saniye>
```

| Alan | Zorunlu | Anlam |
|---|---|---|
| `destination` | evet | Alıcının `G...` adresi (`StellarAddress.isValid`) |
| `amount` | hayır | Düz ondalık string. Yoksa gönderen kendi girer |
| `asset_code` | hayır | Yalnızca `XLM`; başka değer ya da `asset_issuer` reddedilir |
| `msg` | hayır | Bilgi amaçlı, işlenmez |
| `x_req` | hayır | Tek kullanımlık nonce (≤ 64 karakter) |
| `x_exp` | hayır | Son kullanma, unix saniye. Alıcı 5 dakikalık talep üretir |

Çıplak `G...` adresi de geçerli bir taleptir (geriye dönük uyum; başka
cüzdanların gösterdiği adresler). Tutar hiçbir yerde `double` olmaz.

**Bilinen sınır:** SEP-7 seçildiği için harici bir Stellar cüzdanı bu URI'yi
klasik bir `payment` sanır, `x_` alanlarını yok sayar ve çek yazmaz — para
doğrudan alıcıya gider, escrow'a değil. ghoStellar ↔ ghoStellar akışında
sorun yoktur; harici cüzdanla kullanımda "iade edilebilir çek" garantisi
(7 gün) geçerli olmaz.

### 2. Çek devri — gönderen → alıcı

```
ghostellar://cheque?id=<ULID>&from=G...&amount=25.50&req=<x_req>
```

Bilerek SEP-7 `pay` değil: harici bir cüzdana "öde" demesi yanlış olurdu.
`req`, devri alıcının kendi başlattığı talebe bağlar. `id` bir URL yoluna
(`/cheques/{id}/claim-xdr`) girdiği ve taranan bir payload'dan geldiği için
backend'in ULID biçimine (`^[0-9A-Za-z]{26}$`) sabitlenir.

**Sızan `chequeId` zararsızdır:** `claim-xdr` JWT'nin `stellar_account`
alanını çekin `receiverAddress`'iyle karşılaştırır ve kontrat
`receiver.require_auth()` ister — çeki yalnızca yazılırken sabitlenen alıcı
tahsil edebilir.

## Akış

```
ALICI (Receive)                          GÖNDEREN (Send)
 tutar gir (opsiyonel)
 SEP-7 talebi üret (nonce + 5 dk)
 NFC yayını + QR
                    ←── temas / QR okut ──→
                                          talebi çöz; süre + nonce kontrolü
                                          tutar doluysa kilitli göster
                                          onayla: POST /cheques → imza →
                                          /tx/submit → confirm-lock → preauth
 (NFC: "okundu" sinyali)
 yayını durdur, okuyucu ol
 /sync'i 3 sn'de bir sorgula
                                          ghostellar://cheque yayınla (2 dk)
                    ←── ikinci temas / QR ──→
 chequeId → claim-xdr → imza → submit →
 confirm-claim → ack  →  "Payment received"
```

Üç yol da aynı sonuca varır; biri kaçsa diğeri kapatır:

1. **İkinci NFC teması** (Android ↔ Android): en hızlı.
2. **Gönderenin ekranındaki QR'ı okutmak** (alıcı "Scan sender's code"):
   NFC olmayan her cihaz çifti için tam eşdeğer yol.
3. **`/sync` polling'i**: hiçbir handoff okunmasa bile, oturumdan *sonra*
   oluşan, alıcıya ait, `HAVUZDA`, (talep tutarlıysa) tutarı eşleşen çek
   otomatik tahsil edilir.

## Güvenlik ve dayanıklılık kararları

- **Nonce tek kullanımlık:** gönderen, çek gerçekten yazıldıktan sonra
  `x_req`'i bellekte "kullanıldı" işaretler; aynı QR ikinci kez taranırsa
  reddedilir. Taramak nonce'u yakmaz (vazgeçilen gönderim kodu bozmaz).
  Kalıcı değildir — uygulama yeniden başlayınca sıfırlanır; bu kasıtlı,
  backend'in `cheque.already_active` (D5) kuralı zaten ikinci bir güvence.
- **Süre:** `x_exp` geçmiş talep, kendi mesajıyla ("expired") reddedilir;
  ayrıştırıcı süreyi *politika* olarak uygulamaz, çağıran karar verir.
  Alıcı, 5 dakikada kimse okumazsa talebi yeni nonce ile yeniler.
- **Eski çekler otomatik tahsil edilmez:** oturum başında zaten bekleyen
  çekler "baseline"dır, elle listede kalır. Her çek otomatik yolda en fazla
  bir kez denenir; başarısız claim döngüye girmez, elle "Claim" düğmesine
  bırakılır.
- **iOS:** Core NFC üçüncü parti uygulamaların tag emülasyonuna izin vermez
  ve başka bir telefonun HCE'sini okumak ücretli bir entitlement ister
  (`com.apple.developer.nfc.readersession.iso7816.select-identifiers`), bu
  yüzden `isEmulateSupported` / `isScanSupported` iOS'ta `false`. iOS ↔ Android
  ve iOS ↔ iOS akışları QR + polling ile tam kapanır. `Info.plist`'e kamera
  izin metni (`NSCameraUsageDescription`) eklendi — `mobile_scanner` onsuz
  gerçek iOS cihazında izin anında çöker.
- **NFC APDU sınırı:** kısa APDU yanıtı en fazla 256 bayt taşır;
  `NfcService.startBroadcast` 240 baytı aşan payload'ı reddeder. Tam bir
  talep (~190 bayt) sığar.

## Doğrulanmayanlar

NFC emülatörde çalışmaz; aşağıdakiler yalnızca iki gerçek Android cihazda
doğrulanabilir ve **henüz doğrulanmadı**:

- HCE ↔ okuyucu el sıkışması ve `payloadRead` sinyalinin ana thread'e
  ulaşması (birim testleri `NfcService`'i sahtelerle değiştirir).
- İkinci temasın, ilk okuyucu oturumu kapandıktan hemen sonra rol
  değiştirerek güvenilir çalışması (okuyucu modu kartı emülasyonunu geçici
  olarak kapatır).
- Kotlin tarafı derlenir (`flutter build apk --debug`), ama cihazda
  çalıştırılmadı.
