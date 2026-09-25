--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : muzzle attachment resolution (client-side)

    Given the firing entity and the shot origin from the EffectData, returns
    the attachment id the flash/smoke should be parented to.

    Where positions are measured
      Attachment positions are NOT read from the rendered vehicle. Each
      vehicle gets a hidden reference copy of its model whose hull never
      moves; only the turret and gun pose is copied onto it, once per shot,
      and then frozen. The shot origin is carried over to that reference
      relative to the live attachment it is nearest to, so hull speed and
      turret motion between fire and resolve cancel out. All distance tests
      below run against that frozen reference.

    How the id is chosen (first match wins)
      1. The attachment id LVS put in the EffectData, if it is close to the
         shot origin and no other attachment is clearly closer. (LVS often
         sends a stale base-model id here -- id 1 on the 2S1 is a suspension
         attachment.)
      2. LVS's own muzzle attachment (ent.TurretBallisticsMuzzleAttachment),
         if close. If another attachment is clearly closer, that one fired
         instead -- multi-gun turrets only name one muzzle (BMD-4M: "muzzle"
         is the autocannon, the cannon fires from a different attachment).
      3. Nearest attachment whose name contains "muzzle" or "barrel".
      4. Nearest attachment of any name inside a strict radius.
      5. Nothing -> id 0; the caller spawns at the world position.

    Names come from GetAttachments(); GetAttachment(id) only returns Pos/Ang.

    The shot origin is only used to FIND the attachment. The particle is
    always parented to the real vehicle with PATTACH_POINT_FOLLOW.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config

-- Tolerances (units). LVS fires from the attachment position itself, so a
-- genuine muzzle is within a few units of the shot origin.
local MAX_EFFECTDATA_DIST = 24
local MAX_NAMED_DIST      = 32   -- allows a little turret-pivot offset
local MAX_GENERIC_DIST    = 24
local CLEARLY_CLOSER      = 4    -- another attachment must beat the candidate by this much
-- An attachment this close to the shot origin IS the barrel tip. Only such an
-- attachment may override LVS's named muzzle (BMD-4M: the cannon tip is a
-- misnamed "sight"; the autocannon shot is 8u from it and must not use it).
local AT_BARREL_DIST      = 3

local function isMuzzleName(name)
    if not isstring(name) then return false end
    local lower = string.lower(name)
    return string.find(lower, "muzzle", 1, true) ~= nil
        or string.find(lower, "barrel", 1, true) ~= nil
end

--[[---------------------------------------------------------------------------
    Per-entity attachment list. Invalidated when the model changes so a
    toolgun model swap can never leave stale ids behind.
-----------------------------------------------------------------------------]]
local function GetCache(ent)
    local model = ent:GetModel()

    local cache = ent._lvsGredMuzzleCache
    if cache and cache.model == model then return cache end

    local atts = nil
    if ent.GetAttachments then
        local ok, res = pcall(ent.GetAttachments, ent)
        if ok and istable(res) then atts = res end
    end

    local named, nameById = {}, {}
    if atts then
        for i = 1, #atts do
            local id = atts[i] and atts[i].id
            local name = atts[i] and atts[i].name
            if id and id > 0 then
                nameById[id] = name or ""
                if isMuzzleName(name) then named[#named + 1] = id end
            end
        end
    end

    cache = {
        model     = model,
        atts      = atts,
        named     = named,
        nameById  = nameById,
        lvsNameId = nil,
        lvsName   = nil,
        guns      = {},   -- gunKey -> attachment id remembered from that gun's first shot
    }

    ent._lvsGredMuzzleCache = cache
    return cache
end

local function attachmentName(cache, attID)
    return cache and cache.nameById and cache.nameById[attID] or ""
end

local function lookupLvsMuzzleId(ent, cache)
    local name = ent.TurretBallisticsMuzzleAttachment

    if not isstring(name) or name == "" then
        cache.lvsName, cache.lvsNameId = nil, nil
        return 0
    end

    if cache.lvsName == name then
        return cache.lvsNameId or 0
    end

    cache.lvsName = name

    if not ent.LookupAttachment then
        cache.lvsNameId = 0
        return 0
    end

    local ok, id = pcall(ent.LookupAttachment, ent, name)
    cache.lvsNameId = (ok and id and id > 0) and id or 0
    return cache.lvsNameId
end

--[[---------------------------------------------------------------------------
    Frozen reference model, one per vehicle.
-----------------------------------------------------------------------------]]
local REF_ORIGIN  = Vector(0, 0, -30000)
local SHOT_WINDOW = 0.05   -- fire events closer together share one captured pose
local REFS = setmetatable({}, { __mode = "k" })   -- vehicle -> { ent, model, shot }

-- Set while a resolve runs so GetAttachmentData reads the reference.
local ACTIVE_REF, ACTIVE_VEH = nil, nil

local function dropRef(veh)
    local r = REFS[veh]
    if r and IsValid(r.ent) then r.ent:Remove() end
    REFS[veh] = nil
end

hook.Add("OnReloaded", "lvs_gred_fx_muzzle_refs", function()
    for veh in pairs(REFS) do dropRef(veh) end
end)
hook.Add("EntityRemoved", "lvs_gred_fx_muzzle_refs", function(ent)
    if REFS[ent] then dropRef(ent) end
end)
timer.Create("lvs_gred_fx_muzzle_refs_sweep", 10, 0, function()
    for veh in pairs(REFS) do
        if not IsValid(veh) then dropRef(veh) end
    end
end)

-- Copies only the turret/gun pose; the hull stays parked. Turret values are
-- taken from LVS's own accessors and written the way sh_turret.lua writes
-- them (reading the normalised pose parameter back wraps at +-180).
local function captureTurretPose(ref, veh)
    ref:SetPos(REF_ORIGIN)
    ref:SetAngles(angle_zero)

    local yawName, pitchName = veh.TurretYawPoseParameterName, veh.TurretPitchPoseParameterName
    if isstring(yawName) and yawName ~= "" and veh.GetTurretYaw then
        ref:SetPoseParameter(yawName, (veh.TurretYawOffset or 0) + (veh:GetTurretYaw() or 0) * (veh.TurretYawMul or 1))
    end
    if isstring(pitchName) and pitchName ~= "" and veh.GetTurretPitch then
        ref:SetPoseParameter(pitchName, (veh.TurretPitchOffset or 0) + (veh:GetTurretPitch() or 0) * (veh.TurretPitchMul or 1))
    end

    -- LVS bone pose parameters (gun elevation / recoil) are bone manipulations.
    local bones = veh:GetBoneCount() or 0
    if bones == ref:GetBoneCount() then
        for b = 0, bones - 1 do
            local a = veh:GetManipulateBoneAngles(b) or angle_zero
            if ref:GetManipulateBoneAngles(b) ~= a then ref:ManipulateBoneAngles(b, a) end
            local pos = veh:GetManipulateBonePosition(b) or vector_origin
            if ref:GetManipulateBonePosition(b) ~= pos then ref:ManipulateBonePosition(b, pos) end
        end
    end

    for i = 0, (veh:GetNumBodyGroups() or 1) - 1 do
        local bg = veh:GetBodygroup(i)
        if ref:GetBodygroup(i) ~= bg then ref:SetBodygroup(i, bg) end
    end

    ref:InvalidateBoneCache()
    ref:SetupBones()
end

local function referenceFor(veh, shotId)
    local model = veh:GetModel()
    local r = REFS[veh]
    if r and (not IsValid(r.ent) or r.model ~= model) then
        dropRef(veh)
        r = nil
    end
    if not r then
        local ent = ClientsideModel(model, RENDERGROUP_OTHER)
        if not IsValid(ent) then return nil end
        ent:SetNoDraw(true)
        ent:DrawShadow(false)
        ent:SetPos(REF_ORIGIN)
        ent:SetAngles(angle_zero)
        r = { ent = ent, model = model, shot = nil }
        REFS[veh] = r
    end
    if r.shot ~= shotId then
        captureTurretPose(r.ent, veh)
        r.shot = shotId
    end
    return r.ent
end

-- Shot origin -> the same point on the frozen reference, expressed relative
-- to the live attachment it is nearest to (hull and turret motion cancel
-- out because that attachment moved with them).
local function toReferenceSpace(veh, ref, worldPos)
    if veh.SetupBones then pcall(veh.SetupBones, veh) end
    local ok, atts = pcall(veh.GetAttachments, veh)
    local bestId, bestD, bestAtt = nil, math.huge, nil
    if ok and istable(atts) then
        for i = 1, #atts do
            local id = atts[i].id
            if id and id > 0 then
                local ok2, att = pcall(veh.GetAttachment, veh, id)
                if ok2 and att and isvector(att.Pos) and isangle(att.Ang) then
                    local d = att.Pos:DistToSqr(worldPos)
                    if d < bestD then bestD, bestId, bestAtt = d, id, att end
                end
            end
        end
    end
    if bestId and bestD <= 128 * 128 then
        local ok3, refAtt = pcall(ref.GetAttachment, ref, bestId)
        if ok3 and refAtt and isvector(refAtt.Pos) and isangle(refAtt.Ang) then
            local off = WorldToLocal(worldPos, angle_zero, bestAtt.Pos, bestAtt.Ang)
            return LocalToWorld(off, angle_zero, refAtt.Pos, refAtt.Ang)
        end
    end
    -- Nothing near: fall back to the vehicle's network (server) transform.
    local org = veh.GetNetworkOrigin and veh:GetNetworkOrigin() or nil
    local ang = veh.GetNetworkAngles and veh:GetNetworkAngles() or nil
    if not isvector(org) or org == vector_origin then org = veh:GetPos() end
    if not isangle(ang) then ang = veh:GetAngles() end
    return REF_ORIGIN + WorldToLocal(worldPos, angle_zero, org, ang)
end

--[[---------------------------------------------------------------------------
    Public helpers.
-----------------------------------------------------------------------------]]

-- Position/angle of an attachment (Pos/Ang only); nil on any failure. While
-- a resolve is running for `ent`, reads come from its frozen reference.
function LVS_GRED_FX.GetAttachmentData(ent, attID)
    if not IsValid(ent) or not ent.GetAttachment then return nil end
    if not attID or attID <= 0 then return nil end

    local src = ent
    if ent == ACTIVE_VEH and IsValid(ACTIVE_REF) then
        src = ACTIVE_REF
    elseif ent.SetupBones then
        pcall(ent.SetupBones, ent)
    end

    local ok, att = pcall(src.GetAttachment, src, attID)
    if not ok or not att or not att.Pos or not isvector(att.Pos) then
        return nil
    end

    return att
end

function LVS_GRED_FX.ValidAttachment(ent, attID)
    return LVS_GRED_FX.GetAttachmentData(ent, attID) ~= nil
end

function LVS_GRED_FX.AttachmentName(ent, attID)
    if not IsValid(ent) or not attID or attID <= 0 then return "?" end
    local name = attachmentName(GetCache(ent), attID)
    return name ~= "" and name or "?"
end

-- Vehicle root for an entity (gunner pods -> their base vehicle).
function LVS_GRED_FX.VehicleRoot(ent)
    if not IsValid(ent) then return nil end
    if ent.GetVehicle then
        local base = ent:GetVehicle()
        if IsValid(base) then return base end
    end
    return ent
end

--[[---------------------------------------------------------------------------
    Resolver.
-----------------------------------------------------------------------------]]

-- Nearest attachment to `pos` other than `exceptId`. Returns id, distSqr.
local function nearestOther(ent, cache, pos, exceptId, limitSqr)
    local bestId, bestD = 0, limitSqr
    if not cache.atts then return bestId, bestD end
    for i = 1, #cache.atts do
        local id = cache.atts[i] and cache.atts[i].id
        if id and id > 0 and id ~= exceptId then
            local att = LVS_GRED_FX.GetAttachmentData(ent, id)
            if att then
                local d = att.Pos:DistToSqr(pos)
                if d < bestD then bestD, bestId = d, id end
            end
        end
    end
    return bestId, bestD
end

-- Nearest attachment from a list of ids. Returns id, distSqr.
local function nearestOf(ent, ids, pos, limitSqr)
    local bestId, bestD = 0, limitSqr
    for i = 1, #ids do
        local id = ids[i]
        local att = LVS_GRED_FX.GetAttachmentData(ent, id)
        if att then
            local d = att.Pos:DistToSqr(pos)
            if d < bestD then bestD, bestId = d, id end
        end
    end
    return bestId, bestD
end

local function result(cache, id, method, distSqr)
    return id, { method = method, dist = math.sqrt(distSqr), name = attachmentName(cache, id) }
end

local function resolveImpl(ent, muzzlePos, effectDataAtt)
    if cfg.DebugEnabled() and debugoverlay and debugoverlay.Box then
        local boxPos = (ent == ACTIVE_VEH) and ent:LocalToWorld(muzzlePos - REF_ORIGIN) or muzzlePos
        debugoverlay.Box(boxPos, Vector(MAX_NAMED_DIST, MAX_NAMED_DIST, MAX_NAMED_DIST), 0.5, Color(0, 100, 255, 60))
    end

    local cache = GetCache(ent)

    -- 1) EffectData attachment id.
    if effectDataAtt and effectDataAtt > 0 then
        local att = LVS_GRED_FX.GetAttachmentData(ent, effectDataAtt)
        if att then
            local distSqr = att.Pos:DistToSqr(muzzlePos)
            if distSqr <= MAX_EFFECTDATA_DIST * MAX_EFFECTDATA_DIST then
                local _, otherD = nearestOther(ent, cache, muzzlePos, effectDataAtt, distSqr)
                if math.sqrt(distSqr) - math.sqrt(otherD) < CLEARLY_CLOSER then
                    return result(cache, effectDataAtt, "effectdata", distSqr)
                end
            end
        end
    end

    -- 2) LVS's own muzzle attachment, unless another barrel is clearly closer.
    local lvsId = lookupLvsMuzzleId(ent, cache)
    if lvsId > 0 then
        local att = LVS_GRED_FX.GetAttachmentData(ent, lvsId)
        if att then
            local distSqr = att.Pos:DistToSqr(muzzlePos)
            if distSqr <= MAX_NAMED_DIST * MAX_NAMED_DIST then
                -- Another attachment beats LVS's named one when it is clearly
                -- closer AND is either right at the shot origin (BMD-4M: the
                -- cannon tip is a misnamed "sight") or itself a muzzle/barrel
                -- attachment (Pz.IV Zerstörer: four muzzle_N points, LVS names
                -- only muzzle_1). A non-barrel attachment merely nearer than
                -- the named muzzle (sight beside the autocannon) never wins.
                local otherId, otherD = nearestOther(ent, cache, muzzlePos, lvsId, AT_BARREL_DIST * AT_BARREL_DIST)
                local margin = CLEARLY_CLOSER
                if otherId == 0 and #cache.named > 0 then
                    otherId, otherD = nearestOf(ent, cache.named, muzzlePos, distSqr)
                    if otherId == lvsId then otherId = 0 end
                    -- LVS pointing at a non-barrel attachment (Flakpanzer 341
                    -- names "aim"): any nearer real barrel point wins outright.
                    if not isMuzzleName(attachmentName(cache, lvsId)) then margin = 0 end
                end
                if otherId > 0 and math.sqrt(distSqr) - math.sqrt(otherD) >= margin then
                    return result(cache, otherId, "lvs_muzzle_name_other_barrel", otherD)
                end
                return result(cache, lvsId, "lvs_muzzle_name", distSqr)
            end
        end
    end

    -- 3) Nearest attachment named muzzle/barrel.
    if cache.named and #cache.named > 0 then
        local id, d = nearestOf(ent, cache.named, muzzlePos, MAX_NAMED_DIST * MAX_NAMED_DIST)
        if id > 0 then return result(cache, id, "named_nearest", d) end
    end

    -- 4) Nearest attachment of any name, strict radius.
    if cache.atts and #cache.atts > 0 then
        local id, d = nearestOther(ent, cache, muzzlePos, 0, MAX_GENERIC_DIST * MAX_GENERIC_DIST)
        if id > 0 then return result(cache, id, "nearest", d) end
    end

    return 0, { method = "none", reason = "no attachment near muzzle position" }
end

local function resolveOnReference(ent, muzzlePos, effectDataAtt)
    local now = CurTime()
    local shotId = ent._lvsGredShotId
    if not shotId or now - (ent._lvsGredShotTime or 0) > SHOT_WINDOW then
        shotId = now
        ent._lvsGredShotId, ent._lvsGredShotTime = shotId, now
    end

    local ref = referenceFor(ent, shotId)
    if not IsValid(ref) then return nil end

    ACTIVE_REF, ACTIVE_VEH = ref, ent
    local ok, id, info = pcall(resolveImpl, ent, toReferenceSpace(ent, ref, muzzlePos), effectDataAtt)
    ACTIVE_REF, ACTIVE_VEH = nil, nil
    if not ok then return nil end
    return id, info
end

--[[---------------------------------------------------------------------------
    ResolveMuzzleAttachment( ent, muzzlePos, effectDataAtt )

    Returns: attachmentID, info
      info = {
        method = "effectdata" | "lvs_muzzle_name" | "lvs_muzzle_name_other_barrel"
               | "named_nearest" | "nearest" | "none",
        dist   = distance from the shot origin (nil for "none"),
        name   = attachment name ("" when unnamed),
      }

    attachmentID == 0 means no usable attachment; the caller falls back to
    the world position.
-----------------------------------------------------------------------------]]
-- A gun that was resolved once on a vehicle keeps that attachment for every
-- later shot, so recoil or vehicle speed can never re-pick a different id
-- mid-burst. A "gun" is the caller's gunKey (effect + caliber + flash pcf)
-- plus where on the vehicle the shot came from: multi-barrel mounts fire the
-- same key from several places, so each barrel gets its own memory. A turned
-- turret moves the local origin and simply resolves fresh for that pose.
local CACHED_LOCAL_RADIUS = 10   -- recoil travel is a few units; barrels sit further apart
local CACHED_MAX_DIST     = 24
local REMEMBER_MAX_DIST   = 4    -- learn only from shots that landed on the attachment

local function cachedForGun(ent, muzzlePos, gunKey)
    local cache = GetCache(ent)
    local entries = cache.guns[gunKey]
    if not entries then return nil end

    local localPos = ent:WorldToLocal(muzzlePos)
    local best, bestD = nil, CACHED_LOCAL_RADIUS * CACHED_LOCAL_RADIUS
    for i = 1, #entries do
        local d = entries[i].localPos:DistToSqr(localPos)
        if d < bestD then best, bestD = entries[i], d end
    end
    if not best then return nil end

    local att = LVS_GRED_FX.GetAttachmentData(ent, best.id)
    local d = att and att.Pos:Distance(muzzlePos) or math.huge
    if d > CACHED_MAX_DIST then
        table.RemoveByValue(entries, best)
        return nil
    end
    return best.id, { method = "remembered", dist = d, name = attachmentName(cache, best.id) }
end

local function rememberGun(ent, muzzlePos, gunKey, id)
    local cache = GetCache(ent)
    cache.guns[gunKey] = cache.guns[gunKey] or {}
    local entries = cache.guns[gunKey]
    entries[#entries + 1] = { localPos = ent:WorldToLocal(muzzlePos), id = id }
    if #entries > 32 then table.remove(entries, 1) end
end

function LVS_GRED_FX.ResolveMuzzleAttachment(ent, muzzlePos, effectDataAtt, gunKey)
    if not IsValid(ent) then return 0, { method = "none", reason = "invalid entity" } end
    if not isvector(muzzlePos) then return 0, { method = "none", reason = "invalid muzzle position" } end

    if isstring(gunKey) then
        local id, info = cachedForGun(ent, muzzlePos, gunKey)
        if id then return id, info end
    end

    local id, info = resolveOnReference(ent, muzzlePos, effectDataAtt)
    if id == nil then
        -- Reference model could not be created: resolve on the live entity.
        id, info = resolveImpl(ent, muzzlePos, effectDataAtt)
    end

    -- Only a confident result is remembered: an attachment that was right at
    -- the shot origin. A loose pick (shared "aim" point 6-11u off a recoiled
    -- barrel) would otherwise be locked in for every later shot.
    if isstring(gunKey) and id and id > 0 and info and info.dist and info.dist <= REMEMBER_MAX_DIST then
        rememberGun(ent, muzzlePos, gunKey, id)
    end
    return id, info
end
