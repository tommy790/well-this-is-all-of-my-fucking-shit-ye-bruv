-- ============================================================================
-- TIV ANCHOR LOAD MODEL (server)
-- ============================================================================
-- Feeds the CLIENT-SIDE visual rocking in tiv/anchor/cl_rock.lua.
--
-- This module is deliberately read-only with respect to the vehicle. It computes
-- how hard the wind is pulling on the deployed anchors and broadcasts a few
-- numbers; it never touches the physics body, never adds a constraint, and never
-- moves the entity. The existing deploy/anchor/loft systems remain the only
-- things that decide where the vehicle actually is.
--
-- One thing this does NOT do is send per-frame data: the broadcast is throttled
-- to SEND_INTERVAL and skipped entirely when nothing is anchored.
-- ============================================================================

TIV.Rock = TIV.Rock or {}

util.AddNetworkString("TIV_RockData")

local SEND_INTERVAL = 0.1

-- Vehicles reported in the previous broadcast, so a vehicle that stops being
-- anchored can be sent one final zeroed record and let its clients relax.
TIV.Rock.LastSent = TIV.Rock.LastSent or {}

-- ----------------------------------------------------------------------------
-- Local-space mount position of one spike.
-- sd.localPos / sd.offset are what sv_spikes.lua stores; the WorldToLocal
-- fallback matches what sv_loft.lua already does for its own exposure sort.
-- ----------------------------------------------------------------------------
local function SpikeLocalPos(veh, sd)
    local lp = sd.localPos or sd.offset
    if lp and lp.x then return lp end
    if IsValid(sd.entity) then
        return veh:WorldToLocal(sd.entity:GetPos())
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- ANCHOR LOAD
--
-- Returns:
--   stress    0..1, straight from TIV.Loft.CalculateStress so the visual and the
--             existing stress sounds/HUD bar can never disagree
--   pitchN    -1..1, signed pitch weight (+ = nose up)
--   rollN     -1..1, signed roll weight (+ = right side down)
--   deployed  live deployed anchors
--   failed    anchors already sheared off
--
-- Two contributions, both normalised to -1..1 and both bounded:
--
--   WIND  -- the windward end is the one being peeled up, so the vehicle pitches
--            and rolls away from where the wind is coming from. This is what
--            produces "front anchors under load -> front end lifts".
--
--   PIVOT -- as anchors shear off, the vehicle is left holding on whatever is
--            still in the ground, and it rotates about those. Averaging the
--            surviving mounts gives that pivot point: lose the front anchors and
--            the nose goes up, lose the left ones and the left side flies.
--
-- Neither term is integrated over time, so nothing here can drift.
-- ----------------------------------------------------------------------------
function TIV.Rock.ComputeLoad(veh, data)
    if not IsValid(veh) then return 0, 0, 0, 0, 0, 0, 0 end

    local windMPH = TIV.Wind and TIV.Wind.GetSpeed and TIV.Wind.GetSpeed(veh) or 0
    local stress = (TIV.Loft and TIV.Loft.CalculateStress) and TIV.Loft.CalculateStress(windMPH, veh) or 0

    -- LOFTING STATE, as the spec asks for. The loft system already tracks when it
    -- has committed to shearing this vehicle's anchors (FailingGroups) and when
    -- the body has been let off its gravity hold (gravityReleased). Both mean the
    -- anchors are actively letting go regardless of what the wind is doing right
    -- now, so the body should be straining even if a gust momentarily dropped.
    local entIndex = veh:EntIndex()
    local shearing = (TIV.Loft.FailingGroups and TIV.Loft.FailingGroups[entIndex] ~= nil)
        or data.gravityReleased == true
    if shearing then
        stress = math.Clamp(stress + 0.35, 0, 1)
    end

    local deployed, failed = 0, 0
    local holdX, holdY, holdN = 0, 0, 0

    for _, sd in ipairs(data.spikes or {}) do
        if sd.phase == "deployed" then
            if sd.failed then
                failed = failed + 1
            elseif IsValid(sd.entity) then
                deployed = deployed + 1
                local lp = SpikeLocalPos(veh, sd)
                if lp then
                    holdX = holdX + lp.x
                    holdY = holdY + lp.y
                    holdN = holdN + 1
                end
            end
        end
    end

    -- Nothing to show: no measurable wind AND no failure sequence under way.
    if stress <= 0 then return 0, 0, 0, deployed, failed, 0, 0 end

    -- Vehicle-local direction the wind is arriving FROM. GetDirection returns the
    -- direction the wind pushes toward (that is how GetForceVector uses it), so
    -- the windward side is its negation. +x is forward and +y is LEFT, because
    -- Angle:Right() is local -Y.
    local windFromX, windFromY = 0, 0
    local dir = TIV.Wind and TIV.Wind.GetDirection and TIV.Wind.GetDirection(veh)
    if dir and (dir.x ~= 0 or dir.y ~= 0 or dir.z ~= 0) then
        local local0 = veh:WorldToLocal(veh:GetPos() - dir:GetNormalized())
        local len = math.sqrt(local0.x * local0.x + local0.y * local0.y)
        if len > 0.0001 then
            windFromX, windFromY = local0.x / len, local0.y / len
        end
    end

    -- Pivot point of the anchors still in the ground, averaged and clamped to a
    -- sane fraction of the wheelbase so a single surviving corner mount cannot
    -- throw the model over.
    local pivotX, pivotY = 0, 0
    if holdN > 0 then
        pivotX = math.Clamp(holdX / holdN / 90, -1, 1)
        pivotY = math.Clamp(holdY / holdN / 60, -1, 1)
    end

    -- While anchors are actively shearing the body is pivoting on whatever is
    -- left, so the pivot term carries more weight than it does in steady wind.
    local PIVOT_WEIGHT = shearing and 1.0 or 0.6

    -- Sign conventions, measured against the Source basis rather than assumed:
    --   +pitch lifts the NOSE (Angle(90,0,0):Up() == +X)
    --   +roll drops the RIGHT side (Angle(0,0,90):Right() == -Z)
    -- and in vehicle local space +x is forward while +y is LEFT, because
    -- Angle:Right() is local -Y.
    --
    -- WIND term, exactly as specified: wind arriving from the front lifts the
    -- front end; wind arriving from the left rolls the body toward the left, i.e.
    -- left side down, i.e. NEGATIVE roll. Note the two axes are deliberately not
    -- the same gesture -- one lifts into the wind, the other leans with it. If
    -- that reads wrong in game it is the sign of windFromY below that flips it.
    --
    -- PIVOT term is the opposite gesture on both axes, because it is a different
    -- physical event: an anchor that has sheared off is no longer holding that
    -- corner down, so the corner flies up. Lose the front anchors and the nose
    -- rises (pivotX < 0, so -pivotX is positive); lose the left ones and the left
    -- side rises, which is POSITIVE roll.
    local pitchN = math.Clamp(windFromX - pivotX * PIVOT_WEIGHT, -1, 1)
    local rollN = math.Clamp(-windFromY - pivotY * PIVOT_WEIGHT, -1, 1)

    -- windFromX/Y go out alongside the tilt so the client can place the small
    -- body shift downwind without re-deriving the vehicle's basis from the tilt,
    -- which the pivot term has already polluted.
    return stress, pitchN, rollN, deployed, failed, windFromX, windFromY
end

-- ----------------------------------------------------------------------------
-- BROADCAST
-- ----------------------------------------------------------------------------
local function SendRecords(records)
    net.Start("TIV_RockData")
    net.WriteUInt(#records, 8)
    for _, r in ipairs(records) do
        net.WriteUInt(r.idx, 13)
        net.WriteUInt(math.Clamp(math.Round(r.stress * 255), 0, 255), 8)
        -- Signed byte at 1/100th resolution: plenty for a 3 degree lean, and it
        -- keeps a full packet to a handful of bytes per vehicle.
        net.WriteInt(math.Clamp(math.Round(r.pitchN * 100), -100, 100), 8)
        net.WriteInt(math.Clamp(math.Round(r.rollN * 100), -100, 100), 8)
        net.WriteUInt(math.Clamp(r.deployed, 0, 63), 6)
        net.WriteUInt(math.Clamp(r.failed, 0, 63), 6)
        -- Local wind-from components, for the body shift. Eight bytes per vehicle
        -- in total, at 10 Hz, and the whole message is skipped when nothing is
        -- anchored.
        net.WriteInt(math.Clamp(math.Round((r.windX or 0) * 100), -100, 100), 8)
        net.WriteInt(math.Clamp(math.Round((r.windY or 0) * 100), -100, 100), 8)
    end
    net.Broadcast()
end

timer.Create("TIV_RockBroadcast", SEND_INTERVAL, 0, function()
    local records = {}
    local seen = {}

    for entIndex, data in pairs(TIV.Deploy.Vehicles or {}) do
        local veh = Entity(entIndex)
        if IsValid(veh) and data.state == "anchored" then
            local stress, pitchN, rollN, deployed, failed, windX, windY = TIV.Rock.ComputeLoad(veh, data)
            seen[entIndex] = true
            records[#records + 1] = {
                idx = entIndex, stress = stress, pitchN = pitchN, rollN = rollN,
                deployed = deployed, failed = failed, windX = windX, windY = windY,
            }
        end
    end

    -- Anything reported last time but no longer anchored gets one zeroed record so
    -- its clients relax the model instead of waiting for the stale timeout.
    for entIndex in pairs(TIV.Rock.LastSent) do
        if not seen[entIndex] then
            records[#records + 1] = {
                idx = entIndex, stress = 0, pitchN = 0, rollN = 0, deployed = 0, failed = 0,
                windX = 0, windY = 0,
            }
        end
    end

    TIV.Rock.LastSent = seen

    if #records > 0 then SendRecords(records) end
end)

print("[TIV] Anchor load model loaded")
