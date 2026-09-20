# Addon rewrite notes

Order of work: smallest/simplest → largest. Each section lists what the addon does,
what was preserved, what was fixed/replaced, and compatibility notes. All rewritten
files are complete in the tree; syntax-checked with LuaJIT (`lupa`), 69/69 plain Lua
files parse (the Expression 2 `e2function` file is E2 syntax, not Lua, and is expected
to fail a Lua parser).

---

## 1. npc_omniscience (`lua/autorun/npc_omniscience.lua`)

**Does:** makes NPCs aware of every player (no line-of-sight requirement).

**Preserved:** convar names, single-file autorun layout, behaviour toward all NPC classes.

**Fixed:** ran on both realms although it only touches the server; iterated every
NPC every Think. Now server-only, uses a slow timer over `ents.FindByClass("npc_*")`
with validity checks, and updates relationships/enemy memory only when they change.

---

## 2. mysterac_explosion_enhancer_fix

**Does:** replaces HL2 explosion/grenade/RPG/AR2 effects with `particles/ac_explosions.pcf`.

**Preserved:** particle names (`AC_grenade`, `AC_rpg`, `AC_ar2`), convars, PCF asset.

**Fixed/replaced:** `env`+`precache` split files merged into a shared core,
`lua/ac_shared/ac_explosions_core.lua` (`AC_Explosions`, Version 3), included by
`autorun/ac_explosions_enhancer.lua`. Correct `AddCSLuaFile`/`include`, precache in
the right realm, no double-hooking on reload, no per-frame work.

**Compat:** the same core file (identical bytes) ships in the particle enhancer; whichever
loads first wins by version check, so both addons installed together do not fight.

---

## 3. mysterac_particle_enhancer_v2 (muzzle flash replacement)

**Does:** replaces muzzle flashes on (almost) any weapon with the `ac_enhancer.pcf`
particles, plus impact particles, plus the explosion set above.

**Preserved:** all particle names, convars (`cl_ac_muzzleflash_disabled` etc.), tool
menu entry and configurator command, per-weapon override list.

**Fixed/replaced:** `ac_particles_remade.lua` and `server_impact_enabler.lua` removed;
logic moved to `lua/ac_shared/ac_muzzle_core.lua` (`AC_Muzzle`, Version 3): owns the
`MuzzleFlash` patch, `FireAnimationEvent` suppression, nets `AC_MuzzleShot`,
`MuzzleReplacer_SyncPCF`, `MuzzleReplacer_SyncParticleName`, and cvars
`cl_ac_muzzleflash_disabled` / `ac_muzzle_profile` / `ac_muzzle_net_enabled`.
`autorun/ac_muzzleflash_override.lua` just registers profile `"ac_enhancer"`.
Impact enabler is client-only (`autorun/client/client_impact_enabler.lua`). Net traffic
is rate-limited per weapon and skipped for the local shooter's own prediction.

---

## 4. war_thunder_style_kill_and_hit_effects (`lua/autorun/wt_hitmarkers.lua`)

**Preserved:** hit/kill/crit sounds and HUD markers, convars, net message names.

**Fixed:** server sent a net message for every bullet including 0-damage; client leaked
HUD timers and drew with `surface` calls each frame even with no markers active.
Now damage-gated, one net per victim per tick, client keeps a small marker list and
returns early when empty. Sounds precached on both realms.

---

## 5. juniez_models_with_modern_warfare_2019_animations

**Preserved:** four `hl2mmod_*` scripts (settings, soundevents, particles, animations),
all convars, weapon model overrides, animation event mapping.

**Fixed/removed:** `runcommand.lua` (a generic `RunConsoleCommand` relay exploitable by
clients) removed. Scripts now use `AddCSLuaFile` properly, hook names are unique,
particle/sound precache lists are built from actual `strings` scans of the shipped
models/PCFs. Known upstream asset gap (documented, not fabricated): the crossbow scope
material `vgui/scopes/hl2mmod_scopes_crossbow` is not in the addon; the code falls
back to the stock crossbow lens.

---

## 6. lvs_effect_replacement_with_the_gredwitch_effects

**Preserved:** full module layout under `lua/lvs_gred_fx/`, all overrides, debug cvars.

**Fixed:** modules re-included and re-patched `LVS.FireBullet` on every autorefresh,
stacking wrappers; particle systems used after being freed (crash on map change). Added
`LVS_GRED_FX.PsysValid` (owned by `particles.lua`) and guarded the client override and
`sv_tracer` with it; patching is now idempotent via a marker on the original function.

**Dependencies:** requires `LVS` and Gredwitch's `gred` global (unchanged).

---

## 7. customvfx_muzzleflash_effects_replacement

**Preserved:** MW-style handgun flashes, AR2/pulse pistol/RPG/procharge PCFs, EZ2
weapon console commands, `ez2_grenade` and `ez2_slam_tripmine` entities and spawn icons.

**Fixed/replaced:** its own muzzle patcher duplicated (and conflicted with) the particle
enhancer's; it now ships the same `ac_shared/ac_muzzle_core.lua` and registers profile
`"customvfx"` through `AC_Muzzle.RegisterProfile`. `ez2slamdetonator.lua` (a broken
shared-realm SWEP fragment) removed; the SLAM detonator behaviour lives in the tripmine
entity's `init.lua`. Grenade entity got proper `shared/cl_init/init` realm split,
physics-based bounce and fuse, and cleanup on removal.

**Compat:** when both this addon and the particle enhancer are installed, the active
profile is chosen by `ac_muzzle_profile`; both tool menus open the same configurator.

---

## 8. jeep_jalopy_interceptor (TIV) — deploy / anchor / loft rewrite

**Does:** turns the Jalopy into a tornado-intercept vehicle: spikes drive into the
ground, the chassis is pulled down, the vehicle rides out the storm anchored, and lofts
when the anchors fail. Wire/E2 interface, HUD, instruments, editor, customization,
progression are untouched.

**Files rewritten:** `tiv/anchor/sv_anchor.lua`, `tiv/animation/sv_spike_anim.lua`,
`tiv/deploy/sv_deploy.lua`; `tiv/loft/sv_loft.lua` patched in place.

**Preserved:** every public `TIV.Deploy/Anchor/Spikes/SpikeAnim/Loft` function name
(verified by grepping every reference in the repo against definitions), state names
(`idle`, `deploying_spikes`, `lowering`, `anchored`, `retracting`, `raising`, `lofted`),
nets (`TIV_DeployRequest`, `TIV_DeployStatus`, `TIV_SpikeAnim*`, `TIV_LoftEvent`,
`TIV_AnchorWarning`), hooks (`TIV_StateChanged`, `TIV_VehicleRemoved`,
`TIV_SpikeFailure`, `TIV_LoftEvent`), timer names other modules cancel
(`TIV_Lower_<idx>`, `TIV_Raise_<idx>`, `TIV_WaveFail_<idx>_n`), all convars, and the
`data` fields other modules read (`state`, `spikes`, `constraints`, `spikeAnims`,
`anchored`, `spikesCreated`, `sessionID`, `plantedPos`, `handbrakeOn`, ...).

**Replaced (why):**
- Lowering used to `SetPos`-lerp the chassis every tick with motion frozen, which is
  the fake-movement approach that produced the jitter/teleport instability. Now the
  chassis is never frozen or moved by code. Lowering is `constraint.Elastic` veh→spike
  per spike whose rest length is shortened over `LowerTime` (`data.pullDown`), so the
  suspension actually compresses under a physical pull.
- Anchored state is an `AdvBallsocket` per spike limited to ±`AnchorPivotLimit`
  (28°) with `BallSocketForceLimit`; zero-spike mode uses a world ballsocket
  (`isWorldAnchor`). Storm forces act on a real constrained body, so failure
  thresholds and loft impulses behave consistently.
- Spikes are parented pistons during strokes (`COLLISION_GROUP_IN_VEHICLE`); once
  planted they become static (motion off, `COLLISION_GROUP_WORLD`, NoCollide to the
  vehicle) at drive depth — a static plant does not need per-tick re-positioning.
- Constraint entries are `{constraint, type = "ballsocket"|"nocollide"|"elastic",
  spikeIndex, spikeTableIndex, ...}`. The old `"anchor_ballsocket"` type is gone;
  `sv_instruments`, `sv_freeze_audit`, `sv_wire` already only test `"ballsocket"`.
- `ReleaseHold` (new) drops ballsockets+elastics before the pistons withdraw so the
  suspension rebounds physically during retract.

**Loft fixes:** `return` inside the per-spike loop aborted integrity checking for the
whole vehicle after the first spike; the per-tick `SetPos` "re-plant" of drifting spikes
is gone (spikes are static); `constraint.RemoveAll(veh)` on loft deleted the player's
own welds — now only TIV's constraints are removed; wave partitioning dropped spikes
beyond six, leaving anchors that could never fail — every spike is now assigned to a
wave; loft tumble torque is mass-scaled; the redundant per-frame `Think` cleanup hook
was folded into the 0.05s loft timer.

**Compat considerations:** `sv_wire` emergency release, `sv_freeze_audit` watchdog,
`sv_custom_components` armor NoCollides and `E2 tiv.lua` were checked against the new
fields and all work unchanged. `SpikeAnim.CancelVehicleJobs` is now exported for them.

---

## Repository-wide consistency pass

- Shared cores: `ac_explosions_core.lua` identical (md5 `938a116f…`) in both explosion
  addons; `ac_muzzle_core.lua` identical (md5 `033251f1…`) in particle enhancer and
  customvfx. Each guards on `Version` so the newest wins regardless of load order.
- Known particle-name overlaps (`AC_grenade/rpg/ar2` in two PCFs, `AC_muzzle_357/pistol`
  in two PCFs) are the same effects in both packs; the engine keeps whichever PCF loads
  first, which is harmless because the definitions match.
- All addons use `AddCSLuaFile` + `include` with realm-correct paths; no `autorun`
  file runs server logic on the client or vice versa.
