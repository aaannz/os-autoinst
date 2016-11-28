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

package testapi;
use 5.018;
use warnings;
use autodie qw(:all);
use Socket;

use parent qw/Exporter/;
use Exporter;

require autotest;
require myjsonrpc;

our $AUTOLOAD;
our @EXPORT = qw($realname $username $password $serialdev %cmd %vars

  get_var get_required_var check_var set_var get_var_array check_var_array autoinst_url

  send_key send_key_until_needlematch type_string type_password
  hold_key release_key

  assert_screen check_screen assert_and_dclick save_screenshot
  assert_and_click mouse_hide mouse_set mouse_click
  mouse_dclick mouse_tclick match_has_tag

  script_run script_sudo script_output validate_script_output
  assert_script_run assert_script_sudo

  wait_terminal assert_terminal

  start_audiocapture assert_recorded_sound

  select_console console reset_consoles

  upload_asset upload_image data_url assert_shutdown parse_junit_log
  upload_logs

  wait_idle wait_screen_change wait_still_screen wait_serial record_soft_failure
  become_root x11_start_program ensure_installed eject_cd power

  save_memory_dump save_storage_drives freeze_vm

  diag hashed_string
);
our @EXPORT_OK = qw(is_serial_terminal);

use subs qw(
  get_var get_required_var check_var set_var get_var_array check_var_array autoinst_url

  send_key send_key_until_needlematch type_string type_password
  hold_key release_key

  assert_screen check_screen assert_and_dclick save_screenshot
  assert_and_click mouse_hide mouse_set mouse_click
  mouse_dclick mouse_tclick match_has_tag

  script_run script_sudo script_output validate_script_output
  assert_script_run assert_script_sudo

  wait_terminal assert_terminal

  start_audiocapture assert_recorded_sound

  select_console console reset_consoles

  upload_asset upload_image data_url assert_shutdown parse_junit_log
  upload_logs

  wait_idle wait_screen_change wait_still_screen wait_serial record_soft_failure
  become_root x11_start_program ensure_installed eject_cd power

  save_memory_dump save_storage_drives freeze_vm

  diag hashed_string

  is_serial_terminal
);


our $testapi_server;

=head1 internal

=head2 init

Initialize connection to testapi server
=cut
sub init {
    return if $testapi_server;
    my $addr = pack_sockaddr_un($autotest::socketname);
    socket($testapi_server, PF_UNIX, SOCK_STREAM, 0);
    connect($testapi_server, $addr);
    $testapi_server->autoflush(1);
    my $token = myjsonrpc::send_json($testapi_server, {cmd => 'init'});
    myjsonrpc::read_json($testapi_server, $token);
}

sub DESTROY {
    close($testapi_server);
    undef $testapi_server;
}

=head2 AUTOLOAD

Automatically forward exported functions to OpenQA::testapi through socket
=cut
sub AUTOLOAD {
    my $cmd = $AUTOLOAD =~ s/.*:://r;
    die "Unknown testapi call \"$cmd\"" unless grep { $_ eq $cmd } @EXPORT;
    my $token = myjsonrpc::send_json($testapi_server, {cmd => $cmd, params => \@_});
    my $rsp = myjsonrpc::read_json($testapi_server, $token);
    return $rsp->{rsp};
}

=for stopwords ProhibitSubroutinePrototypes

=head2 set_distribution

    set_distribution($distri);

Set distribution object.

You can use distribution object to implement distribution specific helpers.

=cut

## no critic (ProhibitSubroutinePrototypes)
sub set_distribution {
    return OpenQA::testapi::set_distribution(@_);
}

=for stopwords SUT

=head2 wait_screen_change

  wait_screen_change { CODEREF [,$timeout] };

Wrapper around code that is supposed to change the screen.
This is the opposite to C<wait_still_screen>. Make sure to put the commands to change the screen
within the block to avoid races between the action and the screen change.

Example:

  wait_screen_change {
     send_key 'esc';
  };

Returns true if screen changed or C<undef> on timeout. Default timeout is 10s.

=cut
#TODO - redesing to call solely testapi::server
sub wait_screen_change(&@) {
    my ($callback, $timeout) = @_;
    $timeout ||= 10;

    bmwqemu::log_call(timeout => $timeout);

    # get the initial screen
    query_isotovideo('backend_set_reference_screenshot');
    $callback->() if $callback;

    my $starttime        = time;
    my $similarity_level = 50;

    while (time - $starttime < $timeout) {
        my $sim = query_isotovideo('backend_similiarity_to_reference')->{sim};
        print "waiting for screen change: " . (time - $starttime) . " $sim\n";
        if ($sim < $similarity_level) {
            bmwqemu::fctres("screen change seen at " . (time - $starttime));
            return 1;
        }
        sleep(0.5);
    }
    testapi::save_screenshot();
    bmwqemu::fctres("timed out");
    return 0;
}


=head2 validate_script_output

  validate_script_output($script, $code, [$wait])

Wrapper around script_output, that runs a callback on the output. Use it as

  validate_script_output "cat /etc/hosts", sub { m/127.*localhost/ }

=cut
sub validate_script_output($&;$) {
    my ($script, $code, $wait) = @_;
    $wait ||= 30;

    my $output = testapi::script_output($script, $wait);
    return unless $code;
    my $res = 'ok';

    # set $_ so the callbacks can be simpler code
    $_ = $output;
    if (!$code->()) {
        $res = 'fail';
        bmwqemu::diag("output does not pass the code block:\n$output");
    }
    # abusing the function
    $autotest::current_test->record_serialresult($output, $res, $output);
    if ($res eq 'fail') {
        die "output not validating";
    }
}

1;

# vim: set sw=4 et:
