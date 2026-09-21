<# Shared dependency setup for first-use downloads and the standalone installer. #>

function Install-WaCzkawka {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DestinationDirectory)

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $destination = [IO.Path]::GetFullPath($DestinationDirectory)
    $binary = Join-Path $destination 'windows_czkawka_cli.exe'
    $expected = 'eb7c2009d2dd49cf5202acbd65370caece0a3f819b9515e727cedb1ec088ed1a'
    $url = 'https://github.com/qarmin/czkawka/releases/download/12.0.2/windows_czkawka_cli.exe'

    if (Test-Path -LiteralPath $binary -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash -eq $expected) { return $binary }
    }

    [void](New-Item -ItemType Directory -Path $destination -Force)
    $download = Join-Path $destination ([guid]::NewGuid().ToString('N') + '.download')
    $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        Write-Host '  Downloading Czkawka CLI 12.0.2 from GitHub and verifying its SHA-256...' -ForegroundColor DarkGray
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $download -UseBasicParsing -TimeoutSec 180
        if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $expected) {
            throw 'Czkawka release checksum mismatch. The installed executable was not replaced.'
        }
        Move-Item -LiteralPath $download -Destination $binary -Force
        Write-Host ('  Czkawka CLI 12.0.2 is ready: ' + $binary) -ForegroundColor DarkGray
        return $binary
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
        if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force }
    }
}
