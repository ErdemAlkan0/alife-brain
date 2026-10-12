# A-Life hook noktaları (inceleme notları)

İncelenen sürüm: **Project A-Life v1.3.15** (`modversion=1.3.15`, `versionMin=42.21.0`), oyun **42.21.0**.
Konum: `C:\Users\ERDEM\Zomboid\mods\ProjectALifeNPCs\42.20\media\lua\` (Steam workshop değil, elle kurulmuş;
CLAUDE.md'deki `workshop/content/108600/3803984183` yolu bu makinede yok).

Aşağıdaki dosya yolları bu klasöre görelidir. A-Life güncellenince bu belgeyi ve `ALifeBrainHooks.lua` dosyasını
birlikte gözden geçir.

---

## 1. Genel yapı

- Tüm kod `ProjectALife` global tablosu altında: `ProjectALife.DecisionLoop`, `ProjectALife.ModuleRegistry`,
  `ProjectALife.ActorRegistry`, `ProjectALife.Talk`, `ProjectALife.Speech`, `ProjectALife.Relations`,
  `ProjectALife.Reputation`, `ProjectALife.Watchdog` ...
- Karar, konuşma, itibar **server** klasöründe (`server/ProjectALife/...`). SP'de client+shared+server aynı Lua VM'de
  çalışır, yani hepsine doğrudan erişilir. MP istemcisinde server tabloları **yok** (istemci yalnızca
  `MirrorTransport`/`sendServerCommand` ile gelen kopyaları görür).
- Başlatma: `server/ProjectALife/Core/ALifeServerBootstrap.lua` → `OnGameStart`/`OnServerStarted` içinde
  `Runtime.safeStart(...)`, her `OnTick` içinde `Runtime.tick()`. Bizim kancalarımızı **`OnGameStart` sonrasında**
  kurmak en güvenlisi (A-Life tabloları o anda dolu).
- A-Life sık sık `pcall` + `type(x) == "function"` korumasıyla birbirini çağırıyor; biz de aynısını yapmalıyız.

## 2. NPC kimliği

NPC = zombi gövdesi ("shell") + kayıt ("actor record").

| Nerede | Alan | Not |
|---|---|---|
| `shell:getModData()` | `ProjectALifeOwned == true` | A-Life NPC'si mi? (CLAUDE.md'deki kontrol doğru) |
| | `ProjectALifeUID` | Kalıcı kimlik, ör. `"palife:<ms>:<seq>"` (≤ 64 karakter) |
| | `ProjectALifeGeneration` | Gövde yeniden yaratıldıkça artar; `uid + generation` birlikte doğrulanmalı |
| | `ProjectALifeFactionId`, `ProjectALifeProfileId` | Fraksiyon ve profil |
| | `ProjectALifeActivity`, `ProjectALifeIntent` | Kayıttaki aktivite/niyetin yansıması |
| | `ProjectALifeBehaviorState`, `ProjectALifeBehaviorIntent` | **Karar döngüsünün o anki durumu** (her `think` sonunda `stampState` yazar) |
| `shell:GetVariable(...)` | `ALifeActor`, `ALifeUID`, `ALifeGeneration` | Aynı bilgilerin animasyon değişkeni kopyası |

Yardımcılar:
- `ProjectALife.Speech.variable(shell, "ALifeUID")` → önce modData `ProjectALifeUID`, yoksa `GetVariable`.
- `ProjectALife.ShellAdapter.shellIdentity(shell)` → `uid, generation`.
- `ProjectALife.Watchdog.bindings[uid].shell` → uid'den gövdeye (yalnızca otorite tarafında).
- `ProjectALife.Speech.findShell(uid)` → istemcide de çalışan yavaş yol (hücredeki zombi listesini tarar).

## 3. Aktör kaydı — `server/ProjectALife/Core/ALifeActorRegistry.lua`

Kayıt alanları: `uid`, `revision`, `generation`, `lifecycle` (`dormant|spawning|active|dead`), `profileId`,
`factionId`, `worldPosition {x,y,z}`, `activity`, `intent`, `memory` (serbest tablo).

Önemli `memory` alanları: `groupId` (squad), `outpostId`, `supportForGroupId`, `behaviorProfile`, `conduct`,
`moduleOverrides`, `spawnStance`, `hostileOverride`, `hostileToPlayerKeys`, `hostileToActorKeys`,
`carefulPlayerKeys`, `tolerateUntil`, `robbery`, `robberyTruce`, `talkHoldUntilMs`, `talkHoldPlayerKey`.

API:
- `Registry.read(uid)` → kopya, `Registry.peek(uid)` → canlı kayıt (değiştirme!), `Registry.each(fn)`.
- `Registry.update(uid, revision, mutate)` / `updateTransient(...)` / `updateMany(uids, mutate)` — iyimser kilit
  (`revision` uyuşmazsa reddeder). `memory` yazmak için `ProjectALife.Talk.writeMemory(uid, fn)` hazır bir sarmalayıcı.

## 4. Karar döngüsü — `server/ProjectALife/Decisions/ALifeDecisionLoop.lua`

- `Decisions.tick(budget)` her tick'te zaman bütçesi (12 ms) içinde aktörleri dolaşır. Oyuncuya yakın (≤ 45 kare)
  aktörler 150 ms'de bir, uzaktakiler (> 110) 1.5 s'de bir düşünür.
- `Decisions.think(uid, now)` → `update(actor, shell, state, now)` → gerekirse `decide(...)` → yeni durum
  `Decisions.states[uid]` içine yazılır ve gövdeye damgalanır.
- **Durum (state) şekli:** `{ kind, intent, cooldownUntilMs, action?, threat?, threatKind?, ... }`
  - `kind`: `idle | movement | combat | retreat | recovering | scavenging`
  - `intent`: serbest metin, ör. `patrol`, `regroup`, `search`, `investigate`, `retreat`, `hold`, `scan`,
    `engage_threat`, `manhunt_player`, `hunt_nearby`, `hold_pressure`, `robbery_pending`, `recover_endurance` ...
- `decideInternal` sırası:
  1. `Perception.findThreat` → tehdit varsa `respondToThreat`:
     **`Modules.evaluate("response", actor, shell, ctx)`** (ctx: `now, threat, threatKind, startRetreat,
     startMovement, setActivity, persistMemory`) → sonuç yoksa `Combat.canEngage` → `startCombat`.
  2. Destek çağrısı (`Programs.supportDestination`), ortam replikleri.
  3. **`Modules.evaluate("decision", actor, shell, ctx)`** (ctx: `now, threat, threatKind, mode, factionProgram,
     orders, defaults, setActivity, startMovement, orderedTarget, persistMemory`).
  4. Son görülen konum araması, ses/ipucu araştırması, `Programs.destination` (devriye/dolaşma), yoksa `idle/hold`.
- Oyuncu emirleri (açık API): `Decisions.setOrder(uid, generation, { kind = "follow"|"hold"|"patrol",
  player = <IsoPlayer>, anchor = {x,y,z}, untilMs?, quiet? })`. `follow` intent'i için doğrudan kullanılabilir.
- `Decisions.refreshDirective(uid)` → mevcut hareket/idle durumunu iptal edip yeniden karar verdirir.
- `Decisions.traceDecisions = true` olursa her karar `Telemetry.emit("decision_trace", {uid, kind, intent})` üretir.
- **Uygulandı (3. aşama):** `Registry.evaluate(kind, ...)` kazanan durumla birlikte **modül id'sini** de döndürür
  (`return result, module.id`), karar döngüsü id'yi atar. Döngü `local Modules = ProjectALife.ModuleRegistry` tuttuğu
  için fonksiyon her çağrıda tablodan okunur; `Hooks.installDecisionTap` `ModuleRegistry.evaluate`'i sarmalar, yalnızca
  `only == nil` olan tam zincir çalışmalarını (`decision`, `response`) izler ve sonucu değiştirmeden döndürür. Etiket =
  modül id'si ya da `default` (zincir boş döndü, A-Life'ın kendi akışı). İzinli modüller (eylem maskesi):
  `Registry.order` içinde `dispatch == kind` olanlar ve `Registry.allows(actor, id)`.
- **Uygulandı (5. aşama):** aynı sarmalayıcı (`Hooks.wrapEvaluate`), policy kontrolü açıkken tam zincirden **önce**
  `Hooks.decisionChooser`'a (`Control.pick`) sorar; bir modül id'si dönerse o modül tek başına (`only`) çalışır,
  `nil` dönerse (yapacak işi yok) ya da seçim yoksa A-Life'ın zinciri eskisi gibi çalışır. Modüller `evaluate`
  içinde hareket başlatır, animasyon/ses çalar, belleğe yazar (`context.startMovement`, `persistMemory`; ör.
  `Search.evaluate`): bu yüzden zincir önce çalıştırılıp sonucu sonradan değiştirilemez. Policy'nin seçtiği kararlar
  `chosen = true` ile bildirilir, BC verisine girmez. A-Life'ın kendi lull çağrıları (`only` dolu) olduğu gibi geçer.
  `Hooks.orderOf(uid)` (`DecisionLoop.orders`), `Hooks.nearestPlayer(shell)` ve `Hooks.stance` Control'ün "A-Life'a
  bırak" kararları için. Mesafeler A-Life'tan: `ModuleCareful.settings.warnRadius` 14 (`memory.carefulRadii` ve
  senaryolu karşılaşmalar değiştirebilir), `ModuleTalkPresence.courtesyTiles` 6, `ModuleRobbery.detectRadius` 55.
- Gözlem kaynakları (`Hooks.decisionObservation`): gövde modData'sı (§9), `context.threat/threatKind`,
  `Perception.zombieSnapshot` (algı her 200 ms'de yeniler: `bodies` = sıradan zombiler, `actors` = A-Life gövdeleri,
  ikisi de `{body, x, y, z}`; algı çalışmadan önce `nil`), `ActorRegistry.peek(uid).memory.groupId` (squad),
  `DecisionLoop.states/orders`, `Talk.stance`, en yakın oyuncu.

## 5. Modül kaydı — `shared/ProjectALife/Behaviours/ALifeModuleRegistry.lua` (RL kancası)

Bu, A-Life'ın **kendi eklenti noktası**; RL kararını monkey-patch olmadan enjekte etmenin en temiz yolu.

```lua
ProjectALife.ModuleRegistry.register({
    id = "alifeBrain", kind = "orders", dispatch = "decision", priority = 2,
    evaluate = function(actor, shell, context) ... return stateOrNil end,
})
```

- `Registry.evaluate(kind, actor, shell, ctx, only)` zinciri **öncelik numarası küçükten büyüğe** dener; ilk `nil`
  olmayan sonuç kazanır. `nil` dönersek A-Life normal akışına devam eder → sidecar/policy yoksa sorunsuz geri düşüş.
- `only` parametresi tek bir modülü çalıştırır: `Registry.evaluate("decision", actor, shell, ctx, "regroup")`.
  **RL aksiyonu = A-Life modül id'si** olarak tasarlanabilir; policy bir id seçer, biz o modülü `only` ile çağırırız.
- **Engel:** `Registry.allows()` → `BehaviorProfiles.allows(actor, id)` yalnızca profilin `overlays` tablosundaki
  id'lere izin veriyor. Bilinmeyen id'li modülümüz **hiç çalışmaz**. Seçenekler:
  - (a) `ProjectALife.BehaviorProfiles.definitions[i].overlays.alifeBrain = true` (çalışma zamanında tablo eklemesi,
    A-Life dosyası değişmez) — önerilen; `ALifeBrainHooks.lua` içinde tutulacak.
  - (b) Her aktörün `memory.moduleOverrides.alifeBrain = "on"` yazmak (kayıt verisini kirletir, önerilmez).
  - (c) A-Life ekibinden "dış modüller için profil whitelist'i" istemek (Discord sorusu).
- Mevcut öncelikler (küçük = önce): `robbery` 3, `talk` 4, `careful` 5, `orders` 10, `flee` 30, `stealth` 30,
  `panic` 34, `radioman` 35, `sniper` 38, `warning` 40, `ambusher` 42, `withdraw` 45, `cover` 50, `weave` 55,
  `strafe`/`doorstack` 60, `fortify` 78, `nightHold` 79, `medic` 85, `healing` 90, `cqbsweep`/`patrolRest` 92,
  `stance` 95, `investigate` 100, `regroup` 110, `search` 117, `scavenge` 118, `idleLife` 140, `spread` 150,
  `groupMarch` 200, diğerleri 500.
  - Önerim: RL modülü `robbery`/`talk`/`careful`'dan **sonra** (ör. `priority = 8`) gelsin; soygun ve konuşma
    sahnelerini bozmasın.

### RL aksiyon adayları (modül id → dispatch)

| Kanal | Modüller |
|---|---|
| `decision` (tehdit yokken) | `orders`, `careful`, `robbery`, `talk`, `fortify`, `nightHold`, `cqbsweep`, `medic`, `healing`, `patrolRest`, `stance`, `investigate`, `regroup`, `search`, `scavenge`, `idleLife`, `spread`, `groupMarch` |
| `response` (tehdit varken) | `flee`, `panic`, `radioman` (+ varsayılanı `reaction` olan diğerleri) |
| `positioning` (çatışma içi) | `stealth`, `sniper`, `ambusher`, `weave`, `cover`, `withdraw` |

Not: `stealth`, `sniper`, `medic`, `ambusher`, `leader` **primary** modüller; yalnızca `memory.conduct` o id ise
çalışır. Ayrıca `kind = "doctrine"`/`"craft"` olup `dispatch` verilmeyenler hiçbir zincire girmez (başka yerden
çağrılıyorlar). Bu tablo ilk RL aksiyon uzayı için başlangıç; CLAUDE.md'deki "devriye, baskın, bölge tutma, uyarma,
soyma, yeniden toplanma" ile eşleme: devriye → `patrolRest`/varsayılan program, bölge tutma → `fortify`/`nightHold`,
uyarma → `careful`, soyma → `robbery`, yeniden toplanma → `regroup`, baskın → `ModuleBreach` (`doorstack`/`cqbsweep`).

### Takipçi tehdit davranışı (oyunda görüldü, 2026-10-09)

- `decideInternal` önce `findThreat` → `respondToThreat` çalıştırır; emir (`orders`) yalnızca tehdit yoksa devreye
  girer. Takip emrinin tasması yok (`Combat.leashFor` yalnızca `memory.stance` / `garrisonPost` olan nöbetçiler için).
  Sonuç: takipçi gördüğü her zombiye saldırır (Grace, yakın dövüş, 25 zombiye daldı).
- Zombiye karşı A-Life'ın tek geri çekilmesi `flee` modülü (`Fear/ALifeModuleSurvival.lua`): can ≤
  `Survival.retreatHealth` (~0,35). Fraksiyon üyelerinde `flee` profile göre kapalı olabilir (Grace'te yalnızca
  `panic` vardı).
- `interruptPassiveState`: `idle` / `movement` / `scavenging` / `recovering` durumları tehdit görüldükçe (son
  taramada tehdit varsa her düşünmede) kesilir ve yeniden tepki verilir; `retreat` durumları kesilmez.
- **Uygulandı:** `Hooks.installCompanionModule` → `alifeBrainCompanion` (`kind = "reaction"`, `dispatch = "response"`,
  öncelik 32: `flee` 30 ile `panic` 34 arası). Profil izni için id çalışma zamanında her
  `BehaviorProfiles.definitions[i].overlays` tablosuna eklenir (kayda yazılmaz; 30 s'de bir yeni profiller için
  tekrarlanır). Yalnızca oyuncu takip emri (`DecisionLoop.orders[uid].kind == "follow"`, `source ~= "leader"`) ve zombi
  tehdidinde karar verir (`Companion.lua`); oyuncuya dönüş `context.startMovement(..., { kind = "retreat" })` ile
  (kesilmesin diye), uzaklaşma A-Life'ın `context.startRetreat`'i ile.

### Gizli takip, NPC uyarıları, pazarlık (oyunda görüldü / istendi, 2026-10-09)

- **Hız:** `orders` modülü takibi hızsız başlatır → `Movement` `walk`. `run` istenince `resolvePace` 14 s'de bir
  650 ms koşu penceresi verir (tehlike duruşunda sürekli koşu) → "kısa koşular". Dünyaya ses yalnızca ateşli silah
  atışı üretir (`Combat.worldNoise`); `Voice.play` dünya sesi üretmez.
- **Eğilme:** `AIFence` her karede `Stealth.stanceActive(modData)` sonucunu `ALifeSneak` animasyon değişkenine ve
  `ProjectALifeSneakActive`'e yazar (yürüme ×0,85, sprint koşuya iner, sırttan saldırı çarpanı). Yalnızca
  `ProjectALifeConduct == "stealth"` NPC'ler için açık. **Uygulandı:** `Hooks.wrapStealthStance` oyuncusu eğilen
  takipçileri ekler (`Companion.sneakers`, 0,5 s'de bir `DecisionLoop.orders`'tan).
- **Uyarı merdiveni:** `ModuleCareful` (karar zinciri, öncelik 5) yalnızca oyunculara uyarır (`CAREFUL_KEEP_BACK` →
  `CAREFUL_LAST_WARNING` → `CAREFUL_HOSTILE`, fraksiyon sesleri `Audio/ALifeFactionVoiceStyles.lua`);
  `Careful.evaluateActor` hep `nil`. **Uygulandı:** `alifeBrainStandoff` aynı merdiveni NPC↔NPC için uygular.
- **Ateşkes:** `memory.robberyTruce[Reputation.playerKey(player)] = untilMs` iken `Relations.hostileToPlayer` false
  döner (görünen tutum `playerStance` yine "hostile"). A-Life bunu soygundan sonra kullanır; `memory.robbery`
  etkinken de ekip oyuncuyu tehdit saymaz. **Uygulandı:** pazarlık ekibe 6 s'lik ateşkes yazar ve 2 s'de bir
  yeniler; barışta uzun ateşkes, çatışmada silinir + `DecisionLoop.refreshDirective`.
- **A-Life'ın soygunu** (`ModuleRobbery`): yalnızca haydut/çete kayıtlı, en az 2 kişilik, silahlı ekipler; kendi
  taraması (55 kare) tehdit tepkisinden önce başlar. Pazarlık, soygun etkinken (`memory.robbery`) devreye girmez.

## 6. Konuşma sistemi (LLM kancası)

Akış (SP):
1. `client/.../Talk/ALifeTalkInput.lua`: sohbet tuşu → kendi metin kutusu (`Input.open`) veya vanilla sohbet
   sarmalayıcısı (`processSayMessage`/`processShoutMessage`). `!` ile başlayan metin = bağırma.
2. `Input.deliver("talkSay", {text, loud})` → SP'de doğrudan `Talk.onPlayerText(player, text, loud)`, MP'de
   `sendClientCommand(player, "ProjectALife", "talkSay", args)`.
3. `server/.../Talk/ALifeTalk.lua` `Talk.onPlayerText`: soygun kelimeleri (`ModuleRobbery.onPlayerWords`) →
   dinleyiciler (12 kare, bağırınca 25; bakış konisi 60°) → muhatap → **`Talk.respond(player, listener, text, now,
   choiceIntent)`**.
4. `Talk.respond`: çatışmadaysa `TALK_BUSY_COMBAT`, düşmansa `TALK_IGNORE_HOSTILE`; değilse
   `TalkIntents.classify(text)` (anahtar kelime puanlama, eşik 30) → `DialogueData.replies[intent]` havuzundan
   `Speech.pick` → `Speech.say`.

**LLM için kanca noktası:** `Talk.respond`. Plan: yalnızca serbest metin (`choiceIntent == nil`), çatışma dışı ve
düşman olmayan durumlarda araya gir:
- `Talk.hold(record, shell, player, now, ms)` → NPC durur ve oyuncuya döner (bekleme süresince tekrarla).
- `Speech.say(shell, "...", { face = player })` → bekleme balonu.
- Cevap gelince `Speech.say(shell, reply, { face = player })`; zaman aşımında orijinal `Talk.respond` çağrılır
  (hazır replik geri dönüşü).
- Bu bir fonksiyon sarmalaması (wrap); `ALifeBrainHooks.lua` içinde tutulacak ve orijinal referans saklanacak.
- **Uygulandı (2. aşama):** `Hooks.installTalkHook(Dialogue.handle)`; orijinal `Hooks.originalRespond` içinde,
  geri düşüş `Hooks.respondWithAlife`. Yalnızca tek oyunculu (MP istemcisinde `Talk` tablosu yok).
- **Araya giren replikler:** `server/.../Behaviours/ALifeModuleTalkPresence.lua` `evaluate`, `memory.talkHoldUntilMs`
  geçerliyken NPC'yi `talk_hold` durumunda tutar (susar, oyuncuya döner). Tutma bitince oyuncu 5 kare içindeyse
  `GREET_PLAYER`, 2,5 kare içinde 20 s'den uzun kalırsa `STARE_PLAYER` der; sayaçlar `Presence.greeted[party]` /
  `Presence.stared[party]`, `party = Presence.partyKey(actor, playerKey)`. Bizim çözüm: pencere açıkken her 2 s
  `Talk.hold`; kapanınca `Hooks.release` (`Talk.writeMemory` ile tutmayı bırakır) + `Hooks.quietPresence` (iki
  sayacı 3 dk ileri alır).
- **Eşya verme:** `server/.../Talk/ALifeTalkSupplies.lua` `Supplies.matches(item, "ASK_WATER"|"ASK_FOOD"|"ASK_MEDS")`
  A-Life'ın verilebilir eşya kuralları (içilebilir su, bozuk/zehirli olmayan yiyecek, ilk yardım; kuşanılmış değil).
  Aktarım `shell:getInventory():Remove(item)` + `player:getInventory():AddItem(item)`, MP sunucuda
  `sendRemoveItemFromContainer` / `sendAddItemToContainer` (Supplies.respond ile aynı).
- **Takip / bekleme:** `DecisionLoop.setOrder(uid, generation, { kind = "follow", player, untilMs })` ve
  `{ kind = "hold", anchor, untilMs }`; `orders` modülü (öncelik 10) uygular, tehdit tepkileri yine önce gelir.
  Etkin emir: `DecisionLoop.orders[uid]`.

Prompt için hazır bağlam:
- `Speech.contextFor(record, player)` → `role, register, temperament, sex, day, hour, voice, stance`.
- `Talk.stance(record, player)` → `hostile | careful | neutral | friendly`.
- `Talk.observations(record, shell, player, now)` → `recent_zombie_contact`, `recent_human_contact`, `player_armed`.
- `Talk.varsFor(intent, ...)` → `destination`, `town`, `den`, `weapon`.
- `Speech.nearestTown(x, y)`, `Speech.clock()`.

Diğer:
- `Speech.say` server'da `sendServerCommand(player, "ProjectALife", "speech", {uid, text, x, y})` ile 40 kare
  içindeki oyunculara yayınlar; istemci `Speech.onServerCommand` ile `shell:addLineChatElement` çizer.
- `ProjectALife.AudioPolicy.caption(text)` metni filtreler/biçimler; `nil` dönerse balon çıkmaz.
- Menü seçenekleri: `TalkIntents.choices` (ör. `ASK_NEWS`, `ASK_DESTINATION`, `JOIN_REQUEST`, `YES`, `NO`).
- `Talk.settings.maxTextLength = 200`, komut hız limitleri `Talk.commandIntervalMs` (talkSay 800 ms).

## 7. İlişki ve itibar (RL gözlemi + LLM'in etkileyebileceği kollar)

- `Relations.playerStance(actor, player)` → `hostile | careful | neutral | friendly` (A-Life "allied"i
  "friendly"ye indirger). Katmanlar: fraksiyon tabanı (`RelationLayers.towardPlayer`, meslek kaydırması dahil) →
  `spawnStance` → `Reputation.recordedStatus` (fraksiyon başına kayıtlı durum) → aktör `memory` geçersiz kılmaları.
- `Relations.status(sourceActor, targetActor)` → NPC↔NPC ilişki.
- `Reputation` (`ModData "ProjectALife.Reputation.v1"`): `escalate(player, actor, "attack"|"kill"|"provoked")`;
  `provoked` 24 oyun saati sonra unutulur.

LLM `trust_delta` / `fear_delta` → A-Life'ta zaten var olan kollar (sınırlı, geri alınabilir olanlar tercih):

| Kol | Etki | Nasıl |
|---|---|---|
| `memory.tolerateUntil[playerKey] = untilMs` | `careful` → `neutral` | `Talk.tolerate(record, playerKey, untilMs)` (squad'a yayar). **Uygulandı:** `Rapport.lua` (güven ≥ 5) |
| `memory.carefulPlayerKeys[playerKey] = untilMs` | `neutral/friendly` → `careful` | `Talk.writeMemory` |
| `memory.hostileToPlayerKeys[playerKey] = true` | → `hostile` | `Talk.writeMemory` (geri dönüşü zor; LLM'e açma) |
| `Reputation.escalate(...)` | fraksiyon çapında düşmanlık | LLM'e **açma** |

`playerKey`: SP'de `"sp:0"`, MP'de kullanıcı adı (`Reputation.playerKey(player)`).

**Güven → tutum (uygulandı, 2026-10-12):** temkinli tutum yalnızca fraksiyondan gelir; `ModuleCareful`
(`Behaviours/ALifeModuleCareful.lua`, öncelik 5) 14 karede `CAREFUL_KEEP_BACK`, 9 karede ve oyuncu 0,75 kare daha
ilerleyince `CAREFUL_LAST_WARNING`, sonra 6 karenin içinde 1,5 s kalınca `turnGroup` (`hostileToPlayerKeys`, ateş)
yapar; merdiven grup + oyuncu başına, 45 s içeri girilmezse unutulur. Oyun testinde güveni 5–6 olan iki NPC sohbet
penceresi kapanınca (oyuncu 6 karenin içinde) gruba döndü. `Rapport.lua`: bildiğimiz en güvenen üyesi ≥ 5 olan
temkinli grup için `Hooks.tolerate` (= `Talk.tolerate`, 10 dk, 5 dk kalınca yenilenir); güven < 3 olunca yalnızca
bizim yazdığımız değer (`toleratedUntil` eşitse) `now` ile bitirilir. Hemen etki için cevap gelir gelmez de çalışır
(`Rapport.onReply`, `Dialogue.finish`). `Hooks.groupKey` = Careful'ın `groupOf` (karakol / grup / tek).

## 8. Olay kaynakları (loglama / hafıza / RL veri seti)

A-Life'ta genel bir olay yolu yok; `Telemetry.emit` çok az kategoriye sahip (`actor_died`, `decision_trace`,
`patrol_rest`, runtime hataları). Olayları şu yollarla toplayacağız:

| Olay | A-Life içindeki kaynak | Bizim yakalama yöntemimiz |
|---|---|---|
| Oyuncu NPC'ye vurdu | `Combat/ALifeHealth.lua Health.onDamage` → `Reputation.onPlayerDamagedActor`, `Talk.onHitByPlayer` | Vanilla `Events.OnHitZombie(zombie, attacker, bodyPart, weapon)` + `ProjectALifeOwned` filtresi; yedek: `modData.ProjectALifeWounds` artış farkı |
| NPC öldü / öldürüldü | `Core/ALifeLifecycle.lua` (`KillAttribution.resolve`, `Reputation.onPlayerKilledActor`) | Vanilla `Events.OnZombieDead(zombie)` + `zombie:getAttackedBy()`. Dikkat: `Sim.markCorpse` (`shared/.../Shells/ALifeShellSimulation.lua`) ölümde `ProjectALifeOwned`'ı siler ve `ProjectALifeCorpseOf = uid` yazar; `ShellAdapter` temizliği tüm `ProjectALife*` anahtarlarını silebilir. Bizim işleyici hem `ProjectALifeOwned` hem `ProjectALifeCorpseOf`'a bakıyor. |
| Squad üyesi öldü | aynı | Ölen NPC'nin `memory.groupId`'si → aynı gruptaki aktörlere hafıza kaydı |
| Soyuldu / soygun | `Behaviours/ALifeModuleRobbery.lua` (`phase`: `spot → demand → search → execute`, `finish`, `take`) | `memory.robbery.phase` farkını yoklama |
| Oyuncu yardım etti | `Talk.onHelped` (istemci `OnZombieDead` → `talkHelped`) | Vanilla `OnZombieDead` + yakın NPC çatışmadaysa |
| Yemek/eşya verildi | (A-Life'ta doğrudan yok; `Talk/ALifeTalkSupplies.lua` yalnızca isteme) | Kendi bağlam menümüz/aksiyonumuz (2. aşamada) |
| Durum/niyet değişimi (BC verisi) | `stampState` → `modData.ProjectALifeBehaviorState/Intent` | Oyuncu yakınındaki NPC'leri belirli aralıklarla örnekle |
| Stance değişimi | `Relations.playerStance` | Yoklama + fark |

## 9. RL gözlemi için hazır veriler

- Can/kanama: `modData.ProjectALifeWounds`, `ProjectALifeBleedOutAtMs`, `ProjectALifeDownedUntilMs`,
  `ProjectALifeWoundLeg`, `shell:getHealth()`; `ProjectALifeMaximumHealth`.
- Mermi/silah: `ProjectALifeLoadedRounds`, `ProjectALifeEngineLoadedRounds`, `ProjectALifeWeaponClass`,
  `ProjectALifeActiveWeaponType`, `ProjectALifeWeaponJammed`.
- Çatışma: `ProjectALifeCombatPhase`, `ProjectALifeCombatTactic`, `ProjectALifeTargetDistance`,
  `ProjectALifeTacticalRole`, `ProjectALifeBehaviorTier`, `ProjectALifeFearOf/FearUntilMs`, `ProjectALifePanicUntilMs`.
- Dayanıklılık: `ProjectALifeEndurance`, `ProjectALifeEnduranceMaximum`.
- Tehdit: karar modülünün `context.threat`, `context.threatKind` (`player | zombie | actor`).
- Oyuncu silahı çekili mi: `Talk.observations(...).player_armed`, `player:isAiming()`.
- Saat: `Speech.clock()` (`hour`, `daysSurvived`).
- Fraksiyon ilişkisi: `Relations.playerStance` (kategorik → one-hot).

## 9b. Test için NPC çağırma

- A-Life sağ tık menüsü (`client/.../Interface/ALifeContextMenu.lua`, debug/admin): `[A-LIFE] Project A-Life` →
  `Spawn faction squad here...` / `Open spawn panel`. İkisi de `ALifeDebugSpawnerWindow.open(...)` panelini açar.
- Panel `sendClientCommand(player, "ProjectALife", "debugSpawnCatalog", { encounterId, count, x, y, z, ... })` gönderir
  (`server/.../Admin/ALifeDebugService.lua`). Bu komut `Service.diagnosticCommands` listesinde; A-Life yalnızca
  `alifeDiagnostics { enabled = true }` sonrası kabul eder. SP'de yetki her zaman var, MP'de admin gerekir.
- Encounter kimlikleri `shared/.../World/ALifeEncounters.lua`: `patrol` (2–4), `raid` (Hostile Scouts),
  `scavenger_crew`, `town_patrol`, `blockade` ... `fullscale_raid` tam ölçekli baskın başlatır, testte kullanma.
  Spawn edilenler `Service.hostileProfileIds` ile seçilir, yani oyuncuya düşman olabilirler.
- `factionId` verilirse o fraksiyondan seçer (`Service.hostileProfileIds(count, seed, factionId, true)`).
  Oyuncuya bakış `common/alife_runtime/catalog/faction_registry.alife` içindeki `stance.player`: ör. dost/barışçıl
  `alife_church_volunteers`, `alife_county_ems`, `alife_lone_nurse`; düşman `alife_hobbs`, `alife_pit`.
- Bizim kısayol: `ALifeBrain.spawnTestNpc(factionId, count, encounterId, temporary)` → `Hooks.spawnTestNpc`
  (varsayılan `alife_church_volunteers`, 1 NPC, `patrol`, kalıcı: komuta `persistent = true` gider).
- **Kalıcılık (2026-10-11 doğrulandı):** `debugSpawnCatalog` `args.persistent` almazsa encounter tanımının
  `persistent`'ini kullanır (`patrol` için yok) → kayıtta `memory.persistent`/`encounter` boş, `memory.debugSpawn`
  dolu. `Population.expendable` bunları harcanabilir sayar: oyuncu 60 kareden (`spawnDistance`) uzaktayken uyuyan
  (`dormant`) NPC, sandbox `Population_DormantTtlHours` ("Unvisited NPC lifetime", varsayılan 8 oyun saati) dolunca
  `Registry.remove(..., "dormant_ttl")` ile silinir. `persistent = true` → `encounterPersistent` + `anchor`, silinmez.
  **Kayıt:** `Persistence.forSave` kayda yalnızca izinli grupların kayıtlarını yazar: `SquadLedger.liveIds()` (offline
  squad'lar), yerleşik karakol sakinleri ve `actorGroup` dönen diğer gruplar (`outpostId`, `squadId`, `persistent` ya da
  `admin.persistent`; anahtar `groupId or encounter or uid`) `Persistence.squadCap`'e (sandbox
  `Population_PersistentSquadCap`, "Saved group limit", varsayılan 20, en çok 500, canlı değişir) kadar. `sessionOnly` /
  `outpostSquadId` hiç yazılmaz. Kalıcı olmayan NPC tek oturumluktur (`sessionActors`). **Uygulandı:** `Keeper.lua` +
  `Hooks.keepGroupOf` (grubun bütün yaşayan üyelerine `Talk.writeMemory` ile `persistent = true`,
  `alifeBrainKeptAtMs`), `Hooks.savedGroups`, `Hooks.releaseKept`. `Persistence.actorGroupCount` hiçbir yerde
  kullanılmıyor; nüfus kapasitesi (`Population.capacityUsed`) yalnızca oyuncunun 60 karesindeki uyuyanları sayar.
  A-Life her silmeyi `Telemetry.emit("actor_removed", {uid, reason})` ile yalnızca bellekteki halkaya (96 olay) ve
  `Telemetry.counters`'a yazar, konsola basmaz: `ALifeBrain.npcs()` bunları gösterir (`Hooks.actorSnapshot`,
  `Hooks.lifecycleEvents`).
- Gözlem (A-Life'a bildirilebilir): `hostileProfileIds` içindeki `seed % 2147483647` milisaniye zaman damgasıyla
  çağrılıyor; Kahlua'nın `%` hatası yüzünden (bkz. CLAUDE.md) sonuç beklenenden farklı olabilir. Zararı muhtemelen
  yalnızca profil seçiminin rastgeleliği.

## 10. Kırılganlık listesi (A-Life güncellenince kontrol et)

Kancalarımızın dayandığı her şey `mod/.../ALifeBrainHooks.lua` içinde toplanacak:

1. `ProjectALife.ModuleRegistry.register / evaluate` imzası ve `context` alanları.
2. `ProjectALife.BehaviorProfiles.definitions[*].overlays` tablosu (modülümüze izin için).
3. `ProjectALife.Talk.respond(player, listener, text, now, choiceIntent)` imzası; `listener = {record, shell, distance, inCone}`.
4. `ProjectALife.Talk.hold`, `Talk.stance`, `Talk.observations`, `Talk.tolerate`, `Talk.writeMemory`.
5. `ProjectALife.Speech.say / contextFor / playerKey / variable / clock`.
6. `ProjectALife.DecisionLoop.states`, `setOrder`, `refreshDirective`.
7. modData alan adları (`ProjectALifeOwned`, `ProjectALifeUID`, `ProjectALifeGeneration`, `ProjectALifeBehaviorState` ...).

## 11. A-Life ekibine sorulacaklar (Discord)

1. Dış modların karar modülü kaydetmesi destekleniyor mu? `BehaviorProfiles` için dış modül whitelist'i
   (ör. `BehaviorProfiles.allowExternal(id)`) eklenebilir mi?
2. `Talk.respond` için resmi bir "dialogue provider" kancası (async cevap, bekleme ve zaman aşımı) düşünülür mü?
3. Davranış klonlama için karar olaylarına abone olunabilecek bir yol (`decision_trace` dışında, ör. `Telemetry.adapters.log` zinciri) önerir misiniz?
4. MP'de karar döngüsünün hangi tarafta koştuğu (`Executor.clientAuthority`) ve istemciye aynalanan aktör alanları.
5. `memory` içine üçüncü parti alan yazmak (ör. `memory.alifeBrain = {...}`) kayıt göçünü (`RecordMigration`) bozar mı?
