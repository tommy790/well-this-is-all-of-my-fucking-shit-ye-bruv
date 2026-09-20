-- ============================================================================
-- TIV ANCHOR SYSTEM
-- ============================================================================
-- Everything that physically ties the chassis to the ground lives here.
--
--   Plant   : a spike that has reached its drive depth becomes a static body
--             (motion disabled) -- it is now part of the world.
--   Pull-down: elastic constraints from the chassis mounts to the planted
--             spikes are shortened over LowerTime. The chassis is pulled down
--             onto its own suspension by real constraint force; the raycast
--             wheels compress exactly as far as the suspension allows.
--   Lock    : limited ballsockets between chassis and spikes hold the pulled
--             down pose. Force limit 0 means the loft system is the only
--             thing that ever breaks them.
--
-- The chassis physics object is never frozen, never teleported and keeps its
-- gravity throughout. Releasing the constraints is what raises the vehicle:
-- the suspension springs back on its own.
-- ============================================================================

TIV.Anchor = TIV.Anchor or {}

local function GetPivotLimit()
    return math.Clamp(tonumber(TIV.Config.AnchorPivotLimit) or 28, 5, 60)
end

local function Track(data, con, spikeData, kind, extra)
    data.constraints = data.constraints or {}
    local rec = {
        constraint      = con,
        spikeIndex      = spikeData and spikeData.index or 0,
        spikeTableIndex = spikeData and spikeData.tableIndex,
        type            = kind,
    }
    if extra then
        for k, v in pairs(extra) do rec[k] = v end
    end
    data.constraints[#data.constraints + 1] = rec
    return rec
end

local function VehicleMass(veh)
    local phys = veh:GetPhysicsObject()
    return IsValid(phys) and math.max(phys:GetMass(), 100) or 800
end

-- ============================================================================
-- PLANT (spike becomes static, chassis and spike ignore each other)
-- ============================================================================
function TIV.Anchor.PlantSingle(veh, data, spikeData)
    if not IsValid(veh) or not IsValid(spikeData.entity) then return end
    local spike = spikeData.entity

    if IsValid(spike:GetParent()) then
        local pos, ang = spike:GetPos(), spike:GetAngles()
        spike:SetParent(nil)
        spike:SetPos(pos)
        spike:SetAngles(ang)
    end

    local sp = spike:GetPhysicsObject()
    if IsValid(sp) then
        sp:EnableGravity(false)
        sp:SetVelocity(vector_origin)
        sp:SetAngleVelocity(vector_origin)
        sp:EnableMotion(false)
    end

    local nocol = constraint.NoCollide(veh, spike, 0, 0)
    if IsValid(nocol) then Track(data, nocol, spikeData, "nocollide") end

    spikeData.plantedPos = spike:GetPos()
    spikeData.phase = "deployed"
end

-- ============================================================================
-- PULL-DOWN (elastics chassis -> planted spikes)
-- ============================================================================
-- Returns the number of elastics created. `lowerAmount` is how far the
-- chassis mount should end up below its current height; the suspension is
-- the real limit, the spring only supplies the pull.
function TIV.Anchor.StartPullDown(veh, data, lowerAmount)
    if not IsValid(veh) then return 0 end
    local planted = {}
    for _, sd in ipairs(data.spikes or {}) do
        if sd.phase == "deployed" and IsValid(sd.entity) then planted[#planted + 1] = sd end
    end
    if #planted == 0 then return 0 end

    local mass = VehicleMass(veh)
    local n = #planted
    -- Spring stiffness per unit stretch: at full overshoot the anchors pull
    -- with roughly 8x the vehicle weight, spread across the spikes.
    local overshoot = 12
    local constant  = (mass * 600 * 8) / (n * (lowerAmount + overshoot))
    local damping   = (mass * 40) / n

    data.pullDown = { elastics = {}, startTime = CurTime(), lowerAmount = lowerAmount, overshoot = overshoot }

    for _, sd in ipairs(planted) do
        local mountLocal = sd.storedLocalPos or sd.localPos or veh:WorldToLocal(sd.entity:GetPos())
        local mountWorld = veh:LocalToWorld(mountLocal)
        local restLen = mountWorld:Distance(sd.entity:GetPos())

        local el = constraint.Elastic(veh, sd.entity, 0, 0, mountLocal, vector_origin,
            constant, damping, 0, "", 0, true)
        if IsValid(el) then
            el:Fire("SetSpringLength", tostring(restLen))
            Track(data, el, sd, "elastic", { restLength = restLen })
            data.pullDown.elastics[#data.pullDown.elastics + 1] = { con = el, restLength = restLen }
        end
    end
    return #data.pullDown.elastics
end

-- frac 0..1 of the lowering stroke; drives the spring lengths.
function TIV.Anchor.UpdatePullDown(data, frac)
    local pd = data.pullDown
    if not pd then return end
    local ease = frac * frac * (3 - 2 * frac)
    local shorten = (pd.lowerAmount + pd.overshoot) * ease
    for _, e in ipairs(pd.elastics) do
        if IsValid(e.con) then
            e.con:Fire("SetSpringLength", tostring(math.max(e.restLength - shorten, 1)))
        end
    end
end

-- ============================================================================
-- LOCK (limited ballsocket chassis <-> spike at the settled pose)
-- ============================================================================
function TIV.Anchor.AttachSingle(veh, data, spikeData, spikeTableIndex)
    if not IsValid(veh) or not IsValid(spikeData.entity) then return end
    spikeData.tableIndex = spikeTableIndex or spikeData.tableIndex

    local spike = spikeData.entity
    local sp = spike:GetPhysicsObject()
    if IsValid(sp) and sp:IsMotionEnabled() then
        sp:SetVelocity(vector_origin)
        sp:SetAngleVelocity(vector_origin)
        sp:EnableMotion(false)
    end

    local limit = GetPivotLimit()
    local localAttachPos = veh:WorldToLocal(spike:GetPos())
    local bs = constraint.AdvBallsocket(
        veh, spike, 0, 0,
        localAttachPos, vector_origin,
        TIV.Config.BallSocketForceLimit or 0, 0,
        -limit, -limit, -limit,
         limit,  limit,  limit,
        0, 0, 0,
        0, 0, 0,
        1
    )
    if IsValid(bs) then
        Track(data, bs, spikeData, "ballsocket", { localPos = localAttachPos })
    else
        print("[TIV] WARNING: Ballsocket failed for spike " .. tostring(spikeData.index))
    end

    local hasNoCollide = false
    for _, c in ipairs(data.constraints or {}) do
        if c.type == "nocollide" and c.spikeIndex == spikeData.index and IsValid(c.constraint) then
            hasNoCollide = true
            break
        end
    end
    if not hasNoCollide then
        local nocol = constraint.NoCollide(veh, spike, 0, 0)
        if IsValid(nocol) then Track(data, nocol, spikeData, "nocollide") end
    end
end

function TIV.Anchor.AttachAll(veh, data)
    if not IsValid(veh) then return end
    for i, sd in ipairs(data.spikes or {}) do
        if sd.phase == "deployed" and IsValid(sd.entity) then
            local has = false
            for _, c in ipairs(data.constraints or {}) do
                if c.type == "ballsocket" and c.spikeIndex == sd.index and IsValid(c.constraint) then
                    has = true
                    break
                end
            end
            if not has then TIV.Anchor.AttachSingle(veh, data, sd, i) end
        end
    end
end

-- 0-spike mode: hold the chassis to the world directly.
function TIV.Anchor.AttachWorld(veh, data)
    if not IsValid(veh) then return end
    local world = game.GetWorld()
    if not IsValid(world) then return end
    local limit = GetPivotLimit() * 0.5
    local bs = constraint.AdvBallsocket(
        veh, world, 0, 0,
        vector_origin, veh:GetPos(),
        TIV.Config.BallSocketForceLimit or 0, 0,
        -limit, -limit, -limit,
         limit,  limit,  limit,
        0, 0, 0,
        0, 0, 0,
        1
    )
    if IsValid(bs) then Track(data, bs, nil, "ballsocket", { isWorldAnchor = true }) end
end

-- ============================================================================
-- CHASSIS PHYSICS INVARIANT
-- The chassis is always a live body. Kept under the old name because the
-- loft/wire modules call it.
-- ============================================================================
function TIV.Anchor.UnfreezeForDeploy(veh)
    if not IsValid(veh) then return end
    local phys = veh:GetPhysicsObject()
    if not IsValid(phys) then return end
    if not phys:IsGravityEnabled() then phys:EnableGravity(true) end
    if not phys:IsMotionEnabled() then phys:EnableMotion(true) end
    phys:Wake()
end
TIV.Anchor.EnsureLive = TIV.Anchor.UnfreezeForDeploy

-- ============================================================================
-- DETACH
-- ============================================================================
function TIV.Anchor.DetachAll(veh, data)
    for _, c in ipairs(data.constraints or {}) do
        if IsValid(c.constraint) then c.constraint:Remove() end
    end
    data.constraints = {}
    data.pullDown = nil
    if IsValid(veh) then
        TIV.Anchor.UnfreezeForDeploy(veh)
    end
end

function TIV.Anchor.ForceDetach(veh, data)
    TIV.Anchor.DetachAll(veh, data)
    data.anchored = false
end

-- Removes only the hold-down constraints (ballsockets + elastics) so the
-- suspension springs back; nocollides stay until the spikes retract.
function TIV.Anchor.ReleaseHold(veh, data)
    for i = #(data.constraints or {}), 1, -1 do
        local c = data.constraints[i]
        if c.type == "ballsocket" or c.type == "elastic" then
            if IsValid(c.constraint) then c.constraint:Remove() end
            table.remove(data.constraints, i)
        end
    end
    data.pullDown = nil
    if IsValid(veh) then TIV.Anchor.UnfreezeForDeploy(veh) end
end

function TIV.Anchor.BreakSpike(veh, data, spikeIndex)
    if not data.constraints then return false end
    local broke = false
    for i = #data.constraints, 1, -1 do
        local c = data.constraints[i]
        if c.spikeIndex == spikeIndex and c.type ~= "nocollide" then
            if IsValid(c.constraint) then c.constraint:Remove() end
            table.remove(data.constraints, i)
            broke = true
        end
    end
    return broke
end

-- ============================================================================
-- QUERIES
-- ============================================================================
function TIV.Anchor.CheckIntegrity(veh, data)
    if not data.constraints then return true end
    local ballsockets = 0
    for i = #data.constraints, 1, -1 do
        local c = data.constraints[i]
        if not IsValid(c.constraint) then
            table.remove(data.constraints, i)
        elseif c.type == "ballsocket" then
            ballsockets = ballsockets + 1
        end
    end
    return ballsockets > 0
end

function TIV.Anchor.GetCounts(data)
    local counts = { total = 0, ballsockets = 0, anchors = 0, nocollide = 0, elastics = 0 }
    for _, c in ipairs(data.constraints or {}) do
        if IsValid(c.constraint) then
            counts.total = counts.total + 1
            if c.type == "ballsocket" then
                if c.isWorldAnchor then counts.anchors = counts.anchors + 1 else counts.ballsockets = counts.ballsockets + 1 end
            elseif c.type == "nocollide" then counts.nocollide = counts.nocollide + 1
            elseif c.type == "elastic" then counts.elastics = counts.elastics + 1
            end
        end
    end
    return counts
end

print("[TIV] Anchor system loaded")
