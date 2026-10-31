use strict;
use warnings;
use Test::More;

# a second use in the same package is a no-op, not a second keyword set
{
	package TDouble;

	use Object::Proto::Cmd;
	use Object::Proto::Cmd;

	option thing => (isa => 'Str', default => 'fine');

	sub run { 0 }

	1;
}

package main;

my $obj = TDouble->new;
is($obj->thing, 'fine', 'double use still defines the class once');

# refuse to layer over a package that already has sugar-like keywords
eval q{
	package THas;
	sub has {}
	use Object::Proto::Cmd;
	1;
};
like($@, qr/'has' is already defined/, 'existing has keyword croaks');

eval q{
	package TExtends;
	sub extends {}
	use Object::Proto::Cmd;
	1;
};
like($@, qr/'extends' is already defined/, 'existing extends keyword croaks');

SKIP: {
	eval { require Object::Proto::Sugar; 1 }
		or skip 'Object::Proto::Sugar not installed', 1;
	eval q{
		package TSugarFirst;
		use Object::Proto::Sugar;
		use Object::Proto::Cmd;
		1;
	};
	like($@, qr/already defined/, 'Sugar keywords in place croaks');
}

# typos in option and arg parameters die at compile time
eval q{
	package TBadKey;
	use Object::Proto::Cmd;
	option foo => (bogus => 1);
	1;
};
like($@, qr/unknown option parameter 'bogus'/, 'unknown option param croaks');

eval q{
	package TBadArgKey;
	use Object::Proto::Cmd;
	arg foo => (alias => 'f');
	1;
};
like($@, qr/unknown arg parameter 'alias'/, 'unknown arg param croaks');

done_testing;
