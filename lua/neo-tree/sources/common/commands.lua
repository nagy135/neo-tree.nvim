--This file should contain all commands meant to be used by mappings.

local vim = vim
local fs_actions = require("neo-tree.sources.filesystem.lib.fs_actions")
local utils = require("neo-tree.utils")
local renderer = require("neo-tree.ui.renderer")
local log = require("neo-tree.log")

---Gets the node parent folder recursively
---@param tree table to look for nodes
---@param node table to look for folder parent
---@return table table
local function get_folder_node(tree, node)
  if not node then
    node = tree:get_node()
  end
  if node.type == "directory" then
    return node
  end
  return get_folder_node(tree, tree:get_node(node:get_parent_id()))
end

local M = {}

---Adds all missing common commands to the given module
---@param to_source_command_module table The commands modeul for a source
M._add_common_commands = function(to_source_command_module)
  for name, func in pairs(M) do
    if type(name) == "string" and not name:match("^_") then
      if not to_source_command_module[name] then
        to_source_command_module[name] = func
      end
    end
  end
end

---Add a new file or dir at the current node
---@param state table The state of the source
---@param callback function The callback to call when the command is done. Called with the parent node as the argument.
M.add = function(state, callback)
  local tree = state.tree
  local node = get_folder_node(tree)

  fs_actions.create_node(node:get_id(), callback)
end

---Add a new file or dir at the current node
---@param state table The state of the source
---@param callback function The callback to call when the command is done. Called with the parent node as the argument.
M.add_directory = function(state, callback)
  local tree = state.tree
  local node = get_folder_node(tree)

  fs_actions.create_directory(node:get_id(), callback)
end

M.close_all_nodes = function(state)
  renderer.collapse_all_nodes(state.tree)
  renderer.redraw(state)
end

M.close_node = function(state, callback)
  local tree = state.tree
  local node = tree:get_node()
  local parent_node = tree:get_node(node:get_parent_id())
  local target_node

  if node:has_children() and node:is_expanded() then
    target_node = node
  else
    target_node = parent_node
  end

  if target_node and target_node:has_children() then
    target_node:collapse()
    renderer.redraw(state)
    renderer.focus_node(state, target_node:get_id())
  end
end

M.close_window = function(state)
  renderer.close(state)
end

---Marks node as copied, so that it can be pasted somewhere else.
M.copy_to_clipboard = function(state, callback)
  local node = state.tree:get_node()
  state.clipboard = state.clipboard or {}
  local existing = state.clipboard[node.id]
  if existing and existing.action == "copy" then
    state.clipboard[node.id] = nil
  else
    state.clipboard[node.id] = { action = "copy", node = node }
    log.info("Copied " .. node.name .. " to clipboard")
  end
  if callback then
    callback()
  end
end

---Marks node as cut, so that it can be pasted (moved) somewhere else.
M.cut_to_clipboard = function(state, callback)
  local node = state.tree:get_node()
  state.clipboard = state.clipboard or {}
  local existing = state.clipboard[node.id]
  if existing and existing.action == "cut" then
    state.clipboard[node.id] = nil
  else
    state.clipboard[node.id] = { action = "cut", node = node }
    log.info("Cut " .. node.name .. " to clipboard")
  end
  if callback then
    callback()
  end
end

M.show_debug_info = function(state)
  print(vim.inspect(state))
end

---Pastes all items from the clipboard to the current directory.
---@param state table The state of the source
---@param callback function The callback to call when the command is done. Called with the parent node as the argument.
M.paste_from_clipboard = function(state, callback)
  if state.clipboard then
    local folder = get_folder_node(state.tree):get_id()
    -- Convert to list so to make it easier to pop items from the stack.
    local clipboard_list = {}
    for _, item in pairs(state.clipboard) do
      table.insert(clipboard_list, item)
    end
    state.clipboard = nil
    local handle_next_paste, paste_complete

    paste_complete = function(source, destination)
      if callback then
        -- open the folder so the user can see the new files
        local node = state.tree:get_node(folder)
        if not node then
          log.warn("Could not find node for " .. folder)
        end
        callback(node, destination)
      end
      local next_item = table.remove(clipboard_list)
      if next_item then
        handle_next_paste(next_item)
      end
    end

    handle_next_paste = function(item)
      if item.action == "copy" then
        fs_actions.copy_node(
          item.node.path,
          folder .. utils.path_separator .. item.node.name,
          paste_complete
        )
      elseif item.action == "cut" then
        fs_actions.move_node(
          item.node.path,
          folder .. utils.path_separator .. item.node.name,
          paste_complete
        )
      end
    end

    local next_item = table.remove(clipboard_list)
    if next_item then
      handle_next_paste(next_item)
    end
  end
end

---Copies a node to a new location, using typed input.
---@param state table The state of the source
---@param callback function The callback to call when the command is done. Called with the parent node as the argument.
M.copy = function(state, callback)
  local node = state.tree:get_node()
  fs_actions.copy_node(node.path, nil, callback)
end

---Moves a node to a new location, using typed input.
---@param state table The state of the source
---@param callback function The callback to call when the command is done. Called with the parent node as the argument.
M.move = function(state, callback)
  local node = state.tree:get_node()
  fs_actions.move_node(node.path, nil, callback)
end

M.delete = function(state, callback)
  local tree = state.tree
  local node = tree:get_node()

  fs_actions.delete_node(node.path, callback)
end

---Open file or directory
---@param state table The state of the source
---@param open_cmd string The vim command to use to open the file
---@param toggle_directory function The function to call to toggle a directory
---open/closed
local open_with_cmd = function(state, open_cmd, toggle_directory)
  local tree = state.tree
  local success, node = pcall(tree.get_node, tree)
  if not (success and node) then
    log.debug("Could not get node.")
    return
  end

  local function open()
    local path = node:get_id()
    utils.open_file(state, path, open_cmd)
  end

  if utils.is_expandable(node) then
    if toggle_directory and node.type == "directory" then
      toggle_directory(node)
    elseif node:has_children() then
      if node:is_expanded() and node.type == "file" then
        return open()
      end

      local updated = false
      if node:is_expanded() then
        updated = node:collapse()
      else
        updated = node:expand()
      end
      if updated then
        renderer.redraw(state)
      end
    end
  else
    open()
  end
end

---Open file or directory in the closest window
---@param state table The state of the source
---@param toggle_directory function The function to call to toggle a directory
---open/closed
M.open = function(state, toggle_directory)
  open_with_cmd(state, "e", toggle_directory)
end

---Open file or directory in a split of the closest window
---@param state table The state of the source
---@param toggle_directory function The function to call to toggle a directory
---open/closed
M.open_split = function(state, toggle_directory)
  open_with_cmd(state, "split", toggle_directory)
end

---Open file or directory in a vertical split of the closest window
---@param state table The state of the source
---@param toggle_directory function The function to call to toggle a directory
---open/closed
M.open_vsplit = function(state, toggle_directory)
  open_with_cmd(state, "vsplit", toggle_directory)
end

---Open file or directory in a new tab
---@param state table The state of the source
---@param toggle_directory function The function to call to toggle a directory
---open/closed
M.open_tabnew = function(state, toggle_directory)
  open_with_cmd(state, "tabnew", toggle_directory)
end

M.rename = function(state, callback)
  local tree = state.tree
  local node = tree:get_node()
  fs_actions.rename_node(node.path, callback)
end

---Expands or collapses the current node.
M.toggle_node = function(state, toggle_directory)
  local tree = state.tree
  local node = tree:get_node()
  if not utils.is_expandable(node) then
    return
  end
  if node.type == "directory" and toggle_directory then
    toggle_directory(node)
  elseif node:has_children() then
    local updated = false
    if node:is_expanded() then
      updated = node:collapse()
    else
      updated = node:expand()
    end
    if updated then
      renderer.redraw(state)
    end
  end
end

---Expands or collapses the current node.
M.toggle_directory = function(state, toggle_directory)
  local tree = state.tree
  local node = tree:get_node()
  if node.type ~= "directory" then
    return
  end
  M.toggle_node(state, toggle_directory)
end

---Marks potential windows with letters and will open the give node in the picked window.
M.open_with_window_picker = function(state)
  local node = state.tree:get_node()
  local path = node:get_id()
  local success, picker = pcall(require, "window-picker")
  if not success then
    print(
      "You'll need to install window-picker to use this command: https://github.com/s1n7ax/nvim-window-picker"
    )
    return
  end
  local picked_window_id = picker.pick_window()
  if picked_window_id then
    vim.api.nvim_set_current_win(picked_window_id)
    vim.cmd("edit " .. vim.fn.fnameescape(node.path))
  end
end

return M
