AddCSLuaFile();

// Precache
if SERVER then
	game.AddParticles("particles/AC_explosions.pcf")
end

if CLIENT then
	game.AddParticles("particles/AC_explosions.pcf")
	PrecacheParticleSystem("AC_grenade_explosion")
	PrecacheParticleSystem("AC_grenade_explosion_air")
	PrecacheParticleSystem("AC_rpg_explosion")
	PrecacheParticleSystem("AC_rpg_explosion_air")
end