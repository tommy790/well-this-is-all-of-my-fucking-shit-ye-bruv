--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : muzzle attachment resolution (client-side)

    Resolves the correct weapon muzzle attachment for a given firing entity and
    muzzle world position, following this priority order:

      1. LVS-provided attachment id in the EffectData  (validated: must exist
         and sit close to the muzzle world position)
      2. Authoritative LVS muzzle attachment name
         (ent.TurretBallisticsMuzzleAttachment, e.g. "muzzle") via
         ent:LookupAttachment(name), validated against the muzzle position
      3. Attachments whose name contains "muzzle"/"barrel", picking the one
         nearest to the muzzle position (this deterministically selects the
         correct barrel on multi-barrel / alternating-barrel weapons, since
         each shot's muzzle position identifies the barrel that fired)
      4. Generic nearest attachment inside a strict radius (models that have
         no named muzzle attachments, e.g. some mounted MG pods)
      5. World-position fallback (only when nothing valid was found — the
         caller logs why)

    The muzzle world position is only ever used to FIND the attachment; the
    actual particle is always spawned with PATTACH_POINT_FOLLOW once an
    attachment has been resolved.

    Performance:
      * attachment enumeration (GetAttachments) is cached per entity and
        invalidated only when the model changes,
      * static barrels (fixed local muzzle positions) are cached per local
        position so the nearest-attachment scan runs at most once per barrel,
      * LookupAttachment for the LVS muzzle name is cheap and cached per
        entity+model as well.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config
local Debug = LVS_GRED_FX.Debug

-- Tolerances (units).
local MAX_EFFECTDATA_DIST = 96   -- EffectData attachment must be near the muzzle
local MAX_NAMED_DIST      = 32   -- "muzzle"/"barrel" named candidates: a real
                                 -- muzzle is within a few units of bullet.Src;
                                 -- 128 allowed far/wrong attachments (e.g. a
                                 -- BMD-4 "muzzle" id 18 units away -> smoke on
                                 -- the wrong spot). 32 still tolerates turret
                                 -- pivot offset while rejecting non-muzzles.
local MAX_GENERIC_DIST    = 48   -- strict radius for unnamed models

-- Local-space quantization for the static-barrel cache.
local LOCAL_CELL = 8

local function isMuzzleName(name)
    if not isstring(name) then return false end
    local lower = string.lower(name)
    return string.find(lower, "muzzle", 1, true) ~= nil
        or string.find(lower, "barrel", 1, true) ~= nil
end

--[[---------------------------------------------------------------------------
    Per-entity attachment cache. Invalidated when the model changes so that
    toolgun model swaps can never leave stale ids behind.
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

    local named = {}
    if atts then
        for i = 1, #atts do
            local id = atts[i] and atts[i].id
            local name = atts[i] and atts[i].name
            if id and id > 0 and isMuzzleName(name) then
                named[#named + 1] = id
            end
        end
    end

    cache = {
        model  = model,
        atts   = atts,
        named  = named,
        byLocal = {},  -- quantized local pos → attachment id (static barrels)
        lvsNameId = nil, -- cached id for ent.TurretBallisticsMuzzleAttachment
        lvsName  = nil,
    }

    ent._lvsGredMuzzleCache = cache
    return cache
end

local function localKey(v)
    if not isvector(v) then return nil end
    return math.floor(v.x / LOCAL_CELL + 0.5)
        .. ","
        .. math.floor(v.y / LOCAL_CELL + 0.5)
        .. ","
        .. math.floor(v.z / LOCAL_CELL + 0.5)
end

--[[---------------------------------------------------------------------------
    Static reference model.

    One hidden ClientsideModel per vehicle. Its HULL never moves: it sits
    parked far below the map with zero angles. Only the turret and gun are
    posed on it -- the vehicle's turret yaw/pitch pose parameters and LVS
    bone pose parameters (bone manipulations) -- and that pose is captured
    once, at the moment the vehicle fires, then frozen. Between shots the
    reference does not change at all, so every attachment lookup during a
    shot's resolution (including the deferred pass a frame later) sees the
    exact barrel pose the shot was fired from.

    The muzzle point from the EffectData is moved into that reference's
    frame with the vehicle's NETWORK transform (the server snapshot the shot
    came from), and all of the resolver's distance tests below run there.
    The resolver's logic, order, caches and tolerances are untouched.
-----------------------------------------------------------------------------]]
local REF_ORIGIN = Vector(0, 0, -30000)
local REFS = setmetatable({}, { __mode = "k" })   -- vehicle -> { ent, model, shot }

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

local function turretPoseNames(veh)
    local names = {}
    local y = veh.TurretYawPoseParameterName
    local p = veh.TurretPitchPoseParameterName
    if isstring(y) and y ~= "" then names[y] = true end
    if isstring(p) and p ~= "" then names[p] = true end
    return names
end

-- Copies ONLY the turret/gun pose. Hull stays static.
local function captureTurretPose(ref, veh)
    ref:SetPos(REF_ORIGIN)
    ref:SetAngles(angle_zero)

    local wanted = turretPoseNames(veh)
    for i = 0, (veh:GetNumPoseParameters() or 0) - 1 do
        local name = veh:GetPoseParameterName(i)
        if name and wanted[name] then
            local lo, hi = veh:GetPoseParameterRange(i)
            local frac = veh:GetPoseParameter(name) or 0
            ref:SetPoseParameter(name, lo + (hi - lo) * frac)
        end
    end

    -- LVS bone pose parameters (gun elevation / recoil on some models) are
    -- written as bone manipulations on the vehicle; mirror them.
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

-- Returns the frozen reference for this vehicle, capturing the turret pose
-- when `shotId` is new (one capture per shot; frozen afterwards).
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

-- Muzzle world point -> the same point in the static reference's frame,
-- using the vehicle's network (server snapshot) transform.
local function toReferenceSpace(veh, worldPos)
    local org = veh.GetNetworkOrigin and veh:GetNetworkOrigin() or nil
    local ang = veh.GetNetworkAngles and veh:GetNetworkAngles() or nil
    if not isvector(org) or org == vector_origin then org = veh:GetPos() end
    if not isangle(ang) then ang = veh:GetAngles() end
    local localPos = WorldToLocal(worldPos, angle_zero, org, ang)
    return REF_ORIGIN + localPos
end

-- The entity whose attachments are being read during a resolve, and the
-- shot id (one per fire event). Set by ResolveMuzzleAttachment.
local ACTIVE_REF, ACTIVE_VEH = nil, nil

-- Get world position (and name) of an attachment; returns nil on any failure.
-- While a resolve is running for `ent`, positions come from its static
-- reference model.
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
    local att = LVS_GRED_FX.GetAttachmentData(ent, attID)
    if not att then return "?" end
    return att.Name or "?"
end

-- Resolve the vehicle root for an entity (gunner pods → their base vehicle).
function LVS_GRED_FX.VehicleRoot(ent)
    if not IsValid(ent) then return nil end
    if ent.GetVehicle then
        local base = ent:GetVehicle()
        if IsValid(base) then return base end
    end
    return ent
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
    ResolveMuzzleAttachment( ent, muzzlePos, effectDataAtt )

    Returns: attachmentID, info
      info = {
        method = "effectdata" | "lvs_muzzle_name" | "named_nearest" |
                "local_cache" | "nearest" | "none",
        dist   = resolution distance (or nil),
        name   = resolved attachment name (or nil),
      }

    attachmentID == 0 means "no usable attachment" — the caller must use the
    world-position fallback.
-----------------------------------------------------------------------------]]
local SHOT_WINDOW = 0.05   -- fire events closer than this share one frozen pose

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
    local ok, id, info = pcall(LVS_GRED_FX._ResolveMuzzleAttachmentImpl, ent, toReferenceSpace(ent, muzzlePos), effectDataAtt)
    ACTIVE_REF, ACTIVE_VEH = nil, nil
    if not ok then return nil end
    return id, info
end

function LVS_GRED_FX.ResolveMuzzleAttachment(ent, muzzlePos, effectDataAtt)
    if not IsValid(ent) then return 0, { method = "none", reason = "invalid entity" } end
    if not isvector(muzzlePos) then return 0, { method = "none", reason = "invalid muzzle position" } end

    local id, info = resolveOnReference(ent, muzzlePos, effectDataAtt)
    if id ~= nil then return id, info end
    -- No reference model could be created: resolve on the live entity.
    return LVS_GRED_FX._ResolveMuzzleAttachmentImpl(ent, muzzlePos, effectDataAtt)
end

function LVS_GRED_FX._ResolveMuzzleAttachmentImpl(ent, muzzlePos, effectDataAtt)

    -- Debug: draw a blue box showing the named-nearest attachment search
    -- area (MAX_NAMED_DIST radius around the muzzle position), so it is easy
    -- to see where the resolver is looking for the barrel attachment.
    if cfg.DebugEnabled() and debugoverlay and debugoverlay.Box then
        local boxPos = (ent == ACTIVE_VEH) and ent:LocalToWorld(muzzlePos - REF_ORIGIN) or muzzlePos
        debugoverlay.Box(boxPos, Vector(MAX_NAMED_DIST, MAX_NAMED_DIST, MAX_NAMED_DIST), 0.5, Color(0, 100, 255, 60))
    end

    local cache = GetCache(ent)

    -- 1) EffectData attachment id. LVS sometimes provides a muzzle attachment
    --    id, but it can be a stale/base-model id (e.g. lvs_2s38 sends id 1 —
    --    39 units away, empty name — which is a hull/root attachment, not the
    --    barrel). Validate it like the other paths: real name AND close to
    --    the muzzle position.
    if effectDataAtt and effectDataAtt > 0 then
        local att = LVS_GRED_FX.GetAttachmentData(ent, effectDataAtt)
        if att and att.Name and att.Name ~= "" then
            local dist = att.Pos:DistToSqr(muzzlePos)
            if dist <= MAX_EFFECTDATA_DIST * MAX_EFFECTDATA_DIST then
                return effectDataAtt, {
                    method = "effectdata",
                    dist = math.sqrt(dist),
                    name = att.Name,
                }
            end
        end
    end

    -- 2) Authoritative LVS muzzle attachment name on the entity.
    local lvsId = lookupLvsMuzzleId(ent, cache)
    if lvsId > 0 then
        local att = LVS_GRED_FX.GetAttachmentData(ent, lvsId)
        -- Require a real name AND proximity: an unnamed or far attachment is
        -- not the actual barrel muzzle (e.g. BMD-4 "muzzle" id 18u away).
        if att and att.Name and att.Name ~= "" then
            local dist = att.Pos:DistToSqr(muzzlePos)
            if dist <= MAX_NAMED_DIST * MAX_NAMED_DIST then
                return lvsId, {
                    method = "lvs_muzzle_name",
                    dist = math.sqrt(dist),
                    name = att.Name,
                }
            end
        end
    end

    -- 3) Named muzzle candidates nearest to the muzzle position. This handles
    --    multi-barrel vehicles (muzzle, hull_muzzle, muzzle_coax, muzzle1/2...)
    --    deterministically: each shot's muzzle position picks its own barrel.
    --    Only attachments with a real name qualify (an unnamed id is not a
    --    trustworthy muzzle).
    if cache.named and #cache.named > 0 then
        local best, bestDistSqr = 0, MAX_NAMED_DIST * MAX_NAMED_DIST
        local bestName = nil

        for i = 1, #cache.named do
            local id = cache.named[i]
            local att = LVS_GRED_FX.GetAttachmentData(ent, id)
            if att and att.Name and att.Name ~= "" then
                local d = att.Pos:DistToSqr(muzzlePos)
                if d < bestDistSqr then
                    bestDistSqr = d
                    best = id
                    bestName = att.Name
                end
            end
        end

        if best > 0 then
            return best, {
                method = "named_nearest",
                dist = math.sqrt(bestDistSqr),
                name = bestName,
            }
        end
    end

    -- 4) Static-barrel cache: fixed local muzzle positions resolve once.
    --    The cache stores the resolved id AND the exact local position. A
    --    cache hit is only accepted when the CURRENT muzzle local position is
    --    within a few units of the cached one — this prevents two barrels
    --    whose muzzles share an 8-unit cell (e.g. BMD-4M autocannon + main
    --    cannon) from cross-returning each other's attachment id.
    if ent.WorldToLocal then
        local localPos = (ent == ACTIVE_VEH) and (muzzlePos - REF_ORIGIN) or ent:WorldToLocal(muzzlePos)
        local key = localKey(localPos)
        if key then
            local cached = cache.byLocal[key]
            if cached and cached.id then
                if LVS_GRED_FX.ValidAttachment(ent, cached.id) and cached.pos and isvector(cached.pos) then
                    local drift = localPos:DistToSqr(cached.pos)
                    if drift <= 4 * 4 then -- within 4 units of the cached barrel
                        return cached.id, { method = "local_cache", dist = nil, name = LVS_GRED_FX.AttachmentName(ent, cached.id) }
                    end
                end
                cache.byLocal[key] = nil
            end
        end
    end

    -- 5) Generic nearest attachment inside a strict radius (unnamed models).
    if cache.atts and #cache.atts > 0 then
        local best, bestDistSqr = 0, MAX_GENERIC_DIST * MAX_GENERIC_DIST
        local bestName = nil

        for i = 1, #cache.atts do
            local id = cache.atts[i] and cache.atts[i].id
            if id and id > 0 then
                local att = LVS_GRED_FX.GetAttachmentData(ent, id)
                if att then
                    local d = att.Pos:DistToSqr(muzzlePos)
                    if d < bestDistSqr then
                        bestDistSqr = d
                        best = id
                        bestName = att.Name or ""
                    end
                end
            end
        end

        if best > 0 then
            if ent.WorldToLocal then
                local localPos = (ent == ACTIVE_VEH) and (muzzlePos - REF_ORIGIN) or ent:WorldToLocal(muzzlePos)
                local key = localKey(localPos)
                if key then
                    cache.byLocal[key] = { id = best, pos = localPos }
                end
            end
            return best, {
                method = "nearest",
                dist = math.sqrt(bestDistSqr),
                name = bestName,
            }
        end
    end

    return 0, { method = "none", reason = "no attachment near muzzle position" }
end
