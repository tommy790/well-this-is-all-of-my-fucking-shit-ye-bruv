-- MysterAC explosion core (shared between the Explosion Enhancer and the
-- Particle Enhancer). Both addons ship this file; the highest version wins and
-- the other copy returns early, so installing either or both gives exactly one
-- tracker, one set of hooks and one set of convars.

local VERSION = 3

if AC_Explosions and (AC_Explosions.Version or 0) >= VERSION then return end

AC_Explosions = AC_Explosions or {}
AC_Explosions.Version = VERSION

-- Kind ids are networked as 3 bits; keep this table small and stable.
AC_Explosions.Kinds = {
    { id = 1, key = "grenade", ground = "AC_grenade_explosion",     air = "AC_grenade_explosion_air",     cvar = "cl_ac_explosions_grenade_disabled" },
    { id = 2, key = "rpg",     ground = "AC_rpg_explosion",         air = "AC_rpg_explosion_air",         cvar = "cl_ac_explosions_rpg_disabled" },
    { id = 3, key = "ar2",     ground = "AC_grenade_ar2_explosion", air = "AC_grenade_ar2_explosion_air", cvar = "cl_ac_explosions_ar2_disabled" },
    { id = 4, key = "generic", ground = "AC_generic_explosion",     air = "AC_generic_explosion_air",     cvar = "cl_ac_explosions_env_disabled" },
}

AC_Explosions.KindById  = {}
AC_Explosions.KindByKey = {}
for _, k in ipairs(AC_Explosions.Kinds) do
    AC_Explosions.KindById[k.id]   = k
    AC_Explosions.KindByKey[k.key] = k
end

-- Projectile class -> kind key. Tripmine/satchel come from weapon_slam.
AC_Explosions.ProjectileClasses = {
    npc_grenade_frag = "grenade",
    npc_tripmine     = "grenade",
    npc_satchel      = "grenade",
    rpg_missile      = "rpg",
    grenade_ar2      = "ar2",
}

local NET_NAME = "AC_Explosion"

if SERVER then
    util.AddNetworkString(NET_NAME)

    local cvEnvMode = CreateConVar("ac_explosions_env_mode", "1",
        bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
        "env_explosion handling: 0 = ignore, 1 = add AC particles on top of the stock explosion, 2 = legacy (remove env_explosion and show only AC particles; disables its damage)",
        0, 2)

    local function IsNearGround(pos)
        local tr = util.TraceLine({
            start  = pos,
            endpos = pos - Vector(0, 0, 60),
            mask   = MASK_SOLID_BRUSHONLY,
        })
        return tr.Hit
    end

    function AC_Explosions.Broadcast(kindKey, pos)
        local kind = AC_Explosions.KindByKey[kindKey]
        if not kind or not isvector(pos) then return end

        net.Start(NET_NAME)
            net.WriteUInt(kind.id, 3)
            net.WriteVector(pos)
            net.WriteBool(IsNearGround(pos))
        net.SendPVS(pos)
    end

    -- Tracked projectiles: ent -> kind key. Weak keys; entries are cleared in
    -- EntityRemoved anyway, this only guards against a missed removal.
    local tracked = setmetatable({}, { __mode = "k" })
    local trackedEnv = setmetatable({}, { __mode = "k" })

    local function Track(ent)
        local kind = AC_Explosions.ProjectileClasses[ent:GetClass()]
        if kind then
            tracked[ent] = kind
            return
        end
        if ent:GetClass() == "env_explosion" then
            trackedEnv[ent] = true
        end
    end

    hook.Add("OnEntityCreated", "AC_Explosions_Track", function(ent)
        if not IsValid(ent) then return end
        Track(ent)
    end)

    -- Projectiles that already existed when this file loaded (autorefresh, or
    -- the addon being enabled mid-session).
    timer.Simple(0, function()
        for cls in pairs(AC_Explosions.ProjectileClasses) do
            for _, ent in ipairs(ents.FindByClass(cls)) do
                Track(ent)
            end
        end
    end)

    -- Projectiles are removed at the instant they detonate, so their position
    -- in EntityRemoved is the detonation point.
    hook.Add("EntityRemoved", "AC_Explosions_Detonate", function(ent)
        local kind = tracked[ent]
        if kind then
            tracked[ent] = nil
            -- Map cleanup removes live grenades without detonating them.
            if AC_Explosions._cleaningUp then return end
            AC_Explosions.Broadcast(kind, ent:GetPos())
            return
        end

        if trackedEnv[ent] then
            trackedEnv[ent] = nil
            if AC_Explosions._cleaningUp then return end
            -- Mode 1: a Lua-spawned env_explosion is normally removed right
            -- after it fires, so its removal is the explosion.
            if cvEnvMode:GetInt() == 1 then
                AC_Explosions.Broadcast("generic", ent:GetPos())
            end
        end
    end)

    hook.Add("PreCleanupMap", "AC_Explosions_CleanupBegin", function()
        AC_Explosions._cleaningUp = true
    end)
    hook.Add("PostCleanupMap", "AC_Explosions_CleanupEnd", function()
        AC_Explosions._cleaningUp = nil
    end)

    -- Legacy mode reproduces the original addon: env_explosion entities are
    -- consumed before they can fire and replaced by the AC particle. It costs
    -- one class lookup per tick, so it only runs while mode 2 is selected.
    local function LegacyEnvTick()
        for _, ent in ipairs(ents.FindByClass("env_explosion")) do
            if IsValid(ent) then
                trackedEnv[ent] = nil
                AC_Explosions.Broadcast("generic", ent:GetPos())
                ent:Remove()
            end
        end
    end

    local function ApplyEnvMode()
        if cvEnvMode:GetInt() == 2 then
            hook.Add("Think", "AC_Explosions_LegacyEnv", LegacyEnvTick)
        else
            hook.Remove("Think", "AC_Explosions_LegacyEnv")
        end
    end

    cvars.AddChangeCallback("ac_explosions_env_mode", ApplyEnvMode, "AC_Explosions")
    ApplyEnvMode()
end

if CLIENT then
    local cvAll = CreateClientConVar("cl_ac_explosions_disabled", "0", true, false,
        "Set to 1 to disable all AC explosion effects")
    local cvByKind = {}
    for _, k in ipairs(AC_Explosions.Kinds) do
        cvByKind[k.id] = CreateClientConVar(k.cvar, "0", true, false,
            "Set to 1 to disable AC " .. k.key .. " explosion effects")
    end

    local precached = false
    local function Precache()
        if precached then return end
        precached = true
        for _, k in ipairs(AC_Explosions.Kinds) do
            PrecacheParticleSystem(k.ground)
            PrecacheParticleSystem(k.air)
        end
    end

    function AC_Explosions.Play(kindId, pos, onGround)
        local kind = AC_Explosions.KindById[kindId]
        if not kind then return end
        if cvAll:GetBool() then return end
        local cv = cvByKind[kindId]
        if cv and cv:GetBool() then return end

        Precache()
        ParticleEffect(onGround and kind.ground or kind.air, pos, Angle(0, math.random(0, 359), 0))
    end

    net.Receive(NET_NAME, function()
        local id  = net.ReadUInt(3)
        local pos = net.ReadVector()
        local onGround = net.ReadBool()
        AC_Explosions.Play(id, pos, onGround)
    end)

    hook.Add("PopulateToolMenu", "AC_Explosions_Menu", function()
        spawnmenu.AddToolMenuOption("Options", "Combat", "AC_ExplosionsToggle", "AC Explosion Effects", "", "", function(panel)
            panel:ClearControls()
            panel:Help("Toggle custom explosion effects for grenades, RPGs, AR2 grenades and generic explosions.")
            panel:CheckBox("Disable All Explosions", "cl_ac_explosions_disabled")
            panel:CheckBox("Disable Grenade Explosions", "cl_ac_explosions_grenade_disabled")
            panel:CheckBox("Disable RPG Explosions", "cl_ac_explosions_rpg_disabled")
            panel:CheckBox("Disable AR2 Explosions", "cl_ac_explosions_ar2_disabled")
            panel:CheckBox("Disable Generic (env_explosion) Explosions", "cl_ac_explosions_env_disabled")
            panel:Help("Server setting: ac_explosions_env_mode (0 off, 1 overlay, 2 legacy replace).")
        end)
    end)
end
