-- CustomVFX Muzzleflash Replacer profile.
-- Registers the CustomVFX particle set with the shared AC muzzle core and
-- keeps the old global tables / command names as aliases.

AddCSLuaFile()

if not AC_Muzzle then
    include("ac_shared/ac_muzzle_core.lua")
end

local CATEGORY = {
    pistol   = "pistol_muzzle",
    revolver = "357_muzzle",
    smg      = "smg1",
    shotgun  = "shotgun_muzzle",
    rifle    = "AC_muzzle_rifle",
    sniper   = "AC_muzzle_desert",
    lmg      = "AC_muzzle_rifle",
    launcher = "hl2mmod_muzzleflash_rpg",
    energy   = "AR2_muzzle",
}

local WEAPON_FIXED = {
    weapon_pistol     = "pistol_muzzle",
    weapon_357        = "357_muzzle",
    weapon_smg1       = "smg1",
    weapon_shotgun    = "shotgun_muzzle",
    weapon_ar2        = "AR2_muzzle",
    weapon_crossbow   = "none",
    weapon_rpg        = "hl2mmod_muzzleflash_rpg",
    weapon_frag       = "none",
    weapon_slam       = "none",
    weapon_physcannon = "none",
}

local WEAPON_ALT = {
    weapon_ar2     = "charge_fire",
    weapon_smg1    = "AC_muzzle_rifle_muzzlesmoke_core",
    weapon_shotgun = "AC_muzzle_shotgun_db",
}

local WEAPON_ALT_SMOKE = {
    weapon_ar2     = "none",
    weapon_smg1    = "AC_muzzle_minigun_smoke_barrel",
    weapon_shotgun = "none",
}

local WEAPON_SMOKE = {
    weapon_pistol     = "AC_muzzle_minigun_smoke_barrel",
    weapon_357        = "AC_muzzle_minigun_smoke_barrel",
    weapon_smg1       = "AC_muzzle_minigun_smoke_barrel",
    weapon_shotgun    = "AC_muzzle_minigun_smoke_barrel",
    weapon_ar2        = "none",
    weapon_crossbow   = "none",
    weapon_rpg        = "none",
    weapon_frag       = "none",
    weapon_slam       = "none",
    weapon_physcannon = "none",
}

local CATEGORY_SMOKE = {
    pistol = "AC_muzzle_minigun_smoke_barrel", revolver = "AC_muzzle_minigun_smoke_barrel",
    smg = "AC_muzzle_minigun_smoke_barrel", rifle = "AC_muzzle_minigun_smoke_barrel",
    lmg = "AC_muzzle_minigun_smoke_barrel", shotgun = "AC_muzzle_minigun_smoke_barrel",
    sniper = "AC_muzzle_minigun_smoke_barrel", energy = "none", launcher = "none",
}

local profile = AC_Muzzle.RegisterProfile({
    id       = "customvfx",
    name     = "CustomVFX Muzzleflash Replacer",
    priority = 20,
    command  = "muzzle_replacer",
    dataFiles = {
        weapon        = "muzzle_config.txt",
        class         = "class_config.txt",
        category      = "category_config.txt",
        pcf           = "pcf_registry.txt",
        settings      = "settings.txt",
        categorySmoke = "category_smoke.txt",
    },
    defaults = {
        category           = CATEGORY,
        weaponFixed        = WEAPON_FIXED,
        alt                = WEAPON_ALT,
        altSmoke           = WEAPON_ALT_SMOKE,
        weaponSmoke        = WEAPON_SMOKE,
        categorySmoke      = CATEGORY_SMOKE,
        smokeParticle      = "AC_muzzle_minigun_smoke_barrel",
        suppressedParticle = "AC_muzzle_pistol_suppressed",
        fallback           = "pistol_muzzle",
        noSmoke            = { AR2_muzzle = true, charge_fire = true, hl2mmod_muzzleflash_rpg = true },
        particles = {
            "pistol_muzzle", "357_muzzle", "smg1", "shotgun_muzzle", "AR2_muzzle", "charge_fire",
            "AC_muzzle_357", "AC_muzzle_desert", "AC_muzzle_pistol", "AC_muzzle_pistol_suppressed",
            "AC_muzzle_rifle", "AC_muzzle_shotgun", "AC_muzzle_shotgun_db", "AC_muzzle_rifle_muzzlesmoke_core",
            "AC_muzzle_minigun_smoke_barrel", "hl2mmod_muzzleflash_rpg", "muzzle_minigun_core",
            "hunter_muzzle_flash", "pulsar_charge", "procharge", "pro2_muzzle", "ar2_muzzle2",
            "muzzlear2blue", "storm_muzzle",
        },
        settings = {
            barrel_smoke_enabled  = true,
            barrel_smoke_mode     = "auto",
            custom_smoke_particle = "",
            smoke_cooldown        = 0.3,
            viewmodel_smoke       = true,
            worldmodel_smoke      = true,
            npc_muzzle_enabled    = true,
            respect_native_muzzle = true,
        },
    },
})

-- Legacy globals other scripts referenced.
HL2_WEAPON_PARTICLES    = WEAPON_FIXED
HL2_WEAPON_ALTPARTICLES = WEAPON_ALT
HL2_WEAPON_ALT_SMOKE    = WEAPON_ALT_SMOKE
HL2_WEAPON_SMOKE        = WEAPON_SMOKE
WEAPON_CATEGORY_SMOKE   = CATEGORY_SMOKE
MUZZLE_CONFIG           = profile.weapon
CLASS_BASED_CONFIG      = profile.class
WEAPON_CATEGORY_CONFIG  = profile.category
MUZZLE_SETTINGS         = profile.settings
CATEGORY_SMOKE_CONFIG   = profile.categorySmoke
PCF_REGISTRY            = profile.pcfFiles

if CLIENT then
    concommand.Add("muzzle_replacer", function()
        AC_Muzzle.OpenConfigurator(profile)
    end)

    hook.Add("PopulateToolMenu", "CustomVFX_MuzzleReplacer_Menu", function()
        spawnmenu.AddToolMenuOption("Options", "Combat", "MuzzleReplacer", "Muzzleflash Replacer", "", "", function(panel)
            panel:ClearControls()
            panel:Help("Replaces weapon muzzleflashes with the CustomVFX particle set.")
            panel:CheckBox("Disable muzzleflash replacement", "cl_ac_muzzleflash_disabled")
            panel:Button("Open Configurator", "muzzle_replacer")
        end)
    end)
end
