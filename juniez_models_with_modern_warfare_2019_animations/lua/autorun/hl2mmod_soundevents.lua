-- Sound events used by the MW2019 viewmodel animations (fired from the
-- models' animation events). Registered on both realms so server-side
-- EmitSound calls resolve the same names.

AddCSLuaFile()

local sounds = {
    { "pistol.draw", "weapons/pistol/draw.wav" },
    { "pistol.back", "weapons/pistol/back.wav" },
    { "pistol.release", "weapons/pistol/release.wav" },
    { "pistol.out", "weapons/pistol/out.wav" },
    { "pistol.in", "weapons/pistol/in.wav" },
    { "pistol.inspect11", "weapons/pistol/inspect1.wav" },
    { "pistol.inspect12", "weapons/pistol/inspect2.wav" },
    { "pistol.inspect13", "weapons/pistol/inspect3.wav" },
    { "pistol.inspect14", "weapons/pistol/inspect4.wav" },
    { "357.draw", "weapons/357/draw.wav" },
    { "357.open", "weapons/357/open.wav" },
    { "357.close", "weapons/357/close.wav" },
    { "357.out", "weapons/357/out.wav" },
    { "357.in", "weapons/357/in.wav" },
    { "357.inspect11", "weapons/357/inspect1.wav" },
    { "357.inspect12", "weapons/357/inspect2.wav" },
    { "357.inspect13", "weapons/357/inspect3.wav" },
    { "357.inspect14", "weapons/357/inspect4.wav" },
    { "smg1.draw", "weapons/smg1/draw.wav" },
    { "smg1.back", "weapons/smg1/back.wav" },
    { "smg1.release", "weapons/smg1/release.wav" },
    { "smg1.inspect12", "weapons/smg1/inspect2.wav" },
    { "smg1.out", "weapons/smg1/out.wav" },
    { "smg1.in", "weapons/smg1/in.wav" },
    { "smg1.button", "weapons/smg1/button.wav" },
    { "smg1.inspect11", "weapons/smg1/inspect1.wav" },
    { "smg1.inspect13", "weapons/smg1/inspect3.wav" },
    { "ar2.draw", "weapons/ar2/draw.wav" },
    { "ar2.out", "weapons/ar2/out.wav" },
    { "ar2.in", "weapons/ar2/in.wav" },
    { "ar2.hit", "weapons/ar2/hit.wav" },
    { "ar2.inspect12", "weapons/ar2/inspect2.wav" },
    { "drop", "weapons/ar2/inspect4.wav" },
    { "ar2.inspect13", "weapons/ar2/inspect3.wav" },
    { "ar2.back", "weapons/ar2/back.wav" },
    { "ar2.inspect11", "weapons/ar2/inspect1.wav" },
    { "ar2.inspect15", "weapons/ar2/inspect5.wav" },
    { "shotgun.draw", "weapons/shotgun/draw.wav" },
    { "shotgun.back", "weapons/shotgun/back.wav" },
    { "shotgun.release", "weapons/shotgun/release.wav" },
    { "shotgun.inspect2", "weapons/shotgun/inspect2.wav" },
    { "shotgun.insert1", "weapons/shotgun/insert1.wav" },
    { "shotgun.insert2", "weapons/shotgun/insert2.wav" },
    { "shotgun.insert3", "weapons/shotgun/insert3.wav" },
    { "shotgun.inspect1", "weapons/shotgun/inspect1.wav" },
    { "shotgun.inspect3", "weapons/shotgun/inspect3.wav" },
    { "shotgun.inspect5", "weapons/shotgun/inspect5.wav" },
    { "crossbow.draw", "weapons/crossbow/draw.wav" },
    { "crossbow.inspect11", "weapons/crossbow/inspect1.wav" },
    { "crossbow.inspect12", "weapons/crossbow/inspect2.wav" },
    { "crossbow.inspect13", "weapons/crossbow/inspect3.wav" },
    { "crossbow.inspect15", "weapons/crossbow/inspect5.wav" },
    { "rpg.draw", "weapons/rpg/draw.wav" },
    { "rpg.lift", "weapons/rpg/lift.wav" },
    { "rpg.insert", "weapons/rpg/insert.wav" },
    { "rpg.load", "weapons/rpg/load.wav" },
    { "rpg.insert1", "weapons/rpg/insert1.wav" },
    { "rpg.inspect11", "weapons/rpg/inspect1.wav" },
    { "rpg.inspect12", "weapons/rpg/inspect2.wav" },
    { "rpg.inspect13", "weapons/rpg/inspect3.wav" },
    { "grenade.pinpull", "weapons/grenade/pinpull.wav" },
    { "grenade.throw", "weapons/grenade/throw.wav" },
    { "grenade.draw", "weapons/grenade/draw.wav" },
    { "Equipment_Rock.Raise", "weapons/bugbait/draw.wav" },
}

for _, s in ipairs(sounds) do
    sound.Add({
        name = s[1],
        channel = CHAN_AUTO,
        volume = 1,
        level = 60,
        pitch = 100,
        sound = "<" .. s[2], -- "<" makes the sound directional
    })
    util.PrecacheSound(s[2])
end

-- These stock HL2 events are baked into the engine weapons and would double
-- up with the animation-event sounds above, so they are silenced.
for _, name in ipairs({ "Weapon_Pistol.Reload", "Weapon_SMG1.Reload", "Weapon_Shotgun.Special1" }) do
    sound.Add({
        name = name,
        channel = CHAN_AUTO,
        volume = 0.001,
        level = 60,
        pitch = 100,
        sound = "hl1/fvox/_comma.wav",
    })
end
