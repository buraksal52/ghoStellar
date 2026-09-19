# Anchor Entegrasyonu (TR Mock Anchor: SEP-1/6/10/12/38)

Ürünün fiat giriş/çıkış kapısı. `architecture.md`'nin De-Fi'deki atası bunu
§16'da "kapsam dışı, gerekirse 15. servis olarak eklenir" diye bırakmıştı —
ghoStellar'da kapsamda ve `pay-anchor-service` (:8086) olarak yaşıyor.
Hedef `tr-mock-anchor.fly.dev` üzerindeki testnet TR Mock Anchor'dır.
TRY/USDC akışı SEP-6 ile çalışır; mevcut SEP-24 proxy geriye uyumluluk içindir.

## İki ayrı SEP-10 bağlamı

1. **Bize karşı SEP-10** → `pay-auth-service`, bizim RS256 JWT'mizi basar.
2. **Anchor'a karşı SEP-10** → anchor'ın kendi `WEB_AUTH_ENDPOINT`'i,
   **anchor'ın** JWT'sini basar. Aynı cihaz anahtarı iki farklı challenge'ı
   imzalar; ikisi karıştırılmaz.

## Custody kararı: anchor JWT cihazda durur

`pay-anchor-service` anchor'ın JWT'sini **hiçbir zaman saklamaz** —
`pay.anchor_transactions` yalnızca bir işlem defteridir, kimlik bilgisi
tutmaz. Akış:

```
mobil --GET /anchors/{id}/auth/challenge--> pay-anchor-service --> anchor
mobil <-- challenge XDR
mobil --imzalar--POST /anchors/{id}/auth/token--> pay-anchor-service --> anchor
mobil <-- anchor JWT (cihazda kalır)

mobil --GET /anchors/{id}/sep6/info-----------------> pay-anchor-service --> anchor
mobil --GET /anchors/{id}/sep6/deposit?asset_code=USDC&account=...&amount=1000
          + X-Anchor-Token -------------------------> pay-anchor-service --> anchor SEP-6
mobil <-- {id, how, more_info_url, ...}
mobil --GET /anchors/{id}/sep6/transaction?id=... --> işlem durumunu sorgular
```

SEP-6, SEP-12 ve SEP-38 uçları, operatörce yapılandırılan tek anchor'ın
SEP-1 `TRANSFER_SERVER`, `KYC_SERVER` ve `ANCHOR_QUOTE_SERVER` adreslerinden
çözülür. İstemcinin gönderdiği host veya URL kullanılmaz; bütün istekler
`pkg/nethost` host allowlist'inden geçer. Yerel yollar:

- `GET/POST /anchors/{id}/sep6/{path...}` — `/info`, `/deposit`, `/withdraw`,
  `/transaction`, `/transactions` ve mock banka simülasyonu.
- `GET/PUT/POST /anchors/{id}/sep12/{path...}` — KYC müşteri sorgusu/güncellemesi.
- `GET/POST /anchors/{id}/sep38/{path...}` — fiyat ve quote uçları.

SEP-6 `/info` haricindeki proxy çağrıları `X-Anchor-Token` ister. Token yalnızca
upstream isteğinde kullanılır ve veritabanına yazılmaz. Deposit/withdraw
başlatma yanıtındaki işlem kimliği kullanıcının anchor işlem defterine eklenir.
İstemci durumu anchor'dan sorgulayabilir ve report endpoint'ine bildirebilir;
backend bu raporun doğruluğunu bağımsız olarak kanıtlamaz.

## Sonucu: kim anchor işlem durumunu takip eder?

Bu, plan'ın Açık Varsayım #3'ünün pratik sonucu: backend anchor JWT'sini
hiç görmediği için `pay-scheduler-service` anchor'ın SEP-24
transaction uç noktalarını kullanıcı adına **sorgulayamaz** — bunlar
SEP-10 (anchor) yetkisi ister. Çözüm: istemci, kendi elindeki anchor JWT
ile anchor'ı doğrudan sorgular ve gördüğü durumu
`POST /anchors/{id}/transactions/{txId}/report` ile backend'e bildirir.
Backend yalnızca daha önce başlatılıp aynı kullanıcıya kaydedilmiş işlem
kimliği için rapor kabul eder (`stellar_address` bearer JWT'den gelir,
istekten değil); anchor'dan gelen durum değerini bağımsız doğrulamaz.

## Trustline: zorunlu onboarding adımı

Anchor'lı varlık klasik bir Stellar asset'i, trustline gerektirir. Bu,
p2p dokümanının A4/F3 case'lerini gerçek bir onboarding adımına çevirir:

- `POST /anchors/{id}/trustline-xdr` — imzasız `change_trust` operasyonu.
- Çek yazarken `pay-cheque-service`, alıcının trustline'ını
  `pay-chain-gateway` üzerinden kontrol eder → yoksa
  `cheque.receiver_no_trustline`.

## Withdraw'ın submit yolu

SEP-6 withdraw yanıtındaki `account_id`, `memo` ve `memo_type` hedef bilgileri
kullanılarak kullanıcı Stellar payment XDR'ını oluşturup imzalar; işlem
ana mimari kuralı gereği **`pay-tx-service`** üzerinden gönderilir.
`pay-anchor-service` hiçbir zincir işlemini submit etmez.

## Keeper hesabı (pay-scheduler-service)

`pay-escrow`'un `refund()` fonksiyonu izinsizdir (kimin çağırdığı önemsiz),
ama Soroban'da bir işlemi göndermek yine de bir hesap ve ağ ücreti
gerektirir. `pay-scheduler-service`, `KEEPER_SECRET_SEED` ile yapılandırılan
kendi testnet hesabıyla bu ücreti öder. Bu **custodial bir anahtar
değildir**: keeper hiçbir kullanıcının fonuna `require_auth` yetkisi
taşımaz, yalnızca kendi imzasıyla "bu işlemi ağa gönderiyorum" der —
`refund()`'ün kendi mantığı zaten sadece "süre doldu mu" kontrolü yapar,
çağıranın kimliğine bakmaz.

## TR Mock Anchor ayarları

Varsayılan `ANCHOR_DOMAIN`, `ASSET_CODE` ve `ASSET_ISSUER` mock anchor testnet
USDC değerleridir. Çek/Havuz kontratı USDC'yi Stellar Asset Contract üzerinden
tuttuğundan `ASSET_SAC_CONTRACT_ID` ayrıca ayarlanır:

```sh
stellar contract id asset --asset USDC:GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5 --network testnet
```

Komut çıktısını `deploy/.env` içindeki `ASSET_SAC_CONTRACT_ID` değerine koyun.
USDC deposit limiti 50–3.000 TRY, withdraw alt limiti 1 USDC'dir. Deposit
`pending_trust` durumunda kalırsa kullanıcı trustline açmalı; XDR'ı imzalatıp
`pay-tx-service` üzerinden göndermelisiniz. Banka transferi simülasyon yolu
yalnız mock anchor'a özeldir.

## Açık varsayım: `authorization_required` bayrağı

İhraççı bu bayrağı açarsa, bir Soroban kontratı o varlığı ihraççı onayı
olmadan tutamaz ve escrow akışı çalışmaz. MVP, bayrağı kapalı bir anchor
varlığı seçer (TR Mock Anchor testnet USDC'si);
gerçek bir üretim anchor'ına geçerken bu bayrak ilk kontrol edilecek şey.
