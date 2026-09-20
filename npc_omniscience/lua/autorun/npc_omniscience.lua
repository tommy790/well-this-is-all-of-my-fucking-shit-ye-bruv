-- NPC Omniscience
-- When enabled, every NPC gets perfect proficiency, a long sight range, a long
-- scripted-weapon range, and periodic enemy-memory updates so it can engage
-- targets it cannot physically see. Disabling restores each NPC to exactly the
-- values it had before the buff was applied.

local cvEnabled = CreateConVar("npc_omniscient", "0",
    bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED),
    "Make all NPCs omniscient (see through walls)")

local cvRate = CreateConVar("npc_omniscient_update_rate", "0.2",
    bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED),
    "How often (in seconds) to update NPC enemy memory", 0.05, 5)

if SERVER then
    local BUFF_LOOK_DISTANCE = 10000
    local BUFF_WEAPON_RANGE  = 15000

    -- npc -> { proficiency = n, lookDistance = n }
    -- Weak keys so removed NPCs never leave stale entries behind.
    local buffed = setmetatable({}, { __mode = "k" })

    local cvIgnorePlayers = GetConVar("ai_ignoreplayers")

    local function BuffWeapon(wep)
        if not IsValid(wep) then return end
        if wep._OmniscientOriginalRange == nil then
            -- Explicit false marks "had no Range field" so it can be nil'd back.
            wep._OmniscientOriginalRange = wep.Range or false
        end
        wep.Range = BUFF_WEAPON_RANGE
    end

    local function RestoreWeapon(wep)
        if not IsValid(wep) then return end
        local orig = wep._OmniscientOriginalRange
        if orig == nil then return end
        wep.Range = orig or nil
        wep._OmniscientOriginalRange = nil
    end

    local function ApplyBuffs(npc)
        if not IsValid(npc) or not npc:IsNPC() then return end

        if not buffed[npc] then
            buffed[npc] = {
                proficiency  = npc:GetCurrentWeaponProficiency(),
                lookDistance = npc:GetMaxLookDistance(),
            }
        end

        npc:SetCurrentWeaponProficiency(WEAPON_PROFICIENCY_PERFECT)
        npc:SetMaxLookDistance(BUFF_LOOK_DISTANCE)
        BuffWeapon(npc:GetActiveWeapon())
    end

    local function RemoveBuffs(npc)
        local orig = buffed[npc]
        buffed[npc] = nil
        if not IsValid(npc) then return end

        if orig then
            npc:SetCurrentWeaponProficiency(orig.proficiency)
            npc:SetMaxLookDistance(orig.lookDistance)
        end
        RestoreWeapon(npc:GetActiveWeapon())
        for _, wep in ipairs(npc:GetWeapons()) do
            RestoreWeapon(wep)
        end
    end

    local function CollectNPCs()
        local list = {}
        for _, ent in ipairs(ents.GetAll()) do
            if ent:IsNPC() and ent:Health() > 0 then
                list[#list + 1] = ent
            end
        end
        return list
    end

    local function UpdateEnemyMemory(npc, players, npcs)
        if not IsValid(npc) then return end

        local hasEnemy = IsValid(npc:GetEnemy())

        if not cvIgnorePlayers:GetBool() then
            for i = 1, #players do
                local ply = players[i]
                if IsValid(ply) and ply:Alive() and npc:Disposition(ply) == D_HT then
                    npc:UpdateEnemyMemory(ply, ply:GetPos())
                    if not hasEnemy then
                        npc:SetEnemy(ply)
                        hasEnemy = true
                    end
                end
            end
        end

        for i = 1, #npcs do
            local other = npcs[i]
            if other ~= npc and IsValid(other) and npc:Disposition(other) == D_HT then
                npc:UpdateEnemyMemory(other, other:GetPos())
                if not hasEnemy then
                    npc:SetEnemy(other)
                    hasEnemy = true
                end
            end
        end
    end

    local function DisableAll()
        for npc in pairs(buffed) do
            RemoveBuffs(npc)
        end
    end

    local function EnableAll()
        local npcs = CollectNPCs()
        local players = player.GetAll()
        for i = 1, #npcs do
            ApplyBuffs(npcs[i])
            UpdateEnemyMemory(npcs[i], players, npcs)
        end
    end

    local function Tick()
        if not cvEnabled:GetBool() then return end

        local npcs = CollectNPCs()
        local players = player.GetAll()

        for i = 1, #npcs do
            local npc = npcs[i]
            if not buffed[npc] then
                ApplyBuffs(npc)
            else
                -- Weapons can be given/dropped without a switch event.
                BuffWeapon(npc:GetActiveWeapon())
            end
            UpdateEnemyMemory(npc, players, npcs)
        end
    end

    local function RestartTimer()
        timer.Create("NPCOmniscienceUpdate", cvRate:GetFloat(), 0, Tick)
    end

    RestartTimer()

    cvars.AddChangeCallback("npc_omniscient_update_rate", RestartTimer, "NPCOmniscience")

    cvars.AddChangeCallback("npc_omniscient", function(_, _, new)
        if tobool(new) then
            EnableAll()
        else
            DisableAll()
        end
    end, "NPCOmniscience")

    hook.Add("OnEntityCreated", "NPCOmniscienceSpawn", function(ent)
        if not cvEnabled:GetBool() then return end
        timer.Simple(0.1, function()
            if not IsValid(ent) or not ent:IsNPC() then return end
            ApplyBuffs(ent)
            UpdateEnemyMemory(ent, player.GetAll(), CollectNPCs())
        end)
    end)

    hook.Add("NPCWeaponSwitch", "NPCOmniscienceWeapon", function(npc, oldWep, newWep)
        if not IsValid(npc) then return end
        if buffed[npc] and cvEnabled:GetBool() then
            BuffWeapon(newWep)
        else
            RestoreWeapon(newWep)
        end
    end)

    hook.Add("EntityRemoved", "NPCOmniscienceCleanup", function(ent)
        buffed[ent] = nil
    end)

    hook.Add("PostCleanupMap", "NPCOmniscienceMapCleanup", function()
        for npc in pairs(buffed) do
            buffed[npc] = nil
        end
    end)
end

if CLIENT then
    hook.Add("PopulateToolMenu", "NPCOmniscienceMenu", function()
        spawnmenu.AddToolMenuOption("Options", "NPCs", "NPCOmniscience", "Omniscience", "", "", function(panel)
            panel:ClearControls()
            panel:CheckBox("Enable NPC Omniscience", "npc_omniscient")
            panel:NumSlider("Update Rate (seconds)", "npc_omniscient_update_rate", 0.05, 2, 2)
            panel:Help("Lower = more responsive but more lag. Higher = better performance.")
            panel:Help("When enabled, all NPCs can:")
            panel:Help("- See enemies through walls")
            panel:Help("- Shoot from long distances")
            panel:Help("- Have perfect aim (no weapon spread)")
        end)
    end)
end
