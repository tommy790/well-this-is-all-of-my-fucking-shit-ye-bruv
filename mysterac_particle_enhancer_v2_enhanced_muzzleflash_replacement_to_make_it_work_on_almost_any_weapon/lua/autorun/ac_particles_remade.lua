--@diagnostic disable: undefined-global, lowercase-global
AddCSLuaFile();

-- ============================================================
-- MysterAC Particle Enhancer V2 - Impact / Explosion pack
-- (bugfix edition: original behavior restored)
--
-- Changes vs the original:
--  * no custom sounds at all - GMod/HL2 plays its own default
--    explosion sound when explosives detonate (the original
--    referenced hd/new_grenadeexplo.mp3 which was never shipped,
--    causing errors; we simply don't touch the sound)
--  * removed leftover debug print()s
--  * removed the no-op table.Merge(x, x)
-- Everything else works exactly like the original: grenade /
-- RPG / AR2 explosions are tracked per frame and fire the
-- moment the projectile disappears, at its last known position.
-- ============================================================

CreateConVar("cl_ac_explosions_disabled", "0", {FCVAR_ARCHIVE, FCVAR_NOTIFY}, "Set to 1 to disable all AC explosion effects")
CreateConVar("cl_ac_explosions_grenade_disabled", "0", {FCVAR_ARCHIVE, FCVAR_NOTIFY}, "Set to 1 to disable grenade explosion effects")
CreateConVar("cl_ac_explosions_rpg_disabled", "0", {FCVAR_ARCHIVE, FCVAR_NOTIFY}, "Set to 1 to disable RPG explosion effects")
CreateConVar("cl_ac_explosions_ar2_disabled", "0", {FCVAR_ARCHIVE, FCVAR_NOTIFY}, "Set to 1 to disable AR2 explosion effects")
CreateConVar("cl_ac_muzzleflash_disabled", "0", {FCVAR_ARCHIVE, FCVAR_NOTIFY}, "Set to 1 to disable AC muzzleflash effects")

-- ============================================================
-- Tool Menu Entries
-- ============================================================
hook.Add("PopulateToolMenu", "AC_Explosions_Menu", function()
    spawnmenu.AddToolMenuOption("Options", "Combat", "AC_ExplosionsToggle", "AC Explosion Effects", "", "", function(panel)
        panel:ClearControls()
        panel:Help("AC Explosion Effects")
        panel:Help("Toggle custom explosion effects for grenades, RPGs, and AR2 grenades.")
        panel:CheckBox("Disable All Explosions", "cl_ac_explosions_disabled")
        panel:CheckBox("Disable Grenade Explosions", "cl_ac_explosions_grenade_disabled")
        panel:CheckBox("Disable RPG Explosions", "cl_ac_explosions_rpg_disabled")
        panel:CheckBox("Disable AR2 Explosions", "cl_ac_explosions_ar2_disabled")
    end)
end)

hook.Add("PopulateToolMenu", "AC_MuzzleFlash_Toggle_Menu", function()
    spawnmenu.AddToolMenuOption("Options", "Combat", "AC_MuzzleFlashToggle", "AC Muzzleflash Toggle", "", "", function(panel)
        panel:ClearControls()
        panel:Help("AC Muzzleflash Quick Toggle")
        panel:Help("Quickly enable or disable all AC muzzleflash effects.")
        panel:CheckBox("Disable Muzzleflashes", "cl_ac_muzzleflash_disabled")
    end)
end)

-- ============================================================
-- SERVER
-- ============================================================
if (SERVER) then

    TRACKING_EXPLOSIVES_GRENADE = {}
    TRACKING_EXPLOSIVES_RPGS = {}
    TRACKING_EXPLOSIVES_AR2 = {}

    function CreateGrenadeExplosion(pos, elapsed_time)
        local all_disabled = GetConVar("cl_ac_explosions_disabled"):GetBool()
        local grenade_disabled = GetConVar("cl_ac_explosions_grenade_disabled"):GetBool()
        if all_disabled or grenade_disabled then return end

        local tr = util.TraceLine({
            start  = pos,
            endpos = pos - Vector(0, 0, 60),
            mask   = MASK_SOLID_BRUSHONLY
        })

        if tr.HitWorld then
            ParticleEffect("AC_grenade_explosion", pos, Angle(0, math.random(0, 360), 0), nil)
        else
            ParticleEffect("AC_grenade_explosion_air", pos, Angle(0, math.random(0, 360), 0), nil)
        end

    end

    function CreateRPGExplosion(pos, elapsed_time)
        local all_disabled = GetConVar("cl_ac_explosions_disabled"):GetBool()
        local rpg_disabled = GetConVar("cl_ac_explosions_rpg_disabled"):GetBool()
        if all_disabled or rpg_disabled then return end

        local tr = util.TraceLine({
            start  = pos,
            endpos = pos - Vector(0, 0, 60),
            mask   = MASK_SOLID_BRUSHONLY
        })

        if tr.HitWorld then
            ParticleEffect("AC_rpg_explosion", pos, Angle(0, math.random(0, 360), 0), nil)
        else
            ParticleEffect("AC_rpg_explosion_air", pos, Angle(0, math.random(0, 360), 0), nil)
        end

    end

    function CreateAR2Explosion(pos, elapsed_time)
        local all_disabled = GetConVar("cl_ac_explosions_disabled"):GetBool()
        local ar2_disabled = GetConVar("cl_ac_explosions_ar2_disabled"):GetBool()
        if all_disabled or ar2_disabled then return end

        local tr = util.TraceLine({
            start  = pos,
            endpos = pos - Vector(0, 0, 60),
            mask   = MASK_SOLID_BRUSHONLY
        })

        if tr.HitWorld then
            ParticleEffect("AC_grenade_ar2_explosion", pos, Angle(0, math.random(0, 360), 0), nil)
        else
            ParticleEffect("AC_grenade_ar2_explosion_air", pos, Angle(0, math.random(0, 360), 0), nil)
        end

    end

    -- ========================================================
    -- Explosive tracking (original behavior, cleaned up):
    -- each frame we look for live projectiles and keep updating
    -- their last known position; the moment one disappears we
    -- spawn the explosion at that last position immediately.
    -- (No debug prints, no no-op table.Merge, and it also
    --  catches projectiles that existed before this addon
    --  loaded - which OnEntityCreated alone would miss.)
    -- ========================================================

    function CheckForGrenades()
        local grenades = {}
        table.Add(grenades, ents.FindByClass("npc_grenade_frag"))
        -- SLAM mines: tripmine mode deploys npc_tripmine, remote
        -- detonate mode deploys npc_satchel (weapon_slam.cpp).
        -- This also covers weapon_tripmine / weapon_satchel.
        table.Add(grenades, ents.FindByClass("npc_tripmine"))
        table.Add(grenades, ents.FindByClass("npc_satchel"))

        for k, v in pairs(grenades) do
            if not IsValid(v) then goto skip_grenade end
            if not (TRACKING_EXPLOSIVES_GRENADE[v]) then
                TRACKING_EXPLOSIVES_GRENADE[v] = { true, v:GetPos(), CurTime() }
            else
                TRACKING_EXPLOSIVES_GRENADE[v][1] = true
                TRACKING_EXPLOSIVES_GRENADE[v][2] = v:GetPos()
            end
            ::skip_grenade::
        end

        for k, v in pairs(TRACKING_EXPLOSIVES_GRENADE) do
            if not (k:IsValid()) then
                local pos, elapsed_time = v[2], (CurTime() - v[3])
                CreateGrenadeExplosion(pos, elapsed_time)
                TRACKING_EXPLOSIVES_GRENADE[k] = nil
            end
        end
    end

    function CheckForRPGS()
        local rpgs = ents.FindByClass("rpg_missile")

        for k, v in pairs(rpgs) do
            if not IsValid(v) then goto skip_rpg end
            if not (TRACKING_EXPLOSIVES_RPGS[v]) then
                TRACKING_EXPLOSIVES_RPGS[v] = { true, v:GetPos(), CurTime() }
            else
                TRACKING_EXPLOSIVES_RPGS[v][1] = true
                TRACKING_EXPLOSIVES_RPGS[v][2] = v:GetPos()
            end
            ::skip_rpg::
        end

        for k, v in pairs(TRACKING_EXPLOSIVES_RPGS) do
            if not (k:IsValid()) then
                local pos, elapsed_time = v[2], (CurTime() - v[3])
                CreateRPGExplosion(pos, elapsed_time)
                TRACKING_EXPLOSIVES_RPGS[k] = nil
            end
        end
    end

    function CheckForAR2Grenades()
        local ar2 = ents.FindByClass("grenade_ar2")

        for k, v in pairs(ar2) do
            if not IsValid(v) then goto skip_ar2 end
            if not (TRACKING_EXPLOSIVES_AR2[v]) then
                TRACKING_EXPLOSIVES_AR2[v] = { true, v:GetPos(), CurTime() }
            else
                TRACKING_EXPLOSIVES_AR2[v][1] = true
                TRACKING_EXPLOSIVES_AR2[v][2] = v:GetPos()
            end
            ::skip_ar2::
        end

        for k, v in pairs(TRACKING_EXPLOSIVES_AR2) do
            if not (k:IsValid()) then
                local pos, elapsed_time = v[2], (CurTime() - v[3])
                CreateAR2Explosion(pos, elapsed_time)
                TRACKING_EXPLOSIVES_AR2[k] = nil
            end
        end
    end

    -- Skip if the legacy "gexplo" addon is already installed
    -- (it handles its own explosions).
    if file.Exists("autorun/gexplo_autorun.lua", "LUA") then

    else
        hook.Add("Think", "CheckForGrenades", CheckForGrenades)
        hook.Add("Think", "CheckForRPGS", CheckForRPGS)
        hook.Add("Think", "CheckForAR2Grenades", CheckForAR2Grenades)
    end
end
