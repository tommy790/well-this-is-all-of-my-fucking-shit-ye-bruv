-- ============================================================================
-- TIV SPIKE ANIMATION - Server Side
-- Dynamic hydraulic spike deployment, terrain-adaptive ground interaction,
-- vehicle-relative coordinate calculations, and seamless mid-stroke reversal.
-- Fully supports Angled Spikes upgrade and custom 3D editor configurations.
-- ============================================================================

TIV = TIV or {}
TIV.SpikeAnim = TIV.SpikeAnim or {}

util.AddNetworkString("TIV_SpikeAnimStart")
util.AddNetworkString("TIV_SpikeAnimRetract")
util.AddNetworkString("TIV_SpikeAnimImpact")
util.AddNetworkString("TIV_SpikeAnimPhase")

TIV.SpikeAnim.ActiveJobs      = TIV.SpikeAnim.ActiveJobs or {}
TIV.SpikeAnim._sessionCounter = TIV.SpikeAnim._sessionCounter or 0

-- ============================================================================
-- SHARED THINK LOOP
-- Runs active hydraulic piston jobs every tick.
-- ============================================================================
timer.Create("TIV_SpikeAnimThink", 0.02, 0, function()
    for jobKey, job in pairs(TIV.SpikeAnim.ActiveJobs) do
        local ok = job.fn(job)
        if ok == false then
            TIV.SpikeAnim.ActiveJobs[jobKey] = nil
        end
    end
end)

-- ============================================================================
-- COORDINATE & ORIENTATION HELPERS
-- Strictly uses the vehicle's actual forward, right, up, and transformation
-- matrices. Never assumes world north/east corresponds to vehicle forward/right.
-- ============================================================================

-- Local angle that points the spike downward along the vehicle's down vector
local function GetParentedLocalAngle()
    return Angle(90, 0, 0)
end

-- World angle pointing downward along the spike's local angle vector
local function GetSpikeDownAngle(veh, localAng)
    if not IsValid(veh) then return localAng or Angle(90, 0, 0) end
    return veh:LocalToWorldAngles(localAng or GetParentedLocalAngle())
end

-- Local position for a spike when stored in the vehicle's hydraulic ram cylinder.
-- Follows the spike's directional vector so angled spikes retract and extend
-- strictly along their cylinder axis, rather than moving straight vertically.
local function GetStoredLocalPos(offsetPos, offsetAng)
    local pos = isvector(offsetPos) and offsetPos or Vector(0, 0, 0)
    local hoverOffset = TIV.Config.SpikeHoverOffset or 60
    local ang = isangle(offsetAng) and offsetAng or GetParentedLocalAngle()
    local dir = ang:Forward()
    return pos - (dir * hoverOffset)
end

TIV.SpikeAnim.GetSpikeDownAngle     = GetSpikeDownAngle
TIV.SpikeAnim.GetParentedLocalAngle = GetParentedLocalAngle
TIV.SpikeAnim.GetStoredLocalPos     = GetStoredLocalPos

-- ============================================================================
-- TERRAIN RAYCASTING
-- Traces downward beneath the actual mounting position along the spike's
-- penetration vector, adapting to slopes, terrain, and angled hydraulic rams.
-- ============================================================================
local function TraceGroundForSpike(veh, mountWorldPos, spikeAng, data)
    local localAng = isangle(spikeAng) and spikeAng or GetParentedLocalAngle()
    local worldAng = veh:LocalToWorldAngles(localAng)
    local downDir  = worldAng:Forward()

    local function traceFilter(ent)
        if not IsValid(ent) then return true end
        if ent == veh or (IsValid(ent:GetParent()) and ent:GetParent() == veh) or ent.TIV_OwnerVehicle == veh or ent.IsTIVArmor or ent.IsTIVSpike then
            return false
        end
        if data and data.spikes then
            for _, sd in ipairs(data.spikes) do
                if sd.entity == ent then return false end
            end
        end
        return true
    end

    -- Primary: trace along the spike's angled drive vector (350 units reach)
    local tr = util.TraceLine({
        start  = mountWorldPos,
        endpos = mountWorldPos + (downDir * 350),
        filter = traceFilter,
        mask   = MASK_SOLID,
    })

    -- Fallback 1: trace further along the angled drive vector if vehicle is lifted (500 units reach)
    if not tr.Hit then
        tr = util.TraceLine({
            start  = mountWorldPos,
            endpos = mountWorldPos + (downDir * 500),
            filter = traceFilter,
            mask   = MASK_SOLID,
        })
    end

    -- Fallback 2: if on a cliff or steep drop-off, trace down relative to vehicle
    if not tr.Hit then
        tr = util.TraceLine({
            start  = mountWorldPos,
            endpos = mountWorldPos + (-veh:GetUp() * 400),
            filter = traceFilter,
            mask   = MASK_SOLID,
        })
    end

    return tr
end

-- ============================================================================
-- COMPATIBILITY & VISIBILITY FLAGS
-- ============================================================================
function TIV.SpikeAnim.ApplyVisibility(spike)
    if not IsValid(spike) then return end
    local hidden = (TIV.Config.HideSpikes == true)
        or (GetConVar("tiv_hide_spikes") and GetConVar("tiv_hide_spikes"):GetBool())
    spike:SetNoDraw(hidden)
    spike:DrawShadow(not hidden)
end

function TIV.SpikeAnim.ApplyCompatibilityFlags(spike, veh)
    if not IsValid(spike) then return end

    spike:SetNWBool("TIV_Spike", true)
    if IsValid(veh) then spike:SetNWEntity("TIV_OwnerVehicle", veh) end
    spike:SetNWBool("GStormsIgnore", true)
    spike:SetNWBool("XT3Ignore", true)
    spike:SetNWBool("XT2Ignore", true)
    spike:SetNWBool("XTwister2Ignore", true)

    spike.IsTIVSpike           = true
    spike.GStormsIgnore        = true
    spike.XT3Ignore            = true
    spike.XT3DoNotApplyPhysics = true
    spike.XT2Ignore            = true
    spike.XT2DoNotApplyPhysics = true
    spike.XTwister2Ignore      = true
    spike.PhysgunDisabled      = true
    spike.DoNotDuplicate       = true
end

-- ============================================================================
-- GET OFFSETS FOR VEHICLE
-- ============================================================================
local function GetOffsetsForVehicle(veh)
    if not IsValid(veh) then
        return TIV.Config.SpikeOffsets.jeep
    end

    local model = string.lower(veh:GetModel() or "")
    local class = string.lower(veh:GetClass() or "")

    if class == "prop_vehicle_apc" or string.find(model, "apc", 1, true) then
        return TIV.Config.SpikeOffsets.prop_vehicle_apc or TIV.Config.SpikeOffsets.jeep
    end
    if class == "prop_vehicle_jalopy" or string.find(model, "jalopy", 1, true) or string.find(model, "vehicle.mdl", 1, true) then
        return TIV.Config.SpikeOffsets.jalopy or TIV.Config.SpikeOffsets.jeep
    end
    return TIV.Config.SpikeOffsets.jeep
end

-- ============================================================================
-- CREATE SPIKES ON VEHICLE
-- Mounts spikes solidly in the vehicle's local coordinate frame.
-- Integrates custom positions, custom angles, and custom models.
-- ============================================================================
function TIV.SpikeAnim.CreateSpikes(veh, data)
    if not IsValid(veh) then return end

    -- Check if player has unlocked angled_spikes
    local ply = (veh.GetDriver and veh:GetDriver()) or veh._TIVOwner
    if not IsValid(ply) and veh.CPPIGetOwner then
        ply = veh:CPPIGetOwner()
    end
    if not IsValid(ply) and game.SinglePlayer() then
        ply = player.GetHumans()[1] or Entity(1)
    end

    local hasAngledUpg = false
    if IsValid(ply) and TIV.Progression and TIV.Progression.GetPlayerProfile then
        local prof = TIV.Progression.GetPlayerProfile(ply)
        if prof and prof.unlocked_upgrades and prof.unlocked_upgrades["angled_spikes"] then
            hasAngledUpg = true
        end
    end

    -- Check if vehicle has custom configuration
    local customSpikes = nil
    if not veh._TIVConfig and TIV.CustomConfig and TIV.CustomConfig.GetSavedConfig then
        veh._TIVConfig = TIV.CustomConfig.GetSavedConfig(veh:GetModel())
    end
    local config = veh._TIVConfig or (TIV.CustomConfig and TIV.CustomConfig.GetDefaultConfig and TIV.CustomConfig.GetDefaultConfig(veh:GetModel(), hasAngledUpg))
    if config and istable(config.components) then
        customSpikes = {}
        for _, comp in ipairs(config.components) do
            if comp.type == "spike" then
                if not hasAngledUpg then
                    comp.ang = Angle(90, 0, 0)
                end
                table.insert(customSpikes, comp)
            end
        end
    end

    local offsets
    if customSpikes and #customSpikes > 0 then
        offsets = customSpikes
    else
        offsets = GetOffsetsForVehicle(veh)
    end

    -- The ceiling comes from the same resolver EnsureSpikes uses. Without the
    -- Heavy Anchor Array unlocked the two outer mounts in the default configs are
    -- simply beyond the cap, so the layout stays at six; with it, all eight build.
    -- They are appended last in the config, so the first six are always the
    -- original ones -- the stock anchor geometry is unchanged.
    local spikeCount = (TIV.Spikes and TIV.Spikes.ResolveCount and TIV.Spikes.ResolveCount(veh))
        or math.Clamp(customSpikes and #customSpikes or TIV.Config.SpikeCount, 0, 12)

    TIV.SpikeAnim._sessionCounter = TIV.SpikeAnim._sessionCounter + 1
    data.sessionID = tostring(TIV.Config.SessionSeed or 1000)
        .. "_" .. veh:EntIndex()
        .. "_" .. tostring(CurTime())
        .. "_" .. TIV.SpikeAnim._sessionCounter

    if spikeCount <= 0 then
        TIV.Spikes.RemoveAll(data, veh:EntIndex())
        data.spikes     = {}
        data.spikeAnims = {}
        return
    end

    TIV.Spikes.RemoveAll(data, veh:EntIndex())
    data.spikes     = {}
    data.spikeAnims = {}

    local groupFront = GetConVar("tiv_spike_group_front")
    local groupMid   = GetConVar("tiv_spike_group_mid")
    local groupRear  = GetConVar("tiv_spike_group_rear")
    local spreadOff  = GetConVar("tiv_spike_spread_offset") and GetConVar("tiv_spike_spread_offset"):GetFloat() or 0
    local lengthOff  = GetConVar("tiv_spike_length_offset") and GetConVar("tiv_spike_length_offset"):GetFloat() or 0

    for i = 1, spikeCount do
        local offsetData = offsets[i]
        if offsetData then
            local grp = offsetData.group or "mid"
            local allowed = true
            if grp == "front" and groupFront and not groupFront:GetBool() then allowed = false end
            if grp == "mid" and groupMid and not groupMid:GetBool() then allowed = false end
            if grp == "rear" and groupRear and not groupRear:GetBool() then allowed = false end

            if allowed then
                local rawPos = offsetData.pos or Vector(0, 0, 0)
                local adjPos = Vector(rawPos.x, rawPos.y, rawPos.z)
                if not customSpikes then
                    if adjPos.x > 0 then
                        adjPos.x = adjPos.x + spreadOff
                    elseif adjPos.x < 0 then
                        adjPos.x = adjPos.x - spreadOff
                    end
                    adjPos.y = adjPos.y + lengthOff
                end

                local storedLocalAng = GetParentedLocalAngle()
                if hasAngledUpg and offsetData.ang then
                    storedLocalAng = offsetData.ang
                else
                    storedLocalAng = Angle(90, 0, 0)
                end

                local storedLocalPos = GetStoredLocalPos(adjPos, storedLocalAng)

                local model = offsetData.model or TIV.Config.SpikeModel or "models/props_junk/harpoon002a.mdl"
                if not util.IsValidModel(model) then
                    model = "models/props_junk/harpoon002a.mdl"
                end

                local spike = ents.Create("prop_physics")
                if IsValid(spike) then
                    local worldPos = veh:LocalToWorld(storedLocalPos)
                    local worldAng = veh:LocalToWorldAngles(storedLocalAng)

                    spike:SetModel(model)
                    spike:SetPos(worldPos)
                    spike:SetAngles(worldAng)
                    spike:Spawn()
                    spike:Activate()

                    spike:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
                    spike:SetColor(Color(90, 90, 95, 255))
                    spike:SetMaterial("models/props_combine/metal_combinebridge001")

                    TIV.SpikeAnim.ApplyCompatibilityFlags(spike, veh)
                    TIV.SpikeAnim.ApplyVisibility(spike)
                    spike:SetCustomCollisionCheck(true)

                    local spikePhys = spike:GetPhysicsObject()
                    if IsValid(spikePhys) then
                        spikePhys:SetMass(1)
                        spikePhys:EnableMotion(false)
                        spikePhys:EnableGravity(false)
                    end

                    if constraint and constraint.NoCollide then
                        constraint.NoCollide(veh, spike, 0, 0)
                        if veh._TIVArmorProps then
                            for _, ap in ipairs(veh._TIVArmorProps) do
                                if IsValid(ap) then
                                    constraint.NoCollide(ap, spike, 0, 0)
                                end
                            end
                        end
                    end

                    spike:SetParent(veh)
                    spike:SetLocalPos(storedLocalPos)
                    spike:SetLocalAngles(storedLocalAng)

                    table.insert(data.spikes, {
                        entity         = spike,
                        offset         = adjPos,
                        storedLocalPos = storedLocalPos,
                        storedLocalAng = storedLocalAng,
                        localPos       = storedLocalPos,
                        index          = i,
                        phase          = "idle",
                        name           = offsetData.name or ("Spike " .. i),
                        group          = offsetData.group or "mid",
                        groundPos      = nil,
                        groundNormal   = nil,
                    })

                    data.spikeAnims[i] = "idle"
                end
            end
        end
    end
end

-- ============================================================================
-- REPARENT SPIKE TO VEHICLE
-- ============================================================================
function TIV.SpikeAnim.ReparentSpike(veh, spike, spikeData)
    if not IsValid(veh) or not IsValid(spike) then return end

    local spikePhys = spike:GetPhysicsObject()
    if IsValid(spikePhys) then
        spikePhys:EnableMotion(false)
        spikePhys:EnableGravity(false)
    end

    TIV.SpikeAnim.ApplyCompatibilityFlags(spike, veh)
    TIV.SpikeAnim.ApplyVisibility(spike)
    spike:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
    spike:SetParent(veh)
    spike:SetLocalPos(spikeData.storedLocalPos or spikeData.localPos)
    spike:SetLocalAngles(spikeData.storedLocalAng or GetParentedLocalAngle())
    spikeData.phase = "idle"
end

-- ============================================================================
-- HYDRAULIC RAM ANIMATION
-- The rams are cosmetic props parented to the vehicle. They telescope as the
-- anchors drive, so the reinforced_hydraulics unlock is something you see happen
-- rather than a static bracket. Driven by the same job ticker as the spikes, so
-- it is cancelled with them and cannot outlive the sequence.
-- ============================================================================
function TIV.SpikeAnim.SetRamExtension(veh, frac)
    if not IsValid(veh) or not veh._TIVArmorProps then return end
    frac = math.Clamp(frac or 0, 0, 1)
    for _, prop in ipairs(veh._TIVArmorProps) do
        if IsValid(prop) and prop._TIVRamBasePos then
            local dir    = prop._TIVRamDir or Vector(0, 0, -1)
            local travel = prop._TIVRamTravel or 10
            prop:SetLocalPos(prop._TIVRamBasePos + (dir * (travel * frac)))
        end
    end
end

local function vehicleHasRams(veh)
    if not IsValid(veh) or not veh._TIVArmorProps then return false end
    for _, prop in ipairs(veh._TIVArmorProps) do
        if IsValid(prop) and prop._TIVRamBasePos then return true end
    end
    return false
end

-- Reads the current extension back off the props so an interrupted stroke starts
-- from where the ram actually is instead of snapping to an end.
local function currentRamExtension(veh)
    local frac = 0
    for _, prop in ipairs(veh._TIVArmorProps or {}) do
        if IsValid(prop) and prop._TIVRamBasePos then
            local dir    = prop._TIVRamDir or Vector(0, 0, -1)
            local travel = prop._TIVRamTravel or 10
            local off    = prop:GetLocalPos() - prop._TIVRamBasePos
            frac = math.Clamp(off:Dot(dir) / math.max(travel, 0.001), 0, 1)
        end
    end
    return frac
end

local function StartRamStroke(sessionID, veh, target, duration)
    if not vehicleHasRams(veh) then return end

    local from  = currentRamExtension(veh)
    local start = CurTime()
    duration    = math.max(duration or 1.0, 0.01)

    TIV.SpikeAnim.ActiveJobs[sessionID .. "_rams"] = {
        veh = veh,
        fn  = function()
            if not IsValid(veh) then return false end
            local frac = math.Clamp((CurTime() - start) / duration, 0, 1)
            -- Same S-curve as the anchor stroke, so the ram and the spikes reach
            -- the end of their travel together.
            local ease = math.sin(Lerp(frac, from, target) * math.pi * 0.5)
            TIV.SpikeAnim.SetRamExtension(veh, frac >= 1 and target or ease)
            if frac >= 1 then return false end
        end,
    }
end

-- ============================================================================
-- CANCEL ACTIVE JOBS FOR VEHICLE
-- ============================================================================
local function CancelVehicleJobs(sessionID)
    if not sessionID then return end
    local prefix = sessionID .. "_"
    for jobKey in pairs(TIV.SpikeAnim.ActiveJobs) do
        if string.sub(jobKey, 1, #prefix) == prefix then
            TIV.SpikeAnim.ActiveJobs[jobKey] = nil
        end
    end
end

-- ============================================================================
-- DYNAMIC DEPLOYMENT TO GROUND
-- Staggered hydraulic stroke, terrain-adaptive raycasting, and physical settle.
-- ============================================================================
function TIV.SpikeAnim.DeployToGround(veh, data, callback)
    if not IsValid(veh) then
        if callback then callback() end
        return
    end
    if not data.spikes or #data.spikes == 0 then
        if callback then callback() end
        return
    end

    local sessionID = data.sessionID or tostring(veh:EntIndex())
    CancelVehicleJobs(sessionID)
    StartRamStroke(sessionID, veh, 1, TIV.Config.SpikeDriveDuration or 3.0)

    net.Start("TIV_SpikeAnimStart")
        net.WriteEntity(veh)
        net.WriteUInt(#data.spikes, 8)
    net.Broadcast()

    local totalSpikes   = #data.spikes
    local deployedCount = 0
    local speedMult     = GetConVar("tiv_deploy_speed") and math.max(0.2, GetConVar("tiv_deploy_speed"):GetFloat()) or 1.0
    local driveDepth    = math.Clamp(GetConVar("tiv_spike_drive_depth") and GetConVar("tiv_spike_drive_depth"):GetFloat() or 18, 5, 45)

    -- Extra drive depth from reinforced hydraulics upgrade if unlocked
    if veh._TIVEffectiveStats and veh._TIVEffectiveStats.drive_depth_bonus then
        driveDepth = driveDepth + veh._TIVEffectiveStats.drive_depth_bonus
    end

    local completionFired = false
    local function fireCompletion()
        if completionFired then return end
        completionFired = true
        if callback then callback() end
    end
    local function tickCompletion()
        deployedCount = deployedCount + 1
        if deployedCount >= totalSpikes then fireCompletion() end
    end

    for i, spikeData in ipairs(data.spikes) do
        local spike = spikeData.entity
        if not IsValid(spike) then
            tickCompletion()
        else
            local index = spikeData.index
            local grp   = spikeData.group or "mid"

            -- Staggered deployment timing: Rear anchors drop first, then Mid, then Front
            local baseDelay = 0.0
            if grp == "rear" then
                baseDelay = 0.00
            elseif grp == "mid" then
                baseDelay = 0.12
            elseif grp == "front" then
                baseDelay = 0.24
            end
            -- Subtle 30ms offset between left and right side hydraulic cylinders
            local sideJitter = (i % 2 == 0) and 0.03 or 0.00
            local stagger    = (baseDelay + sideJitter) / speedMult

            timer.Simple(stagger, function()
                if not IsValid(veh) or not IsValid(spike) then
                    tickCompletion()
                    return
                end

                local localAng = spikeData.storedLocalAng or GetParentedLocalAngle()
                local localDriveDir = localAng:Forward()

                -- Raycast downward from the spike's actual mounting position along its drive angle
                local mountWorldPos  = veh:LocalToWorld(spikeData.storedLocalPos)
                local groundTrace    = TraceGroundForSpike(veh, mountWorldPos, localAng, data)
                local worldDriveDir  = veh:LocalToWorldAngles(localAng):Forward()

                local groundWorldPos = groundTrace.Hit and groundTrace.HitPos
                    or (mountWorldPos + (worldDriveDir * 60))
                local groundNormal   = groundTrace.HitNormal or veh:GetUp()

                -- Calculate exact ground contact and anchoring depth in vehicle's local frame
                local groundLocalPos = veh:WorldToLocal(groundWorldPos)
                local targetLocalPos = groundLocalPos + (localDriveDir * driveDepth)

                spikeData.groundPos      = groundWorldPos
                spikeData.groundNormal   = groundNormal
                spikeData.targetLocalPos = targetLocalPos
                spikeData.phase          = "deploying"
                data.spikeAnims[index]   = "deploying"

                net.Start("TIV_SpikeAnimPhase")
                    net.WriteEntity(veh)
                    net.WriteUInt(index, 8)
                    net.WriteString("deploying")
                net.Broadcast()

                -- Starting local position (wherever the spike currently is)
                local startLocalPos      = spike:GetLocalPos()
                local strokeStart        = CurTime()
                local totalDriveDuration = (TIV.Config.SpikeDriveDuration or 3.0) / speedMult
                local strokeDuration     = totalDriveDuration * 0.88
                local settleDuration     = totalDriveDuration * 0.12
                local totalDuration      = strokeDuration + settleDuration

                local hasImpacted = false
                local jobKey      = sessionID .. "_deploy_" .. index

                TIV.SpikeAnim.ActiveJobs[jobKey] = {
                    veh   = veh,
                    spike = spike,
                    fn    = function(job)
                        if not IsValid(veh) or not IsValid(spike) then
                            tickCompletion()
                            return false
                        end

                        local elapsed = CurTime() - strokeStart

                        if elapsed < strokeDuration then
                            -- Main hydraulic stroke: smooth S-curve downward
                            local frac = math.Clamp(elapsed / strokeDuration, 0, 1)
                            local ease = math.sin(frac * math.pi * 0.5)

                            local curPos = LerpVector(ease, startLocalPos, groundLocalPos)
                            spike:SetLocalPos(curPos)
                            spike:SetLocalAngles(localAng)
                        else
                            -- Ground contact impact puff and sound
                            if not hasImpacted then
                                hasImpacted = true

                                net.Start("TIV_SpikeAnimImpact")
                                    net.WriteEntity(veh)
                                    net.WriteUInt(index, 8)
                                    net.WriteVector(groundWorldPos)
                                    net.WriteVector(groundNormal)
                                net.Broadcast()

                                spike:EmitSound("physics/metal/metal_solid_impact_bullet" .. math.random(1, 4) .. ".wav",
                                    70, math.random(95, 105))
                            end

                            -- Settling phase: penetrates to depth with hydraulic pressure rebound
                            local settleElapsed = elapsed - strokeDuration
                            local settleFrac    = math.Clamp(settleElapsed / settleDuration, 0, 1)

                            -- Damped harmonic settling oscillation
                            local bounce = math.sin(settleFrac * math.pi * 3) * (1 - settleFrac) * 1.5
                            local penetrationPos = LerpVector(settleFrac, groundLocalPos, targetLocalPos)
                            local settledPos = penetrationPos + (localDriveDir * bounce)

                            spike:SetLocalPos(settledPos)
                            spike:SetLocalAngles(localAng)
                        end

                        if elapsed >= totalDuration then
                            spikeData.phase        = "deployed"
                            data.spikeAnims[index] = "deployed"

                            local finalWorldPos = veh:LocalToWorld(targetLocalPos)
                            local finalWorldAng = veh:LocalToWorldAngles(localAng)

                            spike:SetParent(nil)
                            spike:SetPos(finalWorldPos)
                            spike:SetAngles(finalWorldAng)
                            spike:SetCollisionGroup(COLLISION_GROUP_WORLD)
                            TIV.SpikeAnim.ApplyCompatibilityFlags(spike, veh)

                            local sp = spike:GetPhysicsObject()
                            if IsValid(sp) then
                                sp:EnableMotion(false)
                            end

                            net.Start("TIV_SpikeAnimPhase")
                                net.WriteEntity(veh)
                                net.WriteUInt(index, 8)
                                net.WriteString("deployed")
                            net.Broadcast()

                            TIV.Anchor.AttachSingle(veh, data, spikeData, i)

                            tickCompletion()
                            return false
                        end

                        return true
                    end
                }
            end)
        end
    end
end

-- ============================================================================
-- DYNAMIC RETRACTION FROM GROUND
-- Smooth hydraulic withdrawal back into vehicle cylinders.
-- ============================================================================
function TIV.SpikeAnim.RetractFromGround(veh, data, callback)
    if not IsValid(veh) then
        if callback then callback() end
        return
    end
    if not data.spikes or #data.spikes == 0 then
        if callback then callback() end
        return
    end

    local sessionID = data.sessionID or tostring(veh:EntIndex())
    CancelVehicleJobs(sessionID)
    StartRamStroke(sessionID, veh, 0, TIV.Config.SpikeRetractDuration or 2.0)

    net.Start("TIV_SpikeAnimRetract")
        net.WriteEntity(veh)
    net.Broadcast()

    local totalSpikes    = #data.spikes
    local retractedCount = 0
    local speedMult      = GetConVar("tiv_deploy_speed") and math.max(0.2, GetConVar("tiv_deploy_speed"):GetFloat()) or 1.0

    local completionFired = false
    local function fireCompletion()
        if completionFired then return end
        completionFired = true
        if callback then callback() end
    end
    local function tickCompletion()
        retractedCount = retractedCount + 1
        if retractedCount >= totalSpikes then fireCompletion() end
    end

    for i, spikeData in ipairs(data.spikes) do
        local spike = spikeData.entity
        if not IsValid(spike) then
            tickCompletion()
        else
            local index    = spikeData.index
            local grp      = spikeData.group or "mid"
            local localAng = spikeData.storedLocalAng or GetParentedLocalAngle()

            -- Retract order: Front anchors withdraw first, then Mid, then Rear
            local baseDelay = 0.0
            if grp == "front" then
                baseDelay = 0.00
            elseif grp == "mid" then
                baseDelay = 0.10
            elseif grp == "rear" then
                baseDelay = 0.20
            end
            local sideJitter = (i % 2 == 0) and 0.02 or 0.00
            local stagger    = (baseDelay + sideJitter) / speedMult

            timer.Simple(stagger, function()
                if not IsValid(veh) or not IsValid(spike) then
                    tickCompletion()
                    return
                end

                local curLocalPos = veh:WorldToLocal(spike:GetPos())
                local targetLocalPos = spikeData.storedLocalPos

                -- Re-parent to vehicle so motion tracks cleanly if vehicle shifts
                spike:SetParent(veh)
                spike:SetLocalPos(curLocalPos)
                spike:SetLocalAngles(localAng)
                spike:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
                TIV.SpikeAnim.ApplyCompatibilityFlags(spike, veh)

                spikeData.phase        = "retracting"
                data.spikeAnims[index] = "retracting"

                net.Start("TIV_SpikeAnimPhase")
                    net.WriteEntity(veh)
                    net.WriteUInt(index, 8)
                    net.WriteString("retracting")
                net.Broadcast()

                local retractStart    = CurTime()
                local retractDuration = (TIV.Config.SpikeRetractDuration or 3.0) / speedMult
                local jobKey          = sessionID .. "_retract_" .. index

                TIV.SpikeAnim.ActiveJobs[jobKey] = {
                    veh   = veh,
                    spike = spike,
                    fn    = function(job)
                        if not IsValid(veh) or not IsValid(spike) then
                            tickCompletion()
                            return false
                        end

                        local elapsed = CurTime() - retractStart
                        local frac    = math.Clamp(elapsed / retractDuration, 0, 1)
                        local ease    = frac * frac * (3 - 2 * frac)

                        local newLocalPos = LerpVector(ease, curLocalPos, targetLocalPos)
                        spike:SetLocalPos(newLocalPos)
                        spike:SetLocalAngles(localAng)

                        if frac >= 1 then
                            TIV.SpikeAnim.ReparentSpike(veh, spike, spikeData)
                            data.spikeAnims[index] = "idle"

                            net.Start("TIV_SpikeAnimPhase")
                                net.WriteEntity(veh)
                                net.WriteUInt(index, 8)
                                net.WriteString("idle")
                            net.Broadcast()

                            tickCompletion()
                            return false
                        end

                        return true
                    end
                }
            end)
        end
    end
end

-- ============================================================================
-- INTERRUPT AND RETRACT
-- Handles pressing B while deployment is currently in progress.
-- Smoothly reverses all spikes from their current positions back to stored.
-- ============================================================================
function TIV.SpikeAnim.InterruptAndRetract(veh, data, callback)
    if not IsValid(veh) or not data.spikes then
        if callback then callback() end
        return
    end

    local sessionID = data.sessionID or tostring(veh:EntIndex())
    CancelVehicleJobs(sessionID)
    StartRamStroke(sessionID, veh, 0, TIV.Config.SpikeRetractDuration or 2.0)
    TIV.Anchor.DetachAll(veh, data)

    net.Start("TIV_SpikeAnimRetract")
        net.WriteEntity(veh)
    net.Broadcast()

    local totalSpikes    = #data.spikes
    local retractedCount = 0
    local speedMult      = GetConVar("tiv_deploy_speed") and math.max(0.2, GetConVar("tiv_deploy_speed"):GetFloat()) or 1.0

    local completionFired = false
    local function fireCompletion()
        if completionFired then return end
        completionFired = true
        if callback then callback() end
    end
    local function tickCompletion()
        retractedCount = retractedCount + 1
        if retractedCount >= totalSpikes then fireCompletion() end
    end

    for _, spikeData in ipairs(data.spikes) do
        local spike = spikeData.entity
        if not IsValid(spike) then
            tickCompletion()
        else
            local index    = spikeData.index
            local localAng = spikeData.storedLocalAng or GetParentedLocalAngle()

            -- Sample current real-time position
            local curLocalPos
            if IsValid(spike:GetParent()) then
                curLocalPos = spike:GetLocalPos()
            else
                curLocalPos = veh:WorldToLocal(spike:GetPos())
                spike:SetParent(veh)
                spike:SetLocalPos(curLocalPos)
                spike:SetLocalAngles(localAng)
            end

            spikeData.phase        = "retracting"
            data.spikeAnims[index] = "retracting"

            net.Start("TIV_SpikeAnimPhase")
                net.WriteEntity(veh)
                net.WriteUInt(index, 8)
                net.WriteString("retracting")
            net.Broadcast()

            local retractStart    = CurTime()
            local targetLocalPos  = spikeData.storedLocalPos
            local distFrac        = math.Clamp((curLocalPos - targetLocalPos):Length() / 40, 0.2, 1.0)
            local retractDuration = ((TIV.Config.SpikeRetractDuration or 3.0) * distFrac) / speedMult
            local jobKey          = sessionID .. "_int_retract_" .. index

            TIV.SpikeAnim.ActiveJobs[jobKey] = {
                veh   = veh,
                spike = spike,
                fn    = function(job)
                    if not IsValid(spike) or not IsValid(veh) then
                        tickCompletion()
                        return false
                    end

                    local elapsed = CurTime() - retractStart
                    local frac    = math.Clamp(elapsed / retractDuration, 0, 1)
                    local ease    = frac * frac * (3 - 2 * frac)

                    local newLocalPos = LerpVector(ease, curLocalPos, targetLocalPos)
                    spike:SetLocalPos(newLocalPos)
                    spike:SetLocalAngles(localAng)

                    if frac >= 1 then
                        TIV.SpikeAnim.ReparentSpike(veh, spike, spikeData)
                        data.spikeAnims[index] = "idle"

                        net.Start("TIV_SpikeAnimPhase")
                            net.WriteEntity(veh)
                            net.WriteUInt(index, 8)
                            net.WriteString("idle")
                        net.Broadcast()

                        tickCompletion()
                        return false
                    end

                    return true
                end
            }
        end
    end
end

-- ============================================================================
-- INTERRUPT AND DEPLOY
-- Handles pressing B while retraction is currently in progress.
-- Smoothly reverses all spikes from their current positions back to ground.
-- ============================================================================
function TIV.SpikeAnim.InterruptAndDeploy(veh, data, callback)
    if not IsValid(veh) or not data.spikes then
        if callback then callback() end
        return
    end

    local sessionID = data.sessionID or tostring(veh:EntIndex())
    CancelVehicleJobs(sessionID)
    StartRamStroke(sessionID, veh, 1, TIV.Config.SpikeDriveDuration or 3.0)

    net.Start("TIV_SpikeAnimStart")
        net.WriteEntity(veh)
        net.WriteUInt(#data.spikes, 8)
    net.Broadcast()

    local totalSpikes   = #data.spikes
    local deployedCount = 0
    local speedMult     = GetConVar("tiv_deploy_speed") and math.max(0.2, GetConVar("tiv_deploy_speed"):GetFloat()) or 1.0
    local driveDepth    = math.Clamp(GetConVar("tiv_spike_drive_depth") and GetConVar("tiv_spike_drive_depth"):GetFloat() or 18, 5, 45)

    if veh._TIVEffectiveStats and veh._TIVEffectiveStats.drive_depth_bonus then
        driveDepth = driveDepth + veh._TIVEffectiveStats.drive_depth_bonus
    end

    local completionFired = false
    local function fireCompletion()
        if completionFired then return end
        completionFired = true
        if callback then callback() end
    end
    local function tickCompletion()
        deployedCount = deployedCount + 1
        if deployedCount >= totalSpikes then fireCompletion() end
    end

    for i, spikeData in ipairs(data.spikes) do
        local spike = spikeData.entity
        if not IsValid(spike) then
            tickCompletion()
        else
            local index    = spikeData.index
            local localAng = spikeData.storedLocalAng or GetParentedLocalAngle()
            local localDriveDir = localAng:Forward()

            local mountWorldPos  = veh:LocalToWorld(spikeData.storedLocalPos)
            local groundTrace    = TraceGroundForSpike(veh, mountWorldPos, localAng, data)
            local worldDriveDir  = veh:LocalToWorldAngles(localAng):Forward()

            local groundWorldPos = groundTrace.Hit and groundTrace.HitPos
                or (mountWorldPos + (worldDriveDir * 60))
            local groundNormal   = groundTrace.HitNormal or veh:GetUp()
            local groundLocalPos = veh:WorldToLocal(groundWorldPos)
            local targetLocalPos = groundLocalPos + (localDriveDir * driveDepth)

            spikeData.groundPos      = groundWorldPos
            spikeData.groundNormal   = groundNormal
            spikeData.targetLocalPos = targetLocalPos
            spikeData.phase          = "deploying"
            data.spikeAnims[index]   = "deploying"

            net.Start("TIV_SpikeAnimPhase")
                net.WriteEntity(veh)
                net.WriteUInt(index, 8)
                net.WriteString("deploying")
            net.Broadcast()

            local curLocalPos = spike:GetLocalPos()
            local distFrac    = math.Clamp((curLocalPos - targetLocalPos):Length() / 40, 0.2, 1.0)
            local strokeStart = CurTime()
            local duration    = ((TIV.Config.SpikeDriveDuration or 3.0) * distFrac) / speedMult
            local jobKey      = sessionID .. "_int_deploy_" .. index

            TIV.SpikeAnim.ActiveJobs[jobKey] = {
                veh   = veh,
                spike = spike,
                fn    = function(job)
                    if not IsValid(veh) or not IsValid(spike) then
                        tickCompletion()
                        return false
                    end

                    local elapsed = CurTime() - strokeStart
                    local frac    = math.Clamp(elapsed / duration, 0, 1)
                    local ease    = math.sin(frac * math.pi * 0.5)

                    local newPos = LerpVector(ease, curLocalPos, targetLocalPos)
                    spike:SetLocalPos(newPos)
                    spike:SetLocalAngles(localAng)

                    if frac >= 1 then
                        spikeData.phase        = "deployed"
                        data.spikeAnims[index] = "deployed"

                        local finalWorldPos = veh:LocalToWorld(targetLocalPos)
                        local finalWorldAng = veh:LocalToWorldAngles(localAng)

                        spike:SetParent(nil)
                        spike:SetPos(finalWorldPos)
                        spike:SetAngles(finalWorldAng)
                        spike:SetCollisionGroup(COLLISION_GROUP_WORLD)
                        TIV.SpikeAnim.ApplyCompatibilityFlags(spike, veh)

                        local sp = spike:GetPhysicsObject()
                        if IsValid(sp) then sp:EnableMotion(false) end

                        net.Start("TIV_SpikeAnimPhase")
                            net.WriteEntity(veh)
                            net.WriteUInt(index, 8)
                            net.WriteString("deployed")
                        net.Broadcast()

                        TIV.Anchor.AttachSingle(veh, data, spikeData, i)

                        tickCompletion()
                        return false
                    end

                    return true
                end
            }
        end
    end
end

print("[TIV] Dynamic spike animation system loaded")
