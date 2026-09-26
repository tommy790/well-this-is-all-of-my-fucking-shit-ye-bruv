-- MysterAC Particle Enhancer V2
-- Registers the shipped particle files and loads the shared AC cores
-- (explosions + muzzleflash). The cores are version-guarded so they can be
-- shipped by more than one addon.

AddCSLuaFile()
AddCSLuaFile("ac_shared/ac_explosions_core.lua")
AddCSLuaFile("ac_shared/ac_muzzle_core.lua")

game.AddParticles("particles/ac_enhancer.pcf")
game.AddParticles("particles/impacts_fx.pcf")
game.AddParticles("particles/burning_fx.pcf")
game.AddParticles("particles/blood_impact.pcf")

if CLIENT then
    for _, name in ipairs({
        "impact_concrete", "impact_metal", "impact_computer", "impact_dirt",
        "impact_wood", "impact_glass", "impact_antlion",
    }) do
        PrecacheParticleSystem(name)
    end
end

include("ac_shared/ac_explosions_core.lua")
include("ac_shared/ac_muzzle_core.lua")
