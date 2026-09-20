local inspectableWeapons = {
	["weapon_pistol"] = true,
	["weapon_357"] = true,
	["weapon_smg1"] = true,
	["weapon_ar2"] = true,
	["weapon_shotgun"] = true,
	["weapon_crossbow"] = true,
	["weapon_rpg"] = true,
	["weapon_crowbar"] = true
}

local sprintableWeapons = {
	["weapon_pistol"] = true,
	["weapon_357"] = true,
	["weapon_smg1"] = true,
	["weapon_shotgun"] = true,
	["weapon_crossbow"] = true,
	["weapon_rpg"] = true,
	["weapon_frag"] = true,
	["weapon_stunstick"] = true,
	["weapon_crowbar"] = true,
	["weapon_physcannon"] = true,
	["weapon_bugbait"] = true,
	["weapon_ar2"] = true
}

-- NEW: Weapons that support reload/reload_empty animation swapping
local reloadableWeapons = {
	["weapon_pistol"] = true,
	["weapon_357"] = true,
	["weapon_smg1"] = true,
	["weapon_ar2"] = true,
	["weapon_shotgun"] = true,
	["weapon_crossbow"] = true,
	["weapon_rpg"] = true
}

if SERVER then
	hook.Add("KeyPress", "MMOD_Weapon_Inspect", function(ply, key)
		if key != IN_RELOAD then return end
		if !ply:Alive() then return end

		local wep = ply:GetActiveWeapon()
		if !IsValid(wep) then return end

		local class = wep:GetClass()
		if !inspectableWeapons[class] then return end

		local vm = ply:GetViewModel()
		if !IsValid(vm) then return end

		local seq = vm:GetSequence()
		local seqinfo = vm:GetSequenceInfo(seq)

		local vel = ply:GetVelocity():Length()
		if vel > 10 then return end

		if seqinfo.activityname == "ACT_VM_IDLE" then
			if (!wep.MMOD_NextInspectTime) or (wep.MMOD_NextInspectTime and CurTime() > wep.MMOD_NextInspectTime) then
				if wep:Clip1() == wep:GetMaxClip1() then
				local seqToPlay = vm:LookupSequence("inspect"..tostring(math.random(1,2)))
					if seqToPlay then
					local dur = vm:SequenceDuration(seqToPlay)

					wep:SetSaveValue("m_flTimeWeaponIdle", dur)
					vm:SendViewModelMatchingSequence(seqToPlay)
					wep.MMOD_NextInspectTime = CurTime() + dur

					end
				end
			end
		end
	end)
end

hook.Add("PlayerPostThink", "MMOD_AR2_Skin", function(ply)
	if !ply:Alive() then return end

	local wep = ply:GetActiveWeapon()
	if !IsValid(wep) then return end

	local class = wep:GetClass()
	if class != "weapon_ar2" then return end

	local vm = ply:GetViewModel()
	if !IsValid(vm) then return end

	local seq = vm:GetSequence()
	local seqinfo = vm:GetSequenceInfo(seq)

	local seqName = seqinfo.label
	local cyc = vm:GetCycle()

	if (string.find(seqName, "fire") and cyc < 0.2) or string.find(seqName, "shake") or (seqName == "inspect1" and cyc > 0.1 and cyc < 0.9) or (seqName == "inspect2" and cyc > 0.4 and cyc < 0.55)then
		if vm:GetSkin() != 1 then
			vm:SetSkin(1)
		end
	else
		if vm:GetSkin() != 0 then
			vm:SetSkin(0)
		end
	end
end)

if SERVER then

	----------------------------------------------
	-- NEW: Reload / Reload Empty Animation Swap--
	----------------------------------------------

	hook.Add("PlayerPostThink", "MMOD_Weapon_Reload", function(ply)
		if !ply:Alive() then return end

		local wep = ply:GetActiveWeapon()
		if !IsValid(wep) then return end

		local class = wep:GetClass()
		if !reloadableWeapons[class] then return end

		local vm = ply:GetViewModel()
		if !IsValid(vm) then return end

		local seq = vm:GetSequence()
		local seqinfo = vm:GetSequenceInfo(seq)
		local cyc = vm:GetCycle()

		-- Detect when the base reload activity starts and swap the animation
		if seqinfo.activityname == "ACT_VM_RELOAD" and cyc < 0.1 then
			if !wep.MMOD_ReloadSwapped then
				wep.MMOD_ReloadSwapped = true

				local seqToPlay
				if wep:Clip1() > 0 then
					-- Tactical reload (still has ammo in clip)
					seqToPlay = vm:LookupSequence("reload")
				else
					-- Empty reload (no ammo left in clip)
					seqToPlay = vm:LookupSequence("reload_empty")
				end

				if seqToPlay and seqToPlay != -1 then
					vm:SendViewModelMatchingSequence(seqToPlay)
				end
			end
		else
			wep.MMOD_ReloadSwapped = false
		end
	end)

	hook.Add("PlayerPostThink", "MMOD_Weapon_Sprint", function(ply)
		if !ply:Alive() then return end

		local wep = ply:GetActiveWeapon()
		if !IsValid(wep) then return end

		local class = wep:GetClass()
		if !sprintableWeapons[class] then return end

		local vm = ply:GetViewModel()
		if !IsValid(vm) then return end

		local seq = vm:GetSequence()
		local seqinfo = vm:GetSequenceInfo(seq)

		local vel = ply:GetVelocity():Length()
		local crouchspeed = ply:GetWalkSpeed() * ply:GetCrouchedWalkSpeed()

		if seqinfo.activityname == "ACT_VM_IDLE" then
			if sprintableWeapons[class] then
			if (!wep.MMOD_NextSprintTime) or (wep.MMOD_NextSprintTime and CurTime() > wep.MMOD_NextSprintTime) then
				if ply:KeyDown(IN_SPEED) and ply:OnGround() and vel >= crouchspeed and !ply:Crouching() then
				local seqToPlay = vm:LookupSequence("sprint")
					if seqToPlay then

						local dur = vm:SequenceDuration(seqToPlay)
						wep:SetSaveValue("m_flTimeWeaponIdle", 200)
						vm:SendViewModelMatchingSequence(seqToPlay)
						wep.MMOD_NextSprintTime = CurTime() + dur

						else return false

						end
					end
				end
			end
		elseif string.lower(seqinfo.label) == "sprint" then
			if !ply:KeyDown(IN_SPEED) or !ply:OnGround() or vel < crouchspeed or ply:Crouching() then
			local seqToPlay = vm:LookupSequence("idle01")
				if seqToPlay then

				local dur = vm:SequenceDuration(seqToPlay)
				vm:SendViewModelMatchingSequence(seqToPlay)
				wep.MMOD_NextSprintTime = CurTime() + 0.25

				else return false

				end
			end
		end
	end)

	hook.Add("PlayerPostThink", "MMOD_Weapon_Walk", function(ply)
		if !ply:Alive() then return end

		local wep = ply:GetActiveWeapon()
		if !IsValid(wep) then return end

		local class = wep:GetClass()
		if !sprintableWeapons[class] then return end

		local vm = ply:GetViewModel()
		if !IsValid(vm) then return end

		local seq = vm:GetSequence()
		local seqinfo = vm:GetSequenceInfo(seq)

		local vel = ply:GetVelocity():Length()
		local crouchspeed = ply:GetWalkSpeed() * ply:GetCrouchedWalkSpeed()

		if seqinfo.activityname == "ACT_VM_IDLE" then
			if sprintableWeapons[class] then
			if (!wep.MMOD_NextWalkTime) or (wep.MMOD_NextWalkTime and CurTime() > wep.MMOD_NextWalkTime) then
				if ply:OnGround() and vel >= crouchspeed and !ply:Crouching() then
				local seqToPlay = vm:LookupSequence("walk")
					if seqToPlay then
						
						local dur = vm:SequenceDuration(seqToPlay)
						wep:SetSaveValue("m_flTimeWeaponIdle", 200)
						vm:SendViewModelMatchingSequence(seqToPlay)
						wep.MMOD_NextWalkTime = CurTime() + dur

						else return false

						end
					end
				end
			end
		elseif string.lower(seqinfo.label) == "walk" then
			if ply:Crouching() or !ply:OnGround() or vel < crouchspeed or (ply:KeyDown(IN_SPEED) and ply:OnGround() and vel >= 50) then
			local seqToPlay = vm:LookupSequence("idle01")
				if seqToPlay then

				local dur = vm:SequenceDuration(seqToPlay)
				vm:SendViewModelMatchingSequence(seqToPlay)
				wep.MMOD_NextWalkTime = CurTime() + 0.25

				else return false

				end
			end
		end
	end)
end

---------------------------
--Crossbow Zoom Animation--
---------------------------

if SERVER then
	hook.Add("PlayerPostThink", "MMOD_CrossbowReloadZoom", function(ply)
		if !ply:Alive() then return end

		local wep = ply:GetActiveWeapon()
		if !IsValid(wep) then return end

		local class = wep:GetClass()
		if class != "weapon_crossbow" then return end

		local vm = ply:GetViewModel()
		if !IsValid(vm) then return end

		local seq = vm:GetSequence()
		local seqinfo = vm:GetSequenceInfo(seq)
	
		local seqName = seqinfo.label
		local cyc = vm:GetCycle()
	
		if ply:GetFOV() < 25 and (seqinfo.activityname == "ACT_VM_RELOAD" and cyc < 0.1) then
			local seqToPlay = vm:LookupSequence("reload_zoomed")
		
			if seqToPlay then

			vm:SendViewModelMatchingSequence(seqToPlay)
			wep.MMOD_CrossbowReload = true
			
			else return false
			
			end
		end
	end)
end

-----------------------------
--Shotgun Altfire Animation--
-----------------------------

if SERVER then
	hook.Add("PlayerPostThink", "MMOD_ShotgunAltFire", function(ply)
		if !ply:Alive() then return end

		local wep = ply:GetActiveWeapon()
		if !IsValid(wep) then return end

		local class = wep:GetClass()
		if class != "weapon_shotgun" then return end

		local vm = ply:GetViewModel()
		if !IsValid(vm) then return end

		local seq = vm:GetSequence()
		local seqinfo = vm:GetSequenceInfo(seq)
		
		local cyc = vm:GetCycle()

		if wep:GetClass() == "weapon_shotgun" and seqinfo.activityname == "ACT_VM_SECONDARYATTACK" then
			wep.MMOD_ShotgunNormalShot = true
		end

		if wep.MMOD_ShotgunNormalShot and seqinfo.activityname == "ACT_VM_PRIMARYATTACK" then
			local seqToPlay = vm:LookupSequence("pump")
				if seqToPlay then

				vm:SendViewModelMatchingSequence(seqToPlay)
				wep.MMOD_ShotgunNormalShot = false

			end
		elseif wep.MMOD_ShotgunNormalShot and string.lower(seqinfo.label) == "pump" then
			local seqToPlay = vm:LookupSequence("pump2_sighted")
				if seqToPlay then

				vm:SendViewModelMatchingSequence(seqToPlay)
				wep.MMOD_ShotgunNormalShot = false

			end
		end
	end)
end

if CLIENT then
	CreateClientConVar("mmod_replacements_stopsway", 0, {FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_USERINFO}, "Disable to support viewmodel lagger and other calcvmview scripts")
	CreateClientConVar("mmod_replacements_lense", 1, {FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_USERINFO}, "Add a refraction overlay for crossbow scope")
	CreateClientConVar("mmod_replacements_crossbow_overlay", 1, {FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_USERINFO}, "Adds an overlay for crossbow scope")

	hook.Add("CalcViewModelView", "MMOD_Weapon_StopDefaultSway", function(wep, vm, oldPos, oldAng, pos, ang)
		local ply = wep:GetOwner()
		if sprintableWeapons[wep:GetClass()] and IsValid(ply) and ply:GetVelocity():Length() > 1 and GetConVar("mmod_replacements_stopsway"):GetInt() == 1 then
			local can = true
			local leaning = ply:GetNW2Int("TFALean", 0) != 0

			if leaning then can = false end

			if can then
				return oldPos, oldAng
			end
		end
	end)

	local cbScope = Material("vgui/scopes/hl2mmod_scopes_crossbow")

	hook.Add("RenderScreenspaceEffects", "MMOD_Weapon_CrossbowZoomOverlay", function()
		local ply = LocalPlayer()

		local wep = ply:GetActiveWeapon()
		if !IsValid(wep) then return end

		if GetConVar("mmod_replacements_crossbow_overlay"):GetInt() == 1 then
			if ply:Alive() and wep:GetClass() == "weapon_crossbow" then
				if ply:GetFOV() < 25 then
					cam.Start2D()
						local w, h = ScrW(), ScrH()

						local start1 = w/2-h/2

						surface.SetDrawColor(255, 255, 255, 255)
						surface.SetMaterial(cbScope)
						surface.DrawTexturedRect(start1, 0, h, h)

						surface.SetDrawColor(0, 0, 0, 255)
						surface.DrawRect(0, 0, start1, h)

						surface.DrawRect(w-start1, 0, w, h)

						surface.DrawRect(-1, -1, w + 2, 2)

						surface.DrawRect(-1, -1, 2, h + 2)
					cam.End2D()
				end
			end
		end
	end)

	local cbLense = Material("models/weapons/v_crossbow/lens")

	local function mmod_replacements_lense_cvar_func(name, oldval, newval)
		if newval == "0" then
			cbLense:SetTexture("$basetexture", "vgui/black")
		elseif newval == "1" then
			cbLense:SetTexture("$basetexture", "_rt_SmallFB1")
		elseif newval == "2" then
			cbLense:SetTexture("$basetexture", "_rt_FullFrameFB")
		end
	end

	cvars.RemoveChangeCallback("mmod_replacements_lense", "mmod_replacements_lense_id")
	cvars.AddChangeCallback("mmod_replacements_lense", mmod_replacements_lense_cvar_func, "mmod_replacements_lense_id")

	hook.Add("InitPostEntity", "MMOD_Weapon_CrossbowLenseConvarInit", function()
		mmod_replacements_lense_cvar_func(nil, nil, GetConVar("mmod_replacements_lense"):GetString())
	end)
end