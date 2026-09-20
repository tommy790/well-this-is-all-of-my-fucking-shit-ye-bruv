-- Turns on the engine's enhanced impact effects once per session.
local function EnableNewImpactEffects()
    local cvar = GetConVar("cl_new_impact_effects")
    if cvar and cvar:GetInt() ~= 1 then
        RunConsoleCommand("cl_new_impact_effects", "1")
    end
end

EnableNewImpactEffects()
hook.Add("InitPostEntity", "AC_EnableNewImpactEffects", EnableNewImpactEffects)
