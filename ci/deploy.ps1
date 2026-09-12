# Deploy Windows (dev) -> Arch (prod 192.168.31.11:22022).
# 1) z.cmd build test   2) tar sources (no .env/cache)
# 3) scp to Arch        4) remote-apply.sh: compose up --build -d
param(
    [switch]$SkipTest,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

# Target from netaccess/.credentials (fallback: defaults)
$Cred = 'C:\Users\admin\Work\netaccess\.credentials'
$Ip = '192.168.31.11'; $User = 'user'; $Port = '22022'
if (Test-Path $Cred) {
    foreach ($line in Get-Content $Cred) {
        if ($line -match '^HOST_ARCH_IP=(.+)$') { $Ip = $Matches[1] }
        if ($line -match '^HOST_ARCH_USER=(.+)$') { $User = $Matches[1] }
        if ($line -match '^HOST_ARCH_SSH_PORT=(.+)$') { $Port = $Matches[1] }
    }
}
$Key = "$env:USERPROFILE\.ssh\id_ed25519_arch"
$SshOpts = @('-i', $Key, '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=8', '-o', 'IdentitiesOnly=yes')
Write-Host "target: $User@$Ip`:$Port" -ForegroundColor Cyan

if ($Status) {
    & ssh.exe @SshOpts -p $Port "$User@$Ip" 'bash ~/Work/moonobsrv/ci/remote-status.sh'
    exit $LASTEXITCODE
}

if (-not $SkipTest) {
    Write-Host '=== zig build test ===' -ForegroundColor Cyan
    Push-Location $Root
    try {
        & (Join-Path $Root 'z.cmd') build test
        if ($LASTEXITCODE -ne 0) { throw "tests failed ($LASTEXITCODE)" }
    } finally { Pop-Location }
    Write-Host 'OK' -ForegroundColor Green
}

Write-Host '=== zig build (linux musl static) ===' -ForegroundColor Cyan
Push-Location $Root
try {
    & (Join-Path $Root 'z.cmd') build -Drelease -Dtarget=x86_64-linux-musl
    if ($LASTEXITCODE -ne 0) { throw "linux build failed ($LASTEXITCODE)" }
} finally { Pop-Location }
$Dist = Join-Path $Root 'dist'
New-Item -ItemType Directory -Force -Path $Dist | Out-Null
Copy-Item -Force (Join-Path $Root 'zig-out\bin\moonobsrv') (Join-Path $Dist 'moonobsrv')
Write-Host "binary: $((Get-Item (Join-Path $Dist 'moonobsrv')).Length) bytes" -ForegroundColor Green

$Tgz = Join-Path $env:TEMP 'moonobsrv-src.tgz'
$Pack = @('src', 'build.zig', 'z.cmd', '.gitignore', 'docs', 'dist', 'Dockerfile', '.dockerignore', 'docker-compose.yml', 'docker-compose.prod.yml', 'ci', 'scripts', 'README.md', '.env.example', 'deploy.cmd')
$Missing = $Pack | Where-Object { -not (Test-Path (Join-Path $Root $_)) -and $_ -ne '.env.example' }
if ($Missing) { throw "missing in tree: $($Missing -join ', ')" }
Write-Host "=== pack $Tgz ===" -ForegroundColor Cyan
& tar.exe -C $Root -czf $Tgz -- @Pack
if ($LASTEXITCODE -ne 0) { throw 'tar failed' }

Write-Host '=== push -> Arch ===' -ForegroundColor Cyan
& scp.exe @SshOpts -P $Port $Tgz "${User}@${Ip}:/tmp/moonobsrv-src.tgz"
if ($LASTEXITCODE -ne 0) { throw 'scp failed' }
# plain single-quoted string: no $()/&& inside double quotes for PS5.
# tar-неудача обязана рвать цепочку — иначе выкатится СТАРЫЙ код с exit 0.
$remote = 'mkdir -p ~/Work/moonobsrv && cd ~/Work/moonobsrv && tar -xzf /tmp/moonobsrv-src.tgz && (chmod +x ci/*.sh scripts/*.sh 2>/dev/null || true) && rm -f /tmp/moonobsrv-src.tgz && bash ci/remote-apply.sh'
& ssh.exe @SshOpts -p $Port "$User@$Ip" $remote
if ($LASTEXITCODE -ne 0) { throw 'remote-apply failed' }
Write-Host 'prod updated' -ForegroundColor Green
