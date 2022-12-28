local path = (...):match('(.-)[^%./]+$')

return function(api)
    api.variables = {
        {
            type ='table',
            name = 'handlers',
            description = '',
        }
    }

    table.insert(api.modules, require(path .. 'modules.arg.Arg'))

    local function modifyModule(name, f)
        for _,module in ipairs(api.modules) do
            if module.name == name then
                f(module)
                return
            end
        end
    end

    modifyModule("graphics", require(path .. "modules.graphics.Graphics"))
end