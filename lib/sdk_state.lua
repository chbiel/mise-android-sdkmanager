local M = {}

function M.write(install_path, package, version, revision, sdk_root, cmdline_tools)
    local contents = require("json").encode({
        schema_version = 1,
        package_id = package.id,
        resolved_version = version,
        installed_revision = revision,
        sdk_root = sdk_root,
        cmdline_tools = cmdline_tools,
    })
    require("cmd").exec(
        "set -eu\nmkdir -p "
            .. shell_quote(install_path)
            .. "\ncd "
            .. shell_quote(install_path)
            .. "\ntmp=$(mktemp .mise-sdk-package.XXXXXXXX)\n"
            .. "trap 'rm -f \"$tmp\"' 0\ntrap 'exit 130' INT\ntrap 'exit 143' TERM HUP\n"
            .. "printf '%s\\n' "
            .. shell_quote(contents)
            .. ' > "$tmp"\nmv -f "$tmp" .mise-sdk-package.json\n'
    )
end

return M
