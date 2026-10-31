use strict;
use warnings;
use Test::More;

{
	package EApp;

	use Object::Proto::Cmd -types;

	name 'eapp';

	command clean => 'EApp::Clean';
	command boom  => 'EApp::Boom';
	command croak => 'EApp::Croak';
	command code  => 'EApp::Code';
	command typed => 'EApp::Typed';
	command needs => 'EApp::Needs';

	1;
}

{
	package EApp::Clean;
	use Object::Proto::Cmd;
	sub run { return 0 }
	1;
}

{
	package EApp::Boom;
	use Object::Proto::Cmd;
	sub run { die "the widget is on fire\n" }
	1;
}

{
	package EApp::Croak;
	use Object::Proto::Cmd;
	use Carp ();
	sub run { Carp::croak "croaked message" }
	1;
}

{
	package EApp::Code;
	use Object::Proto::Cmd -types;
	option want => (isa => Int, default => 0);
	sub run { my ($self) = @_; return $self->want }
	1;
}

{
	package EApp::Typed;
	use Object::Proto::Cmd;
	option port => (
		isa => sub { die "bad port\n" unless $_[0] =~ /^\d+$/ },
	);
	sub run { return 0 }
	1;
}

{
	package EApp::Needs;
	use Object::Proto::Cmd -types;
	option target => (isa => Str, required => 1);
	sub run { return 0 }
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
	my $code = EApp->main(@argv);
	close $ofh;
	close $efh;
	return ($code, $out, $err);
}

# 0 when fine
my ($code, $out, $err) = run_main('clean');
is($code, 0, 'clean run exits 0');
is($err, '', 'clean run quiet on stderr');

# 1 when run dies, message tidied and prefixed
($code, $out, $err) = run_main('boom');
is($code, 1, 'dying run exits 1');
is($err, "eapp: the widget is on fire\n", 'die message prefixed');

($code, $out, $err) = run_main('croak');
is($code, 1, 'croaking run exits 1');
is($err, "eapp: croaked message\n", 'at FILE line N stripped');

# run picks its own exit code
($code, $out, $err) = run_main('code', '--want', '3');
is($code, 3, 'run return value becomes the exit code');
($code, $out, $err) = run_main('code');
is($code, 0, 'zero return is 0');

# 2 when the command is used wrongly
($code, $out, $err) = run_main('clean', '--wat');
is($code, 2, 'unknown option exits 2');
like($err, qr/eapp: unknown option '--wat'/, 'unknown option message');
like($err, qr/Usage: eapp clean/, 'usage names the resolved command');

# construction failure is usage, the inputs came from the command line
($code, $out, $err) = run_main('typed', '--port', 'nope');
is($code, 2, 'type failure at construction exits 2');
like($err, qr/bad port/, 'type error reaches the user');

# missing required option is caught before the constructor
($code, $out, $err) = run_main('needs');
is($code, 2, 'missing required exits 2');
like($err, qr/missing required option '--target'/, 'required message');

done_testing;
