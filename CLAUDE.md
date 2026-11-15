# Quest Ketchup

WoW Forever addon (client 1.60.x, `## Interface: 16001`) that lets two players
compare quest progress, so one can catch up on what the other did while
offline. Progress syncs over addon messages while grouped, or through an
export/import string sent over any messenger. Partner data is saved and stays
available after they log off.

This repo is the source and lives **outside** the WoW folder. The game loads an
installed copy in `D:\Program Files\World of Warcraft\_forever_\Interface\AddOns\QuestKetchup`,
written by `tools\deploy.ps1` - edit the repo, never the installed copy.

Displayed name `K.NAME = "Quest Ketchup"`. Folder, toc, saved variables
(`QuestKetchupDB`), addon-message prefix (`QuestKetchup`) and export prefix
(`QUESTKETCHUP1:`) were renamed from "Ketchup" on 2026-11-15 (version 1.1.0).
Slash commands: `/ketchup` (keep it), `/questketchup`, `/ketch`.

## Reminder: remove the rename compatibility code

From **2027-01-15** on, remind the user at the start of a session that the
compatibility code for the old "Ketchup" name can go. Few people had installed
the addon before the rename, so this is low priority. Remove:

- `LEGACY_PREFIX` in `Comm.lua` (registered and accepted next to `PREFIX`
  in `Comm:Init`) - lets 1.0.x clients' sync messages through.
- `LEGACY_PREFIXES` in `Serialize.lua` (the loop in `S.FromExportString`) -
  lets `KETCHUP1:` export strings from 1.0.x import.

Delete this section once that is done.

## Files

- `Locale.lua`, `Locales/*.lua` - `L` table; the English text is the key and
  the fallback. 9 locales: deDE, frFR, esES (+esMX), itIT, ptBR (+ptPT), ruRU,
  koKR, zhCN, zhTW.
- `Serialize.lua` - snapshot <-> string: CBOR -> deflate -> Base64 via
  `C_EncodingUtil`.
- `Core.lua` - saved data, snapshots `{v,n,r,cl,lv,fa,g,ts,c,q}`, partner
  storage, diff for the window, `GetSyncStatus` (catchup / together / ahead /
  none), "stop and do it together" warning, group helpers (`FindGroupUnit`,
  `IsQuestingTogether`), group progress (`GroupPartners`,
  `OtherGroupProgress`), quest chains (`PartnerChain`), events, slash command.
- `Comm.lua` - addon messages: chunking, throttled queue, reassembly.
- `Style.lua` - EllesmereUI skin facade, or a built-in flat dark fallback.
- `UI.lua` - main window, export/import dialog, minimap and world map buttons,
  quest log icons and quest log tooltip.

## WoW Forever facts (learned in-game, not in any docs)

- Reports as mainline and uses the **modern map-attached quest log**: rows come
  from `QuestScrollFrame.titleFramePool` (`row.questID`, `row.Text`); hook
  `QuestLogQuests_Update` and the pool's `Acquire`, and put icons inline into
  the title text. There is no `QuestLogFrame` / `QuestLog_Update`.
- Gamepad navigation hooks `CreateFrame`: creating a frame whose parent sits
  in an open panel taints that panel. Use `UI.CreateDetached` (create with a
  nil parent, then `SetParent`).
- Names: `UnitName` gives the first name ("Tarokk"), addon-message senders
  include a surname ("Tarokk Ligro-Realm"), and for cross-realm partners the
  sender realm can differ from their own `GetRealmName`. Match group members by
  GUID (`snapshot.g`) first, then by first name (`KeyIsName`).
- `C_QuestLog.IsUnitOnQuest` (and Blizzard's "[N]" party count in quest titles)
  only works while the group member is on the same map instance.
- EllesmereUI's "restrip" fades textures on frames it skinned: put own textures
  on a `Canvas()` child frame.
- The user runs Leatrix Maps, which moves the map's close/maximize buttons and
  search box into its own title bar: place the map button when the map is shown.
- Addons have no internet access; anything "online" must come from other
  players via addon messages.

## Optional integrations

- **Questie**: `QuestieLoader:ImportModule("QuestieDB")` - `GetQuest`,
  `IsDoable`, `QueryQuestSingle(id, field)` (`nextQuestInChain`,
  `preQuestSingle`, `preQuestGroup`; dot-call). It may still be loading right
  after login (`K:HasQuestie()` probes). Group members' progress:
  `ImportModule("QuestieComms").remoteQuestLogs[questID][sender]` =
  `{ {fulfilled, required, finished}, ... }`.
- **EllesmereUI**: `EllesmereUI.RegisterSkin(ADDON, function(S) ... end)`, see
  its `SKINNING_API.md`.

## Conventions

- Quest log icons, used the same way everywhere (quest log, tooltips, chain):
  green check = partner has the quest; orange ">>" (atlas
  `creditsscreen-assets-buttons-fastforward`, tinted 255,165,38) = partner
  turned it in or has every objective done, so do it to catch up; red cross =
  partner doesn't have it.
- Strings: always `L["English text"]` with a literal key (the checker only
  finds literals; for tables, resolve `L[...]` when the file loads). Add every
  new string to all 9 `Locales` files.

## Checks, logo and release

There is no Lua interpreter on this machine; the checks parse with luaparse.

- Once: `cd tools` and `npm install`. Then `node check-lua.js` (syntax) and
  `node check-locales.js` (keys and placeholders in all locales).
- Install into the game: `powershell -File tools\deploy.ps1` (optional
  `-AddOnsDir <path>`). It copies only the addon files, removes ones the addon
  no longer has, refuses to touch a folder with `.git`, and says whether a
  `/reload` is enough (changed Lua) or the game needs a restart (toc, new or
  removed files, textures).
- Logo: `tools\make-icon.ps1 -Src art.jpg -Preview preview.png` writes
  `Media\Logo.tga` (64x64, uncompressed 32-bit TGA). WoW caches textures, so a
  new icon needs a game restart, not just `/reload`.
- Release: bump `## Version` in the toc, run `tools\build-zip.ps1` (writes
  `dist\Quest-Ketchup-<version>.zip` with only the addon files under a
  `QuestKetchup/` folder), upload it to CurseForge.

## Working with the user

- The user tests in-game and commits/pushes themselves: don't commit; end with
  a short suggested commit message.
- After changing addon files, run the checks, then `tools\deploy.ps1`, and tell
  the user whether to `/reload` or restart the game.
- In-game debugging: add a temporary slash command that prints diagnostics,
  stores them in SavedVariables and calls `Screenshot()` (the user has no
  Print Screen key). Screenshots land in `_forever_\Screenshots`, saved
  variables in `_forever_\WTF\Account\<id>\SavedVariables` (written on
  `/reload` or logout). Remove the debug code afterwards.
