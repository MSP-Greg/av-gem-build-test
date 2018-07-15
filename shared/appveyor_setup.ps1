# PowerShell script for updating MSYS2 / MinGW, installing OpenSSL and other packages
# must be called with 32 or 64 argument
# Code by MSP-Greg, see https://github.com/MSP-Greg/av-gem-build-test

$LastExitCode = $null

#—————————————————————————————————————————————————————————————————————————————— Init
# below sets constants & variables for use, use local_paths.ps1 for a local run
function Init-AV-Setup {
  if ($env:APPVEYOR) {
    $pkgs_temp = "$PSScriptRoot/../packages"
    Path-Make $pkgs_temp
  
    Make-Const dflt_ruby 'C:\ruby25-x64'
    Make-Const in_av     $true

    # MinGW & Base Ruby
    Make-Const msys2     'C:\msys64'
    Make-Const dir_ruby  'C:\Ruby'

    # DevKit paths
    Make-Const DK32w     'C:\Ruby23\DevKit'
    Make-Const DK64w     'C:\Ruby23-x64\DevKit'

    # Folder for storing downloaded packages
    Make-Const pkgs      "$( Convert-Path $pkgs_temp )"

    # Use simple base path without all Appveyor additions
    Make-Const base_path 'C:\WINDOWS\system32;C:\WINDOWS;C:\WINDOWS\System32\Wbem;C:\WINDOWS\System32\WindowsPowerShell\v1.0\;C:\Program Files\Git\cmd;'

    Make-Const 7z        "$env:ProgramFiles\7-Zip\7z.exe"
    Make-Const fc        'Yellow'
  } else {
    . $PSScriptRoot\local_paths.ps1
  }

  Make-Const dir_user  "$env:USERPROFILE\.gem\ruby\"
  Make-Const ruby_vers_high 40
  # Download locations
  Make-Const ri1_pkgs  'https://dl.bintray.com/oneclick/OpenKnapsack'
  Make-Const ri2_pkgs  'https://dl.bintray.com/larskanis/rubyinstaller2-packages'
  Make-Const rubyloco  'https://dl.bintray.com/msp-greg/ruby_trunk'

  Make-Const trunk_uri_64  'https://ci.appveyor.com/api/projects/MSP-Greg/ruby-loco/artifacts/ruby_trunk.7z'
  Make-Const trunk_uri_32  'https://github.com/oneclick/rubyinstaller2/releases/download/rubyinstaller-head/rubyinstaller-head-x86.7z'
  Make-Const trunk_32_root 'rubyinstaller-head-x86'
  
  # Misc
  Make-Const SSL_CERT_FILE "$dflt_ruby\ssl\cert.pem"
  Make-Const ks1           'hkp://pool.sks-keyservers.net'
  Make-Const ks2           'hkp://pgp.mit.edu'
  Make-Const dash          "$([char]0x2015)"
  Make-Const wc            $(New-Object System.Net.WebClient)
  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

  # platform dependent varis (32 or 64)
  Make-Vari  g_plat        # gem  platform
  Make-Vari  r_plat        # ruby platform
  Make-Vari  mingw         # mingw32 or mingw64
  Make-Vari  m_pre         # MSYS2 package prefix
  Make-Vari  is64          # true for 64 bit
  Make-Vari  DKw           # DevKit path, windows style backslash

  Make-Vari  isRI2         # true for Ruby >= 2.4 (RubyInstaller2)

  Make-Vari  abi_vers      # ruby ABI vers, like '2.3'
  Make-Vari  gem_dflt      # Gem.default_dir
  Make-Vari  gem_user      # Gem.user_dir
  Make-Vari  gem_file_name # file name of gem
  Make-Vari  gem_full_name # full name of gem
  Make-Vari  commit_info   # commit info - date, short commit, desc
  Make-Vari  dk_b          # DevKit folder
  Make-Vari  rv_min        # Gem min ruby version
  Make-Vari  rv_max        # Gem max ruby version
  Make-Vari  rubies        # array of ruby versions to use in fat-binary

  Make-Vari  exit_code          # ExitCode from last exe
  Make-Vari  ttl_errors_fails 0 # Total of tests across all versions

  Make-Vari  need_refresh     $true  # flag for whether to MSYS2 needs a refresh
  Make-Vari  msys_full        $false # true to do a full MSYS2 update -Syu
  Make-Vari  ssl_vhash        @{}    # hash of ssl version, key is build system folder

  # varis for trunk
  Make-Vari  run_trunk
  Make-Vari  test_trunk
  Make-Vari  test_trunk_jit
  Make-Vari  test_use
}

#—————————————————————————————————————————————————————————————————————————————— Make-Const
# readonly, available in all session scripts
function Make-Const($N, $V) {
  New-Variable -Name $N -Value $V  -Scope Script -Option AllScope, Constant
}

#—————————————————————————————————————————————————————————————————————————————— Make-Vari
# available in all session scripts
function Make-Vari($N, $V) {
  try { New-Variable -Name $N -Value $V  -Scope Script -Option AllScope -ErrorAction "Stop" }
  catch {  }
#  New-Variable -Name $N -Value $V  -Scope Script -Option AllScope
}

#—————————————————————————————————————————————————————————————————————————————— Check-Exit
# checks whether to exit
function Check-Exit($msg, $pop) {
  $exit_code = $LastExitCode
  if ($exit_code -and $exit_code -gt 0) {
    if ($pop) { Pop-Location }
    Write-Host $msg -ForegroundColor $fc
    exit $exit_code
  }
}

#—————————————————————————————————————————————————————————————————————————————— Check-SetVars
function Check-SetVars {
  # Set up path with Ruby bin
  $env:path = "$dir_ruby$ruby$suf\bin;" + $base_path

  $isRI2 = $ruby -ge '24'

  # add cert file to ENV
  if ( !($isRI2) ) { $env:SSL_CERT_FILE = $SSL_CERT_FILE }

  $t = &ruby.exe -e "STDOUT.write Gem.default_dir + '|' + Gem.user_dir"
  $gem_dflt, $gem_user = $t.Split('|')
  $env:path += $gem_user.Replace('/', '\') + "\bin"
  $abi_vers = &ruby.exe -e "STDOUT.write RUBY_VERSION[/\A\d+\.\d+/]"
}

#—————————————————————————————————————————————————————————————————————————————— Check-OpenSSL
# assumes path is set to build tools
function Check-OpenSSL {
  # Set OpenSSL versions - 2.4 uses standard MinGW 1.0.2 package
  $openssl = if ($ruby -lt '20')     { 'openssl-1.0.0o'  } # 1.9.3
         elseif ($ruby -lt '22')     { 'openssl-1.0.1l'  } # 2.0, 2.1, 2.2
         elseif ($ruby -lt '24')     { 'openssl-1.0.2j'  } # 2.3
         elseif ($ruby -lt '25')     { 'openssl-1.0.2o'  } # 2.4
         else                        { 'openssl-1.1.0.h' } # 2.5

  $bit = if ($is64) { '64 bit' } else { '32 bit'}

  if (!$isRI2) {
    #—————————————————————————————————————————————————————————————————————— RubyInstaller
    if ($is64) { $86_64 = 'x64' ; $dk_b = 'x86_64-w64-mingw32' }
    else       { $86_64 = 'x86' ; $dk_b = 'i686-w64-mingw32'   }

    if ($ssl_vhash[$86_64] -ne $openssl) {
      # Install it
      if ($is64) { Package-DevKit $openssl 64
          } else { Package-DevKit $openssl 32 }
      # Set hash to indicate it's loaded
      $ssl_vhash[$86_64] = $openssl
    } else {
      Write-Host DevKit - $openssl $bit - Already installed -ForegroundColor $fc
    }

    $DKu = $DKw.Replace('\', '/')
    $env:SSL_CERT_FILE = $SSL_CERT_FILE
    $env:OPENSSL_CONF  = "$DKu/mingw/ssl/openssl.cnf"
    $env:SSL_VERS = (&"$DKu/mingw/$dk_b/bin/openssl.exe" version | Out-String).Trim()
  } else {
    #—————————————————————————————————————————————————————————————————————— RubyInstaller2
    if ($is64) { $key = '77D8FA18' ; $uri = $rubyloco }
      else     { $key = 'BE8BF1C5' ; $uri = $ri2_pkgs }

    if ($ssl_vhash[$mingw] -ne $openssl) {
      Write-Host MSYS2/MinGW - $openssl $bit - Retrieving and installing -ForegroundColor $fc
      $t = $openssl

      # as of 2018-06, OpenSSL package for 2.4 is standard MSYS2/MinGW package
      # 2.5 and later use custom OpenSSL 1.1.0 packages
      if ($ruby.StartsWith('24')) {
        pacman.exe -Rdd --noconfirm --noprogressbar $($m_pre + 'openssl')
        pacman.exe -S   --noconfirm --noprogressbar $($m_pre + 'openssl')
      } else {
        $openssl = "$m_pre$openssl-1-any.pkg.tar.xz"
        if( !(Test-Path -Path $pkgs/$openssl -PathType Leaf) ) {
          $wc.DownloadFile("$uri/$openssl"    , "$pkgs/$openssl")
        }
        if( !(Test-Path -Path $pkgs/$openssl.sig -PathType Leaf) ) {
          $wc.DownloadFile("$uri/$openssl.sig", "$pkgs/$openssl.sig")
        }
        $t1 = "`"pacman-key -r $key --keyserver $ks1 && pacman-key -f $key && pacman-key --lsign-key $key`""
        Retry bash.exe -lc $t1
        $exit_code = $LastExitCode
        # below is for occasional key retrieve failure on Appveyor
        if ($exit_code -and $exit_code -gt 0) {
          Write-Host GPG Key Lookup failed from $ks1 -ForegroundColor $fc
          # try another keyserver
          $t1 = "`"pacman-key -r $key --keyserver $ks2 && pacman-key -f $key && pacman-key --lsign-key $key`""
          Retry bash.exe -lc $t1
          Check-Exit "GPG Key Lookup failed from $ks2"
        }
        pacman.exe -Rdd --noconfirm --noprogressbar $($m_pre + 'openssl')
        $pkgs_u = $pkgs.replace('\', '/')
        pacman.exe -Udd --noconfirm --noprogressbar $pkgs_u/$openssl
        Check-Exit "Package Install failure!"
      }
      $ssl_vhash[$mingw] = $t
    } else {
      Write-Host MSYS2/MinGW - $openssl $bit - Already installed -ForegroundColor $fc
    }
    $env:SSL_VERS = (&"$msys2\$mingw\bin\openssl.exe" version | Out-String).Trim()
  }
}

#—————————————————————————————————————————————————————————————————————————————— Install-Trunk
# Loads trunk into ruby99 or ruby99-x64
function Install-Trunk {
  Write-Host "Installing Trunk..." -ForegroundColor $fc
  $trunk_path = $dir_ruby + "99" + $suf
  if ( !(Test-Path -Path $trunk_path -PathType Container) ) {
    $trunk_uri = if ($is64) { $trunk_uri_64 } else { $trunk_uri_32 }
    $fn = "$env:TEMP\ruby_trunk.7z"
    Write-Host "Download started"
    $wc.DownloadFile($trunk_uri, $fn)
    Write-Host "Download finished"

    if ( $is64 ) {
      $tp = "-o$trunk_path"
      &$7z x $fn $tp 1> $null
    } else {
      $tp = "-o" + $dir_ruby -replace '\\[^\\]*$', ''
      Write-Host "Extracting"
      &$7z x $fn $tp 1> $null
      $tp = $($dir_ruby -replace '\\[^\\]*$', '') + '\' + $trunk_32_root
      Rename-Item -Path $tp -NewName $trunk_path
    }
    Remove-Item -LiteralPath $fn -Force
#    if ( !($is64) ) {
#      # 64 bit 7z has no root, 32 bit root is $trunk_32_root
#      Get-ChildItem -Path $trunk_path\$trunk_32_root -Recurse | Move-Item -Destination $trunk_path
#    }
    Write-Host "finished" -ForegroundColor $fc
  } else {
    Write-Host "using existing trunk install" -ForegroundColor $fc
  }
  $trunk_exe = $trunk_path + "\bin\ruby.exe"
  return &"$trunk_path\bin\ruby.exe" -e "STDOUT.write RUBY_VERSION[/\A\d+\.\d+/]"
}

#——————————————————————————————————————————————————————————————————————————————  Load-Rubies
# loads array of ruby versions to loop thru
function Load-Rubies {

  $run_trunk = if ($is64) {
    ($trunk_x64 -ne $null) -or ($trunk_x64_JIT -ne $null)
  } else {
    ($trunk     -ne $null) -or ($trunk_JIT     -ne $null)
  }

  # Make an array, like a range
  $vers = $ruby_vers_high..$ruby_vers_low
  if ($run_trunk) {
    # add current trunk
    $trunk_abi = $(Install-Trunk)
    $vers = ,99 + $vers
  }
  $rubies = @()
  foreach ($v in $vers) {
    if ( $v -eq 19 -and $is64 ) { continue }

    $v = switch ($v) {
      19 { '193' }
      20 { '200' }
      default { [string]$v }
    }
    # loop if version isn't installed
    if ( !(Test-Path -Path $dir_ruby$v$suf -PathType Container) ) { continue }
    $rubies += $v
  }
  $rv_min = $rubies[-1].Substring(0,1) + '.' + $rubies[-1].Substring(1,1)
  if ($run_trunk) {
    # set $rv_max equal to one minor version above trunk
    $next = [int]($trunk_abi.Substring(2,1)) + 1
    $rv_max = $trunk_abi.Substring(0,2) + $next
  } else {
    $next = [int]($rubies[0].Substring(1,1)) + 1
    $rv_max = $rubies[0].Substring(0,1) + '.' + $next
  }
}

#—————————————————————————————————————————————————————————————————————————————— Package-DevKit
# $pkg parameter is <name-version>
# $b parameter should be 32, 64, or null for both
function Package-DevKit($pkg, $b) {
  $bits = if ($b -eq 32 -Or $b -eq 64) { @($b) } else { @(32,64) }
  foreach ($bit in $bits) {
    if ($bit -eq 32) {
             $DK = $DK32w ; $86_64 = 'x86' ; $dk_b = 'i686-w64-mingw32'   }
      else { $DK = $DK64w ; $86_64 = 'x64' ; $dk_b = 'x86_64-w64-mingw32' }

    Write-Host DevKit - $pkg $bit bit - Retrieving and Installing... -ForegroundColor $fc
    # Download & upzip into DK folder
    $pkg_i = $pkg + '-' + $86_64 + '-windows.tar.lzma'
    if( !(Test-Path -Path $pkgs/$pkg_i -PathType Leaf) ) {
      $wc.DownloadFile("$ri1_pkgs/$86_64/$pkg_i", "$pkgs/$pkg_i")
    }
    $t = '-o' + $pkgs
    &$7z e -y $pkgs\$pkg_i $t 1> $null
    $pkg_i = $pkg_i -replace "\.lzma\z", ""
    $p = "-o$DK\mingw\$dk_b"
    &$7z x -y $pkgs\$pkg_i $p 1> $null
  }
}

#—————————————————————————————————————————————————————————————————————————————— Package-MSYS2
function Package-MSYS2($pkg) {
  Check-SetVars
  $s = if ($need_refresh) { '-Sy' } else { '-S' }
  try   { &"$msys2\usr\bin\pacman.exe" $s --noconfirm --needed --noprogressbar $m_pre$pkg }
  catch { Write-Host "Cannot install/update $pkg package" }
  if (!$ri2 -And $pkg -eq 'ragel') { $env:path += ";$msys2\$mingw\bin" }
  $need_refresh = $false
}

#—————————————————————————————————————————————————————————————————————————————— Path-Make
# make a path
function Path-Make($p) {
  if ( !(Test-Path -Path $p -PathType Container) ) {
    New-Item -Path $p -ItemType Directory 1> $null
  }
}

#—————————————————————————————————————————————————————————————————————————————— Retry
# retries passed parameters as a command three times
function Retry {
  foreach ($idx in 1..3) {
    $cmd = $args -join ' '
    iex $cmd 2> $null
    if ($LastExitCode -and $LastExitCode -gt 0) { Start-Sleep 1 } else { break }
  }
  if ($LastExitCode -and $LastExitCode -gt 0) { exit $LastExitCode }
}

#—————————————————————————————————————————————————————————————————————————————— Ruby-Desc
function Ruby-Desc {
  if ($ruby -eq '99') {
    if ($is64) { return 'trunk-x64' } else { return 'trunk' }
  } else {
    return "ruby$ruby$suf"
  }
}

#—————————————————————————————————————————————————————————————————————————————— Update-Gems
# Call with a comma separated list of gems to update / install
function Update-Gems($str_gems) {
  if ($env:RUBYOPT) {
    $rubyopt = $env:RUBYOPT
    Remove-Item Env:\RUBYOPT
  }

  $install = ''
  $update  = ''
  foreach ($gem in $str_gems) {
    if ((iex "gem query -i $gem") -eq $False) { $install += " $gem" }
                                         else { $update  += " $gem" }
  }
  $install = $install.trim(' ')
  $update  = $update.trim(' ')

  if ($update)  {
    Write-Host "gem update $update -N -q -f" -ForegroundColor $fc
    iex "gem update $update -N -q -f"
  }
  if ($install) {
    Write-Host "gem install $install -N -q -f" -ForegroundColor $fc
    iex "gem install $install -N -q -f"
  }
  gem cleanup

  if ($rubyopt) {
    $env:RUBYOPT = $rubyopt
    $rubyopt = $null
  }
}

#—————————————————————————————————————————————————————————————————————————————— Update-MSYS2
# updates MSYS2/MinGW if $isRI2, sets $need_refresh to $false
# needs paths set to MSYS2 before calling
function Update-MSYS2 {
  if ($need_refresh) {
    if ($msys_full) {
      Write-Host "$($dash * 63) Updating MSYS2 / MinGW" -ForegroundColor Yellow

      Write-Host "pacman.exe -Syu --noconfirm --noprogressbar" -ForegroundColor Yellow
      pacman.exe -Syu --noconfirm --noprogressbar

      Write-Host "`npacman.exe -Su --noconfirm --noprogressbar" -ForegroundColor Yellow
      pacman.exe -Su --noconfirm --noprogressbar

      Write-Host "`nThe following two commands may not be needed, but I had issues" -ForegroundColor Yellow
      Write-Host "retrieving a new key without them..." -ForegroundColor Yellow

      $t1 = "pacman-key --init"
      Write-Host "`nbash.exe -lc $t1" -ForegroundColor Yellow
      bash.exe -lc $t1

      $t1 = "pacman-key -l"
      Write-Host "bash.exe -lc $t1" -ForegroundColor Yellow
      bash.exe -lc $t1

      if ($in_av) {
        Write-Host "Clean cache & database" -ForegroundColor Yellow
        Write-Host "pacman.exe -Sc  --noconfirm" -ForegroundColor Yellow
        pacman.exe -Sc  --noconfirm
      }
    } else {
      Write-Host "$($dash * 65) Updating MSYS2 / MinGW base-devel" -ForegroundColor $fc
      $s = if ($need_refresh) { '-Sy' } else { '-S' }
      pacman.exe $s --noconfirm --needed --noprogressbar base-devel 2> $null
      Check-Exit 'Cannot update base-devel'
      Write-Host "$($dash * 65) Updating MSYS2 / MinGW toolchain" -ForegroundColor $fc
      pacman.exe -S --noconfirm --needed --noprogressbar $($m_pre + 'toolchain') 2> $null
      Check-Exit 'Cannot update toolchain'
      Write-Host "`nClean cache & database" -ForegroundColor Yellow
      pacman.exe -Sc  --noconfirm 2> $null
    }
    $need_refresh = $false
  }
}

Init-AV-Setup

# load r_archs
[int]$temp = $args[0]
if ($temp -eq 32) {
  $r_plat = 'i386-mingw32' ; $mingw  = 'mingw32'
  $g_plat =  'x86-mingw32' ; $m_pre  = 'mingw-w64-i686-' 
  $suf    = ''             ; $DKw    = $DK32w
  $is64   = $false
} elseif ($temp -eq 64) {
  $r_plat = 'x64-mingw32'  ; $mingw  = 'mingw64'
  $g_plat = 'x64-mingw32'  ; $m_pre  = 'mingw-w64-x86_64-'
  $suf    = '-x64'         ; $DKw    = $DK64w
  $is64   = $true
} else {
  Write-Host "Must specify an platform (32 or 64)!" -ForegroundColor $fc
  exit 1
}

Path-Make $pkgs
