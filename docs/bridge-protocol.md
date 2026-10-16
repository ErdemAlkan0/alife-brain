# File bridge protocol (v1)

Implementation: Lua `mod/Contents/mods/ALifeBrain/42/media/lua/shared/ALifeBrain/Bridge.lua`,
Python `sidecar/alifebrain_sidecar/` (`protocol.py`, `files.py`, `app.py`).

## Files (all in `Zomboid/Lua/`, flat names)

| File | Written by | Read by | How |
|---|---|---|---|
| `alifebrain_req.txt` | Lua (append) | sidecar | The sidecar claims the file by **renaming** it; Lua creates a new one on its next write. Lua never truncates or cleans it. |
| `alifebrain_req.processing` | sidecar | sidecar | The claimed batch; deleted once read. If it is left behind by a crash, it is processed first. |
| `alifebrain_res.txt` | sidecar (atomic replace) | Lua (every ~250 ms) | Written to `alifebrain_res.tmp`, then swapped in with `os.replace`. |
| `alifebrain_res.tmp` | sidecar | — | Temporary. |

The content is JSON lines but the extension is `.txt`: in B42 `getFileWriter` writes only `txt, ini, cfg, json, lua,
log` and refuses others such as `.jsonl` without an error.

On Windows a rename / replace fails while the game holds the file open; the sidecar then tries again on its next step.
That way a half line is never read. The sidecar touches nothing in `Zomboid/Lua` but these four files.

Every line is **ASCII** JSON (non-ASCII characters as `\uXXXX`), so the file encoding does not matter.

## Lua -> sidecar (request line)

```json
{"v":1,"id":"<sess>:<seq>","sess":"<sess>","type":"ping","ts":1759951234567,"world":"Apocalypse/<save name>","data":{...},"ack":{"sid":"a1b2c3d4","rseq":7}}
```

- `sess`: made when the game starts (`<ms>-<random>`). It changes with every new game load.
- `id`: unique within the session; replies refer to it in their `re` field.
- `ts`: Lua's `getTimestampMs()` (wall clock, ms).
- `world` (optional): the save being played, `<game mode>/<save name>` (`Hooks.worldKey`, as in the game's own save
  list). The sidecar keeps faction memories per save (`memory.faction_key`): A-Life reuses role names in every crew
  ("Deputy Rowe"), so a death in an old test save must not leak into a new world. Old faction memories written without
  `world` are no longer read in any save.
- `ack` (optional): the highest `rseq` Lua has processed from that sidecar instance (`sid`). It is added to every
  message; when there is nothing else to send, a separate `ack` message goes at most once a second.
- `type` values (v1): `hello`, `ping`, `event`, `dialogue`, `history`, `moods`, `ack`. No reply line is written for
  `event` and `ack` (one is written for a bad `event`).
- The `hello` reply returns a `features` list (`ping`, `event`, `dataset`, `history` and `moods` when there is memory,
  `dialogue` and `actions` when the provider and memory are ready); Lua uses the dialogue hook only with `dialogue`,
  decision sampling only with `dataset`, and stored-mood requests only with `moods`.

### `dialogue` (phase 2)

Request `data` (Lua `Hooks.dialogueContext` + `Dialogue.handle`):

```json
{"text": "Got any water?", "stance": "neutral",
 "npc": {"uid": "palife:...", "name": "...", "factionId": "...", "factionName": "...", "groupId": "...",
         "roleLabel": "Militia - Rifleman", "temperament": "seasoned", "sex": "m", "behaviorState": "idle", "wounds": 0},
 "player": {"key": "sp:0", "weapon": "hammer"},
 "facts": {"player_armed": true, "recent_zombie_contact": true},
 "world": {"town": "Muldraugh", "hour": 14, "day": 2}}
```

The request also carries `npc.inventory` (`{"water": 1, "food": 0, "medicine": 2}`, counted by A-Life's rules for items
it may hand out) and `npc.following` (whether the NPC is following this player right now). `vouched: true`: the NPC's
group is careful, but it lets the player come close because this NPC trusts them (`Rapport.lua`; `stance` then comes as
`neutral`); the prompt tells it not to say "keep back".

Reply `data`: `{"say": "...", "intent": "none|give|follow|stay|leave|trade|warn|attack|rob|give_info",
"item": "water|food|medicine|null", "trustDelta": 0, "fearDelta": 0, "trust": 0, "fear": 0, "goalDelta": 0,
"goal": 0}`. `item` comes only with `give`. `goal` is the NPC's drive (phase 5, the policy's `goal` input; -100 lie
low, stay safe <-> 100 go out for loot, take risks): it is kept per NPC, not per player, the LLM moves it by up to ±25 per
reply with `goal_delta`, and it settles to 0 with a 30-minute half-life (`memory.GOAL_HALF_LIFE_MS` =
`Dialogue.GOAL_HALF_LIFE_MS`; the value is the one at reply time, the game keeps settling it with its own clock).

`world.language` in the request is the game's language code (`TR`, `EN` ...). The interface is English only, but the
NPC answers in the language the player writes in (Turkish and English alike); an NPC that speaks first uses this code.
In a parley (`Parley.lua`) the request carries `standoff: {"opening": bool, "feud": bool}`: the NPC is hostile and has
stopped the player before shooting. `feud = true`: the crew is hostile only because its faction counts the player as
an enemy for what they did to its other groups (A-Life reputation); the prompt describes an angry crew that still
speaks first. With `opening = true` the NPC speaks first; `text` is then a narration, not the player's words (it is not
written into memory as a player line, and goes into the prompt with the language name). In a parley `intent attack`
starts the fight and `intent leave` lets the player go; a toll is asked through `trade` (`decision: counter`,
`npcWants`, empty `npcOffer`).

#### Trade fields

The request carries `npc.tradeable` (`[{"name": "Canned Beans", "count": 2}]`, the NPC's items that are not held / worn /
attached, not keys and not bags with items inside, at most 30 kinds) and, when something is on the table, `trade`:
`{"playerOffer": [{"name", "count"}], "npcSide": [{"name", "count"}]}` (what the player put down / asked from the NPC).
While the conversation window is open the request also carries `player.tradeable` (the items the player could trade,
same format); the NPC may ask for them.
The reply's `trade`: `null` or `{"decision": "accept|reject|counter", "npcOffer": ["..."], "npcWants": ["..."]}`.
`accept` makes the exchange on the table now; `counter` puts the NPC's own items (only `tradeable` names) on the table
and, with `npcWants` (only `player.tradeable` names), fills the player's side with exactly those (the items still stay
with the player); the player can take it with "Accept" without another LLM call.

**No credit:** the game always makes the exchange (`Hooks.executeTrade`): first both sides' items are validated again;
when the NPC gives something, the player's side cannot be empty (`unpaid`); the player's items move first, then the
NPC's; if one item cannot move, every move is undone. If the player changed the table while waiting, the accept is void.
The sidecar also turns a `give` that is part of a bargain (words like "in return", "trade" from the player or the NPC,
"I'll give", "I'll pay" from the player, in Turkish too, e.g. "karşılığında", "takas", "veririm") into a trade offer:
the NPC's item goes on the table and the player's item they named is asked for.

### `history`

Request `data`: `{"uid": "...", "playerKey": "sp:0", "limit": 30}`. Reply: `{"uid", "name", "trust", "fear", "goal",
"turns": [{"speaker": "player|npc|system", "text": "...", "ts": 0}]}` (oldest first). `system` lines are what really
happened in the game (e.g. "Henry handed over Water Bottle.").

### `moods` (phase 5)

The stored mood of NPCs not talked to in this session, for the policy's input (`Moods.lua`). Request `data`:
`{"playerKey": "sp:0", "uids": ["palife:...", ...]}` (at most 32 uids; the game sends batches of 24, at most one request
every 3 s). Reply: `{"moods": [{"uid", "trust", "fear", "goal"}], "goalHalfLifeMs": 1800000}`; only NPCs with something
stored in the sidecar are listed (the rest start at 0; the game asks for them again after 5 minutes).
The game writes them into `Dialogue.minds` only for NPCs it does not know yet; a reply from this session is always
fresher. Exception: when one of the player's events changed trust or fear in the sidecar (`npc_hit`, `player_helped`,
the crew of `robbed_player`, a successful `npc_action` trade / give), the game asks again although it knows the NPC
(`Moods.refresh`) and writes the answer over trust / fear / drive (`Dialogue.updateMood`; the last intent stays). The
event line is written before the request, so the sidecar applies it first.

### `decision_samples` (phase 3, behaviour cloning data)

Sent as an `event` (`DecisionLog.lua`) when the sidecar announced the `dataset` feature in its `hello` reply; it does
not go into memory or `events.jsonl`:

```json
{"kind": "decision_samples", "schema": 1, "names": ["health", "..."],
 "rows": [{"d": "decision", "a": "regroup", "o": [1, 0, 0.5, "..."], "m": ["orders", "regroup"],
           "u": "palife:...", "f": "alife_church_volunteers", "p": "...", "t": 1791496029466, "pa": "regroup"}]}
```

- `d`: the A-Life chain (`decision` without a threat, `response` to a threat), `a`: the winning module id or `default`
  (A-Life's own fallback), `o`: `Features.vector` (rounded to 3 digits), `m`: the modules allowed for that NPC in that
  chain, `pa`: the shadow-mode policy's choice (when trained weights exist).
- `c: true` (sidecar `chosen`): policy control chose the module (`Control.lua`); it is not A-Life's choice, `rl/` does
  not learn from it and shadow mode does not compare it. `ctl: true` (`control`): the row was logged while policy
  control was on.
- `names` comes once per connection with the first batch. A batch has at most 12 rows (to stay below the line limit).
- The sidecar writes valid rows to `<data folder>/dataset/decisions-<date>.jsonl` and the names to `schema-<n>.json`.
  When the feature list changes, `Features.SCHEMA` is bumped; data of the old schema stays apart.

### `event` kinds

`policy_stats` (every 5 minutes while policy control is on, `ALifeBrainMain.reportPolicy`): `Control.stats`
(`decision` / `response`: `asked`, `ran`, `declined` = had nothing to do, `near` = the player was near, `left` = left to
A-Life; `modules`: the modules that ran; `reasons`: why it was left). One line goes into `sidecar.log`, and it stays in
`events.jsonl`; it does not go into memory.

`npc_hit`, `npc_died` (EventLog.lua) and `npc_action` (Dialogue.lua): `{"kind": "npc_action", "action":
"give|follow|stay|leave|trade", "ok": true, "item": "water", "label": "Water Bottle", "given": ["..."] (from the NPC to
the player), "received": ["..."] (from the player to the NPC), "reason": "no_item|too_far|limit|low_trust|refused|
rejected|changed|empty|unpaid", "npc": {...}, "by": {"kind": "player", "key": "sp:0"}}`. `trust` / `fear` are the NPC's
accumulated values toward that player (-100..100).
An `npc_hit` from the player carries `zombiesNear` (the number of plain zombies within 4 tiles of the victim): when
> 0 the sidecar takes it as an accident (trust -3, fear +2, a "by accident" memory; not written as an attack on the
squad). `player_helped` (EventLog `onZombieKilled`): for every A-Life NPC within 10 tiles of a plain zombie the player
killed, at most once a minute per NPC, with the kills in between added up in `kills`: trust +3 (+4 for 3+ kills), fear
-1, and every 5 minutes a personal ("The stranger killed ... right next to me.") and a squad memory. When the player gave
something in a completed trade, trust rises too (a gift +6, a fair exchange +2). `reason` can also be `combat` (the NPC
is in the middle of a fight).
`robbed_player` (Robberies.lua): an A-Life crew's robbery of the player has ended. `{"npc": <leader>, "crew": [<at most
6 members>], "outcome": "released" | "execute:<fled|drew_weapon|armed|no_hands|shouted|aimed_at_crew|attacked_crew|
hostile_surrender>" | "player_gone" | "crew_gone" | "interrupted", "taken": ["Hammer", ...], "by": {"kind": "player",
"key"}}`. The NPCs here are described from A-Life's registry (`Hooks.describeRecord`: uid, name, factionId, groupId).
`by`: `{"kind": "player", "key"}`, `{"kind": "npc", "uid"}` (in `npc_died` also `name`, `factionId`, `groupId`: the
sidecar remembers the loss with the killer's name), `{"kind": "zombie"}` or `{"kind": "other"}`.
Error codes: `dialogue_unavailable`, `invalid_llm_reply`, provider codes (`timeout`, `rate_limited`, `unreachable`,
`unauthorized`, `player2_client_id_missing` ...). The LLM call runs in the background in the sidecar; the sidecar gives
up after 60 s (`dialogue.timeout_s`; over 130 replies Player2 had a median of 11 s, 95% within 20 s, the slowest 32 s,
and on a slow evening the first reply of a conversation took 37 and 43 s; the old 30 s limit cut off 3% of the replies;
the game is paused during a conversation, so waiting is cheap; when the file still holds the old default 30, 60 is
used). Lua waits 75 s (the sidecar always answers first; this only matters when the sidecar is gone), then falls back
to A-Life's canned line.

## Sidecar -> Lua (reply file)

The first line is **always** the status line; the following ones are unacknowledged messages:

```json
{"v":1,"type":"status","sid":"a1b2c3d4","beat":42,"ts":1759951234600,"ver":"0.1.0","sess":"<last session seen>"}
{"v":1,"type":"res","rseq":7,"re":"<request id>","ok":true,"data":{...}}
{"v":1,"type":"res","rseq":8,"re":"<request id>","ok":false,"error":"unknown_type"}
{"v":1,"type":"push","rseq":9,"sess":"<session>","kind":"...","data":{...}}
```

- `sid`: random per sidecar process. When it changes, Lua resets its `rseq` tracking.
- `beat`: grows with every write; the sidecar writes once a second even when idle.
- `rseq`: a growing sequence within the sidecar instance; Lua processes only those above `lastRseq` (repeats are
  harmless).
- The sidecar drops from the file the messages that were acknowledged (`rseq <= ack`), are older than 120 s, or belong
  to old sessions.

## Liveness and fallback

- Lua counts the sidecar as online when the `ts` of the status line is within 4 s of its own clock **or** `beat`
  changed within the last 4 s.
- While offline Lua **never writes** to the file: `request()` returns `nil, "offline"` at once (the caller falls back to
  a canned line), `send("event")` keeps events in a queue of at most 200 in memory and sends them with their original
  `ts` once the connection is back.
- If it goes offline while online, every pending request ends with `false, "offline"`.
- The default request timeout is 8 s (`ping` 5 s). The sidecar drops requests older than 30 s, except `event` / `ack`.

## Limits

- At most 16000 characters per line; JSON depth at most 64.
- Lua's outgoing queue holds 256 lines; the sidecar's pending replies 500.
- One sidecar at a time: the `sidecar.lock` file in the data folder is locked.
