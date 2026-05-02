using System.Buffers;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
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

    public bool GlobalDedupe { get; set; }

    public bool PromptDelete { get; set; }

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

    public bool ExcludedExecutableProgram { get; init; }

    public bool Moved { get; set; }

    public string? MovedToPath { get; set; }
}

internal sealed class SummaryStats
{
    public long TotalFilesScanned { get; set; }

    public long DuplicateFilesFound { get; set; }

    public long DuplicateFilesMoved { get; set; }

    public long DirectoriesTraversed { get; set; }

    public HashSet<string> DupsDirectories { get; } = new(StringComparer.Ordinal);
}

internal enum Blake3Backend
{
    Gpu,
    Cpu,
}

internal static class NativeBlake3Gpu
{
    private const string LibraryName = "libblake3gpu.so";

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr blake3_gpu_create(int maxChunks);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void blake3_gpu_destroy(IntPtr ctx);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int blake3_gpu_hash_file(
        IntPtr ctx,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path,
        byte[] outHash32
    );
}

internal sealed class Blake3GpuContext : IDisposable
{
    private IntPtr _ctx;

    public Blake3GpuContext(int maxChunks)
    {
        _ctx = NativeBlake3Gpu.blake3_gpu_create(maxChunks);

        if (_ctx == IntPtr.Zero)
        {
            throw new InvalidOperationException("Failed to create CUDA BLAKE3 context.");
        }
    }

    public byte[] HashFile(string path)
    {
        if (_ctx == IntPtr.Zero)
        {
            throw new ObjectDisposedException(nameof(Blake3GpuContext));
        }

        var hash = new byte[32];
        var rc = NativeBlake3Gpu.blake3_gpu_hash_file(_ctx, path, hash);

        if (rc != 0)
        {
            throw new InvalidOperationException($"GPU hash failed with error code {rc}.");
        }

        return hash;
    }

    public void Dispose()
    {
        if (_ctx != IntPtr.Zero)
        {
            NativeBlake3Gpu.blake3_gpu_destroy(_ctx);
            _ctx = IntPtr.Zero;
        }

        GC.SuppressFinalize(this);
    }

    ~Blake3GpuContext()
    {
        Dispose();
    }
}

internal static class Program
{
    private const string BoldYellow = "\u001b[1;33m";
    private const string Green = "\u001b[32m";
    private const string Gray = "\u001b[37m";
    private const string Italic = "\u001b[3m";
    private const string Reset = "\u001b[0m";
    private const char MiddleDot = '\u00B7';
    private const Blake3Backend DefaultBlake3Backend = Blake3Backend.Cpu; // CPU by default
    private const int DefaultGpuMaxChunks = 1 << 20;
    private static readonly Regex AnsiEscapeRegex = new("\u001B\\[[0-9;]*m", RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static string WorkingDirectory = Directory.GetCurrentDirectory();
    private static Blake3Backend? SelectedBlake3Backend;
    private static bool Blake3GpuFallbackLogged;
    private static int? CachedConsoleWidth;

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

            if (IsPromptDeleteGarbageCollectMode(options))
            {
                RunPromptDeleteGarbageCollectMode();
                return 0;
            }

            var summaryStats = new SummaryStats();

            if (options.DedupeEnabled && options.GlobalDedupe)
            {
                ProcessGlobalDedupe(options, summaryStats);
            }
            else if (options.Recursive)
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

                if (arg is "--directory" or "--all-directory")
                {
                    options.AllDirectoryDedupe = true;
                    continue;
                }

                if (arg == "--global")
                {
                    options.GlobalDedupe = true;
                    continue;
                }

                if (arg == "--prompt-delete")
                {
                    options.PromptDelete = true;
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
            Usage: lshash [--algorithm=NAME] [-r|--recursive] [-e PATTERN] [--exclude=PATTERN] [-d [MODE]] [--directory] [--global] [--prompt-delete] [-q|--quiet] [DIRECTORY]

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
                                          Valid MODE values: newer, older, shorter, longer
              --directory                With -d, dedupe using all files in directory by hash (ignores filename adjacency)
              --all-directory            Backward-compatible alias for --directory
              --global                   With -d and -r, dedupe globally across the full recursive tree by hash.
                                         With -d only, behaves like --directory for the selected directory.
              --prompt-delete            With -d, after listing .dups directories, prompt y/N to delete them.
                                          When used alone (or with only DIRECTORY), recursively gather existing .dups directories,
                                          list them, and prompt y/N to delete them.
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
              lshash -d --directory
              lshash -r -d shorter --global
              lshash --dedupe=longer
                            lshash --prompt-delete
                            lshash --prompt-delete /path/to/scan
              lshash -dr newer
              lshash -rq /path/to/scan
            """
        );
    }

    private static bool IsPromptDeleteGarbageCollectMode(Options options)
    {
        return options.PromptDelete
            && !options.DedupeEnabled
            && !options.Recursive
            && options.ExcludePatterns.Count == 0
            && !options.Quiet
            && !options.AllDirectoryDedupe
            && !options.GlobalDedupe
            && options.Algorithm == HashAlgorithmKind.Blake3;
    }

    private static void ProcessGlobalDedupe(Options options, SummaryStats summaryStats)
    {
        var files = new List<string>();

        if (options.Recursive)
        {
            foreach (var directory in EnumerateDirectoriesDepthFirst())
            {
                summaryStats.DirectoriesTraversed++;
                var directoryFiles = GetFilesForDirectory(directory);
                if (options.ExcludePatterns.Count > 0)
                {
                    directoryFiles = directoryFiles
                        .Where(path => !options.ExcludePatterns.Any(pattern => GlobMatch(path, pattern)))
                        .ToList();
                }

                files.AddRange(directoryFiles);
            }
        }
        else
        {
            files = GetFilesForDirectory(".");
            if (options.ExcludePatterns.Count > 0)
            {
                files = files.Where(path => !options.ExcludePatterns.Any(pattern => GlobMatch(path, pattern))).ToList();
            }
        }

        summaryStats.TotalFilesScanned += files.Count;
        if (files.Count == 0)
        {
            return;
        }

        if (!options.Recursive)
        {
            var previousHash = string.Empty;
            PrintWithDedupe(files, options.Algorithm, options.DedupeMode, options.Quiet, allDirectoryDedupe: true, summaryStats, previousHash);
            return;
        }

        PrintWithGlobalDedupe(files, options.Algorithm, options.DedupeMode, options.Quiet, writeMetadata: true, summaryStats);
    }

    private static void RunPromptDeleteGarbageCollectMode()
    {
        var dupsDirectories = CollectExistingDupsDirectories();
        if (dupsDirectories.Count == 0)
        {
            Console.WriteLine($"{Green}No .dups directories were found.{Reset}");
            return;
        }

        foreach (var dupsDir in dupsDirectories.OrderBy(path => path, StringComparer.Ordinal))
        {
            Console.WriteLine($"{Green}{dupsDir}{Reset}");
        }

        PromptDeleteDupsDirectories(dupsDirectories);
    }

    private static HashSet<string> CollectExistingDupsDirectories()
    {
        var dupsDirectories = new HashSet<string>(StringComparer.Ordinal);
        var stack = new Stack<string>();
        stack.Push(WorkingDirectory);

        while (stack.Count > 0)
        {
            var currentDirectory = stack.Pop();
            List<string> subDirectories;
            try
            {
                subDirectories = Directory
                    .EnumerateDirectories(currentDirectory)
                    .Where(path => !IsSymlink(path))
                    .OrderBy(path => Path.GetFileName(path), StringComparer.Ordinal)
                    .ToList();
            }
            catch (Exception ex)
            {
                var displayPath = string.Equals(currentDirectory, WorkingDirectory, StringComparison.Ordinal)
                    ? "."
                    : ToUnixRelativePath(currentDirectory);
                Warn("enumerate directories", displayPath, ex.Message);
                continue;
            }

            for (var i = subDirectories.Count - 1; i >= 0; i--)
            {
                var subDirectory = subDirectories[i];
                if (string.Equals(Path.GetFileName(subDirectory), ".dups", StringComparison.Ordinal))
                {
                    dupsDirectories.Add(subDirectory);
                    continue;
                }

                stack.Push(subDirectory);
            }
        }

        return dupsDirectories;
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
            List<string> subDirs;
            try
            {
                subDirs = Directory
                    .EnumerateDirectories(absoluteDir)
                    .Where(path => !IsSymlink(path))
                    .Where(path => !string.Equals(Path.GetFileName(path), ".dups", StringComparison.Ordinal))
                    .Select(path => Path.GetFileName(path))
                    .OrderBy(name => name, StringComparer.Ordinal)
                    .ToList();
            }
            catch (Exception ex)
            {
                Warn("enumerate directories", dir, ex.Message);
                continue;
            }

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

        IEnumerable<string> filePaths;
        try
        {
            filePaths = Directory.EnumerateFiles(absoluteDir, "*", SearchOption.TopDirectoryOnly);
        }
        catch (Exception ex)
        {
            Warn("enumerate files", directory, ex.Message);
            return files;
        }

        foreach (var file in filePaths)
        {
            if (IsSymlink(file))
            {
                continue;
            }

            files.Add(ToUnixRelativePath(file));
        }

        files.Sort(StringComparer.Ordinal);
        return files;
    }

    private static string PrintNonDedupe(List<string> files, HashAlgorithmKind algorithm, bool quiet, SummaryStats summaryStats, string previousHash)
    {
        var maxNameLen = files.Max(path => path.Length);
        var consoleWidth = GetConsoleWidth();

        foreach (var file in files)
        {
            if (!TryComputeHash(file, algorithm, out var hash) || hash is null)
            {
                if (!quiet)
                {
                    var unavailableHash = "<hash unavailable>";
                    var displayName = FormatNameField(file, unavailableHash, consoleWidth, maxNameLen, italicize: false);

                    Console.WriteLine($"{displayName}{unavailableHash}");
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
                var displayName = FormatNameField(file, displayHash, consoleWidth, maxNameLen, italicize: false);

                Console.WriteLine($"{displayName}{displayHash}");
            }

            previousHash = hash;
        }

        return previousHash;
    }

    private static string PrintWithDedupe(List<string> files, HashAlgorithmKind algorithm, DedupeMode dedupeMode, bool quiet, bool allDirectoryDedupe, SummaryStats summaryStats, string previousHash)
    {
        const string movedSuffix = " (moved to .dups/)";
        var maxNameLen = files.Max(path => path.Length + movedSuffix.Length);
        var consoleWidth = GetConsoleWidth();

        var runActive = false;
        var runHash = string.Empty;
        var runEntries = new List<FileEntry>();

        void PrintEntry(FileEntry entry)
        {
            string displayHash;
            var isDuplicate = false;
            if (entry.ExcludedExecutableProgram)
            {
                displayHash = "<excluded executable program>";
            }
            else if (entry.HashAvailable && entry.Hash is not null)
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

            var formattedName = entry.Moved
                ? FormatMovedNameField(entry.RelativePath, movedSuffix, displayHash, consoleWidth, maxNameLen)
                : FormatNameField(entry.RelativePath, displayHash, consoleWidth, maxNameLen, italicize: false);
            Console.WriteLine($"{formattedName}{displayHash}");
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

                    if (TryMoveToDups(runEntries[index], summaryStats))
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

                    if (TryMoveToDups(entries[index], summaryStats))
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

    private static void PrintWithGlobalDedupe(List<string> files, HashAlgorithmKind algorithm, DedupeMode dedupeMode, bool quiet, bool writeMetadata, SummaryStats summaryStats)
    {
        const string movedSuffix = " (moved to .dups/)";
        var maxNameLen = files.Max(path => path.Length + movedSuffix.Length);
        var consoleWidth = GetConsoleWidth();
        var previousHash = string.Empty;

        var entries = files.Select(file => BuildEntry(file, algorithm)).ToList();
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

                if (TryMoveToDups(entries[index], summaryStats))
                {
                    entries[index].Moved = true;
                    summaryStats.DuplicateFilesMoved++;
                }
            }

            if (writeMetadata)
            {
                WriteGlobalDedupeMetadata(entries, indices, dedupeMode);
            }
        }

        foreach (var entry in entries)
        {
            string displayHash;
            var isDuplicate = false;
            if (entry.ExcludedExecutableProgram)
            {
                displayHash = "<excluded executable program>";
            }
            else if (entry.HashAvailable && entry.Hash is not null)
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
                continue;
            }

            var formattedName = entry.Moved
                ? FormatMovedNameField(entry.RelativePath, movedSuffix, displayHash, consoleWidth, maxNameLen)
                : FormatNameField(entry.RelativePath, displayHash, consoleWidth, maxNameLen, italicize: false);
            Console.WriteLine($"{formattedName}{displayHash}");
        }
    }

    private static void WriteGlobalDedupeMetadata(List<FileEntry> entries, List<int> groupIndices, DedupeMode dedupeMode)
    {
        var canonicalEntries = groupIndices.Select(index => entries[index]).ToList();
        foreach (var subject in canonicalEntries)
        {
            if (!subject.Moved || string.IsNullOrWhiteSpace(subject.MovedToPath))
            {
                continue;
            }

            var others = canonicalEntries
                .Where(entry => !ReferenceEquals(entry, subject))
                .Select(entry => new
                {
                    path = GetFinalPath(entry),
                    status = entry.Moved ? "moved" : "kept",
                })
                .ToList();

            var payload = new
            {
                hash = subject.Hash,
                dedupeMode = dedupeMode.ToString().ToLowerInvariant(),
                subject = new
                {
                    path = subject.MovedToPath,
                    status = "moved",
                },
                others,
            };

            var metadataPath = subject.MovedToPath + ".json";
            try
            {
                var json = JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(metadataPath, json + Environment.NewLine);
            }
            catch (Exception ex)
            {
                Warn("write metadata", metadataPath, ex.Message);
            }
        }
    }

    private static string GetFinalPath(FileEntry entry)
    {
        if (entry.Moved && !string.IsNullOrWhiteSpace(entry.MovedToPath))
        {
            return entry.MovedToPath;
        }

        return GetAbsolutePath(entry.RelativePath);
    }

    private static void PrintSummary(Options options, SummaryStats summaryStats)
    {
        var duplicatesReported = options.DedupeEnabled ? summaryStats.DuplicateFilesMoved : summaryStats.DuplicateFilesFound;
        var duplicatePhrase = options.DedupeEnabled ? "were found and moved" : "were found";
        var duplicatePercent = FormatPercent(duplicatesReported, summaryStats.TotalFilesScanned);
        string summaryLine;

        if (options.Recursive)
        {
            summaryLine =
                $"Summary: scanned {summaryStats.TotalFilesScanned} file(s); {duplicatesReported} duplicate file(s) {duplicatePhrase} ({duplicatePercent}% of scanned files); {summaryStats.DirectoriesTraversed} directories were traversed.";
        }
        else
        {
            summaryLine =
                $"Summary: scanned {summaryStats.TotalFilesScanned} file(s); {duplicatesReported} duplicate file(s) {duplicatePhrase} ({duplicatePercent}% of scanned files).";
        }

        Console.WriteLine($"{BoldYellow}{summaryLine}{Reset}");

        if (options.DedupeEnabled)
        {
            PrintDupsDirectories(summaryStats);
        }

        if (options.DedupeEnabled && options.PromptDelete)
        {
            PromptDeleteDupsDirectories(summaryStats.DupsDirectories);
        }
    }

    private static void PrintDupsDirectories(SummaryStats summaryStats)
    {
        if (summaryStats.DupsDirectories.Count == 0)
        {
            Console.WriteLine($"{Green}No duplicates were moved into .dups directories.{Reset}");
            return;
        }

        foreach (var dupsDir in summaryStats.DupsDirectories.OrderBy(path => path, StringComparer.Ordinal))
        {
            Console.WriteLine($"{Green}{dupsDir}{Reset}");
        }
    }

    private static void PromptDeleteDupsDirectories(ICollection<string> dupsDirectories)
    {
        if (dupsDirectories.Count == 0)
        {
            return;
        }

        if (Console.IsInputRedirected)
        {
            Console.Error.WriteLine("Warning: --prompt-delete requested, but input is not interactive; skipping delete prompt.");
            return;
        }

        Console.Write("Delete listed .dups directories? y/N: ");
        var answer = Console.ReadLine();
        if (!string.Equals(answer?.Trim(), "y", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        foreach (var dupsDir in dupsDirectories.OrderBy(path => path, StringComparer.Ordinal))
        {
            try
            {
                Directory.Delete(dupsDir, recursive: true);
            }
            catch (Exception ex)
            {
                Warn("delete", dupsDir, ex.Message);
            }
        }
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
        if (IsExecutableProgramForDedupe(file))
        {
            return new FileEntry
            {
                RelativePath = file,
                DirectoryPath = GetDirectoryPath(file),
                BaseName = Path.GetFileName(file) ?? file,
                Hash = null,
                HashAvailable = false,
                MtimeSeconds = 0,
                MtimeAvailable = false,
                ExcludedExecutableProgram = true,
                Moved = false,
            };
        }

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
            ExcludedExecutableProgram = false,
            Moved = false,
        };
    }

    private static bool IsExecutableProgramForDedupe(string relativePath)
    {
        var absolutePath = GetAbsolutePath(relativePath);
        if (!HasAnyExecuteBit(absolutePath))
        {
            return false;
        }

        if (HasShebangPrefix(absolutePath))
        {
            return true;
        }

        return TryGetMimeType(absolutePath, out var mimeType) && IsProgramMimeType(mimeType);
    }

    private static bool HasShebangPrefix(string filePath)
    {
        try
        {
            using var stream = File.OpenRead(filePath);
            Span<byte> firstTwo = stackalloc byte[2];
            if (stream.Read(firstTwo) < 2)
            {
                return false;
            }

            return firstTwo[0] == (byte)'#' && firstTwo[1] == (byte)'!';
        }
        catch
        {
            return false;
        }
    }

    private static bool HasAnyExecuteBit(string filePath)
    {
        if (OperatingSystem.IsWindows())
        {
            return false;
        }

        try
        {
            var mode = File.GetUnixFileMode(filePath);
            return (mode & (UnixFileMode.UserExecute | UnixFileMode.GroupExecute | UnixFileMode.OtherExecute)) != 0;
        }
        catch
        {
            return false;
        }
    }

    private static bool TryGetMimeType(string filePath, out string mimeType)
    {
        mimeType = string.Empty;

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = "file",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };

            startInfo.ArgumentList.Add("--mime-type");
            startInfo.ArgumentList.Add("-b");
            startInfo.ArgumentList.Add("--");
            startInfo.ArgumentList.Add(filePath);

            using var process = Process.Start(startInfo);
            if (process is null)
            {
                return false;
            }

            var output = process.StandardOutput.ReadToEnd().Trim();
            process.WaitForExit();
            if (process.ExitCode != 0 || output.Length == 0)
            {
                return false;
            }

            mimeType = output;
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static bool IsProgramMimeType(string mimeType)
    {
        var normalized = mimeType.Trim().ToLowerInvariant();

        return normalized is "application/x-executable"
            or "application/x-pie-executable"
            or "application/x-mach-binary"
            or "application/x-dosexec"
            or "application/vnd.microsoft.portable-executable"
            or "application/x-shellscript"
            or "text/x-shellscript"
            or "text/x-python"
            or "text/x-perl"
            or "text/x-ruby"
            or "text/x-php"
            or "text/x-lua"
            or "text/x-tcl"
            || (normalized.StartsWith("application/", StringComparison.Ordinal)
                && normalized.Contains("program", StringComparison.Ordinal))
            || (normalized.StartsWith("text/x-", StringComparison.Ordinal)
                && normalized.Contains("script", StringComparison.Ordinal));
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

    private static bool TryMoveToDups(FileEntry entry, SummaryStats summaryStats)
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
            entry.MovedToPath = targetPath;
            summaryStats.DupsDirectories.Add(dupsDirAbs);
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
        var backend = ResolveBlake3Backend();
        if (backend == Blake3Backend.Cpu)
        {
            return ComputeBlake3Cpu(filePath);
        }

        try
        {
            return ComputeBlake3Gpu(filePath);
        }
        catch (Exception ex) when (CanFallbackFromGpu(ex))
        {
            if (!Blake3GpuFallbackLogged)
            {
                Console.Error.WriteLine($"Warning: GPU BLAKE3 backend unavailable ({ex.Message}). Falling back to CPU backend.");
                Blake3GpuFallbackLogged = true;
            }

            SelectedBlake3Backend = Blake3Backend.Cpu;
            return ComputeBlake3Cpu(filePath);
        }
    }

    private static bool CanFallbackFromGpu(Exception ex)
    {
        return ex is DllNotFoundException
            or EntryPointNotFoundException
            or BadImageFormatException
            or InvalidOperationException;
    }

    private static Blake3Backend ResolveBlake3Backend()
    {
        if (SelectedBlake3Backend is not null)
        {
            return SelectedBlake3Backend.Value;
        }

        var configured = Environment.GetEnvironmentVariable("LSHASH_BLAKE3_BACKEND");
        if (string.IsNullOrWhiteSpace(configured))
        {
            SelectedBlake3Backend = DefaultBlake3Backend;
            return SelectedBlake3Backend.Value;
        }

        SelectedBlake3Backend = configured.Trim().ToLowerInvariant() switch
        {
            "gpu" => Blake3Backend.Gpu,
            "cpu" => Blake3Backend.Cpu,
            _ => throw new InvalidOperationException(
                "Invalid LSHASH_BLAKE3_BACKEND value. Supported values: gpu, cpu."
            ),
        };

        return SelectedBlake3Backend.Value;
    }

    private static string ComputeBlake3Gpu(string filePath)
    {
        using var gpu = new Blake3GpuContext(ComputeRequiredGpuChunks(filePath));
        var hash = gpu.HashFile(filePath);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static string ComputeBlake3Cpu(string filePath)
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

    private static int ComputeRequiredGpuChunks(string filePath)
    {
        const int chunkBytes = 1024;

        var fileInfo = new FileInfo(filePath);
        var requiredChunks = (fileInfo.Length + chunkBytes - 1) / chunkBytes;
        if (requiredChunks <= 0)
        {
            requiredChunks = 1;
        }

        if (requiredChunks > int.MaxValue)
        {
            throw new InvalidOperationException("File is too large for GPU chunk configuration.");
        }

        var maxChunks = 1L;
        while (maxChunks < requiredChunks && maxChunks <= (int.MaxValue / 2))
        {
            maxChunks <<= 1;
        }

        if (maxChunks < requiredChunks)
        {
            maxChunks = requiredChunks;
        }

        var configured = GetConfiguredGpuMaxChunks();
        if (maxChunks < configured)
        {
            maxChunks = configured;
        }

        return (int)maxChunks;
    }

    private static int GetConfiguredGpuMaxChunks()
    {
        var configured = Environment.GetEnvironmentVariable("LSHASH_BLAKE3_GPU_MAX_CHUNKS");
        if (string.IsNullOrWhiteSpace(configured))
        {
            return DefaultGpuMaxChunks;
        }

        if (!int.TryParse(configured, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) || parsed <= 0)
        {
            throw new InvalidOperationException(
                "Invalid LSHASH_BLAKE3_GPU_MAX_CHUNKS value. It must be a positive integer."
            );
        }

        return parsed;
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

    private static bool IsSymlink(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            return (attributes & FileAttributes.ReparsePoint) != 0;
        }
        catch (Exception ex)
        {
            Warn("inspect path", ToUnixRelativePath(path), ex.Message);
            return false;
        }
    }

    private static string GetAbsolutePath(string relativePath)
    {
        var local = relativePath.Replace('/', Path.DirectorySeparatorChar);
        return Path.GetFullPath(Path.Combine(WorkingDirectory, local));
    }

    private static string FormatNameField(string fileName, string displayHash, int consoleWidth, int fallbackNameWidth, bool italicize)
    {
        var fieldWidth = consoleWidth > 0
            ? consoleWidth - VisibleLength(displayHash)
            : fallbackNameWidth;

        if (fieldWidth <= 0)
        {
            fieldWidth = 3;
        }

        var fitted = TruncateRightWithEllipsis(fileName, fieldWidth);
        return FormatFittedNameField(fitted, fieldWidth, italicize);
    }

    private static string FormatMovedNameField(string fileName, string movedSuffix, string displayHash, int consoleWidth, int fallbackNameWidth)
    {
        var fieldWidth = consoleWidth > 0
            ? consoleWidth - VisibleLength(displayHash)
            : fallbackNameWidth;

        if (fieldWidth <= 0)
        {
            fieldWidth = 3;
        }

        string fitted;
        if (fieldWidth <= movedSuffix.Length)
        {
            fitted = TruncateRightWithEllipsis(movedSuffix, fieldWidth);
        }
        else
        {
            var fileWidth = fieldWidth - movedSuffix.Length;
            fitted = TruncateRightWithEllipsis(fileName, fileWidth) + movedSuffix;
        }

        return FormatFittedNameField(fitted, fieldWidth, italicize: true);
    }

    private static string FormatFittedNameField(string fitted, int fieldWidth, bool italicize)
    {
        var sb = new StringBuilder();

        if (italicize)
        {
            sb.Append(Italic);
        }

        sb.Append(fitted);

        if (italicize)
        {
            sb.Append(Reset);
        }

        var padCount = fieldWidth - fitted.Length;
        if (padCount > 0)
        {
            sb.Append(Gray);
            sb.Append(new string(MiddleDot, padCount));
            sb.Append(Reset);
        }

        return sb.ToString();
    }

    private static int GetConsoleWidth()
    {
        if (CachedConsoleWidth is not null)
        {
            return CachedConsoleWidth.Value;
        }

        var outputIsTerminal = !Console.IsOutputRedirected;

        var overrideWidth = Environment.GetEnvironmentVariable("LSHASH_CONSOLE_WIDTH");
        if (int.TryParse(overrideWidth, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedOverride)
            && parsedOverride > 0)
        {
            CachedConsoleWidth = parsedOverride;
            return CachedConsoleWidth.Value;
        }

        if (outputIsTerminal)
        {
            try
            {
                if (Console.WindowWidth > 0)
                {
                    CachedConsoleWidth = Console.WindowWidth;
                    return CachedConsoleWidth.Value;
                }
            }
            catch
            {
                // Fall through to environment variable and command detection.
            }
        }

        var columns = Environment.GetEnvironmentVariable("COLUMNS");
        if (int.TryParse(columns, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedColumns) && parsedColumns > 0)
        {
            CachedConsoleWidth = parsedColumns;
            return CachedConsoleWidth.Value;
        }

        if (outputIsTerminal && TryGetWidthFromTput(out var tputWidth) && tputWidth > 0)
        {
            CachedConsoleWidth = tputWidth;
            return CachedConsoleWidth.Value;
        }

        // Conservative fallback only for interactive terminals.
        CachedConsoleWidth = outputIsTerminal ? 80 : 0;
        return CachedConsoleWidth.Value;
    }

    private static bool TryGetWidthFromTput(out int width)
    {
        width = 0;

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = "tput",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            startInfo.ArgumentList.Add("cols");

            using var process = Process.Start(startInfo);
            if (process is null)
            {
                return false;
            }

            var output = process.StandardOutput.ReadToEnd().Trim();
            process.WaitForExit();
            if (process.ExitCode != 0)
            {
                return false;
            }

            return int.TryParse(output, NumberStyles.Integer, CultureInfo.InvariantCulture, out width) && width > 0;
        }
        catch
        {
            return false;
        }
    }

    private static int VisibleLength(string text)
    {
        var withoutAnsi = AnsiEscapeRegex.Replace(text, string.Empty);
        return withoutAnsi.Length;
    }

    private static string TruncateRightWithEllipsis(string text, int maxWidth)
    {
        if (maxWidth <= 0)
        {
            return string.Empty;
        }

        if (text.Length <= maxWidth)
        {
            return text;
        }

        if (maxWidth <= 3)
        {
            return new string('.', maxWidth);
        }

        return text[..(maxWidth - 3)] + "...";
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