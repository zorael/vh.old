module vh;

import bash;
import std.stdio;
import std.file : DirEntry;
import std.format : format;

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

	bool opEquals(T)(T that)
	{
		return (this.filename == that.filename);
	}

	this(string[] filelines)
	{
		filename = filelines[0];

		if (filelines.length > 1)
		{
			lines = filelines[1..$];
		}
	}
}


void main(string[] args)
{
	import std.file : dirEntries, SpanMode;
	import std.path : exists, isDir, isFile;
	import std.algorithm : sort, uniq;

	string[] paths = (args.length > 1) ? args[1..$] : [ "." ];
	string[] files;

	version(Colour)
	{
		write(bashResetToken);
	}

	Context ctx;

	foreach (path; paths.sort.uniq)
	{
		if (!path.exists)
		{
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
					++ctx.skippedFiles;
					continue;
				}

				files ~= entry.name;
			}
		}
		else if (path.isFile)
		{
			if (!isNormalFile(path) || !path.canBeRead)
			{
				++ctx.skippedFiles;
				continue;
			}

			files ~= path;
		}
		else
		{
			writeln();
			writeln("don't understand ", path);
			++ctx.skippedFiles;
			continue;
		}

		write(".");
	}

	foreach (filename; files)
	{
		auto file = File(filename, "r");

		file
			.byLineCopy
			.gather(filename, ctx);
	}

	writeln();
	present(ctx);
}

bool canBeRead(string filename)
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
	return DirEntry(filename).isNormalFile();
}

bool isNormalFile(DirEntry entry)
{
	import core.sys.posix.sys.stat;
	import std.path : isFile, DirEntry;

	if (!entry.isFile) return false;

	try
	{
		const stat = entry.statBuf.st_mode;

		if ((stat & S_IFIFO) ||
			(stat & S_IFCHR) ||
			(stat & S_IFBLK))
		{
			// Either a FIFO, a character file or a block file
			return false;
		}
	}
	catch (Exception e)
	{
		// object.Exception@std/file.d(3216): Failed to stat file `./rcmysql'
		// (broken link)
		return false;
	}

	return true;
}


void gather(T)(T lines, const string filename, ref Context ctx)
{
	import std.array : Appender;
	import std.range : take;

	FileHead head;
	head.filename = filename;

	Appender!(string[]) sink;

	foreach (line; lines.take(numberOfLines))
	{
		import std.utf;

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

	head.linecount = linecount;
	head.lines = sink.data;
	ctx.allFiles ~= head;
}


size_t longestFilenameLength(FileHead[] fileheads) pure @nogc
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
	return (filename[0..2] == "./") ? filename[2..$] : filename;
}


void present(Context ctx)
{
	version(Colour)
	{
		import std.concurrency : Generator;
		auto colourGenerator = new Generator!string(&cycleBashColours);
	}

	size_t longestLength = ctx.files.longestFilenameLength;
	immutable pattern = " %%-%ds %%d: %%s".format(longestLength+1);

	static bool headSortPred(FileHead a, FileHead b)
	{
		return a.filename == b.filename;
	}

	import std.algorithm : sort, SwapStrategy, uniq;

	foreach (fileline; ctx.files.sort!(headSortPred, SwapStrategy.stable).uniq)
	{
		import std.path : baseName;

		version(Colour)
		{
			write(colourGenerator.front);
			colourGenerator.popFront();
		}

		size_t linesConsumed;

		if (fileline.empty)
		{
			writefln(pattern, fileline.filename, 0, "< empty >");
		}
		else foreach (lineNumber, line; fileline.lines)
		{
			if (lineNumber == 0)
			{
				writefln(pattern, fileline.filename.withoutDotSlash,
						 lineNumber+1, line);
			}
			else
			{
				writefln(pattern, string.init, lineNumber+1, line);
			}

			++linesConsumed;
		}

		if (fileline.linecount > linesConsumed)
		{
			version(Colour)
			{
				write(bashResetToken);
			}

			immutable linesTruncated = (fileline.linecount - linesConsumed);
			immutable linecountPattern =
				format!" %%-%ds [%%d %s truncated]"
				(longestLength+1, linesTruncated.plurality("line", "lines"));
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


string plurality(ptrdiff_t num, string singular, string plural) pure
{
	return ((num == 1) || (num == -1)) ? singular : plural;
}

