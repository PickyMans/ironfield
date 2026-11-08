--[[
	SpatialHash
	Uniform grid for fast neighbour queries between soldiers. Rebuilt every tick.
]]

local SpatialHash = {}
SpatialHash.__index = SpatialHash

local function key(cx: number, cz: number): number
	return cx * 8192 + cz
end

function SpatialHash.new(cellSize: number)
	return setmetatable({
		cell = cellSize,
		cells = {},
	}, SpatialHash)
end

function SpatialHash:clear()
	-- keep bucket tables around to avoid garbage; just empty them
	for _, bucket in self.cells do
		table.clear(bucket)
	end
end

function SpatialHash:insert(obj, x: number, z: number)
	local c = self.cell
	local k = key(x // c, z // c)
	local bucket = self.cells[k]
	if not bucket then
		bucket = {}
		self.cells[k] = bucket
	end
	bucket[#bucket + 1] = obj
end

-- Fills `out` with candidates in all cells overlapping the radius. Returns the count.
-- Candidates are NOT distance filtered.
function SpatialHash:query(x: number, z: number, radius: number, out): number
	local c = self.cell
	local x0, x1 = (x - radius) // c, (x + radius) // c
	local z0, z1 = (z - radius) // c, (z + radius) // c
	local n = 0
	local cells = self.cells
	for cx = x0, x1 do
		for cz = z0, z1 do
			local bucket = cells[key(cx, cz)]
			if bucket then
				for i = 1, #bucket do
					n += 1
					out[n] = bucket[i]
				end
			end
		end
	end
	return n
end

return SpatialHash
