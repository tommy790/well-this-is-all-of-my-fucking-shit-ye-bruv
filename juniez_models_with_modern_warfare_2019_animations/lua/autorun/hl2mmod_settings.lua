-- Replaces the old runcommand.lua which unconditionally forced viewmodel_fov
-- and sv_defaultdeployspeed every time the file loaded. The same defaults are
-- now applied once, and only if the user has not turned them off.

AddCSLuaFile()

if SERVER then
    -- The MW2019 draw animations are authored for real-time deploy speed.
    local cv = CreateConVar("mmod_replacements_deployspeed", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
        "Set sv_defaultdeployspeed to 1 so draw animations play at their authored speed (0 = leave it alone)", 0, 1)

    local function Apply()
        if not cv:GetBool() then return end
        local deploy = GetConVar("sv_defaultdeployspeed")
        if deploy and deploy:GetFloat() ~= 1 then
            RunConsoleCommand("sv_defaultdeployspeed", "1")
        end
    end

    hook.Add("InitPostEntity", "MMOD_ApplyDeploySpeed", Apply)
    cvars.AddChangeCallback("mmod_replacements_deployspeed", Apply, "MMOD_ApplyDeploySpeed")
    return
end

local cvFov = CreateClientConVar("mmod_replacements_viewmodel_fov", "67", true, false,
    "viewmodel_fov applied once per session for the MW2019 viewmodels (0 = do not touch)", 0, 120)

hook.Add("InitPostEntity", "MMOD_ApplyViewmodelFov", function()
    local fov = cvFov:GetFloat()
    if fov <= 0 then return end
    local vmfov = GetConVar("viewmodel_fov")
    if vmfov and vmfov:GetFloat() ~= fov then
        RunConsoleCommand("viewmodel_fov", tostring(fov))
    end
end)
