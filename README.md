# vh

verbose head

This tool acts like the terminal tool `head`, performed on all files in your current directory or one specified at the command-line. By default only the first three lines are shown (`head -n3 *`) and in colours, but this is compile-time configurable.

Future improvements will include being able to specify more than one directory, getopt options and saved configuration files.

## Getting started

You need a D compiler, and the official `dub` package manager is recommended. It is however very possible to build the project without it.

There are three compilers available; see [here](https://wiki.dlang.org/Compilers) for an overview. As of October 2017, `vh` can be built using any of them.

### Downloading

GitHub offers downloads in ZIP format, but it's easiest to use `git` and clone the repository that way.

    $ git clone https://github.com/zorael/vh.git
    $ cd vh

### Compiling

    $ dub build

This will compile it in the default `debug` mode, which adds some extra code and debugging symbols. You can build it in `release` mode by passing `-b release` as an argument to `dub`. Refer to the output of `dub build --help` for more build types.

Unit tests are built into the language, but you need to compile in `unittest` mode for them to run. The shorthand form for this is `dub test`;

    $ dub test

The tests are run at the *start* of the program, not during compilation.

## How to use

Merely place the `vh` executable somewhere in your PATH, and execute it as normal. Alternatively for fast tests after changes to the source, you can use `dub run`.

## TODO
* getopt, move some compile-time options to runtime
* multiple paths

## License
This project is licensed under the **MIT License** S- see the [LICENSE](LICENSE) file for details.
