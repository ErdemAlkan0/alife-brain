# A-Life Brain — Project Zomboid NPC'leri için RL + LLM eklentisi

Bu dosya, claude.ai'de yapılan ön tasarım sohbetinin özetidir (Ekim 2026).
Kullanıcıyla Türkçe konuş. Kod, değişken ve dosya adları İngilizce olsun.

## Hedef

Project Zomboid (Build 42.20+) için **Project A-Life** modunun NPC'lerine şunları eklemek:
- **RL (pekiştirmeli öğrenme)** ile karar verme: NPC'nin hangi davranışı seçeceği
- **LLM** ile diyalog ve uzun süreli hafıza
- Diyalogun davranışı ayarlaması: LLM çıktısı (trust / fear / goal) → RL policy girdisi

## Mimari (3 katman)

1. **A-Life**: yürüme, çatışma, squad taktikleri, ekran dışı simülasyon. Buna dokunmuyoruz.
2. **RL policy**: sadece karar katmanı. A-Life'ın mevcut davranışlarından hangisinin seçileceğine karar verir.
3. **LLM**: diyalog + hafıza. Ürettiği `trust` / `fear` / `goal` değerleri RL policy'nin girdisidir.

Veri akışı:
PZ Lua addon ⇄ (JSON satırları, dosya köprüsü) ⇄ Python sidecar ⇄ LLM sağlayıcı (Player2 / Ollama / kullanıcının API anahtarı)

## Kesin kurallar

- A-Life dosyalarını **asla düzenleme, kopyalayıp yeniden yükleme**. Ayrı bir addon yaz: `mod.info` içinde `require=\ProjectALifeNPCs`.
- A-Life NPC'leri zombi gövdesi üzerine kurulu. Tanıma: `zombie:getModData().ProjectALifeOwned == true`.
- A-Life sık güncelleniyor (v1.3.x, Eylül 2026). İç fonksiyonlara monkey-patch kırılgandır. Kalıcı hook'lar için ekiple Discord'dan (discord.gg/alife) konuşulacak; hook noktalarını tek bir dosyada topla ki güncellemede kolay onarılsın.
- PZ Lua'sı (Kahlua) sandbox'lı: `io`, socket, HTTP yok. Dış dünyayla iletişim **yalnızca dosya köprüsüyle**.
- LLM oyunu asla doğrudan kontrol etmez: çıktı sabit JSON şemasıdır, sidecar doğrular ve sınırlar, Lua yalnızca beyaz listedeki `intent` değerlerini uygular.
- Sidecar kapalıysa veya LLM zaman aşımına uğrarsa mod normal A-Life gibi çalışmaya devam eder (hazır repliklere geri dön).
- Multiplayer: Player2 girişi oyuncu başına olduğu için LLM çağrıları istemci tarafında yapılır; sunucu `trust_delta` / `fear_delta` değerlerini her zaman yeniden sınırlar (istemci sahteleyebilir).
- Kendi API anahtarını moda veya sidecar'a **asla gömme**.

## Bileşenler

### 1) Lua addon (`mod/`)
- Olay loglama: vuruldu, soyuldu, yemek verildi, squad üyesi öldü vb. Bunlar hem hafıza kaydı hem RL veri seti olur. Soyulma (uygulandı, `Robberies.lua`): A-Life `ModuleRobbery.active` tablosu saniyede bir okunur (yamasız); biten her soygun `robbed_player` olayıyla gider (ekip, `finishedReason`: `released` / `execute:<neden>` / boşa çıktı, alınan eşyaların adları); ekibin her üyesi hatırlar, boyun eğen oyuncuya güven +1 korku −2, direnen −3 / +3.
- İstek yazma: `getFileWriter("alifebrain_req.txt", true, true)` (kullanıcının `Zomboid/Lua` klasörüne yazar). Alt klasör yerine düz dosya adı kullan.
- Cevap okuma: `alifebrain_res.txt` dosyasını kısa aralıklarla yokla (OnTick'i seyrelterek).
- İçerik JSON satırlarıdır ama uzantı `.txt` olmalı: B42 `getFileWriter` yalnızca `txt, ini, cfg, json, lua, log` uzantılarına yazar, diğerlerini (ör. `.jsonl`) **sessizce** reddeder (`LuaManager.ALLOWED_FILE_EXTENSIONS`, 42.21'de doğrulandı). `getFileReader` kısıtlı değil.
- Her mesajda `id` alanı olsun. Yarım satır okumamak için sidecar önce `.tmp` dosyasına yazıp sonra yeniden adlandırsın. Dosyaları periyodik olarak temizle.
- Konuşma arayüzü: sohbet penceresi (`ChatWindow.lua`, A-Life'ın `ALifeTalkMenu.lua` penceresi örnek alındı; serbest metin; geçmiş sidecar'dan `history` ile yüklenip üstte gösterilir) + NPC balonu (beklerken "..."). `T` tuşu (`TalkInput.open` sarmalanır) yakında konuşulabilir NPC varsa ve sidecar hazırsa pencereyi açar, değilse A-Life'ın kutusunu; sağ tık menüsünde de en üstte. A-Life kutusu yolunda eylem sonucu oyuncunun üstünde bildirim (halo) olarak gösterilir. Kullanıcı geri bildirimi: oyuncular eşyanın verildiğini görmeli; LLM gerçek eşya adlarını (`inventoryItems`) kullanmalı. Pencere açıkken NPC A-Life'ın `talkHold`'u ile tutulur; kapanınca `ModuleTalkPresence` selamlamaları 3 dk susturulur. Pencere açıkken oyun duraklatılır (`Pause.lua`, Mod Options "Konuşurken oyunu duraklat", varsayılan açık; oyunun kendi duraklatması: `SpeedControls:SetCurrentGameSpeed(0)`, kapanınca eski hız, oyuncu arada hızı değiştirdiyse o kalır). Duraklatılınca `OnTick` durur: köprü ve diyalog `OnTickEvenPaused` ile çalışmaya devam eder (`Main.onTickEvenPaused`), dünya işleri (A-Life kararları, Parley, Keeper) oyunla bekler. Duraklatılmışken vanilla envanter tuşu çalışmaz (`getGameSpeed() > 0`). Çok oyunculu oyunda duraklatılamaz: kullanıcı kararıyla (2026-10-11) çok oyunculu desteği ertelendi.
- RL çıkarımı: küçük MLP ağırlıkları bir Lua tablosunda, ileri geçiş oyunun içinde (köprüyü beklemez). NPC başına birkaç saniyede bir çalışır.
- Kendi A-Life tepki modüllerimiz (`Hooks.MODULES`, profil `overlays`'ına çalışma zamanında eklenir): `alifeBrainParley` (29, `Parley.lua`: düşman NPC ateşten önce konuşur; ekibe A-Life'ın `memory.robberyTruce` ateşkesi yazılır; pencere kapanırsa / saldırı / `intent attack` / 45 s sessizlik → çatışma, haraç ya da `leave` → ateşkes), `alifeBrainStandoff` (31, `Standoff.lua`: NPC↔NPC uyarı merdiveni, A-Life `CAREFUL_*` sesleri), `alifeBrainCompanion` (32). Takipçi, oyuncu eğilince `Stealth.stanceActive` sarmalayıcısıyla eğilir ve koşmaz.
- Davranış klonlama (3. aşama, uygulandı): `Hooks.installDecisionTap` A-Life'ın modül zincirlerini yalnızca izler; `DecisionLog.lua` kararları örnekler (NPC+zincir başına seçim değişince ya da 3 s'de bir, saniyede en çok 20) ve `decision_samples` olayıyla gönderir; sidecar `%LOCALAPPDATA%\ALifeBrain\dataset\` altına yazar. Eylem = A-Life modül id'si ya da `default`; gözlem = `Features.lua` (şema 1, 43 özellik; aynı kod hem veri hem çıkarım için kullanılır, özellik değişirse `SCHEMA` artırılır). Eğitim `rl\run-bc.cmd` (numpy, `rl/.venv`), çıktı `PolicyWeights.lua` (yer tutucu `return nil`; dışa aktarıcı bir kontrol girdisi ve logitlerini ekler, oyun yüklerken `Policy.check` ile doğrular). Gölge modunda karar vermez, A-Life ile ne kadar aynı seçtiğini sayar (`ALifeBrain.policy()`); kontrol 5. aşamada (aşağıda).
- Policy kontrolü (5. aşama, uygulandı; varsayılan kapalı: Mod Options tik kutusu `PZAPI.ModOptions`, ya da `ALifeBrain.control(true)`): `Hooks.wrapEvaluate` tam zincirden **önce** `Control.pick`'e sorar, seçilen modül `only` ile tek başına çalışır, `nil` dönerse A-Life'ın zinciri çalışır (modüller `evaluate` içinde hareket/ses başlattığı için zincir önce çalıştırılıp sonradan değiştirilemez). Policy yalnızca seçim ekler: `default`, `talk`, `robbery`, `orders`, takipçi ve pazarlık modüllerini hiç seçmez; oyuncu emri, konuşma, soygun, pazarlık/NPC merdiveni, oyuncu tehdidi ve 55 kare içinde oyuncuya düşman NPC (A-Life `ModuleRobbery.detectRadius`) A-Life'ta kalır; oyuncu 20 karenin içindeyken yalnızca `careful` ekleyebilir (A-Life uyarı yarıçapı 14, selamlama 6). NPC+zincir başına 2,5 s önbellek. Seçtiği kararlar veri setine `c` (sidecar `chosen`) işaretiyle yazılır, BC bunları atlar; kontrol açıkken kaydedilen satırlar `ctl`; sayaçlar 5 dakikada bir `policy_stats` olayıyla `sidecar.log`'a gider. Konuşulmamış NPC'lerin kayıtlı ruh hali `Moods.lua` ile (`moods` isteği) `Dialogue.minds`'a gelir.
- JSON için Kahlua uyumlu saf Lua kütüphanesi kullan ve Kahlua'da test et. Oyun olmadan: `rl\.venv\Scripts\python tests\lua\run_tests.py` (lupa, standart Lua 5.1; Kahlua'dan farkları var, son söz oyundaki `-debug` testleri).
- Kahlua tuzakları (oyunda doğrulandı):
  - `a % b`, `a / b` bölümü 2³¹'i aşınca yanlış sonuç verir (içeride 32 bit int dönüşümü var; bölme işleminin kendisi doğru). Milisaniye zaman damgalarında `%` kullanma; sayıyı metne çevirmek için `Json.intToString` kullan.
  - Debug modunda (`-debug`) `pcall` ile yakalanan hatalar da konsola yığın izi olarak dökülür; bu bir hata değildir.
  - `string.byte` UTF-16 birimi döndürür (> 255 olabilir); `string.char(300)` çalışır.
  - `next` yok ("Object tried to call nil"); bir tablonun boş olup olmadığını `pairs` ile say.
- NPC'lerin kalıcılığı ("oyuna girip çıkınca NPC'ler siliniyor", 2026-10-11): A-Life kayda yalnızca kalıcı grupları yazar (`Persistence.forSave`: kendi offline squad defteri, karakollar ve `memory.persistent` / encounter grupları, sandbox "Saved group limit" = `Persistence.squadCap`, varsayılan 20); geri kalan NPC'ler tek oturumluktur, uyurken "Unvisited NPC lifetime" (8 oyun saati) dolunca da silinir. `Keeper.lua` (varsayılan açık, Mod Options "Tanıştığın NPC'ler kalsın"): oyuncuya 10 kare yaklaşan NPC'nin bütün grubuna `Talk.writeMemory` ile `persistent = true` + `alifeBrainKeptAtMs` yazar (`Hooks.keepGroupOf`; offline squad ve karakol görev ekipleri A-Life'ın, dokunulmaz); kalıcı grup sınırı aşılırsa bir kez uyarır; `ALifeBrain.releaseKept()` geri alır. `ALifeBrain.spawnTestNpc` `persistent = true` gönderir; `ALifeBrain.npcs()` A-Life kaydını, kaydedilecek grup sayısını ve silinme nedenlerini (`Telemetry` halkası) gösterir.
- Mod Options: tik kutusu `ModOptions.ini`'de `true` iken oyunda "off" göründü (2026-10-11; oyunun yükleyicisi CRLF satırın `\r`'ını bırakıyor olabilir); `Main.loadOptions` kendi satırımızı da okur, açılış logu `saved` / `menu` değerlerini yazar.
- PZ arayüz tuzağı (oyunda görüldü): `ISCollapsableWindow` türevinde `render` / `prerender` adlarını başka iş için kullanma; ezersen üst sınıfı çağır. `prerender` stencil (kırpma) açar, `render` kapatır; kapanmazsa sonra çizilen bütün pencereler (ör. tıklanınca öne gelen envanter) bu pencerenin dikdörtgenine kırpılır ve görünmez olur.

### 2) Python sidecar (`sidecar/`)
- `alifebrain_req.txt` dosyasını izle → LLM'i çağır → `alifebrain_res.txt` dosyasına yaz. Protokol: `docs/bridge-protocol.md`.
- Sağlayıcı soyutlaması (OpenAI uyumlu): Player2 (varsayılan), Ollama, kullanıcının kendi API anahtarı. Geçiş tek bir ayarla yapılır.
- Hafıza: SQLite, NPC kimliğine bağlı; katmanlar: kişisel / squad / fraksiyon. Fraksiyon anıları kayıt (save) başına: her mesajda `world` = `<oyun modu>/<kayıt adı>` gelir, anahtar `<world>|<fraksiyon>` (A-Life rol adlarını her ekipte tekrar kullanır; eski test kayıtlarındaki ölümler yeni dünyada oyuncuya yükleniyordu, 2026-10-11). Kişisel (uid) ve squad (groupId) anahtarları zaten kayda özgü. Aynı kayıtta da adlar tekrarlanır: fraksiyon anısı "one of our people in another group" der ve ölenin kendi squad'ına gösterilmez. Squad kaybı katili adıyla yazılır ("Gus - Rifleman killed Deputy Rowe, not the stranger"; `npc_died.by` NPC katilin adını/squad'ını taşır); yalnızca "We lost X" kalınca LLM suçu oyuncuya yüklüyordu. Prompt kuralı: yabancıyı yalnızca anıların ya da konuşmanın gösterdiği şey için suçla. Prompt'a yalnızca en yeni, önemli ve ilgili birkaç anı ile bir özet girer. Eski anıları periyodik olarak özetle. **Uygulandı** (`summary.py`, config `memory`): bir katmanda (NPC, squad, fraksiyon) özetlenmemiş anı 14'ü geçince en yeni 6'sı dışındakiler (ve önceki özet) LLM'le birinci şahıs, en çok 3 cümle / 400 karakterlik bir özete yazılır; asıllar silinmez, `memories.summarized = 1` olur ve recall'dan çıkar (eski veritabanına sütun açılışta eklenir). Sidecar bunu yalnızca bekleyen cevap yokken ve en çok dakikada bir yapar; başarısız katman 10 dk bekler. Prompt'ta "From before:" altında katman başına son özet, sonra "What you remember:".
- Dağıtım: tek .exe (PyInstaller), oyuncunun Python kurmasına gerek kalmasın. **Uygulandı:** `sidecar\build-exe.cmd` (ilk çalıştırmada `sidecar\.venv-build` + PyInstaller) → `sidecar\dist\ALifeBrainSidecar.exe` (~9 MB, `--onefile --console`, giriş `sidecar\packaging\launcher.py`; `run-sidecar.cmd` ile aynı argümanlar; hata olursa pencere Enter'a kadar açık kalır). 2026-10-11'de derlenip sahte sağlayıcıyla ping/pong denendi.

### 3) LLM çıktı şeması

```json
{"say": "...", "memory_note": "...", "trust_delta": 0, "fear_delta": 0, "goal_delta": 0, "intent": "warn"}
```

- `intent` beyaz listesi: none, give, follow, stay, leave, trade, warn, attack, rob, give_info. Şemaya `item` alanı eklendi (`give` için: water, food, medicine).
- Takas (`Trade.lua` + pencerenin sağ bölümü): oyuncu envanterden sürükler (Inventory Tetris uyumlu: `ISMouseDrag.dragging` + Tetris `DragAndDrop.getDraggedStacks/endDrag`; bırakılan yer UI olduğu için Tetris yere atmaz), NPC eşyalarına tıklayarak ister; LLM `trade.decision` accept/reject/counter döner, karşı teklifte `npc_wants` ile oyuncudan ne istediğini söyler (oyuncunun tarafı bununla doldurulur). Veresiye yok (kullanıcı isteği: oyuncu NPC'nin eşyasını alıp karşılığını vermeden kaçamamalı): NPC'nin eşyası yalnızca oyuncunun karşılığı aynı değişimdeyken çıkar (`unpaid`), önce oyuncunun eşyaları taşınır, hata olursa hepsi geri alınır; pazarlığın parçası olan `give` sidecar'da takas önerisine çevrilir. Değişimi `Hooks.executeTrade` yapar (önce her şey yeniden doğrulanır; elde/üstte/takılı eşyalar, anahtarlar, favoriler ve içi dolu çantalar asla takas edilmez). Sürüklemeyi bitiren alıcı vanilla protokolüne uymalı: önce `ISMouseDrag.draggingFocus:onMouseUp(0,0)` (kaynak liste paneli kendi sürükleme durumunu ancak böyle sıfırlar; atlanırsa envanter yarım sürüklemede takılı kalır), sonra Tetris `endDrag`. Pencerenin metin kutusu klavyeyi yalnızca pencereye tıklanınca alır; dışarı (envanter, dünya) tıklanınca bırakır, yoksa Tetris döndürme ve envanter tuşları çalışmaz. Pencere görünür envanter pencerelerinin yanındaki boşluğa açılır. Doğrudan `Remove`/`AddItem` sonrası kaplar `setDrawDirty` + `ISInventoryPage.dirtyUI()` ile yenilenir; Tetris ızgarası yerleşmeyen eşyayı kendisi başka çantaya ya da yere taşır. Bilinen sınır: A-Life NPC'yi bellekten silip yeniden oluşturursa ona verilen eşyalar kaybolabilir (A-Life'ın kendi Supplies davranışıyla aynı).
- Oyunun uyguladığı eylemler (`Dialogue.act`, A-Life mekanizmalarıyla): `give` (A-Life `TalkSupplies.matches` kurallarıyla NPC envanterinden oyuncuya; oyuncu-NPC başına saatte en çok 3, 20 s aralık), `follow` / `stay` (`DecisionLoop.setOrder`, 10 dk; takip için dost tutum ya da güven ≥ 0 ve düşman olmamak; LLM güveni cevap başına 1–3 oynattığından eski ≥ 10 eşiğinde NPC "gidelim" deyip kalıyordu; A-Life'ta tehdit tepkisi emirlerden önce gelir ve takibin tasması yoktur, takipçi her zombiye saldırıyordu: `Companion.lua` + `alifeBrainCompanion` tepki modülü takipçiyi oyuncunun yanında tutar — oyuncudan 8 kareden uzak zombiyi kovalamaz, kalabalıktan (yakın dövüşte 3, silahla 6 zombi / 4 kare) ve can < %50 iken geri çekilir), `leave` (pencereyi kapatır). trade / warn / attack / rob / give_info yalnızca kaydediliyor. Sonuç `npc_action` olayıyla sidecar'a gider ve NPC'nin hafızasına "gerçekte olan" olarak yazılır. LLM'e envanteri ve "eylem yapmadan yaptım deme" kuralı prompt'ta verilir.
- Delta'lar sidecar'da sınırlanır (güven/korku ±10, oyuncu başına). Geçersiz JSON → hazır replik.
- Güven tutumu değiştirir (oyun testi 2026-10-11: takastan sonra güven 5–6 iken NPC "yaklaşma" demeye devam etti, pencere kapanınca A-Life'ın temkinli uyarı merdiveni grubu oyuncuya çevirdi; A-Life tutumu yalnızca fraksiyondan hesaplar). `Rapport.lua`: bildiğimiz en güvenen üyesi güven ≥ 5 olan temkinli grup oyuncuyu tolere eder (A-Life `Talk.tolerate` → `memory.tolerateUntil`, temkinli → tarafsız, bütün grup; 10 dk, yenilenir; güven < 3 olunca yalnızca kendi yazdığımızı geri alır). Cevap gelir gelmez uygulanır (`Rapport.onReply`), istekte `vouched: true` ile prompt "geri dur deme" der, pencere başlığı "Sana güveniyor". Düşman gruplar düşman kalır. Konsol: `ALifeBrain.trust()`.
- Güven kazanmak (oyun testi 2026-10-11: güven hep 0/−1, "kanıtla" döngüleri): prompt güvenin nasıl değiştiğini sayılarla söyler (dostça konuşma +1/+2, yardım/paylaşım/söz tutma/birlikte savaşma +3…+6) ve aynı kanıtı tekrar istemeyi yasaklar; temkinli tutum metni artık "uzak dur" demez. İyilikler hafızaya ve güvene işler: NPC'nin 10 karesinde zombi öldürmek (`player_helped`), hediye (+6) ve adil takas (+2); zombilerin arasındayken gelen isabet kaza sayılır (−3, `npc_hit.zombiesNear`).
- `goal_delta` (±25): NPC'nin atılganlığı (policy'nin `goal` girdisi, −100 sakin dur ↔ 100 ganimet/risk), NPC başına SQLite `drives` tablosunda, 30 dk yarı ömürle 0'a söner (sidecar `memory.GOAL_HALF_LIFE_MS` = oyun `Dialogue.GOAL_HALF_LIFE_MS`). Sohbet penceresinde "Atılganlık".

### 4) Player2 entegrasyonu
- Yerel uygulama: `http://localhost:4315/v1/chat/completions` (OpenAI formatı). Oyuncu Player2 uygulamasında giriş yapmış olmalı.
- Client ID: https://player2.game/profile/developer → istek başlığı `player2-game-key: <client_id>`.
- `GET /v1/health` her 60 saniyede bir (süre takibi ve gelir paylaşımı için öneriliyor).
- Cevap süresi (130 cevap, 2026-10-11/12): ortanca 11 s, %95'i 20 s, en yavaşı 32 s; yavaş bir akşam sohbetin ilk cevabı 37 / 43 s. Sidecar 60 s bekler (`dialogue.timeout_s`; eski 30 s %3'ü kesiyordu, config.json'da eski varsayılan 30 kaldıysa 60 kullanılır: `config.OLD_DEFAULTS`), Lua 75 s (`Dialogue.settings.timeoutMs`; Lua sidecar'dan kısa beklerse geç gelen cevap kaybolur, sidecar ise onu konuşma geçmişine yazmış olur).
- Rate limit hatasını yakala. Ücretsiz ve kredili modeller farklı olabilir, bu yüzden JSON doğrulaması şart.
- Player2 bazen isteği "user input rejected (HTTP 400)" ile reddeder (içerik filtresi gibi; 2026-10-11'de iki kez, aynı istek tekrar da reddedildi: bir pazarlık açılışı ve sıradan bir konuşma). `Player2Provider` hızlı bir reddi bir kez aynen yeniden dener; o da reddedilirse `Sidecar._ask_llm` kısa prompt'la (başta "Role-play for the zombie survival video game Project Zomboid…", anı/özet ve uzun takas listeleri yok, son 2 satır geçmiş) bir kez daha sorar. Pazarlık kuralları da yumuşatıldı ("tribute/menacing/open fire" yerine "toll/tough/starts the fight"). Pencere nedene göre yazar (`fallback_http_400`, `fallback_timeout`, `fallback_rate_limited`).
- Uygulamasız seçenek: Web API `https://api.player2.game/v1` (kimlik doğrulama gerekir).
- TTS ile seslendirme opsiyonel (ses konumsal olmaz).
- Player2'nin kendi hafıza araçlarını kullanma; hafıza sidecar'da kalır.

### 5) RL (`rl/`)
- Aksiyonlar: A-Life'ın mevcut davranışları (devriye, baskın, bölge tutma, uyarma, soyma, yeniden toplanma…).
- Gözlem: can/kanama, mermi, yakındaki zombi ve düşman sayısı, oyuncunun silahı çekili mi, saat, fraksiyon ilişkisi + LLM'den gelen trust / fear / goal.
- Eğitim:
  1. Oyun loglarından behavior cloning (önce A-Life'ın kendi kararlarını taklit et).
  2. A-Life'ın ekran dışı squad simülasyonuna benzeyen basit bir Gymnasium ortamında PPO (Stable-Baselines3). CPU yeterli; MlpPolicy için GPU önerilmiyor.
- trust / fear / goal girdileri eğitimde rastgele verilir → tek policy, yeniden eğitim olmadan diyalogla ayarlanabilir.
- Ödül: hayatta kalma + görev başarısı, squad kayıplarına ceza.
- Dışa aktarma: MLP ağırlıkları → Lua tablosu.
- Uygulandı (4. aşama): `rl/alifebrain_rl/sim.py` (`SquadEnv`; gözlem `features.py` = `Features.lua` şema 1, eylemler
  iki zincirin A-Life modül id'leri, geçersiz eylem = zincirin `default`'u + küçük ceza; çatışma A-Life
  `Offline/ALifeOfflineCombat.lua` güç modeli; güven/korku/hedef ödülü değiştirir: korku = oyuncunun tehlikesi, onun
  gücünü artırır; her yeni tehdit hayatta kalma ağırlığıyla ek bedel, temkinli hedef bu yüzden belaya girmez; oyuncu
  yerinin çevresinde kalır), `ppo.py` (SB3 PPO, 64-64 tanh;
  tek gövde iki ağ olarak dışa aktarılır; `--install` moda yazar). `rl/.venv`: numpy + torch CPU + SB3 + Gymnasium.
  Kalibrasyon hedefi: A-Life benzeri kural (hep savaş, yalnızca çok yaralıyken kaç) bölümlerin ~%30'unda ölür.
  Sonuç (3M adım, n_steps 1024, batch 512, target_kl 0.02; 2 tohum tutarlı): PPO ölüm %8–14 (kural %38); güven >
  +0.6 takip %93–95 (< +0.4: %18–43); yalnızken toplama hedef > +0.5 %90–95, < −0.5 %5–11; 4+ zombi ve can < 0.4 →
  kaç %99. Zayıf kalan: korkulan silahlı oyuncuyu uyarma (ilk seçimde %38–47, bölüm boyunca ~%2; oyunda da nadir:
  kararların %4'ünde oyuncu 10 karenin içinde). `ppo.py` raporu: probe'lar (ilk seçim) + `HABITS` (bölüm boyunca).

## Yol haritası

1. Loglama + dosya köprüsü: Lua ⇄ Python arasında uçtan uca ping/pong.
2. LLM diyalog + hafıza (Player2 ile). İlk görünür sonuç.
3. Behavior cloning.
4. PPO (Gymnasium simülasyonu).
5. LLM çıktılarını policy girdisine bağlama (uygulandı: `goal_delta`, `moods`, `Control.lua`; oyunda denenecek).

## İlk iş

- A-Life'ın Lua kodunu incele: karar/durum fonksiyonları, konuşma/uyarı fonksiyonları, NPC kimliği ve modData alanları, squad yapısı.
- A-Life dosyaları Steam workshop klasöründe: `steamapps/workshop/content/108600/3803984183`. Erişilemiyorsa kullanıcıdan Claude Code'u `--add-dir` ile bu klasörü ekleyerek başlatmasını iste.
- Bulguları `docs/alife-hooks.md` dosyasına yaz, sonra 1. aşamaya geç.

## Ortam

- Project Zomboid Build 42.20+ (stable), A-Life v1.3.x (B42.21 destekli).
- Doğrulandı (2026-10-08): Windows 11, PZ 42.21.0, A-Life v1.3.15.
- A-Life bu makinede Steam workshop'ta **değil**, elle kurulu: `C:\Users\ERDEM\Zomboid\mods\ProjectALifeNPCs\42.20\`.
- Oyunla gelen Java: `C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\jre64\bin\java.exe` (Kahlua testleri için).
- A-Life inceleme notları: `docs/alife-hooks.md`.

## Referanslar

- A-Life Workshop sayfası: https://steamcommunity.com/sharedfiles/filedetails/?id=3803984183
- PZ modding API notları: https://github.com/FWolfe/Zomboid-Modding-Guide/blob/master/api/README.md
- PZ JavaDocs (LuaFileWriter): https://demiurgequantified.github.io/ProjectZomboidJavaDocs/
- ZombieBuddy (Java mod alternatifi; dağıtım için önerilmiyor): https://github.com/zed-0xff/ZombieBuddy
- Player2: https://player2.game
- Player2 Python istemcisi: https://pypi.org/project/player2py/
- Player2 Godot eklentisi (API kullanım örnekleri): https://github.com/elefant-ai/player2-ai-npc-godot
- Stable-Baselines3 PPO: https://stable-baselines3.readthedocs.io
