param(
    [ValidateSet('Start', 'Stop', 'Status')]
    [string] $Action = 'Start'
)

$ErrorActionPreference = 'Stop'
$distribution = 'Ubuntu-24.04'
$service = Join-Path $PSScriptRoot 'run-wsl.sh'
$servicePath = & wsl.exe --distribution $distribution --exec wslpath -a -u $service
if ($LASTEXITCODE -ne 0) {
    throw "Unable to locate the service script in WSL $distribution."
}
$servicePath = ($servicePath -join '').Trim()

if ($Action -ne 'Start') {
    & wsl.exe --distribution $distribution --exec bash $servicePath ($Action.ToLowerInvariant())
    exit $LASTEXITCODE
}

& wsl.exe --distribution $distribution --exec bash $servicePath probe
if ($LASTEXITCODE -eq 0) {
    Write-Output 'eLabFTW is ready at https://127.0.0.1:8080'
    exit 0
}

$launcher = $null
if ($LASTEXITCODE -eq 1) {
    # Keep a Windows WSL client attached while the two Linux services run.
    $launcher = Start-Process -FilePath 'wsl.exe' -ArgumentList @(
        '--distribution', $distribution, '--exec', 'bash', ('"{0}"' -f $servicePath), 'run'
    ) -WindowStyle Hidden -PassThru
}

$deadline = [DateTime]::UtcNow.AddSeconds(150)
do {
    & wsl.exe --distribution $distribution --exec bash $servicePath probe
    if ($LASTEXITCODE -eq 0) {
        Write-Output 'eLabFTW is ready at https://127.0.0.1:8080'
        exit 0
    }
    if ($launcher -and $launcher.HasExited) {
        break
    }
    Start-Sleep -Seconds 2
} while ([DateTime]::UtcNow -lt $deadline)

throw 'eLabFTW did not become ready. Check the service, web, and MySQL logs in the WSL runtime directory.'
