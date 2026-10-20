# HANDOFF

Persistent working file for autonomous development of "Not Gonna Make It".
Whoever works on the project (one autonomous Claude terminal looping, or a
human) reads this whole file first and records each change in section 6.

## 1. Protocol

1. **Start of iteration:** read this file, run `git status` and
   `git diff --stat`, and read the newest log entry in section 6. Finish or
   resolve any item left `IN PROGRESS` before starting something new.
2. **Pick one item:** the highest-priority `OPEN` item on the board (section 5).
   Mark it `IN PROGRESS` and list the files you expect to touch. If nothing fits,
   survey the game, add new items with priorities, then take one.
3. **Studio:** there is one Roblox Studio instance (`list_roblox_studios` ->
   "not gonna make it"). Always leave it in Edit mode with no preview junk
   (see 3.6).
4. **Definition of done:** `selene src` adds no new warnings in files you touched;
   files you create or rewrite stay under 500 lines; the change is exercised in a
   Play session with no new errors in the output (the UIBlox and
   `rbxassetid://203785492` warnings are pre-existing noise); visual changes are
   checked with screenshots; venue changes pass `scripts/zfight-detector.luau`.
5. **End of iteration:** add a log entry at the top of section 6 (what, why, how
   verified, next steps; a few lines), update item statuses, add new items, and
   record any hard-won fact in section 3.
6. **Do not commit or push** unless the user asks. Never commit secrets or `.env`.
   If a change turns out risky or half-done, revert it and log why.
7. **Questions for the user** (design direction, spending, publishing) go in a
   `## Open questions` list right below this protocol; wait for an answer.
   Update from the user: never stop to ask anything. Reason it out, decide, log
   the reasoning in section 6, and keep working. Anything that truly needs the
   user (spending, publishing) is skipped and noted in Open questions, not asked.
8. Style (user's global rule): in code comments and docs, no emojis, no em dashes,
   no stereotypical AI phrasing. Match the surrounding code's style.

## 2. Project map

Roblox, Luau `--!strict`, synced by Rojo (`rojo serve` is normally running).
`src/server` -> ServerScriptService.Server, `src/client` ->
StarterPlayerScripts.Client, `src/shared` -> ReplicatedStorage.Shared,
`assets/` -> ReplicatedStorage.Assets (hand-made model overrides).

| Area | Where |
|---|---|
| Phase loop (Lobby, Day1, Day2, Night2, Day3), matches | `server/GameStateManager`, `LobbyManager`, `QueueManager` |
| Venue build (layout, walls, halls, rooms, stairs, elevators, exterior) | `server/Venue/` (entry `Builder.luau`, dimensions `Layout.luau`), thin entry `server/MapBuilder.server.luau` |
| Furniture templates | `server/Venue/Furniture/{Office,Lounge,Fixtures}`, resolved by `server/AssetLibrary.luau` |
| Avatars, locomotion, IK | `server/RigFactory.luau` |
| Talkable NPCs (wander, dialogue, corruption) | `server/NPCManager`, `shared/NPCConfig`, `client/NPCDialogue` |
| Ambient crowd (desk workers, leaners, sleepers) | `server/AmbientPopulation` |
| NGMI enemies (AI, attacks) / their client animation and voices | `server/NGMIController` / `client/NGMIAnimator`, `client/NGMIVoice` |
| Procedural posing for R15 rigs | `shared/RigPose.luau` |
| Cutscenes | `shared/OpeningCinematic`, `SpeakerChoreo`, `NGMIChoreo`, `CutsceneActors`, `client/CutsceneManager`, `server/OpeningSequence` |
| Lighting, atmosphere, VFX | `shared/LightingProfiles`, `client/LightingController`, `AtmosphereFX`, `VFXManager` |
| Night 2 systems | `server/PowerManager`, `SurvivalManager`, `client/FlashlightController`, `ElectricalPanelUI`, `HeartbeatMinigame` |
| Coding minigame | `server/CodingGameServer`, `client/CodingGameUI`, `DeskBeacon` |
| Items, quests | `server/InventoryManager`, `InteractionManager`, `QuestManager`, `shared/ItemConfig` |
| Audio | `client/AudioManager` |
| Weathering (grime, puddles, Night 2 blood) | `server/SurfaceWeathering` |
| Visual setup notes | `docs/horror-visual-setup.md` |

## 3. Facts that cost a debugging round to learn

1. **R15 rigs have no Motor6Ds.** Rigs from `CreateHumanoidModelFromDescription`
   (everything RigFactory makes) use AnimationConstraints. Editing `C0` does
   nothing. Pose through `Shared.RigPose`, which rotates the constraint's
   Attachment0 and also corrects the inverted pitch axes (waist/neck/elbow/hip/knee).
   RigPose offsets layer under a playing animation, and server-side writes replicate.
2. **Walk animation speed.** The default R15 walk covers ~16 studs/s at playback 1.
   `RigFactory.driveLocomotion` scales playback to `WalkSpeed / 16`, reads root
   velocity with hysteresis (Humanoid.Running dips to 0 at every path waypoint),
   and honours a `WalkIntent` humanoid attribute to start the cycle early.
3. **Render budgets.** Past ~600 local lights the renderer silently drops lights
   (rooms went black); keep the venue near 300. Past ~900 SurfaceGuis some stop
   rendering; desk/laptop screens draw glowing strips instead
   (`Kit.screen{strips = true}`). The venue is ~30k parts.
4. **Z-fighting rule.** No two faces may share a plane and overlap. Covering pieces
   (casings, trim) reach 0.05 past the edge they cover. After any venue change,
   run `scripts/zfight-detector.luau` in Studio (instructions in its header).
   Last run (2026-10-19, Day 2): 13. Wall+Wall x8 and Coping x4 are the known
   invisible ones; one ElevDoor+ElevDoor pair at (-148, 4.9, -0.5) depends on
   door state. The detector skips rotated parts (random-yaw chairs are unchecked).
5. **Venue contracts other scripts depend on:** outer footprint, corridor Z +-9,
   the AUD rectangle (OpeningSequence has a copy), stair and elevator geometry
   (ElevatorController attributes), `BenchSeat` Seats, Workstation `Desk`/`Seat`/
   `Monitor` with the desk top at Y 3.26, Couch `CushionL/R`, Shelf board tops
   2.2/5.2/8.2, Laptop `Base` 0.18 thick, exactly 4 `PlayerDesk` desks in a
   random level-0 lab, exactly 4 `QuestChair`s on level 0 (`Venue/QuestChairs`:
   one in the player-desk lab, the rest in random non-restroom rooms; each is a
   seat part with `QuestId = "chair_hoarder"` and its legs/back as children, so
   InteractionManager hides or restores the whole chair), slabs named `Slab` in `Slab_<n>` (room
   floors are `FloorFinish`). Structural pieces are named `Wall` (line-of-sight
   blockers in InteractionManager, lean targets in AmbientPopulation).
6. **Studio testing recipes.**
   - Jump phases from a client: `ReplicatedStorage.Remotes.AdminCommand:FireServer({cmd = "setPhase", phase = GameConfig.Phase.DAY2})`.
     Skipping past Day 1 sets a flag that suppresses the opening cutscene for that
     session; restart Play to see it again.
   - The camera controller fights scripted cameras. Pin a shot camera with
     `RunService:BindToRenderStep("ShotCam", Enum.RenderPriority.Last.Value + 50, ...)`
     and disable the PlayerGui ScreenGuis before `screen_capture`.
   - Edit-mode venue preview: clone `ServerScriptService.Server.Venue` and
     `AssetLibrary` into a temp folder in ServerStorage, then
     `require(tmp.Venue.Builder).build(workspace, true)`. Edit-mode lighting is
     not the game's; judge interiors in Play. Clean up `workspace.Map`,
     `ServerStorage.VenuePreview`, `ServerStorage.AssetTemplates`, and restore
     `Lighting.Ambient` afterwards.
   - Rojo updates a ModuleScript's source in place, but `require` caches; clone
     modules (as above) to test fresh code in Edit mode.
   - Animation weights read 0 on the server; check `WeightCurrent` from a client.
   - If the agent has no Studio MCP tools loaded (Devin CLI only sees `ruflo`;
     `Roblox_Studio` is configured for Claude Code in `~/.claude.json`), use
     `python -X utf8 scripts/studio-mcp.py` (usage in its header). It drives the
     running StudioMCP over stdio: `luau Server file.lua`, `call start_stop_play`,
     `call screen_capture '{}' out.png`.
     Each run starts a new bridge, and Studio needs up to ~40 s to reconnect
     (the script waits for it). Never run two copies in parallel: they fight
     over the bridge and both see no Studio. Studio names can come back
     `null`; set `STUDIO_ID` (from `call list_roblox_studios`) when more than
     one Studio is open. `luau Client a.lua b.lua` runs several files over one
     connection. `execute_luau` returns the chunk's `return` value; `print`
     output is not captured.
   - After a reboot, check that `rojo serve` is running and the Studio plugin is
     connected. If it is not, `python -X utf8 scripts/sync-to-studio.py` (Edit
     mode) pushes every `src/` script into Studio. It never deletes anything.
   - Boss health is local to QuestManager; read it from
     `HealthFill.Size.X.Scale` on the `BathroomMonster`-tagged model.
   - Prompts CAN be fired for real: teleport the client root in front of the
     part, then `call user_keyboard_input` with `datamodel_type = "Client"` and
     `{"action":"keyPress","key_code":"E"}` (a `wait` step needs `wait_time_ms`).
     Prompts use `RequiresLineOfSight`; standing with furniture between you and
     the part fails silently, so approach from the part's open side.
     This did NOT work in the S2 session (keyboard and `prompt:InputHoldBegin()`
     alike; a server `Triggered` hook saw nothing, and `PromptShown` never fired
     3 studs from an NPC). Likely Studio lacking window focus while the user was
     on the PC. When it fails, drive the server bus the prompt would fire
     (e.g. `ServerComm.PanelPuzzleOpened`) and leave a hand-test item.
   - Admin `setPhase` DAY2 from the lobby passes through DAY1 (DAY1 handlers run).
   - Server buses live in `ServerStorage.ServerComm`. Quest progress must arrive
     on a server bus (`QuestItemCollected`, `GrantItem`), never from a client remote.
   - `scripts/sync-to-studio.py` compares raw bytes. The "17 stale scripts" it
     reported in S2 were line endings, not old code: those files were CRLF and
     the copies had been written LF. All changed files are LF now; keep them
     that way (the agent's file-write tool can produce CRLF on Windows, so
     check with `git diff --stat` or a byte scan after creating files). Expect
     `0 changed` on a second run; a new file under `src/` appearing in Studio
     confirms Rojo is live.
   - Python one-liners passed through a bash heredoc mangle non-ASCII (em
     dashes, arrows), so `str.replace` silently fails to match. Put edit
     scripts in a file instead.
   - Client folders of ModuleScripts sit next to their LocalScript under
     StarterPlayerScripts.Client (`HUD/`, `VFX/`, `Camera/`, `Flashlight/`,
     `Lighting/`, `Objectives/`, `NGMI/`) and are required with
     `script.Parent:WaitForChild("HUD"):WaitForChild("ScreenFX")`. Server
     ones (`Rig/`, `Power/`, `Venue/`) and shared ones (`Cinematic/`,
     `Opening/`) follow the same pattern.
   - Test recorders: a Client `execute_luau` can connect `OnClientEvent`
     listeners that outlive the call; have them write counts into
     `LocalPlayer` attributes and read those back in later calls.
7. **Client remote rule.** A client can fire any RemoteEvent with any arguments.
   Every `OnServerEvent` must either only affect the sender in ways they could
   already do (crouch, equip, leave a hiding spot) or be checked against server
   state: an inventory item, ammo AND a use cooldown (`UseItem`; items without
   ammo, like melee, are only bounded by the cooldown), a server-opened session
   (`PanelPuzzleOpened` bus, then `PanelRepaired` for that exact panel, once,
   after 1.5 s, within 16 studs), a server-confirmed action (a `WeaponUsed`
   spray allows one `DeodorantSpray` hit within 2 s and 30 studs, a melee
   swing one hit within 12 studs), or a
   validated conversation (`NPCTalked` bus). State other scripts need goes
   out on a `ServerComm` bus or a server-set attribute (`Player.Hiding`),
   never by re-reading a client remote. Remotes nobody should act on keep an
   empty listener so their queue drains (`HidingStateChanged`). `GameStateChanged`
   from clients is only `{ requestLobby = true }`, handled by LobbyReturn.
8. **One phase per server.** On a lobby server or in Studio the match runs on
   the same server as the lobby, every system reads one CurrentPhase and loops
   `Players:GetPlayers()`, so never move a single player out of a running
   match. End the match for everyone (publishPhase LOBBY resets every system)
   or leave them in. New server buses: `server/ServerComm.luau` (`bus(name)`).

## 4. Tooling

- Lint: `selene src` (std = roblox). Format: `stylua` (no `--syntax` flag).
- No Luau type checker is installed; Studio's Script Analysis is the fallback.
- Repo rule: files under 500 lines. Every file created or rewritten since the
  first commit is under it; 15 files that were already over (or within a few
  lines of) 500 at the first commit still exceed it (C1).

## 5. Improvement board

Status: `OPEN`, `IN PROGRESS`, `DONE`. Priority P1 (player-visible or
broken) to P3 (polish/cleanup). Add items freely; keep each to one or two lines.

| ID | P | Area | Item | Files | Status |
|---|---|---|---|---|---|
| G1 | P1 | Gameplay | Chair-hoarder quest: reward never granted, pickups never reached QuestManager, 1 chair for a 4-chair quest. Now 4 shared chairs, server-side progress, reward, objectives row, per-match reset. | `server/QuestManager`, `server/InteractionManager`, `server/Venue/{Builder,QuestChairs,Rooms/Work}`, `client/{ObjectivesUI,QuestUI}` | DONE |
| S1 | P1 | Security | `QuestUpdate` remote `attack_monster` trusts the client: every fire deals 20 boss damage with no item, range or cooldown check. Route through InventoryManager's `WeaponUsed` bus (already handled) and drop the remote branch; check the client still lands hits. | `server/QuestManager`, client deodorant use | DONE |
| S2 | P1 | Security | Audit every `OnServerEvent` handler (all 14 remotes clients can fire) for client trust. Fixed: `PlayerDamaged` (any client could damage or heal any player on Night 2), `HidingStateChanged` (client-set invulnerability vs NGMIs, plus a SurvivalManager copy), `DeodorantSpray` (8 fires from anywhere despawned any NGMI; dead SurvivalManager copy), `PanelRepaired` (panels fixed without the puzzle; client could also end sabotages and unblock coding), `SabotageEvent` (client could block everyone's coding), NPC talk objective (spoofed npcIds), and (second review) `UseItem` melee: no cooldown, so 5 forged calls killed the boss and every call broadcast `DeodorantSpray` to all clients; now a per-player weapon cooldown (melee 0.5 s, spray 0.4 s), and `EquipItem` is rate-limited. Already sound: `AdminCommand` (Studio or allowlist), `CodingTaskComplete`, `PickupItem`, `DropItem`, `CrouchState`, `PlayerJoinedLobby`, NPCManager's dialogue. Rule in 3.7. | `server/{SurvivalManager,NGMIController,PowerManager,InteractionManager,CodingGameServer,NPCManager,ProgressionManager,GameStateManager}` | DONE |
| G5 | P2 | Gameplay | Hiding minigame wiring: HeartbeatMinigame reads `data.hiding` but InteractionManager sends `isHiding`, and the `FireAllClients` broadcast reaches every client, so the minigame never starts for the hider (or would start for everyone). Its "discovered" result is ignored by the server. Decide whether discovery should kick the player out of the spot (server-side, in InteractionManager). | `client/HeartbeatMinigame`, `server/InteractionManager` | OPEN |
| G6 | P2 | Gameplay | SurvivalManager's zone sabotages (lights to 0, desks `Sabotaged`) could never be repaired: the client sent a panel name where a zone index was expected, and that remote path is now gone. It also fights PowerManager over the same lights. Pick one owner (PowerManager) and drop or merge SurvivalManager's sabotage. Done: SurvivalManager's duplicate sabotage system is removed; GameStateManager's timer is the only sabotage and flickers the lights (power types only) through PowerManager. | `server/SurvivalManager`, `server/PowerManager` | DONE |
| G7 | P1 | Gameplay | End screens fire `GameStateChanged {requestLobby = true}` (HUDController, CutsceneManager) but no server code handles it, so "back to lobby" does nothing. Done: `server/LobbyReturn` accepts it only in DAY3 or when the sender's character is dead (2 s cooldown). Match server: teleport to a public server (one retry, no local fallback). Same-server match: GameStateManager's `RequestLobby` bus ends the match for everyone once it is over or nobody else in it is alive; otherwise refused (one shared phase, so nobody is left half in a match). | `server/LobbyReturn`, `server/GameStateManager` | DONE |
| G8 | P1 | QA | Hand-test the prompt-gated paths changed in S2 (prompts could not be pressed from the MCP that session): hide in a closet (NGMIs should now lose you; they never respected hiding before), solve an electrical panel puzzle, talk to an NPC on Day 1 (Meet the staff ticks). Also with two players: one dies on Night 2 and presses Return to Lobby while the other is alive; nothing should happen. | `server/InteractionManager`, `server/PowerManager`, `server/NPCManager`, `server/LobbyReturn` | OPEN |
| G9 | P2 | Bug | NGMI hits error the HUD: NGMIController fires `PlayerDamaged:FireClient(target, BASE_DAMAGE, model)` (a number), HUDController:244 indexes `data.health`, so the health display never updates on NGMI damage. SurvivalManager also sends numbers. Pick one payload (`{ damage = n }`) and send it everywhere. The HUD now tolerates any payload (no more error), but the senders still disagree. | `server/NGMIController`, `server/SurvivalManager`, `client/HUDController` | OPEN |
| C4 | P3 | Code health | CodingGameServer `state.blocked` is never set any more (its only setters were the client `SabotageEvent`/`PanelRepaired` handlers). Remove it or drive it from PowerManager's `NightSystemsRestored`. | `server/CodingGameServer` | OPEN |
| V4 | P1 | Visual | User request: far more static NPCs, so most seats and couch spots are taken. Survey (Play, 2026-10-19): 220 `DeskSeat` (cap `MAX_SEATED` 80), 60 couch cushions but only 10 tagged `CouchSeat`, 148 `OfficeChair` Seats, 36 stools, 23 benches, 22 beanbags, 13 armchairs, 12 auditorium benches, all untagged. Skip `PlayerDesk` desks and quest chairs; mind the rig cost (~30k parts already, F1). Note: one fresh Play read phase 3 with 0 ambient rigs 25 s in; find out why before tuning. | `server/AmbientPopulation`, `server/Venue/*` | OPEN |
| U1 | P3 | UI | The QUEST COMPLETE toast (QuestUI, top right at 15%) draws over the Objectives panel. Move it (top center, under the clock?) or offset it below the panel. | `client/QuestUI` | OPEN |
| L1 | P3 | Bug | LobbyUI vignette `rbxassetid://1166862856` is not an image asset; "Asset type does not match" x3 every Play, vignette never shows. Replace with a valid image or a UIGradient. | `client/LobbyUI` | OPEN |
| G2 | P1 | Gameplay | `GameStateManager.spawnNGMI` only logs (TODO); confirm whether NGMIController covers the spawn ramp and remove or wire the dead path. Done: NGMIController spawns on NIGHT2 by itself (2 NGMIs in Play); the dead timer and TODO are removed. | `server/GameStateManager`, `server/NGMIController` | DONE |
| G10 | P1 | Bug | Endings never used real progress: `evaluateEndings` read PlayerData fields that nothing wrote, so every survivor got the bad ending. Done: reads CodingGameServer's `FinalProjectCompletion` / `ProjectCompletion` attribute and the live humanoid. | `server/GameStateManager` | DONE |
| G3 | P1 | QA | Elevator ride untested since the venue rebuild. Prompts can now be pressed via `user_keyboard_input` (section 3.6), so test: call, ride all 3 floors, doors, blackout refusal. | `server/ElevatorController`, `server/Venue/Elevators` | OPEN |
| G4 | P1 | QA | Night 2 full pass on the new venue: blackout look, emergency lights, flashlight on new materials, panels and racks reachable, NGMI chase through doors and stairs, blood decals on room floors. | many | OPEN |
| V1 | P2 | Visual | Night transition cutscene builds its own plain-part room at (8000, 400, 8000); rebuild it from the Venue furniture templates so it matches the game. | `client/CutsceneManager` | OPEN |
| V2 | P2 | Visual | Verify couch and sleeping-bag sleeper poses (moved to RigPose this session, never eyeballed). | `server/AmbientPopulation` | OPEN |
| V3 | P2 | Visual | Stairwell Brick material reads oversized; consider a MaterialVariant or a smaller-scale material for painted block. | `server/Venue/Stairs`, `server/Venue/Elevators` | OPEN |
| A1 | P2 | Audio | Footsteps by floor material (carpet, tile, concrete, wood), door and elevator sounds, per-room ambience (server hum in supply, HVAC). The `[AudioManager] 0 sounds` print is just `#` on a dictionary. | `client/AudioManager` | OPEN |
| F1 | P2 | Perf | Mobile/low-end pass: 30k parts, ~300 lights, ~530 SurfaceGuis, StreamingEnabled off by design. Measure, then trim trim-parts or add distance culling for hall decor. | `server/Venue/*` | OPEN |
| C1 | P2 | Code health | Files still over 500 lines (all were over, or within a few lines of 500, at the first commit): NGMIController 1502, CutsceneManager 1329, CodingGameUI 1039, NPCManager 1036, InventoryManager 944, GameStateManager 851, LobbyUI 766, InventoryUI 706, QuestManager 687, ElectricalPanelUI 677, InteractionManager 589, NGMIClient 583, NPCDialogue 554, CodingGameServer 523, ProgressionManager 504. | listed | OPEN |
| C2 | P3 | Code health | 202 selene warnings (331 at the first commit; 0 in `src/server`), 155 of them in CutsceneManager (unused locals). All remaining ones predate the first commit. | `client/CutsceneManager` and others | OPEN |
| C3 | P3 | Code health | Dead code: NPCConfig hand-authored waypoints and hiding spots for the old map (NPCManager ignores them). (`CorruptionStarted` IS used: GameStateManager fires it at the Day 2 halfway mark.) | `shared/NPCConfig` | OPEN |
| D1 | P3 | Design | Give the new spaces gameplay: Hack Hall and Library hiding spots, lounge/library items, use of the locked front entrance in an ending. | `server/Venue/Rooms/*` | OPEN |
| D2 | P3 | Design | Coding minigame UX review (CodingGameUI is the core loop and hasn't been touched in the recent passes). | `client/CodingGameUI`, `server/CodingGameServer` | OPEN |

## 6. Work log (newest first)

### 2026-10-19: Return to Lobby, reworked after review (G7, G2, G10)
- **What:** the first G7 version dropped one player from GameStateManager's roster, but every other system still treated them as in the match (NGMIs, survival, CurrentPhase), a teleport failure on a match server faked a lobby, and a missing character counted as dead. Now:
  - `server/LobbyReturn`: valid in DAY3 or with a loaded, dead character; 2 s cooldown. Match server: teleport to a public server, one retry, no local fallback. Lobby server/Studio: `RequestLobby` bus.
  - GameStateManager ends the match for everyone when it is over or nobody else in it is alive (publishes LOBBY, sends phase 0, reloads characters on the venue spawns players join on), otherwise refuses. One `removeFromMatch` helper also serves PlayerRemoving.
  - G10: endings read the real completion attribute and the live humanoid (before, every survivor got the bad ending).
  - G2: removed the dead NGMI spawn timer and TODO; NGMIController owns spawning.
  - Removed GameStateManager's unrequirable damage/heal/accessor API and the PlayerData state only it used: 870 to 702 lines (797 at the first commit). Bus get-or-create moved to `server/ServerComm.luau`.
- **Verified (Play):** NIGHT2 with 2 NGMIs: request while alive ignored; after dying, phase 0 on server and client, NGMIs gone, FloorPower restored, lights back to their pre-night 212/608, camera Classic, and still in the lobby 8 s later (no respawn into Night 2). DAY1 dead: lobby. DAY3 with completion 100: "true" ending, then lobby. New matches started after each. No script errors; selene 0 warnings on all touched files.
- **Not testable solo:** the refusal when another player is alive (needs two clients). Logged under G8.
- **Next:** V4 (user request), G8 by hand.

### 2026-10-19: merge-readiness pass (third review)
- **What:** the reviewer rejected the whole uncommitted tree for file length, em dashes, scope, and four correctness issues.
  - Correctness: LightingController's phase guard now resets a corruption creep on a repeated phase signal. VFXManager starts its focus raycast from the live phase instead of always (it ran every frame in the lobby). HUD heartbeat vignette rebuilds its gradients only when the alpha moves. Cursor leaks: the death screen closes on respawn and on any phase change; both ending screens close on any phase change other than DAY3 (requestLobby still has no server handler, G7).
  - Sabotage: SurvivalManager's duplicate zone sabotage (zeroed lights nobody could repair) is gone (G6). GameStateManager flickers only for PowerOutage and ServerCrash. Power/Flicker scales each light's live power level instead of restoring a snapshot, so a panel fixed mid-flicker is kept.
  - Dead config: removed RigFactory's empty SurfaceAppearance maps and the empty texture slots in GameConfig.SURFACES (materials stay); doc updated. Removed PowerManager's unpublished PanelFixed listener.
  - Split every file created or rewritten in this tree under 500 lines: LightingController (+Lighting/VenueLights), VFXManager (+VFX/Focus, Shake, Particles), HUDController (+HUD/ScreenFX, DeathScreen), FlashlightController (+Flashlight/Rig), ObjectivesUI (+Objectives/ObjectivePlan, ObjectivesPanel), CameraController (+Camera/Sway), RigFactory (+Rig/Hair, IK, Articulation; API re-exported), PowerManager (+Power/Flicker), CinematicCamera (+Cinematic/ScreenFX), NGMIAnimator (+NGMI/Poses), OpeningCinematic (+Opening/Audience, Overlay).
  - Em dashes removed from every line added since the first commit (35 lines). All changed files normalized to LF.
- **Verified:**
  - selene: 0 errors, 202 warnings (331 at the first commit), none new; 0 in `src/server`.
  - Play: lobby has depth of field off; Day 1 opening plays with letterbox, captions and seated crowd (screenshot); Day 2 corruption took saturation -0.18 to -0.45 and a repeated Day 2 signal restored -0.18; Night 2 flashlight rig present, a 3 s sabotage flicker ran cleanly; killing the player showed the death screen with a free cursor, and after respawn the screen was gone, CursorManager closed, camera back to LockFirstPerson. No script errors.
- **Scope:** the tree is committed as one commit per system rather than per iteration, since several files carry work from more than one iteration.
- **Next:** G8 hand test, V4 (user request), G7.

### 2026-10-19: melee spam closed (S2 second review)
- **What:** the reviewer found S2 had wrongly listed `UseItem` as sound. Melee items have no ammo, so nothing limited them: 5 forged `UseItem` calls with the plunger (20 damage each) killed the boss and earned its badge, and each call broadcast `DeodorantSpray` to every client. Fixes:
  - InventoryManager: per-player weapon cooldown in `useItem`, the single path to every `WeaponUsed` and spray broadcast (melee 0.5 s, the 0.28 s slash plus a beat; spray 0.4 s).
  - NGMIController: melee hits on NGMIs are supported on purpose again (S2 had silently dropped them). A confirmed melee use allows one hit within 12 studs; sprays keep 30.
  - `EquipItem` rate-limited to one rebuild per 0.15 s, deferring rather than dropping, so the last selection always wins.
  - Removed dead locals (`INVENTORY_SLOTS`, `getInventory`, QueueManager's `Players`). `selene src/server`: 0 warnings.
- **Verified (Play):** facing the boss at 5 studs, two bursts of 25 `UseItem` calls took it 1.00 to 0.80 to 0.60 (one swing each) with one broadcast per burst. Before, the first burst dealt 500. Night 2: melee from 6 studs with 3 hit reports gave 1 stun, from 20 studs 0. A spray from 8 studs still stuns. 31 alternating `EquipItem` calls ended holding the plunger when the last asked for it and empty-handed otherwise. No new errors; the HUD error is old (G9).
- **Note for balance:** the plunger now deals a flat 20 when facing the boss (an earlier iteration; it used to be 3, or 30 during a spray stagger). With the cooldown that is a 2.5 s kill at best. Left as designed.
- **Next:** G8 hand test, then V4 (user request), G7.

### 2026-10-19: client remote audit (S2), after a review rejection
- **What:** a reviewer rejected S1 because `PlayerDamaged.OnServerEvent` (SurvivalManager) let any client damage or heal any player during Night 2, and the S2 list missed it. Audited all 14 client-to-server remotes instead of the three named:
  - SurvivalManager handles no client remotes now. Removed `PlayerDamaged`, `HidingStateChanged`, `DeodorantSpray` and `PanelRepaired` handlers and their dead code (an ammo mirror that was never filled, a duplicate hiding system). Hiding immunity reads `Player.Hiding`.
  - Hiding: InteractionManager (the prompt) sets the server-only `Hiding` player attribute; NGMIController reads it instead of trusting `HidingStateChanged(true)`. Side effect: NGMIs now respect real hiding, which they never did (the legit client only ever sent `{hiding = false}` tables).
  - `DeodorantSpray` (NGMIController): a hit counts only against a spray InventoryManager confirmed on `WeaponUsed`, once, within 2 s and 30 studs.
  - `PanelRepaired` (PowerManager): only for the panel InteractionManager opened the puzzle on (new `PanelPuzzleOpened` bus), once, after 1.5 s, within 16 studs. It now fixes that exact panel instead of the nearest one.
  - CodingGameServer: removed client-reachable `SabotageEvent` and `PanelRepaired` handlers (any client could block or unblock everyone's coding).
  - Day 1 "Meet the staff": ProgressionManager counts NPCManager's new `NPCTalked` bus (fired after its dialogue-state check) instead of any npcId a client names.
  - Removed empty client-reachable listeners (NPCManager x2); left one deliberate drain each for `GameStateChanged` and `HidingStateChanged`.
- **Verified:**
  - selene: 0 warnings in all 8 touched server files (were 6, 3, 1, 1, 1, 4, 0, 1). Total 232 to 215. Fixed the forward-declared globals (`handlePlayerDeath`, `evaluateEndings`) as locals.
  - Play, Night 2: `PlayerDamaged` x6 (plus and minus 50) gave no damage events and no health change. `HidingStateChanged(true)` left `Hiding` nil. `DeodorantSpray` x8 with no spray: 0 stuns, NGMI still there. Forged `SabotageEvent` did nothing.
  - Real spray at 8 studs with 3 hit reports: exactly 1 stun. Spray at 60 studs: confirmed on `WeaponUsed`, hit rejected.
  - Panel: forged `PanelRepaired` with no puzzle open did nothing. After a puzzle session (bus driven directly, see 3.6): repaired. Replay on the next panel and a report from 60 studs: rejected.
  - Day 1: 5 spoofed npcIds left "Meet the staff (0/2)"; an `NPCTalked` from the server made it 1/2.
  - No script errors (40 sound `DnsResolve` failures from a network drop). Studio left in Edit; Rojo confirmed live.
- **Not verified:** the prompt-driven halves (hide, open a panel, talk to an NPC) because prompts could not be pressed this session. Logged as G8.
- **Found:** G5 (minigame payload mismatch), G6 (sabotage repair never worked), G7 (no `requestLobby` handler), C4 (dead `blocked` state). Recorded the user's NPC density request as V4 with a seat survey.
- **Next:** G8 by hand or when prompts work, then V4 (user request), G7, G2.

### 2026-10-19: boss damage exploit closed (S1)
- **What:** removed `QuestUpdate.OnServerEvent` in QuestManager (any client could fire `attack_monster` for 20 boss damage, no checks). No client ever sent it; real hits already come through InventoryManager's `WeaponUsed` bus, which checks the item, ammo and range. Also removed the empty `GameStateChanged.OnServerEvent` listener and fixed the file's other selene warnings (unused locals, one multi-statement line).
- **Why:** P1 exploit, same class as the old `pickup_chair` remote.
- **Verified:**
  - selene: QuestManager 6 warnings to 0.
  - Play session, Day 2, standing 6 studs from the boss: 10 `attack_monster` fires left its health at 1.00 (would have killed it before). One real deodorant spray through `UseItem` took it to 0.95 (5 damage, as designed).
  - No console errors. Studio left in Edit.
- **Tooling:** after the overnight Windows Update reboot, Studio reopened from AutoRecovery and `rojo serve` was down. Added `scripts/sync-to-studio.py` (pushes `src/` sources into Studio when Rojo is not connected) and made `studio-mcp.py` wait for Studio to reconnect, accept `STUDIO_ID`, and run several Luau files per connection. See 3.6.
- **Next:** S2 (audit the remaining client remotes), then G2.

### 2026-10-19: Chair Hoarder quest made playable (G1)
- **What:**
  - New `Venue/QuestChairs`: 4 folding chairs on level 0 (player lab plus 3 random non-restroom rooms). Each lands on free floor found by an AABB test against the room's parts, away from doors.
  - Remodelled the chair: the old one had legs poking through a floating seat.
  - InteractionManager hides the whole chair on pickup and fires `ServerComm.QuestItemCollected`. Collected prompts stay off across phase changes, and DAY1 (new match) restores all chairs.
  - QuestManager counts pickups from that bus and grants 2 energy bars through `GrantItem`. It also resets the quest on DAY1 and sends an ObjectivesUI label.
  - Dropped the client-trusted `pickup_chair` remote.
  - Added a Day 2 bonus objective "Bonus: hoard folding chairs (n/4)". Chairs are collectible from Day 2 on (was Day 1), matching the bonus row.
  - QuestUI drops reset quests.
- **Why:** the reward TODO hid a dead quest. No client sent `pickup_chair`, and the venue built 1 chair for a target of 4. The user picked 4 shared chairs (a race).
- **Verified:**
  - selene: 0 warnings in the new and venue files; total unchanged at 238.
  - Two Play sessions. Teleported to each chair and pressed E through `user_keyboard_input`: progress 1/4 to 4/4, QUEST COMPLETE toast, hotbar Energy Bar x2.
  - The DAY1 reset restored chairs and quest; DAY2 re-enabled the prompts.
  - Screenshots of the chair, the objective row and the completion state.
  - z-fight detector at 13 (none from chairs). No new console errors.
  - Studio left in Edit with no leftovers.
- **Also:** added `scripts/studio-mcp.py` (Studio bridge when the MCP isn't loaded) and the no-questions protocol note.
- **Next:** S1 (boss damage remote, same exploit class), then G2. U1 and L1 are small.

### 2026-10-19: NPC gaits, leaners, desk laptops, opening camera
- **What:**
  - Opening cinematic's first and last shots now stay under the auditorium ceiling (last crane ended at y 21 inside the slab).
  - Talkable NPCs: walk playback scaled to ground speed (was ~3x too fast), velocity-driven walk/idle with hysteresis plus a `WalkIntent` early start, pathfinding strolls instead of straight-line MoveTo into walls, and a per-NPC pace and pause rhythm.
  - Desk laptops face their user (were rotated 180 degrees).
  - Hallway leaners stand tipped back against a real wall, skipping spots blocked by furniture.
  - All ambient poses go through RigPose; the old C0 edits never applied.
- **Why:** user reports (camera clipping, unnatural gaits, laptops facing away, leaners sitting on the floor away from the wall).
- **Verified:** final crane at y 12.4 under the panels. Client-side sampling: 226 moving samples, walk dominant in all of them. Screenshots of a desk worker and a leaner. No errors.
- **Next:** V2 (sleeper poses), maybe more leaner variety (one foot up on the wall).

### 2026-10-19: venue rebuild and z-fight cleanup
- **What:**
  - The 2,700-line MapBuilder became `server/Venue/` modules.
  - New look throughout: suspended ceilings, two-tone walls with trim, door casings and leaves, glazed partitions, a new furniture set, Hack Hall (L1) and Library (L2), a front entrance, and the stairwell, elevator, auditorium and exterior dressing.
  - Fixed coplanar faces venue-wide: visible overlaps went from 13,306 to 12.
- **Why:** user asked for better models and layout, then reported flickering corners and doorposts.
- **Verified:** Play sessions through the opening, Day 2 and Night 2 (NGMIs path through doors), all gameplay tags present, the coplanar-face detector, screenshots.
- **Next:** G3, G4, V1, F1.
