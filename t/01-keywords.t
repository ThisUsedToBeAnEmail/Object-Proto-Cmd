use strict;
use warnings;
use Test::More;

{
	package TestApp;

	use Object::Proto::Cmd -types;

	name     'testapp';
	abstract 'a test app';
	usage    '[options] COMMAND';

	option verbose => (
		isa   => Bool,
		alias => 'v',
		doc   => 'be noisy',
	);
	option level => (
		isa     => Int,
		default => 3,
		alias   => ['l', 'lvl'],
		doc     => 'set the level',
	);
	option secret => (
		isa    => Str,
		hidden => 1,
	);

	command foo => 'TestApp::Foo';
	command bar => 'TestApp::Bar';

	1;
}

{
	package TestCmd::Coderefs;

	use Object::Proto::Cmd qw/Str/;

	our $TRIGGERED = 0;

	option checked => (
		isa => sub { die "not ok\n" unless $_[0] =~ /^ok/ },
	);
	option built => (
		lazy    => 1,
		default => sub { 'made' },
	);
	option ticker => (
		isa     => Str,
		trigger => sub { $TRIGGERED++ },
	);
	option [qw/aa bb/] => (
		isa     => Str,
		default => 'x',
	);

	sub run { 0 }

	1;
}

{
	package TestCmd::WithArgs;

	use Object::Proto::Cmd;

	arg infile => (isa => 'Str', required => 1, doc => 'input file');
	arg rest   => (isa => 'ArrayRef');

	sub run { 0 }

	1;
}

package main;

# attributes exist on the class, including the reserved cmd_parent
my %props = map { $_ => 1 } Object::Proto::properties('TestApp');
ok($props{verbose}, 'verbose is a property');
ok($props{level}, 'level is a property');
ok($props{secret}, 'secret is a property');
ok($props{cmd_parent}, 'cmd_parent is appended');

# alias/doc/hidden were stripped before define - slot_info knows the rest
my $si = Object::Proto::slot_info('TestApp', 'verbose');
is($si->{type}, 'Bool', 'verbose typed Bool');
ok($si->{has_default}, 'Bool got an auto default');
$si = Object::Proto::slot_info('TestApp', 'level');
is($si->{type}, 'Int', 'level typed Int');
ok($si->{has_default}, 'level has its default');

# an absent flag reads false, not undef
my $app = TestApp->new;
is($app->verbose, 0, 'Bool auto-default is 0');
is($app->level, 3, 'plain default survives translation');

# the Cmd meta holds what slot_info cannot
my $meta = $Object::Proto::Cmd::META{TestApp};
is($meta->{name}, 'testapp', 'name recorded');
is($meta->{abstract}, 'a test app', 'abstract recorded');
is($meta->{usage}, '[options] COMMAND', 'usage recorded');
is_deeply($meta->{options}{verbose}{aliases}, ['v'], 'alias recorded');
is($meta->{options}{verbose}{doc}, 'be noisy', 'doc recorded');
is_deeply($meta->{options}{level}{aliases}, ['l', 'lvl'], 'alias arrayref recorded');
ok($meta->{options}{secret}{hidden}, 'hidden recorded');
is_deeply($meta->{command_order}, ['foo', 'bar'], 'command order kept');
is($meta->{commands}{foo}, 'TestApp::Foo', 'command class recorded');
ok(TestApp->can('main'), 'main installed');

# coderef isa becomes an anonymous registered type
eval { TestCmd::Coderefs->new(checked => 'nope') };
like($@, qr/not ok/, 'coderef isa rejects');
my $c = TestCmd::Coderefs->new(checked => 'okay');
is($c->checked, 'okay', 'coderef isa accepts');

# coderef default becomes a generated builder method
is($c->built, 'made', 'coderef default built lazily');

# coderef trigger becomes a generated method
$c->ticker('tick');
is($TestCmd::Coderefs::TRIGGERED, 1, 'coderef trigger fired');

# arrayref NAME declares several options with the same params
is($c->aa, 'x', 'first of arrayref NAME');
is($c->bb, 'x', 'second of arrayref NAME');
my $cmeta = $Object::Proto::Cmd::META{'TestCmd::Coderefs'};
is_deeply([grep { /^(aa|bb)$/ } @{$cmeta->{option_order}}], ['aa', 'bb'],
	'both names in option order');

# args are attributes with their own meta list
my $ameta = $Object::Proto::Cmd::META{'TestCmd::WithArgs'};
is(scalar @{$ameta->{args}}, 2, 'two args recorded');
is($ameta->{args}[0]{name}, 'infile', 'arg order kept');
is($ameta->{args}[0]{doc}, 'input file', 'arg doc kept');
$si = Object::Proto::slot_info('TestCmd::WithArgs', 'infile');
ok($si->{is_required}, 'arg required reaches the slot');

# named type imports install constants; unknown names croak
eval q{ package TBadType; use Object::Proto::Cmd qw/Bogus/; 1 };
like($@, qr/Unknown type 'Bogus'/, 'unknown type import croaks');

done_testing;
