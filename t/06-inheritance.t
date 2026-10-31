use strict;
use warnings;
use Test::More;

{
	package IBase;

	use Object::Proto::Cmd -types;

	our $LAST;

	option verbose => (isa => Bool, alias => 'v', doc => 'noisy');
	option retries => (isa => Int, default => 2, alias => 'r', doc => 'try N times');

	sub run {
		my ($self) = @_;
		$LAST = { v => $self->verbose, r => $self->retries };
		return 0;
	}

	1;
}

{
	package IChild;

	use Object::Proto::Cmd -types;

	our $LAST;

	extends 'IBase';

	name     'ichild';
	abstract 'the child command';

	option target => (isa => Str, doc => 'where to aim');
	option '+retries' => (default => 5, doc => 'retry harder');

	sub run {
		my ($self) = @_;
		$LAST = { v => $self->verbose, r => $self->retries, t => $self->target };
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

# the slot override lands: new default, inherited attribute
my $obj = IChild->new;
is($obj->retries, 5, '+retries override changed the default');
is($obj->verbose, 0, 'inherited Bool keeps its auto default');

# cmd_parent is inherited, not declared twice
my %props = map { $_ => 1 } Object::Proto::properties('IChild');
ok($props{cmd_parent}, 'cmd_parent present via inheritance');

# the effective spec merges child first, inherited after own
my $spec = Object::Proto::Cmd::_spec('IChild');
is_deeply($spec->{order}, ['target', 'retries', 'verbose'],
	'own options first, inherited after');
is($spec->{options}{retries}{doc}, 'retry harder', 'override doc wins');
is_deeply($spec->{options}{retries}{aliases}, ['r'],
	'unmentioned alias survives the override');
is($spec->{options}{retries}{default}, 5, 'slot_info sees the new default');

# inherited and overridden options both parse, including the kept alias
my ($code, $out, $err) = run_main('IChild', '-r', '9', '-v', '--target', 'x');
is($code, 0, 'child dispatch ok');
is_deeply($IChild::LAST, { v => 1, r => 9, t => 'x' },
	'inherited, overridden and own options all land');

# parent class still works untouched
($code, $out, $err) = run_main('IBase', '-r', '3');
is($code, 0, 'parent dispatch ok');
is($IBase::LAST->{r}, 3, 'parent unaffected by child override');
my $pspec = Object::Proto::Cmd::_spec('IBase');
is($pspec->{options}{retries}{doc}, 'try N times', 'parent doc unchanged');

# generated help lists own options before inherited, with merged meta
($code, $out, $err) = run_main('IChild', '--help');
is($code, 0, 'child help ok');
like($out, qr/--target.*\n.*--retries.*\n.*--verbose/s, 'help order own then inherited');
like($out, qr/-r, --retries N\s{3,}retry harder \(default: 5\)/, 'merged row');

done_testing;
