-- MysterAC Explosion Enhancer
-- Ships particles/ac_explosions.pcf and loads the shared explosion core.

AddCSLuaFile()
AddCSLuaFile("ac_shared/ac_explosions_core.lua")

game.AddParticles("particles/ac_explosions.pcf")

include("ac_shared/ac_explosions_core.lua")
