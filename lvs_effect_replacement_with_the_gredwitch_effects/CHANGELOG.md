# LVS Gredwitch Effects — Changelog

## Update: "Right Barrel, Every Time"

Muzzle flashes and smoke now land on the correct gun on every vehicle,
including while driving fast and with the turret turned.

**Fixed**
- Fixed muzzle flash and smoke appearing on the wrong part of the vehicle (wheels, hull, suspension) when the gun was aimed down or close to the hull.
- Fixed flashes attaching to the wrong barrel while the vehicle is moving fast with the turret turned.
- Fixed the flash appearing between the barrels on multi-barrel guns (Flakpanzer 341) when the gun has no per-barrel attachment; it now appears on the barrel that fired.
- Fixed vehicles with two guns on one turret (for example BMD-4M) mixing up which barrel the flash appears on.
- Fixed a wrong barrel getting "stuck": once the addon picked a wrong spot at a given turret angle, it kept using it for every following shot.
- Fixed the smoke canister (defence smoke) effect not showing — it now uses LVS's own smoke.
- Fixed effects sometimes being created twice per shot after a Lua reload.
- Fixed fire, ammo-rack and trail effects being restarted every frame instead of once.

**Changed**
- Cannon barrel smoke now plays in two stages: the sharp white burst first, and the lingering smoke only starts once the burst has finished. No more overlapping clouds.
- Attachment detection is now checked against a still copy of the vehicle instead of the moving one, so vehicle speed no longer affects where effects appear.
- Tracer path calculation on the server is lighter (half the trace work per machine-gun round).

**Added**
- Each gun on a vehicle remembers which barrel point it uses after its first shot, so a recoiling barrel or a turning turret can't make later shots jump to a different spot.
- Debug output now shows the real attachment name and how far it was from the shot, making problems easy to report.

**Removed**
- Removed the old "remembered barrel position" shortcut that caused stuck wrong barrels.
- Removed the replacement smoke canister effect (LVS's own is used instead).
