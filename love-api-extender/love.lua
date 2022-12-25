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
end