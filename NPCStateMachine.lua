--[[

This script implements a generic Finite State Machine used to control character behaviour.

This module that I made includes 3 important classes: Machine, State, Context.
P.S: This is a GENERIC MODULE that can be used in any program that uses state based logic.

The reason I went with this structure is to separate behaviour logic from control logic
to solve the problem of having giant if/else statements to handle behaviour,
I made each behaviour become its own isolated unit (state).
This way it makes the system easier to extend
with how new behaviours can be added without modifying the machine itself.

Machine is responsible for:
- keeping track of the currently active state
- validating whether transitions are allowed
- executing lifecycle hooks (EnterState / ExitState / UpdateState)

The machine itself does NOT contain behaviour logic. Instead it acts as the authority layer
that coordinates independent "State" objects.

State defines:
- how it behaves when active
- which states it can transition into
- temporary runtime data while active

Context: 
This acts as the shared data container between states so they can make decisions
based on the current world conditions (targets, timers, character references, etc).

]]
--!strict


-- ===============================

-- TYPES

-- ===============================

--[[

BaseState acts like an ABSTRACT template that every state must follow.

The machine depends on this interface so it can SAFELY call state methods
without needing to know what the state actually does internally.

]]
type BaseState<C> = {

	-- !! DATA ATTRIBUTES !! --

	Name: string,

	--[[
	
	Defines what states this state is allowed to transition into.

	The transition function receives Context so it can evaluate
	world conditions before allowing the state change.

	My reasoning here is that transition rules belong to the state
	itself rather than the machine. The machine only executes transitions and
	it does not decide WHEN they should happen.
	
	]]
	Transitions: {[string]: (context: C) -> (boolean)},

	--[[
	Runtime storage specific to the state.

	I separated this from Context because it is shared across states,
	while this data should only exist while the state is active.

	This way, it avoids states accidentally interfering with each other's data.
	
	]]
	StateData: {[string]: any},


	-- !! PUBLIC METHODS !! --

	EnterState: (self: BaseState<C>, machine: StateMachine<C>) -> (),

	UpdateState: (self: BaseState<C>, machine: StateMachine<C>, dt: number) -> (),

	ExitState: (self: BaseState<C>, machine: StateMachine<C>) -> (),

	Cleanup: ((self: BaseState<C>) -> ())?,
}


--[[

StateMachine main job is to coordinate the execution of states.

The machine does not contain gameplay logic. It only manages
state flow and lifecycle execution.

This way it keeps the machine reusable for many different systems.

]]
type StateMachine<C> = {
	--[[
		
		The generic C stands for CONTEXT to support
		different data structures
	
	]]

	-- !! DATA ATTRIBUTES !! --

	-- The currently active state
	-- Used to lookup the state_object by the update function
	CurrentState: string,

	-- Stored mainly for debugging
	-- Potential transition logic that requires access to state history
	PreviousState: string,

	-- Dictionary lookup of state_name to state_object
	-- This avoids iterating through states when resolving transitions
	StateTable: {[string]: BaseState<C>},

	-- Shared data accessible by all states
	Context: C,


	-- !! PUBLIC METHODS !! --
	--[[
	
		These are type definitions used to reinforce
		strict typing and have a clearer understanding of
		what functions exist and what they return
		
	]]
	GetContext: (self: StateMachine<C>) -> (C),

	GetPrevious: (self: StateMachine<C>) -> (string?),

	Init: (self: StateMachine<C>) -> (),

	Transition: (self: StateMachine<C>, to_state: string) -> (boolean),

	Update: (self: StateMachine<C>, dt: number) -> (),

	Destroy: (self: StateMachine<C>) -> (),


	-- !! PRIVATE METHODS !! --

	_translateToObject: (self: StateMachine<C>, states: {BaseState<C>}) -> {[string]: BaseState<C>},
}


-- ===============================

-- MACHINE CLASS

-- ===============================

local StateMachine = {}
StateMachine.__index = StateMachine


--[[

Constructs the state machine.

States are provided as an array because it's easier to define them that way,
but internally the machine converts them into a dictionary for faster lookups.

My reasoning here is that transitions reference states by name, so using
a dictionary allows near O(1) lookup instead of scanning through the array
every time a transition happens.

I could have used their indexes instead of creating a dictionary but I feel that
it would have made debugging more difficult to pinpoint what state is causing trouble.

]]
function StateMachine.new<C>(context: C, states: {BaseState<C>})

	local self = setmetatable({}, StateMachine) :: StateMachine<C>

	-- Convert state array into dictionary lookup
	self.StateTable = self:_translateToObject(states)

	-- First state in the list becomes the default starting state
	self.CurrentState = states[1].Name

	self.PreviousState = ""

	-- Context is shared between states
	self.Context = context

	return self	
end


--[[

Helper function that converts the provided state array into a dictionary.

The machine needs to resolve states frequently during transitions,
so doing this conversion once at initialization avoids repeated iteration
during runtime.

]]
function StateMachine._translateToObject<C>(self: StateMachine<C>, states: {BaseState<C>}): {[string]: BaseState<C>}

	local state_object = {}

	for _, state in pairs(states) do
		state_object[state.Name] = state
	end

	return state_object
end


function StateMachine.Init<C>(self: StateMachine<C>)

	-- Guard clause to ensure the initial state actually exists.
	-- If this fails it likely means the states list was misconfigured.
	assert(
		self.StateTable[self.CurrentState],
		"STATE MACHINE COULD NOT INITIATE! Current state not found in state table!"
	)

	-- Enter the initial state to begin the lifecycle
	self.StateTable[self.CurrentState]:EnterState(self)
end


-- States use this to access shared machine data
function StateMachine.GetContext<C>(self: StateMachine<C>)
	return self.Context
end


-- Allows states or debugging systems to inspect previous state
function StateMachine.GetPrevious<C>(self: StateMachine<C>)
	return self.PreviousState
end


--[[

Handles transitioning between states.

The machine validates transitions before executing them because
states define their own transition rules.

If the machine skipped validation it could break the intended
behaviour flow defined by the state.

]]
function StateMachine.Transition<C>(self: StateMachine<C>, to_state: string): boolean

	local current_state = self.StateTable[self.CurrentState]
	local next_state = self.StateTable[to_state]

	-- Prevent transitioning into the same state.
	-- Doing so would unnecessarily trigger ExitState and EnterState
	-- which could reset state data unintentionally.
	if current_state == next_state then
		warn("Can't transition to self!")
		return false
	end

	-- Ensure the transition rule actually exists
	if current_state.Transitions[to_state] == nil then
		warn("Transition not found!")
		return false
	end

	-- Evaluate the transition condition using shared Context
	if not current_state.Transitions[to_state](self:GetContext()) then
		warn("Can't transition!")
		return false
	end


	-- Store previous state before leaving it
	self.PreviousState = current_state.Name

	-- Allow the current state to clean up runtime logic
	current_state:ExitState(self)

	-- Initialize the next state's runtime data
	next_state:EnterState(self)

	-- Update machine pointer to the new active state
	self.CurrentState = to_state

	print("Transitioned to", to_state)

	return true
end


--[[

Called every frame by the runtime update loop.

The machine itself does not execute behaviour logic
but instead it forwards the update call to the currently active state.

]]
function StateMachine.Update<C>(self: StateMachine<C>, dt: number)

	local current_state = self.StateTable[self.CurrentState]

	assert(current_state, "Current state not found!")

	current_state.UpdateState(current_state, self, dt)
end


--[[

Destroys the machine by clearing references.

This is mainly to ensure that there are no memory leaks

]]
function StateMachine.Destroy<C>(self: StateMachine<C>)

	self = self :: any

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

--[[

As defined by my module, 
context acts as the shared data container between all states.

For this particular usecase, this exists so that states can access world information
without needing direct references to the machine itself.

]]
local Context = {
	-- !! CHARACTER ATTRIBUTES !!
	Character = script.Parent,

	-- Humanoid and Animator are stored here because multiple states
	-- need to access them (movement, animations, etc).
	Humanoid = script.Parent:WaitForChild("Humanoid", 1) or error("NO HUMANOID"),
	Animator = script.Parent.Humanoid:WaitForChild("Animator") or error("NO ANIMATOR"),

	-- !! LOGIC ATTRIBUTES !! --

	-- Target is set when a character is detected by the sensing logic.
	-- Other states rely on this value to determine whether they should
	-- transition into combat or detection behaviours.
	Target = nil :: Model?,
}


-- // TYPES FOR MAIN AND SIMPLICITY //--

--[[
	These type aliases are mostly for readability.
	Instead of repeatedly writing BaseState<Context> and StateMachine<Context>,
	I shorten them so the state definitions below are easier to read.
]]
type Context = typeof(Context)
type State = BaseState<Context>
type Machine = StateMachine<Context>


--// HELPER FUNCTIONS //--

--[[
Performs a spatial query to find nearby characters.

I chose to use GetPartBoundsInBox instead of iterating through the entire
Characters folder because the engine handles spatial filtering internally.

My assumption here is that this should be closer to O(1) lookup
compared to manually checking every character in the folder which would be
O(n) lookup and that matters for multiple NPCs and objects.

After finding nearby parts we still need to validate the actual character
models and ensure they meet the conditions we care about.
]]
local function checkNearbyTarget(character: Model, current_cf: CFrame): Model?

	local overlap_params = OverlapParams.new()
	overlap_params.FilterType = Enum.RaycastFilterType.Include
	overlap_params.FilterDescendantsInstances = {workspace.Characters}

	local sphere_cast = workspace:GetPartBoundsInBox(current_cf, Vector3.one * 100, overlap_params)
	if #sphere_cast == 0 then return nil end
	-- If nothing is returned then there are no nearby characters
	for _, child in pairs(sphere_cast) do
		-- Convert the part into its character model
		local model = child:FindFirstAncestorOfClass("Model") or continue
		-- SKIPS if no model was found
		if not model then continue end
		-- SKIPS our own character
		if model == character then continue end
		-- SKIPS models that don't represent characters
		if not model:FindFirstChildOfClass("Humanoid") then continue end

		-- Simple visibility check using dot product.
		-- This prevents the AI from detecting targets behind it.
		local look_character = current_cf.LookVector.Unit
		local look_target = (model:GetPivot().Position - current_cf.Position).Unit

		local dot_product = look_character:Dot(look_target)

		-- 0.707 roughly corresponds to a 45 degree vision
		if dot_product < 0.707 then continue end
		return model
	end

	-- Returns nil if no model was found
	return nil
end


--// STATES //--

--[[

In this particular usecase, these states define
the behaviour of the NPC character

]]
local States: {State} = {

	{ -- !! IDLE STATE !! --

		Name = "Idle",

		Transitions = {

			-- Idle can always transition to Patrol.
			-- This transition is triggered by a timer in UpdateState.
			Patrol = function(context: Context)
				return true
			end,

			-- Detect transition only happens if a target was found.
			-- The sensing logic in UpdateState is responsible for
			-- populating Context.Target.
			Detect = function(context: Context)
				if context.Target == nil then return false end
				return true
			end,
		},

		StateData = {},


		EnterState = function(self: State, machine: Machine)

			print("Entered Idle")

			local state_data = self.StateData

			-- Reset idle timers whenever we enter the state.
			state_data.Elapsed = 0

			-- These values control the idle scanning behaviour where
			-- the character slowly rotates left and right while searching.
			state_data.Angle = 0
			state_data.RotationSpeed = 2
			state_data.RotationDirection = 1

		end,


		UpdateState = function(self: State, machine: Machine, dt: number)

			local context = machine:GetContext()
			local state_data = self.StateData

			-- Track how long the character has been idle
			state_data.Elapsed += dt

			-- Update scanning angle
			state_data.Angle += state_data.RotationDirection * state_data.RotationSpeed

			-- Reverse direction once the scan reaches its limit
			if state_data.Angle >= 45 then
				state_data.RotationDirection = -1
			elseif state_data.Angle <= -45 then
				state_data.RotationDirection = 1
			end

			-- After idling for a while the AI begins patrolling.
			if state_data.Elapsed >= 5 then
				machine:Transition("Patrol")
			end

			local character = context.Character
			local current_cf = character:GetPivot()

			-- Continuously check for nearby targets while idle.
			local target = checkNearbyTarget(character, current_cf)

			if target then
				context.Target = target
				machine:Transition("Detect")
				return
			end

			-- Apply the scanning rotation
			character:PivotTo(current_cf * CFrame.Angles(0, math.rad(state_data.RotationDirection), 0))
		end,


		ExitState = function(self: State, machine: Machine)

			print("Exiting idle")

			-- Clear state data so the next time we enter Idle
			-- the state starts with fresh values.
			self.StateData = {}
		end,
	},
	{ -- !! PATROL STATE !! --

		Name = "Patrol",

		Transitions = {

			-- Patrol can always return to Idle.
			-- This usually happens once the patrol route finishes.
			Idle = function(context: Context)
				return true
			end,

			-- Similar to Idle, Detect only becomes valid once
			-- the sensing logic finds a target and stores it in Context.
			Detect = function(context: Context)
				if context.Target == nil then return false end
				return true
			end,
		},

		StateData = {},


		EnterState = function(self: State, machine: Machine)

			print("Entered Patrol")

			local context = machine:GetContext()
			local state_data = self.StateData

			local character = context.Character
			local current_cf = character:GetPivot()

			--[[ 
				
				Patrol behaviour works by generating temporary waypoints.
				
				I generate them relative to the character's current position
				so the patrol always starts from where the NPC currently is
				rather than relying on predefined world points.

				Random angles create variation so patrol paths look realistic
			]]
			local random_pos1 =
				((CFrame.Angles(0, math.rad(math.random(0,180)),0) + current_cf.Position)
					* CFrame.new(0,0,-10)).Position

			local random_pos2 =
				((CFrame.Angles(0, math.rad(math.random(-180,0)),0) + current_cf.Position)
					* CFrame.new(0,0,-10)).Position


			-- Debug visualization so I can see where the NPC intends to walk.
			-- These parts are temporary and only exist for debugging.
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


			-- Patrol progression is tracked using a small path table.
			-- The state walks through the points sequentially.
			state_data.Path = {random_pos1, random_pos2}

			-- Index pointer for which waypoint is currently active.
			state_data.CurrentPathIndex = 1

			-- These control waypoint arrival behaviour.
			state_data.Reached = false
			state_data.ElapsedSinceReached = 0

		end,


		UpdateState = function(self: State, machine: Machine, dt: number)

			local context = machine:GetContext()
			local state_data = self.StateData

			local character = context.Character
			local humanoid = context.Humanoid

			local current_cf = character:GetPivot()

			-- Patrol still performs perception checks every frame.
			-- Behaviour states should remain interruptible so higher priority
			-- states like Detect can immediately take control.
			local target = checkNearbyTarget(character, current_cf)

			if target then
				context.Target = target
				machine:Transition("Detect")
				return
			end

			-- Once a waypoint is reached we pause briefly before moving on.
			-- This gives the patrol a more natural pacing instead of instantly
			-- snapping to the next point.
			if state_data.Reached then
				state_data.ElapsedSinceReached += dt

				-- If we finished the final waypoint we return to Idle.
				if state_data.ElapsedSinceReached >= 3 and state_data.CurrentPathIndex >= #state_data.Path then
					machine:Transition("Idle")
				elseif state_data.ElapsedSinceReached >= 3 then
					-- Advance to the next waypoint and reset timers.
					state_data.ElapsedSinceReached = 0
					state_data.CurrentPathIndex += 1
					state_data.Reached = false
				end

				return
			end

			-- Active waypoint the NPC should currently move toward.
			local current_path = state_data.Path[state_data.CurrentPathIndex] :: Vector3

			humanoid:MoveTo(current_path)

			-- Distance check determines whether the waypoint has been reached.
			-- This avoids relying on MoveToFinished events which can sometimes
			-- behave inconsistently depending on path interruptions.
			if (current_cf.Position - current_path).Magnitude <= 2 then
				state_data.Reached = true
			end

		end,


		ExitState = function(self: State, machine: Machine)

			print("Exiting patrol")

			-- Clearing runtime state ensures patrol always recomputes
			-- a fresh path the next time it runs.
			self.StateData = {}

		end,
	},


	{ -- !! DETECT STATE !! --

		Name = "Detect",

		Transitions = {

			-- Detect can fall back to Idle when the target becomes invalid.
			Idle = function(context: Context)
				return true
			end,

			-- Patrol is technically allowed as well,
			-- although Idle is the usual fallback behaviour.
			Patrol = function(context: Context)
				return true
			end,
		},

		StateData = {},


		EnterState = function(self: State, machine: Machine)
			print("Entered Detect")
		end,


		UpdateState = function(self: State, machine: Machine, dt: number)

			local context = machine:GetContext()
			local state_data = self.StateData

			local target_humanoid =
				context.Target and context.Target:FindFirstChildOfClass("Humanoid")

			-- Detect relies heavily on Context.Target.
			-- If the reference becomes invalid we immediately abandon this state.
			if context.Target == nil
				or context.Target.Parent == nil
				or target_humanoid == nil then

				print("Invalid target, returning to idle")

				context.Target = nil
				machine:Transition("Idle")
				return

			end


			-- Processing flag prevents repeated execution
			-- of the attack logic once the target is reached.
			if state_data.Processing then
				return
			end


			local character = context.Character
			local humanoid = context.Humanoid

			local current_cf = character:GetPivot()
			local target_cf = context.Target:GetPivot()

			-- Basic chase behaviour.
			-- The NPC continually moves toward the target while the state is active.
			humanoid:MoveTo(target_cf.Position)

			if (target_cf.Position - current_cf.Position).Magnitude >= 5 then return end
			-- Once the NPC gets close enough we resolve the interaction.
			-- This parts a bit unrealistic but it demonstrates it.
			state_data.Processing = true

			target_humanoid:TakeDamage(100)

			-- Small delay to simulate attack resolution.
			task.wait(1)

			context.Target:Destroy()
			context.Target = nil

			machine:Transition("Idle")
		end,


		ExitState = function(self: State, machine: Machine)

			print("Exiting Detect")

			-- Clear runtime state so the next detection
			-- cycle begins cleanly.
			self.StateData = {}

		end,
	}
}

-- ===============================

-- RUNTIME

-- ===============================

--[[
	
	This part of the code simply starts the program 

]]

-- Constructs a new state machine object based on the context and states we defined.
local machine = StateMachine.new(Context, States)

-- Initializes the machine
machine:Init()

-- Have the machine be updated every frame
local update_connection = game:GetService("RunService").Heartbeat:Connect(function(dt)
	machine:Update(dt)
end)
