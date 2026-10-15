# Reports the toolchain status for building vshell on Windows.
#
#   powershell -ExecutionPolicy Bypass -File scripts/setup/check_env.ps1

$tools = @('git', 'node', 'npm', 'bun', 'v', 'gcc', 'g++', 'cmake', 'clang')

foreach ($t in $tools) {
    $cmd = Get-Command $t -ErrorAction SilentlyContinue
    if ($cmd) {
        $ver = ''
        try { $ver = (& $t --version 2>$null | Select-Object -First 1) } catch { $ver = '' }
        '{0,-8} OK       {1}' -f $t, $ver
    }
    else {
        '{0,-8} MISSING' -f $t
    }
}

Write-Host ''
Write-Host 'Manual steps that cannot be automated:'
Write-Host '  - WebKit (WinCairo) engine, built once outside this repo:'
Write-Host '      perl Tools/Scripts/build-webkit --release     (in a WebKit/WebKit checkout)'
Write-Host '      WK_SRC=... WK_BUILD=... sh scripts/stage_runtime.sh'
Write-Host '    build_vshell.sh runs that staging for you the first time.'
Write-Host '  - (legacy backend only) Ultralight SDK: https://ultralig.ht/download'
Write-Host '  - vscode-web build: sh scripts/build_web.sh'
