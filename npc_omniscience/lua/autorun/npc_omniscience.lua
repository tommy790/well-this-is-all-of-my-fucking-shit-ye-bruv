if SERVER then
    util.AddNetworkString("NPCOmniscienceToggle")
end

-- Global convar
CreateConVar("npc_omniscient", "0", {FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED}, "Make all NPCs omniscient (see through walls)")
CreateConVar("npc_omniscient_update_rate", "0.2", {FCVAR_ARCHIVE}, "How often (in seconds) to update NPC enemy memory")

if SERVER then
    -- Function to apply omniscient buffs to an NPC
    local function ApplyOmniscientBuffs(npc)
        if not IsValid(npc) then return end

        -- Perfect weapon proficiency (perfect aim)
        npc:SetCurrentWeaponProficiency(WEAPON_PROFICIENCY_PERFECT)

        -- Long sight range (10000 units = very far)
        npc:SetMaxLookDistance(10000)

        -- Unlimited firing distance - make them able to snipe from far away
        local wep = npc:GetActiveWeapon()
        if IsValid(wep) then
            -- Store original values if not already stored
            if not wep._OmniscientOriginalRange then
                wep._OmniscientOriginalRange = wep.Range or 5000
            end
            -- Set very long range
            wep.Range = 15000
        end
    end

    -- Function to remove omniscient buffs
    local function RemoveOmniscientBuffs(npc)
        if not IsValid(npc) then return end

        -- Reset to good proficiency instead of perfect
        npc:SetCurrentWeaponProficiency(WEAPON_PROFICIENCY_GOOD)

        -- Reset sight range to default
        npc:SetMaxLookDistance(2000)

        -- Restore original weapon range
        local wep = npc:GetActiveWeapon()
        if IsValid(wep) and wep._OmniscientOriginalRange then
            wep.Range = wep._OmniscientOriginalRange
        end
    end

    -- Function to update enemy memory - optimized to use cached lists
    local function UpdateNPCEnemyMemory(npc, players, npcs)
        if not IsValid(npc) then return end

        local aiIgnorePlayers = GetConVar("ai_ignoreplayers"):GetBool()
        local npcPos = npc:GetPos()

        -- Check players
        for _, ent in ipairs(players) do
            if IsValid(ent) and ent ~= npc and ent:Alive() and not aiIgnorePlayers then
                npc:UpdateEnemyMemory(ent, ent:GetPos())
                if npc.GetEnemy and npc.SetEnemy and not IsValid(npc:GetEnemy()) then
                    npc:SetEnemy(ent)
                end
            end
        end

        -- Check hostile NPCs
        for _, ent in ipairs(npcs) do
            if IsValid(ent) and ent ~= npc and ent:IsNPC() and ent.Disposition and ent:Disposition(npc) == D_HT then
                npc:UpdateEnemyMemory(ent, ent:GetPos())
                if npc.GetEnemy and npc.SetEnemy and not IsValid(npc:GetEnemy()) then
                    npc:SetEnemy(ent)
                end
            end
        end
    end

    -- Timer-based update instead of Think hook for performance
    local nextUpdate = 0
    hook.Add("Think", "NPCOmniscienceThink", function()
        local curTime = CurTime()
        if curTime < nextUpdate then return end

        local updateRate = GetConVar("npc_omniscient_update_rate"):GetFloat()
        nextUpdate = curTime + updateRate

        local enabled = GetConVar("npc_omniscient"):GetBool()

        -- Cache expensive lookups once per update cycle
        local players = player.GetAll()
        local allNPCs = ents.FindByClass("npc_*")

        for _, npc in ipairs(allNPCs) do
            if IsValid(npc) and npc:IsNPC() then
                if enabled then
                    ApplyOmniscientBuffs(npc)
                    UpdateNPCEnemyMemory(npc, players, allNPCs)
                else
                    -- Check if we need to remove buffs (only once when disabled)
                    if npc._OmniscientBuffed then
                        RemoveOmniscientBuffs(npc)
                        npc._OmniscientBuffed = false
                    end
                end
                -- Mark as buffed when enabled
                if enabled then
                    npc._OmniscientBuffed = true
                end
            end
        end
    end)

    -- Apply to newly spawned NPCs
    hook.Add("OnEntityCreated", "NPCOmniscienceSpawn", function(ent)
        if not GetConVar("npc_omniscient"):GetBool() then return end
        timer.Simple(0.1, function()
            if IsValid(ent) and ent:IsNPC() then
                ApplyOmniscientBuffs(ent)
                UpdateNPCEnemyMemory(ent, player.GetAll(), ents.FindByClass("npc_*"))
            end
        end)
    end)
    
    -- Hook to maintain long range on weapon switches
    hook.Add("NPCWeaponSwitch", "NPCOmniscienceWeapon", function(npc, oldWep, newWep)
        if not GetConVar("npc_omniscient"):GetBool() then return end
        if IsValid(npc) and IsValid(newWep) then
            -- Apply range to new weapon
            if not newWep._OmniscientOriginalRange then
                newWep._OmniscientOriginalRange = newWep.Range or 5000
            end
            newWep.Range = 15000
        end
    end)
end

-- Spawnmenu panel
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
