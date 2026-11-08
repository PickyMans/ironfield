--[[
	Unit tests for shared modules (run with `lune run tools/unit.luau`).
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local modules = {}
local function load(name)
	if modules[name] then
		return modules[name]
	end
	local node = setmetatable({}, {
		__index = function(_, k)
			if k == "Parent" then
				return setmetatable({}, {
					__index = function(_, child)
						return { _name = child }
					end,
				})
			end
			return nil
		end,
	})
	local env = {
		script = node,
		Color3 = roblox.Color3,
		require = function(n)
			return load(n._name)
		end,
		game = {
			GetService = function()
				return {}
			end,
		},
	}
	local fn = luau.load(
		fs.readFile("src/shared/" .. name .. ".lua"),
		{ debugName = name, environment = env, injectGlobals = true }
	)
	modules[name] = fn()
	return modules[name]
end

local Config = load("Config")
local Formation = load("Formation")
local Codec = load("Codec")

local failures = 0
local function check(cond, msg)
	if cond then
		print("  ok   " .. msg)
	else
		failures += 1
		print("  FAIL " .. msg)
	end
end
local function near(a, b, eps)
	return math.abs(a - b) <= (eps or 1e-3)
end

print("Formation")
do
	-- facing -Z: right should be +X
	local x1 = Formation.slotWorld(0, 0, 0, -1, 1, 4, 4, 2, 2)
	local x4 = Formation.slotWorld(0, 0, 0, -1, 4, 4, 4, 2, 2)
	check(x1 < 0 and x4 > 0, "files run left-to-right along the right vector")
	local _, zBack = Formation.slotWorld(0, 0, 0, -1, 5, 8, 4, 2, 2)
	check(zBack > 0, "second rank stands behind the first (facing -Z)")
	local a = Formation.angleOf(0.6, 0.8)
	local fx, fz = Formation.vecOf(a)
	check(near(fx, 0.6) and near(fz, 0.8), "angleOf / vecOf round trip")

	local def = Config.UnitTypes.Spearmen
	local regs = {
		{ id = 1, def = def, alive = 60, x = 50, z = 0, fx = 0, fz = -1, width = 20 },
		{ id = 2, def = def, alive = 60, x = -50, z = 0, fx = 0, fz = -1, width = 20 },
	}
	-- drag left to right while looking down -Z
	local plans = Formation.planLine(regs, -60, 0, 60, 0)
	check(#plans == 2, "planLine returns one plan per regiment")
	check(plans[1].id == 2 and plans[1].x < plans[2].x, "regiments keep their left/right order on the line")
	check(near(plans[1].fx, 0) and near(plans[1].fz, -1), "line faces away from the camera side")
	check(plans[1].width >= 4 and plans[1].width <= 60, "width clamped to sane range")

	local short = Formation.planLine(regs, 0, 0, 4, 0)
	check(short[1].width == Formation.minWidth(def, 60), "very short line gives minimum width (deep column)")

	local g = Formation.planGroupMove(regs, 0, -100)
	check(near(g[1].fz, -1, 1e-2) and near(g[2].fz, -1, 1e-2), "group move forward keeps facing")
	local g2 = Formation.planGroupMove(regs, 0, 100)
	check(g2[1].fz > 0.99, "group move backwards turns the group around")
	local d1 = math.abs(g2[1].x - g2[2].x)
	check(near(d1, 100, 0.5), "group keeps its spacing after turning")

	local soldiers = {}
	for i = 1, 12 do
		soldiers[i] = { x = (i % 4) * 2, z = (i // 4) * 2 }
	end
	Formation.assignSlots(soldiers, 0, -1, 4)
	local seen = {}
	for _, s in soldiers do
		seen[s.slot] = true
	end
	local all = true
	for i = 1, 12 do
		all = all and seen[i] == true
	end
	check(all, "assignSlots gives every soldier a unique slot")
end

print("Codec")
do
	local soldiers = {
		{ index = 1, x = 12.34, z = -400.56, facing = 1.2, flags = 1 + 4 },
		{ index = 60, x = -479.9, z = 479.9, facing = 6.0, flags = 8 },
	}
	local buf = Codec.encodeSnapshot({
		{
			id = 7,
			alive = 59,
			morale = 63.6,
			state = 2,
			ammo = 255,
			flags = 3,
			ax = 1.5,
			az = -2.5,
			facing = 3.0,
			width = 20,
			entries = soldiers,
		},
		{
			id = 8,
			alive = 0,
			morale = 0,
			state = 6,
			ammo = 0,
			flags = 0,
			ax = 0,
			az = 0,
			facing = 0,
			width = 1,
			entries = {},
		},
	})
	local regs = Codec.decodeSnapshot(buf)
	check(#regs == 2, "two regiments decoded")
	local r = regs[1]
	check(r.id == 7 and r.alive == 59 and r.morale == 64 and r.state == 2 and r.width == 20, "header fields")
	check(near(r.ax, 1.5, 0.05) and near(r.az, -2.5, 0.05), "anchor position")
	check(#r.entries == 2 and r.entries[2].index == 60, "entries and indices")
	check(near(r.entries[1].x, 12.34, 0.06) and near(r.entries[1].z, -400.56, 0.06), "soldier position precision")
	check(
		math.abs(((r.entries[1].facing - 1.2 + math.pi) % (2 * math.pi)) - math.pi) < 0.03,
		"soldier facing precision"
	)
	check(r.entries[1].flags == 5 and r.entries[2].flags == 8, "soldier flags")

	local v =
		Codec.decodeVolley(Codec.encodeVolley({ { regId = 3, index = 40, tx = -100.25, tz = 55.5, flight = 2.37 } }))
	check(#v == 1 and v[1].regId == 3 and v[1].index == 40 and near(v[1].flight, 2.37, 0.01), "volley round trip")
end

if failures > 0 then
	error(failures .. " test(s) failed")
end
print("all tests passed")
