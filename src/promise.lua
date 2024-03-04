local typed_script = script :: LuaSourceContainer & {
    Parent: {
        Parent: {
            ["lukadev-0_typed-promise@4.0.2"]: ModuleScript
        }
    }
}

return require(typed_script.Parent.Parent["lukadev-0_typed-promise@4.0.2"])