--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : tracer system (client-side)

    Gredwitch's tracer particle, riding LVS's ballistics.

    The gred tracer (gred_tracers_<color>_<caliber>, gred_particles.pcf) is
    one render_sprite_trail particle: material particles/ins_tracer, sheet
    sequence 2 or 3, radius 25, trail = 0.25 s of velocity clamped to
    2000 u with a 0.22 s length fade-in, colour1/colour2 per tracer colour.
    Its motion is baked into the particle system: "move particles between
    2 control points" gives it a fixed speed at emission and a lifetime
    equal to the distance to the end point, and Movement Basic has no
    gravity. Nothing outside the system can bend or slow it afterwards, so
    that particle cannot follow a dropping, LVS-speed round.

    What can follow the round is the way Gredwitch draws the tracer of its
    own ballistic shells (entities/base_shell/cl_init.lua ENT:Think): a
    ParticleEmitter fed every frame at the shell's real position with the
    shell's velocity. That mechanism is used here with the LVS client
    bullet (LVS:GetBullet(index), simulated by LVS with the weapon's
    Velocity and, for EnableBallistics rounds, gravity) in place of the
    shell, and with the gred tracer particle's own ingredients as the
    emitted sprite:

      * material: particles/ins_tracer, cropped to the pcf's sheet strip by
        $basetexturetransform, so the sprite is the very same streak image,
      * width 25 (pcf radius), drawn velocity-aligned with length
        min(speed * 0.25, 2000) ramping in over 0.22 s (pcf sprite trail),
      * colour picked once per shot between the pcf's colour1/colour2,
      * velocity and position from LVS's own flight formula every frame.

    Not reproduced: the pcf's smoke rope and glow children (0.5 s / 0.1 s
    after launch), which are Position From Parent Particles systems.

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
    gred_tracers_* particle parameters (gred_particles.pcf) and the
    ins_tracer sheet strips they use (sequences 2 and 3, from the VTF sheet).
-----------------------------------------------------------------------------]]
local TRACER_RADIUS   = 25      -- Radius Random 25/25
local TRAIL_SECONDS   = 0.25    -- Trail Length Random 0.25/0.25
local TRAIL_MAX       = 2000    -- render_sprite_trail max length
local LENGTH_FADE_IN  = 0.22    -- render_sprite_trail length fade in time
local MIN_SPEED       = 5000    -- base_shell: no tracer under l = 5 (v * 0.001)
local SHEET_STRIPS = {          -- u0, u1 of the strip; v spans the full sheet
    { 0.251, 0.374 },
    { 0.376, 0.499 },
}
local COLORS = {                -- Color Random color1 / color2
    red    = { { 255, 142, 142 }, { 255, 137, 137 } },
    green  = { { 180, 255, 214 }, { 180, 255, 214 } },
    white  = { { 255, 255, 255 }, { 255, 255, 255 } },
    yellow = { { 241, 243,  31 }, { 194, 196,  35 } },
}

-- Which end of the streak leads. The bright end of the ins_tracer strip is
-- at the bottom of the sheet (v -> 1); the emitter draws length particles
-- with v = 1 at the leading end, so 0 is the pcf orientation. Flip if the
-- bright end trails on your build.
local CvarFlip = GetConVar("lvs_gred_fx_tracer_flip")
    or CreateClientConVar("lvs_gred_fx_tracer_flip", "0", true, false, "Flip the tracer streak so its bright end leads if it appears reversed.")

local STRIP_MATS = {}
local function stripMaterial(index, flip)
    local key = index .. (flip and "f" or "n")
    local mat = STRIP_MATS[key]
    if mat then return mat end
    local u0, u1 = SHEET_STRIPS[index][1], SHEET_STRIPS[index][2]
    local scaleU = u1 - u0
    local transform = flip
        and string.format("center 0 0 scale %.4f -1 rotate 0 translate %.4f 1", scaleU, u0)
        or  string.format("center 0 0 scale %.4f 1 rotate 0 translate %.4f 0", scaleU, u0)
    mat = CreateMaterial("lvs_gred_fx_ins_tracer_" .. key, "UnlitGeneric", {
        ["$basetexture"]          = "particles/ins_tracer",
        ["$basetexturetransform"] = transform,
        ["$additive"]             = 1,
        ["$vertexcolor"]          = 1,
        ["$vertexalpha"]          = 1,
        ["$translucent"]          = 1,
        ["$nocull"]               = 1,
    })
    STRIP_MATS[key] = mat
    return mat
end

local function pickColor(name)
    local pair = COLORS[name] or COLORS.white
    local f = math.random()
    local a, b = pair[1], pair[2]
    return { Lerp(f, a[1], b[1]), Lerp(f, a[2], b[2]), Lerp(f, a[3], b[3]) }
end

local EMITTER = nil
local function emitter(pos)
    if EMITTER and EMITTER:IsValid() then return EMITTER end
    EMITTER = ParticleEmitter(pos, false)
    return EMITTER
end

hook.Add("ShutDown", "lvs_gred_fx_tracer_emitter", function()
    if EMITTER and EMITTER:IsValid() then EMITTER:Finish() end
    EMITTER = nil
end)

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

    -- Sequence Random 2..3 and Color Random happen once per gred particle,
    -- i.e. once per shot.
    self._strip = math.random(#SHEET_STRIPS)
    self._color = pickColor(map and map.color or "white")

    return true
end

-- One velocity-aligned streak per frame at the round's position: the gred
-- sprite-trail particle, re-emitted where LVS says the round is.
local function emitTracer(self, bullet)
    local age = CurTime() - bullet:GetSpawnTime()
    local v = bulletVelocity(bullet, age)
    local speed = v:Length()
    if speed < MIN_SPEED then return end

    local pos = bullet:GetPos()
    local len = math.min(speed * TRAIL_SECONDS, TRAIL_MAX) * math.min(age / LENGTH_FADE_IN, 1)
    -- LVS blends the round out of the muzzle; never draw back past it.
    if isvector(bullet.Src) then len = math.min(len, pos:Distance(bullet.Src)) end
    if len <= 1 then return end

    local em = emitter(pos)
    if not em then return end

    local particle = em:Add(stripMaterial(self._strip, CvarFlip:GetBool()), pos)
    if not particle then return end

    local c = self._color
    particle:SetVelocity(v)
    particle:SetDieTime(math.max(RealFrameTime() * 2, 0.01))
    particle:SetAirResistance(0)
    particle:SetGravity(vector_origin)
    particle:SetCollide(false)
    particle:SetStartAlpha(255)
    particle:SetEndAlpha(255)
    particle:SetStartSize(TRACER_RADIUS)
    particle:SetEndSize(TRACER_RADIUS)
    particle:SetStartLength(len)
    particle:SetEndLength(len)
    particle:SetColor(c[1], c[2], c[3])
end

function LVS_GRED_FX_TRACER.Think(self)
    -- Alive exactly as long as the LVS bullet: LVS decides when the round is
    -- gone (hit, water, 5 s), and with it the tracer.
    local bullet = getBullet(self._bulletID)
    if not bullet then
        LVS_GRED_FX_TRACER.Stop(self)
        return false
    end
    if CurTime() - bullet:GetSpawnTime() > 0 then
        emitTracer(self, bullet)
    end
    return true
end

function LVS_GRED_FX_TRACER.Stop(self)
    -- Emitted sprites expire on their own within two frames.
end
