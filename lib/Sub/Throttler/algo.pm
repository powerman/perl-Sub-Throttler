package Sub::Throttler::algo;

use warnings;
use strict;
use utf8;
use feature ':5.10';
use Carp;
our @CARP_NOT = qw( Sub::Throttler );

use version; our $VERSION = qv('0.2.0');    # REMINDER: update Changes

# REMINDER: update dependencies in Build.PL
use Scalar::Util qw( blessed );
use Sub::Throttler qw( throttle_add );


use constant DEFAULT_KEY    => 'default';


sub apply_to {
    goto &throttle_add;
}

sub apply_to_functions {
    my ($self, @func) = @_;
    my %func = map { $_ => DEFAULT_KEY }
        map {/::/ms ? $_ : caller().q{::}.$_} @func;
    $self->apply_to(sub {
        my ($this, $name) = @_;
        my $key
          = $this   ? undef
          : @func   ? $func{$name}
          :           DEFAULT_KEY
          ;
        return $key ? {$key=>1} : undef;
    });
    return $self;
}

sub apply_to_methods {
    my ($self, $class_or_obj, @func) = @_;
    croak 'require class or object'
        if ref $class_or_obj && !blessed($class_or_obj);
    croak 'method must not contain ::' if grep {/::/ms} @func;
    my %func = map { $_ => DEFAULT_KEY } @func;
    if (1 == @_) {
        $self->apply_to(sub {
            my ($this) = @_;
            my $key = $this ? DEFAULT_KEY : undef;
            return $key ? {$key=>1} : undef;
        });
    } elsif (ref $class_or_obj) {
        my $obj = $class_or_obj;
        $self->apply_to(sub {
            my ($this, $name) = @_;
            my $key
              = !$this || !ref $this || $this != $obj           ? undef
              : @func                                           ? $func{$name}
              :                                                   DEFAULT_KEY
              ;
            return $key ? {$key=>1} : undef;
        });
    } else {
        my $class = $class_or_obj;
        $self->apply_to(sub {
            my ($this, $name) = @_;
            my $key
              = !eval {local $SIG{__DIE__}; $this->isa($class)} ? undef
              : @func                                           ? $func{$name}
              :                                                   DEFAULT_KEY
              ;
            return $key ? {$key=>1} : undef;
        });
    }
    return $self;
}


1; # Magic true value required at end of module
__END__

=encoding utf8

=head1 NAME

Sub::Throttler::algo - base class for throttling algorithms


=head1 SYNOPSIS

    package Sub::Throttler::YourCustomAlgo;
    use parent qw( Sub::Throttler::algo );
    sub new { ... }
    sub load { ... }
    sub save { ... }
    sub acquire { ... }
    sub try_acquire { ... }
    sub release { ... }
    sub release_unused { ... }

    package main;
    $throttle->apply_to_methods(Mojo::UserAgent => qw( get post ));


=head1 DESCRIPTION

This is a base class useful for implementing throttling algorithm plugins
for L<Sub::Throttler>. For more details check
L<Sub::Throttler::Limit/"Implementing throttle algorithms/plugins">.


=head1 EXPORTS

Nothing.


=head1 INTERFACE

=over

=item new

    my $throttle = Sub::Throttler::YourCustomAlgo->new(...);

Create and return new instance of this algorithm.

Supported params depends on concrete algorithm, for example see
L<Sub::Throttler::Limit/"new">, L<Sub::Throttler::Periodic/"new">.

It won't affect throttling of your functions/methods until you'll call
L</"apply_to_functions"> or L</"apply_to_methods"> or L</"apply_to"> or
L<Sub::Throttler/"throttle_add">. You don't have to keep returned object
after you've configured throttling by calling these methods.

=item load

    my $throttle = Sub::Throttler::YourCustomAlgo->load($state);

Create and return new instance of this algorithm.

Parameter C<$state> is one returned by L</"save">, with details about
object configuration and acquired resources.

While processing C<$state> load() should take in account what it may be
returned by save() from different version of this algorithm module and
difference in time between calls to save() and load() (including time jump
backward or reset of monotonic clock because of OS reboot).

Which data is actually restored by load() depends on algorithm - in some
cases it won't be possible to release resources acquired while previous
run of this application (when save() was called), so it may be a bad idea
to restore acquired state of these resources while load().

=item save

    my $state = $throttle->save(...);

Return complex perl data structure with details about current
configuration and acquired resources (also usually contain current version
and time details needed for L</"load">).

User is supposed to serialize returned value (for ex. into JSON format),
save it into file/database, and use later with L</"load"> if she wanna
keep information about used resources between application restarts (to
protect against occasional crashes it make sense to save current state
every few seconds/minutes).

=back

=head2 Activate throttle for selected subrouties

=over

=item apply_to_functions

    $throttle = $throttle->apply_to_functions;
    $throttle = $throttle->apply_to_functions('func', 'Some::func2');

When called without params will apply to all functions with throttling
support. When called with list of function names will apply to only these
functions (if function name doesn't contain package name it will use
caller's package for that name).

All affected functions will use C<1> resource named C<"default">.

=item apply_to_methods

    $throttle = $throttle->apply_to_methods;
    $throttle = $throttle->apply_to_methods('Class');
    $throttle = $throttle->apply_to_methods($object);
    $throttle = $throttle->apply_to_methods(Class   => qw( method method2 ));
    $throttle = $throttle->apply_to_methods($object => qw( method method2 ));

When called without params will apply to all methods with throttling
support. When called only with C<'Class'> or C<$object> param will apply
to all methods of that class/object. When given list of methods will apply
only to these methods.

In C<'Class'> case will apply both to Class's methods and methods of any
object of that Class.

All affected methods will use C<1> resource named C<"default">.

=item apply_to

    $throttle = $throttle->apply_to(sub {
        my ($this, $name, @params) = @_;
        if (!$this) {
            # it's a function, $name contains package:
            # $name eq 'main::func'
        }
        elsif (!ref $this) {
            # it's a class method:
            # $this eq 'Class::Name'
            # $name eq 'new'
        }
        else {
            # it's an object method:
            # $this eq $object
            # $name eq 'method'
        }
        return;                     # do no throttle it
        return undef;               # do no throttle it
        return {};                  # do no throttle it
        return { key=>1 };          # throttle it by acquiring 1 resource 'key'
        return { k1=>2, k2=>5 };    # throttle it by atomically acquiring:
                                    #   2 resources 'k1' and 5 resources 'k2'
    });

This is most complex but also most flexible way to configure throttling -
you can introspect what function/method and with what params was called
and return which and how many resources it should acquire before run.

=back

=head2 Manual resource management

It's unlikely you'll need to manually manage resources, but it's possible
to do if you want this - just be careful because if you acquire and don't
release resource used to throttle your functions/methods they may won't be
run anymore.

All methods listed below isn't implemented in L<Sub::Throttler::algo>,
they must be provided by algorithm module inherited from this base class.

=over

=item acquire

    $throttle = $throttle->acquire($id, $key, $quantity);

Blocking version of L</"try_acquire"> - it will either successfully
acquire requested resource or throw exception. If this resource is not
available right now but will become available later (this depends on
throttling algorithm) it will wait (using sleep()) until resource will be
available.

=item try_acquire

    my $is_acquired = $throttle->try_acquire($id, $key, $quantity);

The throttling engine uses C<Scalar::Util::refaddr($done)> for C<$id>
(large number), so it's safe for you to use either non-numbers as C<$id>
or refaddr() of your own variables.

    $throttle->try_acquire('reserve', 'default', 3) || die;
    $throttle->try_acquire('extra reserve', 'default', 1) || die;

Will throw if some C<$key> will be acquired more than once by same C<$id>
or C<$quantity> is non-positive.

=item release

    $throttle = $throttle->release($id);

Release all resources previously acquired by one or more calls to
L</"acquire"> or L</"try_acquire"> using this C<$id> (this may or may not
make them immediately available for acquiring again depending on
plugin/algorithms).

=item release_unused

    $throttle = $throttle->release_unused($id);

Release all resources previously acquired by one or more calls to
L</"acquire"> or L</"try_acquire"> using this C<$id>.

Treat these resources as unused, to make it possible to reuse them as soon
as possible (this may or may not differ from L</"release"> depending on
plugin/algorithms).

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

