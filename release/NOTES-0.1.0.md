# A-Life Brain 0.1.0 (test release)

LLM conversations, long-term memory and trained decisions for Project A-Life NPCs in Project Zomboid Build 42.
Project A-Life's NPCs talk back in your own words (through Player2, Ollama or your own key), remember what you did,
trust or fear you for it, and that trust changes how their group treats you.

## Download

`ALifeBrain-0.1.0.zip`: the mod, the sidecar (`ALifeBrainSidecar.exe`, no Python needed) and `INSTALL.txt`
(setup in English and Turkish).

SHA-256 `0431E065B9E75DC23EBDF4072768D08A80A65F554980D4C25E81ED53C2EC18CF`
(check with PowerShell: `Get-FileHash ALifeBrain-0.1.0.zip`)

## Requirements

- Project Zomboid Build 42.21 or newer, **single player** (multiplayer is not supported yet).
- Project A-Life (Steam Workshop); tested with 1.3.15.
- Windows 10 or 11.
- The Player2 app (https://player2.game), signed in, and your own Player2 client id
  (https://player2.game/profile/developer), or Ollama, or your own OpenAI-compatible key.

## What it does

- A conversation window (`T` next to an NPC): free text, the NPC answers in character, gives, trades, follows or
  waits for real. The game pauses while the window is open.
- Memory per NPC, squad and faction, per save; old memories are summarized.
- Trust and fear from words and deeds (gifts, fair trades, fighting the dead next to them). A careful group whose
  member trusts you (5+) lets you come close instead of warning you off.
- Hostile crews talk before they shoot: pay a toll, talk your way out, or fight.
- NPCs you meet are kept in the save.
- Optional: a trained policy (behaviour cloning + PPO) chooses among A-Life's own behaviours, steered by trust,
  fear and drive. Off by default (Options -> Mods -> A-Life Brain).
- Without the sidecar the game and A-Life run as usual.

## Known limits

- Test release: expect rough edges. Try it on a new save first.
- The exe is not signed: Windows SmartScreen may warn (More info -> Run anyway).
- Every player needs their own Player2 client id for now.
- Player2 sometimes refuses a line (HTTP 400) or answers slowly (up to about 40 s); the window says so and
  A-Life's own line is used.
