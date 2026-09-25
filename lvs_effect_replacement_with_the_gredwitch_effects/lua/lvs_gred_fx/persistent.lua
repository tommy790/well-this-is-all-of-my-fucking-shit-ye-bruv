--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : effects LVS re-fires every tick while something is
    happening (client-side)

    LVS has no "stop" message for these; it simply keeps calling util.Effect
    at a fixed cadence for as long as the condition holds:

      * lvs_ammorack_fire  — every 0.05 s from the ammo rack while destroyed
      * lvs_defence_smoke  — every 0.2 s from lvs_item_smoke while it exists

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
    Defence smoke screen — one gred smoke cloud per canister.

    lvs_item_smoke sends only an origin, no entity. Calls from the same
    canister land within a few units of each other (the canister may roll),
    so a call adopts the nearest live screen within SMOKE_MATCH_DIST.
-----------------------------------------------------------------------------]]
local SMOKE_CADENCE    = 0.2    -- lvs_item_smoke: SetNextClientThink(T + 0.2)
local SMOKE_MATCH_DIST = 96

function P.SmokeScreen(name, self, data)
    self._gmode = "oneshot"
    if not cfg.Enabled() then return false end

    local pos = data.GetOrigin and data:GetOrigin() or nil
    if not isvector(pos) then return false end

    local now = CurTime()
    local bestKey, bestD = nil, SMOKE_MATCH_DIST * SMOKE_MATCH_DIST
    for key, src in pairs(P.Active) do
        if src.kind == "smoke" and src.pos then
            local d = src.pos:DistToSqr(pos)
            if d < bestD then bestKey, bestD = key, d end
        end
    end

    if bestKey then
        local src = P.Active[bestKey]
        src.lastCall = now
        src.pos = pos
        if LVS_GRED_FX.PsysValid(src.psys) then return true end
        -- Emission cap reached (watcher stopped it): start the next system
        -- in place so the screen stays continuous.
        P.Active[bestKey] = nil
    end

    local pcf = cfg.SmokeScreenPcf
    if not LVS_GRED_FX.Preload(pcf) then return false end

    local psys = LVS_GRED_FX.SpawnWorld(pcf, pos, angle_zero, nil, false)
    if not LVS_GRED_FX.PsysValid(psys) then return false end

    local key = "smoke:" .. tostring(now) .. ":" .. tostring(pos)
    P.Active[key] = {
        kind = "smoke", psys = psys, pos = pos, lastCall = now, started = now,
        cadence = SMOKE_CADENCE, emitCap = cfg.SmokeScreenEmitTime,
    }
    ensureWatcher()

    if cfg.DebugEnabled() then
        Debug("smoke screen started:", pcf, "pos:", tostring(pos))
    end
    return true
end
