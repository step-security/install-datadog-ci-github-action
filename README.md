[![StepSecurity Maintained Action](https://raw.githubusercontent.com/step-security/maintained-actions-assets/main/assets/maintained-action-banner.png)](https://docs.stepsecurity.io/actions/stepsecurity-maintained-actions)

# Install datadog-ci Action

A GitHub Action that installs the [Datadog CI CLI](https://github.com/DataDog/datadog-ci) (standalone binary) on the runner.

## Usage

```yaml
steps:
  - name: Install datadog-ci
    uses: step-security/install-datadog-ci-github-action@v1

  - name: Use datadog-ci
    run: datadog-ci version
```

### Pin to a specific version

```yaml
- uses: step-security/install-datadog-ci-github-action@v1
  with:
    version: 'v5.6.0'
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `github-token` | Optional GitHub token used to authenticate GitHub Releases API lookups for floating major versions like `v5`. Falls back to `github.token` when not provided. | No | `github.token` |
| `version` | Version of datadog-ci to install. Use a major version like `v5` to get the latest release within that major version, or a specific tag like `v5.6.0` to pin. | No | `v5` |

## Outputs

| Output | Description |
|--------|-------------|
| `version` | The concrete version that was installed (e.g. `"v5.6.0"`) |
| `binary-path` | Absolute path to the installed datadog-ci binary |
| `cache-hit` | `"true"` if the binary was restored from cache; empty string if it was downloaded from GitHub Releases |

## Caching

The action caches the downloaded binary using [`actions/cache`](https://github.com/actions/cache), keyed on runner OS, architecture, and the resolved version. On a cache hit, the network download is skipped entirely. If the cache service is unavailable, the action transparently falls back to downloading directly from GitHub Releases. Cache write failures are non-fatal and produce a warning rather than failing the action.

## Supported platforms

| Runner OS | Architecture | Binary |
|-----------|-------------|--------|
| Linux | X64 | `datadog-ci_linux-x64` |
| Linux | ARM64 | `datadog-ci_linux-arm64` |
| macOS | X64 | `datadog-ci_darwin-x64` |
| macOS | ARM64 | `datadog-ci_darwin-arm64` |
| Windows | X64 | `datadog-ci_win-x64` |

## Checksum verification

When available, the action verifies the downloaded binary against SHA-256 checksums published alongside the release assets. If the checksums file is not available (older releases), the action continues with a warning.

## License

Apache 2.0 - See [LICENSE](LICENSE) for details.
