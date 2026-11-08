--[[
	Config
	All tunable game data lives here: simulation rates, map size, factions,
	unit stats and default army compositions. Server and client both read it.
]]

local Config = {}

-- Simulation ---------------------------------------------------------------
Config.TICK_RATE = 20 -- server simulation ticks per second
Config.SNAPSHOT_EVERY = 2 -- send a network snapshot every N ticks (10 Hz)
Config.POS_QUANT = 10 -- positions are sent as int16 * 1/POS_QUANT studs

-- Map ----------------------------------------------------------------------
Config.MAP_HALF = 560 -- terrain is generated from -MAP_HALF..MAP_HALF
Config.PLAY_HALF = 480 -- units that route past this line leave the battle
Config.DEPLOY_HALF_WIDTH = 300

-- Combat tuning --------------------------------------------------------------
Config.CONTACT_RADIUS = 3.5 -- enemy soldiers this close put regiments in melee
Config.MELEE_SEARCH_RADIUS = 14
Config.ROUT_THRESHOLD = 15 -- morale below this -> route
Config.RALLY_THRESHOLD = 38
Config.SHATTER_FRACTION = 0.2 -- below this fraction of men a route is permanent
Config.MAX_ROUTS = 3
Config.GENERAL_AURA = 90
Config.CHARGE_RANGE_INFANTRY = 40
Config.CHARGE_RANGE_CAVALRY = 70

Config.Teams = {
	[1] = {
		name = "Azure Kingdom",
		color = Color3.fromRGB(46, 98, 196),
		dark = Color3.fromRGB(24, 48, 102),
		accent = Color3.fromRGB(226, 196, 112),
		frontZ = 220,
		deployZ = { 170, 440 },
		facingZ = -1, -- the direction this army faces at deployment
	},
	[2] = {
		name = "Crimson Host",
		color = Color3.fromRGB(178, 38, 38),
		dark = Color3.fromRGB(90, 18, 18),
		accent = Color3.fromRGB(40, 36, 32),
		frontZ = -220,
		deployZ = { -440, -170 },
		facingZ = 1,
	},
}

--[[
	Unit stats
	  men            soldiers in the regiment (max 255)
	  hp             hit points per soldier
	  armor          0-100, percentage of base damage blocked
	  meleeAttack    raises hit chance
	  meleeDefense   lowers enemy hit chance (ignored when flanked from the rear)
	  damage / ap    base damage (reduced by armor) / armor-piercing damage
	  chargeBonus    attack + damage bonus for a few seconds after charging in
	  bonusVsLarge   attack bonus against cavalry
	  shield         chance to block arrows coming from the front
	  morale         base leadership
	  spacingX/Z     distance between files / ranks
]]
Config.UnitTypes = {
	Spearmen = {
		displayName = "Spear Levy",
		short = "SP",
		category = "infantry",
		weapon = "spear",
		men = 60,
		hp = 80,
		armor = 35,
		meleeAttack = 24,
		meleeDefense = 42,
		damage = 18,
		ap = 5,
		chargeBonus = 8,
		bonusVsLarge = 24,
		attackInterval = 1.6,
		reach = 3.4,
		shield = 0.45,
		morale = 58,
		walkSpeed = 8,
		runSpeed = 15,
		spacingX = 1.6,
		spacingZ = 1.8,
		defaultWidth = 20,
		mass = 1,
	},
	Swordsmen = {
		displayName = "Iron Blades",
		short = "SW",
		category = "infantry",
		weapon = "sword",
		men = 50,
		hp = 90,
		armor = 48,
		meleeAttack = 38,
		meleeDefense = 30,
		damage = 24,
		ap = 7,
		chargeBonus = 14,
		bonusVsLarge = 0,
		attackInterval = 1.4,
		reach = 2.6,
		shield = 0.5,
		morale = 66,
		walkSpeed = 8,
		runSpeed = 15.5,
		spacingX = 1.6,
		spacingZ = 1.8,
		defaultWidth = 17,
		mass = 1,
	},
	Archers = {
		displayName = "Longbowmen",
		short = "AR",
		category = "ranged",
		weapon = "bow",
		men = 40,
		hp = 65,
		armor = 15,
		meleeAttack = 14,
		meleeDefense = 12,
		damage = 12,
		ap = 2,
		chargeBonus = 4,
		bonusVsLarge = 0,
		attackInterval = 1.6,
		reach = 2.4,
		shield = 0,
		morale = 46,
		walkSpeed = 8.5,
		runSpeed = 16,
		spacingX = 1.9,
		spacingZ = 2.0,
		defaultWidth = 20,
		mass = 1,
		ranged = {
			range = 170,
			damage = 22,
			ap = 6,
			reload = 5.5,
			ammo = 30,
			accuracy = 0.7,
			projectileSpeed = 85,
		},
	},
	Cavalry = {
		displayName = "Lancers",
		short = "CV",
		category = "cavalry",
		weapon = "lance",
		men = 24,
		hp = 130,
		armor = 40,
		meleeAttack = 32,
		meleeDefense = 22,
		damage = 22,
		ap = 8,
		chargeBonus = 45,
		bonusVsLarge = 0,
		attackInterval = 1.7,
		reach = 3.4,
		shield = 0.25,
		morale = 60,
		walkSpeed = 12,
		runSpeed = 28,
		spacingX = 2.6,
		spacingZ = 4.4,
		defaultWidth = 12,
		isLarge = true,
		mass = 4,
	},
	General = {
		displayName = "General's Guard",
		short = "GN",
		category = "cavalry",
		weapon = "sword",
		men = 12,
		hp = 190,
		armor = 58,
		meleeAttack = 42,
		meleeDefense = 34,
		damage = 26,
		ap = 10,
		chargeBonus = 38,
		bonusVsLarge = 0,
		attackInterval = 1.5,
		reach = 3.2,
		shield = 0.35,
		morale = 82,
		walkSpeed = 12,
		runSpeed = 27,
		spacingX = 2.6,
		spacingZ = 4.4,
		defaultWidth = 6,
		isLarge = true,
		isGeneral = true,
		mass = 4,
	},
}

--[[
	Default deployment, in an army-local frame:
	  x = lateral offset (positive = the army's right)
	  depth = distance behind the front line
]]
Config.Army = {
	{ type = "Cavalry", x = -135, depth = 12 },
	{ type = "Spearmen", x = -76, depth = 0 },
	{ type = "Swordsmen", x = -38, depth = 0 },
	{ type = "Spearmen", x = 0, depth = 0 },
	{ type = "Swordsmen", x = 38, depth = 0 },
	{ type = "Spearmen", x = 76, depth = 0 },
	{ type = "Cavalry", x = 135, depth = 12 },
	{ type = "Archers", x = -42, depth = 26 },
	{ type = "Archers", x = 42, depth = 26 },
	{ type = "General", x = 0, depth = 58 },
}

-- Regiment state ids (sent over the network as u8)
Config.States = {
	Idle = 0,
	Moving = 1,
	Melee = 2,
	Firing = 3,
	Routing = 4,
	Shattered = 5,
	Dead = 6,
}
Config.StateNames = {}
for name, id in Config.States do
	Config.StateNames[id] = name
end

return Config
