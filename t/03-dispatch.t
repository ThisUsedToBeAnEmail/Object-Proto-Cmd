use strict;
use warnings;
use Test::More;

{
	package DApp;

	use Object::Proto::Cmd -types;

	our $VERSION = '1.23';

	name     'dapp';
	abstract 'dispatch fixture';

	option verbose => (isa => Bool, alias => 'v');

	command sub1 => 'DApp::Sub';
	command deep => 'DApp::Deep';

	1;
}

{
	package DApp::Sub;

	use Object::Proto::Cmd -types;

	abstract 'a leaf';

	our $LAST;

	option count => (isa => Int, default => 1, alias => 'c');

	sub run {
		my ($self, @pos) = @_;
		$LAST = {
			count          => $self->count,
			parent_verbose => $self->cmd_parent->can('verbose')
				? $self->cmd_parent->verbose : undef,
			pos            => [@pos],
		};
		return 0;
	}

	1;
}

{
	package DApp::Deep;

	use Object::Proto::Cmd;

	abstract 'has children';

	command leaf => 'DApp::Deep::Leaf';

	1;
}

{
	package DApp::Deep::Leaf;

	use Object::Proto::Cmd;

	our $LAST;

	sub run {
		my ($self) = @_;
		$LAST = { chain => [] };
		my $p = $self->cmd_parent;
		while (defined $p) {
			push @{$LAST->{chain}}, ref $p;
			$p = $p->cmd_parent;
		}
		return 0;
	}

	1;
}

{
	package FApp;

	use Object::Proto::Cmd;

	name 'fapp';

	our $LAST;

	command real => 'DApp::Sub';

	sub run {
		my ($self, @pos) = @_;
		$LAST = [@pos];
		return 0;
	}

	1;
}

package main;

sub run_main {
	my ($class, @argv) = @_;
	my ($out, $err) = ('', '');
	open my $ofh, '>', \$out or die;
	open my $efh, '>', \$err or die;
	local $Object::Proto::Cmd::OUT = $ofh;
	local $Object::Proto::Cmd::ERR = $efh;
	my $code = $class->main(@argv);
	close $ofh;
	close $efh;
	return ($code, $out, $err);
}

# simple dispatch with defaults
my ($code, $out, $err) = run_main('DApp', 'sub1');
is($code, 0, 'dispatch returns 0');
is($DApp::Sub::LAST->{count}, 1, 'default option value');
is($DApp::Sub::LAST->{parent_verbose}, 0, 'parent constructed with defaults');
is_deeply($DApp::Sub::LAST->{pos}, [], 'no positionals');

# parent options before the command land on the parent
($code, $out, $err) = run_main('DApp', '-v', 'sub1', '-c', '3', 'x', 'y');
is($code, 0, 'nested run ok');
is($DApp::Sub::LAST->{count}, 3, 'leaf option parsed');
is($DApp::Sub::LAST->{parent_verbose}, 1, 'parent option before command');
is_deeply($DApp::Sub::LAST->{pos}, ['x', 'y'], 'positionals reach run');

# two level dispatch builds the cmd_parent chain
($code, $out, $err) = run_main('DApp', 'deep', 'leaf');
is($code, 0, 'two level dispatch ok');
is_deeply($DApp::Deep::Leaf::LAST->{chain}, ['DApp::Deep', 'DApp'],
	'cmd_parent chain walks to the root');

# unknown command is misuse
($code, $out, $err) = run_main('DApp', 'bogus');
is($code, 2, 'unknown command exits 2');
like($err, qr/dapp: unknown command 'bogus'/, 'unknown command message');
like($err, qr/Usage: dapp/, 'usage follows the message');
is($out, '', 'nothing on stdout');

# a class with both run and commands falls through to run
($code, $out, $err) = run_main('FApp', 'notacmd', 'y');
is($code, 0, 'fall through ok');
is_deeply($FApp::LAST, ['notacmd', 'y'], 'unmatched token is positional');
($code, $out, $err) = run_main('FApp', 'real');
is($code, 0, 'matching command still dispatches');
is($DApp::Sub::LAST->{count}, 1, 'command won over run');

# empty argv on a class with subcommands and no run prints usage
($code, $out, $err) = run_main('DApp');
is($code, 0, 'bare invocation exits 0');
like($out, qr/Usage: dapp/, 'usage on stdout');
is($err, '', 'nothing on stderr');

# --version prints name and version; -v stands down to the verbose alias
($code, $out, $err) = run_main('DApp', '--version');
is($code, 0, 'version exits 0');
is($out, "dapp 1.23\n", 'version line');
($code, $out, $err) = run_main('DApp', '-v', 'sub1');
is($code, 0, '-v claimed by an option dispatches');
is($DApp::Sub::LAST->{parent_verbose}, 1, '-v set verbose, not version');

done_testing;
