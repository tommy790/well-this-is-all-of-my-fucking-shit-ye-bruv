--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : weapon → attachment mapping from the vehicle's own
    LVS weapon configuration (client-side)

    LVS vehicles register their guns through ENT:InitWeapons() →
    self:AddWeapon({ Attack = function( ent ) ... end, ... }). That runs in
    SetupDataTables, so the client holds the very same Attack closures the
    server fires with, and the selected weapon id is a NetworkVar. The
    Attack function is where the vehicle author wrote which attachment the
    gun fires from ( ent:LookupAttachment( "muzzle_l" ) ). This module reads
    that back instead of guessing from geometry.

    Two readers, in order:
      1. Source text. debug.getinfo gives the file and line span of the
         closure; the file is readable from the LUA search path because
         entity files are always sent to the client. Within that span:
           LookupAttachment( "name" )            → that attachment
           LookupAttachment( "prefix" .. expr )  → every attachment starting
                                                   with the prefix (multi-barrel)
           LookupAttachment( X.Field )           → the string in ent.Field
           GetAttachment( 3 )                     → numeric id
           TurretBallisticsMuzzleAttachment       → ent.TurretBallisticsMuzzleAttachment
         Methods the function calls on the entity ( ent:FireCannon() ) are
         followed the same way, so helpers defined elsewhere in the vehicle
         are covered.
      2. Bytecode constants. string.dump keeps the closure's string
         constants; every constant that is the name of an attachment on the
         vehicle is a candidate. Used only when the source is unreadable.

    A weapon whose code fires from a plain vector (LVS "LMG" preset:
    ent.PosLMG) references no attachment at all; the result is empty and the
    caller falls back to its geometric chain.

    Results are cached per vehicle class + model + pod + weapon id and
    contain attachment IDS on the vehicle root (where the barrel
    attachments live even when a gunner pod fired).
-----------------------------------------------------------------------------]]

if not CLIENT then return end

LVS_GRED_FX_WEAPONCODE = LVS_GRED_FX_WEAPONCODE or {}
local W = LVS_GRED_FX_WEAPONCODE

local MAX_FUNCS = 16   -- Attack plus helpers it calls
local MAX_DEPTH = 3

W.Cache = W.Cache or {}   -- key -> { ids = {...}, names = {...}, reader = "source"|"bytecode"|"none", detail = "" }

--[[---------------------------------------------------------------------------
    Source access.
-----------------------------------------------------------------------------]]
local fileCache = {}   -- normalised path -> table of lines | false

local function luaPathOf(info)
    local src = info and (info.source or info.short_src)
    if not isstring(src) or src == "" then return nil end
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    if src:sub(1, 1) == "=" then return nil end   -- C or generated chunk
    src = src:gsub("\\", "/")
    -- Paths arrive as "lua/entities/x/shared.lua", "addons/foo/lua/entities/..."
    -- or "entities/x/shared.lua"; the LUA search path wants the part after lua/.
    local pos = src:find("/lua/", 1, true)
    if pos then
        src = src:sub(pos + 5)
    elseif src:sub(1, 4) == "lua/" then
        src = src:sub(5)
    end
    if src:sub(-4) ~= ".lua" then return nil end
    return src
end

local function linesOf(path)
    local cached = fileCache[path]
    if cached ~= nil then return cached or nil end
    local text = file.Read(path, "LUA")
    if not isstring(text) then
        fileCache[path] = false
        return nil
    end
    local lines = string.Explode("\n", text)
    fileCache[path] = lines
    return lines
end

local function functionText(fn)
    local ok, info = pcall(debug.getinfo, fn, "S")
    if not ok or not info or info.what ~= "Lua" then return nil end
    local path = luaPathOf(info)
    if not path then return nil end
    local lines = linesOf(path)
    if not lines then return nil end
    local first, last = info.linedefined or 0, info.lastlinedefined or 0
    if first < 1 or last < first or last > #lines then return nil end
    return table.concat(lines, "\n", first, last), path
end

--[[---------------------------------------------------------------------------
    Candidate collection.
-----------------------------------------------------------------------------]]
local function addName(out, name)
    if isstring(name) and name ~= "" and not out.names[name] then
        out.names[name] = true
        out.order[#out.order + 1] = { kind = "name", value = name }
    end
end

local function addPrefix(out, prefix)
    if isstring(prefix) and prefix ~= "" and not out.prefixes[prefix] then
        out.prefixes[prefix] = true
        out.order[#out.order + 1] = { kind = "prefix", value = prefix }
    end
end

local function addId(out, id)
    id = tonumber(id)
    if id and id > 0 and not out.ids[id] then
        out.ids[id] = true
        out.order[#out.order + 1] = { kind = "id", value = id }
    end
end

-- Strips comments so a commented-out LookupAttachment is not read as live code.
local function stripComments(text)
    text = text:gsub("%-%-%[(=*)%[.-%]%1%]", "")
    text = text:gsub("%-%-[^\n]*", "")
    return text
end

local function scanSource(text, owners, out)
    text = stripComments(text)

    -- Every string literal inside a LookupAttachment( ... ) argument list:
    --   "muzzle"                      → name
    --   "muzzle_" .. n                → prefix (multi-barrel)
    --   cond and "muzzle_l" or "muzzle_r" → both names
    local searchFrom = 1
    while true do
        local _, open = text:find("LookupAttachment%s*%(", searchFrom)
        if not open then break end
        local depth, i, close = 1, open + 1, nil
        while i <= #text do
            local c = text:sub(i, i)
            if c == "(" then depth = depth + 1
            elseif c == ")" then
                depth = depth - 1
                if depth == 0 then close = i break end
            end
            i = i + 1
        end
        if not close then break end
        local arg = text:sub(open + 1, close - 1)
        for q, lit, after in arg:gmatch("([\"'])([^\"']-)%1%s*(%.?%.?)") do
            if after == ".." then addPrefix(out, lit) else addName(out, lit) end
        end
        -- LookupAttachment( ent.MuzzleName ): a string field on the entity.
        for field in arg:gmatch("[%a_][%w_]*%.([%a_][%w_]*)") do
            for _, owner in ipairs(owners) do
                local v = owner[field]
                if isstring(v) then addName(out, v) break end
            end
        end
        searchFrom = close + 1
    end
    -- GetAttachment( 3 )
    for id in text:gmatch("GetAttachment%s*%(%s*(%d+)%s*%)") do
        addId(out, id)
    end
    -- The turret-ballistics module's own muzzle name.
    if text:find("TurretBallisticsMuzzleAttachment", 1, true) then
        for _, owner in ipairs(owners) do
            if isstring(owner.TurretBallisticsMuzzleAttachment) then
                addName(out, owner.TurretBallisticsMuzzleAttachment)
                break
            end
        end
    end
end

-- Methods called on any entity variable inside the text: ent:Fire(), self:X(),
-- Base:Y(). Returns the method names.
local function calledMethods(text)
    local names, seen = {}, {}
    for name in text:gmatch(":%s*([%a_][%w_]*)%s*%(") do
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    return names
end

local function scanBytecode(fn, attachmentNames, out)
    if not string.dump then return false end
    local ok, dump = pcall(string.dump, fn, true)
    if not ok or not isstring(dump) then return false end
    local function count(hay, needle)
        local n, from = 0, 1
        while true do
            local a, b = hay:find(needle, from, true)
            if not a then return n end
            n, from = n + 1, b + 1
        end
    end
    -- Constants are length-prefixed in the dump, so "muzzle" also matches
    -- inside "muzzle_coax". A name only counts for occurrences that are not
    -- part of a longer matched name.
    local hits = {}
    for name in pairs(attachmentNames) do
        if #name >= 2 then
            local n = count(dump, name)
            if n > 0 then hits[#hits + 1] = { name = name, n = n } end
        end
    end
    table.sort(hits, function(a, b) return #a.name > #b.name end)
    local found = false
    for i, h in ipairs(hits) do
        local own = h.n
        for j = 1, i - 1 do
            local longer = hits[j]
            if longer.own > 0 then own = own - longer.own * count(longer.name, h.name) end
        end
        h.own = math.max(own, 0)
        if h.own > 0 then
            addName(out, h.name)
            found = true
        end
    end
    return found
end

--[[---------------------------------------------------------------------------
    Analysis of one weapon.
-----------------------------------------------------------------------------]]
local function attachmentNameSet(root)
    local set = {}
    local ok, atts = pcall(root.GetAttachments, root)
    if ok and istable(atts) then
        for i = 1, #atts do
            local a = atts[i]
            if a and a.id and a.id > 0 and isstring(a.name) and a.name ~= "" then
                set[a.name] = a.id
            end
        end
    end
    return set
end

local function analyse(weapon, owners, root)
    local out = { names = {}, prefixes = {}, ids = {}, order = {} }
    local nameSet = attachmentNameSet(root)
    local reader = "none"

    local visited, queue, count = {}, {}, 0
    local function push(fn, depth)
        if not isfunction(fn) or visited[fn] then return end
        visited[fn] = true
        queue[#queue + 1] = { fn = fn, depth = depth }
    end
    push(weapon.Attack, 0)
    -- Multi-barrel vehicles sometimes advance the barrel in StartAttack or
    -- OnThink and only read it in Attack; the names still live in Attack, but
    -- a helper called from either is worth following.
    push(weapon.StartAttack, 1)

    local i = 1
    while i <= #queue and count < MAX_FUNCS do
        local item = queue[i]
        i = i + 1
        count = count + 1
        local text = functionText(item.fn)
        if text then
            if reader == "none" then reader = "source" end
            scanSource(text, owners, out)
            if item.depth < MAX_DEPTH then
                for _, m in ipairs(calledMethods(text)) do
                    for _, owner in ipairs(owners) do
                        local f = owner[m]
                        if isfunction(f) then
                            local okI, info = pcall(debug.getinfo, f, "S")
                            if okI and info and info.what == "Lua" then push(f, item.depth + 1) end
                            break
                        end
                    end
                end
            end
        elseif item.depth == 0 then
            if scanBytecode(item.fn, nameSet, out) then reader = "bytecode" end
        end
    end
    -- Source read fine but named nothing the patterns understand: the
    -- closure's own string constants are the last word on what it references.
    if #out.order == 0 and isfunction(weapon.Attack) then
        if scanBytecode(weapon.Attack, nameSet, out) then reader = "bytecode" end
    end

    -- Expand to attachment ids on the root.
    local ids, names, seen = {}, {}, {}
    local function take(id, name)
        if id and id > 0 and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
            names[#names + 1] = name or ""
        end
    end
    for _, entry in ipairs(out.order) do
        if entry.kind == "name" then
            take(nameSet[entry.value], entry.value)
        elseif entry.kind == "prefix" then
            local matches = {}
            for name, id in pairs(nameSet) do
                if name:sub(1, #entry.value) == entry.value then matches[#matches + 1] = { id = id, name = name } end
            end
            table.sort(matches, function(a, b) return a.name < b.name end)
            for _, m in ipairs(matches) do take(m.id, m.name) end
        elseif entry.kind == "id" then
            local okA, att = pcall(root.GetAttachment, root, entry.value)
            if okA and att then
                local name = ""
                for n, id in pairs(nameSet) do if id == entry.value then name = n break end end
                take(entry.value, name)
            end
        end
    end

    return { ids = ids, names = names, reader = (#ids > 0) and reader or "none" }
end

--[[---------------------------------------------------------------------------
    Public API.
-----------------------------------------------------------------------------]]

-- The LVS weapon table for the entity that fired (base vehicle or gunner
-- pod). Returns weapon, podIndex, weaponId.
function W.ActiveWeapon(ent)
    if not IsValid(ent) or not ent.GetActiveWeapon then return nil end
    local ok, weapon, id = pcall(ent.GetActiveWeapon, ent)
    if not ok or not istable(weapon) then return nil end
    local pod = 1
    if ent.GetPodIndex then
        local okP, p = pcall(ent.GetPodIndex, ent)
        if okP and isnumber(p) then pod = p end
    end
    return weapon, pod, id
end

-- Attachment ids (on `root`) that the active weapon of `ent` fires from,
-- according to its own Attack code. Returns nil when the vehicle is not an
-- LVS weapon carrier or the code names no attachment.
--   result = { ids = {...}, names = {...}, reader = "source"|"bytecode", weaponId = n, pod = n }
function W.AttachmentsFor(ent, root)
    local weapon, pod, weaponId = W.ActiveWeapon(ent)
    if not weapon or not isfunction(weapon.Attack) then return nil end
    root = IsValid(root) and root or ent

    local key = table.concat({ root:GetClass(), root:GetModel() or "", ent:GetClass(), pod, weaponId or 0 }, "|")
    local cached = W.Cache[key]
    if not cached then
        local owners = { ent }
        if root ~= ent then owners[#owners + 1] = root end
        local ok, res = pcall(analyse, weapon, owners, root)
        cached = (ok and res) or { ids = {}, names = {}, reader = "none" }
        cached.weaponId, cached.pod = weaponId, pod
        W.Cache[key] = cached
    end
    if #cached.ids == 0 then return nil end
    return cached
end

function W.ClearCache()
    W.Cache = {}
    fileCache = {}
end

concommand.Add("lvs_gred_fx_weaponcode_dump", function()
    print("[LVS_GRED_FX] weapon-code attachment cache:")
    for key, v in pairs(W.Cache) do
        print(string.format("  %s -> reader=%s ids=[%s] names=[%s]", key, v.reader,
            table.concat(v.ids, ","), table.concat(v.names, ",")))
    end
end)

hook.Add("OnReloaded", "lvs_gred_fx_weaponcode_reload", W.ClearCache)
