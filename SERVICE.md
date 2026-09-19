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
