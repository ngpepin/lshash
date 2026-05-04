# macOS Docker Deployment (.NET)

This directory contains a Docker-based deployment path for running the .NET lshash implementation on macOS.

Note: native macOS builds produced by `dotnet/build-macos.sh` now default to `net6.0` for Catalina-friendly compatibility. Use this Docker path when you prefer containerized execution.

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
