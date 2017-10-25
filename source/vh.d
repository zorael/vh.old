module vh;

import bash;
import std.stdio;
import std.file : DirEntry;

// version = IgnoreLeadingDots;
// version = IgnoreCase;
version = Colour;


enum numberOfLines = 3;


struct VerboseHeadResults
{
	FileHead[] allFiles;
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
	import std.path : exists, isDir;

	immutable path = (args.length > 1) ? args[1] : ".";

	version(Colour)
	{
		writef("%s[%dm", BashColourToken, BashReset.all);
	}

	if (!path.exists)
	{
		writeln(path, " does not exist");
		return;
	}

	if (!path.isDir)
	{
		writeln("Only support directory paths so far");
		return;
	}

	VerboseHeadResults res;
	auto entries = path.dirEntries(SpanMode.shallow);

	foreach (entry; entries)
	{
		if (entry.isDir)
		{
			++res.skippedDirs;
			continue;
		}

		import core.sys.posix.sys.stat;

		try
		{
			const s = entry.statBuf.st_mode;

			if ((s & S_IFIFO) ||
				(s & S_IFCHR) ||
				(s & S_IFBLK))
			{
				++res.skippedFiles;
				continue;
			}
		}
		catch (Exception e)
		{
			// object.Exception@std/file.d(3216): Failed to stat file `./rcmysql'
			// (broken link)
			++res.skippedFiles;
			continue;
		}

		File file;

		try file = File(entry, "r");
		catch (Exception e)
		{
			++res.skippedFiles;
			continue;
		}

		write(".");

		file
			.byLineCopy
			.gather(entry.name, res);
	}

	writeln();
	present(res);
}

bool isNormalFile(string filename)
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


void gather(T)(T lines, string filename, ref VerboseHeadResults res)
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
			++res.skippedFiles;
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
	res.allFiles ~= head;
}


size_t longestFilenameLength(FileHead[] fileheads) pure @nogc
{
	size_t longest;

	foreach (filehead; fileheads)
	{
		longest = (filehead.filename.length > longest) ?
			filehead.filename.length : longest;
	}

	return longest;
}


void present(VerboseHeadResults res)
{
	import std.format : format;

	version(Colour)
	{
		import std.concurrency : Generator;
		auto colourGenerator = new Generator!string(&cycleBashColours);
	}

	size_t longestLength = res.allFiles.longestFilenameLength;
	immutable pattern = " %%-%ds %%d: %%s".format(longestLength);

	version(IgnoreLeadingDots)
	{
		static bool headSortPred(FileHead a, FileHead b)
		{
			static string dotless(string something)
			{
				return (something[0..3] == "./.") ? something[3..$] : something[2..$];
			}

			version(IgnoreCase)
			{
				import std.string : toUpper;

				return toUpper(dotless(a.filename)) < toUpper(dotless(b.filename));
			}
			else
			{
				return dotless(a.filename) < dotless(b.filename);
			}
		}
	}
	else
	{
		bool headSortPred(FileHead a, FileHead b)
		{
			import std.string : toUpper;

			version(IgnoreCase)
			{
				return toUpper(a.filename) < toUpper(b.filename);
			}
			else
			{
				return a.filename < b.filename;
			}
		}
	}

	import std.algorithm : sort, SwapStrategy;

	foreach (fileline; res.allFiles.sort!(headSortPred, SwapStrategy.stable))
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
			writefln(pattern, fileline.filename.baseName, 0, "< empty >");
		}
		else foreach (lineNumber, line; fileline.lines)
		{
			if (lineNumber == 0)
			{
				writefln(pattern, fileline.filename.baseName, lineNumber+1, line);
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
				writef("%s[%dm", BashColourToken, BashReset.all);
			}

			immutable linesTruncated = (fileline.linecount - linesConsumed);
			immutable linecountPattern =
				format!" %%-%ds [%%d %s truncated]"
				(longestLength, linesTruncated.plurality("line", "lines"));
			writefln(linecountPattern, string.init, linesTruncated);
		}
	}

	writefln("%s[%dm", BashColourToken, BashReset.all);
	writefln("%d %s listed, with %d %s and %d %s skipped",
		res.allFiles.length, res.allFiles.length.plurality("file", "files"),
		res.skippedFiles, res.skippedFiles.plurality("file", "files"),
		res.skippedDirs, res.skippedDirs.plurality("directory", "directories"));
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

