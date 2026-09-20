--@diagnostic disable: undefined-global, lowercase-global
AddCSLuaFile()

-- ============================================================
-- SHARED WEAPON HELPERS
-- (used by the client muzzleflash replacer AND by the
--  server-side tracer hook in ac_particles_remade.lua)
-- ============================================================
function AC_IsEnergyWeapon(class)
    local name = string.lower(class)

    -- Exact match for HL2 AR2
    if name == "weapon_ar2" then return true end

    -- Check for AR2 with word boundaries (underscore before/after)
    if string.find(name, "_ar2_", 1, true) then return true end
    if string.find(name, "_ar2", 1, true) and string.sub(name, -4) == "_ar2" then return true end
    if string.sub(name, 1, 4) == "ar2_" then return true end

    -- Other energy weapon keywords
    for _, kw in ipairs({"pulse","plasma","laser","energy","irifle","physcannon"}) do
        if string.find(name, kw, 1, true) then return true end
    end

    return false
end

function AC_IsSuppressedWeapon(class)
    local name = string.lower(class)
    for _, kw in ipairs({"silenced","suppressed","supressed","silencer","_sd","-sd"}) do
        if string.find(name, kw, 1, true) then return true end
    end
    if string.sub(name, -2) == "sd" then return true end
    return false
end

function AC_DetectWeaponCategory(class)
    local name = string.lower(class)

    -- Check for energy weapons FIRST with proper AR2 detection
    if AC_IsEnergyWeapon(class) then return "energy" end

    -- Other categories
    local checks = {
        {"revolver", {"revolver","357","magnum","python","deagle","desert_eagle","50ae","handcannon"}},
        {"sniper",   {"sniper","awp","awm","l96","intervention","barrett","m82","dragunov","svd","scout","mosin","kar98"}},
        {"launcher", {"rpg","launcher","m79","thumper","grenade_launcher","m32","mgl"}},
        {"shotgun",  {"shotgun","benelli","remington870","r870","mossberg","spas","nova","xm1014","sawedoff","aa12","ksg","m3"}},
        {"lmg",      {"m249","m60","pkm","negev","minigun","mg42","rpk","lmg","saw"}},
        {"smg",      {"smg","mp5","mp7","mp9","ump","uzi","mac10","vector","p90","bizon","ppsh","thompson","tmp","smg1"}},
        {"rifle",    {"ak47","ak74","m4a1","m16","scar","aug","famas","galil","g36","fal","ar15","hk416","acr","rifle","tar21","tar-21","tavor"}},
        {"pistol",   {"pistol","glock","beretta","m9","1911","usp","p226","fiveseven","sig","makarov","walther","luger"}},
    }

    for _, check in ipairs(checks) do
        for _, kw in ipairs(check[2]) do
            if string.find(name, kw, 1, true) then return check[1] end
        end
    end

    return "pistol"
end

-- ============================================================
-- SHARED NPC HELPERS
-- NPC muzzleflashes are spawned on the SERVER (EntityFireBullets
-- is reliable there and particles are networked to every client);
-- the client only suppresses the default engine flash.
-- ============================================================

-- Default particle per weapon category. The client may override these
-- via the configurator (AC_MUZZLE_CATEGORY_CONFIG); the server always
-- uses these defaults for NPC flashes.
AC_DEFAULT_CATEGORY_PARTICLES = {
    ["pistol"]   = "AC_muzzle_pistol",
    ["revolver"] = "AC_muzzle_357",
    ["smg"]      = "AC_muzzle_smg",
    ["shotgun"]  = "AC_muzzle_shotgun",
    ["rifle"]    = "AC_muzzle_ar2",
    ["sniper"]   = "AC_muzzle_357",
    ["lmg"]      = "AC_muzzle_ar2",
    ["launcher"] = "AC_muzzle_shotgun",
    ["energy"]   = "AC_muzzle_ar2",
}

-- NPCs that never fire a ranged weapon - never show a muzzleflash
AC_MELEE_NPC_KEYWORDS = {
    "zombie", "antlion", "headcrab", "crab", "bullsquid", "ichthyosaur",
    "manhack", "scanner", "rollermine", "turret", "strider", "hunter",
    "helicopter", "gunship", "pigeon", "seagull", "crow", "houndeye",
}

function AC_GetMuzzleAttachment(ent)
    if not IsValid(ent) then return 1 end
    for _, name in ipairs({"muzzle", "muzzle_flash", "muzzle_attachment", "muzzle1", "muzzle_01", "1", "0"}) do
        local id = ent:LookupAttachment(name)
        if id and id > 0 then return id end
    end
    return 1
end

function AC_GetNPCWeaponClass(npc)
    if not IsValid(npc) then return nil end

    local wep = npc:GetActiveWeapon()
    if IsValid(wep) then
        return wep:GetClass()
    end

    -- Fallback: detect from NPC class
    local npcClass = npc:GetClass():lower()

    -- Melee-only NPCs: no muzzleflash at all
    for _, kw in ipairs(AC_MELEE_NPC_KEYWORDS) do
        if string.find(npcClass, kw, 1, true) then return nil end
    end

    if string.find(npcClass, "combine", 1, true) then
        if string.find(npcClass, "elite", 1, true) then
            return "weapon_ar2"
        end
        return "weapon_smg1"
    elseif string.find(npcClass, "metropolice", 1, true) then
        return "weapon_pistol"
    elseif string.find(npcClass, "citizen", 1, true) or string.find(npcClass, "rebel", 1, true) then
        return "weapon_smg1"
    elseif string.find(npcClass, "alyx", 1, true) then
        return "weapon_pistol"
    elseif string.find(npcClass, "barney", 1, true) then
        return "weapon_pistol"
    elseif string.find(npcClass, "monk", 1, true) or string.find(npcClass, "grigori", 1, true) then
        return "weapon_shotgun"
    end

    return "weapon_smg1" -- default fallback
end

-- Particle for an NPC weapon class: category default (client overrides
-- only apply client-side; the server uses the defaults).
function AC_GetNPCParticle(wepClass)
    if not wepClass then return nil end
    local category = AC_DetectWeaponCategory(wepClass)
    local map = AC_MUZZLE_CATEGORY_CONFIG or AC_DEFAULT_CATEGORY_PARTICLES
    return map[category] or "AC_muzzle_pistol"
end

-- ============================================================
-- SUPPRESS THE DEFAULT ENGINE MUZZLE FLASH
-- GMod's stock weapon scripts call Owner:MuzzleFlash() (via
-- SWEP:ShootEffects etc.), which spawns the default light+sprite
-- muzzle flash on top of our custom particles. FireAnimationEvent
-- cannot suppress it (it's an effect, not an animation event),
-- so we intercept the method itself. It lives on the ENTITY
-- metatable, so this one patch covers:
--   * players (client: viewmodel flash) and NPCs (server: their
--     weapon scripts call it too)
--   * both realms (shared code)
-- The cl_ac_muzzleflash_disabled cvar is respected: when it's on,
-- the default flash passes through as normal.
-- ============================================================
do
    local EntityMeta = FindMetaTable("Entity")
    if EntityMeta and EntityMeta.MuzzleFlash then
        local AC_OrigMuzzleFlash = EntityMeta.MuzzleFlash

        function EntityMeta:MuzzleFlash()
            if not GetConVar("cl_ac_muzzleflash_disabled"):GetBool() then
                local wep = self.GetActiveWeapon and self:GetActiveWeapon()
                if IsValid(wep) and wep:GetClass() then
                    -- This addon replaces muzzleflashes on (almost) any
                    -- weapon; suppress the stock effect so it doesn't
                    -- overlap the custom particle.
                    return
                end
            end
            return AC_OrigMuzzleFlash(self)
        end
    end
end

-- ============================================================
-- SERVER: Precache
-- ============================================================
if SERVER then
    game.AddParticles("particles/AC_enhancer.pcf")

    PrecacheParticleSystem("AC_muzzle_357")
    PrecacheParticleSystem("AC_muzzle_ar2")
    PrecacheParticleSystem("AC_muzzle_pistol")
    PrecacheParticleSystem("AC_muzzle_shotgun")
    PrecacheParticleSystem("AC_muzzle_smg")
    PrecacheParticleSystem("AC_357_barrel_smoke")

    -- ========================================================
    -- NPC muzzleflashes (server-side)
    -- EntityFireBullets is reliable on the server for every NPC
    -- bullet, and ParticleEffectAttach there is networked to all
    -- clients in the PVS. (Client-side spawning was unreliable:
    -- animation events / prediction often never fired for NPCs.)
    -- The client still suppresses the default engine flash.
    -- ========================================================
    -- Safety net: the engine's weapon code can attach its own default
    -- muzzle flash sprite/light (env_sprite / light_dynamic) to the
    -- weapon - remove any that appear on the weapon we just flashed.
    local function RemoveDefaultMuzzleFlashEntities(weapon)
        if not IsValid(weapon) then return end
        for _, cls in ipairs({"env_sprite", "light_dynamic"}) do
            for _, e in ipairs(ents.FindByClass(cls)) do
                if IsValid(e) and e:GetParent() == weapon then
                    e:Remove()
                end
            end
        end
    end

    hook.Add("EntityFireBullets", "AC_MuzzleFlash_NPC", function(ent, data)
        if GetConVar("cl_ac_muzzleflash_disabled"):GetBool() then return end
        if not IsValid(ent) or not ent:IsNPC() then return end

        local wepClass = AC_GetNPCWeaponClass(ent)
        if not wepClass then return end -- melee NPCs etc.

        local particle = AC_GetNPCParticle(wepClass)
        if not particle or particle == "none" then return end

        -- Attach to the NPC's weapon model when it exists (its own
        -- body usually has no muzzle attachment)
        local attachEnt = ent
        local wep = ent:GetActiveWeapon()
        if IsValid(wep) then attachEnt = wep end

        local attID = AC_GetMuzzleAttachment(attachEnt)
        if attID <= 0 then return end

        ParticleEffectAttach(particle, PATTACH_POINT_FOLLOW, attachEnt, attID)

        -- Remove the stock muzzle flash sprite/light if the engine
        -- created one on this weapon (immediately + once more shortly
        -- after, since the entity may be created after our hook runs)
        RemoveDefaultMuzzleFlashEntities(attachEnt)
        timer.Simple(0.1, function()
            RemoveDefaultMuzzleFlashEntities(attachEnt)
        end)

        -- Barrel smoke, matching the client rules (no smoke for
        -- suppressed weapons or the AR2 particle)
        local noSmoke = {
            ["AC_muzzle_ar2"] = true,
            ["AC_muzzle_pistol_suppressed"] = true,
            ["none"] = true,
        }
        if not noSmoke[particle] and not AC_IsSuppressedWeapon(wepClass) then
            ParticleEffectAttach("AC_357_barrel_smoke", PATTACH_POINT_FOLLOW, attachEnt, attID)
        end
    end)
end

-- ============================================================
-- Tool Menu Entry
-- ============================================================
hook.Add("PopulateToolMenu", "AC_MuzzleFlash_Menu", function()
    spawnmenu.AddToolMenuOption("Options", "Combat", "AC_MuzzleReplacer", "AC Muzzleflash Replacer", "", "", function(panel)
        panel:ClearControls()
        panel:Help("AC Muzzleflash Replacer")
        panel:Help("Replaces all weapon muzzleflashes with custom PCF particles.")
        panel:Button("Open Configurator", "ac_muzzle_config")
    end)
end)

-- ============================================================
-- CLIENT
-- ============================================================
if CLIENT then

    game.AddParticles("particles/AC_enhancer.pcf")

    PrecacheParticleSystem("AC_muzzle_357")
    PrecacheParticleSystem("AC_muzzle_ar2")
    PrecacheParticleSystem("AC_muzzle_pistol")
    PrecacheParticleSystem("AC_muzzle_shotgun")
    PrecacheParticleSystem("AC_muzzle_smg")
    PrecacheParticleSystem("AC_357_barrel_smoke")

    -- ========================================================
    -- Tracking tables (local, no conflict)
    -- ========================================================
    local lastAmmo = {}
    local lastWeapon = {}
    local PARTICLE_COOLDOWN = 0.05

    local ar2LastAmmo = {}
    local ar2LastFire = {}
    local ar2WorldAmmo = {}
    local ar2WorldLastFire = {}

    -- Shared FX cooldown (one shot -> one particle set,
    -- regardless of whether FireAnimationEvent or ammo tracking fired first)
    local lastFXByEnt = {}

    -- ========================================================
    -- Shared FX cooldown
    -- (one shot -> one particle set, regardless of whether
    --  FireAnimationEvent or ammo tracking fired first -
    --  prevents double muzzleflashes)
    -- ========================================================
    local function FXReady(ent)
        if not IsValid(ent) then return false end
        local now = CurTime()
        local last = lastFXByEnt[ent]
        if last and (now - last) < PARTICLE_COOLDOWN then return false end
        lastFXByEnt[ent] = now
        return true
    end

    -- ========================================================
    -- CONFIG TABLES (unique names to avoid conflicts)
    -- ========================================================
    AC_MUZZLE_WEAPON_CONFIG = AC_MUZZLE_WEAPON_CONFIG or {}
    AC_MUZZLE_CLASS_CONFIG = AC_MUZZLE_CLASS_CONFIG or {}
    AC_MUZZLE_CATEGORY_CONFIG = AC_MUZZLE_CATEGORY_CONFIG or {
        ["pistol"]   = "AC_muzzle_pistol",
        ["revolver"] = "AC_muzzle_357",
        ["smg"]      = "AC_muzzle_smg",
        ["shotgun"]  = "AC_muzzle_shotgun",
        ["rifle"]    = "AC_muzzle_ar2",
        ["sniper"]   = "AC_muzzle_357",
        ["lmg"]      = "AC_muzzle_ar2",
        ["launcher"] = "AC_muzzle_shotgun",
        ["energy"]   = "AC_muzzle_ar2",
    }
    AC_MUZZLE_PCF_FILES = AC_MUZZLE_PCF_FILES or {}
    AC_MUZZLE_PARTICLE_NAMES = AC_MUZZLE_PARTICLE_NAMES or {}
    AC_MUZZLE_AVAILABLE_PARTICLES = AC_MUZZLE_AVAILABLE_PARTICLES or {}

    -- ========================================================
    -- BARREL SMOKE CONFIG (not in menu)
    -- ========================================================
    local BARREL_SMOKE_PARTICLE = "AC_357_barrel_smoke"

    local NO_SMOKE_PARTICLES = {
        ["AC_muzzle_ar2"] = true,
        ["AC_muzzle_pistol_suppressed"] = true,
        ["none"] = true,
    }

    local function ShouldHaveSmoke(particle)
        if not particle then return false end
        if particle == "none" then return false end
        if NO_SMOKE_PARTICLES[particle] then return false end
        return true
    end

    local function SpawnBarrelSmoke(targetEnt, attID)
        if not IsValid(targetEnt) then return end
        if not attID or attID < 1 then return end
        ParticleEffectAttach(BARREL_SMOKE_PARTICLE, PATTACH_POINT_FOLLOW, targetEnt, attID)
    end

    -- ========================================================
    -- CONFIG LOAD / SAVE (unique file names)
    -- ========================================================
    local function LoadConfig()
        if file.Exists("ac_enhancer_muzzle_config.txt", "DATA") then
            AC_MUZZLE_WEAPON_CONFIG = util.JSONToTable(file.Read("ac_enhancer_muzzle_config.txt", "DATA")) or {}
        end
        if file.Exists("ac_enhancer_class_config.txt", "DATA") then
            local loaded = util.JSONToTable(file.Read("ac_enhancer_class_config.txt", "DATA"))
            if loaded then
                for k, v in pairs(loaded) do AC_MUZZLE_CLASS_CONFIG[k] = v end
            end
        end
        if file.Exists("ac_enhancer_category_config.txt", "DATA") then
            local loaded = util.JSONToTable(file.Read("ac_enhancer_category_config.txt", "DATA"))
            if loaded then
                for k, v in pairs(loaded) do AC_MUZZLE_CATEGORY_CONFIG[k] = v end
            end
        end
        if file.Exists("ac_enhancer_pcf_config.txt", "DATA") then
            AC_MUZZLE_PCF_FILES = util.JSONToTable(file.Read("ac_enhancer_pcf_config.txt", "DATA")) or {}
        end
        if file.Exists("ac_enhancer_particle_names.txt", "DATA") then
            AC_MUZZLE_PARTICLE_NAMES = util.JSONToTable(file.Read("ac_enhancer_particle_names.txt", "DATA")) or {}
        end
    end

    local function SaveConfig()
        file.Write("ac_enhancer_muzzle_config.txt", util.TableToJSON(AC_MUZZLE_WEAPON_CONFIG))
        file.Write("ac_enhancer_class_config.txt", util.TableToJSON(AC_MUZZLE_CLASS_CONFIG))
        file.Write("ac_enhancer_category_config.txt", util.TableToJSON(AC_MUZZLE_CATEGORY_CONFIG))
        file.Write("ac_enhancer_pcf_config.txt", util.TableToJSON(AC_MUZZLE_PCF_FILES))
        file.Write("ac_enhancer_particle_names.txt", util.TableToJSON(AC_MUZZLE_PARTICLE_NAMES))
    end

    LoadConfig()

    -- ========================================================
    -- PARTICLE SCANNER
    -- ========================================================
    local function ScanForParticles()
        local found = {}
        local builtinFiles = {
            "particles/AC_enhancer.pcf",
        }
        for _, pcf in ipairs(builtinFiles) do
            if file.Exists(pcf, "GAME") then game.AddParticles(pcf) end
        end
        for _, customPCF in ipairs(AC_MUZZLE_PCF_FILES) do
            if file.Exists(customPCF, "GAME") then game.AddParticles(customPCF) end
        end

        local particles = {
            "AC_muzzle_357",
            "AC_muzzle_ar2",
            "AC_muzzle_pistol",
            "AC_muzzle_shotgun",
            "AC_muzzle_smg",
        }

        for _, name in ipairs(AC_MUZZLE_PARTICLE_NAMES) do
            local exists = false
            for _, existing in ipairs(particles) do
                if existing == name then exists = true break end
            end
            if not exists then table.insert(particles, name) end
        end

        for _, p in ipairs(particles) do
            pcall(function()
                PrecacheParticleSystem(p)
                table.insert(found, p)
            end)
        end

        return found
    end

    AC_MUZZLE_AVAILABLE_PARTICLES = ScanForParticles()

    -- ========================================================
    -- ENERGY WEAPON DETECTION (shared helper)
    -- ========================================================
    local IsEnergyWeapon = AC_IsEnergyWeapon

    -- ========================================================
    -- NPC WEAPON DETECTION
    -- (shared helper AC_GetNPCWeaponClass - see top of file;
    --  NPC muzzleflashes are spawned server-side)
    -- ========================================================
    local GetNPCWeaponClass = AC_GetNPCWeaponClass

    -- ========================================================
    -- WEAPON CATEGORY DETECTION (shared helper)
    -- ========================================================
    local DetectWeaponCategory = AC_DetectWeaponCategory

    -- ========================================================
    -- SUPPRESSED WEAPON DETECTION (shared helper)
    -- ========================================================
    local IsSuppressedWeapon = AC_IsSuppressedWeapon

    -- ========================================================
    -- GET PARTICLE FOR WEAPON (config priority)
    -- ========================================================
    local function GetWeaponParticle(wepClass)
        -- 1. Direct per-weapon override
        if AC_MUZZLE_WEAPON_CONFIG[wepClass] then return AC_MUZZLE_WEAPON_CONFIG[wepClass] end

        -- 2. Class-based pattern config (exact match)
        if AC_MUZZLE_CLASS_CONFIG[wepClass] then return AC_MUZZLE_CLASS_CONFIG[wepClass] end

        -- 3. Class-based pattern config (partial match)
        local lowerClass = string.lower(wepClass)
        for pattern, particle in pairs(AC_MUZZLE_CLASS_CONFIG) do
            if pattern ~= wepClass and string.find(lowerClass, string.lower(pattern), 1, true) then
                return particle
            end
        end

        -- 4. Category-based default
        local category = DetectWeaponCategory(wepClass)
        if AC_MUZZLE_CATEGORY_CONFIG[category] then return AC_MUZZLE_CATEGORY_CONFIG[category] end

        return "AC_muzzle_pistol"
    end

    -- ========================================================
    -- AUTO APPLY ALL WEAPONS
    -- ========================================================
    local function AutoApplyAll()
        for _, wepTable in pairs(weapons.GetList()) do
            if wepTable.ClassName then
                local category = DetectWeaponCategory(wepTable.ClassName)
                if AC_MUZZLE_CATEGORY_CONFIG[category] and not AC_MUZZLE_WEAPON_CONFIG[wepTable.ClassName] then
                    AC_MUZZLE_WEAPON_CONFIG[wepTable.ClassName] = AC_MUZZLE_CATEGORY_CONFIG[category]
                end
            end
        end
        SaveConfig()
    end

    -- ========================================================
    -- HELPERS
    -- ========================================================
    local function IsFirstPerson(ply)
        if not IsValid(ply) then return false end
        return ply:GetViewEntity() == ply and not ply:ShouldDrawLocalPlayer()
    end

    local function GetMuzzleAttachment(ent)
        if not IsValid(ent) then return 1 end
        for _, name in ipairs({"muzzle", "muzzle_flash", "muzzle_attachment", "muzzle1", "muzzle_01", "1", "0"}) do
            local id = ent:LookupAttachment(name)
            if id and id > 0 then return id end
        end
        return 1
    end

    -- ========================================================
    -- FireAnimationEvent: Suppress default + replace (PLAYERS)
    -- (NPC flashes are spawned server-side; here we only suppress
    --  the default engine flash for NPCs)
    -- ========================================================
    local muzzleEvents = {
        [5001] = true, [5003] = true, [5004] = true,
        [5011] = true, [5021] = true, [5031] = true,
        [20] = true, [21] = true, [22] = true,
        [6001] = true, [6002] = true,
        [3014] = true, [3015] = true, [3016] = true,
        [7001] = true, [7002] = true,
    }

    hook.Add("FireAnimationEvent", "AC_MuzzleFlash_Suppress", function(ent, pos, ang, event, name)
        if GetConVar("cl_ac_muzzleflash_disabled"):GetBool() then return end
        if not muzzleEvents[event] then return end

        local owner = ent:GetOwner()

        -- Handle NPC firing (NPC is the entity itself, not owner)
        if not IsValid(owner) and IsValid(ent) and ent:IsNPC() then
            owner = ent
        end

        if not IsValid(owner) then return end

        local wep = nil
        local wepClass = nil

        if owner:IsPlayer() then
            wep = owner:GetActiveWeapon()
            if IsValid(wep) then
                wepClass = wep:GetClass()
            end
        elseif owner:IsNPC() then
            wep = owner:GetActiveWeapon()
            if IsValid(wep) then
                wepClass = wep:GetClass()
            else
                wepClass = GetNPCWeaponClass(owner)
            end
        end

        if not wepClass then return end

        if IsEnergyWeapon(wepClass) then return true end

        local particle = GetWeaponParticle(wepClass)
        if not particle or particle == "none" then return true end

        -- Skip viewmodel for local player in first person
        if owner:IsPlayer() and owner == LocalPlayer() and IsFirstPerson(owner) then
            local vm = owner:GetViewModel()
            if IsValid(vm) and ent == vm then return true end
        end

        -- NPCs: their muzzleflash is spawned on the SERVER
        -- (EntityFireBullets), which networks it to every client.
        -- Here we only suppress the default engine flash.
        if owner:IsNPC() then return true end

        -- Always suppress the default engine flash, but only spawn
        -- ours once per shot (shared cooldown with the ammo tracker)
        if not FXReady(ent) then return true end

        local attID = GetMuzzleAttachment(ent)
        if attID > 0 then
            local suppressed = IsSuppressedWeapon(wepClass)
            ParticleEffectAttach(particle, PATTACH_POINT_FOLLOW, ent, attID)
            if ShouldHaveSmoke(particle) and not suppressed then
                SpawnBarrelSmoke(ent, attID)
            end
        end

        return true
    end)

    -- ========================================================
    -- EntityFireBullets: NPC flashes are handled on the SERVER
    -- (see the EntityFireBullets hook in the SERVER block at the
    --  top of this file), where it is reliable and networked to
    --  all clients. Nothing to do here.
    -- ========================================================

    -- ========================================================
    -- Helper: Check if weapon is reloading (ARC9 and other weapon bases)
    -- ========================================================
    local function IsReloading(wep)
        if not IsValid(wep) then return false end
        -- ARC9 uses GetReloading() networked bool
        if wep.GetReloading and wep:GetReloading() then return true end
        -- Check for ARC9 reload timer (fallback)
        if wep.GetReloadTime and wep:GetReloadTime() > CurTime() then return true end
        return false
    end

    -- ========================================================
    -- Think: NON-ENERGY weapons (ammo tracking) - PLAYERS ONLY
    -- ========================================================
    hook.Add("Think", "AC_MuzzleFlash_Think", function()
        if GetConVar("cl_ac_muzzleflash_disabled"):GetBool() then return end
        local curTime = CurTime()

        for _, ply in ipairs(player.GetAll()) do
            local wep = ply:GetActiveWeapon()
            if not IsValid(wep) then
                lastWeapon[ply] = nil
                goto skip_player
            end

            if lastWeapon[ply] ~= wep then
                lastWeapon[ply] = wep
                lastAmmo[wep] = nil
            end

            local class = wep:GetClass()
            if IsEnergyWeapon(class) then goto skip_player end

            local particle = GetWeaponParticle(class)
            if not particle or particle == "none" then goto skip_player end

            -- Skip if weapon is reloading (fixes fast reload muzzle flash bug in ARC9)
            if IsReloading(wep) then
                lastAmmo[wep] = wep:Clip1()
                goto skip_player
            end

            local currentAmmo = wep:Clip1()
            if currentAmmo == -1 then
                local ammoType = wep:GetPrimaryAmmoType()
                if ammoType and ammoType >= 0 then
                    currentAmmo = ply:GetAmmoCount(ammoType)
                else
                    goto skip_player
                end
            end

            if lastAmmo[wep] == nil then
                lastAmmo[wep] = currentAmmo
                goto skip_player
            end

            if currentAmmo < lastAmmo[wep] then
                local isLocal = ply == LocalPlayer()
                local isFP = isLocal and IsFirstPerson(ply)
                local isSuppressed = IsSuppressedWeapon(class)

                -- Shared cooldown: if FireAnimationEvent already handled
                -- this shot (or vice versa), don't spawn a second flash
                local fxEnt = isFP and ply:GetViewModel() or wep
                if not IsValid(fxEnt) then fxEnt = wep end

                if FXReady(fxEnt) then
                    if isFP then
                        local vm = ply:GetViewModel()
                        if IsValid(vm) then
                            local attID = GetMuzzleAttachment(vm)
                            if attID > 0 then
                                ParticleEffectAttach(particle, PATTACH_POINT_FOLLOW, vm, attID)
                                if ShouldHaveSmoke(particle) and not isSuppressed then
                                    SpawnBarrelSmoke(vm, attID)
                                end
                            end
                        end
                    else
                        local attID = GetMuzzleAttachment(wep)
                        if attID > 0 then
                            ParticleEffectAttach(particle, PATTACH_POINT_FOLLOW, wep, attID)
                            if ShouldHaveSmoke(particle) and not isSuppressed then
                                SpawnBarrelSmoke(wep, attID)
                            end
                        end
                    end
                end
            end

            lastAmmo[wep] = currentAmmo
            ::skip_player::
        end
    end)

    -- ========================================================
    -- Think: ENERGY / AR2 - Viewmodel (first person)
    -- ========================================================
    hook.Add("Think", "AC_MuzzleFlash_AR2_Viewmodel", function()
        if GetConVar("cl_ac_muzzleflash_disabled"):GetBool() then return end
        local ply = LocalPlayer()
        if not IsValid(ply) then return end
        if not IsFirstPerson(ply) then return end

        local wep = ply:GetActiveWeapon()
        if not IsValid(wep) then
            ar2LastAmmo[ply] = nil
            return
        end

        if not IsEnergyWeapon(wep:GetClass()) then
            ar2LastAmmo[ply] = nil
            return
        end

        local currentAmmo = wep:Clip1()
        if currentAmmo < 0 then return end

        if ar2LastAmmo[ply] == nil then
            ar2LastAmmo[ply] = currentAmmo
            return
        end

        if currentAmmo < ar2LastAmmo[ply] then
            local curTime = CurTime()
            local key = ply:EntIndex()

            if not ar2LastFire[key] or curTime - ar2LastFire[key] > PARTICLE_COOLDOWN then
                ar2LastFire[key] = curTime

                local particle = GetWeaponParticle(wep:GetClass())
                if particle and particle ~= "none" then
                    local vm = ply:GetViewModel()
                    if IsValid(vm) then
                        local attID = GetMuzzleAttachment(vm)
                        if attID > 0 then
                            vm:StopParticles()
                            ParticleEffectAttach(particle, PATTACH_POINT_FOLLOW, vm, attID)
                        end
                    end
                end
            end
        end

        ar2LastAmmo[ply] = currentAmmo
    end)

    -- ========================================================
    -- Think: ENERGY / AR2 - Worldmodel (third person / others / NPCs)
    -- ========================================================
    hook.Add("Think", "AC_MuzzleFlash_AR2_Worldmodel", function()
        if GetConVar("cl_ac_muzzleflash_disabled"):GetBool() then return end
        local curTime = CurTime()

        -- Players
        for _, ply in ipairs(player.GetAll()) do
            if ply == LocalPlayer() and IsFirstPerson(ply) then goto skip_ar2_player end

            local wep = ply:GetActiveWeapon()
            if not IsValid(wep) then
                ar2WorldAmmo[ply] = nil
                goto skip_ar2_player
            end

            if not IsEnergyWeapon(wep:GetClass()) then
                ar2WorldAmmo[ply] = nil
                goto skip_ar2_player
            end

            local currentAmmo = wep:Clip1()
            if currentAmmo < 0 then goto skip_ar2_player end

            if ar2WorldAmmo[ply] == nil then
                ar2WorldAmmo[ply] = currentAmmo
                goto skip_ar2_player
            end

            if currentAmmo < ar2WorldAmmo[ply] then
                local key = ply:EntIndex()

                if not ar2WorldLastFire[key] or curTime - ar2WorldLastFire[key] > PARTICLE_COOLDOWN then
                    ar2WorldLastFire[key] = curTime

                    local particle = GetWeaponParticle(wep:GetClass())
                    if particle and particle ~= "none" then
                        local attID = GetMuzzleAttachment(wep)
                        if attID > 0 then
                            wep:StopParticles()
                            ParticleEffectAttach(particle, PATTACH_POINT_FOLLOW, wep, attID)
                        end
                    end
                end
            end

            ar2WorldAmmo[ply] = currentAmmo
            ::skip_ar2_player::
        end
    end)

    -- ========================================================
    -- NPC SOUND HOOK - removed
    -- (NPC flashes are spawned server-side; the client no longer
    --  needs sound-based detection)
    -- ========================================================

    -- ========================================================
    -- CLEANUP
    -- ========================================================
    timer.Create("AC_MuzzleFlash_Cleanup", 5, 0, function()
        for wep, _ in pairs(lastAmmo) do
            if not IsValid(wep) then
                lastAmmo[wep] = nil
            end
        end
        for ply, _ in pairs(lastWeapon) do
            if not IsValid(ply) then lastWeapon[ply] = nil end
        end
        for ent, _ in pairs(lastFXByEnt) do
            if not IsValid(ent) then lastFXByEnt[ent] = nil end
        end
        for key, _ in pairs(ar2LastFire) do
            if not IsValid(Entity(key)) then ar2LastFire[key] = nil end
        end
        for ply, _ in pairs(ar2LastAmmo) do
            if not IsValid(ply) then ar2LastAmmo[ply] = nil end
        end
        for key, _ in pairs(ar2WorldLastFire) do
            if not IsValid(Entity(key)) then ar2WorldLastFire[key] = nil end
        end
        for ply, _ in pairs(ar2WorldAmmo) do
            if not IsValid(ply) then ar2WorldAmmo[ply] = nil end
        end
    end)

    -- ========================================================
    -- UI: CONFIGURATOR
    -- ========================================================
    local function OpenConfigurator()
        local frame = vgui.Create("DFrame")
        frame:SetSize(900, 700)
        frame:Center()
        frame:SetTitle("AC Muzzleflash Replacer - Configuration")
        frame:MakePopup()
        frame:SetDeleteOnClose(true)

        local tabs = vgui.Create("DPropertySheet", frame)
        tabs:Dock(FILL)
        tabs:DockMargin(5, 5, 5, 5)

        -- ==========================
        -- TAB 1: CATEGORIES
        -- ==========================
        local catPanel = vgui.Create("DPanel", tabs)
        catPanel.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, Color(30, 30, 30))
        end

        local catHeader = vgui.Create("DLabel", catPanel)
        catHeader:Dock(TOP)
        catHeader:DockMargin(10, 10, 10, 5)
        catHeader:SetText("Set the default muzzleflash particle for each weapon category.")
        catHeader:SetFont("DermaDefaultBold")
        catHeader:SetTextColor(Color(200, 200, 200))
        catHeader:SizeToContents()

        local catScroll = vgui.Create("DScrollPanel", catPanel)
        catScroll:Dock(FILL)
        catScroll:DockMargin(10, 5, 10, 10)

        local categories = {
            {id = "pistol",   name = "Pistols"},
            {id = "revolver", name = "Revolvers / Magnums"},
            {id = "smg",      name = "SMGs"},
            {id = "shotgun",  name = "Shotguns"},
            {id = "rifle",    name = "Rifles"},
            {id = "sniper",   name = "Snipers"},
            {id = "lmg",      name = "LMGs / Machine Guns"},
            {id = "launcher", name = "Launchers"},
            {id = "energy",   name = "Energy / AR2"},
        }

        for _, cat in ipairs(categories) do
            local row = vgui.Create("DPanel", catScroll)
            row:Dock(TOP)
            row:SetTall(40)
            row:DockMargin(0, 0, 0, 5)
            row.Paint = function(s, w, h)
                draw.RoundedBox(4, 0, 0, w, h, Color(50, 50, 50))
            end

            local lbl = vgui.Create("DLabel", row)
            lbl:SetPos(10, 10)
            lbl:SetText(cat.name)
            lbl:SetFont("DermaDefaultBold")
            lbl:SizeToContents()

            local combo = vgui.Create("DComboBox", row)
            combo:SetPos(200, 8)
            combo:SetSize(350, 24)
            combo:SetValue(AC_MUZZLE_CATEGORY_CONFIG[cat.id] or "AC_muzzle_pistol")
            combo:AddChoice("none")
            for _, p in ipairs(AC_MUZZLE_AVAILABLE_PARTICLES) do
                combo:AddChoice(p)
            end
            combo.OnSelect = function(s, i, v)
                AC_MUZZLE_CATEGORY_CONFIG[cat.id] = v
                SaveConfig()
            end
        end

        local applyAllBtn = vgui.Create("DButton", catPanel)
        applyAllBtn:Dock(BOTTOM)
        applyAllBtn:SetTall(35)
        applyAllBtn:DockMargin(10, 0, 10, 10)
        applyAllBtn:SetText("Apply Categories to All Weapons")
        applyAllBtn:SetFont("DermaDefaultBold")
        applyAllBtn.DoClick = function()
            AC_MUZZLE_WEAPON_CONFIG = {}
            AutoApplyAll()
            chat.AddText(Color(100, 255, 100), "[AC Muzzleflash] ", Color(255, 255, 255), "Applied category defaults to all weapons.")
        end

        tabs:AddSheet("Categories", catPanel, "icon16/chart_organisation.png")

        -- ==========================
        -- TAB 2: PER-WEAPON
        -- ==========================
        local wepPanel = vgui.Create("DPanel", tabs)
        wepPanel.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, Color(30, 30, 30))
        end

        local wepList = vgui.Create("DListView", wepPanel)
        wepList:Dock(LEFT)
        wepList:SetWide(350)
        wepList:DockMargin(10, 10, 5, 10)
        wepList:AddColumn("Weapon Class")
        wepList:AddColumn("Particle")
        wepList:SetMultiSelect(false)

        local selectedWeapon = nil

        local function RefreshWeaponList()
            wepList:Clear()

            local allWeapons = {}
            for _, wepTable in pairs(weapons.GetList()) do
                if wepTable.ClassName then
                    allWeapons[wepTable.ClassName] = true
                end
            end

            for _, ply in ipairs(player.GetAll()) do
                local w = ply:GetActiveWeapon()
                if IsValid(w) then
                    allWeapons[w:GetClass()] = true
                end
                for _, w2 in ipairs(ply:GetWeapons()) do
                    if IsValid(w2) then
                        allWeapons[w2:GetClass()] = true
                    end
                end
            end

            for class, _ in SortedPairs(allWeapons) do
                local particle = AC_MUZZLE_WEAPON_CONFIG[class] or GetWeaponParticle(class)
                local line = wepList:AddLine(class, particle)
                if AC_MUZZLE_WEAPON_CONFIG[class] then
                    line:SetColumnText(2, particle .. " (custom)")
                end
            end
        end

        wepList.OnRowSelected = function(lst, idx, row)
            selectedWeapon = row:GetColumnText(1)
        end

        local pSelectPanel = vgui.Create("DPanel", wepPanel)
        pSelectPanel:Dock(FILL)
        pSelectPanel:DockMargin(5, 10, 10, 10)
        pSelectPanel.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, Color(40, 40, 40))
        end

        local pLabel = vgui.Create("DLabel", pSelectPanel)
        pLabel:Dock(TOP)
        pLabel:DockMargin(10, 10, 10, 5)
        pLabel:SetText("Select a weapon, then click a particle to assign:")
        pLabel:SetFont("DermaDefaultBold")
        pLabel:SetTextColor(Color(200, 200, 200))
        pLabel:SizeToContents()

        local pScroll = vgui.Create("DScrollPanel", pSelectPanel)
        pScroll:Dock(FILL)
        pScroll:DockMargin(5, 5, 5, 5)

        local noneBtn = vgui.Create("DButton", pScroll)
        noneBtn:Dock(TOP)
        noneBtn:SetTall(30)
        noneBtn:DockMargin(5, 2, 5, 2)
        noneBtn:SetText("none (Disable Muzzleflash)")
        noneBtn:SetTextColor(Color(255, 100, 100))
        noneBtn.DoClick = function()
            if selectedWeapon then
                AC_MUZZLE_WEAPON_CONFIG[selectedWeapon] = "none"
                SaveConfig()
                RefreshWeaponList()
                chat.AddText(Color(255, 150, 100), "[AC Muzzleflash] ", Color(255, 255, 255), "Disabled muzzleflash for: " .. selectedWeapon)
            end
        end

        local resetBtn = vgui.Create("DButton", pScroll)
        resetBtn:Dock(TOP)
        resetBtn:SetTall(30)
        resetBtn:DockMargin(5, 2, 5, 2)
        resetBtn:SetText("Reset to Default (Use Category)")
        resetBtn:SetTextColor(Color(100, 255, 100))
        resetBtn.DoClick = function()
            if selectedWeapon then
                AC_MUZZLE_WEAPON_CONFIG[selectedWeapon] = nil
                SaveConfig()
                RefreshWeaponList()
                chat.AddText(Color(100, 255, 100), "[AC Muzzleflash] ", Color(255, 255, 255), "Reset to default for: " .. selectedWeapon)
            end
        end

        for _, p in ipairs(AC_MUZZLE_AVAILABLE_PARTICLES) do
            local btn = vgui.Create("DButton", pScroll)
            btn:Dock(TOP)
            btn:SetTall(28)
            btn:DockMargin(5, 2, 5, 2)
            btn:SetText(p)
            btn.DoClick = function()
                if selectedWeapon then
                    AC_MUZZLE_WEAPON_CONFIG[selectedWeapon] = p
                    SaveConfig()
                    RefreshWeaponList()
                    chat.AddText(Color(100, 200, 255), "[AC Muzzleflash] ", Color(255, 255, 255), selectedWeapon .. " → " .. p)
                end
            end
        end

        RefreshWeaponList()

        local refreshBtn = vgui.Create("DButton", wepPanel)
        refreshBtn:Dock(BOTTOM)
        refreshBtn:SetTall(30)
        refreshBtn:DockMargin(10, 0, 10, 10)
        refreshBtn:SetText("Refresh Weapon List")
        refreshBtn.DoClick = function() RefreshWeaponList() end

        tabs:AddSheet("Weapons", wepPanel, "icon16/gun.png")

        -- ==========================
        -- TAB 3: PATTERNS
        -- ==========================
        local patPanel = vgui.Create("DPanel", tabs)
        patPanel.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, Color(30, 30, 30))
        end

        local patHeader = vgui.Create("DLabel", patPanel)
        patHeader:Dock(TOP)
        patHeader:DockMargin(10, 10, 10, 5)
        patHeader:SetText("Pattern matching: Any weapon class containing the pattern will use the assigned particle.")
        patHeader:SetFont("DermaDefaultBold")
        patHeader:SetTextColor(Color(200, 200, 200))
        patHeader:SizeToContents()

        local patList = vgui.Create("DListView", patPanel)
        patList:Dock(FILL)
        patList:DockMargin(10, 5, 10, 50)
        patList:AddColumn("Pattern")
        patList:AddColumn("Particle")

        local function RefreshPatternList()
            patList:Clear()
            for pattern, particle in SortedPairs(AC_MUZZLE_CLASS_CONFIG) do
                patList:AddLine(pattern, particle)
            end
        end

        patList.OnRowRightClick = function(lst, idx, row)
            local menu = DermaMenu()
            menu:AddOption("Remove", function()
                AC_MUZZLE_CLASS_CONFIG[row:GetColumnText(1)] = nil
                SaveConfig()
                RefreshPatternList()
            end)
            menu:Open()
        end

        local patCtrl = vgui.Create("DPanel", patPanel)
        patCtrl:Dock(BOTTOM)
        patCtrl:SetTall(40)
        patCtrl:DockMargin(10, 0, 10, 10)
        patCtrl.Paint = function() end

        local patInput = vgui.Create("DTextEntry", patCtrl)
        patInput:Dock(LEFT)
        patInput:SetWide(200)
        patInput:SetPlaceholderText("Pattern (e.g. ak47, m4a1)")

        local patCombo = vgui.Create("DComboBox", patCtrl)
        patCombo:Dock(LEFT)
        patCombo:SetWide(250)
        patCombo:DockMargin(5, 0, 0, 0)
        patCombo:SetValue("Select Particle")
        patCombo:AddChoice("none")
        for _, p in ipairs(AC_MUZZLE_AVAILABLE_PARTICLES) do
            patCombo:AddChoice(p)
        end

        local patAddBtn = vgui.Create("DButton", patCtrl)
        patAddBtn:Dock(LEFT)
        patAddBtn:SetWide(100)
        patAddBtn:DockMargin(5, 0, 0, 0)
        patAddBtn:SetText("Add Pattern")
        patAddBtn.DoClick = function()
            local pat = patInput:GetValue()
            local _, part = patCombo:GetSelected()
            if pat ~= "" and part then
                AC_MUZZLE_CLASS_CONFIG[pat] = part
                SaveConfig()
                RefreshPatternList()
                patInput:SetValue("")
                chat.AddText(Color(100, 200, 255), "[AC Muzzleflash] ", Color(255, 255, 255), "Pattern added: " .. pat .. " → " .. part)
            end
        end

        RefreshPatternList()

        tabs:AddSheet("Patterns", patPanel, "icon16/script.png")

        -- ==========================
        -- TAB 4: PCF MANAGER
        -- ==========================
        local pcfPanel = vgui.Create("DPanel", tabs)
        pcfPanel.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, Color(30, 30, 30))
        end

        local pcfLabel = vgui.Create("DLabel", pcfPanel)
        pcfLabel:Dock(TOP)
        pcfLabel:DockMargin(10, 10, 10, 5)
        pcfLabel:SetText("Custom PCF Files (add your own .pcf files)")
        pcfLabel:SetFont("DermaDefaultBold")
        pcfLabel:SetTextColor(Color(200, 200, 200))
        pcfLabel:SizeToContents()

        local pcfList = vgui.Create("DListView", pcfPanel)
        pcfList:Dock(TOP)
        pcfList:SetTall(120)
        pcfList:DockMargin(10, 5, 10, 5)
        pcfList:AddColumn("PCF File Path")
        for _, pcf in ipairs(AC_MUZZLE_PCF_FILES) do
            pcfList:AddLine(pcf)
        end

        pcfList.OnRowRightClick = function(lst, idx, row)
            local menu = DermaMenu()
            menu:AddOption("Remove", function()
                for j, pcf in ipairs(AC_MUZZLE_PCF_FILES) do
                    if pcf == row:GetColumnText(1) then
                        table.remove(AC_MUZZLE_PCF_FILES, j)
                        break
                    end
                end
                SaveConfig()
                lst:RemoveLine(idx)
                AC_MUZZLE_AVAILABLE_PARTICLES = ScanForParticles()
            end)
            menu:Open()
        end

        local pcfCtrl = vgui.Create("DPanel", pcfPanel)
        pcfCtrl:Dock(TOP)
        pcfCtrl:SetTall(30)
        pcfCtrl:DockMargin(10, 0, 10, 10)
        pcfCtrl.Paint = function() end

        local pcfInput = vgui.Create("DTextEntry", pcfCtrl)
        pcfInput:Dock(FILL)
        pcfInput:DockMargin(0, 0, 5, 0)
        pcfInput:SetPlaceholderText("particles/my_custom.pcf")

        local pcfAddBtn = vgui.Create("DButton", pcfCtrl)
        pcfAddBtn:Dock(RIGHT)
        pcfAddBtn:SetWide(100)
        pcfAddBtn:SetText("Add PCF")
        pcfAddBtn.DoClick = function()
            local path = pcfInput:GetValue()
            if path ~= "" and not table.HasValue(AC_MUZZLE_PCF_FILES, path) then
                table.insert(AC_MUZZLE_PCF_FILES, path)
                SaveConfig()
                pcfList:AddLine(path)
                pcfInput:SetValue("")
                AC_MUZZLE_AVAILABLE_PARTICLES = ScanForParticles()
                chat.AddText(Color(100, 200, 255), "[AC Muzzleflash] ", Color(255, 255, 255), "Added PCF: " .. path)
            end
        end

        local pnLabel = vgui.Create("DLabel", pcfPanel)
        pnLabel:Dock(TOP)
        pnLabel:DockMargin(10, 10, 10, 5)
        pnLabel:SetText("Custom Particle Names (names inside your PCF files)")
        pnLabel:SetFont("DermaDefaultBold")
        pnLabel:SetTextColor(Color(200, 200, 200))
        pnLabel:SizeToContents()

        local pnList = vgui.Create("DListView", pcfPanel)
        pnList:Dock(FILL)
        pnList:DockMargin(10, 5, 10, 5)
        pnList:AddColumn("Particle Name")
        for _, n in ipairs(AC_MUZZLE_PARTICLE_NAMES) do
            pnList:AddLine(n)
        end

        pnList.OnRowRightClick = function(lst, idx, row)
            local menu = DermaMenu()
            menu:AddOption("Remove", function()
                for j, n in ipairs(AC_MUZZLE_PARTICLE_NAMES) do
                    if n == row:GetColumnText(1) then
                        table.remove(AC_MUZZLE_PARTICLE_NAMES, j)
                        break
                    end
                end
                SaveConfig()
                lst:RemoveLine(idx)
                AC_MUZZLE_AVAILABLE_PARTICLES = ScanForParticles()
            end)
            menu:Open()
        end

        local pnCtrl = vgui.Create("DPanel", pcfPanel)
        pnCtrl:Dock(BOTTOM)
        pnCtrl:SetTall(30)
        pnCtrl:DockMargin(10, 0, 10, 10)
        pnCtrl.Paint = function() end

        local pnInput = vgui.Create("DTextEntry", pnCtrl)
        pnInput:Dock(FILL)
        pnInput:DockMargin(0, 0, 5, 0)
        pnInput:SetPlaceholderText("my_particle_name")

        local pnAddBtn = vgui.Create("DButton", pnCtrl)
        pnAddBtn:Dock(RIGHT)
        pnAddBtn:SetWide(100)
        pnAddBtn:SetText("Add Particle")
        pnAddBtn.DoClick = function()
            local n = pnInput:GetValue()
            if n ~= "" and not table.HasValue(AC_MUZZLE_PARTICLE_NAMES, n) then
                table.insert(AC_MUZZLE_PARTICLE_NAMES, n)
                SaveConfig()
                pnList:AddLine(n)
                pnInput:SetValue("")
                AC_MUZZLE_AVAILABLE_PARTICLES = ScanForParticles()
                chat.AddText(Color(100, 200, 255), "[AC Muzzleflash] ", Color(255, 255, 255), "Added particle: " .. n)
            end
        end

        tabs:AddSheet("PCF Manager", pcfPanel, "icon16/folder.png")

        -- ==========================
        -- TAB 5: RESET / INFO
        -- ==========================
        local infoPanel = vgui.Create("DPanel", tabs)
        infoPanel.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, Color(30, 30, 30))
        end

        local infoText = vgui.Create("DLabel", infoPanel)
        infoText:Dock(TOP)
        infoText:DockMargin(20, 20, 20, 10)
        infoText:SetText([[
AC Muzzleflash Replacer

How it works:
- Every weapon is auto-categorized by class name keywords
- Categories set the default particle for each weapon type
- Per-weapon overrides take priority over categories
- Patterns let you match multiple weapons at once
- Custom PCF files let you add your own particle effects
- Barrel smoke is automatically added to all non-suppressed, non-energy weapons
- Works with players AND NPCs

Priority order:
1. Per-weapon override (Weapons tab)
2. Class pattern match (Patterns tab)
3. Category default (Categories tab)
4. Fallback: AC_muzzle_pistol
        ]])
        infoText:SetFont("DermaDefault")
        infoText:SetTextColor(Color(200, 200, 200))
        infoText:SizeToContentsY()
        infoText:SetWrap(true)
        infoText:SetAutoStretchVertical(true)

        local resetAllBtn = vgui.Create("DButton", infoPanel)
        resetAllBtn:Dock(BOTTOM)
        resetAllBtn:SetTall(40)
        resetAllBtn:DockMargin(50, 0, 50, 20)
        resetAllBtn:SetText("RESET ALL SETTINGS TO DEFAULT")
        resetAllBtn:SetFont("DermaDefaultBold")
        resetAllBtn:SetTextColor(Color(255, 100, 100))
        resetAllBtn.DoClick = function()
            Derma_Query(
                "Are you sure you want to reset ALL muzzleflash settings?",
                "Reset Confirmation",
                "Yes, Reset",
                function()
                    AC_MUZZLE_WEAPON_CONFIG = {}
                    AC_MUZZLE_CLASS_CONFIG = {}
                    AC_MUZZLE_CATEGORY_CONFIG = {
                        ["pistol"]   = "AC_muzzle_pistol",
                        ["revolver"] = "AC_muzzle_357",
                        ["smg"]      = "AC_muzzle_smg",
                        ["shotgun"]  = "AC_muzzle_shotgun",
                        ["rifle"]    = "AC_muzzle_ar2",
                        ["sniper"]   = "AC_muzzle_357",
                        ["lmg"]      = "AC_muzzle_ar2",
                        ["launcher"] = "AC_muzzle_shotgun",
                        ["energy"]   = "AC_muzzle_ar2",
                    }
                    AC_MUZZLE_PCF_FILES = {}
                    AC_MUZZLE_PARTICLE_NAMES = {}
                    SaveConfig()
                    AC_MUZZLE_AVAILABLE_PARTICLES = ScanForParticles()
                    frame:Close()
                    chat.AddText(Color(255, 150, 100), "[AC Muzzleflash] ", Color(255, 255, 255), "All settings reset to default.")
                end,
                "Cancel",
                function() end
            )
        end

        tabs:AddSheet("Info / Reset", infoPanel, "icon16/information.png")
    end

    concommand.Add("ac_muzzle_config", OpenConfigurator)

    -- ========================================================
    -- INIT
    -- ========================================================
    hook.Add("InitPostEntity", "AC_MuzzleFlash_Init", function()
        AC_MUZZLE_AVAILABLE_PARTICLES = ScanForParticles()
        AutoApplyAll()
        timer.Simple(3, function()
            if IsValid(LocalPlayer()) then
                chat.AddText(Color(100, 200, 255), "[AC Muzzleflash] ", Color(255, 255, 255), "Loaded. Type ac_muzzle_config in console to configure.")
            end
        end)
    end)

end -- END CLIENT