-- MysterAC muzzleflash profile ("AC Muzzleflash Replacer").
-- The detection/spawn machinery lives in ac_shared/ac_muzzle_core.lua; this
-- file only registers the AC particle set, its data files, its console command
-- and the legacy globals other scripts may reference.

AddCSLuaFile()

if not AC_Muzzle then
    include("ac_shared/ac_muzzle_core.lua")
end

local DEFAULT_CATEGORY = {
    pistol   = "AC_muzzle_pistol",
    revolver = "AC_muzzle_357",
    smg      = "AC_muzzle_smg",
    shotgun  = "AC_muzzle_shotgun",
    rifle    = "AC_muzzle_ar2",
    sniper   = "AC_muzzle_357",
    lmg      = "AC_muzzle_ar2",
    launcher = "AC_muzzle_shotgun",
    energy   = "AC_muzzle_ar2",
}

local profile = AC_Muzzle.RegisterProfile({
    id       = "ac_enhancer",
    name     = "AC Muzzleflash Replacer",
    priority = 10,
    command  = "ac_muzzle_config",
    dataFiles = {
        weapon   = "ac_enhancer_muzzle_config.txt",
        class    = "ac_enhancer_class_config.txt",
        category = "ac_enhancer_category_config.txt",
        pcf      = "ac_enhancer_pcf_config.txt",
        names    = "ac_enhancer_particle_names.txt",
        settings = "ac_enhancer_settings.txt",
        categorySmoke = "ac_enhancer_category_smoke.txt",
    },
    defaults = {
        category      = DEFAULT_CATEGORY,
        fallback      = "AC_muzzle_pistol",
        smokeParticle = "AC_357_barrel_smoke",
        noSmoke       = { AC_muzzle_ar2 = true },
        particles     = { "AC_muzzle_357", "AC_muzzle_ar2", "AC_muzzle_pistol", "AC_muzzle_shotgun", "AC_muzzle_smg", "AC_357_barrel_smoke" },
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

-- Legacy globals kept for third-party scripts that referenced them.
AC_IsEnergyWeapon        = AC_Muzzle.IsEnergyWeapon
AC_IsSuppressedWeapon    = AC_Muzzle.IsSuppressedWeapon
AC_DetectWeaponCategory  = AC_Muzzle.DetectCategory
AC_GetMuzzleAttachment   = AC_Muzzle.GetMuzzleAttachment
AC_GetNPCWeaponClass     = AC_Muzzle.GetNPCWeaponClass
AC_DEFAULT_CATEGORY_PARTICLES = DEFAULT_CATEGORY
AC_MELEE_NPC_KEYWORDS    = AC_Muzzle.MeleeNPCKeywords

function AC_GetNPCParticle(wepClass)
    if not wepClass then return nil end
    return AC_Muzzle.GetParticle(profile, wepClass, false)
end

if CLIENT then
    AC_MUZZLE_WEAPON_CONFIG       = profile.weapon
    AC_MUZZLE_CLASS_CONFIG        = profile.class
    AC_MUZZLE_CATEGORY_CONFIG     = profile.category
    AC_MUZZLE_PCF_FILES           = profile.pcfFiles
    AC_MUZZLE_PARTICLE_NAMES      = profile.particleNames
    AC_MUZZLE_AVAILABLE_PARTICLES = profile.available

    concommand.Add("ac_muzzle_config", function()
        AC_Muzzle.OpenConfigurator(profile)
    end)

    hook.Add("PopulateToolMenu", "AC_MuzzleFlash_Menu", function()
        spawnmenu.AddToolMenuOption("Options", "Combat", "AC_MuzzleReplacer", "AC Muzzleflash Replacer", "", "", function(panel)
            panel:ClearControls()
            panel:Help("Replaces weapon muzzleflashes with the AC particle set.")
            panel:CheckBox("Disable muzzleflash replacement", "cl_ac_muzzleflash_disabled")
            panel:Button("Open Configurator", "ac_muzzle_config")
        end)
        spawnmenu.AddToolMenuOption("Options", "Combat", "AC_MuzzleFlashToggle", "AC Muzzleflash Toggle", "", "", function(panel)
            panel:ClearControls()
            panel:CheckBox("Disable Muzzleflashes", "cl_ac_muzzleflash_disabled")
        end)
    end)
end
