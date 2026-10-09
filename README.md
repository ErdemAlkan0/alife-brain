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
    42/media/lua/shared/ALifeBrain/   Json, Bridge, ALifeBrainHooks (A-Life'a dokunan her şey), Tests/
    42/media/lua/client/ALifeBrain/   ALifeBrainMain (başlatma, ping), EventLog
sidecar/                  Python sidecar (yalnızca standart kütüphane)
tests/lua/run_tests.lua   Lua testlerini standart Lua 5.1 / LuaJIT ile koşar
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
`ALifeBrain.spawnTestNpc("alife_hobbs", 3)` (başka fraksiyon / sayı).

## LLM diyalog (2. aşama)

Ayarlar: `%LOCALAPPDATA%\ALifeBrain\config.json` (ilk çalıştırmada varsayılanlarla oluşur).

- `provider`: `player2` (varsayılan), `ollama`, `openai` veya `fake` (LLM yok, test cevabı).
- Player2: uygulamayı kur, giriş yap; https://player2.game/profile/developer sayfasından Client ID al ve
  `player2.client_id` alanına yaz (veya `ALIFEBRAIN_PLAYER2_CLIENT_ID` ortam değişkeni).
- OpenAI uyumlu servis: anahtar yalnızca `openai.api_key_env` alanında adı geçen ortam değişkeninden okunur;
  dosyaya anahtar yazılmaz.
- Hafıza: `%LOCALAPPDATA%\ALifeBrain\memory.sqlite3` (NPC'ler, anılar, konuşmalar, güven/korku).

Oyunda: sidecar'ı başlat (LLM'siz denemek için `run-sidecar-fake.cmd`), dost bir NPC çağır ve yanında `T`'ye
bas (ya da yere sağ tık → en üstte **A-Life Brain: <ad> ile konuş**). Sohbet penceresi açılır: A-Life'ın
konuşma penceresine benzer (portre, ad, fraksiyon, tutum, güven/korku); önceki konuşmalar üstte, yenileri
altta. Yaz ve Enter'a bas; NPC durur, "..." gösterir ve cevap verir. Yakında konuşulabilir NPC yoksa ya da
sidecar kapalıysa `T` A-Life'ın kendi kutusunu açar.

NPC'nin söyledikleri gerçek eylemlere bağlıdır: su / yiyecek / ilaç verebilir (gerçekten envanterinde varsa),
seni 10 dakika takip edebilir, bekleyebilir ya da konuşmayı bitirebilir; pencerede ne olduğu gri satırla yazar.
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
