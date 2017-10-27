module vh;

import bash;

import std.format : format;
import std.stdio;


enum VHInfo
{
    version_ = "0.4.5",
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
    import std.getopt;

    Context ctx;

    try
    {
        auto helpInformation = getopt(args,
            config.stopOnFirstNonOption,
            "lines|n", "Number of lines to display",
                &ctx.settings.lines,
            "colour", "Display with Bash colouring [off|auto|always]",
                &ctx.settings.colourSettingString,
            "hidden|a", "Display hidden files",
                &ctx.settings.showHidden,
        );

        if (helpInformation.helpWanted)
        {
            immutable usageString = header ~
                "\nusage: %s [options] [files|dirs] ...\n".format(args[0]);

            defaultGetoptPrinter(usageString,
                helpInformation.options);
            return;
        }
    }
    catch (Exception e)
    {
        writeln("Error: ", e.msg);
        writeln("--help displays help screen.");
        return;
    }

    string[] paths = (args.length > 1) ? args[1..$] : [ "." ];

    ctx.populate(paths);
    writeln();
    ctx.present();
}


struct Context
{
    FileHead[] files;
    size_t skippedFiles;
    size_t skippedDirs;

    struct Settings
    {
        enum ColourSetting { off, auto_, always }
        ColourSetting colourSetting = ColourSetting.auto_;
        bool showHidden = true;
        uint lines = 3;

        void colourSettingString(string nil, string option)
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
                writeln("Don't understand colour option ", option);
                assert(0);
            }
        }

        bool useColours()
        {
            with (ColourSetting)
            {
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

    Settings settings;
}


struct FileHead
{
    string filename;
    size_t linecount;
    string[] lines;

    this(const string filename, const size_t linecount, string[] lines)
    {
        assert((filename.length), filename);

        this.filename = filename;
        this.linecount = linecount;
        this.lines = lines;
    }
}


void populate(ref Context ctx, string[] paths)
{
    import std.algorithm.sorting : sort;
    import std.algorithm.iteration : uniq;
    import std.file : dirEntries, SpanMode;
    import std.path : exists, isDir, isFile;

    string[] filelist;

    foreach (path; paths.sort().uniq)
    {
        if (!path.exists)
        {
            writeln();
            writeln(path, " does not exist");
            continue;
        }

        if (path.isDir)
        {
            auto entries = path.dirEntries(SpanMode.shallow);

            foreach (entry; entries)
            {
                if (entry.isDir)
                {
                    // don't recurse
                    ++ctx.skippedDirs;
                    continue;
                }

                if (entry.name.isNormalFile(ctx.settings) && entry.name.canBeRead)
                {
                    filelist ~= entry.name;
                    write(".");
                }
                else
                {
                    // not a normal file (FIFO etc) or reading threw exception
                    ++ctx.skippedFiles;
                }

            }
        }
        else if (path.isNormalFile(ctx.settings) && path.canBeRead)
        {
            filelist ~= path;
            write(".");
        }
        else
        {
            // ditto
            ++ctx.skippedFiles;
        }
    }

    foreach (filename; filelist)
    {
        File(filename, "r").byLineCopy.gather(filename, ctx);
    }
}


void gather(T)(T lines, const string filename, ref Context ctx)
{
    import std.array : Appender;
    import std.range : take;

    Appender!(string[]) sink;

    foreach (line; lines.take(ctx.settings.lines))
    {
        import std.utf : UTFException, validate;

        try
        {
            validate(line);
            sink.put(line);
        }
        catch (UTFException e)
        {
            ++ctx.skippedFiles;
            return;
        }
    }

    size_t linecount = sink.data.length;

    foreach (line; lines)
    {
        // expensive exhaustion
        ++linecount;
    }

    ctx.files ~= FileHead(filename, linecount, sink.data);
}


void present(Context ctx)
{
    import std.algorithm : SwapStrategy, uniq, sort;
    import std.concurrency : Generator;

    Generator!string colourGenerator;

    if (ctx.settings.useColours)
    {
        colourGenerator = new Generator!string(&cycleBashColours);
    }

    size_t longestLength = ctx.files.longestFilenameLength;
    immutable pattern = " %%-%ds  %%d: %%s".format(longestLength);

    auto uniqueFiles = ctx.files
        .sort!((a,b) => (a.filename < b.filename), SwapStrategy.stable)
        .uniq;

    foreach (filehead; uniqueFiles)
    {
        if (ctx.settings.useColours)
        {
            write(colourGenerator.front);
            colourGenerator.popFront();
        }

        size_t linesConsumed;
        bool printedLines;

        if (!filehead.linecount)
        {
            writefln(pattern, filehead.filename.withoutDotSlash,
                     0, bashResetToken ~ "< empty >");
            continue;
        }

        foreach (immutable lineNumber, line; filehead.lines)
        {
            if (lineNumber == 0)
            {
                writefln(pattern, filehead.filename.withoutDotSlash,
                        lineNumber+1, line);
            }
            else
            {
                writefln(pattern, string.init, lineNumber+1, line);
            }

            printedLines = true;
            ++linesConsumed;
        }

        if (filehead.linecount > linesConsumed)
        {

            immutable linesTruncated = (filehead.linecount - linesConsumed);
            immutable truncatedPattern =
                    format!" %%-%ds%s  [%%d %s truncated]"
                    (longestLength, bashResetToken, linesTruncated.plurality("line", "lines"));

            if (printedLines)
            {
                writefln(truncatedPattern, string.init, string.init,
                         linesTruncated);
            }
            else
            {
                writefln(truncatedPattern, filehead.filename.withoutDotSlash,
                         linesTruncated);
            }
        }
    }

    if (ctx.settings.useColours) writeln(bashResetToken);
    writefln("%d %s listed, with %d %s and %d %s skipped",
        ctx.files.length, ctx.files.length.plurality("file", "files"),
        ctx.skippedFiles, ctx.skippedFiles.plurality("file", "files"),
        ctx.skippedDirs, ctx.skippedDirs.plurality("directory", "directories"));
}


bool isNormalFile(const string filename, Context.Settings settings)
{
    import std.file : getAttributes, isFile;

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
                               VALID_FLAGS,VALID_SET_FLAGS}*/

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
    catch (Exception e)
    {
        writeln();
        writeln(e.msg);
        return false;
    }
}


bool canBeRead(const string filename)
{
    try File(filename, "r");
    catch (Exception e)
    {
        return false;
    }

    return true;
}


size_t longestFilenameLength(const FileHead[] fileheads) pure @nogc nothrow
{
    size_t longest;

    foreach (filehead; fileheads)
    {
        immutable dotlessLength = filehead.filename.withoutDotSlash.length;
        longest = (dotlessLength > longest) ? dotlessLength : longest;
    }

    return longest;
}


string withoutDotSlash(const string filename) pure @nogc nothrow
{
    assert((filename.length > 2), filename);
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


string plurality(ptrdiff_t num, string singular, string plural) pure @nogc nothrow
{
    return ((num == 1) || (num == -1)) ? singular : plural;
}


void cycleBashColours()
{
    import std.concurrency : yield;
    import std.format : format;
    import std.range : cycle;

    alias F = BashForeground;

    static immutable colours = [
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

    foreach (code; colours.cycle)
    {
        yield("%s[%d;%dm".format(BashColourToken, BashFormat.bright, code));
    }
}


string header()
{
    import std.array : Appender;
    Appender!string sink;
    sink.reserve(128);  // usually 91 characters

    with (VHInfo)
    {
        sink.put("verbose head v%s, built %s\n"
                 .format(cast(string)version_, cast(string)built));
        sink.put("$ git clone %s\n".format(cast(string)source));
    }

    return sink.data;
}


enum bashResetToken = "%s[%dm".format(BashColourToken, BashReset.all);
