# CLAUDE.md — Local-Payment

Bu dosya, bu depoda çalışan herkes (insan veya agent) için hub dokümandır.

## Ne İnşa Ediyoruz

Stellar üzerinde non-custodial bir P2P ödeme MVP'si: kişiden kişiye "Çek"
gönderimi, "Havuz" mevduatı, ve bir anchor üzerinden fiat giriş/çıkışı.
Backend Go mikroservisleri + tek bir Soroban kontratı. **Bu depo yalnızca
backend'i kapsar** — Flutter mobil istemci ayrı bir adımda ele alınacak
(tasarım tamamlandıktan sonra); API sözleşmesi kendi başına eksiksizdir.

Kapsam ve kararların tam gerekçesi:
`C:\Users\Furkan Berk\.claude\plans\c-projeler-de-fi-docs-reference-platform-fizzy-goose.md`

## Pointer Tablosu

| Konu | Dosya |
|---|---|
| Platform mimarisi (bu depoda gerçekten var olan) | `docs/reference/platform/architecture.md` |
| P2P çek/havuz akışı ve case kataloğu (referans, De-Fi'den) | `docs/reference/platform/p2p-cek-ve-havuz-mimarisi.md` |
| Anchor (SEP-1/10/24) entegrasyon kararları | `docs/reference/platform/anchor-entegrasyonu.md` |
| Kasıtlı kapsam sınırlamaları ve açık işler | `SERVICE.md` |
| Soroban kontratı | `contracts/soroban/pay-escrow/README.md` |
| Paylaşılan Go paketleri | `backend/pkg/{money,httpx,authx,nethost,obs,dbx,envx,stellarx}` |

## Kurulmuş Kalıplar

- **Tek Go modülü** (`backend/go.mod`), `internal/` yok — De-Fi'nin monolith'i
  tam da bu yüzden hiç derlenemedi (bkz. plan, "Neden tek Go modülü").
- **Servisler birbirini import etmez.** `backend/ports` bir interface
  (`ChainGateway`) tanımlar; `ports/httpadapter` (mikroservis) ve
  `ports/directadapter` (gelecekteki monolith) iki gerçeklemedir.
- **Para hiçbir yerde `float64` değildir.** `pkg/money.Amount`, API
  sınırında her zaman string.
- **Yalnızca `pay-tx-service` transaction submit eder.** Diğer servisler
  imzasız XDR üretir.
- **Yalnızca `pay-chain-gateway` Horizon/Soroban'a çıkar.**
- **Backend hiçbir zaman özel anahtar tutmaz** — ne kullanıcının, ne
  anchor'ın JWT'sinin. Tek istisna: `pay-scheduler-service`'in keeper
  anahtarı, yalnızca izinsiz `refund()` çağrılarının ağ ücretini öder,
  kimsenin parasını hareket ettirme yetkisi taşımaz.
- **Response envelope tek tip:** başarı `{"data":..., "meta":...}`, hata
  `{"error":{"code","message","details"}}`.
- **Boş env var = özellik kapalı + fallback.** `SOROBAN_RPC_URL` boşsa
  chain-gateway yalnız Horizon modunda açılır.

## GOTCHA'lar

- Postgres'te para kolonu `NUMERIC(40,0)` + ayrı `decimals SMALLINT`.
- `pay.idempotency_keys`/`pay.submissions`/`pay.anchor_transactions`/
  `pay.trustlines` bir `stellar_address` TEXT/VARCHAR taşır, `pay.users(id)`'e
  FK **değil** — "hiçbir servis başka bir servisin tablosunu okumaz" kuralı,
  tek Postgres instance'ında bile FK sınırıyla korunur.
- `contracts/soroban/pay-escrow`'da Çek'in tüm hayat döngüsü (fonlama, claim,
  iade, zorla tahsil) **tek kontratta**; classic Claimable Balance MVP'de
  kullanılmaz (bkz. plan, "Kritik Mimari Karar").
- `force_collect`'in ön-yetki XDR'ı (`pkg/stellarx.BuildForceCollectAuthEntry`)
  canlı ağda henüz doğrulanmadı — bkz. `SERVICE.md` madde 2.
- Compose dosyasındaki `name: local-payment` satırını **silme** — silinirse
  proje adı dizin adından türer ve named volume kopar (veri kaybı).

## Komutlar

```
bash scripts/setup-secrets.sh         # dev JWT anahtarları + .env iskeleti
bash scripts/dev-up.sh                # docker compose up --build
bash scripts/smoke.sh                 # APISIX edge doğrulaması
bash scripts/e2e.sh                   # testnet mutlu-yol senaryosu
cd backend && go test ./...           # Go birim testleri
cd contracts/soroban/pay-escrow && cargo test   # kontrat testleri (17)
```

## Diller

Kod yorumları İngilizce; `docs/` ve bu dosya Türkçe.
