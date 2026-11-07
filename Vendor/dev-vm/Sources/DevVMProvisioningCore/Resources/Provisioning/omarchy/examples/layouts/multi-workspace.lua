-- Example per-VM layout: VS Code and Chromium on workspace 1, four Foot
-- terminals on workspace 2, and Claude with two Foot terminals on workspace 3.
-- Pass this file with OMARCHY_VM_LAYOUT_FILE; it is not installed by default.

local vscode_class = "^([Cc]ode|com[.]microsoft[.]VSCode)$"

local function workstation_window(class, workspace, size, move)
  o.window({ class = class }, {
    float = true,
    workspace = workspace .. " silent",
    size = size,
    move = move,
    persistent_size = true,
  })
end

-- Dedicated Foot app IDs keep all six terminal positions independent.
local function terminal(slot, title, workspace, size, move)
  local app_id = "org.omarchy.dev-vm-multi-" .. slot
  workstation_window("^" .. app_id:gsub("%.", "[.]") .. "$", workspace, size, move)
  o.exec_on_start(o.launch_sole(app_id,
    "foot --app-id=" .. app_id .. " --title=" .. o.shell_quote(title)))
end

-- Workspace 1: VS Code left 60%, Chromium right 40%.
workstation_window(
  vscode_class, 1,
  { "(monitor_w*0.60-18)", "(monitor_h-50)" },
  { 12, 38 }
)
workstation_window(
  "^omarchy-multi-browser$", 1,
  { "(monitor_w*0.40-18)", "(monitor_h-50)" },
  { "(monitor_w*0.60+6)", 38 }
)

-- Workspace 2: equal 2x2 terminal grid with the usual panel and gap clearance.
local quarter_size = { "(monitor_w*0.50-18)", "(monitor_h*0.50-31)" }
terminal("ws2-top-left", "Workspace 2: top left", 2, quarter_size, { 12, 38 })
terminal("ws2-top-right", "Workspace 2: top right", 2, quarter_size,
  { "(monitor_w*0.50+6)", 38 })
terminal("ws2-bottom-left", "Workspace 2: bottom left", 2, quarter_size,
  { 12, "(monitor_h*0.50+19)" })
terminal("ws2-bottom-right", "Workspace 2: bottom right", 2, quarter_size,
  { "(monitor_w*0.50+6)", "(monitor_h*0.50+19)" })

-- Workspace 3: Claude right 60%, two terminals stacked in the left 40%.
workstation_window(
  "^com[.]anthropic[.]Claude$", 3,
  { "(monitor_w*0.60-18)", "(monitor_h-50)" },
  { "(monitor_w*0.40+6)", 38 }
)
local stacked_size = { "(monitor_w*0.40-18)", "(monitor_h*0.50-31)" }
terminal("ws3-top", "Workspace 3: top", 3, stacked_size, { 12, 38 })
terminal("ws3-bottom", "Workspace 3: bottom", 3, stacked_size,
  { 12, "(monitor_h*0.50+19)" })

o.exec_on_start(o.launch_sole(vscode_class, "code --new-window"))
o.exec_on_start(o.launch_sole(
  "omarchy-multi-browser",
  "chromium --class=omarchy-multi-browser --new-window"
))
o.exec_on_start(o.launch_sole("com.anthropic.Claude", "claude-desktop"))
