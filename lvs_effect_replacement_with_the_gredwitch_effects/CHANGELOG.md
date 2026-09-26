# LVS Gredwitch Effects — Changelog

## Update: "Right Barrel, Every Time"

Muzzle flashes and smoke now land on the correct gun on every vehicle,
including while driving fast and with the turret turned.

**Fixed**
- Muzzle flash placement is taken from the vehicle's weapon code and nothing else: the code names the attachment a gun fires relative to, and when the shot does not come from that point itself (Flakpanzer 341 and Pz.IV Zerstörer offset each barrel from a shared "aim" point; the BMD-4M fires its 30mm beside its "muzzle"), the flash and barrel smoke are placed at the exact origin the code computed, expressed in that attachment's frame and parented to it. The nearest-attachment style searches only remain for vehicles whose weapon code names no attachment at all.
- Muzzle flash jumping to the cannon while the T-35's turret MG fires on the move: when the weapon code's own attachment narrowly misses the barrel-line test (turret traverse puts the client's attachment a few units from where the server fired), the geometric fallback could hand the shot to a different gun 28 u away. The code's attachment now only loses to a fallback attachment that is clearly closer to the shot (`weapon_code_near`); when the code names a single point, only a muzzle/barrel-named attachment right at the shot origin (a twin/quad mount's real barrel tip) can take it, so a nearer non-barrel attachment such as the BMD-4M's misnamed "sight" never steals the 30mm's flash.
- Muzzle flash landing on the wrong gun while driving (T-35 turret MG flashing from the cannon): the shot origin comes from the vehicle's newest networked transform while the client's attachments trail it by the interpolation delay, so at speed the MG's origin was nearer the cannon muzzle than the MG. The origin is now re-expressed in the interpolated frame before matching; the debug line shows the compensated distance as `motion:`.
- Fixed muzzle flash and smoke appearing on the wrong part of the vehicle (wheels, hull, suspension) when the gun was aimed down or close to the hull.
- Fixed flashes attaching to the wrong barrel while the vehicle is moving fast with the turret turned.
- Fixed vehicles with two guns on one turret (for example BMD-4M) mixing up which barrel the flash appears on.
- Fixed a wrong barrel getting "stuck": once the addon picked a wrong spot at a given turret angle, it kept using it for every following shot.
- Fixed ammo rack fire flickering out after two seconds while the rack is still burning — it now burns as one steady fire until LVS puts it out.
- Fixed heavy frame drops when driving on water — the spray no longer starts a new effect every tick for every wheel.
- Fixed effects sometimes being created twice per shot after a Lua reload.
- Fixed fire, ammo-rack and trail effects being restarted every frame instead of once.

**Changed**
- Tracers are Gredwitch's own tracer particles flying LVS ballistics. The addon ships `particles/lvs_gred_tracers.pcf`, generated from gred's tracer definitions by `tools/pcf_tool.py` (same streak, colours, smoke and glow children); the fixed-speed launcher is replaced by a previous-position remap so the particle leaves at the LVS round's own velocity, with gravity matched to LVS's ballistic flight. Players without this addon still get the straight gred beam from the server, now using the gred definition whose baked-in speed is closest to the round's.
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
