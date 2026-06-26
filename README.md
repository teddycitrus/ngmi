# 🔴 CODE RED: The Hackathon Horror

> A multiplayer psychological-horror survival game for Roblox. Code your project through the day — survive the night when the venue corrupts and your fellow hackers turn into NGMIs.

---

## About The Project

CODE RED is a co-op Roblox horror game built with Luau and synced to Studio via Rojo. Up to four players queue into a private match server and live out a doomed hackathon: explore the venue and meet the organizers by day, grind out your project at coding terminals, then fight to survive once the building — and everyone in it — starts to fall apart.

A match runs through five phases on a shared, server-authoritative clock. Halfway through Day 2 the **corruption** sets in: the lighting warps, the audio distorts, and the NPC hackers around you begin mutating into NGMIs ("Not Gonna Make It"). By Night 2 the game drops into first-person survival horror, and your ending is decided by whether you make it out — and how much of your project you actually finished.

**Core capabilities:**

- Matchmaking for 1 / 2 / 4-player co-op via reserved match servers (lobby ↔ match-server teleport split)
- Five-phase match loop — Lobby → Day 1 → Day 2 → Night 2 → Day 3 — on a synced day/night clock
- Third-person exploration by day; first-person survival horror at night
- Day 2 **corruption system**: at the halfway mark the venue warps and NPC hackers mutate into NGMIs
- Coding minigame at terminals — your completion % drives which ending you get
- Scavenging & inventory: energy bars (refill sprint), deodorant (throw off NGMIs), flashlight batteries
- Stamina-based sprint, battery-powered flashlight, electrical-panel puzzles, power management, and side quests
- Narrative cutscenes: opening ceremony, the Day 1 → Day 2 sleep transition, the **Day 2 → Night 2 corruption sequence**, and branching **Bad / True** endings

---

## Built With

[![Roblox](https://img.shields.io/badge/Roblox-000000?style=for-the-badge&logo=roblox&logoColor=white)](https://www.roblox.com/)
[![Luau](https://img.shields.io/badge/Luau-00A2FF?style=for-the-badge&logo=lua&logoColor=white)](https://luau.org/)
[![Rojo](https://img.shields.io/badge/Rojo-D14836?style=for-the-badge&logoColor=white)](https://rojo.space/)
[![Rokit](https://img.shields.io/badge/Rokit-4B32C3?style=for-the-badge&logoColor=white)](https://github.com/rojo-rbx/rokit)
[![Selene](https://img.shields.io/badge/Selene-1E5A8E?style=for-the-badge&logoColor=white)](https://kampfkarren.github.io/selene/)
[![StyLua](https://img.shields.io/badge/StyLua-2C2C2C?style=for-the-badge&logoColor=white)](https://github.com/JohnnyMorganz/StyLua)

---

## Getting Started

### Prerequisites

- [Roblox Studio](https://create.roblox.com/) with the [Rojo plugin](https://rojo.space/docs/v7/getting-started/installation/) installed
- [Rokit](https://github.com/rojo-rbx/rokit) — the toolchain manager. It installs the exact tool versions pinned in `rokit.toml` (Rojo 7.4.4, Selene, StyLua).

### Installation

```sh
git clone https://github.com/<your-username>/code-red-hackathon-horror.git
cd code-red-hackathon-horror

# Install the pinned toolchain (Rojo, Selene, StyLua)
rokit install

# Start the Rojo server, then click "Connect" in the Rojo Studio plugin
rojo serve
```

To produce a standalone place file instead of live-syncing:

```sh
rojo build -o CodeRed.rbxl
```

### Project Structure

```
src/
├── server/   → ServerScriptService  (game state, AI, matchmaking, world build)
├── client/   → StarterPlayerScripts  (camera, UI, input, VFX)
├── shared/   → ReplicatedStorage     (configs, item/NPC definitions, utils)
└── gui/      → StarterGui            (HUD, menus)
```

---

## Usage

### Controls

| Input | Action |
|---|---|
| `WASD` + Mouse | Move and look |
| `Left Shift` (hold) | Sprint — drains your energy bar |
| `Space` | Jump |
| `E` | Interact — talk to NPCs, pick up items, use terminals |
| `1` – `4` | Select inventory slot |
| `Q` | Drop the held item |
| `F` | Toggle flashlight (Night 2) |
| `Esc` | Close the active panel / puzzle |

> Dev/admin builds expose a free-cam and admin panel on `V`.

### Match Flow

1. **Lobby** — queue for a 1 / 2 / 4-player match.
2. **Day 1** *(3 min)* — opening ceremony, meet the NPCs, find your desk, learn the venue.
3. **Day 2** *(10 min)* — code at your terminal and scavenge supplies; **corruption begins at the 5-minute mark**.
4. **Night 2** *(15 min)* — first-person survival horror against the NGMIs: keep the power on, repair server racks, stay lit, stay hidden.
5. **Day 3** — an ending cutscene determined by your survival **and** project completion (Bad Ending < 100% · True Ending = 100%).

---

## Roadmap

- [x] Matchmaking with reserved match servers (1 / 2 / 4-player)
- [x] Five-phase match loop with a synced, server-authoritative day/night clock
- [x] Day 2 corruption system — NPC hackers mutate into NGMIs
- [x] Narrative cutscenes including the Day 2 → Night 2 transition and branching Bad / True endings
- [x] First-person Night 2 survival — flashlight, power management, server-rack repair
- [ ] Polish the NGMI transformation poses (forearm articulation in the corruption cutscene)
- [ ] Per-player settings & accessibility options
- [ ] Additional endings and post–Night 2 content

---

## Contributing

Contributions are welcome. To contribute:

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Commit your changes (`git commit -m 'Add your feature'`)
4. Push to the branch (`git push origin feature/your-feature`)
5. Open a Pull Request

Please run `selene src` and `stylua src` before opening a PR so changes stay lint-clean and consistently formatted.

---

## License

No `LICENSE` file is present yet. Add one (e.g. MIT) to declare how others may use this code.

---

## Contact

`<your-name>` — `<your-github-username>`

Project: `https://github.com/<your-username>/code-red-hackathon-horror`

---

## Acknowledgments

- [Rojo](https://rojo.space/) — filesystem ↔ Roblox Studio sync
- [Rokit](https://github.com/rojo-rbx/rokit) — toolchain version management
- [Selene](https://kampfkarren.github.io/selene/) & [StyLua](https://github.com/JohnnyMorganz/StyLua) — Luau linting & formatting
- [Img Shields](https://shields.io) — badges
