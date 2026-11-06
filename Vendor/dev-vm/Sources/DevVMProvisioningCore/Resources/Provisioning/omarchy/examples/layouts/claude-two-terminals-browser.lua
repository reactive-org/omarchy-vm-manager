-- Example per-VM layout: Claude on the right, two Foot terminals on the left,
-- and a floating Chromium window. Pass this file with
-- OMARCHY_LAYOUT_FILE; it is not installed by default.

local function workstation_window(class, size, move)
  o.window({ class = class }, {
    float = true,
    workspace = "1 silent",
    size = size,
    move = move,
    persistent_size = true,
  })
end

-- Claude occupies the full usable height of the right 60%.
workstation_window(
  "^com\\.anthropic\\.Claude$",
  { "(monitor_w*0.60-18)", "(monitor_h-50)" },
  { "(monitor_w*0.40+6)", 38 }
)

-- Dedicated Foot app IDs make the upper and lower left positions stable.
workstation_window(
  "^org\\.omarchy\\.dev-vm-terminal-top$",
  { "(monitor_w*0.40-18)", "(monitor_h*0.50-31)" },
  { 12, 38 }
)
workstation_window(
  "^org\\.omarchy\\.dev-vm-terminal-bottom$",
  { "(monitor_w*0.40-18)", "(monitor_h*0.50-31)" },
  { 12, "(monitor_h*0.50+6)" }
)

-- Chromium overlaps the base layout and remembers manual resizing.
workstation_window(
  "^omarchy-work-browser$",
  { "monitor_w*0.46", "monitor_h*0.62" },
  { "monitor_w*0.27", "monitor_h*0.18" }
)

-- Reopen missing layout terminals with their dedicated IDs. Once both slots
-- exist (or on another workspace), keep Omarchy's normal terminal launcher.
local regular_terminal = o.launch_terminal()
function o.launch_workstation_terminal()
  local workspace = hl.get_active_workspace()
  if not workspace or workspace.id ~= 1 then
    return regular_terminal()
  end

  local occupied = {}
  for _, window in ipairs(hl.get_windows()) do
    if window.class then occupied[window.class] = true end
  end
  for _, slot in ipairs({
    { "org.omarchy.dev-vm-terminal-top", "Top terminal" },
    { "org.omarchy.dev-vm-terminal-bottom", "Bottom terminal" },
  }) do
    if not occupied[slot[1]] then
      local active = hl.get_active_window()
      local pid = active and tonumber(active.pid)
      local directory = ' --working-directory="$(omarchy-cmd-terminal-cwd'
        .. (pid and " " .. math.floor(pid) or "") .. ')"'
      hl.exec_cmd(o.launch_sole(slot[1],
        "foot --app-id=" .. slot[1] .. " --title=" .. o.shell_quote(slot[2]) .. directory))
      return
    end
  end
  regular_terminal()
end
o.bind_expressions[o.launch_workstation_terminal] = "o.launch_workstation_terminal"
o.rebind("SUPER + RETURN", "Terminal", o.launch_workstation_terminal)

o.exec_on_start(o.launch_sole(
  "org.omarchy.dev-vm-terminal-top",
  "foot --app-id=org.omarchy.dev-vm-terminal-top --title='Top terminal'"
))
o.exec_on_start(o.launch_sole(
  "org.omarchy.dev-vm-terminal-bottom",
  "foot --app-id=org.omarchy.dev-vm-terminal-bottom --title='Bottom terminal'"
))
o.exec_on_start(o.launch_sole("com.anthropic.Claude", "claude-desktop"))
o.exec_on_start(o.launch_sole(
  "omarchy-work-browser",
  "chromium --class=omarchy-work-browser --new-window"
))
