AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- Timed grenade thrown by the EZ2 weapon pack. Physics-simulated; the
-- optional "stick to player" mode uses bone following instead of teleporting
-- the entity every Think.

ENT.FuseBeeps = 5
ENT.BeepInterval = 0.199

function ENT:Initialize()
    self:SetModel("models/weapons/w_npcnade.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)

    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end

    self.beeps = 0
    self.nextBeep = CurTime() + 1
    self:EmitSound("weapons/grenade/tick1.wav")

    if self.trackplayer and IsValid(self.playertotrack) then
        self:AttachTo(self.playertotrack)
    end

    local att = self:LookupAttachment("fuse")
    if att <= 0 then return end
    local pos = self:GetAttachment(att).Pos

    local glow = ents.Create("env_sprite")
    if IsValid(glow) then
        glow:SetPos(pos)
        glow:SetKeyValue("model", "sprites/redglow1.vmt")
        glow:SetKeyValue("scale", "0.1")
        glow:SetKeyValue("GlowProxySize", "3")
        glow:SetKeyValue("rendermode", "5")
        glow:SetKeyValue("renderamt", "200")
        glow:Spawn()
        glow:SetParent(self, att)
        self:DeleteOnRemove(glow)
    end

    local trail = ents.Create("env_spritetrail")
    if IsValid(trail) then
        trail:SetPos(pos)
        trail:SetKeyValue("spritename", "sprites/bluelaser1.vmt")
        trail:SetKeyValue("startwidth", "10")
        trail:SetKeyValue("endwidth", "1")
        trail:SetKeyValue("lifetime", "0.7")
        trail:SetKeyValue("rendermode", "5")
        trail:SetKeyValue("rendercolor", "255 0 0")
        trail:Spawn()
        trail:SetParent(self, att)
        self:DeleteOnRemove(trail)
    end
end

function ENT:AttachTo(target)
    if not IsValid(target) then return end
    local bone = target:LookupBone("ValveBiped.Bip01_Spine2") or 0
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    self:SetMoveType(MOVETYPE_NONE)
    self:FollowBone(target, bone)
    self.stuckTo = target
end

function ENT:Think()
    if self.stuckTo and (not IsValid(self.stuckTo) or (self.stuckTo.Alive and not self.stuckTo:Alive())) then
        -- Host died or vanished: drop back into the world as a physics object.
        self:FollowBone(NULL, 0)
        self:SetParent(NULL)
        self:SetMoveType(MOVETYPE_VPHYSICS)
        local phys = self:GetPhysicsObject()
        if IsValid(phys) then phys:EnableMotion(true) phys:Wake() end
        self.stuckTo = nil
    end

    if CurTime() < self.nextBeep then
        self:NextThink(self.nextBeep)
        return true
    end

    if self.beeps < self.FuseBeeps then
        self:EmitSound("weapons/grenade/tick1.wav")
        self.beeps = self.beeps + 1
        self.nextBeep = CurTime() + self.BeepInterval
        self:NextThink(self.nextBeep)
        return true
    end

    self:Detonate()
end

function ENT:Detonate()
    if self.detonated then return end
    self.detonated = true

    local owner = self:GetOwner()
    local explo = ents.Create("env_explosion")
    if IsValid(explo) then
        explo:SetPos(self:WorldSpaceCenter())
        if IsValid(owner) then explo:SetOwner(owner) end
        explo:SetKeyValue("iMagnitude", "100")
        explo:SetKeyValue("spawnflags", "32")
        explo:Spawn()
        explo:Activate()
        explo:Fire("Explode")
        explo:Fire("Kill", "", 1)
    end
    self:Remove()
end
