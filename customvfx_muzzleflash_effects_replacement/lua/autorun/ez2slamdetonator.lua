concommand.Add("ez2_detonateslams", function(ply)
    -- local slams = ents.FindByClass("npc_satchel")
    ply:EmitSound("ui/buttonclick.wav")
    janjerman = ply -- it just wont work in multiplayer so i decided to do it like this...yeah its a bad idea probably changes nothing...yeah.
    timer.Simple(0.2, function()
        for k, v in ipairs( janjerman.ez2wepsslamstable ) do
            if (v:IsValid()) then v:Fire("Explode") end
            --table.Empty(ply.ez2wepsslamstable)
        end
    end)
    /*  local slams = ents.FindByClass("npc_satchel")
    local xdxxd = table.ToString(slams, "xd", true)
    print(xdxxd) */
end)