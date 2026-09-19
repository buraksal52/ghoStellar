# P2P Çek ve Havuz (Pool) Mimarisi

> **ghoStellar MVP Notu.** Bu doküman `C:\Projeler\De-Fi`'den değişmeden
> taşındı — tasarım (durum makinesi, değişmezler D1-D9, case kataloğu)
> aynen geçerli. Servis adları bu depoda `defi-*` değil `pay-*`
> (`pay-tx-service`, `pay-chain-gateway`, `pay-cheque-service`). Bölüm
> 10'daki üç açık varsayım MVP'de şöyle kapatıldı:
>
> - **§10.1** (Claimable Balance + Soroban escrow iş bölümü): kapatıldı.
>   Çek'in tüm hayat döngüsü tek Soroban kontratında
>   (`contracts/soroban/pay-escrow`) — gerekçe kontratın `lib.rs` modül
>   dokümanında ve platform mimarisinin "Kritik Mimari Karar" notunda.
> - **§10.2** (ön yetkinin zincir-üstü temsili): kapatıldı. Soroban'ın
>   `SorobanAuthorizationEntry`'si (`backend/pkg/stellarx.BuildForceCollectAuthEntry`) —
>   canlı ağda henüz doğrulanmadı, bkz. `SERVICE.md` madde 2.
> - **§10.3** (fee sponsorluğu): MVP'de yok, F2 durumunda alıcıdan minimum
>   XLM bakiyesi beklenir (Faz 2).
> - **§10.4** (G5 penceresi): 24 saat, kontratta `FORCE_COLLECT_WINDOW_SECONDS`
>   sabiti olarak.
> - **§10.5** (hangi servise yerleşir): `pay-cheque-service`.
>
> Devamı orijinal doküman — aşağıda değişmeden.

Bu dosya yaşayan bir referanstır. Kod değiştikçe bu dosya da güncellenir.
İlişki: `docs/reference/platform/architecture.md` (kısaca "ana mimari") bu
dokümanla çatışmazsa geçerlidir; çatışırsa ana mimari kazanır. Para tipi
kuralları (ana mimari Bölüm 7), event sözleşmesi (Bölüm 6), "yalnızca
`defi-tx-service` submit eder" ve "yalnızca `defi-chain-gateway` zincire
çıkar" kuralları (Bölüm 4) burada da aynen geçerlidir — ghoStellar'da bu
servisler `pay-tx-service` / `pay-chain-gateway`'dir.

| | |
|---|---|
| **Kapsam** | Kişiden kişiye para gönderme ("Çek") + ortak/kişisel para havuzu ("Pool"). Swap/lending/vault kapsamı dışında, ayrı bir akış. |
| **Zincir** | Stellar — Claimable Balance (classic) + Soroban escrow kontratı birlikte kullanılır (Bölüm 2). |
| **Custody** | non-custodial. Para hiçbir aşamada platform cüzdanında durmaz; ya kullanıcının kendi hesabında, ya zincir üstü escrow'dadır. |
| **Amaç** | Aşağıdaki beş kullanıcı kuralının, hiçbir durumda kullanıcıyı eksi bakiyeye düşürmeden, hiçbir durumda parayı kaybetmeden veya kilitlemeden çalışabileceğini kanıtlamak (Bölüm 3 Değişmezler). |

## 0. Kullanıcı Gereksinimleri (girdi)

Bu doküman aşağıdaki beş maddenin üzerine kuruludur; her biri Bölüm 6'da
bir veya daha fazla case grubuna karşılık gelir.

1. Yeterli parası olan kullanıcı Pool'a para gönderme (Çek) başlatabilir.
2. Pool'a para eklemek her zaman serbesttir; çekmek için en az 1 hafta
   geçmesi gerekir. Çek'in geçerlilik süresi de 1 haftadır.
3. Pool'a Çek'i aynı anda yalnızca 1 kişi başlatabilir, aynı anda
   yalnızca 1 kişi çekebilir. Her çekimden sonra alıcının onayı gerekir.
4. Gönderen online olduğunda parayı Pool'a atar; alıcı 1 hafta içinde
   almazsa para gönderene otomatik döner.
5. Alıcı online olduğunda mobil uygulama önce bekleyen işlemleri
   zincirden doğrular. Alıcı parayı alamadıysa (Pool boş/fonlanmamışsa),
   ön yetkiyle gönderenden zorla tahsil eder — ama kullanıcı hiçbir
   aşamada eksiye düşmez, çünkü para Çek yazılırken zaten rezerve
   edilmiştir.

## 1. Kavramlar

**Çek (Cheque)**
Gönderenden alıcıya, tutarı ve son kullanma tarihi sabit, tek atımlık bir
para taahhüdü. Klasik kağıt çek gibi: yazıldığı an karşılığı ayrılır, ama
nakde dönüşmesi ayrı bir adımdır.

**Havuz (Pool)**
İki yüzü olan zincir-üstü yapının ortak adı:

- **Mevduat yüzü**: kullanıcının kendi kilitli bakiyesi (Bölüm 7).
- **Çek yüzü**: kişiden kişiye transfer escrow'ları (Bölüm 4-6).

Teknik olarak Stellar Claimable Balance (süre koşullu, tek alıcı) +
gerektiğinde Soroban escrow kontratı (ön yetki, zorla tahsil mantığı
için) birlikte kullanılır — iş bölümü Bölüm 2'de.

**Rezerv (Reservation)**
Çek imzalandığı anda gönderenin harcanabilir bakiyesinden düşülen, henüz
zincire yazılmamış tutar. Aynı parayla ikinci bir Çek yazılmasını ve
eksiye düşmeyi mümkünsüz kılan yerel/zincir-önce kilit.

**Ön Yetki (Pre-authorization)**
Çek ile birlikte aynı anda imzalanan, tutarı/alıcıyı/son kullanma
tarihini sabitleyen, tek atımlık ikinci bir yetki. Yalnızca Pool
fonlanmadıysa ve süre içindeyse kullanılabilir (Bölüm 5).

**Zorunlu Mutabakat (Forced Sync)**
Mobil uygulamanın her açılışta, başka hiçbir ekran göstermeden önce,
kullanıcının bütün bekleyen Çek/Pool durumlarını zincirden okuyup yerel
defterle eşitlediği adım.

## 2. Zincir Üzerinde İş Bölümü: Claimable Balance + Soroban Escrow

İki mekanizma farklı sorunları çözer, birlikte kullanılırlar:

**Claimable Balance (classic Stellar)**

- Çek'in "havuzda bekleme" hâlini taşır: tek alıcı (claimant), süre
  koşulu (predicate: not-before / not-after), izinsiz iade.
- Native, ucuz, denetimi kolay. Süre dolunca **herkes** (izinsiz) iade
  claim'i tetikleyebilir — gönderen tek başına hapiste kalmaz.

**Soroban Escrow Kontratı**

- Ön yetkiyi ve "zorla tahsil" koşul kümesini taşır: yetkinin hâlâ
  geçerli olup olmadığını (süre + Pool'un fonlanmamış olması + tam
  tutar) kontrat mantığıyla doğrular.
- Çek yalnızca ön yetki gerektiriyorsa (Bölüm 5) devreye girer; salt
  "gönder ve bekle" akışında (Bölüm 6 Grup A/B/C) yalnızca Claimable
  Balance yeterlidir.
- Kontrat, Claimable Balance'ın id'sini referans tutar; aynı tutar iki
  mekanizmada birden "canlı" sayılmaz (Değişmez D1).

Böylece: normal akış native Stellar primitifiyle, tek zorluklu senaryo
(zorla tahsil) Soroban ile çözülür — gereksiz kontrat riski alınmaz.

## 3. Değişmezler (Invariants) — "hiçbir durumda patlamama" garantisi

Aşağıdaki liste, Bölüm 6'daki her case çözümünün dayandığı temel. Bir
case çözümü bunlardan en az birine açıkça bağlanmalı.

**D1 — Korunum**
Her birim para her an tam olarak TEK yerdedir: gönderende (rezerve),
Pool'da (Claimable Balance / escrow), ya da alıcıda. İki yerde birden
görünmez, hiçbir yerde kaybolmaz.

**D2 — Negatife düşme yok**
Rezerve edilen tutar, harcanabilir bakiyeyi aşamaz — Çek yaratma
isteğinin ilk adımı budur. Yetersiz bakiyeyle Çek YAZILAMAZ. Rezerv
konulduktan sonra bakiye başka bir yolla (başka bir Çek, başka bir işlem)
tekrar kullanılamaz; ikinci istek reddedilir.

**D3 — İdempotans**
Her durum geçişi `(cek_id, kaynak_durum, hedef_durum)` üçlüsüyle
tekildir. Aynı zincir olayı (reorg/replay dahil, ana mimari Bölüm 6) iki
kez işlenmez; aynı kullanıcı eylemi iki kez tetiklenmez
(Idempotency-Key, ana mimari Bölüm 5.2 örneğinde olduğu gibi).

**D4 — Terminal durum kapalıdır**
KAPANDI / IADE_EDILDI / HUKUMSUZ / KARSILIKSIZ durumlarından çıkış
yoktur. Bir Çek kapandıktan sonra yeniden açılamaz; yeni istek yeni bir
Çek'tir.

**D5 — Tek aktiflik (kullanıcının, konsept 3)**
Bir kullanıcının aynı anda en fazla: 1 aktif giden Çek'i, 1 aktif gelen
claim'i olur. Pool'a yatırma ve Pool'dan çekme de aynı anda tek
kişiliktir (Bölüm 7) — serileştirme kilidiyle sağlanır.

**D6 — Zincir otoritedir**
Yerel/backend defteri yalnızca önbellektir (ana mimari Bölüm 8).
Zincirdeki gerçek durumla yerel kayıt çelişkiye düşerse zincir kazanır;
yerel kayıt düzeltilir, kullanıcıya asla zincirdekinden farklı bir
bakiye gösterilmez.

**D7 — Zincir saati**
Tüm süre (1 hafta claim, 1 hafta çekim kilidi) kararları ledger zaman
damgasından (predicate not-after) okunur. Cihaz saati yalnız
görüntülemede kullanılır, hiçbir yetkilendirme kararında kullanılmaz.

**D8 — Ya hep ya hiç**
Kısmi fonlama, kısmi claim, kısmi zorla tahsil yoktur. Bir Çek ya tam
tutarıyla ilerler ya da o adımda hiçbir şey değişmez.

**D9 — Hiçbir taraf kilitlenmez**
Süresi dolmuş bir Çek'in iadesi izinsizdir (permissionless) — gönderen
sonsuza dek çevrimdışı kalsa bile para Pool'da hapsolmaz. Aynı şekilde
gönderen sonsuza dek çevrimdışı kalsa bile, süre içinde ön yetki varsa
alıcı parasını alabilir (Bölüm 5).

## 4. Çek Durum Makinesi

Ana hat:

```
TASLAK --> IMZALI(rezerve) --> FONLANIYOR --> HAVUZDA --> TALEP_EDILDI
  --> ONAYLANDI --> KAPANDI
```

Yan dallar:

```
                       +--> HUKUMSUZ            (hic fonlanmadan iptal/
                       |                          rezerv suresi dolumu)
IMZALI(rezerve) -------+
                       +--> FONLANIYOR (basarisiz tx) --> IMZALI(rezerve)
                                                            (yeniden dene)

HAVUZDA --> (1 hafta gecti, claim yok) --> IADE_EDILEBILIR
                                                  |
                                                  v
                                         IADE_EDILDI  (izinsiz tetiklenir,
                                                        herkes cagirabilir)

FONLANIYOR/HAVUZDA yok, on yetki var, sure dolmak uzere:
  --> ZORLA_TAHSIL_DENENDI --+--> KAPANDI       (gonderende tuttugu tutar
                              |                   vardi, tahsil basarili)
                              +--> KARSILIKSIZ   (yetersizdi/reddedildi --
                                                   D2 geregi bu asla
                                                   "kullanicinin borcu"
                                                   olarak islenmez, sadece
                                                   Cek'in kendisi biter)
```

Her geçiş için sorulan üç soru: (a) tetikleyen kim — gönderen, alıcı,
yoksa zamanlayıcı/izinsiz çağırım mı; (b) ön koşul ne — hangi zincir
durumu gerekli; (c) geri dönüşü var mı — yalnızca FONLANIYOR
başarısızlığında IMZALI'ya dönüş var, diğerleri tek yönlü (D4).

## 5. Ön Yetki ve Zorla Tahsil Koşulları

Ön yetki, **yalnızca** aşağıdaki üç koşul birden doğruysa kullanılabilir
— kontrat bunu zincir üzerinde doğrular, backend'e güvenilmez:

1. **Süre hâlâ içinde**: `now < son_kullanma_tarihi` (D7, ledger saati)
2. **Pool fonlanmamış**: bu Çek için Claimable Balance hiç oluşmamış
   VEYA oluşmuş ama hiç claim edilmemiş ve gönderen tarafından iade
   edilmemiş
3. **Tam tutar mevcut**: gönderenin ilgili hesabında rezerve tutar hâlâ
   harcanmadan duruyor (D2 sayesinde garanti — rezerv başka hiçbir
   işlemde kullanılamadığı için bu kontrol pratikte hep doğru çıkar)

Neden kullanıcı asla eksiye düşmez:

- Rezerv, Çek YAZILDIĞI anda ayrılır (Bölüm 3, D2) — "önce yetersiz
  bakiyeyle çek yaz, sonra tahsil sırasında açık ver" senaryosu Çek
  yaratma aşamasında zaten engellenmiştir.
- Uygulama ilk online olduğu anda (Bölüm 0 madde 5) her şeyden önce
  zorunlu mutabakatı (Bölüm 1, Forced Sync) çalıştırır; bekleyen zorla
  tahsil talepleri kullanıcıya başka hiçbir ekrandan önce gösterilir ve
  gerekiyorsa hemen zincire yazılır. Böylece "kullanıcının haberi
  olmadan bakiyesi değişti" durumu oluşmaz — kullanıcı değişikliği
  gördüğü anda zaten gerçekleşmiş olur, arada kullanıcının müdahale
  edebileceği bir "eksi bakiye penceresi" yoktur.
- Zorla tahsil BAŞARISIZ olursa (rezerv bir şekilde artık geçerli
  değilse — örneğin hesap kapatıldı/trustline silindi) sonuç
  kullanıcının BORCU olarak değil, Çek'in KARSILIKSIZ olarak kapanması
  şeklinde işlenir (D8: ya hep ya hiç). Alıcı zarar görür ama gönderen
  asla eksiye düşmez; bu durum Bölüm 6 Grup D'de ayrıca ele alınır.

Gönderen ön yetkiyi tek taraflı iptal edemez (D5/D9 ile çelişir); yetki
yalnız süresi dolunca veya Çek KAPANDI/IADE_EDILDI olunca geçersizleşir.

## 6. Uçtan Uca Akışlar

### 6.1 Mutlu Yol

```
Gonderen(online) --> Cek imzala (rezerve) --> Pool'a fonla
                                                    |
                                                    v
                                        Claimable Balance olusur
                                                    |
                                    (bildirim: defi-notification)
                                                    |
                                                    v
Alici(online) --> Zorunlu Mutabakat --> bekleyen claim gorulur
              --> claim et --> Pool'dan alicinin hesabina gecer
              --> ONAY ver (makbuz) --> KAPANDI
```

### 6.2 Alıcı Gelmedi (Süre Aşımı)

```
Gonderen --> fonla --> Claimable Balance (not-after = +1 hafta)
                                  |
                        1 hafta gecer, claim yok
                                  |
                                  v
                        IADE_EDILEBILIR (izinsiz)
                                  |
                  (herhangi biri -- scheduler veya alici/gonderen
                   kendisi -- iade cagrisini zincire yollayabilir)
                                  |
                                  v
                      para gonderenin hesabina doner --> IADE_EDILDI
```

### 6.3 Fonlama Boşluğu + Zorla Tahsil

```
Gonderen --> Cek imzala (rezerve + on yetki imzasi) --> [cevrimdisi kalir,
                                                          hic fonlamaz]
                                                    |
                                   (sure sayaci calisiyor, D7)
                                                    |
Alici(online olur) --> Zorunlu Mutabakat --> Pool bos oldugunu gorur
                   --> on yetki kosullari kontrol edilir (Bolum 5)
                   --> ZORLA_TAHSIL_DENENDI --> chain-gateway'e XDR
                                     |
                      +-------------+-------------+
                      v                           v
               basarili: rezerv            basarisiz: rezerv
               aliciya gecer               artik gecerli degil
                      |                           |
                      v                           v
                  KAPANDI                   KARSILIKSIZ
            (alici onay verir)        (gonderen eksiye DUSMEZ, D2/D8)
```

## 7. Pool Mevduat Kuralları (kullanıcının kendi kilitli bakiyesi)

- **Ekleme**: her zaman serbest, bekleme yok, anında kilitli bakiyeye
  eklenir.
- **Çekme**: yalnızca son ekleme işleminden itibaren >= 1 hafta
  geçmişse (D7, ledger saati). Erken çekme isteği zincir tarafından
  reddedilir — backend'e güvenilmez.
- **Eşzamanlılık (D5)**: aynı anda tek yatıran, tek çekim işlemi —
  ikinci istek, birincisi zincirde sonuçlanana kadar kuyruğa alınır
  veya reddedilip yeniden denenmesi istenir (kullanıcıya açık "işlem
  devam ediyor" mesajı gösterilir).
- **Çekimden sonra onay**: her başarılı çekimden sonra kullanıcıdan bir
  onay (makbuz) alınır — bu onay PARAYI bloke etmez, yalnızca defteri
  kapatır (Bölüm 9, Grup I).

## 8. Servis Sorumlulukları (kaba hat)

Ana mimarinin servis sınırları (Bölüm 4) burada da geçerlidir:

- **İmzasız XDR üretimi**: Çek/Pool akışına özel mantık (yeni veya
  mevcut bir servise eklenecek yüz — Bölüm 10'da açık).
- **Transaction submit**: yalnızca `defi-tx-service` (ana mimari
  kuralı).
- **Zincire çıkış**: yalnızca `defi-chain-gateway` (Horizon Claimable
  Balance API + Soroban RPC escrow çağrıları).
- **Süre dolumu tarama**: `defi-scheduler-service` — IADE_EDILEBILIR
  durumuna geçenleri periyodik tarar ve izinsiz iade çağrısını tetikler
  (kullanıcı beklemeden).
- **Bildirim**: `defi-notification-service` — fonlama, claim, zorla
  tahsil, iade olaylarında push/SSE.
- **Zorunlu Mutabakat**: mobil uygulama açılışında ilk çağrılan
  endpoint; kullanıcının tüm bekleyen Çek/Pool durumlarını tek istekte
  döner, başka hiçbir ekrandan önce çalışır (Bölüm 0 madde 5, Bölüm 5).

## 9. Case Kataloğu ve Çözümleri

Format: Durum -> Ne olur -> Neden patlamaz (hangi Değişmez).

### 9.A Oluşturma (Çek yazma)

**A1 — Yetersiz bakiye**
-> Çek yazma isteği ANINDA reddedilir, rezerv hiç konmaz.
-> D2: rezerv, harcanabilir bakiyeyi hiçbir zaman aşamaz.

**A2 — Bayat/çevrimdışı bakiye bilgisiyle istek**
-> Zincir üzerindeki güncel bakiye backend/kontrat tarafından yeniden
okunur; istek çevrimdışı önbelleğe değil, o ana ait zincir durumuna
göre değerlendirilir.
-> D6: zincir otoritedir.

**A3 — Kullanıcının zaten aktif bir Çek'i var**
-> İkinci Çek isteği reddedilir; önce mevcut Çek
KAPANDI/IADE_EDILDI/HUKUMSUZ/KARSILIKSIZ olmalı.
-> D5: tek aktiflik.

**A4 — Alıcı adresi geçersiz veya trustline/hesap yok**
-> Çek oluşturulmaz; kullanıcıya açıklayıcı hata (ana mimarinin
`{"error":{"code",...}}` zarfı, mesaja değil koda göre davranılır).
-> D1: para hiçbir zaman ulaşamayacağı bir yere kilitlenmez.

**A5 — Kendine gönderme**
-> Reddedilir (gönderen == alıcı Claimable Balance'ta anlamsızdır).
-> D8: anlamlı olmayan işlem hiç başlamaz.

**A6 — Sıfır veya negatif tutar**
-> Reddedilir, para tipi kurallarına göre doğrulanır (ana mimari Bölüm
7 — string miktar, işaretsiz/pozitif zorunluluğu).
-> D2.

### 9.B Fonlama

**B1 — Gönderen Çek'i imzaladıktan sonra hiç online olmadı**
-> Rezerv, süre dolana kadar tutulur; süre dolunca Çek HUKUMSUZ olur,
rezerv serbest kalır. Eğer ön yetki de varsa Bölüm 5/6.3 akışı devreye
girer.
-> D9: kimse sonsuza dek hapsolmaz.

**B2 — Fonlama tx'inin sonucu bilinmiyor (bağlantı koptu)**
-> Idempotency-Key ile aynı istek güvenle tekrar sorgulanır/gönderilir;
zincir durumu tek doğruluk kaynağı olarak okunur.
-> D3 + D6.

**B3 — Fonlama tx'i başarısız (fee, sequence, trustline)**
-> Çek IMZALI(rezerve) durumuna geri döner, kullanıcıya tekrar
denemesi için gösterilir; rezerv bozulmaz.
-> D2, D4 (henüz terminal değil, tek istisna geçişi).

**B4 — Rezerve tutar fonlama sırasında başka bir işlemde harcanmaya
çalışıldı (aynı kullanıcının başka bir akışı)**
-> Reddedilir; rezerv, harcanabilir bakiyeden zaten düşülmüştür (A1 ile
aynı mekanizma).
-> D2.

**B5 — Uygulama fonlama ortasında çöktü**
-> Bir sonraki açılışta Zorunlu Mutabakat çalışır, zincirdeki gerçek
durumu (fonlanmış mı, değil mi) okur, yerel durumu düzeltir.
-> D6, D3 (aynı fonlama iki kez tetiklenmez).

### 9.C Talep (Claim)

**C1 — Zamanında claim**
-> Standart yol, Bölüm 6.1.

**C2 — Alıcı claim etti ama onay vermedi**
-> Para zaten alıcıdadır (D1); onay yalnızca makbuz/defter kapatma
adımıdır, ayrıca hatırlatma bildirimi gönderilir, para bloke kalmaz.
-> Bölüm 9.I ile ilişkili.

**C3 — Alıcı Çek'i reddetti (almak istemiyor)**
-> Claimable Balance claim edilmeden bırakılır; süre dolunca normal
iade akışı (6.2) işler. Aktif ret özelliği istenirse aynı sonuca (erken
IADE_EDILEBILIR) bağlanır.
-> D9.

**C4 — Alıcı hiç gelmedi**
-> Bölüm 6.2.

**C5 — Süre sonu yarışı: claim ile iade aynı anda tetiklendi**
-> Zincir seviyesinde tek işlem kazanır (Claimable Balance predicate'i
bunu native olarak çözer: not-after'dan önce yalnızca claimant, sonra
yalnızca iade edilebilir); ikisi aynı anda geçerli olamaz.
-> D6, D8.

**C6 — Aynı Çek'e birden fazla cihazdan claim denemesi (aynı alıcı)**
-> Claimable Balance tek kullanımlıktır; ilk başarılı claim'den sonra
diğerleri zincirde doğal olarak başarısız olur, kullanıcıya "zaten
alındı" gösterilir.
-> D3, D8.

**C7 — Claim tx'inin sonucu bilinmiyor**
-> B2 ile aynı çözüm: zincirden yeniden okuma, Idempotency-Key.
-> D3, D6.

### 9.D Zorla Tahsil

**D1' — Koşullar sağlanmadan zorla tahsil denemesi (süre geçmiş / Pool
zaten fonlanmış / tutar yetersiz)**
-> Kontrat seviyesinde reddedilir (Bölüm 5); backend'in onayına gerek
yoktur, zincir kendi doğrular.
-> D6.

**D2' — Zorla tahsil anında gönderende tutar var**
-> Başarılı, Çek KAPANDI (Bölüm 6.3 sağ dal).
-> D2, D8.

**D3' — Zorla tahsil anında tutar artık geçerli değil (hesap kapandı,
trustline silindi, D2 rezervine rağmen olağandışı bir durum oluştu)**
-> KARSILIKSIZ; kullanıcı BORÇLU sayılmaz, yalnızca Çek başarısız
sayılır. Alıcı bildirim alır.
-> D2 (asla negatif), D8.

**D4' — Ön yetkinin süresi doldu**
-> Zorla tahsil artık hiçbir şekilde tetiklenemez; Çek zaten süre
dolumu akışıyla (6.2/HUKUMSUZ) kapanmış olmalıdır.
-> D4, D7.

**D5' — Aynı ön yetki iki kez kullanılmaya çalışıldı**
-> Tek atımlık: ilk kullanımda kontrat yetkiyi tüketir/işaretler,
ikinci deneme zincirde reddedilir.
-> D3, D8.

**D6' — Gönderen ön yetkiyi tek taraflı iptal etmeye çalışıyor**
-> İzin verilmez (D9 ile çelişir — alıcı tek taraflı hapsolmamalı);
yetki yalnızca doğal süre dolumu veya Çek'in terminal duruma
geçmesiyle biter.
-> D9, D4.

**D7' — Fonlama ile zorla tahsil aynı anda yarışıyor (gönderen tam o
an online olup geç kalmış fonlamayı gönderdi)**
-> Zincir seviyesinde kontrat, Pool'un fonlanıp fonlanmadığını aynı
işlem içinde kontrol eder (Bölüm 5 koşul 2); ikisinden yalnızca biri
geçerli olur, diğeri doğal olarak başarısız olur.
-> D6, D8.

### 9.E Çevrimdışılık

**E1 — İki taraf da uzun süre çevrimdışı**
-> Gönderen fonlamadıysa: süre dolunca rezerv serbest kalır (D9).
Gönderen fonladıysa: süre dolunca izinsiz iade çalışır (6.2, D9).
Hiçbir senaryoda para taraflardan birinin çevrimdışı kalması yüzünden
sonsuza kilitlenmez.

**E2 — Zorunlu açılış taraması başarısız oldu (ağ hatası)**
-> Uygulama tekrar dener, tarama tamamlanana kadar diğer ekranlara
geçişe izin vermez (kullanıcı deneyimi kuralı, zincir durumunu
değiştirmez).
-> D6.

**E3 — Cihaz değişimi / hesap kurtarma**
-> Kimlik zincir hesabına (anahtar/SEP-10) bağlı olduğundan (ana
mimari Bölüm 10), yeni cihazda da Zorunlu Mutabakat aynı zincir
durumunu okur; bekleyen Çek/Pool durumu cihazdan bağımsızdır.
-> D6.

**E4 — Alıcının birden fazla hesabı/cüzdanı var**
-> Claimable Balance belirli TEK bir claimant adresine yazılır; hangi
hesabın alıcı olduğu Çek oluşturulurken sabitlenir (A4), sonradan
değişmez.
-> D1, D8.

**E5 — Bildirim gitmedi (push başarısız)**
-> Zorunlu Mutabakat bir güvenlik ağı olarak çalışır; bildirim kaybı
iş sonucunu değiştirmez, yalnızca kullanıcının ne zaman haberdar
olduğunu geciktirir.
-> D6 (zincir zaten doğru durumda), D9.

**E6 — Cihaz saati yanlış/kullanıcı manuel değiştirdi**
-> Hiçbir süre kararı cihaz saatiyle alınmaz (D7); görüntülenen geri
sayım yalnız tahmini gösterimdir, gerçek karar zincir sorgusunda
verilir.

**E7 — RPC/Horizon veya Soroban RPC geçici kesinti**
-> `defi-chain-gateway` failover/retry/cache katmanından geçer (ana
mimari Bölüm 2); istek başarısız dönerse kullanıcıya "tekrar dene"
gösterilir, hiçbir yerel durum "başarılı" olarak işaretlenmez zincirden
doğrulanmadan.
-> D6, D3.

### 9.F Para ve Varlık

**F1 — İşlem ücreti (fee) kimden karşılanır**
-> Fee, Çek tutarının DIŞINDA, gönderenin kendi hesabından karşılanır;
Çek tutarı asla fee için kırpılmaz (D8: ya hep ya hiç — alıcı her
zaman tam tutarı alır).

**F2 — Alıcının fee ödeyecek bakiyesi yok (claim işlemi de fee
gerektirir)**
-> fee-bump / sponsorluk mekanizmasıyla claim işlemi platform
tarafından sponsorlanabilir (non-custodial kalır — platform yalnızca
fee'yi sponsorlar, varlık transferine karışmaz).
-> D1 (varlık el değiştirmesi etkilenmez, yalnızca fee kaynağı
değişir).

**F3 — Alıcının ilgili varlık için trustline'i/hesabı yok**
-> A4 ile aynı kontrol claim aşamasında da zincir tarafından
doğrulanır; yoksa claim başarısız olur, Çek HAVUZDA kalmaya devam
eder, süre işlemeye devam eder (D9 sayesinde nihayetinde iade edilir).

**F4 — Issuer varlığı dondurdu (classic asset freeze)**
-> Claimable Balance zincir kurallarına tabi olur; dondurma süresince
claim/iade başarısız olabilir, ama tutar Pool'da (D1) güvenle bekler,
kaybolmaz.

**F5 — Yuvarlama**
-> Çek/Pool akışında swap yoktur, miktar dönüşümü yapılmaz; ana
mimarinin "kullanıcı aleyhine yuvarlama" kuralı (Bölüm 7) burada
uygulanmaz çünkü yuvarlanacak bir dönüşüm yoktur — gönderilen tutar
ile alınan tutar birebir aynıdır.

### 9.G Kötüye Kullanım

**G1 — Replay (aynı zincir olayı tekrar geldi — reorg)**
-> Tüm tüketiciler idempotent (ana mimari kuralı); durum geçişi
(cek_id, kaynak, hedef) üçlüsüyle tekilliği garantiler.
-> D3.

**G2 — Aynı parayla iki Çek yazma denemesi**
-> A1/A3 ile aynı mekanizma: rezerv ilk Çek'te konur, ikinci istek
yetersiz bakiye olarak reddedilir.
-> D2, D5.

**G3 — Alıcı "almadım" diye itiraz ediyor ama zincirde claim
görünüyor**
-> Zincir tek doğruluk kaynağıdır (D6); anlaşmazlık zincir kaydıyla
çözülür, bu bir iş/destek süreci konusudur, mimari açıdan zaten
çözümlüdür.

**G4 — Platform tamamen kapalıyken kullanıcının doğrudan zincire
erişmesi**
-> Non-custodial olduğu için (Kapsam), kullanıcı backend olmadan da
kendi cüzdanıyla Claimable Balance'ı claim edebilir veya süresi
dolanı iade edebilir — platform bir SPOF (tek hata noktası) değildir.
-> D9.

**G5 — Zorla tahsil özelliğinin kötüye kullanımı (alıcı, gönderen
hâlâ fonlayabilecekken erken tahsile zorluyor)**
-> Bölüm 5 koşul 2 (Pool fonlanmamış + kontrat doğrulaması) ve koşul 1
(süre hâlâ içinde olmalı — yani zorla tahsil ancak son kullanma
tarihine yakın/geçtiğinde anlamlı hale gelir, mimari bunu erken
tetiklemeye açık bırakmaz, uygulama katmanında "süre dolmadan önce son
X saat" gibi bir pencereyle sınırlanabilir) ile sınırlanır; açık
varsayım olarak Bölüm 10'da not edilmiştir.
-> D2, D8.

### 9.H Süre

**H1** — Çek geçerlilik süresi = 1 hafta (D7, ledger saati)
**H2** — Pool mevduatında çekim kilidi = son eklemeden itibaren 1
hafta (Bölüm 7)
**H3** — Süre sonu iadesi izinsizdir, kimse gönderenin/alıcının online
olmasını beklemez (D9)
**H4** — Süre uzatma YOKTUR — ihtiyaç olursa gönderen yeni bir Çek
yazar; bu eski Çek'in durumunu etkilemez (D4, terminal kapalı).

### 9.I Onay

**I1** — Her başarılı çekimden/claim'den sonra alıcıdan bir onay
istenir -> Bu onay yalnızca makbuz/defter kapatma amaçlıdır; para
transferi onaydan ÖNCE, zincir seviyesinde zaten gerçekleşmiştir (D1).
Onay verilmese bile para alıcıdadır; onay yalnızca bildirim/gösterge
durumunu KAPANDI olarak işaretler.

## 10. Açık Varsayımlar

1. Claimable Balance ile Soroban escrow arasındaki tam iş bölümü
   (Bölüm 2) — basit akışlarda escrow'a hiç gerek olmayabilir, ilk
   sürümde yalnızca Claimable Balance ile başlanıp ön yetki/zorla
   tahsil özelliği ikinci fazda eklenebilir.
2. Ön yetkinin zincir-üstü tam temsili (Soroban kontrat imzası mı,
   SEP-10 benzeri ikinci bir off-chain imza + kontrat doğrulaması mı).
3. Fee sponsorluğu politikası (F2) — hangi durumlarda platform
   fee-bump yapar, limiti ne olur.
4. G5'teki "erken zorla tahsili sınırlayan pencere" değerinin kesin
   süresi (örneğin son 24 saat).
5. Çek/Pool akışının hangi servise (yeni `defi-cheque-service` mi,
   mevcut bir servise yeni bir yüz mü) yerleşeceği (Bölüm 8).
6. Karşılıksız (KARSILIKSIZ) kapanan Çek'lerin bir itibar/kayıt
   mekanizmasına bağlanıp bağlanmayacağı.
