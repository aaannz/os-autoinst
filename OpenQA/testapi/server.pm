# Copyright © 2016 SUSE LLC
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

package OpenQA::testapi::server;
use strict;
use warnings;
use autodie qw(:all);
use OpenQA::testapi;
require myjsonrpc;

our $isotovideo;
our $socketname = 'testapi';
our $socket;

my %testapi_dispatch = ();

sub init {
    for my $sub ( keys %OpenQA::testapi ) {
        if (OpenQA::testapi->can($sub)) {
            $testapi_dispatch{$sub} = &{"OpenQA::testapi::$sub"};
        }
    }
}

sub start_process {
    my $child;

    # this is for testapi <-> isotovideo comm
    socketpair($child, $isotovideo, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
      or die "socketpair: $!";

    $child->autoflush(1);
    $isotovideo->autoflush(1);

    my $testapipid = fork();
    if ($testapipid) {
        close $isotovideo;
        return ($testapipid, $child);
    }

    die "cannot fork: $!" unless defined $testapipid;
    close $child;

    $SIG{TERM} = 'DEFAULT';
    $SIG{INT}  = 'DEFAULT';
    $SIG{HUP}  = 'DEFAULT';
    $SIG{CHLD} = 'DEFAULT';

    $0 = "$0: testapi";

    # open testapi socket for incomming tasks
    # this is for autotest executed test script <-> testapi comm
    my $addr = sockaddr_un($socketname);
    socket($socket, PF_UNIX, SOCK_STREAM, 0);
    unlink($socketname);
    bind($socket, $addr);
    # listen for max 1 connection at a time - from os-autoinst::autotest, possible from openQA::Worker needs first one to close
    # TODO allow concurency?
    listen($socket, 1);

    my $line = <$isotovideo>;
    if (!$line) {
        _exit(0);
    }
    print "TestAPI: GOT $line\n";
    mainloop;
}

sub mainloop {
    # we should use some well known socket for us
    while(accept(my $test, $socket)) {
        while(my $rsp = myjsonrpc::read_json($test)) {
            my $cmd = $rsp->{command};
            my @params = $rsp->{params};
            if ($testapi_dispatch{$cmd}) {
                $testapi_dispatch{$cmd}->(@params);
            }
            else {
                die "Unknown command $rsp->{cmd}";
            }
        }
    }
}

1;

# vim: set sw=4 et:

