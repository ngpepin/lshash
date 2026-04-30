using System.Buffers;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Blake3;
using Org.BouncyCastle.Crypto.Digests;

namespace LsHash;

internal enum HashAlgorithmKind
{
    Blake3,
    Sha256,
    Sha512,
    Sha1,
    Md5,
    Blake2,
}

internal enum DedupeMode
{
    Newer,
    Older,
    Shorter,
    Longer,
}

internal sealed class Options
{
    public HashAlgorithmKind Algorithm { get; set; } = HashAlgorithmKind.Blake3;

    public bool Recursive { get; set; }

    public List<string> ExcludePatterns { get; } = new();

    public bool DedupeEnabled { get; set; }

    public DedupeMode DedupeMode { get; set; } = DedupeMode.Shorter;

    public bool ShowHelp { get; set; }

    public bool Quiet { get; set; }

    public bool AllDirectoryDedupe { get; set; }

    public string RootDirectory { get; set; } = ".";
}

internal sealed class FileEntry
{
    public required string RelativePath { get; init; }

    public required string DirectoryPath { get; init; }

    public required string BaseName { get; init; }

    public string? Hash { get; init; }

    public bool HashAvailable { get; init; }

    public long MtimeSeconds { get; init; }

    public bool MtimeAvailable { get; init; }

    public bool Moved { get; set; }
}

internal sealed class SummaryStats
{
    public long TotalFilesScanned { get; set; }

    public long DuplicateFilesFound { get; set; }

    public long DuplicateFilesMoved { get; set; }

    public long DirectoriesTraversed { get; set; }
}

internal static class Program
{
    private const string Green = "\u001b[32m";
    private const string Italic = "\u001b[3m";
    private const string Reset = "\u001b[0m";

    private static string WorkingDirectory = Directory.GetCurrentDirectory();

    private static int Main(string[] args)
    {
        try
        {
            var options = ParseArgs(args);
            if (options.ShowHelp)
            {
                PrintHelp();
                return 0;
            }

            WorkingDirectory = ResolveWorkingDirectory(options.RootDirectory);
            var summaryStats = new SummaryStats();

            if (options.Recursive)
            {
                ProcessRecursive(options, summaryStats);
            }
            else
            {
                ProcessSingleDirectory(".", options, summaryStats);
            }

            PrintSummary(options, summaryStats);

            return 0;
        }
        catch (ArgumentException ex)
        {
            Console.Error.WriteLine(ex.Message);
            Console.Error.WriteLine("Try: --help");
            return 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Error: {ex.Message}");
            return 1;
        }
    }

    private static Options ParseArgs(string[] args)
    {
        var options = new Options();

        for (var argIndex = 0; argIndex < args.Length; argIndex++)
        {
            var arg = args[argIndex];

            if (arg is "-h" or "--help")
            {
                options.ShowHelp = true;
                return options;
            }

            if (arg.StartsWith("--", StringComparison.Ordinal))
            {
                if (arg.StartsWith("--algorithm=", StringComparison.Ordinal))
                {
                    options.Algorithm = ParseAlgorithm(arg[12..]);
                    continue;
                }

                if (arg == "--algorithm")
                {
                    argIndex = RequireValueIndex(args, argIndex, "--algorithm");
                    options.Algorithm = ParseAlgorithm(args[argIndex]);
                    continue;
                }

                if (arg == "--recursive")
                {
                    options.Recursive = true;
                    continue;
                }

                if (arg == "--quiet")
                {
                    options.Quiet = true;
                    continue;
                }

                if (arg == "--all-directory")
                {
                    options.AllDirectoryDedupe = true;
                    continue;
                }

                if (arg.StartsWith("--exclude=", StringComparison.Ordinal))
                {
                    options.ExcludePatterns.Add(arg[10..]);
                    continue;
                }

                if (arg == "--exclude")
                {
                    argIndex = RequireValueIndex(args, argIndex, "--exclude");
                    options.ExcludePatterns.Add(args[argIndex]);
                    continue;
                }

                if (arg.StartsWith("--dedupe=", StringComparison.Ordinal)
                    || arg.StartsWith("--dedup=", StringComparison.Ordinal)
                    || arg.StartsWith("--dedub=", StringComparison.Ordinal))
                {
                    options.DedupeEnabled = true;
                    options.DedupeMode = ParseDedupeMode(arg[(arg.IndexOf('=') + 1)..]);
                    continue;
                }

                if (arg is "--dedupe" or "--dedup" or "--dedub")
                {
                    options.DedupeEnabled = true;
                    options.DedupeMode = DedupeMode.Shorter;

                    if (argIndex + 1 < args.Length
                        && !args[argIndex + 1].StartsWith("-", StringComparison.Ordinal)
                        && TryParseDedupeMode(args[argIndex + 1], out var dedupeMode))
                    {
                        argIndex++;
                        options.DedupeMode = dedupeMode;
                    }

                    continue;
                }

                throw new ArgumentException($"Unknown option: {arg}");
            }

            if (arg.StartsWith("-", StringComparison.Ordinal) && arg.Length > 1)
            {
                ParseShortCluster(arg[1..], args, ref argIndex, options);
                continue;
            }

            if (options.RootDirectory == ".")
            {
                options.RootDirectory = arg;
                continue;
            }

            throw new ArgumentException($"Unexpected argument: {arg}");
        }

        return options;
    }

    private static void ParseShortCluster(string cluster, string[] args, ref int argIndex, Options options)
    {
        var clusterPos = 0;
        var dedupeModePending = false;

        while (clusterPos < cluster.Length)
        {
            var opt = cluster[clusterPos];
            switch (opt)
            {
                case 'r':
                    options.Recursive = true;
                    clusterPos++;
                    break;
                case 'q':
                    options.Quiet = true;
                    clusterPos++;
                    break;
                case 'h':
                    options.ShowHelp = true;
                    clusterPos = cluster.Length;
                    break;
                case 'e':
                {
                    string value;
                    if (clusterPos + 1 < cluster.Length)
                    {
                        value = cluster[(clusterPos + 1)..];
                    }
                    else
                    {
                        argIndex = RequireValueIndex(args, argIndex, "-e");
                        value = args[argIndex];
                    }

                    options.ExcludePatterns.Add(value);
                    clusterPos = cluster.Length;
                    break;
                }
                case 'd':
                {
                    options.DedupeEnabled = true;
                    options.DedupeMode = DedupeMode.Shorter;
                    var remainder = cluster[(clusterPos + 1)..];

                    if (remainder.Length == 0)
                    {
                        dedupeModePending = true;
                        clusterPos++;
                        break;
                    }

                    if (remainder.StartsWith("=", StringComparison.Ordinal))
                    {
                        options.DedupeMode = ParseDedupeMode(remainder[1..]);
                        clusterPos = cluster.Length;
                        break;
                    }

                    if (Regex.IsMatch(remainder, "^[rhedq]+$", RegexOptions.CultureInvariant))
                    {
                        dedupeModePending = true;
                        clusterPos++;
                        break;
                    }

                    options.DedupeMode = ParseDedupeMode(remainder);
                    clusterPos = cluster.Length;
                    break;
                }
                default:
                    throw new ArgumentException($"Unknown option: -{opt}");
            }
        }

        if (dedupeModePending
            && argIndex + 1 < args.Length
            && !args[argIndex + 1].StartsWith("-", StringComparison.Ordinal)
            && TryParseDedupeMode(args[argIndex + 1], out var dedupeMode))
        {
            argIndex++;
            options.DedupeMode = dedupeMode;
        }
    }

    private static int RequireValueIndex(string[] args, int currentIndex, string optionName)
    {
        var valueIndex = currentIndex + 1;
        if (valueIndex >= args.Length)
        {
            throw new ArgumentException($"Missing value for {optionName}");
        }

        return valueIndex;
    }

    private static HashAlgorithmKind ParseAlgorithm(string value)
    {
        return value.Trim().ToLowerInvariant() switch
        {
            "blake3" => HashAlgorithmKind.Blake3,
            "sha256" => HashAlgorithmKind.Sha256,
            "sha512" => HashAlgorithmKind.Sha512,
            "sha1" => HashAlgorithmKind.Sha1,
            "md5" => HashAlgorithmKind.Md5,
            "blake2" => HashAlgorithmKind.Blake2,
            _ => throw new ArgumentException(
                $"Unsupported algorithm: {value}{Environment.NewLine}Supported: blake3, sha256, sha512, sha1, md5, blake2"
            ),
        };
    }

    private static DedupeMode ParseDedupeMode(string value)
    {
        return value.Trim().ToLowerInvariant() switch
        {
            "newer" => DedupeMode.Newer,
            "older" => DedupeMode.Older,
            "shorter" => DedupeMode.Shorter,
            "longer" => DedupeMode.Longer,
            _ => throw new ArgumentException(
                $"Unsupported dedupe mode: {value}{Environment.NewLine}Supported dedupe modes: newer, older, shorter, longer"
            ),
        };
    }

    private static bool TryParseDedupeMode(string value, out DedupeMode mode)
    {
        switch (value.Trim().ToLowerInvariant())
        {
            case "newer":
                mode = DedupeMode.Newer;
                return true;
            case "older":
                mode = DedupeMode.Older;
                return true;
            case "shorter":
                mode = DedupeMode.Shorter;
                return true;
            case "longer":
                mode = DedupeMode.Longer;
                return true;
            default:
                mode = DedupeMode.Shorter;
                return false;
        }
    }

    private static string ResolveWorkingDirectory(string rootDirectory)
    {
        var resolved = Path.GetFullPath(rootDirectory);
        if (!Directory.Exists(resolved))
        {
            throw new ArgumentException($"Cannot access directory: {rootDirectory}");
        }

        return resolved;
    }

    private static void PrintHelp()
    {
        Console.WriteLine(
            """
            Usage: lshash [--algorithm=NAME] [-r|--recursive] [-e PATTERN] [--exclude=PATTERN] [-d [MODE]] [-q|--quiet] [DIRECTORY]

            NAME can be one of:
              blake3, sha256, sha512, sha1, md5, blake2

            MODE can be one of:
              newer, older, shorter, longer

            Options:
              -r, --recursive            Include files from subdirectories
              -e, --exclude PATTERN      Exclude files matching PATTERN (repeatable)
                  --exclude=PATTERN      Exclude files matching PATTERN (repeatable)
              -d, --dedupe [MODE]        Dedupe files with same hash in each directory
                  --dedupe=MODE          Keep one file by MODE, move others to .dups/
              --all-directory            With -d, dedupe using all files in directory by hash (ignores filename adjacency)
              -q, --quiet                Only print duplicate (green) file lines

            Short-option stacking:
              One-letter switches can be stacked in any order, for example: -rd, -dr, -re '*.log'.

            Examples:
              lshash
              lshash --algorithm=sha256
              lshash -r
              lshash -r -e '*.log' -e '*.tmp'
              lshash --algorithm=sha512 --exclude='build/*' --exclude='*.bak'
              lshash -d
              lshash -r --dedupe newer
              lshash -d --all-directory
              lshash --dedupe=longer
              lshash -dr newer
              lshash -rq /path/to/scan
            """
        );
    }

    private static void ProcessRecursive(Options options, SummaryStats summaryStats)
    {
        var previousHash = string.Empty;
        foreach (var directory in EnumerateDirectoriesDepthFirst())
        {
            summaryStats.DirectoriesTraversed++;
            ProcessDirectory(directory, options, summaryStats, ref previousHash);
        }
    }

    private static void ProcessSingleDirectory(string directory, Options options, SummaryStats summaryStats)
    {
        var previousHash = string.Empty;
        ProcessDirectory(directory, options, summaryStats, ref previousHash);
    }

    private static void ProcessDirectory(string directory, Options options, SummaryStats summaryStats, ref string previousHash)
    {
        var files = GetFilesForDirectory(directory);
        if (options.ExcludePatterns.Count > 0)
        {
            files = files.Where(path => !options.ExcludePatterns.Any(pattern => GlobMatch(path, pattern))).ToList();
        }

        summaryStats.TotalFilesScanned += files.Count;

        if (files.Count == 0)
        {
            return;
        }

        if (options.DedupeEnabled)
        {
            previousHash = PrintWithDedupe(files, options.Algorithm, options.DedupeMode, options.Quiet, options.AllDirectoryDedupe, summaryStats, previousHash);
        }
        else
        {
            previousHash = PrintNonDedupe(files, options.Algorithm, options.Quiet, summaryStats, previousHash);
        }
    }

    private static IEnumerable<string> EnumerateDirectoriesDepthFirst()
    {
        var stack = new Stack<string>();
        stack.Push(".");

        while (stack.Count > 0)
        {
            var dir = stack.Pop();
            yield return dir;

            var absoluteDir = dir == "." ? WorkingDirectory : GetAbsolutePath(dir);
            var subDirs = Directory
                .EnumerateDirectories(absoluteDir)
                .Where(path => !string.Equals(Path.GetFileName(path), ".dups", StringComparison.Ordinal))
                .Select(path => Path.GetFileName(path))
                .OrderBy(name => name, StringComparer.Ordinal)
                .ToList();

            for (var i = subDirs.Count - 1; i >= 0; i--)
            {
                var child = subDirs[i];
                stack.Push(dir == "." ? child : $"{dir}/{child}");
            }
        }
    }

    private static List<string> GetFilesForDirectory(string directory)
    {
        var absoluteDir = directory == "." ? WorkingDirectory : GetAbsolutePath(directory);
        var files = new List<string>();

        foreach (var file in Directory.EnumerateFiles(absoluteDir, "*", SearchOption.TopDirectoryOnly))
        {
            files.Add(ToUnixRelativePath(file));
        }

        files.Sort(StringComparer.Ordinal);
        return files;
    }

    private static string PrintNonDedupe(List<string> files, HashAlgorithmKind algorithm, bool quiet, SummaryStats summaryStats, string previousHash)
    {
        var maxNameLen = files.Max(path => path.Length);

        foreach (var file in files)
        {
            if (!TryComputeHash(file, algorithm, out var hash) || hash is null)
            {
                if (!quiet)
                {
                    Console.WriteLine($"{file.PadRight(maxNameLen)}  <hash unavailable>");
                }

                continue;
            }

            var isDuplicate = previousHash.Length > 0 && hash == previousHash;
            if (isDuplicate)
            {
                summaryStats.DuplicateFilesFound++;
            }

            var displayHash = isDuplicate ? $"{Green}{hash}{Reset}" : hash;

            if (!quiet || isDuplicate)
            {
                Console.WriteLine($"{file.PadRight(maxNameLen)}  {displayHash}");
            }

            previousHash = hash;
        }

        return previousHash;
    }

    private static string PrintWithDedupe(List<string> files, HashAlgorithmKind algorithm, DedupeMode dedupeMode, bool quiet, bool allDirectoryDedupe, SummaryStats summaryStats, string previousHash)
    {
        const string movedSuffix = " (moved to .dups/)";
        var maxNameLen = files.Max(path => path.Length + movedSuffix.Length);

        var runActive = false;
        var runHash = string.Empty;
        var runEntries = new List<FileEntry>();

        void PrintEntry(FileEntry entry)
        {
            string displayHash;
            var isDuplicate = false;
            if (entry.HashAvailable && entry.Hash is not null)
            {
                isDuplicate = previousHash.Length > 0 && entry.Hash == previousHash;
                if (isDuplicate)
                {
                    summaryStats.DuplicateFilesFound++;
                }

                displayHash = isDuplicate ? $"{Green}{entry.Hash}{Reset}" : entry.Hash;
                previousHash = entry.Hash;
            }
            else
            {
                displayHash = "<hash unavailable>";
            }

            if (quiet && !isDuplicate)
            {
                return;
            }

            var displayName = entry.Moved ? entry.RelativePath + movedSuffix : entry.RelativePath;
            displayName = displayName.PadRight(maxNameLen);

            if (entry.Moved)
            {
                Console.WriteLine($"{Italic}{displayName}{Reset}  {displayHash}");
            }
            else
            {
                Console.WriteLine($"{displayName}  {displayHash}");
            }
        }

        void FlushRun()
        {
            if (!runActive)
            {
                return;
            }

            var hashableIndices = runEntries
                .Select((entry, index) => (entry, index))
                .Where(tuple => tuple.entry.HashAvailable)
                .Select(tuple => tuple.index)
                .ToList();

            if (hashableIndices.Count >= 2)
            {
                var keepIndex = hashableIndices[0];
                for (var i = 1; i < hashableIndices.Count; i++)
                {
                    var candidateIndex = hashableIndices[i];
                    if (ShouldReplace(runEntries[candidateIndex], runEntries[keepIndex], dedupeMode))
                    {
                        keepIndex = candidateIndex;
                    }
                }

                foreach (var index in hashableIndices)
                {
                    if (index == keepIndex)
                    {
                        continue;
                    }

                    if (TryMoveToDups(runEntries[index]))
                    {
                        runEntries[index].Moved = true;
                        summaryStats.DuplicateFilesMoved++;
                    }
                }
            }

            foreach (var entry in runEntries)
            {
                PrintEntry(entry);
            }

            runEntries.Clear();
            runActive = false;
            runHash = string.Empty;
        }

        void ApplyAllDirectoryDedupe(List<FileEntry> entries)
        {
            var groups = new Dictionary<string, List<int>>(StringComparer.Ordinal);
            for (var i = 0; i < entries.Count; i++)
            {
                var entry = entries[i];
                if (!entry.HashAvailable || entry.Hash is null)
                {
                    continue;
                }

                if (!groups.TryGetValue(entry.Hash, out var indices))
                {
                    indices = new List<int>();
                    groups[entry.Hash] = indices;
                }

                indices.Add(i);
            }

            foreach (var indices in groups.Values)
            {
                if (indices.Count < 2)
                {
                    continue;
                }

                var keepIndex = indices[0];
                for (var i = 1; i < indices.Count; i++)
                {
                    var candidateIndex = indices[i];
                    if (ShouldReplace(entries[candidateIndex], entries[keepIndex], dedupeMode))
                    {
                        keepIndex = candidateIndex;
                    }
                }

                foreach (var index in indices)
                {
                    if (index == keepIndex)
                    {
                        continue;
                    }

                    if (TryMoveToDups(entries[index]))
                    {
                        entries[index].Moved = true;
                        summaryStats.DuplicateFilesMoved++;
                    }
                }
            }
        }

        if (allDirectoryDedupe)
        {
            var entries = files.Select(file => BuildEntry(file, algorithm)).ToList();
            ApplyAllDirectoryDedupe(entries);

            foreach (var entry in entries)
            {
                PrintEntry(entry);
            }

            return previousHash;
        }

        foreach (var file in files)
        {
            var entry = BuildEntry(file, algorithm);

            if (!runActive)
            {
                if (!entry.HashAvailable)
                {
                    PrintEntry(entry);
                    continue;
                }

                runActive = true;
                runHash = entry.Hash!;
                runEntries.Add(entry);
                continue;
            }

            if (!entry.HashAvailable)
            {
                runEntries.Add(entry);
                continue;
            }

            if (entry.Hash == runHash)
            {
                runEntries.Add(entry);
                continue;
            }

            FlushRun();

            runActive = true;
            runHash = entry.Hash!;
            runEntries.Add(entry);
        }

        FlushRun();

        return previousHash;
    }

    private static void PrintSummary(Options options, SummaryStats summaryStats)
    {
        var duplicatesReported = options.DedupeEnabled ? summaryStats.DuplicateFilesMoved : summaryStats.DuplicateFilesFound;
        var duplicatePhrase = options.DedupeEnabled ? "were found and moved" : "were found";
        var duplicatePercent = FormatPercent(duplicatesReported, summaryStats.TotalFilesScanned);

        if (options.Recursive)
        {
            Console.WriteLine(
                $"Summary: scanned {summaryStats.TotalFilesScanned} file(s); {duplicatesReported} duplicate file(s) {duplicatePhrase} ({duplicatePercent}% of scanned files); {summaryStats.DirectoriesTraversed} directories were traversed."
            );
            return;
        }

        Console.WriteLine(
            $"Summary: scanned {summaryStats.TotalFilesScanned} file(s); {duplicatesReported} duplicate file(s) {duplicatePhrase} ({duplicatePercent}% of scanned files)."
        );
    }

    private static string FormatPercent(long numerator, long denominator)
    {
        if (denominator <= 0)
        {
            return "0.00";
        }

        var basisPoints = numerator * 10000 / denominator;
        return FormattableString.Invariant($"{basisPoints / 100}.{basisPoints % 100:00}");
    }

    private static FileEntry BuildEntry(string file, HashAlgorithmKind algorithm)
    {
        var hashAvailable = TryComputeHash(file, algorithm, out var hash);
        var mtimeAvailable = TryGetMtimeSeconds(file, out var mtime);

        return new FileEntry
        {
            RelativePath = file,
            DirectoryPath = GetDirectoryPath(file),
            BaseName = Path.GetFileName(file) ?? file,
            Hash = hash,
            HashAvailable = hashAvailable,
            MtimeSeconds = mtimeAvailable ? mtime : 0,
            MtimeAvailable = mtimeAvailable,
            Moved = false,
        };
    }

    private static bool ShouldReplace(FileEntry candidate, FileEntry current, DedupeMode mode)
    {
        return mode switch
        {
            DedupeMode.Newer => candidate.MtimeAvailable && (!current.MtimeAvailable || candidate.MtimeSeconds > current.MtimeSeconds),
            DedupeMode.Older => candidate.MtimeAvailable && (!current.MtimeAvailable || candidate.MtimeSeconds < current.MtimeSeconds),
            DedupeMode.Shorter => candidate.BaseName.Length < current.BaseName.Length,
            DedupeMode.Longer => candidate.BaseName.Length > current.BaseName.Length,
            _ => false,
        };
    }

    private static bool TryMoveToDups(FileEntry entry)
    {
        try
        {
            var sourcePath = GetAbsolutePath(entry.RelativePath);
            var dupsDirRel = entry.DirectoryPath == "." ? ".dups" : $"{entry.DirectoryPath}/.dups";
            var dupsDirAbs = GetAbsolutePath(dupsDirRel);
            Directory.CreateDirectory(dupsDirAbs);

            var targetPath = Path.Combine(dupsDirAbs, entry.BaseName);
            if (File.Exists(targetPath))
            {
                var suffix = 1;
                while (File.Exists(Path.Combine(dupsDirAbs, $"{entry.BaseName}.dup{suffix}")))
                {
                    suffix++;
                }

                targetPath = Path.Combine(dupsDirAbs, $"{entry.BaseName}.dup{suffix}");
            }

            File.Move(sourcePath, targetPath);
            return true;
        }
        catch (Exception ex)
        {
            Warn("move", entry.RelativePath, ex.Message);
            return false;
        }
    }

    private static bool TryComputeHash(string relativePath, HashAlgorithmKind algorithm, out string? hash)
    {
        try
        {
            var absolutePath = GetAbsolutePath(relativePath);
            hash = algorithm switch
            {
                HashAlgorithmKind.Blake3 => ComputeBlake3(absolutePath),
                HashAlgorithmKind.Sha256 => ComputeSystemHash(absolutePath, SHA256.Create()),
                HashAlgorithmKind.Sha512 => ComputeSystemHash(absolutePath, SHA512.Create()),
                HashAlgorithmKind.Sha1 => ComputeSystemHash(absolutePath, SHA1.Create()),
                HashAlgorithmKind.Md5 => ComputeSystemHash(absolutePath, MD5.Create()),
                HashAlgorithmKind.Blake2 => ComputeBlake2b512(absolutePath),
                _ => throw new InvalidOperationException("Unsupported hash algorithm."),
            };

            return true;
        }
        catch (Exception ex)
        {
            Warn("hash", relativePath, ex.Message);
            hash = null;
            return false;
        }
    }

    private static bool TryGetMtimeSeconds(string relativePath, out long mtimeSeconds)
    {
        try
        {
            var absolutePath = GetAbsolutePath(relativePath);
            mtimeSeconds = new DateTimeOffset(File.GetLastWriteTimeUtc(absolutePath)).ToUnixTimeSeconds();
            return true;
        }
        catch (Exception ex)
        {
            Warn("read mtime", relativePath, ex.Message);
            mtimeSeconds = 0;
            return false;
        }
    }

    private static void Warn(string action, string path, string details)
    {
        Console.Error.WriteLine($"Warning: cannot {action} '{path}': {details}");
    }

    private static string ComputeSystemHash(string filePath, HashAlgorithm algorithm)
    {
        using (algorithm)
        using (var stream = File.OpenRead(filePath))
        {
            var hash = algorithm.ComputeHash(stream);
            return Convert.ToHexString(hash).ToLowerInvariant();
        }
    }

    private static string ComputeBlake3(string filePath)
    {
        var hasher = Hasher.New();
        var buffer = ArrayPool<byte>.Shared.Rent(64 * 1024);

        try
        {
            using var stream = File.OpenRead(filePath);
            while (true)
            {
                var bytesRead = stream.Read(buffer, 0, buffer.Length);
                if (bytesRead == 0)
                {
                    break;
                }

                hasher.Update(buffer.AsSpan(0, bytesRead));
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }

        return hasher.Finalize().ToString().ToLowerInvariant();
    }

    private static string ComputeBlake2b512(string filePath)
    {
        var digest = new Blake2bDigest(512);
        var buffer = ArrayPool<byte>.Shared.Rent(64 * 1024);

        try
        {
            using var stream = File.OpenRead(filePath);
            while (true)
            {
                var bytesRead = stream.Read(buffer, 0, buffer.Length);
                if (bytesRead == 0)
                {
                    break;
                }

                digest.BlockUpdate(buffer, 0, bytesRead);
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }

        var output = new byte[digest.GetDigestSize()];
        digest.DoFinal(output, 0);
        return Convert.ToHexString(output).ToLowerInvariant();
    }

    private static string GetDirectoryPath(string relativePath)
    {
        var normalized = relativePath.Replace('\\', '/');
        var slash = normalized.LastIndexOf('/');
        return slash >= 0 ? normalized[..slash] : ".";
    }

    private static string ToUnixRelativePath(string absolutePath)
    {
        var relative = Path.GetRelativePath(WorkingDirectory, absolutePath);
        return relative.Replace(Path.DirectorySeparatorChar, '/').Replace(Path.AltDirectorySeparatorChar, '/');
    }

    private static string GetAbsolutePath(string relativePath)
    {
        var local = relativePath.Replace('/', Path.DirectorySeparatorChar);
        return Path.GetFullPath(Path.Combine(WorkingDirectory, local));
    }

    private static bool GlobMatch(string input, string pattern)
    {
        var regex = GlobToRegex(pattern);
        return Regex.IsMatch(input, regex, RegexOptions.CultureInvariant);
    }

    private static string GlobToRegex(string pattern)
    {
        var sb = new StringBuilder();
        sb.Append('^');

        foreach (var ch in pattern)
        {
            switch (ch)
            {
                case '*':
                    sb.Append(".*");
                    break;
                case '?':
                    sb.Append('.');
                    break;
                case '\\':
                case '.':
                case '+':
                case '(':
                case ')':
                case '|':
                case '^':
                case '$':
                case '{':
                case '}':
                    sb.Append('\\').Append(ch);
                    break;
                default:
                    sb.Append(ch);
                    break;
            }
        }

        sb.Append('$');
        return sb.ToString();
    }
}