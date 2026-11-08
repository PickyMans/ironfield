--[[
	CameraController
	Free RTS camera.
	  WASD / arrows   pan          Shift   pan faster
	  Q / E           rotate       Wheel   zoom
	  Middle mouse    drag to rotate and tilt
	  Mouse at screen edge pans (toggleable)
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Heightmap = require(Shared.Heightmap)

local CameraController = {}

local camera = workspace.CurrentCamera

local focusX, focusZ = 0, 0
local yaw, pitch, distance = 0, math.rad(42), 140
-- smoothed values actually used for rendering
local sFocusX, sFocusZ, sYaw, sPitch, sDistance = 0, 0, 0, math.rad(42), 140

local MIN_DIST, MAX_DIST = 18, 520
local MIN_PITCH, MAX_PITCH = math.rad(12), math.rad(84)

local rotating = false
CameraController.edgePan = false

local function clampFocus()
	local h = Config.MAP_HALF - 20
	focusX = math.clamp(focusX, -h, h)
	focusZ = math.clamp(focusZ, -h, h)
end

function CameraController.focusOn(x: number, z: number, instant: boolean?)
	focusX, focusZ = x, z
	clampFocus()
	if instant then
		sFocusX, sFocusZ = focusX, focusZ
	end
end

function CameraController.setView(x: number, z: number, newYaw: number, newDist: number?, instant: boolean?)
	CameraController.focusOn(x, z, instant)
	yaw = newYaw
	distance = newDist or distance
	if instant then
		sYaw, sDistance = yaw, distance
	end
end

function CameraController.getYaw(): number
	return sYaw
end

function CameraController.init()
	camera.CameraType = Enum.CameraType.Scriptable

	UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.MouseButton3 and not processed then
			rotating = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton3 then
			rotating = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.MouseWheel and not processed then
			distance = math.clamp(distance * (0.87 ^ input.Position.Z), MIN_DIST, MAX_DIST)
		elseif input.UserInputType == Enum.UserInputType.MouseMovement and rotating then
			yaw -= input.Delta.X * 0.006
			pitch = math.clamp(pitch + input.Delta.Y * 0.005, MIN_PITCH, MAX_PITCH)
		end
	end)
end

local function keyDown(...)
	for _, k in { ... } do
		if UserInputService:IsKeyDown(k) then
			return true
		end
	end
	return false
end

function CameraController.update(dt: number)
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	local typing = UserInputService:GetFocusedTextBox() ~= nil
	local K = Enum.KeyCode
	local moveX, moveZ = 0, 0
	if not typing then
		if keyDown(K.W, K.Up) then
			moveZ += 1
		end
		if keyDown(K.S, K.Down) then
			moveZ -= 1
		end
		if keyDown(K.D, K.Right) then
			moveX += 1
		end
		if keyDown(K.A, K.Left) then
			moveX -= 1
		end
		if keyDown(K.Q) then
			yaw += 1.6 * dt
		end
		if keyDown(K.E) then
			yaw -= 1.6 * dt
		end
	end

	if CameraController.edgePan then
		local m = UserInputService:GetMouseLocation()
		local vp = camera.ViewportSize
		local edge = 6
		if m.X <= edge then
			moveX -= 1
		elseif m.X >= vp.X - edge then
			moveX += 1
		end
		if m.Y <= edge then
			moveZ += 1
		elseif m.Y >= vp.Y - edge then
			moveZ -= 1
		end
	end

	if moveX ~= 0 or moveZ ~= 0 then
		local speed = (40 + distance * 1.4) * (keyDown(K.LeftShift, K.RightShift) and 2.2 or 1)
		-- forward on the ground plane for the current yaw (look vector at yaw is (-sin, -cos))
		local fx, fz = -math.sin(yaw), -math.cos(yaw)
		local rx, rz = math.cos(yaw), -math.sin(yaw)
		local mag = math.sqrt(moveX * moveX + moveZ * moveZ)
		focusX += (fx * moveZ + rx * moveX) / mag * speed * dt
		focusZ += (fz * moveZ + rz * moveX) / mag * speed * dt
		clampFocus()
	end

	-- smoothing
	local k = 1 - math.exp(-dt * 12)
	sFocusX += (focusX - sFocusX) * k
	sFocusZ += (focusZ - sFocusZ) * k
	sYaw += (yaw - sYaw) * k
	sPitch += (pitch - sPitch) * k
	sDistance += (distance - sDistance) * k

	-- zooming in flattens the view a bit, like a battlefield camera
	local zoomT = math.clamp((sDistance - MIN_DIST) / 160, 0, 1)
	local effPitch = math.clamp(sPitch * (0.55 + 0.45 * zoomT), MIN_PITCH, MAX_PITCH)

	local focusY = Heightmap.get(sFocusX, sFocusZ) + 2
	local cf = CFrame.new(sFocusX, focusY, sFocusZ)
		* CFrame.Angles(0, sYaw, 0)
		* CFrame.Angles(-effPitch, 0, 0)
		* CFrame.new(0, 0, sDistance)

	-- keep the camera above the ground
	local p = cf.Position
	local ground = Heightmap.get(p.X, p.Z) + 3
	if p.Y < ground then
		cf = CFrame.lookAt(Vector3.new(p.X, ground, p.Z), Vector3.new(sFocusX, focusY, sFocusZ))
	end
	camera.CFrame = cf
	camera.Focus = CFrame.new(sFocusX, focusY, sFocusZ)
end

return CameraController
