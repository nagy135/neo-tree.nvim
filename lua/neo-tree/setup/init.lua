local utils = require("neo-tree.utils")
local defaults = require("neo-tree.defaults")
local mapping_helper = require("neo-tree.setup.mapping-helper")
local events = require("neo-tree.events")
local log = require("neo-tree.log")
local file_nesting = require("neo-tree.sources.common.file-nesting")
local highlights = require("neo-tree.ui.highlights")
local manager = require("neo-tree.sources.manager")
local netrw = require("neo-tree.setup.netrw")

-- If you add a new source, you need to add it to the sources table.
-- Each source should have a defaults module that contains the default values
-- for the source config, and a setup function that takes that config.
local sources = {
  "filesystem",
  "buffers",
  "git_status",
}

local M = {}

local normalize_mappings = function(config)
  if config == nil then
    return false
  end
  local mappings = utils.get_value(config, "window.mappings", nil)
  if mappings then
    local fixed = mapping_helper.normalize_map(mappings)
    config.window.mappings = fixed
    return true
  else
    return false
  end
end

local events_setup = false
local define_events = function()
  if events_setup then
    return
  end

  local v = vim.version()
  local diag_autocmd = "DiagnosticChanged"
  if v.major < 1 and v.minor < 6 then
    diag_autocmd = "User LspDiagnosticsChanged"
  end
  events.define_autocmd_event(events.VIM_DIAGNOSTIC_CHANGED, { diag_autocmd }, 500, function(args)
    args.diagnostics_lookup = utils.get_diagnostic_counts()
    return args
  end)

  events.define_autocmd_event(
    events.VIM_BUFFER_CHANGED,
    { "BufWritePost", "BufFilePost", "BufModifiedSet" },
    200
  )
  events.define_autocmd_event(events.VIM_BUFFER_MODIFIED_SET, { "BufModifiedSet" }, 0)
  events.define_autocmd_event(events.VIM_BUFFER_ADDED, { "BufAdd" }, 200)
  events.define_autocmd_event(events.VIM_BUFFER_DELETED, { "BufDelete" }, 200)
  events.define_autocmd_event(events.VIM_BUFFER_ENTER, { "BufEnter", "BufWinEnter" }, 0)
  events.define_autocmd_event(events.VIM_WIN_ENTER, { "WinEnter" }, 0)
  events.define_autocmd_event(events.VIM_DIR_CHANGED, { "DirChanged" }, 200, nil, true)
  events.define_autocmd_event(events.VIM_TAB_CLOSED, { "TabClosed" })
  events.define_autocmd_event(events.VIM_COLORSCHEME, { "ColorScheme" }, 0)
  events.define_event(events.GIT_STATUS_CHANGED, { debounce_frequency = 0 })
  events_setup = true
end

local last_buffer_enter_filetype = nil
M.buffer_enter_event = function()
  -- if it is a neo-tree window, just set local options
  if vim.bo.filetype == "neo-tree" then
    vim.cmd([[
    setlocal cursorline
    setlocal nowrap
    setlocal winhighlight=Normal:NeoTreeNormal,NormalNC:NeoTreeNormalNC,SignColumn:NeoTreeSignColumn,CursorLine:NeoTreeCursorLine,FloatBorder:NeoTreeFloatBorder,StatusLine:NeoTreeStatusLine,StatusLineNC:NeoTreeStatusLineNC,VertSplit:NeoTreeVertSplit,EndOfBuffer:NeoTreeEndOfBuffer
    setlocal nolist nospell nonumber norelativenumber
    ]])
    events.fire_event(events.NEO_TREE_BUFFER_ENTER)
    last_buffer_enter_filetype = vim.bo.filetype
    return
  end
  if vim.bo.filetype == "neo-tree-popup" then
    vim.cmd([[
    setlocal winhighlight=Normal:NeoTreeNormal,FloatBorder:NeoTreeFloatBorder
    setlocal nolist nospell nonumber norelativenumber
    ]])
    events.fire_event(events.NEO_TREE_POPUP_BUFFER_ENTER)
    last_buffer_enter_filetype = vim.bo.filetype
    return
  end

  if last_buffer_enter_filetype == "neo-tree" then
    events.fire_event(events.NEO_TREE_BUFFER_LEAVE)
  end
  if last_buffer_enter_filetype == "neo-tree-popup" then
    events.fire_event(events.NEO_TREE_POPUP_BUFFER_LEAVE)
  end
  last_buffer_enter_filetype = vim.bo.filetype

  -- there is nothing more we want to do with floating windows
  if utils.is_floating() then
    return
  end

  -- if vim is trying to open a dir, then we hijack it
  if netrw.hijack() then
    return
  end

  -- For all others, make sure another buffer is not hijacking our window
  -- ..but not if the position is "current"
  local prior_buf = vim.fn.bufnr("#")
  if prior_buf < 1 then
    return
  end
  local prior_type = vim.api.nvim_buf_get_option(prior_buf, "filetype")
  if prior_type == "neo-tree" then
    local position = vim.api.nvim_buf_get_var(prior_buf, "neo_tree_position")
    if position == "current" then
      -- nothing to do here, files are supposed to open in same window
      return
    end

    local current_tabnr = vim.api.nvim_get_current_tabpage()
    local neo_tree_tabnr = vim.api.nvim_buf_get_var(prior_buf, "neo_tree_tabnr")
    if neo_tree_tabnr ~= current_tabnr then
      -- This a new tab, so the alternate being neo-tree doesn't matter.
      return
    end
    local neo_tree_winid = vim.api.nvim_buf_get_var(prior_buf, "neo_tree_winid")
    local current_winid = vim.api.nvim_get_current_win()
    if neo_tree_winid ~= current_winid then
      -- This is not the neo-tree window, so the alternate being neo-tree doesn't matter.
      return
    end

    local bufname = vim.api.nvim_buf_get_name(0)
    log.debug("redirecting buffer " .. bufname .. " to new split")
    vim.cmd("b#")
    -- Using schedule at this point  fixes problem with syntax
    -- highlighting in the buffer. I also prevents errors with diagnostics
    -- trying to work with the buffer as it's being closed.
    vim.schedule(function()
      -- try to delete the buffer, only because if it was new it would take
      -- on options from the neo-tree window that are undesirable.
      pcall(vim.cmd, "bdelete " .. bufname)
      local fake_state = {
        window = {
          position = position,
        },
      }
      utils.open_file(fake_state, bufname)
    end)
  end
end

M.win_enter_event = function()
  local win_id = vim.api.nvim_get_current_win()
  if utils.is_floating(win_id) then
    return
  end

  -- if the new win is not a floating window, make sure all neo-tree floats are closed
  require("neo-tree").close_all("float")

  if M.config.close_if_last_window then
    local tabnr = vim.api.nvim_get_current_tabpage()
    local wins = utils.get_value(M, "config.prior_windows", {})[tabnr]
    local prior_exists = utils.truthy(wins)
    local non_floating_wins = vim.tbl_filter(function(win)
      return not utils.is_floating(win)
    end, vim.api.nvim_tabpage_list_wins(tabnr))
    local win_count = #non_floating_wins
    log.trace("checking if last window")
    log.trace("prior window exists = ", prior_exists)
    log.trace("win_count: ", win_count)
    if prior_exists and win_count == 1 and vim.o.filetype == "neo-tree" then
      local position = vim.api.nvim_buf_get_var(0, "neo_tree_position")
      if position ~= "current" then
        -- close_if_last_window just doesn't make sense for a split style
        log.trace("last window, closing")
        vim.cmd("q!")
        return
      end
    end
  end

  if vim.o.filetype == "neo-tree" then
    -- it's a neo-tree window, ignore
    return
  end

  M.config.prior_windows = M.config.prior_windows or {}

  local tabnr = vim.api.nvim_get_current_tabpage()
  local tab_windows = M.config.prior_windows[tabnr]
  if tab_windows == nil then
    tab_windows = {}
    M.config.prior_windows[tabnr] = tab_windows
  end
  table.insert(tab_windows, win_id)

  -- prune the history when it gets too big
  if #tab_windows > 100 then
    local new_array = {}
    local win_count = #tab_windows
    for i = 80, win_count do
      table.insert(new_array, tab_windows[i])
    end
    M.config.prior_windows[tabnr] = new_array
  end
end

M.set_log_level = function(level)
  log.set_level(level)
end

local function merge_global_components_config(components, config)
  local indent_exists = false
  local merged_components = {}
  local do_merge

  do_merge = function(component)
    local name = component[1]
    if type(name) == "string" then
      if name == "indent" then
        indent_exists = true
      end
      local merged = { name }
      local global_config = config.default_component_configs[name]
      if global_config then
        for k, v in pairs(global_config) do
          merged[k] = v
        end
      end
      for k, v in pairs(component) do
        merged[k] = v
      end
      if name == "container" then
        for i, child in ipairs(component.content) do
          merged.content[i] = do_merge(child)
        end
      end
      return merged
    else
      log.error("component name is the wrong type", component)
    end
  end

  for _, component in ipairs(components) do
    local merged = do_merge(component)
    table.insert(merged_components, merged)
  end

  -- If the indent component is not specified, then add it.
  -- We do this because it used to be implicitly added, so we don't want to
  -- break any existing configs.
  if not indent_exists then
    local indent = { "indent" }
    for k, v in pairs(config.default_component_configs.indent or {}) do
      indent[k] = v
    end
    table.insert(merged_components, 1, indent)
  end
  return merged_components
end

local merge_renderers = function (default_config, source_default_config, user_config)
  -- This can't be a deep copy/merge. If a renderer is specified in the target it completely
  -- replaces the base renderer.

  if source_default_config == nil then
    -- first override the default config global renderer with the user's global renderers
    for name, renderer in pairs(user_config.renderers or {}) do
      log.debug("overriding global renderer for " .. name)
      default_config.renderers[name] = renderer
    end
  else
    -- then override the global renderers with the source specific renderers
    source_default_config.renderers = source_default_config.renderers or {}
    for name, renderer in pairs(default_config.renderers or {}) do
      if source_default_config.renderers[name] == nil then
        log.debug("overriding source renderer for " .. name)
        local r = {}
        -- Only copy components that exist in the target source.
        -- This alllows us to specify global renderers that include components from all sources,
        -- even if some of those components are not universal
        for _, value in ipairs(renderer) do
          if value[1] and source_default_config.components[value[1]] ~= nil then
            table.insert(r, value)
          end
        end
        source_default_config.renderers[name] = r
      end
    end

    -- if user sets renderers, completely wipe the default ones
    local source_name = source_default_config.name
    for name, _ in pairs(source_default_config.renderers) do
      local user = utils.get_value(user_config, source_name .. ".renderers." .. name)
      if user then
        source_default_config.renderers[name] = nil
      end
    end
  end
end

M.merge_config = function(user_config, is_auto_config)
  local default_config = vim.deepcopy(defaults)
  user_config = vim.deepcopy(user_config or {})

  local migrations = require("neo-tree.setup.deprecations").migrate(user_config)
  if #migrations > 0 then
    -- defer to make sure it is the last message printed
    vim.defer_fn(function()
      vim.cmd(
        "echohl WarningMsg | echo 'Some options have changed, please run `:Neotree migrations` to see the changes' | echohl NONE"
      )
    end, 50)
  end

  if user_config.log_level ~= nil then
    M.set_log_level(user_config.log_level)
  end
  log.use_file(user_config.log_to_file, true)
  log.debug("setup")

  events.clear_all_events()
  define_events()

  -- Prevent accidentally opening another file in the neo-tree window.
  events.subscribe({
    event = events.VIM_BUFFER_ENTER,
    handler = M.buffer_enter_event,
  })

  if user_config.event_handlers ~= nil then
    for _, handler in ipairs(user_config.event_handlers) do
      events.subscribe(handler)
    end
  end

  highlights.setup()

  -- setup the default values for all sources
  normalize_mappings(default_config)
  merge_renderers(default_config, nil, user_config)
  for _, source_name in ipairs(sources) do
    local source_default_config = default_config[source_name]
    local mod_root = "neo-tree.sources." .. source_name
    source_default_config.components = require(mod_root .. ".components")
    source_default_config.commands = require(mod_root .. ".commands")
    source_default_config.name = source_name

    -- Make sure all the mappings are normalized so they will merge properly.
    normalize_mappings(source_default_config)
    normalize_mappings(user_config[source_name])

    local use_default_mappings = default_config.use_default_mappings
    if type(user_config.use_default_mappings) ~= "nil" then
      use_default_mappings = user_config.use_default_mappings
    end
    if use_default_mappings then
      -- merge the global config with the source specific config
      source_default_config.window = vim.tbl_deep_extend(
        "force",
        default_config.window or {},
        source_default_config.window or {},
        user_config.window or {}
      )
    else
      source_default_config.window = user_config.window
    end

    merge_renderers(default_config, source_default_config, user_config)

    --validate the window.position
    local pos_key = source_name .. ".window.position"
    local position = utils.get_value(user_config, pos_key, "left", true)
    local valid_positions = {
      left = true,
      right = true,
      top = true,
      bottom = true,
      float = true,
      current = true,
    }
    if not valid_positions[position] then
      log.error("Invalid value for ", pos_key, ": ", position)
      user_config[source_name].window.position = "left"
    end
  end
  --print(vim.inspect(default_config.filesystem))

  -- apply the users config
  M.config = vim.tbl_deep_extend("force", default_config, user_config)
  if not M.config.enable_git_status then
    M.config.git_status_async = false
  end

  file_nesting.setup(M.config.nesting_rules)

  for _, source_name in ipairs(sources) do
    for name, rndr in pairs(M.config[source_name].renderers) do
      M.config[source_name].renderers[name] = merge_global_components_config(rndr, M.config)
    end
    manager.setup(source_name, M.config[source_name], M.config)
    manager.redraw(source_name)
  end

  events.subscribe({
    event = events.VIM_COLORSCHEME,
    handler = highlights.setup,
    id = "neo-tree-highlight",
  })

  events.subscribe({
    event = events.VIM_WIN_ENTER,
    handler = M.win_enter_event,
    id = "neo-tree-win-enter",
  })

  local rt = utils.get_value(M.config, "resize_timer_interval", 50, true)
  require("neo-tree.ui.renderer").resize_timer_interval = rt

  if not is_auto_config and netrw.get_hijack_netrw_behavior() ~= "disabled" then
    vim.cmd("silent! autocmd! FileExplorer *")
  end

  return M.config
end

return M
