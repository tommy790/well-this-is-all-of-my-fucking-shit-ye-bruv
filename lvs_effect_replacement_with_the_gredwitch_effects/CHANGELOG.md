# LVS Gredwitch Effects — Changelog

## Update: "Right Barrel, Every Time"

Muzzle flashes and smoke now land on the correct gun on every vehicle,
including while driving fast and with the turret turned.

**Fixed**
- Fixed muzzle flash and smoke appearing on the wrong part of the vehicle (wheels, hull, suspension) when the gun was aimed down or close to the hull.
- Fixed flashes attaching to the wrong barrel while the vehicle is moving fast with the turret turned.
- Fixed vehicles with two guns on one turret (for example BMD-4M) mixing up which barrel the flash appears on.
- Fixed a wrong barrel getting "stuck": once the addon picked a wrong spot at a given turret angle, it kept using it for every following shot.
- Fixed ammo rack fire flickering out after two seconds while the rack is still burning — it now burns as one steady fire until LVS puts it out.
- Fixed heavy frame drops when driving on water — the spray no longer starts a new effect every tick for every wheel.
- Fixed effects sometimes being created twice per shot after a Lua reload.
- Fixed fire, ammo-rack and trail effects being restarted every frame instead of once.

**Changed**
- Tracers now fly with the actual LVS round: the Gredwitch tracer streak is drawn on LVS's own bullet, so it drops with gravity on ballistic guns and travels at the weapon's real projectile speed instead of gred's fixed speed in a straight line. Colour, width, trail length and material are the ones from Gredwitch's tracer particles. Players without this addon still receive the plain straight gred beam from the server.
- Which barrel a gun fires from is now read from the vehicle's own LVS weapon setup: the attachment named in the weapon's fire code is used when the shot really leaves from it, and multi-barrel guns (`"muzzle_" .. n`) are narrowed down by the line of fire. Twin and quad mounts whose code names one shared point and offsets each barrel from it are detected and resolved to the actual barrel instead of all flashing from that one point.
- Smoke canisters now use the Gredwitch smoke cloud, refreshed every 3 seconds while the canister is active so it never piles up or lingers after it's spent.
- Barrel detection now follows the line of fire: the barrel point that lies along the direction the shot went is chosen, instead of whichever point is simply nearest. Recoiled barrels, side-by-side barrels and sights next to the gun no longer confuse it.
- Cannon barrel smoke now plays in two stages: the sharp white burst first, and the lingering smoke only starts once the burst has finished. No more overlapping clouds.
- Attachment detection is now checked against a still copy of the vehicle instead of the moving one, so vehicle speed no longer affects where effects appear.
- Tracer path calculation on the server is lighter (half the trace work per machine-gun round).

**Added**
- Each gun on a vehicle remembers which barrel point it uses after its first shot, so a recoiling barrel or a turning turret can't make later shots jump to a different spot.
- Debug output now shows the real attachment name and how far it was from the shot, making problems easy to report.

**Removed**
- Removed the old "remembered barrel position" shortcut that caused stuck wrong barrels.
