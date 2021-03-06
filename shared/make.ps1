# PowerShell script for compiling all so files needed for fat binary gems
# This script is utility script, and should not require changes for any gems
# Code by MSP-Greg, see https://github.com/MSP-Greg/av-gem-build-test

#———————————————————————————————————————————————————————— Process Repo
Push-Location $dir_gem
$commit_info = $(git.exe log -1 --pretty=format:'%ci   %h   %s')
Write-Host "`nCommit Info: $commit_info`n" -ForegroundColor $fc

# Remove tmp folder
if ( Test-Path -Path .\tmp -PathType Container ) {
  Remove-Item  -Path .\tmp -Recurse -Force
}

# call optional function in gem ps1 file, allows changes before starting build
# typically checks MSYS2 for packages used by all Ruby versions
if (Get-Command Repo-Changes -errorAction SilentlyContinue) { Repo-Changes }

# if used, write rb files that load correct so file based on Ruby ABI version
if ($write_so_require) {
  foreach ($ext in $exts) {
    $file_text = "require_relative `"#{RUBY_VERSION[/\A\d+\.\d+/]}/" + $ext.so + "`"`n"
    $fn = "$dir_gem/$dest_so/" + $ext.so + '.rb'
    # below needed to write UTF8 file without BOM
    [IO.File]::WriteAllText($fn, $file_text, $UTF8)
  }
}

# Copy Rakefile_wintest if it exists
if ( Test-Path -Path $dir_ps\Rakefile_wintest -PathType Leaf) {
  Copy-Item -Path $dir_ps\Rakefile_wintest -Destination $dir_gem -Force
}
Pop-Location
#—————————————————————————————————————————————————————————————— Done with Process Repo

[string[]]$so_dests = @()

Load-Rubies

foreach ($ruby in $rubies) {
  # Loop if ruby version does not exist
  if ( !(Test-Path -Path $dir_ruby$ruby$suf -PathType Container) ) { continue }

  Check-SetVars

  # Add build system bin folders to path
  if ($isRI2) {
    $env:path += ";$msys2\$mingw\bin;$msys2\usr\bin;"
    Update-MSYS2
  } else {
    $env:path += ";$DKw\mingw\bin;$DKw\bin;"
  }

  # Out info to console
  Write-Host "`n$($dash * 75) $(Ruby-Desc)" -ForegroundColor $fc
  ruby.exe -v
  Write-Host RubyGems (gem --version)

  # call optional function in gem ps1 file, allows changes before starting builds,
  # typically used for MSYS2 packages that are Ruby version dependent, like OpenSSL
  if (Get-Command Pre-Compile -errorAction SilentlyContinue) { Pre-Compile }

  $dest = "$dir_gem\$dest_so\$abi_vers"
  Path-Make $dest

  $so_dests += $dest
  foreach ($ext in $exts) {
    $so = $ext.so
    $src_dir = "$dir_gem/tmp/$r_plat/$so/$abi_vers"
    New-Item -Path $src_dir -ItemType Directory 1> $null

    Push-Location -Path $src_dir
    Write-Host "`n$($dash * 50)" Compiling $(Ruby-Desc) $ext.so -ForegroundColor $fc
    if ($env:b_config) {
      $b_config = $env:b_config
      Write-Host "options:$($b_config.replace("--", "`n   --"))" -ForegroundColor $fc
    } else {
      $b_config = $null
    }
    # Invoke-Expression needed due to spaces in $env:b_config
    Write-Host "ruby.exe -I. $dir_gem/$($ext.conf) $b_config" -ForegroundColor $fc
    iex "ruby.exe -I. $dir_gem/$($ext.conf) $b_config"
    if ($isRI2) {
      Write-Host "make.exe -j2" -ForegroundColor $fc
      make.exe -j2
    } else {
      Write-Host "make.exe" -ForegroundColor $fc
      make.exe
    }
    Check-Exit "Make Failed!" $true

    $fn = $so + '.so'
    Write-Host Creating $dest_so\$abi_vers\$fn

    Copy-Item -Path $fn -Destination $dest\$fn -Force
    Pop-Location
  }
}
#———————————————————————————————————————————————————————————————— Strip all *.so files
[string[]]$sos = Get-ChildItem -Include *.so -Path $dir_gem\$dest_so -Recurse | select -expand fullname
foreach ($so in $sos) { strip.exe --strip-unneeded -p $so }

#————————————————————————————————————————————————————————————————————————— package gem
Write-Host "`n$($dash * 60)" Packaging Gem $g_plat -ForegroundColor $fc
$env:path = $dir_ruby + "25-x64\bin;$base_path"

Push-Location $dir_gem
$env:commit_info = $commit_info
$upper_ruby_vers = $rv_max + ".0.dev"
ruby.exe $dir_ps\package_gem.rb $g_plat $rv_min $upper_ruby_vers | Tee-Object -Variable bytes
Pop-Location
Check-Exit
Remove-Item Env:commit_info

# below mess is outputing package_gem.rb to console and a variable
# the converting to UTF-8
$bytes = [System.Text.Encoding]::Unicode.GetBytes($bytes)
$t = @()
foreach ($b in $bytes) {
  if ($b -ne 0) { $t += $b }
}
$gem_out = $UTF8.GetString($t)

$gem_file_name = if ($gem_out -imatch "\s+File:\s+(\S+)") { $matches[1]
  } else {
    $exit_code = 1
    exit 1
  }

$gem_full_name = $gem_file_name -replace '\.gem$', ''

# remove so folders
foreach ($so_dest in $so_dests) { Remove-Item  -Path $so_dest -Recurse -Force }

#————————————————————————————————————————————————————————— save gems if appveyor
if ($in_av) {
  Write-Host "`nSaving $gem_file_name as artifact" -ForegroundColor $fc
  $fn = $dir_gem + '/' + $gem_file_name
  Push-AppveyorArtifact $fn
} else { Write-Host '' }
