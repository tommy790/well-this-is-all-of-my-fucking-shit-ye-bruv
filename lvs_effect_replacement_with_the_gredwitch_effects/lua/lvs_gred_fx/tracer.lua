--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : tracer system (client-side)

    Hybrid of the two ballistics systems:

      * LVS owns the projectile. Its client bullet object
        (LVS:GetBullet(index)) is simulated by LVS itself every frame with
        the weapon's Velocity and, for EnableBallistics rounds, the world
        gravity. That object is the position of the round -- drop, speed,
        the brief muzzle "parenting" LVS does on the client, all of it.

      * Gredwitch owns the look. gred_tracers_<color>_<caliber> in
        gred_particles.pcf is a single render_sprite_trail particle:
        material particles/ins_tracer, sheet sequences 2-3, radius 25,
        trail length 0.25 s of velocity clamped to 2000 u, length fading
        in over 0.22 s, one colour per tracer colour. Those parameters are
        read out of the pcf and drawn here as the same camera-facing strip,
        but stretched behind the LVS bullet's actual position along its
        actual direction of travel instead of flying in a straight line at
        the pcf's own fixed speed.

    Why not the gred particle itself: its velocity is set once at emission
    (Movement Basic, no gravity) and cannot be steered afterwards, so it can
    neither drop nor match an LVS round's speed. What is not reproduced:
    the pcf's short smoke rope and glow children (0.5 s / 0.1 s after
    launch); both are "Position From Parent Particles" systems that cannot
    exist without the gred particle.

    The effect instance lives exactly as long as the LVS bullet (the
    wrapper's silent original Think still fires lvs_bullet_impact_ap at
    LVS's timing), and each shot is recorded so the muzzle-flash and impact
    systems can pair caliber/PCF with it.
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
    Gredwitch tracer look, from gred_particles.pcf (gred_tracers_*).
-----------------------------------------------------------------------------]]
local TRACER_MAT       = Material("particles/ins_tracer")
local TRACER_RADIUS    = 25      -- Radius Random 25/25 (half width of the strip)
local TRAIL_SECONDS    = 0.25    -- Trail Length Random 0.25/0.25
local TRAIL_MAX        = 2000    -- render_sprite_trail max length
local LENGTH_FADE_IN   = 0.22    -- render_sprite_trail length fade in time
-- ins_tracer sheet, sequences 2 and 3 (u ranges; v runs tail 0 -> head 1,
-- the bright end of the streak is at the bottom of the strip).
local SEQUENCES = {
    { 0.251, 0.374 },
    { 0.376, 0.499 },
}
-- Color Random color1/color2 per tracer colour.
local COLORS = {
    red    = { { 255, 142, 142 }, { 255, 137, 137 } },
    green  = { { 180, 255, 214 }, { 180, 255, 214 } },
    white  = { { 255, 255, 255 }, { 255, 255, 255 } },
    yellow = { { 241, 243,  31 }, { 194, 196,  35 } },
}

local function pickColor(name)
    local pair = COLORS[name] or COLORS.white
    local f = math.random()
    local a, b = pair[1], pair[2]
    return Color(
        Lerp(f, a[1], b[1]),
        Lerp(f, a[2], b[2]),
        Lerp(f, a[3], b[3]),
        255)
end

-- LVS's DoBulletFlight: ballistic offset = StartDir * t * V + gravity * t^2,
-- so the instantaneous velocity is StartDir * V + 2 * gravity * t.
local function bulletVelocity(bullet, age)
    local v = bullet.Velocity or 0
    if bullet.EnableBallistics then
        return (bullet.StartDir or bullet:GetDir()) * v + bullet:GetGravity() * (2 * age)
    end
    return bullet:GetDir() * v
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

    self._color = pickColor(map and map.color)
    self._uv    = SEQUENCES[math.random(#SEQUENCES)]

    -- Render bounds over everything the round can reach in LVS's 5 s bullet
    -- lifetime, including the drop, so the strip is never culled mid-flight.
    if bullet and isvector(srcPos) then
        local dir = bullet:GetDir()
        local far = srcPos + dir * (bullet.Velocity or 0) * 5
        local mins, maxs = Vector(srcPos), Vector(srcPos)
        local function extend(p)
            mins.x, mins.y, mins.z = math.min(mins.x, p.x), math.min(mins.y, p.y), math.min(mins.z, p.z)
            maxs.x, maxs.y, maxs.z = math.max(maxs.x, p.x), math.max(maxs.y, p.y), math.max(maxs.z, p.z)
        end
        extend(far)
        if bullet.EnableBallistics then extend(far + bullet:GetGravity() * 25) end
        local pad = Vector(TRACER_RADIUS, TRACER_RADIUS, TRACER_RADIUS)
        self._bounds = { mins - pad, maxs + pad }
    elseif isvector(srcPos) then
        local n = data.GetNormal and data:GetNormal() or Vector(1, 0, 0)
        self._bounds = { srcPos, srcPos + n * 50000 }
    end
    -- Applied from Think: the wrapper runs the original LVS Init (for its
    -- non-visual feedback) after this one, and that Init sets the straight
    -- line bounds LVS uses for its own beam.
    self._boundsSet = false

    return true
end

function LVS_GRED_FX_TRACER.Think(self)
    -- Alive exactly as long as the LVS bullet: LVS decides when the round is
    -- gone (hit, water, 5 s), and with it the tracer.
    if not getBullet(self._bulletID) then
        LVS_GRED_FX_TRACER.Stop(self)
        return false
    end
    if not self._boundsSet then
        self._boundsSet = true
        if self._bounds then self:SetRenderBoundsWS(self._bounds[1], self._bounds[2]) end
    end
    return true
end

function LVS_GRED_FX_TRACER.Render(self)
    local bullet = getBullet(self._bulletID)
    if not bullet then return end

    local pos = bullet:GetPos()
    local dir = bullet:GetDir()
    if not isvector(pos) or not isvector(dir) then return end

    local age = CurTime() - bullet:GetSpawnTime()
    if age <= 0 then return end

    local speed = bulletVelocity(bullet, age):Length()
    local len = math.min(speed * TRAIL_SECONDS, TRAIL_MAX) * math.min(age / LENGTH_FADE_IN, 1)
    -- Never stretch back past the muzzle.
    if isvector(bullet.Src) then
        len = math.min(len, pos:Distance(bullet.Src))
    end
    if len <= 1 then return end

    local tail = pos - dir * len

    -- Camera-facing strip (what render_sprite_trail draws).
    local side = dir:Cross(EyePos() - pos)
    if side:LengthSqr() < 1e-6 then
        side = dir:Angle():Right()
    else
        side:Normalize()
    end
    side = side * TRACER_RADIUS

    local uv = self._uv or SEQUENCES[1]
    local col = self._color or color_white
    local r, g, b, a = col.r, col.g, col.b, col.a

    render.SetMaterial(TRACER_MAT)
    mesh.Begin(MATERIAL_QUADS, 1)
        mesh.Position(tail - side) mesh.TexCoord(0, uv[1], 0) mesh.Color(r, g, b, a) mesh.AdvanceVertex()
        mesh.Position(tail + side) mesh.TexCoord(0, uv[2], 0) mesh.Color(r, g, b, a) mesh.AdvanceVertex()
        mesh.Position(pos + side)  mesh.TexCoord(0, uv[2], 1) mesh.Color(r, g, b, a) mesh.AdvanceVertex()
        mesh.Position(pos - side)  mesh.TexCoord(0, uv[1], 1) mesh.Color(r, g, b, a) mesh.AdvanceVertex()
    mesh.End()
end

function LVS_GRED_FX_TRACER.Stop(self)
    -- Nothing owned outside the effect instance.
end
