module vh;

import bash;

import std.format : format;
import std.stdio;


enum VHInfo
{
    version_ = "0.5.1",
    built = __TIMESTAMP__,
    source = "https://github.com/zorael/vh"
}

version(unittest)
void main()
{
    writeln("All tests completed successfully!");
}
else
void main(string[] args)
{
    import std.array : Appender;
    import std.conv : ConvException;
    import std.getopt;

    Context ctx;

    try
    {
        with (ctx.settings)
        {
            auto result = getopt(args,
                config.stopOnFirstNonOption,
                "lines|n", "Number of lines to display",
                    &lines,
                "colour", "Display with Bash colouring [off|auto|always]",
                    &colourSettingString,
                "color", &colourSettingString,
                "hidden|a", "Display hidden files (--hidden=false to disable)",
                    &showHidden,
                "progress|p", "Display progress bar (dots)",
                    &progress,
                "truncated|t", "Show truncated line count (--truncated=false to disable)",
                    &showTruncated,
                "truncate", &showTruncated,
                "verbose|v", "Enable verbose output",
                    &verbose,
            );

            if (result.helpWanted)
            {
                immutable usageString = "%s\nusage: %s [options] [files|dirs] ...\n"
                    .format(header, args[0]);
                defaultGetoptPrinter(usageString, result.options);
                return;
            }
        }
    }
    catch (const GetOptException e)
    {
        writeln("Error: ", e.msg);
        writeln("--help displays the help screen.");
        return;
    }
    catch (const ConvException e)
    {
        writeln("Error parsing argument: ", e.msg);
        return;
    }
    catch (const Exception e)
    {
        writeln(e.msg);
        return;
    }

    Appender!string sink;
    sink.reserve(2048);  // probably overkill, but at least then no reallocation
    string[] paths = (args.length > 1) ? args[1..$] : [ "." ];

    ctx.populate(paths);
    ctx.process(sink);
    writeln();
    writeln(sink.data);
}


struct Context
{
    Settings settings;
    FileHead[] files;
    size_t skippedFiles;
    size_t skippedDirs;

    struct Settings
    {
        enum ColourSetting { off, auto_, always }

        ColourSetting colourSetting = ColourSetting.auto_;
        uint lines = 3;
        bool showHidden = true;
        bool progress = true;
        bool showTruncated = true;
        bool verbose;

        void colourSettingString(const string nil, const string option) pure @safe
        {
            with (ColourSetting)
            switch (option)
            {
            case "off":
                colourSetting = off;
                break;
            case "auto":
                colourSetting = auto_;
                break;
            case "always":
                colourSetting = always;
                break;
            default:
                throw new Exception(`Invalid colour: "%s"`.format(option));
            }
        }

        bool useColours() const pure nothrow @nogc @safe
        {
            with (ColourSetting)
            version(Posix)
            {
                return (colourSetting == always) || (colourSetting == auto_);
            }
            else version(Windows)
            {
                // auto means off in Windows
                return (colourSetting == always);
            }
            else assert(0, "Unknown platform");
        }
    }
}


struct FileHead
{
    string filename;
    size_t linecount;
    string[] lines;

    this(const string filename, const size_t linecount, string[] lines)
        pure nothrow @nogc @safe
    {
        assert(filename.length, filename);

        this.filename = filename;
        this.linecount = linecount;
        this.lines = lines;  // no need to dup, it's fresh from byLineCopy
    }
}


void populate(ref Context ctx, string[] paths)
{
    import std.algorithm.sorting : sort;
    import std.algorithm.iteration : uniq;
    import std.file : dirEntries, SpanMode, FileException;
    import std.path : exists, isDir, isFile;

    string[] filelist;

    foreach (const path; paths.sort().uniq)
    {
        if (!path.exists)
        {
            writeln();
            writeln(path, " does not exist");
            continue;
        }

        bool dir;

        try
        {
            dir = path.isDir;
        }
        catch (const FileException e)
        {
            // No such file or directory
            // assume it's a file. is there a way to tell?
            ++ctx.skippedFiles;
            continue;
        }

        if (dir)
        {
            auto entries = path.dirEntries(SpanMode.shallow);

            foreach (entry; entries)
            {
                if (ctx.settings.verbose) writeln(entry.name);

                try
                {
                    if (entry.isDir)
                    {
                        // don't recurse
                        ++ctx.skippedDirs;
                        continue;
                    }
                }
                catch (Exception e)
                {
                    // Failed to stat for whatever reason
                    ++ctx.skippedFiles;
                    continue;
                }

                if (ctx.testPath(entry.name, filelist) && ctx.settings.progress)
                {
                    write('.');
                }
                else if (ctx.settings.verbose)
                {
                    writeln("(skipped)");
                }
            }
        }
        else
        {
            if (ctx.settings.verbose) writeln(path);

            if (ctx.testPath(path, filelist) && ctx.settings.progress)
            {
                write('.');
            }
            else if (ctx.settings.verbose)
            {
                writeln("(skipped)");
            }
        }
    }

    foreach (const filename; filelist)
    {
        File(filename, "r").byLineCopy.gather(filename, ctx);
    }
}


void gather(T)(T lines, const string filename, ref Context ctx)
{
    import std.array : Appender;
    import std.range : take;

    Appender!(string[]) sink;

    foreach (const line; lines.take(ctx.settings.lines))
    {
        import std.utf : UTFException, validate;

        try
        {
            validate(line);
            sink.put(line);
        }
        catch (const UTFException e)
        {
            if (ctx.settings.verbose) writeln(e.msg);
            ++ctx.skippedFiles;
            return;
        }
    }

    size_t linecount = sink.data.length;

    foreach (const line; lines)
    {
        // expensive exhaustion
        ++linecount;
    }

    ctx.files ~= FileHead(filename, linecount, sink.data);
}


void process(Sink)(Context ctx, ref Sink sink)
{
    import std.algorithm : SwapStrategy, uniq, sort;
    import std.concurrency : Generator;
    import std.format : formattedWrite;

    Generator!string colourGenerator;

    if (ctx.settings.useColours)
    {
        colourGenerator = new Generator!string(&cycleBashColours);
    }

    size_t longestLength = ctx.files.longestFilenameLength;

    auto uniqueFiles = ctx.files
        .sort!((a,b) => (a.filename < b.filename), SwapStrategy.stable)
        .uniq;

    foreach (const filehead; uniqueFiles)
    {
        if (ctx.settings.useColours)
        {
            sink.put(colourGenerator.front);
            colourGenerator.popFront();
        }

        size_t linesConsumed;
        bool linesWerePrinted;

        if (!filehead.linecount)
        {
            immutable pattern = " %-*s  0: %s\n";

            sink.formattedWrite(pattern, longestLength,
                filehead.filename.withoutDotSlash,
                bashResetToken ~ "< empty >");
            continue;
        }

        foreach (immutable lineNumber, const line; filehead.lines)
        {
            enum pattern = " %-*s  %d: %s\n";
            immutable filename = (lineNumber == 0) ?
                filehead.filename.withoutDotSlash : string.init;

            sink.formattedWrite(pattern, longestLength, filename,
                lineNumber+1, line);
            linesWerePrinted = true;
            ++linesConsumed;
        }

        if (!ctx.settings.showTruncated)
        {
            sink.formattedWrite(" %-*s%s  [...]\n", longestLength,
                filehead.filename.withoutDotSlash, bashResetToken);
        }
        else if (filehead.linecount > linesConsumed)
        {
            immutable linesTruncated = (filehead.linecount - linesConsumed);
            enum truncatedPattern = " %-*s%s  [%d %s truncated]\n";

            if (linesWerePrinted)
            {
                sink.formattedWrite(truncatedPattern, longestLength,
                    string.init,
                    bashResetToken, linesTruncated,
                    linesTruncated.plurality("line", "lines"));
            }
            else
            {
                sink.formattedWrite(truncatedPattern, longestLength,
                    filehead.filename.withoutDotSlash,
                    bashResetToken, linesTruncated,
                    linesTruncated.plurality("line", "lines"));
            }
        }
    }

    if (ctx.settings.useColours)
    {
        sink.put(bashResetToken);
    }

    ctx.summarise(sink);
}


void summarise(Sink)(const Context ctx, Sink sink)
{
    import std.format : formattedWrite;

    sink.formattedWrite("\n %d %s listed", ctx.files.length,
        ctx.files.length.plurality("file", "files"));

    if (ctx.skippedFiles || ctx.skippedDirs)
    {
        sink.put(", with ");
    }
    else
    {
        sink.put('.');
        return;
    }

    if (ctx.skippedFiles)
    {
        sink.formattedWrite("%d %s ", ctx.skippedFiles,
            ctx.skippedFiles.plurality("file", "files"));

        if (ctx.skippedDirs) sink.put("and ");
    }

    if (ctx.skippedDirs)
    {
        sink.formattedWrite("%d %s ", ctx.skippedDirs,
            ctx.skippedDirs.plurality("directory", "directories"));
    }

    if (ctx.skippedFiles || ctx.skippedDirs)
    {
        sink.put("skipped.");
    }
}


bool testPath(ref Context ctx, const string filename, ref string[] filelist) @safe
{
    if (filename.isNormalFile(ctx.settings) && filename.canBeRead)
    {
        filelist ~= filename;
        return true;
    }
    else
    {
        // not a normal file (FIFO etc) or reading threw exception
        ++ctx.skippedFiles;
        return false;
    }
}


bool isNormalFile(const string filename, const Context.Settings settings) @safe @property
{
    import std.file : getAttributes, isFile, FileException;

    try
    {
        version(Posix)
        {
            import core.sys.posix.sys.stat : S_IFBLK, S_IFCHR, S_IFIFO;
            import std.path : baseName;

            if (!settings.showHidden && (filename.baseName[0] == '.'))
            {
                return false;
            }

            return filename.isFile &&
                !(getAttributes(filename) & (S_IFBLK | S_IFCHR | S_IFIFO));
        }
        else version(Windows)
        {
            import core.sys.windows.windows;

            /* FILE_ATTRIBUTE_{DIRECTORY,COMPRESSED,DEVICE,ENCRYPTED,HIDDEN,
                               NORMAL,NOT_CONTENT_INDEXED,OFFLINE,READONLY,
                               REPARSE_POINT,SPARSE_FILE,SYSTEM,TEMPORARY,
                               VALID_FLAGS,VALID_SET_FLAGS} */

            auto attr = getAttributes(filename);

            if (!settings.showHidden && (attr & FILE_ATTRIBUTE_HIDDEN))
            {
                return false;
            }

            return filename.isFile &&
                !(attr & (FILE_ATTRIBUTE_DEVICE | FILE_ATTRIBUTE_SYSTEM));
        }
        else assert(0, "Unknown platform");
    }
    catch (const FileException e)
    {
        // possible broken link
        if (settings.verbose) writeln(e.msg);
        return false;
    }
    catch (const Exception e)
    {
        // always print this as we don't know what can cause it (debug purposes)
        writeln();
        writeln(e.msg);
        return false;
    }
}


bool canBeRead(const string filename) nothrow @safe @property
{
    try File(filename, "r");
    catch (const Exception e)
    {
        return false;
    }

    return true;
}


size_t longestFilenameLength(const FileHead[] fileheads) pure nothrow @nogc @safe @property
{
    size_t longest;

    foreach (const filehead; fileheads)
    {
        immutable dotlessLength = filehead.filename.withoutDotSlash.length;
        longest = (dotlessLength > longest) ? dotlessLength : longest;
    }

    return longest;
}


string withoutDotSlash(const string filename) pure nothrow @nogc @safe @property
{
    if (filename.length < 3) return filename;

    version(Posix)
    {
        return (filename[0..2] == "./") ? filename[2..$] : filename;
    }
    else version(Windows)
    {
        return (filename[0..2] == `.\`) ? filename[2..$] : filename;
    }
    else assert(0, "Unknown platform");
}

@safe unittest
{
    {
        immutable without = "./herp".withoutDotSlash;
        assert((without == "herp"), without);
    }
    {
        immutable without = "./subdir/thing".withoutDotSlash;
        assert((without == "subdir/thing"), without);
    }
    {
        immutable without = "basename".withoutDotSlash;
        assert((without == "basename"), without);
    }
    {
        immutable without = "./.".withoutDotSlash;
        assert((without == "."), without);
    }
}


string plurality(ptrdiff_t num, string singular, string plural) pure nothrow @nogc @safe
{
    return ((num == 1) || (num == -1)) ? singular : plural;
}

@safe unittest
{
    {
        immutable singular = 1.plurality("cat", "cats");
        assert((singular == "cat"), singular);
    }
    {
        immutable singular = (-5).plurality("dog", "dogs");
        assert((singular == "dogs"), singular);
    }
    {
        immutable plural = 0.plurality("banana", "bananas");
        assert((plural == "bananas"), plural);
    }
    {
        immutable plural = 999.plurality("", "");
        assert((plural == ""), plural);
    }
}


void cycleBashColours()
{
    import std.concurrency : yield;
    import std.format : format;
    import std.range : cycle;

    alias F = BashForeground;

    static immutable colours =
    [
        F.red,
        F.green,
        F.yellow,
        F.blue,
        F.magenta,
        F.cyan,
        F.lightgrey,
        F.darkgrey,
        F.lightred,
        F.lightgreen,
        F.lightyellow,
        F.lightblue,
        F.lightmagenta,
        F.lightcyan,
        F.white,
    ];

    foreach (const code; colours.cycle)
    {
        yield("%s[%d;%dm".format(BashColourToken, BashFormat.bright, code));
    }
}

@system unittest
{
    import std.concurrency : Generator;

    alias F = BashForeground;

    static immutable colours =
    [
        F.red,
        F.green,
        F.yellow,
        F.blue,
        F.magenta,
        F.cyan,
        F.lightgrey,
        F.darkgrey,
        F.lightred,
        F.lightgreen,
        F.lightyellow,
        F.lightblue,
        F.lightmagenta,
        F.lightcyan,
        F.white,
    ];

    auto colourGenerator = new Generator!string(&cycleBashColours);

    foreach (const colour; colours)
    {
        immutable code = "%s[%d;%dm".format(BashColourToken, BashFormat.bright,
            cast(size_t)colour);

        assert(colourGenerator.front == code);
        colourGenerator.popFront();
    }
}


string header() pure @safe @property
{
    import std.array : Appender;
    import std.format : formattedWrite;

    Appender!string sink;
    sink.reserve(128);  // usually 91 characters

    with (VHInfo)
    {
        sink.formattedWrite("verbose head v%s, built %s\n",
            cast(string)version_, cast(string)built);
        sink.formattedWrite("$ git clone %s.git\n", cast(string)source);
    }

    return sink.data;
}


enum bashResetToken = "%s[%dm".format(BashColourToken, BashReset.all);
