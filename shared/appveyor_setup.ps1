# PowerShell script for updating MSYS2 / MinGW, installing OpenSSL and other packages
# must be called with 32 or 64 argument
# Code by MSP-Greg, see https://github.com/MSP-Greg/av-gem-build-test

$LastExitCode = $null

#—————————————————————————————————————————————————————————————————————————— Init
# below sets constants & variables for use, use local_paths.ps1 for a local run
function Init-AV-Setup {
  if ($env:APPVEYOR) {
    $pkgs_temp = "$PSScriptRoot/../packages"
    Path-Make $pkgs_temp

    Make-Const dflt_ruby 'C:\Ruby25-x64'
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
    Make-Const base_path `
    $("$env:SystemRoot\system32;$env:SystemRoot;$env:SystemRoot\System32\Wbem;" `
    + "$env:SystemRoot\System32\WindowsPowerShell\v1.0\;" `
    + "$env:ProgramFiles\Git\cmd;$env:ProgramFiles\AppVeyor\BuildAgent")

    Make-Const 7z        "$env:ProgramFiles\7-Zip\7z.exe"
    Make-Const fc        'Yellow'
  } else {
    . $PSScriptRoot\local_paths.ps1
  }

  Make-Const dir_user  "$env:USERPROFILE\.gem\ruby\"
  Make-Const ruby_vers_high 40
  # Download locations

  # old RI knapsack packages
  Make-Const ri1_pkgs  'https://dl.bintray.com/oneclick/OpenKnapsack'

  # used for very old MSYS2/MinGW packages, as of 2019-01, OpenSSL 1.0.2p
  Make-Const msys_pkgs 'https://dl.bintray.com/msp-greg/MSYS2-MinGW-OpenSSL'

  # RI2 packages, as of 2019-01, only Ruby 2.4 OpenSSL 1.0.2p
  Make-Const ri2_pkgs  'https://dl.bintray.com/larskanis/rubyinstaller2-packages'
  Make-Const ri2_key   'F98B8484BE8BF1C5'

  Make-Const sf_pkgs   'https://sourceforge.net/projects/msys2/files/REPOS/MINGW'

  # used for OpenSSL beta & pre-release packages, only used by ruby-loco (64 bit trunk)
  Make-Const rubyloco  'https://ci.appveyor.com/api/projects/MSP-Greg/ruby-makepkg-mingw/artifacts'

  # download URI's for trunk builds, ruby-loco is only 64 bit, RI2 builds 32 bit
  Make-Const trunk_uri_64  'https://ci.appveyor.com/api/projects/MSP-Greg/ruby-loco/artifacts/ruby_trunk.7z'
  Make-Const ri2_release   'https://github.com/oneclick/rubyinstaller2/releases/download'
  Make-Const trunk_uri_32  "$ri2_release/rubyinstaller-head/rubyinstaller-head-x86.7z"
  Make-Const trunk_32_root 'rubyinstaller-head-x86'

  # Misc
  Make-Const UTF8           $(New-Object System.Text.UTF8Encoding $False)
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
  Make-Vari  86_64         # x86 or x64
  Make-Vari  dk_b          # DevKit folder
  Make-Vari  rv_min        # Gem min ruby version
  Make-Vari  rv_max        # Gem max ruby version
  Make-Vari  rubies        # array of ruby versions to use in fat-binary

  Make-Vari  exit_code          # ExitCode from last exe
  Make-Vari  ttl_errors_fails 0 # Total of tests across all versions

  Make-Vari  need_refresh     $true  # flag for whether MSYS2 needs a refresh
  Make-Vari  need_refresh_db  $true  # flag for whether MSYS2 database needs a refresh
  Make-Vari  msys_full        $false # true to do a full MSYS2 update -Syu
  Make-Vari  ssl_vhash        @{}    # hash of ssl version, key is build system folder

  # varis for trunk
  Make-Vari  run_trunk
}

#—————————————————————————————————————————————————————————————————————————— Make-Const
# readonly, available in all session scripts
function Make-Const($N, $V) {
  New-Variable -Name $N -Value $V  -Scope Script -Option AllScope, Constant
}

#—————————————————————————————————————————————————————————————————————————— Make-Vari
# available in all session scripts
function Make-Vari($N, $V) {
  try { New-Variable -Name $N -Value $V  -Scope Script -Option AllScope -ErrorAction "Stop" }
  catch {  }
}

#—————————————————————————————————————————————————————————————————————————— Check-Exit
# checks whether to exit
function Check-Exit($msg, $pop) {
  if ($LastExitCode -and $LastExitCode -ne 0) {
    if ($pop) { Pop-Location }
    Write-Host $msg -ForegroundColor $fc
    exit 1
  }
}

#——————————————————————————————————————————————————————————————————————— Check-SetVars
function Check-SetVars {
  # Set up path with Ruby bin
  $env:path = "$dir_ruby$ruby$suf\bin;$base_path"

  $isRI2 = $ruby -ge '24'

  # add cert file to ENV, set vari's
  if ( !($isRI2) ) { $env:SSL_CERT_FILE = $SSL_CERT_FILE }

  $t = &ruby.exe -e "STDOUT.write Gem.default_dir + '|' + Gem.user_dir"
  $gem_dflt, $gem_user = $t.Split('|')
  $env:path += $gem_user.Replace('/', '\') + "\bin"
  $abi_vers = &ruby.exe -e "STDOUT.write RUBY_VERSION[/\A\d+\.\d+/]"
}

#——————————————————————————————————————————————————————————————————————— Check-OpenSSL
# assumes path is set to build tools
function Check-OpenSSL {

  # Create $pkgs path if it doesn't exist
  if ( !(Test-Path -Path $pkgs -PathType Container) ) {
    New-Item -Path $pkgs -ItemType Directory 1> $null
  }

  # Set OpenSSL versions - 2.4 uses standard MinGW 1.0.2 package
  $uri = $null
  $openssl_sha = ''
  $openssl =   if ($ruby -lt '20') { 'openssl-1.0.0o'
         } elseif ($ruby -lt '22') { 'openssl-1.0.1l'
         } elseif ($ruby -lt '24') { 'openssl-1.0.2j'
         } elseif ($ruby -lt '25') { 'openssl-1.0.2.p'
           $uri = $msys_pkgs
           # $key = $ri2_key
           $msys2_rev = '1'
         } elseif ($ruby -lt '26') { 'openssl-1.1.1'
         } elseif ($ruby -lt '27') { 'openssl-1.1.1'
         } elseif ($is64) {
#          $uri = $rubyloco             # 2.7 64 bit ruby-loco, may use OpenSSL beta
#          $key = $null
#          $openssl_sha = '0c8be3277693f60c319f997659c2fed0eadce8535aed29a4617ec24da082b60ee30a03d3fe1024dae4461041e6e9a5e5cff1a68fa08b4b8791ea1bf7b02abc40'
          'openssl-1.1.1'
         } else {
#          $uri = $ri2_pkgs             # 2.7 32 bit
#          $key = $ri2_key
          'openssl-1.1.1'
         }

  $bit = if ($is64) { '64 bit' } else { '32 bit'}

  if (!$isRI2) {
    #————————————————————————————————————————————————————————————————— RubyInstaller
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
#    $env:SSL_CERT_FILE = $SSL_CERT_FILE
    $env:OPENSSL_CONF  = "$DKu/mingw/$dk_b/ssl/openssl.cnf"
    $env:SSL_VERS = (&"$DKu/mingw/$dk_b/bin/openssl.exe" version | Out-String).Trim()
  } else {
    #———————————————————————————————————————————————————————————————— RubyInstaller2
    if ($ssl_vhash[$mingw] -ne $openssl) {
      Write-Host MSYS2/MinGW - $openssl $bit - Retrieving and Installing -ForegroundColor $fc

      if (!$uri) {
        # standard MSYS2/MinGW package
        pacman.exe -Rdd --noconfirm --noprogressbar $($m_pre + 'openssl')
        pacman.exe -S   --noconfirm --noprogressbar $($m_pre + 'openssl')
      } else {
        $openssl_fn = "$m_pre$openssl-$msys2_rev-any.pkg.tar.xz"

        if ($key) {
          #——————————————————————————————————————————————————————————————— Add GPG key
          Write-Host "`ntry retrieving key" -ForegroundColor Yellow

          $okay = Retry bash.exe -c `"pacman-key -r $key --keyserver $ks1`"
          # below is for occasional key retrieve failure on Appveyor
          if (!$okay) {
            Write-Host GPG Key Lookup failed from $ks1 -ForegroundColor Yellow
            # try another keyserver
            $okay = Retry bash.exe -c `"pacman-key -r $key --keyserver $ks2`"
            if (!$okay) {
              Write-Host GPG Key Lookup failed from $ks2 -ForegroundColor Yellow
              if ($in_av) {
                Update-AppveyorBuild -Message "keyserver retrieval failed"
              }
              exit 1
            } else { Write-Host GPG Key Lookup succeeded from $ks2 }
          }   else { Write-Host GPG Key Lookup succeeded from $ks1 }
          Write-Host "signing key" -ForegroundColor Yellow
          bash.exe -c "pacman-key -f $key && pacman-key --lsign-key $key" 2>$null

          if( !(Test-Path -Path $pkgs/$openssl_fn.sig -PathType Leaf) ) {
            $wc.DownloadFile("$uri/$openssl_fn.sig", "$pkgs/$openssl_fn.sig")
          }
        }

        if( !(Test-Path -Path $pkgs/$openssl_fn -PathType Leaf) ) {
          $wc.DownloadFile("$uri/$openssl_fn"      , "$pkgs/$openssl_fn")
          if ($openssl_sha -ne '') {
            Check-SHA $pkgs $openssl_fn $uri $openssl_sha
          } else {
            $wc.DownloadFile("$uri/$openssl_fn.sig", "$pkgs/$openssl_fn.sig")
          }
        }

        pacman.exe -Rdd --noconfirm --noprogressbar $($m_pre + 'openssl')
        $pkgs_u = $pkgs.replace('\', '/')
        pacman.exe -Udd --noconfirm --noprogressbar $pkgs_u/$openssl_fn
        Check-Exit "Package Install failure!"
      }
      $ssl_vhash[$mingw] = $openssl
    } else {
      Write-Host MSYS2/MinGW - $openssl $bit - Already installed -ForegroundColor $fc
    }
    $env:SSL_VERS = (&"$msys2\$mingw\bin\openssl.exe" version | Out-String).Trim()
  }
}

#—————————————————————————————————————————————————————————————————————————— Check_SHA
# checks SHA512 from file, script variable & Appveyor message
function Check-SHA($path, $file, $uri_dl, $sha_local) {
  $uri_bld = $uri_dl -replace '/artifacts$', ''
  $obj_bld = ConvertFrom-Json -InputObject $(Invoke-WebRequest -Uri $uri_bld)
  $job_id = $obj_bld.build.jobs[0].jobId

  $json_msgs = Invoke-WebRequest -Uri "https://ci.appveyor.com/api/buildjobs/$job_id/messages"
  $obj_msgs = ConvertFrom-Json -InputObject $json_msgs
  $sha_msg  = $($obj_msgs.list | Where {$_.message -eq $($file + '_SHA512')}).details

  $sha_file = $(CertUtil -hashfile $path\$file SHA512).split("`r`n")[1].replace(' ', '')
  if ($sha_local -ne '') {
    if (($sha_msg -eq $sha_file) -and ($sha_local -eq $sha_file)) {
      Write-Host "Three SHA512 values match for file, Appveyor message, and local script" -ForegroundColor $fc
    } else {
      Write-Host SHA512 values do not match -ForegroundColor $fc
      exit 1
    }
  } else {
    if ($sha_msg -eq $sha_file) {
      Write-Host SHA512 matches for file and Appveyor message -ForegroundColor $fc
    } else {
      Write-Host SHA512 values do not match -ForegroundColor $fc
      exit 1
    }
  }
}

#——————————————————————————————————————————————————————————————————————— Install-New
# Loads newest Ruby version, as it may not exist on Appveyor
function Install-New($new_path, $new_vers) {
  Write-Host new_path $new_path
  Write-Host new_vers $new_vers
  $dn = "rubyinstaller-" + $new_vers
  $new_uri = "$ri2_release/RubyInstaller-$new_vers/"
  if ($is64) { $dn += "-x64" } else { $dn += "-x86" }

  Write-Host "Download started $dn"
  $fn = "$env:TEMP\$dn" + ".7z"
  $new_uri += "$dn" + ".7z"

  try {
    $wc.DownloadFile($new_uri, $fn)
    Write-Host "Download finished"

    Write-Host "Extracting"
    $tp = "-o" + $dir_ruby -replace '\\[^\\]*$', ''
    &$7z x $fn $tp 1> $null
    $tp = $($dir_ruby -replace '\\[^\\]*$', '') + '\' + $dn
    Rename-Item -Path $tp -NewName $new_path
    Write-Host "Installed"
  } catch {
    Write-Host "$dn is not available, skipping"  -ForegroundColor Red
  }
}

#——————————————————————————————————————————————————————————————————————— Install-Trunk
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
    Write-Host "finished" -ForegroundColor $fc
  } else {
    Write-Host "using existing trunk install at $trunk_path" -ForegroundColor $fc
  }
  $trunk_exe = $trunk_path + "\bin\ruby.exe"
  # check for Ruby version behind trunk
  $two = $(&$trunk_exe -e "STDOUT.write RUBY_VERSION[/\A\d+\.\d+/].tr('.','').to_i - 1")
  $new_dir = "$dir_ruby$two$suf"
  if ( !(Test-Path -Path $new_dir -PathType Container) ) {
    # Ruby 2.6.1
    $t = $two[0] + "." + $two[1] + ".1-1"
    Install-new $new_dir $t
  }
  return &$trunk_exe -e "STDOUT.write RUBY_VERSION[/\A\d+\.\d+/]"
}

#————————————————————————————————————————————————————————————————————————  Load-Rubies
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

#—————————————————————————————————————————————————————————————————————— Package-DevKit
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

#——————————————————————————————————————————————————————————————————————— Package-MSYS2
function Package-MSYS2($pkg) {
  $s = if ($need_refresh) { '-Sy' } else { '-S' }
  try   { &"$msys2\usr\bin\pacman.exe" $s --noconfirm --needed --noprogressbar $m_pre$pkg }
  catch { Write-Host "Cannot install/update $pkg package" }
  if (!$ri2 -And $pkg -eq 'ragel') { $env:path += ";$msys2\$mingw\bin" }
  $need_refresh_db = false
}

#——————————————————————————————————————————————————————————————————————————— Path-Make
# make a path
function Path-Make($p) {
  if ( !(Test-Path -Path $p -PathType Container) ) {
    New-Item -Path $p -ItemType Directory 1> $null
  }
}

#——————————————————————————————————————————————————————————————————————————————— Retry
# retries passed parameters as a command three times
function Retry {
  $err_action = $ErrorActionPreference
  $ErrorActionPreference = "Stop"
  $a = $args[1..($args.Length-1)]
  $c = $args[0]
  # Write-Host $c $a -ForegroundColor $fc
  foreach ($idx in 1..3) {
    $Error.clear()
    try {
      &$c $a # 2> $null
      if ($? -and ($Error.length -eq 0 -or $Error.length -eq $null)) {
        $ErrorActionPreference = $err_action
        return $true
      }
    } catch {
      if (!($Error[0] -match 'fail|error|Remote key not fetched correctly')) {
        $ErrorActionPreference = $err_action
        return $true
      }
    }
    if ($idx -lt 3) {
      Write-Host "  retry"
      Start-Sleep 1
    }
  }
  $ErrorActionPreference = $err_action
  return $false
}

#——————————————————————————————————————————————————————————————————————————— Ruby-Desc
# returns string like trunk-x64 or ruby25-x64
function Ruby-Desc {
  if ($ruby -eq '99') {
    if ($is64) { return 'trunk-x64' } else { return 'trunk' }
  } else {
    return "ruby$ruby$suf"
  }
}

#————————————————————————————————————————————————————————————————————————— Update-Gems
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

#———————————————————————————————————————————————————————————————————————— Update-MSYS2
# updates MSYS2/MinGW if $isRI2, sets $need_refresh to $false
# needs paths set to MSYS2 before calling
function Update-MSYS2 {
  if ($need_refresh) {
    if ($msys_full) {
      Write-Host "$($dash * 63) Updating MSYS2 / MinGW" -ForegroundColor $fc

      Write-Host "pacman.exe -Syu --noconfirm --noprogressbar" -ForegroundColor $fc
      pacman.exe -Syu --noconfirm --noprogressbar

      Write-Host "`npacman.exe -Su --noconfirm --noprogressbar" -ForegroundColor $fc
      pacman.exe -Su --noconfirm --noprogressbar

    } else {
      if ($need_refresh_db) {
        Write-Host "$($dash * 65) Updating MSYS2 / MinGW" -ForegroundColor $fc
        Write-Host "pacman.exe -Sy --noconfirm --needed --noprogressbar" -ForegroundColor $fc
        pacman.exe -Sy --noconfirm --needed --noprogressbar
      }

<#———————————————————————————————————————————————————————————————————————— 30-Aug-2018

      # Only use below for really outdated systems, as it wil perform a full update
      # for 'newer' systems...
      Write-Host "$($dash * 65) Updating MSYS2 / MinGW -Syu" -ForegroundColor $fc
      pacman.exe -Syu --noconfirm --needed --noprogressbar
      Check-Exit 'Cannot update with -Syu'

      Write-Host "$($dash * 65) Updating MSYS2 / MinGW base" -ForegroundColor $fc
      # change to -Syu if above is commented out
      pacman.exe -S --noconfirm --needed --noprogressbar base 2> $null
      Check-Exit 'Cannot update base'

      Write-Host "$($dash * 65) Updating MSYS2 / MinGW db gdbm libgdbm libreadline ncurses" -ForegroundColor $fc
      pacman.exe -Sy --noconfirm --needed --noprogressbar db gdbm libgdbm libreadline ncurses 2> $null
      Check-Exit 'Cannot update db gdbm libgdbm libreadline ncurses'

      Write-Host "$($dash * 65) Updating MSYS2 / MinGW base-devel" -ForegroundColor $fc
      pacman.exe -S --noconfirm --needed --noprogressbar base-devel 2> $null
      Check-Exit 'Cannot update base-devel'

      Write-Host "$($dash * 65) Updating gnupg `& depends" -ForegroundColor $fc

      Write-Host "Updating gnupg extended dependencies" -ForegroundColor Yellow
      #pacman.exe -S --noconfirm --needed --noprogressbar brotli ca-certificates glib2 gmp heimdal-libs icu libasprintf libcrypt
      #pacman.exe -S --noconfirm --needed --noprogressbar libdb libedit libexpat libffi libgettextpo libhogweed libidn2 liblzma
      pacman.exe -S --noconfirm --needed --noprogressbar libmetalink libnettle libnghttp2 libopenssl libp11-kit libpcre libpsl 2> $null
      #pacman.exe -S --noconfirm --needed --noprogressbar libssh2 libtasn1 libunistring libxml2 libxslt openssl p11-kit

      Write-Host "Updating gnupg package dependencies" -ForegroundColor Yellow
      # below are listed gnupg dependencies
      pacman.exe -S --noconfirm --needed --noprogressbar bzip2 libassuan libbz2 libcurl libgcrypt libgnutls libgpg-error libiconv 2> $null
      pacman.exe -S --noconfirm --needed --noprogressbar libintl libksba libnpth libreadline libsqlite nettle pinentry zlib 2> $null

      Write-Host "Updating gnupg" -ForegroundColor Yellow
      pacman.exe -S --noconfirm --needed --noprogressbar gnupg 2> $null
#>

#      Write-Host "$($dash * 65) Updating MSYS2 / MinGW toolchain" -ForegroundColor $fc
#      Write-Host "pacman.exe -S --noconfirm --needed --noprogressbar $($m_pre + 'toolchain')" -ForegroundColor $fc
#      pacman.exe -S --noconfirm --needed --noprogressbar $($m_pre + 'toolchain') 2> $null
#      Check-Exit 'Cannot update toolchain'

      Write-Host "$($dash * 65) Updating MSYS2 / MinGW ruby depends1" -ForegroundColor Yellow
      # 2019-05-29 below only needed until next Appveyor image update
      $tools = "___python3 ___readline ___sqlite3".replace('___', $m_pre)
      pacman.exe -S --noconfirm --needed --noprogressbar $tools.split(' ')
      Check-Exit 'Cannot update ruby depends1'

      Write-Host "$($dash * 65) Updating MSYS2 / MinGW toolchain" -ForegroundColor $fc
      Write-Host "pacman.exe -S --noconfirm --needed --noprogressbar --nodeps $($m_pre + 'toolchain')" -ForegroundColor $fc
      pacman.exe -S --noconfirm --needed --noprogressbar --nodeps $($m_pre + 'toolchain') 2> $null
      Check-Exit 'Cannot update toolchain'

      Write-Host "$($dash * 65) Updating MSYS2 / MinGW ruby depends2" -ForegroundColor Yellow
      $tools =  "___gdbm ___gmp ___libffi ___pdcurses ___readline ___zlib".replace('___', $m_pre)
      pacman.exe -S --noconfirm --needed --noprogressbar $tools.split(' ') 2> $null
      Check-Exit 'Cannot update Ruby dependencies'
    }
    if ($in_av) {
      Write-Host "Clean cache & database" -ForegroundColor Yellow
      Write-Host "pacman.exe -Sc  --noconfirm" -ForegroundColor Yellow
      pacman.exe -Sc  --noconfirm

    }
    $need_refresh = $false
  }
}

Init-AV-Setup

# load r_archs
[int]$temp = $args[0]
if ($temp -eq 32) {
  $dk_b   = 'i686-w64-mingw32'
  $r_plat = 'i386-mingw32' ; $mingw  = 'mingw32'
  $g_plat =  'x86-mingw32' ; $m_pre  = 'mingw-w64-i686-'
  $suf    = ''             ; $DKw    = $DK32w
  $is64   = $false         ; $86_64  = 'x86'
} elseif ($temp -eq 64) {
  $dk_b   = 'x86_64-w64-mingw32'
  $r_plat = 'x64-mingw32'  ; $mingw  = 'mingw64'
  $g_plat = 'x64-mingw32'  ; $m_pre  = 'mingw-w64-x86_64-'
  $suf    = '-x64'         ; $DKw    = $DK64w
  $is64   = $true          ; $86_64  = 'x64'
} else {
  Write-Host "Must specify an platform (32 or 64)!" -ForegroundColor $fc
  exit 1
}

Path-Make $pkgs
