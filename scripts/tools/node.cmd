@echo off
rem vshell: `node` for build tools only, forwarded to Bun.
rem
rem Some third-party binding.gyp files shell out to `node -p "require(...)"` to read
rem include paths at configure time (spdlog, node-pty and node-addon-api all do). That
rem is the last place the build touched Node, and it does not have to: Bun implements
rem --print/-p and -e, so a two-line shim keeps the whole toolchain on one interpreter.
rem
rem This is a BUILD-time alias. Nothing at runtime resolves `node`: the addons are
rem N-API (ABI stable, loaded by Bun) and both the renderer and the server are JSC.
bun %*
