# Reports the toolchain status for building vshell on Windows.
#
#   powershell -ExecutionPolicy Bypass -File scripts/setup/check_env.ps1
#
# Node and npm are deliberately NOT on this list: Bun is the only JavaScript
# interpreter this project uses, at build time as well as at runtime. Where a
# third-party binding.gyp shells out to `node`, scripts/tools/node (a two-line Bun
# shim) answers instead — see the note in that file.

$required = @('git', 'bun', 'v', 'gcc', 'g++')
$optional = @('cmake', 'clang')

foreach ($t in $required + $optional) {
    $cmd = Get-Command $t -ErrorAction SilentlyContinue
    $label = if ($required -contains $t) { 'required' } else { 'optional' }
    if ($cmd) {
        $ver = ''
        try { $ver = (& $t --version 2>$null | Select-Object -First 1) } catch { $ver = '' }
        '{0,-8} {1,-9} OK       {2}' -f $t, $label, $ver
    }
    else {
        '{0,-8} {1,-9} MISSING' -f $t, $label
    }
}

# Informational only: a system Node must not be needed, and the build removes it
# from PATH anyway (scripts/build_reh.sh).
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    Write-Host ''
    Write-Host "note: a system node was found ($($node.Source)) but it is not used; Bun stands in for it."
}

Write-Host ''
Write-Host 'Manual steps that cannot be automated:'
Write-Host '  - WebKit (WinCairo) engine, built once outside this repo:'
Write-Host '      perl Tools/Scripts/build-webkit --release     (in a WebKit/WebKit checkout)'
Write-Host '      WK_SRC=... WK_BUILD=... sh scripts/stage_runtime.sh'
Write-Host '    build_vshell.sh runs that staging for you the first time.'
Write-Host '  - (legacy backend only) Ultralight SDK: https://ultralig.ht/download'
Write-Host '  - vscode-web build: sh scripts/build_web.sh'
