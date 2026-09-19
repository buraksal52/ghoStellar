# Local-Payment Backend Mimarisi

Bu dosya yaşayan bir referanstır — kod değiştikçe güncellenir. Kaynak:
plan onayı → `C:\Users\Furkan Berk\.claude\plans\c-projeler-de-fi-docs-reference-platform-fizzy-goose.md`.
Bu doküman, `C:\Projeler\De-Fi\docs\reference\platform\architecture.md`'nin
platform tabanı kararlarından MVP'ye uyanları taşır; De-Fi'nin swap/lending/
vault/portfolio kapsamı bu depoda **yok**.

| | |
|---|---|
| **Kapsam** | P2P Çek + Havuz + Anchor on/off-ramp |
| **Zincir** | yalnızca Stellar (Horizon + Soroban RPC) |
| **Diller** | Go (backend) + Rust (Soroban kontratı) |
| **Custody** | non-custodial. Backend hiçbir kullanıcı özel anahtarını tutmaz. |
| **Frontend** | bu depoda yok — bkz. `CLAUDE.md` |

## 1. Sistem Topolojisi

```mermaid
graph TD
    Client["İstemci (testnet hesapları, curl/CLI)"]
    Gateway["APISIX Gateway :9080\nrouting / CORS / ratelimit"]
    Auth["pay-auth-service :8081\nSEP-10, RS256 JWT"]
    Cheque["pay-cheque-service :8083\nÇek + Havuz state machine"]
    Tx["pay-tx-service :8084\ntek submit noktası"]
    Anchor["pay-anchor-service :8086\nSEP-1/6/10/12/38 proxy"]
    Scheduler["pay-scheduler-service :8085\nizinsiz refund sweep"]
    Chain["pay-chain-gateway :8082\ntek zincir çıkış noktası"]
    DB[("Postgres\nşema: pay")]
    Horizon[("Horizon API")]
    Soroban[("Soroban RPC")]
    Escrow["pay-escrow kontratı\nCDD7FWHQIAF2Z57CMZUO5BT4TY4VTIZKXLYD4WKQ7HDLO5IQOYU6V3ID"]
    TRAnchor["TR Mock Anchor\ntr-mock-anchor.fly.dev"]

    Client -->|HTTPS| Gateway
    Gateway --> Auth
    Gateway --> Cheque
    Gateway --> Tx
    Gateway --> Anchor

    Auth -.X-Internal-Api-Key.-> Chain
    Cheque -.X-Internal-Api-Key.-> Chain
    Tx -.X-Internal-Api-Key.-> Chain
    Anchor -.X-Internal-Api-Key.-> Chain
    Scheduler -.X-Internal-Api-Key.-> Chain
    Scheduler -.X-Internal-Api-Key.-> Cheque

    Auth --> DB
    Cheque --> DB
    Tx --> DB
    Anchor --> DB

    Chain --> Horizon
    Chain --> Soroban
    Soroban --> Escrow

    Anchor -->|"SSRF allow-list'ten geçen HTTPS"| TRAnchor
```

<details>
<summary>Aynı topolojinin ASCII hâli (Mermaid render olmayan ortamlar için)</summary>

```
                    +------------------------------+
                    |     APISIX Gateway (:9080)    |
                    |  routing / CORS / ratelimit   |
                    +---------------+----------------+
   +----------+----------+----------+----------+----------+
   |          |          |          |          |
+--v--+  +----v----+  +--v--+  +----v----+  +--v------+
|auth |  | cheque  |  | tx  |  | anchor  |  |scheduler|
|:8081|  | :8083   |  |:8084|  | :8086   |  | :8085   |
+--+--+  +----+----+  +--+--+  +----+----+  +----+----+
   |          |            |         |             |
   +----------+---(internal HTTP, X-Internal-Api-Key)---+
                          |
                +---------v----------+
                |  pay-chain-gateway |  <- tek zincir cikis noktasi
                |    (:8082)         |
                +---------+----------+
                          |
              +-----------+-----------+
              |                       |
      +-------v-------+     +---------v---------+
      |  Horizon API  |     |   Soroban RPC     |
      +---------------+     +-------------------+
```

</details>

`pay-auth-service`'in zincire ihtiyacı yok (SEP-10 challenge/verify saf
kriptografidir). `pay-scheduler-service` `pay-chain-gateway` ve
`pay-cheque-service`'in internal uçlarını çağırır, kendi HTTP API'si yok.

## 2. Servis Envanteri

| Servis | Port | Sorumluluk |
|---|---|---|
| `pay-auth-service` | 8081 | SEP-10 challenge/verify, RS256 JWT + refresh, kullanıcı profili |
| `pay-chain-gateway` | 8082 | Tek Horizon + Soroban RPC çıkışı |
| `pay-cheque-service` | 8083 | Çek durum makinesi, Havuz, rezerv defteri, imzasız XDR, Forced Sync |
| `pay-tx-service` | 8084 | Tek submit noktası, Idempotency-Key |
| `pay-scheduler-service` | 8085 | Süresi dolan çeklerin izinsiz iadesi (keeper hesabıyla) |
| `pay-anchor-service` | 8086 | SEP-1/SEP-10(anchor)/SEP-24 proxy, trustline XDR |

Servis sınırları (kod tarafından zorlanır, yalnızca kural olarak değil):

1. Servisler birbirinin Postgres tablosunu okumaz — kimlik geçişi bir
   `stellar_address` sütunu olarak taşınır, `pay.users(id)`'e FK ile değil.
2. Yalnızca `pay-chain-gateway` Horizon/Soroban'a çıkar
   (`backend/services/chain`); diğerleri `ports.ChainGateway` üzerinden
   çağırır (`ports/httpadapter` mikroservis modunda, `ports/directadapter`
   gelecekteki monolith modunda — bkz. `SERVICE.md` madde 4).
3. Yalnızca `pay-tx-service` imzalı XDR submit eder.
4. Hiçbir serviste kullanıcı özel anahtarı yok. `pay-auth-service`'in
   SEP-10 sunucu imzalama anahtarı ve `pay-scheduler-service`'in keeper
   anahtarı, kullanıcı fonlarını hareket ettirme yetkisi taşımayan iki
   istisnadır (bkz. `docs/reference/platform/anchor-entegrasyonu.md` ve
   plan'ın "Kritik Mimari Karar" bölümü).
5. Servisler arası çağrıda `X-Internal-Api-Key` zorunlu.
6. Boş env var = özellik kapalı + fallback (`SOROBAN_RPC_URL` boşsa
   chain-gateway yalnız Horizon modunda açılır).

## 3. Çek + Havuz'un Zincir Üstü Temsili

`contracts/soroban/pay-escrow` — tek kontrat, hem Çek hem Havuz. Klasik
Claimable Balance MVP'de **kullanılmaz**; gerekçe kontratın kendi
`lib.rs`'indeki modül dokümanında ve plan'ın "Kritik Mimari Karar"
bölümünde. Fonksiyonlar, durumlar ve değişmezlerin (D1-D9) kontrat
karşılığı için `contracts/soroban/pay-escrow/README.md`'ye bakın.

## 4. Para ve Sayı Tipleri

De-Fi'nin ana mimarisiyle birebir aynı kural: `backend/pkg/money.Amount`
(`Raw *big.Int` + `Decimals uint8`), API sınırında her zaman string,
Postgres'te `NUMERIC(40,0)` + `decimals SMALLINT`, `DOUBLE PRECISION` yasak.

## 5. Kimlik, Yetki, Güvenlik

- SEP-10 → RS256 JWT (`backend/pkg/authx`). Özel anahtar yalnızca
  `pay-auth-service`'te.
- Servisler arası: `X-Internal-Api-Key` (`authx.RequireInternalKey`).
- Dışarı çıkan tüm HTTP (Horizon, Soroban RPC, anchor) `pkg/nethost`
  SSRF allow-list'inden geçer.
- Idempotency: para hareketi doğuran her POST `Idempotency-Key` ister
  (`pay.idempotency_keys`, 24 saat TTL).

## 6. Kontrat + Servis Sınırındaki Sorumluluk Ayrımı

Backend, kontratın kendi kendine yeten kontrollerini (D2, H2, G5)
**tekrar etmez** — yalnızca kullanıcıya hızlı, açıklayıcı bir hata dönmek
için önden ucuz bir kontrol yapar (örn. `pool.withdraw_locked`'ı ağ
ücreti harcamadan önce yakalamak). Nihai doğruluk her zaman kontrattadır
(D6): backend'e güvenilmez.

## 7. Referans: De-Fi'den Ne Alındı, Ne Alınmadı

Tam liste ve gerekçesi plan dosyasının "Kesilen prod fazlalıkları" ve
"Render tool'u almama kararı" bölümlerinde. Özet: Temporal, MinIO,
TimescaleDB, OpenSearch, OTel/Prometheus, Redis, `tools/render`,
`defi-ingestor-service`, `defi-notification-service` — hepsi MVP'de yok.
