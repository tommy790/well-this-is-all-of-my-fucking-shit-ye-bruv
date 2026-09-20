-- AC muzzleflash core.
--
-- Shared by "MysterAC Particle Enhancer" (profile "ac_enhancer") and
-- "CustomVFX Muzzleflash Replacer" (profile "customvfx"). Both addons ship this
-- file; the highest version wins and the other copy returns early, so having
-- both installed gives exactly one set of hooks and no double flashes.
--
-- Shots are event driven:
--   * server: EntityFireBullets (players + NPCs) and projectile creation
--     (RPG, crossbow, SMG grenade, combine ball) -> one small net message to
--     the PVS. The firing player is omitted for bullets because their own
--     client already saw the predicted event.
--   * client: predicted EntityFireBullets + muzzle FireAnimationEvents for the
--     local player, net messages for everyone else, and a Clip1-drop fallback
--     for the local player's non-bullet custom weapons.
-- Every path funnels into AC_Muzzle.Flash(), which dedups per target entity.

local VERSION = 3

if AC_Muzzle and (AC_Muzzle.Version or 0) >= VERSION then return end

AC_Muzzle = AC_Muzzle or {}
AC_Muzzle.Version  = VERSION
AC_Muzzle.Profiles = AC_Muzzle.Profiles or {}

local NET_SHOT   = "AC_MuzzleShot"
local NET_PCF    = "MuzzleReplacer_SyncPCF"
local NET_PNAME  = "MuzzleReplacer_SyncParticleName"

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- Keywords short enough to appear inside unrelated words are matched on
-- alphabetic word boundaries; the rest are plain substring matches.
local STRICT_KEYWORDS = {
    ar2 = true, p90 = true, m16 = true, m60 = true, m9 = true, g36 = true,
    m3 = true, saw = true, sig = true, r8 = true, acr = true, aug = true,
    fal = true, tmp = true, ksg = true, mgl = true, svd = true,
}

local function MatchesWord(name, keyword)
    local start = 1
    while true do
        local s, e = string.find(name, keyword, start, true)
        if not s then return false end
        local leftOk  = s == 1 or not string.match(string.sub(name, s - 1, s - 1), "%a")
        local rightOk = e == #name or not string.match(string.sub(name, e + 1, e + 1), "%a")
        if leftOk and rightOk then return true end
        start = s + 1
    end
end

local function HasKeyword(name, keyword)
    if STRICT_KEYWORDS[keyword] then return MatchesWord(name, keyword) end
    return string.find(name, keyword, 1, true) ~= nil
end

local ENERGY_KEYWORDS = { "ar2", "pulse", "plasma", "laser", "energy", "irifle", "combine_gun", "physcannon" }

local CATEGORY_CHECKS = {
    { "energy",   ENERGY_KEYWORDS },
    { "revolver", { "revolver", "357", "magnum", "python", "deagle", "desert_eagle", "50ae", "handcannon" } },
    { "sniper",   { "sniper", "awp", "awm", "l96", "intervention", "barrett", "m82", "dragunov", "svd", "scout", "mosin", "kar98" } },
    { "launcher", { "rpg", "launcher", "m79", "thumper", "grenade_launcher", "m32", "mgl" } },
    { "shotgun",  { "shotgun", "benelli", "remington870", "r870", "mossberg", "spas", "nova", "xm1014", "sawedoff", "aa12", "ksg", "m3" } },
    { "lmg",      { "m249", "m60", "pkm", "negev", "minigun", "mg42", "rpk", "lmg", "saw" } },
    { "smg",      { "smg", "mp5", "mp7", "mp9", "ump", "uzi", "mac10", "vector", "p90", "bizon", "ppsh", "thompson", "tmp", "smg1" } },
    { "rifle",    { "ak47", "ak74", "m4a1", "m16", "scar", "aug", "famas", "galil", "g36", "fal", "ar15", "hk416", "acr", "rifle", "tar21", "tar-21", "tavor", "qbz", "l85", "sa80", "f2000", "groza", "an94", "aek" } },
    { "pistol",   { "pistol", "glock", "beretta", "m9", "1911", "usp", "p226", "fiveseven", "sig", "makarov", "walther", "luger", "cz75", "p250", "tec9", "r8" } },
}

AC_Muzzle.Categories = { "pistol", "revolver", "smg", "shotgun", "rifle", "sniper", "lmg", "launcher", "energy" }
AC_Muzzle.CategoryNames = {
    pistol = "Pistols", revolver = "Revolvers / Magnums", smg = "SMGs", shotgun = "Shotguns",
    rifle = "Rifles", sniper = "Snipers", lmg = "LMGs / Machine Guns", launcher = "Launchers",
    energy = "Energy / AR2",
}

local categoryCache = {}

function AC_Muzzle.IsEnergyWeapon(class)
    if not isstring(class) then return false end
    local name = string.lower(class)
    for _, kw in ipairs(ENERGY_KEYWORDS) do
        if HasKeyword(name, kw) then return true end
    end
    return false
end

function AC_Muzzle.IsSuppressedWeapon(class)
    if not isstring(class) then return false end
    local name = string.lower(class)
    for _, kw in ipairs({ "silenced", "suppressed", "supressed", "silencer", "_sd", "-sd" }) do
        if string.find(name, kw, 1, true) then return true end
    end
    return string.sub(name, -2) == "sd"
end

function AC_Muzzle.DetectCategory(class)
    if not isstring(class) then return "pistol" end
    local cached = categoryCache[class]
    if cached then return cached end

    local name = string.lower(class)
    local result = "pistol"
    for _, check in ipairs(CATEGORY_CHECKS) do
        for _, kw in ipairs(check[2]) do
            if HasKeyword(name, kw) then
                result = check[1]
                break
            end
        end
        if result ~= "pistol" then break end
    end
    categoryCache[class] = result
    return result
end

AC_Muzzle.MeleeNPCKeywords = {
    "zombie", "antlion", "headcrab", "crab", "bullsquid", "ichthyosaur",
    "manhack", "scanner", "rollermine", "turret", "strider", "hunter",
    "helicopter", "gunship", "pigeon", "seagull", "crow", "houndeye",
}

function AC_Muzzle.GetNPCWeaponClass(npc)
    if not IsValid(npc) then return nil end
    local wep = npc:GetActiveWeapon()
    if IsValid(wep) then return wep:GetClass() end

    local cls = string.lower(npc:GetClass())
    for _, kw in ipairs(AC_Muzzle.MeleeNPCKeywords) do
        if string.find(cls, kw, 1, true) then return nil end
    end
    if string.find(cls, "combine", 1, true) then
        return string.find(cls, "elite", 1, true) and "weapon_ar2" or "weapon_smg1"
    elseif string.find(cls, "metropolice", 1, true) or string.find(cls, "alyx", 1, true) or string.find(cls, "barney", 1, true) then
        return "weapon_pistol"
    elseif string.find(cls, "monk", 1, true) or string.find(cls, "grigori", 1, true) then
        return "weapon_shotgun"
    end
    return "weapon_smg1"
end

-- Attachment ids are cached per model; LookupAttachment on every shot for a
-- list of a dozen names adds up on miniguns.
local ATTACH_NAMES = {
    "muzzle", "muzzle_flash", "muzzle_attachment", "muzzle1", "muzzle_01",
    "muzzle_flash1", "muzzle_flash_01", "muzzle_attach", "muzzle2", "flash", "1",
}
local attachCache = {}

function AC_Muzzle.GetMuzzleAttachment(ent)
    if not IsValid(ent) then return 0 end
    local model = ent:GetModel() or ""
    local cached = attachCache[model]
    if cached ~= nil then return cached end

    local id = 0
    for _, name in ipairs(ATTACH_NAMES) do
        local found = ent:LookupAttachment(name)
        if found and found > 0 then
            id = found
            break
        end
    end
    if id == 0 and ent:GetAttachment(1) then id = 1 end

    -- Models without attachment data at all are not cached: attachments only
    -- become available once the model is actually loaded on this realm.
    if id > 0 or #ent:GetAttachments() > 0 then
        attachCache[model] = id
    end
    return id
end

-- ---------------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------------

local function CopyTable(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

-- def fields:
--   id, name, priority, command, dataFiles = { weapon, class, category, pcf,
--   names, settings, categorySmoke }, defaults = { category, weaponFixed, alt,
--   altSmoke, weaponSmoke, categorySmoke, smokeParticle, suppressedParticle,
--   noSmoke, particles, settings }
function AC_Muzzle.RegisterProfile(def)
    local p = AC_Muzzle.Profiles[def.id]
    if not p then
        p = { id = def.id }
        AC_Muzzle.Profiles[def.id] = p
    end
    p.name      = def.name
    p.priority  = def.priority or 0
    p.command   = def.command
    p.dataFiles = def.dataFiles
    p.defaults  = def.defaults

    -- Live config tables. Re-registration on autorefresh keeps the same table
    -- objects so the legacy global aliases stay valid.
    p.weapon        = p.weapon        or {}
    p.class         = p.class         or {}
    p.category      = p.category      or CopyTable(def.defaults.category)
    p.pcfFiles      = p.pcfFiles      or {}
    p.particleNames = p.particleNames or {}
    p.settings      = p.settings      or CopyTable(def.defaults.settings)
    p.categorySmoke = p.categorySmoke or {}
    p.available     = p.available     or {}
    p.loaded        = p.loaded or false

    for k, v in pairs(def.defaults.settings) do
        if p.settings[k] == nil then p.settings[k] = v end
    end

    if CLIENT and not p.loaded then
        AC_Muzzle.LoadProfile(p)
    end
    return p
end

function AC_Muzzle.GetActiveProfile()
    local wanted = CLIENT and GetConVar("ac_muzzle_profile") and GetConVar("ac_muzzle_profile"):GetString() or "auto"
    if wanted ~= "auto" and AC_Muzzle.Profiles[wanted] then
        return AC_Muzzle.Profiles[wanted]
    end
    local best
    for _, p in pairs(AC_Muzzle.Profiles) do
        if not best or p.priority > best.priority then best = p end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- Server
-- ---------------------------------------------------------------------------

if SERVER then
    util.AddNetworkString(NET_SHOT)
    util.AddNetworkString(NET_PCF)
    util.AddNetworkString(NET_PNAME)

    local cvNet = CreateConVar("ac_muzzle_net_enabled", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
        "Broadcast NPC / other-player shot events for client muzzleflash replacement", 0, 1)

    -- shooter entity, weapon entity, kind: 0 primary, 1 alt/projectile
    local function SendShot(shooter, wep, kind, omit)
        if not cvNet:GetBool() or not IsValid(shooter) then return end
        local filter = RecipientFilter()
        filter:AddPVS(shooter:GetPos())
        if IsValid(omit) and omit:IsPlayer() then filter:RemovePlayer(omit) end
        if filter:GetCount() == 0 then return end

        net.Start(NET_SHOT, true)
            net.WriteEntity(shooter)
            net.WriteEntity(IsValid(wep) and wep or NULL)
            net.WriteUInt(kind, 1)
        net.Send(filter)
    end
    AC_Muzzle.SendShot = SendShot

    hook.Add("EntityFireBullets", "AC_Muzzle_FireBullets", function(ent, data)
        if not IsValid(ent) then return end
        local shooter, wep = ent, nil
        if ent:IsWeapon() then
            shooter = ent:GetOwner()
            wep = ent
        end
        if not IsValid(shooter) then return end
        if shooter:IsPlayer() or shooter:IsNPC() or shooter:IsNextBot() then
            if not IsValid(wep) then wep = shooter:GetActiveWeapon() end
            SendShot(shooter, wep, 0, shooter)
        end
    end)

    -- Non-bullet weapons never call FireBullets; their projectile appearing is
    -- the shot. Owner is assigned after Spawn(), hence the zero-delay timer.
    local PROJECTILES = {
        rpg_missile       = 0,
        crossbow_bolt     = 0,
        grenade_ar2       = 1,
        prop_combine_ball = 1,
    }

    hook.Add("OnEntityCreated", "AC_Muzzle_Projectiles", function(ent)
        local kind = PROJECTILES[ent:GetClass()]
        if not kind then return end
        timer.Simple(0, function()
            if not IsValid(ent) then return end
            local owner = ent:GetOwner()
            if not IsValid(owner) and ent.GetThrower then owner = ent:GetThrower() end
            if not IsValid(owner) then return end
            if not (owner:IsPlayer() or owner:IsNPC()) then return end
            SendShot(owner, owner:GetActiveWeapon(), kind, nil)
        end)
    end)

    -- Custom PCF sharing (admin driven, replayed to late joiners).
    local syncedPCFs, syncedNames = {}, {}
    local lastRequest = {}

    local function Throttled(ply, key, delay)
        local sid = ply:SteamID64() or ply:SteamID()
        lastRequest[sid] = lastRequest[sid] or {}
        local last = lastRequest[sid][key] or 0
        if CurTime() - last < delay then return true end
        lastRequest[sid][key] = CurTime()
        return false
    end

    net.Receive(NET_PCF, function(_, ply)
        if not IsValid(ply) or not ply:IsAdmin() then return end
        if Throttled(ply, "pcf", 1) then return end
        local path = net.ReadString()
        if path == "" or #path > 256 then return end
        if not string.StartWith(path, "particles/") or not string.EndsWith(path, ".pcf") then return end
        if string.find(path, "..", 1, true) or string.find(path, "//", 1, true) then return end
        if syncedPCFs[path] then return end
        syncedPCFs[path] = true
        game.AddParticles(path)
        net.Start(NET_PCF) net.WriteString(path) net.SendOmit(ply)
    end)

    net.Receive(NET_PNAME, function(_, ply)
        if not IsValid(ply) or not ply:IsAdmin() then return end
        if Throttled(ply, "name", 0.1) then return end
        local name = net.ReadString()
        if name == "" or #name > 128 then return end
        if syncedNames[name] then return end
        syncedNames[name] = true
        PrecacheParticleSystem(name)
        net.Start(NET_PNAME) net.WriteString(name) net.SendOmit(ply)
    end)

    hook.Add("PlayerInitialSpawn", "AC_Muzzle_ReplaySync", function(ply)
        timer.Simple(2, function()
            if not IsValid(ply) then return end
            for path in pairs(syncedPCFs) do
                net.Start(NET_PCF) net.WriteString(path) net.Send(ply)
            end
            for name in pairs(syncedNames) do
                net.Start(NET_PNAME) net.WriteString(name) net.Send(ply)
            end
        end)
    end)

    hook.Add("PlayerDisconnected", "AC_Muzzle_ForgetThrottle", function(ply)
        lastRequest[ply:SteamID64() or ply:SteamID()] = nil
    end)

    return
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

local cvDisabled = CreateClientConVar("cl_ac_muzzleflash_disabled", "0", true, false,
    "Set to 1 to disable all custom muzzleflash replacement")
CreateClientConVar("ac_muzzle_profile", "auto", true, false,
    "Which muzzleflash profile drives replacement: auto, ac_enhancer or customvfx")

local function Enabled()
    return not cvDisabled:GetBool()
end

-- Precache results are cached including failures so a missing system is not
-- retried per shot.
local precached = {}
function AC_Muzzle.Precache(name)
    if not isstring(name) or name == "" or name == "none" then return false end
    local c = precached[name]
    if c ~= nil then return c end
    local ok, res = pcall(PrecacheParticleSystem, name)
    precached[name] = ok and res ~= false
    return precached[name]
end

-- ---- persistence ---------------------------------------------------------

local function ReadJSON(path)
    if not file.Exists(path, "DATA") then return nil end
    return util.JSONToTable(file.Read(path, "DATA") or "")
end

local function WriteJSON(path, tbl)
    local json = util.TableToJSON(tbl)
    if json then file.Write(path, json) end
end

function AC_Muzzle.LoadProfile(p)
    local f = p.dataFiles
    local weapon = ReadJSON(f.weapon)
    if weapon then p.weapon = weapon end
    for k, v in pairs(ReadJSON(f.class) or {}) do p.class[k] = v end
    for k, v in pairs(ReadJSON(f.category) or {}) do p.category[k] = v end
    local pcfs = ReadJSON(f.pcf)
    if istable(pcfs) then
        -- customvfx stored { [path] = {names} }; ac_enhancer stored a list.
        local list, names = {}, {}
        for k, v in pairs(pcfs) do
            if isnumber(k) and isstring(v) then
                list[#list + 1] = v
            elseif isstring(k) and string.EndsWith(k, ".pcf") then
                list[#list + 1] = k
                if istable(v) then
                    for _, n in ipairs(v) do names[#names + 1] = n end
                end
            end
        end
        p.pcfFiles = list
        for _, n in ipairs(names) do
            if not table.HasValue(p.particleNames, n) then p.particleNames[#p.particleNames + 1] = n end
        end
    end
    if f.names then
        local names = ReadJSON(f.names)
        if istable(names) then
            for _, n in ipairs(names) do
                if isstring(n) and not table.HasValue(p.particleNames, n) then
                    p.particleNames[#p.particleNames + 1] = n
                end
            end
        end
    end
    if f.settings then
        for k, v in pairs(ReadJSON(f.settings) or {}) do p.settings[k] = v end
    end
    if f.categorySmoke then
        local cs = ReadJSON(f.categorySmoke)
        if istable(cs) then p.categorySmoke = cs end
    end
    p.loaded = true
    AC_Muzzle.ScanProfile(p)
end

function AC_Muzzle.SaveProfile(p)
    local f = p.dataFiles
    WriteJSON(f.weapon, p.weapon)
    WriteJSON(f.class, p.class)
    WriteJSON(f.category, p.category)
    WriteJSON(f.pcf, p.pcfFiles)
    if f.names then WriteJSON(f.names, p.particleNames) end
    if f.settings then WriteJSON(f.settings, p.settings) end
    if f.categorySmoke then WriteJSON(f.categorySmoke, p.categorySmoke) end
end

function AC_Muzzle.ScanProfile(p)
    for _, path in ipairs(p.pcfFiles) do
        if file.Exists(path, "GAME") then game.AddParticles(path) end
    end

    local seen, list = {}, {}
    local function add(name)
        if isstring(name) and name ~= "" and name ~= "none" and not seen[name] then
            seen[name] = true
            list[#list + 1] = name
            AC_Muzzle.Precache(name)
        end
    end
    for _, n in ipairs(p.defaults.particles or {}) do add(n) end
    for _, n in ipairs(p.particleNames) do add(n) end
    for _, n in pairs(p.weapon) do add(n) end
    for _, n in pairs(p.class) do add(n) end
    for _, n in pairs(p.category) do add(n) end
    if p.settings.custom_smoke_particle and p.settings.custom_smoke_particle ~= "" then
        add(p.settings.custom_smoke_particle)
    end
    table.sort(list, function(a, b) return string.lower(a) < string.lower(b) end)
    p.available = list
    return list
end

function AC_Muzzle.AutoApplyAll(p)
    for _, tbl in pairs(weapons.GetList()) do
        local cls = tbl.ClassName
        if cls and not (p.defaults.weaponFixed and p.defaults.weaponFixed[cls]) and not p.weapon[cls] then
            local cat = AC_Muzzle.DetectCategory(cls)
            if p.category[cat] then p.weapon[cls] = p.category[cat] end
        end
    end
    AC_Muzzle.SaveProfile(p)
end

-- ---- resolution ----------------------------------------------------------

function AC_Muzzle.GetParticle(p, class, isAlt)
    if not isstring(class) then return "none" end
    local d = p.defaults

    if isAlt and d.alt and d.alt[class] and d.alt[class] ~= "" then
        return d.alt[class]
    end
    if d.weaponFixed and d.weaponFixed[class] then return d.weaponFixed[class] end
    if p.weapon[class] then return p.weapon[class] end
    if p.class[class] then return p.class[class] end

    local lower = string.lower(class)
    for pattern, particle in pairs(p.class) do
        if pattern ~= class and string.find(lower, string.lower(pattern), 1, true) then
            return particle
        end
    end
    if d.suppressedParticle and AC_Muzzle.IsSuppressedWeapon(class) then
        return d.suppressedParticle
    end
    local cat = AC_Muzzle.DetectCategory(class)
    return p.category[cat] or d.fallback or "AC_muzzle_pistol"
end

function AC_Muzzle.GetSmoke(p, class, particle, isAlt, isViewmodel)
    local s = p.settings
    if s.barrel_smoke_enabled == false then return nil end
    if s.barrel_smoke_mode == "never" then return nil end
    if isViewmodel and s.viewmodel_smoke == false then return nil end
    if not isViewmodel and s.worldmodel_smoke == false then return nil end
    if not particle or particle == "none" then return nil end

    local d = p.defaults
    if isAlt and d.altSmoke and d.altSmoke[class] ~= nil then
        local alt = d.altSmoke[class]
        return (alt ~= "none" and alt ~= "") and alt or nil
    end
    if d.weaponSmoke and d.weaponSmoke[class] ~= nil then
        local ws = d.weaponSmoke[class]
        return (ws ~= "none" and ws ~= "") and ws or nil
    end
    if s.barrel_smoke_mode == "custom" and s.custom_smoke_particle and s.custom_smoke_particle ~= "" then
        return s.custom_smoke_particle
    end
    if s.barrel_smoke_mode ~= "always" then
        if d.noSmoke and d.noSmoke[particle] then return nil end
        if AC_Muzzle.IsSuppressedWeapon(class) then return nil end
    end
    local cat = AC_Muzzle.DetectCategory(class)
    if p.categorySmoke[cat] == false then return nil end
    local smoke = d.categorySmoke and d.categorySmoke[cat]
    if smoke == nil then smoke = d.smokeParticle end
    if smoke == "none" or smoke == "" then return nil end
    return smoke
end

-- Weapon bases that draw their own particle muzzle effects.
local NATIVE_PCF_BASES = {
    arccw_base = true, arc9_base = true, tfa_gun_base = true, fas2_base = true,
    bobs_gun_base = true, css_gun_base = true, mg_base = true,
}

function AC_Muzzle.WeaponUsesNativePCF(p, wep)
    if not IsValid(wep) then return false end
    if p.settings.respect_native_muzzle == false then return false end
    local class = wep:GetClass()
    if p.weapon[class] then return false end

    if isstring(wep.MuzzleEffect) and wep.MuzzleEffect ~= "" then return true end
    if wep.Primary and isstring(wep.Primary.MuzzleEffect) and wep.Primary.MuzzleEffect ~= "" then return true end
    if isfunction(wep.GetMuzzleEffect) then
        local ok, eff = pcall(wep.GetMuzzleEffect, wep)
        if ok and isstring(eff) and eff ~= "" then return true end
    end
    if NATIVE_PCF_BASES[wep.Base or ""] or NATIVE_PCF_BASES[class] then return true end
    if wep.ArcCW or wep.ARC9 or wep.IsTFAWeapon then return true end
    return false
end

-- ---- spawning ------------------------------------------------------------

local lastFlash = setmetatable({}, { __mode = "k" }) -- target -> CurTime
local lastSmoke = setmetatable({}, { __mode = "k" }) -- target -> { name, time }
local DEDUP_WINDOW = 0.03

local function IsFirstPerson(ply)
    return IsValid(ply) and ply == LocalPlayer() and ply:GetViewEntity() == ply and not ply:ShouldDrawLocalPlayer()
end

-- Returns the entity + attachment the particles should follow for a shooter.
function AC_Muzzle.ResolveTarget(shooter, wep)
    if not IsValid(shooter) then return nil, 0 end
    if IsFirstPerson(shooter) then
        local vm = shooter:GetViewModel()
        if IsValid(vm) then
            local att = AC_Muzzle.GetMuzzleAttachment(vm)
            if att > 0 then return vm, att, true end
        end
    end
    if IsValid(wep) then
        local att = AC_Muzzle.GetMuzzleAttachment(wep)
        if att > 0 then return wep, att, false end
    end
    if shooter:IsPlayer() then
        local hand = shooter:LookupAttachment("anim_attachment_RH")
        if hand and hand > 0 then return shooter, hand, false end
    else
        local att = AC_Muzzle.GetMuzzleAttachment(shooter)
        if att > 0 then return shooter, att, false end
    end
    return nil, 0
end

local function SpawnSmoke(p, target, att, smoke)
    local prev = lastSmoke[target]
    local now = CurTime()
    local minInterval = tonumber(p.settings.smoke_cooldown) or 0.3
    if prev then
        if now - prev.time < minInterval then return end
        -- Replace rather than stack: a burst should read as one smoke column.
        target:StopParticlesNamed(prev.name)
    end
    if not AC_Muzzle.Precache(smoke) then return end
    ParticleEffectAttach(smoke, PATTACH_POINT_FOLLOW, target, att)
    lastSmoke[target] = { name = smoke, time = now }
end

-- opts: { alt = bool, window = number }
function AC_Muzzle.Flash(shooter, wep, opts)
    if not Enabled() then return false end
    local p = AC_Muzzle.GetActiveProfile()
    if not p then return false end
    if not IsValid(shooter) then return false end
    opts = opts or {}

    if shooter:IsNPC() or shooter:IsNextBot() then
        if p.settings.npc_muzzle_enabled == false then return false end
    end

    if not IsValid(wep) then wep = shooter:GetActiveWeapon() end
    local class
    if IsValid(wep) then
        class = wep:GetClass()
        if AC_Muzzle.WeaponUsesNativePCF(p, wep) then return false end
    else
        class = AC_Muzzle.GetNPCWeaponClass(shooter)
    end
    if not class then return false end

    local particle = AC_Muzzle.GetParticle(p, class, opts.alt)
    if not particle or particle == "none" then return true end

    local target, att, isViewmodel = AC_Muzzle.ResolveTarget(shooter, wep)
    if not IsValid(target) or att <= 0 then return false end

    local now = CurTime()
    local last = lastFlash[target]
    if last and now - last < (opts.window or DEDUP_WINDOW) then return true end
    lastFlash[target] = now

    if AC_Muzzle.Precache(particle) then
        ParticleEffectAttach(particle, PATTACH_POINT_FOLLOW, target, att)
    end

    local smoke = AC_Muzzle.GetSmoke(p, class, particle, opts.alt, isViewmodel)
    if smoke then SpawnSmoke(p, target, att, smoke) end
    return true
end

-- True when the active profile would replace this shooter's flash, i.e. the
-- stock engine flash must be suppressed for it.
local function Replaces(shooter)
    if not Enabled() then return false end
    local p = AC_Muzzle.GetActiveProfile()
    if not p or not IsValid(shooter) then return false end
    local wep = shooter.GetActiveWeapon and shooter:GetActiveWeapon()
    local class = IsValid(wep) and wep:GetClass() or AC_Muzzle.GetNPCWeaponClass(shooter)
    if not class then return false end
    if IsValid(wep) and AC_Muzzle.WeaponUsesNativePCF(p, wep) then return false end
    if (shooter:IsNPC() or shooter:IsNextBot()) and p.settings.npc_muzzle_enabled == false then return false end
    return AC_Muzzle.GetParticle(p, class, false) ~= "none"
end
AC_Muzzle.Replaces = Replaces

-- ---- stock flash suppression --------------------------------------------

do
    local META = FindMetaTable("Entity")
    AC_Muzzle._origMuzzleFlash = AC_Muzzle._origMuzzleFlash or META.MuzzleFlash
    local orig = AC_Muzzle._origMuzzleFlash
    META.MuzzleFlash = function(self)
        if Replaces(self) then return end
        return orig(self)
    end
end

local MUZZLE_EVENTS = {
    [5001] = true, [5003] = true, [5004] = true, [5011] = true, [5021] = true, [5031] = true,
    [20] = true, [21] = true, [22] = true, [6001] = true, [6002] = true,
    [3014] = true, [3015] = true, [3016] = true, [7001] = true, [7002] = true,
}

hook.Add("FireAnimationEvent", "AC_Muzzle_AnimEvent", function(ent, pos, ang, event)
    if not MUZZLE_EVENTS[event] then return end
    if not IsValid(ent) then return end

    local owner = ent:GetOwner()
    if not IsValid(owner) then
        if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() then owner = ent end
    end
    if not IsValid(owner) then return end
    if not Replaces(owner) then return end

    -- Only the local player's own event is a spawn trigger; everyone else is
    -- driven by the server event so one shot never becomes two flashes.
    if owner == LocalPlayer() then
        AC_Muzzle.Flash(owner, owner:GetActiveWeapon(), { alt = false })
    end
    return true
end)

-- ---- triggers ------------------------------------------------------------

hook.Add("EntityFireBullets", "AC_Muzzle_PredictedShot", function(ent)
    if not IsFirstTimePredicted() then return end
    if not IsValid(ent) then return end
    local shooter, wep = ent, nil
    if ent:IsWeapon() then
        shooter = ent:GetOwner()
        wep = ent
    end
    if shooter ~= LocalPlayer() then return end
    AC_Muzzle.Flash(shooter, wep or shooter:GetActiveWeapon(), { alt = false })
end)

net.Receive(NET_SHOT, function()
    local shooter = net.ReadEntity()
    local wep = net.ReadEntity()
    local kind = net.ReadUInt(1)
    if not IsValid(shooter) then return end
    -- Projectile events reach the owner too; a wider window absorbs the case
    -- where the owner's anim event already flashed.
    AC_Muzzle.Flash(shooter, wep, { alt = kind == 1, window = kind == 1 and 0.15 or DEDUP_WINDOW })
end)

-- Local-player fallback for custom weapons that neither FireBullets nor spawn
-- a known projectile class. Clip1 is compared once per frame for one weapon.
do
    local trackedWep, trackedClip
    local reloadUntil = 0

    hook.Add("Think", "AC_Muzzle_LocalAmmoFallback", function()
        if not Enabled() then return end
        local ply = LocalPlayer()
        if not IsValid(ply) or not ply:Alive() then return end
        local wep = ply:GetActiveWeapon()
        if not IsValid(wep) then trackedWep = nil return end

        if wep ~= trackedWep then
            trackedWep = wep
            trackedClip = wep:Clip1()
            return
        end

        local clip = wep:Clip1()
        if clip < 0 then return end
        local now = CurTime()

        if ply:KeyDown(IN_RELOAD) or wep:GetInternalVariable("m_bInReload") == true
            or (isfunction(wep.GetReloading) and wep:GetReloading()) then
            reloadUntil = now + 1
        end

        if clip < trackedClip and now > reloadUntil then
            local last = lastFlash[ply:GetViewModel()] or lastFlash[wep] or 0
            if now - last > 0.1 then
                AC_Muzzle.Flash(ply, wep, { alt = ply:KeyDown(IN_ATTACK2) and not ply:KeyDown(IN_ATTACK) })
            end
        end
        trackedClip = clip
    end)
end

net.Receive(NET_PCF, function()
    local path = net.ReadString()
    if path ~= "" and file.Exists(path, "GAME") then game.AddParticles(path) end
end)

net.Receive(NET_PNAME, function()
    local name = net.ReadString()
    if name == "" then return end
    AC_Muzzle.Precache(name)
    local p = AC_Muzzle.GetActiveProfile()
    if p and not table.HasValue(p.available, name) then
        p.available[#p.available + 1] = name
    end
end)

hook.Add("InitPostEntity", "AC_Muzzle_Init", function()
    for _, p in pairs(AC_Muzzle.Profiles) do
        AC_Muzzle.ScanProfile(p)
    end
end)

-- ---------------------------------------------------------------------------
-- Configurator UI (one implementation, parametrised by profile)
-- ---------------------------------------------------------------------------

local function Notify(text)
    chat.AddText(Color(100, 200, 255), "[Muzzleflash] ", color_white, text)
end

local function ParticlePicker(parent, p, onPick)
    local scroll = vgui.Create("DScrollPanel", parent)
    scroll:Dock(FILL)
    scroll:DockMargin(5, 5, 5, 5)

    local none = vgui.Create("DButton", scroll)
    none:Dock(TOP) none:SetTall(28) none:DockMargin(5, 2, 5, 2)
    none:SetText("none (disable muzzleflash)")
    none:SetTextColor(Color(255, 100, 100))
    none.DoClick = function() onPick("none") end

    local reset = vgui.Create("DButton", scroll)
    reset:Dock(TOP) reset:SetTall(28) reset:DockMargin(5, 2, 5, 2)
    reset:SetText("Reset to default (use category)")
    reset:SetTextColor(Color(100, 255, 100))
    reset.DoClick = function() onPick(nil) end

    for _, name in ipairs(p.available) do
        local b = vgui.Create("DButton", scroll)
        b:Dock(TOP) b:SetTall(26) b:DockMargin(5, 1, 5, 1)
        b:SetText(name)
        b.DoClick = function() onPick(name) end
    end
    return scroll
end

function AC_Muzzle.OpenConfigurator(p)
    if not p then return end

    local frame = vgui.Create("DFrame")
    frame:SetSize(920, 700)
    frame:Center()
    frame:SetTitle(p.name .. " - Configuration")
    frame:MakePopup()
    frame:SetDeleteOnClose(true)

    local tabs = vgui.Create("DPropertySheet", frame)
    tabs:Dock(FILL)

    local function Save() AC_Muzzle.SaveProfile(p) end

    -- Settings -------------------------------------------------------------
    do
        local pnl = vgui.Create("DPanel", tabs)
        pnl.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(30, 30, 30)) end
        local form = vgui.Create("DForm", pnl)
        form:Dock(FILL) form:DockMargin(10, 10, 10, 10)
        form:SetName("General")

        form:CheckBox("Disable all muzzleflash replacement", "cl_ac_muzzleflash_disabled")

        local profCombo = form:ComboBox("Active profile", "ac_muzzle_profile")
        profCombo:AddChoice("auto (highest priority installed)", "auto")
        for id, prof in SortedPairs(AC_Muzzle.Profiles) do profCombo:AddChoice(prof.name, id) end

        local function Toggle(label, key)
            local cb = form:CheckBox(label)
            cb:SetChecked(p.settings[key] ~= false)
            cb.OnChange = function(_, v) p.settings[key] = v Save() end
        end
        Toggle("Barrel smoke enabled", "barrel_smoke_enabled")
        Toggle("Smoke on viewmodel", "viewmodel_smoke")
        Toggle("Smoke on world models", "worldmodel_smoke")
        Toggle("NPC muzzleflashes", "npc_muzzle_enabled")
        Toggle("Skip weapons that already emit their own particle muzzleflash (ArcCW, TFA, ...)", "respect_native_muzzle")

        local mode = form:ComboBox("Smoke mode")
        for _, m in ipairs({ "auto", "always", "never", "custom" }) do mode:AddChoice(m, m) end
        mode:SetValue(p.settings.barrel_smoke_mode or "auto")
        mode.OnSelect = function(_, _, _, data) p.settings.barrel_smoke_mode = data Save() end

        local custom = form:TextEntry("Custom smoke particle")
        custom:SetValue(p.settings.custom_smoke_particle or "")
        custom.OnEnter = function(s)
            p.settings.custom_smoke_particle = string.Trim(s:GetValue())
            Save() AC_Muzzle.ScanProfile(p)
        end

        local cd = form:NumSlider("Minimum seconds between smoke columns", nil, 0, 2, 2)
        cd:SetValue(p.settings.smoke_cooldown or 0.3)
        cd.OnValueChanged = function(_, v) p.settings.smoke_cooldown = math.Round(v, 2) Save() end

        tabs:AddSheet("Settings", pnl, "icon16/cog.png")
    end

    -- Categories -----------------------------------------------------------
    do
        local pnl = vgui.Create("DPanel", tabs)
        pnl.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(30, 30, 30)) end
        local scroll = vgui.Create("DScrollPanel", pnl)
        scroll:Dock(FILL) scroll:DockMargin(10, 10, 10, 10)

        for _, cat in ipairs(AC_Muzzle.Categories) do
            local row = vgui.Create("DPanel", scroll)
            row:Dock(TOP) row:SetTall(40) row:DockMargin(0, 0, 0, 5)
            row.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(50, 50, 50)) end

            local lbl = vgui.Create("DLabel", row)
            lbl:SetPos(10, 10) lbl:SetText(AC_Muzzle.CategoryNames[cat]) lbl:SetFont("DermaDefaultBold") lbl:SizeToContents()

            local combo = vgui.Create("DComboBox", row)
            combo:SetPos(200, 8) combo:SetSize(350, 24)
            combo:SetValue(p.category[cat] or "none")
            combo:AddChoice("none")
            for _, name in ipairs(p.available) do combo:AddChoice(name) end
            combo.OnSelect = function(_, _, v) p.category[cat] = v Save() end

            local smoke = vgui.Create("DCheckBoxLabel", row)
            smoke:SetPos(570, 12) smoke:SetText("Barrel smoke")
            smoke:SetChecked(p.categorySmoke[cat] ~= false)
            smoke.OnChange = function(_, v) p.categorySmoke[cat] = v Save() end
        end

        local apply = vgui.Create("DButton", pnl)
        apply:Dock(BOTTOM) apply:SetTall(35) apply:DockMargin(10, 0, 10, 10)
        apply:SetText("Apply categories to all known weapons")
        apply.DoClick = function()
            p.weapon = {}
            AC_Muzzle.AutoApplyAll(p)
            Notify("Applied category defaults to all weapons.")
        end
        tabs:AddSheet("Categories", pnl, "icon16/chart_organisation.png")
    end

    -- Weapons --------------------------------------------------------------
    do
        local pnl = vgui.Create("DPanel", tabs)
        pnl.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(30, 30, 30)) end

        local list = vgui.Create("DListView", pnl)
        list:Dock(LEFT) list:SetWide(380) list:DockMargin(10, 10, 5, 10)
        list:AddColumn("Weapon class") list:AddColumn("Particle")
        list:SetMultiSelect(false)

        local selected
        local function Refresh()
            list:Clear()
            local all = {}
            for _, tbl in pairs(weapons.GetList()) do
                if tbl.ClassName then all[tbl.ClassName] = true end
            end
            for _, ply in ipairs(player.GetAll()) do
                for _, w in ipairs(ply:GetWeapons()) do all[w:GetClass()] = true end
            end
            for class in SortedPairs(all) do
                local particle = AC_Muzzle.GetParticle(p, class, false)
                list:AddLine(class, p.weapon[class] and (particle .. " (custom)") or particle)
            end
        end
        list.OnRowSelected = function(_, _, row) selected = row:GetColumnText(1) end

        local right = vgui.Create("DPanel", pnl)
        right:Dock(FILL) right:DockMargin(5, 10, 10, 10)
        right.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(40, 40, 40)) end
        local lbl = vgui.Create("DLabel", right)
        lbl:Dock(TOP) lbl:DockMargin(10, 10, 10, 5)
        lbl:SetText("Select a weapon, then click a particle to assign:") lbl:SetFont("DermaDefaultBold") lbl:SizeToContents()

        ParticlePicker(right, p, function(name)
            if not selected then return end
            p.weapon[selected] = name
            Save() Refresh()
            Notify(selected .. " -> " .. tostring(name or "default"))
        end)

        local refresh = vgui.Create("DButton", pnl)
        refresh:Dock(BOTTOM) refresh:SetTall(30) refresh:DockMargin(10, 0, 10, 10)
        refresh:SetText("Refresh weapon list")
        refresh.DoClick = Refresh
        Refresh()
        tabs:AddSheet("Weapons", pnl, "icon16/gun.png")
    end

    -- Patterns -------------------------------------------------------------
    do
        local pnl = vgui.Create("DPanel", tabs)
        pnl.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(30, 30, 30)) end
        local header = vgui.Create("DLabel", pnl)
        header:Dock(TOP) header:DockMargin(10, 10, 10, 5)
        header:SetText("Any weapon class containing the pattern uses the assigned particle. Right click a row to remove it.")
        header:SetFont("DermaDefaultBold") header:SizeToContents()

        local list = vgui.Create("DListView", pnl)
        list:Dock(FILL) list:DockMargin(10, 5, 10, 5)
        list:AddColumn("Pattern") list:AddColumn("Particle")
        local function Refresh()
            list:Clear()
            for pattern, particle in SortedPairs(p.class) do list:AddLine(pattern, particle) end
        end
        list.OnRowRightClick = function(_, _, row)
            local menu = DermaMenu()
            menu:AddOption("Remove", function() p.class[row:GetColumnText(1)] = nil Save() Refresh() end)
            menu:Open()
        end

        local ctrl = vgui.Create("DPanel", pnl)
        ctrl:Dock(BOTTOM) ctrl:SetTall(30) ctrl:DockMargin(10, 0, 10, 10)
        ctrl.Paint = nil
        local input = vgui.Create("DTextEntry", ctrl)
        input:Dock(LEFT) input:SetWide(220) input:SetPlaceholderText("pattern (e.g. ak47)")
        local combo = vgui.Create("DComboBox", ctrl)
        combo:Dock(LEFT) combo:SetWide(280) combo:DockMargin(5, 0, 0, 0)
        combo:SetValue("Select particle") combo:AddChoice("none")
        for _, name in ipairs(p.available) do combo:AddChoice(name) end
        local add = vgui.Create("DButton", ctrl)
        add:Dock(LEFT) add:SetWide(100) add:DockMargin(5, 0, 0, 0) add:SetText("Add pattern")
        add.DoClick = function()
            local pat = string.Trim(input:GetValue())
            local _, particle = combo:GetSelected()
            if pat == "" or not particle then return end
            p.class[pat] = particle
            Save() Refresh() input:SetValue("")
        end
        Refresh()
        tabs:AddSheet("Patterns", pnl, "icon16/script.png")
    end

    -- PCF manager ----------------------------------------------------------
    do
        local pnl = vgui.Create("DPanel", tabs)
        pnl.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(30, 30, 30)) end

        local function Section(title, items, placeholder, onAdd, onRemove)
            local lbl = vgui.Create("DLabel", pnl)
            lbl:Dock(TOP) lbl:DockMargin(10, 10, 10, 5) lbl:SetText(title) lbl:SetFont("DermaDefaultBold") lbl:SizeToContents()
            local list = vgui.Create("DListView", pnl)
            list:Dock(TOP) list:SetTall(150) list:DockMargin(10, 0, 10, 5)
            list:AddColumn(title)
            local function Refresh()
                list:Clear()
                for _, v in ipairs(items()) do list:AddLine(v) end
            end
            list.OnRowRightClick = function(_, _, row)
                local menu = DermaMenu()
                menu:AddOption("Remove", function() onRemove(row:GetColumnText(1)) Refresh() end)
                menu:Open()
            end
            local ctrl = vgui.Create("DPanel", pnl)
            ctrl:Dock(TOP) ctrl:SetTall(28) ctrl:DockMargin(10, 0, 10, 5) ctrl.Paint = nil
            local input = vgui.Create("DTextEntry", ctrl)
            input:Dock(FILL) input:DockMargin(0, 0, 5, 0) input:SetPlaceholderText(placeholder)
            local btn = vgui.Create("DButton", ctrl)
            btn:Dock(RIGHT) btn:SetWide(100) btn:SetText("Add")
            btn.DoClick = function()
                local v = string.Trim(input:GetValue())
                if v == "" then return end
                onAdd(v) input:SetValue("") Refresh()
            end
            Refresh()
        end

        Section("Custom PCF files", function() return p.pcfFiles end, "particles/my_effects.pcf",
            function(path)
                if not string.EndsWith(path, ".pcf") then path = path .. ".pcf" end
                if not string.StartWith(path, "particles/") then path = "particles/" .. path end
                if table.HasValue(p.pcfFiles, path) then return end
                if not file.Exists(path, "GAME") then
                    Derma_Message("File not found: " .. path, "PCF Manager", "OK")
                    return
                end
                p.pcfFiles[#p.pcfFiles + 1] = path
                game.AddParticles(path)
                Save() AC_Muzzle.ScanProfile(p)
                if LocalPlayer():IsAdmin() then
                    net.Start(NET_PCF) net.WriteString(path) net.SendToServer()
                end
            end,
            function(path)
                table.RemoveByValue(p.pcfFiles, path)
                Save() AC_Muzzle.ScanProfile(p)
            end)

        Section("Custom particle names", function() return p.particleNames end, "my_particle_name",
            function(name)
                name = string.gsub(name, "%.pcf$", "")
                if table.HasValue(p.particleNames, name) then return end
                p.particleNames[#p.particleNames + 1] = name
                Save() AC_Muzzle.ScanProfile(p)
                if LocalPlayer():IsAdmin() then
                    net.Start(NET_PNAME) net.WriteString(name) net.SendToServer()
                end
            end,
            function(name)
                table.RemoveByValue(p.particleNames, name)
                Save() AC_Muzzle.ScanProfile(p)
            end)

        tabs:AddSheet("PCF Manager", pnl, "icon16/folder.png")
    end

    -- Test lab -------------------------------------------------------------
    do
        local pnl = vgui.Create("DPanel", tabs)
        pnl.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(30, 30, 30)) end
        local row = vgui.Create("DPanel", pnl)
        row:Dock(TOP) row:SetTall(35) row:DockMargin(10, 10, 10, 5) row.Paint = nil
        local entry = vgui.Create("DTextEntry", row)
        entry:Dock(LEFT) entry:SetWide(350) entry:SetPlaceholderText("particle name to test")
        local function Test(atMuzzle)
            local name = string.Trim(entry:GetValue())
            if name == "" or not AC_Muzzle.Precache(name) then
                Notify("Unknown particle: " .. name)
                return
            end
            local ply = LocalPlayer()
            if atMuzzle then
                local target, att = AC_Muzzle.ResolveTarget(ply, ply:GetActiveWeapon())
                if IsValid(target) and att > 0 then
                    ParticleEffectAttach(name, PATTACH_POINT_FOLLOW, target, att)
                    return
                end
            end
            ParticleEffect(name, ply:GetPos() + Vector(0, 0, 50), angle_zero)
        end
        local b1 = vgui.Create("DButton", row)
        b1:Dock(LEFT) b1:SetWide(110) b1:DockMargin(10, 0, 0, 0) b1:SetText("Test at feet")
        b1.DoClick = function() Test(false) end
        local b2 = vgui.Create("DButton", row)
        b2:Dock(LEFT) b2:SetWide(110) b2:DockMargin(10, 0, 0, 0) b2:SetText("Test at muzzle")
        b2.DoClick = function() Test(true) end
        tabs:AddSheet("Test Lab", pnl, "icon16/eye.png")
    end

    -- Info / reset ---------------------------------------------------------
    do
        local pnl = vgui.Create("DPanel", tabs)
        pnl.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(30, 30, 30)) end
        local text = vgui.Create("DLabel", pnl)
        text:Dock(TOP) text:DockMargin(20, 20, 20, 10) text:SetWrap(true) text:SetAutoStretchVertical(true)
        text:SetText([[
Priority order when picking a particle:
1. Fixed HL2 weapon table (profile default)
2. Per-weapon override (Weapons tab)
3. Class pattern match (Patterns tab)
4. Category default (Categories tab)

Shots are detected from the server for NPCs and other players and predicted locally for your own weapon, so every shooter gets exactly one flash. Barrel smoke follows the category / smoke mode settings.]])

        local reset = vgui.Create("DButton", pnl)
        reset:Dock(BOTTOM) reset:SetTall(40) reset:DockMargin(50, 0, 50, 20)
        reset:SetText("RESET ALL SETTINGS TO DEFAULT") reset:SetTextColor(Color(255, 100, 100))
        reset.DoClick = function()
            Derma_Query("Reset all muzzleflash settings for " .. p.name .. "?", "Reset", "Yes", function()
                table.Empty(p.weapon) table.Empty(p.class) table.Empty(p.pcfFiles)
                table.Empty(p.particleNames) table.Empty(p.categorySmoke)
                table.Empty(p.category)
                for k, v in pairs(p.defaults.category) do p.category[k] = v end
                table.Empty(p.settings)
                for k, v in pairs(p.defaults.settings) do p.settings[k] = v end
                Save() AC_Muzzle.ScanProfile(p)
                frame:Close()
                Notify("Settings reset.")
            end, "Cancel", function() end)
        end
        tabs:AddSheet("Info / Reset", pnl, "icon16/information.png")
    end
end
