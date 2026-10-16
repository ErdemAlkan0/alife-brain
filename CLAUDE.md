# A-Life Brain: an RL + LLM add-on for Project Zomboid NPCs

This file sums up the design conversation held on claude.ai (October 2026).
Talk to the user in Turkish. Code, variable and file names are in English, and so are all documents in the repository
(user request, 2026-10-16).

## Goal

Give the NPCs of the **Project A-Life** mod for Project Zomboid (Build 42.20+):
- decisions made with **RL (reinforcement learning)**: which behaviour the NPC picks
- dialogue and long-term memory with an **LLM**
- dialogue that steers behaviour: LLM output (trust / fear / goal) -> input of the RL policy

## Architecture (3 layers)

1. **A-Life**: walking, combat, squad tactics, off-screen simulation. We do not touch it.
2. **RL policy**: the decision layer only. It decides which of A-Life's existing behaviours is chosen.
3. **LLM**: dialogue + memory. Its `trust` / `fear` / `goal` values are inputs of the RL policy.

Data flow:
PZ Lua add-on <-> (JSON lines, file bridge) <-> Python sidecar <-> LLM provider (Player2 / Ollama / the user's API key)

## Hard rules

- **Never edit, copy or reload A-Life's files.** Write a separate add-on: `require=\ProjectALifeNPCs` in `mod.info`.
- A-Life NPCs are built on zombie bodies. Recognise them by `zombie:getModData().ProjectALifeOwned == true`.
- A-Life is updated often (v1.3.x, September 2026). Monkey-patching its internals is fragile. Lasting hooks are to be
  discussed with the team on Discord (discord.gg/alife); keep every hook point in one file so an update is easy to
  repair.
- PZ's Lua (Kahlua) is sandboxed: no `io`, sockets or HTTP. The outside world is reached **only through the file
  bridge**.
- The LLM never controls the game directly: its output is a fixed JSON schema, the sidecar validates and limits it,
  and Lua applies only whitelisted `intent` values.
- If the sidecar is down or the LLM times out, the mod keeps working like plain A-Life (fall back to canned lines).
- Multiplayer: Player2 sign-in is per player, so LLM calls are made on the client; the server always clamps
  `trust_delta` / `fear_delta` again (a client can fake them).
- **Never embed your own API key** in the mod or the sidecar.

## Components

### 1) Lua add-on (`mod/`)
- Event logging: hit, robbed, fed, a squad member died, and so on. These become both memories and the RL dataset.
  Robberies (implemented, `Robberies.lua`): A-Life's `ModuleRobbery.active` table is read once a second (no patch);
  every robbery that ends is sent as a `robbed_player` event (crew, `finishedReason`: `released` / `execute:<reason>` /
  came to nothing, names of the items taken); every member of the crew remembers it; a player who gives in gets
  trust +1 fear -2, one who resists -3 / +3.
- Writing requests: `getFileWriter("alifebrain_req.txt", true, true)` (writes into the user's `Zomboid/Lua` folder).
  Use a flat file name, not a subfolder.
- Reading replies: poll `alifebrain_res.txt` at short intervals (thinning out OnTick).
- The content is JSON lines but the extension must be `.txt`: B42 `getFileWriter` writes only `txt, ini, cfg, json,
  lua, log` and **silently** refuses anything else (such as `.jsonl`) (`LuaManager.ALLOWED_FILE_EXTENSIONS`, verified
  on 42.21). `getFileReader` is not restricted.
- Every message has an `id`. So that half lines are never read, the sidecar writes to a `.tmp` file first and then
  renames it. Clean the files up periodically.
- Conversation UI: a chat window (`ChatWindow.lua`, modelled on A-Life's `ALifeTalkMenu.lua` window; free text; the
  history is loaded from the sidecar with `history` and shown at the top) + an NPC speech bubble ("..." while it
  waits). The `T` key (`TalkInput.open` is wrapped) opens the window when a talkable NPC is near and the sidecar is
  ready, A-Life's box otherwise; it is also at the top of the right-click menu. On A-Life's box path the outcome of an
  action is shown above the player (halo). User feedback: players must see that an item was handed over; the LLM must
  use real item names (`inventoryItems`). While the window is open the NPC is held with A-Life's `talkHold`; when it
  closes, `ModuleTalkPresence` greetings are muted for 3 minutes. The game is paused while the window is open
  (`Pause.lua`, Mod Options "Pause the game while talking", on by default; the game's own pause:
  `SpeedControls:SetCurrentGameSpeed(0)`, the old speed when it closes, or the speed the player chose in between).
  When paused, `OnTick` stops: the bridge and the dialogue keep running on `OnTickEvenPaused` (`Main.onTickEvenPaused`),
  world work (A-Life decisions, Parley, Keeper) waits with the game. While paused the vanilla inventory key does not
  work (`getGameSpeed() > 0`). A multiplayer game cannot be paused: by the user's decision (2026-10-11) multiplayer
  support is postponed.
- The UI is English only (`Text.lua`; it had a Turkish translation until 2026-10-16). `Text.language()` still sends the
  game's language code to the LLM (`world.language`): an NPC that speaks first answers in it; otherwise NPCs answer in
  the language the player writes in, Turkish and English alike.
- RL inference: small MLP weights in a Lua table, forward pass inside the game (it never waits for the bridge). Runs
  every few seconds per NPC.
- Our own A-Life response modules (`Hooks.MODULES`, added to the profiles' `overlays` at run time):
  `alifeBrainParley` (29, `Parley.lua`: a hostile NPC talks before it shoots; the crew gets A-Life's
  `memory.robberyTruce` truce; window closed / attack / `intent attack` / 45 s of silence -> fight, toll or `leave` ->
  truce. It shoots without a word when its own group holds a grudge (`hostileToPlayerKeys`), when the player hit the
  group in the last 2 minutes, while it is fighting, during an A-Life robbery, or when the player is in a vehicle.
  A-Life's reputation makes a whole faction hostile for good after one attack; such a crew, hostile only through its
  faction, parleys (`feud`; play test 2026-10-12: 17 of 26 crews opened fire without a word). An NPC that cannot see
  the player waits 8 s for sight), `alifeBrainStandoff` (31, `Standoff.lua`: NPC<->NPC warning ladder, A-Life's
  `CAREFUL_*` voices), `alifeBrainCompanion` (32). A follower crouches with the player through a `Stealth.stanceActive`
  wrapper and does not run.
- Behaviour cloning (phase 3, implemented): `Hooks.installDecisionTap` only watches A-Life's module chains;
  `DecisionLog.lua` samples decisions (per NPC + chain when the choice changes or every 3 s, at most 20 per second) and
  sends them as `decision_samples` events; the sidecar writes them under `%LOCALAPPDATA%\ALifeBrain\dataset\`. Action =
  an A-Life module id or `default`; observation = `Features.lua` (schema 1, 43 features; the same code produces data
  and inference input; bump `SCHEMA` when features change). Training with `rl\run-bc.cmd` (numpy, `rl/.venv`), output
  `PolicyWeights.lua` (placeholder `return nil`; the exporter adds a check input and its logits, verified by
  `Policy.check` when the game loads). In shadow mode it makes no decisions and counts how often it agrees with A-Life
  (`ALifeBrain.policy()`); control comes in phase 5 (below).
- Policy control (phase 5, implemented; off by default: Mod Options tick box through `PZAPI.ModOptions`, or
  `ALifeBrain.control(true)`): `Hooks.wrapEvaluate` asks `Control.pick` **before** the full chain, the chosen module
  runs alone with `only`, and when it returns `nil` A-Life's chain runs (modules start movement and voices inside
  `evaluate`, so the chain cannot run first and be overridden later). The policy only adds choices: it never picks
  `default`, `talk`, `robbery`, `orders`, the follower or the parley modules; player orders, conversations, robberies,
  parleys / NPC ladders, the player as a threat and an NPC hostile to a player within 55 tiles (A-Life
  `ModuleRobbery.detectRadius`) stay with A-Life; with a player within 20 tiles it may only add `careful` (A-Life's
  warning radius is 14, greeting 6). Cached for 2.5 s per NPC + chain. The decisions it chose go into the dataset
  marked `c` (sidecar `chosen`) and BC skips them; rows logged while control is on are marked `ctl`; counters go to
  `sidecar.log` every 5 minutes as a `policy_stats` event. Stored moods of NPCs not talked to come into
  `Dialogue.minds` through `Moods.lua` (`moods` request).
- Use a pure-Lua JSON library that works in Kahlua, and test it in Kahlua. Without the game:
  `rl\.venv\Scripts\python tests\lua\run_tests.py` (lupa, standard Lua 5.1; it differs from Kahlua, the in-game
  `-debug` tests have the last word).
- Kahlua pitfalls (verified in game):
  - `a % b` and `a / b` give wrong results past 2^31 (there is a 32-bit int conversion inside; the division itself is
    right). Never use `%` on millisecond timestamps; turn numbers into text with `Json.intToString`.
  - In debug mode (`-debug`) errors caught by `pcall` are printed to the console as stack traces too; that is not an
    error.
  - `string.byte` returns UTF-16 units (may be > 255); `string.char(300)` works.
  - There is no `next` ("Object tried to call nil"); count with `pairs` to see whether a table is empty.
- NPC persistence ("NPCs seem deleted after reloading", 2026-10-11): A-Life writes only persistent groups into the save
  (`Persistence.forSave`: its own offline squad ledger, outposts and `memory.persistent` / encounter groups, sandbox
  "Saved group limit" = `Persistence.squadCap`, default 20); every other NPC lives for one session and is also deleted
  while asleep once "Unvisited NPC lifetime" (8 game hours) runs out. `Keeper.lua` (on by default, Mod Options "Keep NPCs
  you meet"): writes `persistent = true` + `alifeBrainKeptAtMs` with `Talk.writeMemory` to the whole group of any NPC
  that comes within 10 tiles of the player (`Hooks.keepGroupOf`; offline squads and outpost task squads belong to
  A-Life and are left alone); warns once when the persistent group limit is exceeded; `ALifeBrain.releaseKept()` undoes
  it. `ALifeBrain.spawnTestNpc` sends `persistent = true`; `ALifeBrain.npcs()` shows A-Life's registry, the number of
  groups to be saved and why NPCs were deleted (`Telemetry` ring).
- Mod Options: the tick box showed "off" in game while `ModOptions.ini` said `true` (2026-10-11; at first we thought
  the game's loader kept the `\r` of a CRLF line); `Main.loadOptions` also reads our own line and the startup log
  writes the `saved` / `menu` values. The real cause (2026-10-14, log: "off (Mod Options: saved true, menu true)"): the
  test leftover below (`Control.forced`).
- In-game tests (`ALifeBrain.runTests()` at a `-debug` startup) run on the live module tables. A test that installs
  fakes must put the old values back with `Tests.keeping(target, fields, body)`: `for k, v in pairs(saved)` skips the
  nils, and until 2026-10-14 the `Control.forced/override`, `Moods`, `Robberies` and `Rapport` fakes stayed in the
  game (policy control always off, Rapport never saw a real NPC, robbery memories and stored moods went to a fake
  bridge). `Tests.runAll` compares every module's `override` / `forced` field before and after; when one changed it
  counts a failed test and puts it back.
- PZ UI pitfall (seen in game): in an `ISCollapsableWindow` subclass never use the names `render` / `prerender` for
  anything else; if you override them, call the superclass. `prerender` opens a stencil (clipping) and `render` closes
  it; if it stays open, every window drawn later (such as an inventory brought to the front with a click) is clipped
  to this window's rectangle and disappears.

### 2) Python sidecar (`sidecar/`)
- Watch `alifebrain_req.txt` -> call the LLM -> write `alifebrain_res.txt`. Protocol: `docs/bridge-protocol.md`.
- Provider abstraction (OpenAI compatible): Player2 (default), Ollama, the user's own API key. One setting switches.
- Memory: SQLite, keyed by NPC id; layers: personal / squad / faction. Faction memories are per save: every message
  carries `world` = `<game mode>/<save name>`, the key is `<world>|<faction>` (A-Life reuses role names in every crew;
  deaths from old test saves were blamed on the player in a new world, 2026-10-11). Personal (uid) and squad (groupId)
  keys are already specific to a save. Names repeat within one save as well: a faction memory says "one of our people
  in another group" and is not shown to the dead NPC's own squad. A squad loss is written with the killer's name ("Gus
  - Rifleman killed Deputy Rowe, not the stranger"; `npc_died.by` carries an NPC killer's name / squad); with only "We
  lost X" the LLM blamed the player. Prompt rule: blame the stranger only for what memories or the conversation show.
  Only a few of the newest, important and relevant memories and a summary go into the prompt. Old memories are
  summarized now and then. **Implemented** (`summary.py`, config `memory`): when a layer (NPC, squad, faction) has
  more than 14 unsummarized memories, all but the newest 6 (and the previous summary) are rewritten by the LLM into a
  first-person summary of at most 3 sentences / 400 characters; the originals are not deleted, they get
  `memories.summarized = 1` and leave recall (the column is added to an old database on startup). The sidecar does this
  only while no reply is pending and at most once a minute; a layer that failed waits 10 minutes. The prompt lists the
  latest summary per layer under "From before:", then "What you remember:".
- Distribution: a single .exe (PyInstaller), so players need no Python. **Implemented:** `sidecar\build-exe.cmd` (the
  first run creates `sidecar\.venv-build` + PyInstaller) -> `sidecar\dist\ALifeBrainSidecar.exe` (~9 MB,
  `--onefile --console`, entry `sidecar\packaging\launcher.py`; the same arguments as `run-sidecar.cmd`; after an error
  the window stays open until Enter). Built on 2026-10-11 and tried with the fake provider (ping/pong). Release zip:
  `python release\make_release.py` -> `dist\ALifeBrain-<version>.zip` (mod, exe, `INSTALL.txt`); it refuses an exe older
  than the sidecar's sources and any file holding this machine's Player2 client id.

### 3) LLM output schema

```json
{"say": "...", "memory_note": "...", "trust_delta": 0, "fear_delta": 0, "goal_delta": 0, "intent": "warn"}
```

- `intent` whitelist: none, give, follow, stay, leave, trade, warn, attack, rob, give_info. An `item` field was added to
  the schema (for `give`: water, food, medicine).
- Trading (`Trade.lua` + the right part of the window): the player drags from the inventory (Inventory Tetris
  compatible: `ISMouseDrag.dragging` + Tetris `DragAndDrop.getDraggedStacks/endDrag`; the drop target is UI, so Tetris
  does not drop the item on the ground) and clicks the NPC's items to ask for them; the LLM returns `trade.decision`
  accept/reject/counter, and in a counter-offer says with `npc_wants` what it wants from the player (the player's side
  is filled with it). No credit (user request: the player must not take the NPC's items and run without paying): the
  NPC's items leave only when the player's part is in the same exchange (`unpaid`); the player's items move first, and
  on an error everything is moved back; a `give` that is part of a bargain becomes a trade offer in the sidecar.
  `Hooks.executeTrade` makes the exchange (everything is validated again first; held / worn / attached items, keys,
  favourites and bags with items inside are never traded). The receiver that ends a drag must follow the vanilla
  protocol: first `ISMouseDrag.draggingFocus:onMouseUp(0,0)` (the source list panel resets its own drag state only
  this way; skip it and the inventory stays stuck half-dragged), then Tetris `endDrag`. The window's text box takes
  the keyboard only after a click in the window and lets it go after a click outside (inventory, world), or Tetris
  rotation and inventory keys stop working. The window opens in the free space beside visible inventory windows.
  After a direct `Remove` / `AddItem`, containers are refreshed with `setDrawDirty` + `ISInventoryPage.dirtyUI()`; the
  Tetris grid moves an item that does not fit into another bag or onto the ground by itself. Known limit: if A-Life
  deletes the NPC from memory and creates it again, the items given to it may be lost (the same as A-Life's own
  Supplies behaviour).
- Actions the game carries out (`Dialogue.act`, through A-Life's mechanisms): `give` (from the NPC's inventory to the
  player by A-Life's `TalkSupplies.matches` rules; at most 3 per hour per player-NPC, 20 s apart), `follow` / `stay`
  (`DecisionLoop.setOrder`, 10 minutes; following needs a friendly stance, or trust >= 0 and not hostile; the LLM moves
  trust 1-3 per reply, so at the old threshold of >= 10 NPCs said "let's go" and stayed put; in A-Life the threat
  response comes before orders and a follow has no leash, so a follower attacked every zombie: `Companion.lua` + the
  `alifeBrainCompanion` response module keep the follower beside the player: it does not chase zombies more than
  8 tiles from the player and falls back from crowds (3 zombies within 4 tiles in melee, 6 with a gun) and below 50%
  health), `leave` (closes the window). trade / warn / attack / rob / give_info are only recorded. The outcome goes to
  the sidecar as an `npc_action` event and is written into the NPC's memory as "what really happened". The prompt gives
  the LLM the inventory and the rule "never claim you did something without the action".
- Deltas are clamped in the sidecar (trust / fear ±10, per player). Invalid JSON -> canned line.
- Trust changes the stance (play test 2026-10-11: after a trade, with trust at 5-6 the NPC kept saying "keep away", and
  when the window closed A-Life's careful warning ladder turned the group on the player; A-Life works out the stance
  from the faction alone). `Rapport.lua`: a careful group whose most trusting known member trusts the player >= 5
  tolerates the player (A-Life's `Talk.tolerate` -> `memory.tolerateUntil`, careful -> neutral, the whole group;
  10 minutes, renewed; when trust drops below 3 it withdraws only what it wrote itself). It acts as soon as a reply
  arrives (`Rapport.onReply`); the request carries `vouched: true` and the prompt says "do not tell them to keep
  away"; the window header says "Trusts you". Hostile groups stay hostile. Console: `ALifeBrain.trust()`. Events change
  trust in the sidecar (gift +6, trade +2, help +3, a hit, a robbery), but the game used to learn it only at the next
  reply (Henry: 13 in the sidecar, 7 in the game): now `EventLog.MOOD_EVENTS` / `Dialogue.report` -> `Moods.refresh` ->
  `Dialogue.updateMood`; trust earned by deeds alone, without talking, also lets the player close.
- Earning trust (play test 2026-10-11: trust always 0 / -1, "prove it" loops): the prompt says with numbers how trust
  changes (friendly talk +1/+2, help / sharing / keeping a promise / fighting together +3...+6) and forbids asking for
  the same proof again; the careful stance text no longer says "stay away". Good deeds go into memory and trust:
  killing zombies within 10 tiles of the NPC (`player_helped`), a gift (+6) and a fair trade (+2); a hit taken among
  zombies counts as an accident (-3, `npc_hit.zombiesNear`).
- `goal_delta` (±25): the NPC's drive (the policy's `goal` input, -100 lie low <-> 100 loot / risk), per NPC in the
  SQLite `drives` table, settling to 0 with a 30-minute half-life (sidecar `memory.GOAL_HALF_LIFE_MS` = game
  `Dialogue.GOAL_HALF_LIFE_MS`). Shown as "Drive" in the chat window.

### 4) Player2 integration
- Local app: `http://localhost:4315/v1/chat/completions` (OpenAI format). The player must be signed in to the Player2
  app.
- Client ID: https://player2.game/profile/developer -> request header `player2-game-key: <client_id>`.
- `GET /v1/health` every 60 seconds (recommended for time tracking and revenue sharing).
- Reply times (130 replies, 2026-10-11/12): median 11 s, 95% within 20 s, the slowest 32 s; on a slow evening the first
  reply of a conversation took 37 / 43 s. The sidecar waits 60 s (`dialogue.timeout_s`; the old 30 s cut off 3%; when
  config.json still holds the old default 30, 60 is used: `config.OLD_DEFAULTS`), Lua 75 s
  (`Dialogue.settings.timeoutMs`; if Lua waits less than the sidecar, a late reply is lost although the sidecar has
  written it into the conversation history).
- Catch rate-limit errors. Free and credit models may differ, so JSON validation is a must.
- Player2 sometimes refuses a request with "user input rejected (HTTP 400)" (like a content filter; twice on
  2026-10-11, and the same request was refused again: a parley opening and an ordinary conversation).
  `Player2Provider` retries a quick refusal once as it is; if that is refused too, `Sidecar._ask_llm` asks once more with
  a short prompt ("Role-play for the zombie survival video game Project Zomboid..." up front, no memories / summaries
  and no long trade lists, the last 2 lines of history). The parley rules were softened too ("toll / tough / starts the
  fight" instead of "tribute / menacing / open fire"). The window says why (`fallback_http_400`, `fallback_timeout`,
  `fallback_rate_limited`).
- Without the app: the Web API `https://api.player2.game/v1` (needs authentication).
- Text-to-speech is optional (the sound is not positional).
- Do not use Player2's own memory tools; memory stays in the sidecar.

### 5) RL (`rl/`)
- Actions: A-Life's existing behaviours (patrol, raid, hold an area, warn, rob, regroup...).
- Observation: health / bleeding, ammunition, nearby zombies and enemies, whether the player has a weapon drawn, time of
  day, faction relation + trust / fear / goal from the LLM.
- Training:
  1. Behaviour cloning from game logs (first imitate A-Life's own decisions).
  2. PPO (Stable-Baselines3) in a simple Gymnasium environment like A-Life's off-screen squad simulation. A CPU is
     enough; a GPU is not recommended for MlpPolicy.
- trust / fear / goal inputs are randomized during training -> one policy that dialogue can steer without retraining.
- Reward: survival + mission success, a penalty for squad losses.
- Export: MLP weights -> a Lua table.
- Implemented (phase 4): `rl/alifebrain_rl/sim.py` (`SquadEnv`; observation `features.py` = `Features.lua` schema 1,
  actions are the A-Life module ids of the two chains, an invalid action = the chain's `default` + a small penalty;
  combat uses A-Life's `Offline/ALifeOfflineCombat.lua` power model; trust / fear / goal change the reward: fear = how
  dangerous the player is, it raises their power; every new threat costs extra by the survival weight, so a careful goal
  stays out of trouble; the player stays around their spot), `ppo.py` (SB3 PPO, 64-64 tanh; one body exported as two
  nets; `--install` writes into the mod). `rl/.venv`: numpy + CPU torch + SB3 + Gymnasium. Calibration target: an
  A-Life-like rule (always fight, flee only when badly hurt) dies in ~30% of episodes. Result (3M steps, n_steps 1024,
  batch 512, target_kl 0.02; 2 seeds agree): PPO death rate 8-14% (rule 38%); trust > +0.6 follows 93-95% (< +0.4:
  18-43%); gathering alone with goal > +0.5 90-95%, < -0.5 5-11%; 4+ zombies and health < 0.4 -> flee 99%. Still weak:
  warning a feared armed player (first choice 38-47%, ~2% over the episode; rare in game too: the player is within
  10 tiles in 4% of decisions). `ppo.py` report: probes (first choice) + `HABITS` (over the episode).

## Roadmap

1. Logging + file bridge: end-to-end ping/pong between Lua and Python.
2. LLM dialogue + memory (with Player2). The first visible result.
3. Behaviour cloning.
4. PPO (Gymnasium simulation).
5. Feed the LLM outputs into the policy (implemented: `goal_delta`, `moods`, `Control.lua`; to be tried in game).

## First steps

- Study A-Life's Lua code: decision / state functions, talk / warning functions, NPC identity and modData fields,
  squad structure.
- A-Life's files are in the Steam workshop folder: `steamapps/workshop/content/108600/3803984183`. If it cannot be
  reached, ask the user to start Claude Code with this folder added through `--add-dir`.
- Write the findings into `docs/alife-hooks.md`, then move on to phase 1.

## Environment

- Project Zomboid Build 42.20+ (stable), A-Life v1.3.x (supports B42.21).
- Verified (2026-10-08): Windows 11, PZ 42.21.0, A-Life v1.3.15.
- On this machine A-Life is **not** in the Steam workshop but installed by hand:
  `%USERPROFILE%\Zomboid\mods\ProjectALifeNPCs\42.20\`.
- The Java that ships with the game: `C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\jre64\bin\java.exe`
  (for Kahlua tests).
- A-Life study notes: `docs/alife-hooks.md`.

## References

- A-Life Workshop page: https://steamcommunity.com/sharedfiles/filedetails/?id=3803984183
- PZ modding API notes: https://github.com/FWolfe/Zomboid-Modding-Guide/blob/master/api/README.md
- PZ JavaDocs (LuaFileWriter): https://demiurgequantified.github.io/ProjectZomboidJavaDocs/
- ZombieBuddy (a Java mod alternative; not recommended for distribution): https://github.com/zed-0xff/ZombieBuddy
- Player2: https://player2.game
- Player2 Python client: https://pypi.org/project/player2py/
- Player2 Godot plugin (API usage examples): https://github.com/elefant-ai/player2-ai-npc-godot
- Stable-Baselines3 PPO: https://stable-baselines3.readthedocs.io
