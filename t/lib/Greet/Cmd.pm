package Greet::Cmd;

use strict;
use warnings;
use Object::Proto::Cmd -types;

our $VERSION = '0.5';

name     'greet';
abstract 'greet people from the command line';

option verbose => (
	isa   => Bool,
	alias => 'v',
	doc   => 'print progress to stderr',
);

command hello => 'Greet::Cmd::Hello';
command wave  => 'Greet::Cmd::Wave';

1;
