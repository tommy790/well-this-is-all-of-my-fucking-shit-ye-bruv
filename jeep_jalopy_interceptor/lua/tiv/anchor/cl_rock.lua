-- ============================================================================
-- TIV VISUAL ROCKING (client)
-- ============================================================================
-- Tilts the visible model of an anchored TIV as its anchors load up, using a
-- RENDER OVERRIDE ONLY.
--
-- Why it cannot freeze the vehicle:
--
--   * It calls Entity:SetRenderAngles and nothing else. No SetPos, no SetAngles,
--     no EnableMotion, no EnableGravity, no constraint. The physics body keeps
--     sole responsibility for position, rotation, gravity and lofting.
--   * SetRenderAngles is client-only and purely cosmetic; the server never hears
--     about it, so it cannot affect simulation, anchoring or the intercept.
--
-- Two traps this file is written around, both documented on the wiki:
--
--   * "Entity:GetAngles() will return the value set by SetRenderAngles until the
--     override is disabled." Reading veh:GetAngles() here would therefore feed
--     last frame's tilt back in and the offset would compound every frame. Every
--     transform below is read from the PHYSICS OBJECT instead, which the render
--     override does not touch. The tilt is recomputed from scratch each frame as
--     (physics angles + a bounded offset), so it cannot accumulate.
--   * SetRenderOrigin shadows GetPos() the same way, and the radar blip reads
--     veh:GetPos(). The shift below is therefore read from phys:GetPos() and
--     capped at MAX_SHIFT (a couple of Source units), which against the radar's
--     16200-unit full scale is a fraction of a pixel -- rock_visual_probe.lua
--     measures that rather than assuming it. tiv_visual_rock_shift 0 turns the
--     origin override off entirely and leaves only the tilt.
--
-- The override is cleared with nil as soon as the tilt settles, so GetAngles()
-- goes back to reporting the real transform and no other client code can see a
-- phantom angle.
-- ============================================================================

TIV.Rock = TIV.Rock or {}

-- Per-vehicle visual state, keyed by EntIndex.
local rocks = {}

-- Hard bounds on the visual tilt, in degrees, at scale 1. The tilt is a lean of
-- a few degrees, not a tip-over: the real thing is the loft system's job.
local MAX_PITCH = 3.4
local MAX_ROLL = 2.6
-- Body shift in Source units. Deliberately tiny: it is a shudder against the
-- anchors, not a displacement, and it has to stay far below anything that could
-- read as the model detaching from its collision.
local MAX_SHIFT = 2.5

local ATTACK_RATE = 7.0  -- per second, tilting into a gust
local RELAX_RATE = 3.5   -- per second, settling back to level
local SETTLE_EPS = 0.02  -- degrees, below this the override is dropped entirely
local STALE_AFTER = 1.0  -- seconds without a packet before the target goes to zero

CreateClientConVar("tiv_visual_rock", "1", true, false,
    "TIV: visually rock the anchored vehicle's model as its anchors load up (render only, never physics).")
CreateClientConVar("tiv_visual_rock_scale", "1", true, false,
    "TIV: multiplier on the visual rocking amplitude.")
CreateClientConVar("tiv_visual_rock_shift", "1", true, false,
    "TIV: also shift the model a couple of units downwind while rocking (render only).")
CreateClientConVar("tiv_visual_rock_debug", "0", true, false,
    "TIV: print the rocking offsets being applied, for checking the direction mapping in game.")

local function RockEnabled()
    local cv = GetConVar("tiv_visual_rock")
    return not cv or cv:GetBool()
end

-- ----------------------------------------------------------------------------
-- CLEARING
-- ----------------------------------------------------------------------------
local function ClearVehicle(veh)
    -- Passing nil is what actually disables an override; anything else leaves it
    -- shadowing GetAngles()/GetPos() forever.
    if not IsValid(veh) then return end
    if veh.SetRenderAngles then veh:SetRenderAngles(nil) end
    if veh.SetRenderOrigin then veh:SetRenderOrigin(nil) end
end

function TIV.Rock.ClearAll()
    for idx, st in pairs(rocks) do
        ClearVehicle(st.ent)
        rocks[idx] = nil
    end
end

-- ----------------------------------------------------------------------------
-- NETWORKING
-- ----------------------------------------------------------------------------
net.Receive("TIV_RockData", function()
    local count = net.ReadUInt(8)
    for _ = 1, count do
        local idx      = net.ReadUInt(13)
        local stress   = net.ReadUInt(8) / 255
        local pitchN   = net.ReadInt(8) / 100
        local rollN    = net.ReadInt(8) / 100
        local deployed = net.ReadUInt(6)
        local failed   = net.ReadUInt(6)
        local windX    = net.ReadInt(8) / 100
        local windY    = net.ReadInt(8) / 100

        local veh = Entity(idx)
        if IsValid(veh) then
            local st = rocks[idx]
            if not st then
                st = { ent = veh, pitch = 0, roll = 0, sx = 0, sy = 0, sz = 0 }
                rocks[idx] = st
            elseif st.ent ~= veh then
                -- EntIndex got reused by a different entity. Drop the old one's
                -- override so it is not left tilted, and start fresh.
                ClearVehicle(st.ent)
                st.ent, st.pitch, st.roll = veh, 0, 0
                st.sx, st.sy, st.sz = 0, 0, 0
            end
            st.stress, st.pitchN, st.rollN = stress, pitchN, rollN
            st.deployed, st.failed = deployed, failed
            st.windX, st.windY = windX, windY
            st.lastUpdate = CurTime()
        end
    end
end)

-- ----------------------------------------------------------------------------
-- TARGET TILT
--
-- Pure function of the latest packet plus the clock. It never reads its own
-- previous output, which is what keeps the offset from drifting.
-- ----------------------------------------------------------------------------
local function TargetTilt(st, now)
    local stress = st.stress or 0
    if stress <= 0 then return 0, 0 end

    local scale = 1
    local cv = GetConVar("tiv_visual_rock_scale")
    if cv then scale = math.Clamp(cv:GetFloat(), 0, 3) end

    -- Subtle at first, more noticeable as the anchors load. Smoothstep keeps the
    -- low end gentle instead of lurching the moment the wind picks up.
    local s = math.Clamp(stress, 0, 1)
    local curve = s * s * (3 - 2 * s)

    -- Fewer surviving anchors means the ones left are carrying more of the load,
    -- and the body moves more for the same wind.
    local total = (st.deployed or 0) + (st.failed or 0)
    local anchorFactor = 1
    if total > 0 then anchorFactor = 1 + 0.85 * ((st.failed or 0) / total) end

    local mag = math.Clamp(curve * anchorFactor * scale, 0, 2)

    local pitch = MAX_PITCH * (st.pitchN or 0) * mag
    local roll = MAX_ROLL * (st.rollN or 0) * mag

    -- A little gust wobble on top of the lean, so it reads as a body straining in
    -- turbulent air rather than a static tilt. Bounded, and derived from the clock
    -- rather than accumulated.
    local wobble = 0.3 * mag * s
    if wobble > 0.001 then
        local t = now * (2.2 + 3.4 * s)
        pitch = pitch + math.sin(t) * MAX_PITCH * wobble
        roll = roll + math.sin(t * 0.79 + 1.1) * MAX_ROLL * wobble
    end

    return math.Clamp(pitch, -MAX_PITCH * 2, MAX_PITCH * 2),
           math.Clamp(roll, -MAX_ROLL * 2, MAX_ROLL * 2),
           mag
end

-- ----------------------------------------------------------------------------
-- TARGET SHIFT, in VEHICLE LOCAL units (+x forward, +y left, +z up)
--
-- The body is dragged a little way downwind and squats into whatever anchors are
-- still holding. windX/windY are the local components of the direction the wind
-- arrives FROM, so downwind is their negation. Sending them separately rather
-- than reusing pitchN/rollN matters: the pivot term is already folded into those,
-- and a shift derived from them would slide the body toward wherever the anchors
-- happen to be missing.
-- ----------------------------------------------------------------------------
local function TargetShift(st, mag)
    if mag <= 0 then return 0, 0, 0 end
    return -(st.windX or 0) * MAX_SHIFT * mag,
           -(st.windY or 0) * MAX_SHIFT * mag,
           -MAX_SHIFT * 0.35 * mag
end

-- ----------------------------------------------------------------------------
-- APPLY
-- ----------------------------------------------------------------------------
local nextDebug = 0

hook.Add("Think", "TIV_RockApply", function()
    if not RockEnabled() then
        if next(rocks) then TIV.Rock.ClearAll() end
        return
    end

    local now = CurTime()
    local dt = math.Clamp(FrameTime(), 0, 0.25)
    local debugOn = false
    local dbgCv = GetConVar("tiv_visual_rock_debug")
    if dbgCv then debugOn = dbgCv:GetBool() end
    local shiftOn = true
    local shCv = GetConVar("tiv_visual_rock_shift")
    if shCv then shiftOn = shCv:GetBool() end

    for idx, st in pairs(rocks) do
        local veh = Entity(idx)
        local phys = IsValid(veh) and veh:GetPhysicsObject() or nil

        if not IsValid(veh) or veh ~= st.ent then
            -- Gone, or the EntIndex was reused by another entity.
            rocks[idx] = nil
        elseif not IsValid(phys) then
            ClearVehicle(veh)
            rocks[idx] = nil
        else
            -- Go quiet if the server has stopped reporting this vehicle: it lofted,
            -- retracted, or the tornado ended. Relax rather than snap.
            local stale = (st.lastUpdate or 0) < (now - STALE_AFTER)
            local tPitch, tRoll, mag = 0, 0, 0
            local tSX, tSY, tSZ = 0, 0, 0
            if not stale then
                tPitch, tRoll, mag = TargetTilt(st, now)
                if shiftOn then tSX, tSY, tSZ = TargetShift(st, mag or 0) end
            end

            local rate = (math.abs(tPitch) > math.abs(st.pitch) or math.abs(tRoll) > math.abs(st.roll))
                and ATTACK_RATE or RELAX_RATE
            local k = 1 - math.exp(-rate * dt)
            st.pitch = st.pitch + (tPitch - st.pitch) * k
            st.roll = st.roll + (tRoll - st.roll) * k
            st.sx = st.sx + (tSX - st.sx) * k
            st.sy = st.sy + (tSY - st.sy) * k
            st.sz = st.sz + (tSZ - st.sz) * k

            local settled = math.abs(st.pitch) < SETTLE_EPS and math.abs(st.roll) < SETTLE_EPS
                and math.abs(st.sx) < SETTLE_EPS and math.abs(st.sy) < SETTLE_EPS
                and math.abs(st.sz) < SETTLE_EPS

            if settled then
                -- Settled: hand GetAngles()/GetPos() back to the real transform and
                -- stop tracking this vehicle entirely.
                ClearVehicle(veh)
                rocks[idx] = nil
            else
                -- The physics object is the true transform and is immune to both
                -- render overrides, so adding a bounded offset to it cannot
                -- compound -- which is the whole reason nothing here reads
                -- veh:GetAngles() or veh:GetPos().
                local pa = phys:GetAngles()
                veh:SetRenderAngles(Angle(pa.p + st.pitch, pa.y, pa.r + st.roll))

                if shiftOn and veh.SetRenderOrigin and
                   (math.abs(st.sx) > SETTLE_EPS or math.abs(st.sy) > SETTLE_EPS or math.abs(st.sz) > SETTLE_EPS) then
                    -- Vehicle local to world. +y is LEFT and Angle:Right() is
                    -- local -Y, so the local left component maps onto -Right.
                    local fwd, rgt, up = pa:Forward(), pa:Right(), pa:Up()
                    local pp = phys:GetPos()
                    veh:SetRenderOrigin(Vector(
                        pp.x + fwd.x * st.sx - rgt.x * st.sy + up.x * st.sz,
                        pp.y + fwd.y * st.sx - rgt.y * st.sy + up.y * st.sz,
                        pp.z + fwd.z * st.sx - rgt.z * st.sy + up.z * st.sz))
                end

                if debugOn and now >= nextDebug then
                    print(string.format(
                        "[TIV rock] #%d stress=%.2f pitch=%+.2f roll=%+.2f shift=(%+.2f,%+.2f,%+.2f) live=%d failed=%d physAng=%.1f/%.1f/%.1f",
                        idx, st.stress or 0, st.pitch, st.roll, st.sx, st.sy, st.sz,
                        st.deployed or 0, st.failed or 0, pa.p, pa.y, pa.r))
                end
            end
        end
    end

    if debugOn then nextDebug = now + 0.25 end
end)

-- ----------------------------------------------------------------------------
-- CLEANUP
-- ----------------------------------------------------------------------------
hook.Add("EntityRemoved", "TIV_RockCleanup", function(ent)
    if not IsValid(ent) then return end
    local idx = ent:EntIndex()
    local st = rocks[idx]
    if st then
        ClearVehicle(st.ent)
        rocks[idx] = nil
    end
end)

hook.Add("Shutdown", "TIV_RockShutdown", function()
    TIV.Rock.ClearAll()
end)

print("[TIV] Visual rocking client loaded")
