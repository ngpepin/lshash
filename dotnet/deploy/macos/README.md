# macOS Docker Deployment (.NET)

This directory contains a Docker-based deployment path for running the .NET lshash implementation on macOS, including Catalina (10.15), where native .NET 10 self-contained binaries may not run directly.

## Files

- `Dockerfile`: Multi-stage build for the .NET executable.
- `deploy.sh`: macOS-friendly wrapper to build and run the container.

## Quick start

1. Build image:

```bash
cd dotnet/deploy/macos
./deploy.sh build
```

2. Audit mode (read-only mount):

```bash
./deploy.sh audit /path/to/scan
```

3. Cull mode (read/write mount):

```bash
./deploy.sh cull /path/to/scan
```

4. Custom run options:

```bash
./deploy.sh run /path/to/scan --algorithm sha512 -r -q
```

## Notes

- The host directory is mounted to `/data` inside the container.
- The wrapper passes your UID:GID to keep file ownership consistent.
- `audit` defaults to `--algorithm sha256 -r`.
- `cull` defaults to `--algorithm sha256 -r -d shorter`.
