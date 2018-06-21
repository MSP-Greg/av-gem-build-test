# PowerShell script for updating MSYS2 / MinGW, installing OpenSSL and other packages
# must be called with 32 or 64 argument
# Code by MSP-Greg, see https://github.com/MSP-Greg/av-gem-build-test

#————————————————————————————————————————————————————————————————————————————————— Make-Const
# readonly, available in all session scripts
function Make-Const($N, $V) {
  New-Variable -Name $N -Value $V  -Scope Script -Option AllScope, Constant
}

#————————————————————————————————————————————————————————————————————————————————— Make-Vari
# available in all session scripts
function Make-Vari($N, $V) {
  New-Variable -Name $N -Value $V  -Scope Script -Option AllScope
}

#————————————————————————————————————————————————————————————————————————————————— Constants
# below sets constants for Appveyor, use local_paths.ps1 for a local run
if ($env:APPVEYOR) {
  Make-Const dflt_ruby 'C:\ruby25-x64'
  Make-Const in_av     $true

  # MinGW & Base Ruby
  Make-Const msys2     'C:\msys64'
  Make-Const dir_ruby  'C:\Ruby'

  # DevKit paths
  Make-Const DK32w     'C:\Ruby23\DevKit'
  Make-Const DK64w     'C:\Ruby23-x64\DevKit'

  # Folder for storing downloaded packages
  Make-Const pkgs      "$PSScriptRoot/../packages"

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

# Misc
Make-Const SSL_CERT_FILE "$dflt_ruby\ssl\cert.pem"
Make-Const ks1           'hkp://na.pool.sks-keyservers.net'
Make-Const ks2           'hkp://pgp.mit.edu/'
Make-Const dash          "$([char]0x2015)"
Make-Const wc            $(New-Object System.Net.WebClient)

# platform dependent varis
Make-Vari  g_plat        # gem  platform
Make-Vari  r_plat        # ruby platform
Make-Vari  mingw         # mingw32 or mingw64
Make-Vari  m_pre         # MSYS2 package prefix
Make-Vari  is64          # true for 64 bit
Make-Vari  dk            # DevKit path

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

Make-Vari  exit_code        0   # ExitCode from last exe
Make-Vari  ttl_errors_fails 0   # Total of tests across all versions

Make-Vari  need_refresh     $true
Make-Vari  ssl_vhash        @{}   # hash of ssl version, key is build system folder

#—————————————————————————————————————————————————————————————————————————————— Check-SetVars
# assumes path is already set
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
function Check-OpenSSL {
  Check-SetVars

  # Set OpenSSL versions - 2.4 uses standard MinGW 1.0.2 package
  $openssl = if ($ruby -lt '20')     { 'openssl-1.0.0o'  } # 1.9.3
         elseif ($ruby -lt '22')     { 'openssl-1.0.1l'  } # 2.0, 2.1, 2.2
         elseif ($ruby -lt '24')     { 'openssl-1.0.2j'  } # 2.3
         elseif ($ruby -lt '25')     { 'openssl-1.0.2o'  } # 2.4
         else                                    { 'openssl-1.1.0.h' } # 2.5

  $bit = if ($is64) { '64 bit' } else { '32 bit'}

  if (!$isRI2) {
    #————————————————————————————————————————————————————————————————————————— RubyInstaller
    if ($is64) { $86_64 = 'x64' ; $dk_b = 'x86_64-w64-mingw32' }
    else       { $86_64 = 'x86' ; $dk_b = 'i686-w64-mingw32'   }

    $DKu = $DKw.Replace('\', '/')
    if ($ssl_vhash[$86_64] -ne $openssl) {
      # Install it
      if ($is64) { DevKit-Package $openssl 64
          } else { DevKit-Package $openssl 32 }
      # Set hash to indicate it's loaded
      $ssl_vhash[$86_64] = $openssl
    } else {
      Write-Host DevKit - $openssl $bit - Already installed -ForegroundColor $fc
    }

    $env:SSL_CERT_FILE = $SSL_CERT_FILE
    $env:OPENSSL_CONF  = "$DKu/mingw/ssl/openssl.cnf"
    $env:SSL_VERS = (&"$DKu/mingw/$dk_b/bin/openssl.exe" version | Out-String).Trim()
  } else {
    #————————————————————————————————————————————————————————————————————————— RubyInstaller2
    if ($is64) { $key = '77D8FA18' ; $uri = $rubyloco }
      else     { $key = 'BE8BF1C5' ; $uri = $ri2_pkgs }

    if ($ssl_vhash[$mingw] -ne $openssl) {
      Write-Host MSYS2/MinGW - $openssl $bit - Retrieving and installing -ForegroundColor $fc
      $t = $openssl
      # as of 2018-06, OpenSSL package for 2.4 is standard MSYS2/MinGW package
      # 2.5 and later use custom OpenSSL 1.1.0 packages
      if ($ruby.StartsWith('24')) {
        &"$msys2\usr\bin\pacman.exe" -S --noconfirm --noprogressbar $($m_pre + 'openssl')
      } else {
        $openssl = "$m_pre$openssl-1-any.pkg.tar.xz"
        if( !(Test-Path -Path $pkgs/$openssl -PathType Leaf) ) {
          $wc.DownloadFile("$uri/$openssl"    , "$pkgs/$openssl")
        }
        if( !(Test-Path -Path $pkgs/$openssl.sig -PathType Leaf) ) {
          $wc.DownloadFile("$uri/$openssl.sig", "$pkgs/$openssl.sig")
        }
        Push-Location -Path $msys2\usr\bin
        $t1 = "pacman-key -r $key --keyserver $ks1 && pacman-key -f $key && pacman-key --lsign-key $key"
        &"$msys2\usr\bin\bash.exe" -lc $t1 2> $null
        $exit_code = $LastExitCode

        # below is for occasional key retrieve failure on Appveyor
        if ($exit_code -ne 0) {
          # try another keyserver
          $t1 = "pacman-key -r $key --keyserver $ks2 && pacman-key -f $key && pacman-key --lsign-key $key"
          &"$msys2\usr\bin\bash.exe" -lc $t1 2> $null
          $exit_code = $LastExitCode

          if ($exit_code -ne 0) {
            Write-Host GPG Key Lookup Failed! -ForegroundColor $fc
            exit $exit_code
          }
        }
        Pop-Location

        &"$msys2\usr\bin\pacman.exe" -Rdd --noconfirm --noprogressbar $($m_pre + 'openssl')
        &"$msys2\usr\bin\pacman.exe" -Udd --noconfirm --noprogressbar --force $pkgs/$openssl
      }
      $ssl_vhash[$mingw] = $t
    } else {
      Write-Host MSYS2/MinGW - $openssl $bit - Already installed -ForegroundColor $fc
    }
    $env:SSL_VERS = (&"$msys2\$mingw\bin\openssl.exe" version | Out-String).Trim()
  }
}

#—————————————————————————————————————————————————————————————————————————————— Check-Update
# updates MSYS2/MinGW if $isRI2, sets $need_refresh to $false
function Check-Update {
  if ($need_refresh) {
    Write-Host "$($dash * 65) Updating MSYS2 / MinGW base-devel" -ForegroundColor $fc
    $s = if ($need_refresh) { '-Sy' } else { '-S' }
    try   { &"$msys2\usr\bin\pacman.exe" $s --noconfirm --needed --noprogressbar base-devel 2> $null }
    catch { Write-Host 'Cannot update base-devel' }
    Write-Host "$($dash * 65) Updating MSYS2 / MinGW toolchain" -ForegroundColor $fc
    try   { &"$msys2\usr\bin\pacman.exe" -S --noconfirm --needed --noprogressbar $($m_pre + 'toolchain') 2> $null }
    catch { Write-Host 'Cannot update toolchain' }
    $need_refresh = $false
  }
}

#——————————————————————————————————————————————————————————————————————————————  Load-Rubies
# loads array of ruby versions to loop thru
function Load-Rubies {
  # Make an array, like a range
  $vers = $ruby_vers_high..$ruby_vers_low
  # add current trunk
  if ($is64) {
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
  $rv_max = if ($is64) {
    $next = [int]($trunk_abi.Substring(2,1)) + 1
    $trunk_abi.Substring(0,2) + $next
  } else {
    $rubies[0].Substring(0,1)  + '.' + [int]($rubies[0].Substring(1,1)) + 1
  }
}

#—————————————————————————————————————————————————————————————————————————————— Install-Trunk
function Install-Trunk {
  Write-Host "Installing Trunk..." -ForegroundColor $fc
  $trunk_path = "$dir_ruby" + "99-x64"
  if ( !(Test-Path -Path $trunk_path -PathType Container) ) {
    $trunk_uri = 'https://ci.appveyor.com/api/projects/MSP-Greg/ruby-loco/artifacts/ruby_trunk.7z'
    $fn = "$env:TEMP\ruby_trunk.7z"
    $wc.DownloadFile($trunk_uri, $fn)
    $tp = "-o$trunk_path"
    &$7z x $fn $tp 1> $null
    Remove-Item  -LiteralPath $fn -Force
    Write-Host "  finished" -ForegroundColor $fc
  } else {
    Write-Host "  using existing trunk install" -ForegroundColor $fc
  }
  $trunk_exe = $dir_ruby + "99-x64\bin\ruby.exe"
  return &$trunk_exe -e "STDOUT.write RUBY_VERSION[/\A\d+\.\d+/]"
}

#—————————————————————————————————————————————————————————————————————————————— Package-DevKit
# $pkg parameter is <name-version>
# $b parameter should be 32, 64, or null for both
function Package-DevKit($pkg, $b) {
  $bits = if ($b -eq 32 -Or $b -eq 64) { @($b) } else { @(32,64) }
  foreach ($bit in $bits) {
    if ($bit -eq 32) {
             $DKw = $DK32w ; $86_64 = 'x86' ; $dk_b = 'i686-w64-mingw32'   }
      else { $DKw = $DK64w ; $86_64 = 'x64' ; $dk_b = 'x86_64-w64-mingw32' }

    Write-Host DevKit - $pkg $bit bit - Retrieving and Installing... -ForegroundColor $fc
    # Download & upzip into DK folder
    $pkg_i = $pkg + '-' + $86_64 + '-windows.tar.lzma'
    if( !(Test-Path -Path $pkgs/$pkg_i -PathType Leaf) ) {
      $wc.DownloadFile("$ri1_pkgs/$86_64/$pkg_i", "$pkgs/$pkg_i")
    }
    $t = '-o' + $pkgs
    &$7z e -y $pkgs\$pkg_i $t 1> $null
    $pkg_i = $pkg_i -replace "\.lzma\z", ""
    $p = "-o$DKw\mingw\$dk_b"
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

#—————————————————————————————————————————————————————————————————————————————— Ruby-Desc
function Ruby-Desc {
  if ($ruby -eq '99') { return 'trunk-x64' } else { return "ruby$ruby$suf" }
}

#—————————————————————————————————————————————————————————————————————————————— Update-Gems
# Call with a comma separated list of gems to update / install
function Update-Gems($str_gems) {
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
    iex "gem update $update  -N -q -f"
  }
  if ($install) {
    Write-Host "gem install $install -N -q -f" -ForegroundColor $fc
    iex "gem install $install -N -q -f"
  }
  gem cleanup
}

# load r_archs
[int]$temp = $args[0]
if ($temp -eq 32) {
  $r_plat = 'i386-mingw32'
  $g_plat =  'x86-mingw32'
  $mingw  = 'mingw32'
  $m_pre  = 'mingw-w64-i686-'
  $dk     = $DK32w
  $suf    = ''
  $is64   = $false
} elseif ($temp -eq 64) {
  $r_plat = 'x64-mingw32'
  $g_plat = 'x64-mingw32'
  $mingw  = 'mingw64'
  $m_pre  = 'mingw-w64-x86_64-'
  $dk     = $DK64w
  $suf    = '-x64'
  $is64   = $true
} else {
  Write-Host "Must specify an platform (32 or 64)!" -ForegroundColor $fc
  exit 1
}

Path-Make $pkgs
