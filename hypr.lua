-- ---------------------------------------------------------------------------
-- Game Focus -- Hyprland side
--
-- Loaded from ~/.config/hypr/hyprland.lua; see README.md for what it does and
-- how it is installed. Enabled state is owned by the Omarchy shell's plugin
-- registry, so this file registers nothing at all unless the companion plugin
-- pashadev.game-focus is enabled.
-- ---------------------------------------------------------------------------

local HOME = os.getenv("HOME")
local SHELL_JSON = HOME .. "/.config/omarchy/shell.json"
-- omarchy-toggle's flag directory. It hardcodes ~/.local/state, so this does too.
local TOGGLES = HOME .. "/.local/state/omarchy/toggles/"
local INSTANCE = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")

-- Everything this file checks at runtime is read in-process, never by spawning
-- a command: this runs on Hyprland's main thread, where even a quick shell-out
-- (o.shell_succeeds) freezes the screen for as long as it takes.
local function read_file(path)
  local file = io.open(path)
  if not file then
    return nil
  end

  local text = file:read("*a")
  file:close()
  return text
end

-- A third-party plugin is enabled iff its id is in shell.json, which is what
-- `omarchy plugin enable|disable` writes -- the same rule as the CLI's
-- is_enabled, and like it this fails open.
local function plugin_enabled()
  local text = read_file(SHELL_JSON)
  return not text or text:find('"id"%s*:%s*"pashadev%.game%-focus"') ~= nil
end

if not plugin_enabled() then
  return
end

local paths = require("default.hypr.paths")

-- --- Configuration ---------------------------------------------------------

local TOGGLE_KEY = "SUPER + F12"

-- Arm and disarm on their own when a game goes fullscreen. false = manual only.
local AUTO_DETECT = true

-- Hyprland regexes, matched against a window's class. Used in exactly one place:
-- the window rules at the bottom, which tag matching windows "game". Lua never
-- matches classes itself -- it reads that tag -- so there is one matcher and one
-- syntax here. Add a game by running `hyprctl clients -j` while it runs and
-- copying its class.
local GAME_CLASSES = {
  "^steam_app_.*", -- every Steam title, native or Proton
  "^gamescope$",
  "^com\\.libretro\\.RetroArch$",
  "^com\\.moonlight_stream\\.Moonlight$",
  "^GeForceNOW$",
  "^lutris-.*",
  "^heroic$",
}

-- Neutered while armed, restored on exit. Deliberately all scalars: they
-- round-trip through hl.get_config cleanly, unlike the "css gap data" values.
-- Gaps and border_size are left alone on purpose -- a fullscreen window has
-- neither, so changing them would be risk for no gain.
local GAME_CONFIG = {
  ["animations.enabled"] = false,
  ["decoration.blur.enabled"] = false,
  ["decoration.shadow.enabled"] = false,
  ["decoration.dim_inactive"] = false,
  ["decoration.rounding"] = 0,
  ["cursor.zoom_factor"] = 1,
}

-- Flags under ~/.local/state/omarchy/toggles/. They exist so the mode survives
-- `hyprctl reload`, which rebuilds this Lua state (though not the submap) --
-- without them, editing any hypr config mid-game would silently un-protect you.
-- Each flag holds the instance signature of the Hyprland that set it: a reload
-- keeps the instance, a crash or reboot starts a new one, so a flag naming
-- another instance is a leftover to clean up rather than a mode to restore.
local ARMED_FLAG = "game-focus"
local HID_BAR_FLAG = "game-focus-hid-bar"

-- Grace period before auto-disarming. Notifications, the Omarchy menu and game
-- overlays all steal focus for an instant and fire window.active; without this
-- the mode would drop every time one appeared.
local AUTO_DISARM_DELAY = 600 -- ms

-- How often to check whether the plugin has been disabled behind our back.
local REGISTRY_POLL = 10000 -- ms

-- --- State -----------------------------------------------------------------

local state = {
  armed = false,
  armed_by = nil, -- "manual" | "auto"
  saved = nil, -- config values captured at arm time
  hid_bar = nil,
  disarm_generation = 0, -- bumped to cancel a pending auto-disarm
  dismissed = nil, -- stable_id of a game you switched off by hand
}

-- --- Helpers ---------------------------------------------------------------

local function flag_set(name)
  return read_file(TOGGLES .. name) ~= nil
end

local function set_flag(name, on)
  local path = o.shell_quote(TOGGLES .. name)
  if on then
    hl.exec_cmd(
      "mkdir -p " .. o.shell_quote(TOGGLES) .. " && printf %s " .. o.shell_quote(INSTANCE) .. " >" .. path
    )
  else
    hl.exec_cmd("rm -f " .. path)
  end
end

-- Careful: omarchy-toggle-bar's argument names the state of a flag called
-- "bar-off", not the visibility of the bar, so it reads backwards --
-- `omarchy-toggle-bar on` sets bar-off and HIDES the bar.
local function set_bar_hidden(hidden)
  hl.exec_cmd("omarchy-toggle-bar " .. (hidden and "on" or "off"))
end

local function notify(headline, description)
  hl.exec_cmd(
    "omarchy-notification-send -u low -t 1500 "
      .. o.shell_quote(headline)
      .. " "
      .. o.shell_quote(description)
  )
end

-- The part of disarming that outlives this Lua state: the submap, the bar and
-- the flags. The CLI's force_unpick is the same thing from outside.
local function unpick(hid_bar)
  hl.dispatch(hl.dsp.submap("reset"))
  if hid_bar then
    set_bar_hidden(false)
  end
  set_flag(HID_BAR_FLAG, false)
  set_flag(ARMED_FLAG, false)
end

-- The window rules at the bottom tag every matching window "game", so Hyprland
-- does the class matching and this only reads the result. Dynamic tags carry a
-- trailing "*" (see default/hypr/bindings/clipboard.lua).
local function is_game(window)
  if not window then
    return false
  end

  if window.content_type == "game" then
    return true
  end

  for _, tag in ipairs(window.tags or {}) do
    if tag:gsub("%*$", "") == "game" then
      return true
    end
  end

  return false
end

-- The focused window, if it is a fullscreen game you haven't switched off by hand.
local function playing_now()
  local window = hl.get_active_window()
  if is_game(window) and window.fullscreen ~= 0 and window.stable_id ~= state.dismissed then
    return window
  end
end

-- Forward declaration: the submap below binds a callback that calls disarm, and
-- a Lua closure captures upvalues that already exist.
local arm, disarm

-- --- The submap ------------------------------------------------------------
--
-- Entering a submap replaces the whole active bind set, so everything NOT bound
-- in here falls through to the game.

hl.define_submap("game", function()
  -- Media, volume, brightness, keyboard backlight. Re-executing Omarchy's own
  -- file beats copying ~30 XF86 binds that would drift on the next update. It
  -- must be dofile, not require: bootstrap.lua leaves the module in
  -- package.loaded, so require would return the cache and register nothing.
  dofile(paths.omarchy_path .. "/default/hypr/bindings/media.lua")

  o.bind("PRINT", "Screenshot", "omarchy-capture-screenshot")
  o.bind(
    "ALT + PRINT",
    "Screenrecording",
    "omarchy-capture-screenrecording --stop-recording || omarchy-menu toggle trigger.capture.screenrecord"
  )

  -- Kept so you can duck out to Discord and back without leaving the mode.
  for workspace = 1, 10 do
    o.bind(
      "SUPER + code:" .. tostring(workspace + 9),
      "Switch to workspace " .. workspace,
      hl.dsp.focus({ workspace = tostring(workspace) })
    )
  end
  o.bind("SUPER + TAB", "Next workspace", hl.dsp.focus({ workspace = "e+1" }))
  o.bind("SUPER + SHIFT + TAB", "Previous workspace", hl.dsp.focus({ workspace = "e-1" }))

  -- Escape hatch for a hung game. Deliberately awkward: plain SUPER + W is
  -- released to the game here, and this cannot be hit by accident.
  o.bind("SUPER + CTRL + ALT + W", "Close window (game focus)", hl.dsp.window.close())

  -- Belt and braces. TOGGLE_KEY leaves via submap_universal, the documented way
  -- to make one key both enter and leave a submap -- but a bind that only fires
  -- inside a submap cannot be verified without physically pressing it, and being
  -- wrong would mean no keyboard way out. A *different* key bound inside the
  -- submap is the path known to work (Hyprland#14733).
  o.bind("SUPER + SHIFT + F12", "Leave game focus mode", function()
    disarm("manual")
  end)

  -- Deliberately absent: ALT + TAB, SUPER + mouse:272/273, SUPER + scroll,
  -- SUPER + W/F/T/G/P, SUPER + C/V/X, and every menu binding.
end)

-- --- Arm / disarm ----------------------------------------------------------

function arm(by, quiet)
  if state.armed then
    return
  end

  state.armed = true
  state.armed_by = by
  state.disarm_generation = state.disarm_generation + 1 -- cancels a pending disarm
  if by == "manual" then
    state.dismissed = nil
  end

  -- hl.config takes the same dotted keys hl.get_config does.
  state.saved = {}
  for key in pairs(GAME_CONFIG) do
    state.saved[key] = hl.get_config(key)
  end
  hl.config(GAME_CONFIG)

  -- Only hide the bar if it isn't already hidden, so disarming can't reveal a
  -- bar you had deliberately turned off. Recorded on disk too: a reload mid-game
  -- wipes the locals but not the bar, so if the flag is already there we are
  -- recovering from one and the bar is hidden because we hid it.
  state.hid_bar = flag_set(HID_BAR_FLAG) or not flag_set("bar-off")
  if state.hid_bar then
    set_bar_hidden(true)
    set_flag(HID_BAR_FLAG, true)
  end

  set_flag(ARMED_FLAG, true)
  hl.dispatch(hl.dsp.submap("game"))

  if not quiet then
    notify("Game focus on", "Shortcuts released to the game")
  end
end

function disarm(by, quiet)
  if not state.armed then
    return
  end

  -- A mode you switched on by hand is never switched off by the watcher --
  -- glancing at an overlay shouldn't silently drop your protection.
  if by == "auto" and state.armed_by == "manual" then
    return
  end

  -- Switched off by hand mid-game: leave this window alone until you arm by hand
  -- again, or the next focus change would re-arm it straight away.
  if by == "manual" then
    local game = playing_now()
    state.dismissed = game and game.stable_id
  end

  hl.config(state.saved)
  unpick(state.hid_bar)

  state.armed = false
  state.armed_by = nil
  state.saved = nil
  state.hid_bar = nil
  state.disarm_generation = state.disarm_generation + 1

  if not quiet then
    notify("Game focus off", "Shortcuts restored")
  end
end

local function toggle()
  if state.armed then
    disarm("manual")
  else
    arm("manual")
  end
end

-- submap_universal is what lets one key both enter and leave the submap; a plain
-- bind cannot (Hyprland#14733).
o.bind(TOGGLE_KEY, "Toggle game focus mode", toggle, { submap_universal = true })

-- --- Auto-detection --------------------------------------------------------

local function reevaluate()
  if playing_now() then
    arm("auto") -- bumps the generation, cancelling any disarm in flight
    return
  end

  if not state.armed or state.armed_by ~= "auto" then
    return
  end

  -- Don't act on the focus change yet; re-check once things have settled, and
  -- bail if anything happened in between.
  state.disarm_generation = state.disarm_generation + 1
  local generation = state.disarm_generation

  hl.timer(function()
    if state.disarm_generation == generation and not playing_now() then
      disarm("auto")
    end
  end, { timeout = AUTO_DISARM_DELAY, type = "oneshot" })
end

if AUTO_DETECT then
  hl.on("window.fullscreen", reevaluate)
  hl.on("window.active", reevaluate)

  -- The closing window is still active when this fires, so look again once it
  -- has actually gone.
  hl.on("window.close", function()
    hl.timer(reevaluate, { timeout = 100, type = "oneshot" })
  end)
end

-- Catch up with whatever is already on screen. Deferred rather than run inline,
-- because the window rules below have not been applied yet at this point in the
-- config load, so the "game" tag this depends on would not be there to read.
hl.timer(function()
  local armed_by = read_file(TOGGLES .. ARMED_FLAG)
  if armed_by and armed_by ~= INSTANCE then
    -- Left by a Hyprland that crashed or lost power while armed. Its config
    -- died with it; the hidden bar and the flags carry over. Don't start the new
    -- session locked in.
    unpick(flag_set(HID_BAR_FLAG))
  elseif armed_by then
    -- Recovering from a reload that happened while armed: the locals are gone,
    -- but the flag survived. Attribute it to the
    -- watcher when a game is on screen, so it still disarms by itself when the
    -- game ends; recovering as "manual" would leave you stuck after quitting.
    arm(AUTO_DETECT and playing_now() and "auto" or "manual", true)
  elseif AUTO_DETECT and playing_now() then
    -- Loading with a game already fullscreen: the plugin was just enabled, or
    -- Hyprland restarted mid-session. No window event fires for a window that is
    -- already there, so the watcher would stay idle until you alt-tabbed away.
    arm("auto")
  end
end, { timeout = 500, type = "oneshot" })

-- --- Watch for being disabled ----------------------------------------------
--
-- `omarchy plugin disable` rewrites shell.json and fires no hooks, so nothing
-- tells Hyprland. The shell service cannot report it either -- by then it has
-- been unloaded. So this side checks for its own removal and stands down. The
-- opposite direction needs nothing here: enabling starts the service, which
-- reloads Hyprland, which loads this file.
hl.timer(function()
  if plugin_enabled() then
    return
  end

  -- Disarm first: the reload restores config values but not the hidden bar.
  disarm("manual", true)
  hl.exec_cmd("hyprctl reload")
end, { timeout = REGISTRY_POLL, type = "repeat" })

-- --- CLI entry point -------------------------------------------------------
--
-- `omarchy-game-focus on|off|toggle` reaches this through
-- `hyprctl dispatch '<expr>'`, which evaluates the expression in this Lua state
-- and passes the result to hl.dispatch -- hence the no_op return, so the work
-- happens as a side effect and hl.dispatch still receives something valid.
_G.omarchy_game_focus = function(action)
  if action == "on" then
    arm("manual")
  elseif action == "off" then
    disarm("manual")
  else
    toggle()
  end
  return hl.dsp.no_op()
end

-- --- A stationary click is not a drag --------------------------------------
--
-- SUPER + left/right click are bound to movewindow/resizewindow. With
-- drag_threshold at its default of 0 a click with zero mouse movement counts as
-- a drag, so merely holding SUPER and right-clicking floats a fullscreen window
-- and drops it out of fullscreen. At 12px move/resize needs an actual drag.
-- Desktop-wide rather than only while armed, which is why it reverts when the
-- plugin is disabled.
hl.config({ binds = { drag_threshold = 12 } })

-- --- Window rules ----------------------------------------------------------
--
-- The "game" tag is what is_game() reads above. The rest is always-on polish:
-- default/hypr/windows.lua tags every window "default-opacity" and renders it at
-- `0.985 0.96`, so a borderless-windowed game is composited translucent for no
-- reason, and idle_inhibit is set upstream for the Steam client, RetroArch and
-- Moonlight but not for steam_app_* -- i.e. not for actual games, which is why
-- the screen blanks during a controller-only session.
for _, class in ipairs(GAME_CLASSES) do
  o.window(class, {
    tag = "+game",
    opacity = "1 1",
    idle_inhibit = "fullscreen",
    no_blur = true,
    no_shadow = true,
    rounding = 0,
  })
end
