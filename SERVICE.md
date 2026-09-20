# Kapsam sınırlaması ve açık işler

Bu dosya, kod içindeki yorumların işaret ettiği "SERVICE.md" — backend'in
kasıtlı olarak dar bıraktığı yerlerin tek listesi. Plan dosyasındaki "Açık
Varsayımlar" bölümünün somutlaştırılmış hâlidir; birini kapatmadan önce
burayı ve ilgili kod yorumunu güncelleyin.

## 1. `/sync`, zinciri değil yerel önbelleği okur

`services/cheque/service.go`'daki `Sync()`, `pay.cheques` ve
`pay.pool_deposits`'i doğrudan döner — kontrattaki `get_cheque`/`get_pool`'u
`simulateTransaction` ile çağırıp ScVal'i çözerek bağımsız bir zincir
doğrulaması yapmaz. Yerel önbellek şu yollarla dürüst tutulur:

- Yazma uçları (`lock`/`claim`/`force_collect`/havuz) zaten chain-gateway
  üzerinden gerçek zincir durumunu (bakiye, trustline) kontrol eder.
- İstemci, `pay-tx-service` bir submit'i başarıyla tamamladığında
  `confirm-*` uçlarını çağırır — bu an, tx-service'in zincirle **doğrudan**
  konuştuğu andır, istemcinin kendi beyanı değildir.
- `pay-scheduler-service` süresi dolan çekleri bağımsız olarak tarar ve
  iade eder.

**Kapatma yolu:** `pay-chain-gateway`'e `get_cheque`/`get_pool` için salt-okunur
bir simulate-passthrough uç ekle, `xdr.ScVal`'i `contracts/soroban/pay-escrow`
struct'larıyla birebir eşleşecek şekilde çöz (ScVec/ScMap sırası kontratın
`#[contracttype]` türetmesiyle eşleşmeli — canlı ağda doğrulanmadan
varsayılmasın), `/sync`'i bununla değiştir.

## 2. `force_collect` ön-yetki XDR'ı canlı ağda doğrulanmadı

`pkg/stellarx/stellarx.go`'daki `BuildForceCollectAuthEntry`, CAP-46-11'i
harfiyen izler ve `cargo test`'te XDR round-trip'i geçer, ama gerçek bir
cihazın imzaladığı bir `SorobanAuthorizationEntry`'nin `pay-escrow`'un
`force_collect`'indeki `sender.require_auth()`'u gerçekten tatmin ettiği
testnet'te henüz doğrulanmadı. İnşa sırasının 2. adımı (kontrat deploy)
tamamlandıktan hemen sonra ilk doğrulanacak şey budur.

## 3. Anchor işlem durumu: istemci kendi bildirir

`pay-scheduler-service`, `pay-anchor-service`'in anchor JWT'sini hiç
tutmaması kararı yüzünden anchor'a kullanıcı adına soramaz (bkz.
`docs/reference/platform/anchor-entegrasyonu.md`). Durum, istemcinin
`POST /anchors/{id}/transactions/{txId}/report` ile kendi gözlemini
bildirmesiyle güncellenir. Kabul edilmiş bir ödünç (plan Açık Varsayım #3).

## 4. `cmd/monolith` yazılmadı

Plan `pay-monolith` (:8080, tüm servisler tek process) öngörüyordu.
`ports/directadapter` şu an yalnızca `ChainGateway` için var; `tx` ve
`cheque` servisleri arası (aslında yok — client her ikisini de ayrı ayrı
çağırıyor) ve `scheduler`'ın `cheque`'e HTTP bağımlılığı için birer
direct adapter eksik. Mikroservis profili (`deploy/docker-compose.yml`)
tam çalışır durumda; monolith `docker-compose.mono.yml` bilinçli olarak
eklenmedi — var olmayan bir binary'ye işaret eden bozuk bir compose
dosyası yazmaktansa açıkça ertelemek tercih edildi.

## 5. [Kapatıldı] Servis-katmanı birim testleri yazıldı; entegrasyon testleri hâlâ yok

Her dört stateful servis (`cheque`, `tx`, `auth`, `anchor`) artık bir
`<domain>Repo` arayüzü üzerinden `*dbx.Pool` yerine test edilebilir bir
`repos func() (<domain>Repo, error)` alanına sahip; `newServiceWithRepo`
test seam'i bellek-içi bir sahte repo enjekte ediyor. `pkg/authx`,
`pkg/httpx`, `pkg/nethost`, `pkg/envx`, `ports/httpadapter`,
`ports/directadapter`, ve altı servisin (`cheque`, `tx`, `auth`, `anchor`,
`chain`, `scheduler`) `service_test.go`/`handler_test.go` dosyaları
(`ports/portstest.FakeChain` paylaşılan `ports.ChainGateway` sahtesiyle)
150+ test vakası ile eklendi — `go test ./...` Docker'sız, saniyeler
içinde çalışıyor. Bu tur ikisini de bulup düzeltti: `/pool/confirm-deposit`
ve `/pool/confirm-withdraw`'ın `money.ParseAmount`'tan hiç geçmeyen ondalık
tutar hatası, ve üç `confirm-*` handler'ının sessizce yutulan JSON decode
hatası (en ağırı `ConfirmForceCollect`'in bozuk gövdeyi `collected=false`
sanması).

Hâlâ yok: testcontainers tabanlı gerçek Postgres entegrasyon testleri (SQL'in
kendisi — partial unique index, `UNIQUE(cheque_id, from_state, to_state)`
transition guard'ı, `NUMERIC` taşması — hâlâ sadece migration dosyalarında,
hiçbir testte doğrulanmıyor). `pkg/money`/`pkg/stellarx` birim testleri ve
kontratın 17 testi (`cargo test`, `contracts/soroban/pay-escrow`) değişmedi.

## 6. `scripts/e2e.sh` yalnızca mutlu yolu kapsıyor

Plan'ın Doğrulama bölümündeki 4 senaryodan yalnızca 1.si (lock→claim→Claimed)
scriptlenmiş durumda. 2-4 (force_collect, süre aşımı iadesi, havuz kilidi)
kontrat testlerinde (`test.rs`) doğrulanıyor ama servisler üzerinden uçtan
uca scriptlenmedi.

## 7. `pay-anchor-service`'in SEP-6/12/38 proxy'si yalnızca JSON gövdeyi destekliyor

`services/anchor/handler.go`'daki `sepProxy` her gövdeyi `json.Valid` ile
doğrular ve `client.go`'daki `ProxyJSON` her zaman `Content-Type:
application/json` zorlar. Gerçek SEP-12 KYC akışı kimlik fotoğrafı gibi
dosyalar için `multipart/form-data` kullanabilir — bu proxy üzerinden
**çalışmaz**. TR Mock Anchor "KYC otomatik onaylanır, dosya gerekmez"
dediği için MVP'de sorun değil; gerçek bir anchor'a geçişte bu proxy'nin
multipart gövdeleri de aktarması gerekecek (`io.Copy` + orijinal
`Content-Type`'ı koruma).

## 8. [Kapatıldı] `pay-anchor-service.cachedInfo` için eşzamanlılık testi eklendi

`services/anchor/service_test.go`'daki `TestInfo_ConcurrentCallsAreRaceFree`,
50 goroutine'in `Info()`'u eşzamanlı çağırmasını `go test -race` altında
kanıtlıyor. `infoMu` kaldırılırsa bu test race detector'ı tetikler.

## 9. [Bilinçli kullanıcı kararı] Eligible Integration Partner entegrasyonu yok

`Pro Hackathon 2026 Tracks Handbook`'un "Genesis and Scale Track
Requirements" madde 1'i, listedeki (DeFindex, Blend v2, Aquarius,
Soroswap, Stellar Broker, Circle CCTP, Near Intents, Allbridge, Stellar
Wallets Kit, Privy, DFNS, Bridge, BlindPay) veya tam SCF Integration
List'ten bir protokolle entegrasyon istiyor. `pay-escrow` bizim kendi
yazdığımız bir kontrat — listedeki hiçbir protokolle entegre değiliz.
Bu, **Ecosystem Fit** kriterinin "Integrates an eligible Stellar
protocol" maddesini karşılamıyor. Kullanıcı bu turda bilerek
kapatmamayı seçti (bkz. plan dosyası "Uygunluk İncelemesi: Rise In ×
Stellar Pro Hackathon 2026 Handbook", Bulgu A).

**En doğal kapatma yolu:** Havuz (Pool) özelliği şu an parayı yalnızca
`pay-escrow`'da tutuyor, getirisiz. `pay-cheque-service`'in
`PoolDepositXDR`/`PoolWithdrawXDR`'ını, ham escrow yerine (veya ona ek
olarak) bir **DeFindex** vault'una yönlendirmek hem ürünün kendi
mantığına (rezerve para atıl durmasın) oturur hem de bu gereksinimi
kapatır. Gerekli değişiklik: `pay-cheque-service`'e bir DeFindex
istemcisi + vault contract ID config'i eklemek, `deposit`/`withdraw`
XDR'larını DeFindex'in `invoke` şemasına göre kurmak.

## 10. [Bilinçli kullanıcı kararı] Front-end / canlı public demo yok

Handbook'un submission zorunlulukları arasında "Front-end / application
URL" ve "Working live demo (a functional, publicly accessible
application that judges can interact with)" var. Bu repo yalnızca
backend — `docker compose` yerel ağda çalışıyor, hiçbir yerde public
deploy edilmiş değil, hiçbir web/mobil arayüz yok. Bu, **Technical
Implementation** ve **User Experience** kriterlerinin büyük kısmını ve
submission portal'ının doğrudan zorunlu iki maddesini karşılamıyor —
handbook'un en sert teslim şartıdır. Kullanıcı bu turda bilerek
kapatmamayı seçti (aynı plan dosyası, Bulgu B); `CLAUDE.md`'nin "frontend
ayrı aşama" kararıyla tutarlı.

**Kapatma yolu (asgari):** API'yi (en azından `pay-cheque-service` +
`pay-tx-service` + `pay-anchor-service`, APISIX arkasında) bir public
host'a (fly.io, Railway) deploy etmek + `scripts/e2e.sh`'ın adımlarını
sürebilen minimal bir web sayfası (Flutter beklemeden, tek sayfalık bir
demo istemcisi) eklemek.

## 11. `pay.audit_log` ve `pay.trustlines` fiilen ölü tablo

`pay.audit_log` migration'da (`000001_init.up.sql`) var ama Go kodunun
**hiçbir yerinden** yazılmıyor — `architecture.md §11`'in vaat ettiği
"append-only audit trail" (quote/XDR üretimi, submission, risk reddi)
gerçekte tutulmuyor. `pay.trustlines` ise yalnızca
`services/anchor/repository.go`'daki `SetTrustline` ile **yazılıyor**,
hiçbir yerden `SELECT` edilmiyor — `pay-cheque-service` kendi trustline
kontrolünü doğrudan `chain.GetTrustline` ile zincirden yapıyor, bu tabloyu
hiç okumuyor. İkisi de şema borcu; kapatma yolu ya gerçekten kullanmak ya
da migration'dan çıkarmak.

## 12. [Kapatıldı] HTTP sunucuları sertleştirildi

`pkg/httpx`'e üç ekleme: `Recover` (panic → 500 envelope, process ayakta
kalır — `TestRecover_NextRequestStillWorks` bunu kanıtlıyor),
`MaxBody` (`http.MaxBytesReader` sarmalayıcı, varsayılan 1 MiB), ve
`ListenAndServe` (`ReadHeaderTimeout` 5s, `ReadTimeout` 15s,
`WriteTimeout` 30s, `IdleTimeout` 60s, SIGINT/SIGTERM'de 15s drain'li
graceful shutdown). Altı `cmd/*/main.go` da artık
`httpx.ListenAndServe(ctx, addr, httpx.WithRequestID(httpx.Recover(logger,
httpx.MaxBody(1<<20, mux))), logger, opts)` kullanıyor; `pay-tx-service` ve
`pay-chain-gateway`, Horizon/Soroban round trip'i için `WriteTimeout`'u
`HTTP_WRITE_TIMEOUT_SECONDS` (varsayılan 60s) ile yükseltiyor.

## 13. Erişim logu yok

`httpx.WithRequestID` yalnızca `X-Request-Id` header'ı basıyor/taşıyor;
hiçbir yerde metod/yol/durum/süre loglanmıyor. `pkg/obs`'un "her log
satırı request_id taşısın" kuralının loglayacağı bir istek logu yok —
prod'da bir isteğin ne olduğunu yalnızca uygulama seviyesindeki hata
logları anlatıyor.

## 14. Asılı kalan idempotency key'ler kurtarılmıyor

`services/tx/repository.go`'daki `BeginSubmission`, `pay.idempotency_keys`'e
`status='pending'` yazıp submit'i dener; süreç tam bu sırada ölürse (crash,
OOM, deploy) key sonsuza dek `pending` kalır ve `ErrKeyInFlight` yüzünden
aynı Idempotency-Key ile hiçbir zaman yeniden denenemez (kalıcı 409).
`expires_at` kolonu (24 saat) var ama onu okuyup temizleyen hiçbir iş yok —
`pay-scheduler-service`'e doğal bir iş.

## 15. `pay-scheduler-service`, `pay-tx-service`'i atlıyor

`CLAUDE.md`'nin "Yalnızca `pay-tx-service` transaction submit eder" kuralına
rağmen `services/scheduler/service.go`'daki `refundOne`/`BumpEscrowInstance`
doğrudan `chain.SubmitSoroban` çağırıyor — belgelenmemiş tek istisna
(keeper anahtarının fee-payer-only doğası nedeniyle risk düşük, ama kural
metninde bu istisna yok). Ayrıca `SweepExpiredCheques`'te backoff/dead-letter
yok: sürekli başarısız olan bir çek her `SWEEP_INTERVAL_SECONDS`'ta (varsayılan
60sn) sonsuza dek yeniden denenir.

## 16. Servis portları APISIX'i bypass ediyor

`deploy/docker-compose.yml` her servisi (8081-8086) doğrudan host'a açıyor;
`deploy/apisix/apisix.yaml`'daki rate-limit/CORS/`internal-deny` yalnızca
9080 (APISIX edge) üzerinden geçen trafiğe uygulanıyor. Ayrıca
`pkg/authx/authx.go`'daki `RequireInternalKey` yorumu "gateway bu header'ı
sıyırır" diyor ama `apisix.yaml`'da `X-Internal-Api-Key`'i sıyıran/reddeden
hiçbir plugin yok — servis portları açık kaldığı sürece bu varsayım
doğrulanamaz.

## 17. [Kapatıldı] CI eklendi

`.github/workflows/ci.yml`: `go` işi `gofmt -l` (boş çıktı zorunlu),
`go build ./...`, `go vet ./...`, `go test -race ./...` (`backend/`
altında) çalıştırıyor; `contract` işi `cargo test`
(`contracts/soroban/pay-escrow`, 17 test) çalıştırıyor. Her push ve PR'da.

## 18. Down migration yok

`000001_init.up.sql` (ve bu turda eklenen `000002_pool_deposit_at.up.sql`)
tek yönlü; `migrate ... down` için karşılık gelen `.down.sql` dosyaları yok.

## 19a. [Kapatıldı] APISIX, `POST /cheques`'i (ve `GET /anchors`'ı) 404'lüyordu

`deploy/apisix/apisix.yaml`'daki `cheque` route'unun `uris` listesi
`/cheques/*` (glob) + `/sync` + `/pool/*` içeriyordu. APISIX'in radix-tree
router'ında `/cheques/*` **yalnızca** `/cheques/` ile başlayan (bir alt
segment içeren) yolları eşliyor — bir çek oluşturmak için kullanılan asıl
uç, `POST /cheques` (segment yok), eşleşmiyor ve edge (9080) `404 Route Not
Found` dönüyordu. Aynı gap, `anchor` route'unun `/anchors/*`'ında
`GET /anchors` (List) için de vardı — bu tur doğrulama sırasında ek olarak
bulundu. Her iki route'un `uris` listesine segment'siz satır
(`/cheques`, `/anchors`) eklendi; `scripts/smoke.sh`'a bu iki uç için
kimliksiz çağrının 401 (404 değil) dönmesini doğrulayan iki kalıcı kontrol
eklendi.

## 19. JWT `aud`/`iss` taşımıyor

`pkg/authx.Claims` yalnızca `stellar_account` ve (bu turdan itibaren)
`sub` taşıyor; SEP-10 sonrası JWT'ler genelde `WEB_AUTH_DOMAIN`'e `aud`
olarak bağlanır. Anahtar tamamen kendi imzamız olduğu için istismar yüzeyi
dar, ama spec uyumu eksik.

## 20. [Kapatıldı] İstemci ağ parolası artık `/sync`'ten geliyor; anchor challenge'ı kendi parolasını taşıyor

Eskiden `frontend/lib/core/config/env.dart`'taki `networkPassphrase` sabit
testnet değeriydi (`const`), oysa `gatewayBaseUrl` `--dart-define` ile başka
bir backend'e yönlendirilebiliyordu. Backend pubnet XDR üretirse istemci yine
testnet ağ kimliğiyle imzalıyordu: imza yapısal olarak geçerli ama
kriptografik olarak yanlış oluyordu, hiçbir hata fırlamıyordu — yalnızca
Horizon'un `tx_bad_auth`'u olarak görünüyordu. Ayrıca `anchor_api.dart`
anchor SEP-10 challenge yanıtındaki `network_passphrase` alanını atıyor,
`anchor_providers.dart` challenge'ı `Env` parolasıyla imzalıyordu.

Kapatıldı:
- `backend/services/cheque` `Sync`'in döndürdüğü `/sync` yanıtına
  `networkPassphrase` eklendi (`SyncView.NetworkPassphrase`). `/sync` her
  soğuk açılışta imzalanan hiçbir şeyden önce koşulsuz çalıştığı için
  istemci artık backend'in gerçekte imzaladığı ağı öğreniyor
  (`networkPassphraseProvider`, `frontend/lib/state/sync_providers.dart`).
  `Env.networkPassphrase` (artık `--dart-define=NETWORK_PASSPHRASE`
  ile de yapılandırılabilir) yalnızca ilk sync'e kadarki fallback.
- Anchor SEP-10 zinciri (`anchor/client.go`'daki `SEP10Challenge` →
  `service.go`'daki `Challenge` → `handler.go` → `anchor_api.dart` →
  `anchor_providers.dart`) artık upstream'in `network_passphrase`'ini
  ucundan ucuna taşıyor; anchor alanı yayınlamıyorsa istemci kendi
  parolasına düşüyor (SEP-10'da alan opsiyonel).
- Altı `cmd/*/main.go`'daki tekrarlanan testnet literali
  `stellarx.TestNetworkPassphrase` tek sabitine indirildi.
- Settings ekranındaki sabit "Testnet" etiketi gerçek ağdan türetilen
  `Env.networkLabel`'a bağlandı (`Testnet`/`Public`/`Custom`).
- `docker-compose.yml`'de `pay-anchor-service`'e enjekte edilen ama hiç
  okunmayan `NETWORK_PASSPHRASE` kaldırıldı.

## 21. `tx_failed` işlem düzeyinde kodun ötesine geçmiyor

`chain.SubmitClassic`, Horizon reddinde yalnızca `TransactionCode`'u
(`tx_failed`, `tx_bad_seq`, …) `resultCode` olarak döner; operasyon düzeyi
kod (`op_low_reserve`, `op_no_issuer`, …) düşürülüyor. Bu yüzden istemci
"yetersiz rezerv" ile diğer `tx_failed` sebeplerini ayırt edemez ve genel
bir XLM ipucu gösterir. Kapatma yolu: `codes.OperationCodes`'u `ResultCode`'a
eklemek (ör. `tx_failed:op_low_reserve`) ve `ErrorCopy`'yi buna göre
genişletmek.

## 22. `cheque.request_used` kaybolan yanıtta kalıcı bir 409'a dönüşebilir

`services/cheque/repository.go`'daki `CreateReservedCheque`,
`uq_cheques_receiver_request` (migration `000003`) ihlalini
`ErrRequestUsedInRepo`'ya çevirir. Ama istemci `POST /cheques`'in
**yanıtını** kaybedip (ağ kopması) aynı `requestId` ile yeniden denerse,
kayıt zaten `IMZALI_REZERVE`'de duruyor olduğundan ikinci istek
`cheque.request_used` alır — çek kendisi geçerli olsa bile istemci bunu
göremez (`chequeId`'yi hiç almadı). Backend'in idempotency anahtarı yok;
tek çıkış yolu istemcinin `/sync`'i (aynı `requestId`'yi taşıyan bir
`IMZALI_REZERVE`/`FONLANIYOR` çek varsa) bu durumu ayırt etmesidir —
şu an `frontend`'de bu ayrım yapılmıyor, kullanıcıya "zaten ödendi"
gösterilir ve alıcı yeni bir talep üretmek zorunda kalır. Kapatma yolu:
`POST /cheques`'e de `Idempotency-Key` desteği eklemek (mevcut
`pay.idempotency_keys` mekanizması `/tx/submit`'e özel, cheque yaratmaya
genişletilmedi).

## 23. Çevrimdışı ödeme sequence çakışmasını yalnızca Horizon yakalar

`frontend/lib/data/stellar/offline_account_cache.dart`'taki
`OfflineAccountSnapshot`, son online anın fotoğrafıdır. Aynı hesaptan
snapshot alındıktan sonra (başka bir cihaz, ya da online moddaki normal
bir çek/havuz işlemiyle) sequence numarası ilerlerse, o snapshot üzerine
inşa edilmiş bir çevrimdışı ödeme `POST /tx/submit`'e ulaştığında
`tx_bad_seq` ile reddedilir — istemci bunu yalnızca ağa çıktığında öğrenir,
offline'ken önceden kestiremez (D6 gereği zaten böyle olması beklenir:
nihai doğruluk zincirde). `pay-tx-service` bu senaryo için özel bir hata
kodu ayırmıyor, genel `tx.submit_failed` + Horizon `resultCode`'u
(`ErrorCopy._submitResultMessages['tx_bad_seq']`) kullanıcıya "hesabınız
imzalama sırasında değişti, tekrar deneyin" olarak gösteriliyor — bu
mesaj çevrimdışı ödeme bağlamında biraz yanıltıcı (kullanıcı hiçbir şeyi
kendisi imzalamamış olabilir, ikinci bir cihaz/oturum sequence'ı
ilerletmiş olabilir). Kapatma yolu: `offline_payment` amaçlı
gönderimlerde bu koda özel bir metin.

## 24. Yeni hesaplar friendbot ile otomatik fonlanıyor (yalnızca testnet)

`pay-auth-service`, ilk başarılı SEP-10 login'de (`services/auth/service.go`
`fundIfNeeded`) hesabı zincirde `GetAccount` ile kontrol eder; yoksa
`ports.ChainGateway.Fund` üzerinden testnet friendbot'unu çağırır. Amaç: hiç
XLM tutmamış yeni bir cüzdanın kendi ilk işleminin ücretini bile ödeyemediği
"0 bakiyeli başlama" durumunu ortadan kaldırmak.

Tasarım kararları:

- **Best-effort, asla login'i başarısız kılmaz** — `pkg.audit_log`'a yazma
  hatasının login'i etkilememesiyle aynı kalıp (madde 11). Friendbot rate
  limit'e takılırsa veya Horizon geçici olarak cevap vermezse kullanıcı yine
  giriş yapar, hesabı 0 bakiyeli kalabilir; bir sonraki login'de tekrar
  denenir (tetikleyici "DB satırı yeni mi" değil, "zincirde hesap var mı").
- **Yalnızca testnet.** `FUND_NEW_ACCOUNTS` env'i açıkça verilmemişse
  varsayılan, `NETWORK_PASSPHRASE`'in testnet parolasıyla eşleşip
  eşleşmediğine bakar (`cmd/authsvc`, `cmd/monolith`'teki
  `shouldFundNewAccounts`) — mainnet'te friendbot zaten yok, kod kendiliğinden
  kapanır.
- **Friendbot ayrı bir host'tur, `FRIENDBOT_URL` ile yapılandırılır.**
  `chain.Service.Fund` önce SDK'nın `horizonclient.Fund`'ını kullanıyordu;
  Horizon `/friendbot`'a `friendbot.stellar.org`'a **307 redirect** verir ve
  `pkg/nethost` allow-list'i redirect hop'larını da denetler — allow-list'te
  yalnızca Horizon/Soroban olduğundan istek her seferinde `host not
  allow-listed` ile reddediliyor, hem login'deki otomatik fund hem
  `POST /auth/fund` sessizce `funded:false` dönüyordu. Artık `Fund`
  `FRIENDBOT_URL`'i (varsayılan `https://friendbot.stellar.org`) doğrudan
  çağırır ve host'u allow-list'e eklenir. Boş değer = fund kapalı
  (`chain.funding_disabled`, "boş env var = özellik kapalı" kalıbı).
- **Uygulamanın tek varlığı USDC; XLM yalnızca ağ ücreti bakiyesidir.**
  Cheque, havuz ve anchor (TRY ↔ USDC, SEP-6) hep `ASSET_CODE`/`PayAsset.configured`
  üzerinden çalışır. Friendbot yalnızca XLM verdiği için "funded" bir cüzdan
  havuza/cheque'e hazır **değildir**: önce USDC trustline'ı, sonra bank
  sekmesinden TRY deposit'i gerekir. Arayüz tek birim gösterir: **USDC**. XLM
  (ağ ücreti + rezerv için her hesapta zorunlu) kullanıcıya hiçbir yerde
  tutar/birim olarak yazılmaz — ne bakiye kartında, ne aktivitede, ne hata
  metinlerinde; yalnızca `AccountBalances.feeBalanceLow` (< 2 XLM) Home'da
  birimsiz bir "ağ ücreti bakiyeniz düşük" ipucu çıkarır. Havuz sayfası
  trustline/USDC yoksa nedenini ve çözüm ekranını söyler. (Eskiden havuz
  sayfası "XLM" yazıp kontrat USDC çektiği için deposit simülasyonda sessizce
  düşüyordu.)
- **"Get test funds" (yalnızca testnet) USDC getirir** — friendbot USDC veremez
  (ihraççı bizim değil), bu yüzden istemcide `StarterFunds`
  (`frontend/lib/state/starter_funds.dart`) tek akışta: (1) ağ ücreti — hesap
  zaten var ve ücret bakiyesi yeterliyse friendbot hiç çağrılmaz, aksi hâlde
  `POST /auth/fund` ve hesap Horizon'da görünene kadar bakiye yeniden okunur,
  (2) USDC trustline'ı — Horizon bakiyesinde (sıfır bakiyeli satır dahil)
  yoksa kurulur, `/sync` turu gerekmez, (3) TR Mock Anchor'dan 1.000 TRY'lik
  SEP-6 deposit + sandbox `simulate-bank-transfer`, anchor final duruma gelene
  kadar 1 sn aralıkla poll (en çok 60 tur), `reportTransaction`. Anchor'ın
  SEP-10 girişi (1) ve (2) ile **paralel** başlar. Anchor `pending_trust`
  derse (trustline'ı bekliyor) trustline bir kez kurulup poll'a dönülür;
  ard arda 3 poll hatası anchor'a ulaşılamıyor sayılır ve hemen raporlanır.
  Her adım tekrarlanabilir; kısmi başarıdan sonra yeniden basmak kaldığı
  yerden devam eder.
  Tetikleyiciler: yalnızca Settings satırı (Home kartında buton **yok**) ve
  yeni cüzdanın Home'a ilk varışında **cüzdan başına bir kez** otomatik çalışma
  (bayrak `ghoStellarStarterFundsOffered_<publicKey>`; başarısızlık kendi
  kendine tekrar denenmez, kullanıcı Settings'ten dener). Banka bekleme adımı
  overlay'de "Continue in background" sunar: kapatılırsa akış sessizce sürer,
  sonuç (veya hata) bittiğinde yine gösterilir. `ApiClient` artık zaman aşımı
  taşır (bağlanma 10 sn, gönderme/alma 30 sn; Dio'nun varsayılanı sonsuzdu) ve
  `balancesProvider` Riverpod 3'ün otomatik yeniden denemesini kullanmaz
  (başarısız okuma dakikalarca "yükleniyor" kalıyordu). Giriş sırasındaki
  sunucu tarafı `fundIfNeeded` XLM koymaya devam eder — fakat XLM arayüzde
  görünmediğinden "hiçbir şey olmuyor" hissi vardı; asıl görünür sonuç artık
  USDC. Mock anchor kapalıyken (1) ve (2) yine de yapılmış olur, net bir hata
  gösterilir (`anchor.deposit_failed` / `anchor.deposit_pending`).
  Banka işlemlerinin geçmişi backend anchor ledger'ındadır; yerel aktivite
  loguna yazılmaz.
- **Simülasyon hataları artık kendi kodunu taşır:** `cheque.simulation_failed`
  (422). Önceden `cheque.bad_request`'e düşüp istemcide "Something went wrong"
  olarak görünüyordu. Ham simülatör mesajı yanıtın `message` alanında kalır.
- **USDC trustline açmaz.** Friendbot yalnızca native XLM verir; çek akışının
  ihtiyaç duyduğu trustline ayrı bir akıştır (SEP-6/24 anchor akışı veya
  manuel `change_trust`), burada ele alınmadı.
- `ports.ChainGateway.Fund` (`ports/ports.go`) daha önce üretim kodunda hiçbir
  çağırana sahip değildi (yalnızca testlerde kullanılıyordu) — artık
  `pay-auth-service`'in iki gerçek çağıranı var: `fundIfNeeded` (otomatik,
  login'de) ve `FundOwnAccount` (manuel, aşağıda).

**Manuel kurtarma yolu: `POST /auth/fund`.** Zaten sıkışmış (fonsuz hesapla
"Set up USDC" gibi bir işlemin `chain.account_not_funded`'a düşmüş) bir
kullanıcı, bir sonraki login'i beklemek zorunda kalmasın diye
`services/auth/handler.go`'daki `Fund`, çağıranın kendi (JWT'deki) adresini
`FundOwnAccount` ile fonlar. `fundIfNeeded`'dan farkı: `Exists` kontrolü
yapmaz (istisnasız dener — birkaç fazladan ücretsiz testnet XLM zarar
vermez) ve `pay.audit_log`'a yazmaz (bu, bir routine login olayı değil,
kullanıcının kendi tetiklediği bir eylem). İstemci tarafında Settings
sayfasındaki "Fund with testnet XLM" butonu bunu çağırır
(`frontend/lib/data/api/endpoints/auth_api.dart:fundTestnetXlm`). Her zaman
200 döner (`{"funded": true|false}`) — best-effort, `FundOwnAccount` hiçbir
zaman hata döndürmez.

**İlişkili sertleştirme: `chain.account_not_funded` / `anchor.account_not_funded`.**
Bu maddenin kapattığı asıl kullanıcı hatası ("Submitting to Stellar failed.
Try again." — USDC trustline kurulumunda) iki katmanlıydı: (1) yeni
cüzdanlar hiç fonlanmıyordu, (2) `anchor.TrustlineXDR`/`WithdrawPaymentXDR`
ve `cheque.PoolDepositXDR`/`PoolWithdrawXDR`, `chain.GetAccount`'un
`Exists:false` dönüşünü hiç kontrol etmeden `Sequence: 0` ile bozuk bir
işlem kurup imzalanmaya/Horizon'a gönderilmeye kadar bırakıyordu — Horizon'un
reddi (`tx_no_source_account` gibi) istemcinin bilinen dört kodundan
(`tx_insufficient_balance`/`tx_failed`/`tx_bad_auth`/`tx_bad_seq`) biri
olmadığı için jenerik hataya düşüyordu. (1) bu madde, (2) dört fonksiyona
eklenen `if !account.Exists { return errAccountNotFunded }` kontrolüyle
kapatıldı — `cheque.CreateCheque`'in kendi (dolaylı, `hasSufficientBalance`
üzerinden) yolu bilinçli olarak dokunulmadan bırakıldı.
