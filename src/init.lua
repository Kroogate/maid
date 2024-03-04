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
	add: (self: maid, object: object_enum, method: string?) -> object_enum,
	extend: (self: maid) -> maid,
	remove: (self: maid, object: object_enum) -> (),
	remove_no_clean: (self: maid, object: object_enum) -> (),
	bind_to_instance: (self: maid, instance: Instance) -> RBXScriptConnection,
	connect: (self: maid, signal: RBXScriptSignal, callback: (...any) -> ()) -> RBXScriptConnection,
	clear: (self: maid) -> (),
	clean: (self: maid) -> (),
}
type object_enum =
	Instance
	| () -> () | { [string]: (object_enum) -> () } | thread | promise | RBXScriptConnection
export type maid = typeof(setmetatable(
	{} :: { objects: { object_enum }, object_cleanups: { [Instance]: string }, cleaning: boolean },
	{} :: maid_impl
))

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

function maid.new(): maid
	local new_maid = {
		objects = {},
		object_cleanups = {},
		cleaning = false,
	}

	return setmetatable(new_maid, maid)
end

function maid:add(object: object_enum, custom_method: string?): object_enum
	assert(not self.cleaning, "cannot call maid:add while cleaning")
	local method: string, is_promise: boolean = get_cleanup_method(object, custom_method)

	table.insert(self.objects, object)
	self.object_cleanups[object] = method

	if is_promise then
        (object :: promise):finallyCall(self.remove_no_clean, self, object) -- remove promises from maid when they are cleaned so they dont take up space
	end

	return object
end

function maid:extend(): maid
	assert(not self.cleaning, "cannot call maid:extend while cleaning")
	local new_maid = maid.new()
	self:add(new_maid, "clean")
	return new_maid
end

function maid:remove(object: object_enum)
	assert(not self.cleaning, "cannot call maid:remove while cleaning")
	local in_table = table.find(self.objects, object)

	if not in_table then
		return
	end

	local user_method = self.object_cleanups[object] :: string
	local method = get_cleanup_method(object, user_method)

	_clean(object, method)
	table.remove(self.objects, in_table)
	self.object_cleanups[object] = nil
end

function maid:remove_no_clean(object: object_enum)
	assert(not self.cleaning, "cannot call maid:remove_no_clean while cleaning")
	local in_table = table.find(self.objects, object)

	if not in_table then
		return
	end

	table.remove(self.objects, in_table)
	self.object_cleanups[object] = nil
end

function maid:connect(signal: RBXScriptSignal, callback: (...any) -> ()): RBXScriptConnection
	return self:add(signal:Connect(callback))
end

function maid:bind_to_instance(instance: Instance): RBXScriptConnection
	return self:connect(instance.Destroying, function()
		self:clean()
	end)
end

function maid:clear()
	assert(not self.cleaning, "cannot call maid:clear while cleaning")
	self.cleaning = true

	for i: number, object: object_enum in self.objects do
		local user_method = self.object_cleanups[object] :: string
		local method = get_cleanup_method(object, user_method)

		_clean(object, method)
		table.remove(self.objects, i)
		self.object_cleanups[object] = nil
	end

	self.cleaning = false
end

function maid:clean()
	assert(not self.cleaning, "cannot call maid:clean while cleaning")
	self.cleaning = true

	for i: number, object: object_enum in self.objects do
		local user_method = self.object_cleanups[object] :: string
		local method = get_cleanup_method(object, user_method)

		_clean(object, method)
		table.remove(self.objects, i)
		self.object_cleanups[object] = nil
	end

	setmetatable(self, nil)
	table.clear(self)
	table.freeze(self)
end

return maid