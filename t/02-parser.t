use strict;
use warnings;
use Test::More;

{
	package TParse;

	use Object::Proto::Cmd -types;

	option verbose => (isa => Bool, alias => 'v');
	option force   => (isa => Bool, alias => 'f');
	option all     => (isa => Bool, alias => 'a');
	option times   => (isa => Int, alias => 'n');
	option out     => (isa => Str, alias => 'o');
	option tags    => (isa => ArrayRef, alias => 't');
	option define  => (isa => HashRef, alias => 'D');
	option ratio   => (isa => Num);
	option dry_run => (isa => Bool);
	option fun     => (isa => Bool);
	option no_fun  => (isa => Bool);
	option must    => (isa => Str, required => 1);

	sub run { 0 }

	1;
}

package main;

my $spec = Object::Proto::Cmd::_spec('TParse');

sub parse {
	my ($argv, $mode) = @_;
	return Object::Proto::Cmd::_parse_options($spec, $argv, $mode || 'permute');
}

sub parse_err {
	my ($argv, $mode) = @_;
	my ($v, $r) = eval { parse($argv, $mode) };
	return ref $@ eq 'HASH' ? $@->{usage_error} : undef;
}

# long options, three value spellings
my ($v, $r) = parse(['--out', 'file', 'pos1']);
is($v->{out}, 'file', 'long with space value');
is_deeply($r, ['pos1'], 'positional collected');
($v, $r) = parse(['--out=file']);
is($v->{out}, 'file', 'long with = value');
($v, $r) = parse(['--out=']);
is($v->{out}, '', 'long with empty = value');

# shorts, attached and detached values
($v, $r) = parse(['-o', 'file']);
is($v->{out}, 'file', 'short with detached value');
($v, $r) = parse(['-ofile']);
is($v->{out}, 'file', 'short with attached value');

# flags and bundling
($v, $r) = parse(['--verbose']);
is($v->{verbose}, 1, 'long flag');
($v, $r) = parse(['-v']);
is($v->{verbose}, 1, 'short flag');
($v, $r) = parse(['-vfa']);
is_deeply([@{$v}{qw/verbose force all/}], [1, 1, 1], 'flag bundling');
($v, $r) = parse(['-vn3']);
is($v->{verbose}, 1, 'flag before value short in bundle');
is($v->{times}, 3, 'value short takes rest of bundle');
($v, $r) = parse(['-vn', '3']);
is($v->{times}, 3, 'value short takes next token after bundle');
($v, $r) = parse(['-vfout']);
is_deeply([@{$v}{qw/verbose force out/}], [1, 1, 'ut'],
	'bundle stops at first value-taking short');

# typed values
is(parse_err(['--times', 'x']), "option '--times' expects an integer, got 'x'",
	'Int rejects non-integer');
($v, $r) = parse(['--times', '-3']);
is($v->{times}, -3, 'Int accepts negative');
($v, $r) = parse(['--ratio', '1.5']);
is($v->{ratio}, 1.5, 'Num accepts decimal');
like(parse_err(['--ratio', 'abc']), qr/expects a number/, 'Num rejects word');

# repeatable ArrayRef and HashRef
($v, $r) = parse(['--tags', 'a', '-t', 'b']);
is_deeply($v->{tags}, ['a', 'b'], 'ArrayRef repeats push');
($v, $r) = parse(['-D', 'k=1', '--define', 'k2=2']);
is_deeply($v->{define}, {k => 1, k2 => 2}, 'HashRef collects pairs');
like(parse_err(['-D', 'nope']), qr/expects KEY=VALUE/, 'HashRef needs =');

# Bool takes no value, negation
like(parse_err(['--verbose=1']), qr/does not take a value/, 'Bool rejects =value');
($v, $r) = parse(['--no-verbose']);
is($v->{verbose}, 0, 'Bool negation sets false');
($v, $r) = parse(['--no_verbose']);
is($v->{verbose}, 0, 'underscore negation too');
($v, $r) = parse(['--no-fun']);
is($v->{no_fun}, 1, 'literal no_ option beats negation');
ok(!exists $v->{fun}, 'fun untouched by literal no-fun');

# hyphen and underscore both reach the underscore attribute
($v, $r) = parse(['--dry-run']);
is($v->{dry_run}, 1, 'hyphen spelling');
($v, $r) = parse(['--dry_run']);
is($v->{dry_run}, 1, 'underscore spelling');

# unknown and incomplete
like(parse_err(['--wat']), qr/unknown option '--wat'/, 'unknown long');
like(parse_err(['-z']), qr/unknown option '-z'/, 'unknown short');
like(parse_err(['--out']), qr/requires a value/, 'missing long value');
like(parse_err(['-o']), qr/requires a value/, 'missing short value');

# -- ends option parsing
($v, $r) = parse(['--out', 'x', '--', '--verbose', '-v']);
is($v->{out}, 'x', 'options before -- parsed');
is_deeply($r, ['--verbose', '-v'], 'everything after -- is positional');
ok(!exists $v->{verbose}, 'flags after -- not set');

# lone - and negative numbers are positional
($v, $r) = parse(['-', '-5', 'x']);
is_deeply($r, ['-', '-5', 'x'], 'dash and negative number positional');

# stop mode halts at the first non option
($v, $r) = parse(['--verbose', 'sub', '--out', 'x'], 'stop');
is($v->{verbose}, 1, 'stop mode parses leading options');
is_deeply($r, ['sub', '--out', 'x'], 'stop mode leaves the rest');
($v, $r) = parse(['--', 'a'], 'stop');
is_deeply($r, ['--', 'a'], 'stop mode does not consume --');

# required is checked separately, after parsing
($v, $r) = parse(['--must', 'ok']);
eval { Object::Proto::Cmd::_check_required($spec, $v) };
is($@, '', 'required satisfied');
($v, $r) = parse(['--verbose']);
eval { Object::Proto::Cmd::_check_required($spec, $v) };
is(ref $@ eq 'HASH' ? $@->{usage_error} : '', "missing required option '--must'",
	'required missing reported');

done_testing;
