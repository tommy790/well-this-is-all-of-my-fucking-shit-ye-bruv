--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : effects LVS re-fires every tick while something is
    happening (client-side)

    LVS has no "stop" message for these; it simply keeps calling util.Effect
    at a fixed cadence for as long as the condition holds:

      * lvs_ammorack_fire  — every 0.05 s from the ammo rack while destroyed
      * lvs_defence_smoke  — every 0.2 s from lvs_item_smoke once it has landed

    The native effects add a fresh handful of sprites per call. A gred
    particle system is a continuous emitter, so the right mapping is ONE
    system per source, kept alive while the calls keep arriving and told to
    stop emitting the moment they cease (a few missed calls at the known
    cadence — no guessed lifetimes). Already-emitted particles fade out on
    their own.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config
local Debug = LVS_GRED_FX.Debug

LVS_GRED_FX_PERSISTENT = LVS_GRED_FX_PERSISTENT or {}
local P = LVS_GRED_FX_PERSISTENT

-- Active sources: key -> { psys, lastCall, cadence, started, pos, ent }
P.Active = P.Active or {}

local function stopSource(key, src)
    if LVS_GRED_FX.PsysValid(src.psys) then
        pcall(function() src.psys:StopEmission(false, false) end)
    end
    P.Active[key] = nil
end

local function stopAll()
    for key, src in pairs(P.Active) do stopSource(key, src) end
end

hook.Add("OnReloaded", "lvs_gred_fx_persistent", stopAll)
hook.Add("ShutDown", "lvs_gred_fx_persistent", stopAll)
hook.Add("EntityRemoved", "lvs_gred_fx_persistent", function(ent)
    for key, src in pairs(P.Active) do
        if src.ent == ent then stopSource(key, src) end
    end
end)

-- A source is considered ended once MISSED_CALLS of its cadence pass with
-- no new call, or its entity is gone. Watcher runs only while sources exist.
local MISSED_CALLS = 3

local function watch()
    local now = CurTime()
    local any = false
    for key, src in pairs(P.Active) do
        any = true
        if not LVS_GRED_FX.PsysValid(src.psys)
            or (src.ent ~= nil and not IsValid(src.ent))
            or now - src.lastCall > src.cadence * MISSED_CALLS then
            stopSource(key, src)
        elseif src.emitCap and now - src.started >= src.emitCap then
            -- Continuous emitter with a per-system emission cap: stop this
            -- one and let the next call start a fresh system (the caller is
            -- still firing, so coverage continues without piling up).
            stopSource(key, src)
        end
    end
    if not any then timer.Remove("lvs_gred_fx_persistent_watch") end
end

local function ensureWatcher()
    if not timer.Exists("lvs_gred_fx_persistent_watch") then
        timer.Create("lvs_gred_fx_persistent_watch", 0.05, 0, watch)
    end
end

--[[---------------------------------------------------------------------------
    Ammo rack fire — one flame jet per burning vehicle position.
-----------------------------------------------------------------------------]]
local AMMORACK_CADENCE = 0.05   -- lvs_wheeldrive_ammorack: SetNextClientThink(T + 0.05)

function P.AmmoRack(name, self, data)
    self._gmode = "oneshot"
    if not cfg.Enabled() then return false end

    local ent = data.GetEntity and data:GetEntity() or nil
    if not IsValid(ent) then return false end

    local firePos = data.GetOrigin and data:GetOrigin() or ent:GetPos()
    local offset = isvector(firePos) and ent:WorldToLocal(firePos) or vector_origin

    -- One jet per rack: racks on the same vehicle sit at different offsets.
    local key = "ammorack:" .. ent:EntIndex() .. ":" .. math.Round(offset.x / 16) .. ","
        .. math.Round(offset.y / 16) .. "," .. math.Round(offset.z / 16)

    local src = P.Active[key]
    if src and LVS_GRED_FX.PsysValid(src.psys) then
        src.lastCall = CurTime()
        return true
    end

    local pcf = cfg.AmmoRackPcf
    if not LVS_GRED_FX.Preload(pcf) then return false end

    local ok, psys = pcall(CreateParticleSystem, ent, pcf, PATTACH_ABSORIGIN_FOLLOW, 0, offset)
    if not ok or not LVS_GRED_FX.PsysValid(psys) then return false end

    P.Active[key] = { psys = psys, ent = ent, lastCall = CurTime(), started = CurTime(), cadence = AMMORACK_CADENCE }
    ensureWatcher()

    if cfg.DebugEnabled() then
        Debug("ammo rack fire started:", pcf, "ent:", ent:GetClass(), "offset:", tostring(offset))
    end
    return true
end

--[[---------------------------------------------------------------------------
    Defence smoke canister — one gred cloud per canister, once it has landed.

    lvs_item_smoke starts sending lvs_defence_smoke (every 0.2 s, origin
    only) from its FIRST PhysicsCollide, and a canister launched from a
    tank usually clips the launching hull on the way out, so LVS's calls
    begin mid-flight. LVS's own sprites start at size 0 and take seconds to
    grow, so natively that is barely visible; a gred cloud popped at the
    first call sat in the air. So the canister entity is looked up at the
    origin and the cloud starts only once it has come to rest; earlier
    calls are ignored (LVS keeps calling, nothing is missed).

    m203_smokegrenade is a single pop (15 puffs, 15-50 s) with no
    continuous emission: spawned once per canister, attached to it so it
    follows a last roll, and left to its own lifetime.
-----------------------------------------------------------------------------]]
local SMOKE_CADENCE    = 0.2    -- lvs_item_smoke: SetNextClientThink(T + 0.2)
local SMOKE_FIND_DIST  = 48     -- canister entity is at the effect origin
local SMOKE_REST_SPEED = 30     -- a can rolling slower than this is settling, not flying

local function canisterAt(pos)
    local best, bestD = nil, SMOKE_FIND_DIST * SMOKE_FIND_DIST
    for _, ent in ipairs(ents.FindByClass("lvs_item_smoke")) do
        local d = ent:GetPos():DistToSqr(pos)
        if d < bestD then best, bestD = ent, d end
    end
    return best
end

function P.SmokeScreen(name, self, data)
    self._gmode = "oneshot"
    if not cfg.Enabled() then return false end

    local pos = data.GetOrigin and data:GetOrigin() or nil
    if not isvector(pos) then return false end

    local can = canisterAt(pos)
    if not IsValid(can) then return false end

    local key = "smoke:" .. can:EntIndex()
    local src = P.Active[key]
    if src then
        src.lastCall = CurTime()
        return true
    end

    -- Still flying: wait for it to come to rest.
    if can:GetVelocity():Length() > SMOKE_REST_SPEED then return true end

    local pcf = cfg.SmokeScreenPcf
    if not LVS_GRED_FX.Preload(pcf) then return false end

    local ok, psys = pcall(CreateParticleSystem, can, pcf, PATTACH_ABSORIGIN_FOLLOW, 0, vector_origin)
    if not ok or not LVS_GRED_FX.PsysValid(psys) then return false end

    -- Tracked for cleanup only (canister removed / calls stop); the pop has
    -- no emission to cap. The cadence window is generous because the
    -- canister keeps calling for its whole 30 s life.
    P.Active[key] = {
        kind = "smoke", psys = psys, ent = can, pos = pos,
        lastCall = CurTime(), started = CurTime(), cadence = SMOKE_CADENCE,
    }
    ensureWatcher()

    if cfg.DebugEnabled() then
        Debug("smoke canister landed:", pcf, "ent:", can:EntIndex(), "pos:", tostring(pos))
    end
    return true
end
