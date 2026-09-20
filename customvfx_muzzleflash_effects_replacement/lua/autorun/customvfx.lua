AddCSLuaFile()

CustomVFX = CustomVFX or {}

if CLIENT then
    game.AddParticles("particles/ac_mw_handguns.pcf") -- CustomVFX
	game.AddParticles("particles/ar2_flash.pcf") -- CustomVFX
	game.AddParticles("particles/procharge.pcf") -- CustomVFX
	game.AddParticles("particles/pulsepistol.pcf") -- CustomVFX
	game.AddParticles("particles/rpg.pcf") -- CustomVFX
end

if SERVER then
    game.AddParticles("particles/ac_mw_handguns.pcf") -- CustomVFX
	game.AddParticles("particles/ar2_flash.pcf") -- CustomVFX
	game.AddParticles("particles/procharge.pcf") -- CustomVFX
	game.AddParticles("particles/pulsepistol.pcf") -- CustomVFX
	game.AddParticles("particles/rpg.pcf") -- CustomVFX
end

-- UwU 