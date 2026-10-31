package Object::Proto::Cmd;

use 5.008003;
use strict;
use warnings;
use BEGIN::Lift;
use Devel::Hook;
use Object::Proto;
use Carp qw/croak/;
use Scalar::Util ();

our $VERSION = 0.01;

our (%META, %SEEN, %valid_types, @type_list, $OUT, $ERR);

BEGIN {
	@type_list = @{ Object::Proto::list_types() };
	%valid_types = map { $_ => 1 } @type_list;
}

# The option keyword takes the Sugar "has" vocabulary plus the three keys
# only the command line cares about: alias, doc and hidden. Anything else
# is a typo and dies at compile time, where the line number still points
# at the declaration.
my %valid_params = map { $_ => 1 } qw(
	is isa coerce default builder lazy required trigger predicate
	clearer reader writer init_arg arg weak_ref weak private
	alias doc hidden
);
my %valid_arg_params = map { $_ => 1 } qw(isa required default doc);

sub import {
	my ($pkg, @import) = @_;
	my $caller = caller();

	if (grep { $_ eq '-types' } @import) {
		no strict 'refs';
		for my $type (@type_list) {
			*{"${caller}::${type}"} = sub { $type };
		}
	}
	for my $name (@import) {
		next if $name =~ /^-/;
		croak "Unknown type '$name' requested from Object::Proto::Cmd"
			unless $valid_types{$name};
		no strict 'refs';
		*{"${caller}::${name}"} = sub { $name };
	}

	return if $SEEN{$caller}++;

	# One object layer per package. If Sugar or Object::Proto keywords are
	# already installed here, a second set of lifted keywords plus a second
	# UNITCHECK hook would both call define for the same class.
	for my $kw (qw(has extends option command)) {
		no strict 'refs';
		croak "cannot use Object::Proto::Cmd in $caller: '$kw' is already defined"
			if defined &{"${caller}::${kw}"};
	}

	my (%info, @options, @args, @commands, @extends);

	BEGIN::Lift::install(($caller, 'name')     => sub { $info{name} = $_[0] });
	BEGIN::Lift::install(($caller, 'abstract') => sub { $info{abstract} = $_[0] });
	BEGIN::Lift::install(($caller, 'usage')    => sub { $info{usage} = $_[0] });

	BEGIN::Lift::install(($caller, 'command') => sub {
		my ($cmd, $class) = @_;
		croak "command requires a name and a class" unless defined $cmd && defined $class;
		push @commands, $cmd, $class;
	});

	BEGIN::Lift::install(($caller, 'option') => sub {
		my ($name, %params) = @_;
		for my $key (keys %params) {
			croak "unknown option parameter '$key' in $caller" unless $valid_params{$key};
		}
		my @names = ref $name ? @{$name} : $name;
		push @options, [$_, {%params}] for @names;
	});

	BEGIN::Lift::install(($caller, 'arg') => sub {
		my ($name, %params) = @_;
		for my $key (keys %params) {
			croak "unknown arg parameter '$key' in $caller" unless $valid_arg_params{$key};
		}
		push @args, [$name, {%params}];
	});

	BEGIN::Lift::install(($caller, 'extends') => sub { push @extends, @_ });

	Devel::Hook->push_UNITCHECK_hook(sub {
		_finalise($caller, \%info, \@options, \@args, \@commands, \@extends);
	});
}

sub _finalise {
	my ($caller, $info, $options, $args, $commands, $extends) = @_;

	my %meta = (
		name          => $info->{name},
		abstract      => $info->{abstract},
		usage         => $info->{usage},
		commands      => {},
		command_order => [],
		options       => {},
		option_order  => [],
		args          => [],
	);

	my (%isa, @attributes);

	for my $o (@{$options}) {
		my ($name, $params) = @{$o};
		(my $plain = $name) =~ s/^\+//;
		my %cmdmeta;
		if (exists $params->{alias}) {
			my $alias = delete $params->{alias};
			$cmdmeta{aliases} = ref $alias ? [@{$alias}] : [$alias];
		}
		$cmdmeta{doc}    = delete $params->{doc}    if exists $params->{doc};
		$cmdmeta{hidden} = delete $params->{hidden} ? 1 : 0 if exists $params->{hidden};
		$cmdmeta{ctor_key} = $params->{init_arg} || $params->{arg}
			if $params->{init_arg} || $params->{arg};
		if ($name =~ /^\+/) {
			# Overriding an inherited option: start from the parent's meta
			# entry so an unmentioned alias or doc survives the override.
			my $inherited = _find_meta_option($extends, $plain) || {};
			%cmdmeta = (%{$inherited}, %cmdmeta);
		}
		$cmdmeta{doc}      = '' unless defined $cmdmeta{doc};
		$cmdmeta{hidden}   = 0  unless $cmdmeta{hidden};
		$cmdmeta{aliases}  = [] unless $cmdmeta{aliases};
		$cmdmeta{ctor_key} = $plain unless $cmdmeta{ctor_key};

		# An absent flag must read false, not undef.
		my $isa_str = defined $params->{isa} && !ref $params->{isa}
			? ucfirst $params->{isa} : '';
		$params->{default} = 0
			if $isa_str eq 'Bool'
			&& !exists $params->{default} && !exists $params->{builder};

		push @attributes, _translate($caller, $name, $params, \%isa);
		my $existed = exists $meta{options}{$plain};
		$meta{options}{$plain} = \%cmdmeta;
		push @{$meta{option_order}}, $plain unless $existed;
	}

	for my $a (@{$args}) {
		my ($name, $params) = @{$a};
		my %argmeta = (name => $name, doc => delete $params->{doc});
		$argmeta{doc} = '' unless defined $argmeta{doc};
		push @attributes, _translate($caller, $name, $params, \%isa);
		push @{$meta{args}}, \%argmeta;
	}

	my @pairs = @{$commands};
	while (@pairs) {
		my ($cmd, $class) = (shift @pairs, shift @pairs);
		push @{$meta{command_order}}, $cmd unless exists $meta{commands}{$cmd};
		$meta{commands}{$cmd} = $class;
	}

	# Every command class carries its constructed parent command during
	# nested dispatch. Only the root of a Cmd hierarchy declares the slot;
	# extending another Cmd class inherits it.
	my $inherits = grep { $META{$_} } @{$extends};
	push @attributes, 'cmd_parent:Any' unless $inherits;

	my @extends_arg = @{$extends} > 1
		? (extends => [@{$extends}])
		: @{$extends}
			? (extends => $extends->[0])
			: ();
	Object::Proto::define($caller, @extends_arg, @attributes);

	$META{$caller} = \%meta;

	{
		no strict 'refs';
		*{"${caller}::main"} = sub {
			my $class = shift;
			return _dispatch($class, @_);
		} unless defined &{"${caller}::main"};
	}
}

sub _find_meta_option {
	my ($extends, $name) = @_;
	my %seen;
	my @queue = @{$extends};
	while (my $class = shift @queue) {
		next if $seen{$class}++;
		my $meta = $META{$class};
		return $meta->{options}{$name} if $meta && $meta->{options}{$name};
		push @queue, eval { Object::Proto::ancestors($class) };
	}
	return undef;
}

# The hash options to colon string translation, trimmed from
# Object::Proto::Sugar. Coderef isa is registered as an anonymous type,
# coderef default/builder/trigger become generated methods on the class.

sub _translate {
	my ($caller, $attr, $spec, $isa) = @_;
	$attr = _configure_is($attr, $spec);
	$attr = _configure_required($attr, $spec);
	$attr = _configure_lazy($attr, $spec);
	$attr = _configure_isa_and_coerce($attr, $spec, $isa, $caller);
	$attr = _configure_default_and_builder($attr, $spec, $isa, $caller);
	$attr = _configure_trigger($attr, $spec, $isa, $caller);
	$attr = _configure_predicate($attr, $spec, $caller);
	$attr = _configure_clearer($attr, $spec, $caller);
	$attr = _configure_reader_and_writer($attr, $spec, $caller);
	$attr = _configure_init_arg($attr, $spec);
	$attr = _configure_weak_ref($attr, $spec);
	$attr = _configure_private($attr, $spec);
	return $attr;
}

sub _configure_is {
	my ($attr, $spec) = @_;
	if (defined $spec->{is} && $spec->{is} eq 'ro') {
		$attr .= ":readonly";
	}
	return $attr;
}

sub _configure_required {
	my ($attr, $spec) = @_;
	if ($spec->{required}) {
		$attr .= ":required";
	}
	return $attr;
}

sub _configure_lazy {
	my ($attr, $spec) = @_;
	if ($spec->{lazy}) {
		$attr .= ":lazy";
	}
	return $attr;
}

sub _configure_isa_and_coerce {
	my ($attr, $spec, $isa, $caller) = @_;
	my ($ref, $val1, $val2);
	if (defined $spec->{isa} || defined $spec->{coerce}) {
		$ref = ref $spec->{isa} || "";
		if ($ref eq 'CODE' || defined $spec->{coerce}) {
			$val1 = (exists $spec->{isa} ? $spec->{isa} + 0 : '0000');
			$val2 = (exists $spec->{coerce} ? $spec->{coerce} + 0 : '0000');
			if (!$isa->{$val1 . $val2}++) {
				Object::Proto::register_type('T' . $val1 . $val2,
					$spec->{isa} || sub { 1 },
					$spec->{coerce} || sub { $_[0] }
				);
			}
			$attr .= sprintf(":T%s%s", $val1, $val2);
		} elsif (!$ref) {
			$val1 = ucfirst($spec->{isa});
			if ($valid_types{$val1}) {
				$attr .= sprintf(":%s", $val1);
			}
		} else {
			croak "Failed to attach isa for $attr in $caller";
		}
	}
	return $attr;
}

sub _configure_default_and_builder {
	my ($attr, $spec, $isa, $caller) = @_;
	my ($ref1, $ref2, $val1);
	return $attr unless exists $spec->{default} || exists $spec->{builder};
	$ref1 = ref($spec->{default}) || "";
	if (exists $spec->{builder} || $ref1 eq 'CODE') {
		$ref2 = ref($spec->{builder});
		if (!$ref2 && $ref1 ne 'CODE') {
			if ($spec->{builder} =~ m/^1$/) {
				$attr .= ':builder()';
			} else {
				$attr .= sprintf(":builder(%s)", $spec->{builder});
			}
		} elsif ($ref2 && $ref2 eq 'CODE' || $ref1 eq 'CODE') {
			my $cb = exists $spec->{builder} ? $spec->{builder} : $spec->{default};
			$val1 = 'BUILDER' . ($cb + 0);
			if (!$isa->{$val1}++) {
				no strict 'refs';
				*{"${caller}::${val1}"} = $cb;
			}
			$attr .= sprintf(":builder(%s)", $val1);
		} else {
			croak "Failed to attach builder for $attr in $caller";
		}
	} elsif (!$ref1) {
		$attr .= sprintf(":default(%s)", defined $spec->{default} ? $spec->{default} : 'undef');
	} elsif ($ref1 eq 'ARRAY') {
		$attr .= ":default([])";
	} elsif ($ref1 eq 'HASH') {
		$attr .= ":default({})";
	}
	return $attr;
}

sub _configure_trigger {
	my ($attr, $spec, $isa, $caller) = @_;
	my ($ref, $val1);
	if (exists $spec->{trigger}) {
		$ref = ref $spec->{trigger};
		if (!$ref) {
			$attr .= sprintf(":trigger(%s)", $spec->{trigger});
		} elsif ($ref eq 'CODE') {
			$val1 = 'TRIG' . ($spec->{trigger} + 0);
			if (!$isa->{$val1}++) {
				no strict 'refs';
				*{"${caller}::${val1}"} = $spec->{trigger};
			}
			$attr .= sprintf(":trigger(%s::%s)", $caller, $val1);
		}
	}
	return $attr;
}

sub _configure_predicate {
	my ($attr, $spec, $caller) = @_;
	if (defined $spec->{predicate}) {
		if ($spec->{predicate} =~ m/^1$/) {
			$attr .= ":predicate";
		} elsif (!ref $spec->{predicate}) {
			$attr .= sprintf(":predicate(%s)", $spec->{predicate});
		} else {
			croak "Failed to attach predicate for $attr in $caller";
		}
	}
	return $attr;
}

sub _configure_clearer {
	my ($attr, $spec, $caller) = @_;
	if (defined $spec->{clearer}) {
		if ($spec->{clearer} =~ m/^1$/) {
			$attr .= ":clearer";
		} elsif (!ref $spec->{clearer}) {
			$attr .= sprintf(":clearer(%s)", $spec->{clearer});
		} else {
			croak "Failed to attach clearer for $attr in $caller";
		}
	}
	return $attr;
}

sub _configure_reader_and_writer {
	my ($attr, $spec, $caller) = @_;
	my ($name) = $attr =~ m/^\+?([^\:]+)/;
	if (exists $spec->{reader}) {
		croak "Failed to attach reader for $attr in $caller" if ref $spec->{reader};
		if ($spec->{reader} =~ m/^1$/) {
			$attr .= sprintf(":reader(get_%s)", $name);
		} else {
			$attr .= sprintf(":reader(%s)", $spec->{reader});
		}
	}
	if (exists $spec->{writer}) {
		croak "Failed to attach writer for $attr in $caller" if ref $spec->{writer};
		if ($spec->{writer} =~ m/^1$/) {
			$attr .= sprintf(":writer(set_%s)", $name);
		} else {
			$attr .= sprintf(":writer(%s)", $spec->{writer});
		}
	}
	return $attr;
}

sub _configure_init_arg {
	my ($attr, $spec) = @_;
	if (defined $spec->{init_arg} || defined $spec->{arg}) {
		$attr .= sprintf(":arg(%s)", $spec->{init_arg} || $spec->{arg});
	}
	return $attr;
}

sub _configure_weak_ref {
	my ($attr, $spec) = @_;
	if ($spec->{weak_ref} || $spec->{weak}) {
		$attr .= ':weak';
	}
	return $attr;
}

sub _configure_private {
	my ($attr, $spec) = @_;
	if ($spec->{private}) {
		$attr .= ':private';
	}
	return $attr;
}

# Everything below is runtime: the spec builder, the parser, dispatch and
# generated help. Output goes through _out/_err so tests can capture it
# without spawning a process.

sub _out { $OUT || \*STDOUT }
sub _err { $ERR || \*STDERR }

sub _prog {
	my ($class) = @_;
	my $meta = $META{$class};
	return $meta->{name} if $meta && defined $meta->{name};
	(my $prog = $0) =~ s{.*[/\\]}{};
	return $prog;
}

sub _tidy {
	my ($msg) = @_;
	$msg = '' unless defined $msg;
	$msg =~ s/ at .+ line \d+\.?\s*\z//s;
	$msg =~ s/\s+\z//;
	return $msg;
}

sub _load {
	my ($class) = @_;
	return if $META{$class};
	(my $file = "$class.pm") =~ s{::}{/}g;
	eval { require $file; 1 } or do {
		my $err = $@;
		# The class may be defined inline (tests, single file scripts)
		# rather than living in its own module file.
		die $err unless $META{$class};
	};
	die "'$class' is not an Object::Proto::Cmd class\n" unless $META{$class};
}

# The effective command line spec for a class: its own options merged with
# everything inherited, child first so an override wins whole, plus the
# token lookup tables the parser works from.

sub _spec {
	my ($class) = @_;
	my (@chain, %seen);
	for my $c ($class, eval { Object::Proto::ancestors($class) }) {
		next unless defined $c;
		next if $seen{$c}++;
		push @chain, $c;
	}
	my (%options, @order, %args_seen, @args);
	for my $c (@chain) {
		my $meta = $META{$c} or next;
		for my $name (@{$meta->{option_order}}) {
			next if $options{$name};
			my $si = eval { Object::Proto::slot_info($class, $name) } or next;
			my %o = %{$meta->{options}{$name}};
			$o{name}        = $name;
			$o{type}        = defined $si->{type} ? $si->{type} : '';
			$o{required}    = $si->{is_required} ? 1 : 0;
			$o{has_default} = $si->{has_default} ? 1 : 0;
			$o{default}     = $si->{default} if exists $si->{default};
			$options{$name} = \%o;
			push @order, $name;
		}
		for my $a (@{$meta->{args}}) {
			next if $args_seen{$a->{name}}++;
			my $si = eval { Object::Proto::slot_info($class, $a->{name}) } or next;
			push @args, {
				%{$a},
				type        => defined $si->{type} ? $si->{type} : '',
				required    => $si->{is_required} ? 1 : 0,
				has_default => $si->{has_default} ? 1 : 0,
			};
		}
	}
	my (%long, %short, %neg);
	for my $name (@order) {
		my $o = $options{$name};
		(my $hyphen = $name) =~ tr/_/-/;
		$long{$name}   = $name;
		$long{$hyphen} = $name;
		for my $alias (@{$o->{aliases}}) {
			if (length $alias == 1) {
				$short{$alias} = $name;
			} else {
				(my $ah = $alias) =~ tr/_/-/;
				$long{$alias} = $name;
				$long{$ah}    = $name;
			}
		}
	}
	for my $name (@order) {
		next unless $options{$name}{type} eq 'Bool';
		(my $hyphen = $name) =~ tr/_/-/;
		for my $cand ("no-$hyphen", "no_$name") {
			$neg{$cand} = $name unless exists $long{$cand};
		}
	}
	return {
		class   => $class,
		options => \%options,
		order   => \@order,
		args    => \@args,
		long    => \%long,
		short   => \%short,
		neg     => \%neg,
	};
}

sub _usage_error {
	my ($msg) = @_;
	die { usage_error => $msg };
}

sub _takes_value {
	my ($type) = @_;
	return $type eq 'Bool' ? 0 : 1;
}

sub _store_value {
	my ($values, $opt, $val) = @_;
	my $type = $opt->{type};
	my $name = $opt->{name};
	(my $display = $name) =~ tr/_/-/;
	if ($type eq 'Int') {
		_usage_error("option '--$display' expects an integer, got '$val'")
			unless $val =~ /^[-+]?\d+$/;
		$values->{$name} = $val;
	} elsif ($type eq 'Num') {
		_usage_error("option '--$display' expects a number, got '$val'")
			unless Scalar::Util::looks_like_number($val);
		$values->{$name} = $val;
	} elsif ($type eq 'ArrayRef') {
		push @{$values->{$name}}, $val;
	} elsif ($type eq 'HashRef') {
		_usage_error("option '--$display' expects KEY=VALUE, got '$val'")
			unless $val =~ /^([^=]+)=(.*)$/s;
		$values->{$name}{$1} = $2;
	} else {
		$values->{$name} = $val;
	}
	return;
}

# GNU style parsing. Two modes: 'stop' halts at the first non option token
# (subcommand resolution), 'permute' allows options anywhere and collects
# the non options in order (leaf commands). Returns (\%values, \@rest)
# where rest is the remaining tokens in stop mode and the positionals in
# permute mode. Misuse dies with { usage_error => $msg }.

sub _parse_options {
	my ($spec, $argv, $mode) = @_;
	my (%values, @rest);
	my @toks = @{$argv};
	while (@toks) {
		my $t = $toks[0];
		if ($t eq '--') {
			last if $mode eq 'stop';
			shift @toks;
			push @rest, @toks;
			@toks = ();
			last;
		}
		if ($t eq '-' || $t =~ /^-\d/ || $t !~ /^-/) {
			last if $mode eq 'stop';
			shift @toks;
			push @rest, $t;
			next;
		}
		shift @toks;
		if ($t =~ /^--(.+)$/s) {
			my $body = $1;
			my ($name, $val);
			my $i = index $body, '=';
			if ($i >= 0) {
				$name = substr $body, 0, $i;
				$val  = substr $body, $i + 1;
			} else {
				$name = $body;
			}
			my ($canon, $negated);
			if (exists $spec->{long}{$name}) {
				$canon = $spec->{long}{$name};
			} elsif (exists $spec->{neg}{$name}) {
				$canon   = $spec->{neg}{$name};
				$negated = 1;
			} else {
				_usage_error("unknown option '--$name'");
			}
			my $opt = $spec->{options}{$canon};
			if (!_takes_value($opt->{type})) {
				_usage_error("option '--$name' does not take a value")
					if defined $val;
				$values{$canon} = $negated ? 0 : 1;
			} else {
				_usage_error("option '--$name' does not take a value")
					if $negated;
				unless (defined $val) {
					_usage_error("option '--$name' requires a value")
						unless @toks;
					$val = shift @toks;
				}
				_store_value(\%values, $opt, $val);
			}
			next;
		}
		my $bundle = substr $t, 1;
		while (length $bundle) {
			my $c = substr $bundle, 0, 1;
			$bundle = substr $bundle, 1;
			my $canon = $spec->{short}{$c};
			_usage_error("unknown option '-$c'") unless defined $canon;
			my $opt = $spec->{options}{$canon};
			if (!_takes_value($opt->{type})) {
				$values{$canon} = 1;
				next;
			}
			my $val;
			if (length $bundle) {
				$val    = $bundle;
				$bundle = '';
			} else {
				_usage_error("option '-$c' requires a value") unless @toks;
				$val = shift @toks;
			}
			_store_value(\%values, $opt, $val);
		}
	}
	push @rest, @toks if $mode eq 'stop';
	return (\%values, \@rest);
}

sub _check_required {
	my ($spec, $values) = @_;
	for my $name (@{$spec->{order}}) {
		my $o = $spec->{options}{$name};
		next unless $o->{required};
		next if exists $values->{$name};
		next if $o->{has_default};
		(my $display = $name) =~ tr/_/-/;
		_usage_error("missing required option '--$display'");
	}
	return;
}

sub _construct {
	my ($class, $spec, $values, $parent, $extra) = @_;
	my %ctor;
	for my $name (keys %{$values}) {
		my $key = $spec->{options}{$name} ? $spec->{options}{$name}{ctor_key} : $name;
		$ctor{$key} = $values->{$name};
	}
	%ctor = (%ctor, %{$extra}) if $extra;
	$ctor{cmd_parent} = $parent;
	my $self = eval { $class->new(%ctor) };
	_usage_error(_tidy($@)) if $@;
	return $self;
}

# Declared positional args are shifted off the front of the leftover
# tokens into constructor values; a trailing ArrayRef arg slurps the rest.
# Anything beyond the declared args still reaches run.

sub _apply_args {
	my ($spec, $positional) = @_;
	my %extra;
	my @args = @{$spec->{args}};
	for my $i (0 .. $#args) {
		my $a = $args[$i];
		if ($a->{type} eq 'ArrayRef' && $i == $#args) {
			$extra{$a->{name}} = [@{$positional}];
			@{$positional} = ();
			last;
		}
		if (@{$positional}) {
			$extra{$a->{name}} = shift @{$positional};
		} elsif ($a->{required} && !$a->{has_default}) {
			_usage_error("missing required argument '" . uc($a->{name}) . "'");
		}
	}
	return \%extra;
}

sub _exit_code {
	my ($code) = @_;
	return 0 unless defined $code && length $code;
	no warnings 'numeric';
	return int $code;
}

sub _merge_values {
	my ($base, $over) = @_;
	for my $name (keys %{$over}) {
		if (ref $over->{$name} eq 'ARRAY' && ref $base->{$name} eq 'ARRAY') {
			push @{$base->{$name}}, @{$over->{$name}};
		} elsif (ref $over->{$name} eq 'HASH' && ref $base->{$name} eq 'HASH') {
			%{$base->{$name}} = (%{$base->{$name}}, %{$over->{$name}});
		} else {
			$base->{$name} = $over->{$name};
		}
	}
	return $base;
}

# Walk leading tokens descending through registered subcommands. In loose
# mode (the --help scan) unknown tokens are skipped; in strict mode (the
# help subcommand) they are a usage error.

sub _descend {
	my ($class, $tokens, $chain, $strict) = @_;
	for my $t (@{$tokens}) {
		last if $t eq '--';
		next if !$strict && $t =~ /^-/;
		my $meta = $META{$class} or last;
		if (exists $meta->{commands}{$t}) {
			$class = $meta->{commands}{$t};
			_load($class);
			push @{$chain}, $t;
		} elsif ($strict) {
			_usage_error("unknown command '$t'");
		}
	}
	return $class;
}

sub _dispatch {
	my ($class, @argv) = @_;
	my $prog  = _prog($class);
	my @chain = ($prog);
	my $current = $class;
	my $rc = eval { _run($class, $prog, \@chain, \$current, @argv) };
	if (my $err = $@) {
		if (ref $err eq 'HASH' && exists $err->{usage_error}) {
			my $fh = _err();
			print {$fh} "$prog: $err->{usage_error}\n\n";
			_usage($current, $fh, \@chain);
			return 2;
		}
		print {_err()} "$prog: " . _tidy($err) . "\n";
		return 1;
	}
	return $rc;
}

sub _run {
	my ($class, $prog, $chain, $current_ref, @argv) = @_;
	my $spec = _spec($class);

	# --help always works, even alongside a missing required option, so it
	# is scanned before any strict parsing. The chain resolved so far picks
	# which command's usage is shown.
	for my $t (@argv) {
		last if $t eq '--';
		if ($t eq '-h' || $t eq '--help') {
			my $target = _descend($class, \@argv, $chain, 0);
			_usage($target, _out(), $chain);
			return 0;
		}
	}

	# -v and --version stand down when a declared option claims the name.
	if (@argv && (($argv[0] eq '-v' && !exists $spec->{short}{v})
			|| ($argv[0] eq '--version' && !exists $spec->{long}{version}))) {
		my $version = $class->VERSION;
		print {_out()} "$prog " . (defined $version ? $version : '') . "\n";
		return 0;
	}

	my $meta = $META{$class};
	if (@argv && $argv[0] eq 'help'
			&& %{$meta->{commands}} && !exists $meta->{commands}{help}) {
		my @rest = @argv[1 .. $#argv];
		my $target = _descend($class, \@rest, $chain, 1);
		_usage($target, _out(), $chain);
		return 0;
	}

	my $parent;
	my $current = $class;
	my @cur = @argv;
	while (1) {
		${$current_ref} = $current;
		$spec = _spec($current);
		my ($values, $rest) = _parse_options($spec, \@cur, 'stop');
		$meta = $META{$current};
		if (%{$meta->{commands}} && @{$rest} && exists $meta->{commands}{$rest->[0]}) {
			_check_required($spec, $values);
			my $obj = _construct($current, $spec, $values, $parent);
			my $cmd = shift @{$rest};
			push @{$chain}, $cmd;
			$parent  = $obj;
			$current = $meta->{commands}{$cmd};
			_load($current);
			@cur = @{$rest};
			next;
		}
		if ($current->can('run')) {
			my ($more, $positional) = _parse_options($spec, $rest, 'permute');
			_merge_values($values, $more);
			_check_required($spec, $values);
			my $extra = _apply_args($spec, $positional);
			my $obj = _construct($current, $spec, $values, $parent, $extra);
			return _exit_code($obj->run(@{$positional}));
		}
		if (@{$rest}) {
			_usage_error("unknown command '$rest->[0]'");
		}
		_usage($current, _out(), $chain);
		return 0;
	}
}

# Generated help. One function feeds --help, the help subcommand and every
# misuse path, so the text cannot drift.

sub _placeholder {
	my ($type) = @_;
	return ''          if $type eq 'Bool';
	return 'N'         if $type eq 'Int' || $type eq 'Num';
	return 'KEY=VALUE' if $type eq 'HashRef';
	return 'VALUE';
}

sub _usage {
	my ($class, $fh, $chain) = @_;
	my $meta = $META{$class} || {};
	my $spec = _spec($class);

	my $summary = $meta->{usage};
	unless (defined $summary) {
		$summary = '[options]';
		$summary .= ' COMMAND' if $meta->{commands} && %{$meta->{commands}};
		for my $a (@{$spec->{args}}) {
			my $p = uc $a->{name};
			$p .= '...' if $a->{type} eq 'ArrayRef';
			$p = "[$p]" unless $a->{required};
			$summary .= " $p";
		}
	}
	print {$fh} "Usage: " . join(' ', @{$chain}) . " $summary\n";
	print {$fh} "\n" . $meta->{abstract} . "\n"
		if defined $meta->{abstract} && length $meta->{abstract};

	if ($meta->{command_order} && @{$meta->{command_order}}) {
		my @rows;
		for my $cmd (@{$meta->{command_order}}) {
			my $child = $meta->{commands}{$cmd};
			_load($child);
			my $abstract = $META{$child}{abstract};
			push @rows, [$cmd, defined $abstract ? $abstract : ''];
		}
		push @rows, ['help', 'show help for a command']
			unless exists $meta->{commands}{help};
		my $width = 0;
		length $_->[0] > $width and $width = length $_->[0] for @rows;
		print {$fh} "\nCommands:\n";
		printf {$fh} "  %-${width}s   %s\n", @{$_} for @rows;
	}

	my @rows;
	for my $name (@{$spec->{order}}) {
		my $o = $spec->{options}{$name};
		next if $o->{hidden};
		(my $display = $name) =~ tr/_/-/;
		my @shorts = grep { length $_ == 1 } @{$o->{aliases}};
		my $left = @shorts
			? join(', ', map { "-$_" } @shorts) . ", --$display"
			: "    --$display";
		my $ph = _placeholder($o->{type});
		$left .= " $ph" if length $ph;
		my $right = $o->{doc};
		$right .= ' (repeatable)' if $o->{type} eq 'ArrayRef';
		$right .= ' (required)'   if $o->{required};
		$right .= " (default: $o->{default})"
			if $o->{type} ne 'Bool'
			&& $o->{has_default} && defined $o->{default} && !ref $o->{default};
		$right =~ s/^\s+//;
		push @rows, [$left, $right];
	}
	if (@rows) {
		my $width = 0;
		length $_->[0] > $width and $width = length $_->[0] for @rows;
		print {$fh} "\nOptions:\n";
		for my $row (@rows) {
			if (length $row->[1]) {
				printf {$fh} "  %-${width}s   %s\n", @{$row};
			} else {
				print {$fh} "  $row->[0]\n";
			}
		}
	}
	return;
}

1;

__END__

=head1 NAME

Object::Proto::Cmd - subcommand CLI framework for Object::Proto classes

=head1 VERSION

Version 0.01

=cut

=head1 SYNOPSIS

	package Greet::Cmd;
	use Object::Proto::Cmd -types;

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

	package Greet::Cmd::Hello;
	use Object::Proto::Cmd -types;

	abstract 'say hello';
	usage    '[options] NAME...';

	option greeting => (
		isa     => Str,
		default => 'hello',
		alias   => 'g',
		doc     => 'word to use',
	);
	option shout => (
		isa   => Bool,
		alias => 's',
		doc   => 'uppercase the greeting',
	);

	sub run {
		my ($self, @names) = @_;
		die "no one to greet\n" unless @names;
		my $line = join ' ', $self->greeting, @names;
		print $self->shout ? uc $line : $line, "\n";
		return 0;
	}

	1;

Then a bin script that is a dispatcher and nothing else:

	#!/usr/bin/env perl
	use Greet::Cmd;
	exit Greet::Cmd->main(@ARGV);

Which behaves like this:

	$ greet hello world
	hello world
	$ greet -v hello -s world
	greeting 1 names
	HELLO WORLD
	$ greet help hello
	Usage: greet hello [options] NAME...
	...
	$ greet bogus; echo $?
	greet: unknown command 'bogus'
	...
	2

=head1 DESCRIPTION

Object::Proto::Cmd turns L<Object::Proto> classes into command line
programs. A command class declares options that are ordinary Object::Proto
attributes, registers its subcommands explicitly and provides a C<run>
method. The framework parses GNU style options from the declarations,
constructs the command objects, dispatches through nested subcommands,
generates all help text and maps outcomes onto a simple exit code
contract.

Everything the parser and the help generator know comes from the class
declarations, so usage text cannot drift from behaviour.

=head1 IMPORTING

	use Object::Proto::Cmd;
	use Object::Proto::Cmd -types;
	use Object::Proto::Cmd qw/Str Bool/;

Importing installs the keywords below into the calling package and, once
the package body has compiled, defines the class via
L<Object::Proto/define>. The C<-types> flag exports every built-in type
name (C<Any Defined Str Int Num Bool ArrayRef HashRef CodeRef Object>) as
a constant; individual type names may be imported instead. Requesting an
unknown name croaks.

A package may use Object::Proto::Cmd once; layering it over a package
that already has C<has> or C<extends> style keywords (for example from
L<Object::Proto::Sugar>) croaks, one object layer per package.

=head1 KEYWORDS

=head2 option

	option name => (%parameters);
	option [qw/first second/] => (%parameters);
	option '+inherited' => (%parameters);

Declares an attribute that is also a command line option. The parameters
are the L<Object::Proto::Sugar> C<has> vocabulary plus three keys only
the command line cares about, see L</OPTION PARAMETERS>. An arrayref
declares several options with the same parameters. A leading C<+>
modifies an option inherited via L</extends>; parameters not mentioned in
the override, including C<alias> and C<doc>, survive from the parent.

The attribute name uses underscores; on the command line both the
underscore and the hyphen spelling are accepted and the hyphen spelling
is displayed.

=head2 arg

	arg name => (%parameters);

Declares a positional argument that is also an attribute. Declaration
order is positional order and a trailing C<ArrayRef> arg slurps whatever
remains. Accepted parameters are C<isa>, C<required>, C<default> and
C<doc>. Positionals beyond the declared args are still passed to C<run>.

=head2 command

	command name => 'Class::Name';

Registers a subcommand explicitly, there is no namespace scanning. The
class name is stored as a string and required lazily when dispatch or
help first needs it, so command classes cost nothing until used.

=head2 abstract

	abstract 'one line summary';

Shown in the parent's command listing and atop the class's own usage.

=head2 usage

	usage '[options] NAME...';

The argument summary portion of the C<Usage:> line. When not set it is
generated: C<[options]>, plus C<COMMAND> when subcommands exist, plus a
placeholder per declared arg.

=head2 name

	name 'greet';

The program name used in usage, version and error text. Only meaningful
on the root class; defaults to the basename of C<$0>.

=head2 extends

	extends 'Parent::Cmd';

Inheritance, passed through to L<Object::Proto/define>. Options inherit
with the class; the effective option set for parsing and help is the
class's own options first, then inherited ones.

=head2 run

Not a keyword, just a method:

	sub run {
		my ($self, @positionals) = @_;
		...
		return 0;
	}

Called on the constructed leaf object with the leftover positionals. Its
numeric return value becomes the exit code (undef counts as 0). A die
becomes exit code 1 with the message tidied and prefixed with the
program name. A class may have subcommands, a C<run> method, or both;
with both, an unmatched first token falls through to C<run> as a
positional.

=head1 OPTION PARAMETERS

From the Sugar C<has> vocabulary: C<is> (C<'ro'>), C<isa> (a type name
string, an imported type constant, or a coderef which is registered as an
anonymous type), C<coerce>, C<default> (plain scalar, C<[]>, C<{}>, or a
coderef installed as a generated builder), C<builder>, C<lazy>,
C<required>, C<trigger> (method name or coderef), C<predicate>,
C<clearer>, C<reader>, C<writer>, C<init_arg> / C<arg>, C<weak_ref> /
C<weak> and C<private>.

Plus the three command line keys:

=over 4

=item alias

A single string or an arrayref. One character aliases become short
options usable in bundles; longer aliases become alternative long
options.

=item doc

The description shown in generated help.

=item hidden

Accept the option but omit it from help.

=back

A C<Bool> option with no default gets C<default(0)> injected, an absent
flag must read false rather than undef. Anything not in the vocabulary
croaks at compile time. A required option is checked after parsing, so
the user sees C<missing required option '--x'> and exit code 2, never a
constructor error.

=head1 COMMAND LINE PARSING

The parser is self contained and GNU shaped:

=over 4

=item * C<--name value>, C<--name=value> and C<-n value>, C<-nvalue> all work.

=item * Short C<Bool> options bundle: C<-vfa>. The first value taking
short in a bundle consumes the rest of the token, or the next one.

=item * C<Bool> options take no value; C<--flag=x> is a usage error.
C<--no-flag> sets a C<Bool> false, unless an option literally named
C<no_flag> exists.

=item * C<ArrayRef> options repeat, each occurrence pushes. C<HashRef>
options take C<KEY=VALUE> and repeat.

=item * C<Int> and C<Num> values are validated before construction.

=item * C<--> ends option parsing; everything after is positional. A
lone C<-> and negative numbers are positional.

=item * Unknown options and missing values are usage errors. There is no
long option abbreviation.

=back

Options for a parent command must appear before its subcommand token:
C<greet -v hello> sets C<verbose> on the C<Greet::Cmd> object that the
leaf reads through C<cmd_parent>.

=head1 DISPATCH AND EXIT CODES

C<< Class->main(@ARGV) >> resolves subcommands left to right,
constructing each intermediate command object and handing it to the next
as C<cmd_parent>, then constructs the leaf and calls C<run>. C<BUILD> is
honoured as normal Object::Proto construction.

The exit code contract:

=over 4

=item * 0 - fine, including C<--help>, C<--version> and bare usage.

=item * 1 - the thing you asked about is wrong: C<run> died, or a
command class failed to load.

=item * 2 - the command was used wrongly: unknown command or option,
bad or missing value, missing required option, construction failure.

=back

C<-h> and C<--help> anywhere before C<--> print the resolved command's
usage to STDOUT and exit 0, even when required options are missing. A
C<help [command]> subcommand is provided automatically on classes with
subcommands. C<-v> and C<--version> print C<name version> from the root
class, standing down when a declared option claims the name.

=head1 GENERATED HELP

One generator feeds C<--help>, the C<help> subcommand and every misuse
path (misuse prints to STDERR, help to STDOUT):

	Usage: greet hello [options] NAME...

	say hello

	Options:
	  -g, --greeting VALUE   word to use (default: hello)
	  -s, --shout            uppercase the greeting

Placeholders come from the type (C<N> for C<Int>/C<Num>, C<KEY=VALUE>
for C<HashRef>, C<VALUE> otherwise, nothing for C<Bool>), with
C<(required)>, C<(repeatable)> and C<(default: x)> markers appended to
the description. Hidden options are omitted. An app level usage also
lists each subcommand with its abstract.

=head1 RESERVED NAMES

The framework reserves the attribute C<cmd_parent> (the constructed
parent command object, undef at the root), the class method C<main>
(installed unless the class defines its own) and the automatic C<help>
subcommand. C<-h>/C<--help> are always help; C<-v>/C<--version> are
version unless claimed by a declared option.

=head1 AUTHOR

LNATION <email@lnation.org>

=head1 BUGS

Please report any bugs or feature requests to C<bug-object-proto-cmd at rt.cpan.org>, or through
the web interface at L<https://rt.cpan.org/NoAuth/ReportBug.html?Queue=Object-Proto-Cmd>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

	perldoc Object::Proto::Cmd

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<https://rt.cpan.org/NoAuth/Bugs.html?Dist=Object-Proto-Cmd>

=item * Search CPAN

L<https://metacpan.org/release/Object-Proto-Cmd>

=back

=head1 SEE ALSO

L<Object::Proto>, L<Object::Proto::Sugar>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by LNATION <email@lnation.org>.

This is free software, licensed under:

	The Artistic License 2.0 (GPL Compatible)

=cut

1; # End of Object::Proto::Cmd
