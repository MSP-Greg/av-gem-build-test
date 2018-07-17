<#
cd C:\Greg\GitHub\av-gem-build-test
./check.ps1 64
#>

. $PSScriptRoot\shared\appveyor_setup.ps1 $args[0]

if ($in_av) {
  &$7z a shared .\shared
  Push-AppveyorArtifact shared.7z
}

$env:path = "$msys2\$mingw\bin;$msys2\usr\bin;" + $env:path

Update-MSYS2

$key = 'D688DA4A77D8FA18'

Write-Host Adding GPG key $key to keyring -ForegroundColor $fc
$t1 = "`"pacman-key -r $key --keyserver $ks1`""

# below is for occasional key retrieve failure on Appveyor
if (!(Retry bash.exe -lc $t1)) {
  Write-Host GPG Key Lookup failed from $ks1 -ForegroundColor $fc
  # try another keyserver
  $t1 = "`"pacman-key -r $key --keyserver`""
  if (Retry bash.exe -lc $t1) {
    Write-Host GPG key $key added -ForegroundColor $fc
  } else {
    "GPG Key Lookup failed from $ks2"
    exit 1
  }
} else {
  Write-Host GPG key $key retrieved -ForegroundColor $fc
  bash.exe -lc "pacman-key -f $key && pacman-key --lsign-key $key"
  Write-Host GPG key $key added -ForegroundColor $fc
}

Write-Host bash.exe -lc "pacman-key --list-keys" -ForegroundColor $fc
bash.exe -lc "pacman-key --list-keys"
