# NFC + QR ile Temaslı Ödeme

Bu doküman Flutter istemcisindeki "yaklaştır ve öde / okut ve öde" akışının
protokolünü ve bilinçli sınırlarını anlatır. NFC ve QR, iki telefon arasında
bir bilgi taşıyıcısıdır; ödemenin kendisi ya bilinen çek hattından (backend
üzerinden) ya da — internet yokken — tamamen istemci-taraflı imzalanmış bir
klasik Stellar ödemesinden geçer. Aşağıdaki iki ana bölüm bu ikisini ayrı ayrı
anlatır.

Kod: `frontend/lib/core/payments/payment_uri.dart` (payload formatları),
`frontend/lib/data/nfc/nfc_frame.dart` (APDU protokolü, platformdan bağımsız),
`frontend/lib/data/nfc/nfc_service.dart` (NFC orkestrasyonu),
`frontend/android/.../nfc/HceService.kt` (Android taşıyıcı),
`frontend/lib/state/tap_providers.dart` (alıcı oturumu),
`frontend/lib/state/offline_providers.dart` +
`frontend/lib/data/stellar/offline_payment_{builder,verifier}.dart`
(gönderen-offline yolu).

## 1. Neden yön "alıcı gösterir, gönderen okur"

`pay-escrow.lock()` alıcının adresini çek yazılırken zincire sabitler ve
`claim()` `receiver.require_auth()` ister. Kontratta hashlock, preimage ya da
claim-token yoktur. Yani gönderen alıcının adresini *önceden* bilmek zorunda:
bu bilgi alıcıdan gönderene akar. Ödeme sonrası ters yönde ikinci bir bilgi
(çekin `chequeId`'si, ya da gönderen offline'sa imzalı XDR'ın kendisi) akar
ki alıcı `/sync` beklemeden tahsil edebilsin.

## 2. NFC taşıyıcı protokolü (platformdan bağımsız)

Tek bir temas **çift yönlü bir takastır**: okuyucu telefon tag telefonun
yükünü **okur (GET)** ve kendi yükünü **yazar (PUT)**, aynı temasta. Bu,
bir iPhone'un — ki yalnızca okuyucu olabilir — hem ödeyip hem tahsil
edebilmesini sağlar: aynı temasta Android'in yükünü çeker, kendi yükünü
iter. Kimse rol değiştirmek zorunda kalmaz.

Payload'lar tek bir kısa APDU'dan uzun olabildiği için (çevrimdışı ödeme
~350 bayt) her iki yön de bayt ofsetiyle parçalanır (`nfc_frame.dart`):

- `SELECT AID` (`F047686F53746C`) — değişmedi, aynı zamanda yarım kalmış
  bir yazmayı da sıfırlar.
- `GET DATA` `00 CA P1P2 00`, P1P2 = ofset → `[toplam(2)] ‖ parça(≤200)` +
  `90 00`, ya da tag hiçbir şey sunmuyorsa `6A 82`. Son parça
  gönderildiğinde tag `onRead`'i tetikler.
- `PUT DATA` `00 DA P1P2 Lc data`, P1P2 = şimdiye kadar gönderilen bayt
  sayısı; ilk parça (ofset 0) 2 baytlık toplam uzunlukla başlar. Her kabul
  edilen parça `90 00` döner; son parça ulaştığında tag `onWritten`'ı
  tetikler. Tag yazma kabul etmiyorsa `69 85`.

`HceTagEmulator` (Dart, `nfc_frame.dart`) bu protokolün referans
davranışıdır — Android'deki `HceService.kt` satır satır aynısını uygular
(“Change one, change the other” yorumu koddadır) ve protokol testleri
(`test/unit/nfc_frame_test.dart`, 26 test) doğrudan bu emülatöre karşı
çalışır.

### Rol tablosu

| Cihaz | Rol |
|---|---|
| Android alıcı | tag (HCE) — talebi sunar, yazma kabul eder |
| iOS alıcı | okuyucu — kullanıcı "Tap sender's phone" ile başlatır (Apple NFC oturumlarının kullanıcı başlatmasını ister) |
| Android gönderen | `auto` — okuyucu penceresi ile tag penceresi arasında otomatik geçiş (~1.5sn), böylece hem başka bir Android'i hem bir iPhone'u yakalar |
| iOS gönderen | okuyucu |

Alıcı arama aşamasında Android gönderen doğrudan `reader` rolünü kullanır;
Android okuyucu modu aynı cihazdaki kart emülasyonunu kapattığı için burada
`auto` pencereleri gereksiz gecikme ve eşzamanlı okuyucu pencerelerinde
kaçırılan temaslar yaratır. Ödeme sonrası Android gönderenin `auto` rolü
korunur: bu aşamada iPhone alıcıya sunulacak bir tag penceresi de gerekir.

Geçerli çiftler: Android↔Android, Android alıcı↔iOS gönderen, iOS
alıcı↔Android gönderen. **iOS↔iOS: NFC yok, yalnızca QR** — Apple'ın Core
NFC'si üçüncü parti uygulamaların tag emülasyonuna izin vermez (HCE
yalnızca AB/Japonya'da Apple onaylı bir yetkiyle var), okuma tarafı da
`com.apple.developer.nfc.readersession.iso7816.select-identifiers`
entitlement'ı ister — ikisi de bu depoda `NfcService.canBeTag`/`canRead`
bayraklarıyla dokümante edilmiştir.

## 3. Payload'lar

### 3.1 Ödeme talebi — alıcı → gönderen (SEP-7)

```
web+stellar:pay?destination=G...&amount=25.50&asset_code=USDC
  &asset_issuer=G...&msg=ghoStellar&x_req=<uuid-v4>&x_exp=<unix-saniye>
```

| Alan | Zorunlu | Anlam |
|---|---|---|
| `destination` | evet | Alıcının `G...` adresi |
| `amount` | hayır | Düz ondalık string; yoksa gönderen kendi girer |
| `asset_code` + `asset_issuer` | hayır | Uygulamanın yapılandırılmış varlığıyla (`PayAsset.configured`) **birebir** eşleşmeli — kod tek başına yeterli değil, issuer de kontrol edilir. Native varlıkta issuer yok. |
| `x_req` | hayır | Tek kullanımlık nonce (≤ 64 karakter) |
| `x_exp` | hayır | Son kullanma, unix saniye |

Çıplak `G...` adresi de geçerli bir taleptir. **Bilinen sınır:** harici bir
Stellar cüzdanı bu URI'yi klasik bir `payment` sanır, `x_` alanlarını yok
sayar — internet varken ghoStellar↔ghoStellar akışında sorun değil, harici
cüzdanla kullanımda yalnızca "escrow + 7 günlük iade" garantisi geçerli
olmaz (ödeme kendisi yine de doğru şekilde çalışır).

### 3.2 Çek devri — gönderen → alıcı (internet varken)

```
ghostellar://cheque?id=<ULID>&from=G...&amount=25.50&req=<x_req>
```

`req` devri alıcının kendi başlattığı talebe bağlar. Sızan bir `chequeId`
zararsızdır: `claim-xdr` JWT'nin `stellar_account`'ını çekin
`receiverAddress`'iyle karşılaştırır, kontrat `receiver.require_auth()`
ister.

### 3.3 Çevrimdışı ödeme — gönderen → alıcı (internet yokken)

```
ghostellar://offline?tx=<imzalı-xdr-base64>&req=<x_req>&from=G...&amount=25.50
```

`from`/`amount` yalnızca **gösterim** amaçlıdır — alıcı hiçbir zaman bunlara
güvenmez, her şeyi `tx` alanındaki imzalı XDR'dan yeniden çıkarır
(`OfflinePaymentVerifier`).

## 4. Gönderen offline — escrow'suz düz Stellar ödemesi

**Ne zaman devreye girer:** `POST /cheques` `cheque.request_used` dışında
`network.error` ile başarısız olursa **ve** talep bir nonce taşıyorsa
(taranmış/dokunulmuş bir talep — elle yapıştırılan çıplak adreste nonce
olmadığı için offline yol hiç sunulmaz, çünkü alıcının bellekte eşleştirecek
bir talebi yoktur). Uygulama zaten çevrimdışı moda girmişse
(`offlineModeProvider`) online deneme hiç yapılmaz, doğrudan bu yola geçilir.

**Uygulamaya çevrimdışı girmek:** soğuk açılışta `AuthGatePage` ağ hatası alırsa
ve cihaz daha önce online olmuşsa (saklı oturum ya da önbellekte hesap
snapshot'ı) duvar yerine shell'e çevrimdışı modda girer; üstte bir şerit görünür.
Hiç online olmamış bir cüzdan çevrimdışı ödeme yapamaz (elinde imzalanacak
sequence/bakiye yoktur).

**İnternet gelince:** kuyruktaki imzalı zarf `POST /tx/submit` ile gönderilir
(idempotency anahtarı zarf hash'i, gönderen ve alıcı yarışsa da tek ödeme).
Çevrimdışı moddayken `AppShell` 15 sn'de bir sessizce internet arar; oturum
düşmüşse yeniden SEP-10 girişi yapılır (`AuthNotifier.ensureSession`), ödeme
oturunca bakiyeler tazelenir. Zincirin ilerisinde imzalanmış bir zarf
`tx_bad_seq` alırsa backend bunu kalıcı sonuç olarak cache'lemez; öncekiler
indiğinde aynı anahtarla yeniden denenir.

**Kullanıcıya açıkça söylenen ödünler:** para escrow'da değil; klasik bir
`Payment` operasyonu doğrudan alıcının hesabına gider. 7 günlük iade garantisi
yok. Soroban çek kilidi offline kurulamaz (simülasyon ağ ister), bu yüzden
bu yol tamamen klasik Stellar'dır.

### Akış

```
GÖNDEREN (offline)                        ALICI
POST /cheques → network.error
accountSnapshotProvider'dan
  önbellekteki bakiye+sequence okunur
OfflinePaymentBuilder: tek Payment op,
  memo = sha256(x_req), TimeBounds(0,+24s),
  imzalanır (KeyPair, cihazda)
accountSnapshotProvider.reserve():
  bakiye düşülür, sequence +1
offlineSpentRequestIdsProvider'a
  ve OfflinePaymentStore'a x_req yazılır
                    ──── NFC/QR (ghostellar://offline) ────→
                                          OfflinePaymentVerifier:
                                          tek Payment op mü, hedef ben miyim,
                                          varlık eşleşiyor mu, tutar ≥ istenen mi,
                                          memo = sha256(kendi x_req'im) mi,
                                          süre dolmamış mı, imza gerçekten
                                          kaynak hesaba mı ait (ed25519 verify)
                                          → geçerliyse pendingOfflinePaymentsProvider'a
                                            yazılır, "Payment received" (settlement
                                            pending) gösterilir
                    ←── (internet gelince, hangi taraf önce yakalarsa) ────
POST /tx/submit idempotencyKey=
  'offline-'+txHash(networkPassphrase)
```

`OfflinePaymentBuilder.feeStroops = 10000`, `validity = 24 saat` (24 saniye
DEĞİL — kısa bir pencere bu amaç için işe yaramaz, alıcının internete
dönmesini beklemesi gerekebilir).

### Doğrulama neyi kanıtlar, neyi kanıtlamaz

`OfflinePaymentVerifier.verify` **tamamen offline**, ağa çıkmadan:
tek operasyon + `PaymentOperation` mü, hedef adres benim mi, varlık kod+issuer
birebir eşleşiyor mu, tutar istenen asgariyi karşılıyor mu, memo tam olarak
`sha256(kendi ürettiğim x_req)` mi, `TimeBounds` var mı/süresi geçmiş mi/aşırı
uzak bir gelecekte mi, ve **imza gerçekten kaynak hesaba ait mi** (SDK'nın
`KeyPair.verify` ile ed25519 doğrulaması — `tx.hash(network)` üzerinden).

Bu bir istemci-tarafı kolaylıktır, nihai otorite değildir (D6): asıl
zorlama Horizon'un submit anında kötü imzayı veya fonsuz hesabı reddetmesidir.
Doğrulamanın sağladığı şey, alıcının bağlantıyı beklemeden **şimdi**
ödemenin değip değmediğini bilmesidir.

### Çifte harcamaya karşı üç katman

1. **`accountSnapshotProvider.reserve()`** — aynı offline oturumda ikinci bir
   ödeme, birincinin düştüğü bakiye ve +1 sequence üzerine kurulur; aynı
   fonu iki kez taahhüt edemez.
2. **`offlineSpentRequestIdsProvider` + `OfflinePaymentStore.markSpent`** —
   aynı `x_req` ikinci kez ödenemez (kalıcı, sunucu tarafı `requestId`
   tekilliğinin olmayışını telafi eder — bu yol hiç sunucuya uğramaz).
3. **`POST /tx/submit` idempotencyKey = işlemin kendi hash'i** — hem alıcı
   hem gönderen (hangisi önce online olursa) aynı imzalı XDR'ı gönderebilir;
   ikincisi `pay-tx-service`'in idempotency tablosundan `replayed` döner,
   çifte submit olmaz.

### Bilinçli sınırlar

- Sequence çakışması: aynı hesaptan offline'ken başka bir cihaz/oturum da
  ödeme imzalarsa (aynı önbelleklenmiş sequence'tan), ikincisi Horizon'a
  ulaştığında `tx_bad_seq` ile reddedilir — kullanıcıya "ödeme başarısız"
  gösterilir, para hareket etmez (D2 hâlâ geçerli: fon offline'ken de asla
  iki yerde birden taahhüt edilmez, yalnızca *hangi* imzanın ağa ilk
  ulaştığı offline bilinemez).
- `OfflineAccountSnapshot` son online anın bir fotoğrafıdır; snapshot'tan
  sonra başka bir cihazdan/offline oturumdan harcanmış olabilecek bir bakiye
  üzerinden imzalamak istemcinin bilemeyeceği bir risktir — yine Horizon'un
  reddiyle sonuçlanır, kullanıcı asla "borçlu" görünmez.
- Gönderen taahhüdü **imzalandığı an** geri alınamaz (nonce hemen
  "harcandı" işaretlenir) — online yoldaki "çek yazıldığı an" ilkesiyle
  aynı.

## 5. Sunucu tarafı tek kullanımlık talep (`requestId`)

İnternet varken yazılan bir çekte "bu talebi zaten ödedin" kontrolü artık
istemci belleğinde değil, sunucuda: `POST /cheques` gövdesine `requestId`
(talebin `x_req`'i) eklenir, `pay.cheques(receiver_address, request_id)`
üzerinde kısmi bir tekil indeks (migration `000003`) aynı talebe ikinci bir
çek yazılmasını `cheque.request_used` (409) ile reddeder. İstemci tarafı
`paidRequestIdsProvider`, `/sync`'teki `requestId` alanlı çekleri okuyarak
bunu **taramadan önce** yakalamaya çalışır (best-effort ön kontrol);
asıl garanti sunucudaki tekil indekstir.

Çevrimdışı ödemede bu indeks hiç devreye girmez (sunucuya hiç uğramaz) —
bu yüzden Bölüm 4'teki ayrı `offlineSpentRequestIdsProvider` mekanizması
gerekli.

## 6. Alıcı offline — bekleyen çek/ödemenin sessiz yeniden denenmesi

Alıcının kendisi offline olabilir: bir handoff'u (çek `chequeId`'si ya da
imzalı offline ödeme) kabul ettiğinde tahsil/gönderim denemesi ağ hatasıyla
başarısız olursa, `PendingHandoffsNotifier` / `PendingOfflinePaymentsNotifier`
(`state/inbox_providers.dart`, `state/offline_providers.dart`) kaydı
kalıcı olarak saklar ve sessizce (imzalama ekranı göstermeden) yeniden
dener: `add()` sırasında bir kez hemen, sonra 15 saniyede bir, ve
`AppShell`'in `didChangeAppLifecycleState` ile app öne geldiğinde. Yalnızca
sunucunun/ağın kalıcı olarak reddettiği (`cheque.expired`,
`cheque.not_found`, `cheque.terminal_state`, `tx.bad_request`) durumlar
kalıcı olarak düşürülür; her şey diğer türlü yeniden denenir.

## 7. Doğrulanmayanlar

NFC emülatörde çalışmaz; aşağıdakiler yalnızca gerçek cihazlarda
doğrulanabilir ve **henüz doğrulanmadı**:

- iOS derlemesi ve iPhone okuma/yazma — Mac + Xcode, Apple Developer
  portalında App ID için "NFC Tag Reading" yeteneği ve yeniden imzalanmış
  provisioning profile gerekir. `ios/Runner/Runner.entitlements` ve
  `Info.plist`'teki `NFCReaderUsageDescription` +
  `com.apple.developer.nfc.readersession.iso7816.select-identifiers` bu
  depoda hazır, ama derlenip cihazda çalıştırılmadı.
- Android okuyucu↔tag pencere alternasyonunun (`NfcRole.auto`) gerçek
  donanımda güvenilirliği; pencere süreleri (1.5sn) cihaza göre ayarlanması
  gerekebilir.
- Offline classic ödemenin testnet'te gerçekten ledger'a girmesi
  (`tx_bad_seq` davranışı dahil) ve iki cihaz arasında NFC ile taşınan
  ~350+ baytlık imzalı XDR'ın parçalı aktarımı.
- `POST /tx/submit`'in aynı offline ödeme için hem alıcıdan hem gönderenden
  gelen iki eşzamanlı isteğinde gerçekten `replayed: true` döndüğü canlı
  ağda doğrulanmadı (birim testlerde sahte `TxApi` ile doğrulandı, gerçek
  `pay-tx-service` ile değil).
