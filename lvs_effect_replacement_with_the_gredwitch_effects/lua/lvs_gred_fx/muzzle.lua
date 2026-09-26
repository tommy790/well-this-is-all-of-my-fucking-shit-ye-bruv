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

    How the id is chosen
      The vehicle's own LVS weapon code is the authority: weaponcode.lua
      reads the attachment(s) the selected weapon's Attack function fires
      from. With several (multi-barrel mounts) the barrel whose line passes
      through the shot origin is taken; if none does, the nearest of them.
      The single exception is a mount whose code names one shared point and
      offsets each shot onto a barrel with its own muzzle/barrel attachment
      lying on the shot's barrel line -- that barrel is used.

      Only when the code names nothing does a geometric chain run
      (first match wins):
      1. Barrel line: the attachment lying on the line through the origin
         in the bullet direction; muzzle/barrel names preferred.
      2. The attachment id LVS put in the EffectData, if it is close to the
         shot origin and no other attachment is clearly closer. (LVS often
         sends a stale base-model id here -- id 1 on the 2S1 is a suspension
         attachment.)
      3. LVS's own muzzle attachment (ent.TurretBallisticsMuzzleAttachment),
         if close. If another barrel is clearly closer, that one fired
         instead -- multi-gun turrets only name one muzzle.
      4. Nearest attachment whose name contains "muzzle" or "barrel".
      5. Nearest attachment of any name inside a strict radius.
      6. Nothing -> id 0; the caller spawns at the world position.

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
-- The shot origin comes from the server, i.e. from the vehicle's newest
-- networked transform; the client's attachments are read from its
-- interpolated transform, which trails that by the interpolation delay. On a
-- moving vehicle the two differ by up to speed x cl_interp (28 u on a T-35
-- at cruise), enough to put the MG's shot origin nearer the cannon muzzle
-- than the MG. Re-expressing the origin from the network frame in the
-- interpolated frame removes the hull's share of that offset exactly; the
-- turret's share is handled by the frozen reference model below.
local LAST_MOTION_COMP = 0
local function compensateHullMotion(veh, worldPos, worldPos2)
    LAST_MOTION_COMP = 0
    local netOrg = veh.GetNetworkOrigin and veh:GetNetworkOrigin() or nil
    local netAng = veh.GetNetworkAngles and veh:GetNetworkAngles() or nil
    if not isvector(netOrg) or netOrg == vector_origin or not isangle(netAng) then
        return worldPos, worldPos2
    end
    local liveOrg, liveAng = veh:GetPos(), veh:GetAngles()
    if netOrg == liveOrg and netAng == liveAng then return worldPos, worldPos2 end
    local function map(p)
        return LocalToWorld(WorldToLocal(p, angle_zero, netOrg, netAng), angle_zero, liveOrg, liveAng)
    end
    local shifted = map(worldPos)
    LAST_MOTION_COMP = shifted:Distance(worldPos)
    return shifted, worldPos2 and map(worldPos2) or nil
end
function LVS_GRED_FX.LastMotionCompensation() return LAST_MOTION_COMP end

local function toReferenceSpace(veh, ref, worldPos, worldPos2)
    if veh.SetupBones then pcall(veh.SetupBones, veh) end
    worldPos, worldPos2 = compensateHullMotion(veh, worldPos, worldPos2)
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
            local function map(p)
                local off = WorldToLocal(p, angle_zero, bestAtt.Pos, bestAtt.Ang)
                return LocalToWorld(off, angle_zero, refAtt.Pos, refAtt.Ang)
            end
            return map(worldPos), worldPos2 and map(worldPos2) or nil
        end
    end
    -- Nothing near: fall back to the vehicle's network (server) transform.
    local org = veh.GetNetworkOrigin and veh:GetNetworkOrigin() or nil
    local ang = veh.GetNetworkAngles and veh:GetNetworkAngles() or nil
    if not isvector(org) or org == vector_origin then org = veh:GetPos() end
    if not isangle(ang) then ang = veh:GetAngles() end
    local function map(p) return REF_ORIGIN + WorldToLocal(p, angle_zero, org, ang) end
    return map(worldPos), worldPos2 and map(worldPos2) or nil
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

-- Barrel-axis match. Recoil and LVS's origin offsets move the shot origin
-- ALONG the barrel, never sideways, so the attachment of the barrel that
-- fired is the one lying on the line through the origin in the bullet
-- direction. A neighbouring barrel, a sight or a suspension point is metres
-- off that line however close it is in plain distance. Muzzle/barrel-named
-- attachments are preferred among on-axis candidates.
-- The along-barrel window is deliberately short. Recoil and LVS origin
-- offsets seen so far are 6-14u; a coaxial MG runs parallel to the cannon a
-- few units beside it, so with a long window the cannon's muzzle 47u ahead
-- sits inside the MG's line of fire (BT-7). Anything further along is left
-- to the fallback chain, which never reached that far either.
local AXIS_PERP_MAX   = 4     -- max sideways offset from the barrel line
local AXIS_ALONG_MIN  = -12   -- attachment slightly behind the origin
local AXIS_ALONG_MAX  = 24    -- attachment ahead of a recoiled origin

local function resolveByAxis(ent, cache, muzzlePos, dir, onlyIds)
    if not cache.atts then return 0 end
    local allowed = nil
    if onlyIds then
        allowed = {}
        for i = 1, #onlyIds do allowed[onlyIds[i]] = true end
    end
    local bestId, bestScore, bestPerp = 0, math.huge, 0
    for i = 1, #cache.atts do
        local id = cache.atts[i] and cache.atts[i].id
        if id and id > 0 and (not allowed or allowed[id]) then
            local att = LVS_GRED_FX.GetAttachmentData(ent, id)
            if att then
                local v = att.Pos - muzzlePos
                local along = v:Dot(dir)
                if along >= AXIS_ALONG_MIN and along <= AXIS_ALONG_MAX then
                    local perp = (v - dir * along):Length()
                    if perp <= AXIS_PERP_MAX then
                        local score = perp + math.abs(along) * 0.05
                        if isMuzzleName(cache.nameById[id]) then score = score - AXIS_PERP_MAX end
                        if score < bestScore then bestId, bestScore, bestPerp = id, score, perp end
                    end
                end
            end
        end
    end
    return bestId, bestPerp
end

-- Attachments named by the weapon's own LVS Attack code. The code tells us
-- which attachment the gun fires RELATIVE to; it is the muzzle only when the
-- shot actually originates there. Twin and quad mounts frequently name one
-- shared point ("aim", "muzzle") and offset the shot sideways per barrel;
-- in that case the named point is not where the flash belongs, and the
-- geometric chain below (barrel line first) finds the barrel it was offset
-- to. So a code candidate is accepted only when the shot's barrel line
-- passes through it; several candidates are told apart the same way.
local CODE_NO_DIR_DIST = 8   -- without a fire direction, only a shot at the point itself

local function resolveByWeaponCode(ent, cache, muzzlePos, dir, code)
    local ids = code.ids
    if dir then
        local id, perp = resolveByAxis(ent, cache, muzzlePos, dir, ids)
        if id > 0 then
            local att = LVS_GRED_FX.GetAttachmentData(ent, id)
            local _, info = result(cache, id, #ids == 1 and "weapon_code" or "weapon_code_axis",
                att and att.Pos:DistToSqr(muzzlePos) or 0)
            info.perp, info.reader = perp, code.reader
            return id, info
        end
        return 0, "shot origin not on the line through the code's attachment(s)"
    end
    local id, d = nearestOf(ent, ids, muzzlePos, CODE_NO_DIR_DIST * CODE_NO_DIR_DIST)
    if id > 0 then
        local _, info = result(cache, id, "weapon_code", d)
        info.reader = code.reader
        return id, info
    end
    return 0, "shot origin not at the code's attachment(s)"
end

local resolveGeometric

local function resolveImpl(ent, muzzlePos, effectDataAtt, dir, code)
    if cfg.DebugEnabled() and debugoverlay and debugoverlay.Box then
        local boxPos = (ent == ACTIVE_VEH) and ent:LocalToWorld(muzzlePos - REF_ORIGIN) or muzzlePos
        debugoverlay.Box(boxPos, Vector(MAX_NAMED_DIST, MAX_NAMED_DIST, MAX_NAMED_DIST), 0.5, Color(0, 100, 255, 60))
    end

    local cache = GetCache(ent)

    -- The weapon's own code is the authority on where it fires from. The
    -- geometric tests below only choose AMONG the points the code names
    -- (multi-barrel mounts: the barrel whose line passes through the shot),
    -- and fall back to the nearest of them when the client's attachment has
    -- drifted off that line (turret traverse lag, or LVS firing a fixed
    -- offset beside the named point as on the BMD-4M's 30mm). The heuristic
    -- chain runs only for vehicles whose code names nothing.
    if code and code.ids and #code.ids > 0 then
        local id, info = resolveByWeaponCode(ent, cache, muzzlePos, dir, code)
        if id == 0 then
            local codeId, codeD = nearestOf(ent, code.ids, muzzlePos, MAX_NAMED_DIST * MAX_NAMED_DIST)
            if codeId > 0 then
                id, info = result(cache, codeId, "weapon_code_near", codeD)
                info.reader = code.reader
                if dir then
                    local att = LVS_GRED_FX.GetAttachmentData(ent, codeId)
                    if att then
                        local v = att.Pos - muzzlePos
                        info.perp = (v - dir * v:Dot(dir)):Length()
                    end
                end
            end
        end
        if id > 0 then
            -- One exception: a twin/quad mount whose code names a shared
            -- point (Pz.IV Zerstörer: "aim", 18u from every barrel) and
            -- offsets each shot onto a real barrel that has its own
            -- muzzle/barrel attachment. That attachment lies on the shot's
            -- barrel line (a recoiled origin sits a few units behind it, so
            -- the line test, not plain distance) while the shared point does
            -- not, and it is the barrel that fired. Only muzzle/barrel-named
            -- attachments outside the code's own set qualify; a sight or aim
            -- point never does.
            if dir and info.method == "weapon_code_near" and cache.named and #cache.named > 0 then
                local tips = {}
                for i = 1, #cache.named do
                    local nid = cache.named[i]
                    if not table.HasValue(code.ids, nid) then tips[#tips + 1] = nid end
                end
                if #tips > 0 then
                    local tipId, tipPerp = resolveByAxis(ent, cache, muzzlePos, dir, tips)
                    if tipId > 0 then
                        local att = LVS_GRED_FX.GetAttachmentData(ent, tipId)
                        local _, tinfo = result(cache, tipId, "weapon_code_barrel_tip",
                            att and att.Pos:DistToSqr(muzzlePos) or 0)
                        tinfo.perp, tinfo.reader = tipPerp, code.reader
                        return tipId, tinfo
                    end
                end
            end
            return id, info
        end
        -- Every code point is out of range of the shot: treat as no code.
    end

    return resolveGeometric(ent, cache, muzzlePos, effectDataAtt, dir)
end

local function resolveGeometricImpl(ent, cache, muzzlePos, effectDataAtt, dir)
    -- 0) Barrel axis (needs the bullet direction).
    if dir then
        local id, perp = resolveByAxis(ent, cache, muzzlePos, dir)
        if id > 0 then
            local att = LVS_GRED_FX.GetAttachmentData(ent, id)
            local _, info = result(cache, id, "barrel_axis", att and att.Pos:DistToSqr(muzzlePos) or 0)
            info.perp = perp
            return id, info
        end
    end

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
                -- LVS pointing at a non-barrel attachment (Flakpanzer 341
                -- names "aim", which sits behind the barrels): a real barrel
                -- point within range wins even when the recoiled shot origin
                -- happens to be momentarily nearer the "aim" point.
                if not isMuzzleName(attachmentName(cache, lvsId)) and #cache.named > 0 then
                    local namedId, namedD = nearestOf(ent, cache.named, muzzlePos, MAX_NAMED_DIST * MAX_NAMED_DIST)
                    if namedId > 0 and namedId ~= lvsId then
                        return result(cache, namedId, "lvs_muzzle_name_other_barrel", namedD)
                    end
                end
                local otherId, otherD = nearestOther(ent, cache, muzzlePos, lvsId, AT_BARREL_DIST * AT_BARREL_DIST)
                if otherId == 0 and #cache.named > 0 then
                    otherId, otherD = nearestOf(ent, cache.named, muzzlePos, distSqr)
                    if otherId == lvsId then otherId = 0 end
                end
                if otherId > 0 and math.sqrt(distSqr) - math.sqrt(otherD) >= CLEARLY_CLOSER then
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
resolveGeometric = resolveGeometricImpl

local function resolveOnReference(ent, muzzlePos, effectDataAtt, dir, code)
    local now = CurTime()
    local shotId = ent._lvsGredShotId
    if not shotId or now - (ent._lvsGredShotTime or 0) > SHOT_WINDOW then
        shotId = now
        ent._lvsGredShotId, ent._lvsGredShotTime = shotId, now
    end

    local ref = referenceFor(ent, shotId)
    if not IsValid(ref) then return nil end

    ACTIVE_REF, ACTIVE_VEH = ref, ent
    local refPos, refTip = toReferenceSpace(ent, ref, muzzlePos, dir and (muzzlePos + dir * 16) or nil)
    local refDir = refTip and (refTip - refPos):GetNormalized() or nil
    local ok, id, info = pcall(resolveImpl, ent, refPos, effectDataAtt, refDir, code)
    ACTIVE_REF, ACTIVE_VEH = nil, nil
    if not ok then return nil end
    if code and info and not info.reader then
        info.code = table.concat(code.names, ",")
    end
    return id, info
end

--[[---------------------------------------------------------------------------
    ResolveMuzzleAttachment( ent, muzzlePos, effectDataAtt )

    Returns: attachmentID, info
      info = {
        method = "weapon_code" | "weapon_code_axis" | "weapon_code_near"
               | "weapon_code_barrel_tip"
               | "barrel_axis" | "remembered" | "effectdata" | "lvs_muzzle_name"
               | "lvs_muzzle_name_other_barrel" | "named_nearest" | "nearest" | "none",
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
-- A remembered id is trusted only while it still sits on the shot. Local-space
-- keying alone is not enough: a turned turret can put another barrel's old
-- entry within the radius, and a 13u-spaced twin would inherit the wrong id.
local CACHED_MAX_DIST     = 6
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

function LVS_GRED_FX.ResolveMuzzleAttachment(ent, muzzlePos, effectDataAtt, gunKey, dir, weaponEnt)
    if not IsValid(ent) then return 0, { method = "none", reason = "invalid entity" } end
    if not isvector(muzzlePos) then return 0, { method = "none", reason = "invalid muzzle position" } end
    if isvector(dir) and dir:LengthSqr() > 0.0001 then dir = dir:GetNormalized() else dir = nil end

    -- The entity LVS fired the effect on (gunner pod or the vehicle itself)
    -- carries the selected weapon; `ent` is the root the attachments live on.
    local code = LVS_GRED_FX_WEAPONCODE.AttachmentsFor(IsValid(weaponEnt) and weaponEnt or ent, ent)

    -- Per-gun memory only stands in for the geometric fallback; a weapon
    -- whose code names its attachment is resolved from that every time.
    if not code and isstring(gunKey) then
        local id, info = cachedForGun(ent, muzzlePos, gunKey)
        if id then return id, info end
    end

    local id, info = resolveOnReference(ent, muzzlePos, effectDataAtt, dir, code)
    if id == nil then
        -- Reference model could not be created: resolve on the live entity.
        local livePos, liveTip = compensateHullMotion(ent, muzzlePos, dir and (muzzlePos + dir * 16) or nil)
        local liveDir = liveTip and (liveTip - livePos):GetNormalized() or nil
        id, info = resolveImpl(ent, livePos, effectDataAtt, liveDir, code)
    end

    -- Only a confident result is remembered: an attachment that was right at
    -- the shot origin. A loose pick (shared "aim" point 6-11u off a recoiled
    -- barrel) would otherwise be locked in for every later shot.
    if isstring(gunKey) and id and id > 0 and info and info.dist and info.dist <= REMEMBER_MAX_DIST then
        rememberGun(ent, muzzlePos, gunKey, id)
    end
    return id, info
end
