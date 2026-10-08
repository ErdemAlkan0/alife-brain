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
`ALifeBrain.spawnTestNpc()` (6 kare doğuna 1 A-Life NPC'si; A-Life diagnostics'ini açar).
