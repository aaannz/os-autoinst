package autotest;
use strict;
use bmwqemu;

our %tests;     # scheduled or run tests
our @testorder; # for keeping them in order
our $running;   # currently running test or undef

sub loadtest($)
{
	my $script = shift;
	return unless $script =~ /.*\/(\w+)\.d\/\d+_(.+)\.pm$/;
	my $category=$1;
	my $name=$2;
	my $test;
	if (exists $tests{$name}) {
		$test = $tests{$name};
		return unless $test->is_applicable;
	} else {
		eval "package $name; require \$script;";
		if ($@) {
			my $msg = "error on $script: $@";
			diag($msg);
			die $msg;
		}
		$test=$name->new($category);
		$test->{script} = $script;
		$tests{$name} = $test;

		return unless $test->is_applicable;
		push @testorder, $test;
	}
	diag "scheduling $name $script";
}

sub runalltests {
	for my $t (@testorder) {
		$t->runtest;
	}
}

sub loadtestdir($) {
	my $dir = shift;
	foreach my $script (<$dir/*.pm>) {
		loadtest($script);
	}
}

sub results()
{
	my $results = [];
	for my $t (@testorder) {
		push @$results, $t->json();
	}
	return $results;
}

1;

# Local Variables:
# tab-width: 8
# cperl-indent-level: 8
# End:
