# lshash Architecture

This document describes the technical architecture of both implementations:

- Bash implementation: `lshash.sh`
- .NET implementation: `dotnet/Program.cs`

It also covers parity testing in `tests/regression.sh`.

## 1. System overview

```mermaid
flowchart LR
  U[User / CI] --> CLI1[lshash.sh]
  U --> CLI2[dotnet/dist/*/lshash]
  CLI1 --> FS[(Filesystem)]
  CLI2 --> FS
  CLI1 --> HASH1[OS hash tools]
  CLI2 --> HASH2[Managed hash engines]
  CLI1 --> OUT[Console output]
  CLI2 --> OUT
  CLI1 --> DUPS[.dups moves]
  CLI2 --> DUPS
  DUPS --> META[Sidecar JSON in global recursive mode]
```

## 2. Shared behavioral contract

Both implementations follow the same behavior contract, validated by parity tests.

```mermaid
flowchart TD
  A[Parse options] --> B{Standalone mode?}
  B -->|move-dups mode| C[Move existing .dups trees]
  B -->|prompt-delete only| D[GC existing .dups trees]
  B -->|normal scan| E[Enumerate files]
  E --> F[Hash + print]
  F --> G{Dedupe enabled?}
  G -->|No| H[Summary only]
  G -->|Yes| I[Select kept file by mode]
  I --> J[Move losers to .dups]
  J --> K{Recursive global?}
  K -->|Yes| L[Write sidecar JSON]
  K -->|No| M[No sidecars]
  L --> N[Summary + list .dups dirs]
  M --> N
  C --> O[Done]
  D --> O
  H --> O
  N --> O
```

## 3. Option parsing architecture

### 3.1 Bash parser

`lshash.sh` parses long options and short-option clusters (`-rd`, `-rq`, `-re`).

```mermaid
flowchart TD
  A[parse_args] --> B{token starts with -- ?}
  B -->|Yes| C[long-option handlers]
  B -->|No| D{token starts with - ?}
  D -->|Yes| E[short-cluster scanner]
  D -->|No| F[set DIRECTORY positional arg]
  C --> G[update flags/state]
  E --> G
  F --> G
  G --> H[validate combinations]
```

### 3.2 .NET parser

`dotnet/Program.cs` parses similarly, including short cluster decoding and mode validation.

```mermaid
flowchart TD
  A[ParseArgs args] --> B[for each arg]
  B --> C{long option?}
  C -->|Yes| D[direct switch cases]
  C -->|No| E{short cluster?}
  E -->|Yes| F[char-by-char decode]
  E -->|No| G[positional directory]
  D --> H[state mutation]
  F --> H
  G --> H
  H --> I[normalize/validate modes]
```

## 4. File traversal architecture

## 4.1 Recursive traversal

```mermaid
flowchart TD
  A[Start at root] --> B[Enumerate directories depth-first]
  B --> C[Skip .dups dirs]
  C --> D[Collect files in directory]
  D --> E[Apply exclude patterns]
  E --> F[Sort entries]
  F --> G[Queue for hashing/printing]
  G --> H{more directories?}
  H -->|Yes| B
  H -->|No| I[Emit summary]
```

## 4.2 Dedupe scope selection

```mermaid
flowchart TD
  A[Dedupe requested] --> B{--global?}
  B -->|Yes| C{--recursive?}
  C -->|Yes| D[Whole-tree duplicate grouping]
  C -->|No| E[Selected-directory full grouping]
  B -->|No| F{--directory?}
  F -->|Yes| G[Per-directory full grouping]
  F -->|No| H[Per-directory contiguous-run grouping]
  D --> I[Move losers to source .dups]
  E --> I
  G --> I
  H --> I
```

## 5. Dedupe decision engine

The keep-selection strategy is shared:

- `newer`: keep greatest mtime
- `older`: keep smallest mtime
- `shorter`: keep shortest root-relative path length
- `longer`: keep longest root-relative path length

```mermaid
flowchart TD
  A[Duplicate set] --> B[Initial keep = first item]
  B --> C[Compare candidate vs keep]
  C --> D{Mode}
  D -->|newer| E[candidate.mtime > keep.mtime]
  D -->|older| F[candidate.mtime < keep.mtime]
  D -->|shorter| G[len(candidate.relativePath) < len(keep.relativePath)]
  D -->|longer| H[len(candidate.relativePath) > len(keep.relativePath)]
  E --> I[maybe replace keep]
  F --> I
  G --> I
  H --> I
  I --> J{more candidates?}
  J -->|Yes| C
  J -->|No| K[Move non-kept entries]
```

## 6. Bash implementation internals

### 6.1 Processing pipeline

```mermaid
flowchart LR
  A[discover_files_in_current_group] --> B[try_hash_file]
  B --> C[print hash lines]
  C --> D{dedupe mode?}
  D -->|No| E[next directory]
  D -->|Yes| F[flush_run / group handling]
  F --> G[safe_move_file to .dups]
  G --> H[write_global_metadata_for_indices if needed]
  H --> E
```

### 6.2 External dependency model

```mermaid
flowchart TD
  A[lshash.sh] --> B[hash command selection]
  B --> C[b3sum / sha*sum / md5sum / b2sum]
  A --> D[file type checks]
  D --> E[file + stat + shell logic]
  A --> F[filesystem moves]
  F --> G[mkdir + mv]
```

## 7. .NET implementation internals

## 7.1 Main execution flow

```mermaid
flowchart TD
  A[Main] --> B[ParseArgs]
  B --> C[Resolve working directory]
  C --> D[MaybePrintPerformanceDiagnostics]
  D --> E{--move-dups standalone?}
  E -->|Yes| F[RunMoveDupsMode]
  E -->|No| G{prompt-delete standalone?}
  G -->|Yes| H[RunPromptDeleteGarbageCollectMode]
  G -->|No| I[Normal scan path]
  I --> J[ProcessRecursive / ProcessSingleDirectory / ProcessGlobalDedupe]
  J --> K[PrintSummary]
```

## 7.2 Hashing subsystem

```mermaid
flowchart LR
  A[TryComputeHash] --> B{Algorithm}
  B -->|blake3| C[ComputeBlake3]
  B -->|sha256/512/sha1/md5| D[ComputeSystemHash]
  B -->|blake2| E[ComputeBlake2b512]
  C --> F{Backend}
  F -->|cpu| G[Managed BLAKE3]
  F -->|gpu| H[Native libblake3gpu]
  H --> I{failure?}
  I -->|Yes| G
  I -->|No| J[Use GPU result]
```

## 7.3 Adaptive parallel hashing controller

```mermaid
flowchart TD
  A[Build file list] --> B[Estimate file sizes]
  B --> C[GetHashWorkerPlan start/end]
  C --> D[Chunk loop]
  D --> E[Parallel.For with current workers]
  E --> F[Measure chunk throughput]
  F --> G{Worker count fixed by env?}
  G -->|Yes| H[Keep workers constant]
  G -->|No| I[Adjust direction by sensitivity/gain thresholds]
  I --> J[Increase or decrease workers]
  J --> K{more chunks?}
  K -->|Yes| D
  K -->|No| L[Return ordered results]
  H --> K
```

## 8. Metadata sidecar architecture (`-r -d --global`)

```mermaid
sequenceDiagram
  participant G as Global duplicate group
  participant S as Subject moved file
  participant O as Other peers
  participant J as JSON writer

  G->>S: select moved entry
  G->>O: collect peer paths and statuses
  S->>J: subject(path,status=moved)
  O->>J: others(path,status kept-or-moved)
  J->>J: serialize payload
  J->>S: write moved-file.json sidecar in same .dups dir
```

## 9. Standalone maintenance modes

```mermaid
flowchart TD
  A[Start] --> B{move-dups mode}
  B -->|Yes| C[Collect existing .dups dirs]
  C --> D[Move each dir to destination preserving tree]
  D --> E[Done]
  B -->|No| F{prompt-delete only}
  F -->|Yes| G[Collect existing .dups dirs]
  G --> H[List + prompt y/N]
  H --> I[Delete selected dirs]
  I --> E
```

## 10. Parity and regression architecture

Parity tests drive both implementations with equivalent fixtures and compare normalized outputs.

```mermaid
flowchart LR
  A[tests/regression.sh fixtures] --> B[Run Bash implementation]
  A --> C[Run .NET implementation]
  B --> D[Normalize ANSI + case root]
  C --> D
  D --> E[assert_same_output]
  E --> F[filesystem assertions]
  F --> G[Parity verdict]
```

## 11. Key design choices

- Keep behaviorally identical user contract across Bash and .NET.
- Preserve deterministic output ordering even with .NET parallel hashing.
- Separate audit and mutation phases for safer operations.
- Keep maintenance modes (`--prompt-delete`, `--move-dups`) explicitly standalone.
- Surface diagnostics for network filesystems where tuning visibility is critical.

## 12. Appendix: Advantages of BLAKE3

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
