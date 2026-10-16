# A-Life Brain

A Project Zomboid (B42) add-on that gives Project A-Life's NPCs LLM dialogue + memory and an RL decision layer.
Design: [CLAUDE.md](CLAUDE.md) · A-Life hook notes: [docs/alife-hooks.md](docs/alife-hooks.md) ·
Bridge protocol: [docs/bridge-protocol.md](docs/bridge-protocol.md)

## Folders

```
mod/                      Zomboid/Workshop/ALifeBrain layout (workshop.txt + Contents/mods/ALifeBrain)
  Contents/mods/ALifeBrain/
    common/               the version-independent folder B42 expects
    42/mod.info           require=\ProjectALifeNPCs
    42/media/lua/shared/ALifeBrain/   Json, Bridge, ALifeBrainHooks (everything that touches A-Life), Dialogue, Trade,
                                      Text, Features + Policy + DecisionLog (phase 3), PolicyWeights (generated),
                                      Moods + Control (phase 5), Keeper, Pause, Rapport, Robberies, Companion,
                                      Standoff, Parley, Tests/
    42/media/lua/client/ALifeBrain/   ALifeBrainMain (startup, ping), EventLog, ChatWindow
sidecar/                  Python sidecar (standard library only)
rl/                       Policy training (rl/.venv): behaviour cloning (numpy), PPO (torch, SB3), export to Lua
release/                  make_release.py (the player zip), INSTALL.txt, release notes
tests/lua/run_tests.lua   runs the Lua tests with standard Lua 5.1 / LuaJIT
tests/lua/run_tests.py    the same from Python, without the game (lupa: rl\.venv\Scripts\python -m pip install lupa;
                          rl\.venv\Scripts\python tests\lua\run_tests.py). Kahlua is not exactly the same; the tests
                          that run in game with -debug have the last word
```

## Safety rules

- The mods in `Zomboid/mods` and the saves in `Zomboid/Saves` are never touched.
- The mod is shown to the game only through the `Zomboid/Workshop/ALifeBrain` link (junction).
- The mod and the sidecar create only `alifebrain_*` files in `Zomboid/Lua`.
- Trials happen in a **new test save**; the mod is not added to existing saves.

## Sidecar

Double-click `sidecar\run-sidecar.cmd`, or:

```bash
cd sidecar
python -m alifebrain_sidecar --verbose
```

Smoke test without the game (with a temporary folder, `Zomboid\Lua` is not touched): start the sidecar with
`--lua-dir <temp folder>` and run `python tools/fake_game.py --lua-dir <temp folder>`; it should end with `SMOKE OK`.

Defaults: Lua folder `%USERPROFILE%\Zomboid\Lua`, data folder `%LOCALAPPDATA%\ALifeBrain` (`events.jsonl`,
`sidecar.lock`). Tests:

```bash
cd sidecar
python -m unittest discover -v tests
```

## Single-file sidecar (no Python)

```bash
sidecar\build-exe.cmd
```

The first run creates `sidecar\.venv-build` and installs PyInstaller; the result is `sidecar\dist\ALifeBrainSidecar.exe`
(about 9 MB). The exe can be copied anywhere and needs no Python; a double click is the same as `run-sidecar.cmd`, and
it takes the same arguments (`ALifeBrainSidecar.exe --provider fake`, `--verbose`). Settings and memory are still under
`%LOCALAPPDATA%\ALifeBrain\`. The exe is not signed, so Windows SmartScreen or an antivirus may warn the first time.
The script only builds, it does not start the sidecar; at the end it shows the result and waits for a key (call
`build-exe.cmd nopause` from scripts).

## Release zip

```bash
python release/make_release.py
```

Builds `dist\ALifeBrain-<version>.zip` (the version comes from `mod.info`): the mod folder (files git tracks), the exe
and `release\INSTALL.txt`. It refuses an exe older than the sidecar's sources (run `build-exe.cmd` first), warns about
uncommitted changes, and refuses any file that holds this machine's Player2 client id.

## Trying it in game (phase 1: ping/pong)

1. Link the mod into the Workshop folder (once; `Zomboid/mods` is not touched):
   `New-Item -ItemType Junction -Path "$env:USERPROFILE\Zomboid\Workshop\ALifeBrain" -Target "<repo>\mod"`
2. Start the sidecar.
3. Start the game with `-debug` (Steam -> Properties -> Launch options), create a **new** game, and enable
   Project A-Life and A-Life Brain in the mod list.
4. Expected in `Zomboid/console.txt`:
   - `[ALifeBrain] [test] N passed, 0 failed (Kahlua wide chars)`
   - `[ALifeBrain] A-Life 1.3.15 ...: touchpoints ok=19 missing=0`
   - `[ALifeBrain] sidecar online ...`, `sidecar ready ...`, `pong #1 rtt=...ms`
5. Hit an A-Life NPC -> `event npc_hit ...` in the sidecar log and a record in `events.jsonl`.
6. Close the sidecar -> `sidecar offline` within a few seconds; the game goes on as normal.

In the debug console: `ALifeBrain.status()`, `ALifeBrain.ping()`, `ALifeBrain.runTests()`,
`ALifeBrain.spawnTestNpc()` (one friendly NPC 6 tiles east, Church Volunteers; turns on A-Life's diagnostics),
`ALifeBrain.spawnTestNpc("alife_hobbs", 3)` (another faction / count), `ALifeBrain.npcs()` (A-Life's NPC registry:
state from nearest to farthest, kept or not, distance; deletions since this load and why), `ALifeBrain.trust()` (trust,
fear and stance toward you of the NPCs whose mood we know).

**The NPCs you meet stay** (on by default; Mod Options -> A-Life Brain -> "Keep NPCs you meet"): every A-Life NPC that
comes within 10 tiles of you is kept together with its crew; A-Life writes it into the save and does not delete it,
even after you walk away. On its own A-Life saves only persistent groups (outposts, persistent encounters, its own
offline squads); the rest live for one session. A-Life saves at most its sandbox option "Saved group limit" (default 20)
of such groups; if the kept groups go past it, a warning shows in game: raise the option (up to 500). To undo it, turn
the box off first, then run `ALifeBrain.releaseKept()` in the console.

`spawnTestNpc` spawns kept NPCs. A-Life's debug spawner makes **expendable** NPCs by default: while the player is far
away they "sleep" (dormant), and when nobody comes near before A-Life's sandbox option "Unvisited NPC lifetime"
(default 8 game hours) runs out, they are deleted. For the old behaviour pass `true` as the 4th argument
(`spawnTestNpc(nil, 1, nil, true)`).

## LLM dialogue (phase 2)

Settings: `%LOCALAPPDATA%\ALifeBrain\config.json` (created with the defaults on the first run).

- `provider`: `player2` (default), `ollama`, `openai` or `fake` (no LLM, a test answer).
- Player2: install the app and sign in; get a Client ID at https://player2.game/profile/developer and write it into
  `player2.client_id` (or the `ALIFEBRAIN_PLAYER2_CLIENT_ID` environment variable).
- An OpenAI-compatible service: the key is read only from the environment variable named in `openai.api_key_env`; no
  key is written into the file.
- Memory: `%LOCALAPPDATA%\ALifeBrain\memory.sqlite3` (NPCs, memories, conversations, trust / fear, drive). Old memories
  are summarized: once an NPC (or its crew, or its faction) has more than 14 memories, all but the newest 6 are
  rewritten by the LLM into a short summary (while the sidecar is idle, at most once a minute; every summary is one LLM
  call). The originals are not deleted. To turn it off, in `config.json`: `"memory": {"summarize": false}`.

The game pauses while the conversation window is open (single player; Mod Options -> A-Life Brain -> "Pause the game
while talking") and goes on at its old speed when the window closes. The inventory key does not work while the game is
paused: open the inventory first if you want to trade. A multiplayer game cannot be paused, so multiplayer support is
postponed for now.

In game: start the sidecar (`run-sidecar-fake.cmd` to try it without an LLM), spawn a friendly NPC and press `T` next
to it (or right-click the ground -> at the top, **A-Life Brain: talk to <name>**). The conversation window opens: it
looks like A-Life's talk window (portrait, name, faction, stance, trust / fear); earlier conversations at the top, new
ones below. Type and press Enter; the NPC stops, shows "..." and answers. When no talkable NPC is near, or the sidecar
is off, `T` opens A-Life's own box.

The window is in English. The NPCs answer in the language you write in: Turkish and English both work (and other
languages the LLM speaks). An NPC that speaks first (a parley) uses the game's language.

What an NPC says is tied to real actions: it can hand over water / food / medicine (only if it really has some), follow
you for 10 minutes, wait, or end the conversation; the window writes what happened in a grey line. A follower stays by
your side: it does not chase zombies more than 8 tiles from you, falls back when a crowd comes (3 zombies in melee,
6 with a gun) or when badly hurt, and fights the odd zombie near you with A-Life's own combat. `companion` in
`ALifeBrain.status()` in the debug console shows how often it came back / fell back. When you move crouched, the
follower crouches too, slows down and does not run; it does not attack zombies that are not within 3 tiles of it or of
you.

**Warnings between NPCs:** two NPCs hostile to each other do not open fire on sight: first "keep away", a last warning
if the other comes closer or stays long, then a fight (with A-Life's faction lines). A follower that is warned falls
back to you.

**Parley (hostile NPCs):** while the sidecar runs, a hostile NPC that sees you stops instead of shooting, calls out, and
the conversation window opens by itself; the NPC speaks first (asks for a toll or threatens). While you talk, its crew
holds fire. Pay the toll through the trade table (walk up to it and press "Accept") or be sent away, and you are left
alone for a while. Close the window, hit one of the crew, stay silent for 45 seconds, or have the NPC give up, and the
fight starts; get far away and the parley is over. Crews you attacked directly, whose warnings you ignored, that you
hit in the last two minutes, or that rob you through A-Life's own robbery system act like A-Life. A crew that is hostile
because you fought another group of its faction talks first; it is angry and may decide to attack at once. An NPC that
notices you but cannot see you waits a few seconds to see you. `ALifeBrain.status()` has `parley` and `standoff`
counters. Keywords of the fake provider: "su" / "water", "yemek" / "food", "takip" / "follow", "bekle" / "wait",
"hoşça kal" / "bye".

**Trading:** drag items from your inventory (vanilla or Inventory Tetris) to the trade section on the right of the
window; click the NPC's items you want (right-click for fewer). "Offer" puts the trade to the NPC together with your
message; the NPC accepts (the exchange happens at once), refuses, or makes a counter-offer with its own items and says
what it wants in return (the items it wants are put on the table for you; "Accept" takes the deal). There is no credit:
the NPC's items change hands only together with your part, at the same moment; even if the NPC answers a bargain like
"give me the water and I'll give you a bandage later" with "give", nothing is handed over directly, it goes on the
trade table. Items stay in your inventory until the trade happens (move one elsewhere and it leaves the table); worn,
held, attached and favourite items and bags with something inside cannot be offered. The window opens beside open
inventory windows; the text box takes the keyboard only when you click the window, and the keys go back to the game
when you click the inventory or the world. The fake provider accepts when something is on the table, and offers its
own first item when you say "teklif" / "offer".

Without the sidecar, when the LLM fails, or when the NPC is fighting or hostile, A-Life's own lines are used.
Single player only for now.

## Behaviour cloning (phase 3)

Goal: first a policy that imitates A-Life's own decisions (to be improved with PPO later).

1. **Collecting data:** play with the sidecar running. The mod watches every A-Life decision (without changing it):
   which module it chose (`regroup`, `orders`, `flee` ... or `default`) and what the NPC saw (43 features: health,
   ammunition, threat, nearby zombies / squad, the player and the stance, time of day, orders, LLM trust / fear ...).
   The records go to `%LOCALAPPDATA%\ALifeBrain\dataset\decisions-<date>.jsonl`. The more varied the situations, the
   better: friendly and hostile NPCs, night / day, zombie crowds, follow orders, fights.
   In the debug console: `ALifeBrain.status()` (`decisions.sent`) and `ALifeBrain.policy()` (the most frequent
   choices).
2. **Training** (once: `py -3.12 -m venv rl\.venv` and `rl\.venv\Scripts\python -m pip install -r rl\requirements.txt`):

   ```bash
   rl\run-bc.cmd
   ```

   Each chain (`decision`, `response`) needs at least 300 decisions. The validation set is made of NPCs never seen in
   training; the output prints the accuracy next to the "always pick the most frequent choice" baseline. The result is
   written to `mod/.../ALifeBrain/PolicyWeights.lua` (`--dry-run` only reports). Decisions from a period when a module
   misbehaved are left out with `--exclude <action>` (e.g. `--exclude alifeBrainStandoff` for the freeze on
   2026-10-10).
3. **Shadow mode:** restart the game. The policy makes its own choice at every sampled decision but **does not apply
   it**; `ALifeBrain.policy()` shows how often it agrees with A-Life. Taking over control is phases 4 / 5.

## PPO (phase 4)

`rl/alifebrain_rl/sim.py`: a Gymnasium environment like A-Life's off-screen squad simulation. An NPC and its squad go
through calm moments (the `decision` chain: patrol, gather, recover, rest, orders, warn, rob) and threats (the
`response` chain: fight, flee, panic, call for support, fall back to the player, warn the NPC, parley); fights are
settled with A-Life's offline power model. The observation is the same as the game's `Features.lua` vector
(`features.py`), the actions are A-Life module ids: the trained net runs in game unchanged. Trust / fear / goal are drawn
at random in every episode and change what pays off (follow a trusted player, do not rob them; fear says how dangerous
the player is: a feared player fights harder, an armed player nearby is warned off; goal -1 careful: every new threat
costs extra by the survival weight <-> +1 loot and fights) -> one policy steered by dialogue. The player stays around
their spot (when warned they mostly move away), so close encounters go on.

Setup (once): `rl\.venv\Scripts\python -m pip install -r rl\requirements-ppo.txt --extra-index-url
https://download.pytorch.org/whl/cpu` (CPU torch, Stable-Baselines3, Gymnasium).

```bash
rl\run-ppo.cmd
```

The default 3 million steps take ~20 minutes on a CPU (change with `--timesteps`; at 1 million some seeds collapsed
into "gather everywhere"). Output: returns / deaths / squad losses of PPO against two baselines (an A-Life-like rule,
random), how the first choice changes as trust, fear and goal change, and habits over whole episodes (e.g. how often it
gathers alone with goal > +0.5 and < -0.5; the A-Life-like rule in square brackets). The weights are written to
`rl\out\PolicyWeights.ppo.lua`; `--install` also writes them to the mod's `PolicyWeights.lua` (shadow mode in game).
Every number in the simulation is a design choice (`SETTINGS`), not a measurement.

Tests: `rl\.venv\Scripts\python -m unittest discover rl\tests` (from the rl folder: `.venv\Scripts\python -m unittest
discover tests`).

## Conversation -> behaviour (phase 5)

The policy's inputs come from conversations (`Dialogue.minds`):
- **Trust / fear** are toward the player (the LLM moves them by up to ±10 per reply).
- **Drive** (`goal`) belongs to the NPC itself: -100 lie low, stay safe <-> +100 go out for loot, take risks.
  - The LLM moves it by up to ±25 per reply with `goal_delta`. For example "there are a lot of them to the east, be
    careful" lowers the drive; "there is medicine in the pharmacy" raises it.
  - The value settles to 0 with a 30-minute half-life, so one conversation does not change the NPC for good.
  - It shows as "Drive" in the header of the chat window.

The stored mood of NPCs not talked to in this session is asked from the sidecar the first time the policy meets them
(`moods` request).

**Policy control** is off by default. To turn it on: Options -> Mods -> A-Life Brain -> **Trained policy chooses NPC
behaviour**. The game keeps the value in its own `ModOptions.ini`. In the debug console `ALifeBrain.control(true)` turns
it on for this session, `false` turns it off, `"option"` goes back to the menu setting.

While control is on:
- Before A-Life's chain runs, the policy picks one of A-Life's own modules and that module runs alone. When the module
  has nothing to do, or the choice is A-Life's own flow (`default`), A-Life decides as before.
- The policy only adds a choice, it never blocks one of A-Life's:
  - **Always left to A-Life:**
    - The player's orders (follow / wait).
    - A conversation (window open or a reply on the way).
    - A robbery in progress.
    - A parley or an NPC<->NPC warning ladder the NPC is part of.
    - The player as a threat.
    - An NPC hostile to the player while the player is within 55 tiles (A-Life's robbery module notices the player at
      that range).
  - **Never chosen by the policy:** `talk`, `robbery`, `orders`, the follower and parley modules.
  - **While the player is within 20 tiles** the policy may only add a warning (`careful`). That way A-Life's greeting
    (6 tiles) and warning (14 tiles) keep their order.
- The policy is asked at most once every 2.5 seconds per NPC and chain.

`ALifeBrain.control()` (or `ALifeBrain.policy()`) shows:
- what the policy ran and how often;
- the choices that had nothing to do;
- how often a decision was left to A-Life, and why.

Shadow-mode statistics count only the decisions A-Life chose itself. Decisions the policy ran are written to the
dataset with a mark (`chosen`) but stay out of training. While control is on, the counters are also written to
`sidecar.log` every 5 minutes ("policy control: ..."), so they can be read after playing without the console.

**Trust changes the stance:** when an NPC of a careful faction (A-Life: it warns anyone coming close with "keep back",
"last warning" and opens fire on whoever ignores the warnings) trusts you at least 5, its whole group lets you come
close: A-Life's own `Talk.tolerate` lever, careful -> neutral; the warnings stop, the window header says "Trusts you",
and the LLM is told. It is taken back when trust drops below 3. Hostile groups stay hostile; hit one and the group turns
on you again. It works without talking too: a gift, a fair trade or killing zombies next to them raises trust in the
sidecar, and the game learns it at once.

Following: when the LLM agrees to follow, the NPC follows unless it distrusts the player (trust < 0) or is hostile.
Memory: faction memories are per save; someone you killed in an old save does not get into the memory of the NPCs in
a new world.
