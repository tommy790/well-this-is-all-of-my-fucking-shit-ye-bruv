-- ============================================================================
-- TIV ANCHOR SYSTEM
-- ============================================================================

TIV.Anchor = TIV.Anchor or {}

local function GetPivotLimit()
    return math.Clamp(tonumber(TIV.Config.AnchorPivotLimit) or 28, 5, 60)
end

-- ============================================================================
-- BUILD BALLSOCKET
-- ============================================================================
local function CreateSpikeBallsocket(veh, spike, localAttachPos, limitDeg, forceLimit)
    if not IsValid(veh) or not IsValid(spike) then return nil end
    return constraint.AdvBallsocket(
        veh, spike,
        0, 0,
        localAttachPos,
        Vector(0, 0, 0),
        forceLimit,
        0,
        -limitDeg, -limitDeg, -limitDeg,
         limitDeg,  limitDeg,  limitDeg,
        0, 0, 0,
        0, 0, 0,
        1
    )
end

-- ============================================================================
-- ATTACH SINGLE SPIKE
-- ============================================================================
function TIV.Anchor.AttachSingle(veh, data, spikeData, spikeTableIndex)
    if not IsValid(veh) or not IsValid(spikeData.entity) then return end

    data.constraints = data.constraints or {}

    local spike          = spikeData.entity
    local index          = spikeData.index
    local spikeWorldPos  = spike:GetPos()
    local localAttachPos = veh:WorldToLocal(spikeWorldPos)

    local spikePhys = spike:GetPhysicsObject()
    if IsValid(spikePhys) then
        spikePhys:EnableMotion(true)
        spikePhys:EnableGravity(false)
        spikePhys:SetVelocity(Vector(0, 0, 0))
        spikePhys:SetAngleVelocity(Vector(0, 0, 0))
    end

    local ballsocket = CreateSpikeBallsocket(
        veh, spike,
        localAttachPos,
        GetPivotLimit(),
        TIV.Config.BallSocketForceLimit
    )

    if IsValid(ballsocket) then
        table.insert(data.constraints, {
            constraint      = ballsocket,
            spikeIndex      = index,
            spikeTableIndex = spikeTableIndex,
            type            = "ballsocket",
            localPos        = localAttachPos,
        })
    else
        print("[TIV] WARNING: Ballsocket failed for spike " .. index)
    end

    local worldEnt = game.GetWorld()
    if IsValid(worldEnt) then
        local worldAnchor = constraint.AdvBallsocket(
            spike, worldEnt,
            0, 0,
            Vector(0, 0, 0),
            spikeWorldPos,
            TIV.Config.SpikeForceLimit,
            0,
            -1, -1, -1,
             1,  1,  1,
            0, 0, 0,
            0, 0, 0,
            1
        )
        if IsValid(worldAnchor) then
            table.insert(data.constraints, {
                constraint      = worldAnchor,
                spikeIndex      = index,
                spikeTableIndex = spikeTableIndex,
                isWorldAnchor   = true,
                type            = "anchor_ballsocket",
            })
        else
            print("[TIV] WARNING: World anchor failed for spike " .. index)
        end
    end

    local nocol = constraint.NoCollide(veh, spike, 0, 0)
    if IsValid(nocol) then
        table.insert(data.constraints, {
            constraint = nocol,
            spikeIndex = index,
            type       = "nocollide",
        })
    end

    -- Re-freeze spike now that all its constraints exist. This is what
    -- actually keeps the spike anchored to its world position; the
    -- world->spike ballsocket above is unreliable on its own.
    if IsValid(spikePhys) then
        spikePhys:SetVelocity(Vector(0, 0, 0))
        spikePhys:SetAngleVelocity(Vector(0, 0, 0))
        spikePhys:EnableMotion(false)
    end
end

-- ============================================================================
-- UNFREEZE FOR DEPLOY
-- ============================================================================
function TIV.Anchor.UnfreezeForDeploy(veh)
    if not IsValid(veh) then return end
    local phys = veh:GetPhysicsObject()
    if not IsValid(phys) then return end

    phys:EnableGravity(false)
    phys:SetVelocity(Vector(0, 0, 0))
    phys:SetAngleVelocity(Vector(0, 0, 0))
    phys:EnableMotion(true)
    phys:Wake()
end

-- ============================================================================
-- ATTACH ALL
-- ============================================================================
function TIV.Anchor.AttachAll(veh, data)
    if not IsValid(veh) then return end
    if not data.spikes or #data.spikes == 0 then return end

    TIV.Anchor.DetachAll(veh, data)
    data.constraints = {}

    for i, spikeData in ipairs(data.spikes) do
        if IsValid(spikeData.entity) then
            TIV.Anchor.AttachSingle(veh, data, spikeData, i)
        end
    end
end

-- ============================================================================
-- DETACH ALL
-- ============================================================================
function TIV.Anchor.DetachAll(veh, data)
    if not data.constraints then return end
    for _, conData in ipairs(data.constraints) do
        if IsValid(conData.constraint) then
            conData.constraint:Remove()
        end
    end
    data.constraints = {}
end

-- ============================================================================
-- CHECK INTEGRITY
-- Returns true if there's at least one intact vehicle->spike ballsocket.
-- (Matches original behavior.)
-- ============================================================================
function TIV.Anchor.CheckIntegrity(veh, data)
    if not data.constraints then return true end

    local broken = 0
    local ballsocketCount = 0

    for i = #data.constraints, 1, -1 do
        local conData = data.constraints[i]
        if not IsValid(conData.constraint) then
            table.remove(data.constraints, i)
            broken = broken + 1
        elseif conData.type == "ballsocket" then
            ballsocketCount = ballsocketCount + 1
        end
    end

    return ballsocketCount > 0
end

-- ============================================================================
-- GET COUNTS
-- ============================================================================
function TIV.Anchor.GetCounts(data)
    local counts = { total = 0, ballsockets = 0, anchors = 0, nocollide = 0 }
    if not data.constraints then return counts end
    for _, conData in ipairs(data.constraints) do
        if IsValid(conData.constraint) then
            counts.total = counts.total + 1
            if     conData.type == "ballsocket"        then counts.ballsockets = counts.ballsockets + 1
            elseif conData.type == "anchor_ballsocket" then counts.anchors     = counts.anchors + 1
            elseif conData.type == "nocollide"         then counts.nocollide   = counts.nocollide + 1
            end
        end
    end
    return counts
end

-- ============================================================================
-- FORCE DETACH
-- ============================================================================
function TIV.Anchor.ForceDetach(veh, data)
    for _, conData in ipairs(data.constraints or {}) do
        if IsValid(conData.constraint) then
            conData.constraint:Remove()
        end
    end
    data.constraints = {}
    data.anchored    = false

    -- Previously left vehicle gravity disabled after ForceDetach (because
    -- UnfreezeForDeploy turned it off). Restore it here so the vehicle falls.
    if IsValid(veh) then
        local phys = veh:GetPhysicsObject()
        if IsValid(phys) then
            phys:EnableGravity(true)

            -- Gravity alone is not enough. The deploy sequence disables motion
            -- while it lerps the body down and back up (sv_deploy.lua), so a
            -- detach landing inside that window restored gravity on a body that
            -- was still not allowed to move -- it hangs there under its own
            -- weight, which is exactly the "frozen after an intercept" symptom.
            -- ForceDetach means the anchors are gone, so there is nothing left
            -- that wants the body held still. This only ever enables motion; it
            -- never freezes and never adds a constraint.
            if not phys:IsMotionEnabled() then
                phys:EnableMotion(true)
            end
            phys:Wake()
        end
    end
end

-- ============================================================================
-- BREAK SPIKE
-- ============================================================================
function TIV.Anchor.BreakSpike(veh, data, spikeIndex)
    if not data.constraints then return false end
    local broke = false
    for i = #data.constraints, 1, -1 do
        local conData = data.constraints[i]
        if conData.spikeIndex == spikeIndex then
            if IsValid(conData.constraint) then
                conData.constraint:Remove()
            end
            table.remove(data.constraints, i)
            broke = true
        end
    end
    return broke
end

print("[TIV] Anchor system loaded")
