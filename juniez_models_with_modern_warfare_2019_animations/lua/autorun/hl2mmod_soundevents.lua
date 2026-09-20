
-- default settings
local defaultSoundTable = {
	channel = CHAN_AUTO, 
	volume = 1,
	level = 60, 
	pitchstart = 100,
	pitchend = 100,
	name = "noName",
	sound = "path/to/sound"
}

local fireSoundTable = {
	channel = CHAN_AUTO, 
	volume = 1,
	level = 97, 
	pitchstart = 92,
	pitchend = 112,
	name = "noName",
	sound = "path/to/sound"
}

local muteSoundTable = {
	channel = CHAN_AUTO, 
	volume = 0.001,
	level = 60, 
	pitchstart = 100,
	pitchend = 100,
	name = "noName",
	sound = "hl1/fvox/_comma.wav"
}

-- "<" makes the sound directional, refer to https://developer.valvesoftware.com/wiki/Soundscripts#Sound_Characters
local function makeSoundDirectional(snd)
	if type(snd) == "table" then
		for key, sound in ipairs(snd) do
			snd[key] = "<" .. sound
		end
	else
		snd = "<" .. snd
	end
	
	return snd
end

local function addDefaultSound(name, snd)
	snd = makeSoundDirectional(snd)
	
	defaultSoundTable.name = name
	defaultSoundTable.sound = snd

	sound.Add(defaultSoundTable)
	
	-- precache the registered sounds
	if type(defaultSoundTable.sound) == "table" then
		for k, v in pairs(defaultSoundTable.sound) do
			util.PrecacheSound(v)
		end
	else
		util.PrecacheSound(snd)
	end
end

local function addFireSound(name, snd, volume, soundLevel, channel, pitchStart, pitchEnd, noDirection)
	-- use defaults if no args are provided
	volume = volume or 1
	soundLevel = soundLevel or 97
	channel = channel or CHAN_AUTO
	pitchStart = pitchStart or 92
	pitchEnd = pitchEnd or 112
	
	if not noDirection then
		snd = makeSoundDirectional(snd)
	end
	
	fireSoundTable.name = name
	fireSoundTable.sound = snd
	
	fireSoundTable.channel = channel
	fireSoundTable.volume = volume
	fireSoundTable.level = soundLevel
	fireSoundTable.pitchstart = pitchStart
	fireSoundTable.pitchend = pitchEnd
	
	sound.Add(fireSoundTable)
	
	-- precache the registered sounds
	
	if type(fireSoundTable.sound) == "table" then
		for k, v in pairs(fireSoundTable.sound) do
			util.PrecacheSound(v)
		end
	else
		util.PrecacheSound(snd)
	end
end

local function muteSound(name)	
	muteSoundTable.name = name
	sound.Add(muteSoundTable)
end


// muted some HL2 sounds because they keep playing even if they should not
muteSound("Weapon_Pistol.Reload")
muteSound("Weapon_SMG1.Reload")
muteSound("Weapon_Shotgun.Special1")


// reload/other sounds
addDefaultSound("pistol.draw", "weapons/pistol/draw.wav")
addDefaultSound("pistol.back", "weapons/pistol/back.wav")
addDefaultSound("pistol.release", "weapons/pistol/release.wav")
addDefaultSound("pistol.out", "weapons/pistol/out.wav")
addDefaultSound("pistol.in", "weapons/pistol/in.wav")
addDefaultSound("pistol.inspect11", "weapons/pistol/inspect1.wav")
addDefaultSound("pistol.inspect12", "weapons/pistol/inspect2.wav")
addDefaultSound("pistol.inspect13", "weapons/pistol/inspect3.wav")
addDefaultSound("pistol.inspect14", "weapons/pistol/inspect4.wav")

addDefaultSound("357.draw", "weapons/357/draw.wav")
addDefaultSound("357.open", "weapons/357/open.wav")
addDefaultSound("357.close", "weapons/357/close.wav")
addDefaultSound("357.out", "weapons/357/out.wav")
addDefaultSound("357.in", "weapons/357/in.wav")
addDefaultSound("357.inspect11", "weapons/357/inspect1.wav")
addDefaultSound("357.inspect12", "weapons/357/inspect2.wav")
addDefaultSound("357.inspect13", "weapons/357/inspect3.wav")
addDefaultSound("357.inspect14", "weapons/357/inspect4.wav")

addDefaultSound("smg1.draw", "weapons/smg1/draw.wav")
addDefaultSound("smg1.back", "weapons/smg1/back.wav")
addDefaultSound("smg1.release", "weapons/smg1/release.wav")
addDefaultSound("smg1.inspect12", "weapons/smg1/inspect2.wav")
addDefaultSound("smg1.out", "weapons/smg1/out.wav")
addDefaultSound("smg1.in", "weapons/smg1/in.wav")
addDefaultSound("smg1.button", "weapons/smg1/button.wav")
addDefaultSound("smg1.inspect11", "weapons/smg1/inspect1.wav")
addDefaultSound("smg1.inspect13", "weapons/smg1/inspect3.wav")

addDefaultSound("ar2.draw", "weapons/ar2/draw.wav")
addDefaultSound("ar2.out", "weapons/ar2/out.wav")
addDefaultSound("ar2.in", "weapons/ar2/in.wav")
addDefaultSound("ar2.hit", "weapons/ar2/hit.wav")
addDefaultSound("ar2.inspect12", "weapons/ar2/inspect2.wav")
addDefaultSound("drop", "weapons/ar2/inspect4.wav")
addDefaultSound("ar2.inspect13", "weapons/ar2/inspect3.wav")
addDefaultSound("ar2.back", "weapons/ar2/back.wav")
addDefaultSound("ar2.inspect11", "weapons/ar2/inspect1.wav")
addDefaultSound("ar2.inspect15", "weapons/ar2/inspect5.wav")

addDefaultSound("shotgun.draw", "weapons/shotgun/draw.wav")
addDefaultSound("shotgun.back", "weapons/shotgun/back.wav")
addDefaultSound("shotgun.release", "weapons/shotgun/release.wav")
addDefaultSound("shotgun.inspect2", "weapons/shotgun/inspect2.wav")
addDefaultSound("shotgun.insert1", "weapons/shotgun/insert1.wav")
addDefaultSound("shotgun.insert2", "weapons/shotgun/insert2.wav")
addDefaultSound("shotgun.insert3", "weapons/shotgun/insert3.wav")
addDefaultSound("shotgun.inspect1", "weapons/shotgun/inspect1.wav")
addDefaultSound("shotgun.inspect3", "weapons/shotgun/inspect3.wav")
addDefaultSound("shotgun.inspect5", "weapons/shotgun/inspect5.wav")

addDefaultSound("crossbow.draw", "weapons/crossbow/draw.wav")
addDefaultSound("crossbow.inspect11", "weapons/crossbow/inspect1.wav")
addDefaultSound("crossbow.inspect12", "weapons/crossbow/inspect2.wav")
addDefaultSound("crossbow.inspect13", "weapons/crossbow/inspect3.wav")
addDefaultSound("crossbow.inspect15", "weapons/crossbow/inspect5.wav")

addDefaultSound("rpg.draw", "weapons/rpg/draw.wav")
addDefaultSound("rpg.lift", "weapons/rpg/lift.wav")
addDefaultSound("rpg.insert", "weapons/rpg/insert.wav")
addDefaultSound("rpg.load", "weapons/rpg/load.wav")
addDefaultSound("rpg.insert1", "weapons/rpg/insert1.wav")
addDefaultSound("rpg.inspect11", "weapons/rpg/inspect1.wav")
addDefaultSound("rpg.inspect12", "weapons/rpg/inspect2.wav")
addDefaultSound("rpg.inspect13", "weapons/rpg/inspect3.wav")

addDefaultSound("grenade.pinpull", "weapons/grenade/pinpull.wav")
addDefaultSound("grenade.throw", "weapons/grenade/throw.wav")
addDefaultSound("grenade.draw", "weapons/grenade/draw.wav")

addDefaultSound("Equipment_Rock.Raise", "weapons/bugbait/draw.wav")
