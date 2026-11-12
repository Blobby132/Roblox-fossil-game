# Fossil Expedition Simulator

A Roblox simulator about digging up fossils. This folder is the game's source code. [Rojo](https://rojo.space) copies it into Roblox Studio.

**Current state: Milestone 1 (digging feel).** You get your own dig plot, a pickaxe and a brush, and fossils to uncover. There is no extraction minigame, inventory, museum, money, upgrades or saving yet.

## Fastest way to try it (no installs)

1. Open `FossilExpedition.rbxlx` in Roblox Studio (double-click it, or **File → Open from File**).
2. Press **Play** (F5).

That file is a ready-built copy of this code. Use it for a first look. To change config values and see them in Studio, do the one-time setup below.

## One-time setup (about 10 minutes)

You need Roblox Studio installed, and a terminal: **PowerShell** on Windows, **Terminal** on macOS.

### 1. Install Rokit

Rokit downloads the exact tool versions this project uses (they are listed in `rokit.toml`).

Windows (PowerShell):

```powershell
Invoke-RestMethod https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.ps1 | Invoke-Expression
```

macOS or Linux:

```bash
curl -sSf https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.sh | bash
```

Close the terminal and open a new one, so it can find the `rokit` command.

### 2. Install the project's tools

In the terminal, go to this folder (the one containing `rokit.toml`), then run:

```bash
rokit install
```

Rokit asks whether you trust each tool the first time. Answer `y`. This installs Rojo, Wally, StyLua, Selene and Lune.

### 3. Install the Rojo plugin into Studio

Close Roblox Studio first, then run:

```bash
rojo plugin install
```

This puts a **Rojo** button in Studio's **Plugins** tab. It matches the Rojo version in `rokit.toml`.

## Everyday workflow

1. In the terminal, in this folder, start the sync server and leave it running:

   ```bash
   rojo serve
   ```

2. Open `FossilExpedition.rbxlx` in Studio.
3. In Studio: **Plugins** tab → **Rojo** → **Connect**. The panel should say it is connected to `FossilExpeditionSimulator`.
4. Edit files in `src/` with any editor. Studio updates as you save.
5. Press **Play** to test. Config values are read when the game starts, so after changing one, press **Stop** and **Play** again.

Things to know:

- **Edit code in this folder, not inside Studio.** Rojo copies from the folder into Studio, not back. Script edits made in Studio are overwritten.
- `FossilExpedition.rbxlx` only holds what the code builds, so you can recreate it at any time:

  ```bash
  rojo build -o FossilExpedition.rbxlx
  ```

- A brand new **Baseplate** place also works (connect Rojo to it). The dig site is built above the baseplate.
- Nothing in Milestone 1 needs Studio's "API Services" setting, publishing, or any uploaded assets. Saving (Milestone 4) will need **Enable Studio Access to API Services**, which requires publishing the place first.

## Controls

| Action | PC | Phone / tablet |
| --- | --- | --- |
| Swing at a cell | Left click (hold to keep swinging) | Tap the cell |
| Switch tool | `1` Pickaxe, `2` Brush, or `Q` to swap | Tap a tool button |
| Move, jump, camera | Roblox defaults | Roblox defaults |

Developer shortcuts (work for anyone inside Studio, and for the UserIds in `DebugConfig` in a published game):

| Key | What it does |
| --- | --- |
| `R` | Refill and reseed your plot now |
| `X` | Show or hide a marker over every buried fossil |

## How digging works

- **Pickaxe** breaks rock and dirt, but is slow on dirt. It cannot clean a fossil.
- **Brush** clears dirt quickly and cleans fossils. It cannot break rock.
- You can dig any cell that open air touches: the surface, or a cell next to a hole.
- Cells above a buried fossil are paler and cracked. The closer to the fossil, the stronger the hint.
- Breaking a fossil's cell leaves a dirt crust. Brush the crust until the fossil is uncovered.
- When every fossil in the plot is uncovered, the plot refills with new fossils after a few seconds.

## Where to tune things

Everything tunable is in `src/shared/Config/`:

| File | What it controls |
| --- | --- |
| `FeelConfig.luau` | Camera shake, rising pitch, crumble, particles, the fossil reveal moment |
| `SoundConfig.luau` | Every sound effect (placeholders built from Roblox's built-in sounds) |
| `ToolConfig.luau` | Tool cooldown, reach, damage per material, greybox look |
| `MaterialConfig.luau` | Dirt and rock: health and colour |
| `GridConfig.luau` | Grid size, rock per layer, fossils per plot, hints, refill delay |
| `FossilConfig.luau` | The fossils: rarity, how often they appear, brush strokes, greybox shape |
| `RarityConfig.luau` | Rarity names and colours |
| `DigConfig.luau` | Hold-to-swing, and how strict the server is about reach and speed |
| `WorldConfig.luau` | Plot layout, number of plots, jump height, lighting |
| `DebugConfig.luau` | Developer shortcut keys and who may use them |

## Project layout

```
default.project.json   tells Rojo where each folder goes in Studio
rokit.toml             tool versions (Rojo, Wally, StyLua, Selene, Lune)
wally.toml             packages (none yet; ProfileStore arrives in Milestone 4)
src/
  shared/              -> ReplicatedStorage.Shared   (both sides can read it)
    Config/            all tunable numbers
    Dig/               grid maths and dig rules used by server and client
    Remotes.luau       creates every RemoteEvent in code
  server/              -> ServerScriptService.Server (players never receive it)
    Main.server.luau   the only Script; starts the services
    Services/          PlotService, FossilService, ToolService, DigService, DebugService
    Dig/               plot seeding and swing rules (pure logic)
    World/             builds the greybox site
  client/              -> StarterPlayerScripts.Client
    Main.client.luau   the only LocalScript; starts the controllers
    Controllers/       PlotController, ToolController, DigController, FossilController, ...
    Effects/           sound, particles, crumble, camera, cell reactions
    Ui/                interface helpers
tests/                 automated tests that run outside Roblox (see below)
```

The server is in charge. The client only tells it "I swung at cell N". The server checks the request, the player's reach, the tool in hand, the cooldown and the cell, then decides what happened. The client predicts the result so feedback is instant, and corrects itself if the server disagrees.

## Checks

Run these from this folder before sharing a build:

```bash
stylua src tests
```

```bash
selene src
```

```bash
lune run tests/logic
```

```bash
lune run tests/sim
```

- `stylua` formats the code. `selene` looks for mistakes (the first run downloads Roblox's API list).
- `tests/logic` checks the grid maths, plot seeding and dig rules.
- `tests/sim` runs the real server and client code against a stand-in for the Roblox engine and plays a whole session: digging by mouse and touch, the reveal, the refill, and the server refusing bad, far, fast and flooded requests.

The tests prove the code runs and the rules hold. They cannot judge how the game feels; that is what the Studio playtest is for.

## Optional: editor setup

[Visual Studio Code](https://code.visualstudio.com) with these extensions gives autocomplete and inline warnings: **Luau Language Server** (JohnnyMorganz), **StyLua** (JohnnyMorganz), **Selene** (Kampfkarren) and **Rojo - Roblox Studio Sync** (evaera).
