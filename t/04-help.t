use strict;
use warnings;
use Test::More;

{
	package HApp;

	use Object::Proto::Cmd -types;

	name     'happ';
	abstract 'the help fixture';

	option verbose => (isa => Bool, doc => 'be noisy');
	option secret  => (isa => Str, hidden => 1);

	command hello => 'HApp::Hello';

	1;
}

{
	package HApp::Hello;

	use Object::Proto::Cmd -types;

	abstract 'say hello';
	usage    '[options] NAME...';

	option greeting => (isa => Str, default => 'hello', alias => 'g', doc => 'word to use');
	option times    => (isa => Int, required => 1, alias => 'n', doc => 'repeat');
	option tags     => (isa => ArrayRef, doc => 'labels');

	sub run { 0 }

	1;
}

package main;

sub run_main {
	my (@argv) = @_;
	my ($out, $err) = ('', '');
	open my $ofh, '>', \$out or die;
	open my $efh, '>', \$err or die;
	local $Object::Proto::Cmd::OUT = $ofh;
	local $Object::Proto::Cmd::ERR = $efh;
	my $code = HApp->main(@argv);
	close $ofh;
	close $efh;
	return ($code, $out, $err);
}

# app level help
my ($code, $out, $err) = run_main('--help');
is($code, 0, '--help exits 0');
is($err, '', '--help writes nothing to stderr');
like($out, qr/^Usage: happ \[options\] COMMAND$/m, 'app usage line');
like($out, qr/^the help fixture$/m, 'app abstract shown');
like($out, qr/^Commands:$/m, 'commands section');
like($out, qr/^  hello   say hello$/m, 'command row with abstract');
like($out, qr/^  help    show help for a command$/m, 'auto help row aligned');
like($out, qr/^ {6}--verbose\s+be noisy$/m, 'option row with doc');
unlike($out, qr/secret/, 'hidden option omitted');

# command level help, from the flag
($code, $out, $err) = run_main('hello', '--help');
is($code, 0, 'command --help exits 0 despite missing required option');
like($out, qr/^Usage: happ hello \[options\] NAME\.\.\.$/m, 'chain in usage line');
like($out, qr/^say hello$/m, 'command abstract shown');
like($out, qr/^  -g, --greeting VALUE\s{3,}word to use \(default: hello\)$/m,
	'short, long, placeholder, doc, default');
like($out, qr/^  -n, --times N\s{3,}repeat \(required\)$/m, 'required marker');
like($out, qr/^ {6}--tags VALUE\s{3,}labels \(repeatable\)$/m, 'repeatable marker');

# the help subcommand and the flag produce identical text
my ($code2, $out2, $err2) = run_main('help', 'hello');
is($code2, 0, 'help subcommand exits 0');
is($out2, $out, 'help hello matches hello --help');

# help with no arguments shows the app usage
($code, $out, $err) = run_main('help');
is($code, 0, 'bare help exits 0');
like($out, qr/^Usage: happ \[options\] COMMAND$/m, 'bare help is app usage');

# help for an unknown command is misuse
($code, $out, $err) = run_main('help', 'wat');
is($code, 2, 'help unknown exits 2');
like($err, qr/happ: unknown command 'wat'/, 'unknown command reported');

# option columns align: every doc starts at the same offset
($code, $out, $err) = run_main('hello', '--help');
my @docs = grep { /^  \S.*\s{3}\S/ } grep { !/^Usage|^Commands|^Options/ } split /\n/, $out;
my %starts;
for my $line (@docs) {
	next unless $line =~ /^(  \S[^\s].*?\s{3,})\S/;
	$starts{length $1}++;
}
is(scalar keys %starts, 1, 'docs share one column') or diag $out;

done_testing;
