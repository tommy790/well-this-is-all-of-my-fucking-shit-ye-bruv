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
	self:SetMaxHealth( 1 )
	self:SetHealth( 1 )

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
	local owner = self:GetOwner()
	if IsValid( owner ) then
		self:SetTripmineOwner( owner )
		self:SetPosOwner( owner:GetPos() )
		self:SetAngleOwner( owner:GetAngles() )
	end

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
	local tr = util.TraceLine({
		start = self:GetPos(),
		endpos = self:GetBeamEnd(),
		filter = self,
		mask = MASK_SHOT_HULL
	})

	if !IsValid( self:GetBeam() ) then
		self:MakeBeam()
	end

	local ent = tr.Entity
	if tr.Hit && IsValid( ent ) && ( ent:IsNPC() || ent:IsPlayer() || ent:IsNextBot() ) then
		self:Explode()
		return
	end

	-- Beam blocked/shortened by a prop or door: HL1 behaviour, trips the mine.
	if math.abs( self:GetBeamLength() - tr.Fraction ) > 0.01 && tr.Fraction < self:GetBeamLength() then
		self:Explode()
		return
	end

	self:NextThink( CurTime() + 0.05 )
end

function ENT:OnTakeDamage( dmginfo )
	if self.dying then return end
	self.dying = true
	local attacker = dmginfo:GetAttacker()
	if IsValid( attacker ) && attacker:IsPlayer() then
		self:SetOwner( attacker )
	end
	timer.Simple(0.2, function()
		if IsValid( self ) then self:Explode() end
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
	self:KillBeam()
	self:Explode()
end

function ENT:Explode()
	if self.exploded then return end
	self.exploded = true

	local explo = ents.Create("env_explosion")
	if IsValid( explo ) then
		explo:SetPos( self:WorldSpaceCenter() )
		local owner = self:GetRealOwner()
		if !IsValid( owner ) then owner = self:GetOwner() end
		if IsValid( owner ) then explo:SetOwner( owner ) end
		explo:SetKeyValue( "iMagnitude", tostring( self:GetBlastDamage() ) )
		explo:SetKeyValue( "iRadiusOverride", tostring( self:GetBlastRadius() ) )
		explo:SetKeyValue( "spawnflags", "32" )
		explo:Spawn()
		explo:Activate()
		explo:Fire( "Explode" )
		explo:Fire( "Kill", "", 1 )
	end

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