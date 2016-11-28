# Copyright © 2009-2013 Bernhard M. Wiedemann
# Copyright © 2012-2016 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package autotest;
use 5.018;
use warnings;

use Data::Dump qw/pp/;
use File::Basename;
use File::Spec;
use IO::Handle;
use POSIX qw(_exit);
use Socket;
use Carp qw(confess);

use Exporter qw(import);
our @EXPORT_OK = qw(loadtest $current_test query_isotovideo);

use bmwqemu;
use cv;
require myjsonrpc;
require OpenQA::testapi;
require testapi;

our %tests;        # scheduled or run tests
our @testorder;    # for keeping them in order
our $isotovideo;

sub query_isotovideo {
    my ($cmd, $args) = @_;

    # deep copy
    my %json;
    if ($args) {
        %json = %$args;
    }
    $json{cmd} = $cmd;

    my $token = myjsonrpc::send_json($isotovideo, \%json);
    my $rsp = myjsonrpc::read_json($isotovideo, $token);
    return $rsp->{ret};
}

# UNIX socket for testapi interface
our $socketname = '/var/run/openqa-testapi';
our $socket;

my %testapi_dispatch = ();

our $current_test;
our $last_milestone;

sub set_current_test {
    ($current_test) = @_;
    query_isotovideo('set_current_test', {name => ref($current_test)});
}

sub make_snapshot {
    my ($sname) = @_;
    bmwqemu::diag("Creating a VM snapshot $sname");
    return query_isotovideo('backend_save_snapshot', {name => $sname});
}

sub load_snapshot {
    my ($sname) = @_;
    bmwqemu::diag("Loading a VM snapshot $sname");
    return query_isotovideo('backend_load_snapshot', {name => $sname});
}

sub run_all {
    my $died      = 0;
    my $completed = 0;
    eval { $completed = autotest::runalltests(); };
    if ($@) {
        warn $@;
        $died = 1;    # test execution died
    }
    bmwqemu::save_vars();
    myjsonrpc::send_json($isotovideo, {cmd => 'tests_done', died => $died, completed => $completed});
    close $isotovideo;
    _exit(0);
}

sub run_loader {

    my $pid = fork();
    if ($pid) {
        return $pid;
    }
    die "cannot fork: $!" unless defined $pid;
    $SIG{TERM} = 'DEFAULT';
    $SIG{INT}  = 'DEFAULT';
    $SIG{HUP}  = 'DEFAULT';
    $SIG{CHLD} = 'DEFAULT';

    testapi::init();
    # add lib of the test distributions - but only for main.pm not to pollute
    # further dependencies (the tests get it through autotest)
    my @oldINC = @INC;
    unshift @INC, $bmwqemu::vars{CASEDIR} . '/lib';
    require $bmwqemu::vars{PRODUCTDIR} . "/main.pm";
    @INC = @oldINC;
    # set a default distribution if the tests don't have one
    $testapi::distri ||= distribution->new;

    bmwqemu::save_vars;
    myjsonrpc::send_json($isotovideo, {cmd => 'loader_done'});
    exit 0;
}

sub run_test {
    my ($t, $snapshots_supported) = @_;

    my $flags    = $t->test_flags();
    my $fullname = $t->{fullname};
    my $testpid  = fork();
    if ($testpid) {
        return $testpid;
    }

    die "cannot fork: $!" unless defined $testpid;

    $SIG{TERM} = 'DEFAULT';
    $SIG{INT}  = 'DEFAULT';
    $SIG{HUP}  = 'DEFAULT';
    $SIG{CHLD} = 'DEFAULT';

    my $name = ref($t);
    bmwqemu::modstart "starting $name $t->{script}";
    testapi::init();
    $t->start();

    # avoid erasing the good vm snapshot
    if ($snapshots_supported && (($bmwqemu::vars{SKIPTO} || '') ne $fullname) && $bmwqemu::vars{MAKETESTSNAPSHOTS}) {
        make_snapshot($t->{fullname});
    }

    eval { $t->runtest; };
    $t->save_test_result();

    my $continue = 1;
    if ($@) {
        my $msg = $@;
        if ($msg !~ /^test.*died/) {
            # avoid duplicating the message
            bmwqemu::diag $msg;
        }
        if ($flags->{fatal} || !$snapshots_supported || $bmwqemu::vars{TESTDEBUG}) {
            bmwqemu::stop_vm();
            $continue = 0;
        }
        elsif (!$flags->{norollback}) {
            if ($last_milestone) {
                load_snapshot('lastgood');
                $last_milestone->rollback_activated_consoles();
            }
        }
    }
    else {
        if ($snapshots_supported && ($flags->{milestone} || $bmwqemu::vars{TESTDEBUG})) {
            make_snapshot('lastgood');
            $last_milestone = $t;
        }
    }

    my $autotest;
    my $addr = pack_sockaddr_un($autotest::socketname);
    socket($autotest, PF_UNIX, SOCK_STREAM, 0);
    connect($autotest, $addr);

    $continue = $continue ? 'NEXT_TEST' : 'DONE';
    my $token = myjsonrpc::send_json($autotest, {cmd => $continue});
    close($autotest);
}

sub start_process {
    my $child;

    socketpair($child, $isotovideo, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
      or die "socketpair: $!";

    $child->autoflush(1);
    $isotovideo->autoflush(1);

    my $autotestpid = fork();
    if ($autotestpid) {
        close $isotovideo;
        return ($autotestpid, $child);
    }

    die "cannot fork: $!" unless defined $autotestpid;
    close $child;

    $SIG{TERM} = 'DEFAULT';
    $SIG{INT}  = 'DEFAULT';
    $SIG{HUP}  = 'DEFAULT';
    $SIG{CHLD} = 'DEFAULT';

    $0 = "$0: autotest";

    # build dispatch table from all available functions from testapi
    {
        no strict qw/refs/;
        for my $sub (keys %{OpenQA::testapi::}) {
            if (OpenQA::testapi->can($sub)) {
                $testapi_dispatch{$sub} = \&{"OpenQA::testapi::$sub"};
            }
        }
    }

    # open testapi socket for incomming tasks
    # this is for autotest executed test script <-> testapi comm
    unlink($socketname) if -e $socketname;
    my $addr = pack_sockaddr_un($socketname);
    socket($socket, PF_UNIX, SOCK_STREAM, 0);
    bind($socket, $addr);
    # listen for max 3 connection at a time - from os-autoinst::autotest, os-autoinst::testapi and possible from openQA::Worker
    listen($socket, 3);

    my $s = IO::Select->new();
    $s->add($isotovideo);
    $s->add($socket);

    my $testpid;
    while (1) {
        my @ready = $s->can_read();
        for my $r (@ready) {
            # accept new connection if can read from $socket
            if ($r == $socket) {
                accept(my $test, $socket);
                $test->autoflush(1);
                $s->add($test);
                next;
            }

            # or read from the socket
            my $rsp    = myjsonrpc::read_json($r);
            unless ($rsp) {
                bmwqemu::diag 'failed reading socket - autotest abort';
                last;
            }
            my $cmd    = $rsp->{cmd};
            my $params = $rsp->{params} // [];
            print "dispatching $cmd ";
            pp $params;
            if ($testapi_dispatch{$cmd}) {
                my $ret = $testapi_dispatch{$cmd}->(@$params);
                print "response ";
                pp $ret;
                myjsonrpc::send_json($r, {rsp => $ret, json_cmd_token => $rsp->{json_cmd_token}});
            }
            elsif ($cmd eq 'DONE') {
                bmwqemu::diag 'exiting testapi mainloop';
                last;
            }
            elsif ($cmd eq 'INIT_TESTLOADER') {
                bmwqemu::load_vars();
                my $pid = run_loader();
                myjsonrpc::send_json($isotovideo, {rsp => $pid});
            }
            elsif ($cmd eq 'GO') {
                # the backend process might have added some defaults for the backend
                bmwqemu::load_vars();

                cv::init;
                require tinycv;

                # write test order
                die "ERROR: no tests loaded" unless @testorder;
                my @result;
                for my $t (@testorder) {
                    push(
                        @result,
                        {
                            name     => ref($t),
                            category => $t->{category},
                            flags    => $t->test_flags(),
                            script   => $t->{script}});
                }
                bmwqemu::save_json_file(\@result, bmwqemu::result_dir . "/test_order.json");

                my $firsttest = $bmwqemu::vars{SKIPTO} || $testorder[0]->{fullname};
                my $snapshots_supported = query_isotovideo('backend_can_handle', {function => 'snapshots'});
                bmwqemu::diag "Snapshots are " . ($snapshots_supported ? '' : 'not ') . "supported";

                my $t;
                while ($t = shift @testorder) {
                    my $fullname = $t->{fullname};
                    if ($fullname eq $firsttest) {
                        if ($bmwqemu::vars{SKIPTO}) {
                            if ($bmwqemu::vars{TESTDEBUG}) {
                                load_snapshot('lastgood');
                            }
                            else {
                                load_snapshot($firsttest);
                            }
                        }
                        unshift @testorder, $t;
                        last;
                    }

                    bmwqemu::diag "skipping $fullname";
                    $t->skip_if_not_running();
                    $t->save_test_result();
                }
                $testpid = run_test($t);
            }
            elsif ($cmd eq 'NEXT_TEST') {
                # wait until currently running test if finished
                waitpid $testpid, 0 if ($testpid);
                my $t = shift @testorder;
                if ($t) {
                    $testpid = run_test($t);
                }
                else {
                    bmwqemu::diag 'no test remains';
                    last;
                }
            }
            else {
                confess "Unknown command $cmd";
            }
        }
    }

    close $_ for ($s->handles);
}

# TODO: define use case and reintegrate
sub prestart_hook {
    # run prestart test code before VM is started
    if (-f "$bmwqemu::vars{CASEDIR}/prestart.pm") {
        bmwqemu::diag "running prestart step";
        eval { require $bmwqemu::vars{CASEDIR} . "/prestart.pm"; };
        if ($@) {
            bmwqemu::diag "prestart step FAIL:";
            die $@;
        }
    }
}

# TODO: define use case and reintegrate
sub postrun_hook {
    # run postrun test code after VM is stopped
    if (-f "$bmwqemu::vars{CASEDIR}/postrun.pm") {
        bmwqemu::diag "running postrun step";
        eval { require "$bmwqemu::vars{CASEDIR}/postrun.pm"; };    ## no critic
        if ($@) {
            bmwqemu::diag "postrun step FAIL:";
            warn $@;
        }
    }
}

sub loadtest {
    my ($script) = @_;
    my $casedir = $bmwqemu::vars{CASEDIR};

    unless (-f join('/', $casedir, $script)) {
        warn "loadtest needs a script below $casedir - $script is not\n";
        $script = File::Spec->abs2rel($script, $bmwqemu::vars{CASEDIR});
    }
    unless ($script =~ m,(\w+)/([^/]+)\.pm$,) {
        die "loadtest needs a script to match \\w+/[^/]+.pm\n";
    }
    my $category = $1;
    my $name     = $2;
    my $test;
    my $fullname = "$category-$name";
    # perl code generating perl code is overcool
    # FIXME turn this into a proper eval instead of a generated string
    my $code = "package $name;";
    $code .= "use lib '$casedir/lib';";
    my $basename = dirname($script);
    $code .= "use lib '$casedir/$basename';";
    $code .= "require '$casedir/$script';";
    eval $code;    ## no critic
    if ($@) {
        my $msg = "error on $script: $@";
        bmwqemu::diag($msg);
        die $msg;
    }
    $test             = $name->new($category);
    $test->{script}   = $script;
    $test->{fullname} = $fullname;
    my $nr = '';
    while (exists $tests{$fullname . $nr}) {
        # to all perl hardcore hackers: fuck off!
        $nr = $nr eq '' ? 1 : $nr + 1;
        bmwqemu::diag($fullname . ' already scheduled');
    }
    $tests{$fullname . $nr} = $test;

    return unless $test->is_applicable;
    push @testorder, $test;
    bmwqemu::diag("scheduling $name$nr $script");
}

1;

# vim: set sw=4 et:
