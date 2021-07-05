<#
cd C:\Greg\GitHub\av-gem-build-test
./check.ps1 64
#>

. $PSScriptRoot\shared\appveyor_setup.ps1 $args[0]

#———————————————————————————————————————————————————————————————— lowest ruby version
Make-Const ruby_vers_low 22
# null = don't compile; false = compile, ignore test (allow failure);
# true = compile & test
Make-Const trunk     $null ; Make-Const trunk_x64     $null
Make-Const trunk_JIT $null  ; Make-Const trunk_x64_JIT $null

Load-Rubies

foreach ($ruby in $rubies) {
  # Loop if ruby version does not exist
  if ( !(Test-Path -Path $dir_ruby$ruby$suf -PathType Container) ) { continue }

  Write-Host "$($dash * 60) $ruby$suf setup" -ForegroundColor $fc
  Check-SetVars

  Write-Host "$($dash * 40) git & path" -ForegroundColor $fc
  git version
  Write-Host $env:path

  # Add build system bin folders to path
  if ($isRI2) {
    $ssl_exe = "$msys2\$mingw\bin\openssl.exe"
    $env:path += ";$msys2\$mingw\bin;$msys2\usr\bin;"
    Update-MSYS2
  } else {
    $ssl_exe = "$DKw\mingw\$dk_b\bin\openssl.exe"
    $env:path += ";$DKw\mingw\bin;$DKw\mingw\$dk_b\bin;$DKw\bin;"
  }
  Check-OpenSSL
  Write-Host "$($dash * 60) $ruby$suf info" -ForegroundColor $fc
  ruby -v
  ruby -ropenssl -e "puts OpenSSL::OPENSSL_VERSION"
  ruby -ropenssl -e "puts OpenSSL::OPENSSL_LIBRARY_VERSION if OpenSSL.const_defined?(:OPENSSL_LIBRARY_VERSION)"
  &$ssl_exe version
}

if ($in_av -and $args[0] -eq '64') {
  &$7z a shared .\shared
  Push-AppveyorArtifact shared.7z
}
