$ErrorActionPreference = 'Stop'

$actionPath = Join-Path $PSScriptRoot '..\action.yml'
$readmePath = Join-Path $PSScriptRoot '..\README.md'
$actionText = Get-Content -LiteralPath $actionPath -Raw
$readmeText = Get-Content -LiteralPath $readmePath -Raw

function Assert-Contains {
  param(
    [string] $Text,
    [string] $Expected,
    [string] $Message
  )

  if (-not $Text.Contains($Expected)) {
    throw "$Message Expected to find: $Expected"
  }
}

function Assert-Equal {
  param(
    [object] $Actual,
    [object] $Expected,
    [string] $Message
  )

  if ($Actual -ne $Expected) {
    throw "$Message Expected: $Expected Actual: $Actual"
  }
}

function Assert-SequenceEqual {
  param(
    [string[]] $Actual,
    [string[]] $Expected,
    [string] $Message
  )

  $actualValue = [string]::Join(', ', $Actual)
  $expectedValue = [string]::Join(', ', $Expected)
  if ($Actual.Count -ne $Expected.Count) {
    throw "$Message Expected: [$expectedValue] Actual: [$actualValue]"
  }

  for ($index = 0; $index -lt $Expected.Count; $index++) {
    if ($Actual[$index] -ne $Expected[$index]) {
      throw "$Message Expected: [$expectedValue] Actual: [$actualValue]"
    }
  }
}

function Assert-Throws {
  param(
    [scriptblock] $Action,
    [string] $Expected
  )

  $failure = $null
  try {
    & $Action | Out-Null
  }
  catch {
    $failure = $_
  }

  if ($null -eq $failure) {
    throw "Expected an error containing: $Expected"
  }
  Assert-Contains -Text $failure.ToString() -Expected $Expected -Message 'The failure must explain what went wrong.'
}

function Get-RunScript {
  param([string] $StepName)

  $lines = Get-Content -LiteralPath $actionPath
  $stepLine = [Array]::FindIndex($lines, [Predicate[string]] {
    param($line)

    $trimmed = $line.Trim()
    return $trimmed -eq "- name: $StepName" -or $trimmed -eq "name: $StepName"
  })
  if ($stepLine -lt 0) {
    throw "Could not find action step '$StepName'."
  }

  $runLine = -1
  for ($index = $stepLine + 1; $index -lt $lines.Count; $index++) {
    if ($lines[$index].StartsWith('  - ')) {
      break
    }
    if ($lines[$index].Trim() -eq 'run: |') {
      $runLine = $index
      break
    }
  }

  if ($runLine -lt 0) {
    throw "Could not find the run block for action step '$StepName'."
  }

  $scriptLines = [System.Collections.Generic.List[string]]::new()
  for ($index = $runLine + 1; $index -lt $lines.Count; $index++) {
    $line = $lines[$index]
    if ($line.StartsWith('  - ') -or $line.StartsWith('    uses:') -or $line.StartsWith('    with:') -or $line.StartsWith('    shell:') -or $line -match '^\S') {
      break
    }
    if ([string]::IsNullOrWhiteSpace($line)) {
      $scriptLines.Add('')
      continue
    }
    if (-not $line.StartsWith('      ')) {
      throw "Unexpected indentation in the '$StepName' run block: $line"
    }
    $scriptLines.Add($line.Substring(6))
  }

  return $scriptLines -join "`n"
}

function Get-GitHubOutputValues {
  param(
    [string] $Text,
    [string] $Name
  )

  $lines = $Text -split "\r?\n"
  for ($index = 0; $index -lt $lines.Count; $index++) {
    $line = $lines[$index]
    if ($line -match "^$([Regex]::Escape($Name))=(?<value>.*)$") {
      if ([string]::IsNullOrEmpty($Matches.value)) {
        return @()
      }
      return @($Matches.value)
    }

    if ($line -match "^$([Regex]::Escape($Name))<<(?<delimiter>.+)$") {
      $values = [System.Collections.Generic.List[string]]::new()
      $delimiter = $Matches.delimiter
      for ($inner = $index + 1; $inner -lt $lines.Count; $inner++) {
        if ($lines[$inner] -eq $delimiter) {
          return $values.ToArray()
        }
        if (-not [string]::IsNullOrEmpty($lines[$inner])) {
          $values.Add($lines[$inner])
        }
      }

      throw "Output '$Name' did not terminate with its delimiter."
    }
  }

  throw "Could not find output '$Name'."
}

function Invoke-ResolveSdkPlan {
  param(
    [object[]] $ReleaseIndexChannels,
    [string[]] $InstalledSdkVersions,
    [bool] $IncludePreview,
    [string] $VersionPrecision = 'major',
    [string] $SdkRoot = 'C:\mock',
    [int] $DotnetExitCode = 0,
    [switch] $DotnetUnavailable
  )

  $resolveScript = Get-RunScript -StepName 'Resolve required .NET SDK versions'
  $resolveScript = $resolveScript.Replace('${{ inputs.includePreview }}', $IncludePreview.ToString().ToLowerInvariant())
  $resolveScript = $resolveScript.Replace(
    '$releaseIndex = Invoke-RestMethod -Uri ''https://raw.githubusercontent.com/dotnet/core/main/release-notes/releases-index.json''',
    '$releaseIndex = $script:mockReleaseIndex'
  )
  if ($DotnetUnavailable) {
    $resolveScript = $resolveScript.Replace('$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue', '$dotnet = $null')
  }

  $script:mockReleaseIndex = [pscustomobject]@{ 'releases-index' = $ReleaseIndexChannels }
  $script:mockDotnetSdkLines = @($InstalledSdkVersions | ForEach-Object { "$_ [$SdkRoot]" })
  $script:mockDotnetExitCode = $DotnetExitCode

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "install-dotnet-contract-$([Guid]::NewGuid().ToString('N'))"
  $outputPath = Join-Path $tempRoot 'github-output.txt'
  New-Item -ItemType Directory -Path $tempRoot | Out-Null

  $previousOutput = $env:GITHUB_OUTPUT
  $previousPrecision = $env:CB_DOTNET_VERSION_PRECISION
  $previousExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
  $existingDotnetFunction = Get-Item -LiteralPath Function:\dotnet -ErrorAction SilentlyContinue
  try {
    $env:GITHUB_OUTPUT = $outputPath
    $env:CB_DOTNET_VERSION_PRECISION = $VersionPrecision
    Set-Content -LiteralPath $outputPath -Value ''

    function dotnet {
      param([Parameter(ValueFromRemainingArguments = $true)] $DotnetArguments)

      if ([string]::Join(' ', $DotnetArguments) -ne '--list-sdks') {
        throw 'The resolver must inspect installed SDKs with dotnet --list-sdks.'
      }
      $global:LASTEXITCODE = $script:mockDotnetExitCode
      return $script:mockDotnetSdkLines
    }

    $messages = @(& { Invoke-Expression $resolveScript } 6>&1)

    $rawOutput = Get-Content -LiteralPath $outputPath -Raw
    return [pscustomobject]@{
      MissingVersions = @(Get-GitHubOutputValues -Text $rawOutput -Name 'missingVersions')
      Log = $messages -join "`n"
    }
  }
  finally {
    if ($null -eq $existingDotnetFunction) {
      Remove-Item -LiteralPath Function:\dotnet -ErrorAction SilentlyContinue
    }
    else {
      Set-Item -LiteralPath Function:\dotnet -Value $existingDotnetFunction.ScriptBlock
    }

    if ($null -eq $previousOutput) {
      Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
    }
    else {
      $env:GITHUB_OUTPUT = $previousOutput
    }
    if ($null -eq $previousPrecision) {
      Remove-Item Env:CB_DOTNET_VERSION_PRECISION -ErrorAction SilentlyContinue
    }
    else {
      $env:CB_DOTNET_VERSION_PRECISION = $previousPrecision
    }
    if ($null -eq $previousExitCode) {
      Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    }
    else {
      $global:LASTEXITCODE = $previousExitCode.Value
    }

    $tempPath = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    if (-not $resolvedTempRoot.StartsWith($tempPath, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to remove contract-test path outside the temporary directory: $resolvedTempRoot"
    }
    Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force

    Remove-Variable -Name mockReleaseIndex -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name mockDotnetSdkLines -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name mockDotnetExitCode -Scope Script -ErrorAction SilentlyContinue
  }
}

$stableAndPreviewChannels = @(
  [pscustomobject]@{
    'channel-version' = '8.0'
    'latest-sdk' = '8.0.425'
    product = '.NET'
    'release-type' = 'lts'
    'support-phase' = 'maintenance'
  },
  [pscustomobject]@{
    'channel-version' = '9.0'
    'latest-sdk' = '9.0.318'
    product = '.NET'
    'release-type' = 'sts'
    'support-phase' = 'maintenance'
  },
  [pscustomobject]@{
    'channel-version' = '10.0'
    'latest-sdk' = '10.0.401'
    product = '.NET'
    'release-type' = 'lts'
    'support-phase' = 'active'
  },
  [pscustomobject]@{
    'channel-version' = '11.0'
    'latest-sdk' = '11.0.100-rc.1.26425.128'
    product = '.NET'
    'release-type' = 'sts'
    'support-phase' = 'go-live'
  },
  [pscustomobject]@{
    'channel-version' = '7.0'
    'latest-sdk' = '7.0.410'
    product = '.NET'
    'release-type' = 'sts'
    'support-phase' = 'eol'
  }
)

$gaOnlyResult = Invoke-ResolveSdkPlan -ReleaseIndexChannels $stableAndPreviewChannels -InstalledSdkVersions @('10.0.401') -IncludePreview:$false
Assert-SequenceEqual -Actual $gaOnlyResult.MissingVersions -Expected @('9.0.318') -Message 'The action must install only the current GA LTS and STS SDKs.'

$previewResult = Invoke-ResolveSdkPlan -ReleaseIndexChannels $stableAndPreviewChannels -InstalledSdkVersions @('9.0.318', '10.0.401') -IncludePreview:$true
Assert-SequenceEqual -Actual $previewResult.MissingVersions -Expected @('11.0.100-rc.1.26425.128') -Message 'The action must install the preview/go-live SDK only when requested.'

$alreadyInstalledResult = Invoke-ResolveSdkPlan -ReleaseIndexChannels $stableAndPreviewChannels -InstalledSdkVersions @('9.0.318', '10.0.401') -IncludePreview:$false
Assert-Equal -Actual $alreadyInstalledResult.MissingVersions.Count -Expected 0 -Message 'The action must skip setup-dotnet when all required GA SDKs are already installed.'

$olderPatches = @('9.0.317', '10.0.400')
$majorResult = Invoke-ResolveSdkPlan -ReleaseIndexChannels $stableAndPreviewChannels -InstalledSdkVersions $olderPatches -IncludePreview:$false
Assert-Equal -Actual $majorResult.MissingVersions.Count -Expected 0 -Message 'The default major precision must reuse older installed patches instead of downloading both SDKs again.'
Assert-Contains -Text $majorResult.Log -Expected 'Version precision: major' -Message 'Diagnostics must identify the matching policy.'
Assert-Contains -Text $majorResult.Log -Expected '10.0.400' -Message 'Diagnostics must identify the actual reused SDK.'

$precisionCases = @(
  @{ Name = 'major accepts another minor'; Precision = 'major'; Installed = @('9.1.100', '10.1.100'); Missing = @() },
  @{ Name = 'minor rejects another minor'; Precision = 'minor'; Installed = @('9.1.100', '10.1.100'); Missing = @('10.0.401', '9.0.318') },
  @{ Name = 'minor accepts older patches and feature bands'; Precision = 'minor'; Installed = @('9.0.100', '10.0.100'); Missing = @() },
  @{ Name = 'patch rejects older patches'; Precision = 'patch'; Installed = $olderPatches; Missing = @('10.0.401', '9.0.318') },
  @{ Name = 'patch rejects newer patches'; Precision = 'patch'; Installed = @('9.0.319', '10.0.402'); Missing = @('10.0.401', '9.0.318') },
  @{ Name = 'patch accepts exact versions'; Precision = 'patch'; Installed = @('9.0.318', '10.0.401'); Missing = @() },
  @{ Name = 'major rejects unrelated majors and textual prefixes'; Precision = 'major'; Installed = @('8.0.425', '90.0.100', '100.0.100'); Missing = @('10.0.401', '9.0.318') },
  @{ Name = 'minor rejects textual prefixes'; Precision = 'minor'; Installed = @('9.01.100', '10.01.100'); Missing = @('10.0.401', '9.0.318') },
  @{ Name = 'major installs only the missing major'; Precision = 'major'; Installed = @('10.0.100'); Missing = @('9.0.318') },
  @{ Name = 'empty SDK inventory installs both GA SDKs'; Precision = 'major'; Installed = @(); Missing = @('10.0.401', '9.0.318') }
)
foreach ($case in $precisionCases) {
  $result = Invoke-ResolveSdkPlan -ReleaseIndexChannels $stableAndPreviewChannels -InstalledSdkVersions $case.Installed -IncludePreview:$false -VersionPrecision $case.Precision
  Assert-SequenceEqual -Actual $result.MissingVersions -Expected $case.Missing -Message $case.Name
}

foreach ($precision in @('major', 'minor', 'patch')) {
  $previewOnlyResult = Invoke-ResolveSdkPlan -ReleaseIndexChannels $stableAndPreviewChannels -InstalledSdkVersions @('9.0.318-preview.1', '10.0.401-rc.1') -IncludePreview:$false -VersionPrecision $precision
  Assert-SequenceEqual -Actual $previewOnlyResult.MissingVersions -Expected @('10.0.401', '9.0.318') -Message 'A preview SDK must never satisfy a GA requirement.'

  $olderPreviewResult = Invoke-ResolveSdkPlan -ReleaseIndexChannels $stableAndPreviewChannels -InstalledSdkVersions @('9.0.318', '10.0.401', '11.0.100-preview.1') -IncludePreview:$true -VersionPrecision $precision
  $expectedPreview = @()
  if ($precision -eq 'patch') {
    $expectedPreview = @('11.0.100-rc.1.26425.128')
  }
  Assert-SequenceEqual -Actual $olderPreviewResult.MissingVersions -Expected $expectedPreview -Message 'Preview matching must follow the requested precision, including the complete prerelease suffix for patch.'
}

$exactPreviewResult = Invoke-ResolveSdkPlan -ReleaseIndexChannels $stableAndPreviewChannels -InstalledSdkVersions @('9.0.318', '10.0.401', '11.0.100-rc.1.26425.128') -IncludePreview:$true -VersionPrecision 'patch'
Assert-Equal -Actual $exactPreviewResult.MissingVersions.Count -Expected 0 -Message 'Patch precision must reuse an exact preview version.'

foreach ($precision in @('major', 'minor')) {
  $stableForPreviewResult = Invoke-ResolveSdkPlan -ReleaseIndexChannels $stableAndPreviewChannels -InstalledSdkVersions @('9.0.318', '10.0.401', '11.0.100') -IncludePreview:$true -VersionPrecision $precision
  Assert-SequenceEqual -Actual $stableForPreviewResult.MissingVersions -Expected @('11.0.100-rc.1.26425.128') -Message 'A stable SDK must not satisfy a preview requirement.'

  $otherMinorPreviewResult = Invoke-ResolveSdkPlan -ReleaseIndexChannels $stableAndPreviewChannels -InstalledSdkVersions @('9.0.318', '10.0.401', '11.1.100-preview.1') -IncludePreview:$true -VersionPrecision $precision
  $expectedPreview = @()
  if ($precision -eq 'minor') {
    $expectedPreview = @('11.0.100-rc.1.26425.128')
  }
  Assert-SequenceEqual -Actual $otherMinorPreviewResult.MissingVersions -Expected $expectedPreview -Message 'Major and minor precision must also differ when matching preview SDKs.'
}

$multipleInstalledResult = Invoke-ResolveSdkPlan -ReleaseIndexChannels $stableAndPreviewChannels -InstalledSdkVersions @('9.0.318', '10.0.99', '10.0.100', '11.0.100-preview.1') -IncludePreview:$false
Assert-Equal -Actual $multipleInstalledResult.MissingVersions.Count -Expected 0 -Message 'Multiple installed versions must not trigger unnecessary installations or opt into previews.'
Assert-Contains -Text $multipleInstalledResult.Log -Expected 'Already installed matching SDKs: 10.0.100, 9.0.318' -Message 'Diagnostics must choose the highest matching installed SDK using numeric version order.'

foreach ($sdkRoot in @('C:\Program Files\dotnet\sdk', '/usr/share/dotnet/sdk', '/usr/local/share/dotnet/sdk')) {
  $pathResult = Invoke-ResolveSdkPlan -ReleaseIndexChannels $stableAndPreviewChannels -InstalledSdkVersions $olderPatches -IncludePreview:$false -SdkRoot $sdkRoot
  Assert-Equal -Actual $pathResult.MissingVersions.Count -Expected 0 -Message "SDK detection must handle paths from each supported OS: $sdkRoot"
}

$missingDotnetResult = Invoke-ResolveSdkPlan -ReleaseIndexChannels $stableAndPreviewChannels -InstalledSdkVersions @() -IncludePreview:$false -DotnetUnavailable
Assert-SequenceEqual -Actual $missingDotnetResult.MissingVersions -Expected @('10.0.401', '9.0.318') -Message 'A runner without dotnet must install the required SDKs.'

foreach ($invalidPrecision in @('', 'latest', 'major.minor')) {
  Assert-Throws -Action { Invoke-ResolveSdkPlan -ReleaseIndexChannels $stableAndPreviewChannels -InstalledSdkVersions @() -VersionPrecision $invalidPrecision } -Expected 'versionPrecision must be one of: major, minor, patch.'
}
Assert-Throws -Action { Invoke-ResolveSdkPlan -ReleaseIndexChannels @() -InstalledSdkVersions @() } -Expected 'Unable to resolve the current GA LTS or STS .NET SDK'
Assert-Throws -Action { Invoke-ResolveSdkPlan -ReleaseIndexChannels $stableAndPreviewChannels -InstalledSdkVersions @('9.0.318', '10.0.401') -DotnetExitCode 42 } -Expected 'dotnet --list-sdks failed with exit code 42'

if ($actionText -notmatch '(?m)^    uses: actions/setup-dotnet@[0-9a-f]{40}(?:\s|$)') {
  throw 'actions/setup-dotnet must be pinned to an immutable SHA.'
}
if ($actionText -notmatch '(?m)^  versionPrecision:\r?\n(?:    .*\r?\n)*?    default: ''major''') {
  throw 'versionPrecision must default to major in the action metadata.'
}
Assert-Contains -Text $actionText -Expected 'CB_DOTNET_VERSION_PRECISION: ${{ inputs.versionPrecision }}' -Message 'The selected precision must reach the resolver through an environment variable.'
Assert-Contains -Text $actionText -Expected "if: steps.resolveSdkPlan.outputs.missingVersions != ''" -Message 'setup-dotnet must run only when SDKs are missing.'
Assert-Contains -Text $actionText -Expected "Where-Object { `$_.'release-type' -eq 'lts' }" -Message 'The action must resolve the current LTS channel dynamically.'
Assert-Contains -Text $actionText -Expected "Where-Object { `$_.'release-type' -eq 'sts' }" -Message 'The action must resolve the current STS channel dynamically.'
Assert-Contains -Text $actionText -Expected "Where-Object { `$_.'support-phase' -in `$previewSupportPhases }" -Message 'Preview selection must be limited to preview/go-live channels.'
Assert-Contains -Text $readmeText -Expected 'current GA LTS and STS channels' -Message 'README must describe the dynamic current-channel behavior.'
Assert-Contains -Text $readmeText -Expected 'preview/go-live' -Message 'README must describe preview/go-live behavior.'
Assert-Contains -Text $readmeText -Expected 'versionPrecision' -Message 'README must document the precision input.'
Assert-Contains -Text $readmeText -Expected 'For applications, we recommend `patch`' -Message 'README must recommend patch precision for applications.'
Assert-Contains -Text $readmeText -Expected 'For libraries and other uses, keep the default `major`' -Message 'README must recommend the default for other uses.'

Write-Host 'install-dotnet action contract passed.'
