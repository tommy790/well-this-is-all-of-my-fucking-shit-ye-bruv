--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : particle spawning (client-side)

    All particle systems are created through this module so that:
      * every particle name is precached exactly once (positive AND negative
        results are cached — a missing PCF is never retried every shot),
      * entity-attached particles ALWAYS use PATTACH_POINT_FOLLOW when an
        attachment is available (the caller passes a validated attachment id),
      * world-position spawning is only used for effects that are genuinely
        world-space (tracer beams, explosions, splashes) or as a last-resort
        fallback when no attachment could be resolved,
      * particle creation failures are logged once, not spammed.

    Handles are returned where possible so callers can stop emission; if the
    engine API used can not return a handle (ParticleEffectAttach), `true` is
    returned to signal success.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config
local Debug = LVS_GRED_FX.Debug
local DebugOnce = LVS_GRED_FX.DebugOnce

local PRECACHED = {} -- name → true / false

local PWO = PATTACH_WORLDORIGIN
local PPF = PATTACH_POINT_FOLLOW

-- Returns true when the particle system name exists and has been precached.
--
-- PrecacheParticleSystem returns nil on success on the GMod client and an
-- explicit `false` for a missing system. pcall only tells us the call didn't
-- error; the RESULT decides existence. Treat "no error + result ~= false" as
-- success, and negative-cache explicit `false` so missing systems (e.g. vj
-- smoke without VJ Base) are not retried every shot.
function LVS_GRED_FX.Preload(name)
    if not isstring(name) or name == "" then return false end
    local cached = PRECACHED[name]
    if cached ~= nil then return cached end

    local ok, res = pcall(PrecacheParticleSystem, name)
    PRECACHED[name] = ok == true and res ~= false

    if not PRECACHED[name] then
        DebugOnce("badpcf:" .. name, "particle system not found:", name)
    end

    return PRECACHED[name]
end

local function worldHost()
    local w = game.GetWorld()
    if IsValid(w) then return w end
    local z = Entity(0)
    if IsValid(z) then return z end
    return nil
end

-- CNewParticleEffect handles are not entities: the global IsValid() returns
-- false for them, so every module validates through this helper.
function LVS_GRED_FX.PsysValid(psys)
    if not psys or psys == true then return false end
    if psys.IsValid then
        local ok, valid = pcall(psys.IsValid, psys)
        return ok and valid == true
    end
    return false
end

local function SafeStop(psys, clear)
    if not psys or not psys.StopEmission then return end
    pcall(function() psys:StopEmission(false, clear == true) end)
end

-- Schedule StopEmission on a particle system after `delay` seconds.
function LVS_GRED_FX.StopAfter(psys, delay, clear)
    if not psys then return end
    timer.Simple(delay, function()
        SafeStop(psys, clear)
    end)
end

local function applyAngle(psys, ang)
    if not psys or not isangle(ang) then return end
    pcall(function()
        psys:SetControlPointOrientation(0, ang:Forward(), ang:Right(), ang:Up())
    end)
end

--[[---------------------------------------------------------------------------
    SpawnAttached — the PATTACH_POINT_FOLLOW workhorse.

    Spawns `name` on `ent` at attachment `attID`, following the attachment as
    the weapon moves / rotates / recoils / traverses.

    opts:
      life        → auto StopEmission after this many seconds
      clear       → clear existing particles on stop (flashes) or let fade (smoke)
      ang         → angle used for roll correction
      roll        → roll offset in degrees (per-model PCF fixes)
      forceHandle → only use CreateParticleSystem; return nil instead of
                    falling back to handle-less ParticleEffectAttach (used by
                    systems that must track/stop the system, e.g. barrel smoke)

    Returns: psys handle, `true` (spawned via ParticleEffectAttach), or nil.
-----------------------------------------------------------------------------]]
-- Offset followers. A particle whose control point 0 is driven every frame
-- to (attachment transform) x (local offset): used when the weapon's code
-- fires from a point that is not itself an attachment (a barrel offset
-- from a shared "aim" point). PATTACH_POINT_FOLLOW cannot carry an offset,
-- and a parented clientside proxy entity is not re-evaluated when the
-- attachment's bone moves, so the point is computed here from the live
-- attachment each frame, exactly as the vehicle's own bones move it.
local FOLLOWERS = {}
local FOLLOW_GRACE = 5

local function followerPose(f)
    local ent = f.ent
    if not IsValid(ent) then return nil end
    if ent.SetupBones then ent:SetupBones() end
    local a = ent:GetAttachment(f.att)
    if not a or not isvector(a.Pos) then return nil end
    return LocalToWorld(f.offset, f.offsetAng, a.Pos, a.Ang)
end

hook.Add("Think", "lvs_gred_fx_followers", function()
    local now = CurTime()
    for i = #FOLLOWERS, 1, -1 do
        local f = FOLLOWERS[i]
        local alive = now < f.until_ and LVS_GRED_FX.PsysValid(f.psys) and not f.psys:IsFinished()
        local pos, ang
        if alive then pos, ang = followerPose(f) end
        if not pos then
            if LVS_GRED_FX.PsysValid(f.psys) then pcall(f.psys.StopEmission, f.psys, false, true) end
            table.remove(FOLLOWERS, i)
        else
            f.psys:SetControlPoint(0, pos)
            if f.roll then ang:RotateAroundAxis(ang:Forward(), f.roll) end
            f.psys:SetControlPointOrientation(0, ang:Forward(), ang:Right(), ang:Up())
        end
    end
end)

local function spawnFollower(name, ent, attID, opts)
    local f = {
        ent = ent, att = attID,
        offset = opts.offset,
        offsetAng = isangle(opts.offsetAng) and opts.offsetAng or angle_zero,
        roll = opts.roll,
        until_ = CurTime() + (opts.life or 1) + FOLLOW_GRACE,
    }
    local pos, ang = followerPose(f)
    if not pos then return nil end
    local ok, psys = pcall(CreateParticleSystem, ent, name, PATTACH_CUSTOMORIGIN, 0, pos)
    if not ok or not LVS_GRED_FX.PsysValid(psys) then return nil end
    f.psys = psys
    psys:SetControlPoint(0, pos)
    if f.roll then ang:RotateAroundAxis(ang:Forward(), f.roll) end
    psys:SetControlPointOrientation(0, ang:Forward(), ang:Right(), ang:Up())
    FOLLOWERS[#FOLLOWERS + 1] = f
    if opts.life then LVS_GRED_FX.StopAfter(psys, opts.life, opts.clear) end
    if cfg.DebugEnabled() then
        Debug("attachment + code offset:", name, "ent:", ent:GetClass(), "att:", attID,
            "name:", LVS_GRED_FX.AttachmentName(ent, attID), "offset:", tostring(opts.offset))
    end
    return psys
end

function LVS_GRED_FX.SpawnAttached(name, ent, attID, opts)
    if not cfg.Enabled() or not isstring(name) then return nil end
    if not IsValid(ent) or not attID or attID <= 0 then return nil end
    if not LVS_GRED_FX.Preload(name) then return nil end
    if not ent.GetAttachment then return nil end
    if not ent:GetAttachment(attID) then return nil end

    opts = opts or {}

    if isvector(opts.offset) then
        local psys = spawnFollower(name, ent, attID, opts)
        if psys then return psys end
        -- Could not drive the point: attach to the attachment itself below.
    end

    local ok, psys = pcall(CreateParticleSystem, ent, name, PPF, attID, vector_origin)

    -- The particle system handle is not an entity; validate it directly (see
    -- SpawnWorld for details).
    if ok and psys ~= nil and (not psys.IsValid or psys:IsValid()) then
        if opts.roll and isangle(opts.ang) then
            local fixed = Angle(opts.ang.p, opts.ang.y, opts.ang.r)
            fixed:RotateAroundAxis(fixed:Forward(), opts.roll)
            applyAngle(psys, fixed)
        elseif isangle(opts.ang) then
            applyAngle(psys, opts.ang)
        end

        if opts.life then
            LVS_GRED_FX.StopAfter(psys, opts.life, opts.clear)
        end

        if cfg.DebugEnabled() then
            Debug("PATTACH_POINT_FOLLOW:", name, "ent:", ent:GetClass(),
                "att:", attID, "name:", LVS_GRED_FX.AttachmentName(ent, attID))
        end

        return psys
    end

    -- CreateParticleSystem unavailable/failed for this system: still attach with
    -- ParticleEffectAttach (also PATTACH_POINT_FOLLOW) unless the caller needs
    -- a handle.
    if opts.forceHandle then
        Debug("attached particle create failed (no handle path):", name)
        return nil
    end

    local okAttach = pcall(ParticleEffectAttach, name, PPF, ent, attID)

    if okAttach then
        return true
    end

    DebugOnce("spawnfail:" .. name, "particle attach failed:", name)
    return nil
end

--[[---------------------------------------------------------------------------
    SpawnWorld — world-position particle.

    Used for effects that are inherently world-space (explosions, splashes,
    tracer beams) and as the documented fallback when a muzzle effect has no
    usable attachment. Returns the psys handle or nil.
-----------------------------------------------------------------------------]]
function LVS_GRED_FX.SpawnWorld(name, pos, ang, life, clear)
    if not cfg.Enabled() or not isstring(name) then return nil end
    if not isvector(pos) then return nil end
    if not LVS_GRED_FX.Preload(name) then return nil end

    local host = worldHost()
    if not host then return nil end

    local ok, psys = pcall(CreateParticleSystem, host, name, PWO, 0, pos)

    -- IMPORTANT: the particle system handle is NOT an entity — the global
    -- IsValid() (which checks IsEntity) returns false for it. Validate the
    -- handle directly, and only consult the psys:IsValid() method when it
    -- exists (gred's own effects do exactly this).
    if not ok or psys == nil then
        DebugOnce("worldspawnfail:" .. name, "world particle create failed:", name)
        return nil
    end
    if psys.IsValid and not psys:IsValid() then
        DebugOnce("worldspawnfail:" .. name, "world particle system invalid:", name)
        return nil
    end

    if isangle(ang) then
        applyAngle(psys, ang)
    end

    if life then
        LVS_GRED_FX.StopAfter(psys, life, clear)
    end

    return psys
end

-- One-shot world particle that needs no handle (pure trigger).
function LVS_GRED_FX.SpawnWorldOneShot(name, pos, ang)
    if not cfg.Enabled() or not isstring(name) then return false end
    if not isvector(pos) then return false end
    if not LVS_GRED_FX.Preload(name) then return false end

    local ok = pcall(ParticleEffect, name, pos, isangle(ang) and ang or angle_zero, nil)
    return ok == true
end
