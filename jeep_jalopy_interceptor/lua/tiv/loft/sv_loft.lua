-- ============================================================================
-- TIV LOFT SYSTEM
-- Clean, Rock-Solid Physics Architecture:
-- 1. Rock-Solid Ground Planting (Zero artificial forces while anchored)
-- 2. External Tornado Mod Immunity while Anchored (GStorms & XT3 cannot suction/teleport vehicle)
-- 3. Instant Displacement Failsafe (If chassis moves > 40u from ground, triggers immediate loft)
-- 4. Directional Anchor Shearing (Rapid, dramatic sequential failure without canceling on wind dips)
-- 5. Clean Single-Impulse Loft (Natural Source gravity & storm physics handle flight; no mid-air traps)
-- ============================================================================

TIV.Loft = TIV.Loft or {}

util.AddNetworkString("TIV_LoftEvent")
util.AddNetworkString("TIV_AnchorWarning")

TIV.Loft.WindTimers    = TIV.Loft.WindTimers    or {}
TIV.Loft.FailingGroups = TIV.Loft.FailingGroups or {}

local function ReleaseSpikesOnLoft()
    local cv = GetConVar("tiv_loft_release_spikes")
    return cv and cv:GetBool() or false
end

CreateConVar("tiv_loft_release_spikes", "0",
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "If 1, spikes fly free as debris on loft. If 0, they stay parented to the vehicle.")

-- ============================================================================
-- EXTERNAL TORNADO MOD IMMUNITY HELPERS
-- Prevents GStorms, XTwisters 2, XTwisters 3, and generic storm mods from suctioning,
-- orbiting, or teleporting the anchored vehicle while constrained to the ground.
-- ============================================================================
function TIV.Loft.SetAnchoredImmunity(veh, enable)
    if not IsValid(veh) then return end
    if enable then
        veh:SetNWBool("GStormsIgnore", true)
        veh.GStormsIgnore        = true
        veh:SetNWBool("XT3Ignore", true)
        veh.XT3Ignore            = true
        veh.XT3DoNotApplyPhysics = true
        veh:SetNWBool("XT2Ignore", true)
        veh.XT2Ignore            = true
        veh.XT2DoNotApplyPhysics = true
        veh.XTwister2Ignore      = true
        veh.GStormsIgnoreWind    = true
        veh.XTwisterIgnore       = true
        veh.XTDoNotApplyPhysics  = true
    else
        veh:SetNWBool("GStormsIgnore", false)
        veh.GStormsIgnore        = nil
        veh:SetNWBool("XT3Ignore", false)
        veh.XT3Ignore            = nil
        veh.XT3DoNotApplyPhysics = nil
        veh:SetNWBool("XT2Ignore", false)
        veh.XT2Ignore            = nil
        veh.XT2DoNotApplyPhysics = nil
        veh.XTwister2Ignore      = nil
        veh.GStormsIgnoreWind    = nil
        veh.XTwisterIgnore       = nil
        veh.XTDoNotApplyPhysics  = nil
    end
end

-- ============================================================================
-- STRESS CALCULATION
-- ============================================================================
function TIV.Loft.CalculateStress(windMPH, veh)
    if windMPH < 100 then return 0 end
    local threshold = (IsValid(veh) and veh._TIVEffectiveStats and veh._TIVEffectiveStats.effective_loft_mph)
        or TIV.Config.LoftWindThreshold
        or 180
    local ratio = windMPH / threshold
    return math.Clamp(ratio * ratio, 0, 1)
end

local function GetWindScale(veh)
    local base = (TIV.Compat and TIV.Compat.Enabled) and (TIV.Compat.AnchoredWindForceScale or 0.65) or 1
    if IsValid(veh) and veh._TIVEffectiveStats and veh._TIVEffectiveStats.wind_force_mult then
        base = base * veh._TIVEffectiveStats.wind_force_mult
    end
    return base
end
TIV.Loft.GetWindScale = GetWindScale

local function CleanupLoftTracking(entIdx)
    TIV.Loft.WindTimers[entIdx]    = nil
    TIV.Loft.FailingGroups[entIdx] = nil
    for wave = 1, 3 do
        timer.Remove("TIV_WaveFail_" .. entIdx .. "_" .. wave)
    end
end
TIV.Loft.CleanupTracking = CleanupLoftTracking

-- ============================================================================
-- ARMOR TEARING (EXTREME VORTEX / AERODYNAMIC STRESS)
-- ============================================================================
function TIV.Loft.RipArmorPanel(veh, prop, windDir)
    if not IsValid(prop) then return end

    prop:SetParent(nil)
    constraint.RemoveAll(prop)
    prop.PhysgunDisabled      = nil
    prop.TIV_OwnerVehicle     = nil
    prop.IsTIVArmor           = nil
    prop.GStormsIgnore        = nil
    prop.XT3Ignore            = nil
    prop.XT3DoNotApplyPhysics = nil
    prop.XT2Ignore            = nil
    prop.XT2DoNotApplyPhysics = nil
    prop.XTwister2Ignore      = nil

    local phys = prop:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetMass(35)
        phys:EnableMotion(true)
        phys:EnableGravity(true)
        phys:Wake()

        local tearDir = (windDir:GetNormalized() + Vector(0, 0, 0.35) + VectorRand() * 0.2):GetNormalized()
        phys:ApplyForceCenter(tearDir * phys:GetMass() * 2400)
        phys:ApplyTorqueCenter(VectorRand() * 1200)
    end

    prop:SetCollisionGroup(COLLISION_GROUP_DEBRIS)

    local ed = EffectData()
    ed:SetOrigin(prop:GetPos())
    ed:SetMagnitude(8)
    ed:SetScale(2.5)
    util.Effect("Sparks", ed)

    prop:EmitSound("physics/metal/metal_sheet_impact_hard" .. math.random(6, 8) .. ".wav", 95, math.random(70, 85))
    util.ScreenShake(prop:GetPos(), 8, 10, 0.5, 300)

    if IsValid(veh) and veh._TIVArmorProps then
        for i = #veh._TIVArmorProps, 1, -1 do
            if veh._TIVArmorProps[i] == prop then
                table.remove(veh._TIVArmorProps, i)
            end
        end
    end

    SafeRemoveEntityDelayed(prop, 15)
end

function TIV.Loft.CheckArmorTear(veh, windMPH, windForceVec)
    if not IsValid(veh) or not veh._TIVArmorProps or #veh._TIVArmorProps == 0 then return end
    if windMPH < 200 then return end

    if math.random() < 0.08 then
        local idx = math.random(1, #veh._TIVArmorProps)
        local prop = veh._TIVArmorProps[idx]
        if IsValid(prop) then
            TIV.Loft.RipArmorPanel(veh, prop, windForceVec)
        end
    end
end

-- ============================================================================
-- FAIL SPIKE LIST (SEQUENTIAL WAVE EXECUTION)
-- ============================================================================
function TIV.Loft.FailSpikeList(veh, data, spikesToFail, duration)
    local cheatGodmode = GetConVar("tiv_cheat_godmode_anchors")
    if cheatGodmode and cheatGodmode:GetBool() then return end
    if not IsValid(veh) or not data or #spikesToFail == 0 then return end

    veh:EmitSound("physics/metal/metal_box_break1.wav", 88, 55)
    local staggerPerSpike = (duration or 0.3) / math.max(1, #spikesToFail)

    for i, sd in ipairs(spikesToFail) do
        local spikeIdx = sd.index
        timer.Simple((i - 1) * staggerPerSpike, function()
            if not IsValid(veh) or data.state ~= "anchored" then return end
            if sd.failed then return end
            sd.failed = true

            -- Sever the hold on this spike first, then let the spike itself
            -- tear out of the ground as debris.
            TIV.Anchor.BreakSpike(veh, data, spikeIdx)

            local spikeEnt = sd.entity
            if IsValid(spikeEnt) then
                spikeEnt:SetMoveType(MOVETYPE_VPHYSICS)
                local sp = spikeEnt:GetPhysicsObject()
                if IsValid(sp) then
                    sp:EnableMotion(true)
                    sp:EnableGravity(true)
                    sp:Wake()
                    sp:ApplyForceCenter((Vector(0, 0, 400) + VectorRand() * 200) * sp:GetMass())
                end
                spikeEnt:SetCollisionGroup(COLLISION_GROUP_DEBRIS)

                local sparkFX = EffectData()
                sparkFX:SetOrigin(spikeEnt:GetPos())
                sparkFX:SetMagnitude(8)
                sparkFX:SetScale(3)
                util.Effect("Sparks", sparkFX)
                spikeEnt:EmitSound("physics/metal/metal_box_break" .. math.random(1, 2) .. ".wav", 90, math.random(60, 80))

                -- Taken back aboard shortly after; it is still the vehicle's
                -- piston, it just lost its grip on the ground.
                timer.Simple(0.4, function()
                    if not IsValid(veh) or not IsValid(spikeEnt) then return end
                    if TIV.SpikeAnim and TIV.SpikeAnim.ReparentSpike then
                        TIV.SpikeAnim.ReparentSpike(veh, spikeEnt, sd)
                        sd.failed = true
                    end
                    if data.spikeAnims then data.spikeAnims[spikeIdx] = "idle" end
                end)
            end

            net.Start("TIV_AnchorWarning")
                net.WriteEntity(veh)
                net.WriteUInt(spikeIdx, 8)
            net.Broadcast()
            hook.Run("TIV_SpikeFailure", veh, spikeIdx)

            local remaining = 0
            for _, c in ipairs(data.constraints or {}) do
                if c.type == "ballsocket" and IsValid(c.constraint) then remaining = remaining + 1 end
            end
            if remaining == 0 then
                TIV.Loft.TriggerLoft(veh, data)
            end
        end)
    end
end

-- ============================================================================
-- START DIRECTIONAL WINDWARD FAILURE
-- Calculates wind angle relative to vehicle and shears windward anchors first.
-- ============================================================================
function TIV.Loft.StartDirectionalFailure(veh, data)
    if not IsValid(veh) or not data then return end
    if data.state ~= "anchored" then return end

    local entIndex = veh:EntIndex()
    if TIV.Loft.WindTimers[entIndex] then return end

    TIV.Loft.WindTimers[entIndex]    = CurTime()
    TIV.Loft.FailingGroups[entIndex] = true

    -- Gather all live, deployed spikes
    local liveSpikes = {}
    for _, sd in ipairs(data.spikes or {}) do
        if sd.phase == "deployed" and not sd.failed and IsValid(sd.entity) then
            table.insert(liveSpikes, sd)
        end
    end

    if #liveSpikes == 0 then
        TIV.Loft.TriggerLoft(veh, data)
        return
    end

    -- Determine relative wind vector to calculate windward vs leeward exposure
    local windForceVec = TIV.Wind.GetForceVector(veh)
    local localWind    = veh:WorldToLocal(veh:GetPos() + windForceVec):GetNormalized()

    for _, sd in ipairs(liveSpikes) do
        local lpos = sd.offset or veh:WorldToLocal(sd.entity:GetPos())
        sd._windExposure = lpos:Dot(localWind)
    end

    table.sort(liveSpikes, function(a, b)
        return (a._windExposure or 0) < (b._windExposure or 0)
    end)

    -- Partition into 3 rapid failure waves, windward first. Every spike lands
    -- in a wave regardless of count, otherwise leftover anchors would hold the
    -- vehicle down forever after the sequence "finished".
    local count = #liveSpikes
    local wave1, wave2, wave3 = {}, {}, {}
    for i, sd in ipairs(liveSpikes) do
        local frac = (i - 1) / count
        if frac < 1 / 3 then
            table.insert(wave1, sd)
        elseif frac < 2 / 3 or count == 2 and i == 2 then
            table.insert(count == 2 and wave3 or wave2, sd)
        else
            table.insert(wave3, sd)
        end
    end

    print(string.format("[TIV] Vehicle #%d exceeding threshold. Initiating rapid failure sequence (W1: %d, W2: %d, W3: %d)",
        entIndex, #wave1, #wave2, #wave3))

    -- Wave 1: Immediate failure (0.05s)
    if #wave1 > 0 then
        timer.Create("TIV_WaveFail_" .. entIndex .. "_1", 0.05, 1, function()
            if not IsValid(veh) or data.state ~= "anchored" then return end
            TIV.Loft.FailSpikeList(veh, data, wave1, 0.25)
        end)
    end

    -- Wave 2: Mid-flank failure (0.35s)
    if #wave2 > 0 then
        timer.Create("TIV_WaveFail_" .. entIndex .. "_2", 0.35, 1, function()
            if not IsValid(veh) or data.state ~= "anchored" then return end
            TIV.Loft.FailSpikeList(veh, data, wave2, 0.25)
        end)
    end

    -- Wave 3: Leeward final failure (0.70s)
    if #wave3 > 0 then
        timer.Create("TIV_WaveFail_" .. entIndex .. "_3", 0.70, 1, function()
            if not IsValid(veh) or data.state ~= "anchored" then return end
            TIV.Loft.FailSpikeList(veh, data, wave3, 0.25)
        end)
    end
end

-- ============================================================================
-- TRIGGER FULL LOFT
-- Clean single launch impulse. Natural Source gravity & storm physics handle flight.
-- ============================================================================
function TIV.Loft.TriggerLoft(veh, data)
    if not IsValid(veh) then return end
    if data.state == "lofted" then return end

    local cheatGodmode = GetConVar("tiv_cheat_godmode_anchors")
    if cheatGodmode and cheatGodmode:GetBool() then
        return
    end

    local entIdx    = veh:EntIndex()
    local sessionID = data.sessionID

    print("[TIV] ================================")
    print("[TIV] === TIV LOFT TRIGGERED       ===")
    print(string.format("[TIV] === Wind: %.0f MPH at t=%.2f ===",
        TIV.Wind.GetSpeed(veh), CurTime()))
    print("[TIV] ================================")

    -- 1. Complete constraint severance: vehicle is fully freed from spikes & world
    TIV.Anchor.ForceDetach(veh, data)
    timer.Remove("TIV_Lower_" .. entIdx)
    timer.Remove("TIV_Raise_" .. entIdx)

    data.state       = "lofted"
    data.anchored    = false
    data.plantedPos  = nil

    -- 2. Clear external tornado mod immunity so storm naturally carries the vehicle
    TIV.Loft.SetAnchoredImmunity(veh, false)

    -- 3. Restore vehicle gravity, motion, and physics
    -- finalizeAnchored applied the handbrake; StartRetract releases it on the
    -- normal path but a loft bypasses retract entirely, so without this the
    -- vehicle lands with the handbrake on and will not drive. That presents as a
    -- frozen vehicle even though the physics are healthy.
    if TIV.Deploy.ReleaseHandbrake then
        TIV.Deploy.ReleaseHandbrake(veh)
    end
    data.handbrakeOn = nil

    local phys = veh:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableGravity(true)
        phys:EnableMotion(true)
        phys:Wake()

        -- Single initial launch impulse: fling up and downwind with natural tumble
        local mass      = phys:GetMass()
        local upForce   = Vector(0, 0, 1) * mass * (TIV.Config.LoftForceMultiplier or 1200)
        local windForce = TIV.Wind.GetForceVector(veh) * mass * 0.65
        local tumble    = VectorRand() * (TIV.Config.LoftTumbleForce or 350) * mass

        phys:ApplyForceCenter(upForce + windForce)
        phys:ApplyTorqueCenter(tumble)
    end

    -- 4. Release or reparent spikes
    if ReleaseSpikesOnLoft() then
        if TIV.Spikes.ReleaseAll then
            TIV.Spikes.ReleaseAll(data)
        end
    else
        for _, sd in ipairs(data.spikes or {}) do
            if IsValid(sd.entity) and TIV.SpikeAnim and TIV.SpikeAnim.ReparentSpike then
                TIV.SpikeAnim.ReparentSpike(veh, sd.entity, sd)
                if data.spikeAnims and sd.index then
                    data.spikeAnims[sd.index] = "idle"
                end
            end
        end
    end

    util.ScreenShake(veh:GetPos(), 25, 15, 3, 800)

    net.Start("TIV_LoftEvent")
        net.WriteEntity(veh)
    net.Broadcast()

    hook.Run("TIV_LoftEvent", veh)

    TIV.Deploy.BroadcastState(veh, "lofted")

    CleanupLoftTracking(entIdx)

    -- 5. Automatic reset 15 seconds after loft to safely mount fresh spikes and return to idle
    timer.Simple(15, function()
        local liveVeh  = Entity(entIdx)
        local liveData = TIV.Deploy.Vehicles and TIV.Deploy.Vehicles[entIdx]

        if not liveData or liveData.sessionID ~= sessionID then return end

        if liveData.spikes then
            for _, sd in ipairs(liveData.spikes) do
                if IsValid(sd.entity) then SafeRemoveEntity(sd.entity) end
            end
        end
        liveData.spikes          = {}
        liveData.spikeAnims      = {}
        liveData.spikesCreated   = false
        liveData.state           = "idle"
        liveData.anchored        = false
        liveData.gravityReleased = false
        liveData.plantedPos      = nil
        liveData.handbrakeOn     = nil

        if IsValid(liveVeh) then
            -- Re-assert the "idle means drivable" invariant rather than assuming
            -- the loft path left things clean. Every one of these calls only ever
            -- enables physics or removes this addon's own constraints, so this
            -- cannot itself be what traps a vehicle.
            TIV.Anchor.DetachAll(liveVeh, liveData)
            if TIV.Deploy.ReleaseHandbrake then TIV.Deploy.ReleaseHandbrake(liveVeh) end

            local p = liveVeh:GetPhysicsObject()
            if IsValid(p) then
                if not p:IsGravityEnabled() then p:EnableGravity(true) end
                if not p:IsMotionEnabled() then
                    p:EnableMotion(true)
                    p:Wake()
                end
            end

            TIV.Deploy.BroadcastState(liveVeh, "idle")
            if TIV.CustomComponents and TIV.CustomComponents.EnsureArmor then
                TIV.CustomComponents.EnsureArmor(liveVeh)
            end
        end
    end)
end

-- ============================================================================
-- MAIN LOFT THINK
-- ============================================================================
local function ProcessAnchored(entIndex, veh, data)
    local phys = veh:GetPhysicsObject()
    if not IsValid(phys) then return end

    local windMPH = TIV.Wind.GetSpeed(veh)
    local stress  = TIV.Loft.CalculateStress(windMPH, veh)
    local effectiveThreshold = (veh._TIVEffectiveStats and veh._TIVEffectiveStats.effective_loft_mph)
        or TIV.Config.LoftWindThreshold or 180

    if not data.plantedPos then data.plantedPos = veh:GetPos() end

    -- Displacement failsafe: the anchors have physically failed if the
    -- chassis got more than 40 units from where it was planted.
    local distFromPlanted = veh:GetPos():Distance(data.plantedPos)
    if distFromPlanted > 40 then
        print(string.format("[TIV] Vehicle #%d lifted %.1f units from ground anchors - triggering instant loft!",
            entIndex, distFromPlanted))
        TIV.Loft.TriggerLoft(veh, data)
        return
    end

    if not veh.XT3Ignore or not veh.GStormsIgnore or not veh.XT2Ignore then
        TIV.Loft.SetAnchoredImmunity(veh, true)
    end

    local isFailing = TIV.Loft.FailingGroups[entIndex] or data.gravityReleased

    -- A planted spike that lost its ballsocket outside a failure sequence
    -- (e.g. an admin cleanup) is re-locked; during failure it counts as gone.
    for i, sd in ipairs(data.spikes or {}) do
        if sd.phase == "deployed" and not sd.failed and IsValid(sd.entity) then
            local hasBS = false
            for _, c in ipairs(data.constraints or {}) do
                if c.spikeIndex == sd.index and c.type == "ballsocket" and IsValid(c.constraint) then
                    hasBS = true
                    break
                end
            end
            if not hasBS then
                if isFailing or distFromPlanted > 20 then
                    sd.failed = true
                else
                    TIV.Anchor.AttachSingle(veh, data, sd, i)
                end
            end
        end
    end

    local liveBallsockets = 0
    for _, c in ipairs(data.constraints or {}) do
        if c.type == "ballsocket" and IsValid(c.constraint) then liveBallsockets = liveBallsockets + 1 end
    end
    if liveBallsockets == 0 and TIV.Spikes.GetCount(data) > 0 then
        print(string.format("[TIV] All anchor constraints lost on #%d - triggering immediate loft!", entIndex))
        TIV.Loft.TriggerLoft(veh, data)
        return
    end

    if stress > 0.40 then
        data.nextShakeTime = data.nextShakeTime or 0
        if CurTime() > data.nextShakeTime then
            data.nextShakeTime = CurTime() + 0.30
            util.ScreenShake(veh:GetPos(), math.Clamp(stress * 3.0, 0.5, 3.0), 10, 0.35, 350)
        end
    end

    local soundChance
    if stress > TIV.Config.Stress.SoundCrit then
        soundChance = TIV.Config.StressCritChance
    elseif stress > TIV.Config.Stress.SoundHigh then
        soundChance = TIV.Config.StressHighSoundChance
    else
        soundChance = TIV.Config.StressLowSoundChance
    end
    if math.random() < soundChance then
        veh:EmitSound("physics/metal/metal_box_strain" .. math.random(1, 4) .. ".wav", 70, math.random(40, 65))
    end

    TIV.Loft.CheckArmorTear(veh, windMPH, TIV.Wind.GetForceVector(veh))

    if windMPH >= effectiveThreshold then
        if TIV.Spikes.GetCount(data) == 0 then
            TIV.Loft.TriggerLoft(veh, data)
        else
            TIV.Loft.StartDirectionalFailure(veh, data)
        end
    elseif TIV.Loft.WindTimers[entIndex] and not isFailing and windMPH < effectiveThreshold * 0.70 then
        data.calmDuration = (data.calmDuration or 0) + 0.05
        if data.calmDuration >= 2.0 then
            print(string.format("[TIV] Wind sustained drop to %.0f MPH - sequence reset for #%d", windMPH, entIndex))
            CleanupLoftTracking(entIndex)
            data.calmDuration = 0
        end
    else
        data.calmDuration = 0
    end
end

timer.Create("TIV_LoftThink", 0.05, 0, function()
    for entIndex, data in pairs(TIV.Deploy.Vehicles or {}) do
        if data.state == "anchored" then
            local veh = Entity(entIndex)
            if IsValid(veh) then
                ProcessAnchored(entIndex, veh, data)
            end
        elseif TIV.Loft.WindTimers[entIndex] then
            CleanupLoftTracking(entIndex)
        end
    end
end)

-- ============================================================================
-- CLEANUP
-- ============================================================================


print("[TIV] Clean 5-Stage Loft system loaded")
