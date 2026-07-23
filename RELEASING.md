# Releasing

## Versioning Strategy

This action follows [semantic versioning](https://semver.org/) with floating major version tags, as recommended by the [GitHub Actions toolkit](https://github.com/actions/toolkit/blob/master/docs/action-versioning.md#recommendations).

Users reference the action by its major version (e.g., `uses: DataDog/install-datadog-ci-github-action@v1`), which should point to the latest `v1.x.y` release.

The [release workflow](.github/workflows/release.yml) creates the GitHub Release for each semver tag. The floating major tag is updated manually because major tags are protected from workflows that use the default `GITHUB_TOKEN`. Updating a floating major tag requires force-updating a protected ref, and workflows using `GITHUB_TOKEN` cannot bypass that protection. If automation attempts the update, GitHub rejects the push with `GH013: Repository rule violations found` and `Cannot update this protected ref`.

## Release Process

1. Ensure all changes are merged to `main`.
2. Create and push a semver tag:
   ```bash
   git tag v1.1.0
   git push origin v1.1.0
   ```
3. The `release.yml` workflow will automatically:
   - Create a GitHub Release with auto-generated release notes.
4. Verify the GitHub Release appears at https://github.com/DataDog/install-datadog-ci-github-action/releases.
5. Update the floating major version tag manually with an account or token that can bypass the tag protection ruleset:
   ```bash
   git fetch origin --tags
   git tag -f v1 v1.1.0
   git push -f origin v1
   ```
6. Verify the floating major version tag points to the released tag:
   ```bash
   git ls-remote --tags origin v1 v1.1.0
   ```
7. Optionally, run the smoke test workflow to validate the release.

## Major Version Releases

Bump the major version when making breaking changes to:

- Action inputs (renaming, removing, or changing required/optional status)
- Action outputs
- Default behavior that users depend on
- Minimum supported runner or Node.js version

To release a new major version (e.g., `v2`):

1. Follow the standard release process with the new major version tag (e.g., `v2.0.0`).
2. Manually create or update the new floating tag (`v2`) with an account or token that can bypass the tag protection ruleset.
3. Update the `README.md` usage examples to reference the new major version.

## Hotfix Process

To patch an older major version:

1. Create a release branch from the last tag of that major version:
   ```bash
   git checkout -b release/v1 v1.2.3
   git push origin release/v1
   ```
2. Cherry-pick or apply the fix on the release branch.
3. Tag and push from the release branch:
   ```bash
   git tag v1.2.4
   git push origin v1.2.4
   ```
4. Manually update the `v1` floating tag with an account or token that can bypass the tag protection ruleset:
   ```bash
   git fetch origin --tags
   git tag -f v1 v1.2.4
   git push -f origin v1
   ```
