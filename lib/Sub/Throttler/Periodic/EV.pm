package Sub::Throttler::Periodic::EV;

use warnings;
use strict;
use utf8;
use feature ':5.10';
use Carp;
our @CARP_NOT = qw( Sub::Throttler );

use version; our $VERSION = qv('0.2.0');    # REMINDER: update Changes

# REMINDER: update dependencies in Build.PL
use parent qw( Sub::Throttler::Periodic );
use Scalar::Util qw( weaken );
use EV;


sub new {
    my $self = shift->SUPER::new(@_);
    weaken(my $this = $self);
    $self->{_t} = EV::periodic 0, $self->{period}, 0, sub { $this && $this->_tick() };
    $self->{_t}->keepalive(0);
    return $self;
}

sub period {
    if (1 == @_) {
        return shift->SUPER::period();
    }
    my $self = shift->SUPER::period(@_);
    $self->{_t}->set(0, $self->{period}, 0);
    return $self;
}

sub release {
    my $self = shift->SUPER::release(@_);
    if (!keys %{ $self->{acquired} }) {
        $self->{_t}->keepalive(0);
    }
    return $self;
}

sub release_unused {
    my $self = shift->SUPER::release_unused(@_);
    if (!keys %{ $self->{acquired} }) {
        $self->{_t}->keepalive(0);
    }
    return $self;
}

sub try_acquire {
    my $self = shift;
    if ($self->SUPER::try_acquire(@_)) {
        $self->{_t}->keepalive(1);
        return 1;
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
    
    my $throttle = Sub::Throttler::Periodic::EV->new(period => 0.1, limit => 42);

See L<Sub::Throttler::Periodic> for more examples.


=head1 DESCRIPTION

This is a plugin for L<Sub::Throttler> providing simple algorithm for
throttling by rate (quantity per time) of used resources.

This is implementation of L<Sub::Throttler::Periodic> algorithm for
applications using L<EV> event loop.

It uses EV::timer, but will avoid keeping your event loop running when it
doesn't needed anymore (if there are no acquired resources).


=head1 EXPORTS

Nothing.


=head1 INTERFACE

L<Sub::Throttler::Periodic::EV> inherits all methods from L<Sub::Throttler::Periodic>.


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

