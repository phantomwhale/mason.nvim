local a = require "mason-core.async"
local log = require "mason-core.log"
local OneShotChannel = require("mason-core.async.control").OneShotChannel
local Result = require "mason-core.result"
local _ = require "mason-core.functional"
local fs = require "mason-core.fs"
local path = require "mason-core.path"

local M = {}

local STATE_FILE = path.concat { vim.fn.stdpath "cache", "mason-registry-update" }

---@param sources LazySourceCollection
---@param time integer
local function update_registry_state(sources, time)
    log.trace("Updating registry state", sources, time)
    local dir = vim.fn.fnamemodify(STATE_FILE, ":h")
    if not fs.sync.dir_exists(dir) then
        fs.sync.mkdirp(dir)
    end
    fs.sync.write_file(STATE_FILE, _.join("\n", { sources:checksum(), tostring(time) }))
end

---@return { checksum: string, timestamp: integer }?
function M.get_registry_state()
    if fs.sync.file_exists(STATE_FILE) then
        local parse_state_file =
            _.compose(_.evolve { timestamp = tonumber }, _.zip_table { "checksum", "timestamp" }, _.split "\n")
        return parse_state_file(fs.sync.read_file(STATE_FILE))
    end
end

---@async
---@param sources LazySourceCollection
---@return Result # Result<RegistrySource[]>
function M.install(sources)
    log.debug("Installing registries.", sources)
    assert(not M.channel, "Cannot install when channel is active.")
    M.channel = OneShotChannel:new()
    local result = Result.try(function(try)
        local updated_sources = {}
        for source in sources:iterate { include_uninstalled = true } do
            log.trace("Installing registry.", source)
            try(source:install():map_err(function(err)
                return ("%s failed to install: %s"):format(source, err)
            end))
            table.insert(updated_sources, source)
        end
        a.scheduler()
        update_registry_state(sources, os.time())
        return updated_sources
    end)
    M.channel:send(result)
    M.channel = nil
    return result
end

return M
