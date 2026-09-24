-- ============================================================================
-- TIV ANCHOR LOAD (server)
-- ============================================================================
-- Puts the wind load on the anchored chassis as a real force so the body
-- strains against its anchor constraints instead of being tilted by a client
-- render override.
--
-- The wind acts on the body above the anchor points, so the push is applied
-- at an aerodynamic centre above the centre of mass: that alone produces the
-- pitch/roll lean away from the wind, and a corner whose spike has sheared is
-- simply no longer held, so it lifts without any special casing. Gusting is a
-- smooth per-vehicle noise on top of the steady load, never a random impulse.
--
-- Nothing here decides whether the anchors fail; sv_loft.lua still owns that.
-- ============================================================================

TIV.Rock = TIV.Rock or {}

local TICK = 0.05                      -- ProcessAnchored cadence in sv_loft.lua
-- Steady load scale. Matches the 0.01-per-0.1s coupling the wind loop uses on
-- a free-rolling vehicle, converted to this loop's 20 Hz cadence.
local BASE_COUPLING = 0.005
-- Gust amplitude as a fraction of the steady load, and how fast it wanders.
local GUST_FRACTION = 0.45
local GUST_RATE_A, GUST_RATE_B = 0.9, 2.3
-- Height of the aerodynamic centre above the physics centre of mass, as a
-- fraction of the vehicle's OBB height.
local AERO_CENTRE_FRACTION = 0.35

local function GustFactor(veh, now)
    local phase = veh:EntIndex() * 1.7
    local a = math.sin(now * GUST_RATE_A + phase)
    local b = math.sin(now * GUST_RATE_B + phase * 0.5)
    return 1 + GUST_FRACTION * (0.6 * a + 0.4 * b)
end

-- Rocking torque about the horizontal axis perpendicular to the wind, once the
-- stress passes TIV.Config.Stress.TorqueMin. AnchoredRockTorque is the peak
-- angular-velocity change in degrees per second at full stress; it is scaled
-- by the body's inertia so it is the same lean on a light and a heavy hull.
local function RockTorque(phys, windDir, stress, gust)
    local torqueMin = TIV.Config.Stress and TIV.Config.Stress.TorqueMin or 0.3
    if stress <= torqueMin then return nil end

    local peakDegPerSec = TIV.Config.AnchoredRockTorque or 5.5
    local ramp = (stress - torqueMin) / math.max(1 - torqueMin, 0.05)
    local deltaOmega = peakDegPerSec * ramp * (gust - 1) * TICK
    if deltaOmega == 0 then return nil end

    local axis = windDir:Cross(vector_up)
    if axis:LengthSqr() < 0.0001 then return nil end
    axis:Normalize()

    local inertia = phys:GetInertia()
    local scalar = (inertia.x + inertia.y + inertia.z) / 3
    return axis * deltaOmega * scalar
end

-- Called from sv_loft.lua ProcessAnchored for every anchored vehicle.
function TIV.Rock.ApplyLoad(veh, data, phys, windMPH, stress)
    if not IsValid(veh) or not IsValid(phys) then return end
    if not phys:IsMotionEnabled() then return end
    if data.gravityReleased then return end   -- loft owns the body from here

    local minMPH = TIV.Config.Stress and TIV.Config.Stress.TurbulenceMinMPH or 50
    if windMPH < minMPH then return end

    local windDir = TIV.Wind.GetDirection(veh)
    if not windDir or windDir:LengthSqr() < 0.0001 then return end
    windDir = Vector(windDir.x, windDir.y, 0)
    if windDir:LengthSqr() < 0.0001 then return end
    windDir:Normalize()

    local now = CurTime()
    local gust = GustFactor(veh, now)
    local scale = (TIV.Config.AnchoredWindForce or 0.8)
        * (TIV.Loft.GetWindScale and TIV.Loft.GetWindScale(veh) or 1)

    local force = windDir * windMPH * TIV.Wind.FORCE_PER_MPH_PER_KG
        * phys:GetMass() * BASE_COUPLING * scale * gust

    local mins, maxs = veh:OBBMins(), veh:OBBMaxs()
    local height = maxs.z - mins.z
    local aeroCentre = phys:LocalToWorld(phys:GetMassCenter() + Vector(0, 0, height * AERO_CENTRE_FRACTION))

    phys:Wake()
    phys:ApplyForceOffset(force, aeroCentre)

    local torque = RockTorque(phys, windDir, stress, gust)
    if torque then phys:ApplyTorqueCenter(torque) end
end

print("[TIV] Anchor load model loaded")
