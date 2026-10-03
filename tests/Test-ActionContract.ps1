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
    [bool] $IncludePreview
  )

  $resolveScript = Get-RunScript -StepName 'Resolve required .NET SDK versions'
  $resolveScript = $resolveScript.Replace('${{ inputs.includePreview }}', $IncludePreview.ToString().ToLowerInvariant())
  $resolveScript = $resolveScript.Replace(
    '$releaseIndex = Invoke-RestMethod -Uri ''https://raw.githubusercontent.com/dotnet/core/main/release-notes/releases-index.json''',
    '$releaseIndex = $script:mockReleaseIndex'
  )

  $script:mockReleaseIndex = [pscustomobject]@{ 'releases-index' = $ReleaseIndexChannels }
  $script:mockDotnetSdkLines = @($InstalledSdkVersions | ForEach-Object { "$_ [C:\mock]" })

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "install-dotnet-contract-$([Guid]::NewGuid().ToString('N'))"
  $outputPath = Join-Path $tempRoot 'github-output.txt'
  New-Item -ItemType Directory -Path $tempRoot | Out-Null

  $previousOutput = $env:GITHUB_OUTPUT
  $existingDotnetFunction = Get-Item -LiteralPath Function:\dotnet -ErrorAction SilentlyContinue
  try {
    $env:GITHUB_OUTPUT = $outputPath
    Set-Content -LiteralPath $outputPath -Value ''

    function dotnet {
      param([Parameter(ValueFromRemainingArguments = $true)] $DotnetArguments)

      return $script:mockDotnetSdkLines
    }

    & { Invoke-Expression $resolveScript }

    $rawOutput = Get-Content -LiteralPath $outputPath -Raw
    return [pscustomobject]@{
      MissingVersions = @(Get-GitHubOutputValues -Text $rawOutput -Name 'missingVersions')
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

    $tempPath = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    if (-not $resolvedTempRoot.StartsWith($tempPath, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to remove contract-test path outside the temporary directory: $resolvedTempRoot"
    }
    Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force

    Remove-Variable -Name mockReleaseIndex -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name mockDotnetSdkLines -Scope Script -ErrorAction SilentlyContinue
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

Assert-Contains -Text $actionText -Expected 'actions/setup-dotnet@26b0ec14cb23fa6904739307f278c14f94c95bf1 # v5' -Message 'actions/setup-dotnet must be pinned to an immutable SHA.'
Assert-Contains -Text $actionText -Expected "Where-Object { `$_.'release-type' -eq 'lts' }" -Message 'The action must resolve the current LTS channel dynamically.'
Assert-Contains -Text $actionText -Expected "Where-Object { `$_.'release-type' -eq 'sts' }" -Message 'The action must resolve the current STS channel dynamically.'
Assert-Contains -Text $actionText -Expected "Where-Object { `$_.'support-phase' -in `$previewSupportPhases }" -Message 'Preview selection must be limited to preview/go-live channels.'
Assert-Contains -Text $readmeText -Expected 'current GA LTS and STS channels' -Message 'README must describe the dynamic current-channel behavior.'
Assert-Contains -Text $readmeText -Expected 'preview/go-live' -Message 'README must describe preview/go-live behavior.'

Write-Host 'install-dotnet action contract passed.'
