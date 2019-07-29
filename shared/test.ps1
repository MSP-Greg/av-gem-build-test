# PowerShell script for testing of fat binary gems
# This script is utility script, and should not require changes for any gems
# Code by MSP-Greg, see https://github.com/MSP-Greg/av-gem-build-test

if ($exit_code) { exit $exit_code }

function Init-Test {
  Make-Vari log_name      ''         # executing ruby build test log file
  Make-Vari test_results  ''         # text of above file
  Make-Vari test_summary  ''         # summary of results

  Make-Vari ruby_desc     ''         # string like trunk-x64 or ruby25-x64
  Make-Vari ruby_v        ''         # output of ruby -v
  Make-Vari ruby_v_a      nil        # above split into array
  Make-Vari fail_error_re ''         # regex used to find failure & error text in test output
  Make-Vari fail_error_summary  ''

  Make-Vari test_trunk               # true if trunk should be tested
  Make-Vari test_trunk_jit           # true if trunk with JIT should be tested
  Make-Vari test_use                 # true if trunk tests results fail build

  $dt = Get-Date -UFormat "%Y-%m-%d_%H-%M"
}

#————————————————————————————————————————————————————————————————————————————————— Get-Secs
# parses $test_results and returns Sec time, rounded to 0.1 sec
function Get-Secs {
  if ($test_results -match "(?ms)^Finished in (\d+\.\d{2})" ) {
    return [math]::Round([float]$matches[1],1)
  } else { return ''}
}

#————————————————————————————————————————————————————————————————————————————————— Get-MS
# parses $test_results and returns mS time, rounded to 1k (seconds)
function Get-MS {
  if ($test_results -match "(?ms)^Finished in (\d+\.\d{2})" ) {
    return [int]([math]::Round([float]$matches[1]) * 1000)
  } else { return $null}
}

#————————————————————————————————————————————————————————————————————————————————— Get-Std-Out
# parses $test_results into string for Add-AppveyorTest -StdOut
# as of 2018-06, limit is about 4k characters
function Get-Std-Out {
  $stdout = if ($test_results.length -le 4000) {
    $test_results
  } elseif ($test_results -match "(?ms)^Finished in \d+\.\d{3}.+" ) {
    $matches[0]
  } else {
    $test_results.Substring($test_results.length - 4000)
  }
  return $stdout
}

#————————————————————————————————————————————————————————————————————————————————— Process-Log
# parses log, adds ruby -v & $commit_info, removes gem path, sets to $test_results
function Process-Log {
  Write-Host $ruby_v
  Write-Host $commit_info
  $gem_full_path = "$gem_dflt/gems/$gem_full_name/"
  if (Test-Path -Path $log_name -PathType leaf) {
    $test_results = [System.Io.File]::ReadAllText($log_name, $UTF8)
    $test_results +=  "$ruby_v`n$gem_full_name`n$commit_info`n"
    $test_results = $test_results.replace("[$gem_full_path", "[")
    $test_results = $test_results.replace($gem_full_path, "    ").replace("`r", "")
  } else {
    $test_results = "Failure - testing aborted?`n$ruby_v`n$commit_info`n"
  }
  [IO.File]::WriteAllText($log_name, $test_results, $UTF8)
}

#————————————————————————————————————————————————————————————————————————————————— AV-Test
# adds a test result to Appveyor job page using Add-AppveyorTest
function AV-Test($outcome) {
  $std_out = Get-Std-Out
  if ($outcome -eq 'Failed') {
    $oc = if (!$test_use) { 'Ignored' } else { 'Failed' }
    Add-AppveyorTest -Name $ruby_desc -Outcome $oc `
      -StdOut $std_out -Framework "ruby" -FileName $gem_full_name
  } else {
    $oc = if ($outcome -eq 0) {'Passed'} elseif (!$test_use) {'Ignored'} else {'Failed'}
    $ms = Get-MS
    Add-AppveyorTest -Name $ruby_desc -Outcome $oc -Duration $ms `
      -StdOut $std_out -Framework "ruby" -FileName $gem_full_name
  }
}

function Add-Fail-Error {
  if ($fail_error_summary -eq '') {
    $fail_error_summary = "$gem_full_name`n$commit_info`n"
  }

  $ri = " {0,-11} {1,-15} ({2}`n" -f (@(Ruby-Desc) + $ruby_v_a)
  $fail_error_summary += "`n" + "$ri".PadLeft(85, $dash) + "`n"

  $ary_fail_error = $test_results | Select-String $fail_error_re -AllMatches |
    Foreach-Object {$_.Matches} | Foreach-Object {$_.Groups[1].Value}

  $fail_error_summary += $ary_fail_error -join "`n"
}

#————————————————————————————————————————————————————————————— minitest results parser
function minitest {
  Process-Log
  if ($test_summary -eq '') {
    $test_summary   = " Runs  Asserts  Fails  Errors  Skips  Secs  Ruby"
  }

  $fail_error_re = '(?ms)(^ {0,2}\d+\) (:?Failure: |Error: ).+?)(?=(^ {0,2}\d+\) (Failure: |Error: |Skipped: )|^\d+ runs,))'

  if ($test_results -match "(?m)^\d+ runs.+ skips" -and !$test_results.StartsWith('Failure')) {
    $ary = ($matches[0] -replace "[^\d]+", ' ').Trim().Split(' ')
    $errors_fails = [int]$ary[2] + [int]$ary[3]
    if ($errors_fails -ne 0) { Add-Fail-Error }
    if ($in_av) { AV-Test $errors_fails }
    if ($test_use) { $ttl_errors_fails += $errors_fails }
    $ary += @($(Get-Secs), $(Ruby-Desc)) + $ruby_v_a
    $test_summary += "`n{0,4:n}    {1,4:n}   {2,4:n}    {3,4:n}    {4,4:n} {5,6:n1}  {6,-11} {7,-15} ({8}" -f $ary
  } else {
    if ($in_av) { AV-Test 'Failed' }
    if ($test_use) { $ttl_errors_fails += 1000 }
    $ary = @($(Ruby-Desc)) + $ruby_v_a
    $test_summary += "`n *** testing aborted? ***                   {0,-11} {1,-15} ({2}" -f $ary
  }
}

function rspec {
  Process-Log
  if ($test_summary -eq '') {
    $test_summary   = "Examples  Fails   Secs   Ruby"
  }
  if ($test_results -match "(?m)^\d+ examples, \d+ failures") {
    $ary = ($matches[0] -replace "[^\d]+", ' ').Trim().Split(' ')
    $errors_fails = [int]$ary[1]
    if ($in_av) { AV-Test $errors_fails }
    if ($test_use) { $ttl_errors_fails += $errors_fails }
    $ary += @($(Get-Secs), $(Ruby-Desc)) + $ruby_v_a
    $test_summary += "`n  {0,4:n}    {1,4:n}   {2,6:n1}  {3,-11} {4,-15} ({5}" -f $ary
  } else {
    if ($in_av) { AV-Test 'Failed' }
    if ($test_use) { $ttl_errors_fails += 1000 }
    $ary = @($(Ruby-Desc)) + $ruby_v_a
    $test_summary += "`ntesting aborted?                      {0,-11} {1,-15} ({2}" -f $ary
  }
}

#————————————————————————————————————————————————————————————— test-unit results parser
function test_unit {
  Process-Log
  if ($test_summary -eq '') {
    $test_summary    = "Tests  Asserts  Fails  Errors  Pend  Omitted  Notes  Secs  Ruby"
  }

  $fail_error_re = '(?ms)(^ {0,2}\d+\) (:?Failure: |Error: ).+?)(?=(^ {0,2}\d+\) (Failure: |Error: |Pending: )|^Omissions:))'

  if ($test_results -match "(?m)^\d+ tests.+ notifications") {
    $ary = ($matches[0] -replace "[^\d]+", ' ').Trim().Split(' ')
    $errors_fails = [int]$ary[2] + [int]$ary[3]
    if ($errors_fails -ne 0) { Add-Fail-Error }
    if ($in_av) { AV-Test $errors_fails }
    if ($test_use) { $ttl_errors_fails += $errors_fails }
    $ary += @($(Get-Secs), $(Ruby-Desc)) + $ruby_v_a
    $test_summary += "`n{0,4:n}    {1,4:n}   {2,4:n}    {3,4:n}   {4,4:n}    {5,4:n}   {6,4:n}  {7,6:n1}  {8,-11} {9,-15} ({10}" -f $ary
  } else {
    if ($in_av) { AV-Test 'Failed' }
    if ($test_use) { $ttl_errors_fails += 1000 }
    $ary = @($(Ruby-Desc)) + $ruby_v_a
    $test_summary += "`ntesting aborted?                                             {0,-11} {1,-15} ({2}" -f $ary
  }
}

#————————————————————————————————————————————————————————————— Find-Gem
# locates gem if $gem_file_name isn't set, which happens when
# make.ps1 (for testing)
function Find-Gem {
  # if make.ps1 is bypassed, get commit_info and try to find gem name
  if ($commit_info -eq $null) {
    Push-Location $dir_gem
    $commit_info = $(git.exe log -1 --pretty=format:'%ci   %h   %s')
    Pop-Location
  }

  if ($gem_file_name -eq '' -or $gem_file_name -eq $null) {
    $match = $dir_gem + '\'+ $gem_name + '-*-' + $g_plat + '.gem'
    $t = $(Get-ChildItem -Path $match | Sort-Object -Descending LastWriteTime | select -expand Name)
    $gem_file_name = if ($t -is [array]) { $t[0] } else { $t }
    $gem_full_name = $gem_file_name -Replace "\.gem$", ""
  }

  $fn = $dir_gem + '\' + $gem_file_name

  if( ($gem_file_name -eq $null) -or !(Test-Path -Path $fn -PathType Leaf) ) {
    Write-Host "Gem $gem_file_name not found!" -ForegroundColor $fc
    $exit_code = 1
    exit 1
  }
  return $fn

}

#————————————————————————————————————————————————————————————————————————————————— Main
$gem_full_path = Find-Gem

Init-Test

Path-Make $dir_ps\test_logs
del $dir_ps\test_logs\*.txt

if ($is64) {
  $test_trunk     = $trunk_x64     -ne $null
  $test_trunk_jit = $trunk_x64_jit -ne $null
} else {
  $test_trunk     = $trunk     -ne $null
  $test_trunk_jit = $trunk_jit -ne $null
}

Load-Rubies
foreach ($ruby in $rubies) {
  # Loop if ruby version does not exist
  if ( !(Test-Path -Path $dir_ruby$ruby$suf -PathType Container) ) { continue }

  if ($ruby -ne '99' -and $env:RUBYOPT) {
    Remove-Item Env:\RUBYOPT
  }

  Check-SetVars

  $ruby_desc = Ruby-Desc

  $orig_path = ''
  $loops = if ($ruby -eq '99' -and $test_trunk -and $test_trunk_jit )
    { @(1,2) } else { @(1) }

  foreach ($loop in $loops) {
    if ($loop -eq 1) {
      if ($ruby -eq '99' -and $test_trunk_jit) {
        $ruby_desc += '-JIT'
        $env:RUBYOPT = '--jit'
        $orig_path = $env:path
        $env:path += ";$msys2\$mingw\bin;$msys2\usr\bin;"
      }
    } else {
      if ($env:RUBYOPT) { Remove-Item Env:\RUBYOPT }
      $ruby_desc = Ruby-Desc
      $env:path = $orig_path
    }

    $test_use = switch ($ruby_desc) {
      'trunk'         { $trunk         }
      'trunk-JIT'     { $trunk_jit     }
      'trunk-x64'     { $trunk_x64     }
      'trunk-x64-JIT' { $trunk_x64_jit }
      default         { $true          }
    }

    Write-Host "`n$($dash * 75) Testing $ruby_desc" -ForegroundColor $fc
    if ($loop -eq 1) {
      if (Get-Command Pre-Gem-Install -errorAction SilentlyContinue) { Pre-Gem-Install }
      if (!$in_av)  { gem uninstall $gem_name -x -a }
      # windows user install may have space in path, tests fail...
      $o = $(gem install -N --no-user-install $gem_full_path 2>&1)
      Write-Host $o
    }

    # Find where gem was installed - default or user
    $rake_dir = $gem_dflt + '/gems/' + $gem_full_name
    if ( !(Test-Path -Path $rake_dir -PathType Container) ) {
      $rake_dir = "$gem_user/gems/$gem_full_name"
      if ( !(Test-Path -Path $rake_dir -PathType Container) ) {
        Write-Host "Improper gem installation!" -ForegroundColor $fc
        continue
      }
    }
    $ruby_v = ruby.exe -v
    $ruby_v_a = [regex]::split( $ruby_v.Replace(" [$r_plat]", '').Trim(), ' \(')
    $log_name = "$dir_ps\test_logs\$ruby_desc.txt"
    ruby.exe -v
    Push-Location $rake_dir
    Run-Tests
    if ($LastExitCode -and $LastExitCode -ne 0) {
      Write-Host "**************************  TESTS FAILED" -ForegroundColor $fc
    }
    Pop-Location
  }
}

$details =  " $gem_full_name Test Summary".PadLeft(85, $dash)
$details += "`n$test_summary"
$details += "`n`nCommit Info: $commit_info`n"
[IO.File]::WriteAllText("$dir_ps\test_logs\summary_test_results.txt", $details, $UTF8)

if ($fail_error_summary -ne '') {
  [IO.File]::WriteAllText("$dir_ps\test_logs\summary_fail_error.txt", $fail_error_summary, $UTF8)
}


# collect all log files
$fn_log = "$dir_ps\test_logs\test_logs-$g_plat" + ".7z"
&$7z a $fn_log $dir_ps\test_logs\*.txt 1> $null
# below are for date stamped file names
#$dt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd_HH-mm")
#$fn_log = "$dir_ps\test_logs\test_logs-$g_plat-$dt" + ".7z"

if ($in_av) {
  Push-AppveyorArtifact $fn_log
  $msg = if ($suf -eq '') { "Test Summary 32 bit" } else { "Test Summary 64 bit" }
  Add-AppveyorMessage -Message $msg -Details $details
}

# write test summary info at end of testing
$txt = " $gem_full_name Test Summary".PadLeft(85, $dash)
Write-Host "`n$txt" -ForegroundColor $fc
Write-Host $test_summary
Write-Host ($dash * 85) -ForegroundColor $fc
Write-Host "`nCommit Info: $commit_info`n" -ForegroundColor $fc
