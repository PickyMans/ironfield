# Ironfield

A Total War–style real-time battle game for Roblox. Two armies of about 420 soldiers each fight on generated terrain. You command regiments, not individual soldiers. Every soldier is simulated and has his own hit points. The game models formations, flanking, cavalry charges, braced spears, arrow volleys, morale, routing and rallying.

Every visual is built in code from parts, so the game needs no external assets.

## Quick start (no Rojo)

Open `Ironfield.rbxlx` in Roblox Studio and press **Play**. The battlefield takes a couple of seconds to generate.

## Setup with Rojo

1. Install Rojo 7.4 or newer, either with [Rokit](https://github.com/rojo-rbx/rokit) (`rokit install` reads `rokit.toml`) or the Rojo plugin, and install the Rojo Studio plugin.
2. From this folder run:

   ```bash
   rojo serve
   ```

3. In Roblox Studio, open a **new Baseplate**, click **Connect** in the Rojo plugin, then press **Play**.
4. Recommended place settings (in Studio's Explorer):
   - `Lighting.Technology` should be **ShadowMap** or **Future**. `rojo build` sets it for you. Live sync may not be able to.
   - Delete the default `Baseplate` and `SpawnLocation`. The game generates its own terrain.

You can also build a place file directly with `rojo build -o Ironfield.rbxlx`.

## How to play

| Input | Action |
|---|---|
| WASD / arrows, Shift | Pan the camera (Shift pans faster) |
| Q / E, middle mouse drag | Rotate and tilt the camera |
| Mouse wheel | Zoom |
| Left click / drag | Select one regiment / box-select several (Shift adds or removes) |
| Ctrl+A, 1–0 | Select all regiments / select a regiment by its card |
| Right click ground | Move. A group keeps its shape and turns to face the direction of travel |
| Right click enemy | Attack |
| **Right drag** | Draw a battle line. The selected regiments spread along it. The length you drag sets how wide and deep they stand |
| Double right click | Same order, but running or charging |
| H / R / F | Halt / toggle run / toggle fire at will |
| Double-click a unit card | Move the camera to that regiment |

**Deployment:** before the battle starts you can place your army anywhere inside the outlined zone. Press **Start Battle** when you are ready.

**Multiplayer:** the first player commands the Azure Kingdom. A second player takes the Crimson Host for a player-vs-player battle. Any further players spectate. A side with no player is commanded by the AI.

## Battle mechanics

- **Melee:** each soldier finds an enemy soldier and attacks him. The hit chance depends on attack against defense. Damage is reduced by armor, but armor-piercing damage is not.
- **Flanking:** attacks from the side halve the defender's defense. Attacks from the rear ignore defense entirely and do heavy damage to morale.
- **Charges:** a unit that runs into an enemy gets its charge bonus for a few seconds. Charging cavalry also knock infantry down and back.
- **Spears:** spearmen get a bonus against cavalry. Spearmen standing still punish a cavalry charge that hits them from the front.
- **Archers:** each arrow is simulated. Scatter grows with distance. Shields block arrows that come from the front. Arrows can hit your own men, so by default archers won't fire into a melee that involves your own troops.
- **Morale:** these lower morale:
  - casualties, both overall and recent
  - being flanked
  - being under fire
  - being outnumbered
  - nearby friendly units routing
  - losing your general

  These raise it:
  - the general being nearby
  - enemy units routing nearby

  A unit whose morale breaks routes towards its own edge of the map. It can rally if it is left alone. A unit that routes three times, or that falls below 20% of its men, shatters for good.
- **High ground:** soldiers fighting downhill get an attack bonus.
- **Victory:** you win when every enemy regiment is destroyed, routing, or has fled.

All unit stats and tuning values are in `src/shared/Config.lua`.

## Architecture

```
src/
  shared/            ReplicatedStorage.Shared
    Config.lua       unit stats, factions, army layout, tuning
    Formation.lua    formation geometry, slot assignment, order planner
    Heightmap.lua    deterministic terrain height (used by server and client)
    Codec.lua        binary snapshot / volley encoding (buffer)
    Net.lua          RemoteEvent setup
  server/            ServerScriptService.Server
    init.server.lua  bootstrap + fixed 20 Hz simulation loop
    Battle.lua       lifecycle, tick, replication, command validation
    Regiment.lua     regiment state machine + soldier movement/fighting
    Combat.lua       melee, charge impacts, arrows
    AI.lua           AI commander
    SpatialHash.lua  neighbour queries
    World.lua        terrain, forests, lighting
  client/            StarterPlayerScripts.Client
    init.client.lua  network handlers + render loop
    Renderer.lua     soldier models, interpolation, animation, banners
    SoldierRig.lua   procedural part-built soldiers and horses
    Projectiles.lua  arrow visuals
    CameraController.lua, Commander.lua (input/orders), UI.lua (HUD), State.lua
```

### Design

- **The server owns the simulation.** Soldiers are plain Lua tables on the server, not physics objects or Humanoids. This is what lets hundreds of soldiers run cheaply.
- **Custom replication:**
  - Every 0.1 s the server sends one buffer. It holds a 16-byte header per regiment, plus 7 bytes for each soldier who moved, turned, attacked or died since the last snapshot. Soldiers who are standing still cost nothing.
  - The client interpolates between snapshots.
  - Arrows are sent as tiny volley events and flown on the client purely for looks.
- **Rendering:**
  - Each soldier is a set of anchored, non-colliding parts.
  - All moving parts are updated with a single `workspace:BulkMoveTo` call each frame.
  - Standing soldiers and corpses are skipped.
  - Distant soldiers skip limb animation.
- **Cheating:** clients send only orders. The server checks that the player owns each regiment, validates every number and rate-limits commands.

## Headless tests

`tools/headless.luau` runs the real server code outside Roblox, using [Lune](https://github.com/lune-org/lune) and small stubs for Roblox services. It plays a whole battle and reports the result, the server tick cost and the bandwidth:

```bash
lune run tools/unit.luau                  # formation planner + network codec tests
lune run tools/headless.luau 600 ai       # AI vs AI battle
lune run tools/headless.luau 600 player   # scripted player orders vs AI
lune run tools/headless.luau 0 world      # terrain/scenery generation
FLAT=1 MIRROR=1 lune run tools/headless.luau 600 ai 5   # balance checks: flat map, sides swapped, seed 5
```

On a typical machine a full AI-vs-AI battle with about 840 soldiers costs under 1 ms per 20 Hz server tick. Snapshot traffic averages 20–30 KB/s per player.
