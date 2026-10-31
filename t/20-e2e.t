use strict;
use warnings;
use FindBin ();
use lib "$FindBin::Bin/lib";
use Test::More;
use CmdSpawn;

# happy path
my ($code, $lines) = cmd_run(['hello', 'world']);
is($code, 0, 'greet hello world exits 0');
is($lines->[0], "hello world\n", 'greeting printed');

# options reach the leaf, parent option before the command
($code, $lines) = cmd_run(['-v', 'hello', '-s', '-n', '2', 'world']);
is($code, 0, 'options run exits 0');
is_deeply($lines, ["greeting 1 names\n", "HELLO WORLD\n", "HELLO WORLD\n"],
	'verbose to stderr, shouted and repeated to stdout');

# generated help
($code, $lines) = cmd_run(['--help']);
is($code, 0, '--help exits 0');
like(join('', @{$lines}), qr/Usage: greet \[options\] COMMAND/, 'app usage');
like(join('', @{$lines}), qr/hello\s+say hello/, 'command listing');

($code, $lines) = cmd_run(['help', 'hello']);
is($code, 0, 'help hello exits 0');
like(join('', @{$lines}), qr/Usage: greet hello \[options\] NAME\.\.\./,
	'command usage via help subcommand');

# misuse
($code, $lines) = cmd_run(['bogus']);
is($code, 2, 'unknown command exits 2');
like(join('', @{$lines}), qr/greet: unknown command 'bogus'/, 'misuse message');

# domain error from run
($code, $lines) = cmd_run(['hello']);
is($code, 1, 'dying run exits 1');
is($lines->[0], "greet: no one to greet\n", 'tidied error with prefix');

# version; -v belongs to the verbose option so only --version answers
($code, $lines) = cmd_run(['--version']);
is($code, 0, '--version exits 0');
is($lines->[0], "greet 0.5\n", 'version line');

# subcommand classes load lazily from their own files
($code, $lines) = cmd_run(['wave']);
is($code, 0, 'wave exits 0');
is($lines->[0], "o/\n", 'lazily required command ran');

done_testing;
