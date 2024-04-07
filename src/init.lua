local function_marker = newproxy()
local thread_marker = newproxy()

type promise = {
	andThen: (
		self: promise,
		successHandler: (...any) -> ...any,
		failureHandler: ((...any) -> ...any)?
	) -> promise,
	andThenCall: <TArgs...>(self: promise, callback: (TArgs...) -> ...any, TArgs...) -> any,
	andThenReturn: (self: promise, ...any) -> promise,

	await: (self: promise) -> (boolean, ...any),
	awaitStatus: (self: promise) -> (Status, ...any),

	cancel: (self: promise) -> (),
	catch: (self: promise, failureHandler: (...any) -> ...any) -> promise,
	expect: (self: promise) -> ...any,

	finally: (self: promise, finallyHandler: (status: Status) -> ...any) -> promise,
	finallyCall: <TArgs...>(self: promise, callback: (TArgs...) -> ...any, TArgs...) -> promise,
	finallyReturn: (self: promise, ...any) -> promise,

	getStatus: (self: promise) -> Status,
	now: (self: promise, rejectionValue: any?) -> promise,
	tap: (self: promise, tapHandler: (...any) -> ...any) -> promise,
	timeout: (self: promise, seconds: number, rejectionValue: any?) -> promise,
}

type maid_impl = {
	__index: maid_impl,
	new: () -> maid,
	spawn: (self: maid, fn: (...any) -> object_enum, ...any) -> object_enum,
	add: (self: maid, object: object_enum, method: string?) -> object_enum,
	extend: (self: maid) -> maid,
	remove: (self: maid, object: object_enum, ignore_clean: boolean?, _internal: boolean?) -> (),
	bind_to_instance: (self: maid, instance: Instance) -> RBXScriptConnection,
	connect: (self: maid, signal: RBXScriptSignal, callback: (...any) -> ()) -> RBXScriptConnection,
	clear: (self: maid) -> (),
	clean: (self: maid) -> (),
}
type object_enum = Instance | () -> () | { [string]: (object_enum) -> () } | thread | promise | RBXScriptConnection
export type maid = typeof(setmetatable({} :: { objects: { [object_enum]: string }, cleaning: boolean }, {} :: maid_impl))

local function is_promise(object: object_enum): boolean -- taken from sleitnick/trove
	local n_promise: promise = object :: promise
	return typeof(object) == "table"
		and typeof(n_promise.getStatus) == "function"
		and typeof(n_promise.finally) == "function"
		and typeof(n_promise.cancel) == "function"
end

local function _clean(object: object_enum, method: string)
	if method == function_marker then
		(object :: () -> ())()
	elseif method == thread_marker then
		task.cancel(object :: thread)
	else
		(object :: { [string]: (object_enum) -> () })[method](object)
	end
end

local function get_cleanup_method(object: object_enum, user_sent_method: string?): (string, boolean)
	local type_of = typeof(object) :: "function" | "thread" | "table" | "Instance"

	if type_of == "function" then
		return function_marker, false
	elseif type_of == "thread" then
		return thread_marker, false
	elseif is_promise(object) then
		return "cancel", true
	elseif type_of == "table" or type_of == "Instance" then
		return user_sent_method or "Destroy", false
	elseif type_of == "RBXScriptConnection" then
		return "Disconnect", false
	end

	return user_sent_method or "Destroy", false
end

local maid = {}
maid.__index = maid

--[=[
  @function new
  @return maid -- The new maid

  Constructs a new maid
]=]
function maid.new(): maid
	local new_maid = {
		objects = {},
		cleaning = false,
	}

	return setmetatable(new_maid, maid)
end

--[=[
  @method add
  @within maid
  @param object -- The object to add to the maid
  @return object -- The passed object	

  Adds a new object to the maid, returns the object passed in for convenience
  Example usage:
  ```lua
	local instance = Instance.new("Part")
	local instance_ptr = maid:add(instance)
	print(instance == instance_ptr) -- true
  ```
]=]

function maid:add(object: object_enum, custom_method: string?): object_enum
	assert(not self.cleaning, debug.traceback("attempted to call maid:add while cleaning! traceback: "))
	local method: string, is_promise: boolean = get_cleanup_method(object, custom_method)

	self.objects[object] = method

	if is_promise and (object :: promise):getStatus() == "Started" then
		(object :: promise):finally(function(status): ...any
			if not self.cleaning then
				self:remove(object, true)
			end
		end)
	end

	return object
end

--[=[
  @method spawn
  @within maid
  @param Fn (...any)->Object -- The function for the maid to pass arguments in
  @param ... ...any -- The arguments for the maid to pass to the function
  @return Object -- The result of the function

  Passes `...` to `Fn`, adds the result to the maid, then returns the result
  Example usage:
  ```lua
	local callback = function(parent: Instance): Part
		return Instance.new("Part", parent)
	end

	local part = maid:spawn(callback, workspace)
	print(part.Parent) -- workspace
  ```
]=]

function maid:spawn(fn: (...any) -> object_enum, ...): object_enum
	local result = fn(...)
	self:add(result)
	return result
end

--[=[
  @method extend
  @within maid
  @return maid -- The constructed maid

  Makes a new maid and adds it to the maid that the function was called from
  Example usage:
  ```lua
	local maid1 = maid.new()
	local maid2 = maid1:extend()

	maid2:add(function() 
		print("hi")
	end)

	maid1:clean() -- hi
  ```
]=]

function maid:extend(): maid
	assert(not self.cleaning, "cannot call maid:extend while cleaning")
	local new_maid = self:add(maid.new(), "clean")

	return new_maid
end

--[=[
  @method remove
  @within maid
  @param object -- The object to remove
  @param ignore_clean -- Optional, if the maid should skip the cleanup process and just remove the object from storage

  Removes an object from the maid & cleans it
]=]

function maid:remove(object: object_enum, ignore_clean: boolean?, _internal: boolean?)
	assert(not (self.cleaning and not _internal), "cannot call maid:remove while cleaning")

	local method = self.objects[object]

	if method then
		if not ignore_clean then
			_clean(object, method)
		end

		self.objects[object] = nil
	end
end

--[=[
  @method connect
  @within maid
  @param Signal RBXScriptSignal -- The signal to connect to
  @param Callback (...any)->() -- The callback to hook to the signal
  @returns Connection RBXScriptConnection -- The connection hooking `callback` to `signal`

  Connects `callback` to `signal`, and adds it to the maid. The same as
   ```lua
	local connection = maid:add(signal:Connect(callback))
   ```

   Example usage:
   ```lua
   local humanoid: Humanoid = some_humanoid
   local connection = maid:connect(humanoid.Died, function()
	print("hi")
   end)
   ```
]=]

function maid:connect(signal: RBXScriptSignal, callback: (...any) -> ()): RBXScriptConnection
	return self:add(signal:Connect(callback))
end

--[=[
  @method bind_to_instance
  @within maid
  @param Instance -- The instance to bind to
` @returns Connection -- The connection listening to `instance.Destroying`

  Connects to `instance.Destroying` and cleans the maid once the signal fires.

  Example usage:
   ```lua
   local maid = maid.new()
   maid:add(function()
	print("hi")
   end)
   maid:bind_to_instance(some_instance)
   some_instance:Destroy() -- hi
   ```
]=]
function maid:bind_to_instance(instance: Instance): RBXScriptConnection
	return self:connect(instance.Destroying, function()
		self:clean()
	end)
end
--[=[
  @method clear
  @within maid

  Clears all objects in the maid without destroying it
]=]
function maid:clear()
	assert(not self.cleaning, "cannot call maid:clear while cleaning")
	self.cleaning = true

	for object: object_enum, method: string in self.objects do
		self:remove(object, false, true)
	end

	self.cleaning = false
end
--[=[
  @method clean
  @within maid

  Clears all objects in the maid & destroys the maid, leaving it unusable
]=]
function maid:clean()
	assert(not self.cleaning, "cannot call maid:clean while cleaning")
	self.cleaning = true

	for object: object_enum, method: string in self.objects do
		self:remove(object, false, true)
	end

	setmetatable(self, nil)
	table.clear(self)
	table.freeze(self)
end

return maid
