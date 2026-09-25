--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : tracer system (client-side)

    Gredwitch's tracer PCF particles, flying LVS's ballistics.

    gred's gred_tracers_<color>_<caliber> (gred_particles.pcf) cannot be
    steered once emitted: "move particles between 2 control points" fixes
    its speed at emission and sets its lifetime to the distance to CP1, and
    its Movement Basic has no gravity. So this addon ships
    particles/lvs_gred_tracers.pcf, generated from gred's file by
    tools/pcf_tool.py: every gred tracer definition copied byte for byte
    (renderer, sprite trail, colours, sheet sequences, smoke and glow
    children) with exactly three edits:

      * the move-between-points initializer is removed,
      * "Remap Control Point to Vector" copies control point 1's position
        into the particle's previous position. Source particles carry
        velocity implicitly as (xyz - prev_xyz) / m_flPreviousDt, and on
        the emission frame m_flPreviousDt is the fixed 0.05 s seeded by
        SimulateFirstFrame (particles.cpp, UpdatePrevControlPoints(0.05f)),
        so CP1 = Src - velocity * 0.05 launches the particle at exactly the
        LVS round's velocity,
      * lifetime 5 s (LVS's cap); two variants: "<name>" whose Movement
        Basic gravity is (0,0,-1200) and "<name>_flat" with none.

    Why -1200: LVS flies EnableBallistics rounds as Src + Dir*V*t + g*t^2
    with g = physenv.GetGravity() (-600 at default sv_gravity), so the
    round's acceleration is 2g. The particle integrates the same motion,
    so the tracer stays on the LVS round for the whole flight. With a
    non-default sv_gravity the drop drifts; that is logged once.

    The effect instance lives exactly as long as the LVS bullet (the
    wrapper's silent original Think still fires lvs_bullet_impact_ap at
    LVS's timing); when LVS removes the bullet the particle system is
    destroyed, as gred does at its own end point. Each shot is recorded so
    the muzzle-flash and impact systems can pair caliber/PCF with it.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config
local Debug = LVS_GRED_FX.Debug

LVS_GRED_FX_TRACER = LVS_GRED_FX_TRACER or {}

-- Recent shots per entity (weak keys). Bounded per entity; used to pair
-- muzzle flashes and to infer caliber for impacts.
local RECENT = setmetatable({}, { __mode = "k" })
local RECENT_MAX_PER_ENT = 8
local RECENT_WINDOW = 0.15

-- Last shot per entity, no expiry — cheap caliber inference for impacts.
local LAST_SHOT = setmetatable({}, { __mode = "k" })

-- Last caliber fired by ANY entity. LVS fires lvs_bullet_impact / AP impact
-- with the HIT surface as the entity (not the shooter), so the per-entity
-- lookup cannot find the caliber there. This global fallback restores the
-- old addon's behavior: contextless impacts still get the caliber of the
-- most recent shot.
local LAST_CALIBER = "20mm"

local function getList(ent)
    local list = RECENT[ent]
    if not list then
        list = {}
        RECENT[ent] = list
    end
    return list
end

-- Record a shot so the muzzle flash and impact systems can pair with it.
function LVS_GRED_FX_TRACER.NoteShot(ent, name, srcPos, map)
    if not IsValid(ent) then return end

    local rec = {
        time   = CurTime(),
        name   = name,
        srcPos = srcPos,
        map    = map,
    }

    if map and map.caliber then
        LAST_CALIBER = map.caliber
    end

    local list = getList(ent)
    list[#list + 1] = rec
    if #list > RECENT_MAX_PER_ENT then
        table.remove(list, 1)
    end

    LAST_SHOT[ent] = rec

    if cfg.DebugEnabled() then
        Debug("tracer recorded:", name, "ent:", ent:GetClass(),
            "caliber:", map and map.caliber or "?", "src:", tostring(srcPos))
    end
end

-- Find the most recent shot for `ent` whose source position is close to
-- `muzzlePos` (within 256 units). Passing a nil muzzlePos returns the newest
-- recent record for the entity.
function LVS_GRED_FX_TRACER.RecentShot(ent, muzzlePos)
    if not IsValid(ent) then return nil end

    local list = RECENT[ent]
    if not list then return nil end

    local now = CurTime()
    local best, bestD = nil, nil

    for i = #list, 1, -1 do
        local rec = list[i]
        if not rec or (now - rec.time) > RECENT_WINDOW then
            table.remove(list, i)
        else
            local d
            local matched = false
            if isvector(muzzlePos) and isvector(rec.srcPos) then
                d = rec.srcPos:DistToSqr(muzzlePos)
                matched = d <= 65536 -- 256 units association
            else
                d = i
                matched = true
            end
            if matched and (not bestD or d < bestD) then
                best, bestD = rec, d
            end
        end
    end

    return best
end

-- Caliber string for impact effects, inferred from the last shot of `ent`,
-- falling back to the most recent shot fired by any entity.
function LVS_GRED_FX_TRACER.CaliberFor(ent)
    if IsValid(ent) then
        local rec = LAST_SHOT[ent]
        if rec and rec.map and rec.map.caliber then
            return rec.map.caliber
        end
        rec = LVS_GRED_FX_TRACER.RecentShot(ent, nil)
        if rec and rec.map and rec.map.caliber then
            return rec.map.caliber
        end
    end
    return LAST_CALIBER
end

-- Tell the server this client draws its own tracers, so the server-side
-- straight gred beam (for clients without the addon) is not sent to us.
local announceTries = 0
local function announce()
    if not net or not net.Start then return end
    local ok = pcall(function()
        net.Start("lvs_gred_fx_client")
        net.SendToServer()
    end)
    -- The string is missing only when the server does not run this addon;
    -- retry briefly in case it is still initialising, then give up.
    announceTries = announceTries + 1
    if not ok and announceTries < 4 then timer.Simple(5, announce) end
end
hook.Add("InitPostEntity", "lvs_gred_fx_tracer_announce", function()
    timer.Simple(1, announce)
end)
if LocalPlayer and IsValid(LocalPlayer()) then announce() end

local function getBullet(id)
    if LVS and LVS.GetBullet then
        return LVS:GetBullet(id)
    end
    return nil
end

--[[---------------------------------------------------------------------------
    Generated tracer systems.
-----------------------------------------------------------------------------]]
local PCF_FILE = "particles/lvs_gred_tracers.pcf"
local TRACER_COLORS   = { "red", "green", "white", "yellow" }
local TRACER_CALIBERS = { "7mm", "12mm", "20mm", "30mm", "40mm" }

game.AddParticles(PCF_FILE)
for _, c in ipairs(TRACER_COLORS) do
    for _, k in ipairs(TRACER_CALIBERS) do
        PrecacheParticleSystem("lvs_gred_tracers_" .. c .. "_" .. k)
        PrecacheParticleSystem("lvs_gred_tracers_" .. c .. "_" .. k .. "_flat")
    end
end

local function systemName(map, ballistic)
    local color = map and map.color or "white"
    local caliber = map and map.caliber or "20mm"
    if not table.HasValue(TRACER_COLORS, color) then color = "white" end
    if not table.HasValue(TRACER_CALIBERS, caliber) then caliber = "40mm" end
    return "lvs_gred_tracers_" .. color .. "_" .. caliber .. (ballistic and "" or "_flat")
end

-- CParticleCollection::SimulateFirstFrame seeds m_flPreviousDt with this.
local FIRST_FRAME_DT = 0.05

local warnedGravity = false
local function checkGravity()
    if warnedGravity then return end
    local g = physenv.GetGravity()
    if isvector(g) and math.abs(g.z + 600) > 1 then
        warnedGravity = true
        print(string.format("[lvs_gred_fx] sv_gravity gives %.0f; tracer drop is generated for -600 and will drift from LVS rounds.", g.z))
    end
end

local function stopSystem(self)
    local psys = self._psys
    self._psys = nil
    if LVS_GRED_FX.PsysValid(psys) then
        pcall(psys.StopEmission, psys, false, true)
    end
end

--[[---------------------------------------------------------------------------
    Tracer effect lifecycle. `data` is the LVS tracer EffectData:
      Origin        = bullet.Src (world muzzle position)
      Normal        = bullet.Dir
      MaterialIndex = LVS bullet index
-----------------------------------------------------------------------------]]
function LVS_GRED_FX_TRACER.Init(name, self, data)
    self._gmode = "tracer"

    local bulletID = 0
    if data.GetMaterialIndex then
        bulletID = data:GetMaterialIndex() or 0
    end
    self._bulletID = bulletID

    local bullet = getBullet(bulletID)

    local srcPos = isvector(data:GetOrigin()) and data:GetOrigin() or nil
    if not srcPos and bullet then
        srcPos = bullet.Src
    end

    local ent = bullet and bullet.Entity
    if not IsValid(ent) then
        ent = data.GetEntity and data:GetEntity() or nil
    end

    local map = cfg.Tracers[name] or cfg.TracerDefaults

    -- Record the shot for muzzle-flash pairing and impact caliber inference.
    if IsValid(ent) and isvector(srcPos) then
        LVS_GRED_FX_TRACER.NoteShot(ent, name, srcPos, map)
    end

    -- Without the LVS bullet there is no velocity to give the particle;
    -- the original LVS tracer handles that case.
    if not bullet or not isvector(bullet.Src) then return false end

    local dir = bullet.StartDir or bullet:GetDir()
    local speed = bullet.Velocity or 0
    if not isvector(dir) or speed <= 0 then return false end

    local ballistic = bullet.EnableBallistics == true
    if ballistic then checkGravity() end

    local psysName = systemName(map, ballistic)
    -- gred_particle_tracer creates its system on the world entity at the
    -- muzzle; same here.
    local psys = CreateParticleSystem(Entity(0), psysName, PATTACH_WORLDORIGIN, 0, bullet.Src)
    if not LVS_GRED_FX.PsysValid(psys) then
        Debug("tracer system missing:", psysName)
        return false
    end

    -- CP0 = launch point. CP1 = where the particle "was" one first-frame
    -- step (0.05 s) ago: the generated definition copies it into prev_xyz,
    -- which is how the engine stores velocity. Both must be set before the
    -- system's first simulation, i.e. right here.
    psys:SetControlPoint(0, bullet.Src)
    psys:SetControlPoint(1, bullet.Src - dir * (speed * FIRST_FRAME_DT))
    self._psys = psys

    return true
end

function LVS_GRED_FX_TRACER.Think(self)
    -- Alive exactly as long as the LVS bullet: LVS decides when the round is
    -- gone (hit, water, 5 s), and with it the tracer.
    if not getBullet(self._bulletID) then
        LVS_GRED_FX_TRACER.Stop(self)
        return false
    end
    return true
end

function LVS_GRED_FX_TRACER.Stop(self)
    stopSystem(self)
end
