if (SERVER) then 

	function CheckForENVExplosion()
		
		local env_explosion = ents.FindByClass("env_explosion") 
		
		for k, v in pairs(env_explosion) do 
			local pos = v:GetPos()
					
			local tr = util.TraceLine( {
				start  = pos,
				endpos = pos,
				mask   = MASK_SOLID_BRUSHONLY
			} )

			if tr.HitWorld then 
				ParticleEffect(table.Random({"AC_generic_explosion","AC_generic_explosion","AC_generic_explosion"}), pos, Angle(0,math.random(0,360),0), nil)

			else
				ParticleEffect(table.Random({"AC_generic_explosion_air","AC_generic_explosion_air","AC_generic_explosion_air"}), pos, Angle(0,math.random(0,360),0), nil)

			end
			sound.Play( "hd/new_grenadeexplo.mp3", pos, math.random(80,120), math.random(80,120), 1)

			v:Remove()
			
		end
	
	end
	
	hook.Add("Think", "CheckForENVExplosion",CheckForENVExplosion)




end