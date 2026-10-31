package Greet::Cmd::Hello;

use strict;
use warnings;
use Object::Proto::Cmd -types;

abstract 'say hello';
usage    '[options] NAME...';

option greeting => (
	isa     => Str,
	default => 'hello',
	alias   => 'g',
	doc     => 'word to use',
);
option times => (
	isa     => Int,
	default => 1,
	alias   => 'n',
	doc     => 'repeat N times',
);
option shout => (
	isa   => Bool,
	alias => 's',
	doc   => 'uppercase the greeting',
);

sub run {
	my ($self, @names) = @_;
	die "no one to greet\n" unless @names;
	print STDERR "greeting " . scalar(@names) . " names\n"
		if $self->cmd_parent->verbose;
	for (1 .. $self->times) {
		my $line = join ' ', $self->greeting, @names;
		print $self->shout ? uc $line : $line, "\n";
	}
	return 0;
}

1;
