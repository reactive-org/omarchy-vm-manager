-- Example per-VM layout: VS Code on the left (60%) and Chromium on the
-- right (40%). Pass this file with OMARCHY_LAYOUT_FILE; it is not
-- installed by default.

-- VS Code uses its desktop app ID on native Wayland and Code/code on XWayland.
local vscode_class = "^([Cc]ode|com[.]microsoft[.]VSCode)$"

local function workstation_window(class, size, move)
  o.window({ class = class }, {
    float = true,
    workspace = "1 silent",
    size = size,
    move = move,
    persistent_size = true,
  })
end

-- Both windows occupy the full usable height, with the usual outer gaps.
workstation_window(
  vscode_class,
  { "(monitor_w*0.60-18)", "(monitor_h-50)" },
  { 12, 38 }
)
workstation_window(
  "^omarchy-work-browser$",
  { "(monitor_w*0.40-18)", "(monitor_h-50)" },
  { "(monitor_w*0.60+6)", 38 }
)

o.exec_on_start(o.launch_sole(vscode_class, "code --new-window"))
o.exec_on_start(o.launch_sole(
  "omarchy-work-browser",
  "chromium --class=omarchy-work-browser --new-window"
))
