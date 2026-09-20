--@diagnostic disable: undefined-global, lowercase-global
AddCSLuaFile();

-- Precache
if SERVER then
	game.AddParticles("particles/AC_enhancer.pcf")
	game.AddParticles("particles/impacts_fx.pcf")
	game.AddParticles("particles/burning_fx.pcf")
	game.AddParticles("particles/blood_impact.pcf")
end

if CLIENT then
	game.AddParticles("particles/AC_enhancer.pcf")
	game.AddParticles("particles/impacts_fx.pcf")
	game.AddParticles("particles/burning_fx.pcf")
	game.AddParticles("particles/blood_impact.pcf")
	PrecacheParticleSystem("impact_concrete")
	PrecacheParticleSystem("impact_metal")
	PrecacheParticleSystem("impact_computer")
	PrecacheParticleSystem("impact_dirt")
	PrecacheParticleSystem("impact_wood")
	PrecacheParticleSystem("impact_glass")
	PrecacheParticleSystem("impact_antlion")
	PrecacheParticleSystem("AC_grenade_explosion")
	PrecacheParticleSystem("AC_grenade_explosion_air")
	PrecacheParticleSystem("AC_rpg_explosion")
	PrecacheParticleSystem("AC_rpg_explosion_air")
	PrecacheParticleSystem("AC_muzzle_357")
	PrecacheParticleSystem("AC_muzzle_ar2")
	PrecacheParticleSystem("AC_muzzle_pistol")
	PrecacheParticleSystem("AC_muzzle_shotgun")
	PrecacheParticleSystem("AC_muzzle_smg")
end