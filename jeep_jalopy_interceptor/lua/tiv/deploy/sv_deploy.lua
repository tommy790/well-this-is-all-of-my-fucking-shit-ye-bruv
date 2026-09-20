-- ============================================================================
-- TIV DEPLOY SYSTEM
-- ============================================================================

TIV.Deploy = TIV.Deploy or {}

util.AddNetworkString("TIV_DeployStatus")
util.AddNetworkString("TIV_DeployRequest")

TIV.Deploy.Vehicles  = TIV.Deploy.Vehicles  or {}
TIV.Deploy.Cooldowns = TIV.Deploy.Cooldowns or {}

local COOLDOWN_TIME = 1.5

-- ============================================================================
-- STATE INIT
-- ============================================================================
function TIV.Deploy.GetState(veh)
    if not IsValid(veh) then return nil end
    local idx = veh:EntIndex()
    if not TIV.Deploy.Vehicles[idx] then
        TIV.Deploy.Vehicles[idx] = {
            state            = "idle",
            originalPos      = nil,
            spikes           = {},
            constraints      = {},
            spikeAnims       = {},
            anchored         = false,
            spikesCreated    = false,
            sessionID        = nil,
            gravityReleased  = false,
        }
    end
    return TIV.Deploy.Vehicles[idx]
end

-- Wrap (don't copy) so we always pick up the current TIV.* impl, even if
-- load order ever shifts. Copying by reference at file-load time was fragile.
function TIV.Deploy.IsJeep(ent)
    return TIV.IsSupportedVehicle and TIV.IsSupportedVehicle(ent) or false
end

function TIV.Deploy.ResolveVehicle(ply)
    if TIV.ResolveVehicle then return TIV.ResolveVehicle(ply) end
    -- Inline fallback if shared helper isn't loaded yet.
    if not IsValid(ply) then return nil end
    local seat = ply:GetVehicle()
    if not IsValid(seat) then return nil end
    return seat
end

-- ============================================================================
-- BROADCAST
-- ============================================================================
function TIV.Deploy.BroadcastState(veh, state)
    net.Start("TIV_DeployStatus")
        net.WriteEntity(veh)
        net.WriteString(state)
    net.Broadcast()

    hook.Run("TIV_StateChanged", veh, state)
end

-- ============================================================================
-- HANDBRAKE
-- ============================================================================
local function ApplyHandbrake(veh)
    if not IsValid(veh) then return end
    local phys = veh:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetVelocity(Vector(0, 0, 0))
        phys:SetAngleVelocity(Vector(0, 0, 0))
    end
    if veh.SetHandbrake then veh:SetHandbrake(true) end
    -- Recorded so the freeze watchdog can tell a deliberate handbrake from a
    -- leaked one. A handbrake left on after an intercept looks exactly like a
    -- frozen vehicle from the driver's seat while the physics are perfectly fine.
    local data = TIV.Deploy.GetState(veh)
    if data then data.handbrakeOn = true end
end

local function ReleaseHandbrake(veh)
    if not IsValid(veh) then return end
    if veh.SetHandbrake then veh:SetHandbrake(false) end
    local data = TIV.Deploy.GetState(veh)
    if data then data.handbrakeOn = nil end
end

-- Exposed so the loft system can release it too. TriggerLoft used to skip this,
-- so a vehicle that was lofted out of its anchors came back down with the
-- handbrake still applied and would not drive.
TIV.Deploy.ReleaseHandbrake = ReleaseHandbrake

-- ============================================================================
-- ENSURE SPIKES EXIST
-- ============================================================================
function TIV.Deploy.EnsureSpikes(veh, data)
    -- Must agree with what CreateSpikes actually builds, or this reconciler
    -- would rebuild the anchors on every call. See TIV.Spikes.ResolveCount.
    local desiredSpikeCount = (TIV.Spikes.ResolveCount and TIV.Spikes.ResolveCount(veh))
        or math.Clamp(TIV.Config.SpikeCount, TIV.Config.SpikeCountConvarMin, TIV.Config.SpikeCountConvarMax)

    if desiredSpikeCount == 0 then
        if not data.spikesCreated then
            TIV.Spikes.Create(veh, data)
            data.spikesCreated = true
        end
        return
    end

    if data.spikesCreated then
        local validCount = 0
        for _, sd in ipairs(data.spikes or {}) do
            if IsValid(sd.entity) then validCount = validCount + 1 end
        end

        if validCount > 0 and validCount ~= desiredSpikeCount and data.state == "idle" then
            print(string.format(
                "[TIV] Spike count changed (%d -> %d), rebuilding spikes...",
                validCount, desiredSpikeCount
            ))
            TIV.Anchor.DetachAll(veh, data)
            TIV.Spikes.RemoveAll(data, veh:EntIndex())
            data.spikesCreated = false
            -- fall through to create below
        elseif validCount > 0 then
            return
        else
            -- spikesCreated=true but no valid entities -- they got cleaned up
            print("[TIV] Spikes missing, recreating...")
            TIV.Anchor.DetachAll(veh, data)
            data.spikesCreated = false
        end
    end

    TIV.Spikes.Create(veh, data)
    data.spikesCreated = true

    if TIV.Wire and TIV.Wire.EnsureController then
        TIV.Wire.EnsureController(veh)
    end

    if TIV.CustomComponents and TIV.CustomComponents.EnsureArmor then
        TIV.CustomComponents.EnsureArmor(veh)
    end

    if TIV.CustomComponents and TIV.CustomComponents.ApplyVehicleBonuses then
        TIV.CustomComponents.ApplyVehicleBonuses(veh)
    end
end

-- ============================================================================
-- COOLDOWN
-- ============================================================================
local function IsOnCooldown(ply)
    local steamID = ply:SteamID()
    local last    = TIV.Deploy.Cooldowns[steamID] or 0
    if CurTime() - last < COOLDOWN_TIME then return true end
    TIV.Deploy.Cooldowns[steamID] = CurTime()
    return false
end

-- ============================================================================
-- INPUT HANDLER
-- ============================================================================
-- Is this player actually the driver of this TIV? (Not a passenger.)
local function IsDriverOf(ply, veh)
    if not IsValid(ply) or not IsValid(veh) then return false end
    -- Direct case: ply is in this vehicle's main seat.
    if veh.GetDriver then
        local driver = veh:GetDriver()
        if IsValid(driver) and driver == ply then return true end
    end
    -- The vehicle the player is in might be a child seat parented to the TIV.
    local plyVeh = ply:GetVehicle()
    if IsValid(plyVeh) then
        if plyVeh == veh then return true end
        if plyVeh:GetParent() == veh then
            -- Check if this is the driver seat (LVS/Glide convention: seat 0).
            if plyVeh.GetDriverSeat and plyVeh:GetDriverSeat() == plyVeh then
                return true
            end
            -- Fallback: if there's no driver in the main vehicle yet,
            -- treat the first-entered seat-parent occupant as the driver.
            if veh.GetDriver then
                local driver = veh:GetDriver()
                if not IsValid(driver) then return true end
            end
        end
    end
    return false
end
TIV.Deploy.IsDriverOf = IsDriverOf

function TIV.Deploy.HandleInput(ply, veh)
    if not IsValid(veh) or not IsValid(ply) then return end
    if IsOnCooldown(ply) then return end
    if not TIV.Deploy.IsJeep(veh) then return end

    -- Only the driver can deploy. Passengers pressing B is a no-op.
    if not IsDriverOf(ply, veh) then return end

    local data = TIV.Deploy.GetState(veh)
    TIV.Deploy.EnsureSpikes(veh, data)

    if data.state == "idle" then
        TIV.Deploy.StartDeploy(ply, veh)
    elseif data.state == "anchored" then
        TIV.Deploy.StartRetract(ply, veh)
    elseif data.state == "lowering" then
        TIV.Deploy.ReverseToLowering(veh, data)
    elseif data.state == "deploying_spikes" then
        TIV.Deploy.ReverseToRetracting(veh, data)
    elseif data.state == "retracting" then
        TIV.Deploy.ReverseToDeploying(veh, data)
    elseif data.state == "raising" then
        TIV.Deploy.ReverseToRaising(veh, data)
    end
end

-- ============================================================================
-- SUSPENSION LOWERING LIMIT
-- Determines the distance the chassis lowers during hydraulic deployment.
-- ============================================================================
function TIV.Deploy.GetSuspensionLimit(veh)
    local cvar = GetConVar("tiv_suspension_limit")
    if cvar then
        local override = cvar:GetFloat()
        if override > 0 then
            return override
        end
    end

    if IsValid(veh) and TIV.Config.SuspensionLimits then
        local class = string.lower(veh:GetClass() or "")
        local model = string.lower(veh:GetModel() or "")
        local limits = TIV.Config.SuspensionLimits
        if class == "prop_vehicle_jalopy" or string.find(model, "jalopy", 1, true) or string.find(model, "vehicle.mdl", 1, true) then
            return limits.jalopy or TIV.Config.LowerAmount or 10
        elseif class == "prop_vehicle_apc" or string.find(model, "apc", 1, true) then
            return limits.apc or TIV.Config.LowerAmount or 10
        elseif limits.jeep then
            return limits.jeep
        end
    end

    return TIV.Config.LowerAmount or 10
end

-- ============================================================================
-- DEPLOY
-- ============================================================================
function TIV.Deploy.StartDeploy(ply, veh)
    local data = TIV.Deploy.GetState(veh)
    local phys = veh:GetPhysicsObject()

    if IsValid(phys) and TIV.Compat and TIV.Compat.Enabled then
        local now = CurTime()
        if data.compatRecoverUntil and now < data.compatRecoverUntil then
            return
        end
        local linearSpeed  = phys:GetVelocity():Length()
        local angularSpeed = phys:GetAngleVelocity():Length()
        if linearSpeed  > TIV.Compat.MaxDeployLinearVelocity
        or angularSpeed > TIV.Compat.MaxDeployAngularVelocity then
            return
        end
    end

    local lowerLimit = TIV.Deploy.GetSuspensionLimit(veh)
    data.lowerAmount = lowerLimit

    data.state           = "lowering"
    data.originalPos     = veh:GetPos()
    data.gravityReleased = false
    TIV.Deploy.BroadcastState(veh, "lowering")

    if IsValid(phys) then
        phys:SetVelocity(Vector(0, 0, 0))
        phys:SetAngleVelocity(Vector(0, 0, 0))
        phys:EnableMotion(false)
    end

    local speedMult   = GetConVar("tiv_deploy_speed") and math.max(0.2, GetConVar("tiv_deploy_speed"):GetFloat()) or 1.0
    local lowerTime   = (TIV.Config.LowerTime or 1.0) / speedMult
    local startPos    = veh:GetPos()
    local endPos      = startPos - (veh:GetUp() * lowerLimit)
    local startTime   = CurTime()
    -- Keep EntIndex-based timer name (sessionID may be nil if EnsureSpikes
    -- hasn't built spikes yet, e.g. 0-spike mode without prior deploy).
    local timerName   = "TIV_Lower_" .. veh:EntIndex()

    timer.Create(timerName, 0.02, 0, function()
        if not IsValid(veh) then
            timer.Remove(timerName)
            return
        end

        local elapsed    = CurTime() - startTime
        local frac       = math.Clamp(elapsed / lowerTime, 0, 1)
        local smoothFrac = frac * frac * (3 - 2 * frac)

        veh:SetPos(LerpVector(smoothFrac, startPos, endPos))

        if math.random() < 0.05 then
            veh:EmitSound("physics/metal/metal_box_strain" .. math.random(1, 4) .. ".wav",
                55, math.random(70, 90))
        end

        if frac >= 1 then
            timer.Remove(timerName)
            util.ScreenShake(veh:GetPos(), 3, 5, 0.5, 200)

            local function finalizeAnchored()
                if not IsValid(veh) then return end
                data.state      = "anchored"
                data.anchored   = true
                data.plantedPos = veh:GetPos()
                if TIV.Loft and TIV.Loft.SetAnchoredImmunity then
                    TIV.Loft.SetAnchoredImmunity(veh, true)
                end
                local hbCVar = GetConVar("tiv_deploy_handbrake")
                if not (hbCVar and not hbCVar:GetBool()) then
                    ApplyHandbrake(veh)
                end
                TIV.Deploy.BroadcastState(veh, "anchored")
            end

            if TIV.Spikes.GetCount(data) == 0 then
                local p = veh:GetPhysicsObject()
                if IsValid(p) then
                    p:EnableMotion(false)
                    p:EnableGravity(true)
                end
                finalizeAnchored()
            else
                data.state = "deploying_spikes"
                TIV.Deploy.BroadcastState(veh, "deploying_spikes")
                TIV.Spikes.Deploy(veh, data, function()
                    if not IsValid(veh) then return end
                    TIV.Anchor.UnfreezeForDeploy(veh)
                    finalizeAnchored()
                end)
            end
        end
    end)
end

-- ============================================================================
-- RETRACT
-- ============================================================================
function TIV.Deploy.StartRetract(ply, veh)
    local data = TIV.Deploy.GetState(veh)
    data.state      = "retracting"
    data.plantedPos = nil
    if TIV.Loft and TIV.Loft.SetAnchoredImmunity then
        TIV.Loft.SetAnchoredImmunity(veh, false)
    end
    TIV.Deploy.BroadcastState(veh, "retracting")

    -- Release handbrake before retracting
    ReleaseHandbrake(veh)

    -- Refreeze for the raise sequence
    local phys = veh:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableGravity(true)
        phys:SetVelocity(Vector(0, 0, 0))
        phys:SetAngleVelocity(Vector(0, 0, 0))
        phys:EnableMotion(false)
    end

    TIV.Anchor.DetachAll(veh, data)
    data.anchored = false

    if TIV.Spikes.GetCount(data) == 0 then
        TIV.Deploy.RaiseVehicle(ply, veh)
    else
        timer.Simple(0.3, function()
            if not IsValid(veh) then return end
            TIV.Spikes.Retract(veh, data, function()
                if not IsValid(veh) then return end
                TIV.Deploy.RaiseVehicle(ply, veh)
            end)
        end)
    end
end

-- ============================================================================
-- RAISE VEHICLE
-- ============================================================================
function TIV.Deploy.RaiseVehicle(ply, veh)
    if not IsValid(veh) then return end

    local data       = TIV.Deploy.GetState(veh)
    data.state       = "raising"
    TIV.Deploy.BroadcastState(veh, "raising")

    local raiseDist  = data.lowerAmount or TIV.Deploy.GetSuspensionLimit(veh)
    local curPos     = veh:GetPos()
    local endPos     = (data.originalPos and data.originalPos:DistToSqr(curPos) < 100)
        and data.originalPos
        or (curPos + (veh:GetUp() * raiseDist))
    local startTime  = CurTime()
    local timerName  = "TIV_Raise_" .. veh:EntIndex()
    local speedMult  = GetConVar("tiv_deploy_speed") and math.max(0.2, GetConVar("tiv_deploy_speed"):GetFloat()) or 1.0
    local raiseTime  = 3 / speedMult

    timer.Create(timerName, 0.02, 0, function()
        if not IsValid(veh) then
            timer.Remove(timerName)
            return
        end

        local elapsed    = CurTime() - startTime
        local frac       = math.Clamp(elapsed / raiseTime, 0, 1)
        local smoothFrac = frac * frac * (3 - 2 * frac)

        veh:SetPos(LerpVector(smoothFrac, curPos, endPos))

        if frac >= 1 then
            timer.Remove(timerName)

            local p = veh:GetPhysicsObject()
            if IsValid(p) then
                p:EnableGravity(true)
                p:SetVelocity(Vector(0, 0, 0))
                p:SetAngleVelocity(Vector(0, 0, 0))
                p:EnableMotion(true)
                p:Wake()
            end

            data.state      = "idle"
            data.anchored   = false
            data.plantedPos = nil
            if TIV.Loft and TIV.Loft.SetAnchoredImmunity then
                TIV.Loft.SetAnchoredImmunity(veh, false)
            end
            TIV.Deploy.BroadcastState(veh, "idle")

            -- After idle, check whether spikes need rebuilding.
            local count = TIV.Spikes.GetCount(data)
            if count == 0
                and math.Clamp(TIV.Config.SpikeCount, 0, TIV.Config.SpikeCountConvarMax) > 0 then
                print("[TIV] Spikes lost during retract, recreating...")
                data.spikesCreated = false
                TIV.Deploy.EnsureSpikes(veh, data)
            end
        end
    end)
end

-- ============================================================================
-- MID-SEQUENCE REVERSAL HANDLERS
-- Safely reverses deploy/retract in mid-stroke without state or entity corruption.
-- ============================================================================
function TIV.Deploy.ReverseToLowering(veh, data)
    if not IsValid(veh) or not data then return end
    local timerName = "TIV_Lower_" .. veh:EntIndex()
    timer.Remove(timerName)
    TIV.Deploy.RaiseVehicle(nil, veh)
end

function TIV.Deploy.ReverseToRetracting(veh, data)
    if not IsValid(veh) or not data then return end
    data.state = "retracting"
    TIV.Deploy.BroadcastState(veh, "retracting")
    ReleaseHandbrake(veh)

    TIV.Spikes.InterruptAndRetract(veh, data, function()
        if not IsValid(veh) then return end
        TIV.Deploy.RaiseVehicle(nil, veh)
    end)
end

function TIV.Deploy.ReverseToDeploying(veh, data)
    if not IsValid(veh) or not data then return end
    data.state = "deploying_spikes"
    TIV.Deploy.BroadcastState(veh, "deploying_spikes")

    local function finalizeAnchored()
        if not IsValid(veh) then return end
        data.state    = "anchored"
        data.anchored = true
        TIV.Anchor.UnfreezeForDeploy(veh)
        local hbCVar = GetConVar("tiv_deploy_handbrake")
        if not (hbCVar and not hbCVar:GetBool()) then
            ApplyHandbrake(veh)
        end
        TIV.Deploy.BroadcastState(veh, "anchored")
    end

    TIV.Spikes.InterruptAndDeploy(veh, data, function()
        finalizeAnchored()
    end)
end

function TIV.Deploy.ReverseToRaising(veh, data)
    if not IsValid(veh) or not data then return end
    local timerName = "TIV_Raise_" .. veh:EntIndex()
    timer.Remove(timerName)
    TIV.Deploy.StartDeploy(nil, veh)
end

-- ============================================================================
-- AUTO CREATE SPIKES ON ENTER
-- Restored the original "try the passed seat first" pattern. ply:GetVehicle()
-- isn't reliably populated inside PlayerEnteredVehicle.
-- ============================================================================
hook.Add("PlayerEnteredVehicle", "TIV_FirstEnter", function(ply, veh)
    local tivVeh = veh
    if not TIV.Deploy.IsJeep(tivVeh) then
        local parent = IsValid(veh) and veh:GetParent() or nil
        if IsValid(parent) and TIV.Deploy.IsJeep(parent) then
            tivVeh = parent
        else
            tivVeh = TIV.Deploy.ResolveVehicle(ply)
        end
    end
    if not IsValid(tivVeh) then return end
    local data = TIV.Deploy.GetState(tivVeh)
    TIV.Deploy.EnsureSpikes(tivVeh, data)
end)

-- ============================================================================
-- INPUT
-- Both paths exist: server-side PlayerButtonDown (works on dedicated and
-- listen servers, independent of client) AND TIV_DeployRequest net message
-- (works when client-side hooks beat server's button polling).
-- The cooldown in HandleInput deduplicates double-fire.
-- ============================================================================
hook.Add("PlayerButtonDown", "TIV_DeployBind", function(ply, button)
    if not TIV.Config then return end
    if button ~= TIV.Config.DeployKey then return end
    local veh = TIV.Deploy.ResolveVehicle(ply)
    if not IsValid(veh) then return end
    TIV.Deploy.HandleInput(ply, veh)
end)

net.Receive("TIV_DeployRequest", function(len, ply)
    local veh = TIV.Deploy.ResolveVehicle(ply)
    if not IsValid(veh) then return end
    TIV.Deploy.HandleInput(ply, veh)
end)

-- ============================================================================
-- CLEANUP ON VEHICLE REMOVE
-- ============================================================================
hook.Add("EntityRemoved", "TIV_VehicleCleanup", function(ent)
    if not IsValid(ent) then return end
    local entIdx = ent:EntIndex()
    local data   = TIV.Deploy.Vehicles[entIdx]
    if not data then return end

    if ent.SetHandbrake then ReleaseHandbrake(ent) end
    TIV.Anchor.DetachAll(ent, data)
    TIV.Spikes.RemoveAll(data, entIdx)
    TIV.Deploy.Vehicles[entIdx] = nil

    if TIV.Wire and TIV.Wire.OnVehicleRemoved then
        TIV.Wire.OnVehicleRemoved(ent)
    end
    if TIV.CustomComponents and TIV.CustomComponents.RemoveArmorProps then
        TIV.CustomComponents.RemoveArmorProps(ent)
    end
    hook.Run("TIV_VehicleRemoved", ent)
end)

print("[TIV] Deploy system loaded")
