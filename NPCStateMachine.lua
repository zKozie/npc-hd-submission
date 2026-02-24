--!strict


-- ===============================

-- TYPES

-- ===============================
type BaseState<C> = {
	
	-- THIS ACTS AS AN ABSTRACT CLASS THAT ALL STATES MUST FOLLOW
	
	-- !! DATA ATTRIBUTES !!
	Name: string,
	Transitions: {[string]: (context: C) -> (boolean)}, 
	--[[
		Dictionary of state_name = function that returns if transition is allowed
	]]
	StateData: {[string]: any}, -- Used to store data for the state
	
	-- !! PUBLIC METHODS !!
	EnterState: (self: BaseState<C>, machine: StateMachine<C>) -> (),
	UpdateState: (self: BaseState<C>, machine: StateMachine<C>, dt: number) -> (),
	ExitState: (self: BaseState<C>, machine: StateMachine<C>) -> (),
	Cleanup: ((self: BaseState<C>) -> ())?,
}

type StateMachine<C> = {
	
	-- !! DATA ATTRIBUTES !!
	CurrentState: string,
	PreviousState: string,
	StateTable: {[string]: BaseState<C>},
	Context: C,
	
	-- !! PUBLIC METHODS !!
	GetContext: (self: StateMachine<C>) -> (C),
	GetPrevious: (self: StateMachine<C>) -> (string?),
	Init: (self: StateMachine<C>) -> (),
	Transition: (self: StateMachine<C>, to_state: string) -> (boolean),
	Update: (self: StateMachine<C>, dt: number) -> (),
	Destroy: (self: StateMachine<C>) -> (),
	
	-- !! PRIVATE METHODS !!
	_translateToObject: (self: StateMachine<C>, states: {BaseState<C>}) -> {[string]: BaseState<C>},
}


-- ===============================

-- MACHINE CLASS

-- ===============================
local StateMachine = {}
StateMachine.__index = StateMachine

--- Constructs and initiates the state machine
function StateMachine.new<C>(context: C, states: {BaseState<C>})
	local self = setmetatable({}, StateMachine) :: StateMachine<C>
	
	-- Sets attributes
	self.StateTable = self:_translateToObject(states)
	self.CurrentState = states[1].Name
	self.PreviousState = ""
	self.Context = context

	return self	
end

--- Helper function to convert array of states to dictionary of states and object
function StateMachine._translateToObject<C>(self: StateMachine<C>, states: {BaseState<C>}): {[string]: BaseState<C>}
	local state_object = {}
	for _, state in pairs(states) do
		state_object[state.Name] = state
	end
	return state_object
end

function StateMachine.Init<C>(self: StateMachine<C>)
	-- Guard clause
	assert(self.StateTable[self.CurrentState], "STATE MACHINE COULD NOT INITIATE! Current state not found in state table!")
	
	-- Initializes the state machine
	self.StateTable[self.CurrentState]:EnterState(self)
end

--- Getter method for context
function StateMachine.GetContext<C>(self: StateMachine<C>)
	return self.Context
end

--- Getter method for previous state
function StateMachine.GetPrevious<C>(self: StateMachine<C>)
	return self.PreviousState
end

--- Transitions to a new state
function StateMachine.Transition<C>(self: StateMachine<C>, to_state: string): boolean
	local current_state = self.StateTable[self.CurrentState]
	local next_state = self.StateTable[to_state]
	
	-- Guard clauses for invalid transitions
	if current_state == next_state then warn("Can't transition to self!") return false end -- Can't transition to self
	if current_state.Transitions[to_state] == nil then warn("Transition not found!") return false end -- Transition doesn't exist
	if not current_state.Transitions[to_state](self:GetContext()) then warn("Can't transition!") return false end -- Transition function returned false
	
	-- Transition logic
	self.PreviousState = current_state.Name
	current_state:ExitState(self)

	next_state:EnterState(self)
	self.CurrentState = to_state
	print("Transitioned to", to_state)
	return true
end

--- Method for updating the state machine
function StateMachine.Update<C>(self: StateMachine<C>, dt: number)
	local current_state = self.StateTable[self.CurrentState]
	assert(current_state, "Current state not found!")
	current_state.UpdateState(current_state, self, dt)
end

--- Method for destroying the state machine
function StateMachine.Destroy<C>(self: StateMachine<C>)
	self = self :: any -- set metatable to any to avoid type errors
	self.Context = nil
	self.CurrentState = nil
	self.StateTable = nil
	self.PreviousState = nil
	setmetatable(self, nil)
end

-- ===============================

-- MAIN

-- ===============================

--// CONTEXT //--

local Context = {
	-- !! CHARACTER ATTRIBUTES !!
	Character = script.Parent,
	Humanoid = script.Parent:WaitForChild("Humanoid", 1) or error("NO HUMANOID") ,
	Animator = script.Parent.Humanoid:WaitForChild("Animator") or error("NO ANIMATOR"),
	
	-- !! LOGIC ATTRIBUTES !! --
	Target = nil :: Model?,
}

-- // TYPES FOR MAIN AND SIMPLICITY //--

type Context = typeof(Context) -- Type for Context
type State = BaseState<Context>
type Machine = StateMachine<Context>

--// HELPER FUNCTIONS //--
local function checkNearbyTarget(character: Model, current_cf: CFrame): Model?
	-- Checks for nearby characters
	local overlap_params = OverlapParams.new()
	overlap_params.FilterType = Enum.RaycastFilterType.Include
	overlap_params.FilterDescendantsInstances = {workspace.Characters}
	local sphere_cast = workspace:GetPartBoundsInBox(current_cf, Vector3.one*100, overlap_params)
	-- I figured that using raycasting here instead of iterating through the whole folder is better for performance
	-- My reasoning here is that it is almost O(1) lookup? Not sure but I think it's better than O(n) if iterating the folder
	if #sphere_cast ~= 0 then --> Checks if there is a character within range
		for _, child in pairs(sphere_cast) do
			-- Validates if the parent is a model
			local model = child:FindFirstAncestorOfClass("Model")
			if not model then continue end

			-- Early out if the model is the same as the machine
			if model == character then continue end

			if model:FindFirstChildOfClass("Humanoid") then
				-- Checks if the character is looking at the target
				local look_character = current_cf.LookVector.Unit
				local look_target = (model:GetPivot().Position-current_cf.Position).Unit

				local dot_product = look_character:Dot(look_target)
				if dot_product < 0.707 then
					continue
				end
				return model
			end
		end
	end
	return nil
end

--// STATES //--

local States: {State} = {
	{ -- !! IDLE STATE !! --
		Name = "Idle",
		Transitions = {
			Patrol = function(context: Context)
				return true
			end,
			Detect = function(context: Context)
				if context.Target == nil then return false end -- Returns false if there is no target
				return true
			end,
		},
		StateData = {
			
		},
		EnterState = function(self: State, machine: Machine)
			print("Entered Idle")
			local state_data = self.StateData
			
			state_data.Elapsed = 0
			state_data.Angle = 0 -- Reference for determining rotation direction
			state_data.RotationSpeed = 2 -- Defines how fast the character rotates
			state_data.RotationDirection = 1 -- 1 or -1, determines the direction of rotation
			
		end,
		UpdateState = function(self: State, machine: Machine, dt: number)
			local context = machine:GetContext()	
			local state_data = self.StateData
			
			state_data.Elapsed += dt
			state_data.Angle += state_data.RotationDirection * state_data.RotationSpeed
			
			if state_data.Angle >= 45 then
				state_data.RotationDirection = -1
			elseif state_data.Angle <= -45 then
				state_data.RotationDirection = 1
			end
			
			if state_data.Elapsed >= 5 then
				machine:Transition("Patrol")
			end
			
			local character = context.Character
			local humanoid = context.Humanoid
			
			local current_cf = character:GetPivot()
			
			local target = checkNearbyTarget(character, current_cf)
			if target then
				context.Target = target
				machine:Transition("Detect")
				return
			end
			
			-- Rotate character by 1 angle per tick
			character:PivotTo(current_cf * CFrame.Angles(0, math.rad(state_data.RotationDirection), 0))
		end,
		ExitState = function(self: State, machine: Machine)
			print("Exiting idle")
			self.StateData = {}
		end,
	},
	
	{ -- !! PATROL STATE !! --
		Name = "Patrol",
		Transitions = {
			Idle = function(context: Context)
				return true
			end,
			Detect = function(context: Context)
				if context.Target == nil then return false end -- Returns false if there is no target
				return true
			end,
		},
		StateData = {
			
		},
		EnterState = function(self: State, machine: Machine)
			print("Entered Patrol")
			local context = machine:GetContext()
			local state_data = self.StateData
			
			local character = context.Character
			
			local current_cf = character:GetPivot()
			
			-- Creates 2 random positions as waypoints
			-- Random position is generated by getting the CFrame of a random angle and multiplying it by a set distance relative to Z axis
			local random_pos1 = ((CFrame.Angles(0, math.rad(math.random(0, 180)), 0) + current_cf.Position) * CFrame.new(0,0, -10)).Position
			local random_pos2 = ((CFrame.Angles(0, math.rad(math.random(-180, 0)), 0) + current_cf.Position) * CFrame.new(0,0, -10)).Position
			
			-- Creates a part to visualize waypoints
			local part_1 = Instance.new("Part", workspace)
			local part_2 = Instance.new("Part", workspace)
			part_1.Anchored, part_2.Anchored = true, true
			part_1.CanCollide, part_2.CanCollide = false, false
			part_1.Size, part_2.Size = Vector3.one, Vector3.one
			part_1.Position, part_2.Position = random_pos1, random_pos2
			task.delay(6, function()
				part_1:Destroy()
				part_2:Destroy()
			end)
			
			
			
			-- Creates a table of waypoints
			state_data.Path = {random_pos1, random_pos2}
			state_data.CurrentPathIndex = 1
			
			state_data.Reached = false
			state_data.ElapsedSinceReached = 0
		end,
		UpdateState = function(self: State, machine: Machine, dt: number)
			
			local context = machine:GetContext()
			local state_data = self.StateData
			
			print("Updating patrol", state_data)
			
			
			
			local character = context.Character
			local humanoid = context.Humanoid
			
			local current_cf = character:GetPivot()
			
			local target = checkNearbyTarget(character, current_cf)
			
			if target then
				context.Target = target
				machine:Transition("Detect")
				return
			end
			
			-- Checks if the machine has reached the current waypoint
			if state_data.Reached then
				state_data.ElapsedSinceReached += dt
				
				-- Waypoint progress logic
				-- Checks if enough time has passed since reaching the last waypoint
				if state_data.ElapsedSinceReached >= 3 and state_data.CurrentPathIndex >= #state_data.Path then
					machine:Transition("Idle")
				elseif state_data.ElapsedSinceReached >= 3 then
					-- Adds one to the path index and resets the elapsed time
					state_data.ElapsedSinceReached = 0
					state_data.CurrentPathIndex += 1
					state_data.Reached = false
				end

				return
			end
			
			local current_path = state_data.Path[state_data.CurrentPathIndex] :: Vector3
			humanoid:MoveTo(current_path)
			
			if (current_cf.Position-current_path).Magnitude <= 2 then
				state_data.Reached = true
			end
		end,
		ExitState = function(self: State, machine: Machine)
			print("Exiting patrol")
			self.StateData = {}
		end,
	},
	
	{ -- !! DETECT STATE !! --
		Name = "Detect",
		Transitions = {
			Idle = function(context: Context)
				return true
			end,
			Patrol = function(context: Context)
				return true
			end,
		},
		StateData = {
			
		},
		EnterState = function(self: State, machine: Machine)
			print("Entered Detect")
		end,
		UpdateState = function(self: State, machine: Machine, dt: number)
			local context = machine:GetContext()
			local state_data = self.StateData
			
			local target_humanoid = context.Target and context.Target:FindFirstChildOfClass("Humanoid")
			
			-- Validates the target
			-- If the target is destroyed or the target is not visible, the state will return to idle
			if context.Target == nil or context.Target.Parent == nil or target_humanoid == nil then
				print("Invalid target, returning to idle")
				context.Target = nil -- Resets target variable for cases where the target is destroyed
				machine:Transition("Idle")
				return
			end
			
			-- This checks if the state is currently processing the target
			-- This is to prevent the state from processing the same target multiple times
			if state_data.Processing then
				return
			end
			
			local character = context.Character
			local humanoid = context.Humanoid
			
			local current_cf = character:GetPivot()
			local target_cf = context.Target:GetPivot()
			humanoid:MoveTo(context.Target:GetPivot().Position)
			
			if (target_cf.Position - current_cf.Position).Magnitude <= 5 then
				state_data.Processing = true
				target_humanoid:TakeDamage(100)
				task.wait(1)
				context.Target:Destroy()
				context.Target = nil
				machine:Transition("Idle")
			end
			
		end,
		ExitState = function(self: State, machine: Machine)
			print("Exiting Detect")
			self.StateData = {}
		end,
	}
}

-- ===============================

-- RUNTIME

-- ===============================

local machine = StateMachine.new(Context, States)

machine:Init()

--// UPDATE CONNECTION //--
local update_connection = game:GetService("RunService").Heartbeat:Connect(function(dt)
	machine:Update(dt)
end)
