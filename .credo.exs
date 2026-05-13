%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: [
        # Additional and reconfigured checks
        {Credo.Check.Design.AliasUsage,
         if_nested_deeper_than: 3,
         if_called_more_often_than: 1,
         files: %{
           included: ["lib/", "test/", "config/"],
           excluded: ["_build/", "deps/", "priv/static/", "assets/node_modules/"]
         }},
        {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 9},
        {Credo.Check.Refactor.ABCSize, max_size: 20},
        {Credo.Check.Refactor.FunctionArity, max_arity: 6},
        {Credo.Check.Readability.AliasAs, []},
        {Credo.Check.Readability.MultiAlias, []},
        {Credo.Check.Readability.NestedFunctionCalls, []},
        {Credo.Check.Readability.SeparateAliasRequire, []},
        {Credo.Check.Readability.StrictModuleLayout, []},
        {Credo.Check.Readability.WithCustomTaggedTuple, []},
        {Credo.Check.Warning.UnsafeToAtom, []},
        {Credo.Check.Refactor.Nesting, max_nesting: 3},

        # Disabled checks
        {Credo.Check.Design.TagFIXME, false},
        {Credo.Check.Design.TagTODO, false},
        {Credo.Check.Readability.ModuleDoc, false},
        {Credo.Check.Refactor.LongQuoteBlocks, false}
      ]
    }
  ]
}
