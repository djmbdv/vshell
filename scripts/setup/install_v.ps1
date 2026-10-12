# Installs the V programming language (vlang) on Windows.
#
#   powershell -ExecutionPolicy Bypass -File scripts/setup/install_v.ps1
#
# Follows the official documented method (Installing V from source):
#   git clone --depth=1 https://github.com/vlang/v
#   cd v && makev.bat
#   v symlink
#
# Clones to %USERPROFILE%\v and adds %USERPROFILE%\v\.bin to PATH.

$ErrorActionPreference = 'Stop'

$root = Join-Path $env:USERPROFILE 'v'

if (-not (Test-Path (Join-Path $root '.git'))) {
    if (Test-Path $root) { Remove-Item -Recurse -Force $root }
    Write-Host "Cloning V into $root ..."
    git clone --depth=1 https://github.com/vlang/v $root
}
else {
    Write-Host "V repo already present at $root"
}

Write-Host "Building V (makev.bat) ..."
cmd /c "cd /d `"$root`" && makev.bat"

$exe = Join-Path $root 'v.exe'
if (-not (Test-Path $exe)) {
    throw "V executable not found at $exe after extraction"
}

Write-Host ""
& $exe version
Write-Host "Adding V to PATH (v symlink) ..."
& $exe symlink
Write-Host ""
Write-Host "V installed at: $root"
Write-Host "Restart the shell so the new PATH is loaded, then run: v version"
Write-Host ""
Write-Host "Then build the shell, e.g.:"
Write-Host '    v -cc gcc -cflags "-I<ultralight-sdk>\include" -ldflags "-L<ultralight-sdk>\lib -lUltralight -lUltralightCore -lWebCore -lAppCore" -o vshell .'
