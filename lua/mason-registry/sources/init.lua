---@class RegistrySource
---@field id string
---@field get_package fun(self: RegistrySource, pkg_name: string): Package?
---@field get_all_package_names fun(self: RegistrySource): string[]
---@field get_all_package_specs fun(self: RegistrySource): RegistryPackageSpec[]
---@field get_display_name fun(self: RegistrySource): string
---@field is_installed fun(self: RegistrySource): boolean
---@field install fun(self: RegistrySource): Result
---@field serialize fun(self: RegistrySource): InstallReceiptRegistry

---@alias RegistrySourceType '"github"' | '"lua"' | '"file"'

---@class LazySource
---@field type RegistrySourceType
---@field id string
---@field init fun(id: string): RegistrySource
local LazySource = {}
LazySource.__index = LazySource

---@param id string
function LazySource.GitHub(id)
    local namespace, name = id:match "^(.+)/(.+)$"
    if not namespace or not name then
        error(("Failed to parse repository from GitHub registry: %q"):format(id), 0)
    end
    local name, version = unpack(vim.split(name, "@"))
    local GitHubRegistrySource = require "mason-registry.sources.github"
    return GitHubRegistrySource:new {
        id = id,
        namespace = namespace,
        name = name,
        version = version,
    }
end

---@param id string
function LazySource.Lua(id)
    local LuaRegistrySource = require "mason-registry.sources.lua"
    return LuaRegistrySource:new {
        id = id,
        mod = id,
    }
end

---@param id string
function LazySource.File(id)
    local FileRegistrySource = require "mason-registry.sources.file"
    return FileRegistrySource:new {
        id = id,
        path = id,
    }
end

---@param type RegistrySourceType
---@param id string
---@param init fun(id: string): RegistrySource
function LazySource:new(type, id, init)
    local instance = setmetatable({}, self)
    instance.type = type
    instance.id = id
    instance.init = init
    return instance
end

function LazySource:get()
    if not self.instance then
        self.instance = self.init(self.id)
    end
    return self.instance
end

function LazySource:__tostring()
    return ("LazySource(type=%s, id=%s)"):format(self.type, self.id)
end

---@param str string
local function split_once_left(str, char)
    for i = 1, #str do
        if str:sub(i, i) == char then
            local segment = str:sub(1, i - 1)
            return segment, str:sub(i + 1)
        end
    end
    return str
end

---@param registry_id string
local function parse(registry_id)
    local type, id = split_once_left(registry_id, ":")
    assert(id, ("Malformed registry %q"):format(registry_id))
    if type == "github" then
        return LazySource:new(type, id, LazySource.GitHub)
    elseif type == "lua" then
        return LazySource:new(type, id, LazySource.Lua)
    elseif type == "file" then
        return LazySource:new(type, id, LazySource.File)
    end
    error(("Unknown registry type: %s"):format(type))
end

---@class LazySourceCollection
---@field list LazySource[]
local LazySourceCollection = {}
LazySourceCollection.__index = LazySourceCollection

---@return LazySourceCollection
function LazySourceCollection:new()
    local instance = {}
    setmetatable(instance, self)
    instance.list = {}
    return instance
end

---@param registry string
function LazySourceCollection:append(registry)
    table.insert(self.list, parse(registry))
    return self
end

---@param registry string
function LazySourceCollection:prepend(registry)
    table.insert(self.list, 1, parse(registry))
    return self
end

function LazySourceCollection:is_all_installed()
    for source in self:iterate { include_uninstalled = true } do
        if not source:is_installed() then
            return false
        end
    end
    return true
end

function LazySourceCollection:checksum()
    ---@type string[]
    local registry_ids = vim.tbl_map(
        ---@param source LazySource
        function(source)
            return source.id
        end,
        self.list
    )
    table.sort(registry_ids)
    return vim.fn.sha256(table.concat(registry_ids, ""))
end

---@param opts? { include_uninstalled?: boolean }
function LazySourceCollection:iterate(opts)
    opts = opts or {}

    local idx = 1
    return function()
        while idx <= #self.list do
            local source = self.list[idx]:get()
            idx = idx + 1
            if opts.include_uninstalled or source:is_installed() then
                return source
            end
        end
    end
end

---@param opts? { include_uninstalled?: boolean }
function LazySourceCollection:to_list(opts)
    opts = opts or {}
    local list = {}
    for source in self:iterate(opts) do
        table.insert(list, source)
    end
    return list
end

function LazySourceCollection:__tostring()
    return ("LazySourceCollection(list={%s})"):format(table.concat(vim.tbl_map(tostring, self.list), ", "))
end

return LazySourceCollection
