import std.stdio;
import std.format : format;

enum TarType : char {
	normal = '0',
	hard = '1',
	symbolic = '2',
	character = '3',
	block = '4',
	directory = '5',
	fifo = '6',
	contiguous = '7',
	global = 'g',
	extended = 'x'
}

ulong fromOctect(const(char)[] input) pure @nogc {
	ulong result = 0;
	while (input.length > 0) {
		result *= 8;
		result += input[0] - '0';
		input = input[1..$];
	}
	return result;
}

T ceildiv(T)(T a, T b) {
	return (a + (b - 1))/b;
}

struct TarHeader {
	import std.string : fromStringz;

	align(1):
	char[100] _name;
	ulong filemode;
	ulong uid;
	ulong gid;
	char[12] _filesize;
	char[12] last_modification;
	char[8] _checksum;
	TarType type;
	char[100] link_name;
	char[6] ustar;
	char[2] ustar_version;
	char[32] uid_name;
	char[32] gid_name;
	ulong dev_major;
	ulong dev_minor;
	char[155] _filename_prefix;
	
	ubyte[12] _padding;

	string toString() const pure {
		return "TarHeader(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)".format(
			name,
			filemode,
			uid,
			gid,
			filesize,
			last_modification[0..11].fromOctect,
			checksum,
			type,
			link_name.ptr.fromStringz,
			ustar.ptr.fromStringz,
			uid_name.ptr.fromStringz,
			gid_name.ptr.fromStringz,
			dev_major,
			dev_minor,
			filename_prefix,
		);
	}

	const(char)[] name() const pure {
		return _name.ptr.fromStringz;
	}

	const(char)[] filename_prefix() const pure {
		return _filename_prefix.ptr.fromStringz;
	}

	const(char)[] fullpath() const pure {
		if (type == TarType.extended) return fullpath_extended;
		return fullpath_normal;
	}

	const(char)[] fullpath_extended() const pure {
		return next_normal(cast(void*)ulong.max).fullpath_normal();
	}

	const(char)[] fullpath_normal() const pure {
		if (filename_prefix.length == 0) {
			return name();
		} else {
			return filename_prefix ~ "/" ~ name();
		}
	}

	uint calcChecksum() const pure {
		TarHeader copy = this;
		copy._checksum[] = ' ';
		uint sum = 0;
		ubyte[] data = (cast(ubyte[])((&copy)[0..1]))[0..500];
		foreach(b; data) {
			sum += b;
		}
		return sum;
	}

	ulong filesize() const pure {
		if (type == TarType.extended) return filesize_extended;
		return filesize_normal;
	}

	ulong filesize_normal() const pure {
		return _filesize.ptr[0..11].fromOctect;
	}

	ulong filesize_extended() const pure {
		import std.algorithm : map, filter, splitter;
		import std.string : split;
		import std.conv;
		const(char)[] paxheader = cast(const(char)[])data_normal;
		auto size = paxheader
			.splitter("\n")
			.map!(x => x.split(" "))
			.filter!(x => x.length == 2)
			.map!(x => x[1].split("="))
			.filter!(x => x.length == 2)
			.filter!(x => x[0] == "size");
		
		if (size.empty) {
			return next_normal(cast(void*)ulong.max).filesize_normal;
		}
		
		return size.front[1].to!ulong;
	}

	uint checksum() const pure {
		return cast(uint)(_checksum.ptr[0..6].fromOctect);
	}

	bool check() const pure {
		return ustar_version == "00" && ustar[0..5] == "ustar" && checksum == calcChecksum;
	}

	const(ubyte)[] data() const pure {
		if (type == TarType.extended) return data_extended;
		return data_normal;
	}

	const(ubyte)[] data_extended() const pure {
		return next_normal(cast(void*)ulong.max).data().ptr[0..filesize_extended];
	}

	const(ubyte)[] data_normal() const pure {
		const(void)* start = (cast(const(void)*)&this) + TarHeader.sizeof;
		return (cast(const(ubyte)*)start)[0..filesize_normal];
	}

	const(TarHeader)* next(void* end) const pure {
		if (type == TarType.extended) return next_extended(end);
		return next_normal(end);
	}

	const(TarHeader)* next_extended(void* end) const pure {
		const(void)* start = next_normal(end).data_normal().ptr;
		ulong blocks = filesize.ceildiv(TarHeader.sizeof);

		return next(start, blocks, end);
	}

	const(TarHeader)* next_normal(void* end) const pure {
		const(void)* start = (cast(const(void)*)&this) + TarHeader.sizeof;
		ulong blocks = filesize_normal.ceildiv(TarHeader.sizeof);
		return next(start, blocks, end);
	}

	private const(TarHeader)* next(const(void)* start, ulong blocks, void* end) const pure {
		start += blocks * TarHeader.sizeof;
		
		while (true) {
			const(TarHeader)* result = cast(const(TarHeader)*)start;

			if (result >= end) {
				return null;
			}

			if (result.check) {
				return result;
			}
			
			debug writeln("Skip ", start);
			start += TarHeader.sizeof;
		}
	}

	const(ubyte)[] tarball() const {
		ulong blocks = 1 + filesize_normal.ceildiv(TarHeader.sizeof);
		if (type == TarType.extended) {
			 blocks += 1 + filesize_extended.ceildiv(TarHeader.sizeof);
		}
		const(ubyte)* start = cast(const(ubyte)*)&this;
		return start[0..blocks * 512];
	}
}
static assert(TarHeader.sizeof == 512);

struct Directory {
	Directory[string] directories;
	const(TarHeader)*[string] files;

	void fill(const(TarHeader)* header, const(char)[][] path = null) {
		import std.string : split;

		if (path is null) {
			path = header.fullpath.split("/");
		}

		assert(path.length > 0);
		if (path.length == 1) {
			files[path[0]] = header;
		} else {
			Directory* sub = path[0] in directories;
			if (sub is null) {
				sub = &(directories[path[0]] = Directory.init);
			}
			sub.fill(header, path[1..$]);
		}
	}

	string toString() const pure {
		import std.algorithm : map;
		import std.range : chain, join;
		return directories.byKey.map!(x => "d %s".format(x)).chain(files.byKey.map!(x => "- %s".format(x))).join("\n");
	}

	auto get(const(char[])[] path) {
		import std.typecons : tuple;

		if (path.length == 0) {
			return tuple(&this, cast(const(TarHeader)*)null);
		} else if (path.length == 1) {
			auto file = path[0] in files;

			if (file !is null) {
				return tuple(cast(Directory*)null, *file);
			}

			auto dir = path[0] in directories;
			if (dir !is null) {
				return tuple(dir, cast(const(TarHeader)*)null);
			}

			return tuple(cast(Directory*)null, cast(const(TarHeader)*)null);
		} else {
			auto dir = path[0] in directories;
			if (dir !is null) {
				return dir.get(path[1..$]);
			}

			return tuple(cast(Directory*)null, cast(const(TarHeader)*)null);
		}
	}

	void save(ref File output, void* start) {
		output.writeln(files.length);
		output.writeln(directories.length);

		foreach(name, file; files) {
			output.writeln(name);
			output.writeln(cast(ulong)(file - start));
		}

		foreach(name, dir; directories) {
			output.writeln(name);
			dir.save(output, start);
		}
	}

	void load(ref File input, void* start) {
		import std.conv : to;
		
		ulong files_n = input.readln[0..$-1].to!ulong;
		ulong directories_n = input.readln[0..$-1].to!ulong;

		foreach(i; 0..files_n) {
			string name = input.readln[0..$-1];
			ulong offset = input.readln[0..$-1].to!ulong;
			files[name] = cast(const(TarHeader)*)(start + offset);
		}

		foreach(i; 0..directories_n) {
			string name = input.readln[0..$-1];
			auto dir = &(directories[name] = Directory.init);
			dir.load(input, start);
		}
	}
}

void tarball(Directory dir, ref File output) {
	foreach(file; dir.files) {
		output.rawWrite(file.tarball);
	}

	foreach(dir; dir.directories) {
		dir.tarball(output);
	}
}

void main(string[] args){
	import std.typecons : scoped;
	import std.mmfile : MmFile;
	import std.string : split;
	import std.file : exists;
	import std.getopt : getopt, defaultGetoptPrinter;

	bool tarball;
	auto opt = getopt(args, "tarball", "Generates tarball of the given path", &tarball);
	if (opt.helpWanted) {
		defaultGetoptPrinter("Tarball indexer", opt.options);
		return;
	}

	foreach(arg; args[1..$]) {
		Directory index;

		string path;
		string subpath;
		if (arg.split(":").length == 2) {
			path = arg.split(":")[0];
			subpath = arg.split(":")[1];
		} else {
			path = arg;
		}


		auto mm = scoped!MmFile(path, MmFile.Mode.read, 0, null);
		void* start = mm[].ptr;
		void* end = mm[][$..$].ptr;

		if (exists(path ~ ".index")) {
			File input = File(path ~ ".index", "r");
			index.load(input, start);
		} else {
			const(TarHeader)* tar = cast(const(TarHeader)*)mm[].ptr;
			while (tar !is null) {
				index.fill(tar);
				tar = tar.next(end);
			}

			File output = File(path ~ ".index", "w");
			index.save(output, start);
		}

		auto r = index.get(subpath.split("/"));
		if (r[0] !is null) {
			if (tarball) {
				(*r[0]).tarball(stdout);
			} else {
				writeln(r[0].toString);
			}
		} else if (r[1] !is null) {
			if (tarball) {
				stdout.rawWrite(r[1].tarball);
			} else {
				stdout.rawWrite(r[1].data);
			}
		} else {
			writeln("Path ", subpath, " not found on ", path);
		}
	}
}
