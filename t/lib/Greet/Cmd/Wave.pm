package Greet::Cmd::Wave;

use strict;
use warnings;
use Object::Proto::Cmd;

abstract 'wave instead';

sub run {
	print "o/\n";
	return 0;
}

1;
