-- Be warned, here be dragons

api = require "love-api.love_api"

-- Add some undocumented Love functions
require("love-api-extender.love")(api)

do
	-- Map types to their modules, so we can properly do imports
	local lovetypes = {}

	for _, type in ipairs(api.types) do
		lovetypes[type.name] = "love"
	end

	for _, module in ipairs(api.modules) do
		local modulename = "love." .. module.name
		if module.types then
			for _, type in ipairs(module.types) do
				lovetypes[type.name] = modulename
			end
		end
		if module.enums then
			for _, type in ipairs(module.enums) do
				lovetypes[type.name] = modulename
			end
		end
	end

	-- types: { name -> true }
	function resolveImports(types, package)
		local imports = {}
		for i, v in pairs(types) do
			local module = lovetypes[i]
			if module and module ~= package then
				table.insert(imports, ("import %s.%s;"):format(module, i))
			end
		end
		table.sort(imports)
		return table.concat(imports, "\n")
	end
end

do
	-- The keys are type names, the values are their "priority",
	-- the most generic base class (Object) has the lowest priority.
	-- Used to find the most specific supertype later on.
	local priority = {}
	priority["Object"] = 0

	-- Now we first need a complete registry of types and their supertypes
	local supertypes = {}
	for _, type in ipairs(api.types) do
		supertypes[type.name] = type.supertypes or {}
	end

	for _, module in ipairs(api.modules) do
		if module.types then
			for _, type in ipairs(module.types) do
				supertypes[type.name] = type.supertypes or {}
			end
		end
		if module.enums then
			for _, type in ipairs(module.enums) do
				supertypes[type.name] = type.supertypes or {}
			end
		end
	end

	-- To assign the priority of a type, take the maximum priority of its
	-- supertypes and add 1.
	local function assignPriority(name)
		if priority[name] then
			-- Priority is known, skip
			return priority[name]
		end

		local max = -math.huge
		for i, v in ipairs(supertypes[name]) do
			max = math.max(max, assignPriority(v))
		end

		priority[name] = max+1
		return max+1
	end

	-- Now assign all priorities, and dump the type list
	for i, v in pairs(supertypes) do
		assignPriority(i)
	end
	supertypes = nil

	-- Now we can just return the supertype with the highest priority
	function mostSpecificSupertype(t)
		local maxVal, maxPriority = "UserData", -math.huge
		for i, v in ipairs(t) do
			local priority = priority[v]
			if priority > maxPriority then
				maxVal, maxPriority = v, priority
			end
		end
		return maxVal
	end
end

do
	local map =
	{
		number = "Float",
		string = "String",
		boolean = "Bool",
		table = "Table<Dynamic,Dynamic>",
		["light userdata"] = "UserData",
		userdata = "UserData",
		cdata = "UserData",
		["function"] = "Dynamic", -- FIXME
		mixed = "Dynamic",
		value = "Dynamic",
		any = "Dynamic",
		Variant = "Dynamic",
	}
	
	function typeMap(t)
		if t:find(" or ") then
			return "Dynamic" -- FIXME: "x or y" types
		end
		return map[t] or t
	end
end

function capitalize(s)
	return s:sub(1, 1):upper() .. s:sub(2)
end

function mergeTables(target, src, prefix)
	prefix = prefix or ""
	for i, v in pairs(src) do
		target[prefix .. i] = v
	end
	return target
end

function dirname(path)
	return path:match("^(.-)/?[^/]+$")
end

function split(str, sep, remove_empty)
    local t = {}
    local i = 1
    local s = ""
    while i <= #str do
        if string.sub(str, i, i + (#sep - 1)) == sep then
            if not remove_empty or s ~= "" then
                table.insert(t, s)
            end
            s = ""
            i = i + (#sep - 1)
        else
            s = s .. string.sub(str, i, i)
        end
        i = i + 1
    end
    if not remove_empty or s ~= "" then
        table.insert(t, s)
    end
    return t
end

function emitMultiReturnType(name, returns, types)
	local parts = {}
	parts[1] = ("\n@:multiReturn\nextern class %s\n{\n"):format(name)
	for i, v in ipairs(returns) do
		-- TODO: Maybe never? Vararg return can't really be modeled.
		if v.name ~= "..." then
			local type = typeMap(v.type)
			types[type] = true

			table.insert(parts, ("\tvar %s : %s;\n"):format(v.name, type))
		end
	end
	table.insert(parts, "}")

	return table.concat(parts)
end

function emitOverload(typeName, name, o, types, multirets)
	local args = {}
	for i, v in ipairs(o.arguments or {}) do
		v.type = typeMap(v.type)
		types[v.type] = true

		v.name = v.name:match("^'(.*)'$") or v.name -- FIXME: workaround for love.event.quit

		if v.name == "..." then
			if v.description == "Additional matrix elements." then
				-- Very special workaround for the "..." in Transform:setMatrix arguments
				for i = 1, 4 do
					for j = 1, 4 do
						if not ((i == 1 and j == 1) or (i == 1 and j == 2) or (i == 4 and j == 4)) then
							table.insert(args, ("e%d_%d:Float"):format(i, j))
						end
					end
				end
			else
				table.insert(args, ("args:Rest<%s>"):format(v.type))
			end
		else
			-- FIXME: love.audio.setOrientation takes multiple values in one ("fx, fy, fz")
			local names = split(v.name, ", ")
			for _, argName in ipairs(names) do
				local default = v.default
				if not default and v.table and #v.table > 0 then
					-- Count table as optional if all of its values are optional
					default = true
					for _, tableValue in ipairs(v.table) do
						if not tableValue.default then
							default = false
							break
						end
					end
				end
				local arg = (default and "?" or "") .. argName .. ":" .. v.type
				table.insert(args, arg)
			end
		end
	end
	local returns = {}
	for i, v in ipairs(o.returns or {}) do
		if v.name == "..." and v.description == "Additional matrix elements." then
			-- Very special workaround for the "..." in Transform:getMatrix return values
			for i = 1, 4 do
				for j = 1, 4 do
					if not ((i == 1 and j == 1) or (i == 1 and j == 2) or (i == 4 and j == 4)) then
						table.insert(returns, {name = ("e%d_%d"):format(i, j), type = "number"})
					end
				end
			end
		else
			-- FIXME: love.audio.getOrientation returns multiple values in one ("fx, fy, fz")
			local names = split(v.name, ", ")
			for _, retName in ipairs(names) do
				table.insert(returns, {name = retName, type = v.type})
			end
		end
	end
	local retType = "Void"
	if #returns > 1 then
		-- In case of multiple returns we need to generate a new return type
		retType = typeName .. capitalize(name) .. "Result"
		multirets[name] = emitMultiReturnType(retType, returns, types)
	elseif #returns == 1 then
		retType = typeMap(returns[1].type)
		types[retType] = true
	end
	return ("(%s) : %s"):format(table.concat(args, ", "), retType)
end

function emitCallback(c, types)
	local type = {}
	for i, v in ipairs(c.variants[1].arguments or {}) do -- TODO: Multiple variants? Does that even exist?
		table.insert(type, typeMap(v.type))
		types[type[#type]] = true
	end

	if c.variants[1].returns then -- TODO: Multiple returns?
		table.insert(type, typeMap(c.variants[1].returns[1].type))
		types[type[#type]] = true
	else
		table.insert(type, "Void")
	end

	-- If there are no arguments, prepend Void
	if #type == 1 then
		table.insert(type, 1, "Void")
	end

	type = table.concat(type, "->")

	return ("\tpublic static var %s : %s;"):format(c.name, type)
end

function emitVariable(var, types)
	local type = typeMap(var.type)
	types[type] = true

	return ("\tpublic static var %s : %s;"):format(var.name, type)
end

function rawEmitFunction(typeName, f, types, static, multirets)
	local out = {""}

	local sigs = {}
	for i, v in ipairs(f.variants) do
		table.insert(sigs, emitOverload(typeName, f.name, v, types, multirets))
	end

	local main = table.remove(sigs, 1)
	for i, v in ipairs(sigs) do
		table.insert(out, ("\t@:overload(function %s {})"):format(v))
	end
	table.insert(out, ("\tpublic%s function %s%s;"):format(static and " static" or "", f.name, main))
	return table.concat(out, "\n")
end

function emitFunction(typeName, f, types, multirets)
	return rawEmitFunction(typeName, f, types, true, multirets)
end

function emitMethod(typeName, m, types, multirets)
	return rawEmitFunction(typeName, m, types, false, multirets)
end

local enumNameSanitizer = {
	["+"] = "plus",
	["-"] = "minus",
	["="] = "equals",
	["."] = "dot",
	["/"] = "slash",
	["\\"] = "backslash",
	["*"] = "asterisk",
	["!"] = "exclamation",
	["?"] = "question",
	["<"] = "less",
	[">"] = "greater",
	["&"] = "ampersand",
	["|"] = "pipe",
	["%"] = "percent",
	["$"] = "dollar",
	["#"] = "hash",
	["@"] = "at",
	["^"] = "caret",
	["~"] = "tilde",
	["`"] = "backtick",
	["("] = "parenleft",
	[")"] = "parenright",
	["["] = "bracketleft",
	["]"] = "bracketright",
	["{"] = "braceleft",
	["}"] = "braceright",
	[","] = "comma",
	[";"] = "semicolon",
	[":"] = "colon",
	["'"] = "apostrophe",
	["\""] = "quote",
	[" "] = "space",
	["_"] = "underscore",
}

local enumValueSanitizer = {
	["\\"] = "\\\\",
	["\""] = "\\\"",
}

function emitEnum(e, packageName)
	local out = {}
	table.insert(out, ("package %s;"):format(packageName))
	table.insert(out, "@:enum")
	table.insert(out, ("abstract %s (String)\n{"):format(e.name))

	for i, v in ipairs(e.constants) do
		local varName = capitalize(v.name:gsub(".", enumNameSanitizer))
		if tonumber(varName:sub(1, 1)) then
			varName = "_"..varName -- prepend underscore if the constant starts with a number
		end
		table.insert(out, ("\tvar %s = \"%s\";"):format(varName, v.name:gsub(".", enumValueSanitizer)))
	end

	table.insert(out, "}")
	return {[e.name .. ".hx"] = table.concat(out, "\n")}
end

function emitHeader(out, packageName)
	table.insert(out, ("package %s;"):format(packageName))
	table.insert(out, "import haxe.extern.Rest;")
	table.insert(out, "import lua.Table;")
	table.insert(out, "import lua.UserData;")
	table.insert(out, "")
end

function emitType(t, packageName)
	local out = {}
	local types = {}
	local multirets = {}
	emitHeader(out, packageName)

	local superType = t.supertypes and mostSpecificSupertype(t.supertypes) or "UserData"
	table.insert(out, ("extern class %s extends %s\n{"):format(t.name, superType))

	local emittedMethods = {}
	for i, v in ipairs(t.functions or {}) do
		if not emittedMethods[v.name] then -- FIXME: workaround because Mesh:attachAttribute is documented twice 
			table.insert(out, emitMethod(t.name, v, types, multirets))
			emittedMethods[v.name] = true
		end
	end

	table.insert(out, "}")
	table.insert(out, 2, resolveImports(types, packageName))

	for i, v in pairs(multirets) do
		table.insert(out, v)
	end
	return {[t.name .. ".hx"] = table.concat(out, "\n")}
end

function emitModule(m, luaName)
	local out = {}
	local files = {}
	local types = {}
	local multirets = {}

	local moduleName = luaName or "love." .. m.name
	local prefix = moduleName:gsub("%.", "/") .. "/"
	emitHeader(out, moduleName)
	table.insert(out, ("@:native(\"%s\")"):format(moduleName))
	local className = capitalize(luaName or (m.name .. "Module"))
	table.insert(out, ("extern class %s"):format(className))
	table.insert(out, "{")

	for i, v in ipairs(m.functions) do
		table.insert(out, emitFunction(className, v, types, multirets))
	end

	for i, v in ipairs(m.callbacks or {}) do
		table.insert(out, emitCallback(v, types))
	end

	-- Not official love-api structure, only used for undocumented features
	for i, v in ipairs(m.variables or {}) do
		table.insert(out, emitVariable(v, types))
	end

	table.insert(out, "}")

	for i, v in ipairs(m.enums or {}) do
		mergeTables(files, emitEnum(v, moduleName), prefix)
	end

	for i, v in ipairs(m.types or {}) do
		mergeTables(files, emitType(v, moduleName), prefix)
	end

	table.insert(out, 2, resolveImports(types, moduleName))

	for i, v in pairs(multirets) do
		table.insert(out, v)
	end
	files[prefix .. className .. ".hx"] = table.concat(out, "\n")
	return files
end

local files = {}

for i, v in ipairs(api.modules) do
	mergeTables(files, emitModule(v))
end

mergeTables(files, emitModule(api, "love"))

local windows = package.config:sub(1, 1) == "\\"

for i, v in pairs(files) do
	if windows then
		os.execute("mkdir \"" .. dirname(i):gsub("/", "\\") .. "\"")
	else
		os.execute("mkdir -p \"" .. dirname(i).."\"")
	end
	local f = io.open(i, "w")
	f:write(v)
	f:close()
end
