# ghoStellar Backend Mimarisi

Bu dosya ghoStellar backend'inin güncel mimarisini gösterir. Servis
envanteri ve akışlar depo içindeki `backend/`, `contracts/` ve `deploy/`
yapılandırmalarıyla eşleştirilmiştir.

| | |
|---|---|
| **Kapsam** | P2P Çek + Havuz + Anchor on/off-ramp |
| **Zincir** | yalnızca Stellar (Horizon + Soroban RPC) |
| **Diller** | Go (backend) + Rust (Soroban kontratı) |
| **Custody** | non-custodial. Backend hiçbir kullanıcı özel anahtarını tutmaz. |
| **Frontend** | bu depoda yok — bkz. `CLAUDE.md` |

## 1. Çalışan Sistem Topolojisi

```mermaid
flowchart TB
    client["Mobil istemci<br/>(bu depoda yok)"]
    edge["APISIX Gateway<br/>:9080 / :9443<br/>routing · CORS · rate limit"]
    client --> edge

    subgraph api["Dış API servisleri"]
      auth["pay-auth-service<br/>:8081"]
      cheque["pay-cheque-service<br/>:8083"]
      tx["pay-tx-service<br/>:8084"]
      anchor["pay-anchor-service<br/>:8086"]
    end
    edge -->|/auth/*| auth
    edge -->|/cheques/* · /pool/* · /sync| cheque
    edge -->|/tx/*| tx
    edge -->|/anchors/*| anchor

    subgraph internal["İç servisler · APISIX üzerinden yayınlanmaz"]
      scheduler["pay-scheduler-service<br/>:8085 · public API yok"]
      chain["pay-chain-gateway<br/>:8082 · tek zincir çıkış noktası"]
    end
    auth -. "DB" .-> db[("PostgreSQL 17<br/>pay şeması")]
    cheque -. "DB" .-> db
    tx -. "DB" .-> db
    anchor -. "DB" .-> db
    cheque -->|internal HTTP<br/>X-Internal-Api-Key| chain
    tx -->|internal HTTP<br/>X-Internal-Api-Key| chain
    scheduler -->|internal HTTP| chain
    scheduler -->|internal HTTP<br/>X-Internal-Api-Key| cheque
    anchor -->|internal HTTP<br/>X-Internal-Api-Key| chain

    chain --> horizon["Stellar Horizon"]
    chain --> rpc["Stellar Soroban RPC"]
    anchor -->|SEP-1 · SEP-10 · SEP-6 · SEP-12 · SEP-38| mock["TR Mock Anchor<br/>tr-mock-anchor.fly.dev"]
```

Docker Compose servisleri ayrı process'ler olarak çalıştırır ve tek Postgres
instance'ını kullanır. Tablolar `pay` şemasında olsa da servisler yalnızca
kendi sorumluluğundaki tablolara erişir. APISIX dış API yollarını yönlendirir;
scheduler ve chain-gateway'in iç uçları edge'den yayınlanmaz.

`pay-auth-service` Horizon/Soroban'a çıkmaz. Scheduler'ın kendi HTTP API'si
yoktur; süre aşımı ve TTL işleri için cheque-service ile chain-gateway'i
internal HTTP üzerinden çağırır.

### İstek ve imzalı işlem akışı

```mermaid
sequenceDiagram
    autonumber
    participant App as Mobil istemci
    participant Edge as APISIX
    participant Domain as Auth / Cheque / Anchor API
    participant Chain as Chain Gateway
    participant Tx as TX Service
    participant Stellar as Horizon / Soroban RPC
    participant DB as PostgreSQL

    App->>Edge: API isteği + ghoStellar JWT
    Edge->>Domain: Rota + rate limit
    Domain->>Chain: hesap, trustline veya simülasyon kontrolü
    Chain->>Stellar: Horizon / Soroban RPC
    Stellar-->>Chain: zincir verisi / simülasyon
    Chain-->>Domain: sonuç
    Domain->>DB: yerel kayıt veya durum geçişi
    Domain-->>App: imzasız XDR
    App->>App: kullanıcının cihaz anahtarıyla imzalar
    App->>Edge: imzalı XDR + Idempotency-Key
    Edge->>Tx: submit isteği
    Tx->>Chain: imzalı XDR submit
    Chain->>Stellar: işlemi gönderir ve sonucu bekler
    Stellar-->>Chain: hash / ledger sonucu
    Chain-->>Tx: submit sonucu
    Tx->>DB: submission kaydı
    Tx-->>App: işlem sonucu
    App->>Edge: ilgili confirm endpoint'i
    Edge->>Domain: işlem durumunu kaydet
```

### Anchor on/off-ramp akışı

```mermaid
sequenceDiagram
    participant App as Mobil istemci
    participant AnchorAPI as pay-anchor-service
    participant Anchor as TR Mock Anchor
    participant Tx as pay-tx-service
    participant Chain as pay-chain-gateway
    participant Stellar as Stellar Horizon
    participant DB as PostgreSQL

    App->>AnchorAPI: ghoStellar JWT ile SEP-10 challenge isteği
    AnchorAPI->>Anchor: WEB_AUTH_ENDPOINT challenge
    Anchor-->>AnchorAPI: Anchor challenge XDR
    AnchorAPI-->>App: Anchor challenge XDR
    App->>App: challenge'ı cihaz anahtarıyla imzalar
    App->>AnchorAPI: imzalı challenge
    AnchorAPI->>Anchor: SEP-10 token isteği
    Anchor-->>AnchorAPI: Anchor JWT
    AnchorAPI-->>App: Anchor JWT (cihazda kalır)
    App->>AnchorAPI: SEP-6 deposit/withdraw + X-Anchor-Token
    AnchorAPI->>Anchor: TRANSFER_SERVER isteği
    Anchor-->>AnchorAPI: işlem id / deposit talimatı / withdraw account + memo
    AnchorAPI->>DB: işlem id'sini ghoStellar kullanıcısına bağla
    AnchorAPI-->>App: anchor işlem bilgisi
    App->>AnchorAPI: SEP-12 KYC veya SEP-38 quote isteği (gerektiğinde)
    AnchorAPI->>Anchor: KYC_SERVER / ANCHOR_QUOTE_SERVER
    Anchor-->>AnchorAPI: KYC sonucu / quote
    AnchorAPI-->>App: KYC sonucu / quote
    App->>Tx: imzalı withdraw payment XDR + Idempotency-Key
    Tx->>Chain: imzalı işlemi gönder
    Chain->>Stellar: Stellar payment
    Stellar-->>Chain: işlem sonucu
    Chain-->>Tx: hash / ledger sonucu
    Tx-->>App: submit sonucu
    App->>AnchorAPI: durum raporu (kullanıcıya ait kayıtlı tx id)
    AnchorAPI->>DB: yerel işlem durumunu güncelle
```

Anchor JWT kalıcı depoya yazılmaz. SEP-6 `/info` dışında proxy uçları
`X-Anchor-Token` bekler. İstemcinin gönderdiği deposit `account` alanı,
ghoStellar JWT'sindeki Stellar adresiyle eşleştirilir. Anchor işlem durumu halen
istemci raporuna dayanır; backend anchor'dan bağımsız doğrulama yapmaz. Ayrıntı:
[`anchor-entegrasyonu.md`](anchor-entegrasyonu.md).

<details>
<summary>Genel topolojinin ASCII hâli (Mermaid render olmayan ortamlar için)</summary>

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

`pay-escrow` kontratı (testnet:
`CDD7FWHQIAF2Z57CMZUO5BT4TY4VTIZKXLYD4WKQ7HDLO5IQOYU6V3ID`) Soroban RPC'nin
arkasında yaşar; Çek + Havuz'un tüm zincir-üstü durumu orada tutulur.

</details>

## 2. Servis Envanteri

| Servis | Port | Sorumluluk |
|---|---|---|
| `pay-auth-service` | 8081 | SEP-10 challenge/verify, RS256 JWT + refresh, kullanıcı profili |
| `pay-chain-gateway` | 8082 | Tek Horizon + Soroban RPC çıkışı |
| `pay-cheque-service` | 8083 | Çek durum makinesi, Havuz, rezerv defteri, imzasız XDR, Forced Sync |
| `pay-tx-service` | 8084 | Tek submit noktası, Idempotency-Key |
| `pay-scheduler-service` | 8085 | Süresi dolan çeklerin izinsiz iadesi (keeper hesabıyla) |
| `pay-anchor-service` | 8086 | SEP-1/SEP-10, SEP-6/12/38 proxy, işlem defteri ve trustline XDR; SEP-24 uyumluluğu |

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
   istisnadır (anchor kararı için
   [`anchor-entegrasyonu.md`](anchor-entegrasyonu.md) belgesine bakın).
5. Servisler arası çağrıda `X-Internal-Api-Key` zorunlu.
6. Boş env var = özellik kapalı + fallback (`SOROBAN_RPC_URL` boşsa
   chain-gateway yalnız Horizon modunda açılır).

## 3. Çek + Havuz'un Zincir Üstü Temsili

`contracts/soroban/pay-escrow` — tek kontrat, hem Çek hem Havuz. Klasik
Claimable Balance MVP'de **kullanılmaz**; gerekçe kontratın kendi
`lib.rs`'indeki modül dokümanındadır. Fonksiyonlar, durumlar ve
değişmezlerin (D1-D9) kontrat
karşılığı için `contracts/soroban/pay-escrow/README.md`'ye bakın.

## 4. Para ve Sayı Tipleri

`backend/pkg/money.Amount` tipi
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

## 7. MVP'de Bulunmayanlar

Bu depo mobil istemciyi, monolith dağıtım profilini, Redis'i, Temporal gibi
kalıcı workflow altyapısını ve üretim gözlemlenebilirlik yığınını içermez. Servislerin
dağıtımı için `deploy/docker-compose.yml`, kapsam dışında kalan işler için
[`SERVICE.md`](../../../../SERVICE.md) güncel kaynaktır.
