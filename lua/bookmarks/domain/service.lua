local Node = require("bookmarks.domain.node")
local Location = require("bookmarks.domain.location")
local Repo = require("bookmarks.domain.repo")
-- TODO: remove this dependency, fire domain events instead
local Sign = require("bookmarks.sign")

local M = {}

-- Working state context
local ctx = {
  -- Keep track of last visited ID within a BookmarkList for list traversal
  last_bm_id = -1,
}

--- Create a new bookmark
---@param bookmark Bookmarks.NewNode # the bookmark
---@param parent_list_id number? # parent list ID, if nil, bookmark will be added to current active list
---@return Bookmarks.Node # Returns the created bookmark
function M.new_bookmark(bookmark, parent_list_id)
  if bookmark.type ~= "bookmark" then
    error("Node is not a bookmark")
  end
  parent_list_id = parent_list_id or Repo.ensure_and_get_active_list().id

  local id = Repo.insert_node(bookmark, parent_list_id)

  return Repo.find_node(id) or error("Failed to create bookmark")
end

--- Create a new bookmark
--- e.g.
--- :lua require("bookmarks.domain.service").mark("mark current line")
---@param name string # the name of the bookmark
---@param location Bookmarks.Location? # location of the bookmark
---@param parent_list_id number? # parent list ID, if nil, bookmark will be added to current active list
---@return Bookmarks.Node # Returns the created bookmark
function M.toggle_mark(name, location, parent_list_id)
  location = location or Location.get_current_location()

  -- if location have already bookmark, and name is empty string, remove it
  local existing_bookmark = Repo.find_bookmark_by_location(location)
  if existing_bookmark then
    if name == "" then
      M.remove_bookmark(existing_bookmark.id)
      return existing_bookmark
    else
      return M.rename_node(existing_bookmark.id, name)
    end
  end

  -- else create a new bookmark
  parent_list_id = parent_list_id or Repo.ensure_and_get_active_list().id
  local bookmark = Node.new_bookmark(name)

  local id = Repo.insert_node(bookmark, parent_list_id)

  return Repo.find_node(id) or error("Failed to create bookmark")
end

--- Remove a bookmark
---@param bookmark_id number # bookmark ID
function M.remove_bookmark(bookmark_id)
  Repo.delete_node(bookmark_id)
end

--- Find an existing bookmark under the cursor
---@param location Bookmarks.Location?
---@return Bookmarks.Node? # Returns the bookmark, or nil if not found
function M.find_bookmark_by_location(location)
  location = location or Location.get_current_location()
  return Repo.find_bookmark_by_location(location)
end

--- Create a new list and set it as active
---@param name string # the name of the list
---@param parent_list_id number? # parent list ID, if nil, list will be added to root list
---@return Bookmarks.Node # Returns the created list
function M.create_list(name, parent_list_id)
  -- If no parent_list_id provided, use root list (id = 0)
  parent_list_id = parent_list_id or 0

  local list = Node.new_list(name)
  local id = Repo.insert_node(list, parent_list_id)

  M.set_active_list(id)
  local created = Repo.find_node(id) or error("Failed to create list")
  Sign.safe_refresh_signs()
  -- return to normal mode
  vim.cmd("stopinsert") -- TODO: remove this line and figure out why it's ends in insert mode

  return created
end

--- rename a bookmark or list
---@param node_id number # bookmark or list ID
---@param new_name string # new name
---@return Bookmarks.Node
function M.rename_node(node_id, new_name)
  local node = Repo.find_node(node_id)
  if not node then
    error("Node not found")
  end

  node.name = new_name
  return Repo.update_node(node)
end

--- goto bookmark's location
---@param bookmark_id number # bookmark ID
---@param opts? {cmd?: "e" | "tabnew" | "split" | "vsplit"}
function M.goto_bookmark(bookmark_id, opts)
  opts = opts or {}

  local node = Repo.find_node(bookmark_id)
  if not node then
    error("Bookmark not found")
  end

  if node.type ~= "bookmark" then
    error("Node is not a bookmark")
  end

  if not node.location then
    error("Bookmark has no location")
  end

  -- Update visited timestamp
  node.visited_at = os.time()
  Repo.update_node(node)

  -- Open the file if it's not the current buffer
  local cmd = opts.cmd or "edit"
  if node.location.path ~= vim.fn.expand("%:p") then
    vim.cmd(cmd .. vim.fn.fnameescape(node.location.path))
  end

  -- Move cursor to the bookmarked position
  vim.api.nvim_win_set_cursor(0, { node.location.line, node.location.col })
  vim.cmd("normal! zz")
  Sign.safe_refresh_signs()
end

local FindDirection = { FORWARD = 0, BACKWARD = 1 }

--- finds the bookmark in a given direction in 'id order' within a BookmarkList
---@param callback fun(bookmark: Bookmarks.Node): nil
---@param bookmark_list
---@param direction
---@param fail_msg
local function find_bookmark_in_id_order(callback, bookmark_list, direction, fail_msg)
  local bookmarks = Node.get_all_bookmarks(bookmark_list)
  local last_bm_id = ctx.last_bm_id

  if #bookmarks == 0 then
    vim.notify("No bookmarks available in this BookmarkList", vim.log.levels.WARN)
    return
  end

  -- sort in ascending id order
  table.sort(bookmarks, function(lhs, rhs)
    return lhs.order < rhs.order
  end)

  -- find last visited bookmark in list
  local bm_idx
  for i, bookmark in ipairs(bookmarks) do
    if bookmark.id == last_bm_id then
      bm_idx = i
      break
    end
  end

  local selected_bm
  if not bm_idx then
    -- if last visited bookmark doesn't exist,
    -- go to first in list
    selected_bm = bookmarks[1]
  else
    -- found last visited bookmark, circular traverse
    if direction == FindDirection.FORWARD then
      selected_bm = bookmarks[(bm_idx + 1 - 1) % #bookmarks + 1]
    elseif direction == FindDirection.BACKWARD then
      selected_bm = bookmarks[(bm_idx - 1 - 1 + #bookmarks) % #bookmarks + 1]
    else
      error("Invalid direction, not a valid call to this function")
    end
  end

  if selected_bm then
    ctx.last_bm_id = selected_bm.id
    callback(selected_bm)
  else
    vim.notify(fail_msg, vim.log.levels.WARN)
  end
end

--- finds the bookmark in a given direction in 'line order' within a BookmarkList
---@param callback fun(bookmark: Bookmarks.Node): nil
---@param bookmark_list
---@param direction
---@param fail_msg
local function find_closest_bookmark_in_line_order(callback, bookmark_list, direction, fail_msg)
  local enable_wraparound = vim.g.bookmarks_config.navigation.next_prev_wraparound_same_file
  local bookmarks = Node.get_all_bookmarks(bookmark_list)
  local filepath = vim.fn.expand("%:p")
  local cur_lnr = vim.api.nvim_win_get_cursor(0)[1]
  local file_bms = {}

  for _, bookmark in ipairs(bookmarks) do
    if filepath == bookmark.location.path then
      table.insert(file_bms, bookmark)
    end
  end

  if #file_bms == 0 then
    vim.notify("No bookmarks available in this file", vim.log.levels.WARN)
    return
  end

  -- sort in ascending line number order
  table.sort(file_bms, function(lhs, rhs)
    return lhs.location.line < rhs.location.line
  end)
  local min_bm = file_bms[1]
  local max_bm = file_bms[#file_bms]

  local selected_bm
  if direction == FindDirection.FORWARD then
    if enable_wraparound and cur_lnr >= max_bm.location.line then
      selected_bm = min_bm
    else
      for _, bookmark in ipairs(file_bms) do
        if bookmark.location.line > cur_lnr then
          selected_bm = bookmark
          break
        end
      end
    end
  elseif direction == FindDirection.BACKWARD then
    if enable_wraparound and cur_lnr <= min_bm.location.line then
      selected_bm = max_bm
    else
      for i = #file_bms, 1, -1 do
        local bookmark = file_bms[i]
        if bookmark.location.line < cur_lnr then
          selected_bm = bookmark
          break
        end
      end
    end
  else
    error("Invalid direction, not a valid call to this function")
  end

  if selected_bm then
    callback(selected_bm)
  else
    vim.notify(fail_msg, vim.log.levels.WARN)
  end
end

--- finds the next bookmark in line number order within the current active BookmarkList
---@param callback fun(bookmark: Bookmarks.Node): nil
function M.find_next_bookmark_line_order(callback)
  find_closest_bookmark_in_line_order(callback, Repo.ensure_and_get_active_list(), FindDirection.FORWARD,
    "No next bookmark found within the active BookmarkList in this file")
end

--- finds the previous bookmark in line number order within the current active BookmarkList
---@param callback fun(bookmark: Bookmarks.Node): nil
function M.find_prev_bookmark_line_order(callback)
  find_closest_bookmark_in_line_order(callback, Repo.ensure_and_get_active_list(), FindDirection.BACKWARD,
    "No previous bookmark found within the active BookmarkList in this file")
end

--- finds the next bookmark in id order within the current active BookmarkList
---@param callback fun(bookmark: Bookmarks.Node): nil
function M.find_next_bookmark_id_order(callback)
  find_bookmark_in_id_order(callback, Repo.ensure_and_get_active_list(), FindDirection.FORWARD,
    "No next bookmark found within the active BookmarkList")
end

--- finds the previous bookmark in id order within the current active BookmarkList
---@param callback fun(bookmark: Bookmarks.Node): nil
function M.find_prev_bookmark_id_order(callback)
  find_bookmark_in_id_order(callback, Repo.ensure_and_get_active_list(), FindDirection.BACKWARD,
    "No previous bookmark found within the active BookmarkList")
end

--- get all bookmarks of the active list
---@return Bookmarks.Node[]
function M.get_all_bookmarks_of_active_list()
  local active_list = Repo.ensure_and_get_active_list()
  return Node.get_all_bookmarks(active_list)
end

--- find a bookmark or list by ID
---@param node_id number # bookmark or list ID
---@return Bookmarks.Node? # Returns the bookmark or list, or nil if not found
function M.find_node(node_id) end

--- add a bookmark or list to a list
---@param node_id number
---@param parent_list_id number
function M.add_to_list(node_id, parent_list_id) end

--- copy a bookmark to a list
---@param bookmark_id number # bookmark ID
---@param list_id number # list ID
function M.copy_bookmark_to_list(bookmark_id, list_id) end

--- move a bookmark to a list
---@param bookmark_id number # bookmark ID
---@param list_id number # list ID
function M.move_bookmark_to_list(bookmark_id, list_id) end

--- delete a bookmark or list
---@param id number # bookmark or list ID
function M.delete_node(id)
  -- Check if node exists
  local node = Repo.find_node(id)
  if not node then
    error("Node not found")
  end

  -- Don't allow deleting root node
  if id == 0 then
    error("Cannot delete root node")
  end

  -- Delete the node and all its relationships
  Repo.delete_node(id)
end

--- Remove the node from its current list
--- @param node_id number # node ID
--- @param parent_id number # Parent node id
function M.remove_from_list(node_id, parent_id)
  Repo.remove_from_list(node_id, parent_id)
end

--- Export list as text to a buffer. useful when you want to provide context to AI
--- @param list_id number # list ID
function M.export_list_to_buffer(list_id) end

--- Set the active list
--- @param list_id number # list ID
function M.set_active_list(list_id)
  Repo.set_active_list(list_id)
  ctx.last_bm_id = -1
end

--- Switch position of two bookmarks in the same list
--- @param b1 Bookmarks.Node
--- @param b2 Bookmarks.Node
function M.switch_position(b1, b2)
  -- Get parent IDs for both nodes
  local parent_id1 = Repo.get_parent_id(b1.id)
  local parent_id2 = Repo.get_parent_id(b2.id)

  -- Check if nodes are in the same list
  if parent_id1 ~= parent_id2 then
    error("Cannot switch positions of nodes from different lists")
  end

  -- Switch their order values
  local temp_order = b1.order
  b1.order = b2.order
  b2.order = temp_order

  -- Update both nodes in the repository
  Repo.update_node(b1)
  Repo.update_node(b2)
end

---Paste a node at a specific position
---@param node Bookmarks.Node The node to paste
---@param parent_id number The parent list ID
---@param position number The position to paste at
---@param operation "cut"|"copy" The operation to perform
---@return Bookmarks.Node # Returns the pasted node
function M.paste_node(node, parent_id, position, operation)
  if node.type == "list" and parent_id == node.id then
    error("Cannot paste a list into itself")
  end

  if operation == "cut" then
    -- Update orders of existing nodes in target list
    local children = Repo.find_node(parent_id).children
    for _, child in ipairs(children) do
      if child.order >= position then
        child.order = child.order + 1
        Repo.update_node(child)
      end
    end

    -- Add relationship to new parent
    Repo.add_to_list(node.id, parent_id)

    -- Update node's order
    node.order = position
    return Repo.update_node(node)
  end

  -- Convert node to newNode format
  local newNode = {
    type = node.type,
    name = node.name,
    description = node.description,
    content = node.content,
    githash = node.githash,
    created_at = os.time(), -- New timestamp for the copy
    visited_at = os.time(),
    is_expanded = node.is_expanded,
    order = node.order,
  }

  -- Copy location if it exists
  if node.location then
    newNode.location = {
      path = node.location.path,
      line = node.location.line,
      col = node.location.col,
    }
  end

  local id = Repo.insert_node_at_position(newNode, parent_id, position)
  return Repo.find_node(id) or error("Failed to paste node")
end

return M
