--@diagnostic disable: undefined-global, lowercase-global
-- Enables the game's enhanced impact effects (cl_new_impact_effects).
-- Fixed: previously this file re-ran the console command every 2 seconds
-- forever; now it is set once (and once more after InitPostEntity).
if CLIENT then

    local function EnableNewImpactEffects()
        local cvar = GetConVar("cl_new_impact_effects")
        if cvar and cvar:GetInt() ~= 1 then
            RunConsoleCommand("cl_new_impact_effects", "1")
        end
    end

    EnableNewImpactEffects()
    hook.Add("InitPostEntity", "AC_EnableNewImpactEffects", EnableNewImpactEffects)
end
