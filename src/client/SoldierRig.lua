--[[
	SoldierRig
	Procedural low-poly soldier models built from parts (no external assets).

	Every part is described by:
	  pivot  CFrame relative to the soldier's root (feet, facing -Z)
	  rest   CFrame relative to the pivot
	  role   which animation channel drives it (static, legL, legR, arm, offArm,
	         hfl/hfr/hbl/hbr for horse legs)
	World CFrame = root * pivot * animation(role) * rest

	Templates are built once per (unit type, team) and cloned per soldier.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local SoldierRig = {}

local rad = math.rad
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local ID = CFrame.identity

local METAL = Color3.fromRGB(138, 140, 148)
local DARK_METAL = Color3.fromRGB(88, 90, 98)
local LEATHER = Color3.fromRGB(96, 70, 46)
local WOOD = Color3.fromRGB(112, 82, 52)
local GOLD = Color3.fromRGB(212, 172, 72)

SoldierRig.SKIN = {
	Color3.fromRGB(236, 190, 152),
	Color3.fromRGB(214, 160, 120),
	Color3.fromRGB(176, 124, 88),
	Color3.fromRGB(128, 88, 60),
}
SoldierRig.HORSE = {
	Color3.fromRGB(96, 66, 44),
	Color3.fromRGB(64, 46, 34),
	Color3.fromRGB(124, 98, 70),
	Color3.fromRGB(42, 38, 36),
	Color3.fromRGB(150, 128, 100),
}
SoldierRig.GENERAL_HORSE = Color3.fromRGB(212, 208, 200)

local templates = {}

local function lighten(c: Color3, a: number): Color3
	return c:Lerp(Color3.new(1, 1, 1), a)
end

local function newPart(name, size, color, material, shape)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	if shape then
		p.Shape = shape
	end
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local function buildInfantry(add, def, team)
	local tc = team.color
	local weapon = def.weapon

	add("legL", newPart("legL", V3(0.42, 1.6, 0.42), team.dark), CF(-0.24, 1.6, 0), CF(0, -0.8, 0), "legL")
	add("legR", newPart("legR", V3(0.42, 1.6, 0.42), team.dark), CF(0.24, 1.6, 0), CF(0, -0.8, 0), "legR")

	local torsoColor = tc
	local torsoMat = Enum.Material.Fabric
	if weapon == "sword" then
		torsoColor, torsoMat = METAL, Enum.Material.Metal
	elseif weapon == "bow" then
		torsoColor = lighten(tc, 0.25)
	end
	local torso = newPart("torso", V3(1.05, 1.5, 0.6), torsoColor, torsoMat)
	torso.CastShadow = true
	add("torso", torso, ID, CF(0, 2.35, 0), "static")
	if weapon == "sword" then
		add("tabard", newPart("tabard", V3(0.8, 1.35, 0.06), tc, Enum.Material.Fabric), ID, CF(0, 2.2, -0.33), "static")
	end

	add(
		"head",
		newPart("head", V3(0.72, 0.72, 0.72), SoldierRig.SKIN[1], nil, Enum.PartType.Ball),
		ID,
		CF(0, 3.47, 0),
		"static",
		"skin"
	)

	if weapon == "spear" then
		add("helmet", newPart("helmet", V3(0.8, 0.38, 0.8), METAL, Enum.Material.Metal), ID, CF(0, 3.76, 0), "static")
	elseif weapon == "sword" then
		add("helmet", newPart("helmet", V3(0.84, 0.62, 0.84), METAL, Enum.Material.Metal), ID, CF(0, 3.62, 0), "static")
		add(
			"plume",
			newPart("plume", V3(0.14, 0.45, 0.7), team.accent, Enum.Material.Fabric),
			ID,
			CF(0, 4.05, 0.05),
			"static"
		)
	else
		add("hat", newPart("hat", V3(0.95, 0.22, 0.95), LEATHER, Enum.Material.Fabric), ID, CF(0, 3.8, 0), "static")
		add(
			"quiver",
			newPart("quiver", V3(0.35, 1.1, 0.35), LEATHER, Enum.Material.Fabric),
			ID,
			CF(0.22, 2.75, 0.4) * ANG(0, 0, rad(20)),
			"static"
		)
	end

	-- weapon arm (right)
	local shoulderR = CF(0.66, 2.95, 0)
	add(
		"armR",
		newPart("armR", V3(0.32, 1.15, 0.32), torsoColor, torsoMat),
		shoulderR,
		ANG(rad(50), 0, 0) * CF(0, -0.55, 0),
		"arm"
	)
	if weapon == "spear" then
		local hand = CF(0, -0.72, -0.62) * ANG(rad(4), 0, 0)
		add(
			"spear",
			newPart("spear", V3(0.13, 0.13, 7), WOOD, Enum.Material.Wood),
			shoulderR,
			hand * CF(0, 0, -1.6),
			"arm"
		)
		add(
			"tip",
			newPart("tip", V3(0.22, 0.22, 0.55), METAL, Enum.Material.Metal),
			shoulderR,
			hand * CF(0, 0, -5.35),
			"arm"
		)
	elseif weapon == "sword" then
		add(
			"sword",
			newPart("sword", V3(0.12, 1.7, 0.26), lighten(METAL, 0.3), Enum.Material.Metal),
			shoulderR,
			CF(0, -0.85, -0.65) * ANG(rad(-50), 0, 0) * CF(0, 0.8, 0),
			"arm"
		)
	end

	if weapon == "bow" then
		local shoulderL = CF(-0.66, 2.95, 0)
		add(
			"armL",
			newPart("armL", V3(0.3, 1.1, 0.3), torsoColor, torsoMat),
			shoulderL,
			ANG(rad(70), 0, 0) * CF(0, -0.55, 0),
			"offArm"
		)
		add(
			"bow",
			newPart("bow", V3(0.12, 2.7, 0.14), WOOD, Enum.Material.Wood),
			shoulderL,
			CF(0, -0.38, -1.02),
			"offArm"
		)
	else
		if weapon == "sword" then
			local shield = newPart("shield", V3(1.0, 1.4, 0.15), tc, Enum.Material.Wood)
			add("shield", shield, ID, CF(-0.64, 2.35, -0.36) * ANG(0, rad(-15), 0), "static")
			add(
				"boss",
				newPart("boss", V3(0.3, 0.3, 0.1), GOLD, Enum.Material.Metal),
				ID,
				CF(-0.64, 2.35, -0.46) * ANG(0, rad(-15), 0),
				"static"
			)
		else
			-- round shield: cylinder axis (X) turned to face forward
			local shield = newPart("shield", V3(0.16, 1.35, 1.35), tc, Enum.Material.Wood, Enum.PartType.Cylinder)
			add("shield", shield, ID, CF(-0.62, 2.35, -0.38) * ANG(0, rad(90 - 15), 0), "static")
		end
	end
end

local function buildRider(add, def, team)
	local tc = team.color
	local general = def.isGeneral

	-- horse
	add(
		"horseBody",
		newPart("horseBody", V3(1.3, 1.35, 3.8), SoldierRig.HORSE[1]),
		ID,
		CF(0, 3.0, 0.2),
		"static",
		"horse"
	)
	add(
		"horseNeck",
		newPart("horseNeck", V3(0.7, 1.9, 0.85), SoldierRig.HORSE[1]),
		ID,
		CF(0, 3.95, -1.75) * ANG(rad(-35), 0, 0),
		"static",
		"horse"
	)
	add(
		"horseHead",
		newPart("horseHead", V3(0.62, 0.62, 1.35), SoldierRig.HORSE[1]),
		ID,
		CF(0, 4.6, -2.5) * ANG(rad(-25), 0, 0),
		"static",
		"horse"
	)
	add(
		"tail",
		newPart("tail", V3(0.25, 1.4, 0.25), DARK_METAL:Lerp(LEATHER, 0.5)),
		ID,
		CF(0, 2.9, 2.25) * ANG(rad(-25), 0, 0),
		"static"
	)
	add(
		"caparison",
		newPart("caparison", V3(1.36, 0.7, 2.6), general and GOLD or tc, Enum.Material.Fabric),
		ID,
		CF(0, 3.25, 0.3),
		"static"
	)
	local legs = {
		{ "hfl", -0.45, -1.3 },
		{ "hfr", 0.45, -1.3 },
		{ "hbl", -0.45, 1.5 },
		{ "hbr", 0.45, 1.5 },
	}
	for _, l in legs do
		add(
			l[1],
			newPart(l[1], V3(0.32, 2.45, 0.32), SoldierRig.HORSE[1]),
			CF(l[2], 2.45, l[3]),
			CF(0, -1.2, 0),
			l[1],
			"horse"
		)
	end

	-- rider
	local torso = newPart(
		"torso",
		V3(0.95, 1.3, 0.55),
		general and METAL or tc,
		general and Enum.Material.Metal or Enum.Material.Fabric
	)
	torso.CastShadow = true
	add("torso", torso, ID, CF(0, 4.3, 0.4), "static")
	add(
		"riderLegL",
		newPart("riderLegL", V3(0.35, 1.1, 0.35), team.dark),
		ID,
		CF(-0.62, 3.6, 0.2) * ANG(rad(-15), 0, 0),
		"static"
	)
	add(
		"riderLegR",
		newPart("riderLegR", V3(0.35, 1.1, 0.35), team.dark),
		ID,
		CF(0.62, 3.6, 0.2) * ANG(rad(-15), 0, 0),
		"static"
	)
	add(
		"head",
		newPart("head", V3(0.68, 0.68, 0.68), SoldierRig.SKIN[1], nil, Enum.PartType.Ball),
		ID,
		CF(0, 5.3, 0.4),
		"static",
		"skin"
	)
	add(
		"helmet",
		newPart("helmet", V3(0.8, 0.6, 0.8), general and GOLD or METAL, Enum.Material.Metal),
		ID,
		CF(0, 5.48, 0.4),
		"static"
	)
	add(
		"plume",
		newPart(
			"plume",
			V3(0.14, 0.5, 0.75),
			general and Color3.fromRGB(240, 240, 240) or team.accent,
			Enum.Material.Fabric
		),
		ID,
		CF(0, 5.95, 0.45),
		"static"
	)

	local shoulderR = CF(0.62, 4.85, 0.4)
	add("armR", newPart("armR", V3(0.3, 1.1, 0.3), tc), shoulderR, ANG(rad(50), 0, 0) * CF(0, -0.5, 0), "arm")
	if def.weapon == "lance" then
		local hand = CF(0, -0.7, -0.6) * ANG(rad(-6), 0, 0)
		add(
			"lance",
			newPart("lance", V3(0.16, 0.16, 8.5), WOOD, Enum.Material.Wood),
			shoulderR,
			hand * CF(0, 0, -2.6),
			"arm"
		)
		add(
			"pennant",
			newPart("pennant", V3(0.04, 0.45, 0.9), tc, Enum.Material.Fabric),
			shoulderR,
			hand * CF(0, 0.3, -6.0),
			"arm"
		)
	else
		add(
			"sword",
			newPart("sword", V3(0.12, 1.9, 0.26), lighten(METAL, 0.3), Enum.Material.Metal),
			shoulderR,
			CF(0, -0.85, -0.6) * ANG(rad(-50), 0, 0) * CF(0, 0.9, 0),
			"arm"
		)
	end
	add("shield", newPart("shield", V3(0.14, 1.1, 0.85), tc, Enum.Material.Wood), ID, CF(-0.62, 4.3, 0.2), "static")
end

local function buildBanner(add, def, team, rider)
	local base = rider and 4.4 or 2.6
	add(
		"pole",
		newPart("pole", V3(0.12, 5.6, 0.12), WOOD, Enum.Material.Wood),
		ID,
		CF(0.15, base + 2.6, 0.5),
		"static",
		"banner"
	)
	local flag = newPart("flag", V3(0.06, 1.4, 1.9), def.isGeneral and GOLD or team.color, Enum.Material.Fabric)
	flag.CastShadow = true
	add("flag", flag, ID, CF(0.15, base + 4.6, 1.45), "static", "banner")
end

--[[
	Returns template info:
	  model   Model containing all parts
	  rig     array of { name, pivot, rest, offset (pivot*rest), role, tag }
	  isRider boolean
	  anim    "thrust" | "swing" | "bow"
]]
function SoldierRig.get(typeKey: string, teamId: number)
	local key = typeKey .. "_" .. teamId
	local cached = templates[key]
	if cached then
		return cached
	end

	local def = Config.UnitTypes[typeKey]
	local team = Config.Teams[teamId]
	local model = Instance.new("Model")
	model.Name = key
	local rig = {}
	local function add(name, part, pivot, rest, role, tag)
		part.Name = name
		part.Parent = model
		table.insert(rig, {
			name = name,
			pivot = pivot,
			rest = rest,
			offset = pivot * rest,
			role = role,
			tag = tag,
		})
	end

	local rider = def.category == "cavalry"
	if rider then
		buildRider(add, def, team)
	else
		buildInfantry(add, def, team)
	end
	buildBanner(add, def, team, rider)

	local anim = "swing"
	if def.weapon == "spear" or def.weapon == "lance" then
		anim = "thrust"
	elseif def.weapon == "bow" then
		anim = "bow"
	end

	local info = { model = model, rig = rig, isRider = rider, anim = anim }
	templates[key] = info
	return info
end

return SoldierRig
