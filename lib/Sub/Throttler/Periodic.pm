package Sub::Throttler::Periodic;

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
use Time::HiRes qw( time );


sub new {
    my ($class, %opt) = @_;
    my $self = bless {
        limit   => delete $opt{limit}   // 1,
        period  => delete $opt{period}  // 1,
        }, ref $class || $class;
    croak 'bad param: '.(keys %opt)[0] if keys %opt;
    $self->{_at} = int(time/$self->{period})*$self->{period} + $self->{period};
    return $self;
}

sub period {
    my ($self, $period) = @_;
    if (1 == @_) {
        return $self->{period};
    }
    $self->{period} = $period;
    $self->{_at} = int(time/$self->{period})*$self->{period} + $self->{period};
    return $self;
}

# TODO сделать $data=dump() и restore($data), только для Rate и Periodic,
# restore() восстанавливает занятые ресурсы без привязывания их к id
# (т.е. без возможности их форсировано освободить), формат $data -
# недокументированная perl-структура (сериализация - задача юзера)

sub release {
    my ($self, $id) = @_;
    croak sprintf '%s not acquired anything', $id if !$self->{acquired}{$id};
    delete $self->{acquired}{$id};
    return $self;
}

sub tick {
    my $self = shift;

    return if time < $self->{_at};
    $self->{_at} = int(time/$self->{period})*$self->{period} + $self->{period};

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

sub tick_delay {
    my $self = shift;
    my $delay = $self->{_at} - time;
    return $delay < 0 ? 0 : $delay;
}


1; # Magic true value required at end of module
__END__

=encoding utf8

=head1 NAME

Sub::Throttler::Periodic - throttle by rate (quantity per time)


=head1 SYNOPSIS

    use Sub::Throttler::Periodic;
    
    # default limit=1, period=1
    my $throttle = Sub::Throttler::Periodic->new(period => 0.1, limit => 42);
    
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


=head1 DESCRIPTION

This is a plugin for L<Sub::Throttler> providing simple algorithm for
throttling by rate (quantity per time) of used resources.

This algorithm works like L<Sub::Throttler::Limit> with one difference:
when current time is divisible by given period value all used resources
will be made available for acquiring again.

It doesn't use event loops, but to keep it going you have to manually call
L</"tick"> periodically - either just often enough (like every 0.01 sec or
about 1/10 of L</"period"> sec) or precisely when needed by delaying next
call by L</"tick_delay"> sec. If your application use L<EV> event loop you
can use L<Sub::Throttler::Periodic::EV> instead of this module to have
L</"tick"> called automatically.


=head1 EXPORTS

Nothing.


=head1 INTERFACE

L<Sub::Throttler::Periodic> inherits all methods from L<Sub::Throttler::algo>
and implements the following ones.

=over

=item new

    my $throttle = Sub::Throttler::Periodic->new;
    my $throttle = Sub::Throttler::Periodic->new(period => 0.1, limit => 42);

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

