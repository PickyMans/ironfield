--[[
	Formation
	Geometry helpers for regiment formations plus the order "planner" that turns
	a click or a right-drag line into a destination for each selected regiment.

	Conventions
	  * A formation is anchored at the centre of its FRONT rank.
	  * Facing is a unit vector (fx, fz) on the XZ plane.
	  * right = (-fz, fx)  (matches Roblox: looking down -Z, right is +X)
	  * Angles: a = atan2(fx, fz)  <=>  fx = sin a, fz = cos a
]]

local Formation = {}

local GAP = 4 -- studs between regiments placed on the same line

function Formation.angleOf(fx: number, fz: number): number
	return math.atan2(fx, fz)
end

function Formation.vecOf(a: number): (number, number)
	return math.sin(a), math.cos(a)
end

function Formation.normalize(x: number, z: number): (number, number, number)
	local m = math.sqrt(x * x + z * z)
	if m < 1e-6 then
		return 0, -1, 0
	end
	return x / m, z / m, m
end

-- Lateral / backward offset of slot i (1-based) in a block of n soldiers, w files wide.
function Formation.slotOffset(i: number, n: number, w: number, sx: number, sz: number): (number, number)
	local idx = i - 1
	local rank = idx // w
	local file = idx % w
	local ranks = math.ceil(n / w)
	local inRank = w
	if rank == ranks - 1 then
		inRank = n - rank * w
	end
	return (file - (inRank - 1) / 2) * sx, rank * sz
end

function Formation.slotWorld(cx, cz, fx, fz, i, n, w, sx, sz): (number, number)
	local lat, back = Formation.slotOffset(i, n, w, sx, sz)
	local rx, rz = -fz, fx
	return cx + rx * lat - fx * back, cz + rz * lat - fz * back
end

function Formation.depth(n: number, w: number, sz: number): number
	return (math.ceil(n / math.max(w, 1)) - 1) * sz
end

function Formation.frontage(w: number, sx: number): number
	return (w - 1) * sx
end

function Formation.minWidth(def, alive: number): number
	local m = def.isLarge and 3 or 4
	return math.min(alive, m)
end

function Formation.clampWidth(def, alive: number, w: number): number
	alive = math.max(alive, 1)
	return math.clamp(math.floor(w + 0.5), Formation.minWidth(def, alive), alive)
end

function Formation.defaultWidth(def, alive: number): number
	return Formation.clampWidth(def, alive, math.min(def.defaultWidth, alive))
end

--[[
	Assign soldiers to slots so they don't cross through each other:
	sort by depth along the new facing (front first), cut into ranks,
	then sort each rank left-to-right.
	soldiers: array of objects with .x .z ; writes .slot on each.
]]
function Formation.assignSlots(soldiers, fx: number, fz: number, w: number)
	local n = #soldiers
	if n == 0 then
		return
	end
	local rx, rz = -fz, fx
	for _, s in soldiers do
		s._fwd = s.x * fx + s.z * fz
		s._lat = s.x * rx + s.z * rz
	end
	table.sort(soldiers, function(a, b)
		return a._fwd > b._fwd
	end)
	local ranks = math.ceil(n / w)
	local slot = 1
	for r = 0, ranks - 1 do
		local first = r * w + 1
		local last = math.min(n, first + w - 1)
		local rank = table.move(soldiers, first, last, 1, {})
		table.sort(rank, function(a, b)
			return a._lat < b._lat
		end)
		for _, s in rank do
			s.slot = slot
			slot += 1
		end
	end
end

--[[
	Planner input: array of
	  { id, def, alive, x, z, fx, fz, width }   (x,z = current anchor)
	Output: array of { id, x, z, fx, fz, width }
]]

-- Right-drag: spread the regiments along the line A->B, facing away from the camera side.
function Formation.planLine(regs, ax: number, az: number, bx: number, bz: number)
	local rx, rz, len = Formation.normalize(bx - ax, bz - az)
	local fx, fz = rz, -rx

	local list = table.clone(regs)
	table.sort(list, function(a, b)
		return (a.x * rx + a.z * rz) < (b.x * rx + b.z * rz)
	end)

	local totalWeight = 0
	for _, r in list do
		r._w = math.min(r.def.defaultWidth, r.alive) * r.def.spacingX
		totalWeight += r._w
	end

	local usable = math.max(len - GAP * (#list - 1), 1)
	local out = {}
	local cursor = 0
	for _, r in list do
		local share = usable * r._w / totalWeight
		local width = Formation.clampWidth(r.def, r.alive, share / r.def.spacingX)
		local mid = cursor + share / 2
		table.insert(out, {
			id = r.id,
			x = ax + rx * mid,
			z = az + rz * mid,
			fx = fx,
			fz = fz,
			width = width,
		})
		cursor += share + GAP
	end
	return out
end

-- Click: move the group keeping its shape; rotate it to face the direction of travel.
function Formation.planGroupMove(regs, tx: number, tz: number)
	local n = #regs
	if n == 0 then
		return {}
	end
	local gx, gz, afx, afz = 0, 0, 0, 0
	for _, r in regs do
		gx += r.x
		gz += r.z
		afx += r.fx
		afz += r.fz
	end
	gx /= n
	gz /= n
	afx, afz = Formation.normalize(afx, afz)

	local dx, dz, dist = Formation.normalize(tx - gx, tz - gz)
	local nfx, nfz = afx, afz
	if dist > 14 then
		nfx, nfz = dx, dz
	end

	local c = afx * nfx + afz * nfz
	local s = afx * nfz - afz * nfx

	local out = {}
	for _, r in regs do
		local ox, oz = r.x - gx, r.z - gz
		local rfx, rfz = r.fx * c - r.fz * s, r.fx * s + r.fz * c
		if n == 1 then
			rfx, rfz = nfx, nfz
		end
		table.insert(out, {
			id = r.id,
			x = tx + ox * c - oz * s,
			z = tz + ox * s + oz * c,
			fx = rfx,
			fz = rfz,
			width = r.width,
		})
	end
	return out
end

return Formation
