module vh;

import bash;

import std.file : DirEntry;
import std.format : format;
import std.stdio;

version(Posix)
{
	version = Colour;
}

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
		this.filename = filename;
		this.linecount = linecount;
		this.lines = lines;
	}
}


void main(string[] args)
{
	import std.algorithm : sort, uniq;
	import std.file : dirEntries, SpanMode;
	import std.path : exists, isDir, isFile;

	string[] paths = (args.length > 1) ? args[1..$] : [ "." ];
	string[] files;

	version(Colour) write(bashResetToken);

	Context ctx;

	foreach (path; paths.sort.uniq)
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

				if (!isNormalFile(entry.name) || !entry.name.canBeRead)
				{
					// not a file or reading threw exception
					++ctx.skippedFiles;
					continue;
				}

				files ~= entry.name;
				write(".");
			}
		}
		else if (path.isFile)
		{
			if (!isNormalFile(path) || !path.canBeRead)
			{
				// not a file or reading threw exception
				++ctx.skippedFiles;
				continue;
			}

			files ~= path;
			write(".");
		}
		else
		{
			writeln();
			writeln("don't understand ", path);
			++ctx.skippedFiles;
			continue;
		}
	}

	foreach (filename; files)
	{
		auto file = File(filename, "r");

		file.byLineCopy.gather(filename, ctx);
	}

	writeln();
	present(ctx);
}


bool canBeRead(const string filename)
{
	File file;

	try file = File(filename, "r");
	catch (Exception e)
	{
		return false;
	}

	return true;
}


bool isNormalFile(const string filename)
{
	import core.sys.posix.sys.stat : S_IFBLK, S_IFCHR, S_IFIFO;
	import std.file : getAttributes, isFile;

	try
	{
		return filename.isFile &&
			(!(getAttributes(filename) & (S_IFBLK | S_IFCHR | S_IFIFO)));
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


size_t longestFilenameLength(const FileHead[] fileheads) pure @nogc
{
	size_t longest;

	foreach (filehead; fileheads)
	{
		immutable dotlessLength = filehead.filename.withoutDotSlash.length;
		longest = (dotlessLength > longest) ? dotlessLength : longest;
	}

	return longest;
}


string withoutDotSlash(const string filename) pure @nogc
{
	assert((filename.length > 2), filename);
	return (filename[0..2] == "./") ? filename[2..$] : filename;
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
			writefln(pattern, filehead.filename, 0, bashResetToken ~ "< empty >");
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

