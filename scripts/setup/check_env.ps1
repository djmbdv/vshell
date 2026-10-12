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
Write-Host '  - Ultralight SDK download (license acceptance): https://ultralig.ht/download'
Write-Host '  - vscode-web build: sh scripts/build_web.sh'
