-- EZ2 weapon pack helper commands (the SLAM detonator used to rely on a
-- single global player reference, which broke in multiplayer).

AddCSLuaFile()
if not SERVER then return end

concommand.Add("ez2_detonateslams", function(ply)
    if not IsValid(ply) then return end

    local mines = {}
    if istable(ply.ez2wepsslamstable) then
        for _, ent in ipairs(ply.ez2wepsslamstable) do
            if IsValid(ent) then mines[#mines + 1] = ent end
        end
        table.Empty(ply.ez2wepsslamstable)
    end
    for _, ent in ipairs(ents.FindByClass("npc_satchel")) do
        if ent:GetOwner() == ply then mines[#mines + 1] = ent end
    end
    for _, ent in ipairs(ents.FindByClass("ez2_slam_tripmine")) do
        if ent:GetRealOwner() == ply then mines[#mines + 1] = ent end
    end
    if #mines == 0 then return end

    ply:EmitSound("ui/buttonclick.wav")
    timer.Simple(0.2, function()
        for _, ent in ipairs(mines) do
            if not IsValid(ent) then continue end
            if ent.Explode then ent:Explode() else ent:Fire("Explode") end
        end
    end)
end)
