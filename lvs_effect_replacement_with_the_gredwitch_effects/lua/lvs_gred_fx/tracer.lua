--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : tracer system (client-side)

    Gredwitch's own ballistic tracer, applied to LVS rounds.

    Gredwitch draws the tracer of its ballistic shells (entities/base_shell
    cl_init.lua, ENT:Think) with a ParticleEmitter: every frame, while the
    shell is faster than 5000 u/s, ten "sprites/animglow02" glow sprites
    tinted in the tracer colour are placed in a line behind the shell,
    spaced caliber*0.1 apart, given the shell's velocity so they ride with
    it, 0.05 s life, start size caliber*0.2 shrinking to 0, no gravity, no
    collision. Because the sprites are emitted at the shell's real position
    each frame, the tracer follows whatever the shell does -- drop, slow
    down, arc.

    That is copied here verbatim, with the LVS client bullet standing in
    for the gred shell: LVS simulates its bullet objects
    (LVS:GetBullet(index)) every frame with the weapon's Velocity and, for
    EnableBallistics rounds, gravity, so position and velocity come from
    LVS's ballistics and the drawing comes from Gredwitch's. Speed is the
    instantaneous velocity of LVS's own flight formula.

    Differences from base_shell, on purpose:
      * one shared emitter instead of one per shell (many MG rounds alive
        at once); the particle parameters are identical,
      * caliber: gred shells are 20-150 mm real calibers; LVS tracers are
        mapped to gred's 7-40 mm tracer set, so the sprite size uses the
        mapped caliber the same way (caliber*0.2 start size),
      * yellow is tinted yellow; base_shell's colour table maps its
        "yellow" entry to a white vector.

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
    Gredwitch base_shell tracer (cl_init.lua ENT:Initialize / ENT:Think).
-----------------------------------------------------------------------------]]
-- base_shell: self.Tracer = Material("sprites/animglow02") with $color set
-- per tracer colour (TRACERCOLOR_TO_VECTOR). One material per colour here
-- since several colours are alive at once.
local TRACER_COLOR_VECTOR = {
    white  = Vector(255, 255, 255),
    red    = Vector(255, 0, 0),
    green  = Vector(0, 255, 0),
    yellow = Vector(255, 255, 0),
}
local TRACER_MATS = {}
local function tracerMaterial(colorName)
    local mat = TRACER_MATS[colorName]
    if mat then return mat end
    mat = CreateMaterial("lvs_gred_fx_tracer_" .. colorName, "UnlitGeneric", {
        ["$basetexture"] = "sprites/animglow02",
        ["$additive"]    = 1,
        ["$vertexcolor"] = 1,
        ["$vertexalpha"] = 1,
        ["$nocull"]      = 1,
    })
    mat:SetVector("$color", TRACER_COLOR_VECTOR[colorName] or TRACER_COLOR_VECTOR.white)
    TRACER_MATS[colorName] = mat
    return mat
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

    -- base_shell: self.Tracer (colour material) and self.Caliber.
    self._tracerMat = tracerMaterial(map and map.color or "white")
    self._caliber   = tonumber(string.match(tostring(map and map.caliber or "20mm"), "^(%d+)")) or 20

    return true
end

-- base_shell ENT:Think, tracer part.
local function emitTracer(self, bullet)
    local v = bulletVelocity(bullet, CurTime() - bullet:GetSpawnTime())
    local pos = bullet:GetPos()
    local l = v:Length() * 0.001

    if not (self._tracerMat and l > 5) then return end

    local vang = v:Angle()
    local fwdv = vang:Forward()
    -- shell: pos + self:GetForward() * 30; the shell's forward is its
    -- velocity direction (it is re-aimed along v every Think).
    pos = pos + fwdv * 30

    local em = emitter(pos)
    if not em then return end

    local caliber = self._caliber
    local spacing = -caliber * 0.1 * math.Clamp(l, 0, 1)
    for i = 1, 10 do
        local particle = em:Add(self._tracerMat, pos + fwdv * (i * spacing))
        if particle then
            particle:SetVelocity(v)
            particle:SetDieTime(0.05)
            particle:SetAirResistance(0)
            particle:SetStartAlpha(255)
            particle:SetStartSize(caliber * 0.2)
            particle:SetEndSize(0)
            particle:SetRoll(math.Rand(-1, 1))
            particle:SetGravity(vector_origin)
            particle:SetCollide(false)
        end
    end
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
    -- Particles die on their own 0.05 s later; nothing else is owned.
end
