package Sub::Throttler::Rate::EV;

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
use Scalar::Util qw( weaken );
use EV;


sub new {
    my $self = shift->SUPER::new(@_);
    $self->{period} //= 1;
    $self->{_t} = EV::periodic 0, $self->{period}, 0, _weak_cb($self, \&_tick);
    $self->{_t}->keepalive(0);
    return $self;
}

sub period {
    my ($self, $period) = @_;
    if (1 == @_) {
        return $self->{period};
    }
    $self->{period} = $period;
    $self->{_t}->set(0, $self->{period}, 0);
    return $self;
}

# TODO сделать $data=dump() и restore($data), только для Rate и Periodic,
# restore() восстанавливает занятые ресурсы без привязывания их к id
# (т.е. без возможности их форсировано освободить), формат $data -
# недокументированная perl-структура (сериализация - задача юзера)

# TODO switch to sliding window algo
# TODO keep current algo as Periodic::EV
sub acquire {
    my $self = shift;
    if ($self->SUPER::acquire(@_)) {
        $self->{_t}->keepalive(1);
        return 1;
    }
    return;
}

sub release {
    my ($self, $id) = @_;
    croak sprintf '%s not acquired anything', $id if !$self->{acquired}{$id};
    delete $self->{acquired}{$id};
    if (!keys %{ $self->{acquired} }) {
        $self->{_t}->keepalive(0);
    }
    return $self;
}

sub release_unused {
    my $self = shift;
    $self->SUPER::release_unused(@_);
    if (!keys %{ $self->{acquired} }) {
        $self->{_t}->keepalive(0);
    }
    return $self;
}

sub _tick {
    my $self = shift;
    for my $id (keys %{ $self->{acquired} }) {
        for my $key (keys %{ $self->{acquired}{$id} }) {
            $self->{acquired}{$id}{$key} = 0;
        }
    }
    # OPTIMIZATION вызывать throttle_flush() только если могли появиться
    # свободные ресурсы (т.е. если какие-то ресурсы освободились)
    if (keys %{ $self->{used} }) {
        $self->{used} = {};
        throttle_flush();
    }
    return;
}

sub _weak_cb {
    my ($this, $method, @p) = @_;
    weaken $this;
    return sub { $this && $this->$method(@p, @_) };
}


1; # Magic true value required at end of module
__END__

=encoding utf8

=head1 NAME

Sub::Throttler::Rate::EV - throttle by rate (quantity per time)


=head1 SYNOPSIS

    use Sub::Throttler::Rate::EV;
    
    # default limit=1, period=1
    my $throttle = Sub::Throttler::Rate::EV->new(period => 0.1, limit => 42);
    
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
    if ($throttle->acquire($id, $key, $quantity)) {
        ...
        $throttle->release($id);
        $throttle->release_unused($id);
    }
    my $quantity = $throttle->used($key);
    $throttle->used($key, $quantity);


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

L<Sub::Throttler::Rate::EV> inherits all methods from L<Sub::Throttler::Limit>
and implements the following ones.

=over

=item new

    my $throttle = Sub::Throttler::Rate::EV->new;
    my $throttle = Sub::Throttler::Rate::EV->new(period => 0.1, limit => 42);

Create and return new instance of this algorithm.

Default C<period> is C<1.0>, C<limit> is C<1>.

See L<Sub::Throttler::algo/"new"> for more details.

=item period

    my $period = $throttle->period;
    $throttle  = $throttle->period($period);

Get or modify current C<period>.

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

