# Install .NET SDK

Install current [LTS and STS versions](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core) of .NET SDK. Leverages the official [setup-dotnet action](https://github.com/actions/setup-dotnet) pre-configured specifically for the Codebelt methodology.

This ensures a smooth and consistent way to setup your CI/CD pipeline as well as structuring your repository.

## Usage

To use this action in your GitHub repository, you can follow these steps:

```yaml
uses: codebeltnet/install-dotnet@main
```

### Inputs

This action has no inputs.

### Outputs

This action has no outputs.

## Examples

### Install all supported versions of .NET SDK

```yaml
steps:
  - name: Install .NET
    uses: codebeltnet/install-dotnet@main
```

## Contributing to Install .NET SDK

Contributions are welcome! 
Feel free to submit issues, feature requests, or pull requests to help improve this action.

### License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
