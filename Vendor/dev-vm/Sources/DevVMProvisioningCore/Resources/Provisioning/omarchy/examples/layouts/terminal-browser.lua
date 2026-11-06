-- Example per-VM layout: a Foot terminal on the left (40%) and Chromium on
-- the right (60%). Pass this file with OMARCHY_LAYOUT_FILE; it is not
-- installed by default.

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
  "^org\\.omarchy\\.dev-vm-terminal$",
  { "(monitor_w*0.40-18)", "(monitor_h-50)" },
  { 12, 38 }
)
workstation_window(
  "^omarchy-work-browser$",
  { "(monitor_w*0.60-18)", "(monitor_h-50)" },
  { "(monitor_w*0.40+6)", 38 }
)

o.exec_on_start(o.launch_sole(
  "org.omarchy.dev-vm-terminal",
  "foot --app-id=org.omarchy.dev-vm-terminal --title='Work terminal'"
))
o.exec_on_start(o.launch_sole(
  "omarchy-work-browser",
  "chromium --class=omarchy-work-browser --new-window"
))
