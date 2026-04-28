# lshash (.NET 10)

This directory contains a .NET 10 C# implementation of lshash for Linux with parity to the Bash version.

## Build a self-contained single-file executable

Run:

```bash
./build.sh
```

Optional runtime identifier argument:

```bash
./build.sh linux-x64
```

Output executable:

- `dist/linux-x64/lshash`

The publish configuration is self-contained and single-file, so no .NET runtime is required on the target host.

## Run from source

```bash
dotnet run -c Release -- --help
```

## Supported options

- `--algorithm` (`blake3`, `sha256`, `sha512`, `sha1`, `md5`, `blake2`)
- `-r`, `--recursive`
- `-e`, `--exclude`
- `-d`, `--dedupe`, `--dedup` (with `newer|older|shorter|longer`)
- short-option stacking (for example: `-dr newer`, `-rde '*.log'`)
