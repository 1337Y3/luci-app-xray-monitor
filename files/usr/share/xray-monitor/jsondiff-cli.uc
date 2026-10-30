#!/usr/bin/ucode
// CLI front end for the jsondiff module: print the paths_diff JSON of two
// JSON files. Used by tests/run.sh and handy from rpcd/xray-sub debugging.
//   jsondiff-cli.uc <a.json> <b.json>
//   -> {"added":[...],"removed":[...],"changed":[...]}
// added = present in b only, removed = present in a only.
'use strict';
import { readfile, stderr } from 'fs';
import { paths_diff } from 'jsondiff';

if (length(ARGV) != 2) {
	stderr.write('usage: jsondiff-cli.uc <a.json> <b.json>\n');
	exit(1);
}

printf('%J\n', paths_diff(json(readfile(ARGV[0])), json(readfile(ARGV[1]))));
