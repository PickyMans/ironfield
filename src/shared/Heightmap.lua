--[[
	Heightmap
	A deterministic height function shared by the server (terrain generation,
	high-ground bonuses) and the client (placing soldiers on the ground).
	Both sides call setSeed with the battle seed so they agree exactly.
]]

local Heightmap = {}

local seed = 0.37
local EDGE_START = 470

function Heightmap.setSeed(s: number)
	-- math.noise returns 0 on integer lattice points, so keep the seed fractional
	seed = (s % 1000) + 0.37
end

function Heightmap.getSeed()
	return seed
end

function Heightmap.get(x: number, z: number): number
	local s = seed
	local h = math.noise(x / 260, z / 260, s) * 18
		+ math.noise(x / 105, z / 105, s + 11.31) * 6
		+ math.noise(x / 38, z / 38, s + 23.73) * 1.1

	-- soften the middle of the field a little so the main clash is playable
	local r = math.sqrt(x * x + z * z)
	if r < 260 then
		h *= 0.55 + 0.45 * (r / 260)
	end

	-- the map rises into hills near its edges
	local edge = math.max(math.abs(x), math.abs(z))
	if edge > EDGE_START then
		h += math.min((edge - EDGE_START) * 0.5, 34)
	end

	return h + 10
end

-- Steepness (rise over run) used for terrain material selection.
function Heightmap.slope(x: number, z: number): number
	local e = 2
	local dx = Heightmap.get(x + e, z) - Heightmap.get(x - e, z)
	local dz = Heightmap.get(x, z + e) - Heightmap.get(x, z - e)
	return math.sqrt(dx * dx + dz * dz) / (2 * e)
end

return Heightmap
