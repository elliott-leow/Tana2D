static NSDictionary *hwm_default_shortcuts(void)
{
    return @{
      @"left":@"ctrl+alt+cmd+left",@"right":@"ctrl+alt+cmd+right",@"up":@"ctrl+alt+cmd+up",@"down":@"ctrl+alt+cmd+down",
      @"move-left":@"ctrl+shift+alt+cmd+left",@"move-right":@"ctrl+shift+alt+cmd+right",
      @"move-up":@"ctrl+shift+alt+cmd+up",@"move-down":@"ctrl+shift+alt+cmd+down",
      @"maximize":@"ctrl+alt+cmd+m",@"fullscreen":@"f11",@"select-window":@"ctrl+alt+cmd+return",@"select-window-alt":@"ctrl+alt+cmd+s",@"fit-focused":@"ctrl+alt+cmd+f",@"actual-size":@"ctrl+alt+cmd+0",
      @"float":@"ctrl+alt+cmd+space",@"float-alt":@"ctrl+shift+alt+cmd+space",
      @"center":@"ctrl+alt+cmd+c",@"home":@"ctrl+alt+cmd+h",@"close":@"ctrl+alt+cmd+q",
      @"terminal":@"ctrl+alt+cmd+t",@"browser":@"ctrl+alt+cmd+b",
      @"previous":@"ctrl+alt+cmd+tab",@"undo":@"ctrl+alt+cmd+z",@"preset-width":@"ctrl+alt+cmd+r",
      @"commands":@"ctrl+alt+cmd+p",@"pause":@"ctrl+shift+alt+cmd+p",@"reload-config":@"ctrl+shift+alt+cmd+r"
    };
}
