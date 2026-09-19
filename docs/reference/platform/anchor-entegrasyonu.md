# Anchor Entegrasyonu (SEP-24)

Ürünün fiat giriş/çıkış kapısı. `architecture.md`'nin De-Fi'deki atası bunu
§16'da "kapsam dışı, gerekirse 15. servis olarak eklenir" diye bırakmıştı —
Local-Payment'ta kapsamda ve `pay-anchor-service` (:8086) olarak yaşıyor.

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

mobil --POST /anchors/{id}/deposit + X-Anchor-Token--> pay-anchor-service
                                                    --> anchor SEP-24
mobil <-- {id, url}  (interactive URL, WebView'de açılır)
```

## Sonucu: kim anchor işlem durumunu takip eder?

Bu, plan'ın Açık Varsayım #3'ünün pratik sonucu: backend anchor JWT'sini
hiç görmediği için `pay-scheduler-service` anchor'ın SEP-24
`GET /transaction` uç noktasını kullanıcı adına **sorgulayamaz** — o uç
SEP-10 (anchor) yetkisi ister. Çözüm: istemci, kendi elindeki anchor JWT
ile anchor'ı doğrudan sorgular ve gördüğü durumu
`POST /anchors/{id}/transactions/{txId}/report` ile backend'e bildirir.
Backend bunu kör kabul etmez — yalnızca JWT-doğrulanmış kullanıcının kendi
işlemi için rapor kabul edilir (`stellar_address` bearer JWT'den gelir,
istekten değil).

## Trustline: zorunlu onboarding adımı

Anchor'lı varlık klasik bir Stellar asset'i, trustline gerektirir. Bu,
p2p dokümanının A4/F3 case'lerini gerçek bir onboarding adımına çevirir:

- `POST /anchors/{id}/trustline-xdr` — imzasız `change_trust` operasyonu.
- Çek yazarken `pay-cheque-service`, alıcının trustline'ını
  `pay-chain-gateway` üzerinden kontrol eder → yoksa
  `cheque.receiver_no_trustline`.

## Withdraw'ın submit yolu

SEP-24 withdraw'da anchor bir hesap+memo verir; kullanıcı oraya kendi
gönderir. Bu, sıradan bir payment XDR'ıdır ve ana mimari kuralı gereği
**`pay-tx-service`** üzerinden submit edilir — `pay-anchor-service` hiçbir
zaman submit etmez.

## Keeper hesabı (pay-scheduler-service)

`pay-escrow`'un `refund()` fonksiyonu izinsizdir (kimin çağırdığı önemsiz),
ama Soroban'da bir işlemi göndermek yine de bir hesap ve ağ ücreti
gerektirir. `pay-scheduler-service`, `KEEPER_SECRET_SEED` ile yapılandırılan
kendi testnet hesabıyla bu ücreti öder. Bu **custodial bir anahtar
değildir**: keeper hiçbir kullanıcının fonuna `require_auth` yetkisi
taşımaz, yalnızca kendi imzasıyla "bu işlemi ağa gönderiyorum" der —
`refund()`'ün kendi mantığı zaten sadece "süre doldu mu" kontrolü yapar,
çağıranın kimliğine bakmaz.

## Açık varsayım: `authorization_required` bayrağı

İhraççı bu bayrağı açarsa, bir Soroban kontratı o varlığı ihraççı onayı
olmadan tutamaz ve escrow akışı çalışmaz. MVP, bayrağı kapalı bir anchor
varlığı seçer (`testanchor.stellar.org`'un SRT'si testnet'te böyle);
gerçek bir üretim anchor'ına geçerken bu bayrak ilk kontrol edilecek şey.
