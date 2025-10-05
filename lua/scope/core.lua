local utils = require("scope.utils")
local config = require("scope.config")

local M = {}

M.cache = {}
M.last_tab = 0

function M.on_tab_new_entered()
    vim.api.nvim_buf_set_option(0, "buflisted", true)
end

function M.on_tab_enter()
    if config.hooks.pre_tab_enter ~= nil then
        config.hooks.pre_tab_enter()
    end
    local tab = vim.api.nvim_get_current_tabpage()
    local buf_nums = M.cache[tab]
    if buf_nums then
        for _, k in pairs(buf_nums) do
            if vim.api.nvim_buf_is_valid(k) then
                vim.api.nvim_buf_set_option(k, "buflisted", true)
            end
        end
    end
    if config.hooks.post_tab_enter ~= nil then
        config.hooks.post_tab_enter()
    end
end

function M.on_tab_leave()
    if config.hooks.pre_tab_leave ~= nil then
        config.hooks.pre_tab_leave()
    end
    local tab = vim.api.nvim_get_current_tabpage()
    local buf_nums = utils.get_valid_buffers()
    M.cache[tab] = buf_nums
    for _, k in pairs(buf_nums) do
        vim.api.nvim_buf_set_option(k, "buflisted", false)
    end
    M.last_tab = tab
    if config.hooks.post_tab_leave ~= nil then
        config.hooks.post_tab_leave()
    end
end

function M.on_tab_closed()
    if config.hooks.pre_tab_close ~= nil then
        config.hooks.pre_tab_close()
    end
    M.cache[M.last_tab] = nil
    if config.hooks.post_tab_close ~= nil then
        config.hooks.post_tab_close()
    end
end

function M.revalidate()
    local tab = vim.api.nvim_get_current_tabpage()
    local buf_nums = utils.get_valid_buffers()
    M.cache[tab] = buf_nums
end

function M.print_summary()
    print("tab" .. " " .. "buf" .. " " .. "name")
    for tab, buf_item in pairs(M.cache) do
        for _, buf in pairs(buf_item) do
            local name = vim.api.nvim_buf_get_name(buf)
            print(tab .. " " .. buf .. " " .. name)
        end
    end
end

-- Smart closing of a scoped buffer, this makes sure you only delete a buffer if is not currently open in any other tab.
-- If it is, then we just unlist the buffer.
-- Also if it is the only buffer in the current tab, we close the tab
-- If is not only the only buffer but also the last tab, we ask for permision to close it all
---@param opts table, if buf is not passed we are considering the current buffer
---@param opts.buf integer, if buf is not passed we are considering the current buffer
---@param opts.force boolean, default to true to force close
---@param opts.ask boolean, default to true to ask before closing the last tab ---@diagnostic disable-line
---@return nil
M.close_buffer = function(opts)
    opts = opts or {}
    local current_tab = vim.api.nvim_get_current_tabpage()
    local current_buf = opts.buf or vim.api.nvim_get_current_buf()

    -- Ensure the cache is up-to-date
    M.revalidate()

    local buffers_in_current_tab = M.cache[current_tab]

    -- Check if the buffer exists in other tabs (could be a utils function)
    local buffer_exists_in_other_tabs = false
    for tab, buffers in pairs(M.cache) do
        if tab ~= current_tab then
            for _, buffer in ipairs(buffers) do
                if buffer == current_buf then
                    buffer_exists_in_other_tabs = true
                    break
                end
            end
        end
        if buffer_exists_in_other_tabs then
            break
        end
    end

    -- If the buffer exists in other tabs, hide it in the current tab
    if buffer_exists_in_other_tabs then
        if #buffers_in_current_tab > 1 then
            vim.api.nvim_buf_set_option(current_buf, "buflisted", false)
            vim.cmd([[bprev]])
        else
            vim.cmd("tabclose")
        end
    else -- buffer does not exist in other tabs
        local tab_count = #vim.api.nvim_list_tabpages()
        if #buffers_in_current_tab == 1 then
            if tab_count > 1 then
                vim.api.nvim_buf_delete(current_buf, { force = opts.force })
                if tab_count > 1 then
                    vim.cmd("tabclose")
                end
            else
                -- Ask for confirmation before quitting if it's the only tab
                local choice = 1
                if opts.ask then
                    choice = vim.fn.confirm("You're about to close the last tab. Do you want to quit?", "&Yes\n&No")
                end
                if choice == 1 then
                    vim.cmd("qa!")
                end
            end
        else
            vim.cmd([[bprev]])
            vim.api.nvim_buf_delete(current_buf, { force = opts.force })
        end
    end

    -- Update the cache
    M.revalidate()
end

function M.move_current_buf(opts)
    -- ensure current buflisted
    local buflisted = vim.api.nvim_buf_get_option(0, "buflisted")
    if not buflisted then
        return
    end

    local current_buf = vim.api.nvim_get_current_buf()
    local existing_tabs = vim.api.nvim_list_tabpages()
    local target_handle = nil

    if #existing_tabs <= 1 then -- there are no other tabs, create one (ignores the input tab since it can't make sense)
        -- Create a new tab with the current buffer.
        -- When we create a new tab, an empty buffer is always opened there by nvim. This takes care of
        -- getting rid of that empty buffer and open the current one in the new tab instead.

        -- Save ref to the original tab from where we're moving the buf
        local current_tab = vim.api.nvim_get_current_tabpage()

        -- Create the new tab. This changes the "current tab" to the new one
        vim.cmd('tabnew')
        target_handle = vim.api.nvim_get_current_tabpage()
        local new_empty_buf = vim.api.nvim_get_current_buf()

        vim.api.nvim_set_current_buf(current_buf) -- set the current buf of the new tab to the one being moved
        vim.api.nvim_buf_delete(new_empty_buf, { force = true }) -- delete the empty buf
        vim.api.nvim_set_current_tabpage(current_tab) -- bring the focus back to the original tab
    else
        local target = tonumber(opts.args)
        if target == nil then
            -- invalid target tab, get input from user
            local input = vim.fn.input("Move buf to: ")
            if input == "" then -- user cancel
                return
            end

            target = tonumber(input)
        end
        -- bufferline always display  tab number, not the handle. When scope use tab handle to store buffer info. So need to convert
        target_handle = existing_tabs[target]
    end

    if target_handle == nil then
        vim.notify("Invalid target tab", vim.log.levels.ERROR)
        return
    end

    M.move_buf(current_buf, target_handle)
end

function M.move_buf(bufnr, target)
    -- copy current buf to target tab
    local target_bufs = M.cache[target] or {}
    target_bufs[#target_bufs + 1] = bufnr

    -- remove current buf from current tab if it is not the last one in the tab
    local buf_nums = utils.get_valid_buffers()
    if #buf_nums > 1 then
        vim.api.nvim_buf_set_option(bufnr, "buflisted", false)

        -- current buf are not in the current tab anymore, so we switch to the previous tab
        if bufnr == vim.api.nvim_get_current_buf() then
            vim.cmd("bprevious")
        end
    end
end
return M
