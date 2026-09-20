-- =====================================================
-- WAR THUNDER STYLE HIT INDICATOR HUD (FIXED & STABLE)
-- simfphys + LVS support, improved simfphys destruction checks
-- =====================================================

AddCSLuaFile()

-- SERVER
if SERVER then
    util.AddNetworkString("WT_ShowHit")
    util.AddNetworkString("WT_ShowCritical")
    util.AddNetworkString("WT_ShowKill")
    util.AddNetworkString("WT_ShowAircraftKill")

    resource.AddFile("sound/wt/kill.wav")
    resource.AddFile("resource/fonts/roboto_condensed_bold.ttf")

    -- Structured damage history: damageHistory[victim] = { attackers = {}, class = "", maxHealth = 0 }
    local damageHistory = {}
    local recentKills = {}
    local lastHitTime = {}    -- [attacker][victimIdx] = time
    local lastKillTime = {}   -- [attacker][victimIdx] = time
    local trackedEntities = {} -- Set of entities that have taken tracked damage

    -- Class cache for projectile checks
    local classCache = {}

    local function GetActualAttacker(ent)
        if not IsValid(ent) then return nil end
        if ent:IsPlayer() then return ent end

        if isfunction(ent.GetDriver) then
            local d = ent:GetDriver()
            if IsValid(d) then return d end
        end

        if isfunction(ent.GetPilot) then
            local p = ent:GetPilot()
            if IsValid(p) then return p end
        end

        local parent = ent:GetParent()
        if IsValid(parent) then
            if isfunction(parent.GetDriver) then
                local d = parent:GetDriver()
                if IsValid(d) then return d end
            end
            if isfunction(parent.GetPilot) then
                local p = parent:GetPilot()
                if IsValid(p) then return p end
            end
            if isfunction(parent.GetOwner) then
                local o = parent:GetOwner()
                if IsValid(o) and o:IsPlayer() then return o end
            end
        end

        if isfunction(ent.GetOwner) then
            local o = ent:GetOwner()
            if IsValid(o) and o:IsPlayer() then return o end
        end

        return nil
    end

    local projectilePatterns = {
        "grenade", "rpg_missile", "missile", "projectile", "rocket",
        "bomb", "effect", "gib", "shell", "flare", "debris", "m9k",
        "prop_physics"
    }

    local function IsProjectileOrEffect(cls)
        if not cls or cls == "" then return false end

        if classCache[cls] ~= nil then
            return classCache[cls]
        end

        local result = false
        for _, pattern in ipairs(projectilePatterns) do
            if cls:find(pattern) then
                result = true
                break
            end
        end

        classCache[cls] = result
        return result
    end

    local function IsVehicleActuallyDestroyed(ent)
        if not IsValid(ent) then return true end

        if isfunction(ent.GetDestroyed) then
            local destroyed = ent:GetDestroyed()
            if destroyed then return true end
        end

        if isfunction(ent.GetHP) then
            local hp = ent:GetHP()
            if type(hp) == "number" and hp <= 0 then
                return true
            end
        end

        if isfunction(ent.Health) then
            local hp = ent:Health()
            if type(hp) == "number" and hp <= 0 then
                return true
            end
        end

        local cls = ent:GetClass() or ""
        local looksLikeSimf = cls:find("gmod_sent_vehicle") or cls:find("simfphys") or cls:find("prop_vehicle")
        if looksLikeSimf then
            if isfunction(ent.GetDriver) then
                local drv = ent:GetDriver()
                if IsValid(drv) then
                    return false
                end
            end

            if isfunction(ent.GetHP) then
                local hp = ent:GetHP()
                if type(hp) == "number" and hp <= 0 then
                    return true
                end
            end

            if isfunction(ent.Health) then
                local hp = ent:Health()
                if type(hp) == "number" and hp <= 0 then
                    return true
                end
            end

            if cls:lower():find("wreck") or cls:lower():find("destroyed") then
                return true
            end

            return false
        end

        if isfunction(ent.Health) then
            local hp = ent:Health()
            if type(hp) == "number" and hp <= 0 then
                return true
            end
        end

        return false
    end

    local function GetEntityMaxHealth(ent)
        if not IsValid(ent) then return 0 end

        if isfunction(ent.GetMaxHealth) then
            local mh = ent:GetMaxHealth()
            if type(mh) == "number" and mh > 0 then return mh end
        end

        if isfunction(ent.GetMaxHP) then
            local mh = ent:GetMaxHP()
            if type(mh) == "number" and mh > 0 then return mh end
        end

        return 0
    end

    local function GetEntityHealth(ent)
        if not IsValid(ent) then return 0 end

        if isfunction(ent.GetHP) then
            local hp = ent:GetHP()
            if type(hp) == "number" then return hp end
        end

        if isfunction(ent.Health) then
            local hp = ent:Health()
            if type(hp) == "number" then return hp end
        end

        return 1
    end

    hook.Add("EntityTakeDamage", "WT_TrackDamage", function(victim, dmg)
        local attacker = GetActualAttacker(dmg:GetAttacker())
        if not IsValid(attacker) or not IsValid(victim) then return end
        if victim == attacker then return end

        local vcls = victim:GetClass() or ""
        if IsProjectileOrEffect(vcls) then return end

        if IsValid(victim:GetParent()) then
            local p = victim:GetParent()
            if isfunction(p.GetPilot) or isfunction(p.GetDriver) then
                victim = p
            end
        end

        -- Per-attacker-per-victim rate limiting
        lastHitTime[attacker] = lastHitTime[attacker] or {}
        local victimIdx = victim:EntIndex()
        lastHitTime[attacker][victimIdx] = lastHitTime[attacker][victimIdx] or 0
        if CurTime() - lastHitTime[attacker][victimIdx] < 0.12 then return end
        lastHitTime[attacker][victimIdx] = CurTime()

        -- Initialize damage history with separated structure
        if not damageHistory[victim] then
            damageHistory[victim] = {
                attackers = {},
                class = victim:GetClass() or "",
                maxHealth = GetEntityMaxHealth(victim)
            }
            if damageHistory[victim].maxHealth == 0 then
                local currentHP = GetEntityHealth(victim)
                if currentHP > 0 then
                    damageHistory[victim].maxHealth = currentHP
                end
            end
        end

        damageHistory[victim].attackers[attacker] = CurTime()
        trackedEntities[victim] = true

        local damage = dmg:GetDamage() or 0
        local maxHealth = damageHistory[victim].maxHealth
        local health = math.max(GetEntityHealth(victim), 1)

        if maxHealth > 0 and damage >= maxHealth * 0.3 and health > damage then
            net.Start("WT_ShowCritical")
            net.Send(attacker)
        else
            net.Start("WT_ShowHit")
            net.Send(attacker)
        end
    end)

    local function AwardKillCredit(victim)
        if not damageHistory[victim] or recentKills[victim] then return end

        local savedClass = damageHistory[victim].class or ""
        if IsProjectileOrEffect(savedClass) then
            damageHistory[victim] = nil
            trackedEntities[victim] = nil
            return
        end

        local cls = IsValid(victim) and (victim:GetClass() or "") or ""
        local looksLikeSimf = cls:find("gmod_sent_vehicle") or cls:find("simfphys") or cls:find("prop_vehicle")

        if looksLikeSimf then
            if not IsVehicleActuallyDestroyed(victim) then
                return
            end
        end

        recentKills[victim] = true

        local killer
        local lastTime = 0

        for ply, t in pairs(damageHistory[victim].attackers) do
            if IsValid(ply) and type(t) == "number" and t > lastTime then
                killer = ply
                lastTime = t
            end
        end

        if IsValid(killer) then
            local isVehicle = false
            if IsValid(victim) then
                local vcls = victim:GetClass() or ""
                isVehicle = vcls:find("gmod_sent_vehicle") or vcls:find("simfphys") or vcls:find("prop_vehicle") or vcls:find("lvs")
            end

            if isVehicle then
                lastKillTime[killer] = lastKillTime[killer] or {}
                local victimIdx = IsValid(victim) and victim:EntIndex() or 0
                lastKillTime[killer][victimIdx] = lastKillTime[killer][victimIdx] or 0
                if CurTime() - lastKillTime[killer][victimIdx] < 0.5 then
                    damageHistory[victim] = nil
                    trackedEntities[victim] = nil
                    return
                end
                lastKillTime[killer][victimIdx] = CurTime()
            end

            local isAircraft = false
            if IsValid(victim) then
                local class = victim:GetClass() or ""
                isAircraft = string.StartWith(class, "lvs_plane_") or string.StartWith(class, "lvs_heli_")
            end

            net.Start(isAircraft and "WT_ShowAircraftKill" or "WT_ShowKill")
            net.Send(killer)
        end

        damageHistory[victim] = nil
        trackedEntities[victim] = nil
        timer.Simple(5, function() recentKills[victim] = nil end)
    end

    hook.Add("EntityRemoved", "WT_DetectKill", function(victim)
        if not trackedEntities[victim] then return end
        AwardKillCredit(victim)
    end)

    hook.Add("OnNPCKilled", "WT_NPCKill", function(victim)
        AwardKillCredit(victim)
    end)

    hook.Add("PlayerDeath", "WT_PlayerKill", function(victim)
        AwardKillCredit(victim)
    end)

    hook.Add("LVS.OnVehicleDestroyed", "WT_LVSKill", function(vehicle)
        AwardKillCredit(vehicle)
    end)

    -- Periodic cleanup of stale data
    timer.Create("WT_CleanupHistory", 30, 0, function()
        for ent, _ in pairs(damageHistory) do
            if not IsValid(ent) then
                damageHistory[ent] = nil
                trackedEntities[ent] = nil
            end
        end

        for ent, _ in pairs(trackedEntities) do
            if not IsValid(ent) then
                trackedEntities[ent] = nil
            end
        end

        for ent, _ in pairs(recentKills) do
            if not IsValid(ent) then
                recentKills[ent] = nil
            end
        end

        for ply, _ in pairs(lastHitTime) do
            if not IsValid(ply) then
                lastHitTime[ply] = nil
            end
        end

        for ply, _ in pairs(lastKillTime) do
            if not IsValid(ply) then
                lastKillTime[ply] = nil
            end
        end
    end)

    return
end

-- CLIENT
local cvar_offset = CreateClientConVar("wt_hud_offset", "180", true, false)
local cvar_glow = CreateClientConVar("wt_hud_glow", "3", true, false)
local cvar_sound = CreateClientConVar("wt_hud_sounds", "1", true, false)

surface.CreateFont("WT_Main", {
    font = "Roboto Condensed",
    size = 44,
    weight = 900,
    antialias = true
})

surface.CreateFont("WT_Sub", {
    font = "Roboto Condensed",
    size = 24,
    weight = 700,
    antialias = true
})

local messages = {}
local MAX_MESSAGES = 10
local killStack = 0 -- Client-side kill streak counter

local function AddMessage(id, data)
    for _, m in ipairs(messages) do
        if m.id == id then
            m.count = m.count + 1
            m.time = m.maxTime
            return
        end
    end

    data.id = id
    data.count = 1
    data.life = 0

    if #messages >= MAX_MESSAGES then
        table.remove(messages, 1)
    end

    table.insert(messages, data)
end

local function AddKillMessage(id, data)
    -- Check if a kill message already exists
    for i = #messages, 1, -1 do
        if messages[i].id == "kill" or messages[i].id == "aircraft" then
            -- Kill message still visible, increment stack
            killStack = killStack + 1
            table.remove(messages, i)
            break
        end
    end

    data.id = id
    data.count = killStack
    data.life = 0

    if #messages >= MAX_MESSAGES then
        table.remove(messages, 1)
    end

    table.insert(messages, data)
end

net.Receive("WT_ShowHit", function()
    AddMessage("hit", {
        text = "Hit",
        sub  = "120 ✦ 10",
        color = Color(222, 222, 214),
        subColor = Color(196, 196, 188),
        time = 0.9,
        maxTime = 0.9,
        glow = 0,
        outline = true,
        rise = 8
    })

end)

net.Receive("WT_ShowCritical", function()
    AddMessage("critical", {
        text = "Critical hit",
        sub  = "740 ✦ 50",
        color = Color(222, 222, 214),
        subColor = Color(196, 196, 188),
        time = 1.15,
        maxTime = 1.15,
        glow = 0,
        outline = true,
        rise = 12
    })

end)

net.Receive("WT_ShowKill", function()
    -- Reset stack since no existing kill message means streak expired
    local hasExisting = false
    for _, m in ipairs(messages) do
        if m.id == "kill" or m.id == "aircraft" then
            hasExisting = true
            break
        end
    end

    if not hasExisting then
        killStack = 1
    end

    AddKillMessage("kill", {
        text = "Target destroyed",
        sub  = "3,260 ✦ 190",
        color = Color(255, 235, 230),
        subColor = Color(245, 245, 245),
        time = 1.7,
        maxTime = 1.7,
        glow = 6,
        outline = true,
        outlineColor = Color(255, 105, 95),
        outlineGlow = 2,
        rise = 18
    })

    surface.PlaySound("wt/kill.wav")

end)

net.Receive("WT_ShowAircraftKill", function()
    local hasExisting = false
    for _, m in ipairs(messages) do
        if m.id == "kill" or m.id == "aircraft" then
            hasExisting = true
            break
        end
    end

    if not hasExisting then
        killStack = 1
    end

    AddKillMessage("aircraft", {
        text = "Aircraft destroyed",
        sub  = "4,120 ✦ 250",
        color = Color(255, 235, 230),
        subColor = Color(245, 245, 245),
        time = 1.7,
        maxTime = 1.7,
        glow = 6,
        outline = true,
        outlineColor = Color(255, 105, 95),
        outlineGlow = 2,
        rise = 18
    })

end)

hook.Add("HUDPaint", "WT_DrawHUD", function()
    local x = ScrW() / 2
    local baseY = ScrH() * 0.28 - cvar_offset:GetInt()
    local y = baseY
    local minY = 10

    local glowMult = cvar_glow:GetInt()

    for i = #messages, 1, -1 do
        local m = messages[i]
        m.time = m.time - FrameTime()
        m.life = (m.life or 0) + FrameTime()

        if m.time <= 0 then
            -- If a kill message expires, reset the kill stack
            if m.id == "kill" or m.id == "aircraft" then
                killStack = 0
            end
            table.remove(messages, i)
            continue
        end

        if y < minY then continue end

        local t = math.Clamp(m.time / m.maxTime, 0, 1)
        local a = t * 255
        local yAnim = y - (1 - t) * (m.rise or 10)
        local text = m.text .. (m.count > 1 and (" x" .. m.count) or "")

        if m.outline then
            if m.outlineColor then
                local oc = m.outlineColor
                local outlineGlow = math.max(1, math.min(m.outlineGlow or 1, 4))
                -- Colored outline is drawn outside glyph fill for War Thunder-like kill text.
                for o = outlineGlow + 1, 2, -1 do
                    local oa = a * (0.12 + (0.10 * (o - 1)))
                    draw.SimpleText(text, "WT_Main", x + o, yAnim, Color(oc.r, oc.g, oc.b, oa), TEXT_ALIGN_CENTER)
                    draw.SimpleText(text, "WT_Main", x - o, yAnim, Color(oc.r, oc.g, oc.b, oa), TEXT_ALIGN_CENTER)
                    draw.SimpleText(text, "WT_Main", x, yAnim + o, Color(oc.r, oc.g, oc.b, oa), TEXT_ALIGN_CENTER)
                    draw.SimpleText(text, "WT_Main", x, yAnim - o, Color(oc.r, oc.g, oc.b, oa), TEXT_ALIGN_CENTER)
                    draw.SimpleText(text, "WT_Main", x + o, yAnim + o, Color(oc.r, oc.g, oc.b, oa * 0.75), TEXT_ALIGN_CENTER)
                    draw.SimpleText(text, "WT_Main", x - o, yAnim + o, Color(oc.r, oc.g, oc.b, oa * 0.75), TEXT_ALIGN_CENTER)
                    draw.SimpleText(text, "WT_Main", x + o, yAnim - o, Color(oc.r, oc.g, oc.b, oa * 0.75), TEXT_ALIGN_CENTER)
                    draw.SimpleText(text, "WT_Main", x - o, yAnim - o, Color(oc.r, oc.g, oc.b, oa * 0.75), TEXT_ALIGN_CENTER)
                end
            else
                -- Default outline for hit/critical remains the classic black shadow.
                draw.SimpleText(text, "WT_Main", x + 1, yAnim + 1, Color(0, 0, 0, a * 0.8), TEXT_ALIGN_CENTER)
            end
        end

        draw.SimpleText(text, "WT_Main", x, yAnim, Color(m.color.r, m.color.g, m.color.b, a), TEXT_ALIGN_CENTER)
        draw.SimpleText(m.sub, "WT_Sub", x, yAnim + 30, Color(m.subColor.r, m.subColor.g, m.subColor.b, a), TEXT_ALIGN_CENTER)

        y = y - 55
    end
end)