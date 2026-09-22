--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : barrel smoke (client-side)

    Fully independent of the muzzle-flash system. Barrel smoke resolves its
    own muzzle attachment (muzzle.lua), attaches with PATTACH_POINT_FOLLOW and
    stops itself after a fixed lifetime. One smoke column at a time per
    (entity, attachment): firing again replaces the previous one so rapid
    autocannon fire never stacks smoke systems.

    Gated by the lvs_gred_fx_barrel_smoke cvar.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config
local Debug = LVS_GRED_FX.Debug

LVS_GRED_FX_BARRELSMOKE = LVS_GRED_FX_BARRELSMOKE or {}

-- Particle system handles are NOT entities: the global IsValid() returns
-- false for them. Validate via the :IsValid() method when present.
local function PsysValid(psys)
    if not psys then return false end
    if psys.IsValid then
        local ok = pcall(function() return psys:IsValid() end)
        return ok == true
    end
    return true
end


-- Weak-keyed on the ENTITY: dead entities are dropped by the GC.
-- Each entity maps to { [pcf] = { psys, expires } } so DIFFERENT smoke types
-- (vj narrow + muzzle smoke) coexist per entity; only the SAME type is
-- replaced (faded out) on re-fire.
local ACTIVE = setmetatable({}, { __mode = "k" })

-- Periodic sweeper: stop systems whose owner vanished or whose lifetime
-- expired without the StopAfter timer firing (safety net).
timer.Create("lvs_gred_fx_smoke_sweep", 2, 0, function()
    local now = CurTime()

    for ent, byPcf in pairs(ACTIVE) do
        if not IsValid(ent) then
            ACTIVE[ent] = nil
        else
            for pcf, info in pairs(byPcf) do
                if (info.expires or 0) < now then
                    if PsysValid(info.psys) then
                        pcall(function() info.psys:StopEmission(false, false) end)
                    end
                    byPcf[pcf] = nil
                end
            end
        end
    end
end)

-- Per-PCF emission length. Cannons chain two systems (vj narrow burst, then
-- the lingering muzzle smoke) and the second must not start until the first
-- has stopped emitting, so each stage owns its own life.
local function smokeLife(pcf)
    local t = cfg.SmokeLifeByPcf and cfg.SmokeLifeByPcf[pcf]
    return t or cfg.SmokeLife
end

function LVS_GRED_FX_BARRELSMOKE.Spawn(ent, muzzlePos, att, pcf)
    if not cfg.SmokeEnabled() then return end
    if not IsValid(ent) or not isvector(muzzlePos) then return end
    if not isstring(pcf) or pcf == "" then return end
    if not LVS_GRED_FX.Preload(pcf) then return end
    local life = smokeLife(pcf)

    local byPcf = ACTIVE[ent]
    if not byPcf then
        byPcf = {}
        ACTIVE[ent] = byPcf
    end

    -- RATE LIMIT: rapid fire (autocannons/MGs fire every 0.05-0.15s) would
    -- spawn a new smoke system per shot, stacking many overlapping systems
    -- before the previous ones fade. Only spawn if this smoke type was not
    -- just spawned for this entity within the throttle window.
    local lastSpawn = byPcf[pcf] and byPcf[pcf].spawnedAt or 0
    if CurTime() - lastSpawn < cfg.SmokeThrottle then
        return
    end

    -- Replacing the SAME smoke type: stop the old one from emitting and let
    -- its existing particles fade naturally (StopEmission, clear=false) — do
    -- NOT delete it instantly. Different types coexist.
    local prev = byPcf[pcf]
    if prev then
        if PsysValid(prev.psys) then
            pcall(function() prev.psys:StopEmission(false, false) end)
        end
        byPcf[pcf] = nil
    end

    -- Resolve the muzzle attachment independently of the flash system.
    local smokeAtt = att
    if not smokeAtt or smokeAtt <= 0 then
        smokeAtt = LVS_GRED_FX.ResolveMuzzleAttachment(ent, muzzlePos, 0)
    end

    local psys
    if smokeAtt and smokeAtt > 0 and LVS_GRED_FX.ValidAttachment(ent, smokeAtt) then
        -- forceHandle: smoke must be trackable so we can replace it later.
        psys = LVS_GRED_FX.SpawnAttached(pcf, ent, smokeAtt, {
            life = life,
            clear = false,
            forceHandle = true,
        })
    end

    if not psys then
        if cfg.DebugEnabled() then
            Debug("barrel smoke world fallback:", pcf,
                "pos:", tostring(muzzlePos),
                "reason: no valid attachment", "att:", tostring(smokeAtt))
        end
        psys = LVS_GRED_FX.SpawnWorld(pcf, muzzlePos, angle_zero, life, false)
    end

    if PsysValid(psys) then
        byPcf[pcf] = {
            psys    = psys,
            att     = smokeAtt,
            spawnedAt = CurTime(),
            expires = CurTime() + life + 0.1,
        }
        return byPcf[pcf]
    end
    return nil
end

-- Plays a list of smoke PCFs one after another. The hand-off is driven by
-- the particle system itself: stage N+1 starts the frame stage N reports it
-- has finished emitting (CNewParticleEffect:IsFinished, i.e. the PCF's own
-- emitter durations ran out, or its StopEmission fired). Nothing here
-- guesses how long a PCF emits for.
local CHAINS   = setmetatable({}, { __mode = "k" })
local WATCHING = {}

-- A stage whose PCF never ends on its own (looping emitters) is cut at its
-- configured life by StopAfter, so IsFinished always eventually flips.
local function psysFinished(psys)
    if not PsysValid(psys) then return true end
    local ok, done = pcall(psys.IsFinished, psys)
    if not ok then return true end
    return done == true
end

hook.Add("Think", "lvs_gred_fx_smoke_chain", function()
    if #WATCHING == 0 then return end
    for i = #WATCHING, 1, -1 do
        local w = WATCHING[i]
        if not IsValid(w.ent) or w.chains[w.key] ~= w.token then
            table.remove(WATCHING, i)
        elseif psysFinished(w.psys) then
            table.remove(WATCHING, i)
            w.next()
        end
    end
end)

function LVS_GRED_FX_BARRELSMOKE.SpawnSequence(ent, muzzlePos, att, list)
    if not cfg.SmokeEnabled() or not IsValid(ent) then return end
    if isstring(list) then list = { list } end
    if not istable(list) or #list == 0 then return end

    local chains = CHAINS[ent]
    if not chains then
        chains = {}
        CHAINS[ent] = chains
    end
    local key = att or 0
    local token = (chains[key] or 0) + 1
    chains[key] = token

    local function stage(i)
        if i > #list then return end
        if not IsValid(ent) or chains[key] ~= token then return end
        local rec = LVS_GRED_FX_BARRELSMOKE.Spawn(ent, muzzlePos, att, list[i])
        if i >= #list then return end

        if rec and rec.psys then
            WATCHING[#WATCHING + 1] = {
                ent = ent, chains = chains, key = key, token = token,
                psys = rec.psys, next = function() stage(i + 1) end,
            }
        else
            -- Throttled: the previous shot's stage-i system is still live,
            -- so this shot's remaining stages ride on that chain instead.
            chains[key] = token - 1
        end
    end
    stage(1)
end
