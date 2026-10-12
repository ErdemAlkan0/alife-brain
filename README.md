# A-Life Brain

Project A-Life NPC'lerine LLM diyalog + hafıza ve RL karar katmanı ekleyen Project Zomboid (B42) eklentisi.
Tasarım: [CLAUDE.md](CLAUDE.md) · A-Life kanca notları: [docs/alife-hooks.md](docs/alife-hooks.md) ·
Köprü protokolü: [docs/bridge-protocol.md](docs/bridge-protocol.md)

## Klasörler

```
mod/                      Zomboid/Workshop/ALifeBrain düzeni (workshop.txt + Contents/mods/ALifeBrain)
  Contents/mods/ALifeBrain/
    common/               B42'nin istediği sürümden bağımsız klasör
    42/mod.info           require=\ProjectALifeNPCs
    42/media/lua/shared/ALifeBrain/   Json, Bridge, ALifeBrainHooks (A-Life'a dokunan her şey), Dialogue, Trade,
                                      Text, Features + Policy + DecisionLog (3. aşama), PolicyWeights (üretilir),
                                      Moods + Control (5. aşama), Companion, Standoff, Parley, Tests/
    42/media/lua/client/ALifeBrain/   ALifeBrainMain (başlatma, ping), EventLog, ChatWindow
sidecar/                  Python sidecar (yalnızca standart kütüphane)
rl/                       Policy eğitimi (rl/.venv): davranış klonlama (numpy), PPO (torch, SB3), Lua'ya dışa aktarma
tests/lua/run_tests.lua   Lua testlerini standart Lua 5.1 / LuaJIT ile koşar
tests/lua/run_tests.py    aynısı Python'dan, oyun olmadan (lupa: rl\.venv\Scripts\python -m pip install lupa;
                          rl\.venv\Scripts\python tests\lua\run_tests.py). Kahlua birebir aynı değil; son söz oyunda
                          -debug ile çalışan testler
```

## Güvenlik kuralları

- `Zomboid/mods` içindeki modlara ve `Zomboid/Saves` içindeki kayıtlara dokunulmaz.
- Mod, oyuna yalnızca `Zomboid/Workshop/ALifeBrain` bağlantısı (junction) ile gösterilir.
- Mod ve sidecar `Zomboid/Lua` içinde yalnızca `alifebrain_*` dosyalarını oluşturur.
- Denemeler **yeni bir test kaydında** yapılır; mevcut kayıtlara mod eklenmez.

## Sidecar

`sidecar\run-sidecar.cmd` dosyasına çift tıkla, ya da:

```bash
cd sidecar
python -m alifebrain_sidecar --verbose
```

Oyunsuz duman testi (geçici bir klasörle, `Zomboid\Lua`'ya dokunmaz): sidecar'ı `--lua-dir <geçici klasör>` ile
başlatıp `python tools/fake_game.py --lua-dir <geçici klasör>` çalıştır; sonunda `SMOKE OK` yazmalı.

Varsayılanlar: Lua klasörü `%USERPROFILE%\Zomboid\Lua`, veri klasörü `%LOCALAPPDATA%\ALifeBrain`
(`events.jsonl`, `sidecar.lock`). Testler:

```bash
cd sidecar
python -m unittest discover -v tests
```

## Tek dosya sidecar (Python'suz)

```bash
sidecar\build-exe.cmd
```

İlk çalıştırmada `sidecar\.venv-build` oluşturur ve PyInstaller'ı kurar; sonucu `sidecar\dist\ALifeBrainSidecar.exe`
(yaklaşık 9 MB). Exe her yere kopyalanabilir ve Python istemez; çift tıklamak `run-sidecar.cmd` ile aynıdır, aynı
argümanları alır (`ALifeBrainSidecar.exe --provider fake`, `--verbose`). Ayarlar ve hafıza yine
`%LOCALAPPDATA%\ALifeBrain\` altındadır. İmzasız exe olduğu için Windows SmartScreen ya da antivirüs ilk açılışta
uyarabilir. Betik yalnızca derler, sidecar'ı başlatmaz; sonunda sonucu yazıp bir tuşa basmanı bekler (betiklerden
çağırırken `build-exe.cmd nopause`).

## Oyunda deneme (1. aşama: ping/pong)

1. Modu Workshop klasörüne bağla (bir kez; `Zomboid/mods`'a dokunmaz):
   `New-Item -ItemType Junction -Path "$env:USERPROFILE\Zomboid\Workshop\ALifeBrain" -Target "<repo>\mod"`
2. Sidecar'ı başlat.
3. Oyunu `-debug` ile aç (Steam → Özellikler → Başlatma seçenekleri), **yeni** bir oyun oluştur, mod listesinde
   Project A-Life ve A-Life Brain'i aç.
4. `Zomboid/console.txt` içinde beklenenler:
   - `[ALifeBrain] [test] N passed, 0 failed (Kahlua wide chars)`
   - `[ALifeBrain] A-Life 1.3.15 ...: touchpoints ok=19 missing=0`
   - `[ALifeBrain] sidecar online ...`, `sidecar ready ...`, `pong #1 rtt=...ms`
5. Bir A-Life NPC'sine vur → sidecar logunda `event npc_hit ...`, `events.jsonl`'de kayıt.
6. Sidecar'ı kapat → birkaç saniye içinde `sidecar offline`; oyun normal devam eder.

Debug konsolunda: `ALifeBrain.status()`, `ALifeBrain.ping()`, `ALifeBrain.runTests()`,
`ALifeBrain.spawnTestNpc()` (6 kare doğuna 1 dost NPC, Church Volunteers; A-Life diagnostics'ini açar),
`ALifeBrain.spawnTestNpc("alife_hobbs", 3)` (başka fraksiyon / sayı), `ALifeBrain.npcs()` (A-Life'ın NPC kaydı:
en yakından uzağa durum, kalıcı mı, uzaklık; bu yüklemeden beri silinenler ve nedenleri), `ALifeBrain.trust()`
(ruh halini bildiğimiz NPC'lerin güveni, korkusu ve sana karşı tutumu).

**Tanıştığın NPC'ler kalır** (varsayılan açık; Mod Options → A-Life Brain → "Tanıştığın NPC'ler kalsın"): sana 10 kare
yaklaşan her A-Life NPC'si ekibiyle birlikte kalıcı olur; A-Life onu kayda yazar ve sonra uzaklaşsan bile silmez.
A-Life kendi başına yalnızca kalıcı grupları (karakollar, kalıcı karşılaşmalar, kendi offline ekipleri) kaydeder; gerisi
tek oturumluktur. A-Life bu tür gruplardan en çok sandbox ayarı "Saved group limit" kadarını (varsayılan 20)
kaydeder; tutulan gruplar bunu aşarsa oyunda bir uyarı çıkar, ayarı yükselt (en çok 500). Geri almak için önce kutuyu
kapat, sonra konsolda `ALifeBrain.releaseKept()`.

`spawnTestNpc` NPC'leri kalıcı çağırır. A-Life'ın debug spawner'ı varsayılan olarak **harcanabilir** NPC üretir:
oyuncu uzaktayken "uyur" (dormant), kimse yaklaşmadan A-Life sandbox ayarı "Unvisited NPC lifetime" (varsayılan 8
oyun saati) dolunca silinir. Eski davranış için 4. argüman `true` (`spawnTestNpc(nil, 1, nil, true)`).

## LLM diyalog (2. aşama)

Ayarlar: `%LOCALAPPDATA%\ALifeBrain\config.json` (ilk çalıştırmada varsayılanlarla oluşur).

- `provider`: `player2` (varsayılan), `ollama`, `openai` veya `fake` (LLM yok, test cevabı).
- Player2: uygulamayı kur, giriş yap; https://player2.game/profile/developer sayfasından Client ID al ve
  `player2.client_id` alanına yaz (veya `ALIFEBRAIN_PLAYER2_CLIENT_ID` ortam değişkeni).
- OpenAI uyumlu servis: anahtar yalnızca `openai.api_key_env` alanında adı geçen ortam değişkeninden okunur;
  dosyaya anahtar yazılmaz.
- Hafıza: `%LOCALAPPDATA%\ALifeBrain\memory.sqlite3` (NPC'ler, anılar, konuşmalar, güven/korku, atılganlık).
  Eski anılar özetlenir: bir NPC'nin (ya da ekibinin, fraksiyonunun) anısı 14'ü geçince en yeni 6'sı dışındakiler
  LLM'le kısa bir özete yazılır (sidecar boştayken, en çok dakikada bir; her özet bir LLM çağrısı). Asıllar silinmez.
  Kapatmak için `config.json`: `"memory": {"summarize": false}`.

Sohbet penceresi açıkken oyun duraklar (tek oyunculu; Mod Options → A-Life Brain → "Konuşurken oyunu duraklat"),
kapanınca eski hızında devam eder. Duraklatılmışken envanter tuşu çalışmaz: takas yapacaksan envanteri önce aç.
Çok oyunculu oyunda oyun duraklatılamadığı için çok oyunculu desteği şimdilik ertelendi.

Oyunda: sidecar'ı başlat (LLM'siz denemek için `run-sidecar-fake.cmd`), dost bir NPC çağır ve yanında `T`'ye
bas (ya da yere sağ tık → en üstte **A-Life Brain: <ad> ile konuş**). Sohbet penceresi açılır: A-Life'ın
konuşma penceresine benzer (portre, ad, fraksiyon, tutum, güven/korku); önceki konuşmalar üstte, yenileri
altta. Yaz ve Enter'a bas; NPC durur, "..." gösterir ve cevap verir. Yakında konuşulabilir NPC yoksa ya da
sidecar kapalıysa `T` A-Life'ın kendi kutusunu açar.

NPC'nin söyledikleri gerçek eylemlere bağlıdır: su / yiyecek / ilaç verebilir (gerçekten envanterinde varsa),
seni 10 dakika takip edebilir, bekleyebilir ya da konuşmayı bitirebilir; pencerede ne olduğu gri satırla yazar.
Takip eden NPC yanında kalır: senden 8 kareden uzak zombileri kovalamaz, kalabalık gelince (yakın dövüşte 3, silahla
6 zombi) ya da ağır yaralıyken geri çekilir; sana yakın tek tük zombilerle A-Life'ın kendi dövüşüyle savaşır.
Debug konsolunda `ALifeBrain.status()` içindeki `companion` kaç kez geri döndüğünü / çekildiğini gösterir.
Sen eğilerek ilerlerken takipçi de eğilir, yavaşlar ve koşmaz; ona ya da sana 3 kareden yakın olmayan zombilere
saldırmaz.

**NPC'ler arası uyarı:** birbirine düşman iki NPC görür görmez ateş etmez: önce "uzak dur", yaklaşırsa ya da uzun
süre kalırsa son uyarı, sonra çatışma (A-Life'ın fraksiyon replikleriyle). Takipçin uyarılırsa senin yanına çekilir.

**Pazarlık (düşman NPC'ler):** sidecar açıkken seni gören düşman bir NPC ateş etmek yerine durur, seslenir ve sohbet
penceresi kendiliğinden açılır; NPC önce konuşur (haraç ister ya da tehdit eder). Konuşurken ekibi ateş etmez.
Haracı takas masasından verirsen (yanına yürüyüp "Kabul et") ya da seni gönderirse bir süre rahat bırakılırsın.
Pencereyi kapatırsan, ekipten birine vurursan, 45 saniye susarsan ya da NPC vazgeçerse çatışma başlar; çok
uzaklaşırsan pazarlık biter. Daha önce saldırdığın ya da kendi soygun sistemiyle seni soyan ekipler A-Life gibi
davranır. `ALifeBrain.status()` içinde `parley` ve `standoff` sayaçları var.
Sahte sağlayıcıda anahtar kelimeler: "su" / "water", "yemek" / "food", "takip" / "follow", "bekle" / "wait",
"hoşça kal" / "bye".

**Takas:** pencerenin sağındaki takas bölümüne envanterinden (vanilla ya da Inventory Tetris) eşya sürükle; NPC'nin
eşyalarından istediğine tıkla (sağ tık azaltır). "Teklif et" mesajınla birlikte takası NPC'ye sunar; NPC kabul eder
(değişim anında olur), reddeder ya da kendi eşyalarıyla karşı teklif yapar ve karşılığında ne istediğini söyler
(istediği eşyaların masaya kendiliğinden konur; "Kabul et" ile alırsın). Veresiye yoktur: NPC'nin eşyası yalnızca
senin karşılığın da masadayken ve aynı anda el değiştirir; sohbette "suyu ver, sonra bandaj veririm" gibi bir
pazarlığa NPC "ver" diye cevap verse bile eşya doğrudan verilmez, takas masasına konur. Eşyalar
takas olana kadar senin envanterinde kalır (başka yere taşırsan masadan düşer); giyilen, elde tutulan, takılı ve
favori eşyalar ile içi dolu çantalar teklif edilemez. Pencere açık envanter pencerelerinin yanına açılır; yazı kutusu
klavyeyi yalnızca pencereye tıklayınca alır, envantere ya da dünyaya tıklayınca tuşlar oyuna döner. Sahte
sağlayıcı masada bir şey varsa kabul eder, "teklif" / "offer" deyince kendi ilk eşyasını önerir.

Sidecar yoksa, LLM hata verirse, NPC çatışmadaysa ya da düşmansa A-Life'ın kendi replikleri kullanılır.
Şimdilik yalnızca tek oyunculu.

## Davranış klonlama (3. aşama)

Amaç: önce A-Life'ın kendi kararlarını taklit eden bir policy (sonra PPO ile geliştirilecek).

1. **Veri toplama:** sidecar açıkken oyna. Mod A-Life'ın her kararını izler (değiştirmez): hangi modülü seçti
   (`regroup`, `orders`, `flee` ... ya da `default`) ve NPC ne görüyordu (43 özellik: sağlık, mermi, tehdit,
   yakındaki zombi/squad, oyuncu ve tutum, saat, emir, LLM güven/korku ...). Kayıtlar
   `%LOCALAPPDATA%\ALifeBrain\dataset\decisions-<tarih>.jsonl` dosyasına gider. Farklı durumlar ne kadar çeşitliyse
   o kadar iyi: dost ve düşman NPC'ler, gece/gündüz, zombi kalabalığı, takip emri, çatışma.
   Debug konsolunda `ALifeBrain.status()` (`decisions.sent`) ve `ALifeBrain.policy()` (en sık seçimler).
2. **Eğitim** (bir kez: `py -3.12 -m venv rl\.venv` ve `rl\.venv\Scripts\python -m pip install -r rl\requirements.txt`):

   ```bash
   rl\run-bc.cmd
   ```

   Her zincir (`decision`, `response`) için en az 300 karar gerekir. Doğrulama kümesi eğitimde hiç görülmemiş
   NPC'lerden oluşur; çıktı doğruluğu "hep en sık seçimi yap" tabanıyla birlikte yazar. Sonuç
   `mod/.../ALifeBrain/PolicyWeights.lua` dosyasına yazılır (`--dry-run` yalnızca raporlar). Bir modülün hatalı
   çalıştığı döneme ait kararlar `--exclude <eylem>` ile dışarıda bırakılır (ör. 2026-10-10'daki donma için
   `--exclude alifeBrainStandoff`).
3. **Gölge modu:** oyunu yeniden başlat. Policy her örneklenen kararda kendi seçimini yapar ama **uygulamaz**;
   `ALifeBrain.policy()` A-Life ile ne kadar aynı seçtiğini gösterir. Kontrolü devralması 4./5. aşamada.

## PPO (4. aşama)

`rl/alifebrain_rl/sim.py`: A-Life'ın ekran dışı squad simülasyonuna benzeyen bir Gymnasium ortamı. Bir NPC ve
squad'ı sakin anlardan (`decision` zinciri: devriye, toplama, toparlanma, dinlenme, emir, uyarma, soygun) ve
tehditlerden (`response` zinciri: savaş, kaç, panik, destek çağır, oyuncuya çekil, NPC'yi uyar, pazarlık) geçer;
çatışmalar A-Life'ın çevrimdışı güç modeliyle çözülür. Gözlem oyunun `Features.lua` vektörünün aynısı
(`features.py`), eylemler A-Life modül id'leri: eğitilen ağ oyunda değişmeden çalışır. Güven / korku / hedef her
bölümde rastgele çekilir ve neyin kazandırdığını değiştirir (güvenilen oyuncuyu takip et, onu soyma; korku oyuncunun
ne kadar tehlikeli olduğunu söyler: korkulan oyuncu daha sert dövüşür, yakındaki silahlı oyuncu uyarılıp uzaklaştırılır;
hedef −1 temkinli: her yeni tehdit hayatta kalma ağırlığıyla ek bedel ↔ +1 ganimet ve çatışma) → diyalogla ayarlanan
tek policy. Oyuncu olduğu yerin çevresinde kalır (uyarılırsa çoğunlukla uzaklaşır), yani yakın karşılaşmalar sürer.

Kurulum (bir kez): `rl\.venv\Scripts\python -m pip install -r rl\requirements-ppo.txt --extra-index-url
https://download.pytorch.org/whl/cpu` (torch CPU, Stable-Baselines3, Gymnasium).

```bash
rl\run-ppo.cmd
```

Varsayılan 3 milyon adım CPU'da ~20 dakika sürer (`--timesteps` ile değişir; 1 milyonda bazı tohumlar "her yerde
topla"ya çöküyordu). Çıktı: PPO ile iki temel çizginin (A-Life benzeri kural, rastgele) getiri /
ölüm / squad kaybı karşılaştırması, güven, korku, hedef değişince ilk seçimin nasıl değiştiği ve bütün bölümler boyunca
alışkanlıklar (ör. yalnızken toplama oranı hedef > +0.5 ve < −0.5 iken; köşeli parantezde A-Life benzeri kural). Ağırlıklar
`rl\out\PolicyWeights.ppo.lua`'ya yazılır; `--install` moddaki `PolicyWeights.lua`'ya da yazar (oyunda gölge modu).
Simülasyondaki bütün sayılar tasarım tercihidir (`SETTINGS`), ölçüm değil.

Testler: `rl\.venv\Scripts\python -m unittest discover rl\tests` (rl klasöründen: `.venv\Scripts\python -m unittest
discover tests`).

## Konuşma → davranış (5. aşama)

Policy'nin girdileri konuşmalardan gelir (`Dialogue.minds`):
- **Güven / korku** oyuncuya karşıdır (LLM her cevapta ±10 oynatır).
- **Atılganlık** (`goal`) NPC'nin kendisine aittir: −100 sakin dur, güvende kal ↔ +100 ganimet için dışarı çık, risk al.
  - LLM her cevapta `goal_delta` ile en çok ±25 oynatır. Örneğin "doğuda bir sürü var, dikkat et" atılganlığı düşürür;
    "eczanede ilaç var" yükseltir.
  - Değer 30 dakikalık yarı ömürle 0'a söner, yani tek bir konuşma NPC'yi kalıcı olarak değiştirmez.
  - Sohbet penceresinin başlığında "Atılganlık" olarak görünür.

Bu oturumda konuşulmamış NPC'lerin kayıtlı ruh hali, policy onlarla ilk karşılaştığında sidecar'dan istenir
(`moods` isteği).

**Policy kontrolü** varsayılan olarak kapalı. Açmak için Seçenekler → Modlar → A-Life Brain → **NPC davranışını
eğitilmiş policy seçsin**. Değeri oyun kendi `ModOptions.ini` dosyasında tutar. Hata ayıklama konsolunda
`ALifeBrain.control(true)` bu oturum için açar, `false` kapatır, `"option"` yeniden menüdeki ayara döner.

Kontrol açıkken:
- Policy, A-Life zinciri çalışmadan önce A-Life'ın kendi modüllerinden birini seçer ve o modül tek başına çalışır.
  Modülün yapacak işi yoksa ya da seçim A-Life'ın kendi akışıysa (`default`), A-Life eskisi gibi karar verir.
- Policy yalnızca bir seçim ekler, A-Life'ın bir seçimini asla engellemez:
  - **Hep A-Life'ta kalır:**
    - Oyuncunun emri (takip et / bekle).
    - Konuşma (pencere açık ya da cevap yolda).
    - Süren bir soygun.
    - NPC'nin dahil olduğu bir pazarlık ya da NPC↔NPC uyarı merdiveni.
    - Tehdit olarak oyuncu.
    - Oyuncuya düşman tutumlu bir NPC, oyuncu 55 karenin içindeyken (A-Life'ın soygun modülü oyuncuyu bu mesafeden
      fark eder).
  - **Policy hiç seçmez:** `talk`, `robbery`, `orders`, takipçi ve pazarlık modülleri.
  - **Oyuncu 20 karenin içindeyken** policy yalnızca bir uyarı (`careful`) ekleyebilir. Böylece A-Life'ın selamlaması
    (6 kare) ve uyarısı (14 kare) sırasını korur.
- Policy aynı NPC ve zincir için en çok 2,5 saniyede bir sorulur.

`ALifeBrain.control()` (ya da `ALifeBrain.policy()`) şunları gösterir:
- policy'nin neyi kaç kez çalıştırdığı;
- yapacak işi olmayan seçimler;
- kararın kaç kez ve neden A-Life'a bırakıldığı.

Gölge modu istatistikleri yalnızca A-Life'ın kendi seçtiği kararları sayar. Policy'nin çalıştırdığı kararlar
veri setine işaretli yazılır (`chosen`) ama eğitime girmez. Kontrol açıkken sayaçlar 5 dakikada bir `sidecar.log`'a da
yazılır ("policy control: ..."), yani oynanıştan sonra konsola bakmadan okunabilir.

**Güven tutumu değiştirir:** temkinli bir fraksiyonun NPC'si (A-Life: yaklaşanı "geri dur", "son uyarı" diye uyarır,
uyarıları dinlemeyene ateş açar) sana en az 5 güvenince bütün grubu yaklaşmana izin verir: A-Life'ın kendi
`Talk.tolerate` kolu, temkinli → tarafsız; uyarılar durur, pencerenin başlığında "Sana güveniyor" yazar, LLM'e de
söylenir. Güven 3'ün altına düşünce geri alınır. Düşman gruplar düşman kalır; vurursan grup yine döner.

Takip: LLM takibi kabul ederse NPC, oyuncuya güvensiz (güven < 0) ya da düşman değilse takip eder. Hafıza: fraksiyon
anıları kayıt (save) başınadır; eski bir kayıtta öldürdüğün biri yeni dünyadaki NPC'lerin hafızasına girmez.
