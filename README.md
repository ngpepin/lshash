# lshash

A Bash utility that lists files in alphabetical order and prints an aligned hash for each file.

## Features

- Sorts files alphabetically.
- Aligns the hash column based on the longest displayed file name.
- Supports multiple hash algorithms.
- Defaults to BLAKE3.
- Can recurse into subdirectories.
- Supports multiple exclusion patterns.
- Highlights adjacent matching hashes in green.
- Optional dedupe mode to keep one file and move duplicates into hidden `.dups/` directories.

## Script

- `lshash.sh`

## Requirements

- Bash 4+
- Standard Unix tools: `find`, `sort`, `awk`, `stat`, `mv`
- Hash command for selected algorithm:
  - `b3sum` for `blake3`
  - `sha256sum` for `sha256`
  - `sha512sum` for `sha512`
  - `sha1sum` for `sha1`
  - `md5sum` for `md5`
  - `b2sum` for `blake2`

### BLAKE3 auto-install behavior

If `blake3` is selected and `b3sum` is missing, the script attempts an automatic install using a detected package manager.

- Uses non-interactive elevation (`sudo -n`) when needed.
- Uses a timeout for install attempts.
- Timeout defaults to 20 seconds and can be overridden:

```bash
LSHASH_INSTALL_TIMEOUT=10 ./lshash.sh
```

If installation cannot be done automatically, the script exits with guidance.

## Usage

```bash
./lshash.sh [--algorithm NAME] [-r|--recursive] [-e PATTERN] [--exclude PATTERN] [-d [MODE]]
```

## Options

- `--algorithm NAME`
  - Hash algorithm: `blake3`, `sha256`, `sha512`, `sha1`, `md5`, `blake2`
- `-r`, `--recursive`
  - Include files in subdirectories
- `-e PATTERN`
- `--exclude PATTERN`
- `--exclude=PATTERN`
  - Exclude files matching glob pattern (repeatable)
- `-d [MODE]`, `--dedupe [MODE]`, `--dedup [MODE]`
- `-d=MODE`, `--dedupe=MODE`, `--dedup=MODE`
  - Dedupe files with identical hash in the same directory
  - Modes: `newer`, `older`, `shorter`, `longer`
  - Default mode when omitted: `shorter`

## Output formatting

- Hash values are left-justified in a single aligned column.
- If the previous listed file has the same hash, the current hash is shown in green.
- When dedupe moves a file, the file name is italicized and annotated:
  - `(moved to .dups/)`

## Dedupe behavior

When dedupe is enabled:

- Duplicate groups are determined per directory by hash value.
- One file is kept in place based on selected mode.
- All other duplicates in that directory are moved to that directory's `.dups/` subdirectory.
- In recursive mode, dedupe is still per directory encountered during traversal.
- Tie-breaking rule: first file in sorted listing order is kept.
- If a destination name already exists in `.dups/`, a `.dupN` suffix is added.

## Examples

### Basic listing (default BLAKE3)

```bash
./lshash.sh
```

### Use SHA-256

```bash
./lshash.sh --algorithm sha256
```

### Recursive listing

```bash
./lshash.sh -r
```

### Exclude multiple patterns

```bash
./lshash.sh -r -e '*.log' --exclude '*.tmp' --exclude='build/*'
```

### Dedupe with default mode (`shorter`)

```bash
./lshash.sh -d
```

### Dedupe and keep newest file

```bash
./lshash.sh -r --dedupe newer
```

### Dedupe and keep longest file name

```bash
./lshash.sh --dedupe=longer
```

## Notes

- Dedupe moves files; it does not delete them.
- Review output carefully before running dedupe on important directories.

## Troubleshooting

### Default run seems slow or pauses

- First run with `blake3` may try to auto-install `b3sum` if missing.
- Use another algorithm immediately:

```bash
./lshash.sh --algorithm sha256
```

- Reduce install wait time:

```bash
LSHASH_INSTALL_TIMEOUT=5 ./lshash.sh
```

### `b3sum` not found

- Install it manually, or use another algorithm.
- Example fallback:

```bash
./lshash.sh --algorithm sha512
```

### Permission issues during auto-install

- Auto-install uses non-interactive sudo (`sudo -n`) and will fail fast if credentials are not already available.
- Fix by installing `b3sum` manually or run with a different algorithm.

### Dedupe did not move files as expected

- Dedupe only groups duplicates by hash within the same directory.
- With `-r`, grouping is still per directory, not across the entire tree.
- Confirm mode selection:
  - `newer` keeps newest
  - `older` keeps oldest
  - `shorter` keeps shortest file name (default)
  - `longer` keeps longest file name

### Unexpected shell warnings about current directory

- If your shell says it cannot access the current directory (`getcwd` warnings), your working directory may have been deleted.
- Change into a valid directory before running again:

```bash
cd /home/npepin/Projects/lshash
```

## FAQ

### How do I run a simple hash listing in the current directory?

```bash
./lshash.sh
```

### How do I recurse but skip common noise directories and file types?

```bash
./lshash.sh -r -e '.git/*' -e '.dups/*' -e 'node_modules/*' -e '*.log' -e '*.tmp'
```

### How do I use a non-BLAKE3 algorithm quickly?

```bash
./lshash.sh --algorithm sha256
```

### How do I dedupe recursively and keep the newest file in each duplicate set?

```bash
./lshash.sh -r --dedupe newer
```

### How do I dedupe but keep the shortest filename instead?

```bash
./lshash.sh -d
```

### Where do moved duplicates go?

- Duplicates are moved into a hidden `.dups/` subdirectory under the same directory where the duplicate was found.

### What if I want dedupe aliases?

- All of these are accepted:
  - `--dedupe`
  - `--dedup`
  - `-d`
