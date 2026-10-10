# Dosya köprüsü protokolü (v1)

Uygulama: Lua `mod/Contents/mods/ALifeBrain/42/media/lua/shared/ALifeBrain/Bridge.lua`,
Python `sidecar/alifebrain_sidecar/` (`protocol.py`, `files.py`, `app.py`).

## Dosyalar (hepsi `Zomboid/Lua/` içinde, düz ad)

| Dosya | Yazan | Okuyan | Nasıl |
|---|---|---|---|
| `alifebrain_req.txt` | Lua (ekleme) | sidecar | Sidecar dosyayı **yeniden adlandırarak** sahiplenir; Lua bir sonraki yazışta yenisini oluşturur. Lua hiçbir zaman kesme/temizleme yapmaz. |
| `alifebrain_req.processing` | sidecar | sidecar | Sahiplenilen parti; okunduktan sonra silinir. Çökmeden kalırsa önce o işlenir. |
| `alifebrain_res.txt` | sidecar (atomik değiştirme) | Lua (~250 ms'de bir) | `alifebrain_res.tmp`'ye yazılır, `os.replace` ile değiştirilir. |

İçerik JSON satırlarıdır ama uzantı `.txt`'dir: B42'de `getFileWriter` yalnızca `txt, ini, cfg, json, lua, log`
uzantılarına yazar, `.jsonl` gibi diğerlerini hata vermeden reddeder.
| `alifebrain_res.tmp` | sidecar | — | Geçici. |

Windows'ta oyun bir dosyayı açık tuttuğu sürece yeniden adlandırma/değiştirme başarısız olur; sidecar bu durumda
bir sonraki adımda tekrar dener. Böylece yarım satır asla okunmaz. Sidecar bu dört dosya dışında `Zomboid/Lua`'ya
dokunmaz.

Bütün satırlar **ASCII** JSON'dur (ASCII dışı karakterler `\uXXXX`), bu yüzden dosya kodlaması önemli değildir.

## Lua → sidecar (istek satırı)

```json
{"v":1,"id":"<sess>:<seq>","sess":"<sess>","type":"ping","ts":1759951234567,"data":{...},"ack":{"sid":"a1b2c3d4","rseq":7}}
```

- `sess`: oyun açılışında üretilir (`<ms>-<rastgele>`). Her yeni oyun yüklemesinde değişir.
- `id`: oturum içinde benzersiz; cevaplar `re` alanında buna atıf yapar.
- `ts`: Lua'nın `getTimestampMs()` değeri (duvar saati, ms).
- `ack` (isteğe bağlı): Lua'nın o sidecar örneğinden (`sid`) işlediği en büyük `rseq`. Her mesaja eklenir; gönderilecek
  başka bir şey yoksa en fazla saniyede bir ayrı bir `ack` mesajı gider.
- `type` değerleri (v1): `hello`, `ping`, `event`, `dialogue`, `history`, `moods`, `ack`. `event` ve `ack` için cevap satırı yazılmaz
  (`event` hatalıysa yazılır).
- `hello` cevabı `features` listesi döner (`ping`, `event`, `dataset`, hafıza varsa `history` ve `moods`, sağlayıcı ve
  hafıza hazırsa `dialogue`, `actions`); Lua diyalog kancasını yalnızca `dialogue`, karar örneklemesini yalnızca
  `dataset`, kayıtlı ruh hali isteğini yalnızca `moods` varsa kullanır.

### `dialogue` (2. aşama)

İstek `data` (Lua `Hooks.dialogueContext` + `Dialogue.handle`):

```json
{"text": "Su var mı?", "stance": "neutral",
 "npc": {"uid": "palife:...", "name": "...", "factionId": "...", "factionName": "...", "groupId": "...",
         "roleLabel": "Militia - Rifleman", "temperament": "seasoned", "sex": "m", "behaviorState": "idle", "wounds": 0},
 "player": {"key": "sp:0", "weapon": "hammer"},
 "facts": {"player_armed": true, "recent_zombie_contact": true},
 "world": {"town": "Muldraugh", "hour": 14, "day": 2}}
```

İstekte ayrıca `npc.inventory` (`{"water": 1, "food": 0, "medicine": 2}`, A-Life'ın verilebilir eşya kurallarıyla
sayılır) ve `npc.following` (NPC şu an bu oyuncuyu takip ediyor mu) gelir.

Cevap `data`: `{"say": "...", "intent": "none|give|follow|stay|leave|trade|warn|attack|rob|give_info",
"item": "water|food|medicine|null", "trustDelta": 0, "fearDelta": 0, "trust": 0, "fear": 0, "goalDelta": 0,
"goal": 0}`. `item` yalnızca `give` ile gelir. `goal` NPC'nin atılganlığıdır (5. aşama, policy'nin `goal` girdisi;
−100 sakin dur, güvende kal ↔ 100 ganimet için dışarı çık, risk al): oyuncu başına değil NPC başına tutulur, LLM her
cevapta `goal_delta` ile en çok ±25 oynatır, 30 dakikalık yarı ömürle 0'a söner (`memory.GOAL_HALF_LIFE_MS` =
`Dialogue.GOAL_HALF_LIFE_MS`; değer cevap anındaki hâlidir, oyun kendi saatiyle söndürmeye devam eder).

İstekte `world.language` oyunun dil kodudur (`TR`, `EN` ...). Pazarlıkta (`Parley.lua`) `standoff: {"opening": bool}`
gelir: NPC düşmandır ve oyuncuyu ateş etmeden durdurmuştur. `opening = true` ise NPC ilk konuşur; `text` oyuncunun
sözü değil bir anlatımdır (hafızaya oyuncu satırı olarak yazılmaz, prompt'a dil adıyla eklenir). Pazarlıkta
`intent attack` çatışmayı, `intent leave` oyuncuyu bırakmayı başlatır; haraç `trade` (`decision: counter`,
`npcWants`, boş `npcOffer`) ile istenir.

#### Takas alanları

İstekte `npc.tradeable` (`[{"name": "Konserve Fasulye", "count": 2}]`, NPC'nin elde/üstte/takılı olmayan, anahtar ya da
içi dolu çanta olmayan eşyaları, en çok 30 tür) ve masada bir şey varsa `trade`:
`{"playerOffer": [{"name", "count"}], "npcSide": [{"name", "count"}]}` (oyuncunun koyduğu / NPC'den istediği).
Sohbet penceresi açıkken istekte ayrıca `player.tradeable` (oyuncunun takas edebileceği eşyalar, aynı biçim) gelir;
NPC bunlardan isteyebilir.
Cevapta `trade`: `null` ya da `{"decision": "accept|reject|counter", "npcOffer": ["..."], "npcWants": ["..."]}`.
`accept` masadaki değişimi şimdi yaptırır; `counter` NPC'nin kendi eşyalarını (yalnızca `tradeable` adları) masaya
koyar ve `npcWants` (yalnızca `player.tradeable` adları) varsa oyuncunun tarafını tam olarak bunlarla doldurur
(eşyalar yine oyuncuda kalır); oyuncu "Kabul et" ile yeni bir LLM çağrısı olmadan alabilir.

**Veresiye yok:** değişimi her zaman oyun yapar (`Hooks.executeTrade`): önce her iki tarafın eşyaları yeniden
doğrulanır; NPC bir şey veriyorsa oyuncunun tarafı boş olamaz (`unpaid`); önce oyuncunun eşyaları taşınır, sonra
NPC'ninkiler; bir eşya taşınamazsa bütün taşımalar geri alınır. Oyuncu beklerken masayı değiştirdiyse kabul
geçersizdir. Sidecar ayrıca pazarlığın parçası olan bir `give`'i (oyuncunun ya da NPC'nin sözünde "karşılığında",
"takas", oyuncunun sözünde "veririm", "I'll pay" vb.) takas önerisine çevirir: NPC'nin eşyası masaya konur, oyuncunun
adını andığı eşyası istenir.

### `history`

İstek `data`: `{"uid": "...", "playerKey": "sp:0", "limit": 30}`. Cevap: `{"uid", "name", "trust", "fear", "goal",
"turns": [{"speaker": "player|npc|system", "text": "...", "ts": 0}]}` (eskiden yeniye). `system` satırları oyunda
gerçekte olanlardır (ör. "Henry handed over Water Bottle.").

### `moods` (5. aşama)

Policy'nin girdisi için, bu oturumda konuşulmamış NPC'lerin kayıtlı ruh hali (`Moods.lua`). İstek `data`:
`{"playerKey": "sp:0", "uids": ["palife:...", ...]}` (en çok 32 uid; oyun 24'lük gruplarla, 3 s'de en çok bir
istek gönderir). Cevap: `{"moods": [{"uid", "trust", "fear", "goal"}], "goalHalfLifeMs": 1800000}`; yalnızca
sidecar'da bir şeyi kayıtlı NPC'ler listelenir (gerisi 0'dan başlar; oyun onları 5 dakika sonra yeniden sorar).
Oyun bunları yalnızca elinde olmayan NPC'ler için `Dialogue.minds`'a yazar; bu oturumdaki bir cevap her zaman daha
yenidir.

### `decision_samples` (3. aşama, davranış klonlama verisi)

`event` olarak gelir (`DecisionLog.lua`), sidecar `hello` cevabında `dataset` özelliğini bildirdiyse gönderilir;
hafızaya ve `events.jsonl`'e girmez:

```json
{"kind": "decision_samples", "schema": 1, "names": ["health", "..."],
 "rows": [{"d": "decision", "a": "regroup", "o": [1, 0, 0.5, "..."], "m": ["orders", "regroup"],
           "u": "palife:...", "f": "alife_church_volunteers", "p": "...", "t": 1791496029466, "pa": "regroup"}]}
```

- `d`: A-Life zinciri (`decision` tehdit yokken, `response` tehdide), `a`: kazanan modül id'si ya da `default`
  (A-Life'ın kendi geri düşüşü), `o`: `Features.vector` (3 hane yuvarlanmış), `m`: o NPC'nin o zincirde izinli
  modülleri, `pa`: gölge modundaki policy'nin seçimi (eğitilmiş ağırlık varsa).
- `names` her bağlantıda ilk partiyle bir kez gelir. Parti en çok 12 satır (satır sınırının altında kalsın diye).
- Sidecar geçerli satırları `<veri klasörü>/dataset/decisions-<tarih>.jsonl`, adları `schema-<n>.json` dosyasına yazar.
  Özellik listesi değişirse `Features.SCHEMA` artırılır; eski şemanın verisi ayrı kalır.

### `event` türleri

`npc_hit`, `npc_died` (EventLog.lua) ve `npc_action` (Dialogue.lua): `{"kind": "npc_action", "action":
"give|follow|stay|leave|trade", "ok": true, "item": "water", "label": "Water Bottle", "given": ["..."] (NPC'den
oyuncuya), "received": ["..."] (oyuncudan NPC'ye), "reason": "no_item|too_far|limit|low_trust|refused|rejected|
changed|empty|unpaid", "npc": {...}, "by": {"kind": "player", "key": "sp:0"}}`. `trust`/`fear` NPC'nin o oyuncuya karşı birikmiş değeridir (-100..100).
Hata kodları: `dialogue_unavailable`, `invalid_llm_reply`, sağlayıcı kodları (`timeout`, `rate_limited`,
`unreachable`, `unauthorized`, `player2_client_id_missing` ...). LLM çağrısı sidecar'da arka planda çalışır;
Lua 35 s bekler (Player2 ücretsiz modeli ölçümde 10–17 s sürdü; sidecar 30 s sonra vazgeçer), sonra A-Life'ın hazır repliğine düşer.

## Sidecar → Lua (cevap dosyası)

İlk satır **her zaman** durum satırıdır, sonrakiler onaylanmamış mesajlardır:

```json
{"v":1,"type":"status","sid":"a1b2c3d4","beat":42,"ts":1759951234600,"ver":"0.1.0","sess":"<son görülen oturum>"}
{"v":1,"type":"res","rseq":7,"re":"<istek id>","ok":true,"data":{...}}
{"v":1,"type":"res","rseq":8,"re":"<istek id>","ok":false,"error":"unknown_type"}
{"v":1,"type":"push","rseq":9,"sess":"<oturum>","kind":"...","data":{...}}
```

- `sid`: sidecar süreci başına rastgele. Değişirse Lua `rseq` takibini sıfırlar.
- `beat`: her yayında artar; sidecar boşta bile saniyede bir yayın yapar.
- `rseq`: sidecar örneği içinde artan sıra; Lua yalnızca `lastRseq`'ten büyükleri işler (tekrarlar zararsız).
- Sidecar, onaylanan (`rseq ≤ ack`), 120 s'den eski veya eski oturumlara ait mesajları dosyadan çıkarır.

## Canlılık ve geri düşüş

- Lua, durum satırındaki `ts` kendi saatine 4 s'den yakınsa **veya** `beat` son 4 s içinde değiştiyse sidecar'ı
  çevrimiçi sayar.
- Çevrimdışıyken Lua dosyaya **hiç yazmaz**: `request()` hemen `nil, "offline"` döner (çağıran hazır repliğe düşer),
  `send("event")` olayları bellekte en fazla 200 kayıtlık bir kuyrukta tutar ve bağlantı gelince orijinal `ts` ile
  gönderir.
- Çevrimiçiyken düşerse bekleyen bütün istekler `false, "offline"` ile sonuçlanır.
- İstek zaman aşımı varsayılan 8 s (`ping` 5 s). Sidecar, `event`/`ack` dışındaki 30 s'den eski istekleri atar.

## Sınırlar

- Satır başına en fazla 16000 karakter; JSON derinliği en fazla 64.
- Lua giden kuyruğu 256 satır; sidecar bekleyen cevaplar 500.
- Aynı anda tek sidecar: veri klasöründeki `sidecar.lock` dosyası kilitlenir.
