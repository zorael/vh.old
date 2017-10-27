module vh;

import bash;

import std.format : format;
import std.stdio;


enum numberOfLines = 3;
enum bashResetToken = "%s[%dm".format(BashColourToken, BashReset.all);


struct Context
{
    FileHead[] files;
    size_t skippedFiles;
    size_t skippedDirs;
}


struct FileHead
{
    string filename;
    size_t linecount;
    string[] lines;

    bool empty()
    {
        return !lines.length;
    }

    this(const string filename, const size_t linecount, string[] lines)
    {
        assert((filename.length), filename);

        this.filename = filename;
        this.linecount = linecount;
        this.lines = lines;
    }
}


void main(string[] args)
{
    string[] paths = (args.length > 1) ? args[1..$] : [ "." ];

    version(Colour) write(bashResetToken);

    Context ctx;
    ctx.populate(paths);
    writeln();
    ctx.present();
}

void populate(ref Context ctx, string[] paths)
{
    import std.algorithm.sorting : sort;
    import std.algorithm.iteration : uniq;
    import std.file : dirEntries, SpanMode;
    import std.path : exists, isDir, isFile;

    string[] files;

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

                if (entry.name.isNormalFile && entry.name.canBeRead)
                {
                    files ~= entry.name;
                    write(".");
                }
                else
                {
                    // not a normal file (FIFO etc) or reading threw exception
                    ++ctx.skippedFiles;
                }

            }
        }
        else if (path.isNormalFile && path.canBeRead)
        {
            files ~= path;
            write(".");
        }
        else
        {
            // ditto
            ++ctx.skippedFiles;
        }
    }

    foreach (filename; files)
    {
        File(filename, "r").byLineCopy.gather(filename, ctx);
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


bool isNormalFile(const string filename)
{
    import std.file : getAttributes, isFile;

    try
    {
        version(Posix)
        {
            import core.sys.posix.sys.stat : S_IFBLK, S_IFCHR, S_IFIFO;

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

            return filename.isFile && !(getAttributes(filename) &
                (FILE_ATTRIBUTE_DEVICE | FILE_ATTRIBUTE_SYSTEM));
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


void gather(T)(T lines, const string filename, ref Context ctx)
{
    import std.array : Appender;
    import std.range : take;

    Appender!(string[]) sink;

    foreach (line; lines.take(numberOfLines))
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


void present(Context ctx)
{
    import std.algorithm : SwapStrategy, uniq, sort;

    version(Colour)
    {
        import std.concurrency : Generator;
        auto colourGenerator = new Generator!string(&cycleBashColours);
    }

    size_t longestLength = ctx.files.longestFilenameLength;
    immutable pattern = " %%-%ds  %%d: %%s".format(longestLength);

    auto uniqueFiles = ctx.files
        .sort!((a,b) => (a.filename < b.filename), SwapStrategy.stable)
        .uniq;

    foreach (filehead; uniqueFiles)
    {
        version(Colour)
        {
            write(colourGenerator.front);
            colourGenerator.popFront();
        }

        size_t linesConsumed;

        if (filehead.empty)
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

            ++linesConsumed;
        }

        if (filehead.linecount > linesConsumed)
        {
            version(Colour) write(bashResetToken);

            immutable linesTruncated = (filehead.linecount - linesConsumed);
            immutable linecountPattern =
                format!" %%-%ds  [%%d %s truncated]"
                (longestLength, linesTruncated.plurality("line", "lines"));

            writefln(linecountPattern, string.init, linesTruncated);
        }
    }

    writeln(bashResetToken);
    writefln("%d %s listed, with %d %s and %d %s skipped",
        ctx.files.length, ctx.files.length.plurality("file", "files"),
        ctx.skippedFiles, ctx.skippedFiles.plurality("file", "files"),
        ctx.skippedDirs, ctx.skippedDirs.plurality("directory", "directories"));
}


version(Colour)
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


string plurality(ptrdiff_t num, string singular, string plural) pure @nogc nothrow
{
    return ((num == 1) || (num == -1)) ? singular : plural;
}

