local path = (...):match('(.-)[^%./]+$')

return function(module)
    table.insert(module.functions, {
        name = 'isCreated',
        description = '',
        variants = {
            {
                arguments = {
                },
                returns = {
                    {
                        type = 'boolean',
                        name = 'created',
                        description = '',
                    },
                },
            },
        },
    })
end