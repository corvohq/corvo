# Releasing Corvo

This guide covers releasing the Corvo server and all SDK packages.

## Versioning

Corvo follows [Semantic Versioning](https://semver.org/):

- **Major** (X.0.0) — breaking API/proto changes
- **Minor** (0.X.0) — new features, backward-compatible
- **Patch** (0.0.X) — bug fixes only

While pre-1.0, minor bumps may include breaking changes. Document these in the release notes.

## 1. Release the Corvo Server

### Pre-release checklist

1. **Update the version constant** in `cmd/corvo/main.go`:
   ```go
   var version = "0.2.0"
   ```
   This is the fallback for local builds. GoReleaser overrides it via ldflags at release time.

2. **Update Helm chart version** in `deploy/helm/corvo/Chart.yaml`:
   ```yaml
   version: 0.2.0
   appVersion: "0.2.0"
   ```

3. **If the proto changed**, update the proto submodule:
   - Commit and push changes in `proto/`
   - Update submodule refs in all SDK repos
   - Regenerate stubs (see [Proto Changes](#proto-changes) below)

4. **Run tests**:
   ```bash
   go test ./...
   ```

5. **Commit** all version bumps on `main`.

### Tag and release

```bash
git tag v0.2.0
git push origin v0.2.0
```

This triggers `.github/workflows/release.yml` which runs GoReleaser to:
- Build binaries for linux/darwin/windows (amd64/arm64)
- Push Docker images to `corvohq/corvo:<version>`
- Update the Homebrew tap
- Create a GitHub Release with auto-generated changelog

## 2. Release SDKs

Each SDK lives in its own repo with its own `.github/workflows/release.yml`. SDKs are versioned and released independently from the server.

### Version locations per SDK

Update **both** the package metadata and the `SDK_VERSION` constant (sent as `x-corvo-client-version` header) in each SDK:

#### Go SDK (`go-sdk/`)
| File | Field |
|------|-------|
| `rpc/client.go` | `const sdkVersion = "X.Y.Z"` |

Go module version is determined by the git tag — no file to update.

#### Python SDK (`python-sdk/`)
| File | Field |
|------|-------|
| `client/pyproject.toml` | `version = "X.Y.Z"` |
| `client/corvo_client/rpc.py` | `SDK_VERSION = "X.Y.Z"` |
| `worker/pyproject.toml` | `version = "X.Y.Z"` |
| `worker/corvo_worker/rpc.py` | `SDK_VERSION = "X.Y.Z"` |

#### Rust SDK (`rust-sdk/`)
| File | Field |
|------|-------|
| `corvo-client/Cargo.toml` | `version = "X.Y.Z"` |
| `corvo-client/src/rpc.rs` | `const SDK_VERSION: &str = "X.Y.Z"` |
| `corvo-worker/Cargo.toml` | `version = "X.Y.Z"` |
| `corvo-worker/src/rpc.rs` | `const SDK_VERSION: &str = "X.Y.Z"` |

#### TypeScript SDK (`typescript-sdk/`)
| File | Field |
|------|-------|
| `packages/client/package.json` | `"version": "X.Y.Z"` |
| `packages/client/src/rpc.ts` | `const SDK_VERSION = "X.Y.Z"` |
| `packages/worker/package.json` | `"version": "X.Y.Z"` |

### Tag and release SDKs

Each SDK repo has its own release workflow triggered by tags pushed to that repo:

```bash
# Go SDK (go-sdk repo) — tags: v*
git tag v0.2.0 && git push origin v0.2.0

# Python SDK (python-sdk repo) — tags: client/v* and worker/v*
git tag client/v0.2.0 && git push origin client/v0.2.0
git tag worker/v0.2.0 && git push origin worker/v0.2.0

# Rust SDK (rust-sdk repo) — tags: v*
# Publishes both corvo-client and corvo-worker crates
git tag v0.2.0 && git push origin v0.2.0

# TypeScript SDK (typescript-sdk repo) — tags: client/v* and worker/v*
git tag client/v0.2.0 && git push origin client/v0.2.0
git tag worker/v0.2.0 && git push origin worker/v0.2.0
```

| SDK | Repo | Tag pattern | Publishes to |
|-----|------|-------------|--------------|
| Go | `go-sdk` | `v*` | pkg.go.dev (automatic) |
| Python client | `python-sdk` | `client/v*` | PyPI |
| Python worker | `python-sdk` | `worker/v*` | PyPI |
| Rust | `rust-sdk` | `v*` | crates.io |
| TypeScript client | `typescript-sdk` | `client/v*` | npm |
| TypeScript worker | `typescript-sdk` | `worker/v*` | npm |

### Update SDK README compatibility tables

After releasing, update each SDK's `README.md` compatibility table:

```markdown
## Compatibility

| SDK Version | Corvo Server |
|-------------|-------------|
| 0.2.x       | >= 0.2.0    |
| 0.1.x       | >= 0.1.0    |
```

## Proto Changes

If the `.proto` file changed, regenerate stubs in every repo **before** releasing SDKs:

```bash
# Server (Go/Connect)
cd corvo && buf generate

# Go SDK
cd go-sdk && buf generate

# Python SDK
cd python-sdk && ./generate_proto.sh

# Rust SDK (build.rs runs tonic_build when protoc is available)
cd rust-sdk/corvo-client && PROTOC=protoc cargo build
cd rust-sdk/corvo-worker && PROTOC=protoc cargo build

# TypeScript SDK
cd typescript-sdk && npx buf generate
```

Commit regenerated stubs in each repo before tagging.

## Typical Release Order

1. Merge all changes to `main` in each repo
2. Update proto submodule refs if proto changed
3. Regenerate stubs if proto changed
4. Bump version constants (server + SDKs)
5. Commit and push
6. Tag and release server: `git tag v0.2.0 && git push origin v0.2.0`
7. Tag and release SDKs (can be done in parallel)
8. Verify GitHub Releases, Docker Hub, npm, PyPI, crates.io
9. Update SDK README compatibility tables

## Rollback

If a release has a critical issue:
- **Server**: Push a new patch tag (e.g., `v0.2.1`) with the fix. Docker `latest` will be updated automatically.
- **SDKs**: Publish a new patch version. For npm, you can also `npm deprecate` the broken version.
- **Do not** delete or force-push tags — downstream users may already reference them.
