# PowerShell script for testing of fat binary gems
# This script is utility script, and should not require changes for any gems
# Code by MSP-Greg, see https://github.com/MSP-Greg/av-gem-build-test

if ($exit_code -ne 0) { exit $exit_code }

Make-Vari log_name      ''
Make-Vari test_results  ''
Make-Vari test_summary  ''
Make-Vari gem_full      ''

$dt = Get-Date -UFormat "%Y-%m-%d_%H-%M"

#————————————————————————————————————————————————————————————————————————————————— Get-MS
# parses $test_results and returns mS time, rounded to 1k
function Get-MS {
  if ($test_results -match "(?ms)^Finished in (\d+\.\d{3})" ) {
    return [int]([math]::Round([float]$matches[1]) * 1000)
  } else { return $null}
}

#————————————————————————————————————————————————————————————————————————————————— Get-Std-Out
# parses $test_results into string for Add-AppveyorTest -StdOut
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
  ruby -v      | Add-Content -Path $log_name -PassThru -Encoding UTF8
  $commit_info | Add-Content -Path $log_name -PassThru -Encoding UTF8
  (Get-Content $log_name).replace("$gem_dflt/gems/", "") | Set-Content $log_name -Encoding UTF8
  $test_results = [System.Io.File]::ReadAllText($log_name)
}

#————————————————————————————————————————————————————————————————————————————————— AV-Test
# adds a test result to Appveyor job page using Add-AppveyorTest
function AV-Test($outcome) {
  $std_out = Get-Std-Out
  if ($outcome -eq 'Failed') {
    Add-AppveyorTest -Name "Ruby$ruby$suf" -Outcome 'Failed' `
      -StdOut $std_out -Framework "ruby" -FileName $gem_full_name
  } else {
    $oc = if ($outcome -eq 0) {'Passed'} else {'Failed'}
    $ms = Get-MS
    Add-AppveyorTest -Name $(Ruby-Desc) -Outcome $oc -Duration $ms `
      -StdOut $std_out -Framework "ruby" -FileName $gem_full_name
  }
}

#————————————————————————————————————————————————————————————— minitest results parser
function minitest {
  Process-Log
  if ($test_summary -eq '') {
    $test_summary   = " Runs  Asserts  Fails  Errors  Skips  Ruby"
  }

  if ($test_results -match "(?m)^\d+ runs.+ skips") {
    $ary = ($matches[0] -replace "[^\d]+", ' ').Trim().Split(' ')
    $errors_fails = [int]$ary[2] + [int]$ary[3]
    if ($in_av) { AV-Test $errors_fails }
    $ttl_errors_fails += $errors_fails
    $ary += @($(Ruby-Desc)) + $ruby_v
    $test_summary += "`n{0,4:n}    {1,4:n}   {2,4:n}    {3,4:n}    {4,4:n}   {5,-11} {6,-15} ({7}" -f $ary
  } else {
    if ($in_av) { AV-Test 'Failed' }
    $ttl_errors_fails += 1000
    $ary = @("Ruby$ruby$suf") + $ruby_v
    $test_summary += "`ntesting aborted?                      {0,-11} {1,-15} ({2}" -f $ary
  }
}

#————————————————————————————————————————————————————————————— test-unit results parser
function test_unit {
  Process-Log

  if ($test_summary -eq '') {
    $test_summary    = "Tests  Asserts  Fails  Errors  Pend  Omitted  Notes  Ruby"
  }

  $results =
  if ($test_results -match "(?m)^\d+ tests.+ notifications") {
    $ary = ($matches[0] -replace "[^\d]+", ' ').Trim().Split(' ')
    $errors_fails = [int]$ary[2] + [int]$ary[3]
    if ($in_av) { AV-Test $errors_fails }
    $ttl_errors_fails += $errors_fails
    $ary += @($(Ruby-Desc)) + $ruby_v
    $test_summary += "`n{0,4:n}    {1,4:n}   {2,4:n}    {3,4:n}   {4,4:n}    {5,4:n}   {6,4:n}    {7,-11} {8,-15} ({9}" -f $ary
  } else {
    if ($in_av) { AV-Test 'Failed' }
    $ary = @("Ruby$ruby$suf") + $ruby_v
    $ttl_errors_fails += 1000
    $test_summary += "`ntesting aborted?                                     {0,-11} {1,-15} ({2}" -f $ary
  }
}

#————————————————————————————————————————————————————————————————————————————————— Main

# create test log folder
if (Test-Path -Path $dir_ps\test_logs -PathType Container) {
  Remove-Item $dir_ps\test_logs\*.txt
} else {
  New-Item -Path $dir_ps\test_logs -ItemType Directory 1> $null
}

$fn = $dir_gem + '/' + $gem_file_name

Load-Rubies
foreach ($ruby in $rubies) {
  # Loop if ruby version does not exist
  if ( !(Test-Path -Path $dir_ruby$ruby$suf -PathType Container) ) { continue }

  Check-SetVars

  Write-Host "`n$($dash * 75) Testing $(Ruby-Desc)" -ForegroundColor $fc
  if ( !($in_av) ) { gem uninstall $gem_name -x -a }
  gem install $fn -Nl

  # Find where gem was installed - default or user
  $rake_dir = $gem_dflt + '/gems/' + $gem_full_name
  if ( !(Test-Path -Path $rake_dir -PathType Container) ) {
    $rake_dir = "$gem_user/gems/$gem_full_name"
    if ( !(Test-Path -Path $rake_dir -PathType Container) ) { continue }
  }

  $ruby_v = [regex]::split( (ruby.exe -v | Out-String).Replace(" [$r_plat]", '').Trim(), ' \(')
  $log_name = "$dir_ps\test_logs\$(Ruby-Desc)" + ".txt"
  ruby.exe -v
  Push-Location $rake_dir
  Run-Tests
  Pop-Location
}

# collect all log files
$fn_log = "$dir_ps\test_logs\test_logs-$g_plat" + ".7z"
&$7z a $fn_log $dir_ps\test_logs\*.txt 1> $null
# below are for date stamped file names
#$dt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd_HH-mm")
#$fn_log = "$dir_ps\test_logs\test_logs-$g_plat-$dt" + ".7z"

if ($in_av) { Push-AppveyorArtifact $fn_log }

# write test summary info at end of testing
Write-Host "`n$($dash * 50) $gem_full_name Test Summary" -ForegroundColor $fc
Write-Host $test_summary
Write-Host ($dash * 88) -ForegroundColor $fc
Write-Host "`nCommit Info: $commit_info`n" -ForegroundColor $fc
