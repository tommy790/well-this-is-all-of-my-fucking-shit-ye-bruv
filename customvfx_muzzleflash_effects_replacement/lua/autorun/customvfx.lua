-- CustomVFX: particle registration + shared muzzle core loader.
-- The muzzleflash logic lives in ac_shared/ac_muzzle_core.lua (identical copy
-- shipped by MysterAC Particle Enhancer; the version gate picks one).

AddCSLuaFile()
AddCSLuaFile("ac_shared/ac_muzzle_core.lua")

CustomVFX = CustomVFX or {}

CustomVFX.ParticleFiles = {
    "particles/ac_mw_handguns.pcf",
    "particles/ar2_flash.pcf",
    "particles/procharge.pcf",
    "particles/pulsepistol.pcf",
    "particles/rpg.pcf",
}

for _, path in ipairs(CustomVFX.ParticleFiles) do
    game.AddParticles(path)
end

-- Legacy EZ2 weapon pack cvars (the pack's SWEPs read them).
if SERVER then
    CreateConVar("ez2weps_extraammo", "0", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY), "EZ2 weapons: give extra reserve ammo", 0, 1)
    CreateConVar("ez2weps_extraar2protoballs", "0", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY), "EZ2 weapons: extra AR2 prototype balls", 0, 1)
end

include("ac_shared/ac_muzzle_core.lua")
