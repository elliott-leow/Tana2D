static NSDictionary *hwm_default_shortcuts(void)
{
    return @{
      @"left":@"alt+cmd+left",@"right":@"alt+cmd+right",@"up":@"alt+cmd+up",@"down":@"alt+cmd+down",
      @"move-left":@"shift+alt+cmd+left",@"move-right":@"shift+alt+cmd+right",
      @"move-up":@"shift+alt+cmd+up",@"move-down":@"shift+alt+cmd+down",
      @"maximize":@"shift+cmd+return",@"select-window":@"ctrl+return",@"select-window-alt":@"ctrl+up",@"fit-focused":@"alt+cmd+f",@"actual-size":@"alt+cmd+0",
      @"float":@"cmd+space",@"float-alt":@"alt+cmd+space",
      @"center":@"alt+cmd+c",@"home":@"alt+cmd+h",@"close":@"cmd+q",
      @"terminal":@"cmd+return",@"browser":@"shift+cmd+w",
      @"previous":@"alt+cmd+tab",@"undo":@"alt+cmd+z",@"preset-width":@"alt+cmd+r",
      @"commands":@"ctrl+alt+p",@"pause":@"ctrl+alt+shift+p",@"reload-config":@"ctrl+alt+r"
    };
}
