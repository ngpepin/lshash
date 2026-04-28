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
}

internal sealed class FileEntry
{
    public required string RelativePath { get; init; }

    public required string DirectoryPath { get; init; }

    public required string BaseName { get; init; }

    public required string Hash { get; init; }

    public required long MtimeSeconds { get; init; }

    public bool Moved { get; set; }
}

internal static class Program
{
    private const string Green = "\u001b[32m";
    private const string Italic = "\u001b[3m";
    private const string Reset = "\u001b[0m";

    private static readonly string WorkingDirectory = Directory.GetCurrentDirectory();

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

            var files = DiscoverFiles(options.Recursive);
            if (options.ExcludePatterns.Count > 0)
            {
                files = files.Where(path => !options.ExcludePatterns.Any(pattern => GlobMatch(path, pattern))).ToList();
            }

            if (files.Count == 0)
            {
                return 0;
            }

            if (!options.DedupeEnabled)
            {
                PrintNonDedupe(files, options.Algorithm);
                return 0;
            }

            PrintWithDedupe(files, options.Algorithm, options.DedupeMode);
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

                    if (argIndex + 1 < args.Length && !args[argIndex + 1].StartsWith("-", StringComparison.Ordinal))
                    {
                        argIndex++;
                        options.DedupeMode = ParseDedupeMode(args[argIndex]);
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

            throw new ArgumentException($"Unknown option: {arg}");
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

                    if (Regex.IsMatch(remainder, "^[rhed]+$", RegexOptions.CultureInvariant))
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
            && !args[argIndex + 1].StartsWith("-", StringComparison.Ordinal))
        {
            argIndex++;
            options.DedupeMode = ParseDedupeMode(args[argIndex]);
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

    private static void PrintHelp()
    {
        Console.WriteLine(
            """
            Usage: lshash [--algorithm=NAME] [-r|--recursive] [-e PATTERN] [--exclude=PATTERN] [-d [MODE]]

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
              lshash --dedupe=longer
              lshash -dr newer
            """
        );
    }

    private static List<string> DiscoverFiles(bool recursive)
    {
        var results = new List<string>();

        if (!recursive)
        {
            foreach (var file in Directory.EnumerateFiles(WorkingDirectory, "*", SearchOption.TopDirectoryOnly))
            {
                results.Add(ToUnixRelativePath(file));
            }

            results.Sort(StringComparer.Ordinal);
            return results;
        }

        var pendingDirs = new Stack<string>();
        pendingDirs.Push(WorkingDirectory);

        while (pendingDirs.Count > 0)
        {
            var dir = pendingDirs.Pop();

            foreach (var subDir in Directory.EnumerateDirectories(dir))
            {
                if (string.Equals(Path.GetFileName(subDir), ".dups", StringComparison.Ordinal))
                {
                    continue;
                }

                pendingDirs.Push(subDir);
            }

            foreach (var file in Directory.EnumerateFiles(dir, "*", SearchOption.TopDirectoryOnly))
            {
                results.Add(ToUnixRelativePath(file));
            }
        }

        results.Sort(StringComparer.Ordinal);
        return results;
    }

    private static void PrintNonDedupe(List<string> files, HashAlgorithmKind algorithm)
    {
        var maxNameLen = files.Max(path => path.Length);
        var previousHash = string.Empty;

        foreach (var file in files)
        {
            var hash = ComputeHash(file, algorithm);
            var displayHash = previousHash.Length > 0 && hash == previousHash
                ? $"{Green}{hash}{Reset}"
                : hash;

            Console.WriteLine($"{file.PadRight(maxNameLen)}  {displayHash}");
            previousHash = hash;
        }
    }

    private static void PrintWithDedupe(List<string> files, HashAlgorithmKind algorithm, DedupeMode dedupeMode)
    {
        var entries = files.Select(file => new FileEntry
        {
            RelativePath = file,
            DirectoryPath = GetDirectoryPath(file),
            BaseName = Path.GetFileName(file),
            Hash = ComputeHash(file, algorithm),
            MtimeSeconds = GetMtimeSeconds(file),
            Moved = false,
        }).ToList();

        var groups = new Dictionary<string, List<int>>(StringComparer.Ordinal);
        for (var i = 0; i < entries.Count; i++)
        {
            var key = $"{entries[i].DirectoryPath}|{entries[i].Hash}";
            if (!groups.TryGetValue(key, out var indices))
            {
                indices = new List<int>();
                groups[key] = indices;
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

                MoveToDups(entries[index]);
                entries[index].Moved = true;
            }
        }

        var displayNames = entries
            .Select(entry => entry.Moved ? $"{entry.RelativePath} (moved to .dups/)" : entry.RelativePath)
            .ToList();

        var maxNameLen = displayNames.Max(name => name.Length);
        var previousHash = string.Empty;

        for (var i = 0; i < entries.Count; i++)
        {
            var hash = entries[i].Hash;
            var displayHash = previousHash.Length > 0 && hash == previousHash
                ? $"{Green}{hash}{Reset}"
                : hash;

            var displayName = displayNames[i].PadRight(maxNameLen);
            if (entries[i].Moved)
            {
                Console.WriteLine($"{Italic}{displayName}{Reset}  {displayHash}");
            }
            else
            {
                Console.WriteLine($"{displayName}  {displayHash}");
            }

            previousHash = hash;
        }
    }

    private static bool ShouldReplace(FileEntry candidate, FileEntry current, DedupeMode mode)
    {
        return mode switch
        {
            DedupeMode.Newer => candidate.MtimeSeconds > current.MtimeSeconds,
            DedupeMode.Older => candidate.MtimeSeconds < current.MtimeSeconds,
            DedupeMode.Shorter => candidate.BaseName.Length < current.BaseName.Length,
            DedupeMode.Longer => candidate.BaseName.Length > current.BaseName.Length,
            _ => false,
        };
    }

    private static void MoveToDups(FileEntry entry)
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
    }

    private static string ComputeHash(string relativePath, HashAlgorithmKind algorithm)
    {
        var absolutePath = GetAbsolutePath(relativePath);
        return algorithm switch
        {
            HashAlgorithmKind.Blake3 => ComputeBlake3(absolutePath),
            HashAlgorithmKind.Sha256 => ComputeSystemHash(absolutePath, SHA256.Create()),
            HashAlgorithmKind.Sha512 => ComputeSystemHash(absolutePath, SHA512.Create()),
            HashAlgorithmKind.Sha1 => ComputeSystemHash(absolutePath, SHA1.Create()),
            HashAlgorithmKind.Md5 => ComputeSystemHash(absolutePath, MD5.Create()),
            HashAlgorithmKind.Blake2 => ComputeBlake2b512(absolutePath),
            _ => throw new InvalidOperationException("Unsupported hash algorithm."),
        };
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

    private static long GetMtimeSeconds(string relativePath)
    {
        var absolutePath = GetAbsolutePath(relativePath);
        return new DateTimeOffset(File.GetLastWriteTimeUtc(absolutePath)).ToUnixTimeSeconds();
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