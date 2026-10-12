# Installs the MSYS2 mingw-w64 (ucrt64) toolchain on Windows WITHOUT admin:
#   1. downloads the official MSYS2 base archive (portable, no installer/UAC)
#   2. pacman -Syu ... (base upgrade)
#   3. installs mingw-w64-ucrt-x86_64-gcc (gcc/g++), make, pkgconf
#   4. adds <msys64>\ucrt64\bin and <msys64>\usr\bin to the *user* PATH
#
#   powershell -ExecutionPolicy Bypass -File scripts/setup/install_toolchain.ps1
#
# Versions: MSYS2 base 20260611, mingw-w64 gcc 16.2.0 (ucrt64, 64-bit).

$ErrorActionPreference = 'Stop'

$msysVersion = '20260611'
$msysRelease = '2026-06-11'
$parent = $env:USERPROFILE
$dest = Join-Path $parent 'msys64'
$bash = Join-Path $dest 'usr\bin\bash.exe'

if (-not (Test-Path $bash)) {
    $tz = Join-Path $env:TEMP "msys2-base-x86_64-$msysVersion.tar.xz"
    $url = "https://github.com/msys2/msys2-installer/releases/download/$msysRelease/msys2-base-x86_64-$msysVersion.tar.xz"
    Write-Host "Downloading $url"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tz
    Write-Host ("Downloaded: {0:N1} MB" -f ((Get-Item $tz).Length / 1MB))
    Write-Host "Extracting to $parent ..."
    tar -xf $tz -C $parent
    if (-not (Test-Path $bash)) { throw "extraction failed: $bash not found" }
}
else {
    Write-Host "MSYS2 base already present at $dest"
}

Write-Host "Updating MSYS2 (pacman -Syu) ..."
& $bash -lc 'pacman -Syu --noconfirm'

Write-Host "Installing mingw-w64 ucrt64 toolchain ..."
& $bash -lc 'pacman -S --noconfirm --needed mingw-w64-ucrt-x86_64-gcc make pkgconf'

# --- add to the user PATH ---
$dirs = @((Join-Path $dest 'ucrt64\bin'), (Join-Path $dest 'usr\bin'))
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($null -eq $userPath) { $userPath = '' }
$parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' })
foreach ($d in $dirs) {
    if ($parts -notcontains $d) { $parts += $d; Write-Host "added to user PATH: $d" }
}
[Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')

Write-Host ''
Write-Host 'Done. Restart the shell, then verify with:'
Write-Host '    gcc --version'
Write-Host '    v doctor        # the gcc version line should be filled in'
Write-Host ''
Write-Host 'Build the shell:'
Write-Host '    v -cc gcc -o vshell.exe .'
