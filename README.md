# Install .NET SDK

Install current [LTS and STS versions](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core) of .NET SDK. Leverages the official [setup-dotnet action](https://github.com/actions/setup-dotnet) pre-configured specifically for the majority.

> This action is part of the Codebelt ecosystem and ensures a consistent way of: 
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
