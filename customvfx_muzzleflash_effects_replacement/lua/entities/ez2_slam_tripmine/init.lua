-------------------------------------
-- Laser Tripmine.
-------------------------------------
AddCSLuaFile('cl_init.lua')
AddCSLuaFile('shared.lua')

include('shared.lua')
ENT.DeploySound = 'slam/place.wav'
ENT.ChargeSound = 'common/null.wav'
ENT.ActivateSound = 'common/null.wav'
ENT.WeaponClassName	= 'ez2wep_slam'
ENT.skName = "tripmine"

local BeamClassName 	= 'env_beam'
local BeamEndClassName 	= 'info_target'

local TRIPMINE_TRACE_LENGTH	= 16384

function ENT:InitializeServerSide()

	self:SetMoveType( MOVETYPE_FLY )
	self:SetSolid( SOLID_NONE )

	self:SetModel( self.Model )

	self:SetCycle(0)
	self:SetSequence(0)
	self:ResetSequenceInfo(0)
	
	self:SetPlaybackRate(0)
	
	self:SetTrigger(true)
	self:UseTriggerBounds(true, 1)
	
	self:SetCollisionBounds( Vector(-8,-8,-8), Vector(8, 8, 8) )
	self:SetPos( self:GetPos() )
	self:SetPowerUp( CurTime() + 1.0 )
	
	self.m_pfnThink = self.PowerupThink
	self:NextThink( CurTime() + 0.001 )

	self:SetBlastDamage( 150 )
	self:SetBlastRadius( 300 )
	self:SetHealth(9999999999)

	if IsValid( self:GetOwner() ) then
		self:EmitSound( self.DeploySound )
		self:EmitSound( self.ChargeSound )
		
		self:SetRealOwner( self:GetOwner() )
	end
	
	local angles = self:GetAngles()
	
	self:SetBeamDir( angles:Up() )
	self:SetBeamEnd( self:GetPos() + self:GetBeamDir() * TRIPMINE_TRACE_LENGTH )
end

function ENT:WarningThink()
	self.m_pfnThink = self.PowerupThink 
	self:NextThink( CurTime() + 1.0 )
end

function ENT:PowerupThink()

		local tr = util.TraceLine({
			start = self:GetPos() + self:GetBeamDir(),
			endpos = self:GetPos() - self:GetBeamDir(),
			filter = self,
			mask = MASK_SHOT_HULL
		})
		self:SetTripmineOwner( self:GetOwner() )
		self:SetPosOwner( self:GetOwner():GetPos() )
		self:SetAngleOwner( self:GetOwner():GetAngles() )
 
	if CurTime() > self:GetPowerUp() then

		-- make solid
		self:SetSolid( SOLID_BBOX )
		self:SetPos( self:GetPos() )

		self:MakeBeam( )

		self:EmitSound( self.ActivateSound )
	end
	self:NextThink( CurTime() + 0.1 )

end

function ENT:KillBeam()
	if IsValid( self:GetBeam() ) then
		self:GetBeam():Remove()
		self:SetBeam( nil )
	end
end

function ENT:MakeBeam()
	local tr = util.TraceLine({
		start = self:GetPos(),
		endpos = self:GetBeamEnd(),
		filter = self,
		mask = MASK_SOLID_BRUSHONLY
	})
	
	self:SetBeamLength( tr.Fraction )

	self.m_pfnThink = self.BeamBreakThink
	self:NextThink( CurTime() + 0.001 )

	local vecTmpEnd = self:GetPos() + self:GetBeamDir() * TRIPMINE_TRACE_LENGTH * self:GetBeamLength()

	local beam = ents.Create( BeamClassName )
	
	local target = ents.Create( BeamEndClassName )
	target:SetKeyValue( 'targetname', '_tripmine_beam_1_' .. self:EntIndex()  )
	target:SetPos( self:GetPos() )
	target:Spawn()
	target:Activate()
	self:SetBeamEndEntity1( target )
	
	beam:SetKeyValue( 'LightningStart', target:GetName() )
	
	target = ents.Create( BeamEndClassName )
	target:SetKeyValue( 'targetname', '_tripmine_beam_2_' .. self:EntIndex() )
	target:SetPos( vecTmpEnd )
	target:Spawn()
	target:Activate()
	self:SetBeamEndEntity2( target )
	
	beam:SetKeyValue( 'LightningEnd', target:GetName() )
	
	beam:SetKeyValue( 'spawnflags', 1 )
	beam:SetKeyValue( 'life', 0 )
	beam:SetKeyValue( 'BoltWidth', 6 )
	beam:SetKeyValue( 'TextureScroll', 255 )
	beam:SetKeyValue( 'texture', "sprites/laser.spr" )
	beam:SetKeyValue( 'rendercolor', '255, 0, 0' )
	beam:SetKeyValue( 'renderamt', 64 )
	beam:Spawn()
	beam:Activate()
	beam:Input( 'TurnOn', self, self )
	
	self:SetBeam(beam)
end

function ENT:BeamBreakThink()

	local bBlowup = 0;

	local tr = util.TraceLine({
		start = self:GetPos(),
		endpos = self:GetBeamEnd(),
		filter = self,
		mask = MASK_SHOT_HULL
	})

	if !IsValid( self:GetBeam() ) then
		self:MakeBeam()
		if tr.Entity then
			self:SetTripmineOwner( tr.Entity )
		end
	end
	
	/* if math.abs( self:GetBeamLength() - tr.Fraction ) > 0.001 then
		self:Explode()
	end */
	if (tr.Hit && (IsValid(tr.Entity:GetPhysicsObject())) && ( (tr.Entity:IsNPC()) || (tr.Entity:IsPlayer()) || (tr.Entity:IsNextBot())) ) then
		self:Explode()
	end

	/*if (bBlowup == 1) then
		self:SetOwner( self:GetRealOwner() )
		self:SetHealth(0)

		local dmginfo = DamageInfo()
		
		if IsValid( self:GetOwner() ) then
			dmginfo:SetInflictor( self:GetOwner() )
			dmginfo:SetAttacker( self:GetOwner() )
		end
		
		self:Event_Killed( dmginfo )
		return
	end */

	self:NextThink( CurTime() + 0.01 )
end

function ENT:OnTakeDamage( dmginfo )
	timer.Simple(0.2, function()
		if (self:IsValid()) then self:Explode() end
	end)
end

function ENT:Event_Killed( dmginfo )

	-- pev->takedamage = DAMAGE_NO;
	
	if ( IsValid( dmginfo:GetAttacker() ) && (  bit.band( dmginfo:GetAttacker():GetFlags(), FL_CLIENT ) ) ) then
		self:SetOwner( dmginfo:GetAttacker() )
	end

	self.m_pfnThink = self.DelayDeathThink
	self:NextThink( CurTime() + 0.1 )

end

function ENT:DelayDeathThink()

	self:KillBeam();
	local tr = util.TraceLine({
		start = self:GetPos() + self:GetBeamDir() * 8,
		endpos = self:GetPos() - self:GetBeamDir() * 64,
		filter = self,
		mask = MASK_SHOT_HULL
	})
	
	self:Explode()
end

function ENT:Explode()
	local pos = self:WorldSpaceCenter()

	local explo = ents.Create("env_explosion")
	explo:SetOwner(self:GetOwner())
	explo:SetPos(pos)
	explo:SetKeyValue("iMagnitude", 100)
	explo:SetKeyValue("spawnflags", 32)
	explo:Spawn()
	explo:Activate()
	explo:Fire("Explode")

	self:Remove()
end

function ENT:Think()
	if self.m_pfnThink then
		self:m_pfnThink()
		return true
	end
end

function ENT:OnRemove()
	self:KillBeam()
	if IsValid( self:GetBeamEndEntity1() ) then
		self:GetBeamEndEntity1():Remove()
	end
	if IsValid( self:GetBeamEndEntity2() ) then
		self:GetBeamEndEntity2():Remove()
	end
end