# Install .NET SDK

Install the current [LTS and STS versions](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core) of the .NET SDK with optional support for the current preview/go-live SDK. The action resolves the current GA LTS and STS channels from [.NET releases-index.json](https://github.com/dotnet/core/blob/main/release-notes/releases-index.json) and reuses installed SDKs with the same major version by default. When no installed SDK satisfies the selected precision, it installs the latest exact SDK version for that channel using the official [setup-dotnet action](https://github.com/actions/setup-dotnet). Preview support is resolved only from `preview`/`go-live` channels when requested.

> This action is part of the Codebelt umbrella and ensures a consistent way of: 
> 
> - Defining your CI/CD pipeline 
> - Structuring your repository
> - Keeping your codebase small and feasible
> - Writing clean and maintainable code
> - Deploying your code to different environments
> - Automating as much as possible
>
> A paved path to excel as a DevSecOps Engineer.

## Usage

To use this action in your GitHub repository, you can follow these steps:

```yaml
uses: codebeltnet/install-dotnet@v3
```

### Inputs

```yaml
with:
  # Match installed SDKs by major (default), minor, or patch.
  versionPrecision: 'major'
  # Whether to include the current preview/go-live .NET SDK or not. Default is to exclude preview versions.
  includePreview: 'false'
```

### Choosing version precision

For applications, we recommend `patch` so the action ensures the latest exact SDK versions resolved from Microsoft's release index are installed. For libraries and other uses, keep the default `major` to reuse the SDKs already provided by the runner and avoid unnecessary installations.

| `versionPrecision` | Installed SDK requirement | Example when the resolved SDK is `10.0.403` |
| --- | --- | --- |
| `major` (default) | Same major version | Reuses `10.0.401` or `10.1.100` |
| `minor` | Same major and minor version | Reuses `10.0.401`; installs `10.0.403` if only `10.1.100` is present |
| `patch` | Exact resolved SDK version | Reuses only `10.0.403` |

All three modes install the latest resolved version when a matching SDK is absent. `patch` preserves the previous exact-match behavior; it follows the release index over time rather than pinning a fixed SDK version. `major` and `minor` accept installed versions that are older or newer than the resolved version within the matching range.

Stable SDK requirements never accept prerelease SDKs. With `includePreview: 'true'`, the same precision applies to the current preview/go-live requirement: `major` and `minor` may reuse an older prerelease, while `patch` requires the full resolved prerelease version, including its suffix. A stable SDK does not satisfy a preview requirement.

This input controls installation, not which SDK the .NET CLI selects or which runtime an application uses. A repository's [`global.json`](https://learn.microsoft.com/en-us/dotnet/core/tools/global-json) still controls SDK selection, including version and roll-forward constraints. Without it, the CLI normally selects the highest installed SDK, including previews. Use a compatible `global.json` policy with `major` or `minor`; `patch` does not automatically install a different historical version pinned by that file. This action does not modify `global.json` or manage deployment runtime versions, and matching by major does not promise identical build output across SDK versions.

### Outputs

This action has no outputs.

## Examples

### Install the current GA LTS and STS .NET SDKs

```yaml
steps:
  - name: Install .NET
    uses: codebeltnet/install-dotnet@v3
```

### Install the current GA SDKs plus the current preview/go-live SDK

```yaml
steps:
  - name: Install .NET
    uses: codebeltnet/install-dotnet@v3
    with:
      includePreview: 'true'
```

### Ensure the latest exact SDK versions for an application

```yaml
steps:
  - name: Install .NET
    uses: codebeltnet/install-dotnet@v3
    with:
      versionPrecision: 'patch'
```

### Reuse installed SDKs within the current major/minor channels

```yaml
steps:
  - name: Install .NET
    uses: codebeltnet/install-dotnet@v3
    with:
      versionPrecision: 'minor'
```

### Sample workflow for .NET Class Library

```yaml
name: Generic CI/CD Pipeline (.NET Library)
on:
  push:
    branches: [main]
    paths-ignore:
      - .codecov
      - .docfx
      - .github
      - .nuget
  pull_request:
    branches: [main]
  workflow_dispatch:
    inputs:
      configuration:
        type: choice
        description: The build configuration to use in the deploy stage.
        required: true
        default: Release
        options:
          - Debug
          - Release

jobs:
  build:
    name: 🛠️ Build
    runs-on: ubuntu-26.04
    outputs:
      version: ${{ steps.minver-calculate.outputs.version }}
    steps:
      - name: Checkout
        uses: codebeltnet/git-checkout@v1

      - name: Install .NET
        uses: codebeltnet/install-dotnet@v3

      - name: Install MinVer
        uses: codebeltnet/dotnet-tool-install-minver@v1

      - id: minver-calculate
        name: Calculate Version
        uses: codebeltnet/minver-calculate@v1

      - name: Download strongname.snk file
        uses: codebeltnet/gcp-download-file@v1
        with: 
          serviceAccountKey: ${{ secrets.GCP_TOKEN }}
          bucketName: ${{ secrets.GCP_BUCKETNAME }}
          objectName: strongname.snk

      - name: Restore Dependencies
        uses: codebeltnet/dotnet-restore@v1

      - name: Build for Preview
        uses: codebeltnet/dotnet-build@v1
        with:
          configuration: Debug

      - name: Build for Production
        uses: codebeltnet/dotnet-build@v1
        with:
          configuration: Release

  pack:
    name: 📦 Pack
    runs-on: ubuntu-26.04
    strategy:
      matrix:
        configuration: [Debug, Release]
    needs: [build]
    steps:     
      - name: Pack for ${{ matrix.configuration }}
        uses: codebeltnet/dotnet-pack@v1
        with:
          configuration: ${{ matrix.configuration }}
          uploadPackedArtifact: true
          version: ${{ needs.build.outputs.version }}

  test:
    name: 🧪 Test
    needs: [build]
    strategy:
      matrix:
        os: [ubuntu-26.04, windows-2025]
    runs-on: ${{ matrix.os }}
    steps:
      - name: Checkout
        uses: codebeltnet/git-checkout@v1

      - name: Install .NET
        uses: codebeltnet/install-dotnet@v3

      - name: Install .NET Tool - Report Generator
        uses: codebeltnet/dotnet-tool-install-reportgenerator@v1

      - name: Test with Debug build
        uses: codebeltnet/dotnet-test@v1
        with:
          configuration: Debug
          buildSwitches: -p:SkipSignAssembly=true

      - name: Test with Release build
        uses: codebeltnet/dotnet-test@v1
        with:
          configuration: Release
          buildSwitches: -p:SkipSignAssembly=true

  sonarcloud:
    name: 🔬 Code Quality Analysis
    needs: [build,test]
    runs-on: ubuntu-22.04
    steps:
      - name: Checkout
        uses: codebeltnet/git-checkout@v1

      - name: Install .NET
        uses: codebeltnet/install-dotnet@v3

      - name: Install .NET Tool - Sonar Scanner
        uses: codebeltnet/dotnet-tool-install-sonarscanner@v1

      - name: Restore Dependencies
        uses: codebeltnet/dotnet-restore@v1

      - name: Run SonarCloud Analysis
        uses: codebeltnet/sonarcloud-scan@v1
        with:
          token: ${{ secrets.SONAR_TOKEN }}
          organization: your-sonarcloud-organization
          projectKey: your-sonarcloud-project-key
          version: ${{ needs.build.outputs.version }}

      - name: Build
        uses: codebeltnet/dotnet-build@v1
        with:
          buildSwitches: -p:SkipSignAssembly=true
          uploadBuildArtifact: false

      - name: Finalize SonarCloud Analysis
        uses: codebeltnet/sonarcloud-scan-finalize@v1
        with:
          token: ${{ secrets.SONAR_TOKEN }}

  codecov:
    name: 📊 Code Coverage Analysis
    needs: [build,test]
    runs-on: ubuntu-22.04
    steps:
      - name: Checkout
        uses: codebeltnet/git-checkout@v1

      - name: Run CodeCov Analysis
        uses: codebeltnet/codecov-scan@v1
        with:
          token: ${{ secrets.CODECOV_TOKEN }}
          repository: your-github-repository
          
  codeql:
    name: 🛡️ Security Analysis
    needs: [build,test]
    runs-on: ubuntu-22.04
    steps:
      - name: Checkout
        uses: codebeltnet/git-checkout@v1

      - name: Install .NET
        uses: codebeltnet/install-dotnet@v3

      - name: Restore Dependencies
        uses: codebeltnet/dotnet-restore@v1

      - name: Prepare CodeQL SAST Analysis
        uses: codebeltnet/codeql-scan@v1

      - name: Build
        uses: codebeltnet/dotnet-build@v1
        with:
          buildSwitches: -p:SkipSignAssembly=true
          uploadBuildArtifact: false

      - name: Finalize CodeQL SAST Analysis
        uses: codebeltnet/codeql-scan-finalize@v1

  deploy:
    name: 🚀 Deploy v${{ needs.build.outputs.version }}
    runs-on: ubuntu-22.04
    needs: [build,pack,test,sonarcloud,codecov,codeql]
    environment: Production
    steps:
      - uses: codebeltnet/nuget-push@v1
        with:
          token: ${{ secrets.NUGET_TOKEN }}
          configuration: ${{ inputs.configuration == '' && 'Release' || inputs.configuration }}

```

## Contributing to Install .NET SDK

Contributions are welcome! 
Feel free to submit issues, feature requests, or pull requests to help improve this action.

### License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

### Other Actions

:bookmark: [Analyze with Codecov](https://github.com/codebeltnet/codecov-scan)\
:bookmark: [Analyze with CodeQL](https://github.com/codebeltnet/codeql-scan)\
:bookmark: [Finalyze with CodeQL](https://github.com/codebeltnet/codeql-scan-finalize)\
:bookmark: [Docker Compose](https://github.com/codebeltnet/docker-compose)\
:bookmark: [.NET Build](https://github.com/codebeltnet/dotnet-build)\
:bookmark: [.NET Pack](https://github.com/codebeltnet/dotnet-pack)\
:bookmark: [.NET Restore](https://github.com/codebeltnet/dotnet-restore)\
:bookmark: [.NET Test](https://github.com/codebeltnet/dotnet-test)\
:bookmark: [Install .NET SDK](https://github.com/codebeltnet/install-dotnet)\
:bookmark: [Install .NET Tool - MinVer](https://github.com/codebeltnet/dotnet-tool-install-minver)\
:bookmark: [Install .NET Tool - Report Generator](https://github.com/codebeltnet/dotnet-tool-install-reportgenerator)\
:bookmark: [Install .NET Tool - Sonar Scanner](https://github.com/codebeltnet/dotnet-tool-install-sonarscanner)\
:bookmark: [GCP Download File](https://github.com/codebeltnet/gcp-download-file)\
:bookmark: [Git Checkout](https://github.com/codebeltnet/git-checkout)\
:bookmark: [MinVer Calculate](https://github.com/codebeltnet/minver-calculate)\
:bookmark: [NuGet Push](https://github.com/codebeltnet/nuget-push)\
:bookmark: [Shell Globbing](https://github.com/codebeltnet/shell-globbing)\
:bookmark: [Analyze with SonarCloud](https://github.com/codebeltnet/sonarcloud-scan)\
:bookmark: [Finalyze with SonarCloud](https://github.com/codebeltnet/sonarcloud-scan-finalize)
