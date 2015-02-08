package Net::Server::ZMQ;

# ABSTRACT: Preforking ZeroMQ job server

use warnings;
use strict;
use base 'Net::Server::PreFork';
use constant READY => "\001";

use Carp;
use POSIX qw/WNOHANG/;
use Net::Server::SIG qw/register_sig check_sigs/;
use ZMQ::FFI;
use ZMQ::FFI::Constants qw/ZMQ_ROUTER ZMQ_REQ/;

our $VERSION = "1.000000";
$VERSION = eval $VERSION;

=head1 NAME

Net::Server::ZMQ - Preforking ZeroMQ job server

=head1 SYNOPSIS

	use Net::Server::ZMQ;

	Net::Server::ZMQ->run(
		port => [6660, 6661],	# [frontend port, backend port]
		min_servers => 5,
		max_servers => 10,
		app => sub {
			my $payload = shift;

			return uc($payload);
		}
	);

=head1 DESCRIPTION

C<Net::Server::ZMQ> is a L<Net::Server> personality based on L<Net::Server::PreFork>,
providing an easy way of creating a preforking ZeroMQ job server. It uses L<ZMQ::FFI>
for ZeroMQ integration, independent of the installed C<libzmq> version. You will need
to have C<libffi> installed.

This personality implements the "Extended Request-Reply" pattern described in the
L<ZeroMQ guide|http://zguide.zeromq.org/page:all>. It creates a C<ROUTER>/C<DEALER>
broker in the parent process, and one or more child processes as C<REP> workers.
C<REQ> clients can send requests to those workers through the broker, which balances
requests across the workers in a non-blocking way.

You get the full benefits of C<Net::Server::PreFork>, including the ability to increase
or decrease the number of workers by sending the C<TTIN> and C<TTOU> signals to the server,
respectively.

=head2 INTERNAL NOTES

ZeroMQ has some different concepts regarding sockets, and as such this class overrides
the binding done by C<Net::Server> so they do nothing (C<pre_bind()> and C<bind()> are
emptied). Also, since ZeroMQ never exposes client information to request handlers, it
is possible for C<Net::Server::ZMQ> to provide workers with data such as the IP address
of the client, and the C<get_client_info()> method is empties as well. Supplying client
information should therefore be done applicatively. The C<allow_deny()> method is also
overridden to always return true, for the same reason, though I'm not so certain yet
whether a better solution can be implemented.

=head2 CLIENT EXAMPLE

This is a simple client that sends a message to the server and prints out the response:

	use ZMQ::FFI;
	use ZMQ::FFI::Constants qw/ZMQ_REQ/;

	my $ctx = ZMQ::FFI->new;
	my $s = $ctx->socket(ZMQ_REQ);
	$s->connect('tcp://localhost:6660');

	$s->send('my name is nobody');

	print $s->recv, "\n";

=head1 OVERRIDDEN METHODS

=head2 pre_bind()

=head2 bind()

=head2 post_bind()

Emptied out

=cut

sub pre_bind { }

sub bind { }

sub post_bind { }

=head2 options()

Adds the custom C<app> option to C<Net::Server>. It takes the subroutine reference
that handles requests, i.e. the worker subroutine.

=cut

sub options {
	my $self = shift;
	my $ref  = $self->SUPER::options(@_);
	my $prop = $self->{server};

	$ref->{app} = \$prop->{app};

	return $ref;
}

=head2 post_configure()

Validates the C<app> option and provides a useless default (a worker
subroutine that simply echos back what the client sends).

=cut

sub post_configure {
	my $self = shift;
	my $prop = $self->{server};

	$self->SUPER::post_configure;

	$prop->{app} = sub { $_[0] }
		unless defined $prop->{app};

	$prop->{user} ||= $>;
	$prop->{group} ||= $);

	confess "app must be a subroutine reference"
		unless ref $prop->{app} && ref $prop->{app} eq 'CODE';

	confess "port must contain a frontend port and a backend port"
		unless ref $prop->{port} && ref $prop->{port} eq 'ARRAY' && scalar @{$prop->{port}} >= 2;
}

=head2 run_parent()

Creates the broker process, binding a C<ROUTER> on the frontend port
(facing clients), and C<DEALER> on the backend port (facing workers).

It then creates a C<QUEUE> proxy between the two ports.

The parent process will receive the proctitle "zmq broker <fport>-<bport>",
where "<fport> is the frontend port and "<bport>" is the backend port.

=cut

sub run_parent {
	my $self = shift;
	my $prop = $self->{server};

	# This method is almost entirely copied from Net::Server::PreFork,
	# which isn't a good thing, but necessary due to the usage of ZeroMQ
	# sockets. The main difference is polling for events on the frontend
	# and backend ports, and running the child-reading code only when
	# backends are talking

	my $read_fh = $prop->{'_READ'};
 
	@{ $prop }{qw(last_checked_for_dead last_checked_for_waiting last_checked_for_dequeue last_process last_kill)} = (time) x 5;

	register_sig(
		PIPE => 'IGNORE',
		INT  => sub { $self->server_close },
		TERM => sub { $self->server_close },
		HUP  => sub { $self->sig_hup },
		CHLD => sub {
			while (defined(my $chld = waitpid(-1, WNOHANG))) {
				last unless $chld > 0;
				$self->{reaped_children}->{$chld} = 1;
			}
		},
		QUIT => sub { $self->{server}->{kind_quit} = 1; $self->server_close() },
		TTIN => sub { $self->{server}->{$_}++ for qw(min_servers max_servers); $self->log(3, "Increasing server count ($self->{server}->{max_servers})") },
		TTOU => sub { $self->{server}->{$_}-- for qw(min_servers max_servers); $self->log(3, "Decreasing server count ($self->{server}->{max_servers})") },
	); 

	$self->register_sig_pass;

	if ($ENV{'HUP_CHILDREN'}) {
		while (defined(my $chld = waitpid(-1, WNOHANG))) {
			last unless $chld > 0;
			$self->{reaped_children}->{$chld} = 1;
		}
	}

	my $fport = $prop->{port}->[0];
	my $bport = $prop->{port}->[1];

	$0 = "zmq broker $fport-$bport";

	my $ctx = ZMQ::FFI->new;

	my $f = $ctx->socket(ZMQ_ROUTER);
	$f->set_linger(0);
	$f->bind('tcp://*:'.$fport);

	my $b = $ctx->socket(ZMQ_ROUTER);
	$b->set_linger(0);
	$b->bind('tcp://*:'.$bport);

	my (@workers, $w_addr, $delim, $c_addr, $data);
	while (1) {
		check_sigs();

		$self->idle_loop_hook;

		# poll on the frontend or the backend, but only poll
		# on the frontend if there are workers
		if (scalar @workers && $f->has_pollin) {
			my @msg = $f->recv_multipart;
			$b->send_multipart([ pop(@workers), '', $msg[0], '', $msg[2] ]);
		} elsif ($b->has_pollin) {
			my @fh = $prop->{'child_select'}->can_read($prop->{'check_for_waiting'});

			$self->idle_loop_hook(\@fh);

			foreach my $fh (@fh) {
				if ($fh != $read_fh) { # preforking server data
					$self->child_is_talking_hook($fh);
					next;
				}

				my $line = <$fh>;
				next if ! defined $line;

				last if $self->parent_read_hook($line); # optional test by user hook

				# child should say "$pid status\n"
				next if $line !~ /^(\d+)\ +(waiting|processing|dequeue|exiting)$/;
				my ($pid, $status) = ($1, $2);

				if (my $child = $prop->{'children'}->{$pid}) {
					if ($status eq 'exiting') {
						$self->delete_child($pid);
					} else {
						# Decrement tally of state pid was in (plus sanity check)
						my $old_status = $child->{'status'}    || $self->log(2, "No status for $pid when changing to $status");
						--$prop->{'tally'}->{$old_status} >= 0 || $self->log(2, "Tally for $status < 0 changing pid $pid from $old_status to $status");

						$child->{'status'} = $status;
						++$prop->{'tally'}->{$status};

						$prop->{'last_process'} = time() if $status eq 'processing';
					}
				}
			}

			my @msg = $b->recv_multipart;

			$w_addr = $msg[0];
			push(@workers, $w_addr);

			$delim = $msg[1];
			$c_addr = $msg[2];

			if ($c_addr ne READY) {
				$delim = $msg[3];

				$data = $msg[4];

				$self->log(4, "$w_addr sending to $c_addr: $data");

				$f->send_multipart([ $c_addr, '', $data ]);
			} else {
				$self->log(3, "$w_addr checking in");
			}

			$self->coordinate_children();
		}

		#select undef, undef, undef, 0.025;
	}
}

=head2 child_init_hook()

This hook binds a C<REP> socket on the backend port, through which
workers communicate with the broker. Every child process receives the
proctitle "zmq worker <bport>", where "<bport>" is the backend port.

=cut

sub child_init_hook {
	my $self = shift;
	my $prop = $self->{server};

	my $port = $prop->{port}->[1];

	$0 = "zmq worker $port";

	my $ctx = ZMQ::FFI->new;
	my $s = $ctx->socket(ZMQ_REQ);
	$s->set_identity("child_$$");
	$s->set_linger(0);

	$s->connect("tcp://localhost:$port");

	$s->send(READY);

	$prop->{sock} = [$s];
	$prop->{context} = $ctx;
}

=head2 accept()

Waits for new messages from clients. When a message is received, it
is stored as the "payload" attribute, with the socket stored as the
"client" attribute.

=cut

sub accept {
	my $self = shift;
	my $prop = $self->{server};

	my $sock = $prop->{sock}->[0];

	$self->fatal("Received a bad sock!")
		unless defined $sock;

	while (1) {
		next unless $sock->has_pollin;

		my @msg = $sock->recv_multipart;

		$self->log(4, $sock->get_identity." got: $msg[2]");

		$prop->{client}	= $sock;
		$prop->{peername}	= $msg[0];
		$prop->{payload}	= $msg[2];

		return 1;
	}
}

=head2 post_accept()

=head2 get_client_info()

Emptied out

=cut

sub post_accept { }

sub get_client_info { }

=head2 allow_deny()

Simply returns a true value

=cut

sub allow_deny { 1 }

=head2 process_request()

Calls the C<app> (i.e. worker subroutine) with the payload from the
client, and sends the result back to the client.

=cut

sub process_request {
	my $self = shift;
	my $prop = $self->{server};

	$prop->{client}->send_multipart([
		$prop->{peername},
		'',
		$prop->{app}->($prop->{payload})
	]);
}

=head2 post_process_request()

Removes the C<client> attribute (holding the C<REP> socket) at the end
of the request.

=cut

sub post_process_request { delete $_[0]->{server}->{client} }

=head2 sig_hup()

Overridden to simply send C<SIGHUP> to the children (to restart them),
and that's it

=cut

sub sig_hup {
	my $self = shift;
	$self->log(2, "Received a SIG HUP");
	$self->hup_children;
}

=head2 shutdown_sockets()

Closes the ZeroMQ sockets

=cut

sub shutdown_sockets {
	my $self = shift;
	my $prop = $self->{server};

	foreach (@{$prop->{sock}}) {
		$_->close;
	}

	$prop->{sock} = [];
}

=head2 child_finish_hook()

Closes the children's socket and destroys the context (this is
necessary, otherwise we'll have zombies).

=cut

sub child_finish_hook {
	my $self = shift;
	my $prop = $self->{server};

	eval {
		$prop->{sock}->[0]->close;
		$prop->{context}->destroy;
	};
}

=head1 CONFIGURATION AND ENVIRONMENT
  
Read L<Net::Server> for more information about configuration.

=head1 DEPENDENCIES

C<Net::Server::ZMQ> depends on the following CPAN modules:

=over

=item * L<Carp>

=item * L<Net::Server::PreFork>

=item * L<ZMQ::FFI>

=back

=head1 BUGS AND LIMITATIONS

Please report any bugs or feature requests to
C<bug-Net-Server-ZMQ@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Net-Server-ZMQ>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

	perldoc Net::Server::ZMQ

You can also look for information at:

=over 4
 
=item * RT: CPAN's request tracker
 
L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Net-Server-ZMQ>
 
=item * AnnoCPAN: Annotated CPAN documentation
 
L<http://annocpan.org/dist/Net-Server-ZMQ>
 
=item * CPAN Ratings
 
L<http://cpanratings.perl.org/d/Net-Server-ZMQ>
 
=item * Search CPAN
 
L<http://search.cpan.org/dist/Net-Server-ZMQ/>
 
=back
 
=head1 AUTHOR
 
Ido Perlmuter <ido@ido50.net>

=head1 ACKNOWLEDGMENTS

In writing this module I relied heavily on L<Starman> by Tatsuhiko Miyagawa.
 
=head1 LICENSE AND COPYRIGHT
 
Copyright (c) 2015, Ido Perlmuter C<< ido@ido50.net >>.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself, either version
5.8.1 or any later version. See L<perlartistic|perlartistic>
and L<perlgpl|perlgpl>.
 
The full text of the license can be found in the
LICENSE file included with this module.
 
=head1 DISCLAIMER OF WARRANTY
 
BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.
 
IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.

=cut

1;
__END__
