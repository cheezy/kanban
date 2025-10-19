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
         files: %{excluded: ["test/support/data_case.ex"]}},
        {Credo.Check.Readability.AliasAs, []},
        {Credo.Check.Readability.MultiAlias, []},
        {Credo.Check.Readability.NestedFunctionCalls, []},
        {Credo.Check.Readability.SeparateAliasRequire, []},
        {Credo.Check.Readability.StrictModuleLayout, []},
        {Credo.Check.Readability.WithCustomTaggedTuple, []},
        {Credo.Check.Refactor.ABCSize, []},
        {Credo.Check.Warning.UnsafeToAtom, []},

        # Disabled checks
        {Credo.Check.Design.TagFIXME, false},
        {Credo.Check.Design.TagTODO, false},
        {Credo.Check.Readability.ModuleDoc, false},
        {Credo.Check.Refactor.LongQuoteBlocks, false},
        {Credo.Check.Refactor.Nesting, false}
      ]
    }
  ]
}
