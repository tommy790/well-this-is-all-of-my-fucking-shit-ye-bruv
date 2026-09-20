
include("shared.lua")
include("cl_init.lua")
function ENT:Initialize()
	if SERVER then
		if (self.trackplayer == nil) then self.trackplayer = false end
		if (self.playertotrack == nil) then self.playertotrack = nil end -- atleast exist
		self.Beep = CurTime()
		self.firstbeep = false
		self.beeps = 0
		self:EmitSound("grenade/tick1.wav")
		self:SetModel("models/weapons/w_npcnade.mdl")
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		local attachment = self:LookupAttachment("fuse")

		if attachment <= 0 then
			return
		end

		local pos = self:GetAttachment(attachment).Pos

		local main = ents.Create("env_sprite")

		main:SetPos(pos)
		main:SetParent(self)
		main:SetKeyValue("model", "sprites/redglow1.vmt")
		main:SetKeyValue("scale", 0.1)
		main:SetKeyValue("GlowProxySize", 3)	
		main:SetKeyValue("rendermode", 5)
		main:SetKeyValue("renderamt", 200)
		main:Spawn()
		main:Activate()

		local trail = ents.Create("env_spritetrail")

		trail:SetPos(pos)
		trail:SetParent(self)
		trail:SetKeyValue("spritename", "sprites/bluelaser1.vmt")
		trail:SetKeyValue("startwidth", 10)
		trail:SetKeyValue("endwidth", 1)
		trail:SetKeyValue("lifetime", 0.7)
		trail:SetKeyValue("rendermode", 5)
		trail:SetKeyValue("rendercolor", "255 0 0")
		trail:Spawn()
		trail:Activate()
		timer.Simple(1, function()
			self.firstbeep = true
		end)
		self:DeleteOnRemove(main)
		self:DeleteOnRemove(trail)
	end
end


function ENT:Think()
	if (self:IsValid() && self.trackplayer && self.playertotrack:IsValid() && self.playertotrack:Alive()) then
		self:SetPos(self.playertotrack:GetBonePosition(11))
	end

	if (SERVER && self.Beep && self.Beep <= CurTime() && self.firstbeep && self.beeps < 5) then
		self:EmitSound("grenade/tick1.wav")
		self.beeps = self.beeps + 1
		self.Beep = CurTime() + 0.1990
	elseif (SERVER && self.firstbeep && self.beeps >= 5) then
		local pos = self:WorldSpaceCenter()

		local explo = ents.Create("env_explosion")
		explo:SetOwner(self:GetOwner())
		explo:SetPos(pos)
		explo:SetKeyValue("iMagnitude", 100)
		explo:SetKeyValue("spawnflags", 32)
		explo:Spawn()
		explo:Activate()
		explo:Fire("Explode")
		explo:Fire("Explode")
	
		self:Remove()
	end
end
