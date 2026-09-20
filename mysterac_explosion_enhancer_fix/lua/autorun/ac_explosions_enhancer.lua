AddCSLuaFile()

--------------------------------------------
-- Particle Precache
--------------------------------------------
game.AddParticles("particles/AC_explosions.pcf")

if CLIENT then
    PrecacheParticleSystem("AC_grenade_explosion")
    PrecacheParticleSystem("AC_grenade_explosion_air")
    PrecacheParticleSystem("AC_rpg_explosion")
    PrecacheParticleSystem("AC_rpg_explosion_air")
    PrecacheParticleSystem("AC_grenade_ar2_explosion")
    PrecacheParticleSystem("AC_grenade_ar2_explosion_air")
    PrecacheParticleSystem("AC_generic_explosion")
    PrecacheParticleSystem("AC_generic_explosion_air")
end

--------------------------------------------
-- Server-Side Explosion Tracking
--------------------------------------------
if SERVER then

    local TRACKING = {}

    local EXPLOSIVE_TYPES = {
        ["npc_grenade_frag"] = {
            ground = "AC_grenade_explosion",
            air    = "AC_grenade_explosion_air",
        },
        ["rpg_missile"] = {
            ground = "AC_rpg_explosion",
            air    = "AC_rpg_explosion_air",
        },
        ["grenade_ar2"] = {
            ground = "AC_grenade_ar2_explosion",
            air    = "AC_grenade_ar2_explosion_air",
        },
    }

    local function IsNearGround(pos)
        local tr = util.TraceLine({
            start  = pos,
            endpos = pos - Vector(0, 0, 60),
            mask   = MASK_SOLID_BRUSHONLY,
        })
        return tr.HitWorld
    end

    local function CreateExplosion(pos, particleInfo)
        local effect = IsNearGround(pos)
            and particleInfo.ground
            or  particleInfo.air

        ParticleEffect(effect, pos, Angle(0, math.random(0, 360), 0))
    end

    ----------------------------------------
    -- Projectile Tracking (grenades, RPGs, AR2)
    ----------------------------------------
    local function CheckExplosives()
        for class, particleInfo in pairs(EXPLOSIVE_TYPES) do
            if not TRACKING[class] then
                TRACKING[class] = {}
            end

            local tracked = TRACKING[class]

            -- Track all current entities of this class
            for _, ent in ipairs(ents.FindByClass(class)) do
                if not tracked[ent] then
                    tracked[ent] = { pos = ent:GetPos(), spawnTime = CurTime() }
                else
                    tracked[ent].pos = ent:GetPos()
                end
            end

            -- Detect removed entities (exploded)
            for ent, data in pairs(tracked) do
                if not IsValid(ent) then
                    CreateExplosion(data.pos, particleInfo)
                    tracked[ent] = nil
                end
            end
        end
    end

    ----------------------------------------
    -- env_explosion Handling
    ----------------------------------------
    local function CheckForENVExplosion()
        for _, ent in ipairs(ents.FindByClass("env_explosion")) do
            local pos = ent:GetPos()

            local effect = IsNearGround(pos)
                and "AC_generic_explosion"
                or  "AC_generic_explosion_air"

            ParticleEffect(effect, pos, Angle(0, math.random(0, 360), 0))
            sound.Play("hd/new_grenadeexplo.mp3", pos, math.random(80, 120), math.random(80, 120), 1)

            ent:Remove()
        end
    end

    ----------------------------------------
    -- Register Hooks
    ----------------------------------------
    if not file.Exists("autorun/ac_particles_remade.lua", "LUA") then
        hook.Add("Think", "AC_CheckExplosives", CheckExplosives)
    end

    hook.Add("Think", "AC_CheckForENVExplosion", CheckForENVExplosion)

end