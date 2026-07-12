# WeirdLoot

WeirdLoot is a World of Warcraft 3.3.5a addon for Wrath-era raid loot handling. It keeps the loot master as the authority, lets raiders register interest in items, resolves winners with explicit priority rules, and helps the loot master move items from boss drops to the correct players with less manual bookkeeping.

## What It Does

- Runs a synchronized loot session with the loot master as the source of truth.
- Rolls loot through on-screen banner cards: raiders click a bracket on the roll card, winners land as win banners.
- Builds the raid roster from guild data automatically, with paste-import as a fallback or override.
- Applies per-item loot priority rules and named-item priority rules, including loot-council handling.
- Records detailed loot results with an audit trail for each item.
- Delivers won items through payout mode: guided whispers and stack-correct trade auto-fill.
- Auto-routes master-loot drops to the loot master or a designated disenchanter while a session is active.
- Handles drops the loot master cannot pick up or cannot even see (held uniques, quest-gated drops).

## Main Features

### Loot sessions

- `Start Session` opens a new active loot session and snapshots the current raid attendees.
- `Scan Bags` refreshes the session item list from the loot master's bags.
- Session state broadcasts automatically on every change; raiders sync on join, reload, or request.
- A raid-entry prompt can offer to start a session when you zone in as the loot master.

### Rolling

- New loot surfaces as banner roll cards with clickable brackets and a countdown; a classic popup fallback is available.
- Rolls start in batches with `Start Rolls`, one at a time by right-click in the Loot tab, or automatically per the auto-roll/auto-start/auto-skip mode.
- Winners appear as win banners; the loot master's cards carry the controls for ending, cancelling, or rerolling.
- `Unlock Roll` clears item locks so previously resolved loot can be intentionally rerolled.

### Priority and resolution

- Raiders choose from `BiS`, `MS`, `MU`, `OS`, `TM`, or `Pass`.
- Resolution uses bracket priority first, then named-item priority, then class/spec loot rules, then roster status, then rolls.
- Named-item rules support hard priority chains and `LC` fallbacks; a session-level LC override can put any item to the council.
- Rolls self-block (only Pass) on items you could never use or receive: wrong class, a Unique you already own (bank included), a quest drop you already completed, a mount you already learned.
- Loot-council items resolve to an `LC Decision` card where the loot master awards each copy from a candidate flyout.
- Result details are written in a human-readable form so you can see why an item resolved the way it did.

### Roster

- The raid roster derives from the guild: guild rank maps to status, officer-note tokens supply spec.
- Non-guild raiders can be added as guests; the Roster tab compares configured roster against the live raid.
- `Import Roster` and `Import Named Items` on the Loot Master tab open paste windows for manual lists.
- The loot master's config is the authoritative source for loot decisions.

### Results and exports

- The Loot Results tab stores processed items, winners, and detailed reasoning.
- `Export Winners` produces a simple item-to-winner list; `Export Log` produces the detailed resolver log.

### Payout and trading

- `Start Payout` whispers owed players and arms automatic trade filling.
- When an owed player opens trade, WeirdLoot fills the window with exactly the owed items; the final accept stays manual.
- Soulbound-tradeable bounces retry with the next eligible copy automatically.
- The Incoming Trades toggle declines unsolicited trades while leaving trades you start untouched.
- The Results tab also supports a guided manual flow per winner.

### Unlootable drops

- A Unique (carry-one) drop the loot master already owns rolls off the corpse and master-loots straight to the winner on re-loot; the cards and a banner strip say the copy is still on the corpse.
- A quest-gated drop the loot master cannot see warns at loot-open, rolls as a normal (invisible) item, and delivers through a temporary master-loot loan: the winner borrows the loot-master role for that one pickup and it returns automatically.
- The loan is guarded end to end: authority stays pinned to the owner, the raid leader is prompted for the role swaps, and timeouts cover an absent borrower.
- A running loan can be reset from the item's card or the Loot Master tab with `Cancel Loan`; the winner is kept.

### Auto-loot routing

- While a session is active, BoP and epic BoE drops route to the loot master for rolling.
- Non-epic BoE drops can route to a designated disenchanter set with `/wl deer`.

### Quality of life

- A minimap icon opens the window and shows session/authority state at a glance.
- A login settle window avoids treating already-owned items as fresh drops during staged bag loading.
- Sessions, results, and payout state survive reloads and relogs.
- Test mode supports in-city validation by treating any bag item as session loot.

## Interface Overview

- `Loot` tab: current session loot, player responses, roller counts, and manual roll starts.
- `Loot Results` tab: resolved winners, detailed reasoning, and payout/trade helper actions.
- `Loot Master` tab: session controls, payout and trade toggles, loan reset, imports, exports, and the session snapshot.
- `Roster` tab: configured roster versus live raid membership.
- `Options` tab: banner, rolling, and delivery behavior.

## Slash Commands

- `/weirdloot` or `/wl` opens the addon window.
- `/wl start`, `/wl end`, `/wl scan` control the session.
- `/wl winners` and `/wl log` open the exports.
- `/wl payout`, `/wl payout stop`, `/wl payout clear` control payout mode.
- `/wl autoroll`, `/wl autostart`, `/wl autoskip` pick the new-loot rolling mode.
- `/wl loan cancel` ends a running master-loot loan.
- `/wl deer <name>` sets the designated disenchanter.
- `/wl guild` shows the guild-roster data the addon derived.
- `/wl test` toggles test mode.

## Layout

- `Core.lua` + `Core/`: bootstrap, saved variables, comm, roster, and authority.
- `Loot/`: session, loot ledger, resolver, live rolls, loot observer, master-loot loan, auto-loot.
- `Trade/`: payout and trade delivery.
- `UI/`: tabs, banners, popups, minimap.
- `Data/`: loot priorities, item info, class blacklist presets.
- `Libs/`: embedded comm and sync libraries.
- `tests/`: out-of-game battery, run with `luajit tests/run.lua`.

## Manual Validation

Install on a 3.3.5a client with at least two raid members: start a session, loot items, roll from the banner cards, and confirm winners, results, exports, and payout trades behave as described above. Reload mid-session and confirm state restores.

Made by and for `Weird Vibes`.
