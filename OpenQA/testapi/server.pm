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
use POSIX qw(_exit);
use Socket;
use autodie qw(:all);
use Exporter qw/import/;
our @EXPORT_OK = qw/query_isotovideo/;

use OpenQA::testapi;
require myjsonrpc;

use Data::Dump qw/pp/;

our $isotovideo;
our $socketname = '/var/run/openqa-testapi';
our $socket;



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



    mainloop;
}
1;

# vim: set sw=4 et:

