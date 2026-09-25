# Jeep & Jalopy Interceptor — Changelog

## Update: "Reworked Deploy & Lofting Mechanics"

The whole deploy, anchor and loft sequence has been rebuilt on real physics.
Nothing teleports or gets frozen in place any more — the vehicle is pulled
down, held and let go by actual forces and constraints.

**Reworked**
- Deploying: the vehicle is pulled down onto its suspension by air springs first, then the spikes drive into the ground, then the anchors lock. Retracting runs the same sequence in reverse, with the suspension coming back up smoothly instead of springing up in one jolt.
- Anchoring: each planted spike now holds the vehicle with a limited pivot joint, so storm forces act on a properly held body and lofting happens when the anchors are actually overloaded.
- Lofting: when the wind wins, the anchors shear off in waves across all spikes, and the vehicle tumbles with force scaled to its weight.

**Added**
- Handbrake and drive lock while deploying, anchored and retracting — you can't drive off half-anchored. The camera toggle still works.
- Deploying with no spikes fitted: the vehicle still lowers and anchors to the ground on its own.
- Physgun-frozen vehicles are respected: deploy is refused while frozen and the addon no longer unfreezes your props.

**Fixed**
- Fixed lowering not happening at all on some setups (the springs were never created).
- Fixed the jeep being pinned to the ground and unable to drive after retracting.
- Fixed spikes being flung out of the ground the moment they were planted.
- Fixed spikes turning into loose props after a physgun freeze/unfreeze.
- Fixed vehicles with more than six spikes having anchors that could never fail.
- Fixed lofting deleting the player's own welds and constraints on the vehicle.
- Fixed the anchor integrity check stopping after the first spike.
- Fixed the vehicle jittering while lowering and raising.

**Removed**
- Removed the per-tick "re-plant" that kept nudging spikes back into position — planted spikes are now static and don't need it.
