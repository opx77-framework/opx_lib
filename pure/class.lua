--- Classes: single inheritance, and nothing else.
-- @author dop42
--
--   local Zone = Lib.Class('Zone')
--
--   function Zone:init(centre, radius)
--     self.centre, self.radius = centre, radius
--   end
--
--   function Zone:holds(point)
--     return distance(self.centre, point) <= self.radius
--   end
--
--   local Circle = Lib.Class('Circle', Zone)
--   local here = Circle(centre, 15)
--
-- UNVERIFIED ON THE CLIENT, and nothing here should be relied on until it is.
-- `getmetatable` is PROVEN ABSENT from the Open77 client sandbox -- it was
-- measured, from a raise on the live server, and `pure/validate.lua` carries the
-- write-up. `Holds` below calls it, and this module is built on `setmetatable`,
-- whose presence has NOT been established either way: the catalogue does not
-- list base Lua functions, so its silence is not evidence. Nothing in
-- `opx_infinity` imports `Class`, which is the only reason this is a note rather
-- than a defect. Before a consumer does, prove `setmetatable` on the client --
-- one line in a client script that logs `type(setmetatable)` -- and then either
-- fix `Holds` the way `Validate.Table` was fixed, or refuse at load with a
-- sentence, rather than letting a caller find out through an unwound coroutine.
--
-- THIS IS THE ONE THING IN THE LIBRARY THAT ONLY WORKS THROUGH `require`, and it
-- is worth saying plainly because it decides where a consumer can use it. A
-- class is a metatable, and a metatable does not survive an export: arguments
-- and results are COPIED as plain data, so an instance sent through
-- `exports.other:thing(instance)` arrives as a table with its fields and none of
-- its methods, and the first call on the far side fails on a value that looks
-- correct. Classes are for code running in one VM. Across a boundary, send data
-- and rebuild.
--
-- SINGLE INHERITANCE, AND NO `super()`. A chain deeper than one is a design that
-- wanted composition, and the library refusing to help build it is the point.
-- An override that needs the parent's behaviour names it: `Zone.holds(self, p)`
-- is explicit about which implementation runs, where `super()` is a lookup whose
-- answer depends on where the method was declared.
--
-- `init` IS OPTIONAL. A class without one constructs an empty instance, which is
-- what a value object with fields assigned afterwards wants.

--- Builds a class and answers it. Calling the class constructs an instance.
-- @author dop42
-- @param name string for `tostring` and for an error that has to name something
-- @param parent table|nil a class from a previous call
-- @return table
return function(name, parent)
	if type(name) ~= 'string' or name == '' then
		error('opx_lib: a class needs a name', 2)
	end
	if parent ~= nil and type(parent) ~= 'table' then
		error(('opx_lib: the parent of %s is not a class'):format(name), 2)
	end

	local class = {}
	class.__name = name
	class.__parent = parent

	-- Instances look methods up on the class; the class looks them up on its
	-- parent. Two links, resolved by the VM, and no walk written here.
	class.__index = class

	--- Whether a value is an instance of this class or of one it descends from.
	--
	-- Walks the chain rather than comparing one metatable, so a subclass answers
	-- true for its parent -- which is the question a caller is actually asking.
	-- @param value any
	-- @return boolean
	function class.Holds(value)
		if type(value) ~= 'table' then return false end
		local held = getmetatable(value)
		while held ~= nil do
			if held == class then return true end
			held = held.__parent
		end
		return false
	end

	-- Constructing is calling the class. `init` is looked up through the chain,
	-- so a subclass with no `init` gets its parent's.
	setmetatable(class, {
		__index = parent,
		__name = name,
		__tostring = function() return ('class %s'):format(name) end,
		__call = function(_, ...)
			local instance = setmetatable({}, class)
			local init = class.init
			if type(init) == 'function' then
				-- Answered rather than swallowed: a constructor that failed must not
				-- hand back a half-built instance, and the caller's stack is where
				-- the mistake is.
				init(instance, ...)
			end
			return instance
		end,
	})

	return class
end
