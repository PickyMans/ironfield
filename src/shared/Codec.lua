--[[
	Codec
	Compact binary encoding for the per-tick network traffic.

	Snapshot layout
	  u16 regimentCount
	  per regiment (16 bytes):
	    u16 id, u16 alive, u8 morale, u8 state, u8 ammo(255 = n/a), u8 flags,
	    i16 anchorX, i16 anchorZ, u8 facing, u8 width, u16 entryCount
	  per entry (7 bytes):
	    u8 soldierIndex-1, i16 x, i16 z, u8 facing, u8 soldierFlags

	Volley layout
	  u16 count, per arrow: u16 regId, u8 soldierIndex-1, i16 tx, i16 tz, u16 flightTime*100
]]

local Config = require(script.Parent.Config)

local Codec = {}

local Q = Config.POS_QUANT
local TAU = math.pi * 2

-- regiment flags
Codec.RF_RUNNING = 1
Codec.RF_FIRE_AT_WILL = 2
Codec.RF_CHARGING = 4

-- soldier flags
Codec.SF_ALIVE = 1
Codec.SF_ATTACK_MASK = 6 -- 2-bit counter, increments on every swing / shot
Codec.SF_ESCAPED = 8
Codec.SF_MELEE = 16

local function qpos(v: number): number
	return math.clamp(math.floor(v * Q + 0.5), -32768, 32767)
end

function Codec.qangle(a: number): number
	return math.floor(((a % TAU) / TAU) * 256 + 0.5) % 256
end

function Codec.dangle(q: number): number
	return q / 256 * TAU
end

--[[
	regs: array of {
	  id, alive, morale, state, ammo, flags, ax, az, facing(angle), width,
	  entries = array of soldier objects { index, x, z, facing(angle), flags }
	}
]]
function Codec.encodeSnapshot(regs): buffer
	local size = 2
	for _, r in regs do
		size += 16 + #r.entries * 7
	end
	local b = buffer.create(size)
	local o = 0
	buffer.writeu16(b, o, #regs)
	o += 2
	for _, r in regs do
		buffer.writeu16(b, o, r.id)
		buffer.writeu16(b, o + 2, r.alive)
		buffer.writeu8(b, o + 4, math.clamp(math.floor(r.morale + 0.5), 0, 255))
		buffer.writeu8(b, o + 5, r.state)
		buffer.writeu8(b, o + 6, r.ammo)
		buffer.writeu8(b, o + 7, r.flags)
		buffer.writei16(b, o + 8, qpos(r.ax))
		buffer.writei16(b, o + 10, qpos(r.az))
		buffer.writeu8(b, o + 12, Codec.qangle(r.facing))
		buffer.writeu8(b, o + 13, math.clamp(r.width, 0, 255))
		buffer.writeu16(b, o + 14, #r.entries)
		o += 16
		for _, s in r.entries do
			buffer.writeu8(b, o, s.index - 1)
			buffer.writei16(b, o + 1, qpos(s.x))
			buffer.writei16(b, o + 3, qpos(s.z))
			buffer.writeu8(b, o + 5, Codec.qangle(s.facing))
			buffer.writeu8(b, o + 6, s.flags)
			o += 7
		end
	end
	return b
end

function Codec.decodeSnapshot(b: buffer)
	local len = buffer.len(b)
	local o = 0
	local count = buffer.readu16(b, o)
	o += 2
	local regs = table.create(count)
	for _ = 1, count do
		if o + 16 > len then
			break
		end
		local r = {
			id = buffer.readu16(b, o),
			alive = buffer.readu16(b, o + 2),
			morale = buffer.readu8(b, o + 4),
			state = buffer.readu8(b, o + 5),
			ammo = buffer.readu8(b, o + 6),
			flags = buffer.readu8(b, o + 7),
			ax = buffer.readi16(b, o + 8) / Q,
			az = buffer.readi16(b, o + 10) / Q,
			facing = Codec.dangle(buffer.readu8(b, o + 12)),
			width = buffer.readu8(b, o + 13),
		}
		local n = buffer.readu16(b, o + 14)
		o += 16
		local entries = table.create(n)
		for i = 1, n do
			entries[i] = {
				index = buffer.readu8(b, o) + 1,
				x = buffer.readi16(b, o + 1) / Q,
				z = buffer.readi16(b, o + 3) / Q,
				facing = Codec.dangle(buffer.readu8(b, o + 5)),
				flags = buffer.readu8(b, o + 6),
			}
			o += 7
		end
		r.entries = entries
		regs[#regs + 1] = r
	end
	return regs
end

-- arrows: array of { regId, index, tx, tz, flight }
function Codec.encodeVolley(arrows): buffer
	local b = buffer.create(2 + #arrows * 9)
	buffer.writeu16(b, 0, #arrows)
	local o = 2
	for _, a in arrows do
		buffer.writeu16(b, o, a.regId)
		buffer.writeu8(b, o + 2, a.index - 1)
		buffer.writei16(b, o + 3, qpos(a.tx))
		buffer.writei16(b, o + 5, qpos(a.tz))
		buffer.writeu16(b, o + 7, math.clamp(math.floor(a.flight * 100 + 0.5), 0, 65535))
		o += 9
	end
	return b
end

function Codec.decodeVolley(b: buffer)
	local n = buffer.readu16(b, 0)
	local out = table.create(n)
	local o = 2
	for i = 1, n do
		out[i] = {
			regId = buffer.readu16(b, o),
			index = buffer.readu8(b, o + 2) + 1,
			tx = buffer.readi16(b, o + 3) / Q,
			tz = buffer.readi16(b, o + 5) / Q,
			flight = buffer.readu16(b, o + 7) / 100,
		}
		o += 9
	end
	return out
end

return Codec
