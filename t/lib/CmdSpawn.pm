package CmdSpawn;

# Spawning the fixture CLI as a real subprocess.
#
# Tests never fork perl themselves: a forked test process carries the
# harness's END blocks and buffered TAP with it, and both fire twice. The
# CLI process is the thing under test anyway.

use strict;
use warnings;
use Exporter 'import';
use FindBin ();
use File::Temp ();

our @EXPORT = qw(cmd_run);

my $BIN = "$FindBin::Bin/bin/greet";
my $LIB = "$FindBin::Bin/lib";

# Run the fixture script to completion. Returns (exit_code, output_lines)
# with stdout and stderr interleaved into the one capture.
sub cmd_run {
    my ($args) = @_;
    my $out = File::Temp->new(TEMPLATE => 'cmdoutXXXXXX', TMPDIR => 1);
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        open STDOUT, '>&', $out or die "redirect: $!";
        open STDERR, '>&', $out or die "redirect: $!";
        exec $^X, '-Mblib', "-I$LIB", $BIN, @$args
            or die "exec: $!";
    }
    waitpid $pid, 0;
    my $code = $? >> 8;
    open my $fh, '<', "$out" or die "read $out: $!";
    my @lines = <$fh>;
    return ($code, \@lines);
}

1;
