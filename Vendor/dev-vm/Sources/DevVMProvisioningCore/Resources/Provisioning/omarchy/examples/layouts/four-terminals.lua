-- Example per-VM layout: four Foot terminals in an equal 2x2 grid on
-- workspace 1. Pass this file with OMARCHY_VM_LAYOUT_FILE; it is not
-- installed by default.

local function workstation_window(class, move)
  o.window({ class = class }, {
    float = true,
    workspace = "1 silent",
    size = { "(monitor_w*0.50-18)", "(monitor_h*0.50-31)" },
    move = move,
    persistent_size = true,
  })
end

-- Keep the usual outer gaps, panel clearance and 12-pixel inner gaps.
-- Dedicated Foot app IDs give each terminal a stable corner.
workstation_window("^org\\.omarchy\\.dev-vm-terminal-top-left$", { 12, 38 })
workstation_window(
  "^org\\.omarchy\\.dev-vm-terminal-top-right$",
  { "(monitor_w*0.50+6)", 38 }
)
workstation_window(
  "^org\\.omarchy\\.dev-vm-terminal-bottom-left$",
  { 12, "(monitor_h*0.50+19)" }
)
workstation_window(
  "^org\\.omarchy\\.dev-vm-terminal-bottom-right$",
  { "(monitor_w*0.50+6)", "(monitor_h*0.50+19)" }
)

o.exec_on_start(o.launch_sole(
  "org.omarchy.dev-vm-terminal-top-left",
  "foot --app-id=org.omarchy.dev-vm-terminal-top-left --title='Top left terminal'"
))
o.exec_on_start(o.launch_sole(
  "org.omarchy.dev-vm-terminal-top-right",
  "foot --app-id=org.omarchy.dev-vm-terminal-top-right --title='Top right terminal'"
))
o.exec_on_start(o.launch_sole(
  "org.omarchy.dev-vm-terminal-bottom-left",
  "foot --app-id=org.omarchy.dev-vm-terminal-bottom-left --title='Bottom left terminal'"
))
o.exec_on_start(o.launch_sole(
  "org.omarchy.dev-vm-terminal-bottom-right",
  "foot --app-id=org.omarchy.dev-vm-terminal-bottom-right --title='Bottom right terminal'"
))
