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

## 5. Entegrasyon testleri yazılmadı

`pkg/money` ve `pkg/stellarx` birim testleri var (`go test ./pkg/...`),
kontratın 17 testi geçiyor (`cargo test` içinde
`contracts/soroban/pay-escrow`). Servislerin `service_test.go` dosyaları ve
testcontainers tabanlı Postgres entegrasyon testleri (plan'ın Doğrulama
bölümünde öngörülen) henüz yok — bu, en büyük tek eksik test yüzeyi.

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

## 8. `pay-anchor-service.cachedInfo` için eşzamanlılık testi yok

`Info()`'daki `sync.Mutex` (bkz. kod yorumu) doğru ve mantık olarak
minimal bir düzeltme, ama bunu kanıtlayan (`go test -race` altında
race'i önce gösterip sonra düzeltmeyle geçen) özel bir eşzamanlı test
yazılmadı. Düşük öncelik — davranış zaten doğru, yalnızca regresyon
koruması eksik.

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
