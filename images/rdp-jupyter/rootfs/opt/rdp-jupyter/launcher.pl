#!/usr/bin/perl
# Attached mode: start a program for whoever asks, as that account.
#   launcher.pl <socket path> <program> [args...]
# Another container of the same pod (the desktop) connects to the unix socket
# and sends one line, the X display to draw on (":10"). The kernel tells us
# which account connected (SO_PEERCRED), so the request carries no name, no
# password and no key. The program then runs as that account with DISPLAY and
# XAUTHORITY set. Reply: "OK", or "ERR <reason>" when nothing was started.
use strict;
use warnings;
use IO::Socket::UNIX;
use Socket qw(SOL_SOCKET SOCK_STREAM);
use POSIX ();

use constant SO_PEERCRED => 17;
use constant MIN_UID     => 1000;

my ($path, @program) = @ARGV;
die "usage: launcher.pl <socket path> <program> [args...]\n" unless defined $path && @program;

sub note { print STDERR "[launcher] @_\n" }

unlink $path;
my $server = IO::Socket::UNIX->new(Type => SOCK_STREAM, Local => $path, Listen => 16)
  or die "[launcher] cannot listen on $path: $!\n";
# Every account in the pod may ask; what they get is decided by who they are
chmod 0666, $path or die "[launcher] chmod $path: $!\n";
$SIG{CHLD} = 'IGNORE';
note "listening on $path for @program";

while (my $client = $server->accept) {
  # One child per request, so a client that never sends its line blocks nobody
  my $pid = fork();
  if (!defined $pid) { note "fork: $!"; close $client; next }
  if ($pid == 0) { close $server; serve($client); POSIX::_exit(0) }
  close $client;
}

sub refuse {
  my ($client, $why) = @_;
  note "refused: $why";
  print $client "ERR $why\n";
  close $client;
  POSIX::_exit(0);
}

sub serve {
  my ($client) = @_;
  # The accept loop ignores SIGCHLD so finished requests are reaped for it.
  # The program must not inherit that: its own waitpid() calls would fail
  # (dbus-launch: "Failed to waitpid() for babysitter intermediate process").
  $SIG{CHLD} = 'DEFAULT';
  my $cred = getsockopt($client, SOL_SOCKET, SO_PEERCRED) or refuse($client, "no peer credentials");
  my (undef, $uid) = unpack('iii', $cred);

  my $line = eval {
    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm 5;
    my $l = <$client>;
    alarm 0;
    $l;
  };
  refuse($client, "no request") unless defined $line;
  chomp $line;
  refuse($client, "bad display") unless $line =~ /\A:(\d{1,4})\z/;
  my $display = $line;

  my ($user, undef, undef, $gid, undef, undef, undef, $home) = getpwuid($uid);
  refuse($client, "unknown account (uid $uid)") unless defined $user && $uid >= MIN_UID && -d $home;

  # Become the account before touching anything it owns
  $) = "$gid $gid";
  $( = $gid;
  POSIX::setuid($uid);
  refuse($client, "cannot switch to $user") unless $< == $uid && $> == $uid && $( + 0 == $gid;

  %ENV = (
    HOME => $home, USER => $user, LOGNAME => $user, SHELL => '/bin/bash',
    PATH => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
    DISPLAY => $display, XAUTHORITY => "$home/.Xauthority",
  );
  chdir $home or refuse($client, "cannot enter $home");

  # Without the display's cookie the program would only start and die
  my $cookie = `xauth -f "\$XAUTHORITY" list "\$DISPLAY" 2>/dev/null`;
  refuse($client, "$user has no access to display $display") unless $cookie =~ /\S/;

  note "$user: starting on $display";
  print $client "OK\n";
  close $client;

  POSIX::setsid();
  open STDIN, '<', '/dev/null';
  exec { $program[0] } @program or note "exec $program[0]: $!";
  POSIX::_exit(127);
}
