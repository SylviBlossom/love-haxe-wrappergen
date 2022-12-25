local path = (...):match('(.-)[^%./]+$')

return function(api)
    table.insert(api.modules, require(path .. 'modules.arg.Arg'))
end