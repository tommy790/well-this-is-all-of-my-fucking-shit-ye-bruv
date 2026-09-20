-- Registers the particle files shipped with this addon. Only names that exist
-- in those files are precached (the old list referenced ~150 systems from
-- HL2:MMod files that are not part of this addon).

AddCSLuaFile()

game.AddParticles("particles/hl2mmod_weaponeffects.pcf")
game.AddParticles("particles/hl2mmod_misc.pcf")
game.AddParticles("particles/explosion.pcf")
game.AddParticles("particles/grenade_fx.pcf")
game.AddParticles("particles/grenade_mp5.pcf")

if not CLIENT then return end

for _, name in ipairs({
    "hl2mmod_weapon_crossbow_boltrelease",
    "hl2mmod_weapon_crossbow_bolttrail",
    "hl2mmod_weapon_crossbow_chargespark",
    "hl2mmod_weapon_crossbow_boltidle",
    "hl2mmod_weapons_grenade_trailandblipglow",
    "hl2mmod_weapon_rpg_ignite",
    "hl2mmod_weapon_rpg_smoketrail",
    "hl2mmod_weapon_smg_grenadetrail",
    "hl2mmod_weapon_ar3_overheat_lvl5",
    "hl2mmod_impact_ar2_1",
    "hl2mmod_misc_temp_shellexhaust",
    "hl2mmod_misc_temp_breakabletrail_concrete",
    "hl2mmod_misc_temp_breakabletrail_wood",
    "grenade_explosion_01",
    "grenade_mp5_trail",
}) do
    PrecacheParticleSystem(name)
end
