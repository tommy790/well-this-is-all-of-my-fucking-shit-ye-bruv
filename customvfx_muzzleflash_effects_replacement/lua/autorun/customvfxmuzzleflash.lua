-- ============================================================
-- Advanced Muzzleflash Replacer - LEGENDARY EDITION v2.4.1 (FULL)
-- 
-- Original full feature set restored + performance smoke system
-- 
-- Key fixes:
-- • All functions defined early (ScanForParticles, IsEnergyWeapon, ShouldSkipAmmoChange, etc.)
-- • Smoke ALWAYS appears after every shot
-- • Detects if smoke is still emitting ("stopping emission")
-- • Stops current barrel smoke cleanly when firing or new smoke spawns
-- • Fixed automatic weapons (rapid fire now produces smoke every shot)
--
-- Full UI with all tabs preserved
-- ============================================================

AddCSLuaFile()

-- ============================================================
-- SHARED
-- ============================================================

local SPECIAL_REGISTRY_KEYS = {
    ["_legacy_particles"] = true,
    ["_standalone"] = true,
}

local function IsSpecialRegistryKey(key)
    return SPECIAL_REGISTRY_KEYS[key] == true
end

local function EarlyLoadPCFRegistry()
    local registry = {}
    if file.Exists("muzzle_pcf_registry.txt", "DATA") then
        registry = util.JSONToTable(file.Read("muzzle_pcf_registry.txt", "DATA")) or {}
    end
    return registry
end

local EARLY_PCF_REGISTRY = EarlyLoadPCFRegistry()

for pcfPath, names in pairs(EARLY_PCF_REGISTRY) do
    if not IsSpecialRegistryKey(pcfPath) and string.EndsWith(pcfPath, ".pcf") then
        game.AddParticles(pcfPath)
    end
    if istable(names) then
        for _, name in ipairs(names) do
            pcall(function() PrecacheParticleSystem(name) end)
        end
    end
end

-- ============================================================
-- SHARED CONFIG INITIALIZATION (MUST BE BEFORE ANY LoadConfig / hooks / CLIENT)
-- This prevents "attempt to index global 'WEAPON_CATEGORY_CONFIG' (a nil value)"
-- and all similar nil errors for config tables. Runs on BOTH server and client.
-- ============================================================

MUZZLE_CONFIG = MUZZLE_CONFIG or {}
CLASS_BASED_CONFIG = CLASS_BASED_CONFIG or {}
WEAPON_CATEGORY_CONFIG = WEAPON_CATEGORY_CONFIG or {
    ["pistol"] = "pistol_muzzle",
    ["revolver"] = "357_muzzle",
    ["smg"] = "smg1",
    ["shotgun"] = "shotgun_muzzle",
    ["rifle"] = "AC_muzzle_rifle",
    ["sniper"] = "AC_muzzle_desert",
    ["lmg"] = "AC_muzzle_rifle",
    ["launcher"] = "hl2mmod_muzzleflash_rpg",
    ["energy"] = "AR2_muzzle",
}

MUZZLE_SETTINGS = MUZZLE_SETTINGS or {
    barrel_smoke_enabled = true,
    barrel_smoke_mode = "auto",
    custom_smoke_particle = "",
    smoke_cooldown = 0.3,
    viewmodel_smoke = true,
    worldmodel_smoke = true,
    npc_muzzle_enabled = true,
}

CATEGORY_SMOKE_CONFIG = CATEGORY_SMOKE_CONFIG or {}
PCF_REGISTRY = PCF_REGISTRY or {}

-- HL2 tables (used by helpers on both sides)
HL2_WEAPON_PARTICLES = HL2_WEAPON_PARTICLES or {
    ["weapon_pistol"]     = "pistol_muzzle",
    ["weapon_357"]        = "357_muzzle",
    ["weapon_smg1"]       = "smg1",
    ["weapon_shotgun"]    = "shotgun_muzzle",
    ["weapon_ar2"]        = "AR2_muzzle",
    ["weapon_crossbow"]   = "none",
    ["weapon_rpg"]        = "hl2mmod_muzzleflash_rpg",
    ["weapon_frag"]       = "none",
    ["weapon_slam"]       = "none",
    ["weapon_physcannon"] = "none",
}

HL2_WEAPON_ALTPARTICLES = HL2_WEAPON_ALTPARTICLES or {
    ["weapon_ar2"]     = "charge_fire",
    ["weapon_smg1"]    = "AC_muzzle_rifle_muzzlesmoke_core",
    ["weapon_shotgun"] = "AC_muzzle_shotgun_db",
}

HL2_WEAPON_ALT_SMOKE = HL2_WEAPON_ALT_SMOKE or {
    ["weapon_ar2"]     = "none",
    ["weapon_smg1"]    = "AC_muzzle_minigun_smoke_barrel",
    ["weapon_shotgun"] = "none",
}

HL2_WEAPON_SMOKE = HL2_WEAPON_SMOKE or {
    ["weapon_pistol"]     = "AC_muzzle_minigun_smoke_barrel",
    ["weapon_357"]        = "AC_muzzle_minigun_smoke_barrel",
    ["weapon_smg1"]       = "AC_muzzle_minigun_smoke_barrel",
    ["weapon_shotgun"]    = "AC_muzzle_minigun_smoke_barrel",
    ["weapon_ar2"]        = "none",
    ["weapon_crossbow"]   = "none",
    ["weapon_rpg"]        = "none",
    ["weapon_frag"]       = "none",
    ["weapon_slam"]       = "none",
    ["weapon_physcannon"] = "none",
}

WEAPON_CATEGORY_SMOKE = WEAPON_CATEGORY_SMOKE or {
    ["pistol"]    = "AC_muzzle_minigun_smoke_barrel",
    ["revolver"]  = "AC_muzzle_minigun_smoke_barrel",
    ["smg"]       = "AC_muzzle_minigun_smoke_barrel",
    ["rifle"]     = "AC_muzzle_minigun_smoke_barrel",
    ["lmg"]       = "AC_muzzle_minigun_smoke_barrel",
    ["shotgun"]   = "AC_muzzle_minigun_smoke_barrel",
    ["sniper"]    = "AC_muzzle_minigun_smoke_barrel",
    ["energy"]    = "none",
    ["launcher"]  = "none",
}

local function MatchesKeyword(name, keyword)
    local searchStart = 1
    while true do
        local s, e = string.find(name, keyword, searchStart, true)
        if not s then return false end
        local leftOk = (s == 1) or not string.match(string.sub(name, s - 1, s - 1), "%a")
        local rightOk = (e == #name) or not string.match(string.sub(name, e + 1, e + 1), "%a")
        if leftOk and rightOk then return true end
        searchStart = s + 1
        if searchStart > #name then return false end
    end
end

-- ============================================================
-- CONFIG SAVE/LOAD (MUST BE DEFINED EARLY — BEFORE ANY CLIENT UI OR CALLS)
-- ============================================================

function SaveConfig()
    local function SafeWrite(path, tbl)
        local json = util.TableToJSON(tbl)
        if json then file.Write(path, json) end
    end
    SafeWrite("muzzle_config.txt", MUZZLE_CONFIG)
    SafeWrite("muzzle_class_config.txt", CLASS_BASED_CONFIG)
    SafeWrite("muzzle_category_config.txt", WEAPON_CATEGORY_CONFIG)
    SafeWrite("muzzle_pcf_registry.txt", PCF_REGISTRY)
    SafeWrite("muzzle_settings.txt", MUZZLE_SETTINGS)
    SafeWrite("muzzle_category_smoke.txt", CATEGORY_SMOKE_CONFIG)
end

function LoadConfig()
    -- Defensive initialization to prevent nil global indexing errors
    MUZZLE_CONFIG = MUZZLE_CONFIG or {}
    CLASS_BASED_CONFIG = CLASS_BASED_CONFIG or {}
    WEAPON_CATEGORY_CONFIG = WEAPON_CATEGORY_CONFIG or {}
    MUZZLE_SETTINGS = MUZZLE_SETTINGS or {}
    CATEGORY_SMOKE_CONFIG = CATEGORY_SMOKE_CONFIG or {}
    PCF_REGISTRY = PCF_REGISTRY or {}

    if file.Exists("muzzle_config.txt", "DATA") then
        MUZZLE_CONFIG = util.JSONToTable(file.Read("muzzle_config.txt", "DATA")) or {}
    end
    if file.Exists("muzzle_class_config.txt", "DATA") then
        local loaded = util.JSONToTable(file.Read("muzzle_class_config.txt", "DATA"))
        if loaded then 
            for k, v in pairs(loaded) do CLASS_BASED_CONFIG[k] = v end 
        end
    end
    if file.Exists("muzzle_category_config.txt", "DATA") then
        local loaded = util.JSONToTable(file.Read("muzzle_category_config.txt", "DATA"))
        if loaded then 
            WEAPON_CATEGORY_CONFIG = WEAPON_CATEGORY_CONFIG or {}
            for k, v in pairs(loaded) do WEAPON_CATEGORY_CONFIG[k] = v end 
        end
    end
    if file.Exists("muzzle_settings.txt", "DATA") then
        local loaded = util.JSONToTable(file.Read("muzzle_settings.txt", "DATA"))
        if loaded then 
            for k, v in pairs(loaded) do MUZZLE_SETTINGS[k] = v end 
        end
    end
    if file.Exists("muzzle_category_smoke.txt", "DATA") then
        local loaded = util.JSONToTable(file.Read("muzzle_category_smoke.txt", "DATA"))
        if loaded then CATEGORY_SMOKE_CONFIG = loaded end
    end
    if file.Exists("muzzle_pcf_registry.txt", "DATA") then
        PCF_REGISTRY = util.JSONToTable(file.Read("muzzle_pcf_registry.txt", "DATA")) or {}
    end
end

-- Load config immediately (shared + early)
LoadConfig()

if SERVER then
    util.AddNetworkString("MuzzleReplacer_SyncPCF")
    util.AddNetworkString("MuzzleReplacer_SyncParticleName")

    local pcfs = {
        "particles/ac_mw_handguns.pcf",
        "particles/ar2_flash.pcf",
        "particles/procharge.pcf",
        "particles/pulsepistol.pcf",
        "particles/rpg.pcf"
    }
    for _, p in ipairs(pcfs) do game.AddParticles(p) end

    local precaches = {
        "AC_muzzle_357", "AC_muzzle_357_barrel_smoke", "357_1",
        "AC_muzzle_desert", "AC_muzzle_pistol_suppressed",
        "AC_muzzle_rifle", "AC_muzzle_shotgun", "AC_muzzle_shotgun_db",
        "AC_muzzle_pistol", "AC_muzzle_minigun_smoke_barrel",
        "pistol_muzzle", "357_muzzle", "smg1", "shotgun_muzzle",
        "AR2_muzzle", "AC_muzzle_rifle_muzzlesmoke_core",
        "charge_fire", "hl2mmod_muzzleflash_rpg"
    }
    for _, p in ipairs(precaches) do pcall(PrecacheParticleSystem, p) end
end

hook.Add("PopulateToolMenu", "MuzzleReplacer_Menu", function()
    spawnmenu.AddToolMenuOption("Options", "Combat", "MuzzleReplacer", "Muzzleflash Replacer", "", "", function(panel)
        panel:ClearControls()
        panel:Help("Muzzleflash Replacer v2.4.1")
        panel:Button("Open Configurator", "muzzle_replacer")
    end)
end)

-- ============================================================
-- CLIENT
-- ============================================================

if CLIENT then
    -- Precache
    local pcfs = {
        "particles/ac_mw_handguns.pcf", "particles/ar2_flash.pcf",
        "particles/procharge.pcf", "particles/pulsepistol.pcf", "particles/rpg.pcf"
    }
    for _, p in ipairs(pcfs) do game.AddParticles(p) end

    local precaches = {
        "AC_muzzle_357", "AC_muzzle_357_barrel_smoke", "357_1",
        "AC_muzzle_desert", "AC_muzzle_pistol_suppressed",
        "AC_muzzle_rifle", "AC_muzzle_shotgun", "AC_muzzle_shotgun_db",
        "AC_muzzle_pistol", "AC_muzzle_minigun_smoke_barrel",
        "pistol_muzzle", "357_muzzle", "smg1", "shotgun_muzzle",
        "AR2_muzzle", "AC_muzzle_rifle_muzzlesmoke_core",
        "charge_fire", "hl2mmod_muzzleflash_rpg"
    }
    for _, p in ipairs(precaches) do pcall(PrecacheParticleSystem, p) end

    -- ==================== STATE ====================
    local lastAmmo = {}
    local lastParticleTime = {}
    local lastWeapon = {}
    local PARTICLE_COOLDOWN = 0.025
    local ALT_FIRE_COOLDOWN = 0.10   -- short debounce to dedup within same drop frame for alt-fires
    local SMG_ALT_COOLDOWN = 0.18    -- slightly longer for SMG to prevent any hold-right-click spam when no real shot
    local lastWorldmodelFlash = {}
    local lastBarrelSmoke = {}         -- track current barrel smoke particle
    local lastSmokeStartTime = {}      -- for detecting if smoke is still emitting
    local SMOKE_EMIT_DURATION = 2.4
    local MIN_SMOKE_INTERVAL = 0.028

    local lastSecondaryAmmo = {}       -- track secondary ammo for alt-fire (SMG1 grenade, AR2 ball, etc.)
    local lastAltFireSpawn = {}        -- per-weapon timestamp of last alt muzzle effect spawn (prevents hold spam, allows repeat fires)

    -- Legacy alt-fire hold detection (still actively used for non-energy weapons like shotgun double-barrel)
    local altKeyHeldSince = {}
    local lastAltFireTime = {}

    local energyAmmo = {}
    local energyLastWeapon = {}
    local energyLastMuzzle = {}
    local ENERGY_MUZZLE_COOLDOWN = 0.05

    local npcLastMuzzle = {}
    local npcAmmo = {}
    local npcLastWeapon = {}
    local NPC_MUZZLE_COOLDOWN = 0.05

    local lastReloadPress = {}
    local lastAttackPress = {}
    local RELOAD_GRACE = 1.0
    local ATTACK_GRACE = 0.15

    local cachedNPCSet = {}
    local cachedNPCList = {}
    local npcListDirty = true

    hook.Add("OnEntityCreated", "MuzzleReplacer_TrackNPCs", function(ent)
        timer.Simple(0, function()
            if IsValid(ent) and ent:IsNPC() and not ent:IsNextBot() and isfunction(ent.GetActiveWeapon) then
                cachedNPCSet[ent] = true
                npcListDirty = true
            end
        end)
    end)

    hook.Add("EntityRemoved", "MuzzleReplacer_UntrackNPCs", function(ent)
        if cachedNPCSet[ent] then
            cachedNPCSet[ent] = nil
            npcListDirty = true
        end
    end)

    local function GetActiveNPCs()
        if npcListDirty then
            cachedNPCList = {}
            for npc in pairs(cachedNPCSet) do
                if IsValid(npc) and npc:IsNPC() then
                    table.insert(cachedNPCList, npc)
                else
                    cachedNPCSet[npc] = nil
                end
            end
            npcListDirty = false
        end
        return cachedNPCList
    end

    -- Config (already initialized in shared; keep for safety / overrides)
    MUZZLE_CONFIG = MUZZLE_CONFIG or {}
    CLASS_BASED_CONFIG = CLASS_BASED_CONFIG or {}
    WEAPON_CATEGORY_CONFIG = WEAPON_CATEGORY_CONFIG or {}
    MUZZLE_SETTINGS = MUZZLE_SETTINGS or {}
    CATEGORY_SMOKE_CONFIG = CATEGORY_SMOKE_CONFIG or {}
    PCF_REGISTRY = EARLY_PCF_REGISTRY or {}

    local NO_SMOKE_PARTICLES = {
        ["AC_muzzle_pistol_suppressed"] = true,
    }

    -- ============================================================
    -- NATIVE PCF DETECTION SYSTEM
    -- Prevents our replacer from stacking on top of weapons that already emit PCF muzzleflashes.
    -- ============================================================

    -- Weapons / bases that are known to emit their own PCF muzzle effects.
    -- Add more as you discover them.
    local KNOWN_NATIVE_PCF_CLASSES = {
        -- Common custom weapon bases
        ["arccw_base"] = true,
        ["tfa_gun_base"] = true,
        ["fas2_base"] = true,
        ["bobs_gun_base"] = true,
        ["swep_base"] = true,
        ["css_gun_base"] = true,
    }

    local function WeaponUsesNativePCF(wep)
        if not IsValid(wep) then return false end
        local class = wep:GetClass()

        -- 1. Explicit user override (set via config or future UI)
        if MUZZLE_CONFIG[class] == "none" then
            return false -- user explicitly wants our version (or disabled)
        end

        -- 2. Check common weapon properties that indicate native PCF usage
        if wep.MuzzleEffect and isstring(wep.MuzzleEffect) and wep.MuzzleEffect ~= "" then
            return true
        end

        if wep.Primary and wep.Primary.MuzzleEffect and isstring(wep.Primary.MuzzleEffect) and wep.Primary.MuzzleEffect ~= "" then
            return true
        end

        -- ArcCW / TFA / modern bases often expose these
        if wep.GetMuzzleEffect and isfunction(wep.GetMuzzleEffect) then
            local ok, eff = pcall(wep.GetMuzzleEffect, wep)
            if ok and isstring(eff) and eff ~= "" then
                return true
            end
        end

        if wep.MuzzleAttachment then
            local att = wep.MuzzleAttachment
            -- Some weapons (ArcCW, TFA, etc.) store the attachment *name* as a string,
            -- others store the index as a number. Either non-empty value means native PCF.
            if (isnumber(att) and att > 0) or (isstring(att) and att ~= "" and att ~= "0") then
                -- Many bases only set this when they do their own particle work
                return true
            end
        end

        -- 3. Check known weapon base classes (parents)
        local base = wep.Base or ""
        if KNOWN_NATIVE_PCF_CLASSES[base] then
            return true
        end

        -- 4. Check if the weapon class itself is in the known list
        if KNOWN_NATIVE_PCF_CLASSES[class] then
            return true
        end

        -- 5. Heuristic: if the weapon has a lot of particle-related functions or NW vars
        if wep.GetNWBool and wep:GetNWBool("HasMuzzleFlash", false) then
            return true
        end

        return false
    end

    -- Global setting (exposed in Settings tab)
    MUZZLE_SETTINGS.respect_native_muzzle = MUZZLE_SETTINGS.respect_native_muzzle ~= false -- default true

    local RUNTIME_PRECACHED = {}
    local AVAILABLE_PARTICLES = {}
    local AVAILABLE_PARTICLES_SET = {}

    -- ==================== CORE HELPERS (ALL DEFINED EARLY) ====================

    local function AddAvailableParticle(name)
        if not name or name == "" then return end
        if AVAILABLE_PARTICLES_SET[name] then return end
        AVAILABLE_PARTICLES_SET[name] = true
        table.insert(AVAILABLE_PARTICLES, name)
    end

    -- ==================== ALT-FIRE HELPERS (DEFINED EARLY) ====================
    -- Must be defined BEFORE ShouldHaveSmoke / SpawnMuzzleWithSmoke that call them
    local function GetAltFireParticle(wepClass)
        if HL2_WEAPON_ALTPARTICLES and HL2_WEAPON_ALTPARTICLES[wepClass] then
            local alt = HL2_WEAPON_ALTPARTICLES[wepClass]
            if alt and alt ~= "none" and alt ~= "" then
                pcall(function() PrecacheParticleSystem(alt) end)
                return alt
            end
        end
        return nil
    end

    local function GetAltFireSmoke(wepClass)
        if HL2_WEAPON_ALT_SMOKE and HL2_WEAPON_ALT_SMOKE[wepClass] then
            local s = HL2_WEAPON_ALT_SMOKE[wepClass]
            if s and s ~= "none" and s ~= "" then
                pcall(function() PrecacheParticleSystem(s) end)
                return s
            end
        end
        return nil
    end

    local function ShouldHaveSmoke(particle, isAltFire, wepClass)
        if not MUZZLE_SETTINGS.barrel_smoke_enabled then return false end
        if MUZZLE_SETTINGS.barrel_smoke_mode == "never" then return false end
        if MUZZLE_SETTINGS.barrel_smoke_mode == "always" then return true end
        if MUZZLE_SETTINGS.barrel_smoke_mode == "custom" then return true end
        if not particle then return false end
        if particle == "none" then return false end

        -- Respect per-weapon alt-fire smoke table ("none" for AR2 alt-fire)
        if isAltFire and wepClass then
            local altSmoke = GetAltFireSmoke(wepClass)
            if altSmoke == "none" or altSmoke == "" or altSmoke == nil then
                return false
            end
        end

        return not NO_SMOKE_PARTICLES[particle]
    end

    local function ShouldCategoryHaveSmoke(category)
        if CATEGORY_SMOKE_CONFIG[category] ~= nil then
            return CATEGORY_SMOKE_CONFIG[category]
        end
        return MUZZLE_SETTINGS.barrel_smoke_enabled
    end

    local function IsFirstPerson(ply)
        if not IsValid(ply) then return false end
        return ply:GetViewEntity() == ply and not ply:ShouldDrawLocalPlayer()
    end

    local function CleanParticleName(raw)
        if not raw then return "" end
        local name = string.Trim(raw)
        name = string.gsub(name, "%.pcf$", "")
        name = string.match(name, "[^/\\]+$") or name
        name = string.Trim(name)
        return name
    end

    -- Reload helpers
    local function IsWeaponInReloadState(wep)
        if not IsValid(wep) then return false end
        if wep.Reloading == true then return true end
        if wep:GetNWBool("Reloading", false) then return true end
        local inReload = wep:GetInternalVariable("m_bInReload")
        if inReload == true then return true end
        if isfunction(wep.GetReloading) then
            local ok, val = pcall(wep.GetReloading, wep)
            if ok and val then return true end
        end
        if isfunction(wep.IsReloading) then
            local ok, val = pcall(wep.IsReloading, wep)
            if ok and val then return true end
        elseif isbool(wep.IsReloading) then
            if wep.IsReloading == true then return true end
        end
        if wep.ReloadDelay and isnumber(wep.ReloadDelay) and wep.ReloadDelay > CurTime() then
            return true
        end
        return false
    end

    local function ShouldSkipAmmoChange(ply, wep, curTime, currentAmmo)
        if ply:KeyDown(IN_ATTACK) or ply:KeyDown(IN_ATTACK2) then
            lastAttackPress[ply] = curTime
        end
        if ply:KeyDown(IN_RELOAD) then
            lastReloadPress[ply] = curTime
        end
        if lastAttackPress[ply] and (curTime - lastAttackPress[ply]) < ATTACK_GRACE then
            return false
        end
        if IsWeaponInReloadState(wep) then return true end
        if lastReloadPress[ply] and (curTime - lastReloadPress[ply]) < RELOAD_GRACE then
            return true
        end
        if currentAmmo == 0 then return true end

        local vm = ply:GetViewModel()
        if IsValid(vm) then
            local seq = vm:GetSequence()
            if seq and seq >= 0 then
                local seqName = vm:GetSequenceName(seq)
                if seqName then
                    local lower = string.lower(seqName)
                    if string.find(lower, "reload", 1, true)
                    or string.find(lower, "insert", 1, true)
                    or string.find(lower, "load", 1, true)
                    or string.find(lower, "charge", 1, true) then
                        return true
                    end
                end
            end
        end
        return false
    end

    local STRICT_KEYWORDS = {
        ["ar2"] = true, ["p90"] = true, ["m16"] = true,
        ["m60"] = true, ["m9"] = true, ["g36"] = true,
    }

    local function CheckKeyword(name, keyword)
        if STRICT_KEYWORDS[keyword] then return MatchesKeyword(name, keyword) end
        return string.find(name, keyword, 1, true) ~= nil
    end

    function DetectWeaponCategory(class)
        local name = string.lower(class or "")
        local checks = {
            {"revolver", {"revolver","357","magnum","python","deagle","desert_eagle","50ae","handcannon"}},
            {"sniper", {"sniper","awp","awm","l96","intervention","barrett","m82","dragunov","svd","scout","mosin","kar98"}},
            {"launcher", {"rpg","launcher","m79","thumper","grenade_launcher","m32","mgl"}},
            {"energy", {"ar2","pulse","plasma","laser","energy","physcannon","irifle","combine_gun"}},
            {"shotgun", {"shotgun","benelli","remington870","r870","mossberg","spas","nova","xm1014","sawedoff","aa12","ksg"}},
            {"lmg", {"m249","m60","pkm","negev","minigun","mg42","rpk","lmg","saw"}},
            {"smg", {"smg","mp5","mp7","mp9","ump","uzi","mac10","vector","p90","bizon","ppsh","thompson"}},
            {"rifle", {"ak47","ak74","m4a1","m16","scar","aug","famas","galil","g36","fal","ar15","hk416","acr","rifle","tar21","tavor","qbz","l85","sa80","f2000","groza","an94","aek"}},
            {"pistol", {"pistol","glock","beretta","m9","1911","usp","p226","fiveseven","sig","makarov","walther","luger","cz75","p250","tec9","r8"}},
        }
        for _, check in ipairs(checks) do
            for _, kw in ipairs(check[2]) do
                if CheckKeyword(name, kw) then return check[1] end
            end
        end
        return "pistol"
    end

    function IsEnergyWeapon(class)
        local name = string.lower(class or "")
        local energyKeywords = {"ar2","pulse","plasma","laser","energy","irifle","combine_gun","physcannon"}
        for _, kw in ipairs(energyKeywords) do
            if CheckKeyword(name, kw) then return true end
        end
        return false
    end

    function GetWeaponParticle(wepClass)
        local result = nil
        if HL2_WEAPON_PARTICLES[wepClass] then
            result = HL2_WEAPON_PARTICLES[wepClass]
        elseif MUZZLE_CONFIG[wepClass] then
            result = MUZZLE_CONFIG[wepClass]
        elseif CLASS_BASED_CONFIG[wepClass] then
            result = CLASS_BASED_CONFIG[wepClass]
        else
            local lowerClass = string.lower(wepClass)
            for pattern, particle in pairs(CLASS_BASED_CONFIG) do
                if pattern ~= wepClass and string.find(lowerClass, string.lower(pattern), 1, true) then
                    result = particle
                    break
                end
            end
            if not result then
                for _, kw in ipairs({"silenced","suppressed","supressed","silencer","*sd","-sd"}) do
                    if string.find(lowerClass, kw, 1, true) then
                        result = "AC_muzzle_pistol_suppressed"
                        break
                    end
                end
                if not result and string.sub(lowerClass, -2) == "sd" then
                    result = "AC_muzzle_pistol_suppressed"
                end
            end
            if not result then
                local category = DetectWeaponCategory(wepClass)
                if WEAPON_CATEGORY_CONFIG[category] then
                    result = WEAPON_CATEGORY_CONFIG[category]
                end
            end
            if not result then result = "AC_muzzle_pistol" end
        end
        if result and result ~= "none" then
            pcall(function() PrecacheParticleSystem(result) end)
        end
        return result
    end

    function AutoApplyAll()
        for _, wepTable in pairs(weapons.GetList()) do
            if wepTable.ClassName then
                if HL2_WEAPON_PARTICLES[wepTable.ClassName] then continue end
                local category = DetectWeaponCategory(wepTable.ClassName)
                if WEAPON_CATEGORY_CONFIG[category] and not MUZZLE_CONFIG[wepTable.ClassName] then
                    MUZZLE_CONFIG[wepTable.ClassName] = WEAPON_CATEGORY_CONFIG[category]
                end
            end
        end
        local json = util.TableToJSON(MUZZLE_CONFIG)
        if json then file.Write("muzzle_config.txt", json) end
    end

    function ScanForParticles()
        AVAILABLE_PARTICLES = {}
        AVAILABLE_PARTICLES_SET = {}

        local builtinFiles = {
            "particles/ac_mw_handguns.pcf",
            "particles/ar2_flash.pcf",
            "particles/procharge.pcf",
            "particles/pulsepistol.pcf",
            "particles/rpg.pcf"
        }
        for _, pcf in ipairs(builtinFiles) do game.AddParticles(pcf) end

        for pcfPath, names in pairs(PCF_REGISTRY) do
            if not IsSpecialRegistryKey(pcfPath) and string.EndsWith(pcfPath, ".pcf") then
                game.AddParticles(pcfPath)
            end
            if istable(names) then
                for _, name in ipairs(names) do
                    pcall(function() PrecacheParticleSystem(name) end)
                    AddAvailableParticle(name)
                end
            end
        end

        local particles = {
            "AC_muzzle_357", "AC_muzzle_desert", "AC_muzzle_pistol_suppressed",
            "AC_muzzle_rifle", "AC_muzzle_shotgun", "AC_muzzle_shotgun_db",
            "AC_muzzle_pistol", "AR2_muzzle", "ar2_muzzle2", "storm_muzzle",
            "357_1", "AC_muzzle_357_barrel_smoke", "hl2mmod_muzzleflash_rpg"
        }

        for _, names in pairs(PCF_REGISTRY) do
            if istable(names) then
                for _, name in ipairs(names) do
                    table.insert(particles, name)
                end
            end
        end

        local function AddFromConfig(tbl)
            if not tbl then return end
            for _, particleName in pairs(tbl) do
                if isstring(particleName) and particleName ~= "none" and particleName ~= "" then
                    table.insert(particles, particleName)
                end
            end
        end
        AddFromConfig(MUZZLE_CONFIG)
        AddFromConfig(CLASS_BASED_CONFIG)
        AddFromConfig(WEAPON_CATEGORY_CONFIG)

        if MUZZLE_SETTINGS.custom_smoke_particle and MUZZLE_SETTINGS.custom_smoke_particle ~= "" then
            table.insert(particles, MUZZLE_SETTINGS.custom_smoke_particle)
        end

        for _, p in ipairs(particles) do
            pcall(function()
                PrecacheParticleSystem(p)
                RUNTIME_PRECACHED[p] = true
                AddAvailableParticle(p)
            end)
        end

        table.sort(AVAILABLE_PARTICLES, function(a, b) return string.lower(a) < string.lower(b) end)
        return AVAILABLE_PARTICLES
    end

    -- ==================== SMOKE PERFORMANCE SYSTEM ====================

    local function StopBarrelSmokeForEnt(ent)
        if not IsValid(ent) then return end
        local key = ent:EntIndex()
        local prevSmoke = lastBarrelSmoke[key]
        if prevSmoke and prevSmoke ~= "" and prevSmoke ~= "none" then
            pcall(function()
                ent:StopParticlesNamed(prevSmoke)
            end)
        end
        lastBarrelSmoke[key] = nil
        lastSmokeStartTime[key] = nil
    end

    local function HasActiveBarrelSmoke(ent)
        if not IsValid(ent) then return false end
        local key = ent:EntIndex()
        local start = lastSmokeStartTime[key]
        if not start then return false end
        return (CurTime() - start) < SMOKE_EMIT_DURATION
    end

    local function GetMuzzleAttachment(ent)
        if not IsValid(ent) then return 0 end
        -- Expanded + energy-specific names. Custom PCFs are picky.
        local attachNames = {
            "muzzle", "muzzle_flash", "muzzle*flash", "muzzle_attachment",
            "muzzle1", "muzzle_01", "muzzle_flash1", "flash", "1", "muzzle2",
            "muzzle_flash_01", "muzzle_attach", "effect", "particle"
        }
        for _, name in ipairs(attachNames) do
            local id = ent:LookupAttachment(name)
            if id and id > 0 then return id end
        end
        if ent:GetAttachment(1) then return 1 end
        return 0
    end

    -- NEW: Robust target for player 3rd-person world models
    -- KEY INSIGHT: Custom AR2 muzzleflash PCFs work on NPC worldmodels because we attach to the **weapon entity**.
    -- For player 3rd person, the weapon entity is still the correct target for most custom PCFs.
    -- Player hand is a good fallback but often moves the custom particle to the wrong location.
    local function GetWorldMuzzleTarget(ply, wep)
        if not IsValid(ply) then return nil, 0 end

        -- 1. Prefer the WEAPON entity (this is why custom PCFs work on NPCs and should work on player 3p)
        if IsValid(wep) then
            local attID = GetMuzzleAttachment(wep)
            if attID and attID > 0 then
                return wep, attID
            end
        end

        -- 2. Player right hand (good fallback for many effects, but secondary for gun muzzleflashes)
        local handID = ply:LookupAttachment("anim_attachment_RH")
        if handID and handID > 0 then
            return ply, handID
        end

        -- 3. Other player body attachments
        for _, name in ipairs({"anim_attachment_head", "eyes"}) do
            local id = ply:LookupAttachment(name)
            if id and id > 0 then return ply, id end
        end

        return nil, 0
    end

    -- Special helper that forces weapon target for energy weapons (AR2 custom PCF)
    local function GetEnergyWorldMuzzleTarget(ply, wep)
        if not IsValid(ply) then return nil, 0 end

        if IsValid(wep) then
            local attID = GetMuzzleAttachment(wep)
            if attID and attID > 0 then
                return wep, attID
            end
        end

        -- fallback to hand if weapon has no muzzle
        local handID = ply:LookupAttachment("anim_attachment_RH")
        if handID and handID > 0 then
            return ply, handID
        end
        return nil, 0
    end

    local function GetNPCMuzzleTarget(npc)
        if not IsValid(npc) then return nil, 0 end
        local wep = npc:GetActiveWeapon()
        if IsValid(wep) then
            local attID = GetMuzzleAttachment(wep)
            if attID and attID > 0 then return wep, attID end
        end
        local attID = GetMuzzleAttachment(npc)
        if attID and attID > 0 then return npc, attID end
        return nil, 0
    end

    -- Robust world position helper for 3rd-person / custom PCF particles
    local function GetMuzzleWorldPosAng(ent, attID)
        if not IsValid(ent) or not attID or attID <= 0 then return nil, nil end
        local att = ent:GetAttachment(attID)
        if att and att.Pos then
            return att.Pos, att.Ang or Angle(0, 0, 0)
        end
        return nil, nil
    end

    local function GetSmokeParticle(wepClass, category, isAltFire)
        -- Check for alt-fire specific smoke first (SMG1 alt-fire uses rifle muzzle smoke core)
        if isAltFire and wepClass and HL2_WEAPON_ALT_SMOKE and HL2_WEAPON_ALT_SMOKE[wepClass] then
            local altSmoke = HL2_WEAPON_ALT_SMOKE[wepClass]
            if altSmoke and altSmoke ~= "none" and altSmoke ~= "" then
                pcall(PrecacheParticleSystem, altSmoke)
                return altSmoke
            end
        end

        if wepClass and HL2_WEAPON_SMOKE[wepClass] then
            return HL2_WEAPON_SMOKE[wepClass]
        end
        if MUZZLE_SETTINGS.barrel_smoke_mode == "custom" then
            local custom = MUZZLE_SETTINGS.custom_smoke_particle
            if custom and custom ~= "" then
                pcall(PrecacheParticleSystem, custom)
                return custom
            end
        end
        if category == nil and wepClass then
            category = DetectWeaponCategory(wepClass)
        end
        if category and WEAPON_CATEGORY_SMOKE[category] then
            return WEAPON_CATEGORY_SMOKE[category]
        end
        return "AC_muzzle_minigun_smoke_barrel"
    end

    -- THE KEY PERFORMANCE FEATURE
    local function ForceSpawnBarrelSmoke(targetEnt, attID, wepClass, isViewmodel, isAltFire)
        if not IsValid(targetEnt) then return end
        if not attID or attID < 1 then return end
        if not MUZZLE_SETTINGS.barrel_smoke_enabled then return end
        if MUZZLE_SETTINGS.barrel_smoke_mode == "never" then return end
        if isViewmodel and not MUZZLE_SETTINGS.viewmodel_smoke then return end
        if not isViewmodel and not MUZZLE_SETTINGS.worldmodel_smoke then return end

        local category = wepClass and DetectWeaponCategory(wepClass) or "pistol"
        if not HL2_WEAPON_SMOKE[wepClass] and not ShouldCategoryHaveSmoke(category) then return end

        local key = targetEnt:EntIndex()
        local curTime = CurTime()

        local hasActive = HasActiveBarrelSmoke(targetEnt)
        local hasTracked = lastBarrelSmoke[key] ~= nil

        -- Detect existing smoke (tracked or still emitting) and stop it
        if hasTracked or hasActive then
            StopBarrelSmokeForEnt(targetEnt)
        end

        -- Light throttle for very fast autos
        if lastSmokeStartTime[key] and (curTime - lastSmokeStartTime[key]) < MIN_SMOKE_INTERVAL then
            return
        end

        local smokeParticle = GetSmokeParticle(wepClass, category, isAltFire)
        if not smokeParticle or smokeParticle == "" or smokeParticle == "none" then return end

        pcall(PrecacheParticleSystem, smokeParticle)

        lastSmokeStartTime[key] = curTime
        lastBarrelSmoke[key] = smokeParticle

        -- Always spawn fresh smoke after a shot
        ParticleEffectAttach(smokeParticle, PATTACH_POINT_FOLLOW, targetEnt, attID)
    end

    local function SpawnMuzzleWithSmoke(particle, ent, attID, wepClass, isViewmodel, isAltFire)
        if particle and particle ~= "none" and particle ~= "" then
            pcall(PrecacheParticleSystem, particle)

            if isViewmodel then
                ParticleEffectAttach(particle, PATTACH_POINT_FOLLOW, ent, attID)
            else
                -- === CRITICAL FIX FOR CUSTOM PCFs ===
                -- For player 3rd-person worldmodels:
                -- - Attach to the **weapon entity** (like we do for NPCs) is the most reliable
                --   for custom AR2/energy PCFs registered via PCF Manager.
                -- - Position-based ParticleEffect works for some, but breaks alignment for many custom .pcf files.
                -- - Vanilla "AR2_muzzle" works because it was authored for weapon attachments.
                -- - Custom ones often only appear correctly when attached to the weapon (not hand).
                if IsValid(ent) and ent:GetClass() ~= "player" and attID > 0 then
                    -- Weapon entity → use attach (matches NPC behavior)
                    ParticleEffectAttach(particle, PATTACH_POINT_FOLLOW, ent, attID)
                else
                    -- Player hand or fallback → try position first, then attach
                    local pos, ang = GetMuzzleWorldPosAng(ent, attID)
                    if pos then
                        local fwd = (ang or Angle(0,0,0)):Forward() * 3
                        ParticleEffect(particle, pos + fwd, ang or Angle(0,0,0))
                    elseif attID and attID > 0 then
                        ParticleEffectAttach(particle, PATTACH_POINT_FOLLOW, ent, attID)
                    end
                end
            end
        end

        if ShouldHaveSmoke(particle, isAltFire, wepClass) then
            ForceSpawnBarrelSmoke(ent, attID, wepClass, isViewmodel, isAltFire)
        end
    end

    -- Reliable spawn specifically for energy weapons (AR2 etc.) in 3rd person
    -- This is the key function for custom PCF muzzleflashes.
    --
    -- Why custom AR2 PCFs are missing in player 3rd person (but work on NPCs):
    --   - NPCs: weapon entity + ParticleEffectAttach works.
    --   - Player 3p: some custom .pcf files (especially from PCF Manager) are invisible or misaligned
    --     when only using attach on the weapon (due to parenting/animation differences).
    --   - Vanilla "AR2_muzzle" is very tolerant and was made for this.
    --   - Solution: For energy weapons we **always** do BOTH:
    --       1. ParticleEffectAttach on the weapon (NPC style)
    --       2. Direct ParticleEffect at the exact world muzzle position (more reliable for custom PCFs)
    local function SpawnMuzzleWorldReliable(particle, target, attID, wepClass, isAltFire)
        if not particle or particle == "none" or particle == "" then return end
        if not IsValid(target) then return end

        pcall(PrecacheParticleSystem, particle)

        local didSpawn = false

        -- 1. Try classic attach on the weapon (best for NPC parity and many PCFs)
        if attID and attID > 0 and IsValid(target) and target:GetClass() ~= "player" then
            ParticleEffectAttach(particle, PATTACH_POINT_FOLLOW, target, attID)
            didSpawn = true
        end

        -- 2. ALWAYS also try direct position spawn at the muzzle attachment.
        --    This fixes the majority of "custom PCF missing in 3rd person" cases.
        local pos, ang = GetMuzzleWorldPosAng(target, attID or 1)
        if pos then
            local fwd = (ang or Angle(0,0,0)):Forward() * 3.5
            ParticleEffect(particle, pos + fwd, ang or Angle(0,0,0))
            didSpawn = true
        end

        -- Fallback attach if we only had a player target
        if not didSpawn and attID and attID > 0 then
            ParticleEffectAttach(particle, PATTACH_POINT_FOLLOW, target, attID)
        end

        if attID and attID > 0 and ShouldHaveSmoke(particle, isAltFire, wepClass) then
            ForceSpawnBarrelSmoke(target, attID, wepClass, false, isAltFire)
        end
    end

    -- Enhanced version that respects alt-fire (primary fix)
    local function GetMuzzleParticleForAttack(wepClass, isAltFire)
        if isAltFire then
            local alt = GetAltFireParticle(wepClass)
            if alt then return alt end
        end
        return GetWeaponParticle(wepClass)
    end

    -- ==================== THINK HOOKS (use ForceSpawn) ====================

    hook.Add("Think", "MuzzleReplacer_EnergyWeapons", function()
        local curTime = CurTime()
        local lp = LocalPlayer()
        if not IsValid(lp) then return end
        if lp:Health() <= 0 then
            energyAmmo[lp] = nil
            energyLastWeapon[lp] = nil
            return
        end
        local wep = lp:GetActiveWeapon()
        if not IsValid(wep) then
            energyAmmo[lp] = nil
            energyLastWeapon[lp] = nil
            return
        end
        local wepClass = wep:GetClass()
        if not IsEnergyWeapon(wepClass) then
            energyAmmo[lp] = nil
            energyLastWeapon[lp] = nil
            return
        end
        if energyLastWeapon[lp] ~= wep then
            if IsValid(energyLastWeapon[lp]) then 
                StopBarrelSmokeForEnt(energyLastWeapon[lp]) 
                lastSecondaryAmmo[energyLastWeapon[lp]] = nil
                lastAltFireSpawn[energyLastWeapon[lp]] = nil
            end
            local vm = lp:GetViewModel()
            if IsValid(vm) then StopBarrelSmokeForEnt(vm) end
            energyLastWeapon[lp] = wep
            energyAmmo[lp] = nil
            lastSecondaryAmmo[wep] = nil
            lastAltFireSpawn[wep] = nil
            lastReloadPress[lp] = nil
            lastAttackPress[lp] = nil
        end
        local isAltFire = lp:KeyDown(IN_ATTACK2)

        -- AR2 alt-fire is handled exclusively below using secondary ammo drop (no key-press fallback).
        local particle = GetWeaponParticle(wepClass)
        if not particle or particle == "none" then return end

        -- NEW: Respect native PCF muzzleflashes (prevent stacking)
        if MUZZLE_SETTINGS.respect_native_muzzle and WeaponUsesNativePCF(wep) then
            energyAmmo[lp] = currentAmmo
            return
        end

        local currentAmmo = wep:Clip1()
        if currentAmmo < 0 then return end
        if ShouldSkipAmmoChange(lp, wep, curTime, currentAmmo) then
            energyAmmo[lp] = currentAmmo
            return
        end
        if energyAmmo[lp] == nil then
            energyAmmo[lp] = currentAmmo
            return
        end
        local ammoDrop = energyAmmo[lp] - currentAmmo
        if ammoDrop > 0 and ammoDrop <= 10 then
            local key = lp:EntIndex()
            if not energyLastMuzzle[key] or (curTime - energyLastMuzzle[key]) >= ENERGY_MUZZLE_COOLDOWN then
                if IsFirstPerson(lp) then
                    local vm = lp:GetViewModel()
                    if IsValid(vm) then
                        StopBarrelSmokeForEnt(vm)
                        local attID = GetMuzzleAttachment(vm)
                        if attID > 0 then
                            SpawnMuzzleWithSmoke(particle, vm, attID, wepClass, true, isAltFire)
                        end
                    end
                else
                    -- === CUSTOM AR2 / ENERGY PCF 3RD-PERSON FIX ===
                    -- Why custom PCF works on NPCs but is missing on player 3rd person:
                    --   - NPC weapons: attach to weapon muzzle works for custom PCFs.
                    --   - Player 3p weapon: attachment + ParticleEffectAttach often fails or is invisible
                    --     for custom PCFs (different parenting/animation in player worldmodel).
                    --   - Vanilla "AR2_muzzle" works because it is simple and was designed for HL2 weapon worldmodels.
                    --   - Solution used here: For energy weapons, we do the **exact same thing** that works on NPCs,
                    --     plus an explicit world-position spawn directly from the weapon's muzzle attachment.

                    local target, attID = GetEnergyWorldMuzzleTarget(lp, wep)

                    if IsValid(target) and attID and attID > 0 then
                        StopBarrelSmokeForEnt(target)

                        pcall(PrecacheParticleSystem, particle)

                        -- 1. Classic attach (good for some PCFs and smoke)
                        ParticleEffectAttach(particle, PATTACH_POINT_FOLLOW, target, attID)

                        -- 2. Direct world position spawn from the weapon (this is what often saves custom PCFs in 3p)
                        local pos, ang = GetMuzzleWorldPosAng(target, attID)
                        if pos then
                            local fwd = (ang or Angle(0,0,0)):Forward() * 4
                            ParticleEffect(particle, pos + fwd, ang or Angle(0,0,0))
                        end

                        if ShouldHaveSmoke(particle, isAltFire, wepClass) then
                            ForceSpawnBarrelSmoke(target, attID, wepClass, false, isAltFire)
                        end
                    end
                end
                energyLastMuzzle[key] = curTime
            end
        end
        energyAmmo[lp] = currentAmmo

        -- ============================================================
        -- AR2 ALT-FIRE (COMBINE BALL) — TRIGGER ON SECONDARY AMMO DROP
        --
        -- Simplified per user request: play "charge_fire" as soon as the
        -- secondary ammo count drops (the moment the weapon decides to fire the ball).
        -- This is the most reliable client-side signal.
        -- No key-press fallback. No post-drop delay.
        -- Smoke is correctly "none" for AR2 alt-fire.
        -- SMG alt-fire remains unaffected.
        -- ============================================================
        if wepClass == "weapon_ar2" then
            local key = lp:EntIndex()
            local secType = wep:GetSecondaryAmmoType()
            local didActualLaunch = false

            if secType and secType >= 0 then
                local curSec = lp:GetAmmoCount(secType)
                if lastSecondaryAmmo[wep] == nil then
                    lastSecondaryAmmo[wep] = curSec
                elseif curSec > lastSecondaryAmmo[wep] then
                    -- Ammo was added (pickup / give) — update baseline + reset alt spawn cooldown
                    -- so the next actual alt-fire drop will play the effect again
                    lastSecondaryAmmo[wep] = curSec
                    lastAltFireSpawn[wep] = 0
                elseif lastSecondaryAmmo[wep] > curSec then
                    didActualLaunch = true
                    lastSecondaryAmmo[wep] = curSec
                end
            end

            if didActualLaunch then
                -- NEW: Respect native PCF for AR2 alt-fire too
                if MUZZLE_SETTINGS.respect_native_muzzle and WeaponUsesNativePCF(wep) then
                    lastSecondaryAmmo[wep] = curSec or lastSecondaryAmmo[wep]
                    return
                end

                -- AR2 alt-fire: play "charge_fire" on EVERY real secondary ammo drop.
                -- No hold-spam possible because we only react to the ammo drop (not key hold).
                -- Use only the general energy cooldown + a tiny dedup.
                -- This fixes "only happens one time".
                local lastSpawn = lastAltFireSpawn[wep] or 0
                if (curTime - lastSpawn) >= 0.05 then
                    if not energyLastMuzzle[key] or (curTime - energyLastMuzzle[key]) >= ENERGY_MUZZLE_COOLDOWN then
                        local altParticle = "charge_fire"
                        pcall(PrecacheParticleSystem, altParticle)

                        if IsFirstPerson(lp) then
                            local vm = lp:GetViewModel()
                            if IsValid(vm) then StopBarrelSmokeForEnt(vm) end
                        else
                            local target, _ = GetWorldMuzzleTarget(lp, wep)
                            if target then StopBarrelSmokeForEnt(target) end
                        end

                        if IsFirstPerson(lp) then
                            local vm = lp:GetViewModel()
                            if IsValid(vm) then
                                local attID = GetMuzzleAttachment(vm)
                                if attID > 0 then
                                    SpawnMuzzleWithSmoke(altParticle, vm, attID, wepClass, true, true)
                                end
                            end
                        else
                            -- AR2 alt-fire custom PCF in 3rd person:
                            -- Same dual-target strategy as primary fire (weapon + hand)
                            local target, attID = GetEnergyWorldMuzzleTarget(lp, wep)
                            if target and attID > 0 then
                                SpawnMuzzleWorldReliable(altParticle, target, attID, wepClass, true)
                            end

                            -- Also spawn on hand for custom PCFs that expect player hand in 3p
                            if IsValid(lp) then
                                local handID = lp:LookupAttachment("anim_attachment_RH")
                                if handID and handID > 0 then
                                    local pos, ang = GetMuzzleWorldPosAng(lp, handID)
                                    if pos then
                                        pcall(PrecacheParticleSystem, altParticle)
                                        local fwd = (ang or Angle(0,0,0)):Forward() * 3
                                        ParticleEffect(altParticle, pos + fwd, ang or Angle(0,0,0))
                                    end
                                end
                            end
                        end

                        lastAltFireSpawn[wep] = curTime
                        energyLastMuzzle[key] = curTime
                    end
                end
            end
        end
    end)

    hook.Add("Think", "MuzzleReplacer_Think", function()
        local curTime = CurTime()
        local ply = LocalPlayer()
        if not IsValid(ply) then return end
        local wep = ply:GetActiveWeapon()
        if not IsValid(wep) then
            lastWeapon[ply] = nil
            return
        end
        if lastWeapon[ply] ~= wep then
            if IsValid(lastWeapon[ply]) then 
                StopBarrelSmokeForEnt(lastWeapon[ply]) 
                lastSecondaryAmmo[lastWeapon[ply]] = nil
                lastAltFireSpawn[lastWeapon[ply]] = nil
            end
            local vm = ply:GetViewModel()
            if IsValid(vm) then StopBarrelSmokeForEnt(vm) end
            lastWeapon[ply] = wep
            lastAmmo[wep] = nil
            lastParticleTime[wep] = nil
            lastSecondaryAmmo[wep] = nil
            lastAltFireSpawn[wep] = nil
            lastReloadPress[ply] = nil
            lastAttackPress[ply] = nil
        end
        local class = wep:GetClass()
        if IsEnergyWeapon(class) then return end
        local particle = GetWeaponParticle(class)
        if not particle or particle == "none" then return end

        -- NEW: Respect weapons that already use their own PCF muzzleflashes
        if MUZZLE_SETTINGS.respect_native_muzzle and WeaponUsesNativePCF(wep) then
            lastAmmo[wep] = currentAmmo
            return
        end

        local currentAmmo = wep:Clip1()
        if currentAmmo == -1 then
            local ammoType = wep:GetPrimaryAmmoType()
            if ammoType and ammoType >= 0 then
                currentAmmo = ply:GetAmmoCount(ammoType)
            else
                return
            end
        end
        if ShouldSkipAmmoChange(ply, wep, curTime, currentAmmo) then
            lastAmmo[wep] = currentAmmo
            return
        end
        if lastAmmo[wep] == nil then
            lastAmmo[wep] = currentAmmo
            return
        end
        local ammoDrop = lastAmmo[wep] - currentAmmo
        if ammoDrop > 0 and ammoDrop <= 10 then
            if not lastParticleTime[wep] or (curTime - lastParticleTime[wep]) >= PARTICLE_COOLDOWN then
                local isAltFire = ply:KeyDown(IN_ATTACK2)

                -- IMPORTANT: For SMG and AR2, alt-fire uses secondary ammo only.
                -- Never force the alt particle on primary ammo drops even if right-click is held.
                -- This prevents the alt muzzleflash from "keeping playing" while holding right-click + shooting primary.
                if (class == "weapon_smg1" or class == "weapon_ar2") and isAltFire then
                    isAltFire = false
                end

                local useParticle = GetMuzzleParticleForAttack(class, isAltFire)

                -- Fallback for shotgun double-barrel if no alt table override
                if isAltFire and class == "weapon_shotgun" and useParticle == particle then
                    useParticle = "AC_muzzle_shotgun_db"
                end

                -- Stop previous smoke + force new one
                if IsFirstPerson(ply) then
                    local vm = ply:GetViewModel()
                    if IsValid(vm) then StopBarrelSmokeForEnt(vm) end
                else
                    StopBarrelSmokeForEnt(wep)
                end

                if IsFirstPerson(ply) then
                    local vm = ply:GetViewModel()
                    if IsValid(vm) then
                        local attID = GetMuzzleAttachment(vm)
                        if attID > 0 then
                            SpawnMuzzleWithSmoke(useParticle, vm, attID, class, true, isAltFire)
                        end
                    end
                else
                    local plyKey = ply:EntIndex()
                    if not lastWorldmodelFlash[plyKey] or (curTime - lastWorldmodelFlash[plyKey]) >= PARTICLE_COOLDOWN then
                        local target, attID = GetWorldMuzzleTarget(ply, wep)
                        if target and attID > 0 then
                            StopBarrelSmokeForEnt(target)
                            SpawnMuzzleWithSmoke(useParticle, target, attID, class, false, isAltFire)
                        end
                        lastWorldmodelFlash[plyKey] = curTime
                    end
                end
                lastParticleTime[wep] = curTime
            end
        end
        lastAmmo[wep] = currentAmmo

        -- ============================================================
        -- ALT-FIRE MUZZLEFLASH DETECTION (SMG1 grenade, AR2 energy ball, etc.)
        -- Many alt-fires do NOT reduce Clip1(). We detect:
        --   1. Secondary ammo drop
        --   2. Fresh IN_ATTACK2 press on weapons that have alt particles defined
        -- This now properly emits the alt muzzleflash + alt smoke.
        -- ============================================================
        local isAltFireNow = ply:KeyDown(IN_ATTACK2)

        -- 1. Secondary ammo drop (SMG1 grenade, AR2 ball, etc.)
        local secType = wep:GetSecondaryAmmoType()
        local didSecondaryDrop = false
        local secDropAmount = 0
        if secType and secType >= 0 then
            local currentSec = ply:GetAmmoCount(secType)
            if lastSecondaryAmmo[wep] == nil then
                lastSecondaryAmmo[wep] = currentSec
            elseif currentSec > lastSecondaryAmmo[wep] then
                -- Ammo pickup / increase: update high-water mark so future drops are detected
                lastSecondaryAmmo[wep] = currentSec
            elseif lastSecondaryAmmo[wep] > currentSec then
                secDropAmount = lastSecondaryAmmo[wep] - currentSec
                didSecondaryDrop = true
                lastSecondaryAmmo[wep] = currentSec
            end
        end

        -- 2. Fresh alt-fire key press fallback (only for weapons that need it)
        -- For SMG and AR2 (which use secondary ammo drops for alt-fire), we rely
        -- ONLY on the authoritative secondary ammo drop signal so the effect plays
        -- exactly when the alt actually shoots (no spam while holding right-click).
        -- Key press fallback is kept only for other cases like shotgun.
        local didAltKeyFire = false
        if isAltFireNow then
            if class == "weapon_ar2" or class == "weapon_smg1" then
                -- Completely disable key-press/hold fallback for AR2 and SMG.
                -- They use secondary ammo drop exclusively (prevents "keeps playing while holding").
                altKeyHeldSince[wep] = nil
            else
                if not altKeyHeldSince[wep] then
                    altKeyHeldSince[wep] = curTime
                end

                local held = curTime - altKeyHeldSince[wep]
                local lastSpawn = lastAltFireTime[wep] or 0

                -- Minimum hold for other alt-fires (e.g. shotgun double)
                local minHold = 0.48

                if held > minHold and (curTime - lastSpawn) > 0.22 then
                    if GetAltFireParticle(class) or class == "weapon_shotgun" then
                        didAltKeyFire = true
                        lastAltFireTime[wep] = curTime
                    end
                end
            end
        else
            altKeyHeldSince[wep] = nil
        end

        -- Skip alt-fire secondary detection for energy weapons (AR2, etc.)
        -- They are handled in the dedicated EnergyWeapons Think hook below.
        if IsEnergyWeapon(class) then
            lastAmmo[wep] = currentAmmo
            return
        end

        if (didSecondaryDrop or didAltKeyFire) then
            -- Respect native PCF weapons for alt-fires too
            if MUZZLE_SETTINGS.respect_native_muzzle and WeaponUsesNativePCF(wep) then
                lastAmmo[wep] = currentAmmo
                return
            end

            -- For SMG and AR2 we rely almost exclusively on didSecondaryDrop.
            -- didAltKeyFire is disabled for them above, so this block will
            -- only fire on actual ammo consumption.
            local lastAlt = lastAltFireSpawn[wep] or 0

            local cooldown = ALT_FIRE_COOLDOWN
            if class == "weapon_smg1" then
                cooldown = SMG_ALT_COOLDOWN
            end

            if (curTime - lastAlt) >= cooldown then
                local altParticle = GetMuzzleParticleForAttack(class, true)
                if altParticle and altParticle ~= "none" and altParticle ~= "" then
                    if IsFirstPerson(ply) then
                        local vm = ply:GetViewModel()
                        if IsValid(vm) then StopBarrelSmokeForEnt(vm) end
                    else
                        local target, _ = GetWorldMuzzleTarget(ply, wep)
                        if target then StopBarrelSmokeForEnt(target) end
                    end

                    if IsFirstPerson(ply) then
                        local vm = ply:GetViewModel()
                        if IsValid(vm) then
                            local attID = GetMuzzleAttachment(vm)
                            if attID > 0 then
                                SpawnMuzzleWithSmoke(altParticle, vm, attID, class, true, true)
                            end
                        end
                    else
                        local plyKey = ply:EntIndex()
                        if not lastWorldmodelFlash[plyKey] or (curTime - lastWorldmodelFlash[plyKey]) >= PARTICLE_COOLDOWN then
                            local target, attID = GetWorldMuzzleTarget(ply, wep)
                            if target and attID > 0 then
                                SpawnMuzzleWithSmoke(altParticle, target, attID, class, false, true)
                            end
                            lastWorldmodelFlash[plyKey] = curTime
                        end
                    end

                    lastAltFireSpawn[wep] = curTime
                    lastParticleTime[wep] = curTime
                end
            end
        end
    end)

    -- NPC
    hook.Add("Think", "MuzzleReplacer_NPCThink", function()
        if not MUZZLE_SETTINGS.npc_muzzle_enabled then return end
        local curTime = CurTime()
        local npcs = GetActiveNPCs()
        for _, npc in ipairs(npcs) do
            if not IsValid(npc) or not npc:IsNPC() or npc:Health() <= 0 then continue end
            if not isfunction(npc.GetActiveWeapon) then continue end
            local wep = npc:GetActiveWeapon()
            if not IsValid(wep) then continue end
            if npcLastWeapon[npc] ~= wep then
                if IsValid(npcLastWeapon[npc]) then StopBarrelSmokeForEnt(npcLastWeapon[npc]) end
                npcLastWeapon[npc] = wep
                npcAmmo[npc] = nil
            end
            local class = wep:GetClass()
            local particle = GetWeaponParticle(class)
            if not particle or particle == "none" then continue end

            -- Respect native PCF on NPCs too
            if MUZZLE_SETTINGS.respect_native_muzzle and WeaponUsesNativePCF(wep) then
                npcAmmo[npc] = currentAmmo
                continue
            end

            local currentAmmo = wep:Clip1()
            if currentAmmo < 0 then continue end
            if IsWeaponInReloadState(wep) then
                npcAmmo[npc] = currentAmmo
                continue
            end
            if npcAmmo[npc] == nil then
                npcAmmo[npc] = currentAmmo
                continue
            end
            local ammoDrop = npcAmmo[npc] - currentAmmo
            if ammoDrop > 0 and ammoDrop <= 10 then
                local key = npc:EntIndex()
                if not npcLastMuzzle[key] or (curTime - npcLastMuzzle[key]) >= NPC_MUZZLE_COOLDOWN then
                    local targetEnt, attID = GetNPCMuzzleTarget(npc)
                    if targetEnt and attID > 0 then
                        StopBarrelSmokeForEnt(targetEnt)
                        SpawnMuzzleWithSmoke(particle, targetEnt, attID, class, false)
                    end
                    npcLastMuzzle[key] = curTime
                end
            end
            npcAmmo[npc] = currentAmmo
        end
    end)

    -- Alt fire + ArcCW also call ForceSpawn via SpawnMuzzleWithSmoke (already updated in logic)

    if ArcCW then
        hook.Add("ArcCW_FireBullets", "MuzzleReplacer_ArcCW", function(wep, bullet)
            if not IsValid(wep) then return end
            if not IsValid(wep.Owner) or wep.Owner ~= LocalPlayer() then return end
            if not IsFirstPerson(wep.Owner) then return end

            -- Respect native PCF for ArcCW (they already do their own muzzle effects)
            if MUZZLE_SETTINGS.respect_native_muzzle and WeaponUsesNativePCF(wep) then
                return
            end

            local wepClass = wep:GetClass()
            local isAlt = wep.Owner:KeyDown(IN_ATTACK2)   -- best effort
            local particle = GetMuzzleParticleForAttack(wepClass, isAlt) or GetWeaponParticle(wepClass)
            if particle and particle ~= "none" then
                local vm = wep.Owner:GetViewModel()
                if IsValid(vm) then
                    local attID = GetMuzzleAttachment(vm)
                    if attID > 0 then
                        StopBarrelSmokeForEnt(vm)
                        SpawnMuzzleWithSmoke(particle, vm, attID, wepClass, true, isAlt)
                    end
                end
            end
        end)
    end

    -- ==================== CLEANUP ====================
    timer.Create("MuzzleReplacer_Cleanup", 5, 0, function()
        for wep, _ in pairs(lastAmmo) do if not IsValid(wep) then lastAmmo[wep] = nil lastParticleTime[wep] = nil end end
        for wep, _ in pairs(lastSecondaryAmmo) do if not IsValid(wep) then lastSecondaryAmmo[wep] = nil end end
        for wep, _ in pairs(lastAltFireSpawn) do if not IsValid(wep) then lastAltFireSpawn[wep] = nil end end
        for ply, _ in pairs(lastWeapon) do if not IsValid(ply) then lastWeapon[ply] = nil end end
        for key, _ in pairs(lastWorldmodelFlash) do local ent = Entity(key) if not IsValid(ent) or not ent:IsPlayer() then lastWorldmodelFlash[key] = nil end end
        for key, _ in pairs(lastBarrelSmoke) do if not IsValid(Entity(key)) then lastBarrelSmoke[key] = nil end end
        for key, _ in pairs(lastSmokeStartTime) do if not IsValid(Entity(key)) then lastSmokeStartTime[key] = nil end end
        for ply, _ in pairs(energyAmmo) do if not IsValid(ply) then energyAmmo[ply] = nil energyLastWeapon[ply] = nil end end
        for key, _ in pairs(energyLastMuzzle) do local ent = Entity(key) if not IsValid(ent) or (not ent:IsPlayer() and not ent:IsNPC()) then energyLastMuzzle[key] = nil end end
        for npc, _ in pairs(npcAmmo) do if not IsValid(npc) then npcAmmo[npc] = nil npcLastWeapon[npc] = nil end end
        for key, _ in pairs(npcLastMuzzle) do local ent = Entity(key) if not IsValid(ent) or not ent:IsNPC() then npcLastMuzzle[key] = nil end end
        for ply, _ in pairs(lastReloadPress) do if not IsValid(ply) then lastReloadPress[ply] = nil end end
        for ply, _ in pairs(lastAttackPress) do if not IsValid(ply) then lastAttackPress[ply] = nil end end
        npcListDirty = true
    end)

    -- ==================== INIT & NET ====================
    net.Receive("MuzzleReplacer_SyncPCF", function()
        local pcfPath = net.ReadString()
        if pcfPath ~= "" then game.AddParticles(pcfPath) end
    end)

    net.Receive("MuzzleReplacer_SyncParticleName", function()
        local particleName = net.ReadString()
        if particleName ~= "" then
            pcall(function() PrecacheParticleSystem(particleName) end)
            RUNTIME_PRECACHED[particleName] = true
            AddAvailableParticle(particleName)
        end
    end)

    hook.Add("InitPostEntity", "MuzzleReplacer_Init", function()
        AVAILABLE_PARTICLES = ScanForParticles()
        AutoApplyAll()
        for _, ent in ipairs(ents.GetAll()) do
            if IsValid(ent) and ent:IsNPC() and not ent:IsNextBot() and isfunction(ent.GetActiveWeapon) then
                cachedNPCSet[ent] = true
            end
        end
        npcListDirty = true
    end)

    -- ==================== FULL UI (RESTORED) ====================
    local function CreateParticlePicker(parent, currentValue, onSelect)
        local container = vgui.Create("DPanel", parent)
        container:SetTall(28)
        container.Paint = function() end
        local combo = vgui.Create("DComboBox", container)
        combo:Dock(LEFT)
        combo:SetWide(250)
        combo:SetValue(currentValue or "AC_muzzle_pistol")
        combo:AddChoice("none")
        for _, p in ipairs(AVAILABLE_PARTICLES) do combo:AddChoice(p) end
        combo.OnSelect = function(s, i, v) if onSelect then onSelect(v) end end
        local orLabel = vgui.Create("DLabel", container)
        orLabel:Dock(LEFT)
        orLabel:SetWide(30)
        orLabel:DockMargin(5, 0, 5, 0)
        orLabel:SetText("OR")
        orLabel:SetContentAlignment(5)
        local customEntry = vgui.Create("DTextEntry", container)
        customEntry:Dock(LEFT)
        customEntry:SetWide(200)
        customEntry:SetPlaceholderText("Type ANY name...")
        local setBtn = vgui.Create("DButton", container)
        setBtn:Dock(LEFT)
        setBtn:SetWide(50)
        setBtn:DockMargin(5, 0, 0, 0)
        setBtn:SetText("Set")
        setBtn:SetTextColor(Color(100, 255, 100))
        setBtn.DoClick = function()
            local customName = CleanParticleName(customEntry:GetValue())
            if customName ~= "" then
                pcall(PrecacheParticleSystem, customName)
                AddAvailableParticle(customName)
                combo:SetValue(customName)
                combo:AddChoice(customName)
                if onSelect then onSelect(customName) end
                customEntry:SetValue("")
            end
        end
        customEntry.OnEnter = function() setBtn:DoClick() end
        return container
    end

    local function OpenMuzzleReplacer()
        local frame = vgui.Create("DFrame")
        frame:SetSize(math.min(1000, ScrW() * 0.82), math.min(780, ScrH() * 0.82))
        frame:Center()
        frame:SetTitle("Muzzleflash Replacer v2.4.1 (Full + Performance Smoke)")
        frame:MakePopup()

        local tabs = vgui.Create("DPropertySheet", frame)
        tabs:Dock(FILL)
        tabs:DockMargin(5, 5, 5, 5)

        local categoryDefs = {
            {id = "pistol", name = "Pistols"},
            {id = "revolver", name = "Revolvers"},
            {id = "smg", name = "SMGs"},
            {id = "shotgun", name = "Shotguns"},
            {id = "rifle", name = "Rifles"},
            {id = "sniper", name = "Snipers"},
            {id = "lmg", name = "LMGs"},
            {id = "launcher", name = "Launchers"},
            {id = "energy", name = "Energy/AR2"},
        }

        -- SETTINGS TAB
        local settingsPanel = vgui.Create("DPanel", tabs)
        settingsPanel.Paint = function() end
        local settingsScroll = vgui.Create("DScrollPanel", settingsPanel)
        settingsScroll:Dock(FILL)
        settingsScroll:DockMargin(10, 10, 10, 10)

        local smokeHeader = vgui.Create("DLabel", settingsScroll)
        smokeHeader:Dock(TOP)
        smokeHeader:SetTall(25)
        smokeHeader:SetText("-- BARREL SMOKE PERFORMANCE --")
        smokeHeader:SetFont("DermaDefaultBold")
        smokeHeader:SetTextColor(Color(255, 200, 100))

        local smokeToggle = vgui.Create("DCheckBoxLabel", settingsScroll)
        smokeToggle:Dock(TOP)
        smokeToggle:SetTall(25)
        smokeToggle:DockMargin(0, 5, 0, 5)
        smokeToggle:SetText("Enable Barrel Smoke (Global)")
        smokeToggle:SetChecked(MUZZLE_SETTINGS.barrel_smoke_enabled)
        smokeToggle:SetTextColor(Color(255, 255, 255))
        smokeToggle.OnChange = function(s, val) MUZZLE_SETTINGS.barrel_smoke_enabled = val SaveConfig() end

        local vmSmokeToggle = vgui.Create("DCheckBoxLabel", settingsScroll)
        vmSmokeToggle:Dock(TOP)
        vmSmokeToggle:SetTall(25)
        vmSmokeToggle:DockMargin(20, 0, 0, 5)
        vmSmokeToggle:SetText("Smoke on First Person Viewmodel")
        vmSmokeToggle:SetChecked(MUZZLE_SETTINGS.viewmodel_smoke)
        vmSmokeToggle:SetTextColor(Color(255, 255, 255))
        vmSmokeToggle.OnChange = function(s, val) MUZZLE_SETTINGS.viewmodel_smoke = val SaveConfig() end

        local wmSmokeToggle = vgui.Create("DCheckBoxLabel", settingsScroll)
        wmSmokeToggle:Dock(TOP)
        wmSmokeToggle:SetTall(25)
        wmSmokeToggle:DockMargin(20, 0, 0, 10)
        wmSmokeToggle:SetText("Smoke on Third Person Worldmodel")
        wmSmokeToggle:SetChecked(MUZZLE_SETTINGS.worldmodel_smoke)
        wmSmokeToggle:SetTextColor(Color(255, 255, 255))
        wmSmokeToggle.OnChange = function(s, val) MUZZLE_SETTINGS.worldmodel_smoke = val SaveConfig() end

        local modeCombo = vgui.Create("DComboBox", settingsScroll)
        modeCombo:Dock(TOP)
        modeCombo:SetTall(25)
        modeCombo:DockMargin(0, 5, 0, 5)
        modeCombo:AddChoice("Auto (smart per-particle)", "auto")
        modeCombo:AddChoice("Always (force smoke on all)", "always")
        modeCombo:AddChoice("Never (disable all smoke)", "never")
        modeCombo:AddChoice("Custom (use custom particle)", "custom")
        local modeNames = { auto = "Auto (smart per-particle)", always = "Always (force smoke on all)", never = "Never (disable all smoke)", custom = "Custom (use custom particle)" }
        modeCombo:SetValue(modeNames[MUZZLE_SETTINGS.barrel_smoke_mode] or "Auto (smart per-particle)")
        modeCombo.OnSelect = function(s, i, text, data) MUZZLE_SETTINGS.barrel_smoke_mode = data SaveConfig() end

        local cdSlider = vgui.Create("DNumSlider", settingsScroll)
        cdSlider:Dock(TOP)
        cdSlider:SetTall(30)
        cdSlider:DockMargin(0, 5, 0, 10)
        cdSlider:SetText("Smoke Cooldown (seconds)")
        cdSlider:SetMin(0.02)
        cdSlider:SetMax(2.0)
        cdSlider:SetDecimals(2)
        cdSlider:SetValue(MUZZLE_SETTINGS.smoke_cooldown or 0.3)
        cdSlider.OnValueChanged = function(s, val) MUZZLE_SETTINGS.smoke_cooldown = val SaveConfig() end

        -- NEW: Native PCF respect toggle
        local nativeHeader = vgui.Create("DLabel", settingsScroll)
        nativeHeader:Dock(TOP)
        nativeHeader:SetTall(25)
        nativeHeader:DockMargin(0, 15, 0, 5)
        nativeHeader:SetText("-- NATIVE PCF PROTECTION --")
        nativeHeader:SetFont("DermaDefaultBold")
        nativeHeader:SetTextColor(Color(255, 200, 100))

        local nativeToggle = vgui.Create("DCheckBoxLabel", settingsScroll)
        nativeToggle:Dock(TOP)
        nativeToggle:SetTall(25)
        nativeToggle:DockMargin(0, 5, 0, 5)
        nativeToggle:SetText("Respect Native Muzzle PCFs (don't stack on weapons that already use PCFs)")
        nativeToggle:SetChecked(MUZZLE_SETTINGS.respect_native_muzzle ~= false)
        nativeToggle:SetTextColor(Color(255, 255, 255))
        nativeToggle.OnChange = function(s, val)
            MUZZLE_SETTINGS.respect_native_muzzle = val
            SaveConfig()
        end

        local nativeHelp = vgui.Create("DLabel", settingsScroll)
        nativeHelp:Dock(TOP)
        nativeHelp:SetTall(40)
        nativeHelp:DockMargin(20, 0, 0, 10)
        nativeHelp:SetText("When enabled, the replacer will skip weapons that already emit their own muzzle PCFs\n(ArcCW, TFA, many custom bases, etc.). This prevents double muzzleflashes.")
        nativeHelp:SetWrap(true)
        nativeHelp:SetTextColor(Color(200, 200, 200))

        tabs:AddSheet("Settings", settingsPanel, "icon16/cog.png")

        -- CATEGORIES TAB
        local catPanel = vgui.Create("DPanel", tabs)
        catPanel.Paint = function() end
        local catScroll = vgui.Create("DScrollPanel", catPanel)
        catScroll:Dock(FILL)
        catScroll:DockMargin(10, 10, 10, 10)

        for _, cat in ipairs(categoryDefs) do
            local row = vgui.Create("DPanel", catScroll)
            row:Dock(TOP)
            row:SetTall(40)
            row:DockMargin(0, 0, 0, 5)
            row.Paint = function(s, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(50, 50, 50)) end
            local lbl = vgui.Create("DLabel", row)
            lbl:Dock(LEFT)
            lbl:SetWide(100)
            lbl:DockMargin(10, 0, 10, 0)
            lbl:SetText(cat.name)
            lbl:SetContentAlignment(4)
            local picker = CreateParticlePicker(row, WEAPON_CATEGORY_CONFIG[cat.id] or "AC_muzzle_pistol", function(particle)
                WEAPON_CATEGORY_CONFIG[cat.id] = particle
                SaveConfig()
            end)
            picker:Dock(FILL)
            picker:DockMargin(0, 6, 10, 6)
        end

        local applyBtn = vgui.Create("DButton", catPanel)
        applyBtn:Dock(BOTTOM)
        applyBtn:SetTall(30)
        applyBtn:DockMargin(10, 0, 10, 10)
        applyBtn:SetText("Apply Categories to All Weapons")
        applyBtn.DoClick = function() MUZZLE_CONFIG = {} AutoApplyAll() end

        tabs:AddSheet("Categories", catPanel, "icon16/chart_organisation.png")

        -- WEAPONS TAB (full)
        local wepPanel = vgui.Create("DPanel", tabs)
        wepPanel.Paint = function() end
        local searchRow = vgui.Create("DPanel", wepPanel)
        searchRow:Dock(TOP)
        searchRow:SetTall(30)
        searchRow:DockMargin(10, 10, 10, 0)
        searchRow.Paint = function() end
        local searchIcon = vgui.Create("DLabel", searchRow)
        searchIcon:Dock(LEFT)
        searchIcon:SetWide(60)
        searchIcon:SetText("Search:")
        searchIcon:SetContentAlignment(4)
        searchIcon:SetTextColor(Color(200, 200, 200))
        local searchBar = vgui.Create("DTextEntry", searchRow)
        searchBar:Dock(FILL)
        searchBar:SetPlaceholderText("Type to filter weapons...")

        local wepList = vgui.Create("DListView", wepPanel)
        wepList:Dock(LEFT)
        wepList:SetWide(350)
        wepList:DockMargin(10, 5, 5, 10)
        wepList:AddColumn("Weapon"):SetWidth(200)
        wepList:AddColumn("Particle")
        wepList:SetMultiSelect(false)

        local selWep = nil

        local function RefreshWL(filter)
            wepList:Clear()
            local search = filter and string.lower(string.Trim(filter)) or ""
            for w, p in SortedPairs(MUZZLE_CONFIG) do
                if search == "" or string.find(string.lower(w), search, 1, true) or string.find(string.lower(p), search, 1, true) then
                    wepList:AddLine(w, p)
                end
            end
        end

        searchBar.OnChange = function(self)
            RefreshWL(self:GetValue())
        end

        local rightPanel = vgui.Create("DPanel", wepPanel)
        rightPanel:Dock(FILL)
        rightPanel:DockMargin(5, 5, 10, 10)
        rightPanel.Paint = function() end

        local selLabel = vgui.Create("DLabel", rightPanel)
        selLabel:Dock(TOP)
        selLabel:SetTall(20)
        selLabel:SetText("Selected: (none)")
        selLabel:SetTextColor(Color(255, 200, 100))

        local customBox = vgui.Create("DPanel", rightPanel)
        customBox:Dock(TOP)
        customBox:SetTall(60)
        customBox:DockMargin(0, 5, 0, 5)
        customBox.Paint = function(s, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(40, 60, 40)) end

        local customLabel = vgui.Create("DLabel", customBox)
        customLabel:Dock(TOP)
        customLabel:DockMargin(5, 3, 5, 0)
        customLabel:SetText("Type ANY particle name:")
        customLabel:SetTextColor(Color(100, 255, 100))

        local customRow = vgui.Create("DPanel", customBox)
        customRow:Dock(TOP)
        customRow:SetTall(25)
        customRow:DockMargin(5, 3, 5, 5)
        customRow.Paint = function() end

        local wepCustomEntry = vgui.Create("DTextEntry", customRow)
        wepCustomEntry:Dock(LEFT)
        wepCustomEntry:SetWide(280)
        wepCustomEntry:SetPlaceholderText("e.g. my_custom_muzzle_flash")

        local wepCustomBtn = vgui.Create("DButton", customRow)
        wepCustomBtn:Dock(LEFT)
        wepCustomBtn:SetWide(100)
        wepCustomBtn:DockMargin(5, 0, 0, 0)
        wepCustomBtn:SetText("Apply Custom")
        wepCustomBtn:SetTextColor(Color(100, 255, 100))
        wepCustomBtn.DoClick = function()
            if not selWep then return end
            local customName = CleanParticleName(wepCustomEntry:GetValue())
            if customName ~= "" then
                pcall(PrecacheParticleSystem, customName)
                AddAvailableParticle(customName)
                MUZZLE_CONFIG[selWep] = customName
                SaveConfig()
                RefreshWL(searchBar:GetValue())
                wepCustomEntry:SetValue("")
            end
        end
        wepCustomEntry.OnEnter = function() wepCustomBtn:DoClick() end

        local pScroll = vgui.Create("DScrollPanel", rightPanel)
        pScroll:Dock(FILL)

        local nBtn = vgui.Create("DButton", pScroll)
        nBtn:Dock(TOP)
        nBtn:SetTall(25)
        nBtn:SetText("none (Disable muzzleflash)")
        nBtn:SetTextColor(Color(255, 100, 100))
        nBtn.DoClick = function()
            if selWep then MUZZLE_CONFIG[selWep] = "none" SaveConfig() RefreshWL(searchBar:GetValue()) end
        end

        for _, p in ipairs(AVAILABLE_PARTICLES) do
            local b = vgui.Create("DButton", pScroll)
            b:Dock(TOP)
            b:SetTall(25)
            b:DockMargin(0, 0, 0, 1)
            b:SetText(p)
            b.DoClick = function()
                if selWep then MUZZLE_CONFIG[selWep] = p SaveConfig() RefreshWL(searchBar:GetValue()) end
            end
        end

        wepList.OnRowSelected = function(l, i, r)
            selWep = r:GetColumnText(1)
            selLabel:SetText("Selected: " .. selWep)
        end

        wepList.OnRowRightClick = function(l, i, r)
            local m = DermaMenu()
            m:AddOption("Remove Override", function()
                MUZZLE_CONFIG[r:GetColumnText(1)] = nil
                SaveConfig()
                RefreshWL(searchBar:GetValue())
            end)
            m:Open()
        end

        RefreshWL()

        tabs:AddSheet("Weapons", wepPanel, "icon16/gun.png")

        -- PATTERNS TAB (simplified but functional)
        local patPanel = vgui.Create("DPanel", tabs)
        patPanel.Paint = function() end
        local patList = vgui.Create("DListView", patPanel)
        patList:Dock(FILL)
        patList:DockMargin(10, 10, 10, 5)
        patList:AddColumn("Pattern"):SetWidth(200)
        patList:AddColumn("Particle")

        local function RefreshPL()
            patList:Clear()
            for p, v in SortedPairs(CLASS_BASED_CONFIG) do patList:AddLine(p, v) end
        end

        local patCtrl = vgui.Create("DPanel", patPanel)
        patCtrl:Dock(BOTTOM)
        patCtrl:SetTall(70)
        patCtrl:DockMargin(10, 0, 10, 10)
        patCtrl.Paint = function(s, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(40, 40, 60)) end

        local patTopRow = vgui.Create("DPanel", patCtrl)
        patTopRow:Dock(TOP)
        patTopRow:SetTall(30)
        patTopRow:DockMargin(5, 5, 5, 0)
        patTopRow.Paint = function() end

        local patIn = vgui.Create("DTextEntry", patTopRow)
        patIn:Dock(LEFT)
        patIn:SetWide(200)
        patIn:SetPlaceholderText("Pattern...")

        local patCmb = vgui.Create("DComboBox", patTopRow)
        patCmb:Dock(LEFT)
        patCmb:SetWide(200)
        patCmb:DockMargin(10, 0, 0, 0)
        patCmb:SetValue("Select particle...")
        patCmb:AddChoice("none")
        for _, p in ipairs(AVAILABLE_PARTICLES) do patCmb:AddChoice(p) end

        local patAdd = vgui.Create("DButton", patTopRow)
        patAdd:Dock(LEFT)
        patAdd:SetWide(80)
        patAdd:DockMargin(5, 0, 0, 0)
        patAdd:SetText("Add")
        patAdd.DoClick = function()
            local pat = string.Trim(patIn:GetValue())
            local _, part = patCmb:GetSelected()
            if pat ~= "" and part then
                CLASS_BASED_CONFIG[pat] = part
                SaveConfig()
                RefreshPL()
            end
        end

        RefreshPL()
        tabs:AddSheet("Patterns", patPanel, "icon16/script.png")

        -- ==================== FULL PCF MANAGER ====================
        local pcfPanel = vgui.Create("DPanel", tabs)
        pcfPanel.Paint = function() end

        local pcfHeader = vgui.Create("DLabel", pcfPanel)
        pcfHeader:Dock(TOP)
        pcfHeader:SetTall(25)
        pcfHeader:DockMargin(10, 10, 10, 5)
        pcfHeader:SetText("PCF Manager - Register custom .pcf files and particles")
        pcfHeader:SetFont("DermaDefaultBold")
        pcfHeader:SetTextColor(Color(100, 255, 100))

        -- List of registered PCFs
        local pcfList = vgui.Create("DListView", pcfPanel)
        pcfList:Dock(TOP)
        pcfList:SetTall(180)
        pcfList:DockMargin(10, 5, 10, 5)
        pcfList:AddColumn("PCF File"):SetWidth(380)
        pcfList:AddColumn("Particles"):SetWidth(80)

        local function RefreshPCFList()
            pcfList:Clear()
            for pcfPath, names in pairs(PCF_REGISTRY) do
                if not IsSpecialRegistryKey(pcfPath) then
                    local count = istable(names) and #names or 0
                    pcfList:AddLine(pcfPath, tostring(count))
                end
            end
        end

        RefreshPCFList()

        -- Add new PCF section
        local addRow = vgui.Create("DPanel", pcfPanel)
        addRow:Dock(TOP)
        addRow:SetTall(32)
        addRow:DockMargin(10, 5, 10, 5)
        addRow.Paint = function() end

        local pcfPathEntry = vgui.Create("DTextEntry", addRow)
        pcfPathEntry:Dock(LEFT)
        pcfPathEntry:SetWide(380)
        pcfPathEntry:SetPlaceholderText("particles/your_custom_effects.pcf")

        local addBtn = vgui.Create("DButton", addRow)
        addBtn:Dock(LEFT)
        addBtn:SetWide(100)
        addBtn:DockMargin(8, 0, 0, 0)
        addBtn:SetText("Add PCF")
        addBtn:SetTextColor(Color(100, 255, 100))

        addBtn.DoClick = function()
            local path = string.Trim(pcfPathEntry:GetValue())
            if path == "" then return end
            if not string.EndsWith(path, ".pcf") then path = path .. ".pcf" end
            if not string.StartWith(path, "particles/") then path = "particles/" .. path end

            if PCF_REGISTRY[path] then
                Derma_Message("PCF already registered.", "PCF Manager", "OK")
                return
            end

            -- Register locally
            PCF_REGISTRY[path] = {}

            -- Add particles on client
            pcall(function() game.AddParticles(path) end)

            -- Try to send to server (admin only)
            if LocalPlayer():IsAdmin() or LocalPlayer():IsSuperAdmin() then
                net.Start("MuzzleReplacer_SyncPCF")
                net.WriteString(path)
                net.SendToServer()
            end

            -- Refresh lists
            RefreshPCFList()
            ScanForParticles()   -- update available particles
            pcfPathEntry:SetValue("")
            Derma_Message("PCF registered: " .. path .. "\nParticles will appear in lists after refresh.", "PCF Manager", "OK")
        end

        pcfPathEntry.OnEnter = function() addBtn:DoClick() end

        -- Particle list from registry + manual add
        local particleListHeader = vgui.Create("DLabel", pcfPanel)
        particleListHeader:Dock(TOP)
        particleListHeader:DockMargin(10, 10, 10, 3)
        particleListHeader:SetText("Registered Particles (from PCFs)")
        particleListHeader:SetTextColor(Color(200, 200, 200))

        local particleScroll = vgui.Create("DScrollPanel", pcfPanel)
        particleScroll:Dock(FILL)
        particleScroll:DockMargin(10, 0, 10, 5)

        local particleList = vgui.Create("DListView", particleScroll)
        particleList:Dock(FILL)
        particleList:AddColumn("Particle Name"):SetWidth(420)
        particleList:AddColumn("Source"):SetWidth(120)

        local function RefreshParticleList()
            particleList:Clear()
            for pcfPath, names in pairs(PCF_REGISTRY) do
                if not IsSpecialRegistryKey(pcfPath) and istable(names) then
                    for _, name in ipairs(names) do
                        particleList:AddLine(name, pcfPath)
                    end
                end
            end
            -- Also show runtime particles that aren't in registry
            for _, name in ipairs(AVAILABLE_PARTICLES) do
                local found = false
                for pcfPath, names in pairs(PCF_REGISTRY) do
                    if istable(names) and table.HasValue(names, name) then
                        found = true
                        break
                    end
                end
                if not found then
                    particleList:AddLine(name, "(manual / other)")
                end
            end
        end

        RefreshParticleList()

        -- Manual particle add
        local manualRow = vgui.Create("DPanel", pcfPanel)
        manualRow:Dock(BOTTOM)
        manualRow:SetTall(32)
        manualRow:DockMargin(10, 5, 10, 10)
        manualRow.Paint = function() end

        local manualEntry = vgui.Create("DTextEntry", manualRow)
        manualEntry:Dock(LEFT)
        manualEntry:SetWide(300)
        manualEntry:SetPlaceholderText("e.g. my_custom_muzzle or AC_muzzle_custom")

        local addParticleBtn = vgui.Create("DButton", manualRow)
        addParticleBtn:Dock(LEFT)
        addParticleBtn:SetWide(110)
        addParticleBtn:DockMargin(8, 0, 0, 0)
        addParticleBtn:SetText("Add Particle")
        addParticleBtn:SetTextColor(Color(100, 255, 100))

        addParticleBtn.DoClick = function()
            local pname = CleanParticleName(manualEntry:GetValue())
            if pname == "" then return end

            pcall(function() PrecacheParticleSystem(pname) end)
            AddAvailableParticle(pname)

            -- Also send to server for syncing
            if LocalPlayer():IsAdmin() or LocalPlayer():IsSuperAdmin() then
                net.Start("MuzzleReplacer_SyncParticleName")
                net.WriteString(pname)
                net.SendToServer()
            end

            manualEntry:SetValue("")
            RefreshParticleList()
            ScanForParticles()
        end

        manualEntry.OnEnter = function() addParticleBtn:DoClick() end

        local refreshBtn = vgui.Create("DButton", manualRow)
        refreshBtn:Dock(RIGHT)
        refreshBtn:SetWide(90)
        refreshBtn:SetText("Refresh List")
        refreshBtn.DoClick = function()
            RefreshPCFList()
            RefreshParticleList()
            ScanForParticles()
        end

        -- Initial refresh
        RefreshPCFList()
        RefreshParticleList()

        tabs:AddSheet("PCF Manager", pcfPanel, "icon16/folder.png")

        -- TEST LAB
        local testPanel = vgui.Create("DPanel", tabs)
        testPanel.Paint = function(s, w, h) draw.RoundedBox(0, 0, 0, w, h, Color(30, 30, 30)) end

        local testRow = vgui.Create("DPanel", testPanel)
        testRow:Dock(TOP)
        testRow:SetTall(35)
        testRow:DockMargin(10, 10, 10, 5)
        testRow.Paint = function() end

        local testEntry = vgui.Create("DTextEntry", testRow)
        testEntry:Dock(LEFT)
        testEntry:SetWide(350)
        testEntry:SetPlaceholderText("Type any particle name to test...")

        local testBtn = vgui.Create("DButton", testRow)
        testBtn:Dock(LEFT)
        testBtn:SetWide(100)
        testBtn:DockMargin(10, 0, 0, 0)
        testBtn:SetText("Test Feet")
        testBtn:SetTextColor(Color(100, 255, 100))
        testBtn.DoClick = function()
            local sname = CleanParticleName(testEntry:GetValue())
            if sname == "" then return end
            pcall(PrecacheParticleSystem, sname)
            local lp = LocalPlayer()
            if IsValid(lp) then ParticleEffect(sname, lp:GetPos() + Vector(0, 0, 50), Angle(0, 0, 0)) end
        end

        tabs:AddSheet("Test Lab", testPanel, "icon16/eye.png")
    end

    concommand.Add("muzzle_replacer", OpenMuzzleReplacer)

end -- END CLIENT

-- ==================== SERVER ====================
if SERVER then
    local serverSyncedPCFs = {}
    local serverSyncedParticles = {}
    local lastPCFSyncRequest = {}
    local lastParticleSyncRequest = {}

    hook.Add("PlayerInitialSpawn", "MuzzleReplacer_Init", function(ply)
        timer.Simple(1, function()
            if not IsValid(ply) then return end
            for pcfPath, _ in pairs(serverSyncedPCFs) do
                net.Start("MuzzleReplacer_SyncPCF") net.WriteString(pcfPath) net.Send(ply)
            end
            for particleName, _ in pairs(serverSyncedParticles) do
                net.Start("MuzzleReplacer_SyncParticleName") net.WriteString(particleName) net.Send(ply)
            end
        end)
    end)

    hook.Add("PlayerDisconnected", "MuzzleReplacer_Cleanup", function(ply)
        local sid = ply:SteamID()
        lastPCFSyncRequest[sid] = nil
        lastParticleSyncRequest[sid] = nil
    end)

    net.Receive("MuzzleReplacer_SyncPCF", function(len, ply)
        if not IsValid(ply) then return end
        if not ply:IsAdmin() and not ply:IsSuperAdmin() then return end
        local sid = ply:SteamID()
        if lastPCFSyncRequest[sid] and CurTime() - lastPCFSyncRequest[sid] < 1 then return end
        lastPCFSyncRequest[sid] = CurTime()
        local pcfPath = net.ReadString()
        if pcfPath == "" or #pcfPath > 256 then return end
        if not string.StartWith(pcfPath, "particles/") or not string.EndsWith(pcfPath, ".pcf") then return end
        if string.find(pcfPath, "%.%.") or string.find(pcfPath, "//") then return end
        if serverSyncedPCFs[pcfPath] then return end
        serverSyncedPCFs[pcfPath] = true
        game.AddParticles(pcfPath)
        print("[MuzzleReplacer] Server registered PCF: " .. pcfPath)
        net.Start("MuzzleReplacer_SyncPCF") net.WriteString(pcfPath) net.SendOmit(ply)
    end)

    net.Receive("MuzzleReplacer_SyncParticleName", function(len, ply)
        if not IsValid(ply) then return end
        if not ply:IsAdmin() and not ply:IsSuperAdmin() then return end
        local sid = ply:SteamID()
        if lastParticleSyncRequest[sid] and CurTime() - lastParticleSyncRequest[sid] < 0.1 then return end
        lastParticleSyncRequest[sid] = CurTime()
        local particleName = net.ReadString()
        if particleName == "" or #particleName > 128 then return end
        if serverSyncedParticles[particleName] then return end
        serverSyncedParticles[particleName] = true
        pcall(function() PrecacheParticleSystem(particleName) end)
        print("[MuzzleReplacer] Server precached particle: " .. particleName)
        net.Start("MuzzleReplacer_SyncParticleName") net.WriteString(particleName) net.SendOmit(ply)
    end)

    print("=== MUZZLEFLASH REPLACER v2.4.1 (FULL + PERFORMANCE) LOADED ===")
end -- END SERVER

-- Note: SaveConfig() and LoadConfig() are defined early (before CLIENT UI) above.
-- The early definition is the only one needed. No trailing duplicate.