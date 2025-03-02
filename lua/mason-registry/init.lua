local EventEmitter = require "mason-core.EventEmitter"
local InstallLocation = require "mason-core.installer.InstallLocation"
local log = require "mason-core.log"
local uv = vim.loop
local LazySourceCollection = require "mason-registry.sources"

-- singleton
local Registry = EventEmitter:new()

Registry.sources = LazySourceCollection:new()
---@type table<string, string[]>
Registry.aliases = {}

---@param pkg_name string
function Registry.is_installed(pkg_name)
    local ok, stat = pcall(uv.fs_stat, InstallLocation.global():package(pkg_name), "r", 438)
    return ok and stat.type == "directory"
end

---Returns an instance of the Package class if the provided package name exists. This function errors if a package
---cannot be found.
---@param pkg_name string
---@return Package
function Registry.get_package(pkg_name)
    for source in Registry.sources:iterate() do
        local pkg = source:get_package(pkg_name)
        if pkg then
            return pkg
        end
    end
    log.fmt_error("Cannot find package %q.", pkg_name)
    error(("Cannot find package %q."):format(pkg_name))
end

function Registry.has_package(pkg_name)
    local ok = pcall(Registry.get_package, pkg_name)
    return ok
end

function Registry.get_installed_package_names()
    local fs = require "mason-core.fs"
    if not fs.sync.dir_exists(InstallLocation.global():package()) then
        return {}
    end
    local entries = fs.sync.readdir(InstallLocation:global():package())
    local directories = {}
    for _, entry in ipairs(entries) do
        if entry.type == "directory" then
            directories[#directories + 1] = entry.name
        end
    end
    -- TODO: validate that entry is a mason package
    return directories
end

function Registry.get_installed_packages()
    return vim.tbl_map(Registry.get_package, Registry.get_installed_package_names())
end

function Registry.get_all_package_names()
    local pkgs = {}
    for source in Registry.sources:iterate() do
        for _, name in ipairs(source:get_all_package_names()) do
            pkgs[name] = true
        end
    end
    return vim.tbl_keys(pkgs)
end

function Registry.get_all_packages()
    return vim.tbl_map(Registry.get_package, Registry.get_all_package_names())
end

function Registry.get_all_package_specs()
    local specs = {}
    for source in Registry.sources:iterate() do
        for _, spec in ipairs(source:get_all_package_specs()) do
            if not specs[spec.name] then
                specs[spec.name] = spec
            end
        end
    end
    return vim.tbl_values(specs)
end

---Register aliases for the specified packages
---@param new_aliases table<string, string[]>
function Registry.register_package_aliases(new_aliases)
    for pkg_name, pkg_aliases in pairs(new_aliases) do
        Registry.aliases[pkg_name] = Registry.aliases[pkg_name] or {}
        for _, alias in pairs(pkg_aliases) do
            if alias ~= pkg_name then
                table.insert(Registry.aliases[pkg_name], alias)
            end
        end
    end
end

---@param name string
function Registry.get_package_aliases(name)
    return Registry.aliases[name] or {}
end

---@param callback? fun(success: boolean, updated_registries: RegistrySource[])
function Registry.update(callback)
    log.debug "Updating the registry."
    local a = require "mason-core.async"
    local installer = require "mason-registry.installer"
    local noop = function() end

    a.run(function()
        if installer.channel then
            log.trace "Registry update already in progress."
            return installer.channel:receive():get_or_throw()
        else
            return installer
                .install(Registry.sources)
                :on_success(function(updated_registries)
                    Registry:emit("update", updated_registries)
                end)
                :get_or_throw()
        end
    end, callback or noop)
end

local REGISTRY_STORE_TTL = 86400 -- 24 hrs

---@param callback? fun(success: boolean, updated_registries: RegistrySource[])
function Registry.refresh(callback)
    log.debug "Refreshing the registry."
    local a = require "mason-core.async"
    local installer = require "mason-registry.installer"

    local state = installer.get_registry_state()
    local is_state_ok = state
        and (os.time() - state.timestamp) <= REGISTRY_STORE_TTL
        and state.checksum == Registry.sources:checksum()

    if is_state_ok and Registry.sources:is_all_installed() then
        log.debug "Registry refresh not necessary."
        if callback then
            callback(true, {})
        end
        return
    end

    if not callback then
        return a.run_blocking(function()
            return a.wait(Registry.update)
        end)
    else
        a.run(function()
            return a.wait(Registry.update)
        end, callback)
    end
end

return Registry
