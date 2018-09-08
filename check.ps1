<#
cd C:\Greg\GitHub\av-gem-build-test
./check.ps1 64
#>

. $PSScriptRoot\shared\appveyor_setup.ps1 $args[0]

if ($in_av) {
  &$7z a shared .\shared
  Push-AppveyorArtifact shared.7z
}

$ruby = '99'
if ($in_av) { Install-Trunk }
Write-Host Check-SetVars
Check-SetVars
$env:path = "$msys2\$mingw\bin;$msys2\usr\bin;$env:path"
# $msys_full = $true
Update-MSYS2
Check-OpenSSL
Write-Host $(openssl version) -ForegroundColor Yellow
