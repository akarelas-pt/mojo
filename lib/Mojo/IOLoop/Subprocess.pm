package Mojo::IOLoop::Subprocess;
use Mojo::Base -base;

use Carp 'croak';
use Config;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use POSIX ();
use Storable;

has deserialize => sub { \&Storable::thaw };
has ioloop      => sub { Mojo::IOLoop->singleton };
has serialize   => sub { \&Storable::freeze };

sub pid { shift->{pid} }

sub run {
  my ($self, $child, $parent, $on_progress) = @_;

  # No fork emulation support
  croak 'Subprocesses do not support fork emulation' if $Config{d_pseudofork};

  # Pipe for subprocess communication
  pipe(my $reader, my $writer) or croak "Can't create pipe: $!";
  $writer->autoflush(1);

  $self->{secret} = do {srand; join '', map {('a'..'z')[rand 26]} (1..100)}
    if $on_progress;

  # Child
  croak "Can't fork: $!" unless defined(my $pid = $self->{pid} = fork);
  unless ($pid) {
    $self->ioloop->reset;
    $self->{writer} = $writer;
    my $results = eval { [$self->$child] } || [];
    print $writer $self->serialize->([$@, @$results]);
    POSIX::_exit(0);
  }

  # Parent
  my $me     = $$;
  my $stream = Mojo::IOLoop::Stream->new($reader)->timeout(0);
  $self->ioloop->stream($stream);
  my $buffer = '';
  $stream->on(read => sub {
    $buffer .= pop;
    while ($on_progress and $buffer =~ s/\A(.*?)\Q$self->{secret}\E//s) {
      my @data = @{ $self->deserialize->($1) };
      $on_progress->(@data);
    }
  });
  $stream->on(
    close => sub {
      return unless $$ == $me;
      waitpid $pid, 0;
      while ($on_progress and $buffer =~ s/\A(.*?)\Q$self->{secret}\E//s) {
        my @data = @{ $self->deserialize->($1) };
        $on_progress->(@data);
      }      
      my $results = eval { $self->deserialize->($buffer) } || [];
      $self->$parent(shift(@$results) // $@, @$results);
    }
  );
  return $self;
}

sub progress {
  my ($self, @data) = @_;
  my $writer = $self->{writer};
  print $writer $self->serialize->([@data]) . $self->{secret};
}

1;

=encoding utf8

=head1 NAME

Mojo::IOLoop::Subprocess - Subprocesses

=head1 SYNOPSIS

  use Mojo::IOLoop::Subprocess;

  # Operation that would block the event loop for 5 seconds
  my $subprocess = Mojo::IOLoop::Subprocess->new;
  $subprocess->run(
    sub {
      my $subprocess = shift;
      sleep 5;
      return '♥', 'Mojolicious';
    },
    sub {
      my ($subprocess, $err, @results) = @_;
      say "Subprocess error: $err" and return if $err;
      say "I $results[0] $results[1]!";
    }
  );

  # Start event loop if necessary
  $subprocess->ioloop->start unless $subprocess->ioloop->is_running;

=head1 DESCRIPTION

L<Mojo::IOLoop::Subprocess> allows L<Mojo::IOLoop> to perform computationally
expensive operations in subprocesses, without blocking the event loop.

=head1 ATTRIBUTES

L<Mojo::IOLoop::Subprocess> implements the following attributes.

=head2 deserialize

  my $cb      = $subprocess->deserialize;
  $subprocess = $subprocess->deserialize(sub {...});

A callback used to deserialize subprocess return values, defaults to using
L<Storable>.

  $subprocess->deserialize(sub {
    my $bytes = shift;
    return [];
  });

=head2 ioloop

  my $loop    = $subprocess->ioloop;
  $subprocess = $subprocess->ioloop(Mojo::IOLoop->new);

Event loop object to control, defaults to the global L<Mojo::IOLoop> singleton.

=head2 serialize

  my $cb      = $subprocess->serialize;
  $subprocess = $subprocess->serialize(sub {...});

A callback used to serialize subprocess return values, defaults to using
L<Storable>.

  $subprocess->serialize(sub {
    my $array = shift;
    return '';
  });

=head1 METHODS

L<Mojo::IOLoop::Subprocess> inherits all methods from L<Mojo::Base> and
implements the following new ones.

=head2 pid

  my $pid = $subprocess->pid;

Process id of the spawned subprocess if available.

=head2 run

  $subprocess = $subprocess->run(sub {...}, sub {...});

Execute the first callback in a child process and wait for it to return one or
more values, without blocking L</"ioloop"> in the parent process. Then execute
the second callback in the parent process with the results. The return values of
the first callback and exceptions thrown by it, will be serialized with
L<Storable>, so they can be shared between processes.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
