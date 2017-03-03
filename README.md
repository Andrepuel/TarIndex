TarIndex
========

Generates a index of a tarfile to quickly list files and extract
contents of specified file.

Usage
-----

    ./tarindex path_to_tar:path_inside_tar

If the specified path is a directory, or no path is specified, the directory is listed.
Otherwise, the contents of the file are written in the standard output.