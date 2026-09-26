--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : muzzle placement (client-side)

    Given the firing entity and the shot origin from the EffectData, returns
    the frame the flash/smoke must follow and the origin expressed in it.

    The shot origin is the output of the weapon's own code: it IS the muzzle
    for that shot. The only question is which transform it is rigid to, so
    that a particle living longer than LVS's 0.05 s sprite flash keeps up
    with traverse, elevation, recoil and hull motion. Two exact frames cover
    every LVS weapon; nothing is searched for or guessed:

      1. Weapon code names an attachment (weaponcode.lua reads it from the
         selected weapon's Attack function): the origin is expressed in that
         attachment's frame. Several named (multi-barrel mounts): the one
         whose bore line passes through the shot. A single-barrel gun whose
         origin lies on the attachment's line at or just behind it flashes
         on the attachment itself; any other origin (a barrel offset from a
         shared "aim" point, a gun firing beside its named point) keeps its
         exact offset and is driven from the live attachment every frame.
      2. Weapon code names nothing (LVS presets fire from a fixed local
         vector via ent:LocalToWorld): the origin is expressed in the
         firing entity's own transform and driven from it every frame.

    Where the origin comes from
      LVS networks each bullet with SrcEntity, the shot origin in the base
      vehicle's local space computed on the server at fire time. Whenever
      the tracer record for the shot carries it, that is the origin used:
      it cannot lag, however fast the hull moves (the world origin of the
      muzzle effect trails the client's interpolated vehicle by speed x
      interpolation time -- tens of units at speed, which put the flash and
      smoke in the air beside a moving vehicle). The world origin is only
      used when no tracer record exists for the shot.

    Where positions are measured
      Attachment positions are NOT read from the rendered vehicle. Each
      vehicle gets a hidden reference copy of its model whose hull never
      moves; only the turret and gun pose is copied onto it, once per shot,
      and then frozen. The shot origin is carried over to that reference
      relative to the live attachment it is nearest to, so hull speed and
      turret motion between fire and resolve cancel out. Offsets are local
      to a frame, so they are identical on the reference and on the live
      vehicle.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config

-- Printed in the pose diagnostics so a log can be matched to the code.
LVS_GRED_FX.MUZZLE_BUILD = "pose-from-render-1"

-- Code point acceptance window (units). LVS fires from the attachment
-- position itself; recoil moves the origin a few units back along the bore.
local MAX_NAMED_DIST = 32   -- a code point further than this is not this shot's

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

    -- Every pose parameter, copied from what the client is actually
    -- rendering. The client reads a pose parameter back normalised (0..1
    -- across its range; verified on the T-35: turret_yaw 0.059 in [0..360]
    -- with the turret at 21 degrees), so it is mapped through the range
    -- before being written. LVS's GetTurretYaw/GetTurretPitch are NOT used:
    -- they are plain Lua fields the client does not necessarily maintain
    -- (0 on the T-35 while its turret is turned), and writing them over the
    -- copied pose is exactly what left the reference turret at zero.
    local nPose = veh.GetNumPoseParameters and veh:GetNumPoseParameters() or 0
    for i = 0, nPose - 1 do
        local pname = veh:GetPoseParameterName(i)
        if isstring(pname) and pname ~= "" then
            local pmin, pmax = veh:GetPoseParameterRange(i)
            local norm = veh:GetPoseParameter(pname)
            if isnumber(norm) and isnumber(pmin) and isnumber(pmax) then
                ref:SetPoseParameter(pname, pmin + norm * (pmax - pmin))
            end
        end
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

    -- Pose diagnostics (once a second per vehicle): what the live vehicle
    -- reports, what the reference ended up with, and where each attachment
    -- sits on both in hull space. A drifting attachment shows up here as a
    -- growing live/ref gap with the pose values that failed to carry it.
    if cfg.DebugEnabled() and CurTime() - (veh._lvsGredPoseLog or 0) > 1 then
        veh._lvsGredPoseLog = CurTime()
        -- Bypasses the per-second line budget: these three lines are the
        -- ones needed when everything else is being suppressed.
        local Debug = function(...) print("[lvs_gred_fx][pose]", ...) end
        Debug("build:", LVS_GRED_FX.MUZZLE_BUILD, "turret accessors:", "yaw", veh.GetTurretYaw and veh:GetTurretYaw() or "-",
            "pitch", veh.GetTurretPitch and veh:GetTurretPitch() or "-",
            "names", tostring(veh.TurretYawPoseParameterName), tostring(veh.TurretPitchPoseParameterName),
            "mul/off", tostring(veh.TurretYawMul), tostring(veh.TurretYawOffset))
        local parts = {}
        for i = 0, nPose - 1 do
            local pname = veh:GetPoseParameterName(i)
            local pmin, pmax = veh:GetPoseParameterRange(i)
            parts[#parts + 1] = string.format("%s=%.3f[%.0f..%.0f]->%.3f", tostring(pname),
                veh:GetPoseParameter(pname) or -999, pmin or 0, pmax or 0, ref:GetPoseParameter(pname) or -999)
        end
        Debug("pose:", table.concat(parts, " "))
        local manip = {}
        for b = 0, bones - 1 do
            local a = veh:GetManipulateBoneAngles(b)
            if a and a ~= angle_zero then
                manip[#manip + 1] = string.format("%s=%s", tostring(veh:GetBoneName(b)), tostring(a))
            end
        end
        Debug("bone manip:", #manip > 0 and table.concat(manip, " ") or "none")
        local ok, atts = pcall(veh.GetAttachments, veh)
        if ok and istable(atts) then
            if veh.SetupBones then pcall(veh.SetupBones, veh) end
            local gaps = {}
            for _, a in ipairs(atts) do
                local la = veh:GetAttachment(a.id)
                local ra = ref:GetAttachment(a.id)
                if la and ra then
                    local liveLocal = veh:WorldToLocal(la.Pos)
                    local refLocal  = ra.Pos - REF_ORIGIN
                    gaps[#gaps + 1] = string.format("%s:%.1f", tostring(a.name), liveLocal:Distance(refLocal))
                end
            end
            Debug("attachment live/ref gap:", table.concat(gaps, " "))
        end
    end
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

-- Origin expressed in the frame of (framePos, frameAng).
local function frameOffset(muzzlePos, dir, framePos, frameAng)
    local ang = dir and dir:Angle() or frameAng
    local lpos, lang = WorldToLocal(muzzlePos, ang, framePos, frameAng)
    return lpos, lang
end

local function resolveImpl(ent, muzzlePos, dir, code, frameEnt)
    if cfg.DebugEnabled() and debugoverlay and debugoverlay.Box then
        local boxPos = (ent == ACTIVE_VEH) and ent:LocalToWorld(muzzlePos - REF_ORIGIN) or muzzlePos
        debugoverlay.Box(boxPos, Vector(4, 4, 4), 0.5, Color(0, 100, 255, 60))
    end

    local cache = GetCache(ent)

    if code and code.ids and #code.ids > 0 then
        local id, info = resolveByWeaponCode(ent, cache, muzzlePos, dir, code)
        if id == 0 then
            local codeId, codeD = nearestOf(ent, code.ids, muzzlePos, MAX_NAMED_DIST * MAX_NAMED_DIST)
            if codeId > 0 then
                id, info = result(cache, codeId, "weapon_code_near", codeD)
                info.reader = code.reader
            end
        end
        if id > 0 then
            local att = LVS_GRED_FX.GetAttachmentData(ent, id)
            if att then
                local onPoint = false
                if dir then
                    local v = att.Pos - muzzlePos
                    local along = v:Dot(dir)
                    local perp = (v - dir * along):Length()
                    info.perp = perp
                    onPoint = perp <= AXIS_PERP_MAX and along >= 0 and along <= AXIS_ALONG_MAX
                end
                if not onPoint then
                    info.method = "weapon_code_offset"
                    info.offset, info.offsetAng = frameOffset(muzzlePos, dir, att.Pos, att.Ang)
                end
            end
            return id, info
        end
        -- Every code point is out of range of this shot: the entity frame.
    end

    -- Preset weapons: fired from a fixed local vector on the firing entity.
    -- On the reference the hull sits at REF_ORIGIN with zero angles, which
    -- is that entity's own frame when it is the vehicle; a gunner pod (its
    -- own entity) is handled by the caller in live space.
    local info = { method = "entity_frame", dist = 0, name = "-" }
    if ent == ACTIVE_VEH and (not IsValid(frameEnt) or frameEnt == ent) then
        info.offset, info.offsetAng = frameOffset(muzzlePos, dir, REF_ORIGIN, angle_zero)
        return 0, info
    end
    return 0, info
end

local function resolveOnReference(ent, muzzlePos, dir, code, frameEnt, srcLocal)
    local now = CurTime()
    local shotId = ent._lvsGredShotId
    if not shotId or now - (ent._lvsGredShotTime or 0) > SHOT_WINDOW then
        shotId = now
        ent._lvsGredShotId, ent._lvsGredShotTime = shotId, now
    end

    local ref = referenceFor(ent, shotId)
    if not IsValid(ref) then return nil end

    ACTIVE_REF, ACTIVE_VEH = ref, ent
    local refPos, refDir
    if isvector(srcLocal) then
        -- LVS's server-side local origin: the hull frame IS the reference
        -- frame, so this is exact regardless of how far the hull has moved
        -- since the shot. Only the direction still needs the live angles.
        refPos = REF_ORIGIN + srcLocal
        if dir then
            refDir = ent:WorldToLocal(ent:GetPos() + dir):GetNormalized()
        end
        LAST_MOTION_COMP = 0
    else
        local refTip
        refPos, refTip = toReferenceSpace(ent, ref, muzzlePos, dir and (muzzlePos + dir * 16) or nil)
        refDir = refTip and (refTip - refPos):GetNormalized() or nil
    end
    local ok, id, info = pcall(resolveImpl, ent, refPos, refDir, code, frameEnt)
    ACTIVE_REF, ACTIVE_VEH = nil, nil
    if not ok then return nil end
    if code and info and not info.reader then
        info.code = table.concat(code.names, ",")
    end
    return id, info
end

--[[---------------------------------------------------------------------------
    ResolveMuzzleAttachment( ent, muzzlePos, effectDataAtt, gunKey, dir, weaponEnt )

    Returns attachment id (0 = none) and an info table:
        method    = "weapon_code" | "weapon_code_axis"   (flash on the attachment)
                  | "weapon_code_near" | "weapon_code_offset" | "entity_frame"
        offset    = Vector, origin in the frame's local space (offset methods)
        offsetAng = Angle,  shot direction in that space
        frameEnt  = entity whose transform the offset is relative to when
                    id == 0 (entity_frame)
        dist, perp, name, reader = diagnostics

    effectDataAtt and gunKey are accepted for the callers' sake and unused:
    LVS's EffectData attachment id is unreliable and nothing is remembered
    between shots because nothing is estimated.
-----------------------------------------------------------------------------]]
function LVS_GRED_FX.ResolveMuzzleAttachment(ent, muzzlePos, effectDataAtt, gunKey, dir, weaponEnt, srcLocal)
    if not IsValid(ent) then return 0, { method = "none", reason = "invalid entity" } end
    if not isvector(muzzlePos) then return 0, { method = "none", reason = "invalid muzzle position" } end
    if isvector(dir) and dir:LengthSqr() > 0.0001 then dir = dir:GetNormalized() else dir = nil end

    -- The entity LVS fired the effect on (gunner pod or the vehicle itself)
    -- carries the selected weapon; `ent` is the root the attachments live on.
    local weaponHolder = IsValid(weaponEnt) and weaponEnt or ent
    local code = LVS_GRED_FX_WEAPONCODE.AttachmentsFor(weaponHolder, ent)

    -- With LVS's server-local origin the entity frame is the base vehicle's
    -- (SrcEntity is expressed in it, also for gunner pods); otherwise the
    -- firing entity's own.
    local frameEnt = isvector(srcLocal) and ent or weaponHolder

    local id, info = resolveOnReference(ent, muzzlePos, dir, code, frameEnt, srcLocal)
    if id == nil then
        local livePos, liveTip = compensateHullMotion(ent, muzzlePos, dir and (muzzlePos + dir * 16) or nil)
        local liveDir = liveTip and (liveTip - livePos):GetNormalized() or nil
        id, info = resolveImpl(ent, livePos, liveDir, code, frameEnt)
    end

    if id == 0 and info and info.method == "entity_frame" then
        info.frameEnt = frameEnt
        if not info.offset and isvector(srcLocal) then
            info.offset, info.offsetAng = frameOffset(ent:LocalToWorld(srcLocal), dir, ent:GetPos(), ent:GetAngles())
        end
        if not info.offset then
            -- Gunner pod or no reference: the pod's live transform. The
            -- origin is moved into the client's interpolated frame first so
            -- hull speed does not bake into the offset.
            local livePos, liveTip = compensateHullMotion(ent, muzzlePos, dir and (muzzlePos + dir * 16) or nil)
            local liveDir = liveTip and (liveTip - livePos):GetNormalized() or nil
            info.offset, info.offsetAng = frameOffset(livePos, liveDir, frameEnt:GetPos(), frameEnt:GetAngles())
        end
    end
    return id, info
end
