# lshash

A corpus-hygiene utility for RAG data pipelines that identifies duplicate content risk, quantifies duplication with actionable statistics, and supports controlled remediation before indexing. It enables staged audit-then-cull workflows that improve retrieval quality, reduce embedding/indexing cost, and strengthen governance in knowledge curation operations.

Topic tags: rag, retrieval-augmented-generation, data-curation, data-governance, corpus-hygiene, document-deduplication, file-deduplication, knowledge-management, data-quality, bash, dotnet

## Features

- Sorts files alphabetically.
- Aligns the hash column based on the longest displayed file name.
- Supports multiple hash algorithms.
- Defaults to BLAKE3.
- Can recurse into subdirectories.
- Supports multiple exclusion patterns.
- Ignores `.dups/` directories by default.
- In recursive mode, processes and prints results directory-by-directory as traversal encounters them.
- Continues processing on per-file access errors and emits warnings instead of halting.
- Highlights adjacent matching hashes in green.
- Optional dedupe mode to keep one file and move duplicates into hidden `.dups/` directories.
- Prints a completion summary with duplicate counts and percentages.

## Upfront use-case perspective

This tool was developed as a corpus-hygiene control for RAG pipelines.

In production RAG systems, duplicate files can create duplicate chunks, increase embedding/indexing spend, and over-weight repeated content during retrieval. That can reduce answer quality and make retrieval behavior less predictable.

The intended workflow is a staged curation process:

- Phase 1 (audit, no mutation): run without `-d` to profile duplication as part of pre-ingestion assessment. Use the completion statistics to quantify duplicate-file rate before chunking and embedding.
- Phase 2 (remediation, optional): run with `-d` (and optionally `--all-directory` for full-directory grouping) to quarantine duplicates into `.dups/`, reducing corpus redundancy before indexing.
- Phase 3 (post-curation validation): re-run audit and compare summary metrics to confirm that curation improved corpus quality.

This separation of discovery and action supports safer change control, clearer governance, and repeatable RAG data-preparation practice.

## Script

- `lshash.sh`

## Implementations

- Bash implementation:
  - Script: `lshash.sh`
  - Supports contiguous dedupe and `--all-directory` dedupe
- .NET implementation:
  - Project: `dotnet/`
  - Supports the same runtime options and dedupe variants as Bash

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

## .NET 10 implementation

This repository also includes a .NET 10 C# implementation with behavior parity to the Bash script.

### Build a self-contained single-file executable

```bash
cd dotnet
./build.sh
```

Optional runtime identifier argument:

```bash
cd dotnet
./build.sh linux-x64
```

Output executable:

- `dotnet/dist/linux-x64/lshash`

The publish configuration is self-contained and single-file, so no .NET runtime is required on the target host.

### Run from source

```bash
cd dotnet
dotnet run -c Release -- --help
```

### .NET options

The .NET implementation supports the same options as Bash (`--algorithm`, `-r/--recursive`, `-e/--exclude`, `-d/--dedupe`, `--all-directory`, `-q/--quiet`, optional `DIRECTORY`):

- `--all-directory`
  - With `-d/--dedupe`, dedupe by hash across all files in each directory, ignoring filename adjacency
  - Without `-d/--dedupe`, this flag is a no-op

### .NET examples

```bash
dotnet/dist/linux-x64/lshash -q
dotnet/dist/linux-x64/lshash -rq /path/to/scan
dotnet/dist/linux-x64/lshash -r -d shorter -q
dotnet/dist/linux-x64/lshash --all-directory            # no-op without -d
dotnet/dist/linux-x64/lshash -d shorter --all-directory
```

## Usage

```bash
./lshash.sh [--algorithm NAME] [-r|--recursive] [-e PATTERN] [--exclude PATTERN] [-d [MODE]] [--all-directory] [-q|--quiet] [DIRECTORY]
```

## Options

- `--algorithm NAME`
  - Hash algorithm: `blake3`, `sha256`, `sha512`, `sha1`, `md5`, `blake2`
- `-r`, `--recursive`
  - Include files in subdirectories
  - Hidden `.dups/` directories are skipped by default
  - Output is emitted progressively per directory encountered during traversal
- `-e PATTERN`
- `--exclude PATTERN`
- `--exclude=PATTERN`
  - Exclude files matching glob pattern (repeatable)
- `-d [MODE]`, `--dedupe [MODE]`, `--dedup [MODE]`
- `-d=MODE`, `--dedupe=MODE`, `--dedup=MODE`
  - Dedupe files with identical hash in the same directory
  - Modes: `newer`, `older`, `shorter`, `longer`
  - Default mode when omitted: `shorter`
- `--all-directory`
  - With `-d/--dedupe`, uses full-directory hash grouping instead of contiguous-neighbor grouping
  - Without `-d/--dedupe`, no-op
- `-q`, `--quiet`
  - Only print duplicate lines (the lines that would be highlighted green in normal output)
  - Works with and without dedupe, and with and without recursive mode
- `DIRECTORY` (optional positional argument)
  - Scan this directory instead of the current working directory
  - Output paths remain relative to the selected directory root
- One-letter short switches are stackable in any order (for example `-rd`, `-dr`, `-rq`, `-re '*.log'`).

## Output formatting

- Hash values are left-justified in a single aligned column.
- If the previous listed file has the same hash, the current hash is shown in green.
- When dedupe moves a file, the file name is italicized and annotated:
  - `(moved to .dups/)`
- Completion summary reports duplicate count and percentage of scanned files.
- With `-r/--recursive`, summary also reports directories traversed.
- With `-d/--dedupe`, summary wording changes to duplicates "found and moved".

## Dedupe behavior

When dedupe is enabled:

- Primary use case: remove copy/restore/merge artifacts where duplicate files usually sort next to each other (for example names containing `(copy)`, version suffixes, or sync-conflict tags).
- Duplicate groups are determined by contiguous same-hash blocks in alphabetical listing order within each directory.
- Files that cannot be hashed are skipped for block matching, so they do not break a contiguous duplicate block among hashable neighbors.
- One file is kept in place based on selected mode.
- All other duplicates in that directory are moved to that directory's `.dups/` subdirectory.
- In recursive mode, dedupe is still per directory encountered during traversal.
- Tie-breaking rule: first file in sorted listing order is kept.
- If a destination name already exists in `.dups/`, a `.dupN` suffix is added.
- `--all-directory` provides a more thorough filename-blind mode that checks duplicates across the full directory. It only takes effect when used with `-d/--dedupe`.

## Variant algorithm flow

```mermaid
flowchart TD
  A["Sorted file listing per directory"] --> B{"Dedupe enabled"}
  B -- No --> C["Hash each file in order<br/>Highlight when current hash equals previous hash"]
  B -- Yes --> D{"Use --all-directory with -d"}
  D -- No --> E["Default strategy<br/>Contiguous same-hash runs only<br/>Unreadable files stay visible and do not break hashable run continuity"]
  D -- Yes --> F["All-directory strategy<br/>Group hashable files by hash across the whole directory"]
  E --> G["Select keep file by mode: newer, older, shorter, longer<br/>Move others to .dups"]
  F --> G
  C --> H["Render output<br/>Quiet mode shows only duplicate-highlight lines"]
  G --> H
```

### Strategy summary

- Default (`-d`): optimized for copy/restore/merge artifacts where duplicate names are often alphabetically adjacent.
- `--all-directory` with `-d`: more thorough and filename-blind dedupe across the entire directory.
- `--all-directory` without `-d`: no-op (normal non-dedupe listing behavior).

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

### Only show duplicate lines

```bash
./lshash.sh -q
./lshash.sh -rq /path/to/scan
```

### Summary message examples (hypothetical)

These examples use made-up file sets to show how the completion summary text changes by mode.

#### 1. Audit pass (no `-d`): duplicates found

Hypothetical files in one directory:

```text
a.txt         (content: same)
b.txt         (content: same)
c.txt         (content: different)
```

Command:

```bash
./lshash.sh --algorithm sha256
```

Expected output shape:

```text
a.txt  <hash-A>
b.txt  <hash-A>
c.txt  <hash-C>
Summary: scanned 3 file(s); 1 duplicate file(s) were found (33.33% of scanned files).
```

#### 2. Recursive audit (`-r`, no `-d`): adds traversed directories

Hypothetical tree:

```text
./a.txt             (content: same)
./b.txt             (content: same)
./sub/c.txt         (content: unique)
```

Command:

```bash
./lshash.sh --algorithm sha256 -r
```

Expected output shape:

```text
a.txt      <hash-A>
b.txt      <hash-A>
sub/c.txt  <hash-C>
Summary: scanned 3 file(s); 1 duplicate file(s) were found (33.33% of scanned files); 2 directories were traversed.
```

#### 3. Cull pass (`-d`): duplicates found and moved

Hypothetical files in one directory:

```text
a.txt         (content: same)
aa.txt        (content: same)
aaa.txt       (content: same)
```

Command:

```bash
./lshash.sh --algorithm sha256 -d shorter
```

Expected output shape:

```text
a.txt                         <hash-A>
aa.txt (moved to .dups/)      <hash-A>
aaa.txt (moved to .dups/)     <hash-A>
Summary: scanned 3 file(s); 2 duplicate file(s) were found and moved (66.66% of scanned files).
```

Expected result on disk:

```text
.dups/aa.txt
.dups/aaa.txt
```

#### 4. Audit pass with no duplicates: zero percentage

Hypothetical files in one directory:

```text
a.txt         (content: alpha)
b.txt         (content: bravo)
c.txt         (content: charlie)
```

Command:

```bash
./lshash.sh --algorithm sha256
```

Expected output shape:

```text
a.txt  <hash-A>
b.txt  <hash-B>
c.txt  <hash-C>
Summary: scanned 3 file(s); 0 duplicate file(s) were found (0.00% of scanned files).
```

#### 5. Recursive cull (`-r -d`): moved count plus traversed directories

Hypothetical tree:

```text
./a.txt            (content: same)
./aa.txt           (content: same)
./sub/p.txt        (content: same)
./sub/pp.txt       (content: same)
```

Command:

```bash
./lshash.sh --algorithm sha256 -r -d shorter
```

Expected output shape:

```text
a.txt                         <hash-A>
aa.txt (moved to .dups/)      <hash-A>
sub/p.txt                     <hash-P>
sub/pp.txt (moved to .dups/)  <hash-P>
Summary: scanned 4 file(s); 2 duplicate file(s) were found and moved (50.00% of scanned files); 2 directories were traversed.
```

#### 6. `--all-directory` without `-d`: modifier no-op

Hypothetical files in one directory (non-adjacent duplicate content):

```text
a-copy.txt         (content: same)
m-middle.txt       (content: unique)
z-sync.txt         (content: same)
```

Command:

```bash
./lshash.sh --algorithm sha256 --all-directory
```

Expected output shape:

```text
a-copy.txt  <hash-S>
m-middle.txt  <hash-M>
z-sync.txt  <hash-S>
Summary: scanned 3 file(s); 0 duplicate file(s) were found (0.00% of scanned files).
```

#### 7. `--all-directory` with `-d`: non-adjacent duplicates moved

Use the same hypothetical files as example 6.

Command:

```bash
./lshash.sh --algorithm sha256 -d shorter --all-directory
```

Expected output shape:

```text
a-copy.txt                      <hash-S>
m-middle.txt                    <hash-M>
z-sync.txt (moved to .dups/)    <hash-S>
Summary: scanned 3 file(s); 1 duplicate file(s) were found and moved (33.33% of scanned files).
```

#### 8. Quiet mode (`-q`) still prints summary

Hypothetical files in one directory:

```text
a.txt         (content: same)
b.txt         (content: same)
c.txt         (content: unique)
```

Command:

```bash
./lshash.sh --algorithm sha256 -q
```

Expected output shape:

```text
b.txt  <hash-A>
Summary: scanned 3 file(s); 1 duplicate file(s) were found (33.33% of scanned files).
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

### Permission or file access errors

- If a file cannot be read (for hash or metadata), the tool prints a warning and continues.
- Output for those files shows `<hash unavailable>`.
- In dedupe mode, inaccessible files are ignored for contiguous block matching; hashable neighbors can still form a duplicate block across them.

### Permission issues during auto-install

- Auto-install uses non-interactive sudo (`sudo -n`) and will fail fast if credentials are not already available.
- Fix by installing `b3sum` manually or run with a different algorithm.

### Dedupe did not move files as expected

- Dedupe only groups contiguous same-hash neighbors (in alphabetical listing order) within the same directory.
- With `-r`, grouping is still per directory, not across the entire tree.
- Confirm mode selection:
  - `newer` keeps newest
  - `older` keeps oldest
  - `shorter` keeps shortest file name (default)
  - `longer` keeps longest file name

### Quiet mode printed nothing

- `-q/--quiet` only prints duplicate lines (green lines in normal mode).
- If no adjacent duplicate hashes are encountered in listing order, quiet output will be empty.

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

### How do I scan a different directory?

```bash
./lshash.sh /path/to/scan
./lshash.sh -rq /path/to/scan
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

## Regression tests

Run the parity/regression checks (Bash + .NET):

```bash
chmod +x tests/regression.sh
./tests/regression.sh
```

## Appendix A: Advantages of BLAKE3

BLAKE3 is a modern cryptographic hash function and a strong default for file hashing workflows.

- High speed: significantly faster than older hashes (such as SHA-256) on many systems, which helps when scanning large directories.
- Efficient scaling: designed to use parallelism well, so it performs especially well on modern multi-core CPUs.
- Strong security design: built from well-reviewed cryptographic components and intended for robust integrity checking.
- Flexible output: supports extendable output mode (XOF), which allows generating more output bytes when needed for advanced uses.
- Practical tooling: available via `b3sum`, making it easy to integrate into scripts and command-line workflows.

For this project, BLAKE3 provides a good balance of speed and safety for differentiating files by content hash.

### Quick comparison


| Algorithm | Speed (typical) | Collision resistance for modern use | Security posture                              | Best fit in this project                                                 |
| --------- | --------------- | ----------------------------------- | --------------------------------------------- | ------------------------------------------------------------------------ |
| BLAKE3    | Very high       | Strong                              | Modern cryptographic design                   | Default choice for fast, reliable file differentiation                   |
| SHA-256   | Moderate        | Strong                              | Widely standardized and trusted               | Great compatibility fallback when BLAKE3 is unavailable                  |
| MD5       | Very high       | Weak                                | Not suitable for adversarial integrity checks | Non-security workflows where speed matters and collisions are acceptable |
