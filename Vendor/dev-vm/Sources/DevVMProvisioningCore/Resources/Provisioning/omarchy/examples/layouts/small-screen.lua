-- Example per-VM layout for one smaller display: Claude Desktop on workspace 1,
-- Chromium on 2, VS Code on 3, and two side-by-side Foot terminals on 4.
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

-- Each app fills the usable area, preserving the panel and usual outer gaps.
local full_size = { "(monitor_w-24)", "(monitor_h-50)" }
workstation_window("^com[.]anthropic[.]Claude$", 1, full_size, { 12, 38 })
workstation_window("^omarchy-small-screen-browser$", 2, full_size, { 12, 38 })
workstation_window(vscode_class, 3, full_size, { 12, 38 })

-- Workspace 4: equal-width, full-height terminals separated by a 12-pixel gap.
-- Dedicated app IDs keep their left/right positions independent.
local function terminal(slot, title, move)
  local app_id = "org.omarchy.dev-vm-small-screen-" .. slot
  workstation_window("^" .. app_id:gsub("%.", "[.]") .. "$", 4,
    { "(monitor_w*0.50-18)", "(monitor_h-50)" }, move)
  o.exec_on_start(o.launch_sole(app_id,
    "foot --app-id=" .. app_id .. " --title=" .. o.shell_quote(title)))
end

terminal("left", "Left terminal", { 12, 38 })
terminal("right", "Right terminal", { "(monitor_w*0.50+6)", 38 })

o.exec_on_start(o.launch_sole("com.anthropic.Claude", "claude-desktop"))
o.exec_on_start(o.launch_sole(
  "omarchy-small-screen-browser",
  "chromium --class=omarchy-small-screen-browser --new-window"
))
o.exec_on_start(o.launch_sole(vscode_class, "code --new-window"))
