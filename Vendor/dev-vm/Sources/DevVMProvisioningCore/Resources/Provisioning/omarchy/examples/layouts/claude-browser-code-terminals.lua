-- Example per-VM layout: Claude Desktop and Chromium on workspace 1,
-- VS Code on workspace 2, and four Foot terminals on workspace 3.
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

-- Workspace 1: Claude Desktop left 60%, Chromium right 40%.
workstation_window(
  "^com[.]anthropic[.]Claude$", 1,
  { "(monitor_w*0.60-18)", "(monitor_h-50)" },
  { 12, 38 }
)
workstation_window(
  "^omarchy-claude-code-browser$", 1,
  { "(monitor_w*0.40-18)", "(monitor_h-50)" },
  { "(monitor_w*0.60+6)", 38 }
)

-- Workspace 2: VS Code fills the usable area, preserving panel clearance and gaps.
workstation_window(
  vscode_class, 2,
  { "(monitor_w-24)", "(monitor_h-50)" },
  { 12, 38 }
)

-- Workspace 3: equal 2x2 terminal grid, with a dedicated app ID for each corner.
local function terminal(slot, title, move)
  local app_id = "org.omarchy.dev-vm-claude-code-ws3-" .. slot
  workstation_window("^" .. app_id:gsub("%.", "[.]") .. "$", 3,
    { "(monitor_w*0.50-18)", "(monitor_h*0.50-31)" }, move)
  o.exec_on_start(o.launch_sole(app_id,
    "foot --app-id=" .. app_id .. " --title=" .. o.shell_quote(title)))
end

terminal("top-left", "Workspace 3: top left", { 12, 38 })
terminal("top-right", "Workspace 3: top right", { "(monitor_w*0.50+6)", 38 })
terminal("bottom-left", "Workspace 3: bottom left", { 12, "(monitor_h*0.50+19)" })
terminal("bottom-right", "Workspace 3: bottom right",
  { "(monitor_w*0.50+6)", "(monitor_h*0.50+19)" })

o.exec_on_start(o.launch_sole("com.anthropic.Claude", "claude-desktop"))
o.exec_on_start(o.launch_sole(
  "omarchy-claude-code-browser",
  "chromium --class=omarchy-claude-code-browser --new-window"
))
o.exec_on_start(o.launch_sole(vscode_class, "code --new-window"))
