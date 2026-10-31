#!perl
use 5.008003;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'Object::Proto::Cmd' ) || print "Bail out!\n";
}

diag( "Testing Object::Proto::Cmd $Object::Proto::Cmd::VERSION, Perl $], $^X" );
