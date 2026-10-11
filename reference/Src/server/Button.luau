--!strict
-- Button: a physical toggle that starts and stops the crowd simulation.
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local CrowdController = require(script.Parent:WaitForChild("CrowdController"))

local COOLDOWN_TIME = 2
local PRESSED_COLOR = BrickColor.new("Lime green")
local RELEASED_COLOR = BrickColor.new("Really red")

type ButtonFields = {
	Model: Model,
	ButtonPart: BasePart,
	Pressed: boolean,
	IsCoolingDown: boolean,
	Crowd: CrowdController.CrowdController,
}

local Button = {}
Button.__index = Button

export type Button = typeof(setmetatable({} :: ButtonFields, Button))

function Button.new(position: Vector3?, parent: Instance?): Button?
	local template = ServerStorage:FindFirstChild("button")
	if not template or not template:IsA("Model") then
		warn("Button template 'button' not found in ServerStorage")
		return nil
	end

	local model = template:Clone()
	local buttonPart = model:FindFirstChild("Button")
	if not buttonPart or not buttonPart:IsA("BasePart") then
		warn("Button template is missing a 'Button' part")
		model:Destroy()
		return nil
	end

	model.Parent = parent or workspace
	model:PivotTo(CFrame.new(position or Vector3.zero))

	local fields: ButtonFields = {
		Model = model,
		ButtonPart = buttonPart,
		Pressed = false,
		IsCoolingDown = false,
		Crowd = CrowdController.new(),
	}
	local self = setmetatable(fields, Button)

	-- When the crowd winds itself down (every player died), reset the
	-- button to its released red state so the next press starts fresh.
	self.Crowd.OnStopped = function()
		self.Pressed = false
		self:SetVisualReleased()
	end

	buttonPart.Touched:Connect(function(otherPart)
		if self.IsCoolingDown then return end

		local player = Players:GetPlayerFromCharacter(otherPart.Parent)
		if not player then return end

		self.IsCoolingDown = true
		self.Pressed = not self.Pressed

		if self.Pressed then
			self.Crowd:Start()
			self:SetVisualPressed()
		else
			self.Crowd:Stop()
			self:SetVisualReleased()
		end

		task.wait(COOLDOWN_TIME)
		self.IsCoolingDown = false
	end)

	return self
end

-- Visual feedback: green while the simulation runs, red while stopped.
function Button.SetVisualPressed(self: Button)
	self.ButtonPart.BrickColor = PRESSED_COLOR
end

function Button.SetVisualReleased(self: Button)
	self.ButtonPart.BrickColor = RELEASED_COLOR
end

return Button
