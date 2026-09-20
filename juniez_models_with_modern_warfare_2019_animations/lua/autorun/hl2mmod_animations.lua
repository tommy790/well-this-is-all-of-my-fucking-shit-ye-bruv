-- Viewmodel animation logic for the Juniez / MW2019 c_ models.
-- Every sequence used here exists in the shipped models; anything is looked
-- up per model and cached, and features whose sequences a model lacks are
-- simply skipped for that model instead of playing sequence -1.

AddCSLuaFile()

local inspectableWeapons = {
    weapon_pistol = true, weapon_357 = true, weapon_smg1 = true, weapon_ar2 = true,
    weapon_shotgun = true, weapon_crossbow = true, weapon_rpg = true, weapon_crowbar = true,
}

local swayWeapons = {
    weapon_pistol = true, weapon_357 = true, weapon_smg1 = true, weapon_shotgun = true,
    weapon_crossbow = true, weapon_rpg = true, weapon_frag = true, weapon_stunstick = true,
    weapon_crowbar = true, weapon_physcannon = true, weapon_bugbait = true, weapon_ar2 = true,
}

local reloadableWeapons = {
    weapon_pistol = true, weapon_357 = true, weapon_smg1 = true, weapon_ar2 = true,
    weapon_crossbow = true, weapon_rpg = true,
}

-- Only the grenade model ships sprint animations.
local sprintableWeapons = { weapon_frag = true }

-- [model][name] = sequence id or false
local seqCache = {}
local function FindSequence(vm, name)
    local mdl = vm:GetModel()
    local perModel = seqCache[mdl]
    if not perModel then
        perModel = {}
        seqCache[mdl] = perModel
    end
    local id = perModel[name]
    if id == nil then
        id = vm:LookupSequence(name)
        if not id or id < 0 then id = false end
        perModel[name] = id
    end
    return id
end

local function PlaySequence(ply, wep, vm, seqId, idleDelay)
    vm:SendViewModelMatchingSequence(seqId)
    local dur = vm:SequenceDuration(seqId)
    -- Keep the engine weapon from stomping the sequence with its own idle.
    wep:SetSaveValue("m_flTimeWeaponIdle", CurTime() + (idleDelay or dur))
    return dur
end

local function GetVM(ply)
    if not IsValid(ply) or not ply:Alive() then return end
    local wep = ply:GetActiveWeapon()
    if not IsValid(wep) then return end
    local vm = ply:GetViewModel()
    if not IsValid(vm) then return end
    return wep, vm, wep:GetClass()
end

if SERVER then
    hook.Add("KeyPress", "MMOD_Weapon_Inspect", function(ply, key)
        if key ~= IN_RELOAD then return end
        local wep, vm, class = GetVM(ply)
        if not wep or not inspectableWeapons[class] then return end
        if ply:GetVelocity():LengthSqr() > 100 then return end
        if wep.MMOD_NextInspectTime and CurTime() < wep.MMOD_NextInspectTime then return end

        local info = vm:GetSequenceInfo(vm:GetSequence())
        if not info or info.activityname ~= "ACT_VM_IDLE" then return end
        if wep:GetMaxClip1() > 0 and wep:Clip1() < wep:GetMaxClip1() then return end

        local seq = FindSequence(vm, "inspect1")
        if not seq then return end
        local dur = PlaySequence(ply, wep, vm, seq)
        wep.MMOD_NextInspectTime = CurTime() + dur
    end)

    -- One PlayerPostThink for every per-tick feature instead of five.
    hook.Add("PlayerPostThink", "MMOD_ViewmodelLogic", function(ply)
        local wep, vm, class = GetVM(ply)
        if not wep then return end

        local info = vm:GetSequenceInfo(vm:GetSequence())
        if not info then return end
        local act = info.activityname
        local label = info.label

        -- Tactical vs empty reload: engine weapons only know ACT_VM_RELOAD.
        if reloadableWeapons[class] then
            if act == "ACT_VM_RELOAD" then
                if not wep.MMOD_ReloadSwapped and vm:GetCycle() < 0.1 then
                    wep.MMOD_ReloadSwapped = true
                    local seq
                    if wep.MMOD_ClipBeforeReload and wep.MMOD_ClipBeforeReload <= 0 then
                        seq = FindSequence(vm, "reload_empty")
                    end
                    seq = seq or FindSequence(vm, "reload")
                    if seq and seq ~= vm:GetSequence() then
                        vm:SendViewModelMatchingSequence(seq)
                    end
                end
            else
                wep.MMOD_ReloadSwapped = false
                -- Clip1 is already refilled by the time the reload sequence is
                -- visible on some weapons, so remember the value from before.
                wep.MMOD_ClipBeforeReload = wep:Clip1()
            end
        end

        if sprintableWeapons[class] then
            local speed = ply:GetVelocity():Length2D()
            local moving = ply:KeyDown(IN_SPEED) and ply:OnGround() and not ply:Crouching()
                and speed > ply:GetWalkSpeed() * 0.9
            local sprinting = label == "sprint" or label == "sprint_in"

            if moving and act == "ACT_VM_IDLE" and not sprinting then
                local seqIn = FindSequence(vm, "sprint_in")
                local seq = FindSequence(vm, "sprint")
                if seq then
                    PlaySequence(ply, wep, vm, seqIn or seq, 60)
                    wep.MMOD_SprintLoopAt = seqIn and (CurTime() + vm:SequenceDuration(seqIn)) or nil
                end
            elseif sprinting then
                if not moving then
                    local seqOut = FindSequence(vm, "sprint_out") or FindSequence(vm, "idle")
                    if seqOut then PlaySequence(ply, wep, vm, seqOut) end
                    wep.MMOD_SprintLoopAt = nil
                elseif wep.MMOD_SprintLoopAt and CurTime() >= wep.MMOD_SprintLoopAt then
                    local seq = FindSequence(vm, "sprint")
                    if seq then PlaySequence(ply, wep, vm, seq, 60) end
                    wep.MMOD_SprintLoopAt = nil
                end
            elseif label == "sprint_out" and vm:GetCycle() >= 0.99 then
                local idle = FindSequence(vm, "idle")
                if idle then PlaySequence(ply, wep, vm, idle) end
            end
        end
    end)

    return
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

local cvStopSway = CreateClientConVar("mmod_replacements_stopsway", "0", true, true,
    "Disable the default viewmodel sway (turn off to support viewmodel lagger and other CalcViewModelView scripts)", 0, 1)
local cvLens = CreateClientConVar("mmod_replacements_lense", "1", true, true,
    "Crossbow scope lens: 0 = black, 1 = refraction (small), 2 = refraction (full frame)", 0, 2)
local cvOverlay = CreateClientConVar("mmod_replacements_crossbow_overlay", "1", true, true,
    "Draw a scope overlay while zoomed with the crossbow", 0, 1)

-- The AR2 model uses skin 1 for its lit muzzle/vent state during fire and
-- inspect frames. Only the owner sees the viewmodel, so this is client-only.
hook.Add("Think", "MMOD_AR2_Skin", function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local wep, vm, class = GetVM(ply)
    if not wep or class ~= "weapon_ar2" then return end

    local info = vm:GetSequenceInfo(vm:GetSequence())
    if not info then return end
    local label = info.label or ""
    local cyc = vm:GetCycle()

    local lit = (string.find(label, "fire", 1, true) and cyc < 0.2)
        or (label == "inspect1" and cyc > 0.1 and cyc < 0.9)
    local skin = lit and 1 or 0
    if vm:GetSkin() ~= skin then vm:SetSkin(skin) end
end)

hook.Add("CalcViewModelView", "MMOD_Weapon_StopDefaultSway", function(wep, vm, oldPos, oldAng, pos, ang)
    if not cvStopSway:GetBool() then return end
    if not IsValid(wep) or not swayWeapons[wep:GetClass()] then return end
    local ply = wep:GetOwner()
    if not IsValid(ply) or ply:GetVelocity():LengthSqr() <= 1 then return end
    if ply:GetNW2Int("TFALean", 0) ~= 0 then return end
    return oldPos, oldAng
end)

-- The original overlay material was never shipped; the scope mask is drawn
-- procedurally instead (circular view with vignette and hairline reticle).
local circlePoly
local function BuildCircle(cx, cy, r)
    local poly = {}
    local segs = 96
    for i = 0, segs do
        local a = math.rad(i / segs * 360)
        poly[#poly + 1] = { x = cx + math.cos(a) * r, y = cy + math.sin(a) * r }
    end
    return poly
end

hook.Add("HUDPaint", "MMOD_Weapon_CrossbowZoomOverlay", function()
    if not cvOverlay:GetBool() then return end
    local ply = LocalPlayer()
    if not IsValid(ply) or not ply:Alive() then return end
    local wep = ply:GetActiveWeapon()
    if not IsValid(wep) or wep:GetClass() ~= "weapon_crossbow" then return end
    if ply:GetFOV() >= 25 then return end

    local w, h = ScrW(), ScrH()
    local cx, cy, r = w / 2, h / 2, h * 0.46

    -- Black outside the scope circle: stencil-mask the circle, fill the rest.
    render.ClearStencil()
    render.SetStencilEnable(true)
    render.SetStencilWriteMask(255)
    render.SetStencilTestMask(255)
    render.SetStencilReferenceValue(1)
    render.SetStencilCompareFunction(STENCIL_ALWAYS)
    render.SetStencilPassOperation(STENCIL_REPLACE)
    render.SetStencilFailOperation(STENCIL_KEEP)
    render.SetStencilZFailOperation(STENCIL_KEEP)

    if not circlePoly or circlePoly.h ~= h then
        circlePoly = BuildCircle(cx, cy, r)
        circlePoly.h = h
    end
    draw.NoTexture()
    surface.SetDrawColor(0, 0, 0, 1)
    surface.DrawPoly(circlePoly)

    render.SetStencilCompareFunction(STENCIL_NOTEQUAL)
    surface.SetDrawColor(0, 0, 0, 255)
    surface.DrawRect(0, 0, w, h)
    render.SetStencilEnable(false)

    -- Reticle
    surface.SetDrawColor(20, 20, 20, 220)
    surface.DrawRect(cx - r, cy, r * 2, 1)
    surface.DrawRect(cx, cy - r, 1, r * 2)
    surface.DrawOutlinedRect(cx - 6, cy - 6, 12, 12, 1)
    for i = 1, 4 do
        local off = i * r * 0.18
        surface.DrawRect(cx + off, cy - 5, 1, 10)
        surface.DrawRect(cx - off, cy - 5, 1, 10)
        surface.DrawRect(cx - 5, cy + off, 10, 1)
        surface.DrawRect(cx - 5, cy - off, 10, 1)
    end
    surface.DrawOutlinedRect(cx - r, cy - r, r * 2, r * 2, 0)
end)

local cbLens = Material("models/weapons/v_crossbow_new/v_crossbow_lens")
local lensTextures = { ["0"] = "vgui/black", ["1"] = "_rt_SmallFB1", ["2"] = "_rt_FullFrameFB" }

local function ApplyLens(_, _, newval)
    if cbLens:IsError() then return end
    local tex = lensTextures[tostring(newval)]
    if tex then cbLens:SetTexture("$basetexture", tex) end
end

cvars.RemoveChangeCallback("mmod_replacements_lense", "mmod_replacements_lense_id")
cvars.AddChangeCallback("mmod_replacements_lense", ApplyLens, "mmod_replacements_lense_id")
hook.Add("InitPostEntity", "MMOD_Weapon_CrossbowLenseConvarInit", function()
    ApplyLens(nil, nil, cvLens:GetString())
end)

hook.Add("PopulateToolMenu", "MMOD_Replacements_Menu", function()
    spawnmenu.AddToolMenuOption("Options", "Player", "MMOD_Replacements", "MW2019 Viewmodels", "", "", function(panel)
        panel:ClearControls()
        panel:CheckBox("Disable default viewmodel sway", "mmod_replacements_stopsway")
        panel:CheckBox("Crossbow scope overlay", "mmod_replacements_crossbow_overlay")
        panel:NumSlider("Crossbow lens mode", "mmod_replacements_lense", 0, 2, 0)
        panel:NumSlider("Viewmodel FOV (0 = untouched)", "mmod_replacements_viewmodel_fov", 0, 120, 0)
    end)
end)
