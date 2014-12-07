package Sub::Throttler::Periodic::EV;

use warnings;
use strict;
use utf8;
use feature ':5.10';
use Carp;
our @CARP_NOT = qw( Sub::Throttler );

use version; our $VERSION = qv('0.2.0');    # REMINDER: update Changes

# REMINDER: update dependencies in Build.PL
use parent qw( Sub::Throttler::Limit );
use Sub::Throttler qw( throttle_flush );
use Time::HiRes qw( time sleep );
use Scalar::Util qw( weaken );
use EV;


sub new {
    use warnings FATAL => qw( misc );
    my ($class, %opt) = @_;
    my $self = bless {
        limit   => delete $opt{limit} // 1,
        period  => delete $opt{period} // 1,
        acquired=> {},  # { $id => { $key => $quantity, … }, … }
        used    => {},  # { $key => $quantity, … }
        }, ref $class || $class;
    croak 'limit must be an unsigned integer' if $self->{limit} !~ /\A\d+\z/ms;
    croak 'period must be a positive number' if $self->{period} <= 0;
    croak 'bad param: '.(keys %opt)[0] if keys %opt;
    weaken(my $this = $self);
    $self->{_t} = EV::periodic 0, $self->{period}, 0, sub { $this && $this->_tick() };
    $self->{_t}->keepalive(0);
    return $self;
}

sub acquire {
    my ($self, $id, $key, $quantity) = @_;
    if (!$self->try_acquire($id, $key, $quantity)) {
        if ($quantity <= $self->{limit} && $self->{used}{$key}) {
            my $time = time;
            my $delay = int($time/$self->{period})*$self->{period} + $self->{period} - $time;
            sleep $delay;
            $self->_tick();
        }
        if (!$self->try_acquire($id, $key, $quantity)) {
            croak "$self: unable to acquire $quantity of resource '$key'";
        }
    }
    return $self;
}

sub load {
    my ($class, $state) = @_;
    croak 'bad state: wrong algorithm' if $state->{algo} ne __PACKAGE__;
    my $v = version->parse($state->{version});
    if ($v > $VERSION) {
        carp 'restoring state saved by future version';
    }
    my $self = $class->new(limit=>$state->{limit}, period=>$state->{period});
    # time jump backward, no matter how much, handled like we still is in
    # current period, to be safe
    if (int($state->{at}/$self->{period})*$self->{period} + $self->{period} > time) {
        $self->{used} = $state->{used};
    }
    if (keys %{ $self->{used} }) {
        $self->{_t}->keepalive(1);
    }
    return $self;
}

sub period {
    my ($self, $period) = @_;
    if (1 == @_) {
        return $self->{period};
    }
    croak 'period must be a positive number' if $period <= 0;
    $self->{period} = $period;
    $self->{_t}->set(0, $self->{period}, 0);
    return $self;
}

sub release {
    my ($self, $id) = @_;
    croak sprintf '%s not acquired anything', $id if !$self->{acquired}{$id};
    delete $self->{acquired}{$id};
    return $self;
}

sub release_unused {
    my $self = shift->SUPER::release_unused(@_);
    if (!keys %{ $self->{used} }) {
        $self->{_t}->keepalive(0);
    }
    return $self;
}

sub save {
    my ($self) = @_;
    my $state = {
        algo    => __PACKAGE__,
        version => $VERSION->numify,
        limit   => $self->{limit},
        period  => $self->{period},
        used    => $self->{used},
        at      => time,
    };
    return $state;
}

sub try_acquire {
    my $self = shift;
    if ($self->SUPER::try_acquire(@_)) {
        $self->{_t}->keepalive(1);
        return 1;
    }
    return;
}

sub _tick {
    my $self = shift;
    for my $id (keys %{ $self->{acquired} }) {
        for my $key (keys %{ $self->{acquired}{$id} }) {
            $self->{acquired}{$id}{$key} = 0;
        }
    }
    # OPTIMIZATION call throttle_flush() only if amount of available
    # resources increased (i.e. if some sources was released)
    if (keys %{ $self->{used} }) {
        $self->{used} = {};
        throttle_flush();
    }
    if (!keys %{ $self->{used} }) {
        $self->{_t}->keepalive(0);
    }
    return;
}


1; # Magic true value required at end of module
__END__

=encoding utf8

=head1 NAME

Sub::Throttler::Periodic::EV - throttle by rate (quantity per time)


=head1 SYNOPSIS

    use Sub::Throttler::Periodic::EV;
    
    # default limit=1, period=1
    my $throttle = Sub::Throttler::Periodic::EV->new(period => 0.1, limit => 42);
    
    my $limit = $throttle->limit;
    $throttle->limit(42);
    my $period = $throttle->period;
    $throttle->period(0.1);
    
    # --- Activate throttle for selected subrouties
    $throttle->apply_to_functions('Some::func', 'Other::func2', …);
    $throttle->apply_to_methods('Class', 'method', 'method2', …);
    $throttle->apply_to_methods($object, 'method', 'method2', …);
    $throttle->apply_to(sub {
      my ($this, $name, @params) = @_;
      ...
      return;   # OR
      return { key1=>$quantity1, ... };
    });
    
    # --- Manual resource management
    if ($throttle->try_acquire($id, $key, $quantity)) {
        ...
        $throttle->release($id);
        $throttle->release_unused($id);
    }


=head1 DESCRIPTION

This is a plugin for L<Sub::Throttler> providing simple algorithm for
throttling by rate (quantity per time) of used resources.

This algorithm works like L<Sub::Throttler::Limit> with one difference:
when current time is divisible by given period value all used resources
will be made available for acquiring again.

It uses EV::timer, but will avoid keeping your event loop running when it
doesn't needed anymore (if there are no acquired resources).


=head1 EXPORTS

Nothing.


=head1 INTERFACE

L<Sub::Throttler::Periodic::EV> inherits all methods from L<Sub::Throttler::algo>
and implements the following ones.

=over

=item new

    my $throttle = Sub::Throttler::Periodic::EV->new;
    my $throttle = Sub::Throttler::Periodic::EV->new(period => 0.1, limit => 42);

Create and return new instance of this algorithm.

Default C<period> is C<1.0>, C<limit> is C<1>.

See L<Sub::Throttler::algo/"new"> for more details.

=item period

    my $period = $throttle->period;
    $throttle  = $throttle->period($period);

Get or modify current C<period>.

=item limit

    my $limit = $throttle->limit;
    $throttle = $throttle->limit(42);

Get or modify current C<limit>.

=item load

    my $throttle = Sub::Throttler::Periodic::EV->load($state);

Create and return new instance of this algorithm.

See L<Sub::Throttler::algo/"load"> for more details.

=item save

    my $state = $throttle->save();

Return current state of algorithm needed to restore it using L</"load">
after application restart.

See L<Sub::Throttler::algo/"save"> for more details.

=back


=head1 BUGS AND LIMITATIONS

No bugs have been reported.


=head1 SUPPORT

Please report any bugs or feature requests through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Sub-Throttler>.
I will be notified, and then you'll automatically be notified of progress
on your bug as I make changes.

You can also look for information at:

=over

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Sub-Throttler>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Sub-Throttler>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Sub-Throttler>

=item * Search CPAN

L<http://search.cpan.org/dist/Sub-Throttler/>

=back


=head1 AUTHOR

Alex Efros  C<< <powerman@cpan.org> >>


=head1 LICENSE AND COPYRIGHT

Copyright 2014 Alex Efros <powerman@cpan.org>.

This program is distributed under the MIT (X11) License:
L<http://www.opensource.org/licenses/mit-license.php>

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

