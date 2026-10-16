# A-Life hook points (study notes)

Version studied: **Project A-Life v1.3.15** (`modversion=1.3.15`, `versionMin=42.21.0`), game **42.21.0**.
Location: `C:\Users\ERDEM\Zomboid\mods\ProjectALifeNPCs\42.20\media\lua\` (not the Steam workshop, installed by hand;
the `workshop/content/108600/3803984183` path in CLAUDE.md does not exist on this machine).

The file paths below are relative to this folder. When A-Life is updated, review this document and
`ALifeBrainHooks.lua` together.

---

## 1. Overall structure

- All code lives under the `ProjectALife` global table: `ProjectALife.DecisionLoop`, `ProjectALife.ModuleRegistry`,
  `ProjectALife.ActorRegistry`, `ProjectALife.Talk`, `ProjectALife.Speech`, `ProjectALife.Relations`,
  `ProjectALife.Reputation`, `ProjectALife.Watchdog` ...
- Decisions, talk and reputation are in the **server** folder (`server/ProjectALife/...`). In SP, client + shared +
  server run in the same Lua VM, so all of it can be reached directly. On an MP client the server tables are **not
  there** (the client only sees copies that arrive through `MirrorTransport` / `sendServerCommand`).
- Startup: `server/ProjectALife/Core/ALifeServerBootstrap.lua` -> `Runtime.safeStart(...)` in
  `OnGameStart` / `OnServerStarted`, `Runtime.tick()` in every `OnTick`. Installing our hooks **after `OnGameStart`**
  is safest (A-Life's tables are filled by then).
- A-Life calls its own parts with `pcall` + `type(x) == "function"` guards all the time; we should do the same.

## 2. NPC identity

NPC = a zombie body ("shell") + a record ("actor record").

| Where | Field | Note |
|---|---|---|
| `shell:getModData()` | `ProjectALifeOwned == true` | Is it an A-Life NPC? (the check in CLAUDE.md is right) |
| | `ProjectALifeUID` | Lasting id, e.g. `"palife:<ms>:<seq>"` (<= 64 characters) |
| | `ProjectALifeGeneration` | Grows every time the body is recreated; check `uid + generation` together |
| | `ProjectALifeFactionId`, `ProjectALifeProfileId` | Faction and profile |
| | `ProjectALifeActivity`, `ProjectALifeIntent` | Mirror of the record's activity / intent |
| | `ProjectALifeBehaviorState`, `ProjectALifeBehaviorIntent` | **The decision loop's current state** (`stampState` writes it after every `think`) |
| `shell:GetVariable(...)` | `ALifeActor`, `ALifeUID`, `ALifeGeneration` | Animation-variable copy of the same information |

Helpers:
- `ProjectALife.Speech.variable(shell, "ALifeUID")` -> modData `ProjectALifeUID` first, `GetVariable` otherwise.
- `ProjectALife.ShellAdapter.shellIdentity(shell)` -> `uid, generation`.
- `ProjectALife.Watchdog.bindings[uid].shell` -> from uid to body (on the authority side only).
- `ProjectALife.Speech.findShell(uid)` -> the slow path that also works on the client (scans the cell's zombie list).

## 3. Actor registry: `server/ProjectALife/Core/ALifeActorRegistry.lua`

Record fields: `uid`, `revision`, `generation`, `lifecycle` (`dormant|spawning|active|dead`), `profileId`,
`factionId`, `worldPosition {x,y,z}`, `activity`, `intent`, `memory` (a free table).

Important `memory` fields: `groupId` (squad), `outpostId`, `supportForGroupId`, `behaviorProfile`, `conduct`,
`moduleOverrides`, `spawnStance`, `hostileOverride`, `hostileToPlayerKeys`, `hostileToActorKeys`,
`carefulPlayerKeys`, `tolerateUntil`, `robbery`, `robberyTruce`, `talkHoldUntilMs`, `talkHoldPlayerKey`.

API:
- `Registry.read(uid)` -> a copy, `Registry.peek(uid)` -> the live record (do not change it!), `Registry.each(fn)`.
- `Registry.update(uid, revision, mutate)` / `updateTransient(...)` / `updateMany(uids, mutate)`: optimistic locking
  (refused when `revision` does not match). `ProjectALife.Talk.writeMemory(uid, fn)` is a ready wrapper for writing
  `memory`.

## 4. Decision loop: `server/ProjectALife/Decisions/ALifeDecisionLoop.lua`

- `Decisions.tick(budget)` walks the actors within a time budget (12 ms) every tick. Actors close to a player
  (<= 45 tiles) think every 150 ms, far ones (> 110) every 1.5 s.
- `Decisions.think(uid, now)` -> `update(actor, shell, state, now)` -> `decide(...)` when needed -> the new state is
  written into `Decisions.states[uid]` and stamped onto the body.
- **State shape:** `{ kind, intent, cooldownUntilMs, action?, threat?, threatKind?, ... }`
  - `kind`: `idle | movement | combat | retreat | recovering | scavenging`
  - `intent`: free text, e.g. `patrol`, `regroup`, `search`, `investigate`, `retreat`, `hold`, `scan`,
    `engage_threat`, `manhunt_player`, `hunt_nearby`, `hold_pressure`, `robbery_pending`, `recover_endurance` ...
- `decideInternal` order:
  1. `Perception.findThreat` -> with a threat, `respondToThreat`:
     **`Modules.evaluate("response", actor, shell, ctx)`** (ctx: `now, threat, threatKind, startRetreat,
     startMovement, setActivity, persistMemory`) -> without a result `Combat.canEngage` -> `startCombat`.
  2. A support call (`Programs.supportDestination`), ambient lines.
  3. **`Modules.evaluate("decision", actor, shell, ctx)`** (ctx: `now, threat, threatKind, mode, factionProgram,
     orders, defaults, setActivity, startMovement, orderedTarget, persistMemory`).
  4. A search of the last seen position, an investigation of a sound / clue, `Programs.destination` (patrol /
     wandering), otherwise `idle/hold`.
- Player orders (a public API): `Decisions.setOrder(uid, generation, { kind = "follow"|"hold"|"patrol",
  player = <IsoPlayer>, anchor = {x,y,z}, untilMs?, quiet? })`. Usable directly for the `follow` intent.
- `Decisions.refreshDirective(uid)` -> cancels the current movement / idle state and makes it decide again.
- With `Decisions.traceDecisions = true` every decision emits `Telemetry.emit("decision_trace", {uid, kind, intent})`.
- **Implemented (phase 3):** `Registry.evaluate(kind, ...)` returns the **module id** together with the winning state
  (`return result, module.id`), and the decision loop drops the id. The loop holds
  `local Modules = ProjectALife.ModuleRegistry`, so the function is read from the table on every call;
  `Hooks.installDecisionTap` wraps `ModuleRegistry.evaluate`, watches only full chain runs with `only == nil`
  (`decision`, `response`) and returns the result unchanged. Label = the module id or `default` (the chain returned
  nothing, A-Life's own flow). Allowed modules (action mask): those in `Registry.order` with `dispatch == kind` and
  `Registry.allows(actor, id)`.
- **Implemented (phase 5):** while policy control is on, the same wrapper (`Hooks.wrapEvaluate`) asks
  `Hooks.decisionChooser` (`Control.pick`) **before** the full chain; when it returns a module id, that module runs
  alone (`only`); when it returns `nil` (nothing to do), or there is no choice, A-Life's chain runs as before. Modules
  start movement, play animations / voices and write memory inside `evaluate` (`context.startMovement`,
  `persistMemory`; e.g. `Search.evaluate`): that is why the chain cannot run first and its result be changed
  afterwards. The decisions the policy chose are reported with `chosen = true` and stay out of the BC data. A-Life's
  own lull calls (`only` set) pass through as they are. `Hooks.orderOf(uid)` (`DecisionLoop.orders`),
  `Hooks.nearestPlayer(shell)` and `Hooks.stance` serve Control's "leave it to A-Life" decisions. Distances from
  A-Life: `ModuleCareful.settings.warnRadius` 14 (`memory.carefulRadii` and scripted encounters may change it),
  `ModuleTalkPresence.courtesyTiles` 6, `ModuleRobbery.detectRadius` 55.
- Observation sources (`Hooks.decisionObservation`): the body's modData (§9), `context.threat/threatKind`,
  `Perception.zombieSnapshot` (perception refreshes it every 200 ms: `bodies` = plain zombies, `actors` = A-Life
  bodies, both `{body, x, y, z}`; `nil` before perception runs), `ActorRegistry.peek(uid).memory.groupId` (squad),
  `DecisionLoop.states/orders`, `Talk.stance`, the nearest player.

## 5. Module registry: `shared/ProjectALife/Behaviours/ALifeModuleRegistry.lua` (the RL hook)

This is A-Life's **own extension point**; the cleanest way to inject an RL decision without monkey-patching.

```lua
ProjectALife.ModuleRegistry.register({
    id = "alifeBrain", kind = "orders", dispatch = "decision", priority = 2,
    evaluate = function(actor, shell, context) ... return stateOrNil end,
})
```

- `Registry.evaluate(kind, actor, shell, ctx, only)` tries the chain **from the smallest priority number to the
  largest**; the first non-`nil` result wins. If we return `nil`, A-Life goes on with its normal flow -> a clean
  fallback when there is no sidecar / policy.
- The `only` parameter runs a single module: `Registry.evaluate("decision", actor, shell, ctx, "regroup")`.
  **RL action = an A-Life module id** is a possible design; the policy picks an id and we call that module with `only`.
- **Obstacle:** `Registry.allows()` -> `BehaviorProfiles.allows(actor, id)` allows only the ids in the profile's
  `overlays` table. A module with an unknown id **never runs**. Options:
  - (a) `ProjectALife.BehaviorProfiles.definitions[i].overlays.alifeBrain = true` (a table addition at run time, no
    A-Life file changes): recommended; kept in `ALifeBrainHooks.lua`.
  - (b) Writing `memory.moduleOverrides.alifeBrain = "on"` for every actor (pollutes the record data, not
    recommended).
  - (c) Asking the A-Life team for a "profile whitelist for external modules" (a Discord question).
- Current priorities (smaller = earlier): `robbery` 3, `talk` 4, `careful` 5, `orders` 10, `flee` 30, `stealth` 30,
  `panic` 34, `radioman` 35, `sniper` 38, `warning` 40, `ambusher` 42, `withdraw` 45, `cover` 50, `weave` 55,
  `strafe`/`doorstack` 60, `fortify` 78, `nightHold` 79, `medic` 85, `healing` 90, `cqbsweep`/`patrolRest` 92,
  `stance` 95, `investigate` 100, `regroup` 110, `search` 117, `scavenge` 118, `idleLife` 140, `spread` 150,
  `groupMarch` 200, others 500.
  - Suggestion: the RL module comes **after** `robbery` / `talk` / `careful` (e.g. `priority = 8`), so it does not
    break robbery and conversation scenes.

### RL action candidates (module id -> dispatch)

| Channel | Modules |
|---|---|
| `decision` (no threat) | `orders`, `careful`, `robbery`, `talk`, `fortify`, `nightHold`, `cqbsweep`, `medic`, `healing`, `patrolRest`, `stance`, `investigate`, `regroup`, `search`, `scavenge`, `idleLife`, `spread`, `groupMarch` |
| `response` (with a threat) | `flee`, `panic`, `radioman` (+ others whose default is `reaction`) |
| `positioning` (inside combat) | `stealth`, `sniper`, `ambusher`, `weave`, `cover`, `withdraw` |

Note: `stealth`, `sniper`, `medic`, `ambusher`, `leader` are **primary** modules; they run only when `memory.conduct` is
that id. Modules with `kind = "doctrine"` / `"craft"` and no `dispatch` join no chain at all (they are called from
elsewhere). This table is the starting point of the first RL action space; mapped to "patrol, raid, hold an area, warn,
rob, regroup" in CLAUDE.md: patrol -> `patrolRest` / the default program, hold an area -> `fortify` / `nightHold`,
warn -> `careful`, rob -> `robbery`, regroup -> `regroup`, raid -> `ModuleBreach` (`doorstack` / `cqbsweep`).

### Follower threat behaviour (seen in game, 2026-10-09)

- `decideInternal` runs `findThreat` -> `respondToThreat` first; an order (`orders`) applies only without a threat. A
  follow order has no leash (`Combat.leashFor` is only for guards with `memory.stance` / `garrisonPost`).
  Result: a follower attacks every zombie it sees (Grace, in melee, charged into 25 zombies).
- A-Life's only retreat from zombies is the `flee` module (`Fear/ALifeModuleSurvival.lua`): health <=
  `Survival.retreatHealth` (~0.35). For faction members `flee` may be off by profile (Grace had only `panic`).
- `interruptPassiveState`: `idle` / `movement` / `scavenging` / `recovering` states are interrupted while threats are
  seen (on every think when the last scan had a threat) and it reacts again; `retreat` states are not interrupted.
- **Implemented:** `Hooks.installCompanionModule` -> `alifeBrainCompanion` (`kind = "reaction"`,
  `dispatch = "response"`, priority 32: between `flee` 30 and `panic` 34). For the profile permission the id is added
  at run time to every `BehaviorProfiles.definitions[i].overlays` table (not saved; repeated every 30 s for new
  profiles). It decides only for a player follow order (`DecisionLoop.orders[uid].kind == "follow"`,
  `source ~= "leader"`) and a zombie threat (`Companion.lua`); returning to the player goes through
  `context.startMovement(..., { kind = "retreat" })` (so it is not interrupted), moving away through A-Life's
  `context.startRetreat`.

### Sneaking with the player, NPC warnings, parley (seen in game / requested, 2026-10-09)

- **Speed:** the `orders` module starts a follow without a speed -> `Movement` `walk`. When `run` is asked,
  `resolvePace` grants a 650 ms run window every 14 s (constant running in a danger stance) -> "short runs". Only
  firearm shots make world noise (`Combat.worldNoise`); `Voice.play` makes none.
- **Crouching:** every frame `AIFence` writes the result of `Stealth.stanceActive(modData)` into the `ALifeSneak`
  animation variable and `ProjectALifeSneakActive` (walking ×0.85, sprint drops to a run, a backstab multiplier). On
  only for NPCs with `ProjectALifeConduct == "stealth"`. **Implemented:** `Hooks.wrapStealthStance` adds followers
  whose player crouches (`Companion.sneakers`, from `DecisionLoop.orders` every 0.5 s).
- **Warning ladder:** `ModuleCareful` (decision chain, priority 5) warns players only (`CAREFUL_KEEP_BACK` ->
  `CAREFUL_LAST_WARNING` -> `CAREFUL_HOSTILE`, faction voices in `Audio/ALifeFactionVoiceStyles.lua`);
  `Careful.evaluateActor` is always `nil`. **Implemented:** `alifeBrainStandoff` applies the same ladder NPC<->NPC.
- **Truce:** while `memory.robberyTruce[Reputation.playerKey(player)] = untilMs`, `Relations.hostileToPlayer` returns
  false (the visible stance `playerStance` is still "hostile"). A-Life uses it after a robbery; while `memory.robbery`
  is active the crew does not count the player as a threat either. **Implemented:** a parley writes a 6 s truce to the
  crew and renews it every 2 s; a long truce on peace, cleared on a fight + `DecisionLoop.refreshDirective`.
- **A-Life's robbery** (`ModuleRobbery`): only crews registered as bandits / gangs, at least 2 strong and armed; its own
  scan (55 tiles) starts before the threat response. A parley does not start while a robbery is active
  (`memory.robbery`).

## 6. Talk system (the LLM hook)

Flow (SP):
1. `client/.../Talk/ALifeTalkInput.lua`: the chat key -> its own text box (`Input.open`) or the vanilla chat wrapper
   (`processSayMessage` / `processShoutMessage`). Text starting with `!` = a shout.
2. `Input.deliver("talkSay", {text, loud})` -> in SP directly `Talk.onPlayerText(player, text, loud)`, in MP
   `sendClientCommand(player, "ProjectALife", "talkSay", args)`.
3. `server/.../Talk/ALifeTalk.lua` `Talk.onPlayerText`: robbery words (`ModuleRobbery.onPlayerWords`) -> listeners
   (12 tiles, 25 when shouting; a 60° view cone) -> the addressee -> **`Talk.respond(player, listener, text, now,
   choiceIntent)`**.
4. `Talk.respond`: `TALK_BUSY_COMBAT` in combat, `TALK_IGNORE_HOSTILE` when hostile; otherwise
   `TalkIntents.classify(text)` (keyword scoring, threshold 30) -> `Speech.pick` from the
   `DialogueData.replies[intent]` pool -> `Speech.say`.

**Hook point for the LLM:** `Talk.respond`. Plan: step in only for free text (`choiceIntent == nil`), outside combat
and when not hostile:
- `Talk.hold(record, shell, player, now, ms)` -> the NPC stops and turns to the player (repeat while waiting).
- `Speech.say(shell, "...", { face = player })` -> the waiting bubble.
- When the reply comes, `Speech.say(shell, reply, { face = player })`; on a timeout the original `Talk.respond` is
  called (the canned-line fallback).
- This is a function wrap; kept in `ALifeBrainHooks.lua` with the original reference saved.
- **Implemented (phase 2):** `Hooks.installTalkHook(Dialogue.handle)`; the original is in `Hooks.originalRespond`, the
  fallback is `Hooks.respondWithAlife`. Single player only (there is no `Talk` table on an MP client).
- **Lines that cut in:** `server/.../Behaviours/ALifeModuleTalkPresence.lua` `evaluate` holds the NPC in the
  `talk_hold` state while `memory.talkHoldUntilMs` is valid (silent, facing the player). When the hold ends it says
  `GREET_PLAYER` if the player is within 5 tiles, and `STARE_PLAYER` if they stay within 2.5 tiles for more than 20 s;
  the counters are `Presence.greeted[party]` / `Presence.stared[party]`, `party = Presence.partyKey(actor, playerKey)`.
  Our solution: `Talk.hold` every 2 s while the window is open; when it closes, `Hooks.release` (lets go of the hold
  with `Talk.writeMemory`) + `Hooks.quietPresence` (moves both counters 3 minutes ahead).
- **Handing items over:** `server/.../Talk/ALifeTalkSupplies.lua` `Supplies.matches(item, "ASK_WATER"|"ASK_FOOD"|
  "ASK_MEDS")` are A-Life's rules for items it may hand out (drinkable water, food that is not rotten / poisoned, first
  aid; not equipped). The transfer is `shell:getInventory():Remove(item)` + `player:getInventory():AddItem(item)`, on an
  MP server `sendRemoveItemFromContainer` / `sendAddItemToContainer` (the same as Supplies.respond).
- **Follow / wait:** `DecisionLoop.setOrder(uid, generation, { kind = "follow", player, untilMs })` and
  `{ kind = "hold", anchor, untilMs }`; the `orders` module (priority 10) applies them, threat responses still come
  first. The active order: `DecisionLoop.orders[uid]`.

Context ready for the prompt:
- `Speech.contextFor(record, player)` -> `role, register, temperament, sex, day, hour, voice, stance`.
- `Talk.stance(record, player)` -> `hostile | careful | neutral | friendly`.
- `Talk.observations(record, shell, player, now)` -> `recent_zombie_contact`, `recent_human_contact`, `player_armed`.
- `Talk.varsFor(intent, ...)` -> `destination`, `town`, `den`, `weapon`.
- `Speech.nearestTown(x, y)`, `Speech.clock()`.

Other:
- On the server `Speech.say` broadcasts to players within 40 tiles with `sendServerCommand(player, "ProjectALife",
  "speech", {uid, text, x, y})`; the client draws `shell:addLineChatElement` in `Speech.onServerCommand`.
- `ProjectALife.AudioPolicy.caption(text)` filters / formats the text; when it returns `nil` no bubble shows.
- Menu choices: `TalkIntents.choices` (e.g. `ASK_NEWS`, `ASK_DESTINATION`, `JOIN_REQUEST`, `YES`, `NO`).
- `Talk.settings.maxTextLength = 200`, command rate limits `Talk.commandIntervalMs` (talkSay 800 ms).

## 7. Relations and reputation (RL observation + levers the LLM may move)

- `Relations.playerStance(actor, player)` -> `hostile | careful | neutral | friendly` (A-Life reduces "allied" to
  "friendly"). Layers: the faction base (`RelationLayers.towardPlayer`, profession shift included) -> `spawnStance` ->
  `Reputation.recordedStatus` (the status recorded per faction) -> actor `memory` overrides.
- `Relations.status(sourceActor, targetActor)` -> NPC<->NPC relation.
- `Reputation` (`ModData "ProjectALife.Reputation.v1"`): `escalate(player, actor, "attack"|"kill"|"provoked")`;
  `provoked` is forgotten after 24 game hours. Hitting or killing **one** member of a faction whose base stance is
  careful or neutral makes the whole faction hostile to the player for good (`cause = "attack"`, never forgotten;
  factions that are hostile at base do not change). `Careful.onHitByPlayer` writes no `hostileToPlayerKeys` to a crew
  that is already hostile.
  **Implemented (2026-10-14):** `Hooks.parleyBlocked` counts only the group's own grudge (`hostileToPlayerKeys`) as
  "grudge"; a crew hostile only through its faction's reputation parleys (`feud`, `FEUD_RULE` in the prompt). In the
  play test 17 of 26 crews had opened fire without a word because of the reputation. Sight: `Talk.lineOfSight` or
  A-Life's warning sight `ModuleCareful.lineOfSight`; when neither sees the player, the NPC waits 8 s
  (`Parley.settings.sightWaitMs`). A group the player hit in the last 2 minutes does not parley
  (`Parley.attackedAtMs`).

LLM `trust_delta` / `fear_delta` -> levers that already exist in A-Life (prefer limited, reversible ones):

| Lever | Effect | How |
|---|---|---|
| `memory.tolerateUntil[playerKey] = untilMs` | `careful` -> `neutral` | `Talk.tolerate(record, playerKey, untilMs)` (spreads to the squad). **Implemented:** `Rapport.lua` (trust >= 5) |
| `memory.carefulPlayerKeys[playerKey] = untilMs` | `neutral/friendly` -> `careful` | `Talk.writeMemory` |
| `memory.hostileToPlayerKeys[playerKey] = true` | -> `hostile` | `Talk.writeMemory` (hard to undo; do not open it to the LLM) |
| `Reputation.escalate(...)` | faction-wide hostility | do **not** open it to the LLM |

`playerKey`: `"sp:0"` in SP, the user name in MP (`Reputation.playerKey(player)`).

**Trust -> stance (implemented, 2026-10-12):** the careful stance comes from the faction alone; `ModuleCareful`
(`Behaviours/ALifeModuleCareful.lua`, priority 5) does `CAREFUL_KEEP_BACK` at 14 tiles, `CAREFUL_LAST_WARNING` at
9 tiles once the player has advanced another 0.75 tiles, then `turnGroup` (`hostileToPlayerKeys`, fire) when the player
stays within 6 tiles for 1.5 s; the ladder is per group + player and is forgotten when nobody comes inside for 45 s. In
the play test two NPCs with trust 5-6 turned on the player when the conversation window closed (the player was within
6 tiles). `Rapport.lua`: for a careful group whose most trusting known member is >= 5, `Hooks.tolerate`
(= `Talk.tolerate`, 10 minutes, renewed when 5 minutes are left); when trust drops below 3, only the value we wrote
ourselves (when `toleratedUntil` matches) is ended with `now`. It also runs as soon as a reply arrives, to act at once
(`Rapport.onReply`, `Dialogue.finish`). `Hooks.groupKey` = Careful's `groupOf` (outpost / group / alone).

## 8. Event sources (logging / memory / RL dataset)

A-Life has no general event bus; `Telemetry.emit` has very few categories (`actor_died`, `decision_trace`,
`patrol_rest`, runtime errors). We collect events this way:

| Event | Source inside A-Life | How we catch it |
|---|---|---|
| The player hit an NPC | `Combat/ALifeHealth.lua Health.onDamage` -> `Reputation.onPlayerDamagedActor`, `Talk.onHitByPlayer` | Vanilla `Events.OnHitZombie(zombie, attacker, bodyPart, weapon)` + a `ProjectALifeOwned` filter; fallback: the growth of `modData.ProjectALifeWounds` |
| An NPC died / was killed | `Core/ALifeLifecycle.lua` (`KillAttribution.resolve`, `Reputation.onPlayerKilledActor`) | Vanilla `Events.OnZombieDead(zombie)` + `zombie:getAttackedBy()`. Careful: `Sim.markCorpse` (`shared/.../Shells/ALifeShellSimulation.lua`) clears `ProjectALifeOwned` on death and writes `ProjectALifeCorpseOf = uid`; the `ShellAdapter` cleanup may delete every `ProjectALife*` key. Our handler looks at both `ProjectALifeOwned` and `ProjectALifeCorpseOf`. |
| A squad member died | the same | The dead NPC's `memory.groupId` -> a memory record for the actors in the same group |
| Robbed / a robbery | `Behaviours/ALifeModuleRobbery.lua` (`phase`: `spot -> demand -> search -> execute`, `finish`, `take`) | Polling for changes of `memory.robbery.phase` |
| The player helped | `Talk.onHelped` (client `OnZombieDead` -> `talkHelped`) | Vanilla `OnZombieDead` + a nearby NPC in combat |
| Food / an item was given | (not directly in A-Life; `Talk/ALifeTalkSupplies.lua` only asks) | Our own context menu / action (in phase 2) |
| State / intent change (BC data) | `stampState` -> `modData.ProjectALifeBehaviorState/Intent` | Sample NPCs near the player at intervals |
| Stance change | `Relations.playerStance` | Polling + diff |

## 9. Data ready for the RL observation

- Health / bleeding: `modData.ProjectALifeWounds`, `ProjectALifeBleedOutAtMs`, `ProjectALifeDownedUntilMs`,
  `ProjectALifeWoundLeg`, `shell:getHealth()`; `ProjectALifeMaximumHealth`.
- Ammunition / weapon: `ProjectALifeLoadedRounds`, `ProjectALifeEngineLoadedRounds`, `ProjectALifeWeaponClass`,
  `ProjectALifeActiveWeaponType`, `ProjectALifeWeaponJammed`.
- Combat: `ProjectALifeCombatPhase`, `ProjectALifeCombatTactic`, `ProjectALifeTargetDistance`,
  `ProjectALifeTacticalRole`, `ProjectALifeBehaviorTier`, `ProjectALifeFearOf/FearUntilMs`, `ProjectALifePanicUntilMs`.
- Endurance: `ProjectALifeEndurance`, `ProjectALifeEnduranceMaximum`.
- Threat: the decision module's `context.threat`, `context.threatKind` (`player | zombie | actor`).
- Whether the player has a weapon drawn: `Talk.observations(...).player_armed`, `player:isAiming()`.
- Time of day: `Speech.clock()` (`hour`, `daysSurvived`).
- Faction relation: `Relations.playerStance` (categorical -> one-hot).

## 9b. Spawning NPCs for tests

- A-Life's right-click menu (`client/.../Interface/ALifeContextMenu.lua`, debug / admin): `[A-LIFE] Project A-Life` ->
  `Spawn faction squad here...` / `Open spawn panel`. Both open the `ALifeDebugSpawnerWindow.open(...)` panel.
- The panel sends `sendClientCommand(player, "ProjectALife", "debugSpawnCatalog", { encounterId, count, x, y, z, ... })`
  (`server/.../Admin/ALifeDebugService.lua`). This command is in the `Service.diagnosticCommands` list; A-Life accepts
  it only after `alifeDiagnostics { enabled = true }`. In SP the permission is always there, in MP it needs an admin.
- Encounter ids are in `shared/.../World/ALifeEncounters.lua`: `patrol` (2-4), `raid` (Hostile Scouts),
  `scavenger_crew`, `town_patrol`, `blockade` ... `fullscale_raid` starts a full-scale raid, do not use it in tests.
  Spawns are chosen with `Service.hostileProfileIds`, so they may be hostile to the player.
- With a `factionId` it chooses from that faction (`Service.hostileProfileIds(count, seed, factionId, true)`).
  The view of the player is `stance.player` in `common/alife_runtime/catalog/faction_registry.alife`: e.g. friendly /
  peaceful `alife_church_volunteers`, `alife_county_ems`, `alife_lone_nurse`; hostile `alife_hobbs`, `alife_pit`.
- Our shortcut: `ALifeBrain.spawnTestNpc(factionId, count, encounterId, temporary)` -> `Hooks.spawnTestNpc`
  (default `alife_church_volunteers`, 1 NPC, `patrol`, kept: `persistent = true` goes with the command).
- **Persistence (verified 2026-10-11):** without `args.persistent`, `debugSpawnCatalog` uses the encounter definition's
  `persistent` (there is none for `patrol`) -> in the record `memory.persistent` / `encounter` are empty and
  `memory.debugSpawn` is set. `Population.expendable` counts these as expendable: a sleeping (`dormant`) NPC, while the
  player is more than 60 tiles away (`spawnDistance`), is deleted with `Registry.remove(..., "dormant_ttl")` once the
  sandbox `Population_DormantTtlHours` ("Unvisited NPC lifetime", default 8 game hours) runs out.
  `persistent = true` -> `encounterPersistent` + `anchor`, never deleted.
  **Saving:** `Persistence.forSave` writes into the save only the records of allowed groups: `SquadLedger.liveIds()`
  (offline squads), resident outpost members and other groups `actorGroup` returns (`outpostId`, `squadId`,
  `persistent` or `admin.persistent`; key `groupId or encounter or uid`) up to `Persistence.squadCap` (sandbox
  `Population_PersistentSquadCap`, "Saved group limit", default 20, at most 500, changes live). `sessionOnly` /
  `outpostSquadId` are never written. A non-persistent NPC lives for one session (`sessionActors`). **Implemented:**
  `Keeper.lua` + `Hooks.keepGroupOf` (`persistent = true`, `alifeBrainKeptAtMs` for every living member of the group
  through `Talk.writeMemory`), `Hooks.savedGroups`, `Hooks.releaseKept`. `Persistence.actorGroupCount` is used nowhere;
  the population capacity (`Population.capacityUsed`) counts only sleepers within 60 tiles of the player.
  A-Life writes every deletion with `Telemetry.emit("actor_removed", {uid, reason})` only into its in-memory ring
  (96 events) and `Telemetry.counters`, not to the console: `ALifeBrain.npcs()` shows them (`Hooks.actorSnapshot`,
  `Hooks.lifecycleEvents`).
- Observation (could be reported to A-Life): `seed % 2147483647` in `hostileProfileIds` is called with a millisecond
  timestamp; because of Kahlua's `%` bug (see CLAUDE.md) the result may differ from what is expected. The harm is
  probably only in how random the profile choice is.

## 10. Fragility list (check when A-Life is updated)

Everything our hooks rely on is gathered in `mod/.../ALifeBrainHooks.lua`:

1. The signature and `context` fields of `ProjectALife.ModuleRegistry.register / evaluate`.
2. The `ProjectALife.BehaviorProfiles.definitions[*].overlays` table (to allow our modules).
3. The signature of `ProjectALife.Talk.respond(player, listener, text, now, choiceIntent)`;
   `listener = {record, shell, distance, inCone}`.
4. `ProjectALife.Talk.hold`, `Talk.stance`, `Talk.observations`, `Talk.tolerate`, `Talk.writeMemory`.
5. `ProjectALife.Speech.say / contextFor / playerKey / variable / clock`.
6. `ProjectALife.DecisionLoop.states`, `setOrder`, `refreshDirective`.
7. modData field names (`ProjectALifeOwned`, `ProjectALifeUID`, `ProjectALifeGeneration`, `ProjectALifeBehaviorState` ...).

## 11. Questions for the A-Life team (Discord)

1. Is it supported for external mods to register decision modules? Could an external module whitelist for
   `BehaviorProfiles` (e.g. `BehaviorProfiles.allowExternal(id)`) be added?
2. Would an official "dialogue provider" hook for `Talk.respond` (async reply, waiting and timeout) be considered?
3. Would you suggest a way to subscribe to decision events for behaviour cloning (other than `decision_trace`, e.g.
   the `Telemetry.adapters.log` chain)?
4. In MP, on which side does the decision loop run (`Executor.clientAuthority`), and which actor fields are mirrored to
   the client?
5. Does writing third-party fields into `memory` (e.g. `memory.alifeBrain = {...}`) break record migration
   (`RecordMigration`)?
