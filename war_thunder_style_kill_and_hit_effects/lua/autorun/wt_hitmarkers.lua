-- War Thunder style hit / critical / kill indicator.
-- Server credits hits and kills to the responsible player (driver, pilot,
-- owner of a projectile...) and sends one compact net message; the client
-- stacks and renders them. The sub line shows the real damage dealt and a
-- reward derived from it instead of fixed decorative numbers.

AddCSLuaFile()

local NET = "WT_Event"

-- Event kinds (2 bits).
local EV_HIT, EV_CRIT, EV_KILL, EV_AIRKILL = 0, 1, 2, 3

if SERVER then
    util.AddNetworkString(NET)

    resource.AddFile("sound/wt/kill.wav")
    resource.AddFile("resource/fonts/roboto_condensed_bold.ttf")

    local cvProps = CreateConVar("wt_hud_track_props", "0", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
        "Show hit markers for damage to plain props (0 = only players, NPCs, nextbots and vehicles)", 0, 1)

    -- victim -> { attackers = { [ply] = { time, damage } }, maxHealth, class }
    local history  = setmetatable({}, { __mode = "k" })
    local credited = setmetatable({}, { __mode = "k" })
    local lastHit  = setmetatable({}, { __mode = "k" }) -- ply -> { [victim] = time }

    local function Send(ply, kind, damage)
        if not IsValid(ply) or not ply:IsPlayer() then return end
        net.Start(NET, true)
            net.WriteUInt(kind, 2)
            net.WriteUInt(math.Clamp(math.Round(damage or 0), 0, 65535), 16)
        net.Send(ply)
    end

    local function PlayerFrom(ent)
        if not IsValid(ent) then return nil end
        if ent:IsPlayer() then return ent end
        if isfunction(ent.GetDriver) then
            local d = ent:GetDriver()
            if IsValid(d) and d:IsPlayer() then return d end
        end
        if isfunction(ent.GetPilot) then
            local p = ent:GetPilot()
            if IsValid(p) and p:IsPlayer() then return p end
        end
        return nil
    end

    -- Attacker resolution: direct player, vehicle occupant, seat parent chain,
    -- or the owner of a projectile / turret.
    local function ResolveAttacker(dmg)
        local att = dmg:GetAttacker()
        local ply = PlayerFrom(att)
        if ply then return ply end

        if IsValid(att) then
            local parent = att:GetParent()
            for _ = 1, 4 do
                if not IsValid(parent) then break end
                ply = PlayerFrom(parent)
                if ply then return ply end
                parent = parent:GetParent()
            end
            local owner = att:GetOwner()
            ply = PlayerFrom(owner)
            if ply then return ply end
            if IsValid(owner) and owner.CPPIGetOwner then
                local o = owner:CPPIGetOwner()
                if IsValid(o) and o:IsPlayer() then return o end
            end
        end

        local inflictor = dmg:GetInflictor()
        if IsValid(inflictor) and inflictor ~= att then
            ply = PlayerFrom(inflictor) or PlayerFrom(inflictor:GetOwner())
            if ply then return ply end
        end
        return nil
    end

    local function IsVehicle(ent)
        if not IsValid(ent) then return false end
        if ent:IsVehicle() then return true end
        if ent.LVS or ent.IsSimfphyscar or ent.IsGlideVehicle then return true end
        local cls = ent:GetClass()
        return string.StartWith(cls, "lvs_") or string.StartWith(cls, "gmod_sent_vehicle")
            or string.find(cls, "simfphys", 1, true) ~= nil or string.StartWith(cls, "prop_vehicle")
    end

    local function IsAircraft(ent)
        if not IsValid(ent) then return false end
        local cls = ent:GetClass()
        if string.StartWith(cls, "lvs_plane") or string.StartWith(cls, "lvs_heli") then return true end
        if ent.LVS_PLANE or ent.LVS_HELICOPTER then return true end
        return false
    end

    -- The entity whose health actually matters: seats and armour plates hand
    -- damage to their vehicle.
    local function ResolveVictim(ent)
        if not IsValid(ent) then return nil end
        if IsVehicle(ent) then
            if ent.GetVehicle and IsValid(ent:GetVehicle()) then return ent:GetVehicle() end
            if isfunction(ent.GetBase) and IsValid(ent:GetBase()) then return ent:GetBase() end
            return ent
        end
        local parent = ent:GetParent()
        if IsValid(parent) and IsVehicle(parent) then return ResolveVictim(parent) end
        return ent
    end

    local function IsTrackable(ent)
        if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() then return true end
        if IsVehicle(ent) then return true end
        return cvProps:GetBool() and ent:GetClass() == "prop_physics"
    end

    local function GetHealth(ent)
        if isfunction(ent.GetHP) then
            local hp = ent:GetHP()
            if isnumber(hp) then return hp end
        end
        return ent:Health()
    end

    local function GetMaxHealth(ent)
        if isfunction(ent.GetMaxHP) then
            local hp = ent:GetMaxHP()
            if isnumber(hp) and hp > 0 then return hp end
        end
        local mh = ent:GetMaxHealth()
        if isnumber(mh) and mh > 0 then return mh end
        return 0
    end

    -- Runs after the damage has been applied so the health check is real.
    hook.Add("PostEntityTakeDamage", "WT_TrackDamage", function(victim, dmg, took)
        if not took then return end
        local attacker = ResolveAttacker(dmg)
        if not attacker then return end

        victim = ResolveVictim(victim)
        if not IsValid(victim) or victim == attacker then return end
        if not IsTrackable(victim) then return end
        if PlayerFrom(victim) == attacker then return end

        local now = CurTime()
        local mine = lastHit[attacker]
        if not mine then
            mine = setmetatable({}, { __mode = "k" })
            lastHit[attacker] = mine
        end
        local damage = dmg:GetDamage()
        if (mine[victim] or 0) > now - 0.12 then
            -- Shotgun pellets / multi-hit bursts: fold into the last marker.
            local rec = history[victim] and history[victim].attackers[attacker]
            if rec then rec.damage = rec.damage + damage end
            return
        end
        mine[victim] = now

        local h = history[victim]
        if not h then
            h = { attackers = setmetatable({}, { __mode = "k" }), maxHealth = GetMaxHealth(victim) }
            if h.maxHealth <= 0 then h.maxHealth = math.max(GetHealth(victim) + damage, 1) end
            history[victim] = h
        end
        local rec = h.attackers[attacker]
        if not rec then
            rec = { damage = 0 }
            h.attackers[attacker] = rec
        end
        rec.time = now
        rec.damage = rec.damage + damage

        local remaining = GetHealth(victim)
        if remaining <= 0 then return end -- the kill path reports this one

        local critical = h.maxHealth > 0 and damage >= h.maxHealth * 0.3
        Send(attacker, critical and EV_CRIT or EV_HIT, damage)
    end)

    local function AwardKill(victim)
        if not IsValid(victim) then return end
        local h = history[victim]
        if not h or credited[victim] then return end
        credited[victim] = true
        history[victim] = nil

        local killer, latest = nil, 0
        for ply, rec in pairs(h.attackers) do
            if IsValid(ply) and rec.time > latest then
                killer, latest = ply, rec.time
            end
        end
        if not killer then return end
        -- Kills only count if the last hit was recent; an old scratch on a
        -- vehicle that later fell off a cliff is not a kill.
        if CurTime() - latest > 10 then return end

        Send(killer, IsAircraft(victim) and EV_AIRKILL or EV_KILL, h.attackers[killer].damage)
    end

    hook.Add("PlayerDeath", "WT_PlayerKill", AwardKill)
    hook.Add("OnNPCKilled", "WT_NPCKill", AwardKill)
    hook.Add("LVS.OnVehicleDestroyed", "WT_LVSKill", AwardKill)
    hook.Add("simfphysOnDestroyed", "WT_SimfphysKill", AwardKill)
    hook.Add("Glide_VehicleDestroyed", "WT_GlideKill", AwardKill)

    -- Nextbots and props have no death hook; they are simply removed at 0 HP.
    hook.Add("EntityRemoved", "WT_RemovedKill", function(ent)
        if not history[ent] then return end
        if ent:IsPlayer() or ent:IsNPC() then return end
        if IsVehicle(ent) and GetHealth(ent) > 0 and not (ent.GetDestroyed and ent:GetDestroyed()) then
            history[ent] = nil
            return
        end
        AwardKill(ent)
    end)

    hook.Add("PlayerSpawn", "WT_ResetCredit", function(ply)
        credited[ply] = nil
        history[ply] = nil
    end)

    hook.Add("PostCleanupMap", "WT_Cleanup", function()
        table.Empty(history)
        table.Empty(credited)
    end)

    return
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

local cvOffset = CreateClientConVar("wt_hud_offset", "180", true, false, "Vertical offset of the hit indicator")
local cvGlow   = CreateClientConVar("wt_hud_glow", "3", true, false, "Glow strength of kill text (0-4)", 0, 4)
local cvSound  = CreateClientConVar("wt_hud_sounds", "1", true, false, "Play the kill confirmation sound", 0, 1)
local cvScale  = CreateClientConVar("wt_hud_scale", "1", true, false, "Size multiplier for the indicator", 0.5, 2)

local function BuildFonts()
    local s = cvScale:GetFloat()
    surface.CreateFont("WT_Main", { font = "Roboto Condensed", size = math.Round(44 * s), weight = 900, antialias = true })
    surface.CreateFont("WT_Sub",  { font = "Roboto Condensed", size = math.Round(24 * s), weight = 700, antialias = true })
end
BuildFonts()
cvars.AddChangeCallback("wt_hud_scale", BuildFonts, "WT_Fonts")

local messages = {}
local MAX_MESSAGES = 10
local killStack = 0

local function FormatNumber(n)
    local s = tostring(math.floor(n))
    local out = ""
    while #s > 3 do
        out = "," .. string.sub(s, -3) .. out
        s = string.sub(s, 1, -4)
    end
    return s .. out
end

-- Reward line in the game's "currency ✦ research" style, scaled from damage.
local function Reward(damage, mult)
    return FormatNumber(damage * 10 * mult) .. " ✦ " .. FormatNumber(math.max(1, damage * 0.8 * mult))
end

local function AddMessage(id, data)
    for _, m in ipairs(messages) do
        if m.id == id then
            m.count = m.count + 1
            m.damage = m.damage + data.damage
            m.sub = data.subFor(m.damage)
            m.time = m.maxTime
            return
        end
    end
    data.id = id
    data.count = 1
    data.sub = data.subFor(data.damage)
    if #messages >= MAX_MESSAGES then table.remove(messages, 1) end
    messages[#messages + 1] = data
end

local function AddKill(id, data)
    local existing = false
    for i = #messages, 1, -1 do
        local m = messages[i]
        if m.id == "kill" or m.id == "aircraft" then
            existing = true
            table.remove(messages, i)
        end
    end
    killStack = existing and killStack + 1 or 1
    data.id = id
    data.count = killStack
    data.sub = data.subFor(data.damage)
    if #messages >= MAX_MESSAGES then table.remove(messages, 1) end
    messages[#messages + 1] = data
    if cvSound:GetBool() then surface.PlaySound("wt/kill.wav") end
end

local STYLES = {
    [EV_HIT] = { id = "hit", text = "Hit", color = Color(222, 222, 214), subColor = Color(196, 196, 188), time = 0.9, rise = 8, mult = 1 },
    [EV_CRIT] = { id = "critical", text = "Critical hit", color = Color(222, 222, 214), subColor = Color(196, 196, 188), time = 1.15, rise = 12, mult = 3 },
    [EV_KILL] = { id = "kill", text = "Target destroyed", color = Color(255, 235, 230), subColor = Color(245, 245, 245), time = 1.7, rise = 18, glow = 6, outlineColor = Color(255, 105, 95), mult = 12, kill = true },
    [EV_AIRKILL] = { id = "aircraft", text = "Aircraft destroyed", color = Color(255, 235, 230), subColor = Color(245, 245, 245), time = 1.7, rise = 18, glow = 6, outlineColor = Color(255, 105, 95), mult = 16, kill = true },
}

net.Receive(NET, function()
    local kind = net.ReadUInt(2)
    local damage = net.ReadUInt(16)
    local st = STYLES[kind]
    if not st then return end
    local data = {
        text = st.text, color = st.color, subColor = st.subColor,
        time = st.time, maxTime = st.time, rise = st.rise, glow = st.glow or 0,
        outlineColor = st.outlineColor, damage = damage,
        subFor = function(d) return Reward(d, st.mult) end,
    }
    if st.kill then AddKill(st.id, data) else AddMessage(st.id, data) end
end)

hook.Add("HUDPaint", "WT_DrawHUD", function()
    if #messages == 0 then return end

    local x = ScrW() / 2
    local scale = cvScale:GetFloat()
    local y = ScrH() * 0.28 - cvOffset:GetInt()
    local glowMult = cvGlow:GetInt()
    local ft = FrameTime()

    for i = #messages, 1, -1 do
        local m = messages[i]
        m.time = m.time - ft
        if m.time <= 0 then
            if m.id == "kill" or m.id == "aircraft" then killStack = 0 end
            table.remove(messages, i)
        elseif y >= 10 then
            local t = math.Clamp(m.time / m.maxTime, 0, 1)
            local a = t * 255
            local yAnim = y - (1 - t) * m.rise * scale
            local text = m.text .. (m.count > 1 and (" x" .. m.count) or "")

            if m.outlineColor and glowMult > 0 then
                local oc = m.outlineColor
                for o = math.min(glowMult, 4) + 1, 2, -1 do
                    local oa = a * (0.12 + 0.10 * (o - 1))
                    local c = Color(oc.r, oc.g, oc.b, oa)
                    local cd = Color(oc.r, oc.g, oc.b, oa * 0.75)
                    draw.SimpleText(text, "WT_Main", x + o, yAnim, c, TEXT_ALIGN_CENTER)
                    draw.SimpleText(text, "WT_Main", x - o, yAnim, c, TEXT_ALIGN_CENTER)
                    draw.SimpleText(text, "WT_Main", x, yAnim + o, c, TEXT_ALIGN_CENTER)
                    draw.SimpleText(text, "WT_Main", x, yAnim - o, c, TEXT_ALIGN_CENTER)
                    draw.SimpleText(text, "WT_Main", x + o, yAnim + o, cd, TEXT_ALIGN_CENTER)
                    draw.SimpleText(text, "WT_Main", x - o, yAnim + o, cd, TEXT_ALIGN_CENTER)
                    draw.SimpleText(text, "WT_Main", x + o, yAnim - o, cd, TEXT_ALIGN_CENTER)
                    draw.SimpleText(text, "WT_Main", x - o, yAnim - o, cd, TEXT_ALIGN_CENTER)
                end
            else
                draw.SimpleText(text, "WT_Main", x + 1, yAnim + 1, Color(0, 0, 0, a * 0.8), TEXT_ALIGN_CENTER)
            end

            draw.SimpleText(text, "WT_Main", x, yAnim, Color(m.color.r, m.color.g, m.color.b, a), TEXT_ALIGN_CENTER)
            draw.SimpleText(m.sub, "WT_Sub", x, yAnim + 30 * scale, Color(m.subColor.r, m.subColor.g, m.subColor.b, a), TEXT_ALIGN_CENTER)

            y = y - 55 * scale
        end
    end
end)

hook.Add("PopulateToolMenu", "WT_HUD_Menu", function()
    spawnmenu.AddToolMenuOption("Options", "HUD", "WT_HitMarkers", "War Thunder Hit Markers", "", "", function(panel)
        panel:ClearControls()
        panel:NumSlider("Vertical offset", "wt_hud_offset", -200, 400, 0)
        panel:NumSlider("Kill text glow", "wt_hud_glow", 0, 4, 0)
        panel:NumSlider("Scale", "wt_hud_scale", 0.5, 2, 2)
        panel:CheckBox("Kill sound", "wt_hud_sounds")
        panel:Help("Server: wt_hud_track_props 1 to also show markers on props.")
    end)
end)
